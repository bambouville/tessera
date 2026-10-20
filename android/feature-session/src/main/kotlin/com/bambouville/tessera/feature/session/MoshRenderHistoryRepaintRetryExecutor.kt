package com.bambouville.tessera.feature.session

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Drives the full-frame repaint side of a staged Mosh render-history fence.
 *
 * A retry is deliberately only another forced repaint. The capture has already
 * been staged in [MoshRenderHistoryDeliveryFence], and rearming preserves that
 * exact staged entry until its authoritative receipt arrives or normal fence
 * invalidation discards it.
 */
internal class MoshRenderHistoryRepaintRetryExecutor(
    private val scope: CoroutineScope,
    private val fence: MoshRenderHistoryDeliveryFence,
    private val allocateRepaintRequestId: () -> Long?,
    private val forceFullRepaint: suspend (repaintRequestId: Long) -> Long?,
    private val onSequenceExhausted: () -> Unit,
    private val onUnavailable: (String) -> Unit,
    private val onPartialAttach: (String) -> Unit,
    private val onRearmed: (String) -> Unit,
    private val onFullFrameFailure: (Throwable) -> Unit,
    private val timing: Timing = Timing(),
    private val launchDispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
) {
    internal data class Timing(
        val receiptTimeoutMilliseconds: Long = DEFAULT_RECEIPT_TIMEOUT_MILLISECONDS,
        val retryDelaysMilliseconds: List<Long> = DEFAULT_RETRY_DELAYS_MILLISECONDS,
    ) {
        init {
            require(receiptTimeoutMilliseconds > 0)
            require(retryDelaysMilliseconds.isNotEmpty())
            require(retryDelaysMilliseconds.all { it >= 0 })
        }

        fun retryDelayMilliseconds(retryAttempt: Int): Long =
            retryDelaysMilliseconds[
                (retryAttempt - 1).coerceIn(0, retryDelaysMilliseconds.lastIndex)
            ]
    }

    private val receiptWatchdogs = mutableMapOf<Long, Job>()

    suspend fun run(
        fenceIds: List<Long>,
        retryAttempt: Int = 0,
    ) {
        if (fenceIds.isEmpty()) return
        val repaintRequestId = allocateRepaintRequestId()
        if (repaintRequestId == null) {
            fence.discardPending()
            onSequenceExhausted()
            return
        }
        val attachedFenceIds = fenceIds.filter {
            fence.attachTransportRequest(it, repaintRequestId)
        }
        if (attachedFenceIds.isEmpty()) {
            onUnavailable("request=$repaintRequestId attach stale fences=$fenceIds")
            return
        }
        if (attachedFenceIds.size != fenceIds.size) {
            onPartialAttach("request=$repaintRequestId attached=$attachedFenceIds requested=$fenceIds")
        }
        val outputTarget = try {
            forceFullRepaint(repaintRequestId)
        } catch (failure: Throwable) {
            if (failure is CancellationException) throw failure
            onFullFrameFailure(failure)
            null
        }
        if (outputTarget == null) {
            val rearmed = fence.rearmRequest(
                repaintRequestId = repaintRequestId,
                expectedOutputTarget = null,
            )
            onRearmed("stage=target-null request=$repaintRequestId fences=$rearmed")
            if (rearmed.isNotEmpty()) {
                scheduleRetry(rearmed, retryAttempt + 1)
            }
            return
        }
        val resolved = attachedFenceIds.filter { fenceId ->
            fence.resolveRepaint(fenceId, outputTarget)
        }
        if (resolved.isEmpty()) {
            onUnavailable("request=$repaintRequestId target=$outputTarget resolve stale")
            return
        }
        armReceiptWatchdog(
            repaintRequestId = repaintRequestId,
            outputTarget = outputTarget,
            retryAttempt = retryAttempt,
        )
    }

    fun scheduleRetry(
        fenceIds: List<Long>,
        retryAttempt: Int,
    ) {
        scope.launch(launchDispatcher) {
            delay(timing.retryDelayMilliseconds(retryAttempt))
            run(fenceIds, retryAttempt)
        }
    }

    fun armReceiptWatchdog(
        repaintRequestId: Long,
        outputTarget: Long,
        retryAttempt: Int,
    ) {
        receiptWatchdogs.remove(repaintRequestId)?.cancel()
        receiptWatchdogs[repaintRequestId] = scope.launch(launchDispatcher) {
            delay(timing.receiptTimeoutMilliseconds)
            receiptWatchdogs.remove(repaintRequestId)
            val rearmed = fence.rearmRequest(
                repaintRequestId = repaintRequestId,
                expectedOutputTarget = outputTarget,
            )
            if (rearmed.isEmpty()) return@launch
            onRearmed(
                "stage=target-timeout request=$repaintRequestId target=$outputTarget fences=$rearmed",
            )
            scheduleRetry(rearmed, retryAttempt + 1)
        }
    }

    fun cancelReceiptWatchdog(repaintRequestId: Long) {
        receiptWatchdogs.remove(repaintRequestId)?.cancel()
    }

    fun cancelAllReceiptWatchdogs() {
        receiptWatchdogs.values.forEach(Job::cancel)
        receiptWatchdogs.clear()
    }

    private companion object {
        const val DEFAULT_RECEIPT_TIMEOUT_MILLISECONDS = 4_000L
        val DEFAULT_RETRY_DELAYS_MILLISECONDS = listOf(50L, 200L, 1_000L)
    }
}
