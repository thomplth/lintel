import Foundation

/// The quality bar every module passes before it is installed. Errors go back to the model for repair.
public enum DesignLint {
    public struct Limits: Sendable {
        public var chipLeaves = 8
        public var chipTextLength = 32
        public var chipTotalTextLength = 56
        public var chipSparklinePoints = 80
        public var panelNodes = 400
        public var listItems = 30
        public var liveSurfaces = 2
        public var appHTMLBytes = 200_000

        public init() {}
    }

    public static func check(
        chip: ViewNode?, panel: ViewNode?, manifest: ModuleManifest, actions: [String],
        limits: Limits = Limits(), symbolExists: (String) -> Bool
    ) -> [ViewProblem] {
        var problems: [ViewProblem] = []
        if let chip {
            checkChip(chip, limits: limits, problems: &problems)
            checkShared(chip, surface: "the bar item", manifest: manifest, actions: actions, symbolExists: symbolExists, problems: &problems)
        } else {
            problems.append(.error("render() returned nothing; the bar item needs at least an icon or a short text"))
        }
        if let panel {
            checkPanel(panel, limits: limits, problems: &problems)
            checkShared(panel, surface: "the panel", manifest: manifest, actions: actions, symbolExists: symbolExists, problems: &problems)
        }
        if !symbolExists(manifest.icon) {
            problems.append(.error("meta.icon '\(manifest.icon)' is not an SF Symbol name"))
        }
        if manifest.title.count > 24 {
            problems.append(.warning("meta.title is longer than 24 characters and will be cut off in settings"))
        }
        return problems
    }

    /// Validates a module's responsive widget view (and runs the 6-viewport stress audit).
    public static func checkWidget(
        _ node: ViewNode, manifest: ModuleManifest, actions: [String],
        metrics: Metrics = Metrics(Theme.preset("glass")!),
        limits: Limits = Limits(), symbolExists: (String) -> Bool
    ) -> [ViewProblem] {
        var problems: [ViewProblem] = []
        checkPanel(node, limits: limits, problems: &problems)
        checkShared(node, surface: "the widget", manifest: manifest, actions: actions, symbolExists: symbolExists, problems: &problems)
        problems += ResponsiveAudit.check(node, metrics: metrics)
        return problems
    }

    /// Validates a module's configure view (rendered in the Lintel window; controls only, no tiny-floor audit).
    public static func checkConfigure(
        _ node: ViewNode, manifest: ModuleManifest, actions: [String],
        limits: Limits = Limits(), symbolExists: (String) -> Bool
    ) -> [ViewProblem] {
        var problems: [ViewProblem] = []
        checkPanel(node, limits: limits, problems: &problems)
        checkShared(node, surface: "the configure view", manifest: manifest, actions: actions, symbolExists: symbolExists, problems: &problems)
        return problems
    }

    private static func checkChip(_ chip: ViewNode, limits: Limits, problems: inout [ViewProblem]) {
        let nodes = chip.descendants
        for node in nodes where !Catalog.chipComponents.contains(node.component) {
            problems.append(.error("\(node.component.rawValue) cannot go in the bar item; return it from panel() instead"))
        }
        let leaves = nodes.filter { $0.component != .row && $0.component != .spacer }
        if leaves.isEmpty {
            problems.append(.error("the bar item is empty; it needs at least an icon or a short text"))
        }
        if leaves.count > limits.chipLeaves {
            problems.append(.error("the bar item has \(leaves.count) elements; the limit is \(limits.chipLeaves). Keep one or two key values in the bar and move the rest to panel()"))
        }
        let texts = nodes.filter { $0.component == .text || $0.component == .badge }.compactMap { $0.string("value") }
        for text in texts where text.count > limits.chipTextLength {
            problems.append(.error("bar item text \"\(text.prefix(20))…\" is \(text.count) characters; shorten or truncate it to \(limits.chipTextLength)"))
        }
        if texts.reduce(0, { $0 + $1.count }) > limits.chipTotalTextLength {
            problems.append(.error("the bar item shows more than \(limits.chipTotalTextLength) characters in total; keep the essentials and move detail to panel()"))
        }
        for node in nodes where node.component == .text {
            if let role = node.string("role"), role == "display" || role == "title" {
                problems.append(.error("text role '\(role)' is for panels; bar item text uses 'value', 'label' or 'caption'"))
            }
            if (node.number("lines") ?? 1) > 1 {
                problems.append(.error("bar item text is always one line; remove lines"))
            }
        }
        for node in nodes where node.component == .sparkline && node.numbers("values").count > limits.chipSparklinePoints {
            problems.append(.error("a bar item sparkline takes at most \(limits.chipSparklinePoints) points"))
        }
        if depth(of: chip) > 3 {
            problems.append(.error("rows in the bar item are nested too deeply; use a single row"))
        }
    }

    private static func checkPanel(_ panel: ViewNode, limits: Limits, problems: inout [ViewProblem]) {
        let nodes = panel.descendants
        if nodes.count <= 1, panel.children.isEmpty, panel.component == .column {
            problems.append(.error("panel() returned an empty view; use empty(icon, title) when there is nothing to show"))
        }
        if nodes.count > limits.panelNodes {
            problems.append(.error("the panel has \(nodes.count) elements; the limit is \(limits.panelNodes). Show a summary and the top few entries"))
        }
        if nodes.filter({ $0.component == .button && $0.string("style") == "primary" }).count > 1 {
            problems.append(.warning("a panel should have at most one primary button"))
        }
        if nodes.filter({ $0.component == .web || $0.component == .app }).count > limits.liveSurfaces {
            problems.append(.error("a panel can hold at most \(limits.liveSurfaces) web or app views"))
        }
        walk(panel, parent: nil) { node, parent in
            switch node.component {
            case .list:
                if node.children.count > limits.listItems {
                    problems.append(.error("a list has \(node.children.count) rows; show at most \(limits.listItems) and summarise the rest in a note"))
                }
                if node.children.contains(where: { $0.component != .item }) {
                    problems.append(.error("list() takes only item() rows"))
                }
            case .item:
                if parent?.component != .list { problems.append(.error("item() must be inside list()")) }
            case .section:
                if parent?.component == .section { problems.append(.error("sections cannot be nested")) }
                if node.children.isEmpty { problems.append(.warning("a section is empty")) }
            case .grid:
                let columns = node.number("columns") ?? 0
                if columns < 1 || columns > 7 { problems.append(.error("grid columns must be 1 to 7")) }
            case .split:
                if node.children.count < 2 || node.children.count > 3 {
                    problems.append(.error("split takes 2 to 3 children; it has \(node.children.count)"))
                }
            case .segmented:
                let count = node.strings("options").count
                if count < 2 || count > 5 { problems.append(.error("segmented takes 2 to 5 options; it has \(count)")) }
            case .slider:
                if let low = node.number("min"), let high = node.number("max"), low >= high {
                    problems.append(.error("slider min must be below max"))
                }
            case .chart:
                if node.series.contains(where: { $0.values.count < 2 }) {
                    problems.append(.warning("a chart series has fewer than two points and will render as a placeholder"))
                }
                if node.series.count > 4 { problems.append(.error("a chart takes at most 4 series")) }
            case .text:
                if let lines = node.number("lines"), lines > 8 { problems.append(.warning("text lines above 8 are clipped")) }
            case .app:
                if (node.string("html") ?? "").utf8.count > limits.appHTMLBytes {
                    problems.append(.error("app html is larger than \(limits.appHTMLBytes / 1000) kB"))
                }
            default:
                break
            }
        }
    }

    private static func checkShared(
        _ root: ViewNode, surface: String, manifest: ModuleManifest, actions: [String],
        symbolExists: (String) -> Bool, problems: inout [ViewProblem]
    ) {
        for node in root.descendants {
            let spec = Catalog.spec(node.component)
            for prop in spec.props {
                guard let value = node.string(prop.name) else { continue }
                switch prop.type {
                case .symbol:
                    if !symbolExists(value), SVGIcon.parse(value) == nil {
                        problems.append(.error("no SF Symbol is named '\(value)' (in \(node.component.rawValue), \(surface))"))
                    }
                case .action:
                    if !actions.contains(value) {
                        problems.append(.error("\(node.component.rawValue) refers to action '\(value)', but the module's actions are: \(actions.isEmpty ? "none" : actions.joined(separator: ", "))"))
                    }
                case .url:
                    guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), url.host() != nil else {
                        problems.append(.error("'\(value.prefix(60))' is not a valid URL"))
                        continue
                    }
                    let opensExternally = node.component == .item || node.component == .button
                    if opensExternally {
                        if scheme != "https" { problems.append(.error("links must be https: \(value.prefix(60))")) }
                    } else if !manifest.allows(url) {
                        problems.append(.error("\(node.component.rawValue) loads \(url.host() ?? value), which is not listed in meta.permissions"))
                    }
                default:
                    break
                }
            }
            if node.component == .item, let slots = node.props["slots"]?.array {
                for slot in slots {
                    if let icon = slot["icon"].string, !symbolExists(icon), SVGIcon.parse(icon) == nil {
                        problems.append(.error("no SF Symbol is named '\(icon)' (in item.slots, \(surface))"))
                    }
                }
            }
            if node.component == .button, node.string("action") == nil, node.string("url") == nil {
                problems.append(.error("button '\(node.string("label") ?? "")' needs an action or a url"))
            }
        }
    }

    private static func walk(_ node: ViewNode, parent: ViewNode?, _ visit: (ViewNode, ViewNode?) -> Void) {
        visit(node, parent)
        for child in node.children { walk(child, parent: node, visit) }
    }

    private static func depth(of node: ViewNode) -> Int {
        1 + (node.children.map(depth(of:)).max() ?? 0)
    }
}
