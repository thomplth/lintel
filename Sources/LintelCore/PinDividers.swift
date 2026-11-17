/// The bar's rows split by a divider each: modules on the anchored side of a row's divider are pinned, so they show
/// while the bar is idle, and the rest show only while it is open.
public struct PinDividers: Equatable, Sendable {
    private static let prefix = "lintel.divider."

    public static func key(_ row: Int) -> String { "\(prefix)\(row)" }

    public static func isDivider(_ key: String) -> Bool { key.hasPrefix(prefix) }

    /// Module keys and divider keys, row by row.
    public private(set) var rows: [[String]]
    public let pinsAtEnd: Bool
    public let keepsFirstRow: Bool

    /// With `keepsFirstRow`, the first row lives in the system menu bar, which shows all of it while idle, so it gets no divider.
    public init(rows: [[String]], isPinned: (String) -> Bool, pinsAtEnd: Bool, keepsFirstRow: Bool) {
        self.pinsAtEnd = pinsAtEnd
        self.keepsFirstRow = keepsFirstRow
        self.rows = rows.enumerated().map { index, row in
            guard !(keepsFirstRow && index == 0) else { return row }
            let pinned = row.filter(isPinned)
            let unpinned = row.filter { !isPinned($0) }
            return pinsAtEnd ? unpinned + [Self.key(index)] + pinned : pinned + [Self.key(index)] + unpinned
        }
    }

    /// The rows once `key` has left its place, closing any row it leaves holding only its divider, as `BarDrop`
    /// counts them.
    private func rowsWithout(_ key: String) -> [[String]] {
        rows.map { $0.filter { $0 != key } }.enumerated().compactMap { index, row in
            if keepsFirstRow, index == 0 { return row }
            return row.allSatisfy(Self.isDivider) ? nil : row
        }
    }

    /// A divider moves only within its own row. Every row keeps at least one module beside its divider, so taking the
    /// divider out closes no row and its index stays the same.
    public func accepts(_ drop: BarDrop, moving key: String) -> Bool {
        guard Self.isDivider(key) else { return true }
        guard case .row(let target, _) = drop else { return false }
        return rows.firstIndex { $0.contains(key) } == target
    }

    public func moving(_ key: String, to drop: BarDrop) -> PinDividers {
        var moved = self
        moved.rows = rowsWithout(key)
        switch drop {
        case .row(let target, let index):
            guard moved.rows.indices.contains(target) else { moved.rows.append([key]); break }
            moved.rows[target].insert(key, at: min(max(index, 0), moved.rows[target].count))
        case .newRow(let target):
            moved.rows.insert([key], at: min(max(target, 0), moved.rows.count))
        case .remove:
            break
        }
        return moved
    }

    public var layoutRows: [[String]] {
        rows.map { $0.filter { !Self.isDivider($0) } }
    }

    /// The pin of every module in a row with a divider; a module alone in a new row keeps the pin it had.
    public var pins: [String: Bool] {
        var pins: [String: Bool] = [:]
        for row in rows {
            guard let divider = row.firstIndex(where: Self.isDivider) else { continue }
            for (index, key) in row.enumerated() where index != divider {
                pins[key] = (index > divider) == pinsAtEnd
            }
        }
        return pins
    }
}
