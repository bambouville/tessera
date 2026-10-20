package com.bambouville.tessera.data.continuity

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Adapter-level only. The cohort's decisions — verdict, evaluation, window
 * closure, clock charging, persist mode — are the shared core's and are pinned
 * by `ForegroundRestoreCohortTests` in `Packages/TesseraCore`; a JVM unit test
 * cannot reach them across JNI.
 */
class ForegroundRestoreContinuityTest {
    @Test
    fun legacyTmuxTransportRowsNormalizeBeforeFirstConnectedSnapshot() {
        assertEquals("ssh", normalizedRestoreTransportKind("ssh+tmux", "ssh"))
        assertEquals("mosh", normalizedRestoreTransportKind("mosh-tmux", "ssh"))
        assertEquals("mosh", normalizedRestoreTransportKind("unknown", "mosh"))
        assertEquals("ssh", normalizedRestoreTransportKind(null, "ssh"))
    }

    @Test
    fun pendingContinuationRecoveryExpiresAndRejectsFutureClockSkew() {
        val record = PendingContinuationRecovery(
            attemptId = "attempt",
            hostId = "host",
            transportKind = "ssh",
            tmuxTarget = null,
            routeIdentity = "route",
            stagedAtEpochMilliseconds = 1_000,
        )

        assertTrue(record.isFreshAt(1_000))
        assertTrue(record.isFreshAt(1_000 + MAX_PENDING_CONTINUATION_AGE_MILLISECONDS))
        assertFalse(record.isFreshAt(999))
        assertFalse(record.isFreshAt(1_001 + MAX_PENDING_CONTINUATION_AGE_MILLISECONDS))
    }

    // The compact-shell policy coercion moved into the shared core, so it is no
    // longer reachable from the JVM — a unit test cannot dlopen it. Its rows
    // live in ProtocolVectors/session/v1/restore-decisions.json under
    // `effectivePolicy`, checked against Swift by RestoreDecisionVectorTests
    // and against this platform's own wrapper by
    // SharedRestoreDecisionVectorInstrumentedTest.

    @Test
    fun documentCodecRoundTripsOnlySecretFreeSnapshotFields() {
        val document = ForegroundRestoreDocument(
            savedAtEpochMilliseconds = 200,
            snapshots = listOf(snapshot(tmux = "work", selection = "4:8")),
            selectedSessionId = "session",
        )

        val encoded = ForegroundRestoreDocumentCodec.encode(document)
        val decoded = ForegroundRestoreDocumentCodec.decodeOrNull(encoded)

        assertEquals(document, decoded)
        assertNull(ForegroundRestoreDocumentCodec.decodeOrNull("not-a-document"))
        assertFalse(encoded.contains("password", ignoreCase = true))
        assertTrue(encoded.isNotBlank())
    }

    @Test
    fun pendingContinuationCodecPreservesOnlyTheRecoverableConnectionHandoff() {
        val record = PendingContinuationRecovery(
            attemptId = "attempt",
            hostId = "host",
            transportKind = "mosh",
            tmuxTarget = "exact-session",
            routeIdentity = "mosh:alice@example.test:22",
            stagedAtEpochMilliseconds = 300,
        )

        assertEquals(record, PendingContinuationRecoveryCodec.decodeOrNull(PendingContinuationRecoveryCodec.encode(record)))
        assertNull(PendingContinuationRecoveryCodec.decodeOrNull("broken"))
    }

    private fun snapshot(
        sessionId: String = "session",
        transport: String = "ssh",
        tmux: String? = null,
        selection: String? = null,
    ) = ForegroundRestoreSnapshot(
        sessionId = sessionId,
        hostId = "host-$sessionId",
        displayName = "Host $sessionId",
        createdAtEpochMilliseconds = 100,
        transportKind = transport,
        tmuxTarget = tmux,
        lastSelection = selection,
        reconnectRequired = true,
    )
}
