import LintelCore
import SwiftUI

enum BlockFlex: Equatable {
    case fixed
    case flexible(minHeight: CGFloat, capsAtIdeal: Bool)
}

struct BlockPriorityKey: LayoutValueKey {
    static let defaultValue = 0
}

struct BlockFlexKey: LayoutValueKey {
    static let defaultValue = BlockFlex.fixed
}

extension ViewNode {
    var layoutPriority: Int {
        switch string("priority") {
        case "detail": 2
        case "supporting": 1
        default: 0
        }
    }

    /// True if this subtree contains a block that meaningfully stretches to fill arbitrary height (chart, web, mini-app, image).
    /// Widgets WITHOUT unbounded flex clamp strictly to their natural content height (zero blank void).
    var hasUnboundedFlex: Bool {
        switch component {
        case .chart, .app, .web, .image:
            return string("height") == nil || string("height") == "fill"
        case .column, .section, .split:
            return children.contains(where: \.hasUnboundedFlex)
        default:
            return false
        }
    }

    var containsFlexibleBlock: Bool {
        switch component {
        case .chart, .list, .app, .web, .image, .split, .spacer:
            return true
        case .section, .column:
            return bool("elastic") || children.contains(where: \.containsFlexibleBlock)
        default:
            return false
        }
    }

    var layoutFlex: BlockFlex {
        switch component {
        case .chart:
            return .flexible(minHeight: 44, capsAtIdeal: false)
        case .app, .web, .image:
            return .flexible(minHeight: 72, capsAtIdeal: false)
        case .list:
            return .flexible(minHeight: 34, capsAtIdeal: true)
        case .split:
            return .flexible(minHeight: 54, capsAtIdeal: !hasUnboundedFlex)
        case .spacer:
            return .flexible(minHeight: 0, capsAtIdeal: true)
        case .section, .column:
            if bool("elastic") {
                return .flexible(minHeight: 44, capsAtIdeal: !hasUnboundedFlex)
            }
            if containsFlexibleBlock {
                return .flexible(minHeight: 52, capsAtIdeal: !hasUnboundedFlex)
            }
            return .fixed
        default:
            return .fixed
        }
    }
}

// MARK: - Zero-Void Card Wrapper Layout

/// Enforces the zero-void invariant:
/// - If `hasUnboundedFlex` is true (chart/web/app/image), fills `requestedHeight`.
/// - If finite, clamps the card's actual height to `min(requestedHeight, max(naturalHeight, minHeight))` so empty
///   blank space can never appear beneath finite content.
struct ZeroVoidCardLayout: Layout {
    let requestedWidth: CGFloat
    let requestedHeight: CGFloat
    let minHeight: CGFloat
    let hasUnboundedFlex: Bool
    let padding: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else {
            return CGSize(width: requestedWidth, height: requestedHeight)
        }
        let innerW = max(requestedWidth - padding * 2, 40)
        if hasUnboundedFlex {
            return CGSize(width: requestedWidth, height: max(requestedHeight, minHeight))
        }
        let maxInnerH = max(requestedHeight - padding * 2, 20)
        // Ask the content for its exact discrete fitted height within `maxInnerH` so even sub-row remainders
        // between whole list items or elastic sections never leave blank void at the bottom of the card.
        let fittedInnerH = content.sizeThatFits(ProposedViewSize(width: innerW, height: maxInnerH)).height
        let fittedCardH = ceil(fittedInnerH + padding * 2)
        return CGSize(width: requestedWidth, height: max(min(requestedHeight, fittedCardH), 48))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let innerW = max(bounds.width - padding * 2, 40)
        let innerH = max(bounds.height - padding * 2, 20)
        content.place(
            at: CGPoint(x: bounds.minX + padding, y: bounds.minY + padding),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: innerW, height: innerH)
        )
    }
}

// MARK: - Zero-Scroll Adaptive Vertical Stack

struct AdaptiveStackCache {
    var width: CGFloat?
    var count = 0
    var priorities: [Int] = []
    var flexes: [BlockFlex] = []
    var ideals: [CGFloat] = []
    var bases: [CGFloat] = []
    var hasMeasurement = false

    mutating func invalidate() {
        hasMeasurement = false
    }

    func matches(width: CGFloat?, count: Int) -> Bool {
        guard hasMeasurement, self.count == count else { return false }
        switch (self.width, width) {
        case (nil, nil): return true
        case (let a?, let b?): return abs(a - b) < 0.01
        default: return false
        }
    }
}

/// Zero-scroll vertical stack for freeform widgets: fixed blocks take natural height, elastic collections & lists
/// compress row-by-row first, flexible charts/apps absorb remaining height, and lower-priority sections yield cleanly.
struct AdaptiveStackLayout: Layout {
    var spacing: CGFloat
    var alignment: HorizontalAlignment

    func makeCache(subviews: Subviews) -> AdaptiveStackCache {
        AdaptiveStackCache()
    }

    func updateCache(_ cache: inout AdaptiveStackCache, subviews: Subviews) {
        cache.invalidate()
    }

    private struct Plan {
        var visible: [Bool]
        var heights: [CGFloat]
        var totalHeight: CGFloat
    }

    private func plan(proposal: ProposedViewSize, subviews: Subviews, cache: inout AdaptiveStackCache) -> Plan {
        let count = subviews.count
        guard count > 0 else { return Plan(visible: [], heights: [], totalHeight: 0) }
        let width = proposal.width

        // Unbounded vertical proposal: measure true natural height (used for zero-void ceiling!).
        guard let maxHeight = proposal.height, maxHeight.isFinite else {
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
            let total = heights.reduce(0, +) + spacing * CGFloat(max(count - 1, 0))
            return Plan(visible: Array(repeating: true, count: count), heights: heights, totalHeight: total)
        }

        var visible = Array(repeating: true, count: count)
        let priorities: [Int]
        let flexes: [BlockFlex]
        let ideals: [CGFloat]
        let bases: [CGFloat]

        if cache.matches(width: width, count: count) {
            priorities = cache.priorities
            flexes = cache.flexes
            ideals = cache.ideals
            bases = cache.bases
        } else {
            priorities = subviews.map { $0[BlockPriorityKey.self] }
            flexes = subviews.map { $0[BlockFlexKey.self] }
            ideals = (0..<count).map { index in
                switch flexes[index] {
                case .fixed:
                    return subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                case .flexible(_, let caps):
                    return caps ? subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height : .greatestFiniteMagnitude
                }
            }
            bases = (0..<count).map { index in
                switch flexes[index] {
                case .fixed:
                    return ideals[index]
                case .flexible(let minH, let caps):
                    // Measure the subview's true compressed minimum height at this width (e.g. a nested column or section
                    // holding fixed stats + a chart needs the sum of its essential children, not a hardcoded 52pt floor!).
                    let compressed = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: 0)).height
                    let floor = max(minH, compressed)
                    return caps ? min(floor, ideals[index]) : floor
                }
            }
            cache.width = width
            cache.count = count
            cache.priorities = priorities
            cache.flexes = flexes
            cache.ideals = ideals
            cache.bases = bases
            cache.hasMeasurement = true
        }

        func baseTotal() -> CGFloat {
            let active = (0..<count).filter { visible[$0] }
            guard !active.isEmpty else { return 0 }
            return active.reduce(0) { $0 + bases[$1] } + spacing * CGFloat(active.count - 1)
        }

        // Drop detail (2), then supporting (1), then trailing overflow essential blocks (keeping at least the first
        // essential block) so a half-clipped orphan header can never peek at the bottom edge of a tight card.
        for dropLevel in [2, 1] {
            if baseTotal() <= maxHeight + 0.5 { break }
            for index in (0..<count).reversed() where visible[index] && priorities[index] >= dropLevel {
                visible[index] = false
                if baseTotal() <= maxHeight + 0.5 { break }
            }
        }
        if maxHeight > 0.5 && baseTotal() > maxHeight + 0.5 {
            for index in (1..<count).reversed() where visible[index] {
                visible[index] = false
                if baseTotal() <= maxHeight + 0.5 { break }
            }
        }

        let active = (0..<count).filter { visible[$0] }
        guard !active.isEmpty else { return Plan(visible: visible, heights: Array(repeating: 0, count: count), totalHeight: 0) }

        var heights = Array(repeating: CGFloat(0), count: count)
        var fixedUsed: CGFloat = spacing * CGFloat(active.count - 1)
        var flexIndices: [Int] = []
        for index in active {
            heights[index] = bases[index]
            fixedUsed += bases[index]
            if case .flexible = flexes[index] {
                flexIndices.append(index)
            }
        }

        // Distribute remaining height across flexible blocks; blocks that cap at ideal hand surplus to stretchables.
        var surplus = max(0, maxHeight - fixedUsed)
        var remainingFlex = flexIndices
        while surplus > 0.5 && !remainingFlex.isEmpty {
            let share = surplus / CGFloat(remainingFlex.count)
            var nextRound: [Int] = []
            var consumed: CGFloat = 0
            for index in remainingFlex {
                let cap = ideals[index]
                let headroom = max(0, cap - heights[index])
                let grant = min(share, headroom)
                heights[index] += grant
                consumed += grant
                if cap - heights[index] > 0.5 {
                    nextRound.append(index)
                }
            }
            if consumed < 0.1 { break }
            surplus -= consumed
            remainingFlex = nextRound
        }

        // Re-measure capped flexible blocks at their granted budget so lists/elastic collections snap to exact whole
        // entries, then redistribute any reclaimed sub-row surplus to sibling flexible blocks that can still grow.
        var reclaimed: CGFloat = 0
        var snapped = Set<Int>()
        for index in flexIndices {
            if case .flexible(_, let caps) = flexes[index], caps {
                let fitted = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: heights[index])).height
                if fitted < heights[index] - 0.5 {
                    reclaimed += heights[index] - fitted
                    heights[index] = fitted
                    snapped.insert(index)
                }
            }
        }
        if reclaimed > 1 {
            let growable = flexIndices.filter { !snapped.contains($0) && ideals[$0] - heights[$0] > 0.5 }
            if !growable.isEmpty {
                let extra = reclaimed / CGFloat(growable.count)
                for index in growable {
                    let grant = min(extra, ideals[index] - heights[index])
                    let candidate = heights[index] + grant
                    if case .flexible(_, let caps) = flexes[index], caps {
                        heights[index] = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: candidate)).height
                    } else {
                        heights[index] = candidate
                    }
                }
            }
        }

        // Measure true minimum or natural height cleanly; when `proposal.height == 0` we return the minimum
        // height required for the essential items so parent stacks never allocate too little space and overlap.
        let total = active.reduce(0) { $0 + heights[$1] } + spacing * CGFloat(active.count - 1)
        return Plan(visible: visible, heights: heights, totalHeight: maxHeight <= 0.5 ? total : min(total, maxHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout AdaptiveStackCache) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let computed = plan(proposal: ProposedViewSize(width: width, height: proposal.height), subviews: subviews, cache: &cache)
        return CGSize(width: width, height: computed.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout AdaptiveStackCache) {
        let computed = plan(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews, cache: &cache)
        var y = bounds.minY
        var placedAny = false
        for index in subviews.indices {
            guard computed.visible[index] else {
                subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.maxY + 200), proposal: ProposedViewSize(width: 0, height: 0))
                continue
            }
            if placedAny { y += spacing }
            placedAny = true
            let h = computed.heights[index]
            let x: CGFloat
            if alignment == .leading {
                x = bounds.minX
            } else {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: h))
                x = alignment == .center
                    ? bounds.minX + max(0, (bounds.width - size.width) / 2)
                    : bounds.maxX - min(bounds.width, size.width)
            }
            subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
            y += h
        }
    }
}

// MARK: - Responsive Auto-Stacking Split Layout

/// Lays 2 to 3 panes side by side when wide, and automatically stacks them vertically when narrowed into a sidebar.
struct SplitLayout: Layout {
    var weights: [Double]
    var spacing: CGFloat
    var alignment: VerticalAlignment
    var stackThreshold: CGFloat

    func makeCache(subviews: Subviews) -> AdaptiveStackCache {
        AdaptiveStackCache()
    }

    func updateCache(_ cache: inout AdaptiveStackCache, subviews: Subviews) {
        cache.invalidate()
    }

    private func shouldStack(width: CGFloat?, count: Int) -> Bool {
        guard count > 1, let width else { return false }
        let threshold = count >= 3 ? stackThreshold * 1.35 : stackThreshold
        return width < threshold
    }

    private func normalizedWeights(count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let raw = (0..<count).map { index -> CGFloat in
            let v = index < weights.count ? weights[index] : 1.0
            return CGFloat(max(v, 0.2))
        }
        let sum = raw.reduce(0, +)
        return sum > 0 ? raw.map { $0 / sum } : Array(repeating: 1 / CGFloat(count), count: count)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout AdaptiveStackCache) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        if shouldStack(width: proposal.width, count: subviews.count) {
            return AdaptiveStackLayout(spacing: spacing, alignment: .leading).sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache)
        }
        let totalGap = spacing * CGFloat(max(subviews.count - 1, 0))
        let width = proposal.width ?? (subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +) + totalGap)
        let fractions = normalizedWeights(count: subviews.count)
        let contentWidth = max(0, width - totalGap)
        let maxHeight = subviews.indices.map { index in
            subviews[index].sizeThatFits(ProposedViewSize(width: contentWidth * fractions[index], height: proposal.height)).height
        }.max() ?? 0
        return CGSize(width: width, height: maxHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout AdaptiveStackCache) {
        guard !subviews.isEmpty else { return }
        if shouldStack(width: bounds.width, count: subviews.count) {
            AdaptiveStackLayout(spacing: spacing, alignment: .leading).placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
            return
        }
        let totalGap = spacing * CGFloat(max(subviews.count - 1, 0))
        let contentWidth = max(0, bounds.width - totalGap)
        let fractions = normalizedWeights(count: subviews.count)
        var x = bounds.minX
        for index in subviews.indices {
            let colW = (contentWidth * fractions[index]).rounded(.down)
            let measured = subviews[index].sizeThatFits(ProposedViewSize(width: colW, height: bounds.height))
            let targetH = min(bounds.height, measured.height)
            let y: CGFloat = switch alignment {
            case .center: bounds.minY + max(0, (bounds.height - targetH) / 2)
            case .bottom: bounds.maxY - targetH
            default: bounds.minY
            }
            subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: colW, height: bounds.height))
            x += colW + spacing
        }
    }
}

// MARK: - Responsive Auto-Reflowing Grid

/// Equal-width grid that automatically reduces its column count when narrowed so stat tiles & buttons never crush.
struct AdaptiveGridLayout: Layout {
    var maxColumns: Int
    var minCellWidth: CGFloat
    var spacing: CGFloat
    var centerCells: Bool = false

    private func columnCount(for width: CGFloat) -> Int {
        let cap = max(maxColumns, 1)
        guard width.isFinite, width > 0 else { return cap }
        let fit = Int(floor((width + spacing) / max(minCellWidth + spacing, 1)))
        return max(1, min(cap, fit))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? CGFloat(maxColumns) * minCellWidth + spacing * CGFloat(max(maxColumns - 1, 0))
        let cols = columnCount(for: width)
        let cellW = max(1, (width - spacing * CGFloat(cols - 1)) / CGFloat(cols))
        var totalHeight: CGFloat = 0
        var rowStart = 0
        while rowStart < subviews.count {
            let rowEnd = min(rowStart + cols, subviews.count)
            let rowH = (rowStart..<rowEnd).map { subviews[$0].sizeThatFits(ProposedViewSize(width: cellW, height: nil)).height }.max() ?? 0
            if rowStart > 0 { totalHeight += spacing }
            totalHeight += rowH
            rowStart = rowEnd
        }
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let cols = columnCount(for: bounds.width)
        let cellW = max(1, (bounds.width - spacing * CGFloat(cols - 1)) / CGFloat(cols))
        var y = bounds.minY
        var rowStart = 0
        while rowStart < subviews.count {
            let rowEnd = min(rowStart + cols, subviews.count)
            let rowH = (rowStart..<rowEnd).map { subviews[$0].sizeThatFits(ProposedViewSize(width: cellW, height: nil)).height }.max() ?? 0
            if rowStart > 0 { y += spacing }
            for col in 0..<(rowEnd - rowStart) {
                let x = bounds.minX + CGFloat(col) * (cellW + spacing)
                let sub = subviews[rowStart + col]
                if centerCells {
                    let measured = sub.sizeThatFits(ProposedViewSize(width: cellW, height: rowH))
                    let cx = x + max(0, (cellW - measured.width) / 2)
                    let cy = y + max(0, (rowH - measured.height) / 2)
                    sub.place(at: CGPoint(x: cx, y: cy), anchor: .topLeading, proposal: ProposedViewSize(width: cellW, height: rowH))
                } else {
                    sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: cellW, height: rowH))
                }
            }
            y += rowH
            rowStart = rowEnd
        }
    }
}

// MARK: - Elastic General Collection (for `section(..., { elastic: true })` and `column(..., { elastic: true })`)

/// Renders as many complete child blocks (meters, keyValues, account sections, etc.) as fit in the allocated height
/// and cleanly appends a `+N more` caption row purely in the `Layout` pass with zero `@State` mutation.
struct AdaptiveCollectionView: View {
    let nodes: [ViewNode]
    let spacing: CGFloat
    let context: RenderContext

    private var footerHeight: CGFloat {
        CGFloat(context.metrics.fontSize(role: "caption") + context.metrics.unit * 1.5)
    }

    var body: some View {
        let footerLabels = AdaptiveOverflowFit.footerLabels(itemCount: nodes.count)
        ElasticItemsLayout(itemCount: nodes.count, spacing: spacing, footerHeight: footerHeight) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { entry in
                NodeView(node: entry.element, context: context)
            }
            ForEach(Array(footerLabels.enumerated()), id: \.offset) { entry in
                HStack(spacing: context.metrics.unit) {
                    Text(entry.element)
                        .font(context.font(role: "caption", weight: "medium", mono: true))
                        .foregroundStyle(context.tertiary)
                    Spacer(minLength: 0)
                }
                .frame(height: footerHeight)
                .allowsHitTesting(false)
            }
        }
        .clipped()
    }
}

private struct ElasticItemsLayout: Layout {
    let itemCount: Int
    let spacing: CGFloat
    let footerHeight: CGFloat

    private func fit(proposal: ProposedViewSize, subviews: Subviews) -> (heights: [CGFloat], result: AdaptiveOverflowFit.Result) {
        let count = min(itemCount, subviews.count)
        guard count > 0 else {
            return ([], AdaptiveOverflowFit.Result(fittedCount: 0, hiddenCount: 0, activeFooterSlot: nil, totalHeight: 0))
        }
        let width = proposal.width
        let heights = (0..<count).map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let footerCount = max(0, subviews.count - count)
        let result = AdaptiveOverflowFit.fit(
            itemHeights: heights,
            spacing: spacing,
            maxHeight: proposal.height,
            showsFooter: footerCount > 0,
            footerHeight: footerHeight
        )
        return (heights, result)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = min(itemCount, subviews.count)
        let width = proposal.width ?? subviews.prefix(count).map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let (_, result) = fit(proposal: ProposedViewSize(width: width, height: proposal.height), subviews: subviews)
        return CGSize(width: width, height: result.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = min(itemCount, subviews.count)
        let footerCount = max(0, subviews.count - count)
        let (heights, result) = fit(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        let parked = CGPoint(x: bounds.minX, y: bounds.maxY + 200)
        var y = bounds.minY
        for index in 0..<count {
            if index < result.fittedCount {
                if index > 0 { y += spacing }
                let h = heights[index]
                subviews[index].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h
            } else {
                subviews[index].place(at: parked, proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
        let footerY = result.fittedCount > 0 ? y + spacing : y
        for slot in 0..<footerCount {
            if result.activeFooterSlot == slot {
                subviews[count + slot].place(at: CGPoint(x: bounds.minX, y: footerY), proposal: ProposedViewSize(width: bounds.width, height: footerHeight))
            } else {
                subviews[count + slot].place(at: parked, proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
    }
}

// MARK: - Elastic Zero-Scroll List

enum RailPosition: Equatable {
    case none
    case only
    case first
    case middle
    case last
}

struct ListCardHeader: View {
    let node: ViewNode
    let context: RenderContext
    let isCompact: Bool

    var body: some View {
        if let title = node.string("title"), !title.isEmpty {
            let padH = context.isNarrowWidget ? context.metrics.unit * 1.4 : (isCompact ? context.metrics.unit * 1.75 : context.metrics.tilePadding)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(context.font(role: "caption", weight: "bold"))
                    .foregroundStyle(context.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 3)
                if let trailing = node.string("trailing"), !trailing.isEmpty {
                    if let tone = node.tone("trailingTone") {
                        let color = context.color(tone, fallback: context.accent)
                        Text(trailing)
                            .font(context.font(role: "caption", weight: "semibold", mono: true))
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, context.metrics.unit * 1.1)
                            .padding(.vertical, 1)
                            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    } else {
                        Text(trailing)
                            .font(context.font(role: "caption", mono: true))
                            .foregroundStyle(context.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .padding(.horizontal, padH)
            .padding(.top, context.metrics.unit * (isCompact ? 1.45 : 2))
            .padding(.bottom, context.metrics.unit * 0.65)
        }
    }
}

/// Elastic zero-scroll list: fits as many whole item() rows as the widget height allows, auto-compacts subtitles when
/// tight, and shows "+N more" cleanly in a single pure `Layout` pass with zero `@State` mutation.
struct AdaptiveListView: View {
    let node: ViewNode
    let context: RenderContext

    private var showsSummary: Bool {
        node.string("overflow") != "none"
    }

    private var isCompact: Bool {
        node.bool("compact") || context.isCompactWidget
    }

    private var stripsSubtitle: Bool {
        node.bool("compact") || context.isShortWidget
    }

    private var hasRail: Bool {
        node.bool("rail")
    }

    private var footerHeight: CGFloat {
        CGFloat(context.metrics.fontSize(role: "caption") + context.metrics.unit * 2.5)
    }

    private func railPosition(at index: Int, total: Int) -> RailPosition {
        guard hasRail else { return .none }
        if total <= 1 { return .only }
        if index == 0 { return .first }
        if index == total - 1 { return .last }
        return .middle
    }

    var body: some View {
        let items = node.children
        let footerLabels = showsSummary ? AdaptiveOverflowFit.footerLabels(itemCount: items.count) : []
        let padH = context.isNarrowWidget ? context.metrics.unit * 1.4 : (isCompact ? context.metrics.unit * 1.75 : context.metrics.tilePadding)
        let railOffset: CGFloat = context.isNarrowWidget ? 12 : 15
        let sepLead = hasRail ? padH + railOffset : padH
        VStack(spacing: 0) {
            ListCardHeader(node: node, context: context, isCompact: isCompact)
            AdaptiveListLayout(itemCount: items.count, showsFooter: showsSummary && !footerLabels.isEmpty, footerHeight: footerHeight) {
                ForEach(Array(items.enumerated()), id: \.offset) { entry in
                    AdaptiveItemRow(
                        node: entry.element,
                        context: context,
                        compact: stripsSubtitle,
                        rail: railPosition(at: entry.offset, total: items.count)
                    )
                    .overlay(alignment: .top) {
                        if entry.offset > 0 {
                            Rectangle().fill(context.separator).frame(height: 1).padding(.leading, sepLead)
                        }
                    }
                }
                ForEach(Array(footerLabels.enumerated()), id: \.offset) { entry in
                    HStack(spacing: context.metrics.unit) {
                        Text(entry.element)
                            .font(context.font(role: "caption", weight: "medium", mono: true))
                            .foregroundStyle(context.tertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, padH)
                    .frame(height: footerHeight)
                    .overlay(alignment: .top) {
                        Rectangle().fill(context.separator).frame(height: 1).padding(.leading, padH)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .background(context.fill, in: context.tileShape)
        .clipShape(context.tileShape)
    }
}

private struct AdaptiveItemRow: View {
    let node: ViewNode
    let context: RenderContext
    let compact: Bool
    var rail: RailPosition = .none

    var body: some View {
        ItemRow(node: compact ? strippedSubtitle : node, context: context, compactOverride: compact, rail: rail)
    }

    private var strippedSubtitle: ViewNode {
        var copy = node
        if compact { copy.props["subtitle"] = nil }
        return copy
    }
}

private struct AdaptiveListLayout: Layout {
    let itemCount: Int
    let showsFooter: Bool
    let footerHeight: CGFloat

    private func fit(proposal: ProposedViewSize, subviews: Subviews) -> (heights: [CGFloat], result: AdaptiveOverflowFit.Result) {
        let rowCount = min(itemCount, subviews.count)
        guard rowCount > 0 else {
            return ([], AdaptiveOverflowFit.Result(fittedCount: 0, hiddenCount: 0, activeFooterSlot: nil, totalHeight: 0))
        }
        let width = proposal.width
        let rowHeights = (0..<rowCount).map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let footerCount = max(0, subviews.count - rowCount)
        let result = AdaptiveOverflowFit.fit(
            itemHeights: rowHeights,
            spacing: 0,
            maxHeight: proposal.height,
            showsFooter: showsFooter && footerCount > 0,
            footerHeight: footerHeight
        )
        return (rowHeights, result)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rowCount = min(itemCount, subviews.count)
        let width = proposal.width ?? subviews.prefix(rowCount).map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let (_, result) = fit(proposal: ProposedViewSize(width: width, height: proposal.height), subviews: subviews)
        return CGSize(width: width, height: result.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rowCount = min(itemCount, subviews.count)
        let footerCount = max(0, subviews.count - rowCount)
        let (rowHeights, result) = fit(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        let parked = CGPoint(x: bounds.minX, y: bounds.maxY + 200)
        var y = bounds.minY
        for index in 0..<rowCount {
            if index < result.fittedCount {
                let h = rowHeights[index]
                subviews[index].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h
            } else {
                subviews[index].place(at: parked, proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
        for slot in 0..<footerCount {
            if result.activeFooterSlot == slot {
                subviews[rowCount + slot].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: footerHeight))
            } else {
                subviews[rowCount + slot].place(at: parked, proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
    }
}
