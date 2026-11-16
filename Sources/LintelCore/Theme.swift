import Foundation

public struct Theme: Equatable, Encodable, Sendable {
    public var preset = "halo"
    public var fontSize = 14.0
    public var fontWeight = "medium"
    public var fontDesign = "default"
    public var textColor = "#FFFFFF"
    public var accentColor = "#0A84FF"
    public var density = "regular"
    public var moduleSpacing = 14.0
    public var rowSpacing = 4.0
    public var idleMaterial = "halo"
    public var activeMaterial = "glass"
    public var panelMaterial = "glass"
    public var surfaceColor = "#1C1C1E"
    public var surfaceOpacity = 0.9
    public var cornerStyle = "capsule"
    public var shadowBlur = 3.0
    public var shadowOpacity = 0.9
    public var idleOpacity = 1.0
    public var colorScheme = "auto"
    public var symbolStyle = "monochrome"
    public var motion = "full"

    public init() {}

    public struct Field: Sendable {
        public enum Kind: Sendable {
            case number(ClosedRange<Double>, WritableKeyPath<Theme, Double> & Sendable)
            case choice([String], WritableKeyPath<Theme, String> & Sendable)
            case color(WritableKeyPath<Theme, String> & Sendable)
        }

        public let name: String
        public let kind: Kind
        public let doc: String

        public var summary: String {
            switch kind {
            case .number(let range, _): "\(name) (\(Self.trim(range.lowerBound))-\(Self.trim(range.upperBound))): \(doc)"
            case .choice(let options, _): "\(name) (\(options.joined(separator: "|"))): \(doc)"
            case .color: "\(name) (#RRGGBB): \(doc)"
            }
        }

        private static func trim(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }
    }

    public static let fields: [Field] = [
        Field(name: "preset", kind: .choice(presetNames, \.preset), doc: "Starts from a whole design language; other fields in the same change apply on top."),
        Field(name: "fontSize", kind: .number(9...32, \.fontSize), doc: "Text size in points. Bigger text is a larger number."),
        Field(name: "fontWeight", kind: .choice(Catalog.weights, \.fontWeight), doc: "Text weight."),
        Field(name: "fontDesign", kind: .choice(["default", "rounded", "monospaced", "serif"], \.fontDesign), doc: "Typeface family."),
        Field(name: "textColor", kind: .color(\.textColor), doc: "Text colour on the halo and solid materials."),
        Field(name: "accentColor", kind: .color(\.accentColor), doc: "Colour of the accent tone, primary buttons and charts."),
        Field(name: "density", kind: .choice(["compact", "regular", "roomy"], \.density), doc: "Padding inside chips and panels. Tighter is compact; airier is roomy."),
        Field(name: "moduleSpacing", kind: .number(0...40, \.moduleSpacing), doc: "Gap between neighbouring items in a row. Tighter is a smaller number."),
        Field(name: "rowSpacing", kind: .number(0...40, \.rowSpacing), doc: "Gap between rows of the bar."),
        Field(name: "idleMaterial", kind: .choice(["halo", "glass", "solid", "none"], \.idleMaterial), doc: "Look while idle: halo is plain text with a shadow; glass and solid give every item a capsule; none is bare text."),
        Field(name: "activeMaterial", kind: .choice(["glass", "solid", "plain"], \.activeMaterial), doc: "Look while the pointer is on the bar."),
        Field(name: "panelMaterial", kind: .choice(["glass", "solid"], \.panelMaterial), doc: "Background of panels."),
        Field(name: "surfaceColor", kind: .color(\.surfaceColor), doc: "Fill of the solid material."),
        Field(name: "surfaceOpacity", kind: .number(0.3...1, \.surfaceOpacity), doc: "Opacity of the solid material."),
        Field(name: "cornerStyle", kind: .choice(["capsule", "rounded", "square"], \.cornerStyle), doc: "Corner shape of chips, tiles and panels."),
        Field(name: "shadowBlur", kind: .number(0...12, \.shadowBlur), doc: "Blur radius of the halo behind idle text. Softer is larger."),
        Field(name: "shadowOpacity", kind: .number(0...1, \.shadowOpacity), doc: "Darkness of the halo."),
        Field(name: "idleOpacity", kind: .number(0.2...1, \.idleOpacity), doc: "Opacity of the whole bar while idle. Subtler is smaller."),
        Field(name: "colorScheme", kind: .choice(["auto", "light", "dark"], \.colorScheme), doc: "Light or dark panels; auto follows macOS."),
        Field(name: "symbolStyle", kind: .choice(["monochrome", "hierarchical", "multicolor"], \.symbolStyle), doc: "How icons are coloured."),
        Field(name: "motion", kind: .choice(["full", "reduced"], \.motion), doc: "Animated number changes and transitions, or none."),
    ]

    public static let presetNames = ["halo", "glass", "ink", "paper", "terminal"]

    public static func preset(_ name: String) -> Theme? {
        var theme = Theme()
        theme.preset = name
        switch name {
        case "halo":
            break
        case "glass":
            theme.idleMaterial = "glass"
            theme.moduleSpacing = 8
        case "ink":
            theme.idleMaterial = "solid"
            theme.activeMaterial = "solid"
            theme.panelMaterial = "solid"
            theme.surfaceColor = "#101012"
            theme.surfaceOpacity = 0.94
            theme.colorScheme = "dark"
            theme.moduleSpacing = 8
            theme.fontDesign = "rounded"
        case "paper":
            theme.idleMaterial = "solid"
            theme.activeMaterial = "solid"
            theme.panelMaterial = "solid"
            theme.surfaceColor = "#FBFAF6"
            theme.surfaceOpacity = 0.96
            theme.textColor = "#1D1D1F"
            theme.accentColor = "#C2410C"
            theme.colorScheme = "light"
            theme.cornerStyle = "rounded"
            theme.moduleSpacing = 8
            theme.fontDesign = "serif"
        case "terminal":
            theme.fontDesign = "monospaced"
            theme.fontWeight = "regular"
            theme.fontSize = 13
            theme.textColor = "#8CFFB5"
            theme.accentColor = "#8CFFB5"
            theme.idleMaterial = "solid"
            theme.moduleSpacing = 6
            theme.activeMaterial = "solid"
            theme.panelMaterial = "solid"
            theme.surfaceColor = "#0A0F0C"
            theme.surfaceOpacity = 0.95
            theme.cornerStyle = "square"
            theme.colorScheme = "dark"
        default:
            return nil
        }
        return theme
    }

    /// Applies only what is valid, so a bad edit can never leave the bar unusable.
    public func applying(_ patch: [String: JSONValue]) -> Theme {
        var theme = self
        if let name = patch["preset"]?.string, let preset = Theme.preset(name) { theme = preset }
        for field in Theme.fields where field.name != "preset" {
            guard let value = patch[field.name] else { continue }
            switch field.kind {
            case .number(let range, let path):
                if let number = value.number { theme[keyPath: path] = min(max(number, range.lowerBound), range.upperBound) }
            case .choice(let options, let path):
                if let choice = value.string, options.contains(choice) { theme[keyPath: path] = choice }
            case .color(let path):
                if let color = value.string, HexColor(color) != nil { theme[keyPath: path] = color.uppercased() }
            }
        }
        return theme
    }

    public var patch: [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for field in Theme.fields {
            switch field.kind {
            case .number(_, let path): result[field.name] = .number(self[keyPath: path])
            case .choice(_, let path), .color(let path): result[field.name] = .string(self[keyPath: path])
            }
        }
        return result
    }
}

extension Theme: Decodable {
    public init(from decoder: Decoder) throws {
        self = Theme().applying(try [String: JSONValue](from: decoder))
    }
}

public struct HexColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init?(_ text: String) {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    public var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrast(with other: HexColor) -> Double {
        let lighter = max(luminance, other.luminance), darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// Every size on screen derives from the theme here, so modules never carry numbers of their own.
public struct Metrics: Equatable, Sendable {
    public let theme: Theme

    public init(_ theme: Theme) {
        self.theme = theme
    }

    public var unit: Double {
        switch theme.density {
        case "compact": 3
        case "roomy": 5
        default: 4
        }
    }

    public func fontSize(role: String?) -> Double {
        switch role {
        case "label": (theme.fontSize * 0.86).rounded()
        case "caption": max(10, (theme.fontSize * 0.76).rounded())
        case "title": (theme.fontSize * 1.05).rounded()
        case "display": (theme.fontSize * 1.9).rounded()
        default: theme.fontSize
        }
    }

    public func spacing(_ token: String?) -> Double {
        switch token {
        case "none": 0
        case "tight": unit
        case "loose": unit * 4
        default: unit * 2
        }
    }

    public var chipPaddingHorizontal: Double { unit * 2.5 }
    public var chipPaddingVertical: Double { unit }
    public var chipContentSpacing: Double { max(3, unit * 1.25) }
    public var panelPadding: Double { unit * 3.5 }
    public var sectionSpacing: Double { unit * 3.5 }
    public var tilePadding: Double { unit * 2.5 }

    public var panelCornerRadius: Double {
        switch theme.cornerStyle {
        case "rounded": 14
        case "square": 6
        default: 22
        }
    }

    public var tileCornerRadius: Double {
        switch theme.cornerStyle {
        case "rounded": 9
        case "square": 3
        default: 12
        }
    }

    /// Nil means a capsule.
    public var chipCornerRadius: Double? {
        switch theme.cornerStyle {
        case "rounded": 8
        case "square": 3
        default: nil
        }
    }

    public func panelWidth(_ size: String?) -> Double {
        let scale = max(theme.fontSize, 12) / 14
        switch size {
        case "small": return (270 * scale).rounded()
        case "large": return (460 * scale).rounded()
        default: return (350 * scale).rounded()
        }
    }

    public func blockHeight(_ size: String?) -> Double {
        switch size {
        case "small": 64
        case "large": 240
        case "tall": 380
        default: 120
        }
    }
}
