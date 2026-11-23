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
    /// The user sized this widget to show all of its content, so it grows and shrinks with that content
    /// up to the screen cap instead of holding `height`.
    public var followsContent: Bool

    public init(width: Double, height: Double, followsContent: Bool = false) {
        self.width = max(width.rounded(), 1)
        self.height = max(height.rounded(), 1)
        self.followsContent = followsContent
    }

    public init(_ size: CGSize, followsContent: Bool = false) {
        self.init(width: Double(size.width), height: Double(size.height), followsContent: followsContent)
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }

    public func requestedHeight(maxSize: CGSize) -> CGFloat {
        followsContent ? max(CGFloat(height), maxSize.height) : CGFloat(height)
    }

    private enum Key: String, CodingKey {
        case width, height, followsContent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        self.init(
            width: try container.decode(Double.self, forKey: .width),
            height: try container.decode(Double.self, forKey: .height),
            followsContent: try container.decodeIfPresent(Bool.self, forKey: .followsContent) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        if followsContent {
            try container.encode(true, forKey: .followsContent)
        }
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

    /// Which bottom corner of a click-to-peek panel is free to drag without fighting its anchored edge.
    /// Matches `Placement.panel(size:under:on:)`, which right-aligns chips on the right half of the screen
    /// and left-aligns chips on the left half.
    public static func peekCorner(forChip chip: CGRect, on screen: CGRect) -> ResizeCorner {
        chip.midX < screen.midX ? .bottomRight : .bottomLeft
    }

    /// Converts global AppKit screen pointer coordinates (bottom-left origin, Y growing upward) into
    /// top-left drag translation deltas (X right, Y down). Invariant to window moves or resizes.
    public static func screenTranslation(from start: CGPoint, to current: CGPoint) -> CGSize {
        CGSize(width: current.x - start.x, height: start.y - current.y)
    }

    /// Clamps a persisted box into valid freeform widget bounds for the current metrics and screen size.
    public static func clampedBox(_ box: WidgetBox, metrics: Metrics, maxSize: CGSize) -> WidgetBox {
        let minS = metrics.minWidgetSize
        let maxW = max(maxSize.width, minS.width)
        let maxH = max(maxSize.height, minS.height)
        let w = min(max(CGFloat(box.width), minS.width), maxW)
        let h = min(max(CGFloat(box.height), minS.height), maxH)
        return WidgetBox(width: Double(w.rounded()), height: Double(h.rounded()), followsContent: box.followsContent)
    }

    /// The box a finished resize stores: it follows its content when the height reached the content ceiling,
    /// while a width-only drag keeps whatever the height did before.
    public static func committedBox(
        _ size: CGSize,
        handle: ResizeHandle,
        previous: WidgetBox?,
        maxContentHeight: CGFloat?,
        maxSize: CGSize
    ) -> WidgetBox {
        let follows: Bool = if case .side = handle {
            previous?.followsContent ?? false
        } else if let maxContentHeight {
            size.height >= min(maxContentHeight, maxSize.height).rounded() - 0.5
        } else {
            false
        }
        return WidgetBox(size, followsContent: follows)
    }

    /// Computes the temporary max-size box when clicking an always-on desktop widget, capped to the visible screen
    /// below `topOffset` and never shrinking below `base`.
    public static func temporaryMaxBox(
        from base: WidgetBox,
        metrics: Metrics,
        screenSize: CGSize,
        topOffset: CGFloat = 0
    ) -> WidgetBox {
        let maxSize = metrics.maxWidgetSize(in: screenSize)
        let screenMargin: CGFloat = 16
        let availableW = max(screenSize.width - screenMargin * 2, metrics.minWidgetSize.width)
        let availableH = max(screenSize.height - max(topOffset, 0) - screenMargin, metrics.minWidgetSize.height)
        let targetW = max(min(maxSize.width, availableW), CGFloat(base.width))
        let targetH = max(min(maxSize.height, availableH), CGFloat(base.height))
        return WidgetBox(width: Double(targetW.rounded()), height: Double(targetH.rounded()))
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
        snapHeights: [CGFloat],
        allowsCollapse: Bool = true
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
        } else if allowsCollapse {
            let collapses: Bool = switch handle {
            case .side:
                raw.width < minS.width * 0.55
            case .corner, .bottom:
                raw.height < min(minS.height * 0.62, startSize.height * 0.85)
                    || (raw.width < minS.width * 0.65 && raw.height < minS.height * 0.78)
            }
            if collapses {
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

/// Tracks a desktop widget's temporary click-to-expand state until the cursor leaves and enters idle mode.
public struct WidgetExpansion: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case collapsed
        case expanded(slotID: String)
        case leaving(slotID: String, since: TimeInterval)
    }

    public private(set) var state: State = .collapsed
    public var grace: TimeInterval

    public init(grace: TimeInterval = 0.6) {
        self.grace = grace
    }

    public var slotID: String? {
        switch state {
        case .collapsed: nil
        case .expanded(let id), .leaving(let id, _): id
        }
    }

    public mutating func expand(_ slotID: String) {
        state = .expanded(slotID: slotID)
    }

    public mutating func collapse() {
        state = .collapsed
    }

    public mutating func pointer(inside: Bool, at now: TimeInterval) {
        switch state {
        case .collapsed:
            break
        case .expanded(let id):
            if !inside {
                state = grace <= 0 ? .collapsed : .leaving(slotID: id, since: now)
            }
        case .leaving(let id, let since):
            if inside {
                state = .expanded(slotID: id)
            } else if now - since + 1e-9 >= grace {
                state = .collapsed
            }
        }
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

/// Pure, stateless fitting math shared by `AdaptiveListLayout` and `ElasticItemsLayout`.
/// Computing the visible prefix and overflow footer slot directly from bounds avoids mutating SwiftUI `@State`
/// during `placeSubviews`, which otherwise oscillates across measurement and placement passes.
public enum AdaptiveOverflowFit {
    /// Upper bound on pre-built `"+N more"` footer subviews so pathological large lists stay O(1) in footer count.
    public static let maxFooterSlots = 64

    public struct Result: Equatable, Sendable {
        public var fittedCount: Int
        public var hiddenCount: Int
        /// Zero-based index into `footerLabels(itemCount:)`, or `nil` when no overflow footer is shown.
        public var activeFooterSlot: Int?
        public var totalHeight: CGFloat

        public init(fittedCount: Int, hiddenCount: Int, activeFooterSlot: Int?, totalHeight: CGFloat) {
            self.fittedCount = fittedCount
            self.hiddenCount = hiddenCount
            self.activeFooterSlot = activeFooterSlot
            self.totalHeight = totalHeight
        }
    }

    public static func footerLabels(itemCount: Int) -> [String] {
        guard itemCount > 1 else { return [] }
        let maxHidden = itemCount - 1
        let slotCount = min(maxHidden, maxFooterSlots)
        return (1...slotCount).map { hidden in
            if hidden == maxFooterSlots && maxHidden > maxFooterSlots {
                "+\(maxFooterSlots)+ more"
            } else {
                "+\(hidden) more"
            }
        }
    }

    public static func fit(
        itemHeights: [CGFloat],
        spacing: CGFloat,
        maxHeight: CGFloat?,
        showsFooter: Bool,
        footerHeight: CGFloat
    ) -> Result {
        let count = itemHeights.count
        guard count > 0 else {
            return Result(fittedCount: 0, hiddenCount: 0, activeFooterSlot: nil, totalHeight: 0)
        }
        let sumAll = itemHeights.reduce(0, +) + spacing * CGFloat(max(count - 1, 0))
        guard let maxH = maxHeight, maxH.isFinite, sumAll > maxH + 0.5 else {
            return Result(fittedCount: count, hiddenCount: 0, activeFooterSlot: nil, totalHeight: sumAll)
        }

        let budget = showsFooter ? max(0, maxH - footerHeight - spacing) : maxH
        var used: CGFloat = 0
        var fitted = 0
        for height in itemHeights {
            let next = used + (fitted > 0 ? spacing : 0) + height
            if next <= budget + 0.5 || fitted == 0 {
                used = next
                fitted += 1
            } else {
                break
            }
        }
        let hidden = max(0, count - fitted)
        let showMore = showsFooter && hidden > 0
        let slotCount = min(max(count - 1, 0), maxFooterSlots)
        let activeFooterSlot: Int? = (showMore && slotCount > 0) ? min(hidden, slotCount) - 1 : nil
        let total = used + (showMore ? (fitted > 0 ? spacing : 0) + footerHeight : 0)
        return Result(
            fittedCount: fitted,
            hiddenCount: hidden,
            activeFooterSlot: activeFooterSlot,
            totalHeight: maxH <= 0.5 ? total : min(total, maxH)
        )
    }
}

/// Pure, stateless height and chrome (legend / axis labels) allocation for `ChartView`.
/// Keeps legend/label visibility inside a single `Layout` pass so charts never flash or oscillate on threshold heights.
public enum ChartBlockFit {
    public static let legendMinTotalHeight: CGFloat = 56
    public static let labelsMinTotalHeight: CGFloat = 76

    public struct Result: Equatable, Sendable {
        public var showLegend: Bool
        public var showLabels: Bool
        public var canvasHeight: CGFloat
        public var totalHeight: CGFloat

        public init(showLegend: Bool, showLabels: Bool, canvasHeight: CGFloat, totalHeight: CGFloat) {
            self.showLegend = showLegend
            self.showLabels = showLabels
            self.canvasHeight = canvasHeight
            self.totalHeight = totalHeight
        }
    }

    public static func fit(
        hasLegend: Bool,
        legendHeight: CGFloat,
        hasLabels: Bool,
        labelsHeight: CGFloat,
        allowLabels: Bool,
        minCanvasHeight: CGFloat,
        fixedCanvasHeight: CGFloat?,
        spacing: CGFloat,
        maxHeight: CGFloat?
    ) -> Result {
        let legendCost = hasLegend ? (legendHeight + spacing) : 0
        let labelsCost = (hasLabels && allowLabels) ? (labelsHeight + spacing) : 0

        func naturalResult(canvas: CGFloat) -> Result {
            let showLegend = hasLegend && (canvas + legendCost + 0.5 >= legendMinTotalHeight)
            let usedLegend = showLegend ? legendCost : 0
            let showLabels = hasLabels && allowLabels && (canvas + usedLegend + labelsCost + 0.5 >= labelsMinTotalHeight)
            let usedLabels = showLabels ? labelsCost : 0
            return Result(
                showLegend: showLegend,
                showLabels: showLabels,
                canvasHeight: canvas,
                totalHeight: canvas + (usedLegend + usedLabels)
            )
        }

        guard let maxH = maxHeight, maxH.isFinite else {
            return naturalResult(canvas: fixedCanvasHeight ?? max(minCanvasHeight, 120))
        }

        if maxH <= 0.5 {
            if let fixed = fixedCanvasHeight {
                return naturalResult(canvas: fixed)
            }
            return Result(showLegend: false, showLabels: false, canvasHeight: minCanvasHeight, totalHeight: minCanvasHeight)
        }

        let showLegend = hasLegend
            && maxH + 0.5 >= max(legendMinTotalHeight, minCanvasHeight + legendCost)
            && (fixedCanvasHeight == nil || (fixedCanvasHeight! + legendCost) + 0.5 >= legendMinTotalHeight)
        let usedLegend = showLegend ? legendCost : 0

        let showLabels = hasLabels && allowLabels
            && maxH + 0.5 >= max(labelsMinTotalHeight, minCanvasHeight + usedLegend + labelsCost)
            && (fixedCanvasHeight == nil || (fixedCanvasHeight! + usedLegend + labelsCost) + 0.5 >= labelsMinTotalHeight)
        let usedLabels = showLabels ? labelsCost : 0

        let extras = usedLegend + usedLabels
        if let fixed = fixedCanvasHeight {
            let availableCanvas = max(0, maxH - extras)
            let canvasH = availableCanvas + 1e-6 >= fixed ? fixed : availableCanvas
            return Result(
                showLegend: showLegend,
                showLabels: showLabels,
                canvasHeight: canvasH,
                totalHeight: min(maxH, canvasH + extras)
            )
        } else {
            let canvasH = max(minCanvasHeight, maxH - extras)
            return Result(
                showLegend: showLegend,
                showLabels: showLabels,
                canvasHeight: canvasH,
                totalHeight: max(maxH, canvasH + extras)
            )
        }
    }
}
