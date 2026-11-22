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

// MARK: - Apple-Style Curved Corner & Edge Resize Handles

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

/// Subtle curved corner handle that fades in on hover and drives live freeform 2D resizing (double-click fits height).
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
    var onDoubleClick: (() -> Void)? = nil

    @State private var isHandleHovered = false
    @State private var isDragging = false
    @State private var dragStartScreenPoint: CGPoint?

    private var handleBox: CGFloat { isCompactChip ? 14 : 20 }
    private var arcRadius: CGFloat { isCompactChip ? min(cornerRadius, 9) : min(cornerRadius - 3, 14) }

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
            .onTapGesture(count: 2) {
                onDoubleClick?()
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: coordinateSpace)
                    .onChanged { _ in
                        let current = NSEvent.mouseLocation
                        if !isDragging {
                            isDragging = true
                            dragStartScreenPoint = current
                            onDragStart()
                        }
                        let start = dragStartScreenPoint ?? current
                        onDragChanged(WidgetResize.screenTranslation(from: start, to: current))
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragStartScreenPoint = nil
                        NSCursor.arrow.set()
                        onDragEnded()
                    }
            )
            .help(isCompactChip ? "Drag to expand into a widget" : "Drag to resize · Double-click to fit height")
    }
}

/// Invisible edge hit-strip for single-axis resizing (bottom edge = height, inward side edge = width).
private struct ResizeEdgeHandle: View {
    let isHorizontalEdge: Bool
    let coordinateSpace: CoordinateSpace
    let onDragStart: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void
    var onDoubleClick: (() -> Void)? = nil

    @State private var isDragging = false
    @State private var dragStartScreenPoint: CGPoint?

    var body: some View {
        Color.clear
            .frame(width: isHorizontalEdge ? nil : 7, height: isHorizontalEdge ? 7 : nil)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    (isHorizontalEdge ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
                } else if !isDragging {
                    NSCursor.pop()
                }
            }
            .onTapGesture(count: 2) {
                onDoubleClick?()
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: coordinateSpace)
                    .onChanged { _ in
                        let current = NSEvent.mouseLocation
                        if !isDragging {
                            isDragging = true
                            dragStartScreenPoint = current
                            onDragStart()
                        }
                        let start = dragStartScreenPoint ?? current
                        onDragChanged(WidgetResize.screenTranslation(from: start, to: current))
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragStartScreenPoint = nil
                        NSCursor.arrow.set()
                        onDragEnded()
                    }
            )
    }
}

// MARK: - Live Frame Driver (isolates 120Hz drag updates to the single widget being resized)

private struct LiveResizeDriver<Content: View>: View {
    let baseBox: WidgetBox
    let isResizingThis: Bool
    let isPeek: Bool
    @ObservedObject var drag: ResizeDragState
    @ViewBuilder let content: (CGSize, Bool) -> Content

    var body: some View {
        let active = isResizingThis && !drag.fromChip
        let size = active && drag.liveSize.width > 1 ? drag.liveSize : baseBox.cgSize
        let collapsing = active && !isPeek && drag.collapsesToChip
        content(size, collapsing)
    }
}

// MARK: - Unified Freeform Widget Card (Desktop Shelf & Click-to-Peek)

/// Draws one freeform-resizable module card with zero-void height clamping, container-responsive blocks,
/// quiet hover utility pill (with drag-to-stack grip), and corner + edge resize handles.
struct WidgetCardView: View, Equatable {
    let slot: Slot
    let box: WidgetBox
    let node: ViewNode?
    let isLoading: Bool
    let failure: String?
    let theme: Theme
    let anchor: BarAnchor
    let isPeek: Bool
    let isSelected: Bool
    let isResizingThis: Bool
    let isDraggingThis: Bool
    var isTemporarilyExpanded: Bool = false
    var cornerOverride: ResizeCorner? = nil
    var adaptiveSurface: AdaptiveSurface? = nil
    let columnCount: Int
    let stackCount: Int
    let model: BarModel

    @State private var isHovered = false
    @State private var isGripDragging = false
    @State private var renderedSize: CGSize = .zero
    @State private var sensedLuma: Double?
    @State private var sensedTone: BackdropTone?
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.isStagedBackdrop) private var isStagedBackdrop

    nonisolated static func == (lhs: WidgetCardView, rhs: WidgetCardView) -> Bool {
        MainActor.assumeIsolated {
            lhs.model === rhs.model
                && lhs.slot == rhs.slot
                && lhs.box == rhs.box
                && lhs.node == rhs.node
                && lhs.isLoading == rhs.isLoading
                && lhs.failure == rhs.failure
                && lhs.theme == rhs.theme
                && lhs.anchor == rhs.anchor
                && lhs.isPeek == rhs.isPeek
                && lhs.isSelected == rhs.isSelected
                && lhs.isResizingThis == rhs.isResizingThis
                && lhs.isDraggingThis == rhs.isDraggingThis
                && lhs.isTemporarilyExpanded == rhs.isTemporarilyExpanded
                && lhs.cornerOverride == rhs.cornerOverride
                && lhs.adaptiveSurface == rhs.adaptiveSurface
                && lhs.columnCount == rhs.columnCount
                && lhs.stackCount == rhs.stackCount
        }
    }

    private var material: SurfaceMaterial {
        SurfaceMaterial(panel: theme.panelMaterial)
    }

    private var corner: ResizeCorner {
        cornerOverride ?? WidgetResize.corner(for: anchor)
    }

    private var handleAlignment: Alignment {
        corner == .bottomLeft ? .bottomLeading : .bottomTrailing
    }

    private var pillAlignment: Alignment {
        corner == .bottomLeft ? .topTrailing : .topLeading
    }

    private var sideEdgeAlignment: Alignment {
        corner == .bottomLeft ? .leading : .trailing
    }

    private var effectiveAdaptiveSurface: AdaptiveSurface? {
        guard material == .adaptive else { return nil }
        if isStagedBackdrop { return adaptiveSurface }
        if let sensedLuma {
            return AdaptiveBackdrop.surface(
                forLuma: sensedLuma,
                hueSample: adaptiveSurface,
                previous: sensedTone.map { AdaptiveSurface.neutral(for: $0) }
            )
        }
        return adaptiveSurface
    }

    private func makeContext(bounds: CGSize?) -> RenderContext {
        var context = RenderContext(
            theme: theme,
            surface: .panel,
            material: material,
            moduleID: slot.id,
            manifest: model.manifestFor(slot.id),
            widgetBounds: bounds,
            adaptiveSurface: effectiveAdaptiveSurface
        )
        let model = model
        context.panelFocus = model.panelFocus
        context.perform = { action, payload in model.onAction(slot.id, action, payload) }
        context.performForResult = { action, payload in await model.onAppAction(slot.id, action, payload) }
        return context
    }

    var body: some View {
        LiveResizeDriver(baseBox: box, isResizingThis: isResizingThis, isPeek: isPeek, drag: model.resizeDrag) { activeSize, collapsing in
            cardBody(activeSize: activeSize, collapsing: collapsing)
        }
    }

    private func cardBody(activeSize: CGSize, collapsing: Bool) -> some View {
        let context = makeContext(bounds: activeSize)
        let pad = CGFloat(context.metrics.widgetPadding)
        let minH = context.metrics.minWidgetSize.height
        let hasUnbounded = (node?.hasUnboundedFlex ?? false) || (node == nil)
        let idleFade: Double = (!isPeek && !isHovered && !isTemporarilyExpanded && theme.idleMaterial == "halo") ? max(theme.idleOpacity, 0.90) : 1.0

        return ZeroVoidCardLayout(
            requestedWidth: max(activeSize.width, 100),
            requestedHeight: max(activeSize.height, minH),
            minHeight: minH,
            hasUnboundedFlex: hasUnbounded,
            padding: pad
        ) {
            liveContent(context: context, innerWidth: max(activeSize.width - pad * 2, 40), pad: pad, hasUnbounded: hasUnbounded)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        .clipped()
        .modifier(SurfaceBackground(context: context, material: material, shape: context.widgetShape, isInteractive: false))
        .clipShape(context.widgetShape)
        .background {
            if material == .adaptive, !isStagedBackdrop {
                BackdropLumaSensor { luma in
                    let nextTone = AdaptiveBackdrop.resolveLumaTone(luma: luma, previous: sensedTone)
                    if sensedTone != nextTone || sensedLuma == nil {
                        sensedTone = nextTone
                        sensedLuma = luma
                    }
                }
                .clipShape(context.widgetShape)
            }
        }
        .contentShape(context.widgetShape)
        .onTapGesture {
            guard !isPeek, !isResizingThis, !isDraggingThis, !isTemporarilyExpanded,
                  slot.supportsResize, !NSEvent.modifierFlags.contains(.command)
            else { return }
            model.onWidgetClick(slot.id)
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { renderedSize = $0 }
        .overlay {
            context.widgetShape.stroke(
                collapsing ? Color.orange.opacity(0.75) : context.primary.opacity(isHovered || isResizingThis || isTemporarilyExpanded ? 0.18 : 0.08),
                lineWidth: collapsing ? 1.5 : 0.75
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
        // Bottom edge handle (height-only)
        .overlay(alignment: .bottom) {
            if slot.supportsResize {
                ResizeEdgeHandle(
                    isHorizontalEdge: true,
                    coordinateSpace: isPeek ? .global : .named(barSpace),
                    onDragStart: { beginResize(.bottom, fallbackSize: activeSize) },
                    onDragChanged: { model.updateResizing(translation: $0) },
                    onDragEnded: { model.endResizing() },
                    onDoubleClick: { model.fitWidgetHeightToContent(slot.id, isPeek: isPeek) }
                )
                .padding(.horizontal, 24)
            }
        }
        // Inward side edge handle (width-only)
        .overlay(alignment: sideEdgeAlignment) {
            if slot.supportsResize {
                ResizeEdgeHandle(
                    isHorizontalEdge: false,
                    coordinateSpace: isPeek ? .global : .named(barSpace),
                    onDragStart: { beginResize(.side(corner), fallbackSize: activeSize) },
                    onDragChanged: { model.updateResizing(translation: $0) },
                    onDragEnded: { model.endResizing() }
                )
                .padding(.vertical, 24)
            }
        }
        // Corner 2D resize arc handle
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
                    onDragStart: { beginResize(.corner(corner), fallbackSize: activeSize) },
                    onDragChanged: { model.updateResizing(translation: $0) },
                    onDragEnded: { model.endResizing() },
                    onDoubleClick: { model.fitWidgetHeightToContent(slot.id, isPeek: isPeek) }
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
        .opacity(isDraggingThis ? 0.28 : (collapsing ? 0.62 : idleFade))
        .scaleEffect(collapsing ? 0.92 : (isDraggingThis ? 0.96 : 1.0))
        .animation(theme.motion == "full" ? .spring(response: 0.22, dampingFraction: 0.82) : nil, value: collapsing)
        .animation(theme.motion == "full" ? .easeOut(duration: 0.16) : nil, value: isHovered)
        .animation(theme.motion == "full" ? .easeInOut(duration: 0.25) : nil, value: effectiveAdaptiveSurface)
        .environment(\.colorScheme, context.colorScheme ?? systemScheme)
        .onHover { isHovered = $0 }
        .contextMenu { widgetContextMenu }
    }

    private func beginResize(_ handle: ResizeHandle, fallbackSize: CGSize) {
        let measured = renderedSize.width > 1 && renderedSize.height > 1 ? renderedSize : fallbackSize
        let startRect: CGRect = if isPeek {
            CGRect(origin: .zero, size: measured)
        } else {
            model.slotFrames[slot.id] ?? CGRect(origin: .zero, size: measured)
        }
        model.beginResizing(slot.id, fromChip: false, handle: handle, startRect: startRect, isPeek: isPeek)
    }

    @ViewBuilder
    private func liveContent(context: RenderContext, innerWidth: CGFloat, pad: CGFloat, hasUnbounded: Bool) -> some View {
        let gap = context.isCompactWidget ? context.metrics.unit * 1.75 : context.metrics.unit * 2.25
        Group {
            if let node {
                let children = (node.component == .column && node.props.isEmpty) ? node.children : [node]
                AdaptiveStackLayout(spacing: gap, alignment: .leading) {
                    ForEach(Array(children.enumerated()), id: \.offset) { child in
                        NodeView(node: child.element, context: context)
                            .clipped()
                            .layoutValue(key: BlockPriorityKey.self, value: child.element.layoutPriority)
                            .layoutValue(key: BlockFlexKey.self, value: child.element.layoutFlex)
                    }
                }
                .background {
                    // Measure true finite natural height only while interactive (hovered, resizing, or peek)
                    // so idle desktop widgets do not duplicate their entire NodeView subtree on every update.
                    if !hasUnbounded {
                        if isHovered || isResizingThis || isPeek {
                            AdaptiveStackLayout(spacing: gap, alignment: .leading) {
                                ForEach(Array(children.enumerated()), id: \.offset) { child in
                                    NodeView(node: child.element, context: context)
                                        .layoutValue(key: BlockPriorityKey.self, value: child.element.layoutPriority)
                                        .layoutValue(key: BlockFlexKey.self, value: child.element.layoutFlex)
                                }
                            }
                            .frame(width: innerWidth)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .allowsHitTesting(false)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                                model.reportWidgetMaxContentHeight(ceil(h + pad * 2), of: slot.id)
                            }
                        }
                    } else {
                        Color.clear.onAppear { model.reportWidgetMaxContentHeight(nil, of: slot.id) }
                    }
                }
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
    }

    @ViewBuilder
    private func hoverUtilityPill(context: RenderContext) -> some View {
        let showPill = isHovered && !isResizingThis && !isDraggingThis
        HStack(spacing: 3) {
            if !isPeek {
                // Dedicated drag grip to reorder or stack widgets vertically/horizontally on the shelf.
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(context.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
                    .onHover { hovering in
                        if hovering { NSCursor.openHand.push() } else if !isGripDragging { NSCursor.pop() }
                    }
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 3, coordinateSpace: .named(barSpace))
                            .onChanged { value in
                                if !isGripDragging {
                                    isGripDragging = true
                                    model.beginDraggingWidget(slot.id, grabbedAt: value.startLocation)
                                }
                                model.updateDraggingWidget(to: value.location)
                            }
                            .onEnded { _ in
                                isGripDragging = false
                                model.endDraggingWidget()
                            }
                    )
                    .help("Drag to reorder or stack (or ⌘-drag card)")
            }
            if slot.hasConfigure {
                pillButton("slider.horizontal.3", "Configure \(slot.title) in Lintel", context: context) {
                    if isPeek { model.onPanelCommand("configure") } else { model.onWidgetCommand(slot.id, "configure") }
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
            pillButton("sparkles", "Open in Lintel", context: context) {
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
        if model.maxContentHeight(of: slot.id) != nil {
            Button("Fit Height to Content") {
                model.fitWidgetHeightToContent(slot.id, isPeek: isPeek)
            }
        }
        if !isPeek {
            if columnCount > 1 || stackCount > 1 {
                Menu("Placement & Stacking") {
                    if stackCount > 1 {
                        Button("Move Up in Stack") { model.onWidgetCommand(slot.id, "stack-up") }
                        Button("Move Down in Stack") { model.onWidgetCommand(slot.id, "stack-down") }
                        Button("Move to Own Column") { model.onWidgetCommand(slot.id, "unstack") }
                        Divider()
                    }
                    if columnCount > 1 {
                        Button("Stack with Adjacent Column") { model.onWidgetCommand(slot.id, "stack-next") }
                        Button("Stack with Previous Column") { model.onWidgetCommand(slot.id, "stack-prev") }
                    }
                }
            }
        }
        if slot.hasConfigure {
            Button("Configure \(slot.title)…") {
                if isPeek { model.onPanelCommand("configure") } else { model.onWidgetCommand(slot.id, "configure") }
            }
        }
        Divider()
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

// MARK: - Stackable Column Shelf SwiftUI Layout

struct ShelfColumnKey: LayoutValueKey {
    static let defaultValue = 0
}

struct ShelfWidgetIDKey: LayoutValueKey {
    static let defaultValue = ""
}

struct WidgetShelfLayout: Layout {
    let shelf: WidgetShelf
    let columnCount: Int

    private func placed(_ subviews: Subviews) -> (result: WidgetShelf.Placed, keys: [String]) {
        let count = max(columnCount, 1)
        var columns = Array(repeating: [(key: String, size: CGSize)](), count: count)
        var keys: [String] = []
        for index in subviews.indices {
            let id = subviews[index][ShelfWidgetIDKey.self]
            let key = id.isEmpty ? "w-\(index)" : id
            keys.append(key)
            let col = min(max(subviews[index][ShelfColumnKey.self], 0), count - 1)
            let measured = subviews[index].sizeThatFits(.unspecified)
            columns[col].append((key: key, size: measured))
        }
        return (shelf.place(columns), keys)
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

// MARK: - Live Freeform Resize Overlay (chip-to-widget preview + dimension & snap pill)

struct ResizeOverlayView: View {
    @ObservedObject var drag: ResizeDragState
    let model: BarModel

    var body: some View {
        if let id = drag.activeSlotID, !drag.isPeek {
            let metrics = Metrics(model.theme)
            let accent = RenderContext.color(hex: model.theme.accentColor)
            let liveSize = drag.liveSize
            let start = drag.startRect
            let anchorX: CGFloat = drag.corner == .bottomLeft ? start.maxX : start.minX
            let liveOrigin = CGPoint(
                x: drag.corner == .bottomLeft ? anchorX - liveSize.width : anchorX,
                y: start.minY
            )
            let cornerR = drag.collapsesToChip ? 14 : CGFloat(metrics.widgetCornerRadius)
            let pillTint: Color = drag.collapsesToChip ? .orange : accent

            ZStack(alignment: .topLeading) {
                if drag.fromChip {
                    RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                        .fill(pillTint.opacity(0.11))
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                                .strokeBorder(pillTint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: drag.collapsesToChip ? [4, 4] : []))
                        }
                        .frame(width: max(liveSize.width, 40), height: max(liveSize.height, 26))
                        .offset(x: liveOrigin.x, y: liveOrigin.y)
                }

                // Live readout pill showing exact dimensions, zero-void ceiling, or collapse state
                HStack(spacing: 5) {
                    if drag.collapsesToChip {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("Collapse to chip")
                            .font(.system(size: 11, weight: .semibold))
                    } else {
                        Text("\(Int(drag.committedSize.width)) × \(Int(drag.committedSize.height))")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        if drag.hitContentCeiling {
                            Text("· Fit")
                                .font(.system(size: 10, weight: .medium))
                                .opacity(0.85)
                        } else if drag.didSnapWidth || drag.didSnapHeight {
                            Image(systemName: "magnet")
                                .font(.system(size: 9.5, weight: .bold))
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(pillTint.gradient, in: Capsule())
                .shadow(color: pillTint.opacity(0.35), radius: 8, y: 3)
                .offset(
                    x: max(4, drag.corner == .bottomLeft ? liveOrigin.x + 6 : liveOrigin.x + liveSize.width - 96),
                    y: liveOrigin.y + liveSize.height + 6
                )
            }
            .allowsHitTesting(false)
            .id(id)
        }
    }
}

// MARK: - Live Widget Shelf Drag & Stack Drop Indicator Overlay

struct WidgetDragOverlayView: View {
    @ObservedObject var drag: WidgetDragState
    let model: BarModel

    var body: some View {
        if let id = drag.activeSlotID {
            let accent = RenderContext.color(hex: model.theme.accentColor)
            let metrics = Metrics(model.theme)
            let ghostOrigin = CGPoint(
                x: drag.pointer.x - drag.grabOffset.width,
                y: drag.pointer.y - drag.grabOffset.height
            )

            ZStack(alignment: .topLeading) {
                if let drop = drag.drop {
                    dropIndicator(for: drop, moving: id, accent: accent, metrics: metrics)
                }

                // Floating translucent drag preview following the pointer
                RoundedRectangle(cornerRadius: CGFloat(metrics.widgetCornerRadius), style: .continuous)
                    .fill(accent.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: CGFloat(metrics.widgetCornerRadius), style: .continuous)
                            .strokeBorder(accent.opacity(0.8), lineWidth: 1.5)
                    }
                    .overlay {
                        if let slot = model.slot(id) {
                            HStack(spacing: 6) {
                                Image(systemName: slot.icon)
                                Text(slot.title)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(accent.opacity(0.9), in: Capsule())
                        }
                    }
                    .frame(width: drag.cardSize.width, height: drag.cardSize.height)
                    .scaleEffect(0.96)
                    .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
                    .offset(x: ghostOrigin.x, y: ghostOrigin.y)
            }
            .allowsHitTesting(false)
            .id(id)
        }
    }

    @ViewBuilder
    private func dropIndicator(for drop: WidgetShelfDrop, moving: String, accent: Color, metrics: Metrics) -> some View {
        let remainingCols: [[CGRect]] = model.visibleWidgetColumns.compactMap { col in
            let rects = col.filter { $0.slot.id != moving }.compactMap { model.slotFrames[$0.slot.id] }
            return rects.isEmpty ? nil : rects
        }
        let gap = metrics.widgetGap

        switch drop {
        case .collapseToChip:
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.to.line")
                    .font(.system(size: 10, weight: .bold))
                Text("Drop to collapse to chip")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.orange.gradient, in: Capsule())
            .shadow(color: .orange.opacity(0.4), radius: 8, y: 2)
            .offset(x: max(12, drag.pointer.x - 80), y: max(6, model.shelfOriginInBarSpace.y - 26))

        case .stack(let colIndex, let rowIndex):
            if remainingCols.indices.contains(colIndex) {
                let col = remainingCols[colIndex]
                let colBounds = col.reduce(CGRect.null) { $0.union($1) }
                let barY: CGFloat = if rowIndex <= 0 {
                    col.first!.minY - 3
                } else if rowIndex >= col.count {
                    col.last!.maxY + gap / 2
                } else {
                    (col[rowIndex - 1].maxY + col[rowIndex].minY) / 2
                }
                Capsule()
                    .fill(accent)
                    .shadow(color: accent.opacity(0.6), radius: 6)
                    .frame(width: max(colBounds.width, 80), height: 4)
                    .offset(x: colBounds.minX, y: barY - 2)
            }

        case .newColumn(let colIndex):
            if !remainingCols.isEmpty {
                let colBounds = remainingCols.map { $0.reduce(CGRect.null) { $0.union($1) } }
                let shelfBounds = colBounds.reduce(CGRect.null) { $0.union($1) }
                let barX: CGFloat = {
                    if colIndex <= 0 {
                        return model.settings.anchor == .right ? shelfBounds.maxX + 4 : shelfBounds.minX - 8
                    } else if colIndex >= colBounds.count {
                        return model.settings.anchor == .right ? shelfBounds.minX - 8 : shelfBounds.maxX + 4
                    } else {
                        let a = colBounds[colIndex - 1]
                        let b = colBounds[colIndex]
                        return (min(a.maxX, b.maxX) + max(a.minX, b.minX)) / 2 - 2
                    }
                }()
                Capsule()
                    .fill(accent)
                    .shadow(color: accent.opacity(0.6), radius: 6)
                    .frame(width: 4, height: max(shelfBounds.height, 100))
                    .offset(x: barX, y: shelfBounds.minY)
            }
        }
    }
}
