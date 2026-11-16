import CoreGraphics
import Foundation

/// Where a module dragged across the bar would land. Rows and indices count the bar as it is once the module has left its place.
public enum BarDrop: Equatable, Sendable {
    case row(Int, index: Int)
    case newRow(Int)
    case remove

    public struct Chip: Equatable, Sendable {
        public var key: String
        public var frame: CGRect

        public init(key: String, frame: CGRect) {
            self.key = key
            self.frame = frame
        }
    }

    private static let newRowEdgeShare: CGFloat = 0.25
    private static let removalDepthInLines: CGFloat = 1.5
    private static let removalSideMargin: CGFloat = 48

    public static func resolve(at point: CGPoint, in displayed: [[Chip]], moving key: String) -> BarDrop? {
        let rows = displayed.map { $0.filter { $0.key != key } }.filter { !$0.isEmpty }
        let bands = rows.map(band)
        guard let first = bands.first, let last = bands.last else { return nil }
        let bar = bands.reduce(first) { $0.union($1) }
        // A module carried into a new row of its own must count toward the bar's depth, or that row lies past the
        // removal line whenever the remaining modules fit on fewer lines, and the drop flips to removing it.
        let drawnBottom = displayed.joined().map(\.frame.maxY).max() ?? last.maxY
        let removalDepth = drawnBottom + lineHeight(rows[rows.count - 1]) * removalDepthInLines
        if point.y > removalDepth || point.x < bar.minX - removalSideMargin || point.x > bar.maxX + removalSideMargin {
            return .remove
        }
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
        guard row(of: key) != nil else { return }
        remove(key)
        switch drop {
        case .row(let target, let index):
            guard rows.indices.contains(target) else { return rows.append([key]) }
            rows[target].insert(key, at: min(max(index, 0), rows[target].count))
        case .newRow(let target):
            rows.insert([key], at: min(max(target, 0), rows.count))
        case .remove:
            setHidden(key, true)
        }
    }
}
