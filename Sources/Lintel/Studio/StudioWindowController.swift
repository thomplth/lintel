import AppKit
import Combine
import LintelCore
import SwiftUI

enum StudioSelection: Hashable {
    case dashboard
    case module(String)

    var moduleID: String? {
        if case .module(let id) = self { return id }
        return nil
    }
}

enum StudioInspectorTab: String, CaseIterable, Identifiable {
    case overview, logs, code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview & Jobs"
        case .logs: "Logs"
        case .code: "Code"
        }
    }
}

@MainActor
final class StudioState: ObservableObject {
    @Published var selection: StudioSelection = .dashboard
    @Published var inspectorTab: StudioInspectorTab = .overview
    @Published var showAssistant = true
    @Published var listings: [ModuleListing] = []
    @Published var previewPanelNode: ViewNode?
    @Published var previewPanelFailure: String?
    @Published var previewIsLoading = false
    @Published var codeDraft = ""
    @Published var codeLoadedModuleID: String?
    @Published var codeDirty = false
    @Published var codeErrors: [String] = []
    @Published var codeWarnings: [String] = []
    @Published var codeStatus = ""
    @Published var tick = 0
}

@MainActor
final class StudioWindowController: NSObject, NSWindowDelegate {
    private unowned let app: AppController
    private(set) var window: NSWindow?
    let state = StudioState()
    private var refreshTimer: Timer?
    private var selectionCancellable: AnyCancellable?

    init(app: AppController) {
        self.app = app
        super.init()
        selectionCancellable = state.$selection.sink { [weak self] selection in
            guard let self else { return }
            self.app.model.studioFocusedModuleID = selection.moduleID
            if let id = selection.moduleID {
                self.loadCodeIfNeeded(for: id, force: false)
                self.refreshPreview(for: id)
            } else {
                self.state.previewPanelNode = nil
                self.state.previewPanelFailure = nil
            }
        }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(module id: String? = nil, tab: StudioInspectorTab? = nil, focusChat: Bool = false, draft: String? = nil) {
        if let id {
            state.selection = .module(id)
            app.model.studioFocusedModuleID = id
            loadCodeIfNeeded(for: id, force: false)
        }
        if let tab { state.inspectorTab = tab }
        if focusChat || draft != nil {
            state.showAssistant = true
        }
        if let draft {
            app.model.chatDraft = draft
        }

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Lintel Studio"
            window.minSize = NSSize(width: 920, height: 560)
            window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.delegate = self
            window.contentView = NSHostingView(rootView: StudioView(app: app, controller: self, model: app.model, jobs: app.host.jobs, state: state))
            if !window.setFrameUsingName("LintelStudio") { window.center() }
            window.setFrameAutosaveName("LintelStudio")
            self.window = window
        }

        refresh()
        startTimer()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if focusChat || draft != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.app.model.chatFocusRequests += 1
            }
        }
    }

    func refresh() {
        Task {
            state.listings = await app.host.listings()
            if let id = state.selection.moduleID {
                loadCodeIfNeeded(for: id, force: !state.codeDirty)
                refreshPreview(for: id)
            }
        }
        state.tick += 1
    }

    func notifyLogsChanged(for moduleID: String) {
        guard isVisible else { return }
        if state.selection.moduleID == moduleID || state.selection == .dashboard {
            state.tick += 1
        }
    }

    func refreshPreview(for id: String) {
        guard state.selection.moduleID == id else { return }
        state.previewIsLoading = true
        Task {
            let result = await app.host.previewPanel(of: id)
            guard state.selection.moduleID == id else { return }
            state.previewIsLoading = false
            state.previewPanelNode = result.node
            state.previewPanelFailure = result.failure
        }
    }

    func loadCodeIfNeeded(for id: String, force: Bool) {
        guard force || state.codeLoadedModuleID != id else { return }
        let listing = state.listings.first { $0.id == id }
        let source = app.host.source(of: id) ?? listing.flatMap { Resources.source(of: $0.file) } ?? ""
        state.codeDraft = source
        state.codeLoadedModuleID = id
        state.codeDirty = false
        state.codeErrors = []
        state.codeWarnings = []
        state.codeStatus = ""
    }

    func saveCode(for id: String) {
        let source = state.codeDraft
        state.codeStatus = "Validating…"
        state.codeErrors = []
        state.codeWarnings = []
        Task {
            let trial = await app.host.trial(source: source)
            state.codeWarnings = trial.problems.filter { $0.severity == .warning }.map(\.message)
            guard trial.errors.isEmpty, let manifest = trial.description?.manifest else {
                state.codeErrors = trial.errors
                state.codeStatus = "Not saved — fix errors below"
                return
            }
            guard manifest.id == id else {
                state.codeErrors = ["meta.id must stay '\(id)' (got '\(manifest.id)')"]
                state.codeStatus = "Not saved"
                return
            }
            do {
                try app.host.install(source: source, id: id, prompt: app.host.prompt(of: id))
                state.codeDirty = false
                state.codeStatus = "Saved & reloaded"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self = self] in
                    self?.refresh()
                }
            } catch {
                state.codeErrors = [ModuleFailure.describe(error)]
                state.codeStatus = "Save failed"
            }
        }
    }

    private func startTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.state.tick += 1
                if let id = self.state.selection.moduleID, self.state.inspectorTab == .overview {
                    self.refreshPreview(for: id)
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
