import CoreGraphics
import Foundation

/// The unified size continuum a module can inhabit: from a one-line bar chip up to a multi-column desktop widget.
public enum WidgetSize: String, CaseIterable, Codable, Hashable, Sendable {
    case chip
    case small
    case wide
    case medium
    case large
    case tall

    public static let widgetSizes: [WidgetSize] = [.small, .wide, .medium, .large, .tall]

    public var isWidget: Bool { self != .chip }

    public var columns: Int {
        switch self {
        case .chip: 0
        case .small: 1
        case .wide, .medium, .tall: 2
        case .large: 3
        }
    }

    public var rows: Int {
        switch self {
        case .chip: 0
        case .small, .wide: 1
        case .medium, .large: 2
        case .tall: 3
        }
    }

    public var displayName: String {
        switch self {
        case .chip: "Chip"
        case .small: "Small"
        case .wide: "Wide"
        case .medium: "Medium"
        case .large: "Large"
        case .tall: "Tall"
        }
    }

    public var shortLabel: String {
        switch self {
        case .chip: "Chip"
        case .small: "S"
        case .wide: "W"
        case .medium: "M"
        case .large: "L"
        case .tall: "T"
        }
    }

    public var area: Int { columns * rows }

    /// Progression order used for keyboard grow/shrink stepping.
    public var rank: Int {
        switch self {
        case .chip: 0
        case .small: 1
        case .wide: 2
        case .medium: 3
        case .large: 4
        case .tall: 5
        }
    }

    public func atLeast(_ other: WidgetSize) -> Bool {
        rank >= other.rank
    }

    public func step(by delta: Int, within allowed: [WidgetSize]) -> WidgetSize {
        let ordered = allowed.sorted { $0.rank < $1.rank }
        guard !ordered.isEmpty else { return self }
        guard let index = ordered.firstIndex(of: self) else {
            return delta >= 0 ? (ordered.first { $0.rank > rank } ?? ordered.last!) : (ordered.last { $0.rank < rank } ?? ordered.first!)
        }
        let target = min(max(index + delta, 0), ordered.count - 1)
        return ordered[target]
    }
}

/// Which bottom corner shows the resize handle so dragging always expands inward into open screen space.
public enum ResizeCorner: Equatable, Sendable {
    case bottomLeft
    case bottomRight
}

public enum WidgetResize {
    public static func corner(for anchor: BarAnchor) -> ResizeCorner {
        switch anchor {
        case .right: .bottomLeft
        case .left, .center: .bottomRight
        }
    }

    /// Proposed raw frame size produced by pulling the adaptive corner handle from `startSize` by `translation`.
    public static func proposedSize(from startSize: CGSize, translation: CGSize, corner: ResizeCorner) -> CGSize {
        let dx = corner == .bottomLeft ? -translation.width : translation.width
        let dy = translation.height
        return CGSize(width: startSize.width + dx, height: startSize.height + dy)
    }

    /// Picks the discrete `WidgetSize` tier in `allowed` that best matches a drag translation from `startSize`.
    public static func targetSize(
        from startTier: WidgetSize,
        startSize: CGSize,
        translation: CGSize,
        corner: ResizeCorner,
        allowed: [WidgetSize],
        metrics: Metrics
    ) -> WidgetSize {
        let unique = Array(Set(allowed)).sorted { $0.rank < $1.rank }
        guard !unique.isEmpty else { return startTier }
        let proposed = proposedSize(from: startSize, translation: translation, corner: corner)

        let chipIncluded = unique.contains(.chip)
        let widgetTiers = unique.filter(\.isWidget)
        guard !widgetTiers.isEmpty else { return .chip }

        let smallMetrics = metrics.widgetSize(.small)

        if startTier == .chip {
            // Pull past a clear intentional threshold (~36pt outward/downward) to morph out of a chip.
            let pullOut = corner == .bottomLeft ? -translation.width : translation.width
            let pullDown = translation.height
            let distance = hypot(max(pullOut, 0), max(pullDown, 0))
            if chipIncluded, distance < 36, proposed.height < smallMetrics.height * 0.55 {
                return .chip
            }
        } else if chipIncluded {
            // Collapse back into a chip once dragged well below the smallest widget's footprint.
            let collapseW = smallMetrics.width * 0.65
            let collapseH = smallMetrics.height * 0.60
            if proposed.width <= collapseW && proposed.height <= collapseH {
                return .chip
            }
            if proposed.height <= smallMetrics.height * 0.48 {
                return .chip
            }
        }

        // Choose the closest widget tier in normalized 2D geometry space so horizontal drags favor `wide`
        // and diagonal/vertical drags favor `medium`, `large`, or `tall`.
        let unitW = max(metrics.widgetUnitWidth, 1)
        let unitH = max(metrics.widgetUnitHeight, 1)
        let clampedW = max(proposed.width, smallMetrics.width * 0.5)
        let clampedH = max(proposed.height, smallMetrics.height * 0.5)

        return widgetTiers.min { lhs, rhs in
            let lSize = metrics.widgetSize(lhs)
            let rSize = metrics.widgetSize(rhs)
            let lDist = hypot((clampedW - lSize.width) / unitW, (clampedH - lSize.height) / unitH)
            let rDist = hypot((clampedW - rSize.width) / unitW, (clampedH - rSize.height) / unitH)
            return lDist < rDist
        } ?? startTier
    }

    /// Apple-style rubber-band damping past the smallest and largest supported footprints during an active drag.
    public static func rubberySize(proposed: CGSize, min minSize: CGSize, max maxSize: CGSize) -> CGSize {
        func damp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
            if value < low {
                let over = low - value
                let floor = low * 0.78
                return Swift.max(floor, low - over * 0.22 / (1 + over / Swift.max(low, 1)))
            }
            if value > high {
                let over = value - high
                return high + over * 0.24 / (1 + over / 260)
            }
            return value
        }
        return CGSize(
            width: damp(proposed.width, low: minSize.width, high: maxSize.width),
            height: damp(proposed.height, low: minSize.height, high: maxSize.height)
        )
    }
}

extension Metrics {
    private var widgetDensityScale: Double {
        switch theme.density {
        case "compact": 0.94
        case "roomy": 1.08
        default: 1.0
        }
    }

    public var widgetUnitWidth: CGFloat {
        let fontScale = max(theme.fontSize, 12) / 14
        return CGFloat((176 * fontScale * widgetDensityScale).rounded())
    }

    public var widgetUnitHeight: CGFloat {
        let fontScale = max(theme.fontSize, 12) / 14
        return CGFloat((164 * fontScale * widgetDensityScale).rounded())
    }

    public var widgetGap: CGFloat {
        CGFloat(max(unit * 2.5, 8))
    }

    public var widgetPadding: Double {
        unit * 3
    }

    public var widgetCornerRadius: Double {
        switch theme.cornerStyle {
        case "rounded": 14
        case "square": 6
        default: 22
        }
    }

    public func widgetSize(_ tier: WidgetSize) -> CGSize {
        guard tier.isWidget else { return .zero }
        let cols = CGFloat(tier.columns)
        let rows = CGFloat(tier.rows)
        return CGSize(
            width: cols * widgetUnitWidth + (cols - 1) * widgetGap,
            height: rows * widgetUnitHeight + (rows - 1) * widgetGap
        )
    }
}
