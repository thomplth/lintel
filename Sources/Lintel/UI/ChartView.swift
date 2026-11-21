import LintelCore
import SwiftUI

struct ChartView: View {
    let node: ViewNode
    let context: RenderContext
    @State private var measuredHeight: CGFloat = 120

    private var palette: [Color] {
        [context.accent, .orange, .green, .purple]
    }

    private func color(_ series: ChartSeries, at index: Int) -> Color {
        series.tone.map { context.color($0) } ?? palette[index % palette.count]
    }

    var body: some View {
        let series = node.series
        let kind = node.string("kind") ?? "area"
        let labels = node.strings("labels")
        let heightToken = node.string("height")
        let fillsWidget = context.isInWidget && (heightToken == nil || heightToken == "fill")
        let fixedHeight = CGFloat(context.metrics.blockHeight(heightToken))
        let minH: CGFloat = fillsWidget ? 38 : fixedHeight
        let maxH: CGFloat = fillsWidget ? .infinity : fixedHeight
        let showLegend = series.contains(where: { !$0.label.isEmpty }) && measuredHeight >= 56
        let showLabels = !labels.isEmpty && !context.isShortWidget && measuredHeight >= 76
        VStack(alignment: .leading, spacing: context.metrics.unit) {
            if showLegend {
                HStack(spacing: context.metrics.unit * 2.5) {
                    ForEach(Array(series.enumerated()), id: \.offset) { entry in
                        HStack(spacing: context.metrics.unit) {
                            Circle().fill(color(entry.element, at: entry.offset)).frame(width: 6, height: 6)
                            Text(entry.element.label).font(context.font(role: "caption")).foregroundStyle(context.secondary).lineLimit(1)
                        }
                    }
                }
            }
            if series.allSatisfy({ $0.values.count < 2 }) {
                Text("Collecting data…")
                    .font(context.font(role: "caption")).foregroundStyle(context.tertiary)
                    .frame(maxWidth: .infinity, minHeight: minH, maxHeight: maxH)
                    .background(context.fill, in: context.tileShape)
            } else {
                Canvas { canvas, size in draw(series, kind: kind, in: &canvas, size: size) }
                    .frame(maxWidth: .infinity, minHeight: minH, maxHeight: maxH)
            }
            if showLabels {
                HStack {
                    Text(labels.first ?? "")
                    Spacer()
                    if labels.count > 2 {
                        Text(labels[labels.count / 2])
                        Spacer()
                    }
                    if labels.count > 1 { Text(labels.last ?? "") }
                }
                .font(context.font(role: "caption"))
                .foregroundStyle(context.tertiary)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
            if abs(h - measuredHeight) > 1 { measuredHeight = h }
        }
    }

    private func draw(_ series: [ChartSeries], kind: String, in canvas: inout GraphicsContext, size: CGSize) {
        let all = series.flatMap(\.values)
        guard let low = all.min(), let high = all.max() else { return }
        // A series that hovers far above zero would draw as a flat line on a zero-based axis, so zoom in on it;
        // bars always start at zero because their length is the value.
        let hugsZero = kind == "bar" || low < 0 || low <= high * 0.5
        let floor = node.number("min") ?? (hugsZero ? min(low, 0) : low - (high - low) * 0.15)
        var ceiling = node.number("max") ?? (hugsZero ? high : high + (high - low) * 0.08)
        if ceiling <= floor { ceiling = floor + 1 }
        let inset = 2.0
        func y(_ value: Double) -> Double {
            inset + (size.height - inset * 2) * (1 - min(max((value - floor) / (ceiling - floor), 0), 1))
        }

        for step in 0...2 {
            let line = inset + (size.height - inset * 2) * Double(step) / 2
            var path = Path()
            path.move(to: CGPoint(x: 0, y: line))
            path.addLine(to: CGPoint(x: size.width, y: line))
            canvas.stroke(path, with: .color(context.separator), style: StrokeStyle(lineWidth: 1, dash: step == 2 ? [] : [2, 3]))
        }

        for (index, entry) in series.enumerated() where entry.values.count > 1 {
            let tint = color(entry, at: index)
            let values = entry.values
            if kind == "bar" {
                let slot = size.width / Double(values.count)
                let width = max(slot * 0.68 / Double(series.count), 1)
                for (position, value) in values.enumerated() {
                    let top = y(value)
                    let x = Double(position) * slot + slot * 0.16 + Double(index) * width
                    let bar = CGRect(x: x, y: top, width: width, height: max(y(floor) - top, 1))
                    canvas.fill(Path(roundedRect: bar, cornerRadius: min(width / 3, 2.5)), with: .color(tint))
                }
                continue
            }
            let points = values.enumerated().map { position, value in
                CGPoint(x: size.width * Double(position) / Double(values.count - 1), y: y(value))
            }
            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() { line.addLine(to: point) }
            if kind == "area", index == 0 || series.count <= 2 {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                canvas.fill(area, with: .linearGradient(
                    Gradient(colors: [tint.opacity(series.count > 1 ? 0.22 : 0.34), tint.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)
                ))
            }
            canvas.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}
