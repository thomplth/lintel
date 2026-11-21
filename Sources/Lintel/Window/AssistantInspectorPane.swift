import AppKit
import LintelCore
import SwiftUI

struct AssistantInspectorPane: View {
    let app: AppController
    let controller: MainWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var state: MainWindowState
    @FocusState private var isComposerFocused: Bool

    private var focusedListing: ModuleListing? {
        guard let id = model.studioFocusedModuleID else { return nil }
        return state.listings.first { $0.id == id }
    }

    private var quickPrompts: [String] {
        if let focused = focusedListing {
            if let err = focused.failure {
                return ["Fix this error: \(err.prefix(80))", "Add a scheduled background job to \(focused.title)", "Improve the panel layout"]
            }
            return ["Add a scheduled job to \(focused.title)", "Add error alerts to \(focused.title)", "Refine \(focused.title)'s bar chip"]
        }
        switch state.selection {
        case .appearance:
            return [
                "Switch to the Ink look",
                "Make the text a little bigger",
                "Give the bar a warm amber accent",
            ]
        case .barLayout:
            return [
                "Put the clock on its own row",
                "Pin battery and network so they always show",
                "Show weather in the bar",
            ]
        default:
            return [
                "Build a module with a scheduled background job",
                "Switch to the Ink look",
                "Add a module with the Bitcoin price",
            ]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Assistant").font(.headline)
                    if !model.engineName.isEmpty {
                        Button {
                            state.selection = .assistant
                        } label: {
                            HStack(spacing: 3) {
                                Text(model.engineName).lineLimit(1)
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Configure Assistant model in Settings › Assistant")
                    }
                }
                Spacer()
                if model.isChatBusy {
                    ProgressView().controlSize(.small)
                }
                Button {
                    app.chat.command("clear", nil)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear conversation")
                .disabled(model.chat.isEmpty || model.isChatBusy)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if let focused = focusedListing {
                HStack(spacing: 6) {
                    Image(systemName: focused.icon).font(.caption).foregroundStyle(.tint)
                    Text("Context: \(focused.title)").font(.caption).lineLimit(1)
                    Spacer()
                    Button {
                        model.studioFocusedModuleID = nil
                    } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Chat globally instead of focusing \(focused.title)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.chat.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Restyle the bar, rearrange items, or build and debug modules here. Selecting a module shares its source, job status, and recent logs automatically.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                ForEach(quickPrompts, id: \.self) { prompt in
                                    Button {
                                        submit(prompt)
                                    } label: {
                                        HStack {
                                            Text(prompt).font(.footnote).multilineTextAlignment(.leading)
                                            Spacer(minLength: 6)
                                            Image(systemName: "arrow.up.left").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 4)
                        }

                        ForEach(model.chat) { message in
                            chatBubble(message).id(message.id)
                        }

                        if model.isChatBusy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(model.chatActivity.isEmpty ? "Thinking…" : model.chatActivity)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .id("studio-activity")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.chat.count) { scroll(proxy) }
                .onChange(of: model.isChatBusy) { scroll(proxy) }
                .onAppear { scroll(proxy) }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    focusedListing.map { "Change \($0.title)…" } ?? "Build a module or change the bar…",
                    text: $model.chatDraft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .onSubmit { submit(model.chatDraft) }

                Button {
                    submit(model.chatDraft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isChatBusy
                                ? Color.secondary.opacity(0.4)
                                : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.isChatBusy || model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .onChange(of: model.chatFocusRequests) { isComposerFocused = true }
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !model.isChatBusy else { return }
        model.chatDraft = ""
        app.chat.submit(trimmed)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if model.isChatBusy {
                proxy.scrollTo("studio-activity", anchor: .bottom)
            } else if let last = model.chat.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder private func chatBubble(_ message: ChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 28)
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(message.isError ? Color.red : Color.primary)
                    .textSelection(.enabled)
                if let detail = message.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if message.needsApproval || message.canUndoTheme || message.moduleID != nil {
                    let pendingApproval = message.needsApproval && message.moduleID.map { model.slot($0)?.needsApproval == true } == true
                    HStack(spacing: 8) {
                        if pendingApproval, let id = message.moduleID {
                            Button("Allow Permissions") {
                                app.host.approve(id)
                                app.chat.markApproved(id)
                                state.selection = .module(id)
                                controller.refresh()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.refresh() }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        } else if message.needsApproval {
                            Label("Allowed", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if let id = message.moduleID {
                            Button("Inspect") {
                                state.selection = .module(id)
                                controller.refresh()
                            }
                            .controlSize(.small)
                        }
                        if message.canUndoTheme {
                            Button("Undo Theme") { app.chat.command("undo", message) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
