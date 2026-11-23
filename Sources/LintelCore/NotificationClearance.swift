import CoreGraphics

/// How far the bar's window content moves down so macOS notification banners do not cover it. Frames are AppKit
/// screen coordinates, origin at the bottom left.
public enum NotificationClearance {
    public static let gap: CGFloat = 8

    /// `content` is where the content sits before any drop, so moving it never changes the answer.
    public static func drop(content: CGRect, banners: [CGRect], screen: CGRect) -> CGFloat {
        let covering = banners.filter { banner in
            banner.height < screen.height * 0.5
                && banner.minX < content.maxX && banner.maxX > content.minX
                && banner.minY < content.maxY && banner.maxY > content.minY
        }
        guard let lowest = covering.map(\.minY).min() else { return 0 }
        return content.maxY - lowest + gap
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
