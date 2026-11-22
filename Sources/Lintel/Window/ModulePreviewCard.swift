import AppKit
import LintelCore
import SwiftUI

/// Live interactive preview of a module's idle bar chip and responsive expanded view,
/// with in-window placement (pinned / chip vs desktop widget) and live size adjustment.
struct ModulePreviewCard: View {
    let app: AppController
    let controller: MainWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var state: MainWindowState
    let listing: ModuleListing

    @State private var backdrop: Backdrop.Style = .photo
    @State private var liveDragSize: CGSize?
    @State private var dragStartSize: CGSize?
    @State private var measuredContentHeight: CGFloat?
    @State private var stageWidth: CGFloat = 560

    private var slot: Slot? { model.slot(listing.id) }
    private var metrics: Metrics { Metrics(model.theme) }
    private var isWidget: Bool { model.layout.isWidget(listing.id) }
    private var isPinned: Bool { model.layout.isPinned(listing.id, default: slot?.isPinned ?? false) }
    private var defaultShape: WidgetShape { slot?.defaultShape ?? .card }

    private var savedBox: WidgetBox {
        ModulePreviewMetrics.resolvedBox(
            widgetBox: model.layout.widgetBox(of: listing.id),
            panelSize: model.layout.panelSize(of: listing.id),
            defaultShape: defaultShape,
            metrics: metrics
        )
    }

    private var activeBox: WidgetBox {
        if let liveDragSize { return WidgetBox(liveDragSize) }
        return savedBox
    }

    private var previewAdaptive: AdaptiveSurface? {
        guard model.theme.usesAdaptiveBackdrop else { return nil }
        return AdaptiveBackdrop.surface(for: backdrop.representativeSample(anchor: model.settings.anchor))
    }

    private var maxEditableSize: CGSize {
        metrics.maxWidgetSize(in: model.maxWidgetScreenSize)
    }

    var body: some View {
        WindowCard(
            title: "Live Preview",
            subtitle: "Idle bar look and responsive expanded view. Adjust placement and size right here.",
            headerAccessory: {
                HStack(spacing: 8) {
                    Picker("Backdrop", selection: $backdrop) {
                        Text("Wallpaper").tag(Backdrop.Style.photo)
                        Text("Light").tag(Backdrop.Style.light)
                        Text("Dark").tag(Backdrop.Style.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 196)

                    Button {
                        app.host.renderChip(listing.id)
                        if isWidget { app.host.renderWidget(listing.id) }
                        controller.refreshPreview(for: listing.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Re-render preview")
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                previewStage
                Divider()
                liveAdjustmentControls
            }
        }
        .onChange(of: listing.id) {
            liveDragSize = nil
            dragStartSize = nil
            measuredContentHeight = nil
        }
    }

    // MARK: - Desktop Backdrop Stage

    private var previewStage: some View {
        let box = activeBox
        let availableW = max(stageWidth - 36, 220)
        let scale = ModulePreviewMetrics.fitScale(box: box.cgSize, in: CGSize(width: availableW, height: 390))

        return ZStack {
            Backdrop(style: backdrop)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 18) {
                idleLookStrip
                expandedViewStrip(box: box, scale: scale)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 1)
        )
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { stageWidth = $0 }
        .environment(\.isStagedBackdrop, true)
    }

    // MARK: - Idle Look

    private var idleLookStrip: some View {
        let idleMaterial = SurfaceMaterial(idle: model.theme.idleMaterial)
        let activeMaterial = SurfaceMaterial(active: model.theme.activeMaterial)
        let showActiveAlongside = idleMaterial != activeMaterial || !isPinned
        let idleNote: String = if isWidget {
            "Shown as desktop widget while idle"
        } else if isPinned {
            "Pinned · visible while idle"
        } else if slot?.isRaised == true {
            "Attention active · visible while idle"
        } else {
            "Unpinned · shown on hover"
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                stageBadge("IDLE LOOK")
                Text(idleNote)
                    .font(.caption)
                    .foregroundStyle(stageLabelColor)
                Spacer()
            }

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    if showActiveAlongside {
                        Text("Idle")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(stageSecondaryLabelColor)
                    }
                    chipSample(material: idleMaterial, opacity: model.theme.idleOpacity)
                }

                if showActiveAlongside {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hover / Open")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(stageSecondaryLabelColor)
                        chipSample(material: activeMaterial, opacity: 1.0)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func chipSample(material: SurfaceMaterial, opacity: Double) -> some View {
        let context = RenderContext(
            theme: model.theme,
            surface: .chip,
            material: material,
            moduleID: listing.id,
            manifest: app.host.manifest(of: listing.id),
            adaptiveSurface: material == .adaptive ? previewAdaptive : nil
        )
        let hasCapsule = material.hasCapsule
        Group {
            if let chip = slot?.chip {
                NodeView(node: chip, context: context)
            } else {
                Image(systemName: listing.icon)
                    .font(.system(size: context.metrics.fontSize(role: nil), weight: context.weight(nil)))
                    .foregroundStyle(context.secondary)
            }
        }
        .frame(minHeight: context.metrics.fontSize(role: nil) * 1.3)
        .padding(.horizontal, hasCapsule ? context.metrics.chipPaddingHorizontal : 4)
        .padding(.vertical, hasCapsule ? context.metrics.chipPaddingVertical : 2)
        .modifier(SurfaceBackground(context: context, material: material, shape: context.chipShape, isInteractive: false))
        .environment(\.colorScheme, context.colorScheme ?? stageColorScheme)
        .opacity(opacity)
    }

    // MARK: - Expanded View

    private func expandedViewStrip(box: WidgetBox, scale: CGFloat) -> some View {
        let panelMaterial = SurfaceMaterial(panel: model.theme.panelMaterial)
        let node = isWidget ? (slot?.widgetNode ?? state.previewPanelNode) : state.previewPanelNode
        let pad = CGFloat(metrics.widgetPadding)
        let minH = metrics.minWidgetSize.height
        let hasUnbounded = (node?.hasUnboundedFlex ?? false) || (node == nil)
        let displayW = max(CGFloat(box.width), 100)
        let displayH = max(CGFloat(box.height), minH)
        let scaledW = displayW * scale
        let scaledH = displayH * scale

        let context = makeExpandedContext(bounds: CGSize(width: displayW, height: displayH), material: panelMaterial)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                stageBadge(isWidget ? "DESKTOP WIDGET" : "EXPANDED VIEW")
                Text("\(Int(displayW.rounded())) × \(Int(displayH.rounded())) pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(stageLabelColor)
                if scale < 0.99 {
                    Text("· scaled \(Int((scale * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(stageSecondaryLabelColor)
                }
                Spacer()
                Text("Drag corner to resize")
                    .font(.caption2)
                    .foregroundStyle(stageSecondaryLabelColor)
            }

            if let node {
                let children = (node.component == .column && node.props.isEmpty) ? node.children : [node]
                let gap = context.isCompactWidget ? context.metrics.unit * 1.75 : context.metrics.unit * 2.25

                ZStack(alignment: .topLeading) {
                    ZeroVoidCardLayout(
                        requestedWidth: displayW,
                        requestedHeight: displayH,
                        minHeight: minH,
                        hasUnboundedFlex: hasUnbounded,
                        padding: pad
                    ) {
                        AdaptiveStackLayout(spacing: gap, alignment: .leading) {
                            ForEach(Array(children.enumerated()), id: \.offset) { child in
                                NodeView(node: child.element, context: context)
                                    .clipped()
                                    .layoutValue(key: BlockPriorityKey.self, value: child.element.layoutPriority)
                                    .layoutValue(key: BlockFlexKey.self, value: child.element.layoutFlex)
                            }
                        }
                        .background {
                            if !hasUnbounded {
                                AdaptiveStackLayout(spacing: gap, alignment: .leading) {
                                    ForEach(Array(children.enumerated()), id: \.offset) { child in
                                        NodeView(node: child.element, context: context)
                                            .layoutValue(key: BlockPriorityKey.self, value: child.element.layoutPriority)
                                            .layoutValue(key: BlockFlexKey.self, value: child.element.layoutFlex)
                                    }
                                }
                                .frame(width: max(displayW - pad * 2, 40))
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .allowsHitTesting(false)
                                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                                    let total = ceil(h + pad * 2)
                                    if total.isFinite, total > 0 { measuredContentHeight = total }
                                }
                            } else {
                                Color.clear.onAppear { measuredContentHeight = nil }
                            }
                        }
                    }
                    .clipped()
                    .modifier(SurfaceBackground(context: context, material: panelMaterial, shape: context.widgetShape, isInteractive: false))
                    .clipShape(context.widgetShape)
                    .overlay {
                        context.widgetShape.stroke(context.primary.opacity(liveDragSize != nil ? 0.35 : 0.14), lineWidth: liveDragSize != nil ? 1.25 : 0.75)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(panelMaterial == .solid ? 0.28 : 0.14), radius: 12, y: 5)
                    .overlay(alignment: .bottomTrailing) {
                        ResizeArcHandle(
                            corner: .bottomRight,
                            cornerRadius: CGFloat(context.metrics.widgetCornerRadius),
                            accent: context.accent,
                            primary: context.primary,
                            isCompactChip: false,
                            isVisible: true,
                            coordinateSpace: .global,
                            onDragStart: {
                                dragStartSize = savedBox.cgSize
                                liveDragSize = savedBox.cgSize
                            },
                            onDragChanged: { translation in
                                let start = dragStartSize ?? savedBox.cgSize
                                let adjusted = CGSize(width: translation.width / scale, height: translation.height / scale)
                                let resolved = WidgetResize.resolve(
                                    fromChip: false,
                                    startSize: start,
                                    translation: adjusted,
                                    handle: .corner(.bottomRight),
                                    metrics: metrics,
                                    maxSize: maxEditableSize,
                                    maxContentHeight: measuredContentHeight,
                                    snapWidths: [],
                                    snapHeights: [],
                                    allowsCollapse: false
                                )
                                liveDragSize = resolved.committedSize
                            },
                            onDragEnded: {
                                if let committed = liveDragSize {
                                    commitSize(WidgetBox(committed))
                                }
                                dragStartSize = nil
                                liveDragSize = nil
                            },
                            onDoubleClick: fitHeightToContent
                        )
                    }
                    .environment(\.colorScheme, context.colorScheme ?? stageColorScheme)
                    .scaleEffect(scale, anchor: .topLeading)
                }
                .frame(width: scaledW, height: scaledH, alignment: .topLeading)
            } else if state.previewIsLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Rendering expanded view…")
                        .font(.caption)
                        .foregroundStyle(stageLabelColor)
                }
                .padding(.vertical, 18)
            } else {
                Text("This module does not provide an expanded view.")
                    .font(.caption)
                    .foregroundStyle(stageSecondaryLabelColor)
                    .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Live Adjustment Controls

    private var liveAdjustmentControls: some View {
        let minSize = metrics.minWidgetSize
        let maxSize = maxEditableSize
        let currentBox = activeBox
        let widthRange = Double(minSize.width)...Double(max(maxSize.width, minSize.width + 100))
        let heightRange = Double(minSize.height)...Double(max(maxSize.height, minSize.height + 100))

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if isWidget {
                    Label("Always visible on desktop while idle", systemImage: "pin.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Text("Always show while idle")
                            .font(.callout)
                        Toggle("", isOn: Binding(
                            get: { isPinned },
                            set: { next in
                                var layout = model.layout
                                layout.pinned[listing.id] = next
                                app.host.update(layout)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }

                Spacer(minLength: 12)

                if slot?.hasWidget == true {
                    Picker("Display", selection: Binding(
                        get: { isWidget },
                        set: { asWidget in
                            if asWidget {
                                app.host.setWidget(listing.id, to: savedBox)
                            } else {
                                let remembered = savedBox
                                app.host.setWidget(listing.id, to: nil)
                                var layout = model.layout
                                layout.setPanelSize(remembered, for: listing.id)
                                app.host.update(layout)
                            }
                            controller.refreshPreview(for: listing.id)
                        }
                    )) {
                        Text("Bar Chip").tag(false)
                        Text("Desktop Widget").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 210)
                }
            }

            if slot?.hasWidget == true {
                Divider()

                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Text("Width")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { min(max(currentBox.width, widthRange.lowerBound), widthRange.upperBound) },
                                set: { next in
                                    commitSize(WidgetBox(width: next.rounded(), height: currentBox.height))
                                }
                            ),
                            in: widthRange
                        )
                        Text("\(Int(currentBox.width.rounded())) pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }

                    HStack(spacing: 8) {
                        Text("Height")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { min(max(currentBox.height, heightRange.lowerBound), heightRange.upperBound) },
                                set: { next in
                                    commitSize(WidgetBox(width: currentBox.width, height: next.rounded()))
                                }
                            ),
                            in: heightRange
                        )
                        Text("\(Int(currentBox.height.rounded())) pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }

                HStack(spacing: 6) {
                    Text("Presets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach([WidgetShape.compact, .card, .wide, .sidebar], id: \.self) { shape in
                        Button(shape.rawValue.capitalized) {
                            commitSize(metrics.defaultWidgetBox(for: shape))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                    if measuredContentHeight != nil {
                        Button("Fit Height", action: fitHeightToContent)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button("Reset Size") {
                        commitSize(metrics.defaultWidgetBox(for: defaultShape))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Helpers

    private var stageColorScheme: ColorScheme {
        backdrop == .light ? .light : .dark
    }

    private var stageLabelColor: Color {
        backdrop == .light ? .black.opacity(0.72) : .white.opacity(0.88)
    }

    private var stageSecondaryLabelColor: Color {
        backdrop == .light ? .black.opacity(0.5) : .white.opacity(0.65)
    }

    private func stageBadge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(backdrop == .light ? .black.opacity(0.75) : .white.opacity(0.92))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(backdrop == .light ? Color.black.opacity(0.08) : Color.black.opacity(0.28), in: Capsule())
    }

    private func commitSize(_ box: WidgetBox) {
        let clamped = WidgetResize.clampedBox(box, metrics: metrics, maxSize: maxEditableSize)
        if isWidget {
            app.host.setWidget(listing.id, to: clamped)
        } else {
            app.host.setPeekBox(listing.id, to: clamped)
        }
    }

    private func fitHeightToContent() {
        guard let contentH = measuredContentHeight else { return }
        let clampedH = max(contentH.rounded(), metrics.minWidgetSize.height)
        commitSize(WidgetBox(width: savedBox.width, height: Double(clampedH)))
    }

    private func makeExpandedContext(bounds: CGSize, material: SurfaceMaterial) -> RenderContext {
        var ctx = RenderContext(
            theme: model.theme,
            surface: .panel,
            material: material,
            moduleID: listing.id,
            manifest: app.host.manifest(of: listing.id),
            widgetBounds: bounds,
            adaptiveSurface: material == .adaptive ? previewAdaptive : nil
        )
        ctx.perform = { action, payload in
            Task {
                await app.host.perform(listing.id, action: action, payload: payload)
                controller.refreshModule(listing.id)
            }
        }
        ctx.performForResult = { action, payload in
            let res = await app.host.perform(listing.id, action: action, payload: payload)
            controller.refreshPreview(for: listing.id)
            return res
        }
        return ctx
    }
}
