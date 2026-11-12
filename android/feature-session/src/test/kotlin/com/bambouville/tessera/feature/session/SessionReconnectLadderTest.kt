package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedConnectionIntent
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import java.util.UUID
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A session whose transport dropped while it was off screen parks its
 * reconnect until it is shown. Opening the host starts a connect of its own,
 * and the same show wakes the parked attempt.
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class SessionReconnectLadderTest {
    private val dispatcher = StandardTestDispatcher()
    private val scopes = mutableListOf<CoroutineScope>()

    @After fun cancelScopes() {
        scopes.forEach { it.coroutineContext[Job]?.cancel() }
    }

    @Test fun openingAHostWhileItsReconnectIsParkedKeepsTheOpeningConnect() {
        val controller = parkedController()
        controller.scheduleReconnect("transport_disconnected")
        dispatcher.scheduler.advanceTimeBy(10_000)
        dispatcher.scheduler.runCurrent()
        @Suppress("UNCHECKED_CAST")
        val state = controller.privateValue("mutableState") as MutableStateFlow<SshSessionUiState>
        assertEquals(SshSessionUiState.Disconnected, state.value)

        controller.connect()
        val opening = controller.privateValue("currentIntent") as SharedConnectionIntent
        controller.setPrivate("presentationActive", true)
        dispatcher.scheduler.advanceTimeBy(10_000)
        dispatcher.scheduler.runCurrent()

        assertSame(
            "the parked attempt must not replace the connect that opened the host",
            opening,
            controller.privateValue("currentIntent"),
        )
        assertNull(controller.privateValue("reconnectJob"))
    }

    @Test fun aParkedReconnectStillConnectsWhenNothingElseDid() {
        val controller = parkedController()
        controller.scheduleReconnect("transport_disconnected")
        dispatcher.scheduler.advanceTimeBy(10_000)
        dispatcher.scheduler.runCurrent()
        assertNull(controller.privateValue("currentIntent"))

        controller.setPrivate("presentationActive", true)
        dispatcher.scheduler.advanceTimeBy(10_000)
        dispatcher.scheduler.runCurrent()

        assertTrue(controller.privateValue("currentIntent") is SharedConnectionIntent)
        assertNull(controller.privateValue("reconnectJob"))
    }

    private fun parkedController(): SshSessionController =
        (unsafe.allocateInstance(SshSessionController::class.java) as SshSessionController).apply {
            // `connect` hands its intent to the native core from a child
            // coroutine this harness has no core for; that child's failure is
            // not what these tests read, so the scope absorbs it.
            val scope = CoroutineScope(SupervisorJob() + dispatcher + CoroutineExceptionHandler { _, _ -> })
            scopes += scope
            setPrivate("scope", scope)
            setPrivate("tmuxTransportLock", Any())
            setPrivate("mutableState", MutableStateFlow<SshSessionUiState>(SshSessionUiState.Disconnected))
            setPrivate("diagnostics", testDiagnosticLogStore())
            setPrivate("diagnosticTransport", "ssh_tmux")
            setPrivate("host", SavedHost(UUID.randomUUID().toString(), "fixture", "fixture.invalid", 22, "fixture", null, null,
                transportKind = TransportKinds.SSH, tmuxMode = TmuxModes.AUTOMATIC))
            setPrivate("closed", false)
            setPrivate("appForeground", true)
            setPrivate("presentationActive", false)
        }

    private fun SshSessionController.scheduleReconnect(reason: String) {
        SshSessionController::class.java.getDeclaredMethod("scheduleReconnect", String::class.java)
            .apply { isAccessible = true }
            .invoke(this, reason)
    }

    private fun Any.privateValue(name: String): Any? =
        javaClass.getDeclaredField(name).apply { isAccessible = true }.get(this)

    private fun Any.setPrivate(name: String, value: Any?) {
        javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value)
    }

    private companion object {
        val unsafe: sun.misc.Unsafe = sun.misc.Unsafe::class.java
            .getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null) as sun.misc.Unsafe
    }
}
