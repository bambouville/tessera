package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedConnectionIntent
import com.bambouville.tessera.core.bridge.SharedSessionEvent
import com.bambouville.tessera.core.bridge.SharedSessionListener
import com.bambouville.tessera.core.bridge.SharedSessionRuntime
import com.bambouville.tessera.core.bridge.SharedSessionState
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.design.DisplayText
import com.bambouville.tessera.forwarding.BoundForwardEndpoint
import com.bambouville.tessera.forwarding.ForwardingCapabilities
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardingFailure
import com.bambouville.tessera.forwarding.PortForwardingLease
import com.bambouville.tessera.forwarding.PortForwardingManager
import com.bambouville.tessera.forwarding.PortForwardingRuntime
import com.bambouville.tessera.forwarding.PortForwardingStatus
import com.bambouville.tessera.networking.SshRouteOwner
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.lang.reflect.Proxy
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.test.StandardTestDispatcher
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** The real controller and manager; no SSH authentication or remote host. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class SessionForwardingLifecycleTest {
    @get:Rule val failures = UncaughtCoroutineFailures()
    private val dispatcher = StandardTestDispatcher()
    private val scopes = mutableListOf<CoroutineScope>()
    private val managers = mutableListOf<PortForwardingManager>()
    private val routes = mutableListOf<SshRouteOwner>()
    private val sessions = mutableListOf<SharedSessionRuntime>()

    @After fun cleanUp() {
        scopes.forEach { it.coroutineContext[Job]?.cancel() }
        dispatcher.scheduler.runCurrent()
        managers.forEach { it.close() }
        routes.forEach { it.close() }
        sessions.forEach { it.close() }
    }

    @Test(timeout = 10_000)
    fun addingARuleWhileTheLastRuleIsStoppingKeepsTheAuthenticatedRuntime() = runBlocking {
        val stopping = CountDownLatch(1)
        val finishStop = CountDownLatch(1)
        val runtime = FakeRuntime {
            stopping.countDown()
            check(finishStop.await(5, TimeUnit.SECONDS)) { "test did not release the stopped listener" }
        }
        val old = rule()
        val added = rule()
        val manager = manager().also { it.attach(runtime, listOf(old)) }
        val controller = controller(manager, listOf(old))
        try {
            controller.updateForwardingRules(emptyList())
            dispatcher.scheduler.runCurrent()
            assertTrue("the old listener did not start closing", stopping.await(5, TimeUnit.SECONDS))
            controller.updateForwardingRules(listOf(added))
            dispatcher.scheduler.runCurrent()
        } finally {
            finishStop.countDown()
        }

        await("the replacement rule was not applied") { controller.updateFinished() && added.id in manager.states.value }

        assertTrue(manager.states.value.getValue(added.id).status.toString(),
            manager.states.value.getValue(added.id).status is PortForwardingStatus.Listening)
        assertFalse("a rule edit retired the authenticated runtime", runtime.closed)
        assertEquals(setOf(added.id), manager.states.value.keys)
    }

    @Test(timeout = 10_000)
    fun startRetriesAttachmentAndStartsAManualRuleAfterAnAttachmentFailure() =
        startAfterAttachmentFailure(tmux = false)

    @Test(timeout = 10_000)
    fun startRestoresForwardingOnTheAuthenticatedTmuxRoute() =
        startAfterAttachmentFailure(tmux = true)

    private fun startAfterAttachmentFailure(tmux: Boolean) = runBlocking {
        val manual = rule().copy(autoStart = false)
        val manager = manager()
        manager.reportTransportUnavailable(listOf(manual), "previous attachment failed")
        val controller = controller(manager, listOf(manual))
        val route = route()
        if (tmux) controller.setPrivate("tmuxConnection", route.openTmux("fixture"))
        else controller.setPrivate("connection", route.openTerminal(80, 24))

        controller.startForwardingRule(manual.id)

        await("Start did not restore forwarding") {
            manager.states.value[manual.id]?.status is PortForwardingStatus.Listening
        }
    }

    @Test(timeout = 10_000)
    fun rulesLoadedAfterTheInitialCheckAttachWhenConnectedIsDelivered() = runBlocking {
        val manager = manager()
        val controller = controller(manager, emptyList())
        controller.setPrivate("transportConnected", false)
        controller.setPrivate("connection", route().openTerminal(80, 24))
        // The initial transport check saw no rules. The loader finishes while
        // CONNECTED is still queued on the controller's Main dispatcher.
        val loaded = rule()
        controller.updateForwardingRules(listOf(loaded))
        await("the rule load did not finish") { controller.updateFinished() }
        assertTrue(manager.states.value.isEmpty())

        controller.receive(SharedSessionEvent.StateChanged(1, SharedSessionState.CONNECTED))

        await("CONNECTED did not attach the late rules") {
            manager.states.value[loaded.id]?.status is PortForwardingStatus.Listening
        }
    }

    @Test(timeout = 10_000)
    fun removingTheLastRuleClearsItsStateWithoutClosingTheRuntime() = runBlocking {
        val original = rule()
        val runtime = FakeRuntime {}
        val manager = manager().also { it.attach(runtime, listOf(original)) }
        val controller = controller(manager, listOf(original))

        controller.updateForwardingRules(emptyList())

        await("the removed rule remained published") { controller.updateFinished() && manager.states.value.isEmpty() }
        assertFalse(runtime.closed)
        assertTrue(manager.reconcileIfAttached(emptyList()))
    }

    @Test(timeout = 10_000)
    fun initialRuleHydrationDoesNotStartAManualRuleThatJustAttached() = runBlocking {
        val manual = rule().copy(autoStart = false)
        val runtime = FakeRuntime {}
        val manager = manager().also { it.attach(runtime, listOf(manual)) }
        val controller = controller(manager, emptyList())
        controller.setPrivate("transportConnected", false)

        controller.updateForwardingRules(listOf(manual))

        await("initial hydration did not finish") { controller.updateFinished() }
        assertEquals(PortForwardingStatus.Idle, manager.states.value.getValue(manual.id).status)
    }

    @Test(timeout = 10_000)
    fun addingAManualRuleToAConnectedSessionStartsItImmediately() = runBlocking {
        val manual = rule().copy(autoStart = false)
        val runtime = FakeRuntime {}
        val manager = manager().also { it.attach(runtime, emptyList()) }
        val controller = controller(manager, emptyList())

        controller.updateForwardingRules(listOf(manual))

        await("the connected edit did not start its enabled rule") {
            controller.updateFinished() && manager.states.value[manual.id]?.status is PortForwardingStatus.Listening
        }
    }

    @Test(timeout = 10_000)
    fun connectedRechecksPreserveAManuallyStoppedRule() = runBlocking {
        val original = rule()
        val runtime = FakeRuntime {}
        val manager = manager().also { it.attach(runtime, listOf(original)); it.stop(original.id) }
        val controller = controller(manager, listOf(original))

        controller.receive(SharedSessionEvent.StateChanged(1, SharedSessionState.CONNECTED))
        await("the connected recheck did not finish") {
            scopes.last().coroutineContext[Job]!!.children.none { it.isActive }
        }

        assertEquals(PortForwardingStatus.Idle, manager.states.value.getValue(original.id).status)
        assertFalse(runtime.closed)
    }

    @Test(timeout = 10_000)
    fun teardownCancelsAnAttachmentWaitingForCredentialUiWithoutWaitingForMain() = runBlocking {
        val manager = manager()
        val controller = controller(manager, listOf(rule()))
        val decision = CompletableDeferred<Unit>()
        val pending = scopes.last().async { decision.await() }
        controller.setPrivate("forwardingAttachJob", pending)
        dispatcher.scheduler.runCurrent()

        controller.javaClass.getDeclaredMethod("detachForwardingBlocking")
            .apply { isAccessible = true }.invoke(controller)

        assertTrue("teardown left its credential wait alive", pending.isCancelled)
        dispatcher.scheduler.runCurrent()
        assertTrue(manager.states.value.isEmpty())
    }

    @Test(timeout = 10_000)
    fun decliningAuxiliaryAuthenticationPublishesAForwardingFailure() = runBlocking {
        val preview = rule()
        val manager = manager()
        val controller = controller(manager, listOf(preview))
        val client = AuthenticatedFakeClient()
        controller.setPrivate("connection", route(client).openTerminal(80, 24))
        // A user decision rejects the auxiliary operation with a
        // CancellationException while its coroutine is still active.
        client.refusal = CancellationException("owner authorization cancelled")

        controller.startForwardingRule(preview.id)

        await("the declined auxiliary operation cancelled the job instead of reporting its error") {
            manager.states.value[preview.id]?.status is PortForwardingStatus.Failed
        }
        assertTrue(scopes.last().coroutineContext[Job]!!.isActive)
        // The reason stays English for diagnostics; the panel resolves its own words as it shows them.
        assertEquals(
            PortForwardingFailure.Transport(
                "Forwarding side channel is unavailable: cancelled",
                DisplayText.Resource(R.string.session_forwarding_side_channel_unavailable, listOf("cancelled")),
            ),
            (manager.states.value.getValue(preview.id).status as PortForwardingStatus.Failed).failure,
        )
    }

    @Test(timeout = 10_000)
    fun ioTeardownWhileStartChecksTheManagerCannotAttachToTheRetiredCarrier() = runBlocking {
        val preview = rule()
        val manager = manager()
        val controller = controller(manager, listOf(preview))
        val client = AuthenticatedFakeClient()
        controller.setPrivate("connection", route(client).openTerminal(80, 24))
        val mutex = manager.javaClass.getDeclaredField("mutex").apply { isAccessible = true }.get(manager) as Mutex
        val failure = AtomicReference<Throwable?>(null)
        val detach = Thread {
            try {
                controller.javaClass.getDeclaredMethod("detachForwardingBlocking")
                    .apply { isAccessible = true }.invoke(controller)
            } catch (error: Throwable) {
                failure.set(error)
            }
        }

        mutex.lock()
        try {
            controller.startForwardingRule(preview.id)
            dispatcher.scheduler.runCurrent()
            detach.start()
            await("IO teardown did not invalidate forwarding admission") {
                val lock = checkNotNull(controller.javaClass.getDeclaredField("forwardingLock")
                    .apply { isAccessible = true }.get(controller))
                synchronized(lock) {
                    controller.javaClass.getDeclaredField("forwardingCarrierRequestId")
                        .apply { isAccessible = true }.get(controller) == null
                }
            }
        } finally {
            mutex.unlock()
        }
        detach.join(5_000)
        assertFalse("IO teardown waited for Main", detach.isAlive)
        assertNull(failure.get())
        await("Start did not retire its stale work") {
            scopes.last().coroutineContext[Job]!!.children.none { it.isActive }
        }
        assertEquals("a stale Start recreated a forwarding runtime", 0, client.forwardingChecks.get())
        assertTrue(manager.states.value.isEmpty())
    }

    @Test(timeout = 10_000)
    fun aLateTransportReadyCallbackCannotReadmitARetiredGeneration() = runBlocking {
        val manager = manager()
        val controller = controller(manager, listOf(rule()))
        val client = AuthenticatedFakeClient()
        controller.setPrivate("connection", route(client).openTerminal(80, 24))
        val intent = controller.javaClass.getDeclaredField("currentIntent")
            .apply { isAccessible = true }.get(controller) as SharedConnectionIntent
        controller.javaClass.getDeclaredMethod("detachForwardingBlocking")
            .apply { isAccessible = true }.invoke(controller)

        val late = scopes.last().async { controller.bindForwarding(intent, generation = 0) }

        await("the stale transport-ready callback did not return") { late.isCompleted }
        assertFalse(late.isCancelled)
        assertEquals(0, client.forwardingChecks.get())
        assertTrue(manager.states.value.isEmpty())
    }

    private fun manager() = PortForwardingManager().also { managers += it }

    private fun controller(manager: PortForwardingManager, rules: List<PortForwardRule>) =
        (unsafe.allocateInstance(SshSessionController::class.java) as SshSessionController).apply {
            val hostId = UUID.randomUUID()
            val scope = failures.scope(dispatcher)
            scopes += scope
            setPrivate("scope", scope)
            setPrivate("host", SavedHost(hostId.toString(), "fixture", "fixture.invalid", 22, "fixture", null, null,
                transportKind = TransportKinds.SSH, tmuxMode = TmuxModes.OFF))
            val intent = SharedConnectionIntent(UUID.randomUUID(), hostId, 0)
            setPrivate("currentIntent", intent)
            setPrivate("forwardingCarrierRequestId", intent.requestId)
            setPrivate("diagnostics", testDiagnosticLogStore())
            setPrivate("diagnosticTransport", "ssh")
            setPrivate("tmuxTransportLock", Any())
            setPrivate("mutableState", MutableStateFlow<SshSessionUiState>(SshSessionUiState.Connecting))
            setPrivate("mutableTmuxSnapshot", MutableStateFlow<SharedTmuxSnapshot?>(null))
            setPrivate("sessionId", UUID.randomUUID().toString())
            setPrivate("restore", RecordingSessionRestoreRepository())
            setPrivate("shared", SharedSessionRuntime.create(object : SharedSessionListener {
                override fun onEvent(event: SharedSessionEvent) = Unit
            }).also { sessions += it })
            setPrivate("forwardingManager", manager)
            setPrivate("forwardingLock", Any())
            setPrivate("forwardingRules", rules)
            setPrivate("transportConnected", true)
        }

    private fun route(client: AuthenticatedFakeClient = AuthenticatedFakeClient()): SshRouteOwner {
        return SshRouteOwner::class.java.getDeclaredConstructor(SSHClient::class.java, List::class.java)
            .apply { isAccessible = true }.newInstance(client, listOf<Closeable>(client)).also { routes += it }
    }

    private suspend fun SshSessionController.receive(event: SharedSessionEvent): Unit =
        suspendCoroutineUninterceptedOrReturn { continuation ->
            try {
                javaClass.getDeclaredMethod("receive", SharedSessionEvent::class.java, Continuation::class.java)
                    .apply { isAccessible = true }.invoke(this, event, continuation)
            } catch (failure: java.lang.reflect.InvocationTargetException) {
                throw failure.targetException
            }
        }

    private suspend fun SshSessionController.bindForwarding(intent: SharedConnectionIntent, generation: Long): Unit =
        suspendCoroutineUninterceptedOrReturn { continuation ->
            try {
                javaClass.getDeclaredMethod("bindForwardingTransport", SharedConnectionIntent::class.java,
                    List::class.java, java.lang.Long.TYPE, Continuation::class.java)
                    .apply { isAccessible = true }.invoke(this, intent, emptyList<Any>(), generation, continuation)
            } catch (failure: java.lang.reflect.InvocationTargetException) {
                throw failure.targetException
            }
        }

    private fun SshSessionController.updateFinished(): Boolean =
        (javaClass.getDeclaredField("forwardingUpdateJob").apply { isAccessible = true }.get(this) as? Job)?.isCompleted != false

    private fun rule(): PortForwardRule {
        val port = ServerSocket(0).use { it.localPort }
        return PortForwardRule(bind = PortForwardEndpoint("127.0.0.1", port),
            target = PortForwardEndpoint("localhost", 8001))
    }

    private fun await(message: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!condition() && System.nanoTime() < deadline) {
            dispatcher.scheduler.runCurrent()
            Thread.sleep(1)
        }
        dispatcher.scheduler.runCurrent()
        assertTrue(message, condition())
    }

    private fun Any.setPrivate(name: String, value: Any?) {
        javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value)
    }

    private class FakeRuntime(private val closeListener: () -> Unit) : PortForwardingRuntime {
        override val capabilities = ForwardingCapabilities(local = true, remote = true, dynamic = true)
        var closed = false

        override suspend fun start(rule: PortForwardRule): PortForwardingLease = object : PortForwardingLease {
            override val bound = BoundForwardEndpoint(rule.bind.host, rule.bind.port)
            override val activeConnectionCount: StateFlow<Int> = MutableStateFlow(0)
            override val isOpen = MutableStateFlow(true)

            override fun close() {
                if (!isOpen.value) return
                closeListener()
                isOpen.value = false
            }
        }

        override fun close() { closed = true }
    }

    private class AuthenticatedFakeClient : SSHClient() {
        val forwardingChecks = AtomicInteger()
        var refusal: Throwable? = null
        override fun isConnected(): Boolean {
            forwardingChecks.incrementAndGet()
            refusal?.let { throw it }
            return true
        }
        override fun isAuthenticated() = true
        override fun close() = Unit

        override fun startSession(): Session {
            val input = ByteArrayInputStream(byteArrayOf())
            val output = ByteArrayOutputStream()
            return Proxy.newProxyInstance(javaClass.classLoader,
                arrayOf(Session::class.java, Session.Shell::class.java, Session.Command::class.java)) { proxy, method, arguments ->
                when (method.name) {
                    "startShell", "exec" -> proxy
                    "allocatePTY", "setEnvVar", "close" -> null
                    "getInputStream", "getErrorStream" -> input
                    "getOutputStream" -> output
                    "getExitStatus" -> null
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === arguments?.firstOrNull()
                    else -> error("Unexpected fake SSH call: ${method.name}")
                }
            } as Session
        }
    }

    private companion object {
        val unsafe = sun.misc.Unsafe::class.java.getDeclaredField("theUnsafe")
            .apply { isAccessible = true }.get(null) as sun.misc.Unsafe
    }
}
