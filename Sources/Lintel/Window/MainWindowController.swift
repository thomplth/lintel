import AppKit
import Combine
import LintelCore
import SwiftUI

@MainActor
final class MainWindowState: ObservableObject {
    @Published var selection: MainWindowSection = .dashboard
    @Published var inspectorTab: ModuleInspectorTab = .overview
    @Published var showAssistant = true

    // Workspace & module state
    @Published var listings: [ModuleListing] = []
    @Published var previewPanelNode: ViewNode?
    @Published var previewPanelFailure: String?
    @Published var previewIsLoading = false
    @Published var configureNode: ViewNode?
    @Published var configureFailure: String?
    @Published var configureIsLoading = false
    @Published var codeDraft = ""
    @Published var codeLoadedModuleID: String?
    @Published var codeDirty = false
    @Published var codeErrors: [String] = []
    @Published var codeWarnings: [String] = []
    @Published var codeStatus = ""
    @Published var tick = 0

    // Bar layout & system settings state
    @Published var menuBarItems: [KnownMenuBarItem] = []
    @Published var trackedApps: [(bundle: String, isAllowed: Bool)] = []
    @Published var signedInSites: [String] = []
    @Published var secretNames: [String] = []
    @Published var notice = ""
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private unowned let app: AppController
    private(set) var window: NSWindow?
    let state = MainWindowState()
    private var refreshTimer: Timer?
    private var selectionCancellable: AnyCancellable?

    init(app: AppController) {
        self.app = app
        super.init()
        selectionCancellable = state.$selection.sink { [weak self] selection in
            guard let self else { return }
            self.app.model.studioFocusedModuleID = selection.moduleID
            self.app.adoption.wantsListing = self.isVisible && selection.wantsMenuBarListing
            if selection.wantsMenuBarListing {
                self.refreshMenuBarItems()
            }
            if let id = selection.moduleID {
                self.state.previewPanelNode = nil
                self.state.previewPanelFailure = nil
                self.state.configureNode = nil
                self.state.configureFailure = nil
                self.state.configureIsLoading = false
                self.loadCodeIfNeeded(for: id, force: false)
                self.refreshPreview(for: id)
                self.refreshConfigure(for: id)
            } else {
                self.state.previewPanelNode = nil
                self.state.previewPanelFailure = nil
                self.state.configureNode = nil
                self.state.configureFailure = nil
                self.state.configureIsLoading = false
            }
            self.syncTimer()
        }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(
        _ destination: MainWindowSection? = nil,
        inspectorTab: ModuleInspectorTab? = nil,
        showAssistant: Bool? = nil,
        focusChat: Bool = false,
        draft: String? = nil
    ) {
        if let destination {
            state.selection = destination
            app.model.studioFocusedModuleID = destination.moduleID
            if let id = destination.moduleID {
                loadCodeIfNeeded(for: id, force: false)
            }
            if showAssistant == nil, !focusChat, draft == nil, !destination.showsAssistantByDefault {
                state.showAssistant = false
            }
        }
        if let inspectorTab { state.inspectorTab = inspectorTab }
        if let showAssistant {
            state.showAssistant = showAssistant
        }
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
            window.title = "Lintel"
            window.minSize = NSSize(width: 900, height: 560)
            window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.delegate = self
            window.contentView = NSHostingView(
                rootView: MainWindowView(app: app, controller: self, model: app.model, jobs: app.host.jobs, state: state)
            )
            if !window.setFrameUsingName("LintelMain") {
                if !window.setFrameUsingName("LintelStudio") {
                    window.center()
                }
            }
            window.setFrameAutosaveName("LintelMain")
            self.window = window
        }

        app.adoption.wantsListing = state.selection.wantsMenuBarListing
        refresh()
        syncTimer()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if focusChat || draft != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.app.model.chatFocusRequests += 1
            }
        }
    }

    func focus() {
        guard let window else {
            show()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func refresh() {
        Task {
            state.listings = await app.host.listings()
            state.signedInSites = await BrowserHost.signedInHosts()
            if let id = state.selection.moduleID {
                loadCodeIfNeeded(for: id, force: !state.codeDirty)
                refreshPreview(for: id)
                refreshConfigure(for: id)
            }
        }
        state.secretNames = SecretStore(home: app.home).names.filter { $0 != ChatEngine.apiKeySecret }
        if state.selection.wantsMenuBarListing {
            refreshMenuBarItems()
        }
        state.tick += 1
    }

    func refreshMenuBarItems() {
        state.trackedApps = MenuBarItems.trackedApplications()
        app.adoption.scan { [weak self] in
            guard let self else { return }
            self.state.menuBarItems = self.app.adoption.listing
        }
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

    func refreshConfigure(for id: String) {
        guard state.selection.moduleID == id else { return }
        guard app.host.hasConfigure(of: id) else {
            state.configureIsLoading = false
            state.configureNode = nil
            state.configureFailure = nil
            return
        }
        let isInitial = state.configureNode == nil
        if isInitial { state.configureIsLoading = true }
        Task {
            let result = await app.host.previewConfigure(of: id)
            guard state.selection.moduleID == id else { return }
            state.configureIsLoading = false
            if state.configureNode != result.node { state.configureNode = result.node }
            if state.configureFailure != result.failure { state.configureFailure = result.failure }
        }
    }

    func refreshModule(_ id: String) {
        guard isVisible, state.selection.moduleID == id else { return }
        refreshPreview(for: id)
        refreshConfigure(for: id)
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

    private func syncTimer() {
        let shouldRun = isVisible && state.selection.wantsLivePreviewTimer
        if shouldRun {
            guard refreshTimer == nil else { return }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isVisible, self.state.selection.wantsLivePreviewTimer else {
                        self?.stopTimer()
                        return
                    }
                    self.state.tick += 1
                    if let id = self.state.selection.moduleID, self.state.inspectorTab == .overview {
                        self.refreshPreview(for: id)
                        if self.state.configureNode == nil, self.app.host.hasConfigure(of: id), !self.state.configureIsLoading {
                            self.refreshConfigure(for: id)
                        }
                    }
                }
            }
        } else {
            stopTimer()
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func windowWillClose(_ notification: Notification) {
        app.adoption.wantsListing = false
        stopTimer()
    }
}

enum ModuleSharing {
    @MainActor
    static func export(_ listing: ModuleListing, app: AppController) {
        guard let source = Resources.source(of: listing.file) else { return }
        let bundle = ModuleBundle(id: listing.id, title: listing.title, permissions: listing.permissions, prompt: app.host.prompt(of: listing.id), source: source)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(listing.id).\(ModuleBundle.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.home.save(bundle, to: url)
    }

    @MainActor
    static func importModule(app: AppController, from file: URL? = nil, completion: @escaping () -> Void = {}) {
        var url = file
        if url == nil {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.message = "Choose a .\(ModuleBundle.fileExtension) file or a module's .js file"
            guard panel.runModal() == .OK else { return }
            url = panel.url
        }
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let source = (try? JSONDecoder().decode(ModuleBundle.self, from: data))?.source ?? String(decoding: data, as: UTF8.self)
        let prompt = (try? JSONDecoder().decode(ModuleBundle.self, from: data))?.prompt
        Task {
            let trial = await app.host.trial(source: source)
            let alert = NSAlert()
            guard trial.errors.isEmpty, let manifest = trial.description?.manifest else {
                alert.messageText = "This module cannot be installed"
                alert.informativeText = trial.errors.prefix(4).joined(separator: "\n")
                alert.runModal()
                return
            }
            alert.messageText = "Install “\(manifest.title)”?"
            let asks = manifest.permissions.isEmpty
                ? "It asks for no permissions."
                : "It asks to:\n" + manifest.permissions.map { "• " + (Capability($0)?.explanation ?? "Contact \($0)") }.joined(separator: "\n") + "\n\nIt stays off until you allow that from the bar."
            alert.informativeText = "\(manifest.summary)\n\n\(asks)\n\nModules run code. Install only from people you trust\(prompt == nil ? "." : ", or ask the assistant to rebuild it from its original request:\n“\(prompt!.prefix(200))”")"
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try? app.host.install(source: source, id: manifest.id, prompt: prompt)
            completion()
        }
    }
}
