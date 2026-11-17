import Testing
@testable import LintelCore

private let orange = HexColor(red: 1, green: 0.624, blue: 0.039)
private let red = HexColor(red: 1, green: 0.271, blue: 0.227)
private let black = HexColor(red: 0, green: 0, blue: 0)

@Suite struct HaloTones {
    @Test func aMidToneIsLiftedToTheFloorLightness() {
        let lifted = orange.lifted(toLightness: 0.86)
        #expect(abs(lifted.lightness - 0.86) < 0.01)
    }

    @Test func liftingKeepsTheHue() {
        for color in [orange, red] {
            let lifted = color.lifted(toLightness: 0.86)
            #expect(abs(lifted.hue - color.hue) < 0.05)
        }
    }

    @Test func liftingStandsFurtherFromTheDarkHalo() {
        #expect(red.lifted(toLightness: 0.86).contrast(with: black) > red.contrast(with: black) * 1.5)
    }

    @Test func aLiftedColourStaysVisiblyColoured() {
        #expect(red.lifted(toLightness: 0.86).chroma > 0.05)
    }

    @Test func aLiftedColourStaysInsideTheDisplayGamut() {
        let lifted = red.lifted(toLightness: 0.95)
        for channel in [lifted.red, lifted.green, lifted.blue] {
            #expect((0...1).contains(channel))
        }
    }

    @Test func aColourAlreadyLightEnoughIsUnchanged() {
        let pale = HexColor(red: 1, green: 0.95, blue: 0.6)
        #expect(pale.lifted(toLightness: 0.86) == pale)
    }

    @Test func greyIsLiftedToALighterGrey() {
        let lifted = HexColor(red: 0.5, green: 0.5, blue: 0.5).lifted(toLightness: 0.86)
        #expect(lifted.chroma < 0.001)
        #expect(lifted.red > 0.5)
    }

    @Test func theDefaultLightTextLiftsTonesOverTheHalo() {
        #expect(Theme().haloToneLightness == HexColor.haloToneCeiling)
    }

    @Test func dimLightTextLiftsTonesOnlyAsFarAsItself() throws {
        var theme = Theme()
        theme.textColor = "#C8C8C8"
        let floor = try #require(theme.haloToneLightness)
        #expect(abs(floor - HexColor(theme.textColor)!.lightness) < 0.001)
    }

    @Test func darkTextLeavesTonesAsTheyAre() {
        var theme = Theme()
        theme.textColor = "#1D1D1F"
        #expect(theme.haloToneLightness == nil)
    }

    @Test func onlyTonesWithAColourOfTheirOwnAreLifted() {
        #expect(Tone.allCases.filter { !$0.isColoured } == [.primary, .secondary, .tertiary])
    }
}
