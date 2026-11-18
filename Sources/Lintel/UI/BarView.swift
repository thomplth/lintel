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
        let _ = Perf.count("view.bar")
        let theme = model.theme
        let material = material
        let hasCapsules = material == .glass || material == .solid
        let isInMenuBar = host == .menuBar
        let spacing = max(theme.rowSpacing, hasCapsules ? 3 : 0)
        BarRows(flow: BarFlow(
            spacing: hasCapsules ? max(theme.moduleSpacing * 0.5, 4) : theme.moduleSpacing, rowSpacing: spacing,
            alignment: BarFlow.Alignment(model.alignment),
            // A menu bar item cannot grow taller; one too wide goes behind the menu bar's overflow button.
            maxWidth: isInMenuBar ? .greatestFiniteMagnitude : model.maxBarWidth,
            firstRowMinHeight: isInMenuBar ? 0 : model.topRowMinHeight
        )) {
            // One flat ForEach keyed by module: nested per row, a module changing rows would get a new identity and
            // fade out of one row and into the other instead of sliding.
            ForEach(rows.enumerated().flatMap { row, slots in slots.map { (row: row, slot: $0) } }, id: \.slot.id) { placed in
                ChipView(slot: placed.slot, model: model, material: material)
                    .equatable()
                    .layoutValue(key: BarRowIndex.self, value: placed.row)
                    .transition(Arrival())
            }
        }
        .overlayPreferenceValue(SelectionMark.Key.self) { mark in
            SelectionRing(
                mark: mark, isDimmed: model.isDrivenByKeyboard && model.panel != nil, bump: model.selectionBump,
                animates: model.animatesSelection
            )
        }
        .padding(.horizontal, isInMenuBar ? 4 : Placement.barSidePadding)
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
        .animation(theme.motion == "full" ? BarModel.reflow : nil, value: model.isActive)
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

/// Takes from the model only what it draws, so `.equatable()` can skip chips a change of the model did not touch;
/// observing the whole model, every chip in the bar redrew whenever any one module updated.
struct ChipView: View, Equatable {
    let slot: Slot
    /// For callbacks and frame reports only; reading its state in `body` would go stale, since the model is not observed.
    let model: BarModel
    let theme: Theme
    let material: SurfaceMaterial
    let isActive: Bool
    let isPanelOpen: Bool
    let isLeftForTheCarrier: Bool
    let isPinned: Bool
    let pinsOnTheLeft: Bool
    let isCarried: Bool
    let isSelected: Bool
    @Environment(\.isInMenuBar) private var isInMenuBar
    @State private var isHovered = false

    init(slot: Slot, model: BarModel, material: SurfaceMaterial, isCarried: Bool = false) {
        self.slot = slot
        self.model = model
        self.material = material
        self.isCarried = isCarried
        theme = model.theme
        isActive = model.isActive
        isPanelOpen = model.panel?.slotID == slot.id
        isLeftForTheCarrier = !isCarried && model.rearrangement?.key == slot.id
        isPinned = model.layout.isPinned(slot.id, default: slot.isPinned)
        pinsOnTheLeft = model.alignment == .leading
        isSelected = !isCarried && model.keyboardSelection == slot.id
    }

    nonisolated static func == (lhs: ChipView, rhs: ChipView) -> Bool {
        MainActor.assumeIsolated {
            lhs.model === rhs.model && lhs.slot == rhs.slot && lhs.theme == rhs.theme && lhs.material == rhs.material
                && lhs.isActive == rhs.isActive && lhs.isPanelOpen == rhs.isPanelOpen
                && lhs.isLeftForTheCarrier == rhs.isLeftForTheCarrier && lhs.isPinned == rhs.isPinned
                && lhs.pinsOnTheLeft == rhs.pinsOnTheLeft && lhs.isCarried == rhs.isCarried
                && lhs.isSelected == rhs.isSelected
        }
    }

    var body: some View {
        let _ = Perf.count("view.chip")
        Group {
            if slot.kind == .pinDivider { pinDivider } else { chip }
        }
        .opacity(isLeftForTheCarrier ? 0 : 1)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(barSpace)) }, action: {
            if !isCarried { model.report(frame: $0, of: slot.id, isInMenuBar: isInMenuBar) }
        })
    }

    /// Drawn as wide as a grab needs, since drags pick what they carry by the frames chips report.
    private var pinDivider: some View {
        let context = RenderContext(theme: theme, surface: .chip, material: material, moduleID: slot.id)
        let height = context.metrics.fontSize(role: nil) * 1.3 + context.metrics.chipPaddingVertical * 2
        return Capsule()
            .fill(context.accent.opacity(0.28))
            .strokeBorder(context.accent.opacity(0.65), lineWidth: 1)
            .overlay {
                Image(systemName: "ellipsis")
                    .font(.system(size: context.metrics.fontSize(role: nil) * 0.75, weight: .bold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(context.accent)
            }
            .frame(width: 11, height: height)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .help("Modules on the \(pinsOnTheLeft ? "left" : "right") of this divider stay in the bar while it is closed. ⌘-drag modules or the divider to change which.")
            .accessibilityLabel("Pin divider")
    }

    private var chip: some View {
        let context = RenderContext(theme: theme, surface: .chip, material: material, moduleID: slot.id)
        let hasCapsule = material == .glass || material == .solid
        let isOpen = isActive || isInMenuBar
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
            .glassEffectTransition(.identity)
            .overlay {
                if hasCapsule, isPanelOpen {
                    context.chipShape.stroke(context.accent.opacity(0.9), lineWidth: 1.5)
                }
            }
            .anchorPreference(key: SelectionMark.Key.self, value: .bounds) { bounds in
                isSelected ? SelectionMark(
                    bounds: bounds, cornerRadius: context.metrics.chipCornerRadius.map { CGFloat($0) }, outset: hasCapsule ? 2 : 6,
                    color: context.accent
                ) : nil
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { if isClickable, model.rearrangement == nil { model.onSlotClick(slot) } }
            .contextMenu { menu }
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
                .renderingMode(image.isTemplate ? .template : .original)
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

/// Where the selected chip lies, so one ring drawn over the whole bar can slide between chips.
struct SelectionMark: Equatable {
    var bounds: Anchor<CGRect>
    /// nil for a capsule.
    var cornerRadius: CGFloat?
    /// How far the ring stands outside the chip horizontally; chips without a capsule draw their text edge to edge.
    var outset: CGFloat
    var color: Color

    struct Key: PreferenceKey {
        static let defaultValue: SelectionMark? = nil
        static func reduce(value: inout SelectionMark?, nextValue: () -> SelectionMark?) {
            value = value ?? nextValue()
        }
    }
}

/// Dimmed while focus is in the selected module's panel; nudges up or down when a step finds no row there.
private struct SelectionRing: View {
    let mark: SelectionMark?
    let isDimmed: Bool
    let bump: SelectionBump
    let animates: Bool

    var body: some View {
        GeometryReader { proxy in
            if let mark {
                let rect = proxy[mark.bounds].insetBy(dx: -mark.outset, dy: -2)
                let shape = mark.cornerRadius.map { AnyShape(RoundedRectangle(cornerRadius: $0 + 2, style: .continuous)) }
                    ?? AnyShape(Capsule())
                shape
                    .fill(mark.color.opacity(isDimmed ? 0 : 0.12))
                    .stroke(mark.color.opacity(isDimmed ? 0.45 : 1), lineWidth: isDimmed ? 1.5 : 2)
                    .shadow(color: mark.color.opacity(isDimmed ? 0 : 0.55), radius: 5)
                    .frame(width: rect.width, height: rect.height)
                    .keyframeAnimator(initialValue: CGFloat(0), trigger: bump.count) { ring, offset in
                        ring.offset(y: bump.direction == .up ? -offset : offset)
                    } keyframes: { _ in
                        SpringKeyframe(animates ? 4 : 0, duration: 0.09)
                        SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                    }
                    .position(x: rect.midX, y: rect.midY)
                    .animation(animates ? .spring(duration: 0.28, bounce: 0.16) : nil, value: rect)
                    .animation(animates ? .easeOut(duration: 0.18) : nil, value: isDimmed)
                    .transition(animates ? .opacity.combined(with: .scale(scale: 1.15)) : .identity)
            }
        }
        .animation(animates ? .easeOut(duration: 0.18) : nil, value: mark == nil)
        .allowsHitTesting(false)
    }
}

/// The module being dragged, drawn in a screen-sized window above the bar so it can follow the pointer anywhere.
struct CarrierView: View {
    @ObservedObject var model: BarModel

    var body: some View {
        if let rearrangement = model.rearrangement, let slot = model.slot(rearrangement.key) {
            CarriedChip(slot: slot, rearrangement: rearrangement, model: model, pointer: model.carried)
                .id(slot.id)
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
}

/// Starts exactly over the module it lifts out of the bar, then rises under the pointer.
private struct CarriedChip: View {
    let slot: Slot
    let rearrangement: Rearrangement
    @ObservedObject var model: BarModel
    @ObservedObject var pointer: CarriedPointer
    @State private var isLifted = false

    var body: some View {
        let carried = CGPoint(
            x: pointer.point.x - rearrangement.grabOffset.width, y: pointer.point.y - rearrangement.grabOffset.height
        )
        let barTopLeft = rearrangement.phase == .landing ? model.slotFrames[slot.id]?.origin ?? carried : carried
        let topLeft = model.barToCarrier(barTopLeft)
        let isRaised = isLifted && rearrangement.phase == .carrying
        ChipView(slot: slot, model: model, material: SurfaceMaterial(active: model.theme.activeMaterial), isCarried: true)
            .equatable()
            .fixedSize()
            .scaleEffect(rearrangement.phase == .vanishing ? 0.5 : isRaised ? 1.06 : 1, anchor: anchor)
            .opacity(rearrangement.phase == .vanishing ? 0 : 1)
            .shadow(color: .black.opacity(isRaised ? 0.3 : 0), radius: isRaised ? 10 : 0, y: isRaised ? 4 : 0)
            .offset(x: topLeft.x, y: topLeft.y)
            .onAppear { withAnimation(BarModel.lift) { isLifted = true } }
    }

    /// Scales about the grab point, so the module grows and shrinks around the pointer instead of sliding under it.
    private var anchor: UnitPoint {
        guard rearrangement.size.width > 0, rearrangement.size.height > 0 else { return .center }
        return UnitPoint(x: rearrangement.grabOffset.width / rearrangement.size.width, y: rearrangement.grabOffset.height / rearrangement.size.height)
    }
}

/// Modules arriving as the bar opens grow out of their place rather than materialising their glass from a blur.
private struct Arrival: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        // scaleEffect would also shrink the frame ChipView reports, and a frame read mid-transition stays the module's
        // frame for drops and landings; a visual effect changes only what is drawn.
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .visualEffect { effect, _ in effect.scaleEffect(phase.isIdentity ? 1 : 0.82) }
    }
}

private struct BarRowIndex: LayoutValueKey {
    static let defaultValue = 0
}

extension BarFlow.Alignment {
    init(_ alignment: HorizontalAlignment) {
        switch alignment {
        case .leading: self = .leading
        case .center: self = .center
        default: self = .trailing
        }
    }
}

/// Every row of the bar in one layout, so a module moving to another row slides there as the same view.
struct BarRows: Layout {
    var flow: BarFlow

    private func placed(_ subviews: Subviews) -> (placed: BarFlow.Placed, members: [[Int]]) {
        let rowCount = (subviews.map { $0[BarRowIndex.self] }.max() ?? -1) + 1
        var members = Array(repeating: [Int](), count: rowCount)
        for index in subviews.indices { members[subviews[index][BarRowIndex.self]].append(index) }
        let sizes = members.map { $0.map { subviews[$0].sizeThatFits(.unspecified) } }
        return (flow.place(sizes), members)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        placed(subviews).placed.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (placed, members) = placed(subviews)
        for (row, indices) in members.enumerated() {
            for (position, index) in indices.enumerated() {
                let frame = placed.frames[row][position].offsetBy(dx: bounds.minX, dy: bounds.minY)
                subviews[index].place(at: frame.origin, proposal: ProposedViewSize(frame.size))
            }
        }
    }
}
