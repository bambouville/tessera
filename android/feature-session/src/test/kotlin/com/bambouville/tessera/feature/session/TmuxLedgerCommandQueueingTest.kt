package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxRenderEffect
import com.bambouville.tessera.networking.SshTmuxConnection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.channels.Channel

/**
 * The reducer's commands reach the writer from the critical section that
 * admitted them to the core's reply FIFO, and a run the reducer emitted
 * together stays together on the wire.
 *
 * A tmux control reply names no command, so anything that reorders these
 * against the FIFO hands every later reply to its neighbour's purpose — the
 * failure that left an attaching pane hanging on a real device.
 */
class TmuxLedgerCommandQueueingTest {
    @Test
    fun contiguousReducerRunsBecomeOneWireTransactionEach() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val tmux = unsafe.allocateInstance(SshTmuxConnection::class.java) as SshTmuxConnection
        val controller = bareController(queue, tmux)

        val queued = controller.enqueueLedgerRenderCommands(
            listOf(
                SharedTmuxRenderEffect.SendCommand("refresh-client -C 56,46"),
                SharedTmuxRenderEffect.SendCommand("select-window -t @3"),
                SharedTmuxRenderEffect.Diagnostic("render-ledger something"),
                SharedTmuxRenderEffect.SendCommand("display-message -p -t @3 '#{pane_id}'"),
            ),
            tmux,
        )

        assertTrue(queued)
        val first = queue.tryReceive().getOrThrow()
        assertEquals(
            listOf("refresh-client -C 56,46", "select-window -t @3"),
            first.wireCommands,
        )
        assertTrue("a reducer command is never re-admitted by the writer", first.ledgerOwned)
        assertNull(first.purpose)
        val second = queue.tryReceive().getOrThrow()
        assertEquals(listOf("display-message -p -t @3 '#{pane_id}'"), second.wireCommands)
        assertNull(queue.tryReceive().getOrNull())
    }

    @Test
    fun aBatchWithoutCommandsQueuesNothingAndStillSucceeds() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val tmux = unsafe.allocateInstance(SshTmuxConnection::class.java) as SshTmuxConnection
        val controller = bareController(queue, tmux)

        assertTrue(
            controller.enqueueLedgerRenderCommands(
                listOf(SharedTmuxRenderEffect.Diagnostic("render-ledger something")),
                tmux,
            )
        )
        assertNull(queue.tryReceive().getOrNull())
    }

    @Test
    fun aReplacedTransportQueuesNothingAndReportsIt() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val tmux = unsafe.allocateInstance(SshTmuxConnection::class.java) as SshTmuxConnection
        val controller = bareController(queue, tmux)
        controller.setPrivate("tmuxTransportGeneration", 9L)

        assertEquals(
            false,
            controller.enqueueLedgerRenderCommands(
                listOf(SharedTmuxRenderEffect.SendCommand("select-window -t @3")),
                tmux,
            ),
        )
        assertNull(queue.tryReceive().getOrNull())
    }

    private fun bareController(
        queue: Channel<TmuxControlCommand>,
        tmux: SshTmuxConnection,
    ): SshSessionController {
        val controller = unsafe.allocateInstance(SshSessionController::class.java) as SshSessionController
        controller.setPrivate("tmuxTransportLock", Any())
        controller.setPrivate("tmuxCommandChannel", queue)
        controller.setPrivate("tmuxConnection", tmux)
        controller.setPrivate("tmuxTransportGeneration", 8L)
        controller.setPrivate("closed", false)
        return controller
    }

    private fun SshSessionController.enqueueLedgerRenderCommands(
        effects: List<SharedTmuxRenderEffect>,
        tmux: SshTmuxConnection,
    ): Boolean = javaClass
        .getDeclaredMethod(
            "enqueueLedgerRenderCommands",
            List::class.java,
            SshTmuxConnection::class.java,
            Long::class.javaPrimitiveType!!,
        )
        .apply { isAccessible = true }
        .invoke(this, effects, tmux, 8L) as Boolean

    private fun Any.setPrivate(name: String, value: Any?) {
        javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value)
    }

    private companion object {
        val unsafe: sun.misc.Unsafe = sun.misc.Unsafe::class.java
            .getDeclaredField("theUnsafe")
            .apply { isAccessible = true }
            .get(null) as sun.misc.Unsafe
    }
}
