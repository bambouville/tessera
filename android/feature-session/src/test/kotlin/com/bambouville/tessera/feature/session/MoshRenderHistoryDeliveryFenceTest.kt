package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxRenderHistoryPlacement
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.terminal.RenderOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MoshRenderHistoryDeliveryFenceTest {
    @Test
    fun correlatedRepaintMayTargetTheStillUnboundMoshPainter() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        fence.stageHistory("overlay:22", painterB, "HISTORY".encodeToByteArray())
        val fenceId = requireNotNull(fence.beginCorrelatedRepaint(91, painterOwner = null))

        val admission = fence.admitTransportOutput(repaintRequestId = 91, livePainterOwner = null)
        assertTrue(admission.accepted)
        assertEquals(null, admission.feedOwner)
        fence.noteTransportOutputResult(7, 91, renderedFully = true, livePainterOwner = null)
        assertTrue(fence.resolveRepaint(fenceId, 7))
        assertTrue(
            fence.markReady(
                "overlay:22",
                painterB,
                ready(painterB),
            ),
        )
        assertEquals(listOf("overlay:22"), deliveries.map { it.surfaceId })
    }

    @Test
    fun historyWaitsForItsExactFullyRenderedReceipt() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        fence.stageHistory("live", ownerA, "history".encodeToByteArray())
        val repaint = requireNotNull(
            fence.beginCorrelatedRepaint(repaintRequestId = 91, painterOwner = painterA),
        )
        assertTrue(fence.markReady("live", ownerA, ready(ownerA)))
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 7))

        val admission = fence.admitTransportOutput(repaintRequestId = 91, livePainterOwner = painterA)
        assertTrue(admission.accepted)
        assertEquals(painterA, admission.feedOwner)
        fence.noteTransportOutputResult(
            deliveryId = 8,
            repaintRequestId = 91,
            renderedFully = true,
            livePainterOwner = painterA,
        )
        assertTrue(deliveries.isEmpty())

        fence.noteTransportOutputResult(
            deliveryId = 7,
            repaintRequestId = 91,
            renderedFully = true,
            livePainterOwner = painterA,
        )

        assertEquals(listOf("live"), deliveries.map { it.surfaceId })
        assertEquals("history", deliveries.single().bytes.decodeToString())
    }

    @Test
    fun largerUnrelatedReceiptCannotReleaseAnOlderFence() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        fence.stageHistory("live", ownerA, byteArrayOf(1))
        val repaint = requireNotNull(fence.beginCorrelatedRepaint(91, painterA))
        assertTrue(fence.markReady("live", ownerA, ready(ownerA)))
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 7))

        fence.noteTransportOutputResult(8, 91, renderedFully = true, livePainterOwner = painterA)

        assertTrue(deliveries.isEmpty())
    }

    @Test
    fun rejectedOrPartialExactFrameCannotReleaseHistory() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        fence.stageHistory("live", ownerA, byteArrayOf(1))
        val repaint = requireNotNull(fence.beginCorrelatedRepaint(91, painterA))
        assertTrue(fence.markReady("live", ownerA, ready(ownerA)))
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 7))

        assertFalse(
            fence.admitTransportOutput(repaintRequestId = 91, livePainterOwner = painterB).accepted,
        )
        fence.noteTransportOutputResult(7, 91, renderedFully = false, livePainterOwner = painterA)
        // A stale duplicate callback cannot rewrite the rejected delivery.
        fence.noteTransportOutputResult(7, 91, renderedFully = true, livePainterOwner = painterA)

        assertTrue(deliveries.isEmpty())
    }

    @Test
    fun wrongRequestAndWrongCurrentPainterOwnerCannotReleaseHistory() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        fence.stageHistory("live", ownerA, byteArrayOf(1))
        val repaint = requireNotNull(fence.beginCorrelatedRepaint(91, painterA))
        assertTrue(fence.markReady("live", ownerA, ready(ownerA)))
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 7))

        val genericWrongRequest = fence.admitTransportOutput(
            repaintRequestId = 92,
            livePainterOwner = painterA,
        )
        assertTrue(genericWrongRequest.accepted)
        assertNull(genericWrongRequest.feedOwner)
        fence.noteTransportOutputResult(7, 92, renderedFully = true, livePainterOwner = painterA)
        fence.noteTransportOutputResult(7, 91, renderedFully = true, livePainterOwner = painterB)

        assertTrue(deliveries.isEmpty())
    }

    @Test
    fun overlayHistoryUsesTheCapturedLivePainterOwnerForAdmission() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        fence.stageHistory("overlay:%22", ownerB, byteArrayOf(2))
        val repaint = requireNotNull(fence.beginCorrelatedRepaint(91, painterA))
        assertTrue(fence.markReady("overlay:%22", ownerB, ready(ownerB)))
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 7))

        val admission = fence.admitTransportOutput(repaintRequestId = 91, livePainterOwner = painterA)
        assertTrue(admission.accepted)
        assertEquals(painterA, admission.feedOwner)
        assertFalse(fence.admitTransportOutput(repaintRequestId = 91, livePainterOwner = ownerB).accepted)
        fence.noteTransportOutputResult(7, 91, renderedFully = true, livePainterOwner = painterA)

        assertEquals(listOf("overlay:%22"), deliveries.map { it.surfaceId })
        assertEquals(ownerB, deliveries.single().owner)
    }

    @Test
    fun acceptedReceiptBeforeDriverResolutionStillRequiresTheMatchingTarget() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        fence.stageHistory("live", ownerA, byteArrayOf(1))
        val repaint = requireNotNull(fence.beginCorrelatedRepaint(91, painterA))
        assertTrue(fence.markReady("live", ownerA, ready(ownerA)))

        fence.noteTransportOutputResult(7, 91, renderedFully = true, livePainterOwner = painterA)
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 7))

        assertEquals(listOf("live"), deliveries.map { it.surfaceId })
    }

    @Test
    fun deferredFenceCanRearmBehindANewExactRequestWithoutLosingHistory() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        fence.stageHistory("live", ownerA, byteArrayOf(1))
        val repaint = requireNotNull(fence.reserveCorrelatedRepaint(painterA))
        assertTrue(fence.markReady("live", ownerA, ready(ownerA)))

        assertTrue(fence.attachTransportRequest(repaint, repaintRequestId = 91))
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 7))
        fence.noteTransportOutputResult(7, 91, renderedFully = false, livePainterOwner = painterA)
        assertTrue(fence.rearmCorrelatedRepaint(repaint, repaintRequestId = 91))
        assertFalse(fence.admitTransportOutput(91, painterA).accepted)
        assertTrue(deliveries.isEmpty())

        assertTrue(fence.attachTransportRequest(repaint, repaintRequestId = 92))
        fence.noteTransportOutputResult(8, 92, renderedFully = true, livePainterOwner = painterA)
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 8))

        assertEquals(listOf("live"), deliveries.map { it.surfaceId })
    }

    @Test
    fun entriesRemainGloballyFifoAfterTheirOwnExactReceiptsArrive() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        fence.stageHistory("live", ownerA, byteArrayOf(1))
        val first = requireNotNull(fence.beginCorrelatedRepaint(1, painterA))
        fence.stageHistory("overlay:%22", ownerB, byteArrayOf(2))
        val second = requireNotNull(fence.beginCorrelatedRepaint(2, painterA))
        assertTrue(fence.markReady("live", ownerA, ready(ownerA)))
        assertTrue(fence.markReady("overlay:%22", ownerB, ready(ownerB)))
        assertTrue(fence.resolveRepaint(first, 11))
        assertTrue(fence.resolveRepaint(second, 12))

        fence.noteTransportOutputResult(12, 2, renderedFully = true, livePainterOwner = painterA)
        assertTrue(deliveries.isEmpty())
        fence.noteTransportOutputResult(11, 1, renderedFully = true, livePainterOwner = painterA)

        assertEquals(listOf("live", "overlay:%22"), deliveries.map { it.surfaceId })
    }

    @Test
    fun noOutputTargetCanRearmBehindALaterExactRequestAndDeliverOnce() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        fence.stageHistory("live", ownerA, byteArrayOf(1))
        val noOutput = requireNotNull(fence.beginCorrelatedRepaint(40, painterA))
        assertFalse(fence.resolveRepaint(noOutput, absoluteOutputTarget = null))
        assertTrue(fence.markReady("live", ownerA, ready(ownerA)))
        assertEquals(listOf(noOutput), fence.rearmRequest(40, expectedOutputTarget = null))
        assertFalse(fence.admitTransportOutput(40, painterA).accepted)

        assertTrue(fence.attachTransportRequest(noOutput, repaintRequestId = 41))
        assertTrue(fence.resolveRepaint(noOutput, absoluteOutputTarget = 12))
        fence.noteTransportOutputResult(13, 41, renderedFully = true, livePainterOwner = painterA)
        assertTrue(deliveries.isEmpty())

        fence.noteTransportOutputResult(12, 41, renderedFully = true, livePainterOwner = painterA)
        // A duplicate exact receipt must not replay the delivery after drain.
        fence.noteTransportOutputResult(12, 41, renderedFully = true, livePainterOwner = painterA)

        assertEquals(listOf("live"), deliveries.map { it.surfaceId })
        assertEquals(1, deliveries.size)
    }

    @Test
    fun timedOutExactTargetCanRearmAndLaterExactReceiptDeliversOnce() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        fence.stageHistory("overlay:%22", ownerB, byteArrayOf(2))
        val repaint = requireNotNull(fence.beginCorrelatedRepaint(51, painterA))
        assertTrue(fence.markReady("overlay:%22", ownerB, ready(ownerB)))
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 9))

        // The receipt watchdog owns only this precise request/target pair.
        assertEquals(listOf(repaint), fence.rearmRequest(51, expectedOutputTarget = 9))
        assertFalse(fence.admitTransportOutput(51, painterA).accepted)
        fence.noteTransportOutputResult(9, 51, renderedFully = true, livePainterOwner = painterA)
        assertTrue(deliveries.isEmpty())

        assertTrue(fence.attachTransportRequest(repaint, repaintRequestId = 52))
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 10))
        fence.noteTransportOutputResult(10, 52, renderedFully = true, livePainterOwner = painterA)
        // A late stale receipt cannot duplicate or replace the new one.
        fence.noteTransportOutputResult(9, 51, renderedFully = true, livePainterOwner = painterA)

        assertEquals(listOf("overlay:%22"), deliveries.map { it.surfaceId })
        assertEquals(1, deliveries.size)
    }

    @Test
    fun targetNullThenMissingReceiptRetryRetainsOneCaptureAndDeliversOnlyTheExactTuple() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        var captureCommands = 0

        // The ledger's capture effect runs once. Both retry paths below must
        // re-use this staged fence, never request or stage another capture.
        captureCommands += 1
        fence.stageHistory("overlay:%22", ownerB, byteArrayOf(2))
        val repaint = requireNotNull(fence.reserveCorrelatedRepaint(painterA))

        assertTrue(fence.attachTransportRequest(repaint, repaintRequestId = 101))
        // AndroidMoshTransport returned no output target. The production
        // adapter rearms this exact request and schedules only a repaint.
        assertEquals(listOf(repaint), fence.rearmRequest(101, expectedOutputTarget = null))
        assertEquals(1, captureCommands)

        assertTrue(fence.attachTransportRequest(repaint, repaintRequestId = 102))
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 900))
        assertTrue(fence.markReady("overlay:%22", ownerB, ready(ownerB)))
        // The four-second receipt watchdog owns request 102 / output 900
        // atomically. A missing receipt may rearm only that same fence.
        assertEquals(listOf(repaint), fence.rearmRequest(102, expectedOutputTarget = 900))
        assertEquals(1, captureCommands)
        assertFalse(fence.admitTransportOutput(102, painterA).accepted)

        assertTrue(fence.attachTransportRequest(repaint, repaintRequestId = 103))
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 901))
        fence.noteTransportOutputResult(901, 103, renderedFully = true, livePainterOwner = painterA)
        // The old timed-out frame is stale and must not add a second delivery.
        fence.noteTransportOutputResult(900, 102, renderedFully = true, livePainterOwner = painterA)

        assertEquals(1, captureCommands)
        assertEquals(1, deliveries.size)
        assertEquals("overlay:%22", deliveries.single().surfaceId)
        assertEquals(ownerB, deliveries.single().owner)
        assertEquals(103, deliveries.single().repaintRequestId)
    }

    @Test
    fun rearmedRetryIsDiscardedOnOwnerGenerationOrSurfaceInvalidation() {
        data class Invalidation(
            val name: String,
            val apply: (MoshRenderHistoryDeliveryFence) -> Unit,
        )
        val invalidations = listOf(
            Invalidation("owner") { fence ->
                fence.retireSurfaceUnlessOwnedBy(
                    surfaceId = "overlay:%22",
                    owner = ownerB.copy(epoch = ownerB.epoch + 1),
                )
            },
            Invalidation("generation") { fence -> fence.discardPending() },
            Invalidation("surface") { fence -> fence.discardSurface("overlay:%22") },
        )

        invalidations.forEach { invalidation ->
            val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
            val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
            fence.stageHistory("overlay:%22", ownerB, byteArrayOf(2))
            val repaint = requireNotNull(fence.beginCorrelatedRepaint(201, painterA))
            assertTrue(fence.markReady("overlay:%22", ownerB, ready(ownerB)))
            assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 902))
            assertEquals(listOf(repaint), fence.rearmRequest(201, expectedOutputTarget = 902))

            invalidation.apply(fence)

            assertFalse(
                "${invalidation.name} invalidation must prevent a queued retry from attaching",
                fence.attachTransportRequest(repaint, repaintRequestId = 202),
            )
            fence.noteTransportOutputResult(903, 202, renderedFully = true, livePainterOwner = painterA)
            assertTrue("${invalidation.name} invalidation must not deliver staged bytes", deliveries.isEmpty())
        }
    }

    @Test
    fun rearmingThroughARequestRetiresEveryLateReceiptForThatRequest() {
        val deliveries = mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>()
        val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
        fence.stageHistory("live", ownerA, byteArrayOf(1))
        val repaint = requireNotNull(fence.beginCorrelatedRepaint(61, painterA))
        assertTrue(fence.markReady("live", ownerA, ready(ownerA)))
        assertTrue(fence.resolveRepaint(repaint, absoluteOutputTarget = 17))

        assertEquals(listOf(repaint), fence.rearmRequest(61, expectedOutputTarget = 17))
        assertFalse(fence.admitTransportOutput(61, painterA).accepted)
        fence.noteTransportOutputResult(17, 61, renderedFully = true, livePainterOwner = painterA)
        fence.noteTransportOutputResult(18, 61, renderedFully = true, livePainterOwner = painterA)

        assertTrue(deliveries.isEmpty())
    }

    @Test
    fun genericFramesAreAcceptedButRemainUnowned() {
        val fence = MoshRenderHistoryDeliveryFence { }

        val admission = fence.admitTransportOutput(repaintRequestId = null, livePainterOwner = painterA)

        assertTrue(admission.accepted)
        assertNull(admission.feedOwner)
    }

    private fun ready(owner: RenderOwner) = MoshRenderHistoryDeliveryFence.Ready(
        owner = SharedTmuxRenderOwner(owner.windowId, owner.paneId, owner.epoch),
        depth = 240,
        historySize = 300,
        placement = SharedTmuxRenderHistoryPlacement.Bottom,
    )

    private companion object {
        val painterA = RenderOwner(windowId = 1, paneId = 11, epoch = 1, transportGeneration = 7)
        val painterB = RenderOwner(windowId = 2, paneId = 22, epoch = 2, transportGeneration = 7)
        val ownerA = RenderOwner(windowId = 3, paneId = 33, epoch = 3, transportGeneration = 7)
        val ownerB = RenderOwner(windowId = 4, paneId = 44, epoch = 4, transportGeneration = 7)
    }
}
