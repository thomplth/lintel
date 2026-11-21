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

    var containsFlexibleBlock: Bool {
        switch component {
        case .chart, .list, .app, .web, .image, .split, .spacer:
            return true
        case .section, .column:
            return children.contains(where: \.containsFlexibleBlock)
        default:
            return false
        }
    }

    var layoutFlex: BlockFlex {
        switch component {
        case .chart:
            return .flexible(minHeight: 46, capsAtIdeal: false)
        case .app, .web, .image:
            return .flexible(minHeight: 72, capsAtIdeal: false)
        case .list:
            return .flexible(minHeight: 36, capsAtIdeal: true)
        case .split:
            return .flexible(minHeight: 54, capsAtIdeal: false)
        case .spacer:
            return .flexible(minHeight: 0, capsAtIdeal: false)
        case .section, .column:
            if containsFlexibleBlock {
                let capsAtIdeal = !descendants.contains { [.chart, .app, .web, .split, .spacer].contains($0.component) }
                return .flexible(minHeight: 54, capsAtIdeal: capsAtIdeal)
            }
            return .fixed
        default:
            return .fixed
        }
    }
}

/// Zero-scroll vertical stack for widgets: fixed blocks take natural height, flexible blocks (charts, lists, mini-apps,
/// splits) share the remaining space, and lower-priority sections yield cleanly instead of overflowing.
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

        // Unbounded vertical proposal: lay out naturally.
        guard let maxHeight = proposal.height, maxHeight.isFinite else {
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
            let total = heights.reduce(0, +) + spacing * CGFloat(max(count - 1, 0))
            return Plan(visible: Array(repeating: true, count: count), heights: heights, totalHeight: total)
        }

        var visible = Array(repeating: true, count: count)
        let priorities = subviews.map { $0[BlockPriorityKey.self] }
        let flexes = subviews.map { $0[BlockFlexKey.self] }

        func measureBase(_ index: Int) -> CGFloat {
            switch flexes[index] {
            case .fixed:
                return subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            case .flexible(let minH, let capsAtIdeal):
                if capsAtIdeal {
                    let ideal = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                    return min(minH, ideal)
                }
                return minH
            }
        }

        let bases = (0..<count).map(measureBase)
        let ideals = (0..<count).map { index -> CGFloat in
            switch flexes[index] {
            case .fixed: return bases[index]
            case .flexible(_, let caps): return caps ? subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height : .greatestFiniteMagnitude
            }
        }

        func baseTotal() -> CGFloat {
            let active = (0..<count).filter { visible[$0] }
            guard !active.isEmpty else { return 0 }
            return active.reduce(0) { $0 + bases[$1] } + spacing * CGFloat(active.count - 1)
        }

        // Drop detail (2) then supporting (1) blocks if base requirements exceed the widget height.
        for dropLevel in [2, 1] {
            if baseTotal() <= maxHeight + 0.5 { break }
            for index in (0..<count).reversed() where visible[index] && priorities[index] >= dropLevel {
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
            switch flexes[index] {
            case .fixed:
                heights[index] = bases[index]
                fixedUsed += bases[index]
            case .flexible:
                heights[index] = bases[index]
                fixedUsed += bases[index]
                flexIndices.append(index)
            }
        }

        // Distribute remaining height across flexible blocks; blocks that cap at ideal (like short lists) give surplus to charts/apps.
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

        let total = active.reduce(0) { $0 + heights[$1] } + spacing * CGFloat(active.count - 1)
        return Plan(visible: visible, heights: heights, totalHeight: min(total, maxHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let computed = plan(proposal: ProposedViewSize(width: width, height: proposal.height), subviews: subviews)
        return CGSize(width: width, height: proposal.height ?? computed.totalHeight)
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

/// Proportional multi-column horizontal layout for wide and large widgets.
struct SplitLayout: Layout {
    var weights: [Double]
    var spacing: CGFloat
    var alignment: VerticalAlignment

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
        let totalGap = spacing * CGFloat(max(subviews.count - 1, 0))
        let width = proposal.width ?? (subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +) + totalGap)
        let fractions = normalizedWeights(count: subviews.count)
        let contentWidth = max(0, width - totalGap)
        let maxHeight = subviews.indices.map { index in
            subviews[index].sizeThatFits(ProposedViewSize(width: contentWidth * fractions[index], height: proposal.height)).height
        }.max() ?? 0
        return CGSize(width: width, height: proposal.height ?? maxHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
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

/// Elastic zero-scroll list: fits as many whole item() rows as the widget height allows and shows "+N more" cleanly.
struct AdaptiveListView: View {
    let node: ViewNode
    let context: RenderContext
    @State private var containerHeight: CGFloat = 0
    @State private var measuredRowHeight: CGFloat = 0

    private var showsSummary: Bool {
        node.string("overflow") != "none"
    }

    private var isCompact: Bool {
        node.bool("compact") || context.isCompactWidget
    }

    private var footerHeight: CGFloat {
        CGFloat(context.metrics.fontSize(role: "caption") + context.metrics.unit * 2.5)
    }

    private var hiddenCount: Int {
        let total = node.children.count
        guard total > 0, measuredRowHeight > 1, containerHeight > 1 else { return 0 }
        let fitted = Self.fitCount(
            total: total, availableHeight: containerHeight,
            rowHeight: measuredRowHeight, showsFooter: showsSummary, footerHeight: footerHeight
        )
        return max(0, total - fitted)
    }

    var body: some View {
        let items = node.children
        AdaptiveListLayout(itemCount: items.count, showsFooter: showsSummary, footerHeight: footerHeight) {
            ForEach(Array(items.enumerated()), id: \.offset) { entry in
                VStack(spacing: 0) {
                    if entry.offset > 0 {
                        Rectangle().fill(context.separator).frame(height: 1).padding(.leading, context.metrics.tilePadding)
                    }
                    AdaptiveItemRow(node: entry.element, context: context, compact: isCompact)
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                    if entry.offset == 0 && h > 1 && abs(h - measuredRowHeight) > 0.5 {
                        measuredRowHeight = h
                    }
                }
            }
            HStack(spacing: context.metrics.unit) {
                Text(hiddenCount > 0 ? "+\(hiddenCount) more" : "More")
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
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
            if abs(h - containerHeight) > 0.5 { containerHeight = h }
        }
        .background(context.fill, in: context.tileShape)
        .clipShape(context.tileShape)
    }

    static func fitCount(total: Int, availableHeight: CGFloat, rowHeight: CGFloat, showsFooter: Bool, footerHeight: CGFloat) -> Int {
        guard total > 0, rowHeight > 1, availableHeight > 1 else { return total }
        let allFit = Int(floor((availableHeight + 1) / rowHeight))
        if allFit >= total { return total }
        guard showsFooter else { return max(1, allFit) }
        let withFooter = Int(floor((availableHeight - footerHeight + 1) / rowHeight))
        return max(1, min(total - 1, withFooter))
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
        return (rowHeights, fitted, min(total, maxH))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.prefix(itemCount).map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let result = fit(proposal: ProposedViewSize(width: width, height: proposal.height), subviews: subviews)
        return CGSize(width: width, height: result.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rowCount = min(itemCount, max(0, subviews.count - 1))
        let result = fit(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
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
            let showMore = showsFooter && result.fitted < rowCount
            if showMore {
                subviews[rowCount].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: footerHeight))
            } else {
                subviews[rowCount].place(at: CGPoint(x: bounds.minX, y: bounds.maxY + 200), proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
    }
}
