import AppKit
import LintelCore
import SwiftUI

// MARK: - Diagonal Resize Cursor

enum ResizeCursors {
    /// Crisp vector diagonal resize cursor matching macOS native style (↖↘ for bottom-right, ↗↙ for bottom-left).
    static func cursor(for corner: ResizeCorner) -> NSCursor {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.translateBy(x: 10, y: 10)
            ctx.rotate(by: corner == .bottomRight ? -.pi / 4 : .pi / 4)

            let arrow = CGMutablePath()
            arrow.move(to: CGPoint(x: -7, y: 0))
            arrow.addLine(to: CGPoint(x: -3, y: 3.5))
            arrow.addLine(to: CGPoint(x: -3, y: 1.2))
            arrow.addLine(to: CGPoint(x: 3, y: 1.2))
            arrow.addLine(to: CGPoint(x: 3, y: 3.5))
            arrow.addLine(to: CGPoint(x: 7, y: 0))
            arrow.addLine(to: CGPoint(x: 3, y: -3.5))
            arrow.addLine(to: CGPoint(x: 3, y: -1.2))
            arrow.addLine(to: CGPoint(x: -3, y: -1.2))
            arrow.addLine(to: CGPoint(x: -3, y: -3.5))
            arrow.closeSubpath()

            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2.2)
            ctx.setLineJoin(.round)
            ctx.addPath(arrow)
            ctx.strokePath()

            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(arrow)
            ctx.fillPath()
            ctx.restoreGState()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }

    static let bottomLeft = cursor(for: .bottomLeft)
    static let bottomRight = cursor(for: .bottomRight)
}

// MARK: - Apple-Style Curved Corner Resize Handle

struct CornerArcShape: Shape {
    let corner: ResizeCorner
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, min(rect.width, rect.height) - 2)
        if corner == .bottomRight {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY + 2))
            path.addArc(
                center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                radius: r,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: rect.minX + 2, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + 2))
            path.addArc(
                center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(90),
                clockwise: true
            )
            path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY))
        }
        return path
    }
}

/// Subtle curved corner handle that fades in on hover and drives live morphing drag-resize.
struct ResizeArcHandle: View {
    let corner: ResizeCorner
    let cornerRadius: CGFloat
    let accent: Color
    let primary: Color
    let isCompactChip: Bool
    let isVisible: Bool
    let coordinateSpace: CoordinateSpace
    let onDragStart: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    @State private var isHandleHovered = false
    @State private var isDragging = false

    private var handleBox: CGFloat { isCompactChip ? 14 : 20 }
    private var arcRadius: CGFloat { isCompactChip ? min(cornerRadius, 9) : min(cornerRadius - 3, 15) }

    var body: some View {
        CornerArcShape(corner: corner, radius: max(arcRadius, 4))
            .stroke(
                isDragging || isHandleHovered ? accent : primary.opacity(0.55),
                style: StrokeStyle(lineWidth: isCompactChip ? 2.4 : 3.0, lineCap: .round, lineJoin: .round)
            )
            .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
            .frame(width: handleBox, height: handleBox)
            .padding(isCompactChip ? 2 : 5)
            .contentShape(Rectangle().inset(by: -4))
            .scaleEffect(isVisible || isDragging ? (isHandleHovered || isDragging ? 1.12 : 1.0) : 0.72)
            .opacity(isDragging ? 1 : (isVisible ? (isHandleHovered ? 1 : 0.72) : 0))
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isVisible)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isHandleHovered)
            .onHover { hovering in
                isHandleHovered = hovering
                if hovering {
                    (corner == .bottomLeft ? ResizeCursors.bottomLeft : ResizeCursors.bottomRight).push()
                } else if !isDragging {
                    NSCursor.pop()
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: coordinateSpace)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onDragStart()
                        }
                        onDragChanged(value.translation)
                    }
                    .onEnded { _ in
                        isDragging = false
                        NSCursor.arrow.set()
                        onDragEnded()
                    }
            )
            .help("Drag to resize")
    }
}

// MARK: - Unified Widget Card (Desktop Shelf & Click-to-Peek)

/// Draws one resized module card with zero-scroll adaptive blocks, quiet hover utility pill, configure flip,
/// and anchor-adaptive corner resize handle. Equatable so unrelated widgets never redraw when one module ticks.
struct WidgetCardView: View, Equatable {
    let slot: Slot
    let size: WidgetSize
    let node: ViewNode?
    let configureNode: ViewNode?
    let isConfiguring: Bool
    let isLoading: Bool
    let failure: String?
    let theme: Theme
    let anchor: BarAnchor
    let isPeek: Bool
    let isSelected: Bool
    let isResizingThis: Bool
    let model: BarModel

    @State private var isHovered = false
    @Environment(\.colorScheme) private var systemScheme

    nonisolated static func == (lhs: WidgetCardView, rhs: WidgetCardView) -> Bool {
        MainActor.assumeIsolated {
            lhs.model === rhs.model
                && lhs.slot == rhs.slot
                && lhs.size == rhs.size
                && lhs.node == rhs.node
                && lhs.configureNode == rhs.configureNode
                && lhs.isConfiguring == rhs.isConfiguring
                && lhs.isLoading == rhs.isLoading
                && lhs.failure == rhs.failure
                && lhs.theme == rhs.theme
                && lhs.anchor == rhs.anchor
                && lhs.isPeek == rhs.isPeek
                && lhs.isSelected == rhs.isSelected
                && lhs.isResizingThis == rhs.isResizingThis
        }
    }

    private var material: SurfaceMaterial {
        theme.panelMaterial == "solid" ? .solid : .glass
    }

    private var corner: ResizeCorner {
        WidgetResize.corner(for: anchor)
    }

    private var handleAlignment: Alignment {
        corner == .bottomLeft ? .bottomLeading : .bottomTrailing
    }

    private var pillAlignment: Alignment {
        // Place the hover utility pill at the top corner opposite the resize corner so cursor paths never collide.
        corner == .bottomLeft ? .topTrailing : .topLeading
    }

    private func makeContext(forConfig: Bool = false) -> RenderContext {
        var context = RenderContext(
            theme: theme,
            surface: .panel,
            material: material,
            moduleID: slot.id,
            manifest: model.manifestFor(slot.id),
            widgetSize: forConfig ? nil : size
        )
        let model = model
        context.panelFocus = model.panelFocus
        context.perform = { action, payload in model.onAction(slot.id, action, payload) }
        context.performForResult = { action, payload in await model.onAppAction(slot.id, action, payload) }
        return context
    }

    var body: some View {
        let context = makeContext()
        let frameSize = context.metrics.widgetSize(size)
        let pad = context.metrics.widgetPadding
        let idleFade: Double = (!isPeek && !isHovered && !isConfiguring && theme.idleMaterial == "halo") ? max(theme.idleOpacity, 0.88) : 1.0

        ZStack(alignment: .topLeading) {
            if isConfiguring {
                configureContent(context: makeContext(forConfig: true), pad: pad)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    ))
            } else {
                liveContent(context: context, pad: pad)
                    .id(size)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .topLeading)
        .clipped()
        .modifier(SurfaceBackground(context: context, material: material, shape: context.widgetShape, isInteractive: false))
        .clipShape(context.widgetShape)
        .overlay {
            context.widgetShape.stroke(
                context.primary.opacity(isHovered ? 0.16 : 0.08),
                lineWidth: 0.75
            )
            .allowsHitTesting(false)
        }
        .shadow(
            color: .black.opacity(material == .solid ? (isHovered ? 0.34 : 0.24) : (isHovered ? 0.18 : 0.11)),
            radius: isHovered ? 16 : 10,
            y: isHovered ? 7 : 4
        )
        .overlay(alignment: pillAlignment) {
            hoverUtilityPill(context: context)
                .padding(8)
        }
        .overlay(alignment: handleAlignment) {
            if slot.supportsResize {
                ResizeArcHandle(
                    corner: corner,
                    cornerRadius: CGFloat(context.metrics.widgetCornerRadius),
                    accent: context.accent,
                    primary: context.primary,
                    isCompactChip: false,
                    isVisible: isHovered || isResizingThis,
                    coordinateSpace: isPeek ? .global : .named(barSpace),
                    onDragStart: {
                        let startRect = model.slotFrames[slot.id] ?? CGRect(origin: .zero, size: frameSize)
                        model.beginResizing(slot.id, startTier: size, startRect: startRect, isPeek: isPeek)
                    },
                    onDragChanged: { translation in
                        model.updateResizing(translation: translation)
                    },
                    onDragEnded: {
                        model.endResizing()
                    }
                )
            }
        }
        .anchorPreference(key: SelectionMark.Key.self, value: .bounds) { bounds in
            isSelected ? SelectionMark(
                bounds: bounds,
                cornerRadius: CGFloat(context.metrics.widgetCornerRadius),
                outset: 3,
                color: context.accent
            ) : nil
        }
        .opacity(idleFade)
        .scaleEffect(isResizingThis ? 0.985 : 1.0)
        .animation(theme.motion == "full" ? .spring(response: 0.34, dampingFraction: 0.82) : nil, value: size)
        .animation(theme.motion == "full" ? .spring(response: 0.30, dampingFraction: 0.84) : nil, value: isConfiguring)
        .animation(theme.motion == "full" ? .easeOut(duration: 0.18) : nil, value: isHovered)
        .environment(\.colorScheme, context.colorScheme ?? systemScheme)
        .onHover { hovering in
            isHovered = hovering
            if !hovering && isConfiguring && !isPeek {
                // Keep configure open only while hovered/active; gently auto-return to live view once pointer leaves.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if !isHovered && isConfiguring {
                        model.onToggleConfigure(slot.id, false, false)
                    }
                }
            }
        }
        .contextMenu { widgetContextMenu }
    }

    @ViewBuilder
    private func liveContent(context: RenderContext, pad: Double) -> some View {
        let gap = size == .small || size == .wide ? context.metrics.unit * 1.75 : context.metrics.unit * 2.5
        Group {
            if let node {
                let children = (node.component == .column && node.props.isEmpty) ? node.children : [node]
                AdaptiveStackLayout(spacing: gap, alignment: .leading) {
                    ForEach(Array(children.enumerated()), id: \.offset) { child in
                        NodeView(node: child.element, context: context)
                            .layoutValue(key: BlockPriorityKey.self, value: child.element.layoutPriority)
                            .layoutValue(key: BlockFlexKey.self, value: child.element.layoutFlex)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let failure {
                NodeView(node: ViewNode(.empty, [
                    "icon": "exclamationmark.triangle.fill",
                    "title": .string(slot.title),
                    "message": .string(failure),
                ]), context: context)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NodeView(node: ViewNode(.empty, [
                    "icon": .string(slot.icon),
                    "title": .string(slot.title),
                ]), context: context)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(pad)
    }

    private func configureContent(context: RenderContext, pad: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: context.metrics.unit * 1.5) {
                Image(systemName: slot.icon)
                    .font(.system(size: context.metrics.fontSize(role: "label"), weight: .medium))
                    .foregroundStyle(context.accent)
                Text(slot.title)
                    .font(context.font(role: "label", weight: "semibold"))
                    .foregroundStyle(context.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Done") {
                    model.onToggleConfigure(slot.id, false, isPeek)
                }
                .buttonStyle(.plain)
                .font(context.font(role: "caption", weight: "semibold"))
                .foregroundStyle(context.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(context.accent.opacity(0.14), in: Capsule())
            }
            .padding(.horizontal, pad)
            .padding(.vertical, context.metrics.unit * 2)

            Rectangle().fill(context.separator).frame(height: 1)

            ScrollView(.vertical) {
                if let configureNode {
                    let children = (configureNode.component == .column && configureNode.props.isEmpty) ? configureNode.children : [configureNode]
                    VStack(alignment: .leading, spacing: context.metrics.unit * 2.5) {
                        ForEach(Array(children.enumerated()), id: \.offset) { child in
                            NodeView(node: child.element, context: context)
                        }
                    }
                    .padding(pad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func hoverUtilityPill(context: RenderContext) -> some View {
        let showPill = isHovered && !isResizingThis && !isConfiguring
        HStack(spacing: 3) {
            if slot.hasConfigure {
                pillButton("slider.horizontal.3", "Configure \(slot.title)", context: context, isActive: isConfiguring) {
                    model.onToggleConfigure(slot.id, !isConfiguring, isPeek)
                }
            }
            if isPeek {
                pillButton("pin", "Keep widget on desktop", context: context) {
                    model.onPanelCommand("pin-widget")
                }
            } else {
                pillButton("arrow.down.right.and.arrow.up.left", "Collapse to chip", context: context) {
                    model.onWidgetCommand(slot.id, "collapse")
                }
            }
            pillButton("sparkles", "Open in Lintel Studio", context: context) {
                if isPeek { model.onPanelCommand("change") } else { model.onWidgetCommand(slot.id, "change") }
            }
            pillButton("gearshape", "Settings", context: context) {
                if isPeek { model.onPanelCommand("settings") } else { model.onWidgetCommand(slot.id, "settings") }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(context.primary.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        .opacity(showPill ? 1 : 0)
        .offset(y: showPill ? 0 : -4)
        .scaleEffect(showPill ? 1 : 0.92)
        .allowsHitTesting(showPill)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: showPill)
    }

    private func pillButton(_ symbol: String, _ help: String, context: RenderContext, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isActive ? context.accent : context.secondary)
                .frame(width: 20, height: 20)
                .background(isActive ? context.accent.opacity(0.16) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }

    @ViewBuilder
    private var widgetContextMenu: some View {
        if slot.supportsResize {
            ForEach(slot.supportedSizes, id: \.self) { tier in
                Button {
                    if isPeek && tier.isWidget {
                        model.onResizePreview(slot.id, tier, true)
                    } else {
                        model.onSlotSecondaryAction(slot, "size:\(tier.rawValue)")
                    }
                } label: {
                    if tier == size {
                        Label(tier.displayName, systemImage: "checkmark")
                    } else {
                        Text(tier.displayName)
                    }
                }
            }
            Divider()
        }
        if slot.hasConfigure {
            Button(isConfiguring ? "Done Configuring" : "Configure Widget") {
                model.onToggleConfigure(slot.id, !isConfiguring, isPeek)
            }
        }
        if isPeek {
            Button("Keep Widget on Desktop") { model.onPanelCommand("pin-widget") }
        } else {
            Button("Collapse to Chip") { model.onWidgetCommand(slot.id, "collapse") }
            Button("Hide from Bar") { model.onSlotSecondaryAction(slot, "hide") }
        }
        Divider()
        Button("Ask Assistant to Change This…") { model.onSlotSecondaryAction(slot, "change") }
        Button("Lintel Settings…") { model.onSlotSecondaryAction(slot, "settings") }
    }
}

// MARK: - Bento Shelf SwiftUI Layout

struct BentoWidgetSizeKey: LayoutValueKey {
    static let defaultValue = WidgetSize.small
}

struct BentoWidgetIDKey: LayoutValueKey {
    static let defaultValue = ""
}

struct BentoGridLayout: Layout {
    let flow: BentoFlow

    private func placed(_ subviews: Subviews) -> (result: BentoFlow.Placed, keys: [String]) {
        let keys = subviews.indices.map { index -> String in
            let id = subviews[index][BentoWidgetIDKey.self]
            return id.isEmpty ? "slot-\(index)" : id
        }
        let entries = subviews.indices.map { (key: keys[$0], size: subviews[$0][BentoWidgetSizeKey.self]) }
        return (flow.place(entries), keys)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        placed(subviews).result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (result, keys) = placed(subviews)
        for index in subviews.indices {
            if let frame = result.frames[keys[index]] {
                let offset = frame.offsetBy(dx: bounds.minX, dy: bounds.minY)
                subviews[index].place(at: offset.origin, anchor: .topLeading, proposal: ProposedViewSize(offset.size))
            }
        }
    }
}

// MARK: - Live Corner-Drag Resize Ghost & Tier Pill Overlay

struct ResizeOverlayView: View {
    @ObservedObject var drag: ResizeDragState
    let model: BarModel

    var body: some View {
        if let id = drag.activeSlotID, !drag.isPeek {
            let metrics = Metrics(model.theme)
            let accent = RenderContext.color(hex: model.theme.accentColor)
            let snapSize: CGSize = drag.targetTier.isWidget
                ? metrics.widgetSize(drag.targetTier)
                : CGSize(width: max(drag.startRect.width, 72), height: 30)
            let liveSize = drag.proposedSize
            let start = drag.startRect

            let anchorX: CGFloat = drag.corner == .bottomLeft ? start.maxX : start.minX
            let snapOrigin = CGPoint(
                x: drag.corner == .bottomLeft ? anchorX - snapSize.width : anchorX,
                y: start.minY
            )
            let liveOrigin = CGPoint(
                x: drag.corner == .bottomLeft ? anchorX - liveSize.width : anchorX,
                y: start.minY
            )
            let cornerR = drag.targetTier.isWidget ? CGFloat(metrics.widgetCornerRadius) : 14

            ZStack(alignment: .topLeading) {
                // Target snap footprint (magnetic Bento outline)
                RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                    .fill(accent.opacity(0.09))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                            .strokeBorder(accent.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    }
                    .frame(width: snapSize.width, height: snapSize.height)
                    .offset(x: snapOrigin.x, y: snapOrigin.y)
                    .animation(.spring(response: 0.26, dampingFraction: 0.78), value: drag.targetTier)

                // Rubbery live tracking bezel
                RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                    .strokeBorder(accent.opacity(0.35), lineWidth: 1)
                    .frame(width: max(liveSize.width, 28), height: max(liveSize.height, 24))
                    .offset(x: liveOrigin.x, y: liveOrigin.y)

                // Tier badge pill near the dragged corner
                HStack(spacing: 5) {
                    Text(drag.targetTier.displayName)
                        .font(.system(size: 11, weight: .semibold))
                    if drag.targetTier.isWidget {
                        Text("\(drag.targetTier.columns)×\(drag.targetTier.rows)")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .opacity(0.75)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(accent.gradient, in: Capsule())
                .shadow(color: accent.opacity(0.35), radius: 8, y: 3)
                .offset(
                    x: (drag.corner == .bottomLeft ? snapOrigin.x + 8 : snapOrigin.x + snapSize.width - 78),
                    y: snapOrigin.y + snapSize.height + 6
                )
                .animation(.spring(response: 0.24, dampingFraction: 0.78), value: drag.targetTier)
            }
            .allowsHitTesting(false)
            .id(id)
        }
    }
}
