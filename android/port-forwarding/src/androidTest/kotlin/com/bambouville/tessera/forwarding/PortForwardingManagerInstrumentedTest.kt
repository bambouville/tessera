package com.bambouville.tessera.forwarding

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Manager lifecycle, on a device where the shared core can be loaded.
 *
 * Every start path consults the shared validator and the shared transport
 * capabilities, so these cases cannot run as JVM unit tests. What they check is
 * still this platform's own: which rules attach starts, when reconcile
 * restarts a listener rather than updating it in place, and that an
 * unsupported transport publishes a failure instead of opening a socket.
 */
@RunWith(AndroidJUnit4::class)
class PortForwardingManagerInstrumentedTest {
    @Test
    fun attachStartsOnlyAutoStartRulesAndReconcileRestartsTransportChanges() = runBlocking {
        val runtime = FakeRuntime()
        val auto = localRule(port = 8100)
        val manual = localRule(port = 8101).copy(autoStart = false)
        val manager = PortForwardingManager()

        manager.attach(runtime, listOf(auto, manual))

        assertEquals(listOf(auto.id), runtime.started.map { it.id })
        assertTrue(manager.states.value.getValue(auto.id).status is PortForwardingStatus.Listening)
        assertEquals(PortForwardingStatus.Idle, manager.states.value.getValue(manual.id).status)

        manager.reconcile(listOf(auto.copy(target = PortForwardEndpoint("db.internal", 5432)), manual))

        assertEquals(2, runtime.started.count { it.id == auto.id })
        assertTrue(runtime.closedLeaseIds.contains(auto.id))
        manager.detach()
        assertTrue(runtime.closed)
    }

    @Test
    fun moshWithoutSshSideChannelReportsUnsupportedInsteadOfOpeningAListener() = runBlocking {
        val runtime = FakeRuntime(
            capabilities = ForwardingCapabilities.forTransport(
                ForwardingTransport.Mosh(sshSideChannelAvailable = false),
            ),
        )
        val rule = localRule()
        val manager = PortForwardingManager()

        manager.attach(runtime, listOf(rule))

        assertTrue(runtime.started.isEmpty())
        val failure = manager.states.value.getValue(rule.id).status as? PortForwardingStatus.Failed
        assertTrue(failure?.failure is PortForwardingFailure.Unsupported)
        manager.detach()
    }

    private fun localRule(
        bindHost: String = "127.0.0.1",
        port: Int = 8080,
    ) = PortForwardRule(
        id = UUID.randomUUID(),
        bind = PortForwardEndpoint(bindHost, port),
        target = PortForwardEndpoint("localhost", 80),
    )

    private class FakeRuntime(
        override val capabilities: ForwardingCapabilities = ForwardingCapabilities.forTransport(ForwardingTransport.Ssh),
    ) : PortForwardingRuntime {
        val started = mutableListOf<PortForwardRule>()
        val closedLeaseIds = mutableListOf<UUID>()
        var closed = false

        override suspend fun start(rule: PortForwardRule): PortForwardingLease {
            started += rule
            return FakeLease(
                BoundForwardEndpoint(rule.bind.host, if (rule.bind.port == 0) 49152 else rule.bind.port),
            ) { closedLeaseIds += rule.id }
        }

        override fun close() {
            closed = true
        }
    }

    private class FakeLease(
        override val bound: BoundForwardEndpoint,
        private val onClose: () -> Unit,
    ) : PortForwardingLease {
        private val activity = MutableStateFlow(0)
        private val open = MutableStateFlow(true)
        override val activeConnectionCount: StateFlow<Int> = activity
        override val isOpen: StateFlow<Boolean> = open
        private var closed = false

        override fun close() {
            if (closed) return
            closed = true
            open.value = false
            onClose()
        }
    }
}
