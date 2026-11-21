import CoreGraphics
import Foundation

/// Packs freeform-sized widgets into explicit vertical stacks (columns) below the chip strip, aligned to the bar anchor.
/// Column 0 hugs the anchor edge (rightmost when `.right`, leftmost when `.left`/`.center`), and widgets inside each
/// column stack vertically from top to bottom.
public struct WidgetShelf: Equatable, Sendable {
    public var gap: CGFloat
    public var anchor: BarAnchor

    public init(gap: CGFloat, anchor: BarAnchor) {
        self.gap = gap
        self.anchor = anchor
    }

    public struct Placed: Equatable, Sendable {
        public var frames: [String: CGRect]
        public var columnRects: [CGRect]
        public var size: CGSize
    }

    public func place(_ columns: [[(key: String, size: CGSize)]]) -> Placed {
        let nonEmpty = columns.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else {
            return Placed(frames: [:], columnRects: [], size: .zero)
        }

        let colWidths = nonEmpty.map { col in col.map(\.size.width).max() ?? 0 }
        let colHeights = nonEmpty.map { col in
            col.map(\.size.height).reduce(0, +) + gap * CGFloat(max(col.count - 1, 0))
        }

        let totalWidth = colWidths.reduce(0, +) + gap * CGFloat(max(nonEmpty.count - 1, 0))
        let totalHeight = colHeights.max() ?? 0

        var frames: [String: CGRect] = [:]
        var columnRects: [CGRect] = []
        var cursor: CGFloat = 0

        for (colIndex, col) in nonEmpty.enumerated() {
            let colW = colWidths[colIndex]
            let colH = colHeights[colIndex]
            let colX: CGFloat = if anchor == .right {
                totalWidth - cursor - colW
            } else {
                cursor
            }
            columnRects.append(CGRect(x: colX, y: 0, width: colW, height: colH))

            var y: CGFloat = 0
            for item in col {
                let itemX: CGFloat = switch anchor {
                case .right: colX + (colW - item.size.width)
                case .center: colX + (colW - item.size.width) / 2
                case .left: colX
                }
                frames[item.key] = CGRect(x: itemX, y: y, width: item.size.width, height: item.size.height)
                y += item.size.height + gap
            }
            cursor += colW + gap
        }

        return Placed(frames: frames, columnRects: columnRects, size: CGSize(width: totalWidth, height: totalHeight))
    }
}

/// Drop target for dragging a desktop widget to reorder, stack vertically in a column, open a new column, or collapse.
public enum WidgetShelfDrop: Equatable, Sendable {
    /// Stack inside existing `column` (indexed after removing `moving` if that emptied a column) at vertical `index`.
    case stack(column: Int, index: Int)
    /// Create a brand-new column at `column` (0 = closest to the bar's anchored edge).
    case newColumn(Int)
    /// Dragged up onto the chip bar to collapse back into a bar chip.
    case collapseToChip

    public struct Entry: Equatable, Sendable {
        public var key: String
        public var frame: CGRect

        public init(key: String, frame: CGRect) {
            self.key = key
            self.frame = frame
        }
    }

    /// Resolves a drag pointer (in shelf-local top-left coordinates) into a drop target.
    public static func resolve(
        at point: CGPoint,
        columns: [[Entry]],
        moving: String,
        anchor: BarAnchor,
        collapseAboveY: CGFloat
    ) -> WidgetShelfDrop? {
        if point.y < collapseAboveY {
            return .collapseToChip
        }

        // Remove the moving widget so target column/row indices are always stable after removal.
        let remaining: [[Entry]] = columns.compactMap { col in
            let kept = col.filter { $0.key != moving }
            return kept.isEmpty ? nil : kept
        }
        guard !remaining.isEmpty else {
            return .newColumn(0)
        }

        let boundsByCol: [CGRect] = remaining.map { col in
            col.reduce(CGRect.null) { $0.union($1.frame) }
        }
        let shelfRect = boundsByCol.reduce(CGRect.null) { $0.union($1) }
        let edgeMargin: CGFloat = 18

        // Check outside left/right edges to open a new column on either outer side.
        if anchor == .right {
            if point.x > shelfRect.maxX + edgeMargin { return .newColumn(0) }
            if point.x < shelfRect.minX - edgeMargin { return .newColumn(remaining.count) }
        } else {
            if point.x < shelfRect.minX - edgeMargin { return .newColumn(0) }
            if point.x > shelfRect.maxX + edgeMargin { return .newColumn(remaining.count) }
        }

        // Check gaps between adjacent columns to insert a new column between them.
        for index in 0..<(boundsByCol.count - 1) {
            let a = boundsByCol[index]
            let b = boundsByCol[index + 1]
            let lowX = min(a.maxX, b.maxX)
            let highX = max(a.minX, b.minX)
            if point.x >= lowX - 8 && point.x <= highX + 8 {
                return .newColumn(index + 1)
            }
        }

        // Otherwise, stack into the horizontally nearest column at the insertion index matching `point.y`.
        let colIndex = boundsByCol.indices.min { lhs, rhs in
            let lDist = horizontalDistance(point.x, to: boundsByCol[lhs])
            let rDist = horizontalDistance(point.x, to: boundsByCol[rhs])
            return lDist < rDist
        } ?? 0

        let col = remaining[colIndex]
        let insertion = col.firstIndex { point.y < $0.frame.midY } ?? col.count
        return .stack(column: colIndex, index: insertion)
    }

    private static func horizontalDistance(_ x: CGFloat, to rect: CGRect) -> CGFloat {
        if x < rect.minX { return rect.minX - x }
        if x > rect.maxX { return x - rect.maxX }
        return 0
    }
}
