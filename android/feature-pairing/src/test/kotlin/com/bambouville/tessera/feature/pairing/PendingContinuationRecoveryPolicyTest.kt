package com.bambouville.tessera.feature.pairing

import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.data.continuity.PendingContinuationRecovery
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Only the local shape checks live here. Whether the record's route identity
 * still names this route is the shared core's answer — `ContinuationRouteIdentity`
 * in `Packages/TesseraCore/Sources/TesseraProtocolCore`, pinned by
 * `ContinuationRouteIdentityTests` — and reaching it needs the native library
 * a JVM unit test cannot load.
 */
class PendingContinuationRecoveryPolicyTest {
    private val jump = host("11111111-1111-1111-1111-111111111111", "jump.example", tmux = TmuxModes.OFF)
    private val destination = host(
        "22222222-2222-2222-2222-222222222222",
        "target.example",
        jumpHostId = jump.id,
        tmux = TmuxModes.PINNED,
        tmuxTarget = "exact",
    )
    private val record = PendingContinuationRecovery(
        attemptId = "attempt",
        hostId = destination.id,
        transportKind = TransportKinds.SSH,
        tmuxTarget = "exact",
        routeIdentity = "ssh:alice@target.example:22&via=X#fingerprint",
        stagedAtEpochMilliseconds = 1,
    )

    @Test
    fun routeShapeAcceptsTheStagedDestinationAndTmuxRendezvous() {
        assertTrue(PendingContinuationRecoveryPolicy.routeShapeMatches(record, destination, listOf(jump, destination)))
    }

    @Test
    fun theSavedRowsTransportAndSessionModeAreNotPartOfTheRoute() {
        // The staged record carries the sender's transport and tmux target;
        // the receiver connects over its own transport and re-applies the
        // staged target as the session override, so neither may veto resume.
        assertTrue(
            PendingContinuationRecoveryPolicy.routeShapeMatches(
                record,
                destination.copy(transportKind = TransportKinds.MOSH),
                listOf(jump, destination.copy(transportKind = TransportKinds.MOSH)),
            ),
        )
        assertTrue(
            PendingContinuationRecoveryPolicy.routeShapeMatches(
                record,
                destination.copy(tmuxMode = TmuxModes.AUTOMATIC, tmuxTarget = null),
                listOf(jump, destination.copy(tmuxMode = TmuxModes.AUTOMATIC, tmuxTarget = null)),
            ),
        )
    }

    @Test
    fun aDifferentDestinationIsNotTheStagedContinuation() {
        assertFalse(
            PendingContinuationRecoveryPolicy.routeShapeMatches(
                record.copy(hostId = jump.id),
                destination,
                listOf(jump, destination),
            ),
        )
    }

    @Test
    fun aRouteMustEndAtTheDestinationAndNameEachHostOnce() {
        assertFalse(PendingContinuationRecoveryPolicy.routeShapeMatches(record, destination, listOf(jump)))
        assertFalse(
            PendingContinuationRecoveryPolicy.routeShapeMatches(
                record,
                destination,
                listOf(jump, jump, destination),
            ),
        )
        assertFalse(PendingContinuationRecoveryPolicy.routeShapeMatches(record, destination, emptyList()))
        assertFalse(PendingContinuationRecoveryPolicy.routeShapeMatches(record, destination, null))
        assertFalse(PendingContinuationRecoveryPolicy.routeShapeMatches(record, null, listOf(jump, destination)))
    }

    @Test
    fun anUnusableCredentialIsRefusedBeforeTheRouteIsEvenDerived() {
        assertFalse(
            PendingContinuationRecoveryPolicy.canOffer(
                record,
                destination,
                listOf(jump, destination),
                credentialUsable = false,
            ),
        )
    }

    private fun host(
        id: String,
        hostname: String,
        jumpHostId: String? = null,
        tmux: String,
        tmuxTarget: String? = null,
    ) = SavedHost(
        id = id,
        displayName = id,
        hostname = hostname,
        port = 22,
        username = "alice",
        jumpHostId = jumpHostId,
        identityId = null,
        transportKind = TransportKinds.SSH,
        tmuxMode = tmux,
        tmuxTarget = tmuxTarget,
    )
}
