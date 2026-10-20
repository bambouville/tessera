package com.bambouville.tessera.feature.session

import java.io.Closeable
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Rule
import org.junit.Test

class AgentAuxiliaryRouteLeaseTest {
    /** The lease renews on a supervisor scope of its own; nothing may fail there uncaught. */
    @get:Rule
    val coroutineFailures = UncaughtCoroutineFailures()

    @Test(timeout = 5_000)
    fun concurrentDemandSharesRenewalAndCancellationLeavesOtherWaiterAlive() = runBlocking {
        val original = Route()
        val fresh = Route()
        val started = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        val calls = AtomicInteger()
        val lease = AgentAuxiliaryRouteLease(original, { true }) {
            calls.incrementAndGet()
            started.complete(Unit)
            finish.await()
            fresh
        }
        try {
            lease.invalidate(original)
            val first = async { lease.acquire() }
            started.await()
            val secondStarted = CompletableDeferred<Unit>()
            val second = async { secondStarted.complete(Unit); lease.acquire() }
            secondStarted.await()
            first.cancelAndJoin()
            finish.complete(Unit)
            assertSame(fresh, second.await())
            assertEquals(1, calls.get())
            assertEquals(1, original.closes.get())
            assertSame(fresh, lease.acquire())
            lease.invalidate(original)
            assertSame("old failures must not retire the new route", fresh, lease.acquire())
            assertEquals(1, calls.get())
        } finally { lease.close() }
        assertEquals("the controller owns the published route", 0, fresh.closes.get())
    }

    @Test(timeout = 5_000)
    fun closedLeaseDisposesLateUnclaimedRenewal() = runBlocking {
        val original = Route()
        val fresh = Route()
        val started = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        val lease = AgentAuxiliaryRouteLease(original, { false }) {
            withContext(NonCancellable) {
                started.complete(Unit)
                finish.await()
                fresh
            }
        }
        val waiting = async { lease.acquire() }
        started.await()
        lease.close()
        finish.complete(Unit)
        waiting.cancelAndJoin()
        withTimeout(2_000) { fresh.closed.await() }
        assertEquals(1, fresh.closes.get())
        assertEquals(0, original.closes.get())
        assertSame(original, lease.current)
    }

    @Test(timeout = 5_000)
    fun failedRenewalCanBeRetriedByLaterDemandWithoutReplayingOperation() = runBlocking {
        val original = Route()
        val fresh = Route()
        val calls = AtomicInteger()
        val lease = AgentAuxiliaryRouteLease(original, { false }) {
            if (calls.incrementAndGet() == 1) error("transient network failure")
            fresh
        }
        try {
            val failure = runCatching { lease.acquire() }
            assertEquals(true, failure.isFailure)
            assertSame(original, lease.current)
            assertEquals(0, original.closes.get())
            assertSame(fresh, lease.acquire())
            assertEquals(2, calls.get())
        } finally { lease.close() }
    }

    @Test(timeout = 5_000)
    fun finalWaiterCancellationDisposesLateReplacementWithoutPublishing() = runBlocking {
        val original = Route()
        val fresh = Route()
        val started = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        val publishes = AtomicInteger()
        val lease = AgentAuxiliaryRouteLease(original, { false }, { _, _ -> publishes.incrementAndGet(); true }) {
            withContext(NonCancellable) {
                started.complete(Unit)
                finish.await()
                fresh
            }
        }
        try {
            val waiting = async { lease.acquire() }
            started.await()
            waiting.cancelAndJoin()
            finish.complete(Unit)
            withTimeout(2_000) { fresh.closed.await() }
            assertEquals(0, publishes.get())
            assertEquals(1, fresh.closes.get())
            assertSame(original, lease.current)
        } finally { lease.close() }
    }

    @Test(timeout = 5_000)
    fun carrierChangeRefusesAndClosesReplacementBeforePublishing() = runBlocking {
        val original = Route()
        val fresh = Route()
        val lease = AgentAuxiliaryRouteLease(original, { false }, { _, _ -> false }) { fresh }
        try {
            assertEquals(true, runCatching { lease.acquire() }.isFailure)
            assertSame(original, lease.current)
            assertEquals(1, fresh.closes.get())
            assertEquals(0, original.closes.get())
        } finally { lease.close() }
    }

    private class Route : Closeable {
        val closes = AtomicInteger()
        val closed = CompletableDeferred<Unit>()
        override fun close() { closes.incrementAndGet(); closed.complete(Unit) }
    }
}
