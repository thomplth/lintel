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
}
