import CoreGraphics
import Foundation

/// Where a module dragged across the bar would land. Row and index count positions before the module leaves its own.
public enum BarDrop: Equatable, Sendable {
    case row(Int, index: Int)
    case newRow(Int)

    public struct Chip: Equatable, Sendable {
        public var key: String
        public var frame: CGRect

        public init(key: String, frame: CGRect) {
            self.key = key
            self.frame = frame
        }
    }

    private static let newRowEdgeShare: CGFloat = 0.25

    public static func resolve(at point: CGPoint, in rows: [[Chip]]) -> BarDrop? {
        let bands = rows.map(band)
        guard let first = bands.first, let last = bands.last else { return nil }
        if point.y < first.minY { return .newRow(0) }
        if point.y > last.maxY { return .newRow(rows.count) }

        for (index, band) in bands.enumerated() {
            if point.y < band.minY { return .newRow(index) }
            guard point.y <= band.maxY else { continue }
            let edge = lineHeight(rows[index]) * newRowEdgeShare
            if point.y < band.minY + edge { return .newRow(index) }
            if point.y > band.maxY - edge { return .newRow(index + 1) }
            return .row(index, index: insertionIndex(at: point, in: rows[index]))
        }
        return .newRow(rows.count)
    }

    public func marker(in rows: [[Chip]], thickness: CGFloat = 2) -> CGRect? {
        switch self {
        case .row(let row, let index):
            guard rows.indices.contains(row), let lastChip = rows[row].last else { return nil }
            let chips = rows[row]
            guard index < chips.count else {
                return CGRect(x: lastChip.frame.maxX + 1, y: lastChip.frame.minY, width: thickness, height: lastChip.frame.height)
            }
            let next = chips[index].frame
            var x = next.minX - thickness - 1
            if index > 0, chips[index - 1].frame.minY == next.minY {
                x = (chips[index - 1].frame.maxX + next.minX) / 2 - thickness / 2
            }
            return CGRect(x: x, y: next.minY, width: thickness, height: next.height)
        case .newRow(let row):
            let bands = rows.map(Self.band)
            guard let first = bands.first, let last = bands.last else { return nil }
            let all = bands.reduce(first) { $0.union($1) }
            let y: CGFloat = if row <= 0 {
                first.minY - thickness - 1
            } else if row >= bands.count {
                last.maxY + 1
            } else {
                (bands[row - 1].maxY + bands[row].minY) / 2 - thickness / 2
            }
            return CGRect(x: all.minX, y: y, width: all.width, height: thickness)
        }
    }

    private static func band(_ row: [Chip]) -> CGRect {
        row.dropFirst().reduce(row.first?.frame ?? .null) { $0.union($1.frame) }
    }

    private static func lineHeight(_ row: [Chip]) -> CGFloat {
        row.map(\.frame.height).min() ?? 0
    }

    private static func insertionIndex(at point: CGPoint, in row: [Chip]) -> Int {
        let nearest = row.indices.min { distance(point, row[$0].frame) < distance(point, row[$1].frame) } ?? 0
        guard row.indices.contains(nearest) else { return 0 }
        return point.x < row[nearest].frame.midX ? nearest : nearest + 1
    }

    private static func distance(_ point: CGPoint, _ frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }
}

extension BarLayout {
    public mutating func move(_ key: String, to drop: BarDrop) {
        guard let from = row(of: key), let fromIndex = rows[from].firstIndex(of: key) else { return }
        switch drop {
        case .row(let target, let index):
            guard rows.indices.contains(target) else { return }
            let adjusted = target == from && fromIndex < index ? index - 1 : index
            rows[from].remove(at: fromIndex)
            rows[target].insert(key, at: min(max(adjusted, 0), rows[target].count))
        case .newRow(let target):
            rows[from].remove(at: fromIndex)
            rows.insert([key], at: min(max(target, 0), rows.count))
        }
        rows.removeAll(where: \.isEmpty)
    }
}
