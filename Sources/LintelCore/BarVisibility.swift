import Foundation

/// Tracks why the bar is hidden: explicitly by the user, or automatically while a window is full screen.
public struct BarVisibility: Equatable, Sendable {
    public var autoHideInFullScreen: Bool
    public private(set) var isHiddenByUser = false
    public private(set) var isInFullScreen = false
    public private(set) var isOverriddenInFullScreen = false

    public init(autoHideInFullScreen: Bool = true) {
        self.autoHideInFullScreen = autoHideInFullScreen
    }

    public var isAutoHiddenInFullScreen: Bool {
        autoHideInFullScreen && isInFullScreen && !isOverriddenInFullScreen
    }

    public var isHidden: Bool {
        isHiddenByUser || isAutoHiddenInFullScreen
    }

    public mutating func setAutoHideInFullScreen(_ enabled: Bool) {
        autoHideInFullScreen = enabled
        if !enabled { isOverriddenInFullScreen = false }
    }

    public mutating func setFullScreen(_ isFullScreen: Bool) {
        guard isFullScreen != isInFullScreen else { return }
        isInFullScreen = isFullScreen
        if !isFullScreen { isOverriddenInFullScreen = false }
    }

    /// Toggles visibility via the user's hide/show shortcut.
    /// In full screen with auto-hide enabled, showing overrides auto-hide until full screen ends,
    /// and hiding again returns to full-screen auto-hide instead of leaving the bar hidden on the desktop.
    public mutating func toggleHide() {
        if isHidden {
            isHiddenByUser = false
            if isInFullScreen { isOverriddenInFullScreen = true }
        } else if autoHideInFullScreen && isInFullScreen {
            isOverriddenInFullScreen = false
        } else {
            isHiddenByUser = true
        }
    }

    /// Explicitly shows the bar (e.g. keyboard control shortcut or Dock click).
    public mutating func show() {
        isHiddenByUser = false
        if isInFullScreen { isOverriddenInFullScreen = true }
    }

    /// Explicitly hides the bar.
    public mutating func hide() {
        if autoHideInFullScreen && isInFullScreen {
            isOverriddenInFullScreen = false
        } else {
            isHiddenByUser = true
        }
    }
}
