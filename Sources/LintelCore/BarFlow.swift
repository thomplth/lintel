import CoreGraphics

/// Lays out every row of the bar in one pass, so a module keeps one frame as it moves between rows.
public struct BarFlow: Equatable, Sendable {
    public enum Alignment: Sendable {
        case leading, center, trailing
    }

    public var spacing: CGFloat
    public var rowSpacing: CGFloat
    public var alignment: Alignment
    public var maxWidth: CGFloat
    public var firstRowMinHeight: CGFloat

    public init(spacing: CGFloat, rowSpacing: CGFloat, alignment: Alignment, maxWidth: CGFloat, firstRowMinHeight: CGFloat = 0) {
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.alignment = alignment
        self.maxWidth = maxWidth
        self.firstRowMinHeight = firstRowMinHeight
    }

    public struct Placed: Equatable, Sendable {
        public var frames: [[CGRect]]
        public var size: CGSize
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(of sizes: [CGSize]) -> [Line] {
        // The modules nearest the anchored edge are the pinned ones; they must keep the first line when the row
        // overflows, so a right-anchored row is filled from its end.
        let fillsFromEnd = alignment == .trailing
        var lines = [Line()]
        for index in fillsFromEnd ? Array(sizes.indices.reversed()) : Array(sizes.indices) {
            let size = sizes[index]
            let last = lines[lines.count - 1]
            let extended = last.indices.isEmpty ? size.width : last.width + spacing + size.width
            if extended > maxWidth, !last.indices.isEmpty {
                lines.append(Line(indices: [index], width: size.width, height: size.height))
            } else {
                lines[lines.count - 1] = Line(indices: last.indices + [index], width: extended, height: max(last.height, size.height))
            }
        }
        return fillsFromEnd ? lines.map { Line(indices: $0.indices.reversed(), width: $0.width, height: $0.height) } : lines
    }

    public func place(_ rows: [[CGSize]]) -> Placed {
        let rowLines = rows.map { lines(of: $0) }
        let width = rowLines.joined().map(\.width).max() ?? 0
        var frames = rows.map { Array(repeating: CGRect.zero, count: $0.count) }
        var y: CGFloat = 0
        var hasPlacedARow = false
        for (row, lines) in rowLines.enumerated() where !rows[row].isEmpty {
            if hasPlacedARow { y += rowSpacing }
            hasPlacedARow = true
            let linesHeight = lines.map(\.height).reduce(0, +) + rowSpacing * CGFloat(lines.count - 1)
            let blockHeight = row == 0 ? max(linesHeight, firstRowMinHeight) : linesHeight
            var lineTop = y + (blockHeight - linesHeight) / 2
            for line in lines {
                var x: CGFloat = switch alignment {
                case .leading: 0
                case .center: (width - line.width) / 2
                case .trailing: width - line.width
                }
                for index in line.indices {
                    let size = rows[row][index]
                    frames[row][index] = CGRect(x: x, y: lineTop + (line.height - size.height) / 2, width: size.width, height: size.height)
                    x += size.width + spacing
                }
                lineTop += line.height + rowSpacing
            }
            y += blockHeight
        }
        return Placed(frames: frames, size: CGSize(width: width, height: y))
    }
}
