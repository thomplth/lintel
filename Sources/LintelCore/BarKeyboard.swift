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

/// What a key pressed while the bar has keyboard focus does.
public enum BarKey: Equatable, Sendable {
    case left, right, up, down, tab, home, end, `return`, space, delete, escape
    case character(Character)

    public struct Modifiers: OptionSet, Sendable {
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

    public static func command(for key: BarKey, modifiers: Modifiers) -> Command? {
        switch (key, modifiers) {
        case (.left, []): .select(.previous)
        case (.right, []), (.tab, []): .select(.next)
        case (.tab, [.shift]): .select(.previous)
        case (.up, []): .select(.rowAbove)
        case (.down, []): .select(.rowBelow)
        case (.home, []): .select(.first)
        case (.end, []): .select(.last)
        case (.left, [.command]): .edit("left")
        case (.right, [.command]): .edit("right")
        case (.up, [.command]): .edit("up")
        case (.down, [.command]): .edit("down")
        case (.return, []), (.space, []): .open
        case (.delete, []): .edit("hide")
        case (.escape, []): .close
        case (.character(","), [.command]): .settings
        case (.character(let letter), []):
            switch letter {
            case "p": .edit("pin")
            case "a": .edit("change")
            case "/": .assistant
            case "1"..."9": letter.wholeNumberValue.map { .openAt($0 - 1) }
            default: nil
            }
        default: nil
        }
    }
}
