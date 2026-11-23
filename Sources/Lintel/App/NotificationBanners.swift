import AppKit
import ApplicationServices
import LintelCore

/// Watches for macOS notification banners and reports where they are on screen, in AppKit coordinates.
@MainActor
final class NotificationBanners {
    private static let bundleID = "com.apple.notificationcenterui"
    var onChange: ([CGRect]) -> Void = { _ in }
    private var timer: Timer?
    private var overlayWindow: (owner: pid_t, window: CGWindowID)?
    private var banners: [CGRect] = [] {
        didSet { if banners != oldValue { onChange(banners) } }
    }

    init() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            banners = []
            return
        }
        guard isOverlayOnScreen(owner: app.processIdentifier) else {
            banners = []
            return
        }
        let measured = AXIsProcessTrusted() ? Self.bannerFrames(in: app.processIdentifier) : []
        if !measured.isEmpty {
            banners = measured
        } else if let screen = NSScreen.main {
            banners = [NotificationClearance.assumedBanner(visibleFrame: screen.visibleFrame)]
        }
    }

    // Notification Center keeps one screen-sized window at all times and orders it in only while a banner or its
    // sidebar shows, so being on screen is the signal; the window's bounds say nothing about the banners' size.
    private func isOverlayOnScreen(owner: pid_t) -> Bool {
        if overlayWindow?.owner != owner {
            let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            overlayWindow = all.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == owner }
                .flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
                .map { (owner, $0) }
        }
        guard let window = overlayWindow?.window else { return false }
        // Lists nothing while the window is ordered out.
        let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]])?.first
        return info?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    private static func bannerFrames(in pid: pid_t) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var found: [CGRect] = []
        for window in children(of: app, attribute: kAXWindowsAttribute) {
            collectBanners(in: window, depth: 0, into: &found)
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return found.map { CGRect(x: $0.minX, y: primaryHeight - $0.maxY, width: $0.width, height: $0.height) }
    }

    private static func collectBanners(in element: AXUIElement, depth: Int, into found: inout [CGRect]) {
        guard depth < 10 else { return }
        if let subrole = string(of: element, attribute: kAXSubroleAttribute), subrole.hasPrefix("AXNotificationCenter"),
           let frame = frame(of: element), frame.width > 0, frame.height > 0 {
            found.append(frame)
            return
        }
        for child in children(of: element, attribute: kAXChildrenAttribute) {
            collectBanners(in: child, depth: depth + 1, into: &found)
        }
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(of element: AXUIElement, attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: AnyObject?
        var size: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }
}
