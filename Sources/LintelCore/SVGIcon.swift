import CoreGraphics
import Foundation

/// A monochrome vector icon parsed from `svg:<size>:<path>` or `svg:<w>x<h>:<path>`, tinted by Lintel's design tokens.
public struct SVGIcon: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)
        case close
    }

    public let width: Double
    public let height: Double
    public let segments: [Segment]

    public static let maxSpecLength = 4096

    public static func parse(_ spec: String) -> SVGIcon? {
        guard spec.hasPrefix("svg:"), spec.count <= maxSpecLength else { return nil }
        let body = spec.dropFirst(4)
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let sizePart = String(body[..<colon])
        let pathPart = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pathPart.isEmpty else { return nil }

        let width: Double
        let height: Double
        if let x = sizePart.firstIndex(of: "x") {
            guard let w = Double(sizePart[..<x]), let h = Double(sizePart[sizePart.index(after: x)...]) else { return nil }
            width = w
            height = h
        } else {
            guard let s = Double(sizePart) else { return nil }
            width = s
            height = s
        }
        guard width > 0, height > 0, width <= 1024, height <= 1024 else { return nil }
        guard let segments = PathParser.parse(pathPart), !segments.isEmpty else { return nil }
        return SVGIcon(width: width, height: height, segments: segments)
    }

    public func cgPath(in rect: CGRect) -> CGPath {
        let scale = min(rect.width / width, rect.height / height)
        let offsetX = rect.minX + (rect.width - width * scale) / 2
        let offsetY = rect.minY + (rect.height - height * scale) / 2
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: offsetX + p.x * scale, y: offsetY + p.y * scale)
        }
        let path = CGMutablePath()
        for segment in segments {
            switch segment {
            case .move(let p): path.move(to: map(p))
            case .line(let p): path.addLine(to: map(p))
            case .quad(let c, let p): path.addQuadCurve(to: map(p), control: map(c))
            case .curve(let c1, let c2, let p): path.addCurve(to: map(p), control1: map(c1), control2: map(c2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

private enum PathParser {
    static func parse(_ source: String) -> [SVGIcon.Segment]? {
        let chars = Array(source)
        var i = 0
        let count = chars.count

        func skipSeparators() {
            while i < count && (chars[i].isWhitespace || chars[i] == ",") { i += 1 }
        }

        func isCommand(_ c: Character) -> Bool {
            switch c {
            case "M", "m", "L", "l", "H", "h", "V", "v", "C", "c", "S", "s", "Q", "q", "T", "t", "A", "a", "Z", "z": true
            default: false
            }
        }

        func readNumber() -> Double? {
            skipSeparators()
            guard i < count else { return nil }
            let start = i
            if chars[i] == "+" || chars[i] == "-" { i += 1 }
            var sawDigit = false
            while i < count && chars[i].isNumber { sawDigit = true; i += 1 }
            if i < count && chars[i] == "." {
                i += 1
                while i < count && chars[i].isNumber { sawDigit = true; i += 1 }
            }
            guard sawDigit else { i = start; return nil }
            if i < count && (chars[i] == "e" || chars[i] == "E") {
                let expStart = i
                i += 1
                if i < count && (chars[i] == "+" || chars[i] == "-") { i += 1 }
                var expDigits = false
                while i < count && chars[i].isNumber { expDigits = true; i += 1 }
                if !expDigits { i = expStart }
            }
            return Double(String(chars[start..<i]))
        }

        func readFlag() -> Int? {
            skipSeparators()
            guard i < count else { return nil }
            if chars[i] == "0" { i += 1; return 0 }
            if chars[i] == "1" { i += 1; return 1 }
            return nil
        }

        var segments: [SVGIcon.Segment] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character?

        while true {
            skipSeparators()
            guard i < count else { break }
            if isCommand(chars[i]) {
                command = chars[i]
                i += 1
            } else if command == nil {
                return nil
            }
            guard let cmd = command else { return nil }
            let rel = cmd.isLowercase
            let upper = Character(cmd.uppercased())

            switch upper {
            case "M":
                guard let x = readNumber(), let y = readNumber() else { return nil }
                current = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                subpathStart = current
                segments.append(.move(current))
                lastCubicControl = nil
                lastQuadControl = nil
                // Subsequent coordinate pairs after M/m are implicit L/l.
                command = rel ? "l" : "L"

            case "L":
                guard let x = readNumber(), let y = readNumber() else { return nil }
                current = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                segments.append(.line(current))
                lastCubicControl = nil
                lastQuadControl = nil

            case "H":
                guard let x = readNumber() else { return nil }
                current = CGPoint(x: rel ? current.x + x : x, y: current.y)
                segments.append(.line(current))
                lastCubicControl = nil
                lastQuadControl = nil

            case "V":
                guard let y = readNumber() else { return nil }
                current = CGPoint(x: current.x, y: rel ? current.y + y : y)
                segments.append(.line(current))
                lastCubicControl = nil
                lastQuadControl = nil

            case "C":
                guard let x1 = readNumber(), let y1 = readNumber(),
                      let x2 = readNumber(), let y2 = readNumber(),
                      let x = readNumber(), let y = readNumber()
                else { return nil }
                let c1 = rel ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let c2 = rel ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let end = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                segments.append(.curve(c1, c2, end))
                lastCubicControl = c2
                lastQuadControl = nil
                current = end

            case "S":
                guard let x2 = readNumber(), let y2 = readNumber(),
                      let x = readNumber(), let y = readNumber()
                else { return nil }
                let c1: CGPoint = if let prev = lastCubicControl {
                    CGPoint(x: 2 * current.x - prev.x, y: 2 * current.y - prev.y)
                } else {
                    current
                }
                let c2 = rel ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let end = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                segments.append(.curve(c1, c2, end))
                lastCubicControl = c2
                lastQuadControl = nil
                current = end

            case "Q":
                guard let x1 = readNumber(), let y1 = readNumber(),
                      let x = readNumber(), let y = readNumber()
                else { return nil }
                let c = rel ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let end = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                segments.append(.quad(c, end))
                lastQuadControl = c
                lastCubicControl = nil
                current = end

            case "T":
                guard let x = readNumber(), let y = readNumber() else { return nil }
                let c: CGPoint = if let prev = lastQuadControl {
                    CGPoint(x: 2 * current.x - prev.x, y: 2 * current.y - prev.y)
                } else {
                    current
                }
                let end = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                segments.append(.quad(c, end))
                lastQuadControl = c
                lastCubicControl = nil
                current = end

            case "A":
                guard let rx = readNumber(), let ry = readNumber(),
                      let rotation = readNumber(),
                      let largeArc = readFlag(), let sweep = readFlag(),
                      let x = readNumber(), let y = readNumber()
                else { return nil }
                let end = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                segments.append(contentsOf: arcToCubics(
                    from: current, to: end, rx: rx, ry: ry,
                    xAxisRotationDegrees: rotation, largeArc: largeArc == 1, sweep: sweep == 1
                ))
                current = end
                lastCubicControl = nil
                lastQuadControl = nil

            case "Z":
                segments.append(.close)
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil
                command = nil

            default:
                return nil
            }
        }
        return segments
    }

    /// W3C SVG 1.1 F.6.5/F.6.6 endpoint-to-center elliptical arc converted into cubic Bezier curves.
    private static func arcToCubics(
        from p1: CGPoint, to p2: CGPoint, rx rawRx: Double, ry rawRy: Double,
        xAxisRotationDegrees: Double, largeArc: Bool, sweep: Bool
    ) -> [SVGIcon.Segment] {
        guard p1 != p2 else { return [] }
        var rx = abs(rawRx)
        var ry = abs(rawRy)
        guard rx > 1e-9, ry > 1e-9 else { return [.line(p2)] }

        let phi = xAxisRotationDegrees * .pi / 180.0
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let dx2 = (p1.x - p2.x) / 2.0
        let dy2 = (p1.y - p2.y) / 2.0
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1.0 {
            let root = sqrt(lambda)
            rx *= root
            ry *= root
        }

        let rx2 = rx * rx
        let ry2 = ry * ry
        let x1p2 = x1p * x1p
        let y1p2 = y1p * y1p
        let num = max(0, rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2)
        let den = rx2 * y1p2 + ry2 * x1p2
        let coef = (largeArc == sweep ? -1.0 : 1.0) * (den > 0 ? sqrt(num / den) : 0.0)
        let cxp = coef * (rx * y1p) / ry
        let cyp = coef * -(ry * x1p) / rx

        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2.0
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2.0

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let mag = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            let ratio = max(-1.0, min(1.0, mag > 0 ? dot / mag : 1.0))
            let sign = (ux * vy - uy * vx) < 0 ? -1.0 : 1.0
            return sign * acos(ratio)
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        else if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let segmentCount = max(1, Int(ceil(abs(dTheta) / (.pi / 2.0))))
        let delta = dTheta / Double(segmentCount)
        let alpha = (4.0 / 3.0) * tan(delta / 4.0)

        func pointOnEllipse(_ t: Double) -> CGPoint {
            let ex = rx * cos(t)
            let ey = ry * sin(t)
            return CGPoint(x: cosPhi * ex - sinPhi * ey + cx, y: sinPhi * ex + cosPhi * ey + cy)
        }

        func tangentOnEllipse(_ t: Double) -> CGPoint {
            let ex = -rx * sin(t)
            let ey = ry * cos(t)
            return CGPoint(x: cosPhi * ex - sinPhi * ey, y: sinPhi * ex + cosPhi * ey)
        }

        var result: [SVGIcon.Segment] = []
        for s in 0..<segmentCount {
            let t1 = theta1 + Double(s) * delta
            let t2 = t1 + delta
            let a = pointOnEllipse(t1)
            let b = pointOnEllipse(t2)
            let da = tangentOnEllipse(t1)
            let db = tangentOnEllipse(t2)
            let c1 = CGPoint(x: a.x + alpha * da.x, y: a.y + alpha * da.y)
            let c2 = CGPoint(x: b.x - alpha * db.x, y: b.y - alpha * db.y)
            result.append(.curve(c1, c2, s == segmentCount - 1 ? p2 : b))
        }
        return result
    }
}
