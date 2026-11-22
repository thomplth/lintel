import AppKit
import Foundation
import JavaScriptCore
import Testing
@testable import LintelCore

private func manifest(_ permissions: [String] = [], id: String = "sample") throws -> ModuleManifest {
    try ModuleManifest(["id": .string(id), "permissions": .array(permissions.map(JSONValue.string))])
}

private func lint(chip: JSONValue, panel: JSONValue? = nil, permissions: [String] = [], actions: [String] = []) throws -> [String] {
    DesignLint.check(
        chip: ViewNode.parse(chip).node, panel: panel.flatMap { ViewNode.parse($0).node }, manifest: try manifest(permissions),
        actions: actions, symbolExists: { $0 != "not.a.symbol" }
    ).filter { $0.severity == .error }.map(\.message)
}

private func evaluate(_ script: String) -> JSValue {
    let context = JSContext()!
    context.evaluateScript("function __call() {} function __post() {}")
    context.evaluateScript(ModulePrelude.source)
    return context.evaluateScript(script)
}

@Suite struct ViewParsing {
    @Test func anArrayBecomesAColumnOfItsEntries() {
        let parsed = ViewNode.parse([["type": "text", "value": "a"], nil, ["type": "divider"]])
        #expect(parsed.node?.component == .column)
        #expect(parsed.node?.children.map(\.component) == [.text, .divider])
        #expect(parsed.errors.isEmpty)
    }

    @Test func anUnknownComponentIsAnErrorThatListsTheRealOnes() {
        let parsed = ViewNode.parse(["type": "card"])
        #expect(parsed.node == nil)
        #expect(parsed.errors.first?.contains("no component named 'card'") == true)
        #expect(parsed.errors.first?.contains("stat") == true)
    }

    @Test func aHexColourIsRejectedInFavourOfTones() {
        let parsed = ViewNode.parse(["type": "text", "value": "x", "tone": "#FF0000"])
        #expect(parsed.errors.first?.contains("raw colours") == true)
    }

    @Test func toneAliasesResolveToTheSemanticTone() {
        let parsed = ViewNode.parse(["type": "text", "value": "x", "tone": "danger"])
        #expect(parsed.node?.tone() == ToneChoice(.bad))
    }

    @Test func aFractionOutsideZeroToOneIsClampedWithAWarning() {
        let parsed = ViewNode.parse(["type": "gauge", "value": 42])
        #expect(parsed.node?.number("value") == 1)
        #expect(parsed.errors.isEmpty)
        #expect(parsed.problems.count == 1)
    }

    @Test func aGaugeAcceptsASecondaryStackedFractionAndTone() {
        let parsed = ViewNode.parse(["type": "gauge", "value": 0.8, "tone": "warn", "secondary": 0.35, "secondaryTone": "info"])
        #expect(parsed.problems.isEmpty)
        #expect(parsed.node?.number("value") == 0.8)
        #expect(parsed.node?.tone() == ToneChoice(.warn))
        #expect(parsed.node?.number("secondary") == 0.35)
        #expect(parsed.node?.tone("secondaryTone") == ToneChoice(.info))
    }

    @Test func anUnknownOptionIsDroppedWithAWarning() {
        let parsed = ViewNode.parse(["type": "text", "value": "x", "fontSize": 40])
        #expect(parsed.node?.props["fontSize"] == nil)
        #expect(parsed.problems.first?.severity == .warning)
    }

    @Test func aMissingRequiredOptionIsAnError() {
        #expect(ViewNode.parse(["type": "stat", "label": "CPU"]).errors.count == 1)
    }

    @Test func nestedChildArraysAndFalsyEntriesAreFlattened() {
        let parsed = ViewNode.parse(["type": "row", "children": [[["type": "spacer"]], false, nil, ["type": "dot"]]])
        #expect(parsed.node?.children.map(\.component) == [.spacer, .dot])
    }

    @Test func chartSeriesCarryLabelsValuesAndTones() {
        let parsed = ViewNode.parse(["type": "chart", "series": [["label": "Down", "values": [1, 2, 3], "tone": "accent"]]])
        #expect(parsed.node?.series == [ChartSeries(label: "Down", values: [1, 2, 3], tone: .accent)])
    }
}

@Suite struct DesignRules {
    @Test func aShortIconAndValuePasses() throws {
        #expect(try lint(chip: ["type": "row", "children": [["type": "icon", "name": "cpu"], ["type": "text", "value": "12%"]]]).isEmpty)
    }

    @Test func aPanelComponentInTheBarItemIsRejected() throws {
        let errors = try lint(chip: ["type": "stat", "label": "CPU", "value": "1"])
        #expect(errors.contains { $0.contains("cannot go in the bar item") })
    }

    @Test func aBarItemWithTooManyElementsIsRejected() throws {
        let children = JSONValue.array((0..<9).map { .object(["type": "text", "value": .string("\($0)")]) })
        #expect(try lint(chip: ["type": "row", "children": children]).contains { $0.contains("9 elements") })
    }

    @Test func barItemTextLongerThanTheLimitIsRejected() throws {
        let errors = try lint(chip: ["type": "text", "value": .string(String(repeating: "x", count: 40))])
        #expect(errors.contains { $0.contains("40 characters") })
    }

    @Test func anEmptyBarItemIsRejected() throws {
        #expect(try lint(chip: ["type": "row", "children": []]).contains { $0.contains("empty") })
    }

    @Test func aSymbolThatDoesNotExistIsRejected() throws {
        #expect(try lint(chip: ["type": "icon", "name": "not.a.symbol"]).contains { $0.contains("no SF Symbol") })
    }

    @Test func aViewNamingAnActionTheModuleLacksIsRejected() throws {
        let panel: JSONValue = [["type": "button", "label": "Go", "action": "start"]]
        #expect(try lint(chip: ["type": "dot"], panel: panel, actions: ["stop"]).contains { $0.contains("action 'start'") })
        #expect(try lint(chip: ["type": "dot"], panel: panel, actions: ["start"]).isEmpty)
    }

    @Test func anEmbeddedPageMustBeCoveredByThePermissions() throws {
        let panel: JSONValue = [["type": "web", "url": "https://example.com/status"]]
        #expect(try lint(chip: ["type": "dot"], panel: panel).contains { $0.contains("not listed in meta.permissions") })
        #expect(try lint(chip: ["type": "dot"], panel: panel, permissions: ["example.com"]).isEmpty)
    }

    @Test func aLinkOnAnItemNeedsNoPermissionButMustBeHTTPS() throws {
        func panel(_ url: String) -> JSONValue {
            [["type": "list", "children": [["type": "item", "title": "PR", "url": .string(url)]]]]
        }
        #expect(try lint(chip: ["type": "dot"], panel: panel("https://github.com/a/b")).isEmpty)
        #expect(try lint(chip: ["type": "dot"], panel: panel("http://github.com/a/b")).contains { $0.contains("https") })
    }

    @Test func aListHoldsOnlyItemsAndItemsLiveOnlyInLists() throws {
        #expect(try lint(chip: ["type": "dot"], panel: [["type": "list", "children": [["type": "divider"]]]]).contains { $0.contains("only item()") })
        #expect(try lint(chip: ["type": "dot"], panel: [["type": "item", "title": "x"]]).contains { $0.contains("inside list()") })
    }

    @Test func sectionsCannotNest() throws {
        let panel: JSONValue = [["type": "section", "title": "A", "children": [["type": "section", "title": "B", "children": [["type": "divider"]]]]]]
        #expect(try lint(chip: ["type": "dot"], panel: panel).contains { $0.contains("nested") })
    }

    @Test func aButtonNeedsAnActionOrALink() throws {
        #expect(try lint(chip: ["type": "dot"], panel: [["type": "button", "label": "Go"]]).contains { $0.contains("needs an action or a url") })
    }
}

@Suite struct Themes {
    @Test func everyPresetNameResolvesToAThemeCarryingThatName() {
        for name in Theme.presetNames { #expect(Theme.preset(name)?.preset == name) }
    }

    @Test func aPresetInAPatchAppliesBeforeTheOtherFields() {
        let theme = Theme().applying(["fontSize": 18, "preset": "ink"])
        #expect(theme.idleMaterial == "solid")
        #expect(theme.fontSize == 18)
    }

    @Test func outOfRangeNumbersAreClampedAndUnknownChoicesIgnored() {
        let theme = Theme().applying(["fontSize": 300, "fontWeight": "ultra", "textColor": "red", "idleOpacity": 0])
        #expect(theme.fontSize == 32)
        #expect(theme.fontWeight == Theme().fontWeight)
        #expect(theme.textColor == "#FFFFFF")
        #expect(theme.idleOpacity == 0.2)
    }

    @Test func aThemeSurvivesEncodingAndDecoding() throws {
        let theme = Theme.preset("terminal")!.applying(["density": "compact"])
        #expect(try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(theme)) == theme)
    }

    @Test func aStoredThemeWithUnknownOrBadFieldsStillLoads() throws {
        let stored = #"{"fontSize": "huge", "sparkle": true, "cornerStyle": "square"}"#
        let theme = try JSONDecoder().decode(Theme.self, from: Data(stored.utf8))
        #expect(theme.fontSize == Theme().fontSize)
        #expect(theme.cornerStyle == "square")
    }

    @Test func theDefaultHaloMatchesMeridiansClock() {
        let theme = Theme()
        #expect(theme.fontSize == 18)
        #expect(theme.fontWeight == "regular")
        #expect(theme.textColor == "#FFFFFF")
        #expect(theme.shadowBlur == 3)
        #expect(theme.shadowOpacity == 1)
    }

    @Test func onlyTheHaloPresetTakesMeridiansLargerRegularText() {
        for name in ["glass", "adaptive", "ink", "paper"] {
            #expect(Theme.preset(name)?.fontSize == 14)
            #expect(Theme.preset(name)?.fontWeight == "medium")
        }
    }

    @Test func adaptivePresetUsesAdaptiveMaterialsAndCapsules() throws {
        let theme = try #require(Theme.preset("adaptive"))
        #expect(theme.idleMaterial == "adaptive")
        #expect(theme.activeMaterial == "adaptive")
        #expect(theme.panelMaterial == "adaptive")
        #expect(theme.cornerStyle == "capsule")
        #expect(theme.colorScheme == "auto")
        #expect(theme.usesAdaptiveBackdrop)
        #expect(!Theme.preset("glass")!.usesAdaptiveBackdrop)
        #expect(try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(theme)) == theme)
    }

    @Test func theHaloShadowRadiusIsHalfTheBlurSoItMatchesAnAppKitShadowOfThatBlur() {
        #expect(Metrics(Theme()).haloShadowRadius == 1.5)
        #expect(Metrics(Theme().applying(["shadowBlur": 8])).haloShadowRadius == 4)
    }

    @Test func densityScalesSpacingAndFontRolesScaleFromTheBaseSize() {
        let compact = Metrics(Theme().applying(["density": "compact"])), roomy = Metrics(Theme().applying(["density": "roomy"]))
        #expect(compact.spacing("normal") < roomy.spacing("normal"))
        let metrics = Metrics(Theme().applying(["fontSize": 20]))
        #expect(metrics.fontSize(role: "caption") < metrics.fontSize(role: nil))
        #expect(metrics.fontSize(role: "display") > metrics.fontSize(role: nil))
    }

    @Test func everyThemeFieldAppearsInThePatchItProduces() {
        #expect(Set(Theme().patch.keys) == Set(Theme.fields.map(\.name)))
    }
}

@Suite struct Manifests {
    @Test func anIdMustBeLowercaseDashedAndShort() {
        #expect(ModuleManifest.isValid(id: "github-prs"))
        #expect(!ModuleManifest.isValid(id: "GitHub"))
        #expect(!ModuleManifest.isValid(id: "-x"))
        #expect(!ModuleManifest.isValid(id: "../x"))
        #expect(!ModuleManifest.isValid(id: String(repeating: "a", count: 41)))
    }

    @Test func permissionsSplitIntoHostsAndCapabilities() throws {
        let manifest = try manifest(["api.example.com", "notify", "exec:gh", "secret:token"])
        #expect(manifest.hosts == ["api.example.com"])
        #expect(Set(manifest.capabilities) == [.notify, .exec("gh"), .secret("token")])
    }

    @Test func aPermissionThatIsNeitherHostNorCapabilityIsRejected() {
        #expect(throws: ModuleManifest.Invalid.self) { try manifest(["everything"]) }
        #expect(throws: ModuleManifest.Invalid.self) { try manifest(["exec:rm -rf"]) }
    }

    @Test func onlyDeclaredHostsOverHTTPSAreAllowed() throws {
        let manifest = try manifest(["api.example.com", "*.cdn.net", "localhost:8080"])
        #expect(manifest.allows(URL(string: "https://api.example.com/v1")!))
        #expect(!manifest.allows(URL(string: "http://api.example.com/v1")!))
        #expect(!manifest.allows(URL(string: "https://evil.com/api.example.com")!))
        #expect(!manifest.allows(URL(string: "https://api.example.com.evil.com/")!))
        #expect(manifest.allows(URL(string: "https://a.b.cdn.net/x.png")!))
        #expect(!manifest.allows(URL(string: "https://notcdn.net/x.png")!))
        #expect(manifest.allows(URL(string: "http://localhost:8080/x")!))
        #expect(!manifest.allows(URL(string: "http://localhost:9090/x")!))
    }

    @Test func refreshIsNeverFasterThanOncePerSecond() throws {
        #expect(try ModuleManifest(["id": "a", "refreshSeconds": 0.01]).refreshSeconds == 1)
    }

    @Test func anApprovalCoversTheSameOrFewerPermissionsButNotMore() throws {
        let approval = Approval(permissions: ["api.example.com", "notify"])
        #expect(approval.covers(try manifest(["notify"])))
        #expect(!approval.covers(try manifest(["notify", "exec:gh"])))
    }
}

@Suite struct Layouts {
    private let items = [
        BarLayout.Item(key: "clock", isPinned: true, order: 90), BarLayout.Item(key: "system", isPinned: false, order: 20),
        BarLayout.Item(key: "battery", isPinned: true, order: 70), BarLayout.Item(key: "menubar:x", isPinned: false, order: 500, isOptIn: true),
    ]

    @Test func withNoRowsEverythingSharesOneRowInOrder() {
        #expect(BarLayout().arranged(items, isActive: true) == [["system", "battery", "clock"]])
    }

    @Test func idleShowsOnlyPinnedItemsAndDropsEmptyRows() {
        let layout = BarLayout(rows: [["system"], ["battery", "clock"]])
        #expect(layout.arranged(items, isActive: false) == [["battery", "clock"]])
    }

    @Test func aFirstRowInTheMenuBarStaysWholeWhileTheRowsBelowShowOnlyPinnedItems() {
        let layout = BarLayout(rows: [["system", "battery"], ["clock"], ["menubar:x"]])
        #expect(layout.arranged(items, isActive: false, keepsFirstRow: true) == [["system", "battery"], ["clock"]])
        #expect(layout.arranged(items, isActive: true, keepsFirstRow: true) == [["system", "battery"], ["clock"], ["menubar:x"]])
    }

    @Test func anEmptyFirstRowInTheMenuBarKeepsItsPlaceSoTheSecondRowDoesNotRiseIntoIt() {
        let layout = BarLayout(rows: [["system"], ["clock"]], hidden: ["system"])
        #expect(layout.arranged(items, isActive: false, keepsFirstRow: true) == [[], ["clock", "battery"]])
    }

    @Test func anOptInItemAppearsOnlyWhenARowNamesIt() {
        #expect(BarLayout(rows: [["menubar:x", "clock"]]).arranged(items, isActive: true).first == ["menubar:x", "clock", "system", "battery"])
    }

    @Test func aPinOverrideBeatsTheModulesOwnDefault() {
        let layout = BarLayout(rows: [], pinned: ["system": true, "clock": false])
        #expect(layout.arranged(items, isActive: false) == [["system", "battery"]])
    }

    @Test func movingAnItemDownFromASharedRowStartsANewRow() {
        var layout = BarLayout(rows: [["system", "clock"]])
        layout.moveToRow("clock", offset: 1)
        #expect(layout.rows == [["system"], ["clock"]])
        layout.moveToRow("clock", offset: -1)
        #expect(layout.rows == [["system", "clock"]])
    }

    @Test func hidingRemovesTheItemFromItsRowAndShowingForgetsIt() {
        var layout = BarLayout(rows: [["system", "clock"]])
        layout.setHidden("system", true)
        #expect(layout.rows == [["clock"]])
        #expect(layout.arranged(items, isActive: true) == [["clock", "battery"]])
        layout.setHidden("system", false)
        #expect(layout.hidden.isEmpty)
    }

    @Test func showingAHiddenModuleMakesItReappearInArrangedRows() {
        var layout = BarLayout(rows: [["clock"]], hidden: ["system"])
        #expect(layout.isHidden("system"))
        #expect(!layout.arranged(items, isActive: true).joined().contains("system"))
        layout.show("system")
        #expect(!layout.isHidden("system"))
        #expect(layout.arranged(items, isActive: true) == [["clock", "system", "battery"]])
    }

    @Test func showingAHiddenOptInItemPlacesItBackInARow() {
        var layout = BarLayout(rows: [["clock"]], hidden: ["menubar:x"])
        layout.show("menubar:x", isOptIn: true)
        #expect(!layout.isHidden("menubar:x"))
        #expect(layout.rows == [["clock", "menubar:x"]])
        #expect(layout.arranged(items, isActive: true).joined().contains("menubar:x"))
    }

    @Test func hidingTheLastMenuBarItemKeepsTheFirstRowEmptyWhenPreserved() {
        var layout = BarLayout(rows: [["system"], ["clock"]])
        layout.setHidden("system", true, keepsFirstRow: true)
        #expect(layout.rows == [[], ["clock"]])
        #expect(layout.isHidden("system"))
        #expect(layout.arranged(items, isActive: true, keepsFirstRow: true) == [[], ["clock", "battery"]])
    }
}

@Suite struct MenuBarFitting {
    @Test func theModulesNearestTheEndStayInTheMenuBarAndTheRestOverflowBelow() {
        let chips: [(key: String, width: CGFloat)] = [("a", 50), ("b", 40), ("clock", 60)]
        let fit = MenuBarFit(chips: chips, spacing: 10, budget: 120)
        #expect(fit.inMenuBar == ["b", "clock"])
        #expect(fit.overflow == ["a"])
        #expect(MenuBarFit(chips: chips, spacing: 10, budget: 500).overflow.isEmpty)
    }

    @Test func aModuleWiderThanTheWholeBudgetOverflows() {
        let fit = MenuBarFit(chips: [("wide", 300)], spacing: 4, budget: 100)
        #expect(fit.inMenuBar.isEmpty)
        #expect(fit.overflow == ["wide"])
    }

    @Test func overflowedModulesLeadTheSecondRow() {
        let fit = MenuBarFit(chips: [("a", 50), ("b", 40)], spacing: 10, budget: 45)
        #expect(fit.rows(from: [["a", "b"], ["c"]]) == [["b"], ["a", "c"]])
        #expect(fit.rows(from: [["a", "b"]]) == [["b"], ["a"]])
    }
}

@Suite struct Rearranging {
    private let rows: [[BarDrop.Chip]] = [
        [.init(key: "a", frame: CGRect(x: 0, y: 4, width: 40, height: 20)), .init(key: "b", frame: CGRect(x: 50, y: 4, width: 40, height: 20))],
        [.init(key: "c", frame: CGRect(x: 0, y: 30, width: 40, height: 20))],
    ]

    @Test func aPointerOnTheMiddleOfARowDropsBesideTheNearestChip() {
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 14), in: rows, moving: "z") == .row(0, index: 0))
        #expect(BarDrop.resolve(at: CGPoint(x: 60, y: 14), in: rows, moving: "z") == .row(0, index: 1))
        #expect(BarDrop.resolve(at: CGPoint(x: 85, y: 14), in: rows, moving: "z") == .row(0, index: 2))
        #expect(BarDrop.resolve(at: CGPoint(x: 80, y: 40), in: rows, moving: "z") == .row(1, index: 1))
    }

    @Test func aPointerOnARowsTopOrBottomEdgeOrBeyondTheBarOpensANewRow() {
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 5), in: rows, moving: "z") == .newRow(0))
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: -20), in: rows, moving: "z") == .newRow(0))
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 27), in: rows, moving: "z") == .newRow(1))
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 49), in: rows, moving: "z") == .newRow(2))
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 70), in: rows, moving: "z") == .newRow(2))
    }

    private let menuBarStrip = CGRect(x: -100, y: -30, width: 200, height: 30)
    private var menuBarRows: [[BarDrop.Chip]] {
        [[.init(key: "a", frame: CGRect(x: -90, y: -25, width: 40, height: 20)), .init(key: "b", frame: CGRect(x: -40, y: -25, width: 40, height: 20))],
         [.init(key: "c", frame: CGRect(x: 0, y: 4, width: 40, height: 20))]]
    }

    @Test func theMenuBarRowTakesADropAnywhereOnItsStripIncludingItsTopEdge() {
        #expect(BarDrop.resolve(at: CGPoint(x: -80, y: -29), in: menuBarRows, moving: "z", firstRowBand: menuBarStrip) == .row(0, index: 0))
        #expect(BarDrop.resolve(at: CGPoint(x: 95, y: -15), in: menuBarRows, moving: "z", firstRowBand: menuBarStrip) == .row(0, index: 2))
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 14), in: menuBarRows, moving: "z", firstRowBand: menuBarStrip) == .row(1, index: 0))
    }

    @Test func anEmptyMenuBarRowStillTakesADropAndKeepsItsIndex() {
        let rows: [[BarDrop.Chip]] = [[], menuBarRows[1]]
        #expect(BarDrop.resolve(at: CGPoint(x: 0, y: -15), in: rows, moving: "z", firstRowBand: menuBarStrip) == .row(0, index: 0))
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 14), in: rows, moving: "z", firstRowBand: menuBarStrip) == .row(1, index: 0))
        let leaving: [[BarDrop.Chip]] = [[.init(key: "z", frame: CGRect(x: -90, y: -25, width: 40, height: 20))], menuBarRows[1]]
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 14), in: leaving, moving: "z", firstRowBand: menuBarStrip) == .row(1, index: 0))
    }

    @Test func movingTheLastModuleOutOfTheMenuBarRowLeavesItEmptyInPlace() {
        var layout = BarLayout(rows: [["a"], ["b"]])
        layout.move("a", to: .row(1, index: 0), keepsFirstRow: true)
        #expect(layout.rows == [[], ["a", "b"]])
        layout.move("b", to: .row(0, index: 0), keepsFirstRow: true)
        #expect(layout.rows == [["b"], ["a"]])
    }

    @Test func makingTheArrangementExplicitKeepsAnEmptyMenuBarRow() {
        var layout = BarLayout(rows: [[], ["c"]])
        layout.materialise([BarLayout.Item(key: "c", isPinned: true, order: 1)], keepsFirstRow: true)
        #expect(layout.rows == [[], ["c"]])
    }

    @Test func carryingAModuleWellBelowTheBarRemovesIt() {
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 90), in: rows, moving: "z") == .remove)
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 300), in: rows, moving: "z") == .remove)
    }

    @Test func aModuleHeldInItsOwnNewRowBelowTheBarIsNotRemoved() {
        let preview: [[BarDrop.Chip]] = [rows[0], [.init(key: "z", frame: CGRect(x: 0, y: 30, width: 40, height: 20))]]
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 70), in: preview, moving: "z") == .newRow(1))
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 90), in: preview, moving: "z") == .remove)
    }

    @Test func carryingAModuleWellPastEitherEndOfTheBarRemovesIt() {
        #expect(BarDrop.resolve(at: CGPoint(x: 130, y: 14), in: rows, moving: "z") == .row(0, index: 2))
        #expect(BarDrop.resolve(at: CGPoint(x: 150, y: 14), in: rows, moving: "z") == .remove)
        #expect(BarDrop.resolve(at: CGPoint(x: -60, y: 14), in: rows, moving: "z") == .remove)
    }

    @Test func removingAModuleHidesItAndClosesItsGap() {
        var layout = BarLayout(rows: [["a", "b"], ["c"]])
        layout.move("c", to: .remove)
        #expect(layout.rows == [["a", "b"]])
        #expect(layout.hidden == ["c"])
    }

    @Test func theDraggedModulesOwnSpaceIsNotATargetSoItsPreviewHoldsStill() {
        var layout = BarLayout(rows: [["a", "b"], ["c"]])
        let drop = BarDrop.resolve(at: CGPoint(x: 80, y: 14), in: rows, moving: "b")
        #expect(drop == .row(0, index: 1))
        layout.move("b", to: drop!)
        #expect(layout.rows == [["a", "b"], ["c"]])
    }

    @Test func aRowHoldingOnlyTheDraggedModuleIsAGapThatKeepsItsPlace() {
        #expect(BarDrop.resolve(at: CGPoint(x: 10, y: 40), in: rows, moving: "c") == .newRow(1))
        var layout = BarLayout(rows: [["a", "b"], ["c"]])
        layout.move("c", to: .newRow(1))
        #expect(layout.rows == [["a", "b"], ["c"]])
    }

    @Test func dropPositionsCountTheRowsAfterTheModuleLeaves() {
        var layout = BarLayout(rows: [["a", "b", "c"]])
        layout.move("a", to: .row(0, index: 1))
        #expect(layout.rows == [["b", "a", "c"]])
        layout.move("c", to: .row(0, index: 0))
        #expect(layout.rows == [["c", "b", "a"]])
    }

    @Test func movingIntoAnotherRowDropsTheRowItLeavesEmpty() {
        var layout = BarLayout(rows: [["a"], ["b", "c"]])
        layout.move("a", to: .row(0, index: 1))
        #expect(layout.rows == [["b", "a", "c"]])
    }

    @Test func movingIntoANewRowSplitsItOutAtThatPosition() {
        var layout = BarLayout(rows: [["a", "b"], ["c"]])
        layout.move("b", to: .newRow(1))
        #expect(layout.rows == [["a"], ["b"], ["c"]])
        layout.move("c", to: .newRow(0))
        #expect(layout.rows == [["c"], ["a"], ["b"]])
    }

    @Test func applyingTheSameDropTwiceChangesNothingMore() {
        var once = BarLayout(rows: [["a", "b"], ["c"]])
        once.move("a", to: .row(1, index: 0))
        var twice = once
        twice.move("a", to: .row(1, index: 0))
        #expect(once.rows == [["b"], ["a", "c"]])
        #expect(twice.rows == once.rows)
    }
}

@Suite struct Placements {
    private let plain = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1000, height: 600), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 576), menuBarAutoHides: true
    )
    private let size = CGSize(width: 200, height: 20)

    @Test func theBarHugsTheTopEdgeAtItsAnchorWhenTheMenuBarHides() {
        #expect(Placement.bar(contentSize: size, on: plain, anchor: .right).frame == CGRect(x: 800, y: 580, width: 200, height: 20))
        #expect(Placement.bar(contentSize: size, on: plain, anchor: .left, edgeInset: 10).frame.minX == 10)
        #expect(Placement.bar(contentSize: size, on: plain, anchor: .center).frame.midX == 500)
    }

    @Test func theBarSitsBelowAMenuBarThatAlwaysShows() {
        var screen = plain
        screen.menuBarAutoHides = false
        #expect(Placement.bar(contentSize: size, on: screen).frame.maxY == 576)
    }

    @Test func besideANotchTheFirstRowIsMeridiansThirtyPointStripAtTheTopOfTheScreen() {
        var screen = plain
        screen.notchStripHeight = 32
        screen.areaRightOfNotch = CGRect(x: 600, y: 568, width: 400, height: 32)
        let placement = Placement.bar(contentSize: size, on: screen)
        #expect(placement.topRowMinHeight == 30)
        #expect(placement.frame.maxY == 600)
        let wide = Placement.bar(contentSize: CGSize(width: 500, height: 20), on: screen)
        #expect(wide.topRowMinHeight == 0)
        #expect(wide.frame.maxY == 568)
    }

    @Test func besideANotchTheBarWrapsToTheSpaceBesideItSoItsFirstLineStaysInTheStrip() {
        var screen = plain
        screen.notchStripHeight = 32
        screen.areaRightOfNotch = CGRect(x: 600, y: 568, width: 400, height: 32)
        screen.areaLeftOfNotch = CGRect(x: 0, y: 568, width: 400, height: 32)
        #expect(Placement.widestRow(on: screen, anchor: .right, edgeInset: 10, otherwise: 900) == 374)
        #expect(Placement.widestRow(on: screen, anchor: .left, otherwise: 900) == 384)
        #expect(Placement.widestRow(on: screen, anchor: .center, otherwise: 900) == 900)
        let wrapped = Placement.bar(contentSize: CGSize(width: 384, height: 60), on: screen, anchor: .right)
        #expect(wrapped.frame.maxY == 600)
    }

    @Test func withoutANotchOrWithAMenuBarThatShowsTheBarKeepsItsUsualWidth() {
        #expect(Placement.widestRow(on: plain, anchor: .right, otherwise: 900) == 900)
        var shown = plain
        shown.menuBarAutoHides = false
        shown.notchStripHeight = 32
        shown.areaRightOfNotch = CGRect(x: 600, y: 568, width: 400, height: 32)
        #expect(Placement.widestRow(on: shown, anchor: .right, otherwise: 900) == 900)
    }

    @Test func aCentredBarOnANotchedScreenGoesBelowTheNotch() {
        var screen = plain
        screen.notchStripHeight = 32
        screen.areaRightOfNotch = CGRect(x: 600, y: 568, width: 400, height: 32)
        #expect(Placement.bar(contentSize: size, on: screen, anchor: .center).frame.maxY == 568)
    }

    @Test func rowsBelowAMenuBarItemHangUnderItAlignedToTheBarsAnchor() {
        let item = CGRect(x: 600, y: 576, width: 200, height: 24)
        let rows = CGSize(width: 300, height: 50)
        #expect(Placement.rows(contentSize: rows, under: item, on: plain, anchor: .right) == CGRect(x: 500, y: 526, width: 300, height: 50))
        #expect(Placement.rows(contentSize: rows, under: item, on: plain, anchor: .left).minX == 600)
        #expect(Placement.rows(contentSize: rows, under: item, on: plain, anchor: .center).midX == 700)
        let tallWindow = CGRect(x: 600, y: 570, width: 200, height: 39)
        #expect(Placement.rows(contentSize: rows, under: tallWindow, on: plain, anchor: .right).maxY == 576)
    }

    @Test func rowsBelowAMenuBarItemStayOnScreen() {
        let item = CGRect(x: 900, y: 576, width: 100, height: 24)
        #expect(Placement.rows(contentSize: CGSize(width: 300, height: 50), under: item, on: plain, anchor: .left).maxX == 1000)
        let nearLeft = CGRect(x: 10, y: 576, width: 100, height: 24)
        #expect(Placement.rows(contentSize: CGSize(width: 300, height: 50), under: nearLeft, on: plain, anchor: .right).minX == 0)
    }

    @Test func anAppKitFrameFlipsIntoGlobalDisplayCoordinates() {
        let flipped = Placement.globalDisplayRect(CGRect(x: 600, y: 576, width: 200, height: 24), mainScreenHeight: 600)
        #expect(flipped == CGRect(x: 600, y: 0, width: 200, height: 24))
    }

    @Test func aDropSnapsToTheNearestThirdOfTheScreen() {
        #expect(Placement.anchor(forDropAt: 100, on: plain) == .left)
        #expect(Placement.anchor(forDropAt: 500, on: plain) == .center)
        #expect(Placement.anchor(forDropAt: 900, on: plain) == .right)
    }

    @Test func aPanelHangsUnderItsChipAndStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let right = Placement.panel(size: CGSize(width: 300, height: 400), under: CGRect(x: 950, y: 580, width: 40, height: 20), on: screen)
        #expect(right.maxX == 990)
        #expect(right.maxY == 574)
        let left = Placement.panel(size: CGSize(width: 300, height: 400), under: CGRect(x: 2, y: 580, width: 40, height: 20), on: screen)
        #expect(left.minX == 8)
        let tall = Placement.panel(size: CGSize(width: 300, height: 900), under: CGRect(x: 500, y: 580, width: 40, height: 20), on: screen)
        #expect(tall.minY >= 8)
    }
}

@Suite struct Activations {
    @Test func restingOpensTheBarButPassingOverDoesNot() {
        var activation = Activation(dwell: 0.3, grace: 0.6)
        activation.pointer(inside: true, at: 0)
        activation.pointer(inside: false, at: 0.1)
        #expect(!activation.isActive)
        activation.pointer(inside: true, at: 1)
        activation.pointer(inside: true, at: 1.31)
        #expect(activation.isActive)
    }

    @Test func leavingKeepsTheBarOpenForTheGracePeriod() {
        var activation = Activation(dwell: 0, grace: 0.6)
        activation.pointer(inside: true, at: 0)
        activation.pointer(inside: true, at: 0.01)
        activation.pointer(inside: false, at: 1)
        activation.pointer(inside: false, at: 1.5)
        #expect(activation.isActive)
        activation.pointer(inside: false, at: 1.7)
        #expect(!activation.isActive)
    }

    @Test func aHeldBarIgnoresThePointerUntilUnheldThenLingers() {
        var activation = Activation()
        activation.hold()
        activation.pointer(inside: false, at: 100)
        #expect(activation.state == .held)
        activation.unhold(at: 100)
        #expect(activation.isActive)
        activation.pointer(inside: false, at: 101)
        #expect(!activation.isActive)
    }
}

@Suite struct ChatReplies {
    @Test func moduleSourceWithBracesInsideProseAndFencesParses() throws {
        let source = "defineModule({ meta: { id: 'x' }, render() { return text('}'); } });"
        let wrapped = "Here you go:\n```json\n{\"say\": \"Done {really}\", \"module\": {\"source\": \(JSONValue.string(source).text)}}\n```\nEnjoy }"
        let reply = try ChatReply.parse(wrapped)
        #expect(reply.say == "Done {really}")
        #expect(reply.moduleSource == source)
    }

    @Test func aReplyWithoutJSONIsAnError() {
        #expect(throws: ChatReply.ParseError.noJSONObject) { try ChatReply.parse("I cannot do that.") }
    }

    @Test func layoutThemeAndSwitchesAreRead() throws {
        let reply = try ChatReply.parse(#"{"theme": {"fontSize": 16}, "layout": {"rows": [["clock"], ["date"]]}, "add": ["weather"], "remove": ["old"], "menuBarApps": {"com.x": false}, "inspect": {"url": "https://a.b"}}"#)
        #expect(reply.theme?["fontSize"] == 16)
        #expect(reply.layout?.rows == [["clock"], ["date"]])
        #expect(reply.add == ["weather"])
        #expect(reply.remove == ["old"])
        #expect(reply.menuBarApps == ["com.x": false])
        #expect(reply.inspectURL == "https://a.b")
    }
}

@Suite struct AccessoryAndSuggestionLint {
    @Test func anItemAccessoryMustNameAnExistingAction() throws {
        let panel: JSONValue = ["type": "list", "children": [["type": "item", "title": "Tokyo", "accessoryIcon": "minus.circle", "accessoryAction": "remove"]]]
        #expect(try lint(chip: ["type": "dot"], panel: panel, actions: []).contains { $0.contains("'remove'") })
        #expect(try lint(chip: ["type": "dot"], panel: panel, actions: ["remove"]).isEmpty)
    }

    @Test func aFieldSuggestActionMustExist() throws {
        let panel: JSONValue = ["type": "field", "placeholder": "Add", "action": "add", "suggest": "suggest"]
        #expect(try lint(chip: ["type": "dot"], panel: panel, actions: ["add"]).contains { $0.contains("'suggest'") })
        #expect(try lint(chip: ["type": "dot"], panel: panel, actions: ["add", "suggest"]).isEmpty)
    }
}

@Suite struct Prelude {
    @Test func everyComponentInTheCatalogHasAFunctionThatBuildsIt() {
        for spec in Catalog.all {
            let name = spec.component.rawValue
            let built = evaluate("typeof \(name) === 'function' ? \(name)('a', 'b', 'c').type : 'missing'")
            #expect(built.toString() == name, "prelude function \(name)")
        }
    }

    @Test func whatTheComponentFunctionsBuildParsesWithoutProblems() {
        let json = evaluate("""
            JSON.stringify([
              row([icon('cpu'), text('12%', { mono: true }), sparkline([1, 2, 3]), gauge(0.5), ring(0.2), dot('good'), badge(3)]),
              section('A', [grid(2, [stat('CPU', 12, { unit: '%' }), stat('RAM', 3)]), meter('Memory', 0.5, { value: '8 GB' })], { trailing: 'x' }),
              chart([1, 2, 3], { kind: 'line' }), chart([{ label: 'a', values: [1, 2] }]),
              list([item('One', { subtitle: 's', value: 'v' })]), keyValue('k', 'v'), button('Go', 'go', { style: 'primary' }),
              toggle('T', true, 'go'), segmented(['a', 'b'], 'a', 'go'), slider(0.5, 'go'), field('Add', 'go'), divider(),
              note('n'), progress(null, { label: 'Loading' }), progress(0.4), empty('tray', 'Nothing'), spacer(),
              image('https://a.b/c.png'), web('https://a.b', { selector: '#x' }), app('<p>hi</p>', { state: { a: 1 } }),
              column([text('x', { role: 'display' })], { align: 'center' }),
            ])
            """).toString()!
        let parsed = ViewNode.parse(json: json)
        #expect(parsed.problems.isEmpty, "\(parsed.problems)")
        #expect(parsed.node?.children.count == 21)
    }

    @Test func anItemCarriesATrailingAccessoryButton() {
        let built = evaluate("JSON.stringify(item('Tokyo', { accessoryIcon: 'minus.circle', accessoryAction: 'remove', accessoryLabel: 'Remove Tokyo', payload: 'Asia/Tokyo' }))").toString()!
        let node = ViewNode.parse(json: built).node
        #expect(node?.string("accessoryIcon") == "minus.circle")
        #expect(node?.string("accessoryAction") == "remove")
        #expect(node?.string("accessoryLabel") == "Remove Tokyo")
    }

    @Test func aGaugeCarriesSecondaryBarOptionsFromThePrelude() {
        let built = evaluate("JSON.stringify(gauge(0.75, { tone: 'warn', secondary: 0.4, secondaryTone: 'good' }))").toString()!
        let parsed = ViewNode.parse(json: built)
        #expect(parsed.problems.isEmpty, "\(parsed.problems)")
        #expect(parsed.node?.number("value") == 0.75)
        #expect(parsed.node?.tone() == ToneChoice(.warn))
        #expect(parsed.node?.number("secondary") == 0.4)
        #expect(parsed.node?.tone("secondaryTone") == ToneChoice(.good))

        let single = ViewNode.parse(json: evaluate("JSON.stringify(gauge(0.5))").toString()!).node
        #expect(single?.number("secondary") == nil)
        #expect(single?.tone("secondaryTone") == nil)
    }

    @Test func aFieldNamesTheActionThatSuggestsCompletions() {
        #expect(evaluate("field('Add a city', 'add', { suggest: 'suggestCities' }).suggest").toString() == "suggestCities")
    }

    @Test func theLegacyColorOptionMapsToTone() {
        #expect(evaluate("text('x', { color: 'red' }).tone").toString() == "red")
    }

    @Test func formatHelpersReadTheSameEverywhere() {
        #expect(evaluate("host.format.bytes(1500000000)").toString() == "1.5 GB")
        #expect(evaluate("host.format.bytes(512)").toString() == "512 B")
        #expect(evaluate("host.format.rate(123456)").toString() == "123 kB/s")
        #expect(evaluate("host.format.percent(0.425)").toString() == "43%")
        #expect(evaluate("host.format.number(1234567)").toString() == "1,234,567")
        #expect(evaluate("host.format.compact(15300)").toString() == "15.3k")
        #expect(evaluate("host.format.duration(3900)").toString() == "1h 05m")
        #expect(evaluate("host.format.timer(245)").toString() == "4:05")
        #expect(evaluate("host.format.timer(3725)").toString() == "1:02:05")
        #expect(evaluate("host.format.truncate('abcdefghij', 5)").toString() == "abcd…")
    }

    @Test func timeReadsInTwentyFourOrTwelveHours() {
        let afternoon = "new Date(2026, 10, 18, 14, 5, 9)"
        #expect(evaluate("host.format.time(\(afternoon))").toString() == "14:05")
        #expect(evaluate("host.format.time(\(afternoon), { seconds: true })").toString() == "14:05:09")
        #expect(evaluate("host.format.time(\(afternoon), { twelveHour: true })").toString() == "2:05 PM")
        #expect(evaluate("host.format.time(\(afternoon), { twelveHour: true, seconds: true })").toString() == "2:05:09 PM")
        #expect(evaluate("host.format.time(new Date(2026, 10, 18, 0, 5), { twelveHour: true })").toString() == "12:05 AM")
        #expect(evaluate("host.format.time(new Date(2026, 10, 18, 12, 0), { twelveHour: true })").toString() == "12:00 PM")
    }

    @Test func dateReadsInTheChosenOrderWithOptionalWeekdayAndYear() {
        func date(_ options: String) -> String? { evaluate("host.format.date(new Date(2026, 2, 4), \(options))").toString() }
        #expect(date("undefined") == "Wed 4 Mar")
        #expect(date("'long'") == "Wed 4 Mar 2026")
        #expect(date("{ order: 'day-month' }") == "Wed 4 Mar")
        #expect(date("{ order: 'month-day', year: true }") == "Wed Mar 4, 2026")
        #expect(date("{ order: 'dmy', weekday: false }") == "04/03")
        #expect(date("{ order: 'mdy', weekday: false, year: true }") == "03/04/2026")
        #expect(date("{ order: 'iso', year: true }") == "Wed 2026-03-04")
        #expect(date("{ order: 'iso', weekday: false }") == "03-04")
        #expect(date("{ weekday: false, year: true }") == "4 Mar 2026")
    }

    @Test func historyKeepsARollingSeriesPerKey() {
        #expect(evaluate("host.history('a', 1, 3); host.history('a', 2, 3); host.history('a', 3, 3); host.history('a', 4, 3).join(',')").toString() == "2,3,4")
        #expect(evaluate("host.history('a', 1); host.history('a').length").toInt32() == 1)
    }

    @Test func storageReadsItsFallbackUntilAValueIsSet() {
        #expect(evaluate("host.storage.get('k', 7)").toInt32() == 7)
        #expect(evaluate("host.storage.set('k', 9); host.storage.get('k', 7)").toInt32() == 9)
    }
}

@Suite struct Guide {
    @Test func everySymbolTheGuideOffersExists() {
        let missing = DesignGuide.allSymbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        #expect(missing.isEmpty, "\(missing)")
    }

    @Test func theReferenceDocumentsEveryComponentAndThemeIndependentRules() {
        for spec in Catalog.all { #expect(DesignGuide.reference.contains(spec.signature)) }
        #expect(DesignGuide.reference.contains("Hex colours are rejected"))
    }
}
