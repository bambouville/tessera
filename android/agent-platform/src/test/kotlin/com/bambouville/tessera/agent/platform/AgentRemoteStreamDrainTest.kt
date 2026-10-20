package com.bambouville.tessera.agent.platform

import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class AgentRemoteStreamDrainTest {
    @Test fun timeoutCleanupCannotOvertakeWorkerCancellation() = runBlocking(Dispatchers.Default) {
        val stderrStarted = kotlinx.coroutines.CompletableDeferred<Unit>()
        val cancelFinished = AtomicBoolean(false)
        val closedAfterCancellation = AtomicBoolean(false)
        val stream = object : AgentRemoteExecStream {
            override val stdout: Flow<ByteArray> = flow {
                stderrStarted.await()
                error("reader-failed")
            }
            override val stderr: Flow<ByteArray> = flow {
                stderrStarted.complete(Unit)
                awaitCancellation()
            }
            override suspend fun awaitExit(): AgentExecExitStatus { awaitCancellation() }
            override fun cancel() {
                Thread.sleep(250)
                cancelFinished.set(true)
            }
            override fun close() { closedAfterCancellation.set(cancelFinished.get()) }
        }
        AgentRemoteStreamDrain.drain(stream, 1024, 50)
        assertTrue("ordinary close overtook in-progress worker cancellation", closedAfterCancellation.get())
    }

    @Test fun outputLimitClosesBlockingSiblingsAndPreservesFailure() = runBlocking {
        val readersStarted = CountDownLatch(2)
        val released = CountDownLatch(1)
        val stream = object : AgentRemoteExecStream {
            override val stdout: Flow<ByteArray> = flow {
                withContext(Dispatchers.IO) { readersStarted.await(1, TimeUnit.SECONDS) }
                emit(ByteArray(1025))
            }
            override val stderr: Flow<ByteArray> = flow {
                withContext(Dispatchers.IO) {
                    readersStarted.countDown()
                    released.await(2, TimeUnit.SECONDS)
                }
            }
            override suspend fun awaitExit(): AgentExecExitStatus = withContext(Dispatchers.IO) {
                readersStarted.countDown()
                released.await(2, TimeUnit.SECONDS)
                AgentExecExitStatus(0)
            }
            override fun cancel() { released.countDown() }
            override fun close() { released.countDown() }
        }
        val started = System.nanoTime()
        val result = AgentRemoteStreamDrain.drain(stream, 1024, 3000)
        val elapsedMillis = (System.nanoTime() - started) / 1_000_000
        assertEquals(AgentRemoteStreamDrain.Result.Failed("stdout_too_large"), result)
        assertTrue("failure waited ${elapsedMillis}ms for blocking readers", elapsedMillis < 1000)
    }

    @Test fun parentCancellationUnblocksReadersAndRemainsCancellation() = runBlocking {
        val readerStarted = kotlinx.coroutines.CompletableDeferred<Unit>()
        val released = CountDownLatch(1)
        val stream = object : AgentRemoteExecStream {
            override val stdout: Flow<ByteArray> = flow {
                withContext(Dispatchers.IO) {
                    readerStarted.complete(Unit)
                    released.await(2, TimeUnit.SECONDS)
                }
            }
            override val stderr: Flow<ByteArray> = flow { awaitCancellation() }
            override suspend fun awaitExit(): AgentExecExitStatus { awaitCancellation() }
            override fun cancel() { released.countDown() }
            override fun close() { released.countDown() }
        }
        val drain = async { AgentRemoteStreamDrain.drain(stream, 1024, 5000) }
        readerStarted.await()
        val started = System.nanoTime()
        drain.cancelAndJoin()
        val elapsedMillis = (System.nanoTime() - started) / 1_000_000
        assertTrue(drain.isCancelled)
        assertTrue("parent cancellation waited ${elapsedMillis}ms for blocking readers", elapsedMillis < 1000)
    }

    @Test fun deadlineClosesBlockingReadersBeforeWaitingForTheirCompletion() = runBlocking {
        val released = CountDownLatch(1)
        val stream = object : AgentRemoteExecStream {
            override val stdout: Flow<ByteArray> = flow {
                withContext(Dispatchers.IO) { released.await(2, TimeUnit.SECONDS) }
            }
            override val stderr: Flow<ByteArray> = flow {
                withContext(Dispatchers.IO) { released.await(2, TimeUnit.SECONDS) }
            }
            override suspend fun awaitExit(): AgentExecExitStatus = withContext(Dispatchers.IO) {
                released.await(2, TimeUnit.SECONDS)
                AgentExecExitStatus(0)
            }
            override fun cancel() { released.countDown() }
            override fun close() { released.countDown() }
        }
        val started = System.nanoTime()
        val result = AgentRemoteStreamDrain.drain(stream, 1024, 100)
        val elapsedMillis = (System.nanoTime() - started) / 1_000_000
        assertTrue(result is AgentRemoteStreamDrain.Result.TimedOut)
        assertTrue("deadline waited ${elapsedMillis}ms for blocking readers before closing", elapsedMillis < 1000)
    }

    @Test fun hungProjectorIsCancelledAndClosedAtItsDeadline() = runBlocking {
        val stream = HungStream()

        val result = AgentRemoteStreamDrain.drain(stream, maxStdoutBytes = 1_024, timeoutMillis = 25)

        assertTrue(result is AgentRemoteStreamDrain.Result.TimedOut)
        assertTrue(stream.cancelled)
        assertTrue(stream.closed)
    }

    private class HungStream : AgentRemoteExecStream {
        override val stdout: Flow<ByteArray> = flow { awaitCancellation() }
        override val stderr: Flow<ByteArray> = flow { awaitCancellation() }
        var cancelled = false
        var closed = false
        override suspend fun awaitExit(): AgentExecExitStatus {
            awaitCancellation()
        }
        override fun cancel() { cancelled = true }
        override fun close() { closed = true }
    }
}
