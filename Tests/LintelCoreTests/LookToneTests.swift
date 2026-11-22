import Testing
@testable import LintelCore

private func parse(tone: JSONValue) -> ParsedView {
    ViewNode.parse(["type": "text", "value": "x", "tone": tone])
}

@Suite struct LookTones {
    @Test func aPlainToneAppliesToEveryLookAndIsAdaptedToIt() {
        let choice = parse(tone: "orange").node?.tone()
        for look in Look.allCases {
            #expect(choice?.resolved(for: look) == ResolvedTone(tone: .orange, isChosenForLook: false))
        }
    }

    @Test func aToneNamedForALookIsUsedExactlyThere() {
        let choice = parse(tone: ["halo": "warn", "otherwise": "orange"]).node?.tone()
        #expect(choice?.resolved(for: .halo) == ResolvedTone(tone: .warn, isChosenForLook: true))
        #expect(choice?.resolved(for: .glass) == ResolvedTone(tone: .orange, isChosenForLook: false))
    }

    @Test func aLookWithoutAToneFallsBackToNoTone() {
        let choice = parse(tone: ["glass": "orange"]).node?.tone()
        #expect(choice?.resolved(for: .halo) == nil)
        #expect(choice?.resolved(for: .glass)?.tone == .orange)
    }

    @Test func perLookTonesAcceptAliases() {
        let choice = parse(tone: ["solid": "danger"]).node?.tone()
        #expect(choice?.resolved(for: .solid)?.tone == .bad)
    }

    @Test func anUnknownLookIsAnErrorThatListsTheRealOnes() {
        let errors = parse(tone: ["menubar": "red"]).errors
        #expect(errors.count == 1)
        #expect(errors.first?.contains("menubar") == true)
        #expect(errors.first?.contains("halo, glass, solid, none, otherwise") == true)
    }

    @Test func aRawColourForALookIsAnError() {
        let errors = parse(tone: ["halo": "#FF0000"]).errors
        #expect(errors.first?.contains("#FF0000") == true)
    }

    @Test func anEmptyPerLookToneIsAnError() {
        #expect(!parse(tone: [:]).errors.isEmpty)
    }

    @Test func theDefaultThemeIsHaloIdleAndGlassWhenOpen() {
        #expect(Theme().idleLook == .halo)
        #expect(Theme().activeLook == .glass)
    }

    @Test func aPlainActiveMaterialIsTheHaloLook() {
        var theme = Theme()
        theme.activeMaterial = "plain"
        #expect(theme.activeLook == .halo)
    }

    @Test func theAssistantHearsAboutHaloLighteningWhenTheThemeUsesTheHalo() throws {
        let note = try #require(DesignGuide.lookNote(for: Theme()))
        #expect(note.contains("halo"))
        #expect(note.contains("idle"))
    }

    @Test func theAssistantHearsNothingAboutTheHaloWhenTheThemeNeverUsesIt() {
        #expect(DesignGuide.lookNote(for: Theme.preset("ink")!) == nil)
        #expect(DesignGuide.lookNote(for: Theme.preset("adaptive")!) == nil)
    }

    @Test func adaptiveMaterialMapsToTheGlassLook() {
        let theme = Theme.preset("adaptive")!
        #expect(theme.idleLook == .glass)
        #expect(theme.activeLook == .glass)
    }

    @Test func theFixedGuideNoLongerAssumesTheHalo() {
        #expect(!DesignGuide.reference.contains("lightened"))
        #expect(DesignGuide.reference.contains("otherwise"))
    }
}
