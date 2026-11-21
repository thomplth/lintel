import Foundation

public struct BarLayout: Equatable, Codable, Sendable {
    public struct Item: Equatable, Sendable {
        public var key: String
        public var isPinned: Bool
        public var order: Int
        public var isOptIn: Bool

        public init(key: String, isPinned: Bool, order: Int = 50, isOptIn: Bool = false) {
            self.key = key
            self.isPinned = isPinned
            self.order = order
            self.isOptIn = isOptIn
        }
    }

    public var rows: [[String]] = []
    public var hidden: [String] = []
    public var pinned: [String: Bool] = [:]
    public var symbols: [String: String] = [:]
    public var sizes: [String: WidgetSize] = [:]

    public init() {}

    public init(
        rows: [[String]], hidden: [String] = [], pinned: [String: Bool] = [:],
        symbols: [String: String] = [:], sizes: [String: WidgetSize] = [:]
    ) {
        self.rows = rows
        self.hidden = hidden
        self.pinned = pinned
        self.symbols = symbols
        self.sizes = sizes.filter { $0.value.isWidget }
    }

    private enum Key: String, CodingKey {
        case rows, hidden, pinned, symbols, sizes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        rows = try container.decodeIfPresent([[String]].self, forKey: .rows) ?? []
        hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
        pinned = try container.decodeIfPresent([String: Bool].self, forKey: .pinned) ?? [:]
        symbols = try container.decodeIfPresent([String: String].self, forKey: .symbols) ?? [:]
        let decodedSizes = try container.decodeIfPresent([String: WidgetSize].self, forKey: .sizes) ?? [:]
        sizes = decodedSizes.filter { $0.value.isWidget }
    }

    public func size(of key: String) -> WidgetSize {
        sizes[key] ?? .chip
    }

    public mutating func setSize(_ size: WidgetSize, for key: String) {
        if size.isWidget {
            sizes[key] = size
        } else {
            sizes[key] = nil
        }
    }

    /// Resized widgets live on the Bento shelf below the chip rows and stay visible while idle too.
    public func arrangedWidgets(_ items: [Item]) -> [(key: String, size: WidgetSize)] {
        let shown = items.filter { !hidden.contains($0.key) && size(of: $0.key).isWidget }
        guard !shown.isEmpty else { return [] }
        let byKey = Dictionary(shown.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var ordered: [String] = []
        for row in rows {
            for key in row where byKey[key] != nil && seen.insert(key).inserted {
                ordered.append(key)
            }
        }
        let unlisted = shown
            .filter { !seen.contains($0.key) }
            .sorted { ($0.order, $0.key) < ($1.order, $1.key) }
            .map(\.key)
        ordered += unlisted
        return ordered.map { ($0, size(of: $0)) }
    }

    /// `raised` holds items asking for attention; they show while idle whatever their pin says.
    /// With `keepsFirstRow`, the first row lives in the system menu bar: it keeps all its items while idle and keeps
    /// its place even when empty, so the rows below never rise into the menu bar.
    /// Items currently sized as desktop widgets leave the chip rows while keeping their remembered row slots.
    public func arranged(_ items: [Item], isActive: Bool, raised: Set<String> = [], keepsFirstRow: Bool = false) -> [[String]] {
        let shown = items.filter { !hidden.contains($0.key) && !size(of: $0.key).isWidget }
        let byKey = Dictionary(shown.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<String>()
        var result = rows.map { row in row.filter { byKey[$0] != nil && placed.insert($0).inserted } }

        let unlisted = shown
            .filter { !$0.isOptIn && !placed.contains($0.key) }
            .sorted { ($0.order, $0.key) < ($1.order, $1.key) }
            .map(\.key)
        if result.isEmpty {
            result = [unlisted]
        } else {
            result[result.count - 1] += unlisted
        }

        if !isActive {
            let showsWhileIdle = { (key: String) in raised.contains(key) || isPinned(key, default: byKey[key]?.isPinned ?? false) }
            result = result.enumerated().map { index, row in keepsFirstRow && index == 0 ? row : row.filter(showsWhileIdle) }
        }
        guard keepsFirstRow, let first = result.first else { return result.filter { !$0.isEmpty } }
        return [first] + result.dropFirst().filter { !$0.isEmpty }
    }

    public func isPinned(_ key: String, default fallback: Bool) -> Bool {
        pinned[key] ?? fallback
    }

    public func row(of key: String) -> Int? {
        rows.firstIndex { $0.contains(key) }
    }

    /// Makes the implicit arrangement explicit so that editing one item cannot reshuffle the others.
    public mutating func materialise(_ items: [Item], keepsFirstRow: Bool = false) {
        rows = arranged(items, isActive: true, keepsFirstRow: keepsFirstRow)
    }

    public mutating func remove(_ key: String, keepsFirstRow: Bool = false) {
        let kept = rows.map { $0.filter { $0 != key } }
        guard keepsFirstRow, let first = kept.first else { return rows = kept.filter { !$0.isEmpty } }
        rows = [first] + kept.dropFirst().filter { !$0.isEmpty }
    }

    public mutating func place(_ key: String, row: Int, at index: Int? = nil) {
        remove(key)
        hidden.removeAll { $0 == key }
        if row >= rows.count || row < 0 {
            if row < 0 { rows.insert([key], at: 0) } else { rows.append([key]) }
            return
        }
        let position = min(max(index ?? rows[row].count, 0), rows[row].count)
        rows[row].insert(key, at: position)
    }

    public mutating func shift(_ key: String, by offset: Int) {
        guard let row = row(of: key), let index = rows[row].firstIndex(of: key) else { return }
        let target = index + offset
        guard rows[row].indices.contains(target) else { return }
        rows[row].swapAt(index, target)
    }

    public mutating func moveToRow(_ key: String, offset: Int) {
        guard let row = row(of: key) else { return }
        let isAlone = rows[row].count == 1
        let target = row + offset
        if target < 0 {
            if !isAlone { place(key, row: -1) }
        } else if target >= rows.count {
            if !isAlone { place(key, row: rows.count) }
        } else {
            let adjusted = isAlone && offset > 0 ? target - 1 : target
            place(key, row: adjusted)
        }
    }

    public mutating func setHidden(_ key: String, _ isHidden: Bool) {
        hidden.removeAll { $0 == key }
        if isHidden {
            hidden.append(key)
            remove(key)
        }
    }
}
