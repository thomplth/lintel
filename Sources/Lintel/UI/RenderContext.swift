import AppKit
import LintelCore
import SwiftUI

enum SurfaceMaterial: Equatable {
    case halo
    case glass
    case solid
    case bare

    init(idle name: String) {
        switch name {
        case "glass": self = .glass
        case "solid": self = .solid
        case "none": self = .bare
        default: self = .halo
        }
    }

    init(active name: String) {
        switch name {
        case "solid": self = .solid
        case "plain": self = .halo
        default: self = .glass
        }
    }
}

/// Resolves the design system's tokens (roles, tones, spacing) into what SwiftUI draws, for one surface and material.
struct RenderContext {
    var theme: Theme
    var metrics: Metrics
    var surface: Surface
    var material: SurfaceMaterial
    var moduleID: String
    var manifest: ModuleManifest?
    var perform: (String, JSONValue) -> Void = { _, _ in }
    var performForResult: (String, JSONValue) async -> JSONValue = { _, _ in .null }

    init(theme: Theme, surface: Surface, material: SurfaceMaterial, moduleID: String = "", manifest: ModuleManifest? = nil) {
        self.theme = theme
        metrics = Metrics(theme)
        self.surface = surface
        self.material = material
        self.moduleID = moduleID
        self.manifest = manifest
    }

    static func color(hex: String) -> Color {
        HexColor(hex).map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .white
    }

    var primary: Color {
        material == .glass ? .primary : Self.color(hex: theme.textColor)
    }

    var secondary: Color { primary.opacity(surface == .chip && material != .glass ? 0.78 : 0.62) }
    var tertiary: Color { primary.opacity(0.4) }
    var accent: Color { Self.color(hex: theme.accentColor) }
    var fill: Color { primary.opacity(0.08) }
    var strongFill: Color { primary.opacity(0.14) }
    var separator: Color { primary.opacity(0.12) }

    var onAccent: Color {
        (HexColor(theme.accentColor)?.luminance ?? 0) > 0.55 ? .black : .white
    }

    /// Text placed on a solid fill of the given tone, as in a badge.
    func textColor(on tone: Tone?) -> Color {
        switch tone {
        case nil, .accent: return onAccent
        case .primary:
            if material == .glass { return Color(nsColor: .windowBackgroundColor) }
            return (HexColor(theme.textColor)?.luminance ?? 1) > 0.5 ? .black : .white
        case .yellow, .mint, .cyan: return .black
        default: return .white
        }
    }

    /// A tone drawn as text or a line. Over the dark halo, coloured tones are lifted to the text's lightness so they
    /// stand out from the halo as plainly as the text does.
    func color(_ tone: Tone?, fallback: Color? = nil) -> Color {
        let exact = fillColor(tone, fallback: fallback)
        guard material == .halo, let tone, tone.isColoured, let floor = theme.haloToneLightness else { return exact }
        return Self.lifted(exact, toLightness: floor)
    }

    private static func lifted(_ color: Color, toLightness floor: Double) -> Color {
        var darkScheme = EnvironmentValues()
        darkScheme.colorScheme = .dark
        let resolved = color.resolve(in: darkScheme)
        let lifted = HexColor(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
            .lifted(toLightness: floor)
        return Color(red: lifted.red, green: lifted.green, blue: lifted.blue, opacity: Double(resolved.opacity))
    }

    /// A tone painted as a solid area, such as a badge, whose own text is chosen against its exact colour.
    func fillColor(_ tone: Tone?, fallback: Color? = nil) -> Color {
        switch tone {
        case nil: fallback ?? primary
        case .primary: primary
        case .secondary: secondary
        case .tertiary: tertiary
        case .accent: accent
        case .good, .green: .green
        case .warn, .orange: .orange
        case .bad, .red: .red
        case .info, .blue: .blue
        case .yellow: .yellow
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    var design: Font.Design {
        switch theme.fontDesign {
        case "rounded": .rounded
        case "monospaced": .monospaced
        case "serif": .serif
        default: .default
        }
    }

    func weight(_ name: String?) -> Font.Weight {
        switch name ?? theme.fontWeight {
        case "light": .light
        case "regular": .regular
        case "semibold": .semibold
        case "bold": .bold
        default: .medium
        }
    }

    func font(role: String? = nil, weight name: String? = nil, mono: Bool = false) -> Font {
        let resolved: Font.Weight = if let name {
            weight(name)
        } else {
            switch role {
            case "title", "display": .semibold
            case "caption", "label": theme.fontWeight == "light" ? .light : .regular
            default: weight(nil)
            }
        }
        let font = Font.system(size: metrics.fontSize(role: role), weight: resolved, design: role == "display" && theme.fontDesign == "default" ? .rounded : design)
        return mono ? font.monospacedDigit() : font
    }

    var symbolMode: SymbolRenderingMode {
        switch theme.symbolStyle {
        case "hierarchical": .hierarchical
        case "multicolor": .multicolor
        default: .monochrome
        }
    }

    var animates: Bool { theme.motion == "full" }

    var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.tileCornerRadius, style: .continuous)
    }

    var chipShape: AnyShape {
        if let radius = metrics.chipCornerRadius {
            AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            AnyShape(Capsule())
        }
    }

    var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.panelCornerRadius, style: .continuous)
    }

    var surfaceFill: Color {
        Self.color(hex: theme.surfaceColor).opacity(theme.surfaceOpacity)
    }

    /// Panels on the solid material take their scheme from the surface so system controls stay legible on it.
    var colorScheme: ColorScheme? {
        if surface == .panel, theme.panelMaterial == "solid" || material == .solid {
            return (HexColor(theme.surfaceColor)?.luminance ?? 0) > 0.5 ? .light : .dark
        }
        switch theme.colorScheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    static func symbol(_ name: String) -> String {
        SymbolNames.exists(name) ? name : "questionmark.square.dashed"
    }
}

struct SurfaceBackground<Outline: Shape>: ViewModifier {
    let context: RenderContext
    let material: SurfaceMaterial
    let shape: Outline
    var isInteractive = false

    // One chain for every material rather than a switch: a switch gives each material its own view, so a chip whose
    // material changes as the bar opens or closes would be replaced where it stands instead of moving with the bar.
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(material == .halo ? context.theme.shadowOpacity : 0), radius: material == .halo ? Metrics(context.theme).haloShadowRadius : 0)
            .background(material == .solid ? AnyShapeStyle(context.surfaceFill) : AnyShapeStyle(.clear), in: shape)
            .overlay(shape.stroke(context.primary.opacity(material == .solid ? 0.1 : 0), lineWidth: 0.5))
            .glassEffect(material == .glass ? isInteractive ? .regular.interactive() : .regular : .identity, in: shape)
    }
}
