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
    /// Meridian's clock window height, which centres the text a little above the middle of the notch strip.
    public static let stripRowHeight: CGFloat = 30

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
                topRowMinHeight = min(stripRowHeight, screen.notchStripHeight)
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

    /// The bar's own padding either side of its rows.
    public static let barSidePadding: CGFloat = 8

    /// How wide a row may grow before it wraps. Beside a notch, while the menu bar hides, rows wrap to the space beside
    /// the notch so the bar's first line stays in the strip at the top of the screen instead of the whole bar
    /// dropping below it.
    public static func widestRow(
        on screen: ScreenGeometry, anchor: BarAnchor, edgeInset: CGFloat = 0, otherwise: CGFloat
    ) -> CGFloat {
        let strip: CGRect? = switch anchor {
        case .left: screen.areaLeftOfNotch
        case .right: screen.areaRightOfNotch
        case .center: nil
        }
        guard screen.menuBarAutoHides, screen.notchStripHeight > 0, let strip else { return otherwise }
        return min(otherwise, strip.width - edgeInset - barSidePadding * 2)
    }

    /// The bar's rows after the first, hanging under the menu bar item that holds the first row, aligned to the
    /// side the bar is anchored to and kept on screen.
    public static func rows(contentSize: CGSize, under item: CGRect, on screen: ScreenGeometry, anchor: BarAnchor) -> CGRect {
        var x: CGFloat = switch anchor {
        case .left: item.minX
        case .center: item.midX - contentSize.width / 2
        case .right: item.maxX - contentSize.width
        }
        x = min(max(x, screen.frame.minX), screen.frame.maxX - contentSize.width)
        // The item's window reaches above and below the menu bar it sits in, so only the menu bar marks the top.
        return CGRect(x: x.rounded(), y: screen.visibleFrame.maxY - contentSize.height, width: contentSize.width, height: contentSize.height)
    }

    /// AppKit frames grow upwards from the bottom of the main display; event taps and window lists use global display
    /// coordinates, which grow downwards from its top.
    public static func globalDisplayRect(_ frame: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainScreenHeight - frame.maxY, width: frame.width, height: frame.height)
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
