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
}

private extension JSONValue {
    static func parseOrNull(_ text: String) -> JSONValue {
        (try? JSONValue.parse(text)) ?? .null
    }
}
