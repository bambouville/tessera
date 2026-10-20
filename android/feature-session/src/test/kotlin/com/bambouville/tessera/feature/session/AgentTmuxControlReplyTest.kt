package com.bambouville.tessera.feature.session

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import com.bambouville.tessera.agent.platform.AgentTmuxControlAck
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AgentTmuxControlReplyTest {
    @Test
    fun tallPanePreservesPhysicalCursorRowAndComposer() {
        for ((height, cursor) in listOf(43 to 39, 80 to 76, 120 to 116)) {
            val rows = MutableList(height) { "" }
            rows[cursor] = "› Ask Codex to do anything"
            rows[cursor + 2] = "custom model status"
            val reply = agentTmuxControlReply(true, rows)
            assertTrue(reply.success)
            assertEquals(rows, reply.lines)
            assertEquals(rows[cursor], reply.lines.getOrNull(cursor))
        }
    }

    @Test
    fun oversizedUtf8ReplyFailsRatherThanReturningAuthoritativePartialRows() {
        val reply = agentTmuxControlReply(true, listOf("é".repeat(32_768)))
        assertFalse(reply.success)
        assertTrue(reply.lines.isEmpty())
    }

    @Test
    fun boundedReplyPreservesEmptyRowsAndCommandFailure() {
        val rows = listOf("", "one", "", "two", "")
        assertEquals(rows, agentTmuxControlReply(true, rows).lines)
        assertFalse(agentTmuxControlReply(false, rows).success)
    }

    // A tmux ack that never arrives is a failed command. Thrown as a
    // TimeoutCancellationException it read as the caller's own cancellation.
    @Test
    fun unansweredAgentCommandsFailInsteadOfCancellingTheCaller() = runTest {
        val port = TmuxAgentControlPort()
        port.attach(sender = { true }, windowSelector = { _, _ -> true }, paneSelector = { _, _, _ -> true })
        val send = async(start = CoroutineStart.UNDISPATCHED) { port.send("display-message -p x") }
        val window = async(start = CoroutineStart.UNDISPATCHED) { port.selectWindow("@1") }
        val pane = async(start = CoroutineStart.UNDISPATCHED) { port.selectPane("%1", preservingWindowZoom = true) }
        advanceTimeBy(TmuxAgentControlPort.TMUX_AGENT_ACK_TIMEOUT_MILLISECONDS + 1)
        for (ack in listOf(send.await(), window.await(), pane.await())) {
            assertFalse(ack.success)
            assertTrue(ack.lines.isEmpty())
        }

        // The caller's own cancellation still propagates. A cancelled
        // Deferred's await() throws even if the body swallowed the
        // cancellation, so the body itself must not run past the call.
        var returnedNormally = false
        val cancelled = async(start = CoroutineStart.UNDISPATCHED) {
            port.send("display-message -p y")
            returnedNormally = true
        }
        cancelled.cancel()
        try { cancelled.await(); fail("expected cancellation") } catch (_: CancellationException) {}
        assertTrue(cancelled.isCancelled)
        assertFalse("send swallowed the caller's cancellation", returnedNormally)
    }

    // A launch polls tmux for its receipt. Each unanswered poll now fails only
    // after its own 15 s ack timeout, so fifty of them would hold the launch
    // for over twelve minutes: the poll stops at its wall-clock budget.
    @Test
    fun launchReceiptPollStopsAtItsBudgetWhenAcksStall() = runTest {
        val port = TmuxAgentControlPort()
        port.attach(sender = { true }, windowSelector = { _, _ -> true }, paneSelector = { _, _, _ -> true })
        var polls = 0
        val stalled = pollTmuxUntil(attempts = 50, intervalMillis = 100, budgetMillis = TMUX_LAUNCH_RECEIPT_WAIT_MILLISECONDS,
            poll = { polls++; port.send("show-options -p -v -t %2 @tessera_agent_launch_receipt") }) { null as String? }
        assertEquals(null, stalled)
        assertEquals(1, polls)
        assertEquals(TMUX_LAUNCH_RECEIPT_WAIT_MILLISECONDS, currentTime)

        // Answered polls keep the count bound and the interval.
        polls = 0
        val start = currentTime
        assertEquals(null, pollTmuxUntil(attempts = 50, intervalMillis = 100, budgetMillis = TMUX_LAUNCH_RECEIPT_WAIT_MILLISECONDS,
            poll = { polls++; AgentTmuxControlAck(false, emptyList()) }) { null as String? })
        assertEquals(50, polls)
        assertEquals(5_000L, currentTime - start)
        polls = 0
        assertEquals("receipt", pollTmuxUntil(attempts = 50, intervalMillis = 100, budgetMillis = TMUX_LAUNCH_RECEIPT_WAIT_MILLISECONDS,
            poll = { polls++; AgentTmuxControlAck(true, listOf(if (polls == 3) "receipt" else "")) }) { ack ->
            ack.lines.firstOrNull { it.isNotEmpty() }
        })
        assertEquals(3, polls)

        // Running out is not the caller's cancellation; the caller's own still
        // propagates out of the poll rather than reading as "no receipt".
        var returnedNormally = false
        val cancelled = async(start = CoroutineStart.UNDISPATCHED) {
            pollTmuxUntil(attempts = 50, intervalMillis = 100, budgetMillis = TMUX_LAUNCH_RECEIPT_WAIT_MILLISECONDS,
                poll = { awaitCancellation() }) { null as String? }
            returnedNormally = true
        }
        cancelled.cancel()
        try { cancelled.await(); fail("expected cancellation") } catch (_: CancellationException) {}
        assertTrue(cancelled.isCancelled)
        assertFalse("the poll swallowed the caller's cancellation", returnedNormally)
    }
}
