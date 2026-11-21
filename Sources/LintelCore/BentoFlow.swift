import CoreGraphics
import Foundation

/// Packs resized desktop widgets into a crisp 2D Bento grid directly below the chip strip.
public struct BentoFlow: Equatable, Sendable {
    public var unitWidth: CGFloat
    public var unitHeight: CGFloat
    public var gap: CGFloat
    public var maxColumns: Int
    public var anchor: BarAnchor

    public init(unitWidth: CGFloat, unitHeight: CGFloat, gap: CGFloat, maxColumns: Int, anchor: BarAnchor) {
        self.unitWidth = unitWidth
        self.unitHeight = unitHeight
        self.gap = gap
        self.maxColumns = max(maxColumns, 1)
        self.anchor = anchor
    }

    public struct Placed: Equatable, Sendable {
        public var frames: [String: CGRect]
        public var size: CGSize
    }

    public func place(_ items: [(key: String, size: WidgetSize)]) -> Placed {
        let widgets = items.filter { $0.size.isWidget }
        guard !widgets.isEmpty else { return Placed(frames: [:], size: .zero) }

        let gridColumns = max(maxColumns, widgets.map(\.size.columns).max() ?? 1)
        var occupied: [[Bool]] = []
        var gridPlacements: [(key: String, col: Int, row: Int, cols: Int, rows: Int)] = []

        func ensureRows(_ count: Int) {
            while occupied.count < count {
                occupied.append(Array(repeating: false, count: gridColumns))
            }
        }

        func canFit(col: Int, row: Int, cols: Int, rows: Int) -> Bool {
            guard col >= 0, col + cols <= gridColumns else { return false }
            ensureRows(row + rows)
            for r in row..<(row + rows) {
                for c in col..<(col + cols) where occupied[r][c] {
                    return false
                }
            }
            return true
        }

        for widget in widgets {
            let cols = min(widget.size.columns, gridColumns)
            let rows = widget.size.rows
            var placed = false
            var row = 0
            while !placed {
                for col in 0...(gridColumns - cols) {
                    if canFit(col: col, row: row, cols: cols, rows: rows) {
                        for r in row..<(row + rows) {
                            for c in col..<(col + cols) {
                                occupied[r][c] = true
                            }
                        }
                        gridPlacements.append((widget.key, col, row, cols, rows))
                        placed = true
                        break
                    }
                }
                if !placed { row += 1 }
            }
        }

        let usedCols = gridPlacements.map { $0.col + $0.cols }.max() ?? 0
        let usedRows = gridPlacements.map { $0.row + $0.rows }.max() ?? 0
        guard usedCols > 0, usedRows > 0 else { return Placed(frames: [:], size: .zero) }

        let totalWidth = CGFloat(usedCols) * unitWidth + CGFloat(usedCols - 1) * gap
        let totalHeight = CGFloat(usedRows) * unitHeight + CGFloat(usedRows - 1) * gap

        var frames: [String: CGRect] = [:]
        for entry in gridPlacements {
            let w = CGFloat(entry.cols) * unitWidth + CGFloat(entry.cols - 1) * gap
            let h = CGFloat(entry.rows) * unitHeight + CGFloat(entry.rows - 1) * gap
            let y = CGFloat(entry.row) * (unitHeight + gap)
            let x: CGFloat = if anchor == .right {
                // First-placed widgets hug the right edge, growing leftward.
                totalWidth - (CGFloat(entry.col) * (unitWidth + gap) + w)
            } else {
                CGFloat(entry.col) * (unitWidth + gap)
            }
            frames[entry.key] = CGRect(x: x, y: y, width: w, height: h)
        }

        return Placed(frames: frames, size: CGSize(width: totalWidth, height: totalHeight))
    }
}
