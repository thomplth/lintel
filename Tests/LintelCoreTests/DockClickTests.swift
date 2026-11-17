import Testing
@testable import LintelCore

@Suite struct DockClicking {
    @Test func aClickWhileTheBarIsClosedOpensTheFullBar() {
        #expect(DockClick.response(isBarOpen: false) == .openBar)
    }

    @Test func aClickWhileTheFullBarIsShownOpensSettings() {
        #expect(DockClick.response(isBarOpen: true) == .openSettings)
    }
}
