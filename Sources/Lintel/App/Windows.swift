import AppKit
import Carbon.HIToolbox
import LintelCore
import SwiftUI

final class Hotkey {
    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var nextIdentifier: UInt32 = 1

    init?(shortcut: Shortcut, action: @escaping () -> Void) {
        self.action = action
        let identifier = EventHotKeyID(signature: OSType(0x4C4E_544C), id: Self.nextIdentifier)
        Self.nextIdentifier += 1
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var fired = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &fired
            )
            let hotkey = Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue()
            // Every handler sees every hotkey of the app; only the one that registered this key may act.
            guard fired.id == hotkey.identifier else { return OSStatus(eventNotHandledErr) }
            hotkey.action()
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        self.identifier = identifier.id
        guard installed == noErr,
              RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), identifier, GetApplicationEventTarget(), 0, &registration) == noErr
        else { return nil }
    }

    private var identifier: UInt32 = 0

    deinit {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    // Without this the first click on a hover-activated bar only focuses the panel and the item ignores it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
func makeFloatingPanel(level: NSWindow.Level) -> FloatingPanel {
    let panel = FloatingPanel(
        contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    panel.level = level
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.isMovable = false
    return panel
}

@MainActor
final class BarWindowController {
    let panel: FloatingPanel
    private let model: BarModel
    private var activation = Activation()
    private var contentSize = CGSize(width: 1, height: 1)
    private var pointerTimer: Timer?
    private var hotkeys: [Hotkey] = []
    private var hasSteppedAside = false
    private var dragOrigin: CGPoint?
    var isPanelOpen: () -> Bool = { false }
    var panelFrame: () -> CGRect? = { nil }
    var onActiveChanged: (Bool) -> Void = { _ in }
    var onAnchorChanged: (BarAnchor) -> Void = { _ in }
    var onHideToggled: () -> Void = {}
    var onAssistantHotkey: () -> Void = {}
    var onSystemMenuBarRevealed: () -> Void = {}

    init(model: BarModel) {
        self.model = model
        panel = makeFloatingPanel(level: .statusBar)
        panel.ignoresMouseEvents = true
        let hostingView = FirstClickHostingView(rootView: BarView(model: model))
        // Left on, the hosting view resizes the window itself and moves it off the top edge.
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        model.onContentSize = { [weak self] size in
            self?.contentSize = CGSize(width: ceil(size.width), height: ceil(size.height))
            self?.place()
        }
        model.onDragChanged = { [weak self] translation in self?.drag(translation) }
        model.onDragEnded = { [weak self] _ in self?.endDrag() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } }
        // macOS shrinks windows created while the screen is locked toward the centre; re-place on unlock and wake.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } }

        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        applySettings()
        place()
        panel.orderFrontRegardless()
    }

    func applySettings() {
        activation.dwell = model.settings.dwell
        activation.grace = model.settings.grace
        hotkeys = []
        if let toggle = Hotkey(shortcut: model.settings.toggleShortcut, action: { [weak self] in
            MainActor.assumeIsolated { self?.onAssistantHotkey() }
        }) { hotkeys.append(toggle) }
        if let hide = Hotkey(shortcut: model.settings.hideShortcut, action: { [weak self] in
            MainActor.assumeIsolated { self?.onHideToggled() }
        }) { hotkeys.append(hide) }
        place()
    }

    var isHeld: Bool { activation.state == .held }

    func hold() {
        activation.hold()
        applyActivation()
    }

    func release() {
        activation.release()
        applyActivation()
        if panel.isKeyWindow { panel.resignKey() }
    }

    func unhold() {
        activation.unhold(at: ProcessInfo.processInfo.systemUptime)
        applyActivation()
    }

    func setHidden(_ isHidden: Bool) {
        model.isHiddenByUser = isHidden
        if isHidden { release() }
        panel.animator().alphaValue = isHidden || hasSteppedAside ? 0 : 1
        panel.ignoresMouseEvents = isHidden || !activation.isActive
    }

    func yieldFocusForExternalMenu() {
        release()
    }

    private var menuBarAutoHides: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["_HIHideMenuBar"] as? Bool ?? false
    }

    private func stepAsideForSystemMenuBar() {
        let isRevealed = menuBarAutoHides && MenuBarItems.isSystemMenuBarRevealed()
        guard isRevealed != hasSteppedAside else { return }
        hasSteppedAside = isRevealed
        panel.animator().alphaValue = isRevealed || model.isHiddenByUser ? 0 : 1
        if isRevealed, !isPanelOpen() { release() }
        if isRevealed { onSystemMenuBarRevealed() }
    }

    private var pointerTicks = 0

    private func trackPointer() {
        pointerTicks += 1
        // Listing every window is the costly part of each tick, and the menu bar only slides in while the pointer
        // is at the top edge; elsewhere an occasional look is enough to notice it leaving.
        let isNearTop = NSEvent.mouseLocation.y > (screen?.frame.maxY ?? 0) - 48
        if isNearTop || hasSteppedAside || pointerTicks % 20 == 0 { stepAsideForSystemMenuBar() }
        guard !hasSteppedAside, !model.isHiddenByUser, dragOrigin == nil, model.rearrangement == nil else { return }
        let pointer = NSEvent.mouseLocation
        var isInside = panel.frame.insetBy(dx: -2, dy: -2).contains(pointer)
        if activation.isActive, let frame = panelFrame(), frame.insetBy(dx: -4, dy: -10).contains(pointer) { isInside = true }
        if !model.settings.hoverActivates, activation.state == .idle { isInside = false }
        // A pressed mouse button means a drag or selection is passing over the bar, not a visit to it.
        if activation.state == .idle, NSEvent.pressedMouseButtons != 0 { isInside = false }
        activation.pointer(inside: isInside, at: ProcessInfo.processInfo.systemUptime)
        applyActivation()
    }

    private func applyActivation() {
        guard model.isActive != activation.isActive else { return }
        model.isActive = activation.isActive
        panel.ignoresMouseEvents = !activation.isActive
        if !activation.isActive, panel.isKeyWindow { panel.resignKey() }
        onActiveChanged(activation.isActive)
    }

    var screen: NSScreen? { NSScreen.screens.first }

    private var geometry: ScreenGeometry? {
        guard let screen else { return nil }
        return ScreenGeometry(
            frame: screen.frame, visibleFrame: screen.visibleFrame, notchStripHeight: screen.safeAreaInsets.top,
            areaLeftOfNotch: screen.auxiliaryTopLeftArea, areaRightOfNotch: screen.auxiliaryTopRightArea,
            menuBarAutoHides: menuBarAutoHides
        )
    }

    func place() {
        guard let geometry, dragOrigin == nil else { return }
        let widest = max(geometry.frame.width * 0.62 - 16, 320)
        if model.maxBarWidth != widest { model.maxBarWidth = widest }
        let placement = Placement.bar(
            contentSize: contentSize, on: geometry, anchor: model.settings.anchor, edgeInset: model.settings.edgeInset
        )
        if model.topRowMinHeight != placement.topRowMinHeight { model.topRowMinHeight = placement.topRowMinHeight }
        if panel.frame != placement.frame { panel.setFrame(placement.frame, display: true) }
    }

    private func drag(_ translation: CGSize) {
        if dragOrigin == nil { dragOrigin = panel.frame.origin }
        guard let origin = dragOrigin, let screen else { return }
        let x = min(max(origin.x + translation.width, screen.frame.minX), screen.frame.maxX - panel.frame.width)
        panel.setFrameOrigin(CGPoint(x: x, y: origin.y))
    }

    private func endDrag() {
        guard dragOrigin != nil, let geometry else { return }
        dragOrigin = nil
        let anchor = Placement.anchor(forDropAt: panel.frame.midX, on: geometry)
        if anchor != model.settings.anchor { onAnchorChanged(anchor) }
        place()
    }

    /// Chip frames are reported in the bar window's top-left coordinates; panels are placed in screen coordinates.
    func screenFrame(ofSlot id: String) -> CGRect? {
        guard let frame = model.slotFrames[id] else { return nil }
        return CGRect(
            x: panel.frame.minX + frame.minX, y: panel.frame.maxY - frame.maxY, width: frame.width, height: frame.height
        )
    }
}

@MainActor
final class PanelWindowController {
    let panel: FloatingPanel
    private let model: BarModel
    private let bar: BarWindowController
    private var contentSize = CGSize(width: 300, height: 200)
    private var clickMonitor: Any?
    private var localMonitor: Any?
    var onClickOutside: () -> Void = {}

    init(model: BarModel, bar: BarWindowController) {
        self.model = model
        self.bar = bar
        panel = makeFloatingPanel(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        let maxHeight = (bar.screen?.visibleFrame.height ?? 800) * 0.78
        let hostingView = FirstClickHostingView(rootView: PanelView(model: model, maxHeight: maxHeight) { [weak self] size in
            self?.contentSize = size
            self?.place()
        })
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.panel != nil else { return }
                let pointer = NSEvent.mouseLocation
                if !self.visibleFrame.contains(pointer), !self.bar.panel.frame.contains(pointer) { self.onClickOutside() }
            }
        }
    }

    /// The window is larger than the panel by a margin that leaves room for its shadow.
    var visibleFrame: CGRect {
        panel.frame.insetBy(dx: PanelView.margin, dy: PanelView.margin)
    }

    var isVisible: Bool { panel.isVisible }

    func show(focus: Bool) {
        place()
        panel.orderFrontRegardless()
        if focus { panel.makeKeyAndOrderFront(nil) }
    }

    func hide() {
        if panel.isKeyWindow { panel.resignKey() }
        panel.orderOut(nil)
    }

    func place() {
        guard let state = model.panel, let screen = bar.screen else { return }
        let chip = bar.screenFrame(ofSlot: state.slotID) ?? bar.panel.frame
        let frame = Placement.panel(size: contentSize, under: chip, on: screen.visibleFrame.union(bar.panel.frame), gap: 6)
        let padded = frame.insetBy(dx: -PanelView.margin, dy: -PanelView.margin)
        if panel.frame != padded { panel.setFrame(padded, display: true) }
    }
}
