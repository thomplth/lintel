import Testing
@testable import LintelCore

@Suite struct BarVisibilityState {
    @Test func autoHideInFullScreenDefaultsToEnabled() {
        let visibility = BarVisibility()
        #expect(visibility.autoHideInFullScreen)
        #expect(!visibility.isHidden)
    }

    @Test func enteringFullScreenHidesTheBarAndExitingRestoresIt() {
        var visibility = BarVisibility()
        visibility.setFullScreen(true)
        #expect(visibility.isHidden)
        #expect(visibility.isAutoHiddenInFullScreen)
        #expect(!visibility.isHiddenByUser)

        visibility.setFullScreen(false)
        #expect(!visibility.isHidden)
        #expect(!visibility.isAutoHiddenInFullScreen)
    }

    @Test func keyboardToggleReappearsTheBarInFullScreenAndCanHideItAgainWithoutHidingOnDesktop() {
        var visibility = BarVisibility()
        visibility.setFullScreen(true)
        #expect(visibility.isHidden)

        // Pressing the hide/show shortcut brings the bar back in full screen.
        visibility.toggleHide()
        #expect(!visibility.isHidden)
        #expect(visibility.isOverriddenInFullScreen)

        // Pressing it again hides the bar in full screen without marking it hidden for the desktop.
        visibility.toggleHide()
        #expect(visibility.isHidden)
        #expect(!visibility.isHiddenByUser)

        // Leaving full screen restores the bar on the desktop.
        visibility.setFullScreen(false)
        #expect(!visibility.isHidden)
    }

    @Test func explicitShowReappearsTheBarInFullScreenUntilFullScreenEnds() {
        var visibility = BarVisibility()
        visibility.setFullScreen(true)
        #expect(visibility.isHidden)

        visibility.show()
        #expect(!visibility.isHidden)

        // Leaving and re-entering full screen auto-hides the bar again.
        visibility.setFullScreen(false)
        #expect(!visibility.isHidden)
        visibility.setFullScreen(true)
        #expect(visibility.isHidden)
    }

    @Test func disablingAutoHideInSettingsRestoresAnAutoHiddenBarImmediately() {
        var visibility = BarVisibility()
        visibility.setFullScreen(true)
        #expect(visibility.isHidden)

        visibility.setAutoHideInFullScreen(false)
        #expect(!visibility.isHidden)

        // Re-enabling while still in full screen hides it again.
        visibility.setAutoHideInFullScreen(true)
        #expect(visibility.isHidden)
    }

    @Test func disablingAutoHideLeavesManualHideWorkingInFullScreen() {
        var visibility = BarVisibility(autoHideInFullScreen: false)
        visibility.setFullScreen(true)
        #expect(!visibility.isHidden)

        visibility.toggleHide()
        #expect(visibility.isHidden)
        #expect(visibility.isHiddenByUser)

        visibility.toggleHide()
        #expect(!visibility.isHidden)
    }

    @Test func manuallyHiddenBarStaysHiddenAfterEnteringAndLeavingFullScreen() {
        var visibility = BarVisibility()
        visibility.toggleHide()
        #expect(visibility.isHidden)
        #expect(visibility.isHiddenByUser)

        visibility.setFullScreen(true)
        #expect(visibility.isHidden)

        visibility.setFullScreen(false)
        #expect(visibility.isHidden)
        #expect(visibility.isHiddenByUser)
    }
}
