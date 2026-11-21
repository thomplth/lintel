import LintelCore
import SwiftUI

struct ChartView: View {
    let node: ViewNode
    let context: RenderContext

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
        let hasLegend = series.contains(where: { !$0.label.isEmpty })
        let hasLabels = !labels.isEmpty
        ChartBlockLayout(
            allowLabels: !context.isShortWidget,
            minCanvasHeight: fillsWidget ? 38 : fixedHeight,
            fixedCanvasHeight: fillsWidget ? nil : fixedHeight,
            spacing: context.metrics.unit
        ) {
            if hasLegend {
                HStack(spacing: context.metrics.unit * 2.5) {
                    ForEach(Array(series.enumerated()), id: \.offset) { entry in
                        HStack(spacing: context.metrics.unit) {
                            Circle().fill(color(entry.element, at: entry.offset)).frame(width: 6, height: 6)
                            Text(entry.element.label).font(context.font(role: "caption")).foregroundStyle(context.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .layoutValue(key: ChartSlotKey.self, value: .legend)
            }
            Group {
                if series.allSatisfy({ $0.values.count < 2 }) {
                    Text("Collecting data…")
                        .font(context.font(role: "caption")).foregroundStyle(context.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(context.fill, in: context.tileShape)
                } else {
                    Canvas { canvas, size in draw(series, kind: kind, in: &canvas, size: size) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .layoutValue(key: ChartSlotKey.self, value: .canvas)
            if hasLabels {
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
                .layoutValue(key: ChartSlotKey.self, value: .labels)
            }
        }
        .clipped()
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

private enum ChartSlot: Equatable {
    case legend
    case canvas
    case labels
}

private struct ChartSlotKey: LayoutValueKey {
    static let defaultValue = ChartSlot.canvas
}

/// Pure single-pass layout for charts: decides legend and axis-label visibility directly from `proposal.height`
/// without mutating `@State` or reading geometry back into `body`.
private struct ChartBlockLayout: Layout {
    let allowLabels: Bool
    let minCanvasHeight: CGFloat
    let fixedCanvasHeight: CGFloat?
    let spacing: CGFloat

    private func measure(width: CGFloat?, maxHeight: CGFloat?, subviews: Subviews) -> (
        legendIdx: Int?, legendH: CGFloat,
        canvasIdx: Int?,
        labelsIdx: Int?, labelsH: CGFloat,
        fit: ChartBlockFit.Result
    ) {
        var legendIdx: Int?
        var canvasIdx: Int?
        var labelsIdx: Int?
        for index in subviews.indices {
            switch subviews[index][ChartSlotKey.self] {
            case .legend: legendIdx = index
            case .canvas: canvasIdx = index
            case .labels: labelsIdx = index
            }
        }
        let legendH = legendIdx.map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height } ?? 0
        let labelsH = labelsIdx.map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height } ?? 0
        let fit = ChartBlockFit.fit(
            hasLegend: legendIdx != nil,
            legendHeight: legendH,
            hasLabels: labelsIdx != nil,
            labelsHeight: labelsH,
            allowLabels: allowLabels,
            minCanvasHeight: minCanvasHeight,
            fixedCanvasHeight: fixedCanvasHeight,
            spacing: spacing,
            maxHeight: maxHeight
        )
        return (legendIdx, legendH, canvasIdx, labelsIdx, labelsH, fit)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 160
        let measured = measure(width: width, maxHeight: proposal.height, subviews: subviews)
        return CGSize(width: width, height: measured.fit.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = measure(width: bounds.width, maxHeight: bounds.height, subviews: subviews)
        let parked = CGPoint(x: bounds.minX, y: bounds.maxY + 200)
        var y = bounds.minY

        if let idx = measured.legendIdx {
            if measured.fit.showLegend {
                subviews[idx].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: measured.legendH))
                y += measured.legendH + spacing
            } else {
                subviews[idx].place(at: parked, proposal: ProposedViewSize(width: 0, height: 0))
            }
        }

        if let idx = measured.canvasIdx {
            subviews[idx].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: measured.fit.canvasHeight))
            y += measured.fit.canvasHeight
        }

        if let idx = measured.labelsIdx {
            if measured.fit.showLabels {
                y += spacing
                subviews[idx].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: measured.labelsH))
            } else {
                subviews[idx].place(at: parked, proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
    }
}
