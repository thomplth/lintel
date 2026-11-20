import Foundation

/// Standard 5-field cron expression: `minute hour day-of-month month day-of-week` (0 or 7 = Sunday).
public struct CronExpression: Equatable, Hashable, Sendable {
    public let raw: String
    public let minutes: Set<Int>
    public let hours: Set<Int>
    public let daysOfMonth: Set<Int>
    public let months: Set<Int>
    public let daysOfWeek: Set<Int>
    private let dayOfMonthWildcard: Bool
    private let dayOfWeekWildcard: Bool

    public init(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5 else {
            throw JobManifest.Invalid(message: "cron expression '\(raw)' must have 5 fields (minute hour day month weekday)")
        }
        self.raw = trimmed
        self.minutes = try Self.parseField(parts[0], range: 0...59, name: "minute")
        self.hours = try Self.parseField(parts[1], range: 0...23, name: "hour")
        self.daysOfMonth = try Self.parseField(parts[2], range: 1...31, name: "day of month")
        self.months = try Self.parseField(parts[3], range: 1...12, name: "month")
        let rawDow = try Self.parseField(parts[4], range: 0...7, name: "weekday")
        self.daysOfWeek = Set(rawDow.map { $0 == 7 ? 0 : $0 })
        self.dayOfMonthWildcard = parts[2] == "*"
        self.dayOfWeekWildcard = parts[4] == "*"
    }

    /// Computes the earliest Date strictly after `date` (aligned to second 0) matching this expression.
    public func nextFire(after date: Date, calendar: Calendar = .current) -> Date? {
        guard var comps = Optional(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)),
              var candidate = calendar.date(from: comps)
        else { return nil }
        candidate = candidate.addingTimeInterval(60)

        // Search up to 4 years forward (handles leap years like Feb 29).
        let maxIterations = 4 * 366 * 24 * 60
        var iterations = 0
        while iterations < maxIterations {
            iterations += 1
            comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: candidate)
            guard let month = comps.month, let day = comps.day, let hour = comps.hour,
                  let minute = comps.minute, let weekday = comps.weekday
            else { return nil }

            if !months.contains(month) {
                var nextMonth = DateComponents(year: comps.year, month: month + 1, day: 1, hour: 0, minute: 0)
                if month == 12 { nextMonth.year = (comps.year ?? 2026) + 1; nextMonth.month = 1 }
                guard let jumped = calendar.date(from: nextMonth) else { return nil }
                candidate = jumped
                continue
            }

            let cronDow = weekday - 1 // Calendar.weekday: 1=Sun..7=Sat -> 0=Sun..6=Sat
            let domMatch = daysOfMonth.contains(day)
            let dowMatch = daysOfWeek.contains(cronDow)
            let dayMatches: Bool = if dayOfMonthWildcard && dayOfWeekWildcard {
                true
            } else if dayOfMonthWildcard {
                dowMatch
            } else if dayOfWeekWildcard {
                domMatch
            } else {
                domMatch || dowMatch
            }

            if !dayMatches {
                guard let startOfDay = calendar.date(from: DateComponents(year: comps.year, month: month, day: day, hour: 0, minute: 0)),
                      let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)
                else { return nil }
                candidate = nextDay
                continue
            }

            if !hours.contains(hour) {
                guard let startOfHour = calendar.date(from: DateComponents(year: comps.year, month: month, day: day, hour: hour, minute: 0)),
                      let nextHour = calendar.date(byAdding: .hour, value: 1, to: startOfHour)
                else { return nil }
                candidate = nextHour
                continue
            }

            if !minutes.contains(minute) {
                candidate = candidate.addingTimeInterval(60)
                continue
            }

            return candidate
        }
        return nil
    }

    private static func parseField(_ field: String, range: ClosedRange<Int>, name: String) throws -> Set<Int> {
        var result = Set<Int>()
        for segment in field.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard !segment.isEmpty else {
                throw JobManifest.Invalid(message: "empty \(name) segment in cron expression")
            }
            let stepParts = segment.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let step: Int
            if stepParts.count == 2 {
                guard let parsedStep = Int(stepParts[1]), parsedStep > 0 else {
                    throw JobManifest.Invalid(message: "invalid step '\(stepParts[1])' in \(name) field")
                }
                step = parsedStep
            } else {
                step = 1
            }

            let base = stepParts[0]
            let low: Int
            let high: Int
            if base == "*" {
                low = range.lowerBound
                high = range.upperBound
            } else if base.contains("-") {
                let bounds = base.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard bounds.count == 2, let a = Int(bounds[0]), let b = Int(bounds[1]),
                      range.contains(a), range.contains(b), a <= b
                else {
                    throw JobManifest.Invalid(message: "invalid range '\(base)' in \(name) field")
                }
                low = a
                high = b
            } else {
                guard let value = Int(base), range.contains(value) else {
                    throw JobManifest.Invalid(message: "invalid value '\(base)' in \(name) field")
                }
                low = value
                high = stepParts.count == 2 ? range.upperBound : value
            }

            var current = low
            while current <= high {
                result.insert(current)
                current += step
            }
        }
        guard !result.isEmpty else {
            throw JobManifest.Invalid(message: "no matching values in \(name) field")
        }
        return result
    }
}

public enum JobTrigger: Equatable, Hashable, Sendable {
    case every(seconds: Double)
    case cron(CronExpression)
    case manual

    public var summary: String {
        switch self {
        case .every(let seconds):
            let total = Int(seconds)
            if total % 3600 == 0 { return "every \(total / 3600)h" }
            if total >= 3600 {
                let h = total / 3600
                let m = (total % 3600) / 60
                return m > 0 ? "every \(h)h \(m)m" : "every \(h)h"
            }
            if total % 60 == 0 { return "every \(total / 60)m" }
            return "every \(total)s"
        case .cron(let expr):
            return "cron \(expr.raw)"
        case .manual:
            return "manual"
        }
    }
}

public struct JobManifest: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var trigger: JobTrigger
    public var timeoutSeconds: Double
    public var runOnWake: Bool
    public var retrySeconds: Double

    public struct Invalid: Error, Equatable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    public init(_ value: JSONValue) throws {
        guard value.object != nil else { throw Invalid(message: "job definition must be an object") }
        guard let id = value["id"].string, ModuleManifest.isValid(id: id) else {
            throw Invalid(message: "job id must be lowercase letters, digits and dashes, at most 40 characters")
        }
        self.id = id
        self.title = value["title"].string.flatMap { $0.isEmpty ? nil : $0 } ?? id
        let schedule = value["schedule"]
        if let every = schedule["every"].number ?? value["intervalSeconds"].number {
            guard every >= 60 else { throw Invalid(message: "job '\(id)' schedule.every must be at least 60 seconds") }
            self.trigger = .every(seconds: min(every, 7 * 86_400))
        } else if let cronText = schedule["cron"].string ?? value["cron"].string {
            self.trigger = .cron(try CronExpression(cronText))
        } else if schedule["manual"].bool == true {
            self.trigger = .manual
        } else {
            throw Invalid(message: "job '\(id)' needs schedule: { every: seconds }, { cron: '...' }, or { manual: true }")
        }
        self.timeoutSeconds = min(max(value["timeoutSeconds"].number ?? 60, 5), 600)
        self.runOnWake = value["runOnWake"].bool ?? true
        self.retrySeconds = min(max(value["retrySeconds"].number ?? 900, 60), 86_400)
    }
}

public enum JobRunStatus: String, Codable, Equatable, Sendable {
    case idle, running, ok, failed, paused
}

public struct JobRunRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(Int(startedAt.timeIntervalSince1970 * 1000))" }
    public var startedAt: Date
    public var finishedAt: Date
    public var durationMs: Int
    public var succeeded: Bool
    public var summary: String?
    public var error: String?

    public init(startedAt: Date, finishedAt: Date, succeeded: Bool, summary: String? = nil, error: String? = nil) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMs = max(0, Int((finishedAt.timeIntervalSince(startedAt) * 1000).rounded()))
        self.succeeded = succeeded
        self.summary = summary
        self.error = error
    }
}

public struct JobRecord: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var status: JobRunStatus
    public var lastRunAt: Date?
    public var lastOkAt: Date?
    public var nextRunAt: Date?
    public var durationMs: Int?
    public var summary: String?
    public var lastError: String?
    public var consecutiveErrors: Int
    public var lastNotifiedAt: Date?
    public var recentRuns: [JobRunRecord]

    public init(
        enabled: Bool = true,
        status: JobRunStatus = .idle,
        lastRunAt: Date? = nil,
        lastOkAt: Date? = nil,
        nextRunAt: Date? = nil,
        durationMs: Int? = nil,
        summary: String? = nil,
        lastError: String? = nil,
        consecutiveErrors: Int = 0,
        lastNotifiedAt: Date? = nil,
        recentRuns: [JobRunRecord] = []
    ) {
        self.enabled = enabled
        self.status = status
        self.lastRunAt = lastRunAt
        self.lastOkAt = lastOkAt
        self.nextRunAt = nextRunAt
        self.durationMs = durationMs
        self.summary = summary
        self.lastError = lastError
        self.consecutiveErrors = consecutiveErrors
        self.lastNotifiedAt = lastNotifiedAt
        self.recentRuns = recentRuns
    }
}

public enum JobPlanner {
    public static let maxHistory = 12
    public static let notifyCooldownSeconds: TimeInterval = 6 * 3600
    public static let maxBackoffSeconds: TimeInterval = 6 * 3600

    public static func initialNextRun(for spec: JobManifest, record: JobRecord, now: Date, calendar: Calendar = .current) -> Date? {
        if let existing = record.nextRunAt { return existing }
        switch spec.trigger {
        case .every:
            return now
        case .cron(let expr):
            return expr.nextFire(after: now, calendar: calendar)
        case .manual:
            return nil
        }
    }

    public static func isDue(spec: JobManifest, record: JobRecord, now: Date, isWake: Bool) -> Bool {
        guard record.enabled, record.status != .running else { return false }
        if isWake, !spec.runOnWake { return false }
        guard let next = record.nextRunAt else { return false }
        return next <= now
    }

    public static func recordSuccess(
        spec: JobManifest,
        record: inout JobRecord,
        startedAt: Date,
        finishedAt: Date,
        summary: String?,
        calendar: Calendar = .current
    ) {
        let entry = JobRunRecord(startedAt: startedAt, finishedAt: finishedAt, succeeded: true, summary: summary)
        record.status = record.enabled ? .ok : .paused
        record.lastRunAt = finishedAt
        record.lastOkAt = finishedAt
        record.durationMs = entry.durationMs
        record.summary = summary
        record.lastError = nil
        record.consecutiveErrors = 0
        record.recentRuns = Array(([entry] + record.recentRuns).prefix(maxHistory))

        switch spec.trigger {
        case .every(let seconds):
            record.nextRunAt = finishedAt.addingTimeInterval(seconds)
        case .cron(let expr):
            record.nextRunAt = expr.nextFire(after: finishedAt, calendar: calendar)
        case .manual:
            if let existing = record.nextRunAt, existing <= finishedAt {
                record.nextRunAt = nil
            }
        }
    }

    @discardableResult
    public static func recordFailure(
        spec: JobManifest,
        record: inout JobRecord,
        startedAt: Date,
        finishedAt: Date,
        error: String,
        now: Date
    ) -> Bool {
        let trimmed = String(error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let entry = JobRunRecord(startedAt: startedAt, finishedAt: finishedAt, succeeded: false, error: trimmed)
        record.status = record.enabled ? .failed : .paused
        record.lastRunAt = finishedAt
        record.durationMs = entry.durationMs
        record.lastError = trimmed
        record.consecutiveErrors += 1
        record.recentRuns = Array(([entry] + record.recentRuns).prefix(maxHistory))

        let factor = pow(2.0, Double(min(record.consecutiveErrors - 1, 2)))
        let delay = min(spec.retrySeconds * factor, maxBackoffSeconds)
        if spec.trigger != .manual {
            record.nextRunAt = now.addingTimeInterval(delay)
        } else {
            record.nextRunAt = nil
        }

        let shouldNotify: Bool
        if let lastNotified = record.lastNotifiedAt {
            shouldNotify = now.timeIntervalSince(lastNotified) >= notifyCooldownSeconds
        } else {
            shouldNotify = true
        }
        if shouldNotify {
            record.lastNotifiedAt = now
        }
        return shouldNotify
    }

    public static func setNextRun(record: inout JobRecord, at date: Date?) {
        record.nextRunAt = date
    }

    public static func jsonSnapshot(moduleID: String, moduleTitle: String, spec: JobManifest, record: JobRecord) -> JSONValue {
        let runs: [JSONValue] = record.recentRuns.map { run in
            [
                "startedAt": .number(run.startedAt.timeIntervalSince1970 * 1000),
                "finishedAt": .number(run.finishedAt.timeIntervalSince1970 * 1000),
                "durationMs": .number(Double(run.durationMs)),
                "succeeded": .bool(run.succeeded),
                "summary": run.summary.map(JSONValue.string) ?? .null,
                "error": run.error.map(JSONValue.string) ?? .null,
            ]
        }
        return [
            "key": .string("\(moduleID):\(spec.id)"),
            "moduleId": .string(moduleID),
            "moduleTitle": .string(moduleTitle),
            "id": .string(spec.id),
            "title": .string(spec.title),
            "schedule": .string(spec.trigger.summary),
            "timeoutSeconds": .number(spec.timeoutSeconds),
            "runOnWake": .bool(spec.runOnWake),
            "enabled": .bool(record.enabled),
            "status": .string(record.enabled ? record.status.rawValue : JobRunStatus.paused.rawValue),
            "isRunning": .bool(record.status == .running),
            "lastRunAt": record.lastRunAt.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null,
            "lastOkAt": record.lastOkAt.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null,
            "nextRunAt": record.nextRunAt.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null,
            "durationMs": record.durationMs.map { .number(Double($0)) } ?? .null,
            "summary": record.summary.map(JSONValue.string) ?? .null,
            "lastError": record.lastError.map(JSONValue.string) ?? .null,
            "consecutiveErrors": .number(Double(record.consecutiveErrors)),
            "recentRuns": .array(runs),
        ]
    }
}

/// Pure summary of what background work a module performs, shown in Studio's Dashboard and Inspector.
public struct ModuleBackgroundActivity: Equatable, Sendable {
    public var refreshSeconds: Double
    public var panelRefreshSeconds: Double
    public var jobCount: Int
    public var hosts: [String]
    public var tools: [String]
    public var secrets: [String]
    public var usesBrowser: Bool
    public var usesNotifications: Bool
    public var samplers: [String]

    public static func analyze(manifest: ModuleManifest, jobs: [JobManifest], source: String) -> ModuleBackgroundActivity {
        var tools: [String] = []
        var secrets: [String] = []
        var usesNotifications = false
        for cap in manifest.capabilities {
            switch cap {
            case .exec(let tool): tools.append(tool)
            case .secret(let name): secrets.append(name)
            case .notify: usesNotifications = true
            case .audio, .clipboard, .jobs: break
            }
        }
        let samplerNames = ["system", "network", "disk", "processes", "audio", "bluetooth"]
        let samplers = samplerNames.filter { source.contains("host.\($0)(") }
        let usesBrowser = source.contains("host.browser.") || source.contains("web(")
        return ModuleBackgroundActivity(
            refreshSeconds: manifest.refreshSeconds,
            panelRefreshSeconds: manifest.panelRefreshSeconds,
            jobCount: jobs.count,
            hosts: manifest.hosts,
            tools: tools,
            secrets: secrets,
            usesBrowser: usesBrowser,
            usesNotifications: usesNotifications,
            samplers: samplers
        )
    }

    public var shortBadges: [String] {
        var result: [String] = []
        if jobCount > 0 { result.append(jobCount == 1 ? "1 job" : "\(jobCount) jobs") }
        let secs = Int(refreshSeconds)
        result.append(secs >= 60 && secs % 60 == 0 ? "\(secs / 60)m" : "\(secs)s")
        if !tools.isEmpty { result.append("CLI") }
        if usesBrowser { result.append("Web") }
        return result
    }
}
