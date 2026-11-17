/// What a picture captured from the system menu bar holds.
public enum MenuBarPicture: Equatable, Sendable {
    /// Nothing drawn: the item was taken out of the menu bar but keeps its Accessibility frame.
    case empty
    /// Glyphs in one colour, which the bar tints to its theme like the menu bar tints them to its own.
    case monochrome
    /// Ink of its own colours, such as a recording dot or an app's badge, which must keep them.
    case colour

    private static let solidAlpha = 150
    private static let minimumSolidPixels = 8
    /// How far apart a pixel's channels must be to count as coloured rather than grey.
    private static let colourSpread = 60
    /// Text smoothing tints a glyph's edges; colour needs more coloured pixels than that leaves.
    private static let colouredShare = 0.08

    /// `rgba` holds premultiplied red, green, blue and alpha bytes, row by row.
    public static func kind(rgba: [UInt8], width: Int, height: Int) -> MenuBarPicture {
        var solid = 0, inked = 0, coloured = 0
        for offset in stride(from: 0, to: min(rgba.count, width * height * 4) - 3, by: 4) {
            let alpha = Int(rgba[offset + 3])
            guard alpha > 24 else { continue }
            inked += 1
            if alpha > solidAlpha { solid += 1 }
            let channels = (0..<3).map { Int(rgba[offset + $0]) * 255 / alpha }
            if channels.max()! - channels.min()! > colourSpread { coloured += 1 }
        }
        guard solid >= minimumSolidPixels else { return .empty }
        return Double(coloured) >= Double(inked) * colouredShare ? .colour : .monochrome
    }
}
