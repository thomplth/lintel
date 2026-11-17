import Testing
@testable import LintelCore

@Suite struct MenuBarPictureKinds {
    func picture(width: Int = 10, height: Int = 10, painting: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)?) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                guard let (r, g, b, a) = painting(x, y) else { continue }
                let offset = (y * width + x) * 4
                bytes[offset] = r
                bytes[offset + 1] = g
                bytes[offset + 2] = b
                bytes[offset + 3] = a
            }
        }
        return bytes
    }

    @Test func aTransparentPictureIsEmpty() {
        #expect(MenuBarPicture.kind(rgba: picture { _, _ in nil }, width: 10, height: 10) == .empty)
    }

    @Test func aFaintBackgroundLeftByARemovedItemIsEmpty() {
        let faint = picture { _, _ in (20, 20, 20, 40) }
        #expect(MenuBarPicture.kind(rgba: faint, width: 10, height: 10) == .empty)
    }

    @Test func whiteGlyphsAreMonochrome() {
        let glyph = picture { x, _ in x < 4 ? (255, 255, 255, 255) : nil }
        #expect(MenuBarPicture.kind(rgba: glyph, width: 10, height: 10) == .monochrome)
    }

    @Test func darkGlyphsOnALightMenuBarAreMonochrome() {
        let glyph = picture { x, _ in x < 4 ? (0, 0, 0, 230) : nil }
        #expect(MenuBarPicture.kind(rgba: glyph, width: 10, height: 10) == .monochrome)
    }

    @Test func aPictureWithColouredInkIsColour() {
        let badge = picture { x, y in
            if x < 3 { return (255, 255, 255, 255) }
            return y < 3 && x < 6 ? (230, 60, 40, 255) : nil
        }
        #expect(MenuBarPicture.kind(rgba: badge, width: 10, height: 10) == .colour)
    }

    @Test func colourIsJudgedOnUnpremultipliedInk() {
        let halfTransparentRed = picture { x, _ in x < 5 ? (110, 15, 10, 160) : nil }
        #expect(MenuBarPicture.kind(rgba: halfTransparentRed, width: 10, height: 10) == .colour)
    }

    @Test func aFewTintedEdgePixelsFromSmoothingStayMonochrome() {
        let glyph = picture { x, y in
            if x < 6 { return (255, 255, 255, 255) }
            return x == 6 && y == 0 ? (200, 180, 120, 200) : nil
        }
        #expect(MenuBarPicture.kind(rgba: glyph, width: 10, height: 10) == .monochrome)
    }
}
