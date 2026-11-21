import CoreGraphics
import Foundation
import JavaScriptCore
import Testing
@testable import LintelCore

private func evaluate(_ script: String) -> JSValue {
    let context = JSContext()!
    context.evaluateScript("function __call() {} function __post() {}")
    context.evaluateScript(ModulePrelude.source)
    return context.evaluateScript(script)
}

@Suite struct FreeformWidgetGeometry {
    let metrics = Metrics(Theme.preset("glass")!)

    @Test func boundsScaleWithThemeFontAndDensity() {
        let compact = Metrics(Theme.preset("glass")!.applying(["density": "compact"]))
        let roomy = Metrics(Theme.preset("glass")!.applying(["density": "roomy"]))
        let largeFont = Metrics(Theme.preset("glass")!.applying(["fontSize": 20]))

        #expect(compact.minWidgetSize.width < metrics.minWidgetSize.width)
        #expect(roomy.minWidgetSize.width > metrics.minWidgetSize.width)
        #expect(largeFont.minWidgetSize.width > metrics.minWidgetSize.width)
        #expect(largeFont.defaultWidgetBox(for: .card).width > metrics.defaultWidgetBox(for: .card).width)
    }

    @Test func handleCornerAdaptsToBarAnchorAndSupportsCornerAndEdgeDrags() {
        #expect(WidgetResize.corner(for: .right) == .bottomLeft)
        #expect(WidgetResize.corner(for: .left) == .bottomRight)
        #expect(WidgetResize.corner(for: .center) == .bottomRight)

        let start = CGSize(width: 280, height: 220)
        // Right-anchored: pulling left (-40) widens, pulling down (+30) tallens.
        #expect(WidgetResize.proposedSize(from: start, translation: CGSize(width: -40, height: 30), handle: .corner(.bottomLeft)) == CGSize(width: 320, height: 250))
        // Bottom edge only changes height.
        #expect(WidgetResize.proposedSize(from: start, translation: CGSize(width: -90, height: 35), handle: .bottom) == CGSize(width: 280, height: 255))
        // Side edge only changes width.
        #expect(WidgetResize.proposedSize(from: start, translation: CGSize(width: -45, height: 80), handle: .side(.bottomLeft)) == CGSize(width: 325, height: 220))
        // Left-anchored side edge pulls rightward to widen.
        #expect(WidgetResize.proposedSize(from: start, translation: CGSize(width: 45, height: 80), handle: .side(.bottomRight)) == CGSize(width: 325, height: 220))
    }

    @Test func draggingTallerThanFiniteContentCeilingRubberBandsAndClampsToZeroVoid() {
        let start = CGSize(width: 300, height: 180)
        let result = WidgetResize.resolve(
            fromChip: false,
            startSize: start,
            translation: CGSize(width: 0, height: 240),
            handle: .bottom,
            metrics: metrics,
            maxSize: CGSize(width: 640, height: 640),
            maxContentHeight: 220,
            snapWidths: [],
            snapHeights: []
        )
        #expect(!result.collapsesToChip)
        #expect(result.hitContentCeiling)
        // Committed size never exceeds natural content height (no blank void!).
        #expect(result.committedSize.height == 220)
        // Live drag preview gives gentle rubber-band feedback past 220 without jumping wildly.
        #expect(result.liveSize.height > 220 && result.liveSize.height < 280)
    }

    @Test func draggingNearNeighborWidthOrHeightSnapsMagnetically() {
        let start = CGSize(width: 240, height: 200)
        let result = WidgetResize.resolve(
            fromChip: false,
            startSize: start,
            translation: CGSize(width: -56, height: 44), // proposed 296 x 244
            handle: .corner(.bottomLeft),
            metrics: metrics,
            maxSize: CGSize(width: 640, height: 640),
            maxContentHeight: nil,
            snapWidths: [300],
            snapHeights: [240]
        )
        #expect(result.didSnapWidth)
        #expect(result.didSnapHeight)
        #expect(result.committedSize == CGSize(width: 300, height: 240))
    }

    @Test func pullingChipOutwardPromotesToWidgetAndShrinkingWidgetCollapsesToChip() {
        let chip = CGSize(width: 72, height: 28)
        let tinyPull = WidgetResize.resolve(
            fromChip: true, startSize: chip, translation: CGSize(width: -12, height: 10),
            handle: .corner(.bottomLeft), metrics: metrics, maxSize: CGSize(width: 640, height: 640),
            maxContentHeight: nil, snapWidths: [], snapHeights: []
        )
        #expect(tinyPull.collapsesToChip)

        let realPull = WidgetResize.resolve(
            fromChip: true, startSize: chip, translation: CGSize(width: -210, height: 190),
            handle: .corner(.bottomLeft), metrics: metrics, maxSize: CGSize(width: 640, height: 640),
            maxContentHeight: nil, snapWidths: [], snapHeights: []
        )
        #expect(!realPull.collapsesToChip)
        #expect(realPull.committedSize.width >= metrics.minWidgetSize.width)
        #expect(realPull.committedSize.height >= metrics.minWidgetSize.height)

        let shrink = WidgetResize.resolve(
            fromChip: false, startSize: CGSize(width: 240, height: 200), translation: CGSize(width: 190, height: -170),
            handle: .corner(.bottomLeft), metrics: metrics, maxSize: CGSize(width: 640, height: 640),
            maxContentHeight: nil, snapWidths: [], snapHeights: []
        )
        #expect(shrink.collapsesToChip)
    }

    @Test func keyboardGrowAndShrinkStepCleanlyBetweenChipAndProgressiveBoxes() {
        let first = WidgetResize.step(from: nil, delta: 1, defaultShape: .card, metrics: metrics)
        #expect(first != nil)
        let bigger = WidgetResize.step(from: first, delta: 1, defaultShape: .card, metrics: metrics)
        #expect(bigger!.width > first!.width && bigger!.height > first!.height)
        let smaller = WidgetResize.step(from: first, delta: -1, defaultShape: .card, metrics: metrics)
        #expect(smaller != nil && smaller!.width < first!.width)
        let smallest = WidgetResize.step(from: smaller, delta: -1, defaultShape: .card, metrics: metrics)
        #expect(smallest != nil && smallest!.width < smaller!.width)
        // Stepping down past minimum collapses to chip (nil).
        let collapsed = WidgetResize.step(from: smallest, delta: -1, defaultShape: .card, metrics: metrics)
        #expect(collapsed == nil)
    }
}

@Suite struct WidgetShelfStackingAndDrops {
    let gap: CGFloat = 10

    @Test func stacksWidgetsVerticallyInColumnsAndPlacesColumnsSideBySide() {
        let shelf = WidgetShelf(gap: gap, anchor: .left)
        let placed = shelf.place([
            [("a", CGSize(width: 240, height: 180)), ("b", CGSize(width: 220, height: 120))],
            [("c", CGSize(width: 300, height: 260))],
        ])
        // Column 0 width = max(240, 220) = 240; height = 180 + 10 + 120 = 310
        // Column 1 starts at x = 250, width = 300, height = 260
        #expect(placed.frames["a"] == CGRect(x: 0, y: 0, width: 240, height: 180))
        #expect(placed.frames["b"] == CGRect(x: 0, y: 190, width: 220, height: 120))
        #expect(placed.frames["c"] == CGRect(x: 250, y: 0, width: 300, height: 260))
        #expect(placed.size == CGSize(width: 550, height: 310))
    }

    @Test func rightAnchoredShelfHugsRightEdgeAndAlignsStackedWidgetsRight() {
        let shelf = WidgetShelf(gap: gap, anchor: .right)
        let placed = shelf.place([
            [("a", CGSize(width: 240, height: 180)), ("b", CGSize(width: 200, height: 100))],
            [("c", CGSize(width: 300, height: 200))],
        ])
        // Total width = 300 + 10 + 240 = 550.
        // Column 0 hugs right edge [310..550]; b (width 200) right-aligns to x = 350.
        // Column 1 sits to its left [0..300].
        #expect(placed.size == CGSize(width: 550, height: 290))
        #expect(placed.frames["a"] == CGRect(x: 310, y: 0, width: 240, height: 180))
        #expect(placed.frames["b"] == CGRect(x: 350, y: 190, width: 200, height: 100))
        #expect(placed.frames["c"] == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func resolvesDropAboveBelowOrBesideWidgetsToStackOrCreateColumns() {
        let shelf = WidgetShelf(gap: gap, anchor: .right)
        let placed = shelf.place([
            [("a", CGSize(width: 240, height: 180))],
            [("b", CGSize(width: 240, height: 180))],
        ])
        let cols: [[WidgetShelfDrop.Entry]] = [
            [.init(key: "a", frame: placed.frames["a"]!)],
            [.init(key: "b", frame: placed.frames["b"]!)],
        ]

        // Dropping b on the bottom half of a stacks b below a in column 0.
        let stackBelow = WidgetShelfDrop.resolve(
            at: CGPoint(x: placed.frames["a"]!.midX, y: placed.frames["a"]!.maxY - 20),
            columns: cols, moving: "b", anchor: .right, collapseAboveY: -20
        )
        #expect(stackBelow == .stack(column: 0, index: 1))

        // Dropping b on the top half of a stacks b above a in column 0.
        let stackAbove = WidgetShelfDrop.resolve(
            at: CGPoint(x: placed.frames["a"]!.midX, y: placed.frames["a"]!.minY + 20),
            columns: cols, moving: "b", anchor: .right, collapseAboveY: -20
        )
        #expect(stackAbove == .stack(column: 0, index: 0))

        // Dropping b well to the right of a (right-anchored: column 0 is rightmost) opens column 0 on the right.
        let rightEdge = WidgetShelfDrop.resolve(
            at: CGPoint(x: placed.frames["a"]!.maxX + 24, y: 90),
            columns: cols, moving: "b", anchor: .right, collapseAboveY: -20
        )
        #expect(rightEdge == .newColumn(0))

        // Dropping above the shelf into the chip bar collapses back to chip.
        let collapse = WidgetShelfDrop.resolve(
            at: CGPoint(x: 200, y: -35),
            columns: cols, moving: "b", anchor: .right, collapseAboveY: -20
        )
        #expect(collapse == .collapseToChip)
    }

    @Test func barLayoutPersistsFreeformBoxesAndStackingColumns() throws {
        var layout = BarLayout(rows: [["system", "battery", "clock"]])
        layout.setWidget(WidgetBox(width: 240, height: 320), for: "system")
        layout.setWidget(WidgetBox(width: 240, height: 160), for: "battery")
        #expect(layout.widgetColumns == [["system"], ["battery"]])

        // Stack battery underneath system in column 0.
        layout.moveWidget("battery", to: .stack(column: 0, index: 1))
        #expect(layout.widgetColumns == [["system", "battery"]])

        // Unstack battery back into its own column on the left (column 1).
        layout.moveWidget("battery", to: .newColumn(1))
        #expect(layout.widgetColumns == [["system"], ["battery"]])

        // Collapsing back to chip removes from widgets & columns while preserving chip row.
        layout.setWidget(nil, for: "system")
        #expect(layout.widgetBox(of: "system") == nil)
        #expect(layout.widgetColumns == [["battery"]])

        let encoded = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(BarLayout.self, from: encoded)
        #expect(decoded == layout)
    }
}

@Suite struct ResponsiveDesignSystemAndAudit {
    @Test func preludeSupportsUnifiedChipWidgetAndConfigureContract() {
        let context = JSContext()!
        context.evaluateScript("function __call() {} function __post() {}")
        context.evaluateScript(ModulePrelude.source)
        context.evaluateScript("""
            defineModule({
              meta: { id: 'demo', defaultShape: 'sidebar' },
              chip() { return text('ok'); },
              widget() {
                return [
                  split([
                    column([stat('A', '1'), stat('B', '2')], { elastic: true }),
                    section('Details', [meter('Quota', 0.5), meter('Weekly', 0.3)], { elastic: true, priority: 'supporting' }),
                  ]),
                ];
              },
              configure() { return [toggle('Flag', true, 'flip')]; },
              actions: { flip() {} },
            });
            """)
        let desc = JSONValue.parseOrNull(context.evaluateScript("__describe()").toString()!)
        #expect(desc["hasChip"].bool == true)
        #expect(desc["hasWidget"].bool == true)
        #expect(desc["hasConfigure"].bool == true)

        var renderedWidget: String?
        var renderedConfig: String?
        let doneWidget: @convention(block) (JSValue, JSValue) -> Void = { val, _ in renderedWidget = val.toString() }
        let doneConfig: @convention(block) (JSValue, JSValue) -> Void = { val, _ in renderedConfig = val.toString() }
        context.objectForKeyedSubscript("__render").call(withArguments: ["widget", unsafeBitCast(doneWidget, to: AnyObject.self)])
        context.objectForKeyedSubscript("__render").call(withArguments: ["configure", unsafeBitCast(doneConfig, to: AnyObject.self)])

        let widgetNode = ViewNode.parse(json: renderedWidget ?? "").node
        #expect(widgetNode?.children.first?.component == .split)
        #expect(widgetNode?.children.first?.children.first?.bool("elastic") == true)
        #expect(widgetNode?.children.first?.children.last?.bool("elastic") == true)
        #expect(ViewNode.parse(json: renderedConfig ?? "").node?.children.first?.component == .toggle)
    }

    @Test func canonicalViewportMatrixCoversAllSixStressFormFactors() {
        let metrics = Metrics(Theme.preset("glass")!)
        let viewports = WidgetViewport.canonicalMatrix(for: metrics)
        #expect(viewports.map(\.id) == ["tiny", "ribbon", "sidebar", "compact", "balanced", "spacious"])
        let ribbon = viewports.first { $0.id == "ribbon" }!
        let sidebar = viewports.first { $0.id == "sidebar" }!
        #expect(ribbon.size.width > ribbon.size.height * 2.5)
        #expect(sidebar.size.height > sidebar.size.width * 1.5)
    }

    @Test func responsiveAuditFlagsAllDetailWidgetsAndOvercrowdedStaticRows() throws {
        let manifest = try ModuleManifest(["id": "test"])
        let metrics = Metrics(Theme.preset("glass")!)

        // A widget where every root block is marked detail leaves nothing guaranteed at tiny floor.
        let onlyDetail = ViewNode(.column, [:], [
            ViewNode(.section, ["title": "Extra", "priority": "detail"], [ViewNode(.note, ["value": "Only detail"])]),
        ])
        let detailProblems = ResponsiveAudit.check(onlyDetail, metrics: metrics)
        #expect(detailProblems.contains { $0.severity == .error && $0.message.contains("essential") })

        // A static row with 6 badges/texts will crush on a narrow 216pt sidebar.
        let wideRow = ViewNode(.column, [:], [
            ViewNode(.row, [:], (0..<6).map { ViewNode(.badge, ["value": .string("Item \($0)")]) }),
        ])
        let rowProblems = ResponsiveAudit.check(wideRow, metrics: metrics)
        #expect(rowProblems.contains { $0.severity == .warning && $0.message.contains("sidebar") })

        // A well-formed responsive tree with essential stat + supporting elastic section passes cleanly.
        let healthy = ViewNode(.column, [:], [
            ViewNode(.stat, ["label": "CPU", "value": "42%"]),
            ViewNode(.section, ["title": "Processes", "priority": "supporting", "elastic": true], [
                ViewNode(.list, [:], [ViewNode(.item, ["title": "Xcode", "value": "12%"])]),
            ]),
        ])
        let healthyProblems = DesignLint.checkWidget(healthy, manifest: manifest, actions: [], metrics: metrics, symbolExists: { _ in true })
        #expect(healthyProblems.filter { $0.severity == .error }.isEmpty)
    }
    @Test("AdaptiveOverflowFit selects exact footer slot without state and stays idempotent")
    func adaptiveOverflowFitStateless() {
        let rows: [CGFloat] = [32, 32, 32]

        // Unbounded natural pass fits every item and hides the footer.
        let unbounded = AdaptiveOverflowFit.fit(itemHeights: rows, spacing: 0, maxHeight: nil, showsFooter: true, footerHeight: 22)
        #expect(unbounded.fittedCount == 3)
        #expect(unbounded.hiddenCount == 0)
        #expect(unbounded.activeFooterSlot == nil)
        #expect(unbounded.totalHeight == 96)

        // Zero-height compressed floor keeps the first item plus the "+2 more" footer.
        let floor = AdaptiveOverflowFit.fit(itemHeights: rows, spacing: 0, maxHeight: 0, showsFooter: true, footerHeight: 22)
        #expect(floor.fittedCount == 1)
        #expect(floor.hiddenCount == 2)
        #expect(floor.activeFooterSlot == 1)
        #expect(floor.totalHeight == 54)

        // Constrained pass with leftover space snaps to 1 row + "+2 more" and stays idempotent on re-measure.
        let constrained = AdaptiveOverflowFit.fit(itemHeights: rows, spacing: 0, maxHeight: 78, showsFooter: true, footerHeight: 22)
        #expect(constrained.fittedCount == 1)
        #expect(constrained.hiddenCount == 2)
        #expect(constrained.activeFooterSlot == 1)
        #expect(constrained.totalHeight == 54)

        let remeasured = AdaptiveOverflowFit.fit(itemHeights: rows, spacing: 0, maxHeight: constrained.totalHeight, showsFooter: true, footerHeight: 22)
        #expect(remeasured == constrained)

        // Exactly enough height for 2 rows + "+1 more" selects slot 0.
        let twoRows = AdaptiveOverflowFit.fit(itemHeights: rows, spacing: 0, maxHeight: 86, showsFooter: true, footerHeight: 22)
        #expect(twoRows.fittedCount == 2)
        #expect(twoRows.hiddenCount == 1)
        #expect(twoRows.activeFooterSlot == 0)
        #expect(twoRows.totalHeight == 86)

        // With showsFooter disabled, no footer slot is ever active.
        let noFooter = AdaptiveOverflowFit.fit(itemHeights: rows, spacing: 0, maxHeight: 70, showsFooter: false, footerHeight: 22)
        #expect(noFooter.fittedCount == 2)
        #expect(noFooter.hiddenCount == 1)
        #expect(noFooter.activeFooterSlot == nil)
        #expect(noFooter.totalHeight == 64)
    }

    @Test("AdaptiveOverflowFit handles elastic spacing and capped footer labels")
    func adaptiveOverflowFitSpacingAndCaps() {
        let labels = AdaptiveOverflowFit.footerLabels(itemCount: 3)
        #expect(labels == ["+1 more", "+2 more"])
        #expect(AdaptiveOverflowFit.footerLabels(itemCount: 1).isEmpty)

        let hugeCount = AdaptiveOverflowFit.maxFooterSlots + 25
        let hugeLabels = AdaptiveOverflowFit.footerLabels(itemCount: hugeCount)
        #expect(hugeLabels.count == AdaptiveOverflowFit.maxFooterSlots)
        #expect(hugeLabels.first == "+1 more")
        #expect(hugeLabels.last == "+\(AdaptiveOverflowFit.maxFooterSlots)+ more")

        let hugeFit = AdaptiveOverflowFit.fit(
            itemHeights: Array(repeating: 30, count: hugeCount),
            spacing: 6,
            maxHeight: 60,
            showsFooter: true,
            footerHeight: 20
        )
        #expect(hugeFit.fittedCount == 1)
        #expect(hugeFit.hiddenCount == hugeCount - 1)
        #expect(hugeFit.activeFooterSlot == AdaptiveOverflowFit.maxFooterSlots - 1)
        #expect(hugeFit.totalHeight == 56)
    }

    @Test("AdaptiveOverflowFit stays idempotent across a 0.5pt height sweep")
    func adaptiveOverflowFitIdempotenceSweep() {
        let rows: [CGFloat] = [32.3, 31.7, 32.1, 29.8, 33.4]
        for spacing in [CGFloat(0), CGFloat(6)] {
            for step in 0...440 {
                let maxH = CGFloat(step) * 0.5
                let first = AdaptiveOverflowFit.fit(
                    itemHeights: rows,
                    spacing: spacing,
                    maxHeight: maxH,
                    showsFooter: true,
                    footerHeight: 22
                )
                let second = AdaptiveOverflowFit.fit(
                    itemHeights: rows,
                    spacing: spacing,
                    maxHeight: first.totalHeight,
                    showsFooter: true,
                    footerHeight: 22
                )
                #expect(second == first, "Non-idempotent at maxH=\(maxH), spacing=\(spacing)")
                let ceiled = AdaptiveOverflowFit.fit(
                    itemHeights: rows,
                    spacing: spacing,
                    maxHeight: ceil(first.totalHeight),
                    showsFooter: true,
                    footerHeight: 22
                )
                #expect(ceiled.fittedCount == first.fittedCount)
                #expect(ceiled.activeFooterSlot == first.activeFooterSlot)
            }
        }
    }

    @Test("ChartBlockFit decides legend and labels purely from bounds and stays idempotent")
    func chartBlockFitStatelessAndIdempotent() {
        // Flexible chart at tight floor collapses legend and labels to keep the canvas floor clean.
        let floor = ChartBlockFit.fit(
            hasLegend: true, legendHeight: 14,
            hasLabels: true, labelsHeight: 14,
            allowLabels: true,
            minCanvasHeight: 38, fixedCanvasHeight: nil,
            spacing: 4, maxHeight: 0
        )
        #expect(!floor.showLegend)
        #expect(!floor.showLabels)
        #expect(floor.canvasHeight == 38)
        #expect(floor.totalHeight == 38)

        // Medium flexible height shows legend without axis labels.
        let mid = ChartBlockFit.fit(
            hasLegend: true, legendHeight: 14,
            hasLabels: true, labelsHeight: 14,
            allowLabels: true,
            minCanvasHeight: 38, fixedCanvasHeight: nil,
            spacing: 4, maxHeight: 68
        )
        #expect(mid.showLegend)
        #expect(!mid.showLabels)
        #expect(mid.canvasHeight == 50)
        #expect(mid.totalHeight == 68)

        // Generous flexible height shows both legend and axis labels.
        let tall = ChartBlockFit.fit(
            hasLegend: true, legendHeight: 14,
            hasLabels: true, labelsHeight: 14,
            allowLabels: true,
            minCanvasHeight: 38, fixedCanvasHeight: nil,
            spacing: 4, maxHeight: 120
        )
        #expect(tall.showLegend)
        #expect(tall.showLabels)
        #expect(tall.canvasHeight == 84)
        #expect(tall.totalHeight == 120)

        // Sweep 0...240pt across flexible and fixed heights to guarantee zero threshold oscillation.
        let fixedOptions: [CGFloat?] = [nil, 32, 48, 64, 120]
        for fixed in fixedOptions {
            for step in 0...480 {
                let maxH = CGFloat(step) * 0.5
                let first = ChartBlockFit.fit(
                    hasLegend: true, legendHeight: 14.4,
                    hasLabels: true, labelsHeight: 14.4,
                    allowLabels: true,
                    minCanvasHeight: fixed ?? 38, fixedCanvasHeight: fixed,
                    spacing: 4, maxHeight: maxH
                )
                let second = ChartBlockFit.fit(
                    hasLegend: true, legendHeight: 14.4,
                    hasLabels: true, labelsHeight: 14.4,
                    allowLabels: true,
                    minCanvasHeight: fixed ?? 38, fixedCanvasHeight: fixed,
                    spacing: 4, maxHeight: first.totalHeight
                )
                #expect(second == first, "ChartBlockFit non-idempotent at fixed=\(String(describing: fixed)), maxH=\(maxH)")
            }
        }
    }

    @Test("UI layouts and widget primitives never feed geometry back into @State")
    func uiLayoutsStayPureWithoutGeometryStateFeedback() throws {
        let uiDir = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../Sources/Lintel/UI")
            .standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(at: uiDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)

        // 1. Every `Layout` conformance across UI/ must be pure (no async dispatch or state callbacks).
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for block in Self.extractLayoutBlocks(in: source) {
                #expect(!block.contains("DispatchQueue"), "\(file.lastPathComponent) Layout must not use DispatchQueue")
                #expect(!block.contains("Task {"), "\(file.lastPathComponent) Layout must not spawn Task")
                #expect(!block.contains("@State"), "\(file.lastPathComponent) Layout must not hold @State")
            }
        }

        // 2. Widget primitive files must decide visibility/overflow in pure Layout, never via geometry-to-state hooks.
        for name in ["AdaptiveLayouts.swift", "ChartView.swift", "NodeView.swift"] {
            let source = try String(contentsOf: uiDir.appending(path: name), encoding: .utf8)
            #expect(!source.contains(".onGeometryChange"), "\(name) must not use .onGeometryChange")
            #expect(!source.contains(".onPreferenceChange"), "\(name) must not use .onPreferenceChange")
            #expect(!source.contains("NaturalContentHeightKey"), "\(name) should not retain unused PreferenceKey")
        }
    }

    private static func extractLayoutBlocks(in source: String) -> [String] {
        var blocks: [String] = []
        let lines = source.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.contains("struct "), line.contains(": Layout") {
                var depth = 0
                var started = false
                var collected: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    collected.append(current)
                    for ch in current {
                        if ch == "{" { depth += 1; started = true }
                        else if ch == "}" { depth -= 1 }
                    }
                    index += 1
                    if started && depth == 0 { break }
                }
                blocks.append(collected.joined(separator: "\n"))
            } else {
                index += 1
            }
        }
        return blocks
    }
}

private extension JSONValue {
    static func parseOrNull(_ text: String) -> JSONValue {
        (try? JSONValue.parse(text)) ?? .null
    }
}
