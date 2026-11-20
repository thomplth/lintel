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
    var panelWidth = "medium"
    var permissions: [String] = []
    var isUserModule = false
    var isRaised = false

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
    var node: ViewNode?
    var failure: String?
    var isLoading = false
    var isPinnedOpen = false
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
    @Published var isHiddenByUser = false
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
    /// Where the menu bar row's top-left corner lies in the bar window's top-left coordinates.
    var menuBarRowOffset = CGSize.zero
    /// The menu bar row's strip in the bar window's top-left coordinates, which takes drops even while empty.
    var menuBarRowBand = CGRect.null

    /// Chip frames in the bar window's top-left coordinates, including chips drawn in the menu bar row.
    var slotFrames: [String: CGRect] {
        reportedFrames.mapValues { reported in
            reported.isInMenuBar ? reported.frame.offsetBy(dx: menuBarRowOffset.width, dy: menuBarRowOffset.height) : reported.frame
        }
    }

    func report(frame: CGRect, of id: String, isInMenuBar: Bool) {
        reportedFrames[id] = (frame, isInMenuBar)
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
}
