import CoreGraphics
import Foundation
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

    @Test func reopeningResumesAtTheRememberedModule() {
        #expect(BarSelection.resume("stocks", in: rows) == "stocks")
    }

    @Test func aRememberedModuleNoLongerInTheBarResumesAtTheFirst() {
        #expect(BarSelection.resume("gone", in: rows) == "wifi")
        #expect(BarSelection.resume(nil, in: rows) == "wifi")
    }

    @Test func steppingPastTheTopOrBottomRowBumpsThatWay() {
        #expect(BarSelection.bump(.rowAbove, from: "battery", in: rows) == .up)
        #expect(BarSelection.bump(.rowBelow, from: "stocks", in: rows) == .down)
    }

    @Test func stepsThatLandSomewhereDoNotBump() {
        #expect(BarSelection.bump(.rowBelow, from: "battery", in: rows) == nil)
        #expect(BarSelection.bump(.next, from: "stocks", in: rows) == nil)
        #expect(BarSelection.bump(.rowAbove, from: nil, in: rows) == nil)
    }

    @Test func anEmptyBarHasNothingToSelect() {
        #expect(BarSelection.step(.next, from: "wifi", in: []) == nil)
    }
}

@Suite struct KeyboardCommands {
    func command(_ key: BarKey, _ modifiers: BarKey.Modifiers = []) -> BarKey.Command? {
        BarKeymap.standard.command(for: key, modifiers: modifiers)
    }

    @Test func arrowsMoveTheSelection() {
        #expect(command(.left) == .select(.previous))
        #expect(command(.right) == .select(.next))
        #expect(command(.up) == .select(.rowAbove))
        #expect(command(.down) == .select(.rowBelow))
        #expect(command(.tab) == .select(.next))
        #expect(command(.tab, [.shift]) == .select(.previous))
        #expect(command(.home) == .select(.first))
        #expect(command(.end) == .select(.last))
    }

    @Test func commandArrowsMoveTheSelectedModuleAsTheContextMenuDoes() {
        #expect(command(.left, [.command]) == .edit("left"))
        #expect(command(.right, [.command]) == .edit("right"))
        #expect(command(.up, [.command]) == .edit("up"))
        #expect(command(.down, [.command]) == .edit("down"))
    }

    @Test func returnAndSpaceOpenTheSelectedModule() {
        #expect(command(.return) == .open)
        #expect(command(.space) == .open)
    }

    @Test func lettersPinHideAndAskTheAssistant() {
        #expect(command(.character("p")) == .edit("pin"))
        #expect(command(.delete) == .edit("hide"))
        #expect(command(.character("a")) == .edit("change"))
        #expect(command(.character("/")) == .assistant)
    }

    @Test func commandCommaOpensSettingsAndEscapeClosesTheBar() {
        #expect(command(.character(","), [.command]) == .settings)
        #expect(command(.escape) == .close)
    }

    @Test func numbersJumpToTheModuleAtThatPosition() {
        #expect(command(.character("1")) == .openAt(0))
        #expect(command(.character("9")) == .openAt(8))
    }

    @Test func otherKeysAndModifiersAreLeftAlone() {
        #expect(command(.character("q"), [.command]) == nil)
        #expect(command(.character("z")) == nil)
        #expect(command(.left, [.option]) == nil)
    }
}

@Suite struct ChosenKeys {
    let h = BarKeyBinding(.character("h"))
    let p = BarKeyBinding(.character("p"))

    @Test func aKeyGivenToAnActionTriggersItInPlaceOfItsOldKeys() {
        var keys = BarKeymap.standard
        keys.assign(h, to: .hide)
        #expect(keys.command(for: .character("h"), modifiers: []) == .edit("hide"))
        #expect(keys.command(for: .delete, modifiers: []) == nil)
        #expect(keys.bindings(for: .hide) == [h])
    }

    @Test func givingAKeyUsedByAnotherActionTakesItFromThatAction() {
        var keys = BarKeymap.standard
        keys.assign(p, to: .hide)
        #expect(keys.command(for: .character("p"), modifiers: []) == .edit("hide"))
        #expect(keys.bindings(for: .pin).isEmpty)
    }

    @Test func takingOneOfSeveralKeysLeavesTheOthers() {
        var keys = BarKeymap.standard
        keys.assign(BarKeyBinding(.space), to: .pin)
        #expect(keys.bindings(for: .open) == [BarKeyBinding(.return)])
    }

    @Test func resettingRestoresTheStandardKeys() {
        var keys = BarKeymap.standard
        keys.assign(p, to: .hide)
        keys.reset(.pin)
        #expect(keys.bindings(for: .pin) == [p])
        #expect(keys.bindings(for: .hide).isEmpty)
        #expect(!keys.isStandard)
        keys.resetAll()
        #expect(keys == .standard)
        #expect(keys.isStandard)
    }

    @Test func escapeAndTheNumberKeysStayReserved() {
        var keys = BarKeymap.standard
        #expect(BarKeymap.isReserved(BarKeyBinding(.escape)))
        #expect(BarKeymap.isReserved(BarKeyBinding(.character("3"))))
        #expect(!BarKeymap.isReserved(BarKeyBinding(.character("3"), [.command])))
        keys.assign(BarKeyBinding(.escape), to: .pin)
        #expect(keys.bindings(for: .pin) == [p])
        #expect(keys.command(for: .escape, modifiers: []) == .close)
    }

    @Test func onlyChangedActionsAreStoredAndTheyReadBackTheSame() throws {
        var keys = BarKeymap.standard
        keys.assign(BarKeyBinding(.left, [.option, .shift]), to: .moveLeft)
        let data = try JSONEncoder().encode(keys)
        let stored = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(stored?.keys.sorted() == ["moveLeft"])
        #expect(try JSONDecoder().decode(BarKeymap.self, from: data) == keys)
    }

    @Test func storedKeysForUnknownActionsAreIgnored() throws {
        let data = Data(#"{"teleport":[{"key":"t","modifiers":0}],"pin":[{"key":"k","modifiers":0}]}"#.utf8)
        let keys = try JSONDecoder().decode(BarKeymap.self, from: data)
        #expect(keys.bindings(for: .pin) == [BarKeyBinding(.character("k"))])
    }

    @Test func keysReadAsTheyAreTyped() {
        #expect(BarKeyBinding(.left, [.command]).label == "⌘←")
        #expect(BarKeyBinding(.tab, [.shift]).label == "⇧Tab")
        #expect(BarKeyBinding(.character("p"), [.control, .option]).label == "⌃⌥P")
        #expect(BarKeyBinding(.space).label == "Space")
        #expect(BarKeyBinding(.delete).label == "Delete")
    }
}
