package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxRenderHistoryPlacement
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.terminal.RenderOwner
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class MoshRenderHistoryRepaintRetryExecutorTest {
    /** The executor's callbacks throw on any outcome the test rules out; this makes that throw fail it. */
    @get:Rule
    val coroutineFailures = UncaughtCoroutineFailures()

    @Test
    fun defaultTimingMatchesTheProductionRetryContract() {
        val timing = MoshRenderHistoryRepaintRetryExecutor.Timing()

        assertEquals(4_000L, timing.receiptTimeoutMilliseconds)
        assertEquals(listOf(50L, 200L, 1_000L), timing.retryDelaysMilliseconds)
    }

    @Test
    fun targetNullThenMissingReceiptRetryReusesTheOneStagedFenceAndCapture() = runBlocking {
        val serialDispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        val testScope = coroutineFailures.scope(serialDispatcher)
        try {
            val deliveries = Collections.synchronizedList(mutableListOf<MoshRenderHistoryDeliveryFence.Delivery>())
            val fence = MoshRenderHistoryDeliveryFence(deliveries::add)
            val owner = RenderOwner(windowId = 1, paneId = 2, epoch = 3, transportGeneration = 4)
            val capturedBytes = "captured history only once".encodeToByteArray()
            var captureStages = 0
            var nextRequestId = 100L
            val repaintRequestIds = mutableListOf<Long>()
            val repaintStartedAtNanos = mutableMapOf<Long, Long>()
            val rearmed = mutableListOf<String>()
            val timing = MoshRenderHistoryRepaintRetryExecutor.Timing(
                receiptTimeoutMilliseconds = 100,
                retryDelaysMilliseconds = listOf(5),
            )
            val executor = MoshRenderHistoryRepaintRetryExecutor(
                scope = testScope,
                fence = fence,
                allocateRepaintRequestId = {
                    nextRequestId += 1
                    nextRequestId
                },
                forceFullRepaint = { requestId ->
                    synchronized(repaintRequestIds) {
                        repaintRequestIds += requestId
                        repaintStartedAtNanos[requestId] = System.nanoTime()
                    }
                    when (requestId) {
                        101L -> null // The driver supplied no delivery target.
                        102L -> 202L // Its receipt never arrives, so watchdog must retry.
                        103L -> 203L
                        else -> error("unexpected repaint request $requestId")
                    }
                },
                onSequenceExhausted = { error("request sequence must not exhaust") },
                onUnavailable = { detail -> error("fence unexpectedly unavailable: $detail") },
                onPartialAttach = { detail -> error("fence unexpectedly partially attached: $detail") },
                onRearmed = { detail -> synchronized(rearmed) { rearmed += detail } },
                onFullFrameFailure = { failure -> throw failure },
                timing = timing,
                launchDispatcher = serialDispatcher,
            )

            var stagedFenceId = 0L
            withContext(serialDispatcher) {
                // This models the one capture/stage effect from the ledger.
                captureStages += 1
                fence.stageHistory("overlay:%2", owner, capturedBytes)
                stagedFenceId = requireNotNull(fence.reserveCorrelatedRepaint(owner))
                assertTrue(fence.markReady("overlay:%2", owner, ready(owner)))
                executor.run(listOf(stagedFenceId))
            }

            awaitCondition {
                synchronized(repaintRequestIds) {
                    repaintRequestIds == listOf(101L, 102L, 103L)
                }
            }

            // Request 103 cannot be a target-null retry: it begins only after
            // request 102's real receipt watchdog has elapsed, then its retry delay.
            synchronized(repaintRequestIds) {
                assertTrue(
                    repaintStartedAtNanos.getValue(103L) - repaintStartedAtNanos.getValue(102L) >=
                        TimeUnit.MILLISECONDS.toNanos(timing.receiptTimeoutMilliseconds),
                )
            }
            assertEquals(
                listOf(
                    "stage=target-null request=101 fences=[$stagedFenceId]",
                    "stage=target-timeout request=102 target=202 fences=[$stagedFenceId]",
                ),
                synchronized(rearmed) { rearmed.toList() },
            )

            withContext(serialDispatcher) {
                fence.noteTransportOutputResult(
                    deliveryId = 203,
                    repaintRequestId = 103,
                    renderedFully = true,
                    livePainterOwner = owner,
                )
                executor.cancelReceiptWatchdog(103)
            }
            awaitCondition { synchronized(deliveries) { deliveries.size == 1 } }

            assertEquals(1, captureStages)
            assertEquals(listOf(101L, 102L, 103L), synchronized(repaintRequestIds) { repaintRequestIds.toList() })
            val delivery = synchronized(deliveries) { deliveries.single() }
            assertEquals("overlay:%2", delivery.surfaceId)
            assertEquals(owner, delivery.owner)
            assertEquals(103L, delivery.repaintRequestId)
            assertArrayEquals(capturedBytes, delivery.bytes)
        } finally {
            testScope.cancel()
            serialDispatcher.close()
        }
    }

    private suspend fun awaitCondition(condition: () -> Boolean) {
        withTimeout(1_000) {
            while (!condition()) delay(1)
        }
    }

    private fun ready(owner: RenderOwner) = MoshRenderHistoryDeliveryFence.Ready(
        owner = SharedTmuxRenderOwner(owner.windowId, owner.paneId, owner.epoch),
        depth = 240,
        historySize = 300,
        placement = SharedTmuxRenderHistoryPlacement.Bottom,
    )
}
