import CoreGraphics

/// Keeps the pointer out of the strip along the top edge where an auto-hidden menu bar starts to slide in, but only
/// above the bar; the rest of the edge still reveals the menu bar.
public enum TopEdgeGuard {
    /// macOS 27 reveals the menu bar once the pointer rests within this many points of the top edge.
    public static let revealDepth: CGFloat = 5

    /// `point`, `screenTop` and `guarded` are in global display coordinates, whose y grows downwards.
    public static func position(for point: CGPoint, screenTop: CGFloat, guarded: ClosedRange<CGFloat>?) -> CGPoint {
        guard let guarded, guarded.contains(point.x), point.y < screenTop + revealDepth else { return point }
        return CGPoint(x: point.x, y: screenTop + revealDepth)
    }

    /// The stretch of the top edge above `bar`, or nil when the bar is not at the edge (or right under the notch
    /// strip, where a bar too wide for the notch's side hangs) or another display sits above it there. All frames
    /// are in AppKit coordinates, whose y grows upwards.
    public static func span(
        of bar: CGRect, on screen: CGRect, besides others: [CGRect], notchStripHeight: CGFloat = 0
    ) -> ClosedRange<CGFloat>? {
        guard bar.maxY >= screen.maxY - notchStripHeight - 1 else { return nil }
        let hasDisplayAbove = others.contains { other in
            abs(other.minY - screen.maxY) < 1 && other.minX < bar.maxX && other.maxX > bar.minX
        }
        return hasDisplayAbove ? nil : bar.minX...bar.maxX
    }
}
