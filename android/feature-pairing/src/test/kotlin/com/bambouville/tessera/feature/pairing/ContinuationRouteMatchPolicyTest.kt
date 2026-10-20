package com.bambouville.tessera.feature.pairing

import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.feature.pairing.ContinuationRouteMatchPolicy.DescriptorRoute
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ContinuationRouteMatchPolicyTest {
    private val jump = host("11111111-1111-1111-1111-111111111111", "bastion.example", port = 2222, user = "gate")
    private val destination = host(
        "22222222-2222-2222-2222-222222222222",
        "target.example",
        jumpHostId = jump.id,
        tmux = TmuxModes.PINNED,
        tmuxTarget = "dev",
    )

    /** The route an iPad on mosh, pinned to `dev`, would describe for this destination. */
    private fun route(
        via: List<SavedHost> = listOf(jump),
        address: String = destination.hostname,
        port: Int = destination.port,
        user: String = destination.username,
        schemaVersion: Int = 1,
    ) = DescriptorRoute(
        schemaVersion = schemaVersion,
        destination = DescriptorRoute.Endpoint(user = user, address = address, port = port),
        via = via.map { DescriptorRoute.Hop(hostId = it.id, user = it.username, address = it.hostname, port = it.port) },
    )

    @Test
    fun theSameRouteMatchesWhateverTransportOrSessionModeEitherSideUses() {
        val sshAutomaticRow = destination.copy(
            transportKind = TransportKinds.SSH,
            tmuxMode = TmuxModes.AUTOMATIC,
            tmuxTarget = null,
        )
        assertTrue(
            ContinuationRouteMatchPolicy.matches(route(), sshAutomaticRow, listOf(jump, sshAutomaticRow)),
        )
        val moshRow = destination.copy(transportKind = TransportKinds.MOSH)
        assertTrue(
            ContinuationRouteMatchPolicy.matches(route(), moshRow, listOf(jump, moshRow)),
        )
    }

    @Test
    fun theHostUuidIsComparedCaseInsensitively() {
        assertTrue(
            ContinuationRouteMatchPolicy.matches(
                route(via = listOf(jump.copy(id = jump.id.uppercase()))),
                destination,
                listOf(jump, destination),
            ),
        )
    }

    @Test
    fun aDifferentDestinationEndpointIsAnotherRoute() {
        assertFalse(ContinuationRouteMatchPolicy.matches(route(address = "elsewhere.example"), destination, listOf(jump, destination)))
        assertFalse(ContinuationRouteMatchPolicy.matches(route(port = 2200), destination, listOf(jump, destination)))
        assertFalse(ContinuationRouteMatchPolicy.matches(route(user = "root"), destination, listOf(jump, destination)))
    }

    @Test
    fun aDifferentJumpChainIsAnotherRoute() {
        val otherJump = jump.copy(id = "33333333-3333-3333-3333-333333333333")
        assertFalse(ContinuationRouteMatchPolicy.matches(route(via = listOf(otherJump)), destination, listOf(jump, destination)))
        assertFalse(ContinuationRouteMatchPolicy.matches(route(via = emptyList()), destination, listOf(jump, destination)))
        assertFalse(ContinuationRouteMatchPolicy.matches(route(), destination, listOf(destination)))
    }

    @Test
    fun anUnknownSchemaVersionNeverMatches() {
        assertFalse(ContinuationRouteMatchPolicy.matches(route(schemaVersion = 2), destination, listOf(jump, destination)))
    }

    private fun host(
        id: String,
        hostname: String,
        port: Int = 22,
        user: String = "alice",
        jumpHostId: String? = null,
        tmux: String = TmuxModes.OFF,
        tmuxTarget: String? = null,
    ) = SavedHost(
        id = id,
        displayName = id,
        hostname = hostname,
        port = port,
        username = user,
        jumpHostId = jumpHostId,
        identityId = null,
        transportKind = TransportKinds.SSH,
        tmuxMode = tmux,
        tmuxTarget = tmuxTarget,
    )
}
