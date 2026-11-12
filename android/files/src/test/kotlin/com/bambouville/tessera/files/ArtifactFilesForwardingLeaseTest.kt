package com.bambouville.tessera.files

import com.bambouville.tessera.forwarding.BoundForwardEndpoint
import com.bambouville.tessera.forwarding.ForwardingCapabilities
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardingLease
import com.bambouville.tessera.forwarding.PortForwardingRuntime
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtifactFilesForwardingLeaseTest {
    private class Channel : AutoCloseable {
        @Volatile var live = true
        @Volatile var duringCheck: () -> Unit = {}
        override fun close() { live = false }
    }
    private class Lease : PortForwardingLease {
        override val bound = BoundForwardEndpoint("127.0.0.1", 45_555)
        override val activeConnectionCount = MutableStateFlow(0)
        override val isOpen = MutableStateFlow(true)
        @Volatile var closes = 0
        override fun close() { closes += 1; isOpen.value = false }
    }
    private class Runtime(val lease: Lease = Lease(), val onStart: suspend () -> Unit = {}) : PortForwardingRuntime {
        override val capabilities = ForwardingCapabilities(local = true, remote = true, dynamic = true)
        @Volatile var closes = 0
        val closed = CountDownLatch(1)
        override suspend fun start(rule: PortForwardRule): PortForwardingLease { onStart(); return lease }
        override fun close() { closes += 1; closed.countDown() }
    }
    private val rule = PortForwardRule(bind = PortForwardEndpoint("127.0.0.1", 0), target = PortForwardEndpoint("127.0.0.1", 5173))

    @Test fun anEmptyOrDeadSlotNeverCreatesARuntimeOrConnects() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>(isUsable = { it.live })
        try {
            assertNull(slot.acquireArtifactForwardingLease(rule) { error("an empty slot must never connect") })
            slot.obtain { Channel().apply { live = false } }
            assertNull(slot.acquireArtifactForwardingLease(rule) { error("a dead slot must never reconnect") })
        } finally { slot.closeAndJoin() }
    }

    @Test fun closingALeaseAlsoClosesItsRuntimeOnceAndLeavesFilesOpen() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>(isUsable = { it.live })
        val channel = slot.obtain { Channel() }
        val runtime = Runtime()
        try {
            val lease = checkNotNull(slot.acquireArtifactForwardingLease(rule) { assertSame(channel, it); runtime })
            assertTrue(lease.isOpen.value)
            lease.close(); lease.close()
            assertEquals(1, runtime.lease.closes)
            assertEquals(1, runtime.closes)
            assertSame(channel, slot.currentOrNull)
            assertTrue(channel.live)
        } finally { slot.closeAndJoin() }
    }

    @Test fun replacingTheHeldConnectionInvalidatesTheOldLease() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>(isUsable = { it.live })
        val channel = slot.obtain { Channel() }
        val runtime = Runtime()
        val lease = checkNotNull(slot.acquireArtifactForwardingLease(rule) { runtime })
        try {
            channel.live = false
            slot.obtain { Channel() }
            assertFalse(lease.isOpen.value)
        } finally { lease.close(); slot.closeAndJoin() }
        assertEquals(1, runtime.closes)
    }

    @Test(timeout = 5_000) fun carrierDeathClosesTheListenerAndRuntimeWithoutReadingTheLeaseOrReconnecting() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>(isUsable = { it.live })
        val channel = slot.obtain { Channel() }
        val runtime = Runtime()
        val runtimeCreations = AtomicInteger()
        val lease = checkNotNull(slot.acquireArtifactForwardingLease(rule) { runtimeCreations.incrementAndGet(); runtime })
        try {
            channel.live = false
            assertTrue("the carrier watcher did not close the listener", runtime.closed.await(WATCH_DEADLINE_MS, TimeUnit.MILLISECONDS))
            assertFalse(runtime.lease.isOpen.value)
            assertEquals(1, runtime.lease.closes)
            assertEquals(1, runtime.closes)
            assertNull(slot.acquireArtifactForwardingLease(rule) { runtimeCreations.incrementAndGet(); error("must never reconnect a dead carrier") })
            assertEquals(1, runtimeCreations.get())
        } finally { lease.close(); slot.closeAndJoin() }
    }

    @Test(timeout = 5_000) fun replacingTheCarrierClosesItsListenerWithoutReadingTheLease() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>(isUsable = { it.live })
        val channel = slot.obtain { Channel() }
        val runtime = Runtime()
        val lease = checkNotNull(slot.acquireArtifactForwardingLease(rule) { runtime })
        try {
            channel.live = false
            val replacement = slot.obtain { Channel() }
            assertTrue("the replaced carrier kept its listener", runtime.closed.await(WATCH_DEADLINE_MS, TimeUnit.MILLISECONDS))
            assertEquals(1, runtime.lease.closes)
            assertEquals(1, runtime.closes)
            assertSame(replacement, slot.currentOrNull)
            assertTrue(replacement.live)
        } finally { lease.close(); slot.closeAndJoin() }
    }

    @Test(timeout = 5_000) fun anExplicitlyClosedLeaseStopsItsDaemonCarrierWatcherAndLeavesFilesOpen() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>(isUsable = { it.duringCheck(); it.live })
        val channel = slot.obtain { Channel() }
        val runtime = Runtime()
        val lease = checkNotNull(slot.acquireArtifactForwardingLease(rule) { runtime })
        try {
            val watched = CountDownLatch(1)
            val watcherThread = AtomicReference<Thread>()
            channel.duringCheck = { watcherThread.set(Thread.currentThread()); watched.countDown() }
            assertTrue("no independent carrier watch ran", watched.await(WATCH_DEADLINE_MS, TimeUnit.MILLISECONDS))
            assertTrue("a watcher must not keep the process alive", watcherThread.get().isDaemon)
            lease.close()
            val readAfterClose = CountDownLatch(1)
            channel.duringCheck = { readAfterClose.countDown() }
            assertFalse("the closed lease still watches its carrier", readAfterClose.await(WATCH_STOP_MS, TimeUnit.MILLISECONDS))
            assertEquals(1, runtime.lease.closes)
            assertEquals(1, runtime.closes)
            assertTrue(channel.live)
        } finally { lease.close(); slot.closeAndJoin() }
    }

    @Test fun channelLossDuringStartClosesTheNewLeaseAndRuntime() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>(isUsable = { it.live })
        val channel = slot.obtain { Channel() }
        val runtime = Runtime(onStart = { channel.live = false })
        try {
            assertNull(slot.acquireArtifactForwardingLease(rule) { runtime })
            assertFalse(runtime.lease.isOpen.value)
            assertEquals(1, runtime.closes)
        } finally { slot.closeAndJoin() }
    }

    @Test fun failedOrCancelledStartsCloseTheirRuntime() = runBlocking {
        for (failure in listOf(IOException("start failed"), CancellationException("cancelled"))) {
            val slot = RemoteFilesConnectionSlot<Channel>()
            slot.obtain { Channel() }
            val runtime = Runtime(onStart = { throw failure })
            try {
                val result = runCatching { slot.acquireArtifactForwardingLease(rule) { runtime } }
                // Coroutine stack-trace recovery (enabled under -ea) rethrows a copy, not the instance.
                val thrown = result.exceptionOrNull()
                assertEquals(failure.javaClass, thrown?.javaClass)
                assertEquals(failure.message, thrown?.message)
                assertEquals(1, runtime.closes)
            } finally { slot.closeAndJoin() }
        }
    }

    @Test fun cancellationAtTheIOHandoffClosesAnAlreadyAllocatedLeaseAndRuntime() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>()
        slot.obtain { Channel() }
        val runtime = Runtime(onStart = { checkNotNull(currentCoroutineContext()[Job]).cancel() })
        try {
            val acquisition = async { slot.acquireArtifactForwardingLease(rule) { runtime } }
            assertTrue(runCatching { acquisition.await() }.exceptionOrNull() is CancellationException)
            assertEquals(1, runtime.lease.closes)
            assertEquals(1, runtime.closes)
        } finally { slot.closeAndJoin() }
    }

    private companion object {
        // One 1 s watch interval plus scheduler headroom; never poll the returned lease.
        const val WATCH_DEADLINE_MS = 1_750L
        const val WATCH_STOP_MS = 1_250L
    }
}
