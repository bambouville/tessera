package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.terminal.RenderOwner

/**
 * Holds the one UI acknowledgement that may reveal an ordered Mosh capture.
 *
 * A `historyReady` effect says the side-channel bytes reached the controller;
 * it does not say that a Termux view has made those bytes visible.  Keep the
 * physical view identity alongside the logical ledger owner so a delayed
 * `View.post` from a replaced Compose surface cannot acknowledge a newer
 * mount that happens to have the same tmux owner and transport generation.
 */
internal class MoshHistoryPresentationAcknowledgements<Surface : Any> {
    data class Delivery<Surface : Any>(
        val deliveryToken: Long,
        val surfaceId: String,
        val owner: SharedTmuxRenderOwner,
        val physicalOwner: RenderOwner,
        val surface: Surface,
    ) {
        init {
            require(deliveryToken > 0) { "history presentation delivery token must be positive" }
        }
    }

    sealed interface Acknowledgement<out Surface : Any> {
        data class Accepted<Surface : Any>(val delivery: Delivery<Surface>) : Acknowledgement<Surface>
        data object Duplicate : Acknowledgement<Nothing>
        data object Unknown : Acknowledgement<Nothing>
        data class Stale<Surface : Any>(val delivery: Delivery<Surface>) : Acknowledgement<Surface>
    }

    private val pendingBySurface = mutableMapOf<String, Delivery<Surface>>()
    private val acknowledgedTokens = mutableSetOf<Long>()

    fun publish(delivery: Delivery<Surface>) {
        pendingBySurface[delivery.surfaceId] = delivery
    }

    /**
     * Accept exactly the current token, physical owner, transport generation,
     * and view identity. A second callback is explicitly harmless.
     */
    fun acknowledge(
        surfaceId: String,
        deliveryToken: Long,
        currentGeneration: Long,
        currentSurface: Surface?,
        currentOwner: RenderOwner?,
    ): Acknowledgement<Surface> {
        if (deliveryToken in acknowledgedTokens) return Acknowledgement.Duplicate
        val delivery = pendingBySurface[surfaceId] ?: return Acknowledgement.Unknown
        if (delivery.deliveryToken != deliveryToken) return Acknowledgement.Unknown
        if (delivery.physicalOwner.transportGeneration != currentGeneration ||
            delivery.surface !== currentSurface ||
            delivery.physicalOwner != currentOwner
        ) {
            pendingBySurface.remove(surfaceId, delivery)
            return Acknowledgement.Stale(delivery)
        }
        pendingBySurface.remove(surfaceId, delivery)
        acknowledgedTokens += deliveryToken
        return Acknowledgement.Accepted(delivery)
    }

    /** Drops a pending callback when its physical surface is removed. */
    fun discardSurface(surfaceId: String): Delivery<Surface>? = pendingBySurface.remove(surfaceId)

    /** Drops callbacks whose logical surfaces are no longer declared by Compose. */
    fun discardUndeclared(surfaceIds: Set<String>): List<Delivery<Surface>> =
        pendingBySurface.entries
            .filter { (surfaceId, _) -> surfaceId !in surfaceIds }
            .map { (surfaceId, delivery) ->
                pendingBySurface.remove(surfaceId, delivery)
                delivery
            }

    fun discardAll(): List<Delivery<Surface>> = pendingBySurface.values.toList().also {
        pendingBySurface.clear()
    }
}
