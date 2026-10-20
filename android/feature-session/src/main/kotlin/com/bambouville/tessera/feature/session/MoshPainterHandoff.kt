package com.bambouville.tessera.feature.session

import com.bambouville.tessera.terminal.RenderOwner

/**
 * Causal barrier between a side-channel owner bind and Mosh's SSP painter.
 *
 * Binding empties the platform terminal, but an output callback that was
 * already queued can still describe the previous tmux window. The first
 * untagged delivery strictly newer than [begin]'s floor is therefore a
 * boundary, not paint: it is rejected and causes one owner-correlated
 * full-frame request. Natural painter ingress remains closed until the exact
 * terminal delivery produced by that request was accepted by the still-bound
 * surface.
 *
 * The floor is a natural-delivery sequence the caller chooses: the last
 * natural delivery at bind time for a switch the peer made, or the one seen
 * when the local selection command was queued. The Mosh painter attaches to
 * the same tmux session as the control client, so the frame carrying a
 * selected window arrives as soon as tmux runs `select-window`, in no fixed
 * order with the ledger bind or the control reply. A delivery already newer
 * than the floor when the handoff begins is that boundary, observed early;
 * waiting for another would wait forever, because a redraw of an unchanged
 * screen produces no SSP delta at all.
 */
internal class MoshPainterHandoff {
    sealed interface Admission {
        data object PassThrough : Admission
        data object Reject : Admission
        data class RejectAndStart(val owner: RenderOwner) : Admission
        data class AcceptOwned(val owner: RenderOwner) : Admission
    }

    data class Start(
        val owner: RenderOwner,
        val requestId: Long,
        val repaintFenceIds: List<Long>,
    )

    sealed interface Resolution {
        data object Pending : Resolution
        data object Stale : Resolution
        data class Completed(val owner: RenderOwner) : Resolution
        data class Rearmed(
            val owner: RenderOwner,
            val retiredRequestId: Long,
            val repaintFenceIds: List<Long>,
            val retryAttempt: Int,
        ) : Resolution
    }

    private data class State(
        val owner: RenderOwner,
        val naturalOutputFloor: Long,
        val repaintFenceIds: MutableList<Long> = mutableListOf(),
        var causalBoundaryObserved: Boolean,
        var retryAttempt: Int = 0,
        var observedNaturalDeliveryHighWater: Long = 0,
        var requestId: Long? = null,
        var outputTarget: Long? = null,
        val renderedResults: MutableMap<Long, Boolean> = mutableMapOf(),
    )

    private var state: State? = null

    val isActive: Boolean
        get() = state != null

    val activeOwner: RenderOwner?
        get() = state?.owner

    val requestInFlight: Boolean
        get() = state?.requestId != null

    val awaitingCausalBoundary: Boolean
        get() = state?.let { !it.causalBoundaryObserved } ?: false

    val activeRequestId: Long?
        get() = state?.requestId

    /**
     * Opens a handoff for [owner]. With [waitsForNaturalOutput] the boundary
     * is the first natural delivery above [naturalOutputFloor]; a delivery
     * the caller has already seen there ([observedNaturalDeliveryHighWater])
     * satisfies it immediately, so the caller should start the owned repaint
     * without waiting. Without it the boundary is taken as given.
     */
    fun begin(
        owner: RenderOwner,
        naturalOutputFloor: Long,
        waitsForNaturalOutput: Boolean,
        observedNaturalDeliveryHighWater: Long = 0,
    ) {
        require(naturalOutputFloor >= 0)
        require(observedNaturalDeliveryHighWater >= 0)
        state = State(
            owner = owner,
            naturalOutputFloor = naturalOutputFloor,
            causalBoundaryObserved = !waitsForNaturalOutput ||
                observedNaturalDeliveryHighWater > naturalOutputFloor,
            observedNaturalDeliveryHighWater = observedNaturalDeliveryHighWater,
        )
    }

    /**
     * Completes the causal wait when a targeted tmux redraw was acknowledged,
     * the Mosh link remained reachable, and no semantic screen delta followed
     * the floor. In that case the old and new canvases are equivalent: a
     * differing target would have produced a natural delivery. The caller
     * still has to request and admit one owner-correlated full frame; this
     * only prevents an equivalent quiet pane from staying blank.
     */
    fun settleQuietCanvas(owner: RenderOwner): Admission {
        val current = state ?: return Admission.Reject
        if (current.owner != owner || current.causalBoundaryObserved || current.requestId != null) {
            return Admission.Reject
        }
        current.causalBoundaryObserved = true
        return Admission.RejectAndStart(current.owner)
    }

    fun reset() {
        state = null
    }

    /**
     * Coalesces repaint work while the causal request has not started. A
     * request arriving after that cut must be queued by the caller and run as
     * a distinct repaint once this handoff settles.
     */
    fun deferRepaintFence(fenceId: Long?): Boolean {
        val current = state ?: return false
        if (current.requestId != null) return false
        if (fenceId != null && fenceId !in current.repaintFenceIds) {
            current.repaintFenceIds += fenceId
        }
        return true
    }

    fun admission(
        deliveryId: Long?,
        repaintRequestId: Long?,
        liveOwner: RenderOwner?,
    ): Admission {
        val current = state ?: return Admission.PassThrough
        if (current.owner != liveOwner) return Admission.Reject
        if (repaintRequestId == null) {
            if (deliveryId != null && deliveryId > current.observedNaturalDeliveryHighWater) {
                current.observedNaturalDeliveryHighWater = deliveryId
            }
            if (!current.causalBoundaryObserved) {
                if (deliveryId == null || deliveryId <= current.naturalOutputFloor) {
                    return Admission.Reject
                }
                current.causalBoundaryObserved = true
            }
            return if (current.requestId == null) {
                Admission.RejectAndStart(current.owner)
            } else {
                Admission.Reject
            }
        }
        return if (current.requestId == repaintRequestId) {
            Admission.AcceptOwned(current.owner)
        } else {
            Admission.Reject
        }
    }

    fun start(requestId: Long): Start? {
        require(requestId > 0)
        val current = state ?: return null
        if (current.requestId != null) return null
        current.requestId = requestId
        return Start(
            owner = current.owner,
            requestId = requestId,
            repaintFenceIds = current.repaintFenceIds.toList(),
        )
    }

    fun resolve(
        requestId: Long,
        outputTarget: Long?,
        liveOwner: RenderOwner?,
    ): Resolution {
        val current = state ?: return Resolution.Stale
        if (current.requestId != requestId) return Resolution.Stale
        if (outputTarget == null || outputTarget <= 0) {
            return rearm(current)
        }
        current.outputTarget = outputTarget
        return evaluate(current, liveOwner)
    }

    fun noteRendered(
        requestId: Long,
        deliveryId: Long,
        renderedFully: Boolean,
        liveOwner: RenderOwner?,
    ): Resolution {
        val current = state ?: return Resolution.Stale
        if (current.requestId != requestId || deliveryId <= 0) return Resolution.Stale
        current.renderedResults.putIfAbsent(deliveryId, renderedFully)
        return evaluate(current, liveOwner)
    }

    /**
     * Rearms only the exact unresolved request/target pair. A late watchdog
     * from an older owner or repaint cannot perturb the current handoff.
     */
    fun receiptTimedOut(
        requestId: Long,
        outputTarget: Long,
        liveOwner: RenderOwner?,
    ): Resolution {
        val current = state ?: return Resolution.Stale
        if (current.requestId != requestId || current.outputTarget != outputTarget ||
            current.owner != liveOwner
        ) return Resolution.Stale
        return rearm(current)
    }

    private fun evaluate(current: State, liveOwner: RenderOwner?): Resolution {
        val target = current.outputTarget ?: return Resolution.Pending
        val renderedFully = current.renderedResults[target] ?: return Resolution.Pending
        if (!renderedFully || liveOwner != current.owner) return rearm(current)
        state = null
        return Resolution.Completed(current.owner)
    }

    private fun rearm(current: State): Resolution.Rearmed {
        val requestId = checkNotNull(current.requestId)
        val fenceIds = current.repaintFenceIds.toList()
        state = State(
            owner = current.owner,
            naturalOutputFloor = current.naturalOutputFloor,
            repaintFenceIds = fenceIds.toMutableList(),
            causalBoundaryObserved = true,
            retryAttempt = current.retryAttempt + 1,
            observedNaturalDeliveryHighWater = current.observedNaturalDeliveryHighWater,
        )
        return Resolution.Rearmed(
            owner = current.owner,
            retiredRequestId = requestId,
            repaintFenceIds = fenceIds,
            retryAttempt = current.retryAttempt + 1,
        )
    }
}

/**
 * Whether natural SSP output may report history activity for the painter's
 * [owner]. SSP carries the whole tmux window, so in a split the owner need not
 * be the active pane: focus moving without history leaves the painter bound to
 * the pane it had. An older transport, an unproven window switch or a handoff
 * to another owner cannot provide this evidence.
 */
internal fun MoshPainterHandoff.admitsTransportActivity(
    owner: RenderOwner,
    transportGeneration: Long,
    activeWindowId: Int?,
): Boolean = owner.transportGeneration == transportGeneration &&
    owner.windowId == activeWindowId &&
    (!isActive || activeOwner == owner)
