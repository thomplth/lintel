import AppKit
import ApplicationServices
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
    // Lintel › Hide (⌘H) is meant for the Settings window; the bar stands in for the menu bar and must stay up.
    panel.canHide = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.isMovable = false
    return panel
}

@MainActor
final class BarWindowController {
    let panel: FloatingPanel
    private let model: BarModel
    private var activation = Activation()
    private var widgetExpansion = WidgetExpansion()
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
    private var mouseMonitors: [Any] = []
    var isPanelOpen: () -> Bool = { false }
    var panelFrame: () -> CGRect? = { nil }
    var onActiveChanged: (Bool) -> Void = { _ in }
    var onAnchorChanged: (BarAnchor) -> Void = { _ in }
    var onHideToggled: () -> Void = {}
    var onWillHide: () -> Void = {}
    var onAssistantHotkey: () -> Void = {}
    var onKeyboardHotkey: () -> Void = {}
    var onSystemMenuBarRevealed: () -> Void = {}

    init(model: BarModel) {
        self.model = model
        panel = makeFloatingPanel(level: .statusBar)
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
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
        model.onResizingChanged = { [weak self] in self?.updateMouseCapture() }
        let follow: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.updateMouseCapture() } }
        let outsideClick: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.handleGlobalClickOutsideWidget() }
        }
        mouseMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .flagsChanged], handler: follow) as Any,
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .flagsChanged]) { follow($0); return $0 } as Any,
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: outsideClick) as Any,
        ]

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated {
            self?.place()
            self?.updateFullScreenState()
        } }
        // macOS shrinks windows created while the screen is locked toward the centre; re-place on unlock and wake.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.place()
                    self?.updateFullScreenState()
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateFullScreenState() } }
        for name in ["com.apple.screenIsUnlocked", "AppleInterfaceMenuBarHidingChangedNotification"] {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }

        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        applySettings()
        updateFullScreenState()
        place()
        panel.orderFrontRegardless()
    }

    func applySettings() {
        activation.dwell = model.settings.dwell
        activation.grace = model.settings.grace
        widgetExpansion.grace = model.settings.grace
        var visibility = model.visibility
        visibility.setAutoHideInFullScreen(model.settings.autoHideInFullScreen)
        applyVisibility(visibility)
        hotkeys = []
        if let toggle = Hotkey(shortcut: model.settings.toggleShortcut, action: { [weak self] in
            MainActor.assumeIsolated { self?.onAssistantHotkey() }
        }) { hotkeys.append(toggle) }
        if let hide = Hotkey(shortcut: model.settings.hideShortcut, action: { [weak self] in
            MainActor.assumeIsolated { self?.onHideToggled() }
        }) { hotkeys.append(hide) }
        if let keyboard = Hotkey(shortcut: model.settings.keyboardShortcut, action: { [weak self] in
            MainActor.assumeIsolated { self?.onKeyboardHotkey() }
        }) { hotkeys.append(keyboard) }
        place()
    }

    var isHeld: Bool { activation.state == .held }

    func hold() {
        activation.hold()
        applyActivation()
    }

    func release() {
        activation.release()
        collapseTemporaryWidget()
        applyActivation()
        if panel.isKeyWindow { panel.resignKey() }
    }

    func expandWidgetTemporarily(_ id: String) {
        guard let savedBox = model.layout.widgetBox(of: id) else { return }
        let topOffset = model.slotFrames[id]?.minY ?? model.shelfOriginInBarSpace.y
        let expandedBox = WidgetResize.temporaryMaxBox(
            from: savedBox,
            metrics: Metrics(model.theme),
            screenSize: model.maxWidgetScreenSize,
            topOffset: topOffset
        )
        widgetExpansion.expand(id)
        withAnimation(model.theme.motion == "full" ? BarModel.reflow : nil) {
            model.temporaryExpandedWidget = TemporaryWidgetExpansion(slotID: id, box: expandedBox)
        }
        updateMouseCapture()
    }

    func collapseTemporaryWidget() {
        guard widgetExpansion.slotID != nil || model.temporaryExpandedWidget != nil else { return }
        widgetExpansion.collapse()
        withAnimation(model.theme.motion == "full" ? BarModel.reflow : nil) {
            model.temporaryExpandedWidget = nil
        }
        updateMouseCapture()
    }

    private func handleGlobalClickOutsideWidget() {
        guard let expandedID = widgetExpansion.slotID else { return }
        let inBarCoords = barPoint(NSEvent.mouseLocation)
        if !model.isPointInWidget(inBarCoords, slotID: expandedID) {
            collapseTemporaryWidget()
        }
    }

    func peekCorner(forSlot id: String) -> ResizeCorner {
        guard let screen else { return WidgetResize.corner(for: model.settings.anchor) }
        let chip = screenFrame(ofSlot: id) ?? contentFrame
        return WidgetResize.peekCorner(forChip: chip, on: screen.visibleFrame.union(contentFrame))
    }

    /// Taking key status must happen inside the hotkey's own event, as for the assistant panel.
    func takeKeyboardFocus() {
        hold()
        panel.makeKeyAndOrderFront(nil)
    }

    func unhold() {
        activation.unhold(at: ProcessInfo.processInfo.systemUptime)
        applyActivation()
    }

    func toggleHide() {
        var visibility = model.visibility
        visibility.toggleHide()
        applyVisibility(visibility)
    }

    func revealIfHidden() {
        var visibility = model.visibility
        visibility.show()
        applyVisibility(visibility)
    }

    private func applyVisibility(_ updated: BarVisibility) {
        guard updated != model.visibility else { return }
        let wasHidden = model.isHidden
        model.visibility = updated
        let isHidden = updated.isHidden
        guard isHidden != wasHidden else { return }
        if isHidden { onWillHide() }
        menuBarRow?.setHidden(isHidden)
        updateGuardedTopEdge()
        if isHidden { release() }
        panel.animator().alphaValue = isHidden || hasSteppedAside ? 0 : 1
        updateMouseCapture()
    }

    private func updateFullScreenState() {
        var visibility = model.visibility
        visibility.setFullScreen(detectFullScreen())
        applyVisibility(visibility)
    }

    private func detectFullScreen() -> Bool {
        guard let screen else { return false }
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenBounds = Placement.globalDisplayRect(screen.frame, mainScreenHeight: mainHeight)
        let axFullScreen = frontmostWindowAXFullScreen(on: screenBounds)
        if axFullScreen == true { return true }
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows: [ScreenWindow] = raw.compactMap { entry in
            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  let layer = entry[kCGWindowLayer as String] as? Int
            else { return nil }
            return ScreenWindow(
                owner: entry[kCGWindowOwnerName as String] as? String ?? "",
                ownerPID: entry[kCGWindowOwnerPID as String] as? Int32 ?? 0,
                layer: layer,
                bounds: bounds,
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1
            )
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostRegularPID = frontmost?.activationPolicy == .regular ? frontmost?.processIdentifier : nil
        return FullScreenDetection.isFullScreen(
            windows: windows,
            screenBounds: screenBounds,
            notchStripHeight: screen.safeAreaInsets.top,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            desktopIconLayer: Int(CGWindowLevelForKey(.desktopIconWindow)),
            normalLayer: Int(CGWindowLevelForKey(.normalWindow)),
            presentationLayer: Int(CGWindowLevelForKey(.screenSaverWindow)),
            frontmostRegularPID: frontmostRegularPID,
            frontmostAXFullScreen: axFullScreen
        )
    }

    private func frontmostWindowAXFullScreen(on screenBounds: CGRect) -> Bool? {
        guard AXIsProcessTrusted(),
              let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let app = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let window = focusedValue
        else { return nil }
        let element = window as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        var fullScreenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &fullScreenValue) == .success,
              let isFullScreen = fullScreenValue as? Bool
        else { return nil }
        guard isFullScreen else { return false }
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success {
            var origin = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            let frame = CGRect(origin: origin, size: size)
            if !frame.isEmpty {
                return frame.intersects(screenBounds.insetBy(dx: 4, dy: 4))
            }
        }
        return true
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
        panel.animator().alphaValue = isRevealed || model.isHidden ? 0 : 1
        if isRevealed, !isPanelOpen() { release() }
        if isRevealed { onSystemMenuBarRevealed() }
    }

    private func updateGuardedTopEdge() {
        guard model.settings.guardsTopEdge, menuBarAutoHides, !hasSteppedAside, !model.isHidden, let screen else {
            guardedTopEdge = nil
            return
        }
        let others = NSScreen.screens.filter { $0 != screen }.map(\.frame)
        guardedTopEdge = TopEdgeGuard.span(
            of: contentFrame, on: screen.frame, besides: others, notchStripHeight: screen.safeAreaInsets.top
        )
    }

    private var pointerTicks = 0

    private func trackPointer() {
        pointerTicks += 1
        // Listing every window is the costly part of each tick, and the menu bar only slides in while the pointer
        // is at the top edge; elsewhere an occasional look is enough to notice it leaving.
        let isNearTop = NSEvent.mouseLocation.y > (screen?.frame.maxY ?? 0) - 48
        if isNearTop || hasSteppedAside || pointerTicks % 20 == 0 { stepAsideForSystemMenuBar() }
        if pointerTicks % 10 == 0 { updateFullScreenState() }
        // Other apps' items come and go beside the menu bar row and push it along.
        if let menuBarRow, menuBarRow.screenFrame != menuBarRowFrame { place() }
        if menuBarRow != nil, pointerTicks % 50 == 1 { measureMenuBarRowBudget() }
        guard !hasSteppedAside, !model.isHidden, dragOrigin == nil, model.rearrangement == nil, model.resizingSlotID == nil, model.draggingWidgetID == nil else { return }
        let pointer = NSEvent.mouseLocation
        let inBarCoords = barPoint(pointer)
        if let expandedID = widgetExpansion.slotID {
            let keepOpen = model.slot(expandedID)?.isConfiguring == true
                || model.isPointInWidget(inBarCoords, slotID: expandedID)
            widgetExpansion.pointer(inside: keepOpen, at: ProcessInfo.processInfo.systemUptime)
            if widgetExpansion.slotID == nil {
                collapseTemporaryWidget()
            }
        }
        let isOverWidget = model.isPointInWidget(inBarCoords)
        let isOverChip = model.isPointInBarChip(inBarCoords)
        var isInside = isOverChip || isOverWidget
        if let menuBarRowFrame, menuBarRowFrame.contains(pointer) { isInside = true }
        if activation.isActive, let frame = panelFrame(), frame.insetBy(dx: -4, dy: -10).contains(pointer) { isInside = true }
        if !model.settings.hoverActivates, activation.state == .idle { isInside = false }
        // A pressed mouse button means a drag or selection is passing over the bar, not a visit to it.
        if activation.state == .idle, NSEvent.pressedMouseButtons != 0 { isInside = false }
        // Hovering a desktop widget directly should let the user interact immediately without expanding the unpinned chip bar,
        // while hovering the chip strip still triggers normal dwell activation.
        if isOverWidget && !isOverChip && activation.state == .idle {
            updateMouseCapture()
            return
        }
        activation.pointer(inside: isInside, at: ProcessInfo.processInfo.systemUptime)
        applyActivation()
        updateMouseCapture()
    }

    private func applyActivation() {
        guard model.isActive != activation.isActive else { return }
        model.isActive = activation.isActive
        if !activation.isActive {
            model.isDrivenByKeyboard = false
            collapseTemporaryWidget()
        }
        updateMouseCapture()
        if !activation.isActive, panel.isKeyWindow { panel.resignKey() }
        onActiveChanged(activation.isActive)
    }

    var screen: NSScreen? { NSScreen.screens.first }

    /// The bar within its window, which is a larger, fixed canvas.
    var contentFrame: CGRect {
        Placement.content(size: contentSize, in: panel.frame, anchor: model.settings.anchor)
    }

    /// The canvas would swallow clicks meant for the windows under it; it takes the pointer only over an actual
    /// chip (when active), an actual desktop widget (even while idle!), or while a drag/resize press is held.
    private func updateMouseCapture() {
        let pointer = NSEvent.mouseLocation
        let inBarCoords = barPoint(pointer)
        let isPressing = !panel.ignoresMouseEvents && NSEvent.pressedMouseButtons != 0
        let isOverWidget = model.isPointInWidget(inBarCoords)
        let isOverBarChip = model.isPointInBarChip(inBarCoords) || contentFrame.insetBy(dx: -2, dy: -2).contains(pointer) && model.visibleWidgets.isEmpty
        let captures = !model.isHidden && (
            isOverWidget
            || (activation.isActive && isOverBarChip)
            || isPressing
            || dragOrigin != nil
            || model.rearrangement != nil
            || model.resizingSlotID != nil
            || model.draggingWidgetID != nil
        )
        if panel.ignoresMouseEvents == captures { panel.ignoresMouseEvents = !captures }
        updatePinDividers(isOverBar: isOverBarChip)
    }

    /// ⌘ over the open bar shows each row's pin divider, ready to be ⌘-dragged, and keeps it while a drag goes on.
    private func updatePinDividers(isOverBar: Bool) {
        let isOverMenuBarRow = menuBarRowFrame?.contains(NSEvent.mouseLocation) ?? false
        let shows = activation.isActive && !model.isHidden && (isOverBar || isOverMenuBarRow)
            && NSEvent.modifierFlags.contains(.command)
        guard shows != model.showsPinDividers else { return }
        withAnimation(BarModel.reflow) { model.showsPinDividers = shows }
    }

    /// Wide enough for the widest row and freeform widget shelf, and tall enough for stacked sidebars, so the window
    /// rarely needs to resize mid-animation.
    private func canvas(around content: CGRect) -> CGRect {
        let screenWidth = screen?.visibleFrame.width ?? 1280
        let screenHeight = screen?.visibleFrame.height ?? 800
        return Placement.canvas(
            around: content,
            width: max(model.maxBarWidth + Placement.barSidePadding * 2, min(screenWidth * 0.72, 920), content.width + 32),
            height: max(520, screenHeight * 0.82, content.height + 40),
            anchor: model.settings.anchor
        )
    }

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
        if model.maxWidgetScreenSize != geometry.visibleFrame.size {
            model.maxWidgetScreenSize = geometry.visibleFrame.size
        }
        let widest = Placement.widestRow(
            on: geometry, anchor: model.settings.anchor, edgeInset: model.settings.edgeInset,
            otherwise: max(geometry.frame.width * 0.62 - 16, 320)
        )
        if model.maxBarWidth != widest { model.maxBarWidth = widest }
        updateMenuBarRow(wanted: !geometry.menuBarAutoHides)
        if let menuBarRow {
            placeUnderMenuBarRow(menuBarRow, on: geometry)
        } else {
            let placement = Placement.bar(
                contentSize: contentSize, on: geometry, anchor: model.settings.anchor, edgeInset: model.settings.edgeInset
            )
            if model.topRowMinHeight != placement.topRowMinHeight { model.topRowMinHeight = placement.topRowMinHeight }
            let canvas = canvas(around: placement.frame)
            if panel.frame != canvas { panel.setFrame(canvas, display: true) }
            model.barWindowFrame = canvas
        }
        updateGuardedTopEdge()
    }

    private func updateMenuBarRow(wanted: Bool) {
        if wanted, menuBarRow == nil {
            let row = MenuBarRow(model: model)
            row.onPress = { [weak self] _ in self?.menuBarRowPressed() }
            row.setHidden(model.isHidden)
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
        let frame = canvas(around: Placement.rows(contentSize: size, under: item, on: geometry, anchor: model.settings.anchor))
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
        let barOffset = contentFrame.minX - panel.frame.minX
        let barX = min(max(origin.x + barOffset + translation.width, screen.frame.minX), screen.frame.maxX - contentFrame.width)
        panel.setFrameOrigin(CGPoint(x: barX - barOffset, y: origin.y))
    }

    private func endDrag() {
        guard dragOrigin != nil, let geometry else { return }
        dragOrigin = nil
        let anchor = Placement.anchor(forDropAt: contentFrame.midX, on: geometry)
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
                if !self.visibleFrame.contains(pointer), !self.bar.contentFrame.contains(pointer) { self.onClickOutside() }
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
        let chip = bar.screenFrame(ofSlot: state.slotID) ?? bar.contentFrame
        let frame = Placement.panel(size: contentSize, under: chip, on: screen.visibleFrame.union(bar.contentFrame), gap: 6)
        let padded = frame.insetBy(dx: -PanelView.margin, dy: -PanelView.margin)
        if panel.frame != padded { panel.setFrame(padded, display: true) }
    }
}
