package com.bambouville.tessera.files

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Compose disposes the Files browser on the main thread, and an SFTP close
 * blocks until the server answers. These pin that disposal returns at once
 * and that every connection, including one still opening, is still closed.
 */
class RemoteFilesConnectionSlotTest {
    @Test(timeout = 30_000)
    fun closeReturnsWhileTheConnectionCloseIsStillBlockedAndFinishesItElsewhere() = runBlocking {
        val slot = RemoteFilesConnectionSlot<FakeConnection>()
        val connection = FakeConnection(blockClose = true)
        assertSame(connection, slot.obtain { connection })

        val caller = Thread.currentThread()
        val started = System.nanoTime()
        slot.close()
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)

        assertTrue("close() waited ${elapsedMs} ms for the blocked connection close", elapsedMs < PROMPT_MS)
        assertEquals("the connection close finished before close() returned", 1L, connection.closeFinished.count)
        assertNull("close() left the connection reusable", slot.currentOrNull)
        assertTrue("the connection close never started", connection.closeStarted.await(WAIT_S, TimeUnit.SECONDS))
        assertNotSame("the connection closed on the disposing thread", caller, connection.closedOn)

        connection.releaseClose()
        assertTrue("the connection close never finished", connection.closeFinished.await(WAIT_S, TimeUnit.SECONDS))
        assertEquals(1, connection.closeCount.get())
    }

    @Test(timeout = 30_000)
    fun closeIsIdempotentAndNothingOpensAfterIt() = runBlocking {
        val never = RemoteFilesConnectionSlot<FakeConnection>()
        never.close()
        never.close()
        never.closeAndJoin()

        val slot = RemoteFilesConnectionSlot<FakeConnection>()
        val connection = FakeConnection()
        slot.obtain { connection }
        slot.close()
        slot.close()
        slot.closeAndJoin()
        slot.closeAndJoin()
        assertEquals(1, connection.closeCount.get())

        val opens = AtomicInteger()
        val reopened = runCatching { slot.obtain { opens.incrementAndGet(); FakeConnection() } }
        assertTrue("obtain after close: $reopened", reopened.exceptionOrNull() is CancellationException)
        assertEquals("a closed slot dialed again", 0, opens.get())
    }

    @Test(timeout = 30_000)
    fun aConnectionThatFinishesOpeningAfterCloseIsClosedRatherThanKept() = runBlocking {
        val slot = RemoteFilesConnectionSlot<FakeConnection>()
        val connection = FakeConnection()
        val openStarted = CountDownLatch(1)
        val finishOpen = CountDownLatch(1)
        // Not cancelled by close(): an open that ignores cancellation, or
        // wins the race back to its caller, still hands its result in.
        val opener = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val opening = opener.async {
                runCatching {
                    slot.obtain {
                        openStarted.countDown()
                        check(finishOpen.await(WAIT_S, TimeUnit.SECONDS))
                        connection
                    }
                }
            }
            assertTrue(openStarted.await(WAIT_S, TimeUnit.SECONDS))
            slot.close()
            finishOpen.countDown()

            val result = withTimeout(WAIT_S * 1_000) { opening.await() }
            assertTrue("late open was handed out: $result", result.exceptionOrNull() is CancellationException)
            assertNull(slot.currentOrNull)
            assertTrue("late connection leaked", connection.closeFinished.await(WAIT_S, TimeUnit.SECONDS))
            assertEquals(1, connection.closeCount.get())
        } finally {
            opener.cancel()
        }
    }

    @Test(timeout = 30_000)
    fun closeAndJoinWaitsForACloseAlreadyHandedOff() = runBlocking {
        val slot = RemoteFilesConnectionSlot<FakeConnection>()
        val connection = FakeConnection(blockClose = true)
        slot.obtain { connection }
        slot.close()

        val joining = async(Dispatchers.IO) { slot.closeAndJoin() }
        assertTrue(connection.closeStarted.await(WAIT_S, TimeUnit.SECONDS))
        Thread.sleep(200)
        assertFalse("closeAndJoin returned before the connection closed", joining.isCompleted)

        connection.releaseClose()
        withTimeout(WAIT_S * 1_000) { joining.await() }
        assertEquals(0L, connection.closeFinished.count)
        assertEquals(1, connection.closeCount.get())
    }

    @Test(timeout = 30_000)
    fun concurrentCallersShareOneOpen() = runBlocking {
        val slot = RemoteFilesConnectionSlot<FakeConnection>()
        val opens = AtomicInteger()
        val finishOpen = CountDownLatch(1)
        val callers = List(4) {
            async(Dispatchers.IO) {
                slot.obtain {
                    opens.incrementAndGet()
                    check(finishOpen.await(WAIT_S, TimeUnit.SECONDS))
                    FakeConnection()
                }
            }
        }
        Thread.sleep(100)
        finishOpen.countDown()
        val connections = callers.awaitAll()
        assertEquals(1, opens.get())
        assertEquals(1, connections.toSet().size)
        assertNotNull(slot.currentOrNull)
        slot.closeAndJoin()
        assertEquals(1, connections.first().closeCount.get())
    }

    @Test(timeout = 30_000)
    fun aConnectionThatDiedIsClosedAndReplacedRatherThanReused() = runBlocking {
        // A live session's route closes when it reconnects; Files must not
        // keep failing on the SFTP channel it opened on the old one.
        val slot = RemoteFilesConnectionSlot<FakeConnection>(isUsable = { !it.dead })
        val first = FakeConnection()
        assertSame(first, slot.obtain { first })

        first.dead = true
        assertNull("currentOrNull handed out a dead connection", slot.currentOrNull)
        val second = FakeConnection()
        assertSame(second, slot.obtain { second })
        assertSame(second, slot.currentOrNull)
        assertTrue("the dead connection was never closed", first.closeFinished.await(WAIT_S, TimeUnit.SECONDS))

        slot.closeAndJoin()
        assertEquals(1, first.closeCount.get())
        assertEquals(1, second.closeCount.get())
    }

    @Test(timeout = 30_000)
    fun closeLetsTheCancelledWorkItIsGivenFinishOnTheConnectionFirst() = runBlocking {
        val slot = RemoteFilesConnectionSlot<FakeConnection>(drainTimeoutMillis = 60_000)
        val connection = FakeConnection()
        slot.obtain { connection }
        val cleanup = Job()

        val started = System.nanoTime()
        slot.close(drain = cleanup)
        assertTrue("close() waited for the drain", TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < PROMPT_MS)
        assertNull(slot.currentOrNull)
        Thread.sleep(200)
        assertEquals("closed under the cleanup still using it", 0, connection.closeCount.get())

        cleanup.complete()
        assertTrue("close waited out the drain budget", connection.closeFinished.await(PROMPT_MS, TimeUnit.MILLISECONDS))
    }

    @Test(timeout = 30_000)
    fun aDrainThatNeverEndsDelaysTheCloseOnlyByItsBudget() = runBlocking {
        val slot = RemoteFilesConnectionSlot<FakeConnection>(drainTimeoutMillis = 300)
        val connection = FakeConnection()
        slot.obtain { connection }
        val stuck = Job()
        try {
            slot.close(drain = stuck)
            assertTrue("a stuck drain kept the connection open", connection.closeFinished.await(WAIT_S, TimeUnit.SECONDS))
        } finally {
            stuck.cancel()
        }
    }

    private class FakeConnection(blockClose: Boolean = false) : AutoCloseable {
        private val gate = CountDownLatch(if (blockClose) 1 else 0)

        @Volatile
        var dead = false
        val closeStarted = CountDownLatch(1)
        val closeFinished = CountDownLatch(1)
        val closeCount = AtomicInteger()

        @Volatile
        var closedOn: Thread? = null
            private set

        fun releaseClose() = gate.countDown()

        /** Stands in for an SFTP close waiting on a dead link. */
        override fun close() {
            closeCount.incrementAndGet()
            closedOn = Thread.currentThread()
            closeStarted.countDown()
            // Bounded, so a regression fails the promptness check instead of hanging.
            gate.await(BLOCKED_CLOSE_S, TimeUnit.SECONDS)
            closeFinished.countDown()
        }
    }

    private companion object {
        const val PROMPT_MS = 1_000L
        const val BLOCKED_CLOSE_S = 5L
        const val WAIT_S = 10L
    }
}
