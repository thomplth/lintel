import CoreGraphics
import Testing
@testable import LintelCore

@Suite struct BarFlowing {
    let chip = CGSize(width: 40, height: 20)

    func flow(_ alignment: BarFlow.Alignment, maxWidth: CGFloat = 1000, firstRowMinHeight: CGFloat = 0) -> BarFlow {
        BarFlow(spacing: 4, rowSpacing: 3, alignment: alignment, maxWidth: maxWidth, firstRowMinHeight: firstRowMinHeight)
    }

    @Test func aRowLaysItsModulesSideBySide() {
        let placed = flow(.leading).place([[chip, chip]])
        #expect(placed.frames == [[CGRect(x: 0, y: 0, width: 40, height: 20), CGRect(x: 44, y: 0, width: 40, height: 20)]])
        #expect(placed.size == CGSize(width: 84, height: 20))
    }

    @Test func rowsStackWithTheBarsRowSpacing() {
        let placed = flow(.leading).place([[chip], [chip]])
        #expect(placed.frames[1] == [CGRect(x: 0, y: 23, width: 40, height: 20)])
        #expect(placed.size == CGSize(width: 40, height: 43))
    }

    @Test func aRightAnchoredBarLinesEveryRowUpOnItsRightEdge() {
        let placed = flow(.trailing).place([[chip, chip], [chip]])
        #expect(placed.frames[1] == [CGRect(x: 44, y: 23, width: 40, height: 20)])
    }

    @Test func aCentredBarCentresEveryRow() {
        let placed = flow(.center).place([[chip, chip], [chip]])
        #expect(placed.frames[1] == [CGRect(x: 22, y: 23, width: 40, height: 20)])
    }

    @Test func aRowTooWideWrapsOntoAnotherLine() {
        let placed = flow(.leading, maxWidth: 90).place([[chip, chip, chip]])
        #expect(placed.frames[0][2] == CGRect(x: 0, y: 23, width: 40, height: 20))
        #expect(placed.size == CGSize(width: 84, height: 43))
    }

    @Test func aRightAnchoredRowKeepsItsLastModulesOnTheFirstLineWhenItWraps() {
        let placed = flow(.trailing, maxWidth: 90).place([[chip, chip, chip]])
        #expect(placed.frames[0][0] == CGRect(x: 44, y: 23, width: 40, height: 20))
        #expect(placed.frames[0][1] == CGRect(x: 0, y: 0, width: 40, height: 20))
        #expect(placed.frames[0][2] == CGRect(x: 44, y: 0, width: 40, height: 20))
    }

    @Test func modulesOfDifferentHeightsAreCentredOnTheirLine() {
        let placed = flow(.leading).place([[chip, CGSize(width: 40, height: 30)]])
        #expect(placed.frames[0][0].minY == 5)
    }

    @Test func theFirstRowFillsTheStripBesideTheNotchWithItsModulesCentredInIt() {
        let placed = flow(.leading, firstRowMinHeight: 30).place([[chip], [chip]])
        #expect(placed.frames[0][0].minY == 5)
        #expect(placed.frames[1][0].minY == 33)
    }

    @Test func anEmptyRowTakesNoSpace() {
        let placed = flow(.leading).place([[chip], [], [chip]])
        #expect(placed.frames[2] == [CGRect(x: 0, y: 23, width: 40, height: 20)])
    }
}

@Suite struct BarCanvas {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func aRightAnchoredCanvasKeepsItsLeftEdgeWhateverTheBarsWidth() {
        let narrow = Placement.canvas(around: CGRect(x: 1412, y: 950, width: 100, height: 32), width: 600, height: 200, anchor: .right)
        let wide = Placement.canvas(around: CGRect(x: 1112, y: 950, width: 400, height: 32), width: 600, height: 200, anchor: .right)
        #expect(narrow == CGRect(x: 912, y: 782, width: 600, height: 200))
        #expect(wide == narrow)
    }

    @Test func aLeftAnchoredCanvasStartsAtTheBar() {
        let canvas = Placement.canvas(around: CGRect(x: 10, y: 950, width: 100, height: 32), width: 600, height: 200, anchor: .left)
        #expect(canvas == CGRect(x: 10, y: 782, width: 600, height: 200))
    }

    @Test func aCentredCanvasSharesTheBarsMiddle() {
        let canvas = Placement.canvas(around: CGRect(x: 706, y: 950, width: 100, height: 32), width: 600, height: 200, anchor: .center)
        #expect(canvas.midX == 756)
    }

    @Test func theCanvasGrowsToHoldABarLargerThanIt() {
        let canvas = Placement.canvas(around: CGRect(x: 812, y: 650, width: 700, height: 332), width: 600, height: 200, anchor: .right)
        #expect(canvas == CGRect(x: 812, y: 650, width: 700, height: 332))
    }

    @Test func theBarSitsInItsCanvasCornerOnTheAnchoredSide() {
        let canvas = CGRect(x: 912, y: 782, width: 600, height: 200)
        #expect(Placement.content(size: CGSize(width: 100, height: 32), in: canvas, anchor: .right) == CGRect(x: 1412, y: 950, width: 100, height: 32))
        #expect(Placement.content(size: CGSize(width: 100, height: 32), in: canvas, anchor: .left) == CGRect(x: 912, y: 950, width: 100, height: 32))
        #expect(Placement.content(size: CGSize(width: 100, height: 32), in: canvas, anchor: .center) == CGRect(x: 1162, y: 950, width: 100, height: 32))
    }
}
