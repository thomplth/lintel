import CoreGraphics
import Foundation

/// Semantic starting shape a module suggests before the user resizes it freely.
/// Never carries raw pixels; `Metrics(theme)` derives theme-scaled starting dimensions.
public enum WidgetShape: String, CaseIterable, Codable, Hashable, Sendable {
    case compact
    case card
    case wide
    case sidebar
    case canvas
}

/// A freeform desktop widget's persisted dimensions in logical points.
public struct WidgetBox: Equatable, Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = max(width.rounded(), 1)
        self.height = max(height.rounded(), 1)
    }

    public init(_ size: CGSize) {
        self.init(width: Double(size.width), height: Double(size.height))
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

/// Which bottom corner shows the 2D resize arc so dragging always pulls inward into open screen space.
public enum ResizeCorner: Equatable, Sendable {
    case bottomLeft
    case bottomRight
}

/// Which resize grip is being dragged: corner (2D), bottom edge (height-only), or inward side edge (width-only).
public enum ResizeHandle: Equatable, Sendable {
    case corner(ResizeCorner)
    case bottom
    case side(ResizeCorner)
}

/// A canonical form factor used to verify that every module adapts cleanly across extreme and typical aspect ratios.
public struct WidgetViewport: Equatable, Sendable {
    public var id: String
    public var title: String
    public var size: CGSize

    public init(id: String, title: String, size: CGSize) {
        self.id = id
        self.title = title
        self.size = size
    }

    public static func canonicalMatrix(for metrics: Metrics) -> [WidgetViewport] {
        let scale = metrics.widgetScale
        func scaled(_ w: Double, _ h: Double) -> CGSize {
            CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        }
        return [
            WidgetViewport(id: "tiny", title: "Tiny Floor", size: scaled(164, 112)),
            WidgetViewport(id: "ribbon", title: "Slim Ribbon", size: scaled(420, 104)),
            WidgetViewport(id: "sidebar", title: "Narrow Sidebar", size: scaled(216, 420)),
            WidgetViewport(id: "compact", title: "Compact Card", size: scaled(264, 208)),
            WidgetViewport(id: "balanced", title: "Balanced Card", size: scaled(340, 290)),
            WidgetViewport(id: "spacious", title: "Spacious Dashboard", size: scaled(500, 360)),
        ]
    }
}

public enum WidgetResize {
    public struct Resolution: Equatable, Sendable {
        public var collapsesToChip: Bool
        public var liveSize: CGSize
        public var committedSize: CGSize
        public var didSnapWidth: Bool
        public var didSnapHeight: Bool
        public var hitContentCeiling: Bool
    }

    public static let magneticThreshold: CGFloat = 10

    public static func corner(for anchor: BarAnchor) -> ResizeCorner {
        switch anchor {
        case .right: .bottomLeft
        case .left, .center: .bottomRight
        }
    }

    /// Raw frame size produced by pulling a corner, bottom edge, or side edge from `startSize` by `translation`.
    public static func proposedSize(from startSize: CGSize, translation: CGSize, handle: ResizeHandle) -> CGSize {
        switch handle {
        case .corner(let corner):
            let dx = corner == .bottomLeft ? -translation.width : translation.width
            return CGSize(width: startSize.width + dx, height: startSize.height + translation.height)
        case .bottom:
            return CGSize(width: startSize.width, height: startSize.height + translation.height)
        case .side(let corner):
            let dx = corner == .bottomLeft ? -translation.width : translation.width
            return CGSize(width: startSize.width + dx, height: startSize.height)
        }
    }

    /// Resolves a freeform drag gesture with collapse threshold, magnetic neighbor detents, and zero-void content ceiling.
    public static func resolve(
        fromChip: Bool,
        startSize: CGSize,
        translation: CGSize,
        handle: ResizeHandle,
        metrics: Metrics,
        maxSize: CGSize,
        maxContentHeight: CGFloat?,
        snapWidths: [CGFloat],
        snapHeights: [CGFloat]
    ) -> Resolution {
        let minS = metrics.minWidgetSize
        let raw = proposedSize(from: startSize, translation: translation, handle: handle)

        // Check chip promotion / collapse thresholds.
        if fromChip {
            let pullOut: CGFloat = switch handle {
            case .corner(let c), .side(let c): c == .bottomLeft ? -translation.width : translation.width
            case .bottom: 0
            }
            let pullDown = max(translation.height, 0)
            let distance = hypot(max(pullOut, 0), pullDown)
            if distance < 34, raw.height < minS.height * 0.72 {
                return Resolution(
                    collapsesToChip: true,
                    liveSize: CGSize(width: max(raw.width, startSize.width * 0.85), height: max(raw.height, startSize.height)),
                    committedSize: startSize,
                    didSnapWidth: false,
                    didSnapHeight: false,
                    hitContentCeiling: false
                )
            }
        } else {
            let tooShort = raw.height < minS.height * 0.62
            let tooSmallBoth = raw.width < minS.width * 0.65 && raw.height < minS.height * 0.78
            if tooShort || tooSmallBoth {
                return Resolution(
                    collapsesToChip: true,
                    liveSize: rubberySize(proposed: raw, min: CGSize(width: 72, height: 28), max: maxSize),
                    committedSize: .zero,
                    didSnapWidth: false,
                    didSnapHeight: false,
                    hitContentCeiling: false
                )
            }
        }

        // Determine effective height ceiling: screen max, tightened to content's natural max height when finite (zero void).
        let effectiveMaxW = max(maxSize.width, minS.width)
        let screenMaxH = max(maxSize.height, minS.height)
        let contentCapH = maxContentHeight.map { max(min($0, screenMaxH), minS.height) }
        let effectiveMaxH = contentCapH ?? screenMaxH

        // Clamp proposed size into valid freeform bounds.
        var committedW = min(max(raw.width, minS.width), effectiveMaxW)
        var committedH = min(max(raw.height, minS.height), effectiveMaxH)

        // Apply magnetic alignment detents against neighbor widgets when dragging that axis.
        var didSnapW = false
        var didSnapH = false
        if handle != .bottom {
            if let snap = nearestDetent(committedW, candidates: snapWidths, threshold: magneticThreshold) {
                committedW = min(max(snap, minS.width), effectiveMaxW)
                didSnapW = true
            }
        }
        if case .side = handle {
            // Side edge doesn't alter height.
        } else if let snap = nearestDetent(committedH, candidates: snapHeights, threshold: magneticThreshold) {
            committedH = min(max(snap, minS.height), effectiveMaxH)
            didSnapH = true
        }

        let hitCeiling = contentCapH != nil && raw.height > effectiveMaxH + 0.5

        // Live preview tracks the snapped value inside bounds, and rubber-bands smoothly past bounds/content ceiling.
        let liveW: CGFloat = if raw.width < minS.width || raw.width > effectiveMaxW {
            rubberyAxis(raw.width, low: minS.width, high: effectiveMaxW)
        } else {
            committedW
        }
        let liveH: CGFloat = if raw.height < minS.height || raw.height > effectiveMaxH {
            rubberyAxis(raw.height, low: minS.height, high: effectiveMaxH)
        } else {
            committedH
        }

        return Resolution(
            collapsesToChip: false,
            liveSize: CGSize(width: liveW.rounded(), height: liveH.rounded()),
            committedSize: CGSize(width: committedW.rounded(), height: committedH.rounded()),
            didSnapWidth: didSnapW,
            didSnapHeight: didSnapH,
            hitContentCeiling: hitCeiling
        )
    }

    /// Keyboard grow/shrink stepping across smooth progressive boxes, returning nil when collapsed back to chip.
    public static func step(from current: WidgetBox?, delta: Int, defaultShape: WidgetShape, metrics: Metrics) -> WidgetBox? {
        let scale = metrics.widgetScale
        let ladder: [WidgetBox] = [
            WidgetBox(width: (210 * scale).rounded(), height: (148 * scale).rounded()),
            WidgetBox(width: (280 * scale).rounded(), height: (224 * scale).rounded()),
            WidgetBox(width: (356 * scale).rounded(), height: (296 * scale).rounded()),
            WidgetBox(width: (468 * scale).rounded(), height: (360 * scale).rounded()),
        ]
        guard let current else {
            guard delta > 0 else { return nil }
            return metrics.defaultWidgetBox(for: defaultShape)
        }
        let currentArea = current.width * current.height
        if delta > 0 {
            return ladder.first { $0.width * $0.height > currentArea * 1.12 } ?? ladder.last
        } else {
            return ladder.last { $0.width * $0.height < currentArea * 0.88 }
        }
    }

    public static func rubberySize(proposed: CGSize, min minSize: CGSize, max maxSize: CGSize) -> CGSize {
        CGSize(
            width: rubberyAxis(proposed.width, low: minSize.width, high: maxSize.width),
            height: rubberyAxis(proposed.height, low: minSize.height, high: maxSize.height)
        )
    }

    private static func rubberyAxis(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        if value < low {
            let over = low - value
            let floor = low * 0.78
            return Swift.max(floor, low - over * 0.22 / (1 + over / Swift.max(low, 1)))
        }
        if value > high {
            let over = value - high
            return high + over * 0.22 / (1 + over / 220)
        }
        return value
    }

    private static func nearestDetent(_ value: CGFloat, candidates: [CGFloat], threshold: CGFloat) -> CGFloat? {
        candidates
            .filter { abs($0 - value) <= threshold }
            .min { abs($0 - value) < abs($1 - value) }
    }
}

extension Metrics {
    private var widgetDensityScale: Double {
        switch theme.density {
        case "compact": 0.93
        case "roomy": 1.08
        default: 1.0
        }
    }

    /// Unified scale factor for freeform widget metrics derived from theme fontSize and density.
    public var widgetScale: Double {
        let fontScale = max(theme.fontSize, 12) / 14
        return fontScale * widgetDensityScale
    }

    public var minWidgetSize: CGSize {
        CGSize(width: (152 * widgetScale).rounded(), height: (88 * widgetScale).rounded())
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
        default: 20
        }
    }

    /// Width threshold below which `split([a, b])` automatically stacks its children vertically.
    public var splitStackThreshold: CGFloat {
        CGFloat((340 * widgetScale).rounded())
    }

    public func defaultWidgetBox(for shape: WidgetShape) -> WidgetBox {
        let s = widgetScale
        switch shape {
        case .compact: return WidgetBox(width: (248 * s).rounded(), height: (172 * s).rounded())
        case .card: return WidgetBox(width: (312 * s).rounded(), height: (268 * s).rounded())
        case .wide: return WidgetBox(width: (400 * s).rounded(), height: (236 * s).rounded())
        case .sidebar: return WidgetBox(width: (248 * s).rounded(), height: (380 * s).rounded())
        case .canvas: return WidgetBox(width: (320 * s).rounded(), height: (260 * s).rounded())
        }
    }

    public func maxWidgetSize(in screenSize: CGSize) -> CGSize {
        CGSize(
            width: min(max((screenSize.width * 0.65).rounded(), 480), 820),
            height: min(max((screenSize.height * 0.78).rounded(), 440), 780)
        )
    }
}
