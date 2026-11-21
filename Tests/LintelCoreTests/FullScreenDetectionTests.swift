import CoreGraphics
import Testing
@testable import LintelCore

@Suite struct FullScreenDetecting {
    let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let notchScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let desktopIconLayer = -2_147_483_603
    let ownPID: Int32 = 999

    @Test func accessibilityFullScreenFlagIsHonoredImmediately() {
        let result = FullScreenDetection.isFullScreen(
            windows: [],
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostAXFullScreen: true
        )
        #expect(result)
    }

    @Test func maximizedWindowOnDesktopWithFinderDesktopIconWindowIsNotFullScreen() {
        let windows = [
            ScreenWindow(owner: "Safari", ownerPID: 100, layer: 0, bounds: screen),
            ScreenWindow(owner: "Finder", ownerPID: 200, layer: desktopIconLayer, bounds: screen),
        ]
        let result = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostAXFullScreen: nil
        )
        #expect(!result)
    }

    @Test func fullScreenWindowWithoutDesktopIconWindowIsDetectedAsFullScreen() {
        let windows = [
            ScreenWindow(owner: "Lintel", ownerPID: ownPID, layer: 25, bounds: CGRect(x: 972, y: 0, width: 1588, height: 576)),
            ScreenWindow(owner: "Safari", ownerPID: 100, layer: 0, bounds: screen),
        ]
        let result = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostAXFullScreen: nil
        )
        #expect(result)
    }

    @Test func nativeFullScreenBelowNotchStripIsDetectedAsFullScreen() {
        let belowNotch = CGRect(x: 0, y: 32, width: 1512, height: 950)
        let windows = [
            ScreenWindow(owner: "Xcode", ownerPID: 100, layer: 0, bounds: belowNotch),
        ]
        let result = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: notchScreen,
            notchStripHeight: 32,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostAXFullScreen: nil
        )
        #expect(result)
    }

    @Test func splitViewFullScreenWindowsWithoutDesktopIconWindowAreDetected() {
        let left = CGRect(x: 0, y: 0, width: 1276, height: 1440)
        let right = CGRect(x: 1284, y: 0, width: 1276, height: 1440)
        let windows = [
            ScreenWindow(owner: "Safari", ownerPID: 100, layer: 0, bounds: left),
            ScreenWindow(owner: "Notes", ownerPID: 101, layer: 0, bounds: right),
        ]
        let result = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostAXFullScreen: nil
        )
        #expect(result)
    }

    @Test func presentationWindowAboveNormalLayerCoveringScreenIsDetectedEvenWithDesktopWindow() {
        let windows = [
            ScreenWindow(owner: "Keynote", ownerPID: 300, layer: 1000, bounds: screen),
            ScreenWindow(owner: "Finder", ownerPID: 200, layer: desktopIconLayer, bounds: screen),
        ]
        let result = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostRegularPID: 300,
            frontmostAXFullScreen: false
        )
        #expect(result)
    }

    @Test func shieldingPresentationWindowOfFrontmostRegularAppIsDetected() {
        let windows = [
            ScreenWindow(owner: "Game", ownerPID: 500, layer: 2_147_483_628, bounds: screen),
            ScreenWindow(owner: "Finder", ownerPID: 200, layer: desktopIconLayer, bounds: screen),
        ]
        let result = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostRegularPID: 500,
            frontmostAXFullScreen: false
        )
        #expect(result)
    }

    @Test func ownCarrierWindowAndTinyOverlayWindowsDoNotTriggerFullScreen() {
        let windows = [
            ScreenWindow(owner: "Lintel", ownerPID: ownPID, layer: 27, bounds: screen),
            ScreenWindow(owner: "BetterDisplay", ownerPID: 400, layer: 1000, bounds: CGRect(x: 0, y: 1439, width: 1, height: 1), alpha: 0.003),
            ScreenWindow(owner: "Window Server", ownerPID: 500, layer: 24, bounds: screen),
            ScreenWindow(owner: "Finder", ownerPID: 200, layer: desktopIconLayer, bounds: screen),
        ]
        let result = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostAXFullScreen: false
        )
        #expect(!result)
    }

    @Test func fullScreenWindowOnAnotherDisplayDoesNotTriggerOnLintelScreen() {
        let otherScreen = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let windows = [
            ScreenWindow(owner: "Safari", ownerPID: 100, layer: 0, bounds: otherScreen),
            ScreenWindow(owner: "Finder", ownerPID: 200, layer: desktopIconLayer, bounds: screen),
        ]
        let result = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostAXFullScreen: nil
        )
        #expect(!result)
    }

    @Test func appSwitcherOverlayCoveringScreenDoesNotTriggerFullScreen() {
        let windows = [
            ScreenWindow(owner: "Debut", ownerPID: 350, layer: 25, bounds: screen),
            ScreenWindow(owner: "Safari", ownerPID: 100, layer: 0, bounds: CGRect(x: 100, y: 100, width: 1200, height: 900)),
            ScreenWindow(owner: "Finder", ownerPID: 200, layer: desktopIconLayer, bounds: screen),
        ]
        // Another app is frontmost while Debut shows its Cmd+Tab overlay.
        let whileOtherFrontmost = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostRegularPID: 100,
            frontmostAXFullScreen: false
        )
        #expect(!whileOtherFrontmost)

        // Even if Debut itself happens to be frontmost, a status-bar-level overlay is not presentation full screen.
        let whileSwitcherFrontmost = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostRegularPID: 350,
            frontmostAXFullScreen: false
        )
        #expect(!whileSwitcherFrontmost)
    }

    @Test func screenshotCaptureOverlaysDoNotTriggerFullScreen() {
        let windows = [
            ScreenWindow(owner: "screencapture", ownerPID: 769, layer: 1498, bounds: screen),
            ScreenWindow(owner: "Screenshot", ownerPID: 770, layer: 24, bounds: screen),
            ScreenWindow(owner: "Finder", ownerPID: 200, layer: desktopIconLayer, bounds: screen),
        ]
        let result = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostRegularPID: 200,
            frontmostAXFullScreen: false
        )
        #expect(!result)

        // Even if the system screenshot helper were treated as frontmost, system owners stay excluded.
        let evenIfFrontmost = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostRegularPID: 769,
            frontmostAXFullScreen: false
        )
        #expect(!evenIfFrontmost)
    }

    @Test func accessoryHighLayerOverlayDoesNotTriggerFullScreen() {
        let windows = [
            ScreenWindow(owner: "CleanShot X", ownerPID: 600, layer: 1500, bounds: screen),
            ScreenWindow(owner: "Finder", ownerPID: 200, layer: desktopIconLayer, bounds: screen),
        ]
        // Accessory apps never yield a frontmostRegularPID, and non-frontmost regular apps do not match.
        let accessoryActive = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostRegularPID: nil,
            frontmostAXFullScreen: false
        )
        #expect(!accessoryActive)

        let otherAppActive = FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screen,
            notchStripHeight: 0,
            ownPID: ownPID,
            desktopIconLayer: desktopIconLayer,
            frontmostRegularPID: 200,
            frontmostAXFullScreen: false
        )
        #expect(!otherAppActive)
    }
}
