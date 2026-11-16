import AppKit
import LintelCore
import SwiftUI

struct Slot: Identifiable, Equatable {
    enum Kind: Equatable {
        case module
        case menuBarItem
        case assistant
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
        kind != .module || hasPanel || failure != nil || needsApproval
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

struct Rearrangement: Equatable {
    enum Phase: Equatable {
        case carrying, landing, vanishing
    }

    var key: String
    var grabOffset: CGSize
    var size: CGSize
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
final class BarModel: ObservableObject {
    @Published var theme = Theme()
    @Published var layout = BarLayout()
    @Published var settings = AppSettings()
    @Published var slots: [Slot] = []
    @Published var isActive = false
    @Published var isHiddenByUser = false
    @Published var topRowMinHeight: CGFloat = 0
    @Published var maxBarWidth: CGFloat = 1200
    @Published var panel: PanelState?
    @Published var chat: [ChatMessage] = []
    @Published var isChatBusy = false
    @Published var chatActivity = ""
    @Published var chatFocusRequests = 0
    @Published var chatDraft = ""
    @Published var engineName = ""
    @Published var rearrangement: Rearrangement? {
        didSet { if (oldValue == nil) != (rearrangement == nil) { onRearrangingChanged() } }
    }
    @Published var carriedPointer = CGPoint.zero

    var slotFrames: [String: CGRect] = [:]
    var barWindowFrame = CGRect.zero
    var carrierWindowFrame = CGRect.zero

    func barToCarrier(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: barWindowFrame.minX - carrierWindowFrame.minX + point.x,
            y: carrierWindowFrame.maxY - barWindowFrame.maxY + point.y
        )
    }

    var onContentSize: (CGSize) -> Void = { _ in }
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
    var onRearrange: (_ key: String, _ drop: BarDrop) -> Void = { _, _ in }
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
        slots.first { $0.id == id }
    }

    var layoutItems: [BarLayout.Item] {
        slots.map { BarLayout.Item(key: $0.id, isPinned: $0.isPinned, order: $0.order, isOptIn: $0.isOptIn) }
    }

    var chipRows: [[BarDrop.Chip]] {
        visibleRows.map { row in row.compactMap { slot in slotFrames[slot.id].map { BarDrop.Chip(key: slot.id, frame: $0) } } }
    }

    func slotID(at point: CGPoint) -> String? {
        visibleRows.joined().first { $0.kind != .assistant && slotFrames[$0.id]?.contains(point) == true }?.id
    }

    var isCarrying: Bool {
        rearrangement?.phase == .carrying
    }

    func beginRearranging(_ key: String, grabbedAt point: CGPoint) {
        guard let frame = slotFrames[key] else { return }
        carriedPointer = point
        rearrangement = Rearrangement(
            key: key, grabOffset: CGSize(width: point.x - frame.minX, height: point.y - frame.minY), size: frame.size
        )
        NSCursor.closedHand.set()
    }

    func carry(to point: CGPoint) {
        guard isCarrying, let key = rearrangement?.key else { return }
        carriedPointer = point
        let drop = BarDrop.resolve(at: point, in: chipRows, moving: key)
        guard drop != rearrangement?.drop else { return }
        (drop == .remove ? NSCursor.disappearingItem : NSCursor.closedHand).set()
        withAnimation(Self.reflow) { rearrangement?.drop = drop }
    }

    func drop() {
        guard isCarrying, let rearrangement else { return }
        NSCursor.arrow.set()
        if let drop = rearrangement.drop { onRearrange(rearrangement.key, drop) }
        let ending = rearrangement.isRemoving ? Rearrangement.Phase.vanishing : .landing
        withAnimation(ending == .vanishing ? Self.vanish : Self.reflow, completionCriteria: .logicallyComplete) {
            self.rearrangement?.phase = ending
        } completion: {
            self.rearrangement = nil
        }
    }

    static let reflow = Animation.spring(duration: 0.28, bounce: 0.18)
    static let vanish = Animation.easeIn(duration: 0.18)

    private var arrangedRows: [[Slot]] {
        let usable = slots.filter { isActive || ($0.failure == nil && !$0.needsApproval && $0.kind != .assistant) }
        let byID = Dictionary(usable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = usable.map { BarLayout.Item(key: $0.id, isPinned: $0.isPinned, order: $0.order, isOptIn: $0.isOptIn) }
        let raised = Set(usable.filter(\.isRaised).map(\.id))
        return layout.arranged(items, isActive: isActive, raised: raised).map { row in row.compactMap { byID[$0] } }
    }

    var visibleRows: [[Slot]] {
        let rows = arrangedRows
        guard let rearrangement, let drop = rearrangement.drop else { return rows }
        let byID = Dictionary(rows.joined().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var preview = BarLayout(rows: rows.map { $0.map(\.id) })
        preview.move(rearrangement.key, to: drop)
        return preview.rows.map { row in row.compactMap { byID[$0] } }
    }
}
