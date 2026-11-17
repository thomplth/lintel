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
    /// The stretch of the top edge kept from revealing the system menu bar.
    private(set) var guardedTopEdge: ClosedRange<CGFloat>? {
        didSet { if guardedTopEdge != oldValue { onGuardedTopEdgeChanged(guardedTopEdge) } }
    }
    var onGuardedTopEdgeChanged: (ClosedRange<CGFloat>?) -> Void = { _ in }
    private var menuBarRow: MenuBarRow?
    private var menuBarRowSize = CGSize(width: 16, height: 22)
    private var menuBarRowFrame: CGRect? {
        didSet { if menuBarRowFrame != oldValue { onMenuBarRowFrameChanged(menuBarRowFrame) } }
    }
    var onMenuBarRowFrameChanged: (CGRect?) -> Void = { _ in }
    private var menuBarRowPress: Timer?
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
        model.onMenuBarRowContentSize = { [weak self] size in
            self?.menuBarRowSize = CGSize(width: ceil(size.width), height: ceil(size.height))
            self?.place()
        }
        model.onDragChanged = { [weak self] translation in self?.drag(translation) }
        model.onDragEnded = { [weak self] _ in self?.endDrag() }
        model.onRearrangingChanged = { [weak self] in self?.showCarrier() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } }
        // macOS shrinks windows created while the screen is locked toward the centre; re-place on unlock and wake.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }
        for name in ["com.apple.screenIsUnlocked", "AppleInterfaceMenuBarHidingChangedNotification"] {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }

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
        menuBarRow?.setHidden(isHidden)
        updateGuardedTopEdge()
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
        defer { updateGuardedTopEdge() }
        guard isRevealed != hasSteppedAside else { return }
        hasSteppedAside = isRevealed
        panel.animator().alphaValue = isRevealed || model.isHiddenByUser ? 0 : 1
        if isRevealed, !isPanelOpen() { release() }
        if isRevealed { onSystemMenuBarRevealed() }
    }

    private func updateGuardedTopEdge() {
        guard model.settings.guardsTopEdge, menuBarAutoHides, !hasSteppedAside, !model.isHiddenByUser, let screen else {
            guardedTopEdge = nil
            return
        }
        let others = NSScreen.screens.filter { $0 != screen }.map(\.frame)
        guardedTopEdge = TopEdgeGuard.span(
            of: panel.frame, on: screen.frame, besides: others, notchStripHeight: screen.safeAreaInsets.top
        )
    }

    private var pointerTicks = 0

    private func trackPointer() {
        pointerTicks += 1
        // Listing every window is the costly part of each tick, and the menu bar only slides in while the pointer
        // is at the top edge; elsewhere an occasional look is enough to notice it leaving.
        let isNearTop = NSEvent.mouseLocation.y > (screen?.frame.maxY ?? 0) - 48
        if isNearTop || hasSteppedAside || pointerTicks % 20 == 0 { stepAsideForSystemMenuBar() }
        // Other apps' items come and go beside the menu bar row and push it along.
        if let menuBarRow, menuBarRow.screenFrame != menuBarRowFrame { place() }
        if menuBarRow != nil, pointerTicks % 50 == 1 { measureMenuBarRowBudget() }
        guard !hasSteppedAside, !model.isHiddenByUser, dragOrigin == nil, model.rearrangement == nil else { return }
        let pointer = NSEvent.mouseLocation
        var isInside = panel.frame.insetBy(dx: -2, dy: -2).contains(pointer)
        if let menuBarRowFrame, menuBarRowFrame.contains(pointer) { isInside = true }
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
        updateMenuBarRow(wanted: !geometry.menuBarAutoHides)
        if let menuBarRow {
            placeUnderMenuBarRow(menuBarRow, on: geometry)
        } else {
            let placement = Placement.bar(
                contentSize: contentSize, on: geometry, anchor: model.settings.anchor, edgeInset: model.settings.edgeInset
            )
            if model.topRowMinHeight != placement.topRowMinHeight { model.topRowMinHeight = placement.topRowMinHeight }
            if panel.frame != placement.frame { panel.setFrame(placement.frame, display: true) }
            model.barWindowFrame = placement.frame
        }
        updateGuardedTopEdge()
    }

    private func updateMenuBarRow(wanted: Bool) {
        if wanted, menuBarRow == nil {
            let row = MenuBarRow(model: model)
            row.onPress = { [weak self] _ in self?.menuBarRowPressed() }
            row.setHidden(model.isHiddenByUser)
            menuBarRow = row
            measureMenuBarRowBudget()
        } else if !wanted, let row = menuBarRow {
            row.remove()
            menuBarRow = nil
            menuBarRowFrame = nil
        }
        if model.isFirstRowInMenuBar != wanted { model.isFirstRowInMenuBar = wanted }
    }

    /// The menu bar row may use the space between the notch, or the middle of a screen without one, and the
    /// leftmost of other apps' items; wider, macOS would hide the whole row behind the menu bar's overflow button.
    private func measureMenuBarRowBudget() {
        guard let screen else { return }
        let ownBundle = Bundle.main.bundleIdentifier ?? "pid-\(ProcessInfo.processInfo.processIdentifier)"
        let start = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
        // Measured on macOS 27: an item's window is 16 pt wider than its length, other items' Accessibility frames sit
        // 8 pt inside their windows, and macOS hides an item whose window comes within 18 pt of the notch. An item resized
        // right at that limit flickers out of the menu bar while macOS lays it out again, hence a few points to spare.
        let margin: CGFloat = 50
        MenuBarItems.scan { [weak self] items in
            guard let self else { return }
            let others = items.filter { $0.owner != ownBundle && $0.frame.width > 0 && $0.frame.minX >= start }
            let end = others.map(\.frame.minX).min() ?? screen.frame.maxX
            // Without Accessibility other apps' items stay out of sight; a narrow row is likelier to fit beside them.
            let budget = AXIsProcessTrusted() ? max(end - start - margin, 0) : 160
            if self.model.menuBarRowBudget != budget { self.model.menuBarRowBudget = budget }
        }
    }

    private func placeUnderMenuBarRow(_ row: MenuBarRow, on geometry: ScreenGeometry) {
        // A drag previews modules arriving before the row is fitted again; wider than the free space, macOS would hide
        // the whole item, so the row's leading modules, the ones that will overflow, are clipped meanwhile.
        row.fit(width: min(menuBarRowSize.width, model.menuBarRowBudget))
        menuBarRowFrame = row.screenFrame
        let menuBarHeight = geometry.frame.maxY - geometry.visibleFrame.maxY
        let item = menuBarRowFrame ?? CGRect(
            x: geometry.frame.maxX - menuBarRowSize.width, y: geometry.visibleFrame.maxY, width: menuBarRowSize.width, height: menuBarHeight
        )
        let size = CGSize(width: max(contentSize.width, 1), height: max(contentSize.height, 1))
        let frame = Placement.rows(contentSize: size, under: item, on: geometry, anchor: model.settings.anchor)
        if model.topRowMinHeight != 0 { model.topRowMinHeight = 0 }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        model.barWindowFrame = frame
        let offset = CGSize(width: item.minX - frame.minX, height: frame.maxY - item.maxY)
        model.menuBarRowOffset = offset
        model.menuBarRowBand = CGRect(origin: CGPoint(x: offset.width, y: offset.height), size: item.size)
    }

    /// The bar window's top-left coordinates, which chip frames and drops are measured in.
    private func barPoint(_ screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: screenPoint.x - panel.frame.minX, y: panel.frame.maxY - screenPoint.y)
    }

    /// A menu bar item receives the press and the release but none of the drags between them, so the menu bar row
    /// follows each press itself: a click opens the module, and a ⌘-drag carries it.
    private func menuBarRowPressed() {
        let start = NSEvent.mouseLocation
        guard model.rearrangement == nil, let pressed = model.slot(at: barPoint(start)) else { return }
        // The press arrives without ⌘, which PointerTap took off so macOS would not drag the item itself, and the
        // session's modifier state follows that press; only the keyboard's own state still has ⌘.
        let canCarry = CGEventSource.flagsState(.hidSystemState).contains(.maskCommand) && pressed.kind != .assistant
        if canCarry { hold() }
        var hasMoved = false
        menuBarRowPress?.invalidate()
        let follow = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let pointer = NSEvent.mouseLocation
                hasMoved = hasMoved || hypot(pointer.x - start.x, pointer.y - start.y) >= 4
                guard NSEvent.pressedMouseButtons & 1 == 0 else {
                    if canCarry, hasMoved, self.model.rearrangement == nil {
                        self.model.beginRearranging(pressed.id, grabbedAt: self.barPoint(start))
                    }
                    self.model.carry(to: self.barPoint(pointer))
                    return
                }
                timer.invalidate()
                if self.model.rearrangement != nil {
                    self.model.carry(to: self.barPoint(pointer))
                    self.model.drop()
                } else if !hasMoved, pressed.isClickable {
                    self.model.onSlotClick(pressed)
                }
                if canCarry { self.unhold() }
            }
        }
        RunLoop.main.add(follow, forMode: .common)
        menuBarRowPress = follow
    }

    private lazy var carrier: FloatingPanel = {
        let carrier = makeFloatingPanel(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2))
        carrier.ignoresMouseEvents = true
        let hostingView = NSHostingView(rootView: CarrierView(model: model))
        hostingView.sizingOptions = []
        carrier.contentView = hostingView
        return carrier
    }()

    private func showCarrier() {
        guard model.rearrangement != nil, let screen else { return carrier.orderOut(nil) }
        model.barWindowFrame = panel.frame
        model.carrierWindowFrame = screen.frame
        carrier.setFrame(screen.frame, display: false)
        carrier.orderFrontRegardless()
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
