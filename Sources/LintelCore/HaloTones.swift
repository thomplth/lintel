import Foundation

extension HexColor {
    /// The lightest a tone is lifted to over the halo: light enough to read like white text, dark enough to keep its hue.
    public static let haloToneCeiling = 0.86
    static let lightTextThreshold = 0.6

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var lightness: Double { OKLCh(self).lightness }
    public var chroma: Double { OKLCh(self).chroma }
    public var hue: Double { OKLCh(self).hue }

    /// The same hue at the given perceptual lightness, giving up chroma only where the display cannot show it.
    public func lifted(toLightness floor: Double) -> HexColor {
        let color = OKLCh(self)
        guard color.lightness < floor else { return self }
        var inGamut = 0.0, outOfGamut = color.chroma
        if let full = OKLCh(lightness: floor, chroma: outOfGamut, hue: color.hue).displayable { return full }
        for _ in 0..<24 {
            let chroma = (inGamut + outOfGamut) / 2
            if OKLCh(lightness: floor, chroma: chroma, hue: color.hue).displayable != nil { inGamut = chroma } else { outOfGamut = chroma }
        }
        return OKLCh(lightness: floor, chroma: inGamut, hue: color.hue).displayable ?? self
    }
}

extension Theme {
    /// The lightness tones are lifted to over the dark halo, or nil when the text is dark and the halo cannot help it.
    public var haloToneLightness: Double? {
        guard let text = HexColor(textColor)?.lightness, text >= HexColor.lightTextThreshold else { return nil }
        return min(text, HexColor.haloToneCeiling)
    }
}

private struct OKLCh {
    var lightness: Double
    var chroma: Double
    var hue: Double

    init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    init(_ color: HexColor) {
        let (r, g, b) = (Self.linear(color.red), Self.linear(color.green), Self.linear(color.blue))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bAxis = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        chroma = hypot(a, bAxis)
        hue = atan2(bAxis, a)
    }

    var displayable: HexColor? {
        let a = chroma * cos(hue), b = chroma * sin(hue)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let channels = [
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
        ]
        let tolerance = 1e-6
        guard channels.allSatisfy({ (-tolerance...(1 + tolerance)).contains($0) }) else { return nil }
        let encoded = channels.map { Self.encoded(min(max($0, 0), 1)) }
        return HexColor(red: encoded[0], green: encoded[1], blue: encoded[2])
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ channel: Double) -> Double {
        channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
    }
}
