import XCTest
@testable import TmuxControlCore

final class WindowOrderInteractionTests: XCTestCase {
    let order = [WindowId(1), WindowId(2), WindowId(3)]

    func testMoveIntentResolvesAgainstLiveOrderAndOmitsImpossibleActions() {
        XCTAssertEqual(TmuxWindowMoveIntent.next.destination(in: order, moving: WindowId(2)), 2)
        XCTAssertEqual(TmuxWindowMoveIntent.next.destination(in: [WindowId(2), WindowId(3), WindowId(1)], moving: WindowId(2)), 1)
        XCTAssertNil(TmuxWindowMoveIntent.previous.destination(in: order, moving: WindowId(1)))
        XCTAssertNil(TmuxWindowMoveIntent.end.destination(in: order, moving: WindowId(3)))
        XCTAssertNil(TmuxWindowMoveIntent.start.destination(in: order, moving: WindowId(9)))
    }

    func testChangedWithoutAdmittedBeginCannotCreateEmptyPreview() {
        var drag = TmuxWindowDragState()
        XCTAssertFalse(drag.begin(id: WindowId(2), order: order, pointer: 10, frameStart: 0, enabled: false))
        XCTAssertFalse(drag.update(pointer: 40, midpoints: [:], enabled: true))
        XCTAssertNil(drag.previewOrder)
        XCTAssertNil(drag.finish(cancelled: false))
    }

    func testDragPreservesPermutationAndCancelsWhenGateCloses() {
        var drag = TmuxWindowDragState()
        XCTAssertTrue(drag.begin(id: WindowId(3), order: order, pointer: 250, frameStart: 200, enabled: true))
        XCTAssertTrue(drag.update(pointer: 10, midpoints: [WindowId(1): 50, WindowId(2): 150], enabled: true))
        XCTAssertEqual(drag.previewOrder, [WindowId(3), WindowId(1), WindowId(2)])
        XCTAssertEqual(drag.offset(currentFrameStart: 0), -40)
        XCTAssertEqual(drag.finish(cancelled: false), 0)
        XCTAssertNil(drag.previewOrder)
        XCTAssertTrue(drag.begin(id: WindowId(3), order: order, pointer: 250, frameStart: 200, enabled: true))
        XCTAssertFalse(drag.update(pointer: 10, midpoints: [:], enabled: false))
        XCTAssertNil(drag.finish(cancelled: false))
    }
}
