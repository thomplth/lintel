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

    func color(_ tone: Tone?, fallback: Color? = nil) -> Color {
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
        NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "questionmark.square.dashed" : name
    }
}

/// The idle look: nothing behind the text but a dark halo, so it stays legible on any window or wallpaper.
struct Halo: ViewModifier {
    let theme: Theme

    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(theme.shadowOpacity), radius: theme.shadowBlur)
            .shadow(color: .black.opacity(theme.shadowOpacity), radius: theme.shadowBlur / 2)
    }
}

struct SurfaceBackground<Outline: Shape>: ViewModifier {
    let context: RenderContext
    let material: SurfaceMaterial
    let shape: Outline
    var isInteractive = false

    func body(content: Content) -> some View {
        switch material {
        case .glass:
            content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
        case .solid:
            content.background(context.surfaceFill, in: shape)
                .overlay(shape.stroke(context.primary.opacity(0.1), lineWidth: 0.5))
        case .halo:
            content.modifier(Halo(theme: context.theme))
        case .bare:
            content
        }
    }
}
