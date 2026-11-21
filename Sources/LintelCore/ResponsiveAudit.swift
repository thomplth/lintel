import CoreGraphics
import Foundation

/// Automated multi-viewport design-system check run on every widget tree before a module is accepted.
/// Ensures a module survives tiny floors, narrow sidebars, slim ribbons, and spacious dashboards cleanly.
public enum ResponsiveAudit {
    public struct Report: Equatable, Sendable {
        public var viewport: WidgetViewport
        public var essentialVisible: Bool
        public var estimatedMinWidth: CGFloat
        public var estimatedNaturalHeight: CGFloat
        public var hasFlexibleContent: Bool
    }

    public static func check(_ root: ViewNode, metrics: Metrics = Metrics(Theme.preset("glass")!)) -> [ViewProblem] {
        var problems: [ViewProblem] = []
        let children = (root.component == .column && root.props.isEmpty) ? root.children : [root]

        // 1. At least one essential top-level block must survive even at the tiny floor viewport.
        let hasEssential = children.contains { node in
            let priority = node.string("priority") ?? "essential"
            return priority == "essential" && node.component != .spacer && node.component != .divider
        }
        if !hasEssential {
            problems.append(.error("widget() needs at least one essential block (without priority: 'supporting' or 'detail') so it still shows content at small sizes"))
        }

        // 2. Check narrow sidebar survivability (216pt scaled): static non-wrapping rows with too many items will clip.
        let sidebar = WidgetViewport.canonicalMatrix(for: metrics).first { $0.id == "sidebar" }!
        let sidebarInnerWidth = sidebar.size.width - CGFloat(metrics.widgetPadding * 2)
        walk(root) { node in
            if node.component == .row {
                let est = estimateRowMinWidth(node, metrics: metrics)
                if est > sidebarInnerWidth * 1.15 && node.children.count >= 4 {
                    problems.append(.warning("a row with \(node.children.count) items may be too wide for a narrow sidebar (\(Int(sidebar.size.width))pt); use grid() or column() so items wrap cleanly"))
                }
            }
            if node.component == .grid, let cols = node.number("columns"), cols > 4 {
                let allSmallAtoms = node.children.allSatisfy { [.text, .badge, .dot, .icon].contains($0.component) }
                if !allSmallAtoms {
                    problems.append(.warning("grid(\(Int(cols))) with rich blocks will wrap heavily when narrow; keep grids to 2–3 columns"))
                }
            }
        }

        return problems
    }

    /// Evaluates every viewport in the canonical 6-shape stress matrix for diagnostics & `Lintel trial`.
    public static func auditMatrix(_ root: ViewNode, metrics: Metrics = Metrics(Theme.preset("glass")!)) -> [Report] {
        let children = (root.component == .column && root.props.isEmpty) ? root.children : [root]
        let hasEssential = children.contains { ($0.string("priority") ?? "essential") == "essential" }
        let hasFlex = root.descendants.contains { [.chart, .list, .app, .web, .image].contains($0.component) || $0.bool("elastic") }
        let minW = estimateMinWidth(root, metrics: metrics)
        return WidgetViewport.canonicalMatrix(for: metrics).map { viewport in
            let innerW = max(viewport.size.width - CGFloat(metrics.widgetPadding * 2), 60)
            let estH = estimateNaturalHeight(root, width: innerW, metrics: metrics) + CGFloat(metrics.widgetPadding * 2)
            return Report(
                viewport: viewport,
                essentialVisible: hasEssential,
                estimatedMinWidth: minW,
                estimatedNaturalHeight: estH,
                hasFlexibleContent: hasFlex
            )
        }
    }

    private static func estimateRowMinWidth(_ row: ViewNode, metrics: Metrics) -> CGFloat {
        let gap = CGFloat(metrics.spacing(row.string("spacing")))
        let items = row.children.filter { $0.component != .spacer }
        let sum = items.reduce(CGFloat(0)) { acc, child in
            acc + estimateMinWidth(child, metrics: metrics)
        }
        return sum + gap * CGFloat(max(items.count - 1, 0))
    }

    private static func estimateMinWidth(_ node: ViewNode, metrics: Metrics) -> CGFloat {
        let charW = CGFloat(metrics.fontSize(role: "label")) * 0.56
        switch node.component {
        case .text:
            return min(CGFloat((node.string("value") ?? "").count) * charW, 140)
        case .badge:
            return CGFloat(max((node.string("value") ?? "").count, 2)) * charW + 16
        case .icon, .dot, .ring:
            return CGFloat(metrics.theme.fontSize * 1.4)
        case .gauge:
            return CGFloat(metrics.theme.fontSize * 2.2)
        case .sparkline:
            return CGFloat(metrics.theme.fontSize * 3.4)
        case .button:
            return max(56, CGFloat((node.string("label") ?? "").count) * charW + 28)
        case .stat:
            return CGFloat((96 * metrics.widgetScale).rounded())
        case .row:
            return estimateRowMinWidth(node, metrics: metrics)
        case .column, .section, .split:
            return node.children.map { estimateMinWidth($0, metrics: metrics) }.max() ?? 80
        default:
            return 80
        }
    }

    private static func estimateNaturalHeight(_ node: ViewNode, width: CGFloat, metrics: Metrics) -> CGFloat {
        let gap = CGFloat(metrics.spacing(node.string("spacing")))
        let lineH = CGFloat(metrics.fontSize(role: "label") * 1.45)
        switch node.component {
        case .column:
            let hs = node.children.map { estimateNaturalHeight($0, width: width, metrics: metrics) }
            return hs.reduce(0, +) + gap * CGFloat(max(hs.count - 1, 0))
        case .split:
            if width < metrics.splitStackThreshold {
                let hs = node.children.map { estimateNaturalHeight($0, width: width, metrics: metrics) }
                return hs.reduce(0, +) + gap * CGFloat(max(hs.count - 1, 0))
            } else {
                let colW = max(width / CGFloat(max(node.children.count, 1)) - gap, 60)
                return node.children.map { estimateNaturalHeight($0, width: colW, metrics: metrics) }.max() ?? 0
            }
        case .section:
            let header = (node.string("title")?.isEmpty == false) ? CGFloat(metrics.fontSize(role: "caption") + metrics.unit * 2) : 0
            let hs = node.children.map { estimateNaturalHeight($0, width: width, metrics: metrics) }
            return header + hs.reduce(0, +) + gap * CGFloat(max(hs.count - 1, 0))
        case .grid:
            let maxCols = max(Int(node.number("columns") ?? 2), 1)
            let minCellW: CGFloat = node.children.allSatisfy { [.text, .badge, .dot, .icon].contains($0.component) } ? 22 : CGFloat(98 * metrics.widgetScale)
            let cols = max(1, min(maxCols, Int(floor((width + gap) / (minCellW + gap)))))
            let rows = Int(ceil(Double(node.children.count) / Double(cols)))
            let cellH: CGFloat = node.children.first?.component == .stat ? CGFloat(64 * metrics.widgetScale) : (lineH + 12)
            return CGFloat(rows) * cellH + gap * CGFloat(max(rows - 1, 0))
        case .stat:
            return CGFloat(64 * metrics.widgetScale)
        case .meter, .progress:
            return lineH + 14
        case .list:
            let rowH = lineH + CGFloat(metrics.unit * 4)
            return CGFloat(max(node.children.count, 1)) * rowH
        case .chart:
            return 90
        case .app, .web, .image:
            return 140
        case .empty:
            return 100
        case .divider:
            return 1
        default:
            return lineH + CGFloat(metrics.unit * 2)
        }
    }

    private static func walk(_ node: ViewNode, _ visit: (ViewNode) -> Void) {
        visit(node)
        for child in node.children { walk(child, visit) }
    }
}
