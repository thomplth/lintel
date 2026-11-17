import Darwin
import Foundation
import LintelCore
import os

/// Performance counters, timings and signposts for development and local builds.
///
/// Compiled in for debug builds and for builds made with `-D LINTEL_METRICS` (Scripts/bundle.sh adds it); elsewhere
/// every call is an empty inline function.
enum Perf {
    #if DEBUG || LINTEL_METRICS
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    private static let ledger = OSAllocatedUnfairLock(initialState: MetricsLedger())
    private static let windowStart = OSAllocatedUnfairLock(initialState: Date())
    static let signposter = OSSignposter(subsystem: "app.lintel", category: .pointsOfInterest)

    @inline(__always)
    static func count(_ name: String, by amount: Int = 1) {
        guard isEnabled else { return }
        ledger.withLock { $0.count(name, by: amount) }
    }

    static func record(_ name: String, seconds: Double) {
        guard isEnabled else { return }
        ledger.withLock { $0.record(name, seconds: seconds) }
    }

    @inline(__always)
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let interval = signposter.beginInterval(name)
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            signposter.endInterval(name, interval)
            record("\(name)", seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        return try body()
    }

    static func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        guard isEnabled else { return try await body() }
        let interval = signposter.beginInterval(name)
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            signposter.endInterval(name, interval)
            record("\(name)", seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        return try await body()
    }

    /// The window so far, without ending it.
    static func summary() -> MetricsSummary {
        let since = windowStart.withLock { $0 }
        return ledger.withLock { $0.summary(over: Date().timeIntervalSince(since)) }
    }

    /// Ends the current window and starts the next.
    static func takeSummary() -> MetricsSummary {
        let now = Date()
        let since = windowStart.withLock { start in
            defer { start = now }
            return start
        }
        return ledger.withLock { ledger in
            defer { ledger.reset() }
            return ledger.summary(over: now.timeIntervalSince(since))
        }
    }

    /// The commit the running build was made from, stamped into Info.plist by Scripts/bundle.sh.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "LintelBuild") as? String ?? "dev"
    }
}

/// Appends a metrics record to a daily log once a minute, and counts main-thread stalls as they happen.
@MainActor
final class PerfRecorder {
    static let interval: TimeInterval = 60
    private nonisolated static let stallThreshold: TimeInterval = 0.1
    private static let daysKept = 14

    private let folder: URL
    private let runnerPID: () -> pid_t?
    private var timer: Timer?
    private var lastCPU: [pid_t: (seconds: Double, at: Double)] = [:]
    private let stallQueue = DispatchQueue(label: "perf-stall-watch", qos: .utility)

    init(home: AppHome, runnerPID: @escaping () -> pid_t?) {
        folder = home.root.appending(path: "Metrics")
        self.runnerPID = runnerPID
    }

    func start() {
        guard Perf.isEnabled else { return }
        _ = Perf.takeSummary()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        prune()
        _ = cpuPercent(of: getpid())
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.write() }
        }
        watchForStalls()
    }

    /// The live numbers for `Lintel ctl '{"cmd":"metrics"}'`, without ending the minute being recorded.
    func snapshot() -> MetricsRecord {
        MetricsRecord(time: Date(), build: Perf.build, process: process(advancing: false), summary: Perf.summary())
    }

    private func write() {
        let record = MetricsRecord(time: Date(), build: Perf.build, process: process(advancing: true), summary: Perf.takeSummary())
        guard let line = try? record.line() else { return }
        let day = record.time.formatted(.iso8601.year().month().day())
        let file = folder.appending(path: "metrics-\(day).jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(Self.daysKept) * 86400)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap({ $0 < cutoff }) == true {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// CPU is averaged since the last record written; a snapshot in between reads it without starting a new average.
    private func process(advancing: Bool) -> MetricsRecord.Process {
        MetricsRecord.Process(
            appCPU: cpuPercent(of: getpid(), advancing: advancing),
            runnerCPU: runnerPID().map { cpuPercent(of: $0, advancing: advancing) } ?? 0,
            memoryMB: (Double(footprint(of: getpid())) / 1_048_576 * 10).rounded() / 10
        )
    }

    /// Average CPU since the previous call for the same process, in percent of one core.
    private func cpuPercent(of pid: pid_t, advancing: Bool = true) -> Double {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return 0 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(usage.ri_user_time + usage.ri_system_time)
        let seconds = ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
        let now = ProcessInfo.processInfo.systemUptime
        let last = lastCPU[pid]
        if advancing || last == nil { lastCPU[pid] = (seconds, now) }
        guard let last, now > last.at else { return 0 }
        return ((seconds - last.seconds) / (now - last.at) * 1000).rounded() / 10
    }

    private func footprint(of pid: pid_t) -> UInt64 {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? usage.ri_phys_footprint : 0
    }

    /// Posts a ping to the main queue every tenth of a second and records how late each one runs, so a frozen bar
    /// shows up as `main.stall` even when nothing else was being measured.
    private func watchForStalls() {
        Self.pingMain(from: stallQueue)
    }

    private nonisolated static func pingMain(from queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + 0.1) {
            let posted = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                let delay = Double(DispatchTime.now().uptimeNanoseconds - posted) / 1e9
                if delay >= stallThreshold {
                    Perf.count("main.stalls")
                    Perf.record("main.stall", seconds: delay)
                }
                pingMain(from: queue)
            }
        }
    }
}
