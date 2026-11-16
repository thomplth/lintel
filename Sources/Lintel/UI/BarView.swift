import AppKit
import LintelCore
import SwiftUI

struct BarView: View {
    @ObservedObject var model: BarModel

    private var material: SurfaceMaterial {
        model.isActive ? SurfaceMaterial(active: model.theme.activeMaterial) : SurfaceMaterial(idle: model.theme.idleMaterial)
    }

    var body: some View {
        let theme = model.theme
        let material = material
        let hasCapsules = material == .glass || material == .solid
        GlassEffectContainer(spacing: 0) {
            VStack(alignment: model.alignment, spacing: max(theme.rowSpacing, hasCapsules ? 3 : 0)) {
                ForEach(Array(model.visibleRows.enumerated()), id: \.offset) { row in
                    WrappingRow(
                        spacing: hasCapsules ? max(theme.moduleSpacing * 0.5, 4) : theme.moduleSpacing,
                        lineSpacing: max(theme.rowSpacing, hasCapsules ? 3 : 0), alignment: model.alignment,
                        maxWidth: model.maxBarWidth
                    ) {
                        ForEach(row.element) { slot in
                            ChipView(slot: slot, model: model, material: material)
                        }
                    }
                    .frame(minHeight: row.offset == 0 ? model.topRowMinHeight : 0)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .opacity(model.isActive ? 1 : theme.idleOpacity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { model.onDragChanged($0.translation) }
                .onEnded { model.onDragEnded($0.translation.width) }
        )
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { model.onContentSize($0) })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: model.alignment, vertical: .top))
        .animation(theme.motion == "full" ? .smooth(duration: 0.22) : nil, value: model.isActive)
        .environment(\.colorScheme, colorScheme(for: material) ?? systemScheme)
        .onExitCommand { model.onDismiss() }
    }

    @Environment(\.colorScheme) private var systemScheme

    private func colorScheme(for material: SurfaceMaterial) -> ColorScheme? {
        switch model.theme.colorScheme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

struct ChipView: View {
    let slot: Slot
    @ObservedObject var model: BarModel
    let material: SurfaceMaterial
    @State private var isHovered = false

    private var isPanelOpen: Bool {
        model.panel?.slotID == slot.id
    }

    var body: some View {
        let context = RenderContext(theme: model.theme, surface: .chip, material: material, moduleID: slot.id)
        let hasCapsule = material == .glass || material == .solid
        let isClickable = model.isActive && slot.isClickable
        content(context)
            .frame(minHeight: context.metrics.fontSize(role: nil) * 1.3)
            .padding(.horizontal, hasCapsule ? context.metrics.chipPaddingHorizontal : 0)
            .padding(.vertical, hasCapsule ? context.metrics.chipPaddingVertical : 0)
            .background {
                if !hasCapsule, model.isActive, isHovered || isPanelOpen, isClickable {
                    context.chipShape.fill(.black.opacity(0.28)).padding(.horizontal, -6).padding(.vertical, -2)
                }
            }
            .modifier(SurfaceBackground(context: context, material: material, shape: context.chipShape, isInteractive: isClickable))
            .overlay {
                if hasCapsule, isPanelOpen {
                    context.chipShape.stroke(context.accent.opacity(0.9), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { if isClickable { model.onSlotClick(slot) } }
            .contextMenu { menu }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { model.slotFrames[slot.id] = $0 })
            .help(model.isActive ? slot.failure ?? slot.title : "")
            .accessibilityLabel(slot.title)
    }

    @ViewBuilder private func content(_ context: RenderContext) -> some View {
        if slot.kind == .assistant {
            Image(systemName: "sparkles")
                .font(.system(size: context.metrics.fontSize(role: nil), weight: context.weight(nil)))
                .foregroundStyle(context.primary)
        } else if slot.needsApproval {
            HStack(spacing: context.metrics.chipContentSpacing) {
                Image(systemName: "lock.fill").foregroundStyle(Color.orange)
                Text(slot.title).foregroundStyle(context.primary).lineLimit(1)
            }
            .font(context.font())
        } else if slot.failure != nil {
            HStack(spacing: context.metrics.chipContentSpacing) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                Text(slot.title).foregroundStyle(context.primary).lineLimit(1)
            }
            .font(context.font())
        } else if let image = slot.image {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: context.theme.fontSize * 1.45)
                .foregroundStyle(context.primary)
        } else if let chip = slot.chip {
            NodeView(node: chip, context: context)
        } else {
            Image(systemName: slot.icon)
                .font(.system(size: context.metrics.fontSize(role: nil), weight: context.weight(nil)))
                .foregroundStyle(context.secondary)
        }
    }

    @ViewBuilder private var menu: some View {
        if slot.kind != .assistant {
            let isPinned = model.layout.isPinned(slot.id, default: slot.isPinned)
            Button(isPinned ? "Show Only When Active" : "Always Show") { model.onSlotSecondaryAction(slot, "pin") }
            Button("Hide from Bar") { model.onSlotSecondaryAction(slot, "hide") }
            Divider()
            Button("Move Left") { model.onSlotSecondaryAction(slot, "left") }
            Button("Move Right") { model.onSlotSecondaryAction(slot, "right") }
            Button("Move Up a Row") { model.onSlotSecondaryAction(slot, "up") }
            Button("Move Down a Row") { model.onSlotSecondaryAction(slot, "down") }
            Divider()
            if slot.kind == .module {
                Button("Ask Assistant to Change This…") { model.onSlotSecondaryAction(slot, "change") }
            }
        }
        Button("Lintel Settings…") { model.onSlotSecondaryAction(slot, "settings") }
    }
}

/// One row of the bar. It stays on one line until it would be wider than the screen allows, then wraps.
struct WrappingRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var alignment: HorizontalAlignment
    var maxWidth: CGFloat

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(_ subviews: Subviews) -> (lines: [Line], sizes: [CGSize]) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        // The items nearest the anchored edge are the pinned ones; they must keep the first line when the row
        // overflows, so a right-anchored row is filled from its end.
        let fillsFromEnd = alignment == .trailing
        let order = fillsFromEnd ? Array(sizes.indices.reversed()) : Array(sizes.indices)
        var lines = [Line()]
        for index in order {
            let size = sizes[index]
            var line = lines[lines.count - 1]
            let extended = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if extended > maxWidth, !line.indices.isEmpty {
                lines.append(Line(indices: [index], width: size.width, height: size.height))
                continue
            }
            line.indices.append(index)
            line.width = extended
            line.height = max(line.height, size.height)
            lines[lines.count - 1] = line
        }
        if fillsFromEnd { lines = lines.map { Line(indices: $0.indices.reversed(), width: $0.width, height: $0.height) } }
        return (lines, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(subviews).lines
        return CGSize(
            width: lines.map(\.width).max() ?? 0,
            height: lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (lines, sizes) = lines(subviews)
        var y = bounds.minY
        for line in lines {
            var x: CGFloat = switch alignment {
            case .leading: bounds.minX
            case .center: bounds.midX - line.width / 2
            default: bounds.maxX - line.width
            }
            for index in line.indices {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - sizes[index].height) / 2), proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
