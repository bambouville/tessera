import XCTest
import CoreGraphics
import TmuxControlCore
@testable import Tessera

/// iOS half of the SSH+tmux inline history ladder (see
/// `docs/tmux-inline-history-deepen.md`).
///
/// The ledger owns depth, exhaustion and single-flight; the platform keeps
/// `canDeepen`, a request latch and the reader's distance from the tail so a
/// deepen's rebind-and-clear does not dump the reader back at the live bottom.
/// These tests pin the request policy (the shared gate composed with the
/// record) and the placement arithmetic.
final class InlineTmuxHistoryRequestStateTests: XCTestCase {

    private let live = SurfaceId.live
    private let pane = SurfaceId("pane:7")

    // MARK: - Record defaults

    func testUnseenSurfaceIsOptimisticallyDeepenable() {
        let state = InlineTmuxHistoryRequestState()
        let record = state[live]
        XCTAssertTrue(record.canDeepen)
        XCTAssertFalse(record.requestInFlight)
        XCTAssertEqual(record.depth, 0)
        XCTAssertEqual(record.historySize, 0)
        XCTAssertNil(record.anchor)
        XCTAssertEqual(state.trackedSurfaceCount, 0)
    }

    // MARK: - Request latch

    func testRequestSubmittedLatchesAndRecordsPlacement() {
        var state = InlineTmuxHistoryRequestState()
        state.requestSubmitted(live, offsetY: 120, maxOffsetY: 900)

        let record = state[live]
        XCTAssertTrue(record.requestInFlight)
        XCTAssertEqual(record.anchor?.offsetY, 120)
        XCTAssertEqual(record.anchor?.maxOffsetY, 900)
        XCTAssertEqual(record.anchor?.distanceFromBottom, 780)
    }

    func testAnchorClampsOutOfRangePlacement() {
        var state = InlineTmuxHistoryRequestState()
        // A rubber-banded gesture can report a negative offset, and an
        // emptied buffer a negative max.
        state.requestSubmitted(live, offsetY: -40, maxOffsetY: 600)
        XCTAssertEqual(state[live].anchor?.offsetY, 0)

        state.requestSubmitted(live, offsetY: 900, maxOffsetY: 600)
        XCTAssertEqual(state[live].anchor?.offsetY, 600)

        state.requestSubmitted(live, offsetY: 10, maxOffsetY: -5)
        XCTAssertEqual(state[live].anchor?.offsetY, 0)
        XCTAssertEqual(state[live].anchor?.maxOffsetY, 0)
    }

    // MARK: - Settling

    func testSettleAnswersTheRequestAndReleasesTheLatch() {
        var state = InlineTmuxHistoryRequestState()
        state.requestSubmitted(live, offsetY: 100, maxOffsetY: 500)

        let settlement = state.settled(
            live,
            depth: 10_000,
            historySize: 7_009,
            canDeepen: false
        )

        XCTAssertTrue(settlement.answeredRequest)
        XCTAssertEqual(settlement.anchor?.offsetY, 100)
        XCTAssertEqual(settlement.anchor?.maxOffsetY, 500)
        XCTAssertEqual(settlement.record.depth, 10_000)
        XCTAssertEqual(settlement.record.historySize, 7_009)
        XCTAssertFalse(settlement.record.canDeepen)
        XCTAssertFalse(state[live].requestInFlight)
        XCTAssertNil(state[live].anchor)
    }

    /// Every inline `.deep` repaint settles, including the attach fill that
    /// no gesture asked for. That must update the record without moving the
    /// reader.
    func testUnrequestedSettleUpdatesRecordWithoutPlacement() {
        var state = InlineTmuxHistoryRequestState()

        let settlement = state.settled(
            live,
            depth: 2_000,
            historySize: 7_009,
            canDeepen: true
        )

        XCTAssertFalse(settlement.answeredRequest)
        XCTAssertNil(settlement.anchor)
        XCTAssertTrue(state[live].canDeepen)
        XCTAssertEqual(state[live].depth, 2_000)
    }

    /// An ignored / exhausted / aborted request still settles exactly once,
    /// so a second gesture is never blocked forever by the latch.
    func testIgnoredRequestStillClearsTheLatch() {
        var state = InlineTmuxHistoryRequestState()
        state.requestSubmitted(live, offsetY: 40, maxOffsetY: 400)
        state.settled(live, depth: 2_000, historySize: 1_200, canDeepen: false)

        XCTAssertFalse(state[live].requestInFlight)
        XCTAssertFalse(TmuxInlineHistoryGate.shouldRequest(
            canDeepen: state[live].canDeepen,
            requestInFlight: state[live].requestInFlight,
            rowsAboveOldest: 0,
            viewportRows: 45,
            crossedOldestRow: true
        ))
    }

    // MARK: - Rebind

    func testIdentityChangeResetsLadderButKeepsTheLatch() {
        var state = InlineTmuxHistoryRequestState()
        state.requestSubmitted(live, offsetY: 100, maxOffsetY: 500)
        state.settled(live, depth: 10_000, historySize: 400, canDeepen: false)
        state.requestSubmitted(live, offsetY: 60, maxOffsetY: 500)

        state.surfaceRebound(live, identityChanged: true)

        let record = state[live]
        XCTAssertTrue(record.canDeepen, "a new pane's history has not been credited yet")
        XCTAssertTrue(record.requestInFlight, "the ledger still owes exactly one settle")
        XCTAssertEqual(record.depth, 0)
        XCTAssertEqual(record.historySize, 0)
        XCTAssertNil(record.anchor, "the placement described the previous pane's transcript")
    }

    /// A window switch overtook the request: the settle that answers it
    /// describes the new pane, so the reader stays on that pane's tail
    /// instead of being carried to a distance measured against the old one.
    func testSettleAfterIdentityChangeReleasesTheLatchWithoutPlacing() {
        var state = InlineTmuxHistoryRequestState()
        state.requestSubmitted(live, offsetY: 60, maxOffsetY: 500)
        state.surfaceRebound(live, identityChanged: true)

        let settlement = state.settled(live, depth: 2_000, historySize: 900, canDeepen: false)

        XCTAssertTrue(settlement.answeredRequest, "the latch is still released exactly once")
        XCTAssertFalse(settlement.placesReader)
        XCTAssertNil(settlement.anchor)
        XCTAssertFalse(state[live].requestInFlight)
        XCTAssertFalse(state[live].placementInvalidated, "the next request starts clean")
        XCTAssertEqual(state[live].depth, 2_000)
    }

    /// The same-identity rebind is the deepen's own epoch change, so the
    /// settle that follows it places the reader as usual.
    func testSettleAfterSameIdentityRebindStillPlaces() {
        var state = InlineTmuxHistoryRequestState()
        state.requestSubmitted(live, offsetY: 60, maxOffsetY: 500)
        state.surfaceRebound(live, identityChanged: false)

        let settlement = state.settled(live, depth: 10_000, historySize: 7_009, canDeepen: false)

        XCTAssertTrue(settlement.placesReader)
        XCTAssertEqual(settlement.anchor?.offsetY, 60)
    }

    /// An identity change with no request in flight invalidates nothing:
    /// the next request placed on the new pane must still be honoured.
    func testIdentityChangeWithoutARequestDoesNotPoisonTheNextOne() {
        var state = InlineTmuxHistoryRequestState()
        state.surfaceRebound(live, identityChanged: true)
        state.requestSubmitted(live, offsetY: 30, maxOffsetY: 300)

        let settlement = state.settled(live, depth: 10_000, historySize: 5_000, canDeepen: false)

        XCTAssertTrue(settlement.placesReader)
        XCTAssertEqual(settlement.anchor?.offsetY, 30)
    }

    /// The deepen itself rebinds under a new owner epoch with the same
    /// window/pane. That must not clear exhaustion, or the ladder would loop.
    func testSameIdentityRebindLeavesTheRecordAlone() {
        var state = InlineTmuxHistoryRequestState()
        state.requestSubmitted(live, offsetY: 100, maxOffsetY: 500)
        state.settled(live, depth: 10_000, historySize: 400, canDeepen: false)
        state.requestSubmitted(live, offsetY: 60, maxOffsetY: 500)

        state.surfaceRebound(live, identityChanged: false)

        let record = state[live]
        XCTAssertFalse(record.canDeepen)
        XCTAssertTrue(record.requestInFlight)
        XCTAssertEqual(record.depth, 10_000)
        XCTAssertEqual(record.anchor?.offsetY, 60)
    }

    // MARK: - Placement arithmetic

    func testRestoredOffsetPreservesDistanceFromBottom() {
        var state = InlineTmuxHistoryRequestState()
        // Reader 780pt above the tail of a 900pt-deep transcript.
        state.requestSubmitted(live, offsetY: 120, maxOffsetY: 900)

        // The deepened capture tripled the local transcript.
        XCTAssertEqual(state.restoredOffsetY(live, newMaxOffsetY: 2_700), 1_920)
    }

    func testRestoredOffsetClampsWhenThePageDidNotGrow() {
        var state = InlineTmuxHistoryRequestState()
        state.requestSubmitted(live, offsetY: 10, maxOffsetY: 900)

        // Exhausted: the replacement page is no longer than the old one, so
        // the reader lands at the oldest row rather than a negative offset.
        XCTAssertEqual(state.restoredOffsetY(live, newMaxOffsetY: 200), 0)
        XCTAssertEqual(state.restoredOffsetY(live, newMaxOffsetY: 0), 0)
    }

    func testRestoredOffsetNeverExceedsTheNewTail() {
        let anchor = InlineTmuxHistoryRequestState.ScrollAnchor(
            offsetY: 500,
            maxOffsetY: 500
        )
        // At the tail: stay at the tail of the longer page.
        XCTAssertEqual(anchor.restoredOffsetY(newMaxOffsetY: 4_000), 4_000)
        XCTAssertEqual(anchor.restoredOffsetY(newMaxOffsetY: -12), 0)
    }

    func testRestoredOffsetIsNilWithoutARecordedRequest() {
        var state = InlineTmuxHistoryRequestState()
        state.settled(live, depth: 2_000, historySize: 9_000, canDeepen: true)
        XCTAssertNil(state.restoredOffsetY(live, newMaxOffsetY: 3_000))
    }

    // MARK: - Surface scoping

    func testRecordsAreScopedPerSurface() {
        var state = InlineTmuxHistoryRequestState()
        state.requestSubmitted(live, offsetY: 100, maxOffsetY: 500)
        state.settled(pane, depth: 10_000, historySize: 120, canDeepen: false)

        XCTAssertTrue(state[live].requestInFlight)
        XCTAssertFalse(state[pane].requestInFlight)
        XCTAssertTrue(state[live].canDeepen)
        XCTAssertFalse(state[pane].canDeepen)
        XCTAssertEqual(state.trackedSurfaceCount, 2)

        state.reset(pane)
        XCTAssertTrue(state[pane].canDeepen)
        XCTAssertEqual(state.trackedSurfaceCount, 1)

        state.reset()
        XCTAssertEqual(state.trackedSurfaceCount, 0)
        XCTAssertFalse(state[live].requestInFlight)
    }

    // MARK: - Grid pane surface ids

    /// The spelling has to match `TmuxController.inlinePaneSurfaceID` (private
    /// to the controller) exactly. Any other string names a surface the ledger
    /// never declared, so the fact is dropped and the gate never settles.
    func testPaneSurfaceIdMirrorsTheLedgerSpelling() {
        XCTAssertEqual(
            InlineTmuxHistoryRequestState.paneSurfaceID(PaneId(16)).rawValue,
            "pane:16"
        )
        XCTAssertEqual(
            InlineTmuxHistoryRequestState.paneID(in: SurfaceId("pane:16")),
            PaneId(16)
        )
    }

    func testPaneIdRejectsNonPaneSurfaces() {
        XCTAssertNil(InlineTmuxHistoryRequestState.paneID(in: .live))
        XCTAssertNil(InlineTmuxHistoryRequestState.paneID(in: SurfaceId("overlay:%16")))
        XCTAssertNil(InlineTmuxHistoryRequestState.paneID(in: SurfaceId("pane:%16")))
        XCTAssertNil(InlineTmuxHistoryRequestState.paneID(in: SurfaceId("pane:")))
    }

    /// A grid pane runs the same ladder as `.live`, independently: deepening
    /// one pane must not credit or exhaust its sibling.
    func testGridPanesRunIndependentLadders() {
        var state = InlineTmuxHistoryRequestState()
        let paneA = InlineTmuxHistoryRequestState.paneSurfaceID(PaneId(16))
        let paneB = InlineTmuxHistoryRequestState.paneSurfaceID(PaneId(35))

        state.requestSubmitted(paneA, offsetY: 90, maxOffsetY: 600)
        let settled = state.settled(paneA, depth: 10_000, historySize: 7_009, canDeepen: false)

        XCTAssertTrue(settled.answeredRequest)
        XCTAssertEqual(state.restoredOffsetY(paneA, newMaxOffsetY: 2_400), nil)
        XCTAssertFalse(state[paneA].canDeepen)
        XCTAssertTrue(state[paneB].canDeepen)
        XCTAssertFalse(state[paneB].requestInFlight)
        XCTAssertEqual(settled.anchor?.restoredOffsetY(newMaxOffsetY: 2_400), 1_890)

        // A pane whose surface is undeclared forgets everything.
        state.reset(paneA)
        XCTAssertTrue(state[paneA].canDeepen)
    }

    // MARK: - Composition with the shared gate

    /// The record feeds the shared rule and nothing else: no platform-local
    /// threshold may creep in beside `TmuxInlineHistoryGate`.
    func testGateComposesWithTheRecordAcrossOneDeepenCycle() {
        var state = InlineTmuxHistoryRequestState()
        let viewportRows = 45
        let band = viewportRows * TmuxInlineHistoryGate.prefetchViewports

        func shouldRequest(rowsAboveOldest: Int, crossedOldestRow: Bool = false) -> Bool {
            TmuxInlineHistoryGate.shouldRequest(
                canDeepen: state[live].canDeepen,
                requestInFlight: state[live].requestInFlight,
                rowsAboveOldest: rowsAboveOldest,
                viewportRows: viewportRows,
                crossedOldestRow: crossedOldestRow
            )
        }

        // Deep in the transcript: no prefetch.
        XCTAssertFalse(shouldRequest(rowsAboveOldest: band + 1))
        // Inside the prefetch band: ask.
        XCTAssertTrue(shouldRequest(rowsAboveOldest: band))

        state.requestSubmitted(live, offsetY: 30, maxOffsetY: 900)
        // Single flight: a second scroll frame must not re-ask.
        XCTAssertFalse(shouldRequest(rowsAboveOldest: 0, crossedOldestRow: true))

        state.settled(live, depth: 10_000, historySize: 7_009, canDeepen: false)
        // Exhausted: crossing the oldest row no longer fetches.
        XCTAssertFalse(shouldRequest(rowsAboveOldest: 0, crossedOldestRow: true))
    }
}
