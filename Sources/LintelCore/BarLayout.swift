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
    /// Freeform desktop widget boxes keyed by module id. Absence means the module lives as a bar chip.
    public var widgets: [String: WidgetBox] = [:]
    /// Explicit vertical widget stacks (columns) on the shelf below the chip strip.
    /// Column 0 hugs the bar's anchored edge; entries within a column stack top to bottom.
    public var widgetColumns: [[String]] = []
    /// Remembered click-to-peek (chip expand) sizes per module id so reopening restores the user's last resized dimensions.
    public var panelSizes: [String: WidgetBox] = [:]

    public init() {}

    public init(
        rows: [[String]],
        hidden: [String] = [],
        pinned: [String: Bool] = [:],
        symbols: [String: String] = [:],
        widgets: [String: WidgetBox] = [:],
        widgetColumns: [[String]] = [],
        panelSizes: [String: WidgetBox] = [:]
    ) {
        self.rows = rows
        self.hidden = hidden
        self.pinned = pinned
        self.symbols = symbols
        self.widgets = widgets
        self.widgetColumns = widgetColumns
        self.panelSizes = panelSizes
    }

    private enum Key: String, CodingKey {
        case rows, hidden, pinned, symbols, widgets, widgetColumns, panelSizes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        rows = try container.decodeIfPresent([[String]].self, forKey: .rows) ?? []
        hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
        pinned = try container.decodeIfPresent([String: Bool].self, forKey: .pinned) ?? [:]
        symbols = try container.decodeIfPresent([String: String].self, forKey: .symbols) ?? [:]
        widgets = try container.decodeIfPresent([String: WidgetBox].self, forKey: .widgets) ?? [:]
        widgetColumns = try container.decodeIfPresent([[String]].self, forKey: .widgetColumns) ?? []
        panelSizes = try container.decodeIfPresent([String: WidgetBox].self, forKey: .panelSizes) ?? [:]
    }

    public func panelSize(of key: String) -> WidgetBox? {
        panelSizes[key]
    }

    public mutating func setPanelSize(_ box: WidgetBox?, for key: String) {
        panelSizes[key] = box
    }

    public func widgetBox(of key: String) -> WidgetBox? {
        widgets[key]
    }

    public func isWidget(_ key: String) -> Bool {
        widgets[key] != nil
    }

    public mutating func setWidget(_ box: WidgetBox?, for key: String) {
        if let box {
            widgets[key] = box
            if !widgetColumns.contains(where: { $0.contains(key) }) {
                widgetColumns.append([key])
            }
        } else {
            widgets[key] = nil
            widgetColumns = widgetColumns.map { $0.filter { $0 != key } }.filter { !$0.isEmpty }
        }
    }

    /// Reorders, stacks, unstacks, or collapses a widget on the shelf.
    public mutating func moveWidget(_ key: String, to drop: WidgetShelfDrop) {
        if drop == .collapseToChip {
            setWidget(nil, for: key)
            return
        }
        guard widgets[key] != nil else { return }
        var columns = widgetColumns.map { $0.filter { $0 != key } }.filter { !$0.isEmpty }
        switch drop {
        case .stack(let col, let index):
            if columns.indices.contains(col) {
                let pos = min(max(index, 0), columns[col].count)
                columns[col].insert(key, at: pos)
            } else {
                columns.append([key])
            }
        case .newColumn(let col):
            let pos = min(max(col, 0), columns.count)
            columns.insert([key], at: pos)
        case .collapseToChip:
            break
        }
        widgetColumns = columns
    }

    /// Moves a widget up or down within its stack, or splits it into a new stack if needed.
    public mutating func moveWidgetInStack(_ key: String, offset: Int) {
        guard let colIndex = widgetColumns.firstIndex(where: { $0.contains(key) }),
              let rowIndex = widgetColumns[colIndex].firstIndex(of: key)
        else { return }
        let target = rowIndex + offset
        guard widgetColumns[colIndex].indices.contains(target) else { return }
        widgetColumns[colIndex].swapAt(rowIndex, target)
    }

    /// Moves a widget to an adjacent column (stacking at the bottom of that column) or out to its own column.
    public mutating func stackWidgetWithColumn(_ key: String, offset: Int) {
        guard let colIndex = widgetColumns.firstIndex(where: { $0.contains(key) }) else { return }
        let target = colIndex + offset
        guard widgetColumns.indices.contains(target) else { return }
        widgetColumns[colIndex].removeAll { $0 == key }
        widgetColumns[target].append(key)
        widgetColumns = widgetColumns.filter { !$0.isEmpty }
    }

    /// Pulls a stacked widget out into its own column right beside its current stack.
    public mutating func unstackWidget(_ key: String) {
        guard let colIndex = widgetColumns.firstIndex(where: { $0.contains(key) }),
              widgetColumns[colIndex].count > 1
        else { return }
        widgetColumns[colIndex].removeAll { $0 == key }
        widgetColumns.insert([key], at: colIndex + 1)
    }

    /// Resized desktop widgets grouped into their explicit vertical stacks (columns), staying visible while idle too.
    public func arrangedWidgetColumns(_ items: [Item]) -> [[(key: String, box: WidgetBox)]] {
        let shown = items.filter { !hidden.contains($0.key) && widgets[$0.key] != nil }
        guard !shown.isEmpty else { return [] }
        let byKey = Dictionary(shown.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [[(key: String, box: WidgetBox)]] = []

        for col in widgetColumns {
            let entries: [(key: String, box: WidgetBox)] = col.compactMap { key in
                guard byKey[key] != nil, let box = widgets[key], seen.insert(key).inserted else { return nil }
                return (key, box)
            }
            if !entries.isEmpty { result.append(entries) }
        }

        // Any active widget not yet present in widgetColumns gets its own column in chip-row / order sequence.
        var unlistedKeys: [String] = []
        for row in rows {
            for key in row where byKey[key] != nil && seen.insert(key).inserted {
                unlistedKeys.append(key)
            }
        }
        let remaining = shown
            .filter { !seen.contains($0.key) }
            .sorted { ($0.order, $0.key) < ($1.order, $1.key) }
            .map(\.key)
        for key in unlistedKeys + remaining {
            if let box = widgets[key] {
                result.append([(key, box)])
            }
        }
        return result
    }

    /// `raised` holds items asking for attention; they show while idle whatever their pin says.
    /// With `keepsFirstRow`, the first row lives in the system menu bar: it keeps all its items while idle and keeps
    /// its place even when empty, so the rows below never rise into the menu bar.
    /// Items currently sized as desktop widgets leave the chip rows while keeping their remembered row slots.
    public func arranged(_ items: [Item], isActive: Bool, raised: Set<String> = [], keepsFirstRow: Bool = false) -> [[String]] {
        let shown = items.filter { !hidden.contains($0.key) && widgets[$0.key] == nil }
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

    public func isHidden(_ key: String) -> Bool {
        hidden.contains(key)
    }

    public mutating func setHidden(_ key: String, _ isHidden: Bool, keepsFirstRow: Bool = false) {
        hidden.removeAll { $0 == key }
        if isHidden {
            hidden.append(key)
            remove(key, keepsFirstRow: keepsFirstRow)
            setWidget(nil, for: key)
        }
    }

    /// Makes a hidden item visible again. Opt-in items (such as adopted menu bar items) are placed back into a row
    /// because `arranged` omits unlisted opt-in items.
    public mutating func show(_ key: String, isOptIn: Bool = false) {
        hidden.removeAll { $0 == key }
        if isOptIn, row(of: key) == nil {
            place(key, row: max(rows.count - 1, 0))
        }
    }
}
