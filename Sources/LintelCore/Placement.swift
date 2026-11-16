import CoreGraphics
import Foundation

public enum BarAnchor: String, Codable, Sendable, CaseIterable {
    case left, center, right
}

public struct ScreenGeometry: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var notchStripHeight: CGFloat
    public var areaLeftOfNotch: CGRect?
    public var areaRightOfNotch: CGRect?
    public var menuBarAutoHides: Bool

    public init(
        frame: CGRect, visibleFrame: CGRect, notchStripHeight: CGFloat = 0, areaLeftOfNotch: CGRect? = nil,
        areaRightOfNotch: CGRect? = nil, menuBarAutoHides: Bool
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.notchStripHeight = notchStripHeight
        self.areaLeftOfNotch = areaLeftOfNotch
        self.areaRightOfNotch = areaRightOfNotch
        self.menuBarAutoHides = menuBarAutoHides
    }
}

public struct BarPlacement: Equatable, Sendable {
    public var frame: CGRect
    public var topRowMinHeight: CGFloat
}

public enum Placement {
    public static func bar(
        contentSize: CGSize, on screen: ScreenGeometry, anchor: BarAnchor = .right, edgeInset: CGFloat = 0
    ) -> BarPlacement {
        let x: CGFloat = switch anchor {
        case .left: screen.frame.minX + edgeInset
        case .center: screen.frame.midX - contentSize.width / 2
        case .right: screen.frame.maxX - edgeInset - contentSize.width
        }
        var top = screen.frame.maxY
        var topRowMinHeight: CGFloat = 0

        if !screen.menuBarAutoHides {
            top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.notchStripHeight)
        } else if screen.notchStripHeight > 0 {
            let strip: CGRect? = switch anchor {
            case .left: screen.areaLeftOfNotch
            case .right: screen.areaRightOfNotch
            case .center: nil
            }
            if let strip, contentSize.width + edgeInset <= strip.width {
                topRowMinHeight = screen.notchStripHeight
            } else {
                top = screen.frame.maxY - screen.notchStripHeight
            }
        }

        return BarPlacement(
            frame: CGRect(x: x.rounded(), y: top - contentSize.height, width: contentSize.width, height: contentSize.height),
            topRowMinHeight: topRowMinHeight
        )
    }

    public static func anchor(forDropAt midX: CGFloat, on screen: ScreenGeometry) -> BarAnchor {
        let third = screen.frame.width / 3
        if midX < screen.frame.minX + third { return .left }
        if midX > screen.frame.maxX - third { return .right }
        return .center
    }

    /// A panel hangs under its chip, aligned to the chip's side of the screen and kept on screen.
    public static func panel(size: CGSize, under chip: CGRect, on screen: CGRect, gap: CGFloat = 6, margin: CGFloat = 8) -> CGRect {
        var x = chip.midX < screen.midX ? chip.minX : chip.maxX - size.width
        x = min(max(x, screen.minX + margin), screen.maxX - margin - size.width)
        let height = min(size.height, chip.minY - gap - screen.minY - margin)
        return CGRect(x: x.rounded(), y: (chip.minY - gap - height).rounded(), width: size.width, height: height)
    }
}

public struct Activation: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case dwelling(since: TimeInterval)
        case hovering
        case leaving(since: TimeInterval)
        case held
    }

    public private(set) var state: State = .idle
    public var dwell: TimeInterval
    public var grace: TimeInterval

    public init(dwell: TimeInterval = 0.3, grace: TimeInterval = 0.6) {
        self.dwell = dwell
        self.grace = grace
    }

    public var isActive: Bool {
        switch state {
        case .hovering, .leaving, .held: true
        case .idle, .dwelling: false
        }
    }

    public mutating func pointer(inside: Bool, at now: TimeInterval) {
        switch state {
        case .idle:
            if inside { state = .dwelling(since: now) }
        case .dwelling(let since):
            if !inside { state = .idle } else if now - since >= dwell { state = .hovering }
        case .hovering:
            if !inside { state = .leaving(since: now) }
        case .leaving(let since):
            if inside { state = .hovering } else if now - since >= grace { state = .idle }
        case .held:
            break
        }
    }

    public mutating func toggleHold() {
        state = state == .held ? .idle : .held
    }

    public mutating func hold() {
        state = .held
    }

    public mutating func release() {
        state = .idle
    }

    /// Ends a hold without snapping shut: the bar stays up for the grace period, or longer if the pointer is on it.
    public mutating func unhold(at now: TimeInterval) {
        if state == .held { state = .leaving(since: now) }
    }
}
