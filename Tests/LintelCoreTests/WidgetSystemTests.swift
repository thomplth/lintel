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

@Suite struct WidgetSizes {
    @Test func everyWidgetTierHasUnitGridDimensionsAndStepsWithinAllowedSizes() {
        #expect(!WidgetSize.chip.isWidget)
        #expect(WidgetSize.small.columns == 1 && WidgetSize.small.rows == 1)
        #expect(WidgetSize.wide.columns == 2 && WidgetSize.wide.rows == 1)
        #expect(WidgetSize.medium.columns == 2 && WidgetSize.medium.rows == 2)
        #expect(WidgetSize.large.columns == 3 && WidgetSize.large.rows == 2)
        #expect(WidgetSize.tall.columns == 2 && WidgetSize.tall.rows == 3)

        let allowed: [WidgetSize] = [.chip, .small, .wide]
        #expect(WidgetSize.chip.step(by: 1, within: allowed) == .small)
        #expect(WidgetSize.small.step(by: 1, within: allowed) == .wide)
        #expect(WidgetSize.wide.step(by: 1, within: allowed) == .wide)
        #expect(WidgetSize.wide.step(by: -1, within: allowed) == .small)
        #expect(WidgetSize.small.step(by: -1, within: allowed) == .chip)
        #expect(WidgetSize.chip.step(by: -1, within: allowed) == .chip)
    }

    @Test func themeMetricsDeriveConsistentBentoGridDimensions() {
        let metrics = Metrics(Theme.preset("glass")!)
        let small = metrics.widgetSize(.small)
        let wide = metrics.widgetSize(.wide)
        let medium = metrics.widgetSize(.medium)
        let large = metrics.widgetSize(.large)
        let tall = metrics.widgetSize(.tall)
        let gap = metrics.widgetGap

        #expect(wide.width == small.width * 2 + gap)
        #expect(wide.height == small.height)
        #expect(medium.width == wide.width)
        #expect(medium.height == small.height * 2 + gap)
        #expect(large.width == small.width * 3 + gap * 2)
        #expect(large.height == medium.height)
        #expect(tall.width == wide.width)
        #expect(tall.height == small.height * 3 + gap * 2)

        let compact = Metrics(Theme.preset("glass")!.applying(["density": "compact"]))
        let roomy = Metrics(Theme.preset("glass")!.applying(["density": "roomy"]))
        #expect(compact.widgetSize(.small).width < metrics.widgetSize(.small).width)
        #expect(roomy.widgetSize(.small).width > metrics.widgetSize(.small).width)
    }
}

@Suite struct AdaptiveResizeGeometry {
    let metrics = Metrics(Theme.preset("glass")!)
    let allSizes: [WidgetSize] = [.chip, .small, .wide, .medium, .large]

    @Test func handleCornerAdaptsToTheBarsScreenAnchor() {
        #expect(WidgetResize.corner(for: .right) == .bottomLeft)
        #expect(WidgetResize.corner(for: .left) == .bottomRight)
        #expect(WidgetResize.corner(for: .center) == .bottomRight)
    }

    @Test func rightAnchoredChipGrowsWhenPulledLeftAndDown() {
        let chipRect = CGSize(width: 72, height: 28)
        let small = WidgetResize.targetSize(
            from: .chip, startSize: chipRect, translation: CGSize(width: -90, height: 90),
            corner: .bottomLeft, allowed: allSizes, metrics: metrics
        )
        #expect(small == .small)

        let wide = WidgetResize.targetSize(
            from: .chip, startSize: chipRect, translation: CGSize(width: -290, height: 95),
            corner: .bottomLeft, allowed: allSizes, metrics: metrics
        )
        #expect(wide == .wide)

        let medium = WidgetResize.targetSize(
            from: .chip, startSize: chipRect, translation: CGSize(width: -290, height: 280),
            corner: .bottomLeft, allowed: allSizes, metrics: metrics
        )
        #expect(medium == .medium)

        let large = WidgetResize.targetSize(
            from: .chip, startSize: chipRect, translation: CGSize(width: -480, height: 300),
            corner: .bottomLeft, allowed: allSizes, metrics: metrics
        )
        #expect(large == .large)
    }

    @Test func leftAnchoredChipGrowsWhenPulledRightAndDown() {
        let chipRect = CGSize(width: 72, height: 28)
        let target = WidgetResize.targetSize(
            from: .chip, startSize: chipRect, translation: CGSize(width: 290, height: 280),
            corner: .bottomRight, allowed: allSizes, metrics: metrics
        )
        #expect(target == .medium)
    }

    @Test func shrinkingAWidgetBackInwardCollapsesItToAChip() {
        let mediumRect = metrics.widgetSize(.medium)
        let target = WidgetResize.targetSize(
            from: .medium, startSize: mediumRect, translation: CGSize(width: 280, height: -270),
            corner: .bottomLeft, allowed: allSizes, metrics: metrics
        )
        #expect(target == .chip)
    }

    @Test func snappingOnlySelectsSizesSupportedByTheModule() {
        let chipRect = CGSize(width: 34, height: 28)
        let soundSizes: [WidgetSize] = [.chip, .small, .wide]
        let target = WidgetResize.targetSize(
            from: .chip, startSize: chipRect, translation: CGSize(width: -450, height: 400),
            corner: .bottomLeft, allowed: soundSizes, metrics: metrics
        )
        #expect(target == .wide)
    }

    @Test func rubberyPreviewSizeDampsPastBoundsWithoutInverting() {
        let minS = CGSize(width: 60, height: 28)
        let maxS = metrics.widgetSize(.wide)
        let over = WidgetResize.rubberySize(proposed: CGSize(width: maxS.width + 200, height: maxS.height + 200), min: minS, max: maxS)
        #expect(over.width > maxS.width && over.width < maxS.width + 80)
        #expect(over.height > maxS.height && over.height < maxS.height + 80)

        let under = WidgetResize.rubberySize(proposed: CGSize(width: -100, height: -50), min: minS, max: maxS)
        #expect(under.width >= minS.width * 0.75)
        #expect(under.height >= minS.height * 0.75)
    }
}

@Suite struct BentoFlowing {
    let unitW: CGFloat = 180
    let unitH: CGFloat = 160
    let gap: CGFloat = 10

    @Test func packsTwoSmallWidgetsFlushAboveAWideWidget() {
        let flow = BentoFlow(unitWidth: unitW, unitHeight: unitH, gap: gap, maxColumns: 2, anchor: .left)
        let placed = flow.place([("a", .small), ("b", .small), ("c", .wide)])
        #expect(placed.frames["a"] == CGRect(x: 0, y: 0, width: 180, height: 160))
        #expect(placed.frames["b"] == CGRect(x: 190, y: 0, width: 180, height: 160))
        #expect(placed.frames["c"] == CGRect(x: 0, y: 170, width: 370, height: 160))
        #expect(placed.size == CGSize(width: 370, height: 330))
    }

    @Test func rightAnchoredShelfHugsTheRightEdge() {
        let flow = BentoFlow(unitWidth: unitW, unitHeight: unitH, gap: gap, maxColumns: 3, anchor: .right)
        let placed = flow.place([("a", .small), ("b", .wide)])
        // Row 0 has a (col 0 from right -> rightmost) and b (cols 1..2 from right)
        #expect(placed.size == CGSize(width: 560, height: 160))
        #expect(placed.frames["a"] == CGRect(x: 380, y: 0, width: 180, height: 160))
        #expect(placed.frames["b"] == CGRect(x: 0, y: 0, width: 370, height: 160))
    }

    @Test func stacksTwoSmallsBesideAMediumWidgetInThreeColumns() {
        let flow = BentoFlow(unitWidth: unitW, unitHeight: unitH, gap: gap, maxColumns: 3, anchor: .left)
        let placed = flow.place([("m", .medium), ("s1", .small), ("s2", .small)])
        #expect(placed.frames["m"] == CGRect(x: 0, y: 0, width: 370, height: 330))
        #expect(placed.frames["s1"] == CGRect(x: 380, y: 0, width: 180, height: 160))
        #expect(placed.frames["s2"] == CGRect(x: 380, y: 170, width: 180, height: 160))
        #expect(placed.size == CGSize(width: 560, height: 330))
    }

    @Test func emptyInputProducesZeroSize() {
        let flow = BentoFlow(unitWidth: unitW, unitHeight: unitH, gap: gap, maxColumns: 3, anchor: .right)
        let placed = flow.place([])
        #expect(placed.frames.isEmpty)
        #expect(placed.size == .zero)
    }
}

@Suite struct WidgetLayouts {
    private let items = [
        BarLayout.Item(key: "clock", isPinned: true, order: 90),
        BarLayout.Item(key: "system", isPinned: false, order: 20),
        BarLayout.Item(key: "battery", isPinned: true, order: 70),
    ]

    @Test func resizedWidgetsLeaveChipRowsAndStayVisibleWhileIdle() {
        var layout = BarLayout(rows: [["system", "battery", "clock"]])
        layout.setSize(.wide, for: "system")

        #expect(layout.size(of: "system") == .wide)
        #expect(layout.arranged(items, isActive: true) == [["battery", "clock"]])
        #expect(layout.arranged(items, isActive: false) == [["battery", "clock"]])
        // Even though system is unpinned as a chip, once resized to a widget it stays visible while idle.
        #expect(layout.arrangedWidgets(items).map { "\($0.key):\($0.size.rawValue)" } == ["system:wide"])

        // Collapsing back to chip restores it to its original row position.
        layout.setSize(.chip, for: "system")
        #expect(layout.arranged(items, isActive: true) == [["system", "battery", "clock"]])
        #expect(layout.arrangedWidgets(items).isEmpty)
    }

    @Test func hiddenModulesDoNotAppearOnTheWidgetShelf() {
        var layout = BarLayout(rows: [["system", "clock"]])
        layout.setSize(.small, for: "system")
        layout.setHidden("system", true)
        #expect(layout.arrangedWidgets(items).isEmpty)
    }

    @Test func layoutSizesSurviveJSONRoundTripAndDefaultEmptyForLegacyFiles() throws {
        let legacy = try JSONDecoder().decode(BarLayout.self, from: Data(#"{"rows":[["clock"]]}"#.utf8))
        #expect(legacy.sizes.isEmpty)

        var modern = BarLayout(rows: [["system", "clock"]])
        modern.setSize(.medium, for: "system")
        let encoded = try JSONEncoder().encode(modern)
        let decoded = try JSONDecoder().decode(BarLayout.self, from: encoded)
        #expect(decoded == modern)
        #expect(decoded.size(of: "system") == .medium)
    }
}

@Suite struct WidgetDesignSystem {
    @Test func splitComponentParsesWithWeightsAndLintsChildCount() throws {
        let json = evaluate("JSON.stringify(split([column([text('A')]), column([text('B')])], { weights: [1, 2], spacing: 'normal' }))").toString()!
        let parsed = ViewNode.parse(json: json)
        #expect(parsed.problems.isEmpty, "\(parsed.problems)")
        #expect(parsed.node?.component == .split)
        #expect(parsed.node?.numbers("weights") == [1, 2])
        #expect(parsed.node?.children.count == 2)

        let manifest = try ModuleManifest(["id": "test"])
        let tooFew = ViewNode(.split, [:], [ViewNode(.text, ["value": "only one"])])
        let errors = DesignLint.checkWidget(tooFew, size: .wide, manifest: manifest, actions: [], symbolExists: { _ in true })
            .filter { $0.severity == .error }.map(\.message)
        #expect(errors.contains { $0.contains("2 to 3") })
    }

    @Test func sectionPriorityAndAdaptiveListOptionsParseCleanly() {
        let json = evaluate("""
            JSON.stringify([
              section('Secondary', [list([item('Row 1')], { compact: true, overflow: 'summary' })], { priority: 'detail' }),
              chart([1, 2, 3], { height: 'fill' })
            ])
            """).toString()!
        let parsed = ViewNode.parse(json: json)
        #expect(parsed.problems.isEmpty, "\(parsed.problems)")
        let sec = parsed.node?.children.first
        #expect(sec?.string("priority") == "detail")
        #expect(sec?.children.first?.bool("compact") == true)
        #expect(sec?.children.first?.string("overflow") == "summary")
        #expect(parsed.node?.children.last?.string("height") == "fill")
    }

    @Test func manifestParsesDeclaredSizesAndDefaultSize() throws {
        let m = try ModuleManifest(["id": "weather", "sizes": ["chip", "small", "wide", "medium", "large"], "defaultSize": "wide"])
        #expect(m.sizes == [.chip, .small, .wide, .medium, .large])
        #expect(m.defaultSize == .wide)

        let legacy = try ModuleManifest(["id": "old", "panelWidth": "large"])
        #expect(legacy.sizes == nil)
        #expect(legacy.resolvedSizes(hasPanel: true) == [.chip, .large])
        #expect(legacy.resolvedDefaultSize(hasPanel: true) == .large)
    }

    @Test func preludeSupportsViewsMapSizeAwareRenderAndConfigure() {
        let context = JSContext()!
        context.evaluateScript("function __call() {} function __post() {}")
        context.evaluateScript(ModulePrelude.source)
        context.evaluateScript("""
            defineModule({
              meta: { id: 'demo', sizes: ['chip', 'small', 'wide'] },
              views: {
                chip() { return text('ok'); },
                small() { return [stat('A', '1')]; },
                wide() { return [split([stat('A', '1'), stat('B', '2')])]; },
              },
              configure() { return [toggle('Flag', true, 'flip')]; },
              actions: { flip() {} },
            });
            """)
        let desc = JSONValue.parseOrNull(context.evaluateScript("__describe()").toString()!)
        #expect(desc["hasRender"].bool == true)
        #expect(desc["hasPanel"].bool == true)
        #expect(desc["hasConfigure"].bool == true)
        #expect((desc["declaredViews"].array ?? []).compactMap(\.string).sorted() == ["chip", "small", "wide"])

        var renderedSmall: String?
        var renderedConfig: String?
        let doneSmall: @convention(block) (JSValue, JSValue) -> Void = { val, _ in renderedSmall = val.toString() }
        let doneConfig: @convention(block) (JSValue, JSValue) -> Void = { val, _ in renderedConfig = val.toString() }
        context.objectForKeyedSubscript("__render").call(withArguments: ["small", unsafeBitCast(doneSmall, to: AnyObject.self)])
        context.objectForKeyedSubscript("__render").call(withArguments: ["configure", unsafeBitCast(doneConfig, to: AnyObject.self)])
        #expect(ViewNode.parse(json: renderedSmall ?? "").node?.children.first?.component == .stat)
        #expect(ViewNode.parse(json: renderedConfig ?? "").node?.children.first?.component == .toggle)
    }

    @Test func keyboardBindingsIncludeGrowAndShrink() {
        let keymap = BarKeymap.standard
        #expect(keymap.command(for: .character("="), modifiers: [.command]) == .edit("grow"))
        #expect(keymap.command(for: .character("-"), modifiers: [.command]) == .edit("shrink"))
    }
}

private extension JSONValue {
    static func parseOrNull(_ text: String) -> JSONValue {
        (try? JSONValue.parse(text)) ?? .null
    }
}
