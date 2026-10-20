package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentSessionKey
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentExecBindingGateTest {
    @Test
    fun cancelledRequestWaitingForChannelDoesNotBlockAnotherPane(): Unit = runBlocking {
        val gate = AgentExecBindingGate<String>()
        val channels = Semaphore(1)
        val active = assertNotNullLease(gate.acquire("old-pane", channels) { true })
        val waiting = async(start = CoroutineStart.UNDISPATCHED) {
            gate.acquire("old-pane", channels) { true }
        }
        assertFalse(waiting.isCompleted)
        waiting.cancelAndJoin()
        assertEquals(0, channels.availablePermits)
        active.close()
        active.close()
        assertEquals(1, channels.availablePermits)
        val next = withTimeout(1_000) { gate.acquire("new-pane", channels) { true } }
        assertNotNull(next)
        assertEquals(0, channels.availablePermits)
        next?.close()
        next?.close()
        assertEquals(1, channels.availablePermits)
    }

    @Test
    fun tmuxEndpointIsNotPublishedUntilItHasAConcretePane() {
        val key = AgentSessionKey("session", 1)
        val provisional = AgentEndpointBinding(key, "host", AgentEndpointTransport.SSH_TMUX, "tmux")
        val concrete = provisional.copy(windowID = "@1", paneID = "%2")
        val raw = AgentEndpointBinding(key, "host", AgentEndpointTransport.SSH)

        assertFalse(provisional.isPublishableAgentBinding())
        assertTrue(concrete.isPublishableAgentBinding())
        assertTrue(raw.isPublishableAgentBinding())
    }

    @Test
    fun sameBindingHelpersCanRunConcurrently() {
        runBlocking {
            val gate = AgentExecBindingGate<String>()
            val first = assertNotNullLease(gate.acquire("pane-a"))
            val second = withTimeout(1_000) { gate.acquire("pane-a") }

            assertNotNull(second)
            second?.close()
            first.close()
        }
    }

    @Test
    fun replacementBindingWaitsForEveryOldHelperToClose() {
        runBlocking {
            val gate = AgentExecBindingGate<String>()
            val oldProbe = assertNotNullLease(gate.acquire("provisional"))
            val oldProjector = assertNotNullLease(gate.acquire("provisional"))
            val replacement = async { gate.acquire("pane-1") }

            assertFalse(replacement.isCompleted)
            oldProbe.close()
            assertFalse(replacement.isCompleted)
            oldProjector.close()

            val acquired = withTimeout(1_000) { replacement.await() }
            assertNotNull(acquired)
            acquired?.close()
        }
    }

    @Test
    fun invalidReplacementStopsWaitingWithoutAcquiring() {
        runBlocking {
            val gate = AgentExecBindingGate<String>()
            val old = assertNotNullLease(gate.acquire("old"))
            var valid = true
            val replacement = async { gate.acquire("new") { valid } }

            assertFalse(replacement.isCompleted)
            valid = false
            old.close()

            assertTrue(withTimeout(1_000) { replacement.await() } == null)
        }
    }

    @Test
    fun closeWakesAReplacementWaitingBehindAnActiveBinding() {
        runBlocking {
            val gate = AgentExecBindingGate<String>()
            val active = assertNotNullLease(gate.acquire("old"))
            val replacement = async { gate.acquire("new") }

            assertFalse(replacement.isCompleted)
            gate.close()

            assertTrue(withTimeout(1_000) { replacement.await() } == null)
            active.close()
        }
    }

    private fun assertNotNullLease(value: AutoCloseable?): AutoCloseable {
        assertNotNull(value)
        return requireNotNull(value)
    }
}
