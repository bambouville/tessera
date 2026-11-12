package com.bambouville.tessera.feature.session

import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.forwarding.BoundForwardEndpoint
import com.bambouville.tessera.forwarding.ForwardingCapabilities
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardingLease
import com.bambouville.tessera.forwarding.PortForwardingRuntime
import com.bambouville.tessera.networking.AuthenticatedForwardingSideChannel
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import net.schmizz.sshj.SSHClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Real acquirer with a retained fake carrier; no connect or socket is needed. */
class SessionArtifactForwardingLeaseTest {
    private class Client : SSHClient() {
        @Volatile var live = true
        val connections = AtomicInteger()
        override fun isConnected() = live
        override fun isAuthenticated() = true
        override fun connect(hostname: String, port: Int) {
            connections.incrementAndGet()
            error("artifacts must never connect")
        }
        override fun close() = Unit
    }
    private class Lease : PortForwardingLease {
        override val bound = BoundForwardEndpoint("127.0.0.1", 45555)
        override val activeConnectionCount = MutableStateFlow(0)
        override val isOpen = MutableStateFlow(true)
        val closes = AtomicInteger()
        override fun close() { closes.incrementAndGet(); isOpen.value = false }
    }
    private class Runtime : PortForwardingRuntime {
        override val capabilities = ForwardingCapabilities(local = true, remote = false, dynamic = false)
        val lease = Lease()
        var starts = 0
        var duringStart: () -> Unit = {}
        override suspend fun start(rule: PortForwardRule): PortForwardingLease {
            starts += 1
            duringStart()
            return lease
        }
        override fun close() = Unit
    }
    private fun carrier(client: Client, runtime: Runtime): AuthenticatedForwardingSideChannel =
        AuthenticatedForwardingSideChannel::class.java.getDeclaredConstructor(SSHClient::class.java, List::class.java)
            .apply { isAccessible = true }.newInstance(client, emptyList<Closeable>()).apply { setPrivate("runtime", runtime) }
    private fun controller(scope: kotlinx.coroutines.CoroutineScope, carrier: AuthenticatedForwardingSideChannel?) =
        (unsafe.allocateInstance(SshSessionController::class.java) as SshSessionController).apply {
            setPrivate("scope", scope)
            setPrivate("forwardingLock", Any())
            setPrivate("host", SavedHost(UUID.randomUUID().toString(), "fixture", "fixture.invalid", 22, "fixture", null, null,
                transportKind = TransportKinds.MOSH, tmuxMode = TmuxModes.OFF))
            setPrivate("transportConnected", true)
            setPrivate("mutableState", MutableStateFlow<SshSessionUiState>(SshSessionUiState.Connected))
            setPrivate("forwardingSideChannel", carrier)
        }
    private val rule = PortForwardRule(bind = PortForwardEndpoint("127.0.0.1", 0), target = PortForwardEndpoint("127.0.0.1", 5173))

    @Test fun failedOrDisconnectedControllersCannotForwardEvenWhenTheirCarrierSurvives() = runTest {
        for (state in listOf(SshSessionUiState.Failed("protocol failed"), SshSessionUiState.Disconnected, SshSessionUiState.Terminated)) {
            val client = Client()
            val runtime = Runtime()
            val controller = controller(backgroundScope, carrier(client, runtime))
            controller.setPrivate("mutableState", MutableStateFlow(state))
            assertNull("$state must not own a page forward", controller.acquire())
            assertEquals(0, runtime.starts)
            assertEquals(0, client.connections.get())
        }
    }

    @Test fun sessionFailureRetiresAnExistingLeaseEvenWhenItsCarrierSurvives() = runTest {
        val client = Client()
        val runtime = Runtime()
        val controller = controller(backgroundScope, carrier(client, runtime))
        val lease = checkNotNull(controller.acquire())
        try {
            controller.setPrivate("mutableState", MutableStateFlow<SshSessionUiState>(SshSessionUiState.Failed("protocol failed")))
            assertFalse(lease.isOpen.value)
            assertFalse(withTimeout(3_000) { runtime.lease.isOpen.first { !it } })
            assertEquals(1, runtime.lease.closes.get())
            assertTrue(client.live)
            assertEquals(0, client.connections.get())
        } finally { lease.close() }
    }

    @Test fun aDeadSideChannelCannotSupplyALeaseWhileMoshRemainsConnected() = runTest {
        val client = Client().apply { live = false }
        val runtime = Runtime()
        val controller = controller(backgroundScope, carrier(client, runtime))
        assertNull(controller.acquire())
        assertEquals(0, runtime.starts)
        assertEquals(0, client.connections.get())
    }

    @Test fun sideChannelLossClosesTheListenerAndUpdatesItsOpenState() = runTest {
        val client = Client()
        val runtime = Runtime()
        val controller = controller(backgroundScope, carrier(client, runtime))
        val lease = checkNotNull(controller.acquire())
        try {
            assertTrue(lease.isOpen.value)
            client.live = false
            assertFalse(lease.isOpen.value)
            assertFalse(runtime.lease.isOpen.value)
            lease.close()
            assertEquals(1, runtime.lease.closes.get())
            assertNull(controller.acquire())
            assertEquals(0, client.connections.get())
        } finally { lease.close() }
    }

    @Test fun replacingTheCarrierRetiresTheOldLeaseEvenWhenBothCarriersAreConnected() = runTest {
        val client = Client()
        val runtime = Runtime()
        val controller = controller(backgroundScope, carrier(client, runtime))
        val lease = checkNotNull(controller.acquire())
        try {
            controller.setPrivate("forwardingSideChannel", carrier(Client(), Runtime()))
            assertFalse(lease.isOpen.value)
            assertEquals(1, runtime.lease.closes.get())
            assertEquals(0, client.connections.get())
        } finally { lease.close() }
    }

    @Test fun replacementDuringAcquisitionCannotPublishTheOldCarriersLease() = runTest {
        val client = Client()
        val runtime = Runtime()
        val controller = controller(backgroundScope, carrier(client, runtime))
        runtime.duringStart = { controller.setPrivate("forwardingSideChannel", carrier(Client(), Runtime())) }
        assertNull(controller.acquire())
        assertEquals(1, runtime.lease.closes.get())
        assertEquals(0, client.connections.get())
    }

    @Test(timeout = 5_000) fun carrierLossIsPublishedToCollectorsWithoutPollingTheLease() = runBlocking {
        val client = Client()
        val runtime = Runtime()
        val controller = controller(this, carrier(client, runtime))
        val lease = checkNotNull(controller.acquire())
        try {
            val closed = async { withTimeout(3_000) { lease.isOpen.first { !it } } }
            client.live = false
            assertFalse(closed.await())
            assertFalse(runtime.lease.isOpen.value)
            assertEquals(0, client.connections.get())
        } finally { lease.close() }
    }

    private suspend fun SshSessionController.acquire(): PortForwardingLease? = suspendCoroutineUninterceptedOrReturn { continuation ->
        try {
            javaClass.getDeclaredMethod("acquireArtifactForwardingLease", PortForwardRule::class.java, Continuation::class.java)
                .apply { isAccessible = true }.invoke(this, rule, continuation)
        } catch (failure: java.lang.reflect.InvocationTargetException) { throw failure.targetException }
    }
    private fun Any.setPrivate(name: String, value: Any?) { javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value) }
    private companion object {
        val unsafe = sun.misc.Unsafe::class.java.getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null) as sun.misc.Unsafe
    }
}
