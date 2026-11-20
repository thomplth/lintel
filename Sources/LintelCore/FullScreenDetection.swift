import CoreGraphics
import Foundation

public struct ScreenWindow: Equatable, Sendable {
    public var owner: String
    public var ownerPID: Int32
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double

    public init(owner: String, ownerPID: Int32, layer: Int, bounds: CGRect, alpha: Double = 1) {
        self.owner = owner
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
    }
}

/// Decides whether a user window is currently full screen on a given display, in global display coordinates.
public enum FullScreenDetection {
    private static let systemOwners: Set<String> = [
        "Window Server", "WindowManager", "Dock", "Control Center", "Notification Center", "Wallpaper",
        "Spotlight", "SystemUIServer",
    ]
    private static let tolerance: CGFloat = 2

    public static func isFullScreen(
        windows: [ScreenWindow],
        screenBounds: CGRect,
        notchStripHeight: CGFloat,
        ownPID: Int32,
        desktopIconLayer: Int,
        normalLayer: Int = 0,
        frontmostAXFullScreen: Bool?
    ) -> Bool {
        if frontmostAXFullScreen == true { return true }
        guard screenBounds.width > 0, screenBounds.height > 0 else { return false }

        let userWindows = windows.filter {
            $0.alpha > 0 && $0.ownerPID != ownPID && !systemOwners.contains($0.owner)
        }

        // Non-native / presentation full-screen windows sit above normal windows and cover the display.
        let hasPresentationFullScreen = userWindows.contains { window in
            window.layer > normalLayer && coversScreen(window.bounds, screen: screenBounds, notchStripHeight: notchStripHeight)
        }
        if hasPresentationFullScreen { return true }

        // On a normal desktop Space, Finder's desktop icon window covers the display at `desktopIconLayer`.
        // In a native full-screen Space (single window or Split View), that desktop window is absent while
        // one or more normal-layer windows fill the display's height (or the area below the notch).
        let hasDesktopWindow = windows.contains { window in
            window.layer == desktopIconLayer && coversScreen(window.bounds, screen: screenBounds, notchStripHeight: 0)
        }
        guard !hasDesktopWindow else { return false }

        let normalOnScreen = userWindows.filter { window in
            window.layer == normalLayer && fillsScreenHeight(window.bounds, screen: screenBounds, notchStripHeight: notchStripHeight)
        }
        if normalOnScreen.contains(where: { coversScreen($0.bounds, screen: screenBounds, notchStripHeight: notchStripHeight) }) {
            return true
        }
        // Split View full screen: two side-by-side windows whose combined width covers almost the whole display.
        let combinedWidth = normalOnScreen.reduce(CGFloat(0)) { $0 + $1.bounds.width }
        return combinedWidth >= screenBounds.width - 24
    }

    private static func coversScreen(_ bounds: CGRect, screen: CGRect, notchStripHeight: CGFloat) -> Bool {
        abs(bounds.minX - screen.minX) <= tolerance
            && abs(bounds.width - screen.width) <= tolerance
            && fillsScreenHeight(bounds, screen: screen, notchStripHeight: notchStripHeight)
    }

    private static func fillsScreenHeight(_ bounds: CGRect, screen: CGRect, notchStripHeight: CGFloat) -> Bool {
        let onScreenHorizontally = bounds.minX >= screen.minX - tolerance && bounds.maxX <= screen.maxX + tolerance
        guard onScreenHorizontally else { return false }
        let fillsAll = abs(bounds.minY - screen.minY) <= tolerance && abs(bounds.height - screen.height) <= tolerance
        if fillsAll { return true }
        guard notchStripHeight > 0 else { return false }
        let belowNotchY = screen.minY + notchStripHeight
        let belowNotchHeight = screen.height - notchStripHeight
        return abs(bounds.minY - belowNotchY) <= tolerance && abs(bounds.height - belowNotchHeight) <= tolerance
    }
}
