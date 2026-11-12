import XCTest
@testable import Tessera

final class DuoSettleGateTests: XCTestCase {
    func testMotionStartsOnceAndSettlesAtExactlyThreeHundredMilliseconds() throws {
        var now: TimeInterval = 1
        var gate = DuoSettleGate(now: { now })
        XCTAssertEqual(gate.state, .none)
        XCTAssertEqual(gate.hingeChanged(.partiallyOpen), .moving)
        now = 1.299
        XCTAssertNil(gate.settle())
        now = try XCTUnwrap(gate.deadline)
        XCTAssertEqual(gate.settle(), .settled(.partiallyOpen))
        XCTAssertNil(gate.settle())
    }

    func testEveryAngleChangeRestartsTheDeadlineEvenWithTheSameStatus() throws {
        var now: TimeInterval = 0
        var gate = DuoSettleGate(now: { now })
        XCTAssertEqual(gate.hingeChanged(.partiallyOpen), .moving)
        now = 0.2
        XCTAssertNil(gate.hingeChanged(.partiallyOpen))
        now = 0.3
        XCTAssertNil(gate.settle())
        now = try XCTUnwrap(gate.deadline)
        XCTAssertEqual(gate.settle(), .settled(.partiallyOpen))
    }

    func testLastStatusWinsAndANewMotionStartsAfterSettlement() throws {
        var now: TimeInterval = 0
        var gate = DuoSettleGate(now: { now })
        _ = gate.hingeChanged(.closed)
        now = 0.1
        XCTAssertNil(gate.hingeChanged(.fullyOpen))
        now = try XCTUnwrap(gate.deadline)
        XCTAssertEqual(gate.settle(), .settled(.fullyOpen))
        now = 1
        XCTAssertEqual(gate.hingeChanged(.closed), .moving)
        now = try XCTUnwrap(gate.deadline)
        XCTAssertEqual(gate.settle(), .settled(.closed))
    }

    func testNilHingeImmediatelyClearsMotionAndCancelsStaleSettlement() {
        var now: TimeInterval = 0
        var gate = DuoSettleGate(now: { now })
        XCTAssertNil(gate.hingeChanged(nil))
        _ = gate.hingeChanged(.partiallyOpen)
        XCTAssertEqual(gate.hingeChanged(nil), DuoHingeState.none)
        XCTAssertNil(gate.deadline)
        now = 10
        XCTAssertNil(gate.settle())
        XCTAssertEqual(gate.state, .none)
        XCTAssertNil(gate.hingeChanged(nil))
    }

    func testWakeUpDelayUsesTheInjectedClockAndExpiresWithoutGoingNegative() {
        var now: TimeInterval = 1
        var gate = DuoSettleGate(now: { now })
        XCTAssertNil(gate.timeUntilSettlement)
        _ = gate.hingeChanged(.fullyOpen)
        XCTAssertEqual(gate.timeUntilSettlement ?? -1, 0.3, accuracy: 0.000001)
        now = 1.2
        XCTAssertEqual(gate.timeUntilSettlement ?? -1, 0.1, accuracy: 0.000001)
        now = 2
        XCTAssertEqual(gate.timeUntilSettlement, 0)
        XCTAssertEqual(gate.settle(), .settled(.fullyOpen))
        XCTAssertNil(gate.timeUntilSettlement)
    }

    func testInitialNilFoldReportsOnceAndSettledChangesAreImmediate() {
        var settlement = DuoFoldSettlement()
        XCTAssertTrue(settlement.update(current: nil, hinge: .none))
        XCTAssertFalse(settlement.update(current: nil, hinge: .none))
        XCTAssertTrue(settlement.update(current: book, hinge: .settled(.partiallyOpen)))
        XCTAssertEqual(settlement.fold, book)
        XCTAssertFalse(settlement.update(current: book, hinge: .settled(.partiallyOpen)))
        XCTAssertTrue(settlement.update(current: nil, hinge: .none))
        XCTAssertNil(settlement.fold)
    }

    func testMovingHingeHoldsTheLastFoldIncludingWhenTheActiveRegionDisappears() {
        var settlement = DuoFoldSettlement()
        _ = settlement.update(current: book, hinge: .settled(.partiallyOpen))
        XCTAssertFalse(settlement.update(current: laptop, hinge: .moving))
        XCTAssertEqual(settlement.fold, book)
        XCTAssertFalse(settlement.update(current: nil, hinge: .moving))
        XCTAssertEqual(settlement.fold, book)
        XCTAssertTrue(settlement.update(current: nil, hinge: .settled(.fullyOpen)))
        XCTAssertNil(settlement.fold)
    }

    func testAHeldFoldGoesWithTheWidthItWasMeasuredAt() {
        var settlement = DuoFoldSettlement()
        let laptopHinge = DuoFold(frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), splitsSideBySide: false)
        _ = settlement.update(current: laptopHinge, hinge: .settled(.partiallyOpen), width: 669)
        // The hinge starts moving: the same display holds its fold.
        XCTAssertFalse(settlement.update(current: nil, hinge: .moving, width: 669))
        XCTAssertEqual(settlement.fold, laptopHinge)
        // Closing: the outer display's 594 pt has no division, even while
        // the hinge still moves.
        XCTAssertTrue(settlement.update(current: nil, hinge: .moving, width: 594))
        XCTAssertNil(settlement.fold)
        // Book to laptop mid-motion: the laptop's own fold replaces the book's.
        _ = settlement.update(current: book, hinge: .settled(.partiallyOpen), width: 951)
        XCTAssertTrue(settlement.update(current: laptopHinge, hinge: .moving, width: 669))
        XCTAssertEqual(settlement.fold, laptopHinge)
    }

    /// Closing from laptop, the first reading at the outer display's width
    /// can still carry the laptop's division; the next one at that width,
    /// with none, must not be held behind it until the hinge settles.
    func testAFoldReadAtANewWidthMidMotionIsFollowedNotHeld() {
        var settlement = DuoFoldSettlement()
        let laptopHinge = DuoFold(frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), splitsSideBySide: false)
        _ = settlement.update(current: laptopHinge, hinge: .settled(.partiallyOpen), width: 669)
        XCTAssertFalse(settlement.update(current: laptopHinge, hinge: .moving, width: 669))
        XCTAssertFalse(settlement.update(current: laptopHinge, hinge: .moving, width: 594))
        XCTAssertTrue(settlement.update(current: nil, hinge: .moving, width: 594))
        XCTAssertNil(settlement.fold)
        // Still moving at that width: a division appearing is followed, its
        // movement is not.
        let outer = DuoFold(frame: CGRect(x: 277, y: 0, width: 40, height: 466), splitsSideBySide: true)
        XCTAssertTrue(settlement.update(current: outer, hinge: .moving, width: 594))
        XCTAssertFalse(settlement.update(current: DuoFold(frame: outer.frame.offsetBy(dx: 3, dy: 0), splitsSideBySide: true), hinge: .moving, width: 594))
        XCTAssertEqual(settlement.fold, outer)
        XCTAssertTrue(settlement.update(current: nil, hinge: .moving, width: 594))
        // Settled again, motion holds the fold once more.
        XCTAssertFalse(settlement.update(current: nil, hinge: .settled(.closed), width: 594))
        XCTAssertTrue(settlement.update(current: book, hinge: .settled(.partiallyOpen), width: 951))
        XCTAssertFalse(settlement.update(current: nil, hinge: .moving, width: 951))
        XCTAssertEqual(settlement.fold, book)
    }

    func testInitialMovingHingeReportsOnlyTheLastSettledNil() {
        var settlement = DuoFoldSettlement()
        XCTAssertTrue(settlement.update(current: book, hinge: .moving))
        XCTAssertNil(settlement.fold)
        XCTAssertFalse(settlement.update(current: laptop, hinge: .moving))
        XCTAssertTrue(settlement.update(current: laptop, hinge: .settled(.partiallyOpen)))
        XCTAssertEqual(settlement.fold, laptop)
    }

    func testMotionProducesExactlyOneNewPaneGeometryAfterTheLastChange() throws {
        var now: TimeInterval = 0
        var gate = DuoSettleGate(now: { now })
        var settlement = DuoFoldSettlement()
        _ = settlement.update(current: nil, hinge: .none)
        var layouts = [layout(fold: settlement.fold)]
        for tick in 0..<20 {
            now = Double(tick) / 100
            _ = gate.hingeChanged(.partiallyOpen)
            let moving = DuoFold(
                frame: CGRect(x: 440 + CGFloat(tick), y: 0, width: 40, height: 553),
                splitsSideBySide: true
            )
            if settlement.update(current: moving, hinge: gate.state) {
                layouts.append(layout(fold: settlement.fold))
            }
        }
        XCTAssertEqual(layouts.count, 1)
        now = try XCTUnwrap(gate.deadline) - 0.001
        XCTAssertNil(gate.settle())
        now = try XCTUnwrap(gate.deadline)
        XCTAssertEqual(gate.settle(), .settled(.partiallyOpen))
        if settlement.update(current: book, hinge: gate.state) {
            layouts.append(layout(fold: settlement.fold))
        }
        XCTAssertEqual(layouts.count, 2)
        XCTAssertEqual(layouts.last?.mainSlot.width, 455.5)
        XCTAssertEqual(layouts.last?.contextSlot?.width, 371.5)
        XCTAssertFalse(settlement.update(current: book, hinge: gate.state))
    }

    /// Closing the Duo hands readers the inner display's 669 pt hinge at the
    /// outer display's size; a display's own hinge lies within its window.
    func testOnlyADivisionWithinTheWindowIsTheDisplaysOwn() {
        let outer = CGSize(width: 466, height: 678)
        let outerLandscape = CGSize(width: 678, height: 466)
        // The laptop's hinge over the closing outer display: wider than it.
        XCTAssertFalse(DuoFold.liesWithin(outer, frame: CGRect(x: 0, y: 414, width: 669, height: 40),
                                          readerOrigin: CGPoint(x: 0, y: 41.5)))
        XCTAssertFalse(DuoFold.liesWithin(outer, frame: CGRect(x: 0, y: 414, width: 669, height: 40), readerOrigin: nil))
        // Closing into landscape: the book's hinge is taller than the window,
        // and the laptop's lies below its bottom edge.
        XCTAssertFalse(DuoFold.liesWithin(outerLandscape, frame: CGRect(x: 182.5, y: 0, width: 40, height: 669), readerOrigin: .zero))
        XCTAssertFalse(DuoFold.liesWithin(outerLandscape, frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), readerOrigin: .zero))
        // The displays' own hinges, also from a reader below a title row.
        XCTAssertTrue(DuoFold.liesWithin(CGSize(width: 669, height: 951), frame: CGRect(x: 0, y: 373.5, width: 669, height: 40),
                                         readerOrigin: CGPoint(x: 0, y: 82)))
        XCTAssertTrue(DuoFold.liesWithin(CGSize(width: 951, height: 669), frame: CGRect(x: 455.5, y: -82, width: 40, height: 669),
                                         readerOrigin: CGPoint(x: 0, y: 82)))
        XCTAssertTrue(DuoFold.liesWithin(CGSize(width: 951, height: 669), frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), readerOrigin: .zero))
        // A lifted reader's origin is not compared; its hinge's size still is.
        XCTAssertTrue(DuoFold.liesWithin(CGSize(width: 951, height: 669), frame: CGRect(x: 455.5, y: 240, width: 40, height: 669), readerOrigin: nil))
        // Before there is a window, nothing is dropped.
        XCTAssertTrue(DuoFold.liesWithin(nil, frame: CGRect(x: 0, y: 414, width: 669, height: 40), readerOrigin: .zero))
    }

    private let book = DuoFold(frame: CGRect(x: 455.5, y: 0, width: 40, height: 553), splitsSideBySide: true)
    private let laptop = DuoFold(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), splitsSideBySide: false)

    private func layout(fold: DuoFold?) -> DuoPaneLayout {
        DuoPaneGeometry.layout(DuoPaneRequest(
            container: CGSize(width: 867, height: 553), fold: fold, contextHidden: false,
            fullScreen: false, swapped: false, mainTakesInput: true, mainIdealWidth: 524
        ))
    }
}
