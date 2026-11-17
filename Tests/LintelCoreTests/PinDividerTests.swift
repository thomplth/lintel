import Testing
@testable import LintelCore

@Suite struct PinDividing {
    let pinned: Set<String> = ["date", "clock"]
    var divider0: String { PinDividers.key(0) }
    var divider1: String { PinDividers.key(1) }

    func split(_ rows: [[String]], pinsAtEnd: Bool = true, keepsFirstRow: Bool = false) -> PinDividers {
        PinDividers(rows: rows, isPinned: pinned.contains, pinsAtEnd: pinsAtEnd, keepsFirstRow: keepsFirstRow)
    }

    @Test func eachRowGathersItsPinnedModulesOnTheAnchoredSideOfItsDivider() {
        let dividers = split([["date", "cpu", "clock", "disk"], ["net"]])
        #expect(dividers.rows == [["cpu", "disk", divider0, "date", "clock"], ["net", divider1]])
    }

    @Test func aLeftAnchoredBarKeepsItsPinnedModulesFirst() {
        let dividers = split([["cpu", "date"]], pinsAtEnd: false)
        #expect(dividers.rows == [["date", divider0, "cpu"]])
    }

    @Test func theMenuBarRowHasNoDividerBecauseItShowsEverythingWhileIdle() {
        let dividers = split([["clock"], ["cpu", "date"]], keepsFirstRow: true)
        #expect(dividers.rows == [["clock"], ["cpu", divider1, "date"]])
    }

    @Test func aModuleDroppedPastTheDividerBecomesPinned() {
        let moved = split([["cpu", "date"]]).moving("cpu", to: .row(0, index: 2))
        #expect(moved.layoutRows == [["date", "cpu"]])
        #expect(moved.pins == ["cpu": true, "date": true])
    }

    @Test func aModuleDroppedBeforeTheDividerBecomesUnpinned() {
        let moved = split([["cpu"], ["date"]]).moving("date", to: .row(0, index: 0))
        #expect(moved.layoutRows == [["date", "cpu"]])
        #expect(moved.pins["date"] == false)
    }

    @Test func movingTheDividerPinsOrUnpinsEveryModuleItPasses() {
        let moved = split([["cpu", "disk", "date"]]).moving(divider0, to: .row(0, index: 0))
        #expect(moved.pins == ["cpu": true, "disk": true, "date": true])
        let back = split([["cpu", "disk", "date"]]).moving(divider0, to: .row(0, index: 3))
        #expect(back.pins == ["cpu": false, "disk": false, "date": false])
    }

    @Test func theDividerStaysInItsOwnRow() {
        let dividers = split([["cpu", "date"], ["net"]])
        #expect(dividers.accepts(.row(0, index: 0), moving: divider0))
        #expect(!dividers.accepts(.row(1, index: 0), moving: divider0))
        #expect(!dividers.accepts(.newRow(0), moving: divider0))
        #expect(!dividers.accepts(.remove, moving: divider0))
        #expect(dividers.accepts(.newRow(2), moving: "cpu"))
    }

    @Test func aRowLeftWithOnlyItsDividerCloses() {
        let moved = split([["cpu"], ["net", "date"]]).moving("cpu", to: .row(0, index: 0))
        #expect(moved.layoutRows == [["cpu", "net", "date"]])
    }

    @Test func aModuleInARowOfItsOwnKeepsItsPin() {
        let moved = split([["cpu", "date"]]).moving("date", to: .newRow(1))
        #expect(moved.layoutRows == [["cpu"], ["date"]])
        #expect(moved.pins["date"] == nil)
    }

    @Test func aRemovedModuleLeavesTheRows() {
        let moved = split([["cpu", "date"]]).moving("cpu", to: .remove)
        #expect(moved.layoutRows == [["date"]])
    }

    @Test func anEmptiedMenuBarRowKeepsItsPlace() {
        let moved = split([["clock"], ["cpu"]], keepsFirstRow: true).moving("clock", to: .row(1, index: 0))
        #expect(moved.layoutRows == [[], ["clock", "cpu"]])
    }
}
