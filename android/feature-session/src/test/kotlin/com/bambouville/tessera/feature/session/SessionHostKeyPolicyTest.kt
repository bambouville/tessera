package com.bambouville.tessera.feature.session

import com.bambouville.tessera.data.HostTrustEvaluation
import com.bambouville.tessera.data.KnownHostsRepository
import com.bambouville.tessera.data.SavedKnownHost
import com.bambouville.tessera.feature.session.SshSessionController.SessionHostKeyPolicy
import com.bambouville.tessera.networking.SshHostKeyApprovalRequired
import com.bambouville.tessera.networking.SshHostKeyObservation
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionHostKeyPolicyTest {
    @Test
    fun trustedKeyReturnsWithoutAskingOrRewritingTrust() = runTest {
        val store = FakeKnownHosts(HostTrustEvaluation.Trusted)
        val policy = SessionHostKeyPolicy(store) { error("trusted key must not prompt") }

        assertTrue(policy.verify(observation))
        assertEquals(0, store.trustWrites)
    }

    @Test
    fun unknownChangedAndRevertedKeysDeferDecisionAndPersistOnlyAfterApproval() = runTest {
        for (evaluation in listOf(
            HostTrustEvaluation.Unknown,
            HostTrustEvaluation.Changed(byteArrayOf(2)),
            HostTrustEvaluation.Reverted(byteArrayOf(3)),
        )) {
            val store = FakeKnownHosts(evaluation)
            var decisions = 0
            val policy = SessionHostKeyPolicy(store) { challenged ->
                assertSame(observation, challenged)
                assertEquals(0, store.trustWrites)
                decisions++
                true
            }

            val approval = runCatching { policy.verify(observation) }.exceptionOrNull() as SshHostKeyApprovalRequired
            assertSame(observation, approval.observation)
            assertEquals(0, decisions)
            assertEquals(0, store.trustWrites)

            assertTrue(approval.approve())
            assertEquals(1, decisions)
            assertEquals(1, store.trustWrites)
            assertTrue(policy.verify(observation))
            assertEquals(1, decisions)
            assertEquals(1, store.trustWrites)
        }
    }

    @Test
    fun declineDoesNotPersistTrust() = runTest {
        val store = FakeKnownHosts(HostTrustEvaluation.Unknown)
        val policy = SessionHostKeyPolicy(store) { false }
        val approval = runCatching { policy.verify(observation) }.exceptionOrNull() as SshHostKeyApprovalRequired

        assertFalse(approval.approve())
        assertEquals(0, store.trustWrites)
    }

    @Test
    fun cancellationDuringTheDecisionDoesNotPersistTrust() = runTest {
        val store = FakeKnownHosts(HostTrustEvaluation.Unknown)
        val asked = CompletableDeferred<Unit>()
        val policy = SessionHostKeyPolicy(store) {
            asked.complete(Unit)
            awaitCancellation()
        }
        val approval = runCatching { policy.verify(observation) }.exceptionOrNull() as SshHostKeyApprovalRequired
        val deciding = async { approval.approve() }

        asked.await()
        deciding.cancelAndJoin()

        assertTrue(deciding.isCancelled)
        assertEquals(0, store.trustWrites)
    }

    @Test
    fun concurrentRoutesWithOneKeyAskOnceAndShareTheAnswer() = runTest {
        val store = FakeKnownHosts(HostTrustEvaluation.Unknown)
        val answer = CompletableDeferred<Boolean>()
        var decisions = 0
        val policy = SessionHostKeyPolicy(store) {
            decisions++
            answer.await()
        }
        val first = runCatching { policy.verify(observation) }.exceptionOrNull() as SshHostKeyApprovalRequired
        val second = runCatching { policy.verify(observation) }.exceptionOrNull() as SshHostKeyApprovalRequired

        val firstDecision = async { first.approve() }
        val secondDecision = async { second.approve() }
        testScheduler.runCurrent()
        assertEquals("the second waits instead of replacing the shown prompt", 1, decisions)
        answer.complete(true)

        assertTrue(firstDecision.await())
        assertTrue(secondDecision.await())
        assertEquals(1, decisions)
        assertEquals(1, store.trustWrites)
    }

    @Test
    fun decisionTimeoutDoesNotPersistTrust() = runTest {
        val store = FakeKnownHosts(HostTrustEvaluation.Unknown)
        val policy = SessionHostKeyPolicy(store) { awaitCancellation() }
        val approval = runCatching { policy.verify(observation) }.exceptionOrNull() as SshHostKeyApprovalRequired

        assertEquals(null, withTimeoutOrNull(120_000) { approval.approve() })
        assertEquals(0, store.trustWrites)
    }

    private class FakeKnownHosts(var evaluation: HostTrustEvaluation) : KnownHostsRepository {
        var trustWrites = 0
        override val loadedKnownHosts = MutableStateFlow<List<SavedKnownHost>?>(emptyList())
        override fun observeKnownHosts() = flowOf(emptyList<SavedKnownHost>())

        override suspend fun evaluate(
            hostname: String,
            port: Int,
            algorithm: String,
            canonicalKeyBlob: ByteArray,
        ): HostTrustEvaluation = evaluation

        override suspend fun trust(hostname: String, port: Int, algorithm: String, canonicalKeyBlob: ByteArray) {
            assertEquals(observation.host, hostname)
            assertEquals(observation.port, port)
            assertEquals(observation.algorithm, algorithm)
            assertTrue(observation.canonicalKeyBlob.contentEquals(canonicalKeyBlob))
            trustWrites++
            evaluation = HostTrustEvaluation.Trusted
        }

        override suspend fun forget(hostname: String, port: Int): Boolean = error("not used")
    }

    private companion object {
        val observation = SshHostKeyObservation("example.test", 22, "ssh-ed25519", byteArrayOf(1))
    }
}
