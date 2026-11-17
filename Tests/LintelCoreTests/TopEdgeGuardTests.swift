import CoreGraphics
import Testing
@testable import LintelCore

@Suite struct TopEdgeGuarding {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let bar = CGRect(x: 1000, y: 950, width: 512, height: 32)

    @Test func thePointerOverTheBarIsHeldJustBelowTheBandThatRevealsTheMenuBar() {
        let held = TopEdgeGuard.position(for: CGPoint(x: 1200, y: 0), screenTop: 0, guarded: 1000...1512)
        #expect(held == CGPoint(x: 1200, y: TopEdgeGuard.revealDepth))
        #expect(TopEdgeGuard.position(for: CGPoint(x: 1200, y: 4.5), screenTop: 0, guarded: 1000...1512).y == TopEdgeGuard.revealDepth)
    }

    @Test func thePointerElsewhereOnTheTopEdgeStillReachesIt() {
        #expect(TopEdgeGuard.position(for: CGPoint(x: 400, y: 0), screenTop: 0, guarded: 1000...1512) == CGPoint(x: 400, y: 0))
        #expect(TopEdgeGuard.position(for: CGPoint(x: 1200, y: 0), screenTop: 0, guarded: nil) == CGPoint(x: 1200, y: 0))
    }

    @Test func thePointerBelowTheBandIsLeftAlone() {
        #expect(TopEdgeGuard.position(for: CGPoint(x: 1200, y: 5), screenTop: 0, guarded: 1000...1512) == CGPoint(x: 1200, y: 5))
        #expect(TopEdgeGuard.position(for: CGPoint(x: 1200, y: 300), screenTop: 0, guarded: 1000...1512) == CGPoint(x: 1200, y: 300))
    }

    @Test func theBandIsMeasuredFromTheScreensOwnTop() {
        #expect(TopEdgeGuard.position(for: CGPoint(x: 1200, y: -200), screenTop: -200, guarded: 1000...1512).y == -195)
    }

    @Test func theGuardedStretchIsTheBarsWidthWhileTheBarTouchesTheTopEdge() {
        #expect(TopEdgeGuard.span(of: bar, on: screen, besides: []) == 1000...1512)
        #expect(TopEdgeGuard.span(of: bar.offsetBy(dx: 0, dy: -33), on: screen, besides: []) == nil)
    }

    @Test func aBarHangingUnderTheNotchStripStillGuardsTheEdgeAboveIt() {
        let opened = CGRect(x: 575, y: 915, width: 937, height: 35)
        #expect(TopEdgeGuard.span(of: opened, on: screen, besides: [], notchStripHeight: 32) == 575...1512)
        #expect(TopEdgeGuard.span(of: opened.offsetBy(dx: 0, dy: -10), on: screen, besides: [], notchStripHeight: 32) == nil)
    }

    @Test func aDisplayAboveTheBarLeavesTheEdgeOpenToCrossInto() {
        let above = CGRect(x: 800, y: 982, width: 1920, height: 1080)
        #expect(TopEdgeGuard.span(of: bar, on: screen, besides: [above]) == nil)
        let aside = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        #expect(TopEdgeGuard.span(of: bar, on: screen, besides: [aside]) == 1000...1512)
        let aboveElsewhere = CGRect(x: -1920, y: 982, width: 1920, height: 1080)
        #expect(TopEdgeGuard.span(of: bar, on: screen, besides: [aboveElsewhere]) == 1000...1512)
    }
}
