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
}
