import AppKit
import LintelCore
import SwiftUI

/// The surface that hangs under a chip: a module's panel, its approval or failure state, or the assistant.
struct PanelView: View {
    @ObservedObject var model: BarModel
    var maxHeight: CGFloat
    var onSize: (CGSize) -> Void
    @State private var contentHeight: CGFloat = 80
    @Environment(\.colorScheme) private var systemScheme

    static let margin: CGFloat = 28

    var body: some View {
        if let panel = model.panel {
            let slot = model.slot(panel.slotID)
            let material: SurfaceMaterial = model.theme.panelMaterial == "solid" ? .solid : .glass
            let context = makeContext(panel, material: material)
            let width = context.metrics.panelWidth(panel.content == .assistant ? "medium" : slot?.panelWidth)
            let headerHeight = context.metrics.fontSize(role: "title") + context.metrics.panelPadding * 2
            VStack(alignment: .leading, spacing: 0) {
                header(panel, slot: slot, context: context)
                    .frame(height: headerHeight)
                Rectangle().fill(context.separator).frame(height: 1)
                if panel.content == .assistant {
                    ChatView(model: model, context: context)
                        .frame(height: min(max(maxHeight - headerHeight, 200), 460))
                } else {
                    ScrollView(.vertical) {
                        moduleContent(panel, slot: slot, context: context)
                            .padding(context.metrics.panelPadding)
                            .frame(width: width, alignment: .leading)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(contentHeight > maxHeight - headerHeight ? .automatic : .hidden)
                    .frame(height: min(contentHeight, max(maxHeight - headerHeight, 120)))
                }
            }
            .frame(width: width)
            .modifier(SurfaceBackground(context: context, material: material, shape: context.panelShape))
            .clipShape(context.panelShape)
            .shadow(color: .black.opacity(material == .solid ? 0.3 : 0.12), radius: 14, y: 6)
            .environment(\.colorScheme, context.colorScheme ?? systemScheme)
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onSize)
            .padding(Self.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onExitCommand { model.onDismiss() }
        }
    }

    private func makeContext(_ panel: PanelState, material: SurfaceMaterial) -> RenderContext {
        var context = RenderContext(
            theme: model.theme, surface: .panel, material: material, moduleID: panel.slotID,
            manifest: model.manifestFor(panel.slotID)
        )
        let model = model
        context.panelFocus = model.panelFocus
        context.perform = { action, payload in model.onAction(panel.slotID, action, payload) }
        context.performForResult = { action, payload in await model.onAppAction(panel.slotID, action, payload) }
        return context
    }

    private func header(_ panel: PanelState, slot: Slot?, context: RenderContext) -> some View {
        HStack(spacing: context.metrics.unit * 2) {
            Image(systemName: panel.content == .assistant ? "sparkles" : slot?.icon ?? "puzzlepiece.extension")
                .font(.system(size: context.metrics.fontSize(role: "title"), weight: .medium))
                .foregroundStyle(context.accent)
                .frame(width: context.metrics.fontSize(role: "title") * 1.4)
            Text(panel.content == .assistant ? "Assistant" : slot?.title ?? panel.slotID)
                .font(context.font(role: "title"))
                .foregroundStyle(context.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if panel.isLoading || (panel.content == .assistant && model.isChatBusy) {
                ProgressView().controlSize(.small)
            }
            if panel.content == .assistant {
                if !model.engineName.isEmpty {
                    Text(model.engineName).font(context.font(role: "caption")).foregroundStyle(context.tertiary).lineLimit(1)
                }
                headerButton("trash", "Clear conversation", context) { model.onChatCommand("clear", nil) }
            } else if slot?.kind == .module {
                headerButton("sparkles", "Open in Lintel Studio", context) { model.onPanelCommand("change") }
            }
            headerButton("gearshape", "Settings", context) { model.onPanelCommand("settings") }
        }
        .padding(.horizontal, context.metrics.panelPadding)
    }

    private func headerButton(_ symbol: String, _ help: String, _ context: RenderContext, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: context.metrics.fontSize(role: "label")))
                .foregroundStyle(context.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .keyboardOperable(context, focusKey: "header." + symbol, isContent: false, ring: RoundedRectangle(cornerRadius: 5), activate: action)
        .help(help)
    }

    @ViewBuilder
    private func moduleContent(_ panel: PanelState, slot: Slot?, context: RenderContext) -> some View {
        if let slot, slot.needsApproval {
            ApprovalView(slot: slot, context: context, model: model)
        } else if let node = panel.node {
            VStack(alignment: .leading, spacing: context.metrics.sectionSpacing) {
                if let failure = panel.failure {
                    NodeView(node: ViewNode(.note, ["value": .string(failure), "tone": "bad", "icon": "exclamationmark.triangle.fill"]), context: context)
                }
                if node.component == .column, node.props.isEmpty {
                    ForEach(Array(node.children.enumerated()), id: \.offset) { child in
                        NodeView(node: child.element, context: context)
                    }
                } else {
                    NodeView(node: node, context: context)
                }
            }
        } else if let failure = panel.failure ?? slot?.failure {
            VStack(spacing: context.metrics.unit * 3) {
                NodeView(node: ViewNode(.empty, [
                    "icon": "exclamationmark.triangle.fill", "title": "This module has a problem", "message": .string(failure),
                ]), context: context)
                HStack(spacing: context.metrics.unit * 2) {
                    Button("Ask assistant to fix") { model.onPanelCommand("fix") }
                        .buttonStyle(TokenButtonStyle(context: context, style: "primary"))
                        .focusable(false)
                        .keyboardOperable(context, focusKey: "fix") { model.onPanelCommand("fix") }
                    if slot?.isUserModule == true {
                        Button("Remove") { model.onPanelCommand("remove") }
                            .buttonStyle(TokenButtonStyle(context: context, style: "destructive"))
                            .focusable(false)
                            .keyboardOperable(context, focusKey: "remove") { model.onPanelCommand("remove") }
                    }
                }
            }
        } else if panel.isLoading {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, context.metrics.unit * 6)
        } else {
            NodeView(node: ViewNode(.empty, ["icon": .string(slot?.icon ?? "puzzlepiece.extension"), "title": "Nothing more to show", "message": "This module has no panel."]), context: context)
        }
    }
}

private struct ApprovalView: View {
    let slot: Slot
    let context: RenderContext
    @ObservedObject var model: BarModel

    var body: some View {
        VStack(alignment: .leading, spacing: context.metrics.sectionSpacing) {
            Text("This module will not run until you allow what it asks for.")
                .font(context.font(role: "label")).foregroundStyle(context.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(slot.permissions.enumerated()), id: \.offset) { entry in
                    if entry.offset > 0 { Rectangle().fill(context.separator).frame(height: 1) }
                    HStack(spacing: context.metrics.unit * 2.5) {
                        Image(systemName: Self.symbol(for: entry.element))
                            .foregroundStyle(Capability(entry.element) == nil ? context.secondary : Color.orange)
                            .frame(width: context.theme.fontSize * 1.4)
                        Text(Self.explain(entry.element)).font(context.font(role: "label")).foregroundStyle(context.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, context.metrics.tilePadding)
                    .padding(.vertical, context.metrics.unit * 2)
                }
            }
            .background(context.fill, in: context.tileShape)
            HStack(spacing: context.metrics.unit * 2) {
                Button("Allow") { model.onPanelCommand("approve") }
                    .buttonStyle(TokenButtonStyle(context: context, style: "primary"))
                    .focusable(false)
                    .keyboardOperable(context, focusKey: "approve") { model.onPanelCommand("approve") }
                Button("View Code") { model.onPanelCommand("source") }
                    .buttonStyle(TokenButtonStyle(context: context, style: "secondary"))
                    .focusable(false)
                    .keyboardOperable(context, focusKey: "source") { model.onPanelCommand("source") }
                Button("Remove") { model.onPanelCommand("remove") }
                    .buttonStyle(TokenButtonStyle(context: context, style: "destructive"))
                    .focusable(false)
                    .keyboardOperable(context, focusKey: "remove") { model.onPanelCommand("remove") }
            }
        }
    }

    static func explain(_ permission: String) -> String {
        Capability(permission)?.explanation ?? "Contact \(permission), including pages you are signed in to in Lintel's browser"
    }

    static func symbol(for permission: String) -> String {
        switch Capability(permission) {
        case .notify: "bell"
        case .audio: "speaker.wave.2.fill"
        case .clipboard: "doc.on.doc"
        case .jobs: "clock.arrow.circlepath"
        case .exec: "terminal"
        case .secret: "key"
        case nil: "globe"
        }
    }
}

struct ChatView: View {
    @ObservedObject var model: BarModel
    let context: RenderContext
    @FocusState private var isFocused: Bool

    private var draft: String { model.chatDraft }

    static let suggestions = [
        "Make the text a little bigger",
        "Switch to the Ink look",
        "Add a module with the Bitcoin price",
        "Put the clock on its own row",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: context.metrics.unit * 2.5) {
                        if model.chat.isEmpty { welcome }
                        ForEach(model.chat) { message in
                            bubble(message).id(message.id)
                        }
                        if model.isChatBusy {
                            HStack(spacing: context.metrics.unit * 2) {
                                ProgressView().controlSize(.small)
                                Text(model.chatActivity.isEmpty ? "Thinking…" : model.chatActivity)
                                    .font(context.font(role: "caption")).foregroundStyle(context.secondary)
                            }
                            .id("activity")
                        }
                    }
                    .padding(context.metrics.panelPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.chat.count) { scroll(proxy) }
                .onChange(of: model.isChatBusy) { scroll(proxy) }
                .onAppear { scroll(proxy) }
            }
            Rectangle().fill(context.separator).frame(height: 1)
            HStack(spacing: context.metrics.unit * 2) {
                TextField("Change the bar or build a module", text: $model.chatDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(context.font(role: "label"))
                    .foregroundStyle(context.primary)
                    .focused($isFocused)
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: context.theme.fontSize * 1.5))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isChatBusy ? context.tertiary : context.accent)
                }
                .buttonStyle(.plain)
                .disabled(model.isChatBusy)
            }
            .padding(.horizontal, context.metrics.panelPadding)
            .padding(.vertical, context.metrics.unit * 2.5)
        }
        .onAppear { isFocused = true }
        .onChange(of: model.chatFocusRequests) { isFocused = true }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if model.isChatBusy { proxy.scrollTo("activity", anchor: .bottom) } else if let last = model.chat.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private func submit() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !model.isChatBusy else { return }
        model.chatDraft = ""
        model.onChatSubmit(message)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: context.metrics.unit * 2.5) {
            Text("Describe a change to the bar, or something you want to keep an eye on.")
                .font(context.font(role: "label")).foregroundStyle(context.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button {
                    model.onChatSubmit(suggestion)
                } label: {
                    HStack {
                        Text(suggestion).font(context.font(role: "label")).foregroundStyle(context.primary)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.left").font(.system(size: context.metrics.fontSize(role: "caption"))).foregroundStyle(context.tertiary)
                    }
                    .padding(.horizontal, context.metrics.tilePadding)
                    .padding(.vertical, context.metrics.unit * 2)
                    .background(context.fill, in: context.tileShape)
                    .contentShape(context.tileShape)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .keyboardOperable(context, focusKey: "suggestion." + suggestion) { model.onChatSubmit(suggestion) }
            }
        }
    }

    @ViewBuilder private func bubble(_ message: ChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(context.font(role: "label"))
                    .foregroundStyle(context.onAccent)
                    .padding(.horizontal, context.metrics.unit * 3)
                    .padding(.vertical, context.metrics.unit * 2)
                    .background(context.accent, in: RoundedRectangle(cornerRadius: context.metrics.tileCornerRadius + 2, style: .continuous))
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: context.metrics.unit * 1.5) {
                Text(message.text)
                    .font(context.font(role: "label"))
                    .foregroundStyle(message.isError ? Color.red : context.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let detail = message.detail, !detail.isEmpty {
                    Text(detail).font(context.font(role: "caption")).foregroundStyle(context.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if message.needsApproval || message.canUndoTheme || message.moduleID != nil {
                    HStack(spacing: context.metrics.unit * 2) {
                        if message.needsApproval {
                            Button("Review Permissions") { model.onChatCommand("review", message) }
                                .buttonStyle(TokenButtonStyle(context: context, style: "primary"))
                                .focusable(false)
                                .keyboardOperable(context, focusKey: "review") { model.onChatCommand("review", message) }
                                .fixedSize()
                        } else if message.moduleID != nil {
                            Button("Open") { model.onChatCommand("open", message) }
                                .buttonStyle(TokenButtonStyle(context: context, style: "secondary"))
                                .focusable(false)
                                .keyboardOperable(context, focusKey: "open") { model.onChatCommand("open", message) }
                                .fixedSize()
                        }
                        if message.canUndoTheme {
                            Button("Undo") { model.onChatCommand("undo", message) }
                                .buttonStyle(TokenButtonStyle(context: context, style: "secondary"))
                                .focusable(false)
                                .keyboardOperable(context, focusKey: "undo") { model.onChatCommand("undo", message) }
                                .fixedSize()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
