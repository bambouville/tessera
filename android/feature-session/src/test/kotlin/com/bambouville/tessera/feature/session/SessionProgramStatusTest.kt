package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.CoreBridge
import com.bambouville.tessera.core.bridge.CoreBridgeState
import com.bambouville.tessera.core.bridge.CoreCallResult
import com.bambouville.tessera.core.bridge.SharedProgramStatusAttention
import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminal
import com.bambouville.tessera.core.bridge.SharedTmuxEvent
import com.bambouville.tessera.core.bridge.SharedTmuxRuntime
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/** Runs against the host-built shared core: the holder only carries its snapshots. */
class SessionProgramStatusTest {
    private val query = "\u001B]7501;?\u001B\\".encodeToByteArray()

    @Before
    fun requireNativeCore() {
        val state = CoreBridge.inspect()
        assumeTrue("host-built shared core unavailable: $state", state is CoreBridgeState.Ready)
    }

    @Test
    fun rawTerminalAnswersOnlyWhileEnabledAndPublishesItsRecords() {
        SessionProgramStatus().use { status ->
            // Created disabled: plain SSH output passes through unread.
            assertTrue(status.feedRaw(query).isEmpty())
            assertTrue(status.feedRaw(report("state=error")).isEmpty())
            assertTrue(status.snapshot.value.terminals.isEmpty())

            status.setEnabled(true, tmuxRuntime = null)
            assertArrayEquals(query, status.feedRaw(query))
            assertTrue(status.feedRaw(report("state=done:app=make")).isEmpty())
            val done = checkNotNull(status.snapshot.value.terminal(SharedProgramStatusTerminal.Raw))
            assertEquals(SharedProgramStatusAttention.FINISHED, done.attention)
            assertEquals("make", done.primaryEntry?.app)

            status.acknowledge(SharedProgramStatusTerminal.Raw, checkNotNull(done.latestUnreadResultToken), null)
            assertNull(status.snapshot.value.terminal(SharedProgramStatusTerminal.Raw)?.attention)

            status.feedRaw(report("state=blocked:kind=permission"))
            status.noteRawTransportLost()
            val lost = checkNotNull(status.snapshot.value.terminal(SharedProgramStatusTerminal.Raw))
            assertTrue(lost.entries.all { it.isHistorical })

            status.setEnabled(false, tmuxRuntime = null)
            assertTrue(status.snapshot.value.terminals.isEmpty())
            assertTrue(status.feedRaw(query).isEmpty())
        }
    }

    @Test
    fun publishesRawFirstThenPanesAndFollowsRuntimeRevisions() {
        val events = mutableListOf<SharedTmuxEvent>()
        SharedTmuxRuntime.create { events += it }.use { runtime ->
            SessionProgramStatus().use { status ->
                status.setEnabled(true, tmuxRuntime = null)
                status.attachTmux(runtime)
                assertEquals(CoreCallResult.Accepted, runtime.feed("%session-changed \$0 work\r\n%window-add @1\r\n".encodeToByteArray()))
                status.feedRaw(report("state=working"))
                assertEquals(CoreCallResult.Accepted, runtime.feed("%output %31 \\033]7501;state=error\\007\r\n".encodeToByteArray()))
                status.observeTmuxEvent(runtime, events.last().programStatusRevision)

                val terminals = status.snapshot.value.terminals.map { it.terminal }
                assertEquals(listOf(SharedProgramStatusTerminal.Raw, SharedProgramStatusTerminal.Pane(31)), terminals)
                val pane = checkNotNull(status.snapshot.value.pane(31))
                assertEquals(SharedProgramStatusAttention.FAILED, pane.attention)

                val published = status.snapshot.value.revision
                status.observeTmuxEvent(runtime, events.last().programStatusRevision)
                assertEquals("an unchanged revision republishes nothing", published, status.snapshot.value.revision)

                status.acknowledge(SharedProgramStatusTerminal.Pane(31), checkNotNull(pane.latestUnreadResultToken), runtime)
                assertNull(status.snapshot.value.pane(31)?.attention)
                assertTrue(status.snapshot.value.revision > published)

                // The setting reaches the tmux runtime as well as the raw monitor.
                status.setEnabled(false, runtime)
                assertTrue(status.snapshot.value.terminals.isEmpty())
                assertTrue(checkNotNull(runtime.programStatus()).terminals.isEmpty())
            }
        }
    }

    @Test
    fun aNewRuntimeHandleReplacesTheOldRecordsWhateverItsRevision() {
        val events = mutableListOf<SharedTmuxEvent>()
        SessionProgramStatus().use { status ->
            status.setEnabled(true, tmuxRuntime = null)
            SharedTmuxRuntime.create { events += it }.use { old ->
                status.attachTmux(old)
                old.feed("%session-changed \$0 work\r\n%window-add @1\r\n".encodeToByteArray())
                repeat(3) { old.feed("%output %31 \\033]7501;state=working:progress=${it * 10}\\007\r\n".encodeToByteArray()) }
                old.feed("%output %31 \\033]7501;state=error\\007\r\n".encodeToByteArray())
                status.observeTmuxEvent(old, events.last().programStatusRevision)
                assertEquals(SharedProgramStatusAttention.FAILED, status.snapshot.value.pane(31)?.attention)
            }
            SharedTmuxRuntime.create { events += it }.use { fresh ->
                status.attachTmux(fresh)
                assertNull("a fresh handle starts a new record lifetime", status.snapshot.value.pane(31))
                fresh.feed("%session-changed \$0 work\r\n%window-add @1\r\n".encodeToByteArray())
                fresh.feed("%output %40 \\033]7501;state=done\\007\r\n".encodeToByteArray())
                status.observeTmuxEvent(fresh, events.last().programStatusRevision)
                assertEquals(listOf(SharedProgramStatusTerminal.Pane(40)), status.snapshot.value.terminals.map { it.terminal })
            }
        }
    }

    @Test
    fun disableWithoutRuntimeClearsBothCachedHalvesBeforeReenable() {
        SharedTmuxRuntime.create {}.use { runtime ->
            SessionProgramStatus().use { status ->
                status.setEnabled(true, null)
                status.attachTmux(runtime)
                status.feedRaw(report("state=done"))
                runtime.feed("%output %31 \\033]7501;state=error\\007\r\n".encodeToByteArray())
                status.pullTmux(runtime)
                assertEquals(2, status.snapshot.value.terminals.size)
                status.setEnabled(false, null)
                status.setEnabled(true, null)
                assertTrue(status.snapshot.value.terminals.isEmpty())
                status.pullTmux(runtime)
                assertTrue(status.snapshot.value.terminals.isEmpty())
                assertTrue(checkNotNull(runtime.programStatus()).terminals.isEmpty())
                runtime.feed("%output %31 \\033]7501;state=blocked\\007\r\n".encodeToByteArray())
                status.pullTmux(runtime)
                assertEquals(SharedProgramStatusAttention.NEEDS_INPUT, status.snapshot.value.pane(31)?.attention)
            }
        }
    }

    @Test
    fun parkedRuntimeMissesDisableButIsResetOnAttachOrPull() {
        for (attach in listOf(false, true)) {
            SharedTmuxRuntime.create {}.use { parked ->
                SharedTmuxRuntime.create {}.use { current ->
                    SessionProgramStatus().use { status ->
                        status.setEnabled(true, null)
                        status.attachTmux(parked)
                        parked.feed("%output %31 \\033]7501;state=done\\007\r\n".encodeToByteArray())
                        status.pullTmux(parked)
                        assertEquals(SharedProgramStatusAttention.FINISHED, status.snapshot.value.pane(31)?.attention)
                        status.attachTmux(current)
                        status.setEnabled(false, current)
                        status.setEnabled(true, current)
                        assertTrue(checkNotNull(parked.programStatus()).terminals.isNotEmpty())
                        if (attach) status.attachTmux(parked) else status.pullTmux(parked)
                        assertTrue(status.snapshot.value.terminals.isEmpty())
                        assertTrue(checkNotNull(parked.programStatus()).terminals.isEmpty())
                        parked.feed("%output %31 \\033]7501;state=error\\007\r\n".encodeToByteArray())
                        status.pullTmux(parked)
                        assertEquals(SharedProgramStatusAttention.FAILED, status.snapshot.value.pane(31)?.attention)
                    }
                }
            }
        }
    }

    @Test
    fun closedHolderStopsReadingAndCreatesNoMonitor() {
        val status = SessionProgramStatus()
        status.close()
        status.setEnabled(true, tmuxRuntime = null)
        assertTrue(status.feedRaw(query).isEmpty())
        assertTrue(status.snapshot.value.terminals.isEmpty())
        status.noteRawTransportLost()
        status.acknowledge(SharedProgramStatusTerminal.Raw, Long.MAX_VALUE, null)
    }

    private fun report(fields: String) = "\u001B]7501;$fields\u0007".encodeToByteArray()
}
