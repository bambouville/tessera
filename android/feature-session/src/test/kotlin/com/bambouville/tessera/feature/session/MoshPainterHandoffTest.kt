package com.bambouville.tessera.feature.session

import com.bambouville.tessera.terminal.RenderOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MoshPainterHandoffTest {
    @Test
    fun firstNaturalOutputIsRejectedAndStartsOneExactOwnedRepaint() {
        val handoff = MoshPainterHandoff()
        handoff.begin(ownerA, naturalOutputFloor = 0, waitsForNaturalOutput = true)
        assertTrue(handoff.deferRepaintFence(71))

        assertEquals(
            MoshPainterHandoff.Admission.RejectAndStart(ownerA),
            handoff.admission(deliveryId = 1, repaintRequestId = null, liveOwner = ownerA),
        )
        assertEquals(
            MoshPainterHandoff.Start(ownerA, 9, listOf(71L)),
            handoff.start(requestId = 9),
        )
        assertEquals(
            MoshPainterHandoff.Admission.Reject,
            handoff.admission(deliveryId = 2, repaintRequestId = null, liveOwner = ownerA),
        )
        assertEquals(
            MoshPainterHandoff.Admission.AcceptOwned(ownerA),
            handoff.admission(deliveryId = 3, repaintRequestId = 9, liveOwner = ownerA),
        )
        assertEquals(
            MoshPainterHandoff.Admission.Reject,
            handoff.admission(deliveryId = 4, repaintRequestId = 10, liveOwner = ownerA),
        )

        assertEquals(
            MoshPainterHandoff.Resolution.Pending,
            handoff.noteRendered(9, deliveryId = 14, renderedFully = true, liveOwner = ownerA),
        )
        assertEquals(
            MoshPainterHandoff.Resolution.Completed(ownerA),
            handoff.resolve(9, outputTarget = 14, liveOwner = ownerA),
        )
        assertFalse(handoff.isActive)
        assertEquals(
            MoshPainterHandoff.Admission.PassThrough,
            handoff.admission(deliveryId = 15, repaintRequestId = null, liveOwner = ownerA),
        )
    }

    @Test
    fun onlyTheExactTargetCanCompleteAndRejectedTargetRearms() {
        val handoff = MoshPainterHandoff()
        handoff.begin(ownerA, naturalOutputFloor = 0, waitsForNaturalOutput = false)
        assertTrue(handoff.deferRepaintFence(3))
        requireNotNull(handoff.start(21))

        assertEquals(
            MoshPainterHandoff.Resolution.Pending,
            handoff.noteRendered(21, deliveryId = 99, renderedFully = true, liveOwner = ownerA),
        )
        assertEquals(
            MoshPainterHandoff.Resolution.Pending,
            handoff.resolve(21, outputTarget = 22, liveOwner = ownerA),
        )
        assertEquals(
            MoshPainterHandoff.Resolution.Rearmed(ownerA, 21, listOf(3L), retryAttempt = 1),
            handoff.noteRendered(21, deliveryId = 22, renderedFully = false, liveOwner = ownerA),
        )
        assertTrue(handoff.isActive)
        assertEquals(
            MoshPainterHandoff.Admission.RejectAndStart(ownerA),
            handoff.admission(deliveryId = 23, repaintRequestId = null, liveOwner = ownerA),
        )
    }

    @Test
    fun noOutputRearmsAndPreservesDeferredHistoryFence() {
        val handoff = MoshPainterHandoff()
        handoff.begin(ownerA, naturalOutputFloor = 0, waitsForNaturalOutput = false)
        assertTrue(handoff.deferRepaintFence(44))
        requireNotNull(handoff.start(31))

        assertEquals(
            MoshPainterHandoff.Resolution.Rearmed(ownerA, 31, listOf(44L), retryAttempt = 1),
            handoff.resolve(31, outputTarget = null, liveOwner = ownerA),
        )
        assertEquals(
            MoshPainterHandoff.Start(ownerA, 32, listOf(44L)),
            handoff.start(32),
        )
    }

    @Test
    fun exactReceiptTimeoutRearmsOnlyTheCurrentOwnerRequestAndTarget() {
        val handoff = MoshPainterHandoff()
        handoff.begin(ownerA, naturalOutputFloor = 0, waitsForNaturalOutput = false)
        assertTrue(handoff.deferRepaintFence(71))
        assertTrue(handoff.deferRepaintFence(72))
        requireNotNull(handoff.start(81))
        assertEquals(
            MoshPainterHandoff.Resolution.Pending,
            handoff.resolve(81, outputTarget = 17, liveOwner = ownerA),
        )

        assertEquals(
            MoshPainterHandoff.Resolution.Stale,
            handoff.receiptTimedOut(82, outputTarget = 17, liveOwner = ownerA),
        )
        assertEquals(
            MoshPainterHandoff.Resolution.Stale,
            handoff.receiptTimedOut(81, outputTarget = 18, liveOwner = ownerA),
        )
        assertEquals(
            MoshPainterHandoff.Resolution.Stale,
            handoff.receiptTimedOut(81, outputTarget = 17, liveOwner = ownerB),
        )
        assertEquals(
            MoshPainterHandoff.Resolution.Rearmed(ownerA, 81, listOf(71L, 72L), retryAttempt = 1),
            handoff.receiptTimedOut(81, outputTarget = 17, liveOwner = ownerA),
        )

        // The old target's delayed callback is no longer authorized to settle this handoff.
        assertEquals(
            MoshPainterHandoff.Resolution.Stale,
            handoff.noteRendered(81, deliveryId = 17, renderedFully = true, liveOwner = ownerA),
        )
        assertEquals(
            MoshPainterHandoff.Start(ownerA, 82, listOf(71L, 72L)),
            handoff.start(82),
        )
    }

    @Test
    fun rebindRetiresTheOldRequestAndRequiresANewNaturalBoundary() {
        val handoff = MoshPainterHandoff()
        handoff.begin(ownerA, naturalOutputFloor = 50, waitsForNaturalOutput = true)
        requireNotNull(handoff.start(51))

        handoff.begin(ownerB, naturalOutputFloor = 60, waitsForNaturalOutput = true)

        assertEquals(
            MoshPainterHandoff.Admission.Reject,
            handoff.admission(deliveryId = 59, repaintRequestId = 51, liveOwner = ownerB),
        )
        assertEquals(MoshPainterHandoff.Resolution.Stale, handoff.resolve(51, 8, ownerB))
        assertEquals(
            MoshPainterHandoff.Admission.RejectAndStart(ownerB),
            handoff.admission(deliveryId = 61, repaintRequestId = null, liveOwner = ownerB),
        )
    }

    @Test
    fun repaintArrivingAfterTheCausalCutMustBeQueuedSeparately() {
        val handoff = MoshPainterHandoff()
        handoff.begin(ownerA, naturalOutputFloor = 0, waitsForNaturalOutput = false)
        assertTrue(handoff.deferRepaintFence(null))
        requireNotNull(handoff.start(61))

        assertFalse(handoff.deferRepaintFence(62))
    }

    @Test
    fun preBindNaturalDeliveryDoesNotOpenTheCausalCut() {
        val handoff = MoshPainterHandoff()
        handoff.begin(ownerA, naturalOutputFloor = 80, waitsForNaturalOutput = true)

        assertEquals(
            MoshPainterHandoff.Admission.Reject,
            handoff.admission(deliveryId = 80, repaintRequestId = null, liveOwner = ownerA),
        )
        assertFalse(handoff.requestInFlight)
        assertEquals(
            MoshPainterHandoff.Admission.RejectAndStart(ownerA),
            handoff.admission(deliveryId = 81, repaintRequestId = null, liveOwner = ownerA),
        )
    }

    @Test
    fun naturalOutputAlreadySeenAboveTheFloorProvesTheBoundaryAtBegin() {
        val handoff = MoshPainterHandoff()
        // The selected window's frame (delivery 82) landed before the bind:
        // the floor was taken when the selection was queued, so it counts.
        handoff.begin(
            ownerA,
            naturalOutputFloor = 81,
            waitsForNaturalOutput = true,
            observedNaturalDeliveryHighWater = 82,
        )
        assertFalse(handoff.awaitingCausalBoundary)
        assertEquals(
            MoshPainterHandoff.Admission.RejectAndStart(ownerA),
            handoff.admission(deliveryId = null, repaintRequestId = null, liveOwner = ownerA),
        )
        assertEquals(
            MoshPainterHandoff.Start(ownerA, 5, emptyList()),
            handoff.start(5),
        )

        // Output at or below the floor is the previous window and stays closed.
        handoff.begin(
            ownerB,
            naturalOutputFloor = 90,
            waitsForNaturalOutput = true,
            observedNaturalDeliveryHighWater = 90,
        )
        assertTrue(handoff.awaitingCausalBoundary)
        assertEquals(
            MoshPainterHandoff.Admission.Reject,
            handoff.admission(deliveryId = 90, repaintRequestId = null, liveOwner = ownerB),
        )
        assertEquals(
            MoshPainterHandoff.Admission.RejectAndStart(ownerB),
            handoff.admission(deliveryId = 91, repaintRequestId = null, liveOwner = ownerB),
        )
    }

    @Test
    fun outputNewerThanTheSelectionFloorOpensTheBoundaryOnEitherSideOfACommit() {
        val handoff = MoshPainterHandoff()
        handoff.begin(ownerB, naturalOutputFloor = 91, waitsForNaturalOutput = true)

        assertEquals(
            MoshPainterHandoff.Admission.Reject,
            handoff.admission(deliveryId = 91, repaintRequestId = null, liveOwner = ownerB),
        )
        // A commit re-begins with the same floor; nothing seen so far is lost.
        handoff.begin(
            ownerB,
            naturalOutputFloor = 91,
            waitsForNaturalOutput = true,
            observedNaturalDeliveryHighWater = 91,
        )
        assertTrue(handoff.awaitingCausalBoundary)
        assertEquals(
            MoshPainterHandoff.Admission.RejectAndStart(ownerB),
            handoff.admission(deliveryId = 92, repaintRequestId = null, liveOwner = ownerB),
        )
        assertEquals(
            MoshPainterHandoff.Start(ownerB, 93, emptyList()),
            handoff.start(93),
        )
    }

    @Test
    fun acknowledgedQuietCanvasCanStartOneOwnedFallbackForTheExactOwner() {
        val handoff = MoshPainterHandoff()
        handoff.begin(ownerB, naturalOutputFloor = 101, waitsForNaturalOutput = true)

        assertEquals(
            "a timeout for a replaced owner must stay closed",
            MoshPainterHandoff.Admission.Reject,
            handoff.settleQuietCanvas(ownerA),
        )
        assertEquals(
            MoshPainterHandoff.Admission.RejectAndStart(ownerB),
            handoff.settleQuietCanvas(ownerB),
        )
        assertEquals(
            "the quiet fallback is edge-triggered",
            MoshPainterHandoff.Admission.Reject,
            handoff.settleQuietCanvas(ownerB),
        )
        assertEquals(
            MoshPainterHandoff.Start(ownerB, 102, emptyList()),
            handoff.start(102),
        )
        assertEquals(
            "a settled handoff with a request in flight does not settle again",
            MoshPainterHandoff.Admission.Reject,
            handoff.settleQuietCanvas(ownerB),
        )
    }

    @Test
    fun transportActivityFollowsThePaintersWindowNotTheActivePane() {
        val handoff = MoshPainterHandoff()
        // Focus moved to another pane of window 1 without history, so the
        // painter keeps pane 11's owner. SSP still shows that whole window.
        assertTrue(handoff.admitsTransportActivity(ownerA, transportGeneration = 7, activeWindowId = 1))
        assertFalse(
            "an older transport cannot report",
            handoff.admitsTransportActivity(ownerA, transportGeneration = 8, activeWindowId = 1),
        )
        assertFalse(
            "a departed window cannot report",
            handoff.admitsTransportActivity(ownerA, transportGeneration = 7, activeWindowId = 2),
        )

        // Past its causal boundary, so only the owner gate is left.
        handoff.begin(ownerB, naturalOutputFloor = 0, waitsForNaturalOutput = false)
        assertFalse(handoff.awaitingCausalBoundary)
        assertFalse(
            "a handoff to another owner holds the previous painter's activity",
            handoff.admitsTransportActivity(ownerA, transportGeneration = 7, activeWindowId = 1),
        )
        assertTrue(handoff.admitsTransportActivity(ownerB, transportGeneration = 7, activeWindowId = 2))
    }

    private companion object {
        val ownerA = RenderOwner(windowId = 1, paneId = 11, epoch = 1, transportGeneration = 7)
        val ownerB = RenderOwner(windowId = 2, paneId = 22, epoch = 2, transportGeneration = 7)
    }
}
