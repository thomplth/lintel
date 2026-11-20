import AppKit
import Combine
import Foundation
import LintelCore

struct JobSnapshot: Identifiable, Equatable {
    var key: String { "\(moduleID):\(spec.id)" }
    var id: String { key }
    var moduleID: String
    var moduleTitle: String
    var spec: JobManifest
    var record: JobRecord

    var effectiveStatus: JobRunStatus {
        record.enabled ? record.status : .paused
    }
}

/// Runs module-declared background jobs on cron, interval, or dynamic schedules, surviving sleep/wake and persisting state.
@MainActor
final class JobHost: ObservableObject {
    private struct Registration {
        var moduleID: String
        var moduleTitle: String
        var jobs: [JobManifest]
    }

    let home: AppHome
    let runner: RunnerClient
    let services: HostServices

    @Published private(set) var snapshots: [JobSnapshot] = []

    var onChanged: (_ affectedModule: String?) -> Void = { _ in }
    var loadedModulesProvider: () -> [(id: String, allowsAllJobs: Bool)] = { [] }

    private var registrations: [String: Registration] = [:]
    private var records: [String: JobRecord] = [:]
    private var tickTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var isStarted = false

    init(home: AppHome, runner: RunnerClient, services: HostServices) {
        self.home = home
        self.runner = runner
        self.services = services
        var loaded = home.load([String: JobRecord].self, from: home.jobsFile) ?? [:]
        // Reset any job left marked running from an unclean exit.
        for key in Array(loaded.keys) {
            guard var entry = loaded[key], entry.status == .running else { continue }
            entry.status = entry.lastOkAt != nil ? .ok : .idle
            loaded[key] = entry
        }
        self.records = loaded
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateDue(isWake: false) }
        }
        tickTimer?.tolerance = 3
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                MainActor.assumeIsolated { self?.evaluateDue(isWake: true) }
            }
        }
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        isStarted = false
    }

    func register(moduleID: String, moduleTitle: String, jobs: [JobManifest]) {
        if jobs.isEmpty {
            unregister(moduleID: moduleID)
            return
        }
        registrations[moduleID] = Registration(moduleID: moduleID, moduleTitle: moduleTitle, jobs: jobs)
        let now = Date()
        var mutated = false
        for spec in jobs {
            let key = "\(moduleID):\(spec.id)"
            var record = records[key] ?? JobRecord()
            if record.nextRunAt == nil, let initial = JobPlanner.initialNextRun(for: spec, record: record, now: now) {
                record.nextRunAt = initial
                mutated = true
            }
            records[key] = record
        }
        if mutated { save() }
        publishAndBroadcast(affectedModule: moduleID)
        // Run due jobs shortly after registration so startup/reload settles first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.evaluateDue(isWake: false)
        }
    }

    func unregister(moduleID: String) {
        guard registrations.removeValue(forKey: moduleID) != nil else { return }
        publishAndBroadcast(affectedModule: moduleID)
    }

    func pushSnapshotsToModule(_ moduleID: String, allowsAllJobs: Bool) {
        let own = snapshots.filter { $0.moduleID == moduleID }.map {
            JobPlanner.jsonSnapshot(moduleID: $0.moduleID, moduleTitle: $0.moduleTitle, spec: $0.spec, record: $0.record)
        }
        let all: [JSONValue] = allowsAllJobs ? snapshots.map {
            JobPlanner.jsonSnapshot(moduleID: $0.moduleID, moduleTitle: $0.moduleTitle, spec: $0.spec, record: $0.record)
        } : []
        runner.setJobs(key: moduleID, own: own, all: all)
    }

    func resolve(callerModule: String, identifier: String) -> (moduleID: String, jobID: String)? {
        if let colon = identifier.firstIndex(of: ":") {
            let targetModule = String(identifier[..<colon])
            let targetJob = String(identifier[identifier.index(after: colon)...])
            guard targetModule == callerModule || services.grants[callerModule]?.manifest.allows(.jobs) == true else {
                return nil
            }
            return (targetModule, targetJob)
        }
        return (callerModule, identifier)
    }

    func evaluateDue(isWake: Bool) {
        let now = Date()
        for reg in registrations.values {
            for spec in reg.jobs {
                let key = "\(reg.moduleID):\(spec.id)"
                let record = records[key] ?? JobRecord()
                if JobPlanner.isDue(spec: spec, record: record, now: now, isWake: isWake) {
                    Task { [weak self] in
                        _ = await self?.runNow(moduleID: reg.moduleID, jobID: spec.id)
                    }
                }
            }
        }
    }

    @discardableResult
    func runNow(moduleID: String, jobID: String) async -> JSONValue {
        guard let reg = registrations[moduleID], let spec = reg.jobs.first(where: { $0.id == jobID }) else {
            return ["error": .string("unknown job \(moduleID):\(jobID)")]
        }
        let key = "\(moduleID):\(jobID)"
        var record = records[key] ?? JobRecord()
        if record.status == .running {
            return ["skipped": .bool(true), "reason": .string("already running")]
        }

        let startedAt = Date()
        record.status = .running
        records[key] = record
        services.appendLog("job '\(jobID)' started", for: moduleID)
        publishAndBroadcast(affectedModule: moduleID)

        do {
            let reply = try await runner.runJob(key: moduleID, name: jobID, timeout: spec.timeoutSeconds + 15)
            let finishedAt = Date()
            let summary = reply["summary"].string ?? reply.string
            var updated = records[key] ?? record
            JobPlanner.recordSuccess(spec: spec, record: &updated, startedAt: startedAt, finishedAt: finishedAt, summary: summary)
            records[key] = updated
            save()
            let note = summary.map { " (\($0))" } ?? ""
            services.appendLog("job '\(jobID)' succeeded in \(updated.durationMs ?? 0)ms\(note)", for: moduleID)
            publishAndBroadcast(affectedModule: moduleID)
            return JobPlanner.jsonSnapshot(moduleID: moduleID, moduleTitle: reg.moduleTitle, spec: spec, record: updated)
        } catch {
            let finishedAt = Date()
            let message = ModuleFailure.describe(error)
            var updated = records[key] ?? record
            let shouldNotify = JobPlanner.recordFailure(spec: spec, record: &updated, startedAt: startedAt, finishedAt: finishedAt, error: message, now: finishedAt)
            records[key] = updated
            save()
            services.appendLog("job '\(jobID)' failed: \(message)", for: moduleID)
            if shouldNotify {
                HostServices.notify(title: "\(reg.moduleTitle): \(spec.title) failed", body: message, module: "Lintel")
            }
            publishAndBroadcast(affectedModule: moduleID)
            return JobPlanner.jsonSnapshot(moduleID: moduleID, moduleTitle: reg.moduleTitle, spec: spec, record: updated)
        }
    }

    func setNext(moduleID: String, jobID: String, date: Date?) {
        guard let reg = registrations[moduleID], reg.jobs.contains(where: { $0.id == jobID }) else { return }
        let key = "\(moduleID):\(jobID)"
        var record = records[key] ?? JobRecord()
        // Avoid redundant writes if the timestamp is effectively unchanged (< 15s diff).
        if let existing = record.nextRunAt, let date, abs(existing.timeIntervalSince(date)) < 15 { return }
        if record.nextRunAt == nil && date == nil { return }
        JobPlanner.setNextRun(record: &record, at: date)
        records[key] = record
        save()
        publishAndBroadcast(affectedModule: moduleID)
    }

    func setEnabled(moduleID: String, jobID: String, enabled: Bool) {
        guard let reg = registrations[moduleID], let spec = reg.jobs.first(where: { $0.id == jobID }) else { return }
        let key = "\(moduleID):\(jobID)"
        var record = records[key] ?? JobRecord()
        guard record.enabled != enabled else { return }
        record.enabled = enabled
        if !enabled {
            if record.status != .running { record.status = .paused }
        } else {
            if record.status == .paused { record.status = record.lastOkAt != nil ? .ok : .idle }
            if record.nextRunAt == nil {
                record.nextRunAt = JobPlanner.initialNextRun(for: spec, record: record, now: Date())
            }
        }
        records[key] = record
        save()
        services.appendLog("job '\(jobID)' \(enabled ? "resumed" : "paused")", for: moduleID)
        publishAndBroadcast(affectedModule: moduleID)
    }

    func clearError(moduleID: String, jobID: String) {
        let key = "\(moduleID):\(jobID)"
        guard var record = records[key] else { return }
        record.lastError = nil
        record.consecutiveErrors = 0
        if record.status == .failed {
            record.status = record.enabled ? (record.lastOkAt != nil ? .ok : .idle) : .paused
        }
        records[key] = record
        save()
        publishAndBroadcast(affectedModule: moduleID)
    }

    func snapshots(for moduleID: String) -> [JobSnapshot] {
        snapshots.filter { $0.moduleID == moduleID }
    }

    var failingCount: Int {
        snapshots.filter { $0.effectiveStatus == .failed }.count
    }

    var runningCount: Int {
        snapshots.filter { $0.effectiveStatus == .running }.count
    }

    private func save() {
        home.save(records, to: home.jobsFile)
    }

    private func publishAndBroadcast(affectedModule: String?) {
        var next: [JobSnapshot] = []
        for moduleID in registrations.keys.sorted() {
            guard let reg = registrations[moduleID] else { continue }
            for spec in reg.jobs {
                let key = "\(moduleID):\(spec.id)"
                let record = records[key] ?? JobRecord()
                next.append(JobSnapshot(moduleID: moduleID, moduleTitle: reg.moduleTitle, spec: spec, record: record))
            }
        }
        snapshots = next
        for entry in loadedModulesProvider() {
            pushSnapshotsToModule(entry.id, allowsAllJobs: entry.allowsAllJobs)
        }
        onChanged(affectedModule)
    }
}
