import CoreGraphics

/// Splits a first row that lives in the system menu bar into the modules that fit beside other apps' items and
/// the ones that overflow to the start of the row below. The modules nearest the row's end, usually the pinned
/// ones such as the clock, keep their place in the menu bar.
public struct MenuBarFit: Equatable, Sendable {
    public private(set) var inMenuBar: [String] = []
    public private(set) var overflow: [String] = []

    public init() {}

    public init(chips: [(key: String, width: CGFloat)], spacing: CGFloat, budget: CGFloat) {
        var used: CGFloat = 0
        var fitsFrom = chips.count
        for index in chips.indices.reversed() {
            let width = used == 0 ? chips[index].width : used + spacing + chips[index].width
            guard width <= budget else { break }
            used = width
            fitsFrom = index
        }
        overflow = chips[..<fitsFrom].map(\.key)
        inMenuBar = chips[fitsFrom...].map(\.key)
    }

    /// The rows as shown, from the layout's rows: overflowed modules leave the first row and lead the second.
    public func rows(from layoutRows: [[String]]) -> [[String]] {
        guard !overflow.isEmpty, let first = layoutRows.first else { return layoutRows }
        let shownFirst = first.filter { !overflow.contains($0) }
        guard layoutRows.count > 1 else { return [shownFirst, overflow] }
        return [shownFirst, overflow + layoutRows[1]] + layoutRows.dropFirst(2)
    }
}
