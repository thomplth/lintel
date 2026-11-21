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
    return context.evaluateScript("__module.chip(host).value").toString()
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

private func findSection(_ sourceExpr: String, _ title: String) -> String {
    """
    (function find(node) {
      if (!node) return null;
      if (Array.isArray(node)) { for (const n of node) { const r = find(n); if (r) return r; } return null; }
      if (node.title === '\(title)') return node;
      return find(node.children);
    })(\(sourceExpr))
    """
}

private func panelSection(_ context: JSContext, _ title: String) -> String {
    findSection("__module.configure(host)", title)
}

private func worldRows(_ context: JSContext) -> [String] {
    let script = """
    (\(findSection("__module.widget(host)", "World")).children.find((view) => view.type === 'list') || { children: [] }).children
      .map((row) => [row.title, row.value, row.subtitle].join(' | '))
    """
    return context.evaluateScript(script).toArray() as? [String] ?? []
}

private func worldRowAccessories(_ context: JSContext) -> [String] {
    let script = """
    (\(findSection("__module.widget(host)", "World")).children.find((view) => view.type === 'list') || { children: [] }).children
      .map((row) => [row.accessoryIcon, row.accessoryAction, row.accessoryLabel, row.payload, row.action || 'no action'].join(' | '))
    """
    return context.evaluateScript(script).toArray() as? [String] ?? []
}

private func worldControls(_ context: JSContext) -> [String] {
    let script = """
    \(findSection("__module.widget(host)", "World")).children.filter((view) => view.type !== 'list')
      .map((view) => [view.type, view.label || view.value || view.placeholder, view.action, view.suggest].filter(Boolean).join(' | '))
    """
    return context.evaluateScript(script).toArray() as? [String] ?? []
}

private func storedZones(_ context: JSContext) -> [String] {
    context.evaluateScript("host.storage.get('zones').map((entry) => typeof entry === 'string' ? entry : entry.name + ' = ' + entry.zone)").toArray() as? [String] ?? []
}

private func suggestions(_ context: JSContext, _ query: String) -> [String] {
    let script = "__module.actions.suggestZones(host, '\(query)').map((s) => [s.title, s.subtitle, s.value].join(' | '))"
    return context.evaluateScript(script).toArray() as? [String] ?? []
}

private func perform(_ context: JSContext, _ action: String, _ payload: String) {
    context.evaluateScript("__module.actions.\(action)(host, \(payload))")
}

private func sectionTitles(_ context: JSContext) -> [String] {
    context.evaluateScript("__module.configure(host).map((view) => view.title || view.type)").toArray() as? [String] ?? []
}

private func controls(_ context: JSContext, in title: String) -> [String] {
    let script = """
    \(panelSection(context, title)).children.map((view) => view.type === 'segmented'
      ? 'segmented ' + view.options.join(' / ') + ' = ' + view.selected
      : view.type + ' ' + view.label + (view.on ? ' on' : ' off'))
    """
    return context.evaluateScript(script).toArray() as? [String] ?? []
}

private func calendarCells(_ context: JSContext) -> [String] {
    let script = """
    (\(findSection("__module.widget(host)", "March 2026"))).children[0].children.map((cell) => cell.type + ':' + cell.value + (cell.tone ? ':' + cell.tone : ''))
    """
    return context.evaluateScript(script).toArray() as? [String] ?? []
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
            "Tokyo | 23:05 | Today · +9 h",
            "Auckland | 03:05 | Tomorrow · +13 h",
            "Los Angeles | 06:05 | Today · −8 h",
            "Kolkata | 19:35 | Today · +5:30",
            "London | 14:05 | Same time",
        ])
    }

    @Test func worldClockOffsetsAreRelativeToTheLocalZone() {
        let context = clockContext(storage: "{ zones: ['Europe/London'] }", localOffsetMinutes: 11 * 60)
        #expect(worldRows(context) == ["London | 14:05 | Yesterday · −11 h"])
    }

    @Test func worldClocksFollowTheTwelveHourSetting() {
        let context = clockContext(storage: "{ zones: ['Asia/Tokyo'], hours: '12h' }")
        #expect(worldRows(context).first?.hasPrefix("Tokyo | 11:05 PM") == true)
    }

    @Test func eachWorldClockEndsInARemoveButtonAndIsNotItselfClickable() {
        let context = clockContext(storage: "{ zones: ['Asia/Tokyo'] }")
        #expect(worldRowAccessories(context) == ["minus.circle | removeZone | Remove Tokyo | Tokyo | no action"])
        perform(context, "removeZone", "'Tokyo'")
        #expect(worldRows(context).isEmpty)
    }

    @Test func theAddFieldSuggestsCitiesAsYouType() {
        let context = clockContext(storage: "{ zones: [] }")
        #expect(worldControls(context).contains("field | Add a city | addZone | suggestZones"))
        #expect(suggestions(context, "pari") == ["Paris | Europe · 15:05 | Europe/Paris"])
        #expect(suggestions(context, "york").first == "New York | America · 09:05 | America/New_York")
        #expect(suggestions(context, "").isEmpty)
    }

    @Test func citiesThatShareAnotherCitysZoneAreSuggestedByTheirOwnName() {
        let context = clockContext(storage: "{ zones: [] }")
        #expect(suggestions(context, "san fr").first == "San Francisco | America · 06:05 | San Francisco")
        perform(context, "addZone", "'San Francisco'")
        #expect(storedZones(context) == ["San Francisco = America/Los_Angeles"])
        #expect(worldRows(context).first?.hasPrefix("San Francisco | 06:05") == true)
    }

    @Test func citiesAlreadyShownAreNotSuggestedAgain() {
        let context = clockContext(storage: "{ zones: ['Europe/Paris'] }")
        #expect(suggestions(context, "paris").isEmpty)
    }

    @Test func suggestionsStartWithCitiesWhoseNameBeginsWithWhatWasTyped() {
        let context = clockContext(storage: "{ zones: [] }")
        let titles = suggestions(context, "san").map { $0.components(separatedBy: " | ")[0] }
        #expect(titles.count == 6)
        #expect(titles.allSatisfy { $0.lowercased().hasPrefix("san") })
    }

    @Test func aZoneCanBeAddedByCityNameOrIdentifier() {
        let context = clockContext(storage: "{ zones: [] }")
        perform(context, "addZone", "'new york'")
        perform(context, "addZone", "'Paris'")
        perform(context, "addZone", "'Asia/Hong_Kong'")
        #expect(storedZones(context) == ["New York = America/New_York", "Paris = Europe/Paris", "Hong Kong = Asia/Hong_Kong"])
    }

    @Test func anUnknownCityIsReportedAndAddsNothing() {
        let context = clockContext(storage: "{ zones: ['Asia/Tokyo'] }")
        perform(context, "addZone", "'Atlantis'")
        #expect(storedZones(context) == ["Asia/Tokyo"])
        #expect(worldControls(context).contains("note | No city or time zone matches \u{201C}Atlantis\u{201D}."))
        perform(context, "addZone", "'Paris'")
        #expect(!worldControls(context).contains { $0.hasPrefix("note | No city") })
    }

    @Test func withNoWorldClocksThePanelInvitesAddingOne() {
        let context = clockContext(storage: "{ zones: [] }")
        perform(context, "addZone", "'Atlantis'")
        perform(context, "addZone", "'Paris'")
        perform(context, "removeZone", "'Paris'")
        #expect(worldControls(context).first == "note | Add a city to compare its time with yours.")
    }

    @Test func theCalendarFillsWholeWeeksAndMarksToday() {
        let cells = calendarCells(clockContext())
        #expect(cells.prefix(7) == ["text:M:tertiary", "text:T:tertiary", "text:W:tertiary", "text:T:tertiary", "text:F:tertiary", "text:S:tertiary", "text:S:tertiary"])
        #expect(cells[7...12] == ["text:23:tertiary", "text:24:tertiary", "text:25:tertiary", "text:26:tertiary", "text:27:tertiary", "text:28:tertiary"])
        #expect(cells[13...14] == ["text:1:secondary", "text:2"])
        #expect(cells.contains("badge:4:accent"))
        #expect(cells.contains("text:7:secondary"))
        #expect(cells.count % 7 == 0)
        #expect(cells.last == "text:5:tertiary")
    }

    @Test func theCalendarHeaderNamesTheMonthAndWeek() {
        let context = clockContext()
        let cal = findSection("__module.widget(host)", "March 2026")
        #expect(context.evaluateScript("(\(cal)).title").toString() == "March 2026")
        #expect(context.evaluateScript("(\(cal)).trailing").toString() == "Week 10")
    }

    @Test func barSettingsAreGroupedIntoTimeAndDate() {
        let context = clockContext()
        #expect(sectionTitles(context).prefix(2) == ["Time in the bar", "Date in the bar"])
        #expect(controls(context, in: "Time in the bar") == ["toggle Show time on", "toggle Seconds on", "segmented 24-hour / 12-hour = 24-hour"])
        #expect(controls(context, in: "Date in the bar") == [
            "toggle Show date on", "toggle Weekday on", "toggle Year off", "segmented 4 Mar / Mar 4 / 04/03 / 03/04 / 03-04 = 4 Mar",
        ])
    }

    @Test func settingsForAHiddenPartAreHidden() {
        let context = clockContext(storage: "{ showTime: false, showDate: false }")
        #expect(controls(context, in: "Time in the bar") == ["toggle Show time off"])
        #expect(controls(context, in: "Date in the bar") == ["toggle Show date off", "toggle Weekday on"])
    }

    @Test func dateOrderExamplesFallBackToAnUnambiguousDayWhenDayAndMonthMatch() {
        let context = clockContext()
        context.evaluateScript("__fixed = Date.UTC(2026, 2, 3, 14, 5, 9)")
        #expect(controls(context, in: "Date in the bar").last == "segmented 31 Dec / Dec 31 / 31/12 / 12/31 / 12-31 = 31 Dec")
    }

    @Test func choosingADateOrderByItsExampleStoresIt() {
        let context = clockContext()
        perform(context, "setDateOrder", "'03-04'")
        #expect(context.evaluateScript("host.storage.get('dateOrder')").toString() == "iso")
    }
}
