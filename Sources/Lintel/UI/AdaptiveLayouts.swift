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

struct NaturalContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

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

/// Zero-scroll vertical stack for freeform widgets: fixed blocks take natural height, elastic collections & lists
/// compress row-by-row first, flexible charts/apps absorb remaining height, and lower-priority sections yield cleanly.
struct AdaptiveStackLayout: Layout {
    var spacing: CGFloat
    var alignment: HorizontalAlignment

    private struct Plan {
        var visible: [Bool]
        var heights: [CGFloat]
        var totalHeight: CGFloat
    }

    private func plan(proposal: ProposedViewSize, subviews: Subviews) -> Plan {
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
        let priorities = subviews.map { $0[BlockPriorityKey.self] }
        let flexes = subviews.map { $0[BlockFlexKey.self] }

        let ideals: [CGFloat] = (0..<count).map { index in
            switch flexes[index] {
            case .fixed:
                return subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            case .flexible(_, let caps):
                return caps ? subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height : .greatestFiniteMagnitude
            }
        }

        let bases: [CGFloat] = (0..<count).map { index in
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let computed = plan(proposal: ProposedViewSize(width: width, height: proposal.height), subviews: subviews)
        return CGSize(width: width, height: computed.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let computed = plan(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
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
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: h))
            let x: CGFloat = switch alignment {
            case .center: bounds.minX + max(0, (bounds.width - size.width) / 2)
            case .trailing: bounds.maxX - min(bounds.width, size.width)
            default: bounds.minX
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
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

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
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
/// and cleanly appends a `+N more` caption row instead of dropping the whole section or leaving blank voids.
struct AdaptiveCollectionView: View {
    let nodes: [ViewNode]
    let spacing: CGFloat
    let context: RenderContext
    @State private var hiddenCount = 0

    private var footerHeight: CGFloat {
        CGFloat(context.metrics.fontSize(role: "caption") + context.metrics.unit * 1.5)
    }

    var body: some View {
        ElasticItemsLayout(itemCount: nodes.count, spacing: spacing, footerHeight: footerHeight, onHiddenCount: { count in
            if count != hiddenCount {
                DispatchQueue.main.async { hiddenCount = count }
            }
        }) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { entry in
                NodeView(node: entry.element, context: context)
            }
            HStack(spacing: context.metrics.unit) {
                Text(hiddenCount > 0 ? "+\(hiddenCount) more" : "")
                    .font(context.font(role: "caption", weight: "medium", mono: true))
                    .foregroundStyle(context.tertiary)
                Spacer(minLength: 0)
            }
            .frame(height: footerHeight)
        }
    }
}

private struct ElasticItemsLayout: Layout {
    let itemCount: Int
    let spacing: CGFloat
    let footerHeight: CGFloat
    let onHiddenCount: (Int) -> Void

    private func fit(proposal: ProposedViewSize, subviews: Subviews) -> (heights: [CGFloat], fitted: Int, totalHeight: CGFloat) {
        let count = min(itemCount, max(0, subviews.count - 1))
        guard count > 0 else { return ([], 0, 0) }
        let width = proposal.width
        let heights = (0..<count).map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let sumAll = heights.reduce(0, +) + spacing * CGFloat(max(count - 1, 0))

        guard let maxH = proposal.height, maxH.isFinite, sumAll > maxH + 0.5 else {
            return (heights, count, sumAll)
        }

        let budget = max(0, maxH - footerHeight - spacing)
        var used: CGFloat = 0
        var fitted = 0
        for height in heights {
            let next = used + (fitted > 0 ? spacing : 0) + height
            if next <= budget + 0.5 || fitted == 0 {
                used = next
                fitted += 1
            } else {
                break
            }
        }
        let showMore = fitted < count
        let total = used + (showMore ? spacing + footerHeight : 0)
        return (heights, fitted, maxH <= 0.5 ? total : min(total, maxH))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.prefix(itemCount).map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let result = fit(proposal: ProposedViewSize(width: width, height: proposal.height), subviews: subviews)
        return CGSize(width: width, height: result.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = min(itemCount, max(0, subviews.count - 1))
        let result = fit(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        let hidden = max(0, count - result.fitted)
        onHiddenCount(hidden)
        var y = bounds.minY
        for index in 0..<count {
            if index < result.fitted {
                if index > 0 { y += spacing }
                let h = result.heights[index]
                subviews[index].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h
            } else {
                subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.maxY + 200), proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
        if subviews.count > count {
            if hidden > 0 {
                if result.fitted > 0 { y += spacing }
                subviews[count].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: footerHeight))
            } else {
                subviews[count].place(at: CGPoint(x: bounds.minX, y: bounds.maxY + 200), proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
    }
}

// MARK: - Elastic Zero-Scroll List

/// Elastic zero-scroll list: fits as many whole item() rows as the widget height allows, auto-compacts subtitles when
/// tight, and shows "+N more" cleanly instead of scrolling or clipping.
struct AdaptiveListView: View {
    let node: ViewNode
    let context: RenderContext
    @State private var hiddenCount = 0

    private var showsSummary: Bool {
        node.string("overflow") != "none"
    }

    private var isCompact: Bool {
        node.bool("compact") || context.isCompactWidget
    }

    private var footerHeight: CGFloat {
        CGFloat(context.metrics.fontSize(role: "caption") + context.metrics.unit * 2.5)
    }

    var body: some View {
        let items = node.children
        AdaptiveListLayout(itemCount: items.count, showsFooter: showsSummary, footerHeight: footerHeight, onHiddenCount: { count in
            if count != hiddenCount {
                DispatchQueue.main.async { hiddenCount = count }
            }
        }) {
            ForEach(Array(items.enumerated()), id: \.offset) { entry in
                VStack(spacing: 0) {
                    if entry.offset > 0 {
                        Rectangle().fill(context.separator).frame(height: 1).padding(.leading, context.metrics.tilePadding)
                    }
                    AdaptiveItemRow(node: entry.element, context: context, compact: isCompact)
                }
            }
            HStack(spacing: context.metrics.unit) {
                Text(hiddenCount > 0 ? "+\(hiddenCount) more" : "")
                    .font(context.font(role: "caption", weight: "medium", mono: true))
                    .foregroundStyle(context.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, isCompact ? context.metrics.unit * 2 : context.metrics.tilePadding)
            .frame(height: footerHeight)
            .overlay(alignment: .top) {
                Rectangle().fill(context.separator).frame(height: 1).padding(.leading, context.metrics.tilePadding)
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

    var body: some View {
        NodeView(node: compact ? strippedSubtitle : node, context: context)
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
    let onHiddenCount: (Int) -> Void

    private func fit(proposal: ProposedViewSize, subviews: Subviews) -> (heights: [CGFloat], fitted: Int, totalHeight: CGFloat) {
        let rowCount = min(itemCount, max(0, subviews.count - 1))
        guard rowCount > 0 else { return ([], 0, 0) }
        let width = proposal.width
        let rowHeights = (0..<rowCount).map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let sumAll = rowHeights.reduce(0, +)

        guard let maxH = proposal.height, maxH.isFinite, sumAll > maxH + 0.5 else {
            return (rowHeights, rowCount, sumAll)
        }

        let budget = showsFooter ? max(0, maxH - footerHeight) : maxH
        var used: CGFloat = 0
        var fitted = 0
        for height in rowHeights {
            if used + height <= budget + 0.5 || fitted == 0 {
                used += height
                fitted += 1
            } else {
                break
            }
        }
        let showMore = showsFooter && fitted < rowCount
        let total = used + (showMore ? footerHeight : 0)
        return (rowHeights, fitted, maxH <= 0.5 ? total : min(total, maxH))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.prefix(itemCount).map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let result = fit(proposal: ProposedViewSize(width: width, height: proposal.height), subviews: subviews)
        return CGSize(width: width, height: result.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rowCount = min(itemCount, max(0, subviews.count - 1))
        let result = fit(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        let hidden = max(0, rowCount - result.fitted)
        onHiddenCount(hidden)
        var y = bounds.minY
        for index in 0..<rowCount {
            if index < result.fitted {
                let h = result.heights[index]
                subviews[index].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h
            } else {
                subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.maxY + 200), proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
        if subviews.count > rowCount {
            let showMore = showsFooter && hidden > 0
            if showMore {
                subviews[rowCount].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: footerHeight))
            } else {
                subviews[rowCount].place(at: CGPoint(x: bounds.minX, y: bounds.maxY + 200), proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
    }
}
