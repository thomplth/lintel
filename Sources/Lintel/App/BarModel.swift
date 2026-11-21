import AppKit
import LintelCore
import SwiftUI

struct Slot: Identifiable, Equatable {
    enum Kind: Equatable {
        case module
        case menuBarItem
        case assistant
        case pinDivider
    }

    let id: String
    var kind = Kind.module
    var title: String
    var icon = "puzzlepiece.extension"
    var isPinned = false
    var order = 50
    var isOptIn = false
    var chip: ViewNode?
    var image: NSImage?
    var failure: String?
    var needsApproval = false
    var hasPanel = false
    var hasConfigure = false
    var panelWidth = "medium"
    var supportedSizes: [WidgetSize] = [.chip]
    var defaultWidgetSize: WidgetSize?
    var widgetNode: ViewNode?
    var widgetSize: WidgetSize = .chip
    var configureNode: ViewNode?
    var isConfiguring = false
    var permissions: [String] = []
    var isUserModule = false
    var isRaised = false

    var supportsResize: Bool {
        kind == .module && supportedSizes.contains(where: \.isWidget) && !needsApproval && failure == nil
    }

    var isClickable: Bool {
        switch kind {
        case .module: hasPanel || failure != nil || needsApproval
        case .menuBarItem, .assistant: true
        case .pinDivider: false
        }
    }

    var showsWhileIdle: Bool {
        failure == nil && !needsApproval && kind != .assistant && kind != .pinDivider
    }

    static func pinDivider(_ key: String) -> Slot {
        Slot(id: key, kind: .pinDivider, title: "Pin divider")
    }
}

struct PanelState: Equatable {
    enum Content: Equatable {
        case module
        case assistant
    }

    var slotID: String
    var content: Content
    var widgetSize: WidgetSize = .medium
    var node: ViewNode?
    var configureNode: ViewNode?
    var isConfiguring = false
    var failure: String?
    var isLoading = false
    var isPinnedOpen = false
}

/// Live corner-drag resize state kept outside BarModel so 120Hz drag ticks never redraw unrelated chips or widgets.
@MainActor
final class ResizeDragState: ObservableObject {
    @Published var activeSlotID: String?
    @Published var isPeek = false
    @Published var startTier: WidgetSize = .chip
    @Published var targetTier: WidgetSize = .chip
    @Published var startRect: CGRect = .zero
    @Published var proposedSize: CGSize = .zero
    @Published var corner: ResizeCorner = .bottomLeft

    var isActive: Bool { activeSlotID != nil }

    func reset() {
        activeSlotID = nil
        isPeek = false
        startTier = .chip
        targetTier = .chip
        startRect = .zero
        proposedSize = .zero
    }
}

struct SelectionBump: Equatable {
    var direction: BarSelection.Bump
    var count: Int
}

struct Rearrangement: Equatable {
    enum Phase: Equatable {
        case carrying, landing, vanishing
    }

    var key: String
    var grabOffset: CGSize
    var size: CGSize
    /// The rows as the drag found them, which every preview and the drop are worked out from.
    var start: PinDividers
    var drop: BarDrop?
    var phase = Phase.carrying

    var isRemoving: Bool { drop == .remove }
}

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable {
        case user, assistant
    }

    var id = UUID()
    var role: Role
    var text: String
    var detail: String?
    var moduleID: String?
    var needsApproval = false
    var canUndoTheme = false
    var isError = false
}

@MainActor
final class CarriedPointer: ObservableObject {
    @Published var point = CGPoint.zero
}

@MainActor
final class BarModel: ObservableObject {
    @Published var theme = Theme()
    @Published var layout = BarLayout()
    @Published var settings = AppSettings()
    @Published var slots: [Slot] = []
    @Published var isActive = false
    @Published var visibility = BarVisibility()
    var isHidden: Bool { visibility.isHidden }
    @Published var topRowMinHeight: CGFloat = 0
    /// The first row lives in a system menu bar item instead of the bar's window.
    @Published var isFirstRowInMenuBar = false
    /// The width free for the menu bar row beside other apps' items.
    @Published var menuBarRowBudget = CGFloat.greatestFiniteMagnitude
    @Published var maxBarWidth: CGFloat = 1200
    @Published var panel: PanelState?
    @Published var chat: [ChatMessage] = []
    @Published var isChatBusy = false
    @Published var chatActivity = ""
    @Published var chatFocusRequests = 0
    @Published var chatDraft = ""
    @Published var engineName = ""
    @Published var studioFocusedModuleID: String?
    @Published var rearrangement: Rearrangement? {
        didSet { if (oldValue == nil) != (rearrangement == nil) { onRearrangingChanged() } }
    }
    /// Kept outside the model's own changes: the pointer moves every frame of a drag, and every view observing the
    /// model would otherwise be rebuilt each time.
    let carried = CarriedPointer()
    /// Live corner-drag resize state, likewise kept outside BarModel to avoid redrawing unrelated modules mid-drag.
    let resizeDrag = ResizeDragState()
    @Published var resizingSlotID: String? {
        didSet { if (oldValue == nil) != (resizingSlotID == nil) { onResizingChanged() } }
    }
    /// ⌘ is held over the open bar: every row shows the divider that splits its pinned modules from the rest.
    @Published var showsPinDividers = false
    /// The bar was opened with the keyboard shortcut, so its keys move `keyboardSelection` and act on that module.
    var isDrivenByKeyboard = false {
        didSet { if !isDrivenByKeyboard { keyboardSelection = nil } }
    }
    @Published var keyboardSelection: String? {
        didSet { if let keyboardSelection { UserDefaults.standard.set(keyboardSelection, forKey: Self.rememberedSelectionKey) } }
    }
    /// The module last selected from the keyboard, where the next keyboard session starts, across restarts too.
    var rememberedSelection: String? { UserDefaults.standard.string(forKey: Self.rememberedSelectionKey) }
    private static let rememberedSelectionKey = "keyboardSelection"
    /// Counts each step that tried to leave the top or bottom row, so the selection ring can nudge that way.
    @Published private(set) var selectionBump = SelectionBump(direction: .down, count: 0)
    let panelFocus = PanelFocusMemory()

    var animatesSelection: Bool {
        theme.motion == "full" && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func bump(_ direction: BarSelection.Bump) {
        selectionBump = SelectionBump(direction: direction, count: selectionBump.count + 1)
    }

    /// The bar's modules as the keyboard steps through them; pin dividers are only for ⌘-dragging.
    var selectableRows: [[BarSelection.Chip]] {
        let frames = slotFrames
        return BarSelection.rows(from: visibleRows.joined().compactMap { slot in
            guard slot.kind != .pinDivider, let frame = frames[slot.id] else { return nil }
            return (slot.id, frame)
        })
    }

    private var reportedFrames: [String: (frame: CGRect, isInMenuBar: Bool)] = [:]
    private var reportedWidgetFrames: [String: CGRect] = [:]
    /// Where the menu bar row's top-left corner lies in the bar window's top-left coordinates.
    var menuBarRowOffset = CGSize.zero
    /// The menu bar row's strip in the bar window's top-left coordinates, which takes drops even while empty.
    var menuBarRowBand = CGRect.null

    /// Chip frames in the bar window's top-left coordinates, including chips drawn in the menu bar row.
    var slotFrames: [String: CGRect] {
        var frames = reportedFrames.mapValues { reported in
            reported.isInMenuBar ? reported.frame.offsetBy(dx: menuBarRowOffset.width, dy: menuBarRowOffset.height) : reported.frame
        }
        for (id, rect) in reportedWidgetFrames where layout.size(of: id).isWidget {
            frames[id] = rect
        }
        return frames
    }

    func report(frame: CGRect, of id: String, isInMenuBar: Bool) {
        reportedFrames[id] = (frame, isInMenuBar)
    }

    func reportWidget(frame: CGRect, of id: String) {
        reportedWidgetFrames[id] = frame
    }

    /// Visible chip and widget frames in the bar window's top-left coordinates, used for precise click-through hit testing.
    var interactiveFramesInBarWindow: [CGRect] {
        var rects: [CGRect] = []
        let chipKeys = Set(visibleRows.joined().map(\.id))
        for (id, entry) in reportedFrames where !entry.isInMenuBar && chipKeys.contains(id) {
            rects.append(entry.frame)
        }
        for entry in visibleWidgets {
            if let rect = reportedWidgetFrames[entry.slot.id] {
                rects.append(rect)
            }
        }
        return rects
    }

    /// True if `barPoint` (in bar window top-left coordinates) hits a visible desktop widget.
    func isPointInWidget(_ barPoint: CGPoint) -> Bool {
        for entry in visibleWidgets {
            if let rect = reportedWidgetFrames[entry.slot.id], rect.insetBy(dx: -6, dy: -6).contains(barPoint) {
                return true
            }
        }
        return false
    }

    /// True if `barPoint` (in bar window top-left coordinates) hits a visible chip in the bar window.
    func isPointInBarChip(_ barPoint: CGPoint) -> Bool {
        let chipKeys = Set(visibleRows.joined().map(\.id))
        for (id, entry) in reportedFrames where !entry.isInMenuBar && chipKeys.contains(id) {
            if entry.frame.insetBy(dx: -4, dy: -4).contains(barPoint) {
                return true
            }
        }
        return false
    }

    var barWindowFrame = CGRect.zero
    var carrierWindowFrame = CGRect.zero

    func barToCarrier(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: barWindowFrame.minX - carrierWindowFrame.minX + point.x,
            y: carrierWindowFrame.maxY - barWindowFrame.maxY + point.y
        )
    }

    var onContentSize: (CGSize) -> Void = { _ in }
    var onMenuBarRowContentSize: (CGSize) -> Void = { _ in }
    var onSlotClick: (Slot) -> Void = { _ in }
    var onSlotSecondaryAction: (Slot, String) -> Void = { _, _ in }
    var onAction: (_ module: String, _ action: String, _ payload: JSONValue) -> Void = { _, _, _ in }
    var onAppAction: (_ module: String, _ action: String, _ payload: JSONValue) async -> JSONValue = { _, _, _ in .null }
    var onChatSubmit: (String) -> Void = { _ in }
    var onChatCommand: (String, ChatMessage?) -> Void = { _, _ in }
    var onDismiss: () -> Void = {}
    var onPanelCommand: (String) -> Void = { _ in }
    var onDragEnded: (CGFloat) -> Void = { _ in }
    var onDragChanged: (CGSize) -> Void = { _ in }
    var onRearrange: (_ rows: [[String]], _ pins: [String: Bool], _ hiding: String?) -> Void = { _, _, _ in }
    var onRearrangingChanged: () -> Void = {}
    var onResizeSlot: (_ id: String, _ size: WidgetSize) -> Void = { _, _ in }
    var onResizePreview: (_ id: String, _ size: WidgetSize, _ isPeek: Bool) -> Void = { _, _, _ in }
    var onResizingChanged: () -> Void = {}
    var onToggleConfigure: (_ id: String, _ isConfiguring: Bool, _ isPeek: Bool) -> Void = { _, _, _ in }
    var onWidgetCommand: (_ id: String, _ command: String) -> Void = { _, _ in }
    var manifestFor: (String) -> ModuleManifest? = { _ in nil }

    var alignment: HorizontalAlignment {
        switch settings.anchor {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    func slot(_ id: String) -> Slot? {
        PinDividers.isDivider(id) ? .pinDivider(id) : slots.first { $0.id == id }
    }

    var layoutItems: [BarLayout.Item] {
        slots.map { BarLayout.Item(key: $0.id, isPinned: $0.isPinned, order: $0.order, isOptIn: $0.isOptIn) }
    }

    var chipRows: [[BarDrop.Chip]] {
        visibleRows.map { row in row.compactMap { slot in slotFrames[slot.id].map { BarDrop.Chip(key: slot.id, frame: $0) } } }
    }

    func slot(at point: CGPoint) -> Slot? {
        visibleRows.joined().first { slotFrames[$0.id]?.contains(point) == true }
    }

    func slotID(at point: CGPoint) -> String? {
        visibleRows.joined().first { $0.kind != .assistant && slotFrames[$0.id]?.contains(point) == true }?.id
    }

    var isCarrying: Bool {
        rearrangement?.phase == .carrying
    }

    func beginRearranging(_ key: String, grabbedAt point: CGPoint) {
        guard let frame = slotFrames[key] else { return }
        carried.point = point
        withAnimation(Self.reflow) {
            rearrangement = Rearrangement(
                key: key, grabOffset: CGSize(width: point.x - frame.minX, height: point.y - frame.minY), size: frame.size,
                start: pinDividers(fittedRows)
            )
        }
        NSCursor.closedHand.set()
    }

    func carry(to point: CGPoint) {
        Perf.measure("drag.carry") { carrying(to: point) }
    }

    private func carrying(to point: CGPoint) {
        guard isCarrying, let rearrangement else { return }
        let key = rearrangement.key
        carried.point = point
        // A row the carried module leaves holding only its divider closes, as PinDividers.moving closes it.
        let rows = chipRows.map { row in
            row.allSatisfy { $0.key == key || PinDividers.isDivider($0.key) } ? row.filter { $0.key == key } : row
        }
        let drop = BarDrop.resolve(at: point, in: rows, moving: key, firstRowBand: isFirstRowInMenuBar ? menuBarRowBand : nil)
            .flatMap { rearrangement.start.accepts($0, moving: key) ? $0 : nil }
        guard drop != rearrangement.drop else { return }
        (drop == .remove ? NSCursor.disappearingItem : NSCursor.closedHand).set()
        withAnimation(Self.reflow) { self.rearrangement?.drop = drop }
    }

    func drop() {
        guard isCarrying, let rearrangement else { return }
        NSCursor.arrow.set()
        if let drop = rearrangement.drop {
            let result = rearrangement.start.moving(rearrangement.key, to: drop)
            let changed = result.pins.filter { key, isPinned in layout.isPinned(key, default: slot(key)?.isPinned ?? false) != isPinned }
            onRearrange(result.layoutRows, changed, rearrangement.isRemoving ? rearrangement.key : nil)
        }
        let ending = rearrangement.isRemoving ? Rearrangement.Phase.vanishing : .landing
        withAnimation(ending == .vanishing ? Self.vanish : Self.reflow, completionCriteria: .logicallyComplete) {
            self.rearrangement?.phase = ending
        } completion: {
            withAnimation(Self.reflow) { self.rearrangement = nil }
        }
    }

    private func pinDividers(_ rows: [[Slot]]) -> PinDividers {
        let byID = Dictionary(rows.joined().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return PinDividers(
            rows: rows.map { $0.map(\.id) },
            isPinned: { [layout] key in layout.isPinned(key, default: byID[key]?.isPinned ?? false) },
            pinsAtEnd: alignment != .leading, keepsFirstRow: isFirstRowInMenuBar
        )
    }

    /// The arranged rows with the modules that do not fit in the menu bar moved to the start of the row below; while
    /// idle only the pinned ones among them show there.
    private var fittedRows: [[Slot]] {
        let rows = arrangedRows
        let fit = menuBarFit
        guard !fit.overflow.isEmpty else { return rows }
        let byID = Dictionary(rows.joined().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = fit.rows(from: rows.map { $0.map(\.id) }).enumerated().map { index, row in
            row.filter { key in
                isActive || index != 1 || !fit.overflow.contains(key) || layout.isPinned(key, default: byID[key]?.isPinned ?? false)
            }
        }
        return [shown[0].compactMap { byID[$0] }] + shown.dropFirst().map { $0.compactMap { byID[$0] } }.filter { !$0.isEmpty }
    }

    static let reflow = Animation.spring(duration: 0.32, bounce: 0.12)
    static let lift = Animation.spring(duration: 0.22, bounce: 0.2)
    static let vanish = Animation.spring(duration: 0.22, bounce: 0)

    /// Splits the menu bar row by the widths its modules last had, wherever they were drawn.
    var menuBarFit: MenuBarFit {
        guard isFirstRowInMenuBar, let first = arrangedRows.first else { return MenuBarFit() }
        let frames = slotFrames
        let hasCapsules = [SurfaceMaterial.glass, .solid].contains(SurfaceMaterial(active: theme.activeMaterial))
        let spacing = hasCapsules ? max(theme.moduleSpacing * 0.5, 4) : theme.moduleSpacing
        let padding: CGFloat = 8
        return MenuBarFit(
            chips: first.map { ($0.id, frames[$0.id]?.width ?? 60) }, spacing: spacing, budget: menuBarRowBudget - padding
        )
    }

    private var arrangedRows: [[Slot]] {
        let usable = slots.filter { isActive || isFirstRowInMenuBar || $0.showsWhileIdle }
        let byID = Dictionary(usable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = usable.map { BarLayout.Item(key: $0.id, isPinned: $0.isPinned, order: $0.order, isOptIn: $0.isOptIn) }
        let raised = Set(usable.filter(\.isRaised).map(\.id))
        let rows = layout.arranged(items, isActive: isActive, raised: raised, keepsFirstRow: isFirstRowInMenuBar)
            .map { row in row.compactMap { byID[$0] } }
        guard isFirstRowInMenuBar, !isActive, let first = rows.first else { return rows }
        return [first] + rows.dropFirst().map { $0.filter(\.showsWhileIdle) }.filter { !$0.isEmpty }
    }

    var visibleRows: [[Slot]] {
        let rows = fittedRows
        guard showsPinDividers || rearrangement != nil else { return rows }
        let byID = Dictionary(rows.joined().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let start = rearrangement?.start ?? pinDividers(rows)
        let shown = rearrangement.flatMap { moving in moving.drop.map { start.moving(moving.key, to: $0) } } ?? start
        return shown.rows.map { row in row.compactMap { byID[$0] ?? (PinDividers.isDivider($0) ? .pinDivider($0) : nil) } }
    }

    /// Persistent desktop widgets shown on the Bento shelf below the chip rows (visible while idle too).
    var visibleWidgets: [(slot: Slot, size: WidgetSize)] {
        let byID = Dictionary(slots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.arrangedWidgets(layoutItems).compactMap { entry in
            guard let slot = byID[entry.key], slot.kind == .module, !slot.needsApproval, slot.failure == nil else { return nil }
            let supported = slot.supportedSizes
            let effective = supported.contains(entry.size) ? entry.size : (slot.defaultWidgetSize ?? .medium)
            return (slot, effective)
        }
    }

    /// The bar's modules as the keyboard steps through them; includes both chips and desktop widgets.
    var selectableRowsWithWidgets: [[BarSelection.Chip]] {
        let frames = slotFrames
        let allIDs = visibleRows.joined().filter { $0.kind != .pinDivider }.map(\.id) + visibleWidgets.map(\.slot.id)
        return BarSelection.rows(from: allIDs.compactMap { id in
            guard let frame = frames[id] else { return nil }
            return (id, frame)
        })
    }

    // MARK: Live Corner Resize

    func beginResizing(_ id: String, startTier: WidgetSize, startRect: CGRect, isPeek: Bool = false) {
        let corner = WidgetResize.corner(for: settings.anchor)
        resizeDrag.activeSlotID = id
        resizeDrag.isPeek = isPeek
        resizeDrag.startTier = startTier
        resizeDrag.targetTier = startTier
        resizeDrag.startRect = startRect
        resizeDrag.proposedSize = startRect.size
        resizeDrag.corner = corner
        resizingSlotID = id
    }

    func updateResizing(translation: CGSize) {
        guard let id = resizeDrag.activeSlotID, let slot = slot(id) else { return }
        let metrics = Metrics(theme)
        let allowed = resizeDrag.isPeek ? slot.supportedSizes.filter(\.isWidget) : slot.supportedSizes
        guard !allowed.isEmpty else { return }
        let raw = WidgetResize.proposedSize(from: resizeDrag.startRect.size, translation: translation, corner: resizeDrag.corner)
        let minTier = allowed.sorted { $0.rank < $1.rank }.first ?? .chip
        let maxTier = allowed.sorted { $0.rank < $1.rank }.last ?? .medium
        let minDim = minTier.isWidget ? metrics.widgetSize(minTier) : CGSize(width: min(resizeDrag.startRect.width, 84), height: 28)
        let maxDim = metrics.widgetSize(maxTier)
        resizeDrag.proposedSize = WidgetResize.rubberySize(proposed: raw, min: minDim, max: maxDim)

        let target = WidgetResize.targetSize(
            from: resizeDrag.startTier,
            startSize: resizeDrag.startRect.size,
            translation: translation,
            corner: resizeDrag.corner,
            allowed: allowed,
            metrics: metrics
        )
        if target != resizeDrag.targetTier {
            resizeDrag.targetTier = target
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            onResizePreview(id, target, resizeDrag.isPeek)
        }
    }

    func endResizing() {
        guard let id = resizeDrag.activeSlotID else { return }
        let target = resizeDrag.targetTier
        let isPeek = resizeDrag.isPeek
        resizeDrag.reset()
        resizingSlotID = nil
        if isPeek {
            if target.isWidget, panel?.slotID == id {
                onResizePreview(id, target, true)
            }
        } else {
            onResizeSlot(id, target)
        }
    }
}
