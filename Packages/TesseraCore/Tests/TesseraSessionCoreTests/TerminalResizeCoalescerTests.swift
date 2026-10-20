import XCTest
@testable import TesseraSessionCore

final class TerminalResizeCoalescerTests: XCTestCase {

    private func size(_ cols: Int, _ rows: Int) -> TerminalResizeCoalescer.Size {
        TerminalResizeCoalescer.Size(cols: cols, rows: rows)
    }

    /// The session cannot start without a size, so the first one is never
    /// held back.
    func testFirstSizeGoesStraightOut() {
        var coalescer = TerminalResizeCoalescer()
        XCTAssertEqual(coalescer.note(size(166, 54)), .send)
        XCTAssertEqual(coalescer.lastDelivered, size(166, 54))
        XCTAssertNil(coalescer.pending)
    }

    /// The reported case: presenting a modal shrank the terminal to 52 rows
    /// and restored it 28ms later. The remote must hear about neither.
    func testTransientThatComesBackIsNeverSent() {
        var coalescer = TerminalResizeCoalescer()
        XCTAssertEqual(coalescer.note(size(166, 54)), .send)

        XCTAssertEqual(coalescer.note(size(166, 52)), .wait)
        XCTAssertEqual(coalescer.note(size(166, 54)), .drop)
        XCTAssertNil(coalescer.pending, "the shrink must not still be waiting")

        // A timer for the shrink that fires late must find nothing to do.
        XCTAssertFalse(coalescer.settle(size(166, 52)))
        XCTAssertEqual(coalescer.lastDelivered, size(166, 54))
    }

    /// A size that holds still is delivered when its window expires.
    func testSettledSizeIsDelivered() {
        var coalescer = TerminalResizeCoalescer()
        _ = coalescer.note(size(166, 54))

        XCTAssertEqual(coalescer.note(size(120, 40)), .wait)
        XCTAssertTrue(coalescer.settle(size(120, 40)))
        XCTAssertEqual(coalescer.lastDelivered, size(120, 40))
        XCTAssertNil(coalescer.pending)
    }

    /// A drag that sweeps through intermediate sizes delivers only where it
    /// stopped — each new size supersedes the one waiting. This is Android's
    /// `animation burst publishes only its settled edge` in the iOS spelling.
    func testOnlyTheLastSizeOfASweepIsDelivered() {
        var coalescer = TerminalResizeCoalescer()
        _ = coalescer.note(size(166, 54))

        XCTAssertEqual(coalescer.note(size(166, 50)), .wait)
        XCTAssertEqual(coalescer.note(size(166, 46)), .wait)
        XCTAssertEqual(coalescer.note(size(166, 42)), .wait)

        XCTAssertFalse(coalescer.settle(size(166, 50)), "superseded")
        XCTAssertFalse(coalescer.settle(size(166, 46)), "superseded")
        XCTAssertTrue(coalescer.settle(size(166, 42)))
        XCTAssertEqual(coalescer.lastDelivered, size(166, 42))
    }

    /// Column-only changes count: a width change reflows just as hard as a
    /// height change.
    func testColumnChangeIsNotConfusedWithNoChange() {
        var coalescer = TerminalResizeCoalescer()
        _ = coalescer.note(size(166, 54))
        XCTAssertEqual(coalescer.note(size(120, 54)), .wait)
        XCTAssertTrue(coalescer.settle(size(120, 54)))
    }

    /// The view re-reports the same size on layout passes that changed
    /// nothing; those must not start a timer. Android's `duplicate proposals
    /// do not reschedule`.
    func testRepeatedSameSizeIsDropped() {
        var coalescer = TerminalResizeCoalescer()
        _ = coalescer.note(size(166, 54))
        XCTAssertEqual(coalescer.note(size(166, 54)), .drop)
        XCTAssertEqual(coalescer.note(size(166, 54)), .drop)
        XCTAssertNil(coalescer.pending)
    }

    /// After a settled delivery the coalescer measures transients against the
    /// new size, not the original one. Android's `returning to published
    /// geometry cancels a transient proposal` is the middle two assertions.
    func testBaselineFollowsTheLastDelivery() {
        var coalescer = TerminalResizeCoalescer()
        _ = coalescer.note(size(166, 54))
        _ = coalescer.note(size(166, 40))
        XCTAssertTrue(coalescer.settle(size(166, 40)))

        XCTAssertEqual(coalescer.note(size(166, 38)), .wait)
        XCTAssertEqual(coalescer.note(size(166, 40)), .drop)
        XCTAssertEqual(coalescer.note(size(166, 54)), .wait,
                       "the original size is now a real change")
    }

    /// Ported from Android `reset permits the same initial geometry after
    /// reconnect`: the replacement shell has been told nothing, so the size it
    /// is already showing counts as new again.
    func testResetPermitsTheSameInitialGeometryAfterReconnect() {
        var coalescer = TerminalResizeCoalescer()
        XCTAssertEqual(coalescer.note(size(166, 54)), .send)
        XCTAssertEqual(coalescer.note(size(166, 54)), .drop)

        coalescer.reset()

        XCTAssertNil(coalescer.lastDelivered)
        XCTAssertNil(coalescer.pending)
        XCTAssertEqual(coalescer.note(size(166, 54)), .send)
    }

    /// Reset while a size is waiting drops the wait too, so a timer that
    /// survives the reconnect cannot deliver a pre-reconnect geometry.
    func testResetDiscardsAPendingWait() {
        var coalescer = TerminalResizeCoalescer()
        _ = coalescer.note(size(166, 54))
        XCTAssertEqual(coalescer.note(size(166, 40)), .wait)

        coalescer.reset()

        XCTAssertFalse(coalescer.settle(size(166, 40)))
    }

    /// The settle window is the measured 28ms modal storm plus headroom; a
    /// change here changes what reaches the remote, so it is pinned.
    func testSettleWindowIsOneHundredAndTwentyMilliseconds() {
        XCTAssertEqual(TerminalResizeCoalescer.settleSeconds, 0.12, accuracy: 0.0000001)
    }
}
