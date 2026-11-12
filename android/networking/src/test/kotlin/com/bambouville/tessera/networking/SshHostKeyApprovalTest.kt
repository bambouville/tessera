package com.bambouville.tessera.networking

import java.io.Closeable
import java.io.IOException
import java.util.concurrent.TimeoutException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SshHostKeyApprovalTest {
    @Test(timeout = 5_000)
    fun trustedKeyConnectsWithoutPrompting() = runBlocking {
        val route = FakeRoute(listOf(key(0)))
        val policy = FakePolicy(route, route.keys.toMutableList())

        withSshHostKeyApproval(policy, connect = route::connect).use {
            assertEquals(1, route.attempts)
            assertEquals(0, policy.decisions)
            assertTrue(route.verdicts.single())
        }
        assertEquals(0, route.openResources)
    }

    @Test(timeout = 5_000)
    fun unknownKeyRejectsImmediatelyClosesBeforeDecisionAndRetriesWithPersistedTrust() = runBlocking {
        val route = FakeRoute(listOf(key(0)))
        val decision = CompletableDeferred<Boolean>()
        val asked = CompletableDeferred<Unit>()
        val policy = FakePolicy(route) {
            asked.complete(Unit)
            decision.await()
        }
        val connecting = async { withSshHostKeyApproval(policy, connect = route::connect) }

        asked.await()
        assertEquals(listOf(false), route.verdicts)
        assertEquals(0, route.openResources)
        assertEquals(1, route.attempts)
        assertTrue(policy.trusted.isEmpty())
        assertFalse(connecting.isCompleted)
        decision.complete(true)
        connecting.await().use {
            assertEquals(listOf(false, true), route.verdicts)
            assertEquals(listOf(0, 0), route.visitedHops)
            assertEquals(listOf(route.keys.single()), policy.trusted)
            assertEquals(1, policy.decisions)
        }
        assertEquals(0, route.openResources)
    }

    @Test(timeout = 5_000)
    fun declineFailsAsARejectedKeyCarryingTheOriginalFailure() = runBlocking {
        val route = FakeRoute(listOf(key(0)))
        val policy = FakePolicy(route) { false }

        val result = runCatching { withSshHostKeyApproval(policy, connect = route::connect) }

        val rejected = result.exceptionOrNull() as SshHostKeyRejected
        assertSame(route.rejection, rejected.cause)
        assertEquals(key(0).host, rejected.observation.host)
        assertEquals(1, route.attempts)
        assertEquals(1, policy.decisions)
        assertEquals(0, route.openResources)
        assertTrue(policy.trusted.isEmpty())
    }

    @Test(timeout = 5_000)
    fun otherFailuresNeverPromptAndKeepTheirOriginalException() = runBlocking {
        for (failure in listOf(IOException("network"), IOException("authentication"), TimeoutException("KEX"))) {
            val route = FakeRoute(listOf(key(0)), failure)
            val policy = FakePolicy(route, route.keys.toMutableList())

            val result = runCatching { withSshHostKeyApproval(policy, connect = route::connect) }

            assertSame(failure, result.exceptionOrNull())
            assertEquals(0, policy.decisions)
            assertEquals(1, route.attempts)
            assertEquals(0, route.openResources)
        }
    }

    @Test(timeout = 5_000)
    fun unknownSecondHopClosesTheWholeChainAndRestartsAtHopZero() = runBlocking {
        val route = FakeRoute(listOf(key(0), key(1)))
        val policy = FakePolicy(route, mutableListOf(route.keys.first()))

        withSshHostKeyApproval(policy, connect = route::connect).use {
            assertEquals(listOf(0, 1, 0, 1), route.visitedHops)
            assertEquals(listOf(true, false, true, true), route.verdicts)
            assertEquals(1, policy.decisions)
            assertEquals(route.keys, policy.trusted)
        }
        assertEquals(0, route.openResources)
    }

    @Test(timeout = 5_000)
    fun cancellationDuringApprovalLeavesNoResourcesAndDoesNotRetryOrTrust() = runBlocking {
        val route = FakeRoute(listOf(key(0), key(1)))
        val asked = CompletableDeferred<Unit>()
        val policy = FakePolicy(route, mutableListOf(route.keys.first())) {
            asked.complete(Unit)
            awaitCancellation()
        }
        val connecting = async { withSshHostKeyApproval(policy, connect = route::connect) }

        asked.await()
        assertEquals(0, route.openResources)
        connecting.cancelAndJoin()

        assertTrue(connecting.isCancelled)
        assertEquals(0, route.openResources)
        assertEquals(1, route.attempts)
        assertEquals(listOf(route.keys.first()), policy.trusted)
    }

    @Test(timeout = 5_000)
    fun decisionTimeoutFailsAsARejectedKeyWithoutRetrying() = runBlocking {
        val route = FakeRoute(listOf(key(0)))
        val policy = FakePolicy(route) { awaitCancellation() }

        val result = runCatching {
            withSshHostKeyApproval(policy, decisionTimeoutMilliseconds = 20, connect = route::connect)
        }

        assertSame(route.rejection, (result.exceptionOrNull() as SshHostKeyRejected).cause)
        assertEquals(1, route.attempts)
        assertEquals(0, route.openResources)
        assertTrue(policy.trusted.isEmpty())
    }

    @Test(timeout = 5_000)
    fun repeatedKeyChangesAtOneHopHaveABoundedNumberOfPrompts() = runBlocking {
        val route = FakeRoute(listOf(key(0)), rotateKey = true)
        val policy = FakePolicy(route)

        val result = runCatching { withSshHostKeyApproval(policy, connect = route::connect) }

        assertSame(route.rejection, result.exceptionOrNull())
        assertEquals(2, policy.decisions)
        assertEquals(3, route.attempts)
        assertEquals(0, route.openResources)
    }

    @Test(timeout = 5_000)
    fun aPlainRejectingPolicyStillFailsWithoutApprovalOrRetry() = runBlocking {
        val route = FakeRoute(listOf(key(0)))

        val result = runCatching {
            withSshHostKeyApproval(SshHostKeyPolicy { false }, connect = route::connect)
        }

        assertSame(route.rejection, result.exceptionOrNull())
        assertEquals(1, route.attempts)
        assertEquals(0, route.openResources)
    }

    private class FakePolicy(
        private val route: FakeRoute,
        val trusted: MutableList<SshHostKeyObservation> = mutableListOf(),
        private val decide: suspend () -> Boolean = { true },
    ) : SshHostKeyPolicy {
        var decisions = 0

        override suspend fun verify(observation: SshHostKeyObservation): Boolean {
            if (observation in trusted) return true
            throw SshHostKeyApprovalRequired(observation) {
                assertEquals("all clients and tunnels must close before asking", 0, route.openResources)
                decisions++
                decide().also { accepted -> if (accepted) trusted += observation }
            }
        }
    }

    private class FakeRoute(
        val keys: List<SshHostKeyObservation>,
        private val failure: Throwable? = null,
        private val rotateKey: Boolean = false,
    ) {
        val rejection = IOException("host key rejected")
        val visitedHops = mutableListOf<Int>()
        val verdicts = mutableListOf<Boolean>()
        var attempts = 0
        var openResources = 0

        suspend fun connect(verify: (SshHostKeyObservation) -> Boolean): Closeable {
            attempts++
            val resources = mutableListOf<Closeable>()
            fun acquire() {
                openResources++
                resources += Closeable { openResources-- }
            }
            try {
                for ((index, key) in keys.withIndex()) {
                    visitedHops += index
                    acquire() // SSH client
                    if (index > 0) acquire() // upstream tunnel
                    val observed = if (rotateKey) key.copy(canonicalKeyBlob = byteArrayOf(attempts.toByte())) else key
                    val trusted = verify(observed)
                    verdicts += trusted
                    if (!trusted) throw rejection
                    failure?.let { throw it }
                }
                return Closeable { resources.asReversed().forEach(Closeable::close) }
            } catch (failure: Throwable) {
                resources.asReversed().forEach(Closeable::close)
                throw failure
            }
        }
    }

    private fun key(hop: Int) = SshHostKeyObservation("hop$hop", 22, "ssh-ed25519", byteArrayOf(hop.toByte()))
}
