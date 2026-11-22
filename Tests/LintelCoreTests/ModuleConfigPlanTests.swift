import CoreGraphics
import Testing
@testable import LintelCore

@Suite struct ModuleConfigPlanTests {
    @Test func splitsTopLevelSectionsIntoNativeWindowCards() {
        let tree = ViewNode(.column, [:], [
            ViewNode(.section, ["title": "Time in the bar"], [
                ViewNode(.toggle, ["label": "Show time", "on": .bool(true), "action": "setShowTime"]),
                ViewNode(.segmented, ["options": .array(["24-hour", "12-hour"]), "selected": "24-hour", "action": "setHours"]),
            ]),
            ViewNode(.section, ["title": "Repositories", "trailing": "All"], [
                ViewNode(.list, [:], [
                    ViewNode(.item, ["title": "org/repo", "action": "toggleRepo"]),
                ]),
                ViewNode(.field, ["placeholder": "Add repo", "action": "addRepo"]),
            ]),
        ])

        let sections = ModuleConfigPlan.sections(from: tree)
        #expect(sections.count == 2)
        #expect(sections[0].title == "Time in the bar")
        #expect(sections[0].trailing == nil)
        #expect(sections[0].items.count == 2)
        #expect(!sections[0].isActionRow)

        #expect(sections[1].title == "Repositories")
        #expect(sections[1].trailing == "All")
        #expect(sections[1].items.count == 2)
        #expect(!sections[1].isActionRow)
    }

    @Test func groupsTrailingStandaloneButtonsIntoAnActionRow() {
        let tree = ViewNode(.column, [:], [
            ViewNode(.section, ["title": "Location"], [
                ViewNode(.keyValue, ["label": "Current place", "value": "Tokyo"]),
                ViewNode(.field, ["placeholder": "Change place", "action": "setPlace"]),
            ]),
            ViewNode(.button, ["label": "Refresh forecast", "action": "retry", "icon": "arrow.clockwise"]),
        ])

        let sections = ModuleConfigPlan.sections(from: tree)
        #expect(sections.count == 2)
        #expect(sections[0].title == "Location")
        #expect(!sections[0].isActionRow)
        #expect(sections[1].isActionRow)
        #expect(sections[1].items.count == 1)
        #expect(sections[1].items[0].component == .button)
    }

    @Test func wrapsFlatUnsectionedControlsIntoAConfigurationCard() {
        let tree = ViewNode(.column, [:], [
            ViewNode(.toggle, ["label": "Flag", "on": .bool(true), "action": "flip"]),
            ViewNode(.slider, ["value": .number(0.5), "action": "slide", "label": "Level"]),
        ])

        let sections = ModuleConfigPlan.sections(from: tree)
        #expect(sections.count == 1)
        #expect(sections[0].title == "Configuration")
        #expect(!sections[0].isActionRow)
        #expect(sections[0].items.count == 2)
    }

    @Test func dividerRulesSkipExplanatoryNotesAndExplicitDividers() {
        let toggle = ViewNode(.toggle, ["label": "A", "on": .bool(true), "action": "a"])
        let segmented = ViewNode(.segmented, ["options": .array(["A", "B"]), "selected": "A", "action": "b"])
        let plainNote = ViewNode(.note, ["value": "Explains the setting above."])
        let warnNote = ViewNode(.note, ["value": "Invalid input.", "tone": "warn"])
        let divider = ViewNode(.divider, [:])

        #expect(ModuleConfigPlan.needsDivider(between: toggle, and: segmented))
        #expect(!ModuleConfigPlan.needsDivider(between: segmented, and: plainNote))
        #expect(ModuleConfigPlan.needsDivider(between: plainNote, and: toggle))
        #expect(ModuleConfigPlan.needsDivider(between: segmented, and: warnNote))
        #expect(!ModuleConfigPlan.needsDivider(between: toggle, and: divider))
        #expect(!ModuleConfigPlan.needsDivider(between: divider, and: toggle))
    }

    @Test func previewMetricsResolvesBoxAndFitScale() {
        let metrics = Metrics(Theme.preset("glass")!)

        // Prefers active widget box over remembered panel size over default shape.
        let activeBox = WidgetBox(width: 240, height: 190)
        let remembered = WidgetBox(width: 400, height: 320)
        #expect(ModulePreviewMetrics.resolvedBox(widgetBox: activeBox, panelSize: remembered, defaultShape: .card, metrics: metrics) == activeBox)
        #expect(ModulePreviewMetrics.resolvedBox(widgetBox: nil, panelSize: remembered, defaultShape: .card, metrics: metrics) == remembered)
        #expect(ModulePreviewMetrics.resolvedBox(widgetBox: nil, panelSize: nil, defaultShape: .compact, metrics: metrics) == metrics.defaultWidgetBox(for: .compact))

        // Scale stays 1 when the card fits inside the preview stage, and shrinks proportionally when wider/taller.
        #expect(ModulePreviewMetrics.fitScale(box: CGSize(width: 300, height: 240), in: CGSize(width: 500, height: 400)) == 1.0)
        let scaled = ModulePreviewMetrics.fitScale(box: CGSize(width: 600, height: 300), in: CGSize(width: 450, height: 400))
        #expect(abs(scaled - 0.75) < 0.0001)
    }
}
