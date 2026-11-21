import CoreGraphics

/// Which module the keyboard selection lands on after a step through the bar's rows.
public enum BarSelection {
    public struct Chip: Equatable, Sendable {
        public var key: String
        public var midX: CGFloat

        public init(key: String, midX: CGFloat) {
            self.key = key
            self.midX = midX
        }
    }

    public enum Step: Equatable, Sendable {
        case next, previous, rowAbove, rowBelow, first, last
    }

    /// The bar wraps a long row onto several lines, so the keyboard's rows are the lines chips are drawn on, in
    /// top-left coordinates; chips whose centres lie within half a chip's height of each other share a line.
    public static func rows(from frames: [(key: String, frame: CGRect)]) -> [[Chip]] {
        var lines: [(midY: CGFloat, tolerance: CGFloat, chips: [(key: String, frame: CGRect)])] = []
        for chip in frames.sorted(by: { $0.frame.midY < $1.frame.midY }) {
            if let last = lines.indices.last, abs(chip.frame.midY - lines[last].midY) <= lines[last].tolerance {
                lines[last].chips.append(chip)
            } else {
                lines.append((chip.frame.midY, chip.frame.height / 2, [chip]))
            }
        }
        return lines.map { line in
            line.chips.sorted { $0.frame.minX < $1.frame.minX }.map { Chip(key: $0.key, midX: $0.frame.midX) }
        }
    }

    public enum Bump: Equatable, Sendable {
        case up, down
    }

    /// Where a step up or down from the top or bottom row would have gone, since the selection itself stays put.
    public static func bump(_ step: Step, from current: String?, in rows: [[Chip]]) -> Bump? {
        let rows = rows.filter { !$0.isEmpty }
        guard step == .rowAbove || step == .rowBelow, let current,
              let row = rows.firstIndex(where: { $0.contains { $0.key == current } })
        else { return nil }
        if step == .rowAbove { return row == 0 ? .up : nil }
        return row == rows.count - 1 ? .down : nil
    }

    public static func resume(_ remembered: String?, in rows: [[Chip]]) -> String? {
        if let remembered, rows.joined().contains(where: { $0.key == remembered }) { return remembered }
        return step(.first, from: nil, in: rows)
    }

    public static func step(_ step: Step, from current: String?, in rows: [[Chip]]) -> String? {
        let rows = rows.filter { !$0.isEmpty }
        let order = rows.joined().map(\.key)
        guard let first = order.first, let last = order.last else { return nil }
        guard let current, let index = order.firstIndex(of: current),
              let row = rows.firstIndex(where: { $0.contains { $0.key == current } })
        else { return first }
        switch step {
        case .next: return order[(index + 1) % order.count]
        case .previous: return order[(index - 1 + order.count) % order.count]
        case .first: return first
        case .last: return last
        case .rowAbove, .rowBelow:
            let target = row + (step == .rowAbove ? -1 : 1)
            guard rows.indices.contains(target), let midX = rows[row].first(where: { $0.key == current })?.midX else { return current }
            return rows[target].min { abs($0.midX - midX) < abs($1.midX - midX) }?.key
        }
    }
}

/// A key pressed while the bar has keyboard focus.
public enum BarKey: Hashable, Sendable {
    case left, right, up, down, tab, home, end, `return`, space, delete, escape
    case character(Character)

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let command = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    public enum Command: Equatable, Sendable {
        case select(BarSelection.Step)
        /// The selected module's context-menu command, by the name `AppController.edit` takes.
        case edit(String)
        case open
        case openAt(Int)
        case assistant
        case settings
        case close
    }

    private static let named: [(BarKey, String)] = [
        (.left, "left"), (.right, "right"), (.up, "up"), (.down, "down"), (.tab, "tab"), (.home, "home"), (.end, "end"),
        (.return, "return"), (.space, "space"), (.delete, "delete"), (.escape, "escape"),
    ]

    var storedName: String {
        if case .character(let character) = self { return String(character) }
        return Self.named.first { $0.0 == self }?.1 ?? ""
    }

    init?(storedName: String) {
        if let named = Self.named.first(where: { $0.1 == storedName }) {
            self = named.0
        } else if storedName.count == 1, let character = storedName.first {
            self = .character(character)
        } else {
            return nil
        }
    }

    var label: String {
        switch self {
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        case .tab: "Tab"
        case .home: "Home"
        case .end: "End"
        case .return: "Return"
        case .space: "Space"
        case .delete: "Delete"
        case .escape: "Esc"
        case .character(let character): character.uppercased()
        }
    }
}

public struct BarKeyBinding: Hashable, Sendable, Codable {
    public var key: BarKey
    public var modifiers: BarKey.Modifiers

    public init(_ key: BarKey, _ modifiers: BarKey.Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public var label: String {
        let marks: [(BarKey.Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return marks.filter { modifiers.contains($0.0) }.map(\.1).joined() + key.label
    }

    private enum CodingKeys: String, CodingKey { case key, modifiers }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .key)
        guard let key = BarKey(storedName: name) else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "Unknown key \(name)")
        }
        self.key = key
        modifiers = BarKey.Modifiers(rawValue: try container.decode(Int.self, forKey: .modifiers))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key.storedName, forKey: .key)
        try container.encode(modifiers.rawValue, forKey: .modifiers)
    }
}

/// What the bar does that a key can be chosen for. Escape and 1–9 are fixed, so they are not among them.
public enum BarAction: String, CaseIterable, Sendable {
    case previous, next, rowAbove, rowBelow, first, last, open
    case moveLeft, moveRight, moveUp, moveDown, grow, shrink, pin, hide, change, assistant, settings

    public var command: BarKey.Command {
        switch self {
        case .previous: .select(.previous)
        case .next: .select(.next)
        case .rowAbove: .select(.rowAbove)
        case .rowBelow: .select(.rowBelow)
        case .first: .select(.first)
        case .last: .select(.last)
        case .open: .open
        case .moveLeft: .edit("left")
        case .moveRight: .edit("right")
        case .moveUp: .edit("up")
        case .moveDown: .edit("down")
        case .grow: .edit("grow")
        case .shrink: .edit("shrink")
        case .pin: .edit("pin")
        case .hide: .edit("hide")
        case .change: .edit("change")
        case .assistant: .assistant
        case .settings: .settings
        }
    }

    public var title: String {
        switch self {
        case .previous: "Select the previous module"
        case .next: "Select the next module"
        case .rowAbove: "Select in the row above"
        case .rowBelow: "Select in the row below"
        case .first: "Select the first module"
        case .last: "Select the last module"
        case .open: "Open the selected module"
        case .moveLeft: "Move it left"
        case .moveRight: "Move it right"
        case .moveUp: "Move it up a row"
        case .moveDown: "Move it down a row"
        case .grow: "Resize larger"
        case .shrink: "Resize smaller"
        case .pin: "Pin or unpin it"
        case .hide: "Hide it from the bar"
        case .change: "Ask the assistant to change it"
        case .assistant: "Open the assistant"
        case .settings: "Open Settings"
        }
    }

    public var standardBindings: [BarKeyBinding] {
        switch self {
        case .previous: [BarKeyBinding(.left), BarKeyBinding(.tab, [.shift])]
        case .next: [BarKeyBinding(.right), BarKeyBinding(.tab)]
        case .rowAbove: [BarKeyBinding(.up)]
        case .rowBelow: [BarKeyBinding(.down)]
        case .first: [BarKeyBinding(.home)]
        case .last: [BarKeyBinding(.end)]
        case .open: [BarKeyBinding(.return), BarKeyBinding(.space)]
        case .moveLeft: [BarKeyBinding(.left, [.command])]
        case .moveRight: [BarKeyBinding(.right, [.command])]
        case .moveUp: [BarKeyBinding(.up, [.command])]
        case .moveDown: [BarKeyBinding(.down, [.command])]
        case .grow: [BarKeyBinding(.character("="), [.command]), BarKeyBinding(.character("]"))]
        case .shrink: [BarKeyBinding(.character("-"), [.command]), BarKeyBinding(.character("["))]
        case .pin: [BarKeyBinding(.character("p"))]
        case .hide: [BarKeyBinding(.delete)]
        case .change: [BarKeyBinding(.character("a"))]
        case .assistant: [BarKeyBinding(.character("/"))]
        case .settings: [BarKeyBinding(.character(","), [.command])]
        }
    }
}

/// Which key does what while the bar has keyboard focus; stored as the actions whose keys differ from the standard ones.
public struct BarKeymap: Equatable, Sendable, Codable {
    private var changed: [BarAction: [BarKeyBinding]] = [:]

    public static let standard = BarKeymap()

    public init() {}

    public func bindings(for action: BarAction) -> [BarKeyBinding] {
        changed[action] ?? action.standardBindings
    }

    public var isStandard: Bool { changed.isEmpty }

    public func isStandard(_ action: BarAction) -> Bool { changed[action] == nil }

    /// Escape steps back and closes the bar, and the unmodified digits open the module at their position.
    public static func isReserved(_ binding: BarKeyBinding) -> Bool {
        if binding.key == .escape { return true }
        guard binding.modifiers.isEmpty, case .character(let character) = binding.key else { return false }
        return ("1"..."9").contains(character)
    }

    /// Replaces the action's keys with `binding`, taking it from any other action that had it.
    public mutating func assign(_ binding: BarKeyBinding, to action: BarAction) {
        guard !Self.isReserved(binding) else { return }
        for other in BarAction.allCases where other != action && bindings(for: other).contains(binding) {
            set(bindings(for: other).filter { $0 != binding }, for: other)
        }
        set([binding], for: action)
    }

    public mutating func reset(_ action: BarAction) {
        changed[action] = nil
        for binding in action.standardBindings {
            for other in BarAction.allCases where other != action && bindings(for: other).contains(binding) {
                set(bindings(for: other).filter { $0 != binding }, for: other)
            }
        }
    }

    public mutating func resetAll() {
        changed = [:]
    }

    private mutating func set(_ bindings: [BarKeyBinding], for action: BarAction) {
        changed[action] = bindings == action.standardBindings ? nil : bindings
    }

    public func command(for key: BarKey, modifiers: BarKey.Modifiers) -> BarKey.Command? {
        let binding = BarKeyBinding(key, modifiers)
        if key == .escape, modifiers.isEmpty { return .close }
        if let action = BarAction.allCases.first(where: { bindings(for: $0).contains(binding) }) { return action.command }
        if Self.isReserved(binding), case .character(let digit) = key, let position = digit.wholeNumberValue {
            return .openAt(position - 1)
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let stored = try [String: [BarKeyBinding]](from: decoder)
        for (name, bindings) in stored {
            if let action = BarAction(rawValue: name) { changed[action] = bindings }
        }
    }

    public func encode(to encoder: Encoder) throws {
        try Dictionary(uniqueKeysWithValues: changed.map { ($0.key.rawValue, $0.value) }).encode(to: encoder)
    }
}
