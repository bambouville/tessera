package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedSessionEvent
import com.bambouville.tessera.core.bridge.SharedTerminalOutputReceipt
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.core.bridge.SharedTmuxPane
import com.bambouville.tessera.core.bridge.SharedTmuxRenderFact
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.terminal.RenderOwner
import com.bambouville.tessera.terminal.TerminalSurface
import java.lang.reflect.Proxy
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MoshPainterActivityControllerTest {
    @Test
    fun naturalSspAfterSplitFocusMovesToBReportsRetainedPainterA() {
        val fixture = Fixture()
        assertEquals(11, fixture.snapshot.value.activePaneId)
        fixture.focusPaneB()

        fixture.deliver()

        fixture.assertPainterActivity()
        assertEquals(listOf("natural SSP"), fixture.feeds)
    }

    @Test
    fun naturalSspReportsActivityBeforeAnOwnedHandoffDiscardsThePaint() {
        val fixture = Fixture()
        fixture.focusPaneB()
        fixture.handoff.begin(ownerA, naturalOutputFloor = 0, waitsForNaturalOutput = false)
        requireNotNull(fixture.handoff.start(81))
        assertFalse(fixture.handoff.awaitingCausalBoundary)

        fixture.deliver()

        fixture.assertPainterActivity()
        assertTrue("activity is evidence even when these bytes cannot paint", fixture.feeds.isEmpty())
    }

    @Test
    fun naturalSspFromADifferentWindowDoesNotReportPainterActivity() {
        val fixture = Fixture()
        fixture.focusPaneB()
        fixture.snapshot.value = fixture.snapshot.value.copy(activeWindowId = 2, revision = 3)

        fixture.deliver()

        assertTrue(fixture.facts.isEmpty())
    }

    @Test
    fun naturalSspWithAStalePainterTransportGenerationDoesNotReportActivity() {
        val fixture = Fixture()
        fixture.focusPaneB()
        fixture.controller.setField("tmuxTransportGeneration", 8L)

        fixture.deliver()

        assertTrue(fixture.facts.isEmpty())
    }

    @Test
    fun forcedFrameDoesNotReportPainterActivity() {
        val fixture = Fixture()
        fixture.focusPaneB()

        fixture.deliver(repaintRequestId = 81)

        assertTrue(fixture.facts.isEmpty())
        assertEquals("a paintable forced frame is still not natural activity", 1, fixture.feeds.size)
    }

    @Test
    fun naturalSspAtTheCausalFloorDoesNotReportPainterActivity() {
        val fixture = Fixture()
        fixture.focusPaneB()
        fixture.handoff.begin(ownerA, naturalOutputFloor = 1, waitsForNaturalOutput = true)

        fixture.deliver(deliveryId = 1)

        assertTrue(fixture.facts.isEmpty())
        assertTrue(fixture.handoff.awaitingCausalBoundary)
        assertTrue(fixture.feeds.isEmpty())
    }

    @Test
    fun naturalSspBeforeVisibleSelectionCommitDoesNotReportPainterActivity() {
        val fixture = Fixture()
        fixture.focusPaneB()
        fixture.controller.setField("visibleClientSelectionGeneration", 1L)

        fixture.deliver()

        assertTrue(fixture.facts.isEmpty())
    }

    @Test
    fun emptyNaturalFrameDoesNotReportPainterActivity() {
        val fixture = Fixture()
        fixture.focusPaneB()

        fixture.deliver(bytes = ByteArray(0))

        assertTrue(fixture.facts.isEmpty())
    }

    private class Fixture {
        val facts = mutableListOf<SharedTmuxRenderFact>()
        val feeds = mutableListOf<String>()
        val handoff = MoshPainterHandoff()
        val snapshot = MutableStateFlow(splitSnapshot(activePaneId = 11))
        // Constructor-less, as in the other controller fixtures: no transport,
        // Android Context, coroutine workers, or native runtime is started.
        val controller = (unsafe.allocateInstance(SshSessionController::class.java) as SshSessionController).apply {
            setField("host", SavedHost(
                id = "painter-activity", displayName = "Painter activity", hostname = "unused.invalid",
                port = 22, username = "tester", jumpHostId = null, identityId = null,
                transportKind = TransportKinds.MOSH, tmuxMode = TmuxModes.AUTOMATIC,
            ))
            setField("diagnosticTransport", "mosh+tmux")
            setField("diagnostics", testDiagnosticLogStore())
            setField("tmuxTransportLock", Any())
            setField("tmuxTransportGeneration", 7L)
            setField("moshUsingSshFallback", false)
            setField("mutableTmuxSnapshot", snapshot)
            setField("visibleClientSelectionGeneration", 0L)
            setField("visibleClientCommittedSelectionGeneration", 0L)
            setField("moshPainterHandoff", handoff)
            setField("moshRenderHistoryFence", MoshRenderHistoryDeliveryFence {
                error("no history delivery is staged by this fixture")
            })
            setField("tmuxRenderFactProbe", { fact: SharedTmuxRenderFact -> facts.add(fact) })
            setField("terminalSurface", Proxy.newProxyInstance(
                TerminalSurface::class.java.classLoader, arrayOf(TerminalSurface::class.java),
            ) { _, method, args ->
                when (method.name) {
                    "getBoundOwner" -> ownerA
                    "feed" -> {
                        assertEquals(2, args!!.size)
                        assertTrue(args[0] == null || args[0] == ownerA)
                        feeds += (args[1] as ByteArray).decodeToString()
                        true
                    }
                    else -> error("unexpected surface call: ${method.name}")
                }
            } as TerminalSurface)
        }

        fun focusPaneB() {
            // A history-less focus switch changes the snapshot, not the
            // ledger's retained live painter owner. Both panes stay in @1.
            snapshot.value = splitSnapshot(activePaneId = 12).copy(revision = 2)
            assertEquals(12, snapshot.value.activePaneId)
            assertEquals(ownerA, controller.javaClass.getDeclaredField("terminalSurface")
                .apply { isAccessible = true }.get(controller).let { (it as TerminalSurface).boundOwner })
        }

        fun deliver(
            bytes: ByteArray = "natural SSP".encodeToByteArray(),
            deliveryId: Long = 1,
            repaintRequestId: Long? = null,
        ) = runBlocking {
            // Invoke the real suspend consumer, including all outer gates and
            // submitTmuxRenderFact; do not duplicate its admission predicate.
            val method = controller.javaClass.getDeclaredMethod(
                "receive", SharedSessionEvent::class.java, Continuation::class.java,
            ).apply { isAccessible = true }
            val result = method.invoke(controller, SharedSessionEvent.TerminalBytes(
                generation = 7, bytes = bytes,
                receipt = SharedTerminalOutputReceipt(deliveryId, repaintRequestId),
            ), Continuation<Unit>(coroutineContext) { it.getOrThrow() })
            assertTrue("TerminalBytes should complete synchronously", result !== COROUTINE_SUSPENDED)
        }

        fun assertPainterActivity() {
            assertEquals(listOf(SharedTmuxRenderFact.TransportOutputObserved(
                surfaceId = TMUX_RENDER_LIVE_SURFACE_ID,
                owner = SharedTmuxRenderOwner(ownerA.windowId, ownerA.paneId, ownerA.epoch),
            )), facts)
        }
    }

    private companion object {
        val ownerA = RenderOwner(windowId = 1, paneId = 11, epoch = 1, transportGeneration = 7)
        val unsafe = sun.misc.Unsafe::class.java.getDeclaredField("theUnsafe")
            .apply { isAccessible = true }.get(null) as sun.misc.Unsafe

        fun Any.setField(name: String, value: Any?) {
            javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value)
        }

        fun splitSnapshot(activePaneId: Int) = SharedTmuxSnapshot(
            sessionId = 3, sessionName = "work", activeWindowId = 1,
            isActiveWindowAuthoritative = true,
            windows = listOf(
                SharedTmuxWindow(
                    id = 1, index = 0, name = "split", activePaneId = activePaneId,
                    panes = listOf(
                        SharedTmuxPane(11, "A", "sh", active = activePaneId == 11),
                        SharedTmuxPane(12, "B", "sh", active = activePaneId == 12),
                    ),
                    zoomed = false,
                    layout = SharedTmuxLayoutNode.Split(
                        horizontal = true, width = 81, height = 24,
                        children = listOf(
                            SharedTmuxLayoutNode.Leaf(11, 40, 24),
                            SharedTmuxLayoutNode.Leaf(12, 40, 24, x = 41),
                        ),
                    ),
                ),
                SharedTmuxWindow(2, 1, "other", 22,
                    listOf(SharedTmuxPane(22, "C", "sh", active = true)), false, null),
            ),
            authority = SharedTmuxGridAuthoritySnapshot.Unknown, revision = 1, rawJson = ByteArray(0),
        )
    }
}
