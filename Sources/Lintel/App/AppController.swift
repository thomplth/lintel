import AppKit
import Carbon.HIToolbox
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
    private(set) var mainWindow: MainWindowController?
    private var backdropSampler: BackdropSampler?
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
        model.onResizeWidget = { [weak self] id, box in
            if self?.model.temporaryExpandedWidget?.slotID == id {
                self?.bar?.collapseTemporaryWidget()
            }
            self?.host.setWidget(id, to: box)
        }
        model.onResizePeek = { [weak self] id, box in self?.host.setPeekBox(id, to: box) }
        model.onEnsureWidgetRendered = { [weak self] id in self?.host.ensureWidgetRendered(id) }
        model.onMoveWidget = { [weak self] id, drop in
            if self?.model.temporaryExpandedWidget?.slotID == id {
                self?.bar?.collapseTemporaryWidget()
            }
            self?.host.moveWidget(id, to: drop)
        }
        model.onToggleConfigure = { [weak self] id, isConfiguring, isPeek in
            self?.host.setConfiguring(id, isConfiguring: isConfiguring, isPeek: isPeek)
        }
        model.onWidgetCommand = { [weak self] id, command in self?.widgetCommand(id, command) }
        model.onWidgetClick = { [weak self] id in self?.bar?.expandWidgetTemporarily(id) }
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onPanelCommand = { [weak self] command in self?.panelCommand(command) }
        model.onChatSubmit = { [weak self] message in self?.chat.submit(message) }
        model.onChatCommand = { [weak self] command, message in self?.chat.command(command, message) }
        host.onSettingsChanged = { [weak self] in
            self?.bar?.applySettings()
            self?.refreshAssistantSlot()
            self?.applyDockPresence()
        }
        host.onModulesChanged = { [weak self] in
            guard let self, self.mainWindow?.isVisible == true else { return }
            self.mainWindow?.refresh()
        }
        services.onLogChanged = { [weak self] moduleID in
            self?.mainWindow?.notifyLogsChanged(for: moduleID)
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
        bar.onKeyboardHotkey = { [weak self] in self?.toggleKeyboardControl() }
        bar.onHideToggled = { [weak self] in
            self?.bar?.toggleHide()
        }
        bar.onWillHide = { [weak self] in
            self?.closePanel()
        }
        bar.onAnchorChanged = { [weak self] anchor in
            guard let self else { return }
            var settings = self.model.settings
            settings.anchor = anchor
            self.host.update(settings)
            self.backdropSampler?.requestSample(after: 0.15)
        }
        bar.onActiveChanged = { [weak self] isActive in
            if isActive {
                self?.adoption.scanIfNeeded(force: false)
            } else {
                self?.closePanel(releasing: false)
                self?.host.clearIdleConfigurations()
            }
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
        installBarKeys()
        adoption.start()
        let sampler = BackdropSampler(model: model, bar: bar, panelWindow: panelWindow)
        sampler.start()
        backdropSampler = sampler
        control = ControlChannel(app: self)
        perf.start()
        if Perf.isEnabled { modelChanges = model.objectWillChange.sink { Perf.count("model.change") } }
        applyDockPresence()
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endDockHold() }
        }
        if !model.settings.hasOnboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showWindow(.welcome) }
        }
    }

    // MARK: Dock

    private var isHeldByDock = false

    private func applyDockPresence() {
        let policy: NSApplication.ActivationPolicy = model.settings.showsInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let mainIsOpen = mainWindow?.isVisible == true
        NSApp.setActivationPolicy(policy)
        // Turning into an accessory app deactivates it, which would drop the main window the toggle sits in behind other apps.
        if mainIsOpen {
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.window?.makeKeyAndOrderFront(nil)
        }
    }

    func dockClicked() {
        switch DockClick.response(isBarOpen: model.isActive && !model.isHidden, hasMainWindow: mainWindow?.isVisible == true) {
        case .focusWindow:
            endDockHold()
            mainWindow?.focus()
        case .openBar:
            if model.isHidden { bar?.revealIfHidden() }
            isHeldByDock = true
            bar?.hold()
        case .openWindow:
            endDockHold()
            showWindow()
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

    // MARK: Keyboard

    func toggleKeyboardControl() {
        if model.isDrivenByKeyboard, model.panel == nil {
            model.isDrivenByKeyboard = false
            isHeldByDock = false
            bar?.release()
            return
        }
        if model.isHidden { bar?.revealIfHidden() }
        closePanel(releasing: false)
        bar?.takeKeyboardFocus()
        model.isDrivenByKeyboard = true
        let remembered = model.rememberedSelection
        let initial = BarSelection.resume(remembered, in: model.selectableRows)
        model.keyboardSelection = initial
        // Chips report their frames only once the opened bar has laid them out, so a module shown only while the bar
        // is open, which the remembered one may be, cannot be found until then.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.model.isDrivenByKeyboard, self.model.keyboardSelection == initial else { return }
            self.model.keyboardSelection = BarSelection.resume(remembered, in: self.model.selectableRows)
        }
    }

    private func installBarKeys() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.bar?.panel.isKeyWindow == true, self.model.isDrivenByKeyboard,
                  let key = BarKey(event), let command = self.model.settings.barKeys.command(for: key, modifiers: BarKey.Modifiers(event.modifierFlags))
            else { return event }
            self.perform(command)
            return nil
        }
    }

    private func perform(_ command: BarKey.Command) {
        let rows = model.selectableRowsWithWidgets
        let selected = model.keyboardSelection.flatMap { id in model.slot(id) }
        switch command {
        case .select(let step):
            if let bump = BarSelection.bump(step, from: model.keyboardSelection, in: rows) {
                if model.animatesSelection { model.bump(bump) } else { NSSound.beep() }
            }
            model.keyboardSelection = BarSelection.step(step, from: model.keyboardSelection, in: rows)
        case .open:
            guard let selected, selected.isClickable else { return NSSound.beep() }
            openFromKeyboard(selected)
        case .openAt(let position):
            let order = rows.joined().map(\.key)
            guard order.indices.contains(position), let slot = model.slot(order[position]) else { return NSSound.beep() }
            model.keyboardSelection = slot.id
            if slot.isClickable { openFromKeyboard(slot) }
        case .edit(let name):
            guard let selected, selected.kind != .assistant else { return NSSound.beep() }
            if name == "hide" { model.keyboardSelection = BarSelection.step(.next, from: selected.id, in: rows) }
            edit(selected, name)
        case .assistant:
            openAssistant()
        case .settings:
            closePanel()
            showWindow(.general)
        case .close:
            dismiss()
        }
    }

    private func openFromKeyboard(_ slot: Slot) {
        model.onSlotClick(slot)
        if model.panel?.slotID == slot.id, model.panel?.content == .module { model.panelFocus.arm(slot.id) }
    }

    // MARK: Panels

    private func clicked(_ slot: Slot) {
        if model.isDrivenByKeyboard, slot.kind != .pinDivider { model.keyboardSelection = slot.id }
        switch slot.kind {
        case .assistant:
            toggleAssistant()
        case .menuBarItem:
            closePanel(releasing: false)
            bar?.yieldFocusForExternalMenu()
            adoption.press(slot.id)
        case .module:
            if model.layout.isWidget(slot.id) {
                if model.temporaryExpandedWidget?.slotID == slot.id {
                    bar?.collapseTemporaryWidget()
                } else {
                    bar?.expandWidgetTemporarily(slot.id)
                }
            } else if model.panel?.slotID == slot.id {
                closePanel()
            } else {
                openModulePanel(slot.id)
            }
        case .pinDivider:
            break
        }
    }

    func openModulePanel(_ id: String) {
        guard model.slot(id) != nil else { return }
        bar?.collapseTemporaryWidget()
        host.closePanel()
        let corner = bar?.peekCorner(forSlot: id) ?? WidgetResize.corner(for: model.settings.anchor)
        host.openPanel(id, corner: corner)
        bar?.hold()
        // Key, so that fields in the panel take typing and Escape closes it; the app itself is never activated.
        panelWindow?.show(focus: true)
    }

    func toggleAssistant() {
        if mainWindow?.isVisible == true, mainWindow?.window?.isKeyWindow == true, mainWindow?.state.showAssistant == true {
            mainWindow?.close()
        } else {
            openAssistant()
        }
    }

    func openAssistant(draft: String? = nil) {
        closePanel()
        showWindow(focusChat: true, draft: draft)
    }

    func showWindow(
        _ destination: MainWindowSection? = nil,
        inspectorTab: ModuleInspectorTab? = nil,
        showAssistant: Bool? = nil,
        focusChat: Bool = false,
        draft: String? = nil
    ) {
        if mainWindow == nil { mainWindow = MainWindowController(app: self) }
        mainWindow?.show(destination, inspectorTab: inspectorTab, showAssistant: showAssistant, focusChat: focusChat, draft: draft)
    }

    func closeMainWindow() {
        mainWindow?.close()
    }

    func closePanel(releasing: Bool = true) {
        guard model.panel != nil else { return }
        model.panelFocus.disarm()
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
        if model.panel != nil, model.isDrivenByKeyboard {
            closePanel(releasing: false)
            bar?.takeKeyboardFocus()
        } else if model.panel != nil { closePanel() } else if model.temporaryExpandedWidget != nil {
            bar?.collapseTemporaryWidget()
        } else {
            isHeldByDock = false
            bar?.release()
        }
    }

    private func panelCommand(_ command: String) {
        guard let id = model.panel?.slotID else { return }
        switch command {
        case "approve":
            host.approve(id)
            chat.markApproved(id)
        case "remove":
            closePanel()
            host.remove(id)
        case "fix":
            let failure = model.slot(id)?.failure ?? model.panel?.failure ?? "it fails"
            closePanel()
            showWindow(.module(id), focusChat: true)
            chat.submit("Fix the module \"\(id)\". It fails with: \(failure)")
        case "change":
            closePanel()
            showWindow(.module(id), focusChat: true)
        case "studio":
            closePanel()
            showWindow(.module(id))
        case "source":
            closePanel()
            showWindow(.module(id), inspectorTab: .code)
        case "settings":
            let destination: MainWindowSection = model.panel?.content == .assistant ? .assistant : .general
            closePanel()
            showWindow(destination)
        case "pin-widget":
            let shape = model.slot(id)?.defaultShape ?? .card
            let box = model.panel?.widgetBox ?? Metrics(model.theme).defaultWidgetBox(for: shape)
            closePanel()
            host.setWidget(id, to: box)
        default:
            break
        }
    }

    private func widgetCommand(_ id: String, _ command: String) {
        switch command {
        case "collapse":
            if model.temporaryExpandedWidget?.slotID == id {
                bar?.collapseTemporaryWidget()
            }
            host.setWidget(id, to: nil)
        case "stack-up":
            var layout = model.layout
            layout.moveWidgetInStack(id, offset: -1)
            host.update(layout)
        case "stack-down":
            var layout = model.layout
            layout.moveWidgetInStack(id, offset: 1)
            host.update(layout)
        case "stack-next":
            var layout = model.layout
            layout.stackWidgetWithColumn(id, offset: 1)
            host.update(layout)
        case "stack-prev":
            var layout = model.layout
            layout.stackWidgetWithColumn(id, offset: -1)
            host.update(layout)
        case "unstack":
            var layout = model.layout
            layout.unstackWidget(id)
            host.update(layout)
        case "change":
            closePanel()
            showWindow(.module(id), focusChat: true)
        case "settings":
            closePanel()
            showWindow(.general)
        default:
            break
        }
    }

    private func edit(_ slot: Slot, _ command: String) {
        if command == "expand" {
            guard slot.supportsResize else { return }
            let box = Metrics(model.theme).defaultWidgetBox(for: slot.defaultShape)
            host.setWidget(slot.id, to: box)
            return
        }
        if command == "grow" || command == "shrink" {
            guard slot.supportsResize else { return }
            let current = model.layout.widgetBox(of: slot.id)
            let target = WidgetResize.step(
                from: current,
                delta: command == "grow" ? 1 : -1,
                defaultShape: slot.defaultShape,
                metrics: Metrics(model.theme)
            )
            if target != current { host.setWidget(slot.id, to: target) }
            return
        }
        var layout = model.layout
        layout.materialise(model.layoutItems.filter { item in
            !item.isOptIn || layout.rows.contains { $0.contains(item.key) }
        }, keepsFirstRow: model.isFirstRowInMenuBar)
        switch command {
        case "pin": layout.pinned[slot.id] = !layout.isPinned(slot.id, default: slot.isPinned)
        case "hide": layout.setHidden(slot.id, true, keepsFirstRow: model.isFirstRowInMenuBar)
        case "left": layout.shift(slot.id, by: -1)
        case "right": layout.shift(slot.id, by: 1)
        case "up": layout.moveToRow(slot.id, offset: -1)
        case "down": layout.moveToRow(slot.id, offset: 1)
        case "change":
            closePanel()
            showWindow(.module(slot.id), focusChat: true)
            return
        case "settings":
            closePanel()
            showWindow(.barLayout)
            return
        default: return
        }
        host.update(layout)
        adoption.refreshSlots()
        adoption.scanIfNeeded(force: false)
    }

    /// `rows` hold every module the open bar showed, as it showed them, so they replace the saved rows outright.
    private func rearrange(rows: [[String]], pins: [String: Bool], hiding: String?) {
        var layout = model.layout
        layout.rows = rows
        layout.pinned.merge(pins) { _, new in new }
        if let hiding { layout.setHidden(hiding, true, keepsFirstRow: model.isFirstRowInMenuBar) }
        host.update(layout)
        adoption.refreshSlots()
        adoption.scanIfNeeded(force: false)
    }

    var windows: [(name: String, window: NSWindow)] {
        var result: [(String, NSWindow)] = []
        if let bar { result.append(("bar", bar.panel)) }
        if let panelWindow, panelWindow.isVisible { result.append(("panel", panelWindow.panel)) }
        if let window = mainWindow?.window, window.isVisible { result.append(("main", window)) }
        return result
    }
}

extension BarKey {
    init?(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_LeftArrow: self = .left
        case kVK_RightArrow: self = .right
        case kVK_UpArrow: self = .up
        case kVK_DownArrow: self = .down
        case kVK_Tab: self = .tab
        case kVK_Home: self = .home
        case kVK_End: self = .end
        case kVK_Return, kVK_ANSI_KeypadEnter: self = .return
        case kVK_Space: self = .space
        case kVK_Delete, kVK_ForwardDelete: self = .delete
        case kVK_Escape: self = .escape
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
            self = .character(character)
        }
    }
}

extension BarKey.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }
}
