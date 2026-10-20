package com.bambouville.tessera.feature.pairing

import com.bambouville.tessera.data.SavedHost
import java.util.UUID

/**
 * Does a received continuation descriptor name the route this device would
 * open for the saved host it points at?
 *
 * A route is *where* a connection leads: the destination endpoint and the jump
 * chain, hop for hop. Three things the descriptor also carries are deliberately
 * not compared, because they describe the sender's client rather than the
 * route:
 *
 * - **transport** — how each client talks to the host. An iPad on mosh handing
 *   to a phone saved on ssh is the same route to the same tmux session; the
 *   receiver connects with its own row's transport.
 * - **launch mode and tmux target** — the rendezvous the sender is in. It is
 *   applied to the receiving session as an override on connect, so the saved
 *   row's own session mode does not have to agree.
 * - **connectionKey** — the wire key embeds the sender's transport, so it can
 *   only ever equal a locally derived one when the transports happen to match.
 *
 * This mirrors the shared `ContinuationResolver` fast path used on iOS, which
 * accepts by host identity and never consults transport or session mode.
 *
 * The descriptor arrives as JSON on the wire; the coordinator parses it into
 * [DescriptorRoute] so the comparison here stays pure and unit-testable off a
 * device (the JVM `org.json` stub cannot build a real `JSONObject`).
 */
internal object ContinuationRouteMatchPolicy {
    /** The transport-free shape of a route, destination last. */
    data class DescriptorRoute(
        val schemaVersion: Int,
        val destination: Endpoint,
        val via: List<Hop>,
    ) {
        data class Endpoint(val user: String, val address: String, val port: Int)
        data class Hop(val hostId: String, val user: String, val address: String, val port: Int)
    }

    fun matches(
        descriptor: DescriptorRoute,
        local: SavedHost,
        localRoute: List<SavedHost>,
    ): Boolean {
        if (descriptor.schemaVersion != 1) return false
        if (localRoute.isEmpty() || localRoute.last().id != local.id) return false
        if (localRoute.size != descriptor.via.size + 1) return false
        val hopsAgree = localRoute.dropLast(1).withIndex().all { (index, hop) ->
            val remote = descriptor.via[index]
            sameUuid(remote.hostId, hop.id) &&
                remote.address == hop.hostname &&
                remote.port == hop.port &&
                remote.user == hop.username
        }
        return hopsAgree &&
            descriptor.destination.address == local.hostname &&
            descriptor.destination.port == local.port &&
            descriptor.destination.user == local.username
    }

    private fun sameUuid(lhs: String, rhs: String): Boolean =
        runCatching { UUID.fromString(lhs) == UUID.fromString(rhs) }.getOrDefault(false)
}
