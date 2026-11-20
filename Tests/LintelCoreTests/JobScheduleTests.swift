import Foundation
import JavaScriptCore
import Testing
@testable import LintelCore

private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

@Suite struct CronExpressions {
    @Test func parsesEveryFifteenMinutes() throws {
        let cron = try CronExpression("*/15 * * * *")
        let next = cron.nextFire(after: utcDate(2026, 11, 20, 10, 7, 30), calendar: utcCalendar)
        #expect(next == utcDate(2026, 11, 20, 10, 15, 0))
    }

    @Test func parsesEveryFiveHoursAtMinuteZero() throws {
        let cron = try CronExpression("0 */5 * * *")
        let next = cron.nextFire(after: utcDate(2026, 11, 20, 10, 0, 0), calendar: utcCalendar)
        #expect(next == utcDate(2026, 11, 20, 15, 0, 0))
    }

    @Test func skipsWeekendForWeekdayCron() throws {
        // 2026-11-20 is Friday; 2026-11-23 is Monday.
        let cron = try CronExpression("30 9 * * 1-5")
        let next = cron.nextFire(after: utcDate(2026, 11, 20, 10, 0, 0), calendar: utcCalendar)
        #expect(next == utcDate(2026, 11, 23, 9, 30, 0))
    }

    @Test func rejectsMalformedCronExpressions() {
        #expect(throws: JobManifest.Invalid.self) { _ = try CronExpression("0 * *") }
        #expect(throws: JobManifest.Invalid.self) { _ = try CronExpression("61 * * * *") }
        #expect(throws: JobManifest.Invalid.self) { _ = try CronExpression("*/0 * * * *") }
    }
}

@Suite struct JobScheduling {
    @Test func parsesIntervalCronAndManualJobManifests() throws {
        let interval = try JobManifest([
            "id": "warm-codex",
            "title": "Warm Codex",
            "schedule": ["every": 18_120],
            "timeoutSeconds": 90,
        ])
        #expect(interval.id == "warm-codex")
        #expect(interval.trigger == .every(seconds: 18_120))
        #expect(interval.timeoutSeconds == 90)
        #expect(interval.runOnWake == true)

        let cron = try JobManifest([
            "id": "daily-backup",
            "schedule": ["cron": "0 3 * * *"],
            "runOnWake": false,
        ])
        #expect(cron.title == "daily-backup")
        #expect(cron.runOnWake == false)

        let manual = try JobManifest([
            "id": "sync-once",
            "schedule": ["manual": true],
        ])
        #expect(manual.trigger == .manual)
    }

    @Test func rejectsInvalidJobIDsAndMissingSchedules() {
        #expect(throws: JobManifest.Invalid.self) {
            _ = try JobManifest(["id": "Bad ID!", "schedule": ["every": 60]])
        }
        #expect(throws: JobManifest.Invalid.self) {
            _ = try JobManifest(["id": "ok-id", "schedule": [:]])
        }
    }

    @Test func intervalJobRunsImmediatelyWhenNeverRunAndAdvancesOnSuccess() throws {
        let job = try JobManifest(["id": "ping", "schedule": ["every": 300]])
        let start = utcDate(2026, 11, 20, 10, 0, 0)
        var record = JobRecord()
        record.nextRunAt = JobPlanner.initialNextRun(for: job, record: record, now: start, calendar: utcCalendar)
        #expect(JobPlanner.isDue(spec: job, record: record, now: start, isWake: false))

        let end = start.addingTimeInterval(2.5)
        JobPlanner.recordSuccess(spec: job, record: &record, startedAt: start, finishedAt: end, summary: "ok", calendar: utcCalendar)
        #expect(record.status == .ok)
        #expect(record.consecutiveErrors == 0)
        #expect(record.lastError == nil)
        #expect(record.nextRunAt == end.addingTimeInterval(300))
        #expect(record.recentRuns.count == 1)
        #expect(record.recentRuns.first?.summary == "ok")
    }

    @Test func failureAppliesExponentialBackoffAndRespectsNotifyCooldown() throws {
        let job = try JobManifest(["id": "ping", "schedule": ["every": 3600], "retrySeconds": 300])
        var record = JobRecord()
        let t1 = utcDate(2026, 11, 20, 10, 0, 0)

        let notify1 = JobPlanner.recordFailure(spec: job, record: &record, startedAt: t1, finishedAt: t1.addingTimeInterval(1), error: "exit 1", now: t1.addingTimeInterval(1))
        #expect(record.status == .failed)
        #expect(record.consecutiveErrors == 1)
        #expect(record.nextRunAt == t1.addingTimeInterval(301))
        #expect(notify1 == true)

        let t2 = t1.addingTimeInterval(301)
        let notify2 = JobPlanner.recordFailure(spec: job, record: &record, startedAt: t2, finishedAt: t2.addingTimeInterval(1), error: "exit 1", now: t2.addingTimeInterval(1))
        #expect(record.consecutiveErrors == 2)
        #expect(record.nextRunAt == t2.addingTimeInterval(601))
        #expect(notify2 == false) // still within 6h cooldown
    }

    @Test func pausedOrRunningJobsAreNeverDueAndWakeHonorsRunOnWake() throws {
        let job = try JobManifest(["id": "ping", "schedule": ["every": 300], "runOnWake": false])
        let now = utcDate(2026, 11, 20, 10, 0, 0)
        var record = JobRecord(enabled: true, status: .idle, nextRunAt: now.addingTimeInterval(-60))
        #expect(JobPlanner.isDue(spec: job, record: record, now: now, isWake: true) == false)
        #expect(JobPlanner.isDue(spec: job, record: record, now: now, isWake: false) == true)

        record.enabled = false
        #expect(JobPlanner.isDue(spec: job, record: record, now: now, isWake: false) == false)

        record.enabled = true
        record.status = .running
        #expect(JobPlanner.isDue(spec: job, record: record, now: now, isWake: false) == false)
    }

    @Test func setNextOverridesScheduledTimeForExactResetSync() throws {
        let target = utcDate(2026, 11, 20, 15, 1, 0)
        var record = JobRecord()
        JobPlanner.setNextRun(record: &record, at: target)
        #expect(record.nextRunAt == target)
    }

    @Test func capabilityJobsIsRecognizedByManifest() throws {
        let manifest = try ModuleManifest(["id": "jobs", "permissions": ["jobs", "notify"]])
        #expect(manifest.allows(.jobs))
        #expect(manifest.allows(.notify))
    }

    @Test func backgroundActivityClassifiesModuleFootprint() throws {
        let manifest = try ModuleManifest([
            "id": "ai-usage",
            "refreshSeconds": 60,
            "permissions": ["127.0.0.1", "exec:codex", "exec:agy", "secret:token", "notify"],
        ])
        let jobs = [try JobManifest(["id": "warm", "schedule": ["every": 18_120]])]
        let activity = ModuleBackgroundActivity.analyze(
            manifest: manifest,
            jobs: jobs,
            source: "host.system(); host.fetchJSON('http://127.0.0.1:8317'); host.exec('codex', []);"
        )
        #expect(activity.refreshSeconds == 60)
        #expect(activity.jobCount == 1)
        #expect(activity.hosts == ["127.0.0.1"])
        #expect(activity.tools == ["codex", "agy"])
        #expect(activity.usesBrowser == false)
        #expect(activity.samplers.contains("system"))
    }

    @Test func preludeDescribesJobsAndExposesHostJobsAPI() throws {
        let context = JSContext()!
        context.evaluateScript("var __posted = []; function __call(name, args, ok) { ok('null'); } function __post(name, args) { __posted.push([name, JSON.parse(args)]); }")
        context.evaluateScript(ModulePrelude.source)
        context.evaluateScript("""
            defineModule({
              meta: { id: 'demo', title: 'Demo' },
              jobs: {
                'tick': {
                  title: 'Tick',
                  schedule: { every: 300 },
                  timeoutSeconds: 45,
                  async run(host) { return { summary: 'ran' }; }
                }
              },
              render(host) { return text(String(host.jobs().length)); }
            });
            __setJobs(JSON.stringify({ own: [{ id: 'tick', status: 'ok' }], all: [{ key: 'demo:tick', status: 'ok' }] }));
            """)
        let descJSON = context.evaluateScript("__describe()").toString()!
        let desc = try JSONValue.parse(descJSON)
        #expect(desc["jobs"].array?.count == 1)
        #expect(desc["jobs"].array?.first?["id"].string == "tick")
        #expect(desc["jobs"].array?.first?["timeoutSeconds"].number == 45)
        #expect(context.evaluateScript("host.jobs().length").toInt32() == 1)
        #expect(context.evaluateScript("host.allJobs().length").toInt32() == 1)
    }
}
