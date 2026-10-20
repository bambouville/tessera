package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxRenderHistoryPlacement
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.terminal.RenderOwner

/**
 * Orders side-channel history behind the Mosh framebuffer it requested.
 *
 * A native force-repaint callback has only enqueued bytes. The main terminal
 * consumer is a later hop, so revealing captured history at callback return
 * lets that framebuffer overwrite the capture. This fence holds the owned
 * history until the consumer has fully rendered the exact framebuffer delivery
 * the driver allocated for that repaint request.
 * Entries are globally FIFO because all surfaces share one Mosh output stream.
 */
internal class MoshRenderHistoryDeliveryFence(
    private val onDelivery: (Delivery) -> Unit,
) {
    data class Ready(
        val owner: SharedTmuxRenderOwner,
        val depth: Int,
        val historySize: Int,
        val placement: SharedTmuxRenderHistoryPlacement,
    )

    data class Delivery(
        val surfaceId: String,
        val owner: RenderOwner,
        val bytes: ByteArray,
        val ready: Ready,
        val repaintRequestId: Long,
    )

    /**
     * The admission decision for one transport frame. Correlated repaint bytes
     * must be fed as [feedOwner], while generic Mosh output remains unowned.
     */
    data class TransportOutputAdmission(
        val accepted: Boolean,
        val feedOwner: RenderOwner?,
    ) {
        companion object {
            val Rejected = TransportOutputAdmission(accepted = false, feedOwner = null)
            val Generic = TransportOutputAdmission(accepted = true, feedOwner = null)
        }
    }

    private sealed interface RepaintTarget {
        data object Unpaired : RepaintTarget
        data object AwaitingDriver : RepaintTarget
        data class Output(val absoluteCount: Long) : RepaintTarget
    }

    /** The outcome of one receipt-bearing output delivery. */
    private data class Receipt(
        val renderedFully: Boolean,
        val livePainterOwner: RenderOwner?,
    )

    private data class Entry(
        val id: Long,
        val surfaceId: String,
        val owner: RenderOwner,
        val bytes: ByteArray,
        var painterOwner: RenderOwner? = null,
        var repaintRequestId: Long? = null,
        var repaintTarget: RepaintTarget = RepaintTarget.Unpaired,
        var ready: Ready? = null,
        val receipts: MutableMap<Long, Receipt> = mutableMapOf(),
        var acceptedDeliveryId: Long? = null,
    )

    private val entries = mutableListOf<Entry>()
    private var nextId = 0L
    private var unfencedCandidateId: Long? = null
    private val retiredRepaintRequestIds = mutableSetOf<Long>()
    private var retiredRepaintRequestUpperBound = 0L

    fun stageHistory(surfaceId: String, owner: RenderOwner, bytes: ByteArray) {
        discardSurface(surfaceId)
        nextId += 1
        if (nextId <= 0) nextId = 1
        entries += Entry(
            id = nextId,
            surfaceId = surfaceId,
            owner = owner,
            bytes = bytes.copyOf(),
        )
        unfencedCandidateId = nextId
    }

    /**
     * Pairs the immediately preceding history capture with its forced repaint.
     *
     * [painterOwner] is the live Mosh-painted surface at this instant. It can
     * differ from the history entry's owner for an overlay capture, and it is
     * the only owner that may receive the repaint bytes.
     *
     * Returns null for a generic repaint that has no preceding history feed.
     */
    fun beginCorrelatedRepaint(
        repaintRequestId: Long,
        painterOwner: RenderOwner?,
    ): Long? {
        if (repaintRequestId <= 0 || isRetired(repaintRequestId)) return null
        val id = reserveCorrelatedRepaint(painterOwner) ?: return null
        return id.takeIf { attachTransportRequest(it, repaintRequestId) }
    }

    /**
     * Reserves the immediately preceding history capture before a transport
     * request exists. The causal painter handoff uses this split phase: the
     * ledger can order history -> repaint -> historyReady now, while the
     * request itself must wait for a post-bind Mosh boundary.
     */
    fun reserveCorrelatedRepaint(painterOwner: RenderOwner?): Long? {
        val id = unfencedCandidateId
        unfencedCandidateId = null
        val entry = entries.firstOrNull { it.id == id && it.repaintTarget == RepaintTarget.Unpaired }
            ?: return null
        entry.painterOwner = painterOwner
        entry.repaintTarget = RepaintTarget.AwaitingDriver
        return entry.id
    }

    /** Attaches the exact request allocated when a deferred repaint starts. */
    fun attachTransportRequest(id: Long, repaintRequestId: Long): Boolean {
        if (repaintRequestId <= 0 || isRetired(repaintRequestId)) return false
        val entry = entries.firstOrNull { it.id == id } ?: return false
        if (entry.repaintTarget != RepaintTarget.AwaitingDriver || entry.repaintRequestId != null) {
            return false
        }
        entry.repaintRequestId = repaintRequestId
        return true
    }

    /**
     * A forced frame that produced no output or was rejected is not authority.
     * Retire only that request and preserve the ordered history for the next
     * causal attempt.
     */
    fun rearmCorrelatedRepaint(id: Long, repaintRequestId: Long): Boolean {
        val entry = entries.firstOrNull { it.id == id } ?: return false
        if (entry.repaintRequestId != repaintRequestId) return false
        retireThrough(repaintRequestId)
        entry.repaintRequestId = null
        entry.repaintTarget = RepaintTarget.AwaitingDriver
        entry.receipts.clear()
        entry.acceptedDeliveryId = null
        return true
    }

    /**
     * Resolves the exact driver target without discarding a staged history
     * when the driver produced no output. The caller may re-arm that request
     * after a bounded wait; only owner/generation invalidation discards it.
     */
    fun resolveRepaint(id: Long, absoluteOutputTarget: Long?): Boolean {
        val entry = entries.firstOrNull { it.id == id } ?: return false
        if (entry.repaintTarget != RepaintTarget.AwaitingDriver || entry.repaintRequestId == null) {
            return false
        }
        val target = absoluteOutputTarget?.takeIf { it > 0 }
        if (target == null) {
            // No future delivery can legitimately carry this completed
            // request id, but the captured history remains staged so the
            // caller can attach a newer exact request.
            retireThrough(checkNotNull(entry.repaintRequestId))
            return false
        }
        entry.repaintTarget = RepaintTarget.Output(target)
        acceptExactReceiptIfPresent(entry, target)
        drain()
        return true
    }

    /**
     * Retires one exact forced-frame request and returns every history fence
     * it owned to the awaiting-driver state. [expectedOutputTarget] is null
     * only for a driver call that returned no target; a receipt timeout must
     * provide the exact target it waited for. Stale watchdogs cannot re-arm a
     * newer request because both request and target are matched atomically.
     */
    fun rearmRequest(
        repaintRequestId: Long,
        expectedOutputTarget: Long?,
    ): List<Long> {
        if (repaintRequestId <= 0) return emptyList()
        val matching = entries.filter { entry ->
            entry.repaintRequestId == repaintRequestId && when (val target = entry.repaintTarget) {
                RepaintTarget.AwaitingDriver -> expectedOutputTarget == null
                is RepaintTarget.Output -> expectedOutputTarget == target.absoluteCount
                RepaintTarget.Unpaired -> false
            }
        }
        if (matching.isEmpty()) return emptyList()
        retireThrough(repaintRequestId)
        matching.forEach { entry ->
            entry.repaintRequestId = null
            entry.repaintTarget = RepaintTarget.AwaitingDriver
            entry.receipts.clear()
            entry.acceptedDeliveryId = null
        }
        return matching.map(Entry::id)
    }

    /** False means the ordered history feed/fence was absent or stale. */
    fun markReady(surfaceId: String, owner: RenderOwner, ready: Ready): Boolean {
        val entry = entries.firstOrNull {
            it.surfaceId == surfaceId && it.owner == owner && it.ready == null
        } ?: return false
        if (entry.repaintTarget == RepaintTarget.Unpaired) {
            entries.remove(entry)
            if (unfencedCandidateId == entry.id) unfencedCandidateId = null
            drain()
            return false
        }
        entry.ready = ready
        drain()
        return true
    }

    /**
     * Decides whether a received Mosh frame may cross the renderer seam.
     *
     * The caller must feed accepted correlated bytes with [TransportOutputAdmission.feedOwner],
     * then call [noteTransportOutputResult] with the outcome of that exact feed.
     */
    fun admitTransportOutput(
        repaintRequestId: Long?,
        livePainterOwner: RenderOwner?,
    ): TransportOutputAdmission {
        val requestId = repaintRequestId ?: return TransportOutputAdmission.Generic
        if (isRetired(requestId)) return TransportOutputAdmission.Rejected
        val entry = entries.firstOrNull { it.repaintRequestId == requestId }
            ?: return TransportOutputAdmission.Generic
        // A fresh mosh+tmux session can legitimately have no ledger owner on
        // the live painter yet: the first history request may target a detached
        // split overlay while SSP still owns the unbound primary surface.  The
        // entry itself proves this is a correlated request, so nullable owner
        // equality is the exact ownership check rather than a reason to drop
        // the frame.
        return if (entry.painterOwner == livePainterOwner) {
            TransportOutputAdmission(accepted = true, feedOwner = entry.painterOwner)
        } else {
            TransportOutputAdmission.Rejected
        }
    }

    /**
     * Records the fate of one receipt-bearing transport delivery.
     *
     * A history fence advances only when this exact [deliveryId] equals the
     * driver's target for the correlated request, the feed rendered fully, and
     * the captured live painter owner is still current. Output sequence
     * high-water marks are deliberately not evidence of that fact.
     */
    fun noteTransportOutputResult(
        deliveryId: Long,
        repaintRequestId: Long?,
        renderedFully: Boolean,
        livePainterOwner: RenderOwner?,
    ) {
        if (deliveryId <= 0) return
        val requestId = repaintRequestId ?: return
        if (isRetired(requestId)) return
        val matching = entries.filter { it.repaintRequestId == requestId }
        if (matching.isEmpty()) return
        // Delivery IDs are unique. Keep the first observed fate if a stale
        // callback is replayed, so a rejected/partial delivery can never be
        // rewritten later as an accepted receipt.
        matching.forEach { entry ->
            entry.receipts.putIfAbsent(
                deliveryId,
                Receipt(
                    renderedFully = renderedFully,
                    livePainterOwner = livePainterOwner,
                ),
            )
            (entry.repaintTarget as? RepaintTarget.Output)?.let { target ->
                acceptExactReceiptIfPresent(entry, target.absoluteCount)
            }
        }
        drain()
    }

    /** Retires generic as well as history-correlated requests allocated before a bind/reset. */
    fun retireRepaintsThrough(requestId: Long) {
        retireThrough(requestId)
    }

    fun retireSurfaceUnlessOwnedBy(surfaceId: String, owner: RenderOwner) {
        val removedIds = entries.asSequence()
            .filter { it.surfaceId == surfaceId && it.owner != owner }
            .mapTo(mutableSetOf()) { it.id }
        if (removedIds.isEmpty()) return
        entries.filter { it.id in removedIds }.forEach(::retire)
        entries.removeAll { it.id in removedIds }
        if (unfencedCandidateId in removedIds) unfencedCandidateId = null
        drain()
    }

    fun discardSurface(surfaceId: String) {
        val removedIds = entries.asSequence()
            .filter { it.surfaceId == surfaceId }
            .mapTo(mutableSetOf()) { it.id }
        if (removedIds.isEmpty()) return
        entries.filter { it.id in removedIds }.forEach(::retire)
        entries.removeAll { it.id in removedIds }
        if (unfencedCandidateId in removedIds) unfencedCandidateId = null
        drain()
    }

    /** A new primary Mosh transport retires every outstanding receipt target. */
    fun resetForNewTransport() {
        entries.forEach(::retire)
        entries.clear()
        unfencedCandidateId = null
    }

    /** A side-channel generation change cancels work but preserves Mosh count. */
    fun discardPending() {
        entries.forEach(::retire)
        entries.clear()
        unfencedCandidateId = null
    }

    private fun retire(entry: Entry) {
        entry.repaintRequestId?.let(retiredRepaintRequestIds::add)
    }

    private fun retireThrough(requestId: Long) {
        if (requestId <= retiredRepaintRequestUpperBound) return
        retiredRepaintRequestUpperBound = requestId
        retiredRepaintRequestIds.removeAll { it <= retiredRepaintRequestUpperBound }
    }

    private fun isRetired(repaintRequestId: Long): Boolean =
        repaintRequestId <= retiredRepaintRequestUpperBound ||
            repaintRequestId in retiredRepaintRequestIds

    private fun acceptExactReceiptIfPresent(entry: Entry, targetDeliveryId: Long) {
        val receipt = entry.receipts[targetDeliveryId] ?: return
        if (receipt.renderedFully && receipt.livePainterOwner == entry.painterOwner) {
            entry.acceptedDeliveryId = targetDeliveryId
        }
    }

    private fun drain() {
        while (true) {
            val entry = entries.firstOrNull() ?: return
            val ready = entry.ready ?: return
            when (val target = entry.repaintTarget) {
                RepaintTarget.Unpaired,
                RepaintTarget.AwaitingDriver,
                -> return
                is RepaintTarget.Output -> if (entry.acceptedDeliveryId != target.absoluteCount) return
            }
            entries.removeAt(0)
            if (unfencedCandidateId == entry.id) unfencedCandidateId = null
            onDelivery(
                Delivery(
                    surfaceId = entry.surfaceId,
                    owner = entry.owner,
                    bytes = entry.bytes,
                    ready = ready,
                    repaintRequestId = checkNotNull(entry.repaintRequestId),
                ),
            )
        }
    }
}
