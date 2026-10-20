import XCTest
@testable import TmuxControlCore

final class WindowReorderPlannerTests: XCTestCase {
    private let modern = TmuxWindowCapabilities(
        supportsMoveBefore: true,
        supportsSubscriptions: true
    )
    private let legacy = TmuxWindowCapabilities(
        supportsMoveBefore: false,
        supportsSubscriptions: false
    )

    func testNoOpEmitsNothingEvenWhenWindowAlreadyFollowsItsPredecessor() {
        let order = ids(1, 2, 3)
        let plan = TmuxWindowReorderPlanner.plan(
            order: order,
            moving: WindowId(2),
            to: 1,
            capabilities: modern
        )
        XCTAssertEqual(plan, .init(commands: [], expectedOrder: order))
    }

    func testDropAfterPredecessorAndAtEnd() {
        let after = TmuxWindowReorderPlanner.plan(
            order: ids(1, 2, 3, 4),
            moving: WindowId(2),
            to: 2,
            capabilities: modern
        )
        XCTAssertEqual(after?.commands, ["move-window -d -a -s @2 -t @3"])
        XCTAssertEqual(after?.expectedOrder, ids(1, 3, 2, 4))

        let end = TmuxWindowReorderPlanner.plan(
            order: ids(1, 2, 3, 4),
            moving: WindowId(1),
            to: 3,
            capabilities: modern
        )
        XCTAssertEqual(end?.commands, ["move-window -d -a -s @1 -t @4"])
        XCTAssertEqual(end?.expectedOrder, ids(2, 3, 4, 1))
    }

    func testModernFrontMoveUsesMoveBeforeAndRestoresActiveByID() {
        let plan = TmuxWindowReorderPlanner.plan(
            order: ids(1, 2, 3),
            moving: WindowId(3),
            to: 0,
            capabilities: modern,
            sessionID: SessionId(9),
            activeWindowID: WindowId(2)
        )
        XCTAssertEqual(
            plan?.commands,
            [
                "move-window -d -b -s $9:@3 -t $9:@1",
                "select-window -t $9:@2",
            ]
        )
        XCTAssertEqual(plan?.expectedOrder, ids(3, 1, 2))
    }

    func testLegacyFrontMoveUsesAdjacentSwapsThenRestoresActive() {
        let plan = TmuxWindowReorderPlanner.plan(
            order: ids(1, 2, 3),
            moving: WindowId(3),
            to: 0,
            capabilities: legacy,
            activeWindowID: WindowId(3)
        )
        XCTAssertEqual(
            plan?.commands,
            [
                "swap-window -d -s @3 -t @2",
                "swap-window -d -s @3 -t @1",
                "select-window -t @3",
            ]
        )
        XCTAssertEqual(plan?.expectedOrder, ids(3, 1, 2))
    }

    func testInvalidInputsAndIndexExhaustionAreRejected() {
        XCTAssertNil(plan(order: ids(1, 1), moving: 1, to: 0))
        XCTAssertNil(plan(order: ids(1, 2), moving: 9, to: 0))
        XCTAssertNil(plan(order: ids(1, 2), moving: 1, to: -1))
        XCTAssertNil(plan(order: ids(1, 2), moving: 1, to: 2))
        XCTAssertNil(plan(order: ids(1, 2), moving: 1, to: 1, active: 9))
        XCTAssertNil(plan(order: ids(1, 2), moving: 1, to: 1, highestIndex: -1))
        XCTAssertNil(plan(order: ids(1, 2), moving: 1, to: 1, highestIndex: Int(Int32.max)))
        XCTAssertNil(TmuxWindowReorderPlanner.plan(
            order: (0...512).map(WindowId.init),
            moving: WindowId(0),
            to: 1,
            capabilities: modern
        ))
    }

    func testSingleWindowIsAValidNoOp() {
        XCTAssertEqual(
            plan(order: ids(4), moving: 4, to: 0),
            .init(commands: [], expectedOrder: ids(4))
        )
    }

    func testExpectedOrderIsAlwaysAnInputPermutation() throws {
        let original = ids(1, 2, 3, 4)
        for source in original {
            for destination in original.indices {
                let plan = try XCTUnwrap(TmuxWindowReorderPlanner.plan(
                    order: original,
                    moving: source,
                    to: destination,
                    capabilities: modern
                ))
                XCTAssertEqual(Set(plan.expectedOrder), Set(original))
                XCTAssertEqual(plan.expectedOrder.count, original.count)
            }
        }
    }

    func testPlanIsCodable() throws {
        let plan = try XCTUnwrap(plan(order: ids(1, 2, 3), moving: 3, to: 0))
        let decoded = try JSONDecoder().decode(
            TmuxWindowReorderPlanner.Plan.self,
            from: JSONEncoder().encode(plan)
        )
        XCTAssertEqual(decoded, plan)
    }

    func testLegacyPlanUsesOnlySwapsAndPreservesEveryOtherWindow() throws {
        let original = ids(1, 2, 3, 4)
        for source in original {
            for destination in original.indices {
                let plan = try XCTUnwrap(TmuxWindowReorderPlanner.plan(
                    order: original, moving: source, to: destination,
                    capabilities: legacy, activeWindowID: WindowId(2)
                ))
                var actual = original
                for command in plan.commands where !command.hasPrefix("select-window") {
                    guard command.hasPrefix("swap-window -d") else {
                        XCTFail("Legacy insertion must not depend on current-window: \(command)")
                        continue
                    }
                    let words = command.split(separator: " ")
                    let first = try XCTUnwrap(WindowId(wireValue: String(words[3])))
                    let second = try XCTUnwrap(WindowId(wireValue: String(words[5])))
                    actual.swapAt(try XCTUnwrap(actual.firstIndex(of: first)),
                                  try XCTUnwrap(actual.firstIndex(of: second)))
                }
                var expected = original.filter { $0 != source }
                expected.insert(source, at: destination)
                XCTAssertEqual(actual, expected)
            }
        }
    }

    private func plan(
        order: [WindowId],
        moving: Int,
        to destination: Int,
        active: Int? = nil,
        highestIndex: Int? = nil
    ) -> TmuxWindowReorderPlanner.Plan? {
        TmuxWindowReorderPlanner.plan(
            order: order,
            moving: WindowId(moving),
            to: destination,
            capabilities: modern,
            activeWindowID: active.map(WindowId.init),
            highestIndex: highestIndex
        )
    }

    private func ids(_ values: Int...) -> [WindowId] { values.map(WindowId.init) }
}
