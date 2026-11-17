import AppKit
import Combine
import LintelCore
import SwiftUI

/// Wires the parts together: module host, menu bar adoption, chat, the bar and panel windows, and settings.
@MainActor
final class AppController {
    static let assistantSlot = "assistant"

    let home: AppHome
    let model = BarModel()
    let runner = RunnerClient()
    let browser = BrowserHost()
    let services: HostServices
    let host: ModuleHost
    let adoption: MenuBarAdoption
    private(set) var chat: ChatController!
    private(set) var bar: BarWindowController?
    private(set) var panelWindow: PanelWindowController?
    private var settingsWindow: SettingsWindowController?
    private var control: ControlChannel?
    let pointerTap = PointerTap()
    private(set) lazy var perf = PerfRecorder(home: home, runnerPID: { [runner] in runner.processIdentifier })
    private var modelChanges: AnyCancellable?

    init(home: AppHome) {
        self.home = home
        home.prepare()
        model.settings = home.loadSettings()
        model.theme = home.loadTheme()
        model.layout = home.loadLayout()
        services = HostServices(home: home, browser: browser, settings: model.settings)
        host = ModuleHost(home: home, model: model, runner: runner, services: services)
        adoption = MenuBarAdoption(model: model, home: home)
        chat = ChatController(app: self)
        model.chat = home.load([ChatMessage].self, from: home.chatFile) ?? []
        wire()
    }

    private func wire() {
        model.onAction = { [weak self] module, action, payload in
            Task { await self?.host.perform(module, action: action, payload: payload) }
        }
        model.onAppAction = { [weak self] module, action, payload in
            await self?.host.perform(module, action: action, payload: payload) ?? .null
        }
        model.onSlotClick = { [weak self] slot in self?.clicked(slot) }
        model.onSlotSecondaryAction = { [weak self] slot, command in self?.edit(slot, command) }
        model.onRearrange = { [weak self] rows, pins, hiding in self?.rearrange(rows: rows, pins: pins, hiding: hiding) }
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onPanelCommand = { [weak self] command in self?.panelCommand(command) }
        model.onChatSubmit = { [weak self] message in self?.chat.submit(message) }
        model.onChatCommand = { [weak self] command, message in self?.chat.command(command, message) }
        host.onSettingsChanged = { [weak self] in
            self?.bar?.applySettings()
            self?.refreshAssistantSlot()
            self?.applyDockPresence()
        }
    }

    func startModules(watching: Bool = true) {
        host.start(watching: watching)
        refreshAssistantSlot()
        chat.refreshEngineName()
    }

    func startInterface() {
        let bar = BarWindowController(model: model)
        self.bar = bar
        let panelWindow = PanelWindowController(model: model, bar: bar)
        self.panelWindow = panelWindow
        bar.isPanelOpen = { [weak self] in self?.model.panel != nil }
        bar.panelFrame = { [weak self] in
            guard let self, self.model.panel != nil else { return nil }
            return self.panelWindow?.visibleFrame
        }
        bar.onAssistantHotkey = { [weak self] in self?.toggleAssistant() }
        bar.onHideToggled = { [weak self] in
            guard let self else { return }
            self.closePanel()
            self.bar?.setHidden(!self.model.isHiddenByUser)
        }
        bar.onAnchorChanged = { [weak self] anchor in
            guard let self else { return }
            var settings = self.model.settings
            settings.anchor = anchor
            self.host.update(settings)
        }
        bar.onActiveChanged = { [weak self] isActive in
            if !isActive { self?.closePanel(releasing: false) }
        }
        bar.onSystemMenuBarRevealed = { [weak self] in self?.adoption.systemMenuBarRevealed() }
        bar.onGuardedTopEdgeChanged = { [weak self] span in self?.pointerTap.guardSpan(span) }
        bar.onMenuBarRowFrameChanged = { [weak self] frame in
            let height = NSScreen.screens.first?.frame.height ?? 0
            self?.pointerTap.takeCommandOffPresses(in: frame.map { Placement.globalDisplayRect($0, mainScreenHeight: height) })
        }
        pointerTap.guardSpan(bar.guardedTopEdge)
        pointerTap.start()
        panelWindow.onClickOutside = { [weak self] in self?.closePanel() }
        installEscapeHandling()
        adoption.start()
        control = ControlChannel(app: self)
        perf.start()
        if Perf.isEnabled { modelChanges = model.objectWillChange.sink { Perf.count("model.change") } }
        applyDockPresence()
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endDockHold() }
        }
        if !model.settings.hasOnboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showSettings(tab: .welcome) }
        }
    }

    // MARK: Dock

    private var isHeldByDock = false

    private func applyDockPresence() {
        let policy: NSApplication.ActivationPolicy = model.settings.showsInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let settingsIsOpen = settingsWindow?.window?.isVisible == true
        NSApp.setActivationPolicy(policy)
        // Turning into an accessory app deactivates it, which would drop the Settings window the toggle sits in behind other apps.
        if settingsIsOpen {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow?.window?.makeKeyAndOrderFront(nil)
        }
    }

    func dockClicked() {
        switch DockClick.response(isBarOpen: model.isActive && !model.isHiddenByUser) {
        case .openBar:
            if model.isHiddenByUser { bar?.setHidden(false) }
            isHeldByDock = true
            bar?.hold()
        case .openSettings:
            endDockHold()
            showSettings(tab: .general)
        }
    }

    private func endDockHold() {
        guard isHeldByDock else { return }
        isHeldByDock = false
        if model.panel == nil { bar?.unhold() }
    }

    private func refreshAssistantSlot() {
        let exists = model.slots.contains { $0.kind == .assistant }
        if model.settings.showsAssistant, !exists {
            var slot = Slot(id: Self.assistantSlot, kind: .assistant, title: "Assistant")
            slot.icon = "sparkles"
            slot.order = 5
            model.slots.append(slot)
        } else if !model.settings.showsAssistant, exists {
            model.slots.removeAll { $0.kind == .assistant }
        }
    }

    // MARK: Panels

    private func clicked(_ slot: Slot) {
        switch slot.kind {
        case .assistant:
            toggleAssistant()
        case .menuBarItem:
            closePanel(releasing: false)
            bar?.yieldFocusForExternalMenu()
            adoption.press(slot.id)
        case .module:
            if model.panel?.slotID == slot.id { closePanel() } else { openModulePanel(slot.id) }
        case .pinDivider:
            break
        }
    }

    func openModulePanel(_ id: String) {
        guard model.slot(id) != nil else { return }
        host.closePanel()
        host.openPanel(id)
        bar?.hold()
        // Key, so that fields in the panel take typing and Escape closes it; the app itself is never activated.
        panelWindow?.show(focus: true)
    }

    func toggleAssistant() {
        if model.panel?.content == .assistant { closePanel() } else { openAssistant() }
    }

    func openAssistant(draft: String? = nil) {
        if model.isHiddenByUser { bar?.setHidden(false) }
        host.closePanel()
        bar?.hold()
        if let draft { model.chatDraft = draft }
        // The chip only exists once the bar is active, so the panel is placed after the layout settles.
        model.panel = PanelState(slotID: Self.assistantSlot, content: .assistant)
        // Taking keyboard focus must happen inside the hotkey's own event; a moment later macOS no longer grants it
        // to an app that is not active, and typing would land in whatever app is in front.
        panelWindow?.show(focus: true)
        model.chatFocusRequests += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.model.panel?.content == .assistant else { return }
            self.panelWindow?.place()
            self.model.chatFocusRequests += 1
        }
    }

    func closePanel(releasing: Bool = true) {
        guard model.panel != nil else { return }
        host.closePanel()
        panelWindow?.hide()
        if releasing, !isHeldByDock { bar?.unhold() }
    }

    private func installEscapeHandling() {
        // SwiftUI's exit command only fires while one of its controls has focus; after a button click nothing does.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            let ownsKey = self.bar?.panel.isKeyWindow == true || self.panelWindow?.panel.isKeyWindow == true
            guard ownsKey, self.model.panel != nil || self.model.isActive else { return event }
            self.dismiss()
            return nil
        }
    }

    private func dismiss() {
        if model.panel != nil { closePanel() } else {
            isHeldByDock = false
            bar?.release()
        }
    }

    private func panelCommand(_ command: String) {
        guard let id = model.panel?.slotID else { return }
        switch command {
        case "approve":
            host.approve(id)
        case "remove":
            closePanel()
            host.remove(id)
        case "fix":
            let failure = model.slot(id)?.failure ?? model.panel?.failure ?? "it fails"
            openAssistant()
            chat.submit("Fix the module \"\(id)\". It fails with: \(failure)")
        case "change":
            openAssistant(draft: "Change the \(model.slot(id)?.title ?? id) module: ")
        case "source":
            NSWorkspace.shared.activateFileViewerSelecting([home.moduleFile(id: id)])
        case "settings":
            let tab: SettingsTab = model.panel?.content == .assistant ? .assistant : .modules
            closePanel()
            showSettings(tab: tab)
        default:
            break
        }
    }

    private func edit(_ slot: Slot, _ command: String) {
        var layout = model.layout
        layout.materialise(model.layoutItems.filter { item in
            !item.isOptIn || layout.rows.contains { $0.contains(item.key) }
        })
        switch command {
        case "pin": layout.pinned[slot.id] = !layout.isPinned(slot.id, default: slot.isPinned)
        case "hide": layout.setHidden(slot.id, true)
        case "left": layout.shift(slot.id, by: -1)
        case "right": layout.shift(slot.id, by: 1)
        case "up": layout.moveToRow(slot.id, offset: -1)
        case "down": layout.moveToRow(slot.id, offset: 1)
        case "change":
            openAssistant(draft: "Change the \(slot.title) module: ")
            return
        case "settings":
            closePanel()
            showSettings(tab: .items)
            return
        default: return
        }
        host.update(layout)
        adoption.refreshSlots()
    }

    /// `rows` hold every module the open bar showed, as it showed them, so they replace the saved rows outright.
    private func rearrange(rows: [[String]], pins: [String: Bool], hiding: String?) {
        var layout = model.layout
        layout.rows = rows
        layout.pinned.merge(pins) { _, new in new }
        if let hiding { layout.setHidden(hiding, true) }
        host.update(layout)
        adoption.refreshSlots()
    }

    func showSettings(tab: SettingsTab) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.show(tab: tab)
    }

    var windows: [(name: String, window: NSWindow)] {
        var result: [(String, NSWindow)] = []
        if let bar { result.append(("bar", bar.panel)) }
        if let panelWindow, panelWindow.isVisible { result.append(("panel", panelWindow.panel)) }
        if let window = settingsWindow?.window, window.isVisible { result.append(("settings", window)) }
        return result
    }
}
