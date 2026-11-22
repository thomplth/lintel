import CoreGraphics
import Testing
@testable import LintelCore

@Suite struct AdaptiveBackdropTests {
    @Test func brightBackdropResolvesToLightAndDarkToDark() {
        #expect(AdaptiveBackdrop.resolveTone(luminance: 1.0, previous: nil) == .light)
        #expect(AdaptiveBackdrop.resolveTone(luminance: 0.9, previous: nil) == .light)
        #expect(AdaptiveBackdrop.resolveTone(luminance: 0.0, previous: nil) == .dark)
        #expect(AdaptiveBackdrop.resolveTone(luminance: 0.05, previous: nil) == .dark)
    }

    @Test func hysteresisPreventsFlickeringNearMidtones() {
        // Starting light: stays light inside deadband (0.14..<0.24), only flips dark at <= 0.14.
        #expect(AdaptiveBackdrop.resolveTone(luminance: 0.20, previous: .light) == .light)
        #expect(AdaptiveBackdrop.resolveTone(luminance: 0.16, previous: .light) == .light)
        #expect(AdaptiveBackdrop.resolveTone(luminance: 0.13, previous: .light) == .dark)

        // Starting dark: stays dark inside deadband, only flips light at >= 0.24.
        #expect(AdaptiveBackdrop.resolveTone(luminance: 0.16, previous: .dark) == .dark)
        #expect(AdaptiveBackdrop.resolveTone(luminance: 0.22, previous: .dark) == .dark)
        #expect(AdaptiveBackdrop.resolveTone(luminance: 0.25, previous: .dark) == .light)
    }

    @Test func whiteAndBlackBackdropsProduceCleanWhiteAndBlackTints() {
        let white = AdaptiveBackdrop.surface(for: BackdropSample(red: 1, green: 1, blue: 1))
        #expect(white.tone == .light)
        #expect(white.tint.red > 0.95 && white.tint.green > 0.95 && white.tint.blue > 0.95)

        let black = AdaptiveBackdrop.surface(for: BackdropSample(red: 0.03, green: 0.03, blue: 0.03))
        #expect(black.tone == .dark)
        #expect(black.tint.red < 0.08 && black.tint.green < 0.08 && black.tint.blue < 0.08)
    }

    @Test func colouredBackdropsKeepSubtleHueWhileProtectingTextContrast() {
        // Deep navy dark window -> dark glass tint with subtle blue hue and high contrast for white text.
        let navy = BackdropSample(red: 0.086, green: 0.141, blue: 0.278)
        let darkSurface = AdaptiveBackdrop.surface(for: navy)
        #expect(darkSurface.tone == .dark)
        #expect(darkSurface.tint.blue > darkSurface.tint.red)
        #expect(darkSurface.tint.contrast(with: HexColor(red: 1, green: 1, blue: 1)) >= 10)

        // Bright saturated orange wallpaper -> light glass tint lifted for crisp dark text legibility.
        let orange = BackdropSample(red: 0.98, green: 0.62, blue: 0.32)
        let lightSurface = AdaptiveBackdrop.surface(for: orange)
        #expect(lightSurface.tone == .light)
        #expect(lightSurface.tint.red >= lightSurface.tint.blue)
        #expect(lightSurface.tint.contrast(with: HexColor(red: 0, green: 0, blue: 0)) >= 12)
    }

    @Test func tinyDriftWithSameToneIsSuppressedByChangeDeadband() {
        let first = AdaptiveBackdrop.surface(for: BackdropSample(red: 0.12, green: 0.12, blue: 0.14))
        let drifted = AdaptiveBackdrop.surface(for: BackdropSample(red: 0.125, green: 0.123, blue: 0.145), previous: first)
        #expect(drifted == first)

        let switched = AdaptiveBackdrop.surface(for: BackdropSample(red: 0.95, green: 0.95, blue: 0.95), previous: first)
        #expect(switched.tone == .light)
        #expect(switched != first)
    }

    @Test func regionSamplingDistinguishesSplitLightAndDarkHalf() throws {
        // 4x2 RGBA buffer: left 2 columns white, right 2 columns near-black.
        let width = 4, height = 2
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let v: UInt8 = x < 2 ? 250 : 12
                rgba[offset] = v
                rgba[offset + 1] = v
                rgba[offset + 2] = v
                rgba[offset + 3] = 255
            }
        }
        let left = try #require(AdaptiveBackdrop.sample(rgba: rgba, width: width, height: height, region: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        let right = try #require(AdaptiveBackdrop.sample(rgba: rgba, width: width, height: height, region: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        #expect(AdaptiveBackdrop.surface(for: left).tone == .light)
        #expect(AdaptiveBackdrop.surface(for: right).tone == .dark)
    }

    @Test func emptyOrInvalidBuffersReturnNilSample() {
        #expect(AdaptiveBackdrop.sample(rgba: [], width: 0, height: 0, region: CGRect(x: 0, y: 0, width: 1, height: 1)) == nil)
        #expect(AdaptiveBackdrop.sample(rgba: [0, 0, 0, 255], width: 2, height: 2, region: CGRect(x: 0, y: 0, width: 1, height: 1)) == nil)
    }
}
