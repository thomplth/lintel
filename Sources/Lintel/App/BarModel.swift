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
    var key: String
    var drop: BarDrop?
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
    @Published var rearrangement: Rearrangement?

    var slotFrames: [String: CGRect] = [:]

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

    func beginRearranging(_ key: String) {
        rearrangement = Rearrangement(key: key)
        NSCursor.closedHand.push()
    }

    func updateRearranging(at point: CGPoint) {
        guard var rearrangement else { return }
        let drop = BarDrop.resolve(at: point, in: chipRows)
        rearrangement.drop = drop.flatMap { drop in
            var trial = BarLayout(rows: visibleRows.map { $0.map(\.id) })
            let before = trial.rows
            trial.move(rearrangement.key, to: drop)
            return trial.rows == before ? nil : drop
        }
        if rearrangement != self.rearrangement { self.rearrangement = rearrangement }
    }

    func endRearranging() {
        guard let rearrangement else { return }
        self.rearrangement = nil
        NSCursor.pop()
        if let drop = rearrangement.drop { onRearrange(rearrangement.key, drop) }
    }

    var visibleRows: [[Slot]] {
        let usable = slots.filter { isActive || ($0.failure == nil && !$0.needsApproval && $0.kind != .assistant) }
        let byID = Dictionary(usable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = usable.map { BarLayout.Item(key: $0.id, isPinned: $0.isPinned, order: $0.order, isOptIn: $0.isOptIn) }
        let raised = Set(usable.filter(\.isRaised).map(\.id))
        return layout.arranged(items, isActive: isActive, raised: raised).map { row in row.compactMap { byID[$0] } }
    }
}
