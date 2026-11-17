import Foundation
import JavaScriptCore
import Testing
@testable import LintelCore

private let clockSource = try! String(
    contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/Lintel/Resources/Modules/clock.js"),
    encoding: .utf8
)

private func barText(storage: String, at moment: String = "new Date(2026, 2, 4, 14, 5, 9)") -> String? {
    let context = JSContext()!
    context.evaluateScript("function __call() {} function __post() {}")
    context.evaluateScript(ModulePrelude.source)
    context.evaluateScript(clockSource)
    context.evaluateScript("var __fixed = \(moment); Date = class extends Date { constructor(...a) { a.length ? super(...a) : super(__fixed) } };")
    context.evaluateScript("var __saved = \(storage); for (var k in __saved) host.storage.set(k, __saved[k]);")
    return context.evaluateScript("__module.render(host).value").toString()
}

private func clockContext(storage: String = "{}", localOffsetMinutes: Int = 0) -> JSContext {
    let context = JSContext()!
    context.evaluateScript("function __call() {} function __post() {}")
    context.evaluateScript(ModulePrelude.source)
    context.evaluateScript(clockSource)
    context.evaluateScript("""
    var __fixed = Date.UTC(2026, 2, 4, 14, 5, 9);
    Date = class extends Date { constructor(...a) { a.length ? super(...a) : super(__fixed) } getTimezoneOffset() { return \(-localOffsetMinutes) } };
    """)
    context.evaluateScript("var __saved = \(storage); for (var k in __saved) host.storage.set(k, __saved[k]);")
    return context
}

private func worldRows(_ context: JSContext) -> [String] {
    let script = """
    __module.panel(host).find((view) => view.title === 'World').children[0].children
      .map((row) => [row.title, row.value, row.subtitle].join(' | '))
    """
    return context.evaluateScript(script).toArray() as? [String] ?? []
}

private func worldControls(_ context: JSContext) -> [String] {
    let script = """
    __module.panel(host).find((view) => view.title === 'World').children.slice(1)
      .map((view) => [view.type, view.label || view.value || view.placeholder, view.action, view.payload].filter(Boolean).join(' | '))
    """
    return context.evaluateScript(script).toArray() as? [String] ?? []
}

private func storedZones(_ context: JSContext) -> [String] {
    context.evaluateScript("host.storage.get('zones')").toArray() as? [String] ?? []
}

private func perform(_ context: JSContext, _ action: String, _ payload: String) {
    context.evaluateScript("__module.actions.\(action)(host, \(payload))")
}

@Suite struct ClockModule {
    @Test func theBarShowsWeekdayDateAndTimeByDefault() {
        #expect(barText(storage: "{}") == "Wed 4 Mar  14:05:09")
    }

    @Test func theBarFollowsTheChosenFormats() {
        #expect(barText(storage: "{ dateOrder: 'mdy', year: true, hours: '12h', seconds: false }") == "Wed 03/04/2026  2:05 PM")
    }

    @Test func eachPartCanBeHidden() {
        #expect(barText(storage: "{ weekday: false }") == "4 Mar  14:05:09")
        #expect(barText(storage: "{ showDate: false }") == "Wed  14:05:09")
        #expect(barText(storage: "{ showDate: false, weekday: false }") == "14:05:09")
        #expect(barText(storage: "{ showTime: false }") == "Wed 4 Mar")
        #expect(barText(storage: "{ showTime: false, showDate: false }") == "Wed")
        #expect(barText(storage: "{ seconds: false }") == "Wed 4 Mar  14:05")
    }

    @Test func hidingEveryPartStillShowsTheTime() {
        #expect(barText(storage: "{ showTime: false, showDate: false, weekday: false, seconds: false }") == "14:05")
    }

    @Test func eachWorldClockShowsItsDayAndOffsetFromLocalTime() {
        let context = clockContext(storage: "{ zones: ['Asia/Tokyo', 'Pacific/Auckland', 'America/Los_Angeles', 'Asia/Kolkata', 'Europe/London'] }")
        #expect(worldRows(context) == [
            "Tokyo | 23:05 | Today, 9 h ahead",
            "Auckland | 03:05 | Tomorrow, 13 h ahead",
            "Los Angeles | 06:05 | Today, 8 h behind",
            "Kolkata | 19:35 | Today, 5 h 30 min ahead",
            "London | 14:05 | Same time",
        ])
    }

    @Test func worldClockOffsetsAreRelativeToTheLocalZone() {
        let context = clockContext(storage: "{ zones: ['Europe/London'] }", localOffsetMinutes: 11 * 60)
        #expect(worldRows(context) == ["London | 14:05 | Yesterday, 11 h behind"])
    }

    @Test func worldClocksFollowTheTwelveHourSetting() {
        let context = clockContext(storage: "{ zones: ['Asia/Tokyo'], hours: '12h' }")
        #expect(worldRows(context).first?.hasPrefix("Tokyo | 11:05 PM") == true)
    }

    @Test func aZoneCanBeAddedByCityName() {
        let context = clockContext(storage: "{ zones: [] }")
        perform(context, "addZone", "'new york'")
        perform(context, "addZone", "'Paris'")
        perform(context, "addZone", "'Asia/Hong_Kong'")
        #expect(storedZones(context) == ["America/New_York", "Europe/Paris", "Asia/Hong_Kong"])
    }

    @Test func anUnknownCityIsReportedAndAddsNothing() {
        let context = clockContext(storage: "{ zones: ['Asia/Tokyo'] }")
        perform(context, "addZone", "'Atlantis'")
        #expect(storedZones(context) == ["Asia/Tokyo"])
        #expect(worldControls(context).contains("note | No time zone matches \u{201C}Atlantis\u{201D}."))
        perform(context, "addZone", "'Paris'")
        #expect(!worldControls(context).contains { $0.hasPrefix("note | No time zone") })
    }

    @Test func clickingAWorldClockOffersRemovalInsteadOfRemovingIt() {
        let context = clockContext(storage: "{ zones: ['Asia/Tokyo', 'Asia/Hong_Kong'] }")
        #expect(!worldControls(context).contains { $0.hasPrefix("button") })
        perform(context, "selectZone", "'Asia/Tokyo'")
        #expect(storedZones(context) == ["Asia/Tokyo", "Asia/Hong_Kong"])
        #expect(worldControls(context).first == "button | Remove Tokyo | removeZone | Asia/Tokyo")
        perform(context, "removeZone", "'Asia/Tokyo'")
        #expect(storedZones(context) == ["Asia/Hong_Kong"])
        #expect(!worldControls(context).contains { $0.hasPrefix("button") })
    }

    @Test func clickingTheChosenWorldClockAgainDismissesRemoval() {
        let context = clockContext(storage: "{ zones: ['Asia/Tokyo'] }")
        perform(context, "selectZone", "'Asia/Tokyo'")
        perform(context, "selectZone", "'Asia/Tokyo'")
        #expect(!worldControls(context).contains { $0.hasPrefix("button") })
    }
}
