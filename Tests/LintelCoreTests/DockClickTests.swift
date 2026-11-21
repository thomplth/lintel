import Testing
@testable import LintelCore

@Suite struct DockClicking {
    @Test func aClickWhileTheBarIsClosedOpensTheFullBar() {
        #expect(DockClick.response(isBarOpen: false) == .openBar)
    }

    @Test func aClickWhileTheFullBarIsShownOpensTheMainWindow() {
        #expect(DockClick.response(isBarOpen: true) == .openWindow)
    }

    @Test func aClickWhileTheMainWindowIsOpenBringsItToFront() {
        #expect(DockClick.response(isBarOpen: false, hasMainWindow: true) == .focusWindow)
        #expect(DockClick.response(isBarOpen: true, hasMainWindow: true) == .focusWindow)
    }
}
