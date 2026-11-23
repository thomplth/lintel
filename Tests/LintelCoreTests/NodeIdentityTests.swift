import CoreGraphics
import Testing
@testable import LintelCore

@Suite struct NodeIdentity {
    private func pr(_ number: Int, title: String = "Fix") -> ViewNode {
        ViewNode(.item, ["title": .string(title), "url": .string("https://github.com/o/r/pull/\(number)")])
    }

    @Test func aRowKeepsItsIdentityWhenARowAboveItIsRemoved() {
        let before = [pr(1), pr(2), pr(3)].keyed
        let after = [pr(1), pr(3)].keyed
        #expect(after.map(\.id) == [before[0].id, before[2].id])
    }

    @Test func aRowKeepsItsIdentityWhenItsTitleChanges() {
        #expect([pr(7, title: "Old")].keyed[0].id == [pr(7, title: "New")].keyed[0].id)
    }

    @Test func anExplicitKeyWinsOverEverythingElse() {
        let node = ViewNode(.item, ["key": .string("pr-7"), "url": .string("https://x.dev/7"), "title": .string("A")])
        #expect([node].keyed[0].id.contains("pr-7"))
        #expect(![node].keyed[0].id.contains("x.dev"))
    }

    @Test func textKeepsItsIdentityWhileItsValueTicks() {
        let tick = [ViewNode(.text, ["value": .string("15:56:00")])].keyed
        let tock = [ViewNode(.text, ["value": .string("15:56:01")])].keyed
        #expect(tick[0].id == tock[0].id)
    }

    @Test func siblingsThatLookAlikeStillGetDistinctIdentities() {
        let keyed = [ViewNode(.divider), ViewNode(.divider), pr(1), pr(1)].keyed
        #expect(Set(keyed.map(\.id)).count == 4)
    }

    @Test func keyedChildrenKeepTheirOrderAndOffsets() {
        let keyed = [pr(1), pr(2)].keyed
        #expect(keyed.map(\.offset) == [0, 1])
        #expect(keyed.map(\.element) == [pr(1), pr(2)])
    }

    @Test func aModuleMayGiveAnyComponentAKey() {
        let parsed = ViewNode.parse(json: #"{"type":"text","value":"hi","key":"greeting"}"#)
        #expect(parsed.problems.isEmpty)
        #expect(parsed.node?.string("key") == "greeting")
    }
}

@Suite struct FocusRingVisibility {
    @Test func theRingStaysHiddenUntilTheKeyboardMovesFocus() {
        #expect(!FocusVisibility().showsRing)
    }

    @Test func tabbingShowsTheRing() {
        var visibility = FocusVisibility()
        visibility.record(.keyboardNavigation)
        #expect(visibility.showsRing)
    }

    @Test func clickingHidesTheRingAgain() {
        var visibility = FocusVisibility()
        visibility.record(.keyboardNavigation)
        visibility.record(.pointer)
        #expect(!visibility.showsRing)
    }

    @Test func typingCharactersDoesNotShowTheRing() {
        var visibility = FocusVisibility()
        visibility.record(.otherKey)
        #expect(!visibility.showsRing)
    }

    @Test func navigationKeysAreTabArrowsSpaceAndReturn() {
        for code: UInt16 in [48, 123, 124, 125, 126, 49, 36, 76] {
            #expect(FocusVisibility.Input(keyCode: code) == .keyboardNavigation)
        }
        #expect(FocusVisibility.Input(keyCode: 0) == .otherKey)
    }
}

@Suite struct NotificationClearanceSuite {
    private let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let widgets = CGRect(x: 2160, y: 700, width: 340, height: 700)

    @Test func nothingMovesWithoutANotification() {
        #expect(NotificationClearance.drop(content: widgets, banners: [], screen: screen) == 0)
    }

    @Test func widgetsMoveJustBelowABannerCoveringThem() {
        let banner = CGRect(x: 2180, y: 1320, width: 360, height: 76)
        let drop = NotificationClearance.drop(content: widgets, banners: [banner], screen: screen)
        #expect(drop == widgets.maxY - banner.minY + NotificationClearance.gap)
    }

    @Test func aTallerStackOfBannersMovesWidgetsFurther() {
        let one = CGRect(x: 2180, y: 1320, width: 360, height: 76)
        let two = CGRect(x: 2180, y: 1230, width: 360, height: 166)
        #expect(
            NotificationClearance.drop(content: widgets, banners: [two], screen: screen)
                > NotificationClearance.drop(content: widgets, banners: [one], screen: screen)
        )
    }

    @Test func aBannerBesideTheWidgetsLeavesThemInPlace() {
        let leftWidgets = CGRect(x: 40, y: 700, width: 340, height: 700)
        let banner = CGRect(x: 2180, y: 1320, width: 360, height: 76)
        #expect(NotificationClearance.drop(content: leftWidgets, banners: [banner], screen: screen) == 0)
    }

    @Test func widgetsMoveBelowEverythingInTheOpenNotificationCentre() {
        let notifications = CGRect(x: 2180, y: 1100, width: 360, height: 300)
        let calendar = CGRect(x: 2180, y: 760, width: 170, height: 320)
        let drop = NotificationClearance.drop(content: widgets, banners: [notifications, calendar], screen: screen)
        #expect(drop == widgets.maxY - calendar.minY + NotificationClearance.gap)
    }

    @Test func widgetsAlsoClearContentTheyWouldLandOnOnceMoved() {
        let banner = CGRect(x: 2180, y: 1300, width: 360, height: 100)
        let lower = CGRect(x: 2180, y: 400, width: 360, height: 200)
        let drop = NotificationClearance.drop(content: widgets, banners: [banner, lower], screen: screen)
        #expect(drop == widgets.maxY - lower.minY + NotificationClearance.gap)
    }

    @Test func aFullNotificationCentrePushesWidgetsOffScreen() {
        let column = (0..<6).map { CGRect(x: 2180, y: CGFloat(40 + $0 * 230), width: 360, height: 220) }
        let drop = NotificationClearance.drop(content: widgets, banners: column, screen: screen)
        #expect(widgets.maxY - drop < screen.minY + widgets.height)
    }

    @Test func aScreenSizedBackdropIsNotContent() {
        let backdrop = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(NotificationClearance.drop(content: widgets, banners: [backdrop], screen: screen) == 0)
    }

    @Test func theFallbackBannerSitsInTheTopRightCornerUnderTheMenuBar() {
        let visible = CGRect(x: 0, y: 0, width: 2560, height: 1415)
        let banner = NotificationClearance.assumedBanner(visibleFrame: visible)
        #expect(banner.maxX < visible.maxX && banner.maxX > visible.maxX - 40)
        #expect(banner.maxY <= visible.maxY && banner.maxY > visible.maxY - 20)
    }
}

@Suite struct WidgetMotionSignature {
    private func list(_ rows: [ViewNode]) -> ViewNode { ViewNode(.list, ["title": .string("repo")], rows) }
    private func pr(_ number: Int, tone: String = "good", ci: String = "124") -> ViewNode {
        ViewNode(.item, [
            "url": .string("https://github.com/o/r/pull/\(number)"), "tone": .string(tone),
            "slots": .array([.object(["value": .string(ci), "tone": .string(tone)])]),
        ])
    }

    @Test func removingARowChangesTheSignature() {
        #expect(list([pr(1), pr(2)]).motionSignature != list([pr(1)]).motionSignature)
    }

    @Test func reorderingRowsChangesTheSignature() {
        #expect(list([pr(1), pr(2)]).motionSignature != list([pr(2), pr(1)]).motionSignature)
    }

    @Test func aToneChangeChangesTheSignature() {
        #expect(list([pr(1, tone: "good")]).motionSignature != list([pr(1, tone: "bad")]).motionSignature)
    }

    @Test func aTickingValueLeavesTheSignatureAlone() {
        let tick = ViewNode(.column, [:], [ViewNode(.text, ["value": .string("15:56:00")]), pr(1, ci: "124")])
        let tock = ViewNode(.column, [:], [ViewNode(.text, ["value": .string("15:56:01")]), pr(1, ci: "125")])
        #expect(tick.motionSignature == tock.motionSignature)
    }
}
