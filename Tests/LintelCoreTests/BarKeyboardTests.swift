import CoreGraphics
import Testing
@testable import LintelCore

@Suite struct KeyboardSelection {
    let rows: [[BarSelection.Chip]] = [
        [.init(key: "wifi", midX: 100), .init(key: "battery", midX: 160), .init(key: "clock", midX: 240)],
        [.init(key: "weather", midX: 120), .init(key: "stocks", midX: 230)],
    ]

    @Test func withNothingSelectedAnyStepSelectsTheFirstModule() {
        #expect(BarSelection.step(.next, from: nil, in: rows) == "wifi")
        #expect(BarSelection.step(.rowBelow, from: nil, in: rows) == "wifi")
    }

    @Test func aSelectionNoLongerInTheBarRestartsAtTheFirstModule() {
        #expect(BarSelection.step(.previous, from: "gone", in: rows) == "wifi")
    }

    @Test func nextAndPreviousFollowReadingOrderAcrossRows() {
        #expect(BarSelection.step(.next, from: "battery", in: rows) == "clock")
        #expect(BarSelection.step(.next, from: "clock", in: rows) == "weather")
        #expect(BarSelection.step(.previous, from: "weather", in: rows) == "clock")
    }

    @Test func nextAndPreviousWrapAroundTheEnds() {
        #expect(BarSelection.step(.next, from: "stocks", in: rows) == "wifi")
        #expect(BarSelection.step(.previous, from: "wifi", in: rows) == "stocks")
    }

    @Test func movingBetweenRowsLandsOnTheModuleNearestAcross() {
        #expect(BarSelection.step(.rowBelow, from: "clock", in: rows) == "stocks")
        #expect(BarSelection.step(.rowBelow, from: "wifi", in: rows) == "weather")
        #expect(BarSelection.step(.rowAbove, from: "stocks", in: rows) == "clock")
    }

    @Test func movingPastTheTopOrBottomRowKeepsTheSelection() {
        #expect(BarSelection.step(.rowAbove, from: "battery", in: rows) == "battery")
        #expect(BarSelection.step(.rowBelow, from: "weather", in: rows) == "weather")
    }

    @Test func firstAndLastJumpToTheEndsOfTheBar() {
        #expect(BarSelection.step(.first, from: "clock", in: rows) == "wifi")
        #expect(BarSelection.step(.last, from: "wifi", in: rows) == "stocks")
    }

    @Test func rowsFollowWhereModulesAreDrawnTopToBottomAndLeftToRight() {
        let frames: [(String, CGRect)] = [
            ("assistant", CGRect(x: 360, y: 100, width: 40, height: 30)),
            ("clock", CGRect(x: 500, y: 30, width: 200, height: 30)),
            ("weather", CGRect(x: 160, y: 31, width: 40, height: 29)),
            ("system", CGRect(x: 130, y: 66, width: 220, height: 31)),
        ]
        #expect(BarSelection.rows(from: frames).map { $0.map(\.key) } == [["weather", "clock"], ["system"], ["assistant"]])
    }

    @Test func anEmptyBarHasNothingToSelect() {
        #expect(BarSelection.step(.next, from: "wifi", in: []) == nil)
    }
}

@Suite struct KeyboardCommands {
    @Test func arrowsMoveTheSelection() {
        #expect(BarKey.command(for: .left, modifiers: []) == .select(.previous))
        #expect(BarKey.command(for: .right, modifiers: []) == .select(.next))
        #expect(BarKey.command(for: .up, modifiers: []) == .select(.rowAbove))
        #expect(BarKey.command(for: .down, modifiers: []) == .select(.rowBelow))
        #expect(BarKey.command(for: .tab, modifiers: []) == .select(.next))
        #expect(BarKey.command(for: .tab, modifiers: [.shift]) == .select(.previous))
        #expect(BarKey.command(for: .home, modifiers: []) == .select(.first))
        #expect(BarKey.command(for: .end, modifiers: []) == .select(.last))
    }

    @Test func commandArrowsMoveTheSelectedModuleAsTheContextMenuDoes() {
        #expect(BarKey.command(for: .left, modifiers: [.command]) == .edit("left"))
        #expect(BarKey.command(for: .right, modifiers: [.command]) == .edit("right"))
        #expect(BarKey.command(for: .up, modifiers: [.command]) == .edit("up"))
        #expect(BarKey.command(for: .down, modifiers: [.command]) == .edit("down"))
    }

    @Test func returnAndSpaceOpenTheSelectedModule() {
        #expect(BarKey.command(for: .return, modifiers: []) == .open)
        #expect(BarKey.command(for: .space, modifiers: []) == .open)
    }

    @Test func lettersPinHideAndAskTheAssistant() {
        #expect(BarKey.command(for: .character("p"), modifiers: []) == .edit("pin"))
        #expect(BarKey.command(for: .delete, modifiers: []) == .edit("hide"))
        #expect(BarKey.command(for: .character("a"), modifiers: []) == .edit("change"))
        #expect(BarKey.command(for: .character("/"), modifiers: []) == .assistant)
    }

    @Test func commandCommaOpensSettingsAndEscapeClosesTheBar() {
        #expect(BarKey.command(for: .character(","), modifiers: [.command]) == .settings)
        #expect(BarKey.command(for: .escape, modifiers: []) == .close)
    }

    @Test func numbersJumpToTheModuleAtThatPosition() {
        #expect(BarKey.command(for: .character("1"), modifiers: []) == .openAt(0))
        #expect(BarKey.command(for: .character("9"), modifiers: []) == .openAt(8))
    }

    @Test func otherKeysAndModifiersAreLeftAlone() {
        #expect(BarKey.command(for: .character("q"), modifiers: [.command]) == nil)
        #expect(BarKey.command(for: .character("z"), modifiers: []) == nil)
        #expect(BarKey.command(for: .left, modifiers: [.option]) == nil)
    }
}
