import AppKit
import LintelCore
import SwiftUI

/// Renders a module's `configure(host)` tree as native macOS settings cards and controls inside the Lintel window.
struct ModuleConfigView: View {
    let node: ViewNode
    let perform: (String, JSONValue) -> Void
    let performForResult: (String, JSONValue) async -> JSONValue

    var body: some View {
        let sections = ModuleConfigPlan.sections(from: node)
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(sections.enumerated()), id: \.offset) { entry in
                let section = entry.element
                if section.isActionRow {
                    HStack(spacing: 10) {
                        ForEach(Array(section.items.enumerated()), id: \.offset) { item in
                            NativeConfigButton(node: item.element, perform: perform)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    WindowCard(title: section.title ?? "Configuration", trailing: section.trailing) {
                        NativeConfigItems(items: section.items, perform: perform, performForResult: performForResult)
                    }
                }
            }
        }
    }
}

private struct NativeConfigItems: View {
    let items: [ViewNode]
    let perform: (String, JSONValue) -> Void
    let performForResult: (String, JSONValue) async -> JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { entry in
                if entry.offset > 0, ModuleConfigPlan.needsDivider(between: items[entry.offset - 1], and: entry.element) {
                    Divider()
                }
                NativeConfigNode(node: entry.element, perform: perform, performForResult: performForResult)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeConfigNode: View {
    let node: ViewNode
    let perform: (String, JSONValue) -> Void
    let performForResult: (String, JSONValue) async -> JSONValue

    var body: some View {
        switch node.component {
        case .toggle:
            NativeConfigToggle(node: node, perform: perform)
        case .segmented:
            NativeConfigSegmented(node: node, perform: perform)
        case .slider:
            NativeConfigSlider(node: node, perform: perform)
        case .field:
            NativeConfigField(node: node, perform: perform, performForResult: performForResult)
        case .button:
            NativeConfigButton(node: node, perform: perform)
        case .list:
            NativeConfigList(node: node, perform: perform)
        case .item:
            NativeConfigItemRow(node: node, perform: perform)
        case .keyValue:
            NativeConfigKeyValue(node: node)
        case .note:
            NativeConfigNote(node: node)
        case .divider:
            Divider()
        case .section:
            VStack(alignment: .leading, spacing: 8) {
                if let title = node.string("title"), !title.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.subheadline.weight(.semibold))
                        Spacer()
                        if let trailing = node.string("trailing") {
                            Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                NativeConfigItems(items: node.children, perform: perform, performForResult: performForResult)
            }
        case .column:
            NativeConfigItems(items: node.children, perform: perform, performForResult: performForResult)
        case .row:
            HStack(spacing: 10) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { child in
                    NativeConfigNode(node: child.element, perform: perform, performForResult: performForResult)
                }
            }
        case .spacer:
            Spacer(minLength: 8)
        case .grid:
            let cols = max(1, min(Int(node.number("columns") ?? 2), 6))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: cols), spacing: 10) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { child in
                    NativeConfigNode(node: child.element, perform: perform, performForResult: performForResult)
                }
            }
        case .split:
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { child in
                    NativeConfigNode(node: child.element, perform: perform, performForResult: performForResult)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .text:
            Text(node.string("value") ?? "")
                .font(textFont(role: node.string("role"), mono: node.bool("mono")))
                .foregroundStyle(toneColor(node.tone(), fallback: node.string("role") == "caption" ? .secondary : .primary))
                .fixedSize(horizontal: false, vertical: true)
        case .icon:
            SymbolGlyph(name: node.string("name") ?? "", size: 14, weight: .regular, symbolMode: .monochrome)
                .foregroundStyle(toneColor(node.tone(), fallback: .secondary))
        case .dot:
            Circle()
                .fill(toneColor(node.tone(), fallback: .secondary))
                .frame(width: 8, height: 8)
        case .badge:
            TagPill(text: node.string("value") ?? "", color: toneColor(node.tone(), fallback: .accentColor))
        case .progress:
            VStack(alignment: .leading, spacing: 4) {
                if let label = node.string("label"), !label.isEmpty {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                if let value = node.number("value") {
                    ProgressView(value: min(max(value, 0), 1))
                        .tint(toneColor(node.tone(), fallback: .accentColor))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        case .meter:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let icon = node.string("icon") {
                        SymbolGlyph(name: icon, size: 12.5, weight: .regular, symbolMode: .monochrome)
                            .foregroundStyle(.secondary)
                    }
                    Text(node.string("label") ?? "").font(.callout)
                    Spacer()
                    if let value = node.string("value") {
                        Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: min(max(node.number("fraction") ?? 0, 0), 1))
                    .tint(toneColor(node.tone(), fallback: .accentColor))
            }
        case .stat:
            VStack(alignment: .leading, spacing: 2) {
                Text(node.string("label") ?? "").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(node.string("value") ?? "")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(toneColor(node.tone(), fallback: .primary))
                    if let unit = node.string("unit") {
                        Text(unit).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .empty:
            HStack(spacing: 10) {
                if let icon = node.string("icon") {
                    SymbolGlyph(name: icon, size: 18, weight: .regular, symbolMode: .monochrome)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.string("title") ?? "").fontWeight(.medium)
                    if let message = node.string("message"), !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let action = node.string("action") {
                    Button(node.string("actionLabel") ?? "Try Again") { perform(action, .null) }
                        .controlSize(.small)
                }
            }
        default:
            EmptyView()
        }
    }

    private func textFont(role: String?, mono: Bool) -> Font {
        let base: Font = switch role {
        case "title": .headline
        case "display": .title2.weight(.semibold)
        case "caption": .footnote
        default: .callout
        }
        return mono ? base.monospacedDigit() : base
    }
}

// MARK: - Native Controls

private struct NativeConfigToggle: View {
    let node: ViewNode
    let perform: (String, JSONValue) -> Void
    @State private var isOn = false

    var body: some View {
        HStack(spacing: 10) {
            if let iconName = node.string("icon"), !iconName.isEmpty {
                SymbolGlyph(name: iconName, size: 14, weight: .regular, symbolMode: .monochrome)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            Text(node.string("label") ?? "")
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { next in
                    isOn = next
                    if let action = node.string("action") {
                        perform(action, .bool(next))
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .onAppear { isOn = node.bool("on") }
        .onChange(of: node.bool("on")) { isOn = node.bool("on") }
    }
}

private struct NativeConfigSegmented: View {
    let node: ViewNode
    let perform: (String, JSONValue) -> Void

    var body: some View {
        let options = node.strings("options")
        let selected = node.string("selected") ?? options.first ?? ""
        Picker("", selection: Binding(
            get: { selected },
            set: { next in
                guard next != selected, let action = node.string("action") else { return }
                perform(action, .string(next))
            }
        )) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

private struct NativeConfigSlider: View {
    let node: ViewNode
    let perform: (String, JSONValue) -> Void
    @State private var value = 0.0
    @State private var isEditing = false

    var body: some View {
        let low = node.number("min") ?? 0
        let high = max(node.number("max") ?? 1, low + 0.0001)
        let step = node.number("step") ?? 0
        HStack(spacing: 10) {
            if let iconName = node.string("icon"), !iconName.isEmpty {
                SymbolGlyph(name: iconName, size: 13.5, weight: .regular, symbolMode: .monochrome)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            if let label = node.string("label"), !label.isEmpty {
                Text(label)
            }
            Spacer(minLength: 12)
            Slider(value: $value, in: low...high) { editing in
                isEditing = editing
                if !editing, let action = node.string("action") {
                    let committed = step > 0 ? (value / step).rounded() * step : value
                    perform(action, .number(committed))
                }
            }
            .frame(width: 210)
            Text(String(format: high <= 1 ? "%.2f" : "%.0f", value))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .onAppear { value = node.number("value") ?? low }
        .onChange(of: node.number("value")) { if !isEditing { value = node.number("value") ?? low } }
    }
}

private struct NativeConfigField: View {
    let node: ViewNode
    let perform: (String, JSONValue) -> Void
    let performForResult: (String, JSONValue) async -> JSONValue

    @State private var draft = ""
    @State private var suggestions: [FieldSuggestion] = []
    @State private var highlighted = 0
    @State private var hoveredSuggestion: FieldSuggestion.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if let iconName = node.string("icon"), !iconName.isEmpty {
                        SymbolGlyph(name: iconName, size: 12.5, weight: .regular, symbolMode: .monochrome)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    TextField(node.string("placeholder") ?? "", text: $draft)
                        .textFieldStyle(.plain)
                        .onSubmit(submit)
                        .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                        .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                        .onKeyPress(.escape) {
                            guard !draft.isEmpty else { return .ignored }
                            draft = ""
                            suggestions = []
                            return .handled
                        }
                    if !draft.isEmpty {
                        Button {
                            draft = ""
                            suggestions = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.primary.opacity(0.14), lineWidth: 1)
                )

                Button(node.string("submitLabel") ?? "Add", action: submit)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        if index > 0 { Divider() }
                        suggestionRow(suggestion, isHighlighted: index == highlighted)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.primary.opacity(0.12), lineWidth: 1)
                )
            }
        }
        .onAppear { draft = node.string("value") ?? "" }
        .task(id: draft) { await refreshSuggestions() }
    }

    private func suggestionRow(_ suggestion: FieldSuggestion, isHighlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(suggestion.title)
                .foregroundStyle(isHighlighted ? .white : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let subtitle = suggestion.subtitle {
                Text(subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isHighlighted ? .white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? Color.accentColor : (hoveredSuggestion == suggestion.id ? Color.primary.opacity(0.06) : .clear))
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
        let reply = await performForResult(suggest, .string(query))
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
        perform(action, .string(suggestion.value))
    }

    private func submit() {
        if suggestions.indices.contains(highlighted) {
            choose(suggestions[highlighted])
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let action = node.string("action") else { return }
        draft = ""
        suggestions = []
        perform(action, .string(text))
    }
}

private struct NativeConfigList: View {
    let node: ViewNode
    let perform: (String, JSONValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(node.children.enumerated()), id: \.offset) { entry in
                if entry.offset > 0 { Divider() }
                NativeConfigItemRow(node: entry.element, perform: perform)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeConfigItemRow: View {
    let node: ViewNode
    let perform: (String, JSONValue) -> Void
    @State private var isHovered = false
    @State private var isAccessoryHovered = false

    private var isClickable: Bool {
        node.string("action") != nil || node.string("url") != nil
    }

    var body: some View {
        HStack(spacing: 10) {
            if let iconName = node.string("icon"), !iconName.isEmpty {
                SymbolGlyph(name: iconName, size: 14, weight: .regular, symbolMode: .monochrome)
                    .foregroundStyle(toneColor(node.tone(), fallback: .secondary))
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.string("title") ?? "")
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle = node.string("subtitle"), !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let value = node.string("value"), !value.isEmpty {
                Text(value)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let badge = node.string("badge"), !badge.isEmpty {
                TagPill(text: badge, color: toneColor(node.tone(), fallback: .accentColor))
            }
            if let accessory = node.string("accessoryAction") {
                let symbol = node.string("accessoryIcon") ?? "minus.circle"
                Button {
                    perform(accessory, node.props["payload"] ?? .null)
                } label: {
                    Image(systemName: RenderContext.symbol(isAccessoryHovered ? symbol + ".fill" : symbol))
                        .font(.system(size: 13.5))
                        .foregroundStyle(isAccessoryHovered ? .red : .secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isAccessoryHovered = $0 }
                .help(node.string("accessoryLabel") ?? "")
            } else if isClickable, node.string("url") != nil && node.string("action") == nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(isHovered && isClickable ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if let action = node.string("action") {
                perform(action, node.props["payload"] ?? .null)
            } else if let address = node.string("url"), let url = URL(string: address), url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

private struct NativeConfigButton: View {
    let node: ViewNode
    let perform: (String, JSONValue) -> Void

    var body: some View {
        let labelText = node.string("label") ?? ""
        let iconName = node.string("icon")
        let style = node.string("style") ?? "secondary"
        let role: ButtonRole? = style == "destructive" ? .destructive : nil

        let button = Button(role: role) {
            if let action = node.string("action") {
                perform(action, node.props["payload"] ?? .null)
            } else if let address = node.string("url"), let url = URL(string: address), url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                if let iconName, !iconName.isEmpty {
                    SymbolGlyph(name: iconName, size: 12.5, weight: .medium, symbolMode: .monochrome)
                }
                Text(labelText)
            }
        }

        Group {
            switch style {
            case "primary":
                button.buttonStyle(.borderedProminent)
            case "plain":
                button.buttonStyle(.borderless)
            default:
                button.buttonStyle(.bordered)
            }
        }
    }
}

private struct NativeConfigKeyValue: View {
    let node: ViewNode

    var body: some View {
        HStack(spacing: 12) {
            Text(node.string("label") ?? "")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(node.string("value") ?? "")
                .font(node.bool("mono") ? .callout.monospaced() : .callout)
                .foregroundStyle(toneColor(node.tone(), fallback: .primary))
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct NativeConfigNote: View {
    let node: ViewNode

    var body: some View {
        let value = node.string("value") ?? ""
        let rawTone = node.string("tone")
        let isCallout = rawTone == "warn" || rawTone == "bad" || rawTone == "good" || rawTone == "info"
        if isCallout {
            let tint = toneColor(node.tone(), fallback: .orange)
            HStack(alignment: .top, spacing: 8) {
                if let iconName = node.string("icon"), !iconName.isEmpty {
                    SymbolGlyph(name: iconName, size: 13, weight: .medium, symbolMode: .monochrome)
                        .foregroundStyle(tint)
                        .padding(.top, 1)
                }
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(rawTone == "bad" ? .red : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            HStack(alignment: .top, spacing: 6) {
                if let iconName = node.string("icon"), !iconName.isEmpty {
                    SymbolGlyph(name: iconName, size: 12, weight: .regular, symbolMode: .monochrome)
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                }
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private func toneColor(_ choice: ToneChoice?, fallback: Color) -> Color {
    guard let tone = choice?.resolved(for: .glass)?.tone else { return fallback }
    switch tone {
    case .primary: return .primary
    case .secondary: return .secondary
    case .tertiary: return Color.secondary.opacity(0.65)
    case .accent: return .accentColor
    case .good, .green: return .green
    case .warn, .orange: return .orange
    case .bad, .red: return .red
    case .info, .blue: return .blue
    case .yellow: return .yellow
    case .mint: return .mint
    case .teal: return .teal
    case .cyan: return .cyan
    case .indigo: return .indigo
    case .purple: return .purple
    case .pink: return .pink
    case .brown: return .brown
    case .gray: return .gray
    }
}
