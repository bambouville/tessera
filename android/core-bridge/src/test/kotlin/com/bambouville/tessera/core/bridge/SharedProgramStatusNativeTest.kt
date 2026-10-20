package com.bambouville.tessera.core.bridge

import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/** Runs against the host-built Swift core and JNI shim; never substitutes a Kotlin parser. */
class SharedProgramStatusNativeTest {
    private val query = "\u001B]7501;?\u001B\\".encodeToByteArray()

    @Before
    fun requireNativeCore() {
        val state = CoreBridge.inspect()
        assumeTrue("host-built shared core unavailable: $state", state is CoreBridgeState.Ready)
    }

    @Test
    fun rawQueriesReportsAcknowledgementAndCloseUseTheSharedMonitor() {
        val monitor = SharedProgramStatusMonitor.create()
        monitor.use {
            assertTrue(monitor.feed(query).reply.isEmpty())
            assertTrue(checkNotNull(monitor.snapshot()).terminals.isEmpty())
            assertEquals(CoreCallResult.Accepted, monitor.setEnabled(true))
            assertArrayEquals(byteArrayOf(27, 93, 55, 53, 48, 49, 59, 63, 27, 92), monitor.feed(query).reply)
            val blockedFeed = monitor.feed("\u001B]7501;state=blocked:kind=question:app=deploy\u0007".encodeToByteArray())
            assertTrue(blockedFeed.reply.isEmpty())
            val blockedSnapshot = checkNotNull(monitor.snapshot())
            assertEquals(blockedSnapshot.revision, blockedFeed.revision)
            val blocked = checkNotNull(blockedSnapshot.terminal(SharedProgramStatusTerminal.Raw))
            assertEquals(SharedProgramStatusAttention.NEEDS_INPUT, blocked.attention)
            assertEquals(SharedProgramStatusBlockedKind.QUESTION, blocked.blockedKind)
            assertEquals("deploy", blocked.primaryEntry?.app)
            assertFalse(monitor.acknowledge(Long.MAX_VALUE))
            val doneFeed = monitor.feed("\u001B]7501;state=done\u0007".encodeToByteArray())
            assertTrue(doneFeed.revision > blockedFeed.revision)
            val done = checkNotNull(monitor.snapshot()?.terminal(SharedProgramStatusTerminal.Raw))
            assertEquals(SharedProgramStatusAttention.FINISHED, done.attention)
            val token = checkNotNull(done.latestUnreadResultToken)
            assertTrue(monitor.acknowledge(token))
            assertFalse(monitor.acknowledge(token))
            assertNull(monitor.snapshot()?.terminal(SharedProgramStatusTerminal.Raw)?.attention)
        }
        monitor.close()
        assertEquals(CoreCallResult.StaleHandle, monitor.setEnabled(true))
        assertNull(monitor.snapshot())
        assertFalse(monitor.acknowledge(1))
        assertArrayEquals(byteArrayOf(), monitor.feed(query).reply)
        assertEquals(0L, monitor.feed(query).revision)
        monitor.noteTransportLost()
    }

    @Test
    fun rawQueryBurstsAndSplitQueriesReturnEveryReplyInOrder() {
        SharedProgramStatusMonitor.create().use { monitor ->
            assertEquals(CoreCallResult.Accepted, monitor.setEnabled(true))
            val belQuery = "\u001B]7501;?\u0007".encodeToByteArray()
            val burst = ByteArray(belQuery.size * 500) { belQuery[it % belQuery.size] }
            val expected = ByteArray(query.size * 500) { query[it % query.size] }
            assertArrayEquals(expected, monitor.feed(burst).reply)
            assertTrue(monitor.feed(belQuery, count = 4).reply.isEmpty())
            assertArrayEquals(query, monitor.feed(belQuery, offset = 4, count = belQuery.size - 4).reply)
            assertTrue(monitor.feed(byteArrayOf()).reply.isEmpty())
        }
    }

    @Test
    fun rawInputSlicesPreserveScannerStateRepliesAndLastRevision() {
        SharedProgramStatusMonitor.create().use { monitor ->
            assertEquals(CoreCallResult.Accepted, monitor.setEnabled(true))
            val ceiling = CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES.toInt()
            // Split the first query across the payload ceiling; the second follows in the next slice.
            val prefix = ByteArray(ceiling - 3) { 'x'.code.toByte() }
            val report = "\u001B]7501;state=error\u0007".encodeToByteArray()
            val payload = byteArrayOf(0) + prefix + query + query + report + byteArrayOf(0)
            val result = monitor.feed(payload, offset = 1, count = payload.size - 2)
            assertArrayEquals(query + query, result.reply)
            val snapshot = checkNotNull(monitor.snapshot())
            assertEquals(snapshot.revision, result.revision)
            assertEquals(SharedProgramStatusAttention.FAILED, snapshot.terminal(SharedProgramStatusTerminal.Raw)?.attention)
            assertEquals(result.revision, monitor.feed(byteArrayOf()).revision)
            monitor.noteTransportLost()
            assertTrue(checkNotNull(monitor.snapshot()?.terminal(SharedProgramStatusTerminal.Raw)).entries.all { it.isHistorical })
            assertEquals(CoreCallResult.Accepted, monitor.setEnabled(false))
            assertTrue(checkNotNull(monitor.snapshot()).terminals.isEmpty())
        }
    }

    @Test
    fun rawNativeBoundaryRefusesInvalidBuffersAndStaleOpaqueHandles() {
        val handle = NativeCoreBindings.createProgramStatusMonitor()
        assertTrue(handle != 0L)
        try {
            assertEquals(-1, NativeCoreBindings.feedProgramStatusMonitor(handle, null, 1, null, 0, longArrayOf(0)))
            assertEquals(-1, NativeCoreBindings.feedProgramStatusMonitor(handle, ByteBuffer.wrap(query), query.size, null, 0, null))
            assertEquals(-1, NativeCoreBindings.feedProgramStatusMonitor(handle, null, 0, null, 1, null))
            assertEquals(-1, NativeCoreBindings.feedProgramStatusMonitor(handle, null, 0, null, 0, longArrayOf()))
            val size = NativeCoreBindings.copyProgramStatusMonitorSnapshot(handle, null, 0)
            assertTrue(size > 1)
            assertEquals(-1, NativeCoreBindings.copyProgramStatusMonitorSnapshot(handle, ByteBuffer.allocateDirect(1), 1))
        } finally {
            NativeCoreBindings.destroyProgramStatusMonitor(handle)
        }
        assertEquals(-2, NativeCoreBindings.setProgramStatusMonitorEnabled(handle, true))
        assertEquals(-2, NativeCoreBindings.feedProgramStatusMonitor(handle, null, 0, null, 0, null))
        assertEquals(-2, NativeCoreBindings.copyProgramStatusMonitorSnapshot(handle, null, 0))
        assertEquals(-2, NativeCoreBindings.acknowledgeProgramStatusMonitor(handle, 1))
        assertEquals(-2, NativeCoreBindings.noteProgramStatusMonitorTransportLost(handle))
        NativeCoreBindings.destroyProgramStatusMonitor(handle)
        assertEquals(-2, NativeCoreBindings.setProgramStatusMonitorEnabled(0, true))
    }

    @Test
    fun tmuxPaneReportsPublishRevisionsAndCanBeAcknowledged() {
        val events = mutableListOf<SharedTmuxEvent>()
        SharedTmuxRuntime.create { events += it }.use { runtime ->
            assertEquals(CoreCallResult.Accepted, runtime.setProgramStatusEnabled(true))
            assertEquals(CoreCallResult.Accepted, runtime.feed("%session-changed \$0 work\r\n%window-add @1\r\n".encodeToByteArray()))
            val before = checkNotNull(events.last().programStatusRevision)
            assertEquals(CoreCallResult.Accepted, runtime.feed("%output %31 \\033]7501;state=error\\007\r\n".encodeToByteArray()))
            val revision = checkNotNull(events.last().programStatusRevision)
            assertTrue(revision > before)
            val snapshot = checkNotNull(runtime.programStatus())
            assertEquals(revision, snapshot.revision)
            val pane = checkNotNull(snapshot.pane(31))
            assertEquals(SharedProgramStatusAttention.FAILED, pane.attention)
            val token = checkNotNull(pane.latestUnreadResultToken)
            assertTrue(runtime.acknowledgeProgramStatus(31, token))
            assertFalse(runtime.acknowledgeProgramStatus(31, token))
            assertNull(runtime.programStatus()?.pane(31)?.attention)
            assertFalse(runtime.acknowledgeProgramStatus(-1, token))
            assertEquals(CoreCallResult.Accepted, runtime.feed("%output %31 \\033]7501;state=working\\007\r\n".encodeToByteArray()))
            assertTrue(checkNotNull(events.last().programStatusRevision) > revision)
            assertEquals(CoreCallResult.Accepted, runtime.setProgramStatusEnabled(false))
            assertTrue(checkNotNull(runtime.programStatus()).terminals.isEmpty())
            runtime.close()
            assertEquals(CoreCallResult.StaleHandle, runtime.setProgramStatusEnabled(true))
            assertNull(runtime.programStatus())
            assertFalse(runtime.acknowledgeProgramStatus(31, token))
        }
    }

    @Test
    fun tmuxProgramStatusCallsAreSafeInsideTheNativeCallback() {
        lateinit var runtime: SharedTmuxRuntime
        var sawResult = false
        runtime = SharedTmuxRuntime.create { event ->
            val pane = runtime.programStatus()?.pane(31)
            if (pane?.attention == SharedProgramStatusAttention.FAILED) {
                assertNotNull(event.programStatusRevision)
                assertTrue(runtime.acknowledgeProgramStatus(31, checkNotNull(pane.latestUnreadResultToken)))
                assertEquals(CoreCallResult.Accepted, runtime.setProgramStatusEnabled(false))
                sawResult = true
            }
        }
        runtime.use {
            assertEquals(CoreCallResult.Accepted, runtime.setProgramStatusEnabled(true))
            assertEquals(CoreCallResult.Accepted, runtime.feed("%session-changed \$0 work\r\n%window-add @1\r\n".encodeToByteArray()))
            assertEquals(CoreCallResult.Accepted, runtime.feed("%output %31 \\033]7501;state=error\\007\r\n".encodeToByteArray()))
            assertTrue(sawResult)
        }
    }
}
