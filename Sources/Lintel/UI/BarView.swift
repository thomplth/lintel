import AppKit
import LintelCore
import SwiftUI

/// The coordinate space chips report their frames in: the top-left of the view hosting them.
let barSpace = "bar"

struct BarView: View {
    enum Host {
        /// The bar's own window, holding every row, or every row after the first while that lives in the menu bar.
        case window
        /// A system menu bar item holding the first row, which always shows all its modules.
        case menuBar
    }

    @ObservedObject var model: BarModel
    var host = Host.window
    @State private var isMovingBar = false
    @Namespace private var chipTravel

    private var looksActive: Bool {
        model.isActive || host == .menuBar
    }

    private var material: SurfaceMaterial {
        looksActive ? SurfaceMaterial(active: model.theme.activeMaterial) : SurfaceMaterial(idle: model.theme.idleMaterial)
    }

    private var rows: [[Slot]] {
        switch host {
        case .menuBar: Array(model.visibleRows.prefix(1))
        case .window: model.isFirstRowInMenuBar ? Array(model.visibleRows.dropFirst()) : model.visibleRows
        }
    }

    var body: some View {
        let theme = model.theme
        let material = material
        let hasCapsules = material == .glass || material == .solid
        let isInMenuBar = host == .menuBar
        GlassEffectContainer(spacing: 0) {
            VStack(alignment: model.alignment, spacing: max(theme.rowSpacing, hasCapsules ? 3 : 0)) {
                ForEach(Array(rows.enumerated()), id: \.offset) { row in
                    WrappingRow(
                        spacing: hasCapsules ? max(theme.moduleSpacing * 0.5, 4) : theme.moduleSpacing,
                        lineSpacing: max(theme.rowSpacing, hasCapsules ? 3 : 0), alignment: model.alignment,
                        // A menu bar item cannot grow taller; one too wide goes behind the menu bar's overflow button.
                        maxWidth: isInMenuBar ? .greatestFiniteMagnitude : model.maxBarWidth
                    ) {
                        ForEach(row.element) { slot in
                            ChipView(slot: slot, model: model, material: material, travel: chipTravel)
                        }
                    }
                    .frame(minHeight: row.offset == 0 && !isInMenuBar ? model.topRowMinHeight : 0)
                }
            }
        }
        .padding(.horizontal, isInMenuBar ? 4 : 8)
        .padding(.top, model.topRowMinHeight > 0 || isInMenuBar ? 0 : 4)
        .padding(.bottom, isInMenuBar ? 0 : 4)
        .frame(minWidth: isInMenuBar ? 16 : 0)
        .opacity(looksActive ? 1 : theme.idleOpacity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named(barSpace))
                .onChanged(dragChanged)
                .onEnded(dragEnded)
        )
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { size in
            if isInMenuBar { model.onMenuBarRowContentSize(size) } else { model.onContentSize(size) }
        })
        .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: isInMenuBar ? .trailing : Alignment(horizontal: model.alignment, vertical: .top)
        )
        .coordinateSpace(name: barSpace)
        .environment(\.isInMenuBar, isInMenuBar)
        .animation(theme.motion == "full" ? .smooth(duration: 0.22) : nil, value: model.isActive)
        .environment(\.colorScheme, colorScheme(for: material) ?? systemScheme)
        .onExitCommand { model.onDismiss() }
    }

    @Environment(\.colorScheme) private var systemScheme

    private func dragChanged(_ value: DragGesture.Value) {
        if model.rearrangement != nil {
            model.carry(to: value.location)
        } else if !isMovingBar, model.isActive, isCommandHeld, let key = model.slotID(at: value.startLocation) {
            model.beginRearranging(key, grabbedAt: value.startLocation)
            model.carry(to: value.location)
        } else if !model.isFirstRowInMenuBar {
            isMovingBar = true
            model.onDragChanged(value.translation)
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        if model.rearrangement != nil {
            model.carry(to: value.location)
            model.drop()
        } else {
            isMovingBar = false
            model.onDragEnded(value.translation.width)
        }
    }

    private var isCommandHeld: Bool {
        NSEvent.modifierFlags.contains(.command) || NSApp.currentEvent?.modifierFlags.contains(.command) == true
    }

    private func colorScheme(for material: SurfaceMaterial) -> ColorScheme? {
        switch model.theme.colorScheme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

extension EnvironmentValues {
    @Entry var isInMenuBar = false
}

struct ChipView: View {
    let slot: Slot
    @ObservedObject var model: BarModel
    @Environment(\.isInMenuBar) private var isInMenuBar
    let material: SurfaceMaterial
    var travel: Namespace.ID?
    var isCarried = false
    @State private var isHovered = false

    private var isPanelOpen: Bool {
        model.panel?.slotID == slot.id
    }

    var body: some View {
        if !isCarried, let rearrangement = model.rearrangement, rearrangement.key == slot.id {
            // GlassEffectContainer draws every chip's glass and content itself, so opacity(0) leaves the chip visible.
            Color.clear
                .frame(width: rearrangement.size.width, height: rearrangement.size.height)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(barSpace)) }, action: {
                    model.report(frame: $0, of: slot.id, isInMenuBar: isInMenuBar)
                })
                .modifier(Travels(id: slot.id, namespace: travel))
        } else {
            chip
        }
    }

    private var chip: some View {
        let context = RenderContext(theme: model.theme, surface: .chip, material: material, moduleID: slot.id)
        let hasCapsule = material == .glass || material == .solid
        let isOpen = model.isActive || isInMenuBar
        let isClickable = isOpen && slot.isClickable
        return content(context)
            .frame(minHeight: context.metrics.fontSize(role: nil) * 1.3)
            .padding(.horizontal, hasCapsule ? context.metrics.chipPaddingHorizontal : 0)
            .padding(.vertical, hasCapsule ? context.metrics.chipPaddingVertical : 0)
            .background {
                if !hasCapsule, isOpen, isHovered || isPanelOpen, isClickable {
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
            .onTapGesture { if isClickable, model.rearrangement == nil { model.onSlotClick(slot) } }
            .contextMenu { menu }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(barSpace)) }, action: {
                if !isCarried { model.report(frame: $0, of: slot.id, isInMenuBar: isInMenuBar) }
            })
            .modifier(Travels(id: slot.id, namespace: isCarried ? nil : travel))
            .help(isOpen ? slot.failure ?? slot.title : "")
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

/// The module being dragged, drawn in a screen-sized window above the bar so it can follow the pointer anywhere.
struct CarrierView: View {
    @ObservedObject var model: BarModel

    var body: some View {
        if let rearrangement = model.rearrangement, let slot = model.slot(rearrangement.key) {
            let carried = CGPoint(
                x: model.carriedPointer.x - rearrangement.grabOffset.width, y: model.carriedPointer.y - rearrangement.grabOffset.height
            )
            let barTopLeft = rearrangement.phase == .landing ? model.slotFrames[slot.id]?.origin ?? carried : carried
            let topLeft = model.barToCarrier(barTopLeft)
            ChipView(slot: slot, model: model, material: SurfaceMaterial(active: model.theme.activeMaterial), isCarried: true)
                .fixedSize()
                .opacity(rearrangement.phase == .vanishing ? 0 : 1)
                .scaleEffect(scale(of: rearrangement))
                .blur(radius: rearrangement.phase == .vanishing ? 4 : 0)
                .shadow(color: .black.opacity(rearrangement.phase == .carrying ? 0.3 : 0), radius: 10, y: 4)
                .offset(x: topLeft.x, y: topLeft.y)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(\.colorScheme, colorScheme ?? systemScheme)
                .allowsHitTesting(false)
        }
    }

    @Environment(\.colorScheme) private var systemScheme

    private var colorScheme: ColorScheme? {
        switch model.theme.colorScheme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private func scale(of rearrangement: Rearrangement) -> CGFloat {
        switch rearrangement.phase {
        case .carrying: 1.08
        case .landing: 1
        case .vanishing: 0.5
        }
    }
}

/// Lets a chip glide between rows, which are separate containers, instead of vanishing from one and appearing in the other.
private struct Travels: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace { content.matchedGeometryEffect(id: id, in: namespace) } else { content }
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
