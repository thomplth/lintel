import CoreGraphics

/// How far the bar's window content moves down so macOS notification banners do not cover it. Frames are AppKit
/// screen coordinates, origin at the bottom left.
public enum NotificationClearance {
    public static let gap: CGFloat = 8

    /// `content` is where the content sits before any drop, so moving it never changes the answer. `notifications`
    /// are banners, or everything shown in the open Notification Center; the content moves below all it would
    /// overlap, off the bottom of the screen if Notification Center is full.
    public static func drop(content: CGRect, banners notifications: [CGRect], screen: CGRect) -> CGFloat {
        let inColumn = notifications
            .filter { $0.height < screen.height * 0.9 && $0.minX < content.maxX && $0.maxX > content.minX }
            .sorted { $0.maxY > $1.maxY }
        var drop: CGFloat = 0
        for notification in inColumn {
            let dropped = content.offsetBy(dx: 0, dy: -drop)
            if notification.minY < dropped.maxY + gap, notification.maxY > dropped.minY - gap {
                drop = max(drop, content.maxY - notification.minY + gap)
            }
        }
        return drop
    }

    /// Where a single banner appears when Accessibility cannot report the real ones, as measured on macOS 26.
    public static func assumedBanner(visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: 360, height: 80)
        return CGRect(
            x: visibleFrame.maxX - 16 - size.width, y: visibleFrame.maxY - 8 - size.height,
            width: size.width, height: size.height
        )
    }
}
