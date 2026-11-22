import CoreGraphics
import Foundation

/// Average sRGB colour sampled from the desktop or window pixels behind a floating surface.
public struct BackdropSample: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public var color: HexColor {
        HexColor(red: red, green: green, blue: blue)
    }

    public var luminance: Double {
        color.luminance
    }
}

/// Light or dark glass polarity chosen from the backdrop behind a capsule, widget, or panel.
public enum BackdropTone: String, Equatable, Sendable {
    case light
    case dark
}

/// Resolved adaptive Liquid Glass parameters for a single floating surface.
public struct AdaptiveSurface: Equatable, Sendable {
    public var tone: BackdropTone
    public var tint: HexColor
    public var tintOpacity: Double

    public init(tone: BackdropTone, tint: HexColor, tintOpacity: Double = AdaptiveBackdrop.defaultTintOpacity) {
        self.tone = tone
        self.tint = tint
        self.tintOpacity = tintOpacity
    }

    public static func neutral(for tone: BackdropTone) -> AdaptiveSurface {
        switch tone {
        case .light:
            AdaptiveSurface(tone: .light, tint: HexColor(red: 1, green: 1, blue: 1))
        case .dark:
            AdaptiveSurface(tone: .dark, tint: HexColor(red: 0, green: 0, blue: 0))
        }
    }
}

/// Pure, deterministic maths that turns sampled desktop pixels into non-flickering, legible adaptive Liquid Glass.
public enum AdaptiveBackdrop {
    /// Switch to dark glass at or below this WCAG relative luminance.
    public static let darkThreshold = 0.14
    /// Switch to light glass at or above this WCAG relative luminance.
    public static let lightThreshold = 0.24
    /// Initial split when no previous tone exists (WCAG equal-contrast point between black and white is ~0.179).
    public static let midpointThreshold = 0.18
    /// Subtle tint strength that blends Liquid Glass into white, black, and coloured desktops while staying translucent.
    public static let defaultTintOpacity = 0.28
    /// Suppress tint updates smaller than this per-channel delta when the tone has not flipped.
    public static let colorDeadband = 0.025
    /// Cap tint chroma in OKLCh so loud wallpapers yield calm, non-intrusive capsules.
    public static let maxTintChroma = 0.055

    public static func resolveTone(luminance: Double, previous: BackdropTone?) -> BackdropTone {
        if luminance >= lightThreshold { return .light }
        if luminance <= darkThreshold { return .dark }
        if let previous { return previous }
        return luminance >= midpointThreshold ? .light : .dark
    }

    /// Computes a gentle, background-matched tint that preserves desktop hue while keeping foreground text crisp.
    public static func tintColor(for sample: BackdropSample, tone: BackdropTone) -> HexColor {
        let range: ClosedRange<Double> = tone == .light ? 0.90...1.0 : 0.0...0.20
        return sample.color.adapted(lightnessRange: range, maxChroma: maxTintChroma)
    }

    public static func surface(for sample: BackdropSample, previous: AdaptiveSurface? = nil) -> AdaptiveSurface {
        let tone = resolveTone(luminance: sample.luminance, previous: previous?.tone)
        let tint = tintColor(for: sample, tone: tone)
        let candidate = AdaptiveSurface(tone: tone, tint: tint, tintOpacity: defaultTintOpacity)
        if let previous, previous.tone == candidate.tone {
            let delta = max(
                abs(previous.tint.red - candidate.tint.red),
                abs(previous.tint.green - candidate.tint.green),
                abs(previous.tint.blue - candidate.tint.blue)
            )
            if delta < colorDeadband { return previous }
        }
        return candidate
    }

    /// Averages a normalised sub-region `(0...1, 0...1)` (top-left origin) of a premultiplied-last sRGB RGBA buffer.
    public static func sample(rgba: [UInt8], width: Int, height: Int, region: CGRect) -> BackdropSample? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let minX = max(0, min(width - 1, Int(floor(region.minX * Double(width)))))
        let maxX = max(minX + 1, min(width, Int(ceil(region.maxX * Double(width)))))
        let minY = max(0, min(height - 1, Int(floor(region.minY * Double(height)))))
        let maxY = max(minY + 1, min(height, Int(ceil(region.maxY * Double(height)))))

        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var weightSum = 0.0
        for y in minY..<maxY {
            let row = y * width
            for x in minX..<maxX {
                let offset = (row + x) * 4
                let alpha = Double(rgba[offset + 3]) / 255.0
                guard alpha > 0.01 else { continue }
                // Unpremultiply so partially transparent edge pixels do not artificially darken the sample.
                sumR += min(Double(rgba[offset]) / 255.0 / alpha, 1.0) * alpha
                sumG += min(Double(rgba[offset + 1]) / 255.0 / alpha, 1.0) * alpha
                sumB += min(Double(rgba[offset + 2]) / 255.0 / alpha, 1.0) * alpha
                weightSum += alpha
            }
        }
        guard weightSum > 0 else { return nil }
        return BackdropSample(red: sumR / weightSum, green: sumG / weightSum, blue: sumB / weightSum)
    }
}
