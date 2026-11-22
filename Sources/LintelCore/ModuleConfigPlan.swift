import CoreGraphics
import Foundation

/// A single native macOS settings card derived from a module's `configure(host)` view tree.
public struct ModuleConfigSection: Equatable, Sendable {
    public var title: String?
    public var trailing: String?
    public var items: [ViewNode]
    public var isActionRow: Bool

    public init(title: String? = nil, trailing: String? = nil, items: [ViewNode], isActionRow: Bool = false) {
        self.title = title
        self.trailing = trailing
        self.items = items
        self.isActionRow = isActionRow
    }
}

/// Pure transformation of a module's `configure(host)` tree into native Lintel window cards and divider rules.
public enum ModuleConfigPlan {
    public static func sections(from root: ViewNode) -> [ModuleConfigSection] {
        let topLevel: [ViewNode] = (root.component == .column && root.props.isEmpty) ? root.children : [root]
        var result: [ModuleConfigSection] = []
        var loose: [ViewNode] = []

        func flushLoose() {
            guard !loose.isEmpty else { return }
            if loose.allSatisfy({ $0.component == .button }) {
                result.append(ModuleConfigSection(title: nil, trailing: nil, items: loose, isActionRow: true))
            } else {
                result.append(ModuleConfigSection(title: "Configuration", trailing: nil, items: loose, isActionRow: false))
            }
            loose = []
        }

        for node in topLevel {
            if node.component == .section {
                flushLoose()
                result.append(ModuleConfigSection(
                    title: node.string("title"),
                    trailing: node.string("trailing"),
                    items: node.children,
                    isActionRow: false
                ))
            } else {
                loose.append(node)
            }
        }
        flushLoose()
        return result
    }

    /// True when a hairline divider belongs between two adjacent items inside a native settings card.
    public static func needsDivider(between previous: ViewNode, and next: ViewNode) -> Bool {
        if previous.component == .divider || next.component == .divider { return false }
        if next.component == .note, isPlainHelperTone(next.string("tone")) { return false }
        return true
    }

    private static func isPlainHelperTone(_ tone: String?) -> Bool {
        guard let tone else { return true }
        return tone == "secondary" || tone == "tertiary"
    }
}

/// Pure sizing math for the module inspector's live preview stage.
public enum ModulePreviewMetrics {
    /// Resolves the active expanded size for a module: active desktop widget box > remembered peek size > default shape.
    public static func resolvedBox(
        widgetBox: WidgetBox?,
        panelSize: WidgetBox?,
        defaultShape: WidgetShape,
        metrics: Metrics
    ) -> WidgetBox {
        widgetBox ?? panelSize ?? metrics.defaultWidgetBox(for: defaultShape)
    }

    /// Computes a uniform scale factor <= 1 so an expanded preview card fits comfortably inside the stage bounds.
    public static func fitScale(box: CGSize, in available: CGSize) -> CGFloat {
        guard box.width > 0, box.height > 0, available.width > 0, available.height > 0 else { return 1 }
        let scaleW = available.width / box.width
        let scaleH = available.height / box.height
        return min(1, max(min(scaleW, scaleH), 0.35))
    }
}
