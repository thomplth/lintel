import AppKit
import LintelCore
import SwiftUI

/// Draws one component of the design system. Modules choose components and tokens; every size and colour comes from here.
struct NodeView: View {
    let node: ViewNode
    let context: RenderContext

    var body: some View {
        let _ = Perf.count("view.node")
        switch node.component {
        case .text: textView
        case .icon: iconView(node.string("name") ?? "", tone: node.tone(), size: node.string("size"))
        case .dot:
            Circle().fill(context.color(node.tone(), fallback: context.secondary))
                .frame(width: context.metrics.fontSize(role: nil) * 0.5, height: context.metrics.fontSize(role: nil) * 0.5)
        case .badge: badgeView(node.string("value") ?? "", tone: node.tone()?.resolved(for: context.look)?.tone)
        case .gauge: gaugeView
        case .ring: ringView
        case .sparkline:
            SparklineShape(values: node.numbers("values"), isBars: node.string("kind") == "bar", color: context.color(node.tone()))
                .frame(width: context.theme.fontSize * 3.4, height: context.theme.fontSize * 1.05)
        case .row:
            HStack(alignment: rowAlignment, spacing: spacing(default: context.surface == .chip ? context.metrics.chipContentSpacing : context.metrics.spacing(nil))) {
                children
            }
        case .spacer: Spacer(minLength: context.metrics.unit * 2)
        case .column: columnView
        case .split: splitView
        case .section: sectionView
        case .grid: gridView
        case .stat: statView
        case .meter: meterView
        case .chart: ChartView(node: node, context: context)
        case .list: listView
        case .item: ItemRow(node: node, context: context)
        case .keyValue: keyValueView
        case .button: buttonView
        case .toggle: ToggleControl(node: node, context: context)
        case .segmented: SegmentedControl(node: node, context: context)
        case .slider: SliderControl(node: node, context: context)
        case .field: FieldControl(node: node, context: context)
        case .divider: Rectangle().fill(context.separator).frame(height: 1)
        case .note: noteView
        case .progress: progressView
        case .image: imageView
        case .empty: emptyView
        case .web: WebClipView(node: node, context: context)
        case .app: MiniAppView(node: node, context: context)
        }
    }

    @ViewBuilder private var children: some View {
        ForEach(Array(node.children.enumerated()), id: \.offset) { child in
            NodeView(node: child.element, context: context)
        }
    }

    private func spacing(default fallback: Double) -> Double {
        node.string("spacing").map { context.metrics.spacing($0) } ?? fallback
    }

    private var rowAlignment: VerticalAlignment {
        switch node.string("align") {
        case "top": .top
        case "bottom": .bottom
        case "baseline": .firstTextBaseline
        default: .center
        }
    }

    private var columnAlignment: HorizontalAlignment {
        switch node.string("align") {
        case "center": .center
        case "trailing": .trailing
        default: .leading
        }
    }

    // MARK: Atoms

    @ViewBuilder private var textView: some View {
        let role = node.string("role")
        let isMono = node.bool("mono")
        let fallback: Color = role == "label" || role == "caption" ? context.secondary : context.primary
        let lines = context.surface == .chip ? 1 : Int(min(max(node.number("lines") ?? 1, 1), 8))
        let text = Text(node.string("value") ?? "")
            .font(context.font(role: role, weight: node.string("weight"), mono: isMono))
            .foregroundStyle(context.color(node.tone(), fallback: fallback))
            .lineLimit(lines)
            .truncationMode(.tail)
        if context.surface == .chip {
            // numericText renders the text in a layer clipped to its frame, which cuts the Halo shadow to a
            // rectangle and cross-fades every tick of the clock, so bar text swaps without a transition.
            text.fixedSize()
        } else {
            text.fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .contentTransition(isMono && context.animates ? .numericText() : .identity)
        }
    }

    private func iconView(_ name: String, tone: ToneChoice?, size: String? = nil, role: String? = nil) -> some View {
        let scale: Double = switch size {
        case "small": 0.8
        case "large": 1.5
        default: 1
        }
        return SymbolGlyph(
            name: name,
            size: context.metrics.fontSize(role: role) * scale,
            weight: context.weight(nil),
            symbolMode: context.symbolMode
        )
        .foregroundStyle(context.color(tone))
    }

    private func badgeView(_ value: String, tone: Tone?) -> some View {
        let color = context.fillColor(tone, fallback: context.accent)
        return Text(value)
            .font(context.font(role: "caption", weight: "semibold", mono: true))
            .foregroundStyle(context.textColor(on: tone))
            .lineLimit(1)
            .padding(.horizontal, context.metrics.unit * 1.5)
            .padding(.vertical, 1)
            .frame(minWidth: context.metrics.fontSize(role: "caption") * 1.5)
            .background(color, in: Capsule())
    }

    @ViewBuilder private var gaugeView: some View {
        let width = context.theme.fontSize * 2.2
        if let secondary = node.number("secondary") {
            let barHeight = max(3, context.theme.fontSize * 0.24)
            VStack(spacing: 2) {
                LevelBar(fraction: node.number("value") ?? 0, color: context.color(node.tone()), track: context.strongFill)
                    .frame(width: width, height: barHeight)
                LevelBar(fraction: secondary, color: context.color(node.tone("secondaryTone") ?? node.tone()), track: context.strongFill)
                    .frame(width: width, height: barHeight)
            }
        } else {
            LevelBar(fraction: node.number("value") ?? 0, color: context.color(node.tone()), track: context.strongFill)
                .frame(width: width, height: max(4, context.theme.fontSize * 0.36))
        }
    }

    private var ringView: some View {
        let size = context.theme.fontSize * 1.05
        let color = context.color(node.tone(), fallback: context.accent == context.primary ? context.primary : context.accent)
        return ZStack {
            Circle().stroke(context.strongFill, lineWidth: size * 0.18)
            Circle().trim(from: 0, to: min(max(node.number("value") ?? 0, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.18, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(context.animates ? .easeOut(duration: 0.3) : nil, value: node.number("value"))
    }

    // MARK: Panel & Widget blocks

    @ViewBuilder private var columnView: some View {
        let gap = spacing(default: context.metrics.spacing(nil))
        if context.isInWidget {
            AdaptiveStackLayout(spacing: gap, alignment: columnAlignment) {
                adaptiveChildren(node.children)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: columnAlignment, vertical: .top))
        } else {
            VStack(alignment: columnAlignment, spacing: gap) { children }
                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: columnAlignment, vertical: .center))
        }
    }

    private var splitView: some View {
        let weights = node.numbers("weights")
        let gap = spacing(default: context.metrics.spacing(nil))
        let vAlign: VerticalAlignment = switch node.string("align") {
        case "center": .center
        case "bottom": .bottom
        default: .top
        }
        return SplitLayout(weights: weights, spacing: gap, alignment: vAlign) {
            ForEach(Array(node.children.enumerated()), id: \.offset) { child in
                NodeView(node: child.element, context: context)
                    .frame(maxWidth: .infinity, maxHeight: context.isInWidget ? .infinity : nil, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: context.isInWidget ? .infinity : nil, alignment: .topLeading)
    }

    @ViewBuilder private func adaptiveChildren(_ nodes: [ViewNode]) -> some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { child in
            NodeView(node: child.element, context: context)
                .layoutValue(key: BlockPriorityKey.self, value: child.element.layoutPriority)
                .layoutValue(key: BlockFlexKey.self, value: child.element.layoutFlex)
        }
    }

    private var sectionView: some View {
        let gap = context.isCompactWidget ? context.metrics.unit * 1.5 : context.metrics.unit * 2
        let childGap = context.isCompactWidget ? context.metrics.unit * 1.25 : context.metrics.spacing(nil)
        return VStack(alignment: .leading, spacing: gap) {
            if let title = node.string("title"), !title.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(context.font(role: "caption", weight: "semibold"))
                        .foregroundStyle(context.secondary)
                        .textCase(.uppercase)
                        .kerning(0.4)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let trailing = node.string("trailing") {
                        Text(trailing).font(context.font(role: "caption", mono: true)).foregroundStyle(context.tertiary).lineLimit(1)
                    }
                }
            }
            if context.isInWidget && node.containsFlexibleBlock {
                AdaptiveStackLayout(spacing: childGap, alignment: .leading) {
                    adaptiveChildren(node.children)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: childGap) { children }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gridView: some View {
        let columns = Int(min(max(node.number("columns") ?? 2, 1), 7))
        let gap = spacing(default: context.metrics.spacing(nil))
        let rows = stride(from: 0, to: node.children.count, by: columns).map { start in
            Array(node.children[start..<min(start + columns, node.children.count)])
        }
        return VStack(spacing: gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { row in
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0..<columns, id: \.self) { index in
                        if index < row.element.count {
                            NodeView(node: row.element[index], context: context)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: [.text, .badge].contains(row.element[index].component) ? .center : .topLeading)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statView: some View {
        let pad = context.isCompactWidget ? context.metrics.unit * 2 : context.metrics.tilePadding
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: context.metrics.unit) {
                if let name = node.string("icon") { iconView(name, tone: ToneChoice(.secondary), role: "caption") }
                Text(node.string("label") ?? "").font(context.font(role: "caption")).foregroundStyle(context.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(node.string("value") ?? "")
                    .font(context.font(role: context.isCompactWidget ? "title" : "display", mono: true))
                    .foregroundStyle(context.color(node.tone()))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .contentTransition(context.animates ? .numericText() : .identity)
                if let unit = node.string("unit") {
                    Text(unit).font(context.font(role: "label")).foregroundStyle(context.secondary).lineLimit(1)
                }
                if let trend = node.string("trend") {
                    Image(systemName: trend == "up" ? "arrow.up.right" : trend == "down" ? "arrow.down.right" : "arrow.right")
                        .font(.system(size: context.metrics.fontSize(role: "caption"), weight: .semibold))
                        .foregroundStyle(context.secondary)
                }
            }
            if let caption = node.string("caption") {
                Text(caption).font(context.font(role: "caption")).foregroundStyle(context.tertiary).lineLimit(1)
            }
        }
        .padding(pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(context.fill, in: context.tileShape)
    }

    private var meterView: some View {
        VStack(spacing: context.metrics.unit) {
            HStack(spacing: context.metrics.unit * 1.5) {
                if let name = node.string("icon") { iconView(name, tone: ToneChoice(.secondary), role: "label") }
                Text(node.string("label") ?? "").font(context.font(role: "label", weight: context.theme.fontWeight)).foregroundStyle(context.primary).lineLimit(1)
                Spacer(minLength: 8)
                if let value = node.string("value") {
                    Text(value).font(context.font(role: "label", mono: true)).foregroundStyle(context.secondary).lineLimit(1)
                        .contentTransition(context.animates ? .numericText() : .identity)
                }
            }
            LevelBar(fraction: node.number("fraction") ?? 0, color: context.color(node.tone(), fallback: context.accent), track: context.strongFill)
                .frame(height: 6)
                .animation(context.animates ? .easeOut(duration: 0.3) : nil, value: node.number("fraction"))
        }
    }

    @ViewBuilder private var listView: some View {
        if context.isInWidget {
            AdaptiveListView(node: node, context: context)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { child in
                    if child.offset > 0 {
                        Rectangle().fill(context.separator).frame(height: 1).padding(.leading, context.metrics.tilePadding)
                    }
                    NodeView(node: child.element, context: context)
                }
            }
            .background(context.fill, in: context.tileShape)
            .clipShape(context.tileShape)
        }
    }

    private var keyValueView: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(node.string("label") ?? "").font(context.font(role: "label")).foregroundStyle(context.secondary).lineLimit(1)
            Spacer(minLength: 12)
            Text(node.string("value") ?? "")
                .font(context.font(role: "label", weight: context.theme.fontWeight, mono: node.bool("mono")))
                .foregroundStyle(context.color(node.tone()))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var buttonView: some View {
        Button(action: press) {
            HStack(spacing: context.metrics.unit * 1.5) {
                if let name = node.string("icon") {
                    SymbolGlyph(name: name, size: context.metrics.fontSize(role: "label"), weight: context.weight(nil), symbolMode: context.symbolMode)
                }
                Text(node.string("label") ?? "").lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TokenButtonStyle(context: context, style: node.string("style") ?? "secondary"))
        .focusable(false)
        .keyboardOperable(context, focusKey: node.focusKey, activate: press)
    }

    private func press() {
        if let action = node.string("action") {
            context.perform(action, node.props["payload"] ?? .null)
        } else if let address = node.string("url"), let url = URL(string: address), url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
    }

    private var noteView: some View {
        HStack(alignment: .firstTextBaseline, spacing: context.metrics.unit * 1.5) {
            if let name = node.string("icon") { iconView(name, tone: node.tone() ?? ToneChoice(.secondary), role: "caption") }
            Text(node.string("value") ?? "")
                .font(context.font(role: "caption"))
                .foregroundStyle(context.color(node.tone(), fallback: context.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var progressView: some View {
        if let fraction = node.number("value") {
            VStack(alignment: .leading, spacing: context.metrics.unit) {
                if let label = node.string("label") {
                    Text(label).font(context.font(role: "caption")).foregroundStyle(context.secondary)
                }
                LevelBar(fraction: fraction, color: context.color(node.tone(), fallback: context.accent), track: context.strongFill)
                    .frame(height: 6)
                    .animation(context.animates ? .easeOut(duration: 0.3) : nil, value: fraction)
            }
        } else {
            HStack(spacing: context.metrics.unit * 2) {
                ProgressView().controlSize(.small)
                if let label = node.string("label") {
                    Text(label).font(context.font(role: "label")).foregroundStyle(context.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var imageView: some View {
        let height = context.metrics.blockHeight(node.string("height"))
        if let address = node.string("url"), let url = URL(string: address), context.manifest?.allows(url) == true {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                case .failure: Image(systemName: "photo").foregroundStyle(context.tertiary)
                default: ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(context.fill)
            .clipShape(context.tileShape)
        } else {
            Image(systemName: "photo").foregroundStyle(context.tertiary)
                .frame(maxWidth: .infinity).frame(height: height).background(context.fill, in: context.tileShape)
        }
    }

    private var emptyView: some View {
        VStack(spacing: context.metrics.unit * 2) {
            Image(systemName: RenderContext.symbol(node.string("icon") ?? "tray"))
                .font(.system(size: context.theme.fontSize * 2, weight: .regular))
                .foregroundStyle(context.tertiary)
            Text(node.string("title") ?? "").font(context.font(role: "title")).foregroundStyle(context.primary)
                .multilineTextAlignment(.center)
            if let message = node.string("message") {
                Text(message).font(context.font(role: "caption")).foregroundStyle(context.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if let action = node.string("action") {
                Button(node.string("actionLabel") ?? "Try again") { context.perform(action, .null) }
                    .buttonStyle(TokenButtonStyle(context: context, style: "secondary"))
                    .fixedSize()
                    .padding(.top, context.metrics.unit)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, context.metrics.unit * 5)
    }
}

struct LevelBar: View {
    let fraction: Double
    let color: Color
    let track: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color).frame(width: max(proxy.size.height, proxy.size.width * min(max(fraction, 0), 1)))
                    .opacity(fraction > 0.001 ? 1 : 0)
            }
        }
    }
}

struct SparklineShape: View {
    let values: [Double]
    let isBars: Bool
    let color: Color

    var body: some View {
        Canvas { canvas, size in
            guard values.count > 1, let low = values.min(), let high = values.max() else { return }
            let span = max(high - low, 1e-9)
            func point(_ index: Int) -> CGPoint {
                CGPoint(
                    x: size.width * Double(index) / Double(values.count - 1),
                    y: 1 + (size.height - 2) * (1 - (values[index] - low) / span)
                )
            }
            if isBars {
                let width = size.width / Double(values.count)
                for index in values.indices {
                    let height = max(1.5, (size.height) * (values[index] - min(low, 0)) / max(high - min(low, 0), 1e-9))
                    let bar = CGRect(x: Double(index) * width + width * 0.15, y: size.height - height, width: width * 0.7, height: height)
                    canvas.fill(Path(roundedRect: bar, cornerRadius: min(width * 0.35, 1.5)), with: .color(color))
                }
            } else {
                var line = Path()
                line.move(to: point(0))
                for index in 1..<values.count { line.addLine(to: point(index)) }
                canvas.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                let last = point(values.count - 1)
                canvas.fill(Path(ellipseIn: CGRect(x: last.x - 1.8, y: last.y - 1.8, width: 3.6, height: 3.6)), with: .color(color))
            }
        }
    }
}

struct TokenButtonStyle: ButtonStyle {
    let context: RenderContext
    let style: String

    func makeBody(configuration: Configuration) -> some View {
        let foreground: Color = switch style {
        case "primary": context.onAccent
        case "destructive": .red
        case "plain": context.accent
        default: context.primary
        }
        let background: Color = switch style {
        case "primary": context.accent
        case "destructive": Color.red.opacity(0.14)
        case "plain": .clear
        default: context.strongFill
        }
        return configuration.label
            .font(context.font(role: "label", weight: "medium"))
            .foregroundStyle(foreground)
            .padding(.horizontal, context.metrics.unit * 3)
            .padding(.vertical, context.metrics.unit * 1.75)
            .background(background, in: context.tileShape)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(context.tileShape)
    }
}

private struct ItemRow: View {
    let node: ViewNode
    let context: RenderContext
    var compactOverride = false
    @State private var isHovered = false

    private var isClickable: Bool {
        node.string("action") != nil || node.string("url") != nil
    }

    private var isCompact: Bool {
        compactOverride || context.isCompactWidget
    }

    var body: some View {
        HStack(spacing: context.metrics.unit * (isCompact ? 1.75 : 2.5)) {
            if let name = node.string("icon") {
                SymbolGlyph(name: name, size: context.metrics.fontSize(role: isCompact ? "label" : nil), weight: context.weight(nil), symbolMode: context.symbolMode)
                    .foregroundStyle(context.color(node.tone(), fallback: context.secondary))
                    .frame(width: context.theme.fontSize * (isCompact ? 1.15 : 1.4))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.string("title") ?? "").font(context.font(role: "label", weight: context.theme.fontWeight))
                    .foregroundStyle(context.primary).lineLimit(1)
                if !compactOverride, let subtitle = node.string("subtitle"), !subtitle.isEmpty {
                    Text(subtitle).font(context.font(role: "caption")).foregroundStyle(context.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let value = node.string("value") {
                Text(value).font(context.font(role: "label", mono: true)).foregroundStyle(context.secondary).lineLimit(1)
            }
            if let badge = node.string("badge") {
                Text(badge)
                    .font(context.font(role: "caption", weight: "semibold", mono: true))
                    .foregroundStyle(context.color(node.tone(), fallback: context.accent))
                    .padding(.horizontal, context.metrics.unit * 1.5)
                    .padding(.vertical, 1)
                    .background(context.color(node.tone(), fallback: context.accent).opacity(0.16), in: Capsule())
            }
            if let accessory = node.string("accessoryAction") {
                ItemAccessory(
                    symbol: node.string("accessoryIcon") ?? "minus.circle", label: node.string("accessoryLabel"),
                    focusKey: node.focusKey + "|accessory", context: context
                ) { context.perform(accessory, node.props["payload"] ?? .null) }
            } else if isClickable {
                Image(systemName: node.string("url") != nil && node.string("action") == nil ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: context.metrics.fontSize(role: "caption") * 0.9, weight: .semibold))
                    .foregroundStyle(context.tertiary)
            }
        }
        .padding(.horizontal, isCompact ? context.metrics.unit * 2 : context.metrics.tilePadding)
        .padding(.vertical, context.metrics.unit * (isCompact ? 1.35 : 2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered && isClickable ? context.fill : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: press)
        .modifier(OptionalKeyboardOperable(context: context, focusKey: node.focusKey, activate: isClickable ? press : nil))
    }

    private func press() {
        if let action = node.string("action") {
            context.perform(action, node.props["payload"] ?? .null)
        } else if let address = node.string("url"), let url = URL(string: address), url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Only rows that do something on a click take a Tab stop.
private struct OptionalKeyboardOperable: ViewModifier {
    let context: RenderContext
    let focusKey: String
    let activate: (() -> Void)?

    func body(content: Content) -> some View {
        if let activate { content.keyboardOperable(context, focusKey: focusKey, activate: activate) } else { content }
    }
}

private struct ItemAccessory: View {
    let symbol: String
    let label: String?
    let focusKey: String
    let context: RenderContext
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: RenderContext.symbol(isHovered ? symbol + ".fill" : symbol))
                .font(.system(size: context.metrics.fontSize(role: "label")))
                .foregroundStyle(isHovered ? Color.red : context.tertiary)
                .frame(width: context.theme.fontSize * 1.4, height: context.theme.fontSize * 1.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .keyboardOperable(context, focusKey: focusKey, ring: Circle(), activate: action)
        .onHover { isHovered = $0 }
        .help(label ?? "")
        .accessibilityLabel(label ?? "")
    }
}

private struct ToggleControl: View {
    let node: ViewNode
    let context: RenderContext
    @State private var isOn = false

    var body: some View {
        HStack(spacing: context.metrics.unit * 2) {
            if let name = node.string("icon") {
                SymbolGlyph(name: name, size: context.metrics.fontSize(role: "label"), weight: context.weight(nil), symbolMode: context.symbolMode)
                    .foregroundStyle(context.secondary)
                    .frame(width: context.theme.fontSize * 1.2)
            }
            Text(node.string("label") ?? "").font(context.font(role: "label", weight: context.theme.fontWeight)).foregroundStyle(context.primary)
            Spacer(minLength: 8)
            Capsule()
                .fill(isOn ? context.accent : context.strongFill)
                .frame(width: 34, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(isOn ? context.onAccent : context.primary.opacity(0.85)).padding(2.5)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                }
                .animation(context.animates ? .snappy(duration: 0.16) : nil, value: isOn)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(isOn ? "on" : "off")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: flip)
        .keyboardOperable(context, focusKey: node.focusKey, activate: flip)
        .onAppear { isOn = node.bool("on") }
        .onChange(of: node.bool("on")) { isOn = node.bool("on") }
    }

    private func flip() {
        isOn.toggle()
        if let action = node.string("action") { context.perform(action, .bool(isOn)) }
    }
}

private struct SegmentedControl: View {
    let node: ViewNode
    let context: RenderContext

    var body: some View {
        let options = node.strings("options")
        let selected = node.string("selected")
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Text(option)
                    .font(context.font(role: "label", weight: option == selected ? "semibold" : nil))
                    .foregroundStyle(option == selected ? context.primary : context.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, context.metrics.unit * 1.25)
                    .background(option == selected ? context.strongFill : .clear, in: RoundedRectangle(cornerRadius: max(context.metrics.tileCornerRadius - 2, 2), style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let action = node.string("action"), option != selected { context.perform(action, .string(option)) }
                    }
            }
        }
        .padding(2)
        .background(context.fill, in: context.tileShape)
        .keyboardOperable(context, focusKey: node.focusKey, ring: context.tileShape, adjust: { step in
            guard let action = node.string("action"), !options.isEmpty else { return }
            let index = options.firstIndex(of: selected ?? "").map { $0 + step } ?? 0
            let option = options[min(max(index, 0), options.count - 1)]
            if option != selected { context.perform(action, .string(option)) }
        })
    }
}

private struct SliderControl: View {
    let node: ViewNode
    let context: RenderContext
    @State private var value = 0.0
    @State private var isEditing = false

    var body: some View {
        let low = node.number("min") ?? 0
        let high = max(node.number("max") ?? 1, low + 0.0001)
        VStack(alignment: .leading, spacing: context.metrics.unit) {
            if let label = node.string("label") {
                Text(label).font(context.font(role: "caption")).foregroundStyle(context.secondary)
            }
            HStack(spacing: context.metrics.unit * 2) {
                if let name = node.string("icon") {
                    Image(systemName: RenderContext.symbol(name)).foregroundStyle(context.secondary)
                        .font(.system(size: context.metrics.fontSize(role: "label")))
                        .frame(width: context.theme.fontSize * 1.4)
                }
                GeometryReader { proxy in
                    let fraction = min(max((value - low) / (high - low), 0), 1)
                    let knob = 16.0
                    ZStack(alignment: .leading) {
                        Capsule().fill(context.strongFill).frame(height: 5)
                        Capsule().fill(context.accent).frame(width: knob / 2 + (proxy.size.width - knob) * fraction, height: 5)
                        Circle().fill(.white).frame(width: knob, height: knob)
                            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                            .offset(x: (proxy.size.width - knob) * fraction)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            isEditing = true
                            value = low + (high - low) * min(max((drag.location.x - knob / 2) / max(proxy.size.width - knob, 1), 0), 1)
                        }
                        .onEnded { _ in
                            isEditing = false
                            guard let action = node.string("action") else { return }
                            let step = node.number("step") ?? 0
                            context.perform(action, .number(step > 0 ? (value / step).rounded() * step : value))
                        })
                }
                .frame(height: 18)
            }
        }
        .keyboardOperable(context, focusKey: node.focusKey, ring: context.tileShape, adjust: { direction in
            guard let action = node.string("action") else { return }
            let step = node.number("step").flatMap { $0 > 0 ? $0 : nil } ?? (high - low) / 20
            value = min(max(value + step * Double(direction), low), high)
            context.perform(action, .number(value))
        })
        .onAppear { value = node.number("value") ?? low }
        .onChange(of: node.number("value")) { if !isEditing { value = node.number("value") ?? low } }
    }
}

private struct FieldControl: View {
    let node: ViewNode
    let context: RenderContext
    @State private var draft = ""
    @State private var suggestions: [FieldSuggestion] = []
    @State private var highlighted = 0
    @State private var hoveredSuggestion: FieldSuggestion.ID?

    var body: some View {
        VStack(spacing: 0) {
            input
            if !suggestions.isEmpty {
                Rectangle().fill(context.separator).frame(height: 1)
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    suggestionRow(suggestion, isHighlighted: index == highlighted)
                }
            }
        }
        .background(context.fill, in: context.tileShape)
        .clipShape(context.tileShape)
        .onAppear { draft = node.string("value") ?? "" }
        .task(id: draft) { await refreshSuggestions() }
    }

    private var input: some View {
        HStack(spacing: context.metrics.unit * 2) {
            if let name = node.string("icon") {
                SymbolGlyph(name: name, size: context.metrics.fontSize(role: "label"), weight: context.weight(nil), symbolMode: context.symbolMode)
                    .foregroundStyle(context.secondary)
                    .frame(width: context.theme.fontSize * 1.2)
            }
            TextField(node.string("placeholder") ?? "", text: $draft)
                .textFieldStyle(.plain)
                .font(context.font(role: "label"))
                .foregroundStyle(context.primary)
                .onSubmit(submit)
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onKeyPress(.escape) {
                    guard !draft.isEmpty else { return .ignored }
                    draft = ""
                    return .handled
                }
            if !draft.isEmpty && suggestions.isEmpty {
                Button(node.string("submitLabel") ?? "Add", action: submit)
                    .buttonStyle(.plain)
                    .font(context.font(role: "caption", weight: "semibold"))
                    .foregroundStyle(context.accent)
            }
        }
        .padding(.horizontal, context.metrics.tilePadding)
        .padding(.vertical, context.metrics.unit * 2)
    }

    private func suggestionRow(_ suggestion: FieldSuggestion, isHighlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: context.metrics.unit * 2) {
            Text(suggestion.title).font(context.font(role: "label", weight: context.theme.fontWeight))
                .foregroundStyle(isHighlighted ? context.onAccent : context.primary).lineLimit(1)
            Spacer(minLength: 8)
            if let subtitle = suggestion.subtitle {
                Text(subtitle).font(context.font(role: "caption", mono: true))
                    .foregroundStyle(isHighlighted ? context.onAccent.opacity(0.8) : context.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, context.metrics.tilePadding)
        .padding(.vertical, context.metrics.unit * 1.75)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? context.accent : hoveredSuggestion == suggestion.id ? context.fill : .clear)
        .contentShape(Rectangle())
        .onHover { hoveredSuggestion = $0 ? suggestion.id : nil }
        .onTapGesture { choose(suggestion) }
    }

    private func refreshSuggestions() async {
        guard let suggest = node.string("suggest") else { return }
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            suggestions = []
            return
        }
        let reply = await context.performForResult(suggest, .string(query))
        guard !Task.isCancelled else { return }
        suggestions = FieldSuggestion.list(from: reply)
        highlighted = 0
    }

    private func moveHighlight(by step: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        highlighted = (highlighted + step + suggestions.count) % suggestions.count
        return .handled
    }

    private func choose(_ suggestion: FieldSuggestion) {
        guard let action = node.string("action") else { return }
        draft = ""
        suggestions = []
        context.perform(action, .string(suggestion.value))
    }

    private func submit() {
        if suggestions.indices.contains(highlighted) {
            choose(suggestions[highlighted])
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let action = node.string("action") else { return }
        draft = ""
        context.perform(action, .string(text))
    }
}

private struct SVGIconShape: Shape {
    let icon: SVGIcon

    func path(in rect: CGRect) -> Path {
        Path(icon.cgPath(in: rect))
    }
}

struct SymbolGlyph: View {
    let name: String
    let size: Double
    let weight: Font.Weight
    let symbolMode: SymbolRenderingMode

    var body: some View {
        if let svg = SVGIcon.parse(name) {
            let side = size * 1.05
            SVGIconShape(icon: svg)
                .fill(style: FillStyle(eoFill: false))
                .frame(width: side, height: side)
        } else {
            Image(systemName: RenderContext.symbol(name))
                .symbolRenderingMode(symbolMode)
                .font(.system(size: size, weight: weight))
        }
    }
}
