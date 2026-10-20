package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The two facts a platform is allowed to keep about inline (SSH+tmux) history.
 *
 * Every stateful decision — the depth ladder, exhaustion, single flight,
 * identity reset — belongs to the shared render ledger. What is asserted here
 * is only that this side mirrors the ledger's settle, refuses a second request
 * while one is outstanding, and can always release a latched gesture, because
 * a stuck `mHistoryScrollPending` freezes *all* local scrolling, not just the
 * deepening.
 */
class InlineTmuxHistoryTest {
    private fun owner(windowId: Int = 1, paneId: Int = 16, epoch: Long = 3L) =
        SharedTmuxRenderOwner(windowId = windowId, paneId = paneId, epoch = epoch)

    /** The gate under test is the shared rule; these fakes only record calls. */
    private val alwaysRequest = InlineTmuxHistoryGate { _, _, _, _, _ -> true }
    private val neverRequest = InlineTmuxHistoryGate { _, _, _, _, _ -> false }

    /**
     * A fixture standing in for `tessera_tmux_inline_history_should_request`,
     * which a JVM test cannot load. It is deliberately the *documented*
     * contract of `TmuxInlineHistoryGate` (two viewports of prefetch), not a
     * second copy of the production path: what these tests own is which
     * geometry Android hands that rule and how it derives the crossing. The
     * rule itself is covered by the Swift tests and the instrumented lane.
     */
    private val sharedRule = InlineTmuxHistoryGate {
            canDeepen, requestInFlight, rowsAboveOldest, viewportRows, crossedOldestRow ->
        when {
            !canDeepen || requestInFlight -> false
            crossedOldestRow -> true
            viewportRows <= 0 -> false
            else -> maxOf(0, rowsAboveOldest) <= viewportRows * 2
        }
    }

    private val openLadder = InlineTmuxHistoryRecord.Initial
        .settled(owner = owner(), depth = 2_000, historySize = 9_460, canDeepen = true)

    /**
     * Termux raises the `setHistoryScrollRequest` runnable on *every* upward
     * frame, not only at the clamp, so a runnable that claimed the crossing
     * unconditionally would deepen on the very first scroll-up and make the
     * prefetch band below dead code.
     */
    @Test
    fun theFirstScrollUpFarFromTheOldestRowDoesNotRequest() {
        assertFalse(
            inlineTmuxHistoryRequestDecision(
                record = openLadder,
                topRow = -10,
                availableRows = 2_000,
                viewportRows = 45,
                derivesCrossing = true,
                gate = sharedRule,
            ),
        )
    }

    /** Inside the prefetch band the capture round trip hides behind the scroll. */
    @Test
    fun aFrameWithinTwoViewportsOfTheOldestRowRequests() {
        assertEquals(89, rowsAboveOldest(topRow = -1_911, availableRows = 2_000))
        assertTrue(
            inlineTmuxHistoryRequestDecision(
                record = openLadder,
                topRow = -1_911,
                availableRows = 2_000,
                viewportRows = 45,
                derivesCrossing = true,
                gate = sharedRule,
            ),
        )
    }

    /**
     * The clamp branch runs after `setLocalScrollPosition` pinned the view to
     * the oldest row, so the crossing is read off that position.
     */
    @Test
    fun aClampedFrameAtTheOldestRowRequests() {
        assertTrue(
            inlineTmuxHistoryRequestDecision(
                record = openLadder,
                topRow = -2_000,
                availableRows = 2_000,
                viewportRows = 45,
                derivesCrossing = true,
                gate = sharedRule,
            ),
        )
    }

    /**
     * The draw listener is never the crossing. With no viewport measured yet
     * the band is disabled, and only a real crossing could still fire — which
     * this path is not allowed to claim.
     */
    @Test
    fun theDrawListenerNeverClaimsTheCrossing() {
        assertFalse(
            inlineTmuxHistoryRequestDecision(
                record = openLadder,
                topRow = -2_000,
                availableRows = 2_000,
                viewportRows = 0,
                derivesCrossing = false,
                gate = sharedRule,
            ),
        )
        assertTrue(
            inlineTmuxHistoryRequestDecision(
                record = openLadder,
                topRow = -2_000,
                availableRows = 2_000,
                viewportRows = 45,
                derivesCrossing = false,
                gate = sharedRule,
            ),
        )
    }

    /** An exhausted surface asks for nothing, however far the reader scrolls. */
    @Test
    fun anExhaustedLadderNeverRequestsFromEitherSignal() {
        val exhausted = InlineTmuxHistoryRecord.Initial
            .settled(owner = owner(), depth = 10_000, historySize = 7_009, canDeepen = false)

        assertFalse(
            inlineTmuxHistoryRequestDecision(
                record = exhausted,
                topRow = -7_009,
                availableRows = 7_009,
                viewportRows = 45,
                derivesCrossing = true,
                gate = sharedRule,
            ),
        )
    }

    @Test
    fun aSettleClearsTheLatchAndStoresWhatTheLedgerCredited() {
        val record = InlineTmuxHistoryRecord.Initial
            .requestSubmitted()
            .settled(owner = owner(), depth = 10_000, historySize = 7_009, canDeepen = false)

        assertEquals(owner(), record.owner)
        assertEquals(10_000, record.depth)
        assertEquals(7_009, record.historySize)
        assertFalse(record.canDeepen)
        assertFalse(record.requestInFlight)
    }

    /** A settle that still has room keeps the ladder open for the next rung. */
    @Test
    fun aSettleThatIsNotExhaustedLeavesTheLadderOpen() {
        val record = InlineTmuxHistoryRecord.Initial
            .settled(owner = owner(), depth = 2_000, historySize = 7_009, canDeepen = true)

        assertTrue(record.canDeepen)
        assertTrue(
            inlineTmuxHistoryShouldRequest(
                record = record,
                topRow = -1_990,
                availableRows = 2_000,
                viewportRows = 45,
                crossedOldestRow = false,
                gate = alwaysRequest,
            ),
        )
    }

    /**
     * The deepen itself rebinds the surface under a new owner epoch. That is
     * not an identity move, so the ledger's exhaustion belief survives it and
     * the outstanding request stays outstanding.
     */
    @Test
    fun anEpochOnlyRebindChangesNothing() {
        val record = InlineTmuxHistoryRecord.Initial
            .settled(owner = owner(), depth = 10_000, historySize = 7_009, canDeepen = false)
            .requestSubmitted()

        val rebound = record.ownerRebound(identityChanged = false)

        assertEquals(record, rebound)
    }

    /**
     * A window or pane move resets the ledger's inline state, so a stale
     * `canDeepen = false` must not outlive it — otherwise the new pane's
     * history is capped at the old pane's exhaustion. The in-flight latch is
     * kept: that request will still settle.
     */
    @Test
    fun anIdentityRebindReopensTheLadderAndKeepsTheOutstandingRequest() {
        val record = InlineTmuxHistoryRecord.Initial
            .settled(owner = owner(), depth = 10_000, historySize = 7_009, canDeepen = false)
            .requestSubmitted()

        val rebound = record.ownerRebound(identityChanged = true)

        assertTrue(rebound.canDeepen)
        assertTrue(rebound.requestInFlight)
        assertEquals(null, rebound.owner)
        assertEquals(0, rebound.depth)
        assertEquals(0, rebound.historySize)
    }

    /**
     * Single flight is the platform's half of the ledger's own admission rule.
     * A second request cannot be refused by the gate alone, because the gate
     * is told `requestInFlight` — this asserts the caller never even asks.
     */
    @Test
    fun aSecondRequestWhileOneIsInFlightIsRefusedWithoutConsultingTheGate() {
        var consulted = false
        val gate = InlineTmuxHistoryGate { _, _, _, _, _ ->
            consulted = true
            true
        }

        val requested = inlineTmuxHistoryShouldRequest(
            record = InlineTmuxHistoryRecord.Initial.requestSubmitted(),
            topRow = -2_000,
            availableRows = 2_000,
            viewportRows = 45,
            crossedOldestRow = true,
            gate = gate,
        )

        assertFalse(requested)
        assertFalse(consulted)
    }

    /** The watchdog releases the latch so the next gesture can ask again. */
    @Test
    fun aTimeoutReleasesTheLatchWithoutTouchingTheLadder() {
        val record = InlineTmuxHistoryRecord.Initial
            .settled(owner = owner(), depth = 2_000, historySize = 7_009, canDeepen = true)
            .requestSubmitted()

        val released = record.timedOut()

        assertFalse(released.requestInFlight)
        assertTrue(released.canDeepen)
        assertEquals(2_000, released.depth)
        assertTrue(
            inlineTmuxHistoryShouldRequest(
                record = released,
                topRow = -2_000,
                availableRows = 2_000,
                viewportRows = 45,
                crossedOldestRow = true,
                gate = alwaysRequest,
            ),
        )
    }

    /**
     * A surface that has never settled reports an open ladder, the same way
     * `TmuxInlineHistoryGate` documents for iOS: the ledger answers an
     * unnecessary request with a settle rather than a capture, whereas a
     * platform that assumed exhaustion would silently swallow the very first
     * scroll-up after attach.
     */
    @Test
    fun aSurfaceWithNoSettleYetIsTreatedAsAnOpenLadder() {
        var seenCanDeepen: Boolean? = null
        val gate = InlineTmuxHistoryGate { canDeepen, _, _, _, _ ->
            seenCanDeepen = canDeepen
            true
        }

        assertTrue(
            inlineTmuxHistoryShouldRequest(
                record = null,
                topRow = -2_000,
                availableRows = 2_000,
                viewportRows = 45,
                crossedOldestRow = true,
                gate = gate,
            ),
        )
        assertEquals(true, seenCanDeepen)
    }

    /** The shared rule is the only authority on the geometry question. */
    @Test
    fun theSharedGateDecidesAndItsAnswerIsNotSecondGuessed() {
        val record = InlineTmuxHistoryRecord.Initial
            .settled(owner = owner(), depth = 2_000, historySize = 7_009, canDeepen = true)

        assertFalse(
            inlineTmuxHistoryShouldRequest(
                record = record,
                topRow = -2_000,
                availableRows = 2_000,
                viewportRows = 45,
                crossedOldestRow = true,
                gate = neverRequest,
            ),
        )
    }

    /** What the gate is told about this surface comes from the record, not the caller. */
    @Test
    fun theRecordSuppliesTheLadderFactsTheGateIsGiven() {
        var seenCanDeepen: Boolean? = null
        var seenInFlight: Boolean? = null
        var seenRowsAbove: Int? = null
        var seenViewportRows: Int? = null
        var seenCrossed: Boolean? = null
        val gate = InlineTmuxHistoryGate { canDeepen, inFlight, rowsAbove, viewportRows, crossed ->
            seenCanDeepen = canDeepen
            seenInFlight = inFlight
            seenRowsAbove = rowsAbove
            seenViewportRows = viewportRows
            seenCrossed = crossed
            false
        }

        inlineTmuxHistoryShouldRequest(
            record = InlineTmuxHistoryRecord.Initial
                .settled(owner = owner(), depth = 2_000, historySize = 7_009, canDeepen = true),
            topRow = -1_940,
            availableRows = 2_000,
            viewportRows = 45,
            crossedOldestRow = false,
            gate = gate,
        )

        assertEquals(true, seenCanDeepen)
        assertEquals(false, seenInFlight)
        assertEquals(60, seenRowsAbove)
        assertEquals(45, seenViewportRows)
        assertEquals(false, seenCrossed)
    }

    /** `topRow` is zero at the tail and negative while scrolled back. */
    @Test
    fun rowsAboveOldestIsTheTranscriptDepthLeftAboveTheViewport() {
        assertEquals(2_000, rowsAboveOldest(topRow = 0, availableRows = 2_000))
        assertEquals(60, rowsAboveOldest(topRow = -1_940, availableRows = 2_000))
        assertEquals(0, rowsAboveOldest(topRow = -2_000, availableRows = 2_000))
    }

    /**
     * A gesture can outrun the transcript between the frame that measured it
     * and the frame that clamps it. A negative remainder is nonsense, and the
     * shared gate clamps the same way.
     */
    @Test
    fun aGestureThatRanPastTheOldestRowReportsNoRowsLeft() {
        assertEquals(0, rowsAboveOldest(topRow = -2_400, availableRows = 2_000))
    }
}
