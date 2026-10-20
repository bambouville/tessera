package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxCompactReprojection
import com.bambouville.tessera.core.bridge.SharedTmuxCompactReprojectionMemo
import com.bambouville.tessera.core.bridge.SharedTmuxCompactReprojectionResult
import com.bambouville.tessera.core.bridge.SharedTmuxCompactSizer
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxGridPresentation
import com.bambouville.tessera.core.bridge.SharedTmuxGridSize
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.networking.mosh.AndroidMoshTransport
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import com.bambouville.tessera.core.bridge.*
import java.util.concurrent.ConcurrentHashMap

/**
 * How the session controller acts on each compact reprojection decision. The
 * decisions themselves are the shared core's (pinned by its Swift tests); a
 * scripted core stands in for it here because the JVM cannot load it.
 *
 * The observable is the device's own Mosh canvas, the first thing every
 * sizing route reconciles. The window-size policy is unknown, so nothing
 * reaches tmux and the canvas alone records which size each route chose;
 * that is also every ordinary Mosh publish before its ownership proof, which
 * leaves `lastPublishedTmuxSize` where it was.
 */
class TmuxCompactSizingControllerTest {
    private val fixtures = mutableListOf<Fixture>()
    @org.junit.After fun closeSessions() {
        fixtures.forEach {
            (it.controller.getPrivate("scope") as kotlinx.coroutines.CoroutineScope).coroutineContext[kotlinx.coroutines.Job]?.cancel()
            it.authority.close()
        }
    }

    @Test
    fun aReprojectionAdvertisesTheSolvedSize() {
        val fixture = Fixture(reproject(1L))
        fixture.reconcile()
        assertEquals(projected, fixture.canvas.value)
        assertEquals(listOf(lastAdvertised), fixture.core.lastSizes)
    }

    @Test
    fun aHoldStillRepairsTowardTheProjection() {
        val fixture = Fixture(result(SharedTmuxCompactReprojection.HOLD, 0L))
        fixture.reconcile()
        assertEquals(projected, fixture.canvas.value)
    }

    @Test
    fun aHeldCycleKeepsTheAdvertisedSizeInsteadOfRepairingTowardTheProjection() {
        val fixture = Fixture(stop(4L))
        fixture.reconcile()
        assertEquals(lastAdvertised, fixture.canvas.value)
        assertNull(fixture.wire.tryReceive().getOrNull())

        // The core reprojects before any advertisement, so this is only the
        // guard: with nothing to hold, it must not chase the projection.
        val fresh = Fixture(stop(4L), last = null)
        fresh.reconcile()
        assertEquals(initialCanvas, fresh.canvas.value)
    }

    /**
     * Every runtime event (`%output` included) reconciles, and a Mosh
     * publish waiting for its ownership proof changes none of the inputs.
     * The core judges the layout once: a second judgement, here scripted to
     * answer as a core that counted it again would, never happens, so the
     * canvas stays on the projection instead of flipping back to the old
     * size under a spurious held cycle.
     */
    @Test
    fun aLayoutIsJudgedOnceHoweverManyEventsCarryIt() {
        val fixture = Fixture(reproject(1L), stop(2L))
        repeat(5) {
            fixture.reconcile()
            assertEquals(projected, fixture.canvas.value)
        }
        assertEquals(listOf(memo(0L)), fixture.core.memosIn)
        assertEquals(memo(1L), fixture.sizer.memo)

        // A layout tmux really moved is a new judgement, from the memo the
        // last one left (here the core stops a cycle); it, too, is judged
        // once.
        fixture.snapshot.value = snapshot(rightPane = 46)
        repeat(3) { fixture.reconcile() }
        assertEquals(listOf(memo(0L), memo(1L)), fixture.core.memosIn)
        assertEquals(lastAdvertised, fixture.canvas.value)
    }

    /**
     * An advertisement withheld while an authority read is in flight (or in
     * the background, or behind the show rule) is judged once however many
     * events arrive meanwhile, and the authority reply's reconcile sends it
     * as judged, rather than a held cycle that keeps the pane off the grid.
     */
    @Test
    fun aWithheldAdvertisementGoesOutAsJudgedOnceReleased() {
        val fixture = Fixture(reproject(1L), stop(2L), transport = TransportKinds.SSH)
        fixture.hold()
        repeat(4) { fixture.reconcile() }
        assertEquals(projected to "shared session withholds geometry", fixture.controller.getPrivate("lastWithheldTmuxClientSize"))
        assertEquals(listOf(memo(0L)), fixture.core.memosIn)

        fixture.release()
        fixture.reconcile()
        assertNull("released and sent", fixture.controller.getPrivate("lastWithheldTmuxClientSize"))
        assertEquals(listOf(memo(0L)), fixture.core.memosIn)
    }

    @Test
    fun theMemoThreadsFromOneLayoutUpdateToTheNextUntilAReset() {
        val fixture = Fixture(reproject(1L), reproject(2L), stop(3L), reproject(1L))
        fixture.reconcile()
        // A later event over a moved layout: the core judges it with the memo
        // its previous answer returned.
        fixture.snapshot.value = snapshot(rightPane = 46)
        fixture.reconcile()
        fixture.snapshot.value = snapshot(rightPane = 47)
        fixture.reconcile()
        assertEquals(listOf(memo(0L), memo(1L), memo(2L)), fixture.core.memosIn)
        assertEquals(memo(3L), fixture.sizer.memo)
        assertEquals(lastAdvertised, fixture.canvas.value)

        // A forced replay starts over, even on the same layout.
        fixture.sizer.reset()
        fixture.reconcile()
        assertEquals(memo(0L), fixture.core.memosIn.last())
        assertEquals(projected, fixture.canvas.value)
    }

    private class ScriptedCore(
        results: List<SharedTmuxCompactReprojectionResult>,
    ) : SharedTmuxCompactSizer.Core {
        private val results = ArrayDeque(results)
        val memosIn = mutableListOf<SharedTmuxCompactReprojectionMemo>()
        val lastSizes = mutableListOf<SharedTmuxGridSize?>()

        override fun clientSize(
            viewport: SharedTmuxGridSize,
            layoutCells: ByteArray?,
            focusPaneId: Int?,
            window: SharedTmuxGridSize?,
            focus: SharedTmuxGridSize?,
        ) = projected

        override fun reprojection(
            viewport: SharedTmuxGridSize,
            lastClientSize: SharedTmuxGridSize?,
            layoutCells: ByteArray?,
            focusPaneId: Int?,
            window: SharedTmuxGridSize?,
            focus: SharedTmuxGridSize?,
            memo: SharedTmuxCompactReprojectionMemo,
        ): SharedTmuxCompactReprojectionResult {
            memosIn += memo
            lastSizes += lastClientSize
            return results.removeFirst()
        }
    }

    private inner class Fixture(
        vararg results: SharedTmuxCompactReprojectionResult,
        last: SharedTmuxGridSize? = lastAdvertised,
        transport: String = TransportKinds.MOSH,
    ) {
        init { fixtures += this }
        val core = ScriptedCore(results.toList())
        val sizer = SharedTmuxCompactSizer(core)
        val canvas = MutableStateFlow<SharedTmuxGridSize?>(initialCanvas)
        val snapshot = MutableStateFlow<SharedTmuxSnapshot?>(snapshot(rightPane = 45))
        val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val authority = TmuxAuthorityReducer()
        init {
            authority.session.adoptShown(0)
            authority.session.localSize(0, lastAdvertised)
            authority.session.windowFacts(0, true, SharedTmuxAuthorityActiveWindow(5, lastAdvertised, true))
            val q = authority.session.attached(0, "android-id").effects.filterIsInstance<SharedTmuxAuthoritySessionEffect.QueryAuthority>().single()
            authority.session.queryReplied(0, q.queryId, "v1 android-id 21 Pixel", "android-id")
        }
        val controller = (unsafe.allocateInstance(SshSessionController::class.java) as SshSessionController).apply {
            setPrivate("tmuxTransportLock", Any())
            setPrivate("tmuxAuthorityLifecycle", authority)
            setPrivate("lastTmuxAuthorityResult", authority.session.state)
            setPrivate("authorityTime", { 0L })
            setPrivate("lastAuthorityWindowFacts", true to SharedTmuxAuthorityActiveWindow(5, lastAdvertised, true))
            setPrivate("lastAuthorityLocalSize", lastAdvertised)
            setPrivate("authorityLocalSizeSubmitted", true)
            setPrivate("mutableTmuxAuthorityPresentation", MutableStateFlow<TmuxAuthorityPresentation>(TmuxAuthorityPresentation.None))
            setPrivate("scope", kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Unconfined))
            setPrivate("restoreSelectionApplied", true)
            setPrivate("inlineAuthorityRepaintFence", InlineAuthorityRepaintFence())
            setPrivate("mutableTmuxWindowMutationState", MutableStateFlow<TmuxWindowMutationState>(TmuxWindowMutationState.Unavailable))
            setPrivate("host", SavedHost("fixture", "fixture", "fixture.invalid", 22, "fixture", null, null,
                transportKind = transport, tmuxMode = TmuxModes.AUTOMATIC))
            setPrivate("diagnostics", testDiagnosticLogStore())
            setPrivate("diagnosticTransport", if (transport == TransportKinds.MOSH) "mosh_tmux" else "ssh_tmux")
            setPrivate("tmuxGridPresentation", SharedTmuxGridPresentation.SINGLE_PANE)
            setPrivate("compactSizeRole", compactSizeRole("Owner"))
            setPrivate("compactTmuxSizer", sizer)
            setPrivate("mutableTmuxSnapshot", snapshot)
            setPrivate("mutableTmuxAuthority", MutableStateFlow<SharedTmuxGridAuthoritySnapshot>(SharedTmuxGridAuthoritySnapshot.Mine(21)))
            setPrivate("mutableTmuxReclaimInFlight", MutableStateFlow(false))
            setPrivate("pendingTmuxWindowSizeReplays", ConcurrentHashMap<Int, PendingTmuxWindowSizeReplay>())
            setPrivate("tmuxTransportGeneration", 8L)
            setPrivate("tmuxCommandChannel", wire)
            setPrivate("lastTmuxViewport", viewport)
            setPrivate("lastPublishedTmuxSize", last)
            setPrivate("moshTransport", unsafe.allocateInstance(AndroidMoshTransport::class.java))
            setPrivate("mutableMoshCanvasSize", canvas)
            setPrivate("moshResizeRequests", Channel<Any>(Channel.CONFLATED))
            setPrivate("appForeground", true)
            setPrivate("presentationActive", true)
            setPrivate("closed", false)
        }

        fun hold() { controller.setPrivate("lastTmuxAuthorityResult", authority.session.attached(0, "android-id").state) }
        fun release() {
            authority.session.queryFailed(0, 2)
            val q = authority.session.foregrounded(0).effects.filterIsInstance<SharedTmuxAuthoritySessionEffect.QueryAuthority>().single()
            controller.setPrivate("lastTmuxAuthorityResult", authority.session.queryReplied(0, q.queryId, "v1 android-id 21 Pixel", "android-id").state)
        }
        fun reconcile() {
            controller.javaClass.getDeclaredMethod(
                "reconcileTmuxClientSize",
                SharedTmuxSnapshot::class.java,
                Boolean::class.javaPrimitiveType!!,
            ).apply { isAccessible = true }.invoke(controller, snapshot.value, false)
        }
    }

    private companion object {
        val viewport = SharedTmuxGridSize(50, 40)
        val projected = SharedTmuxGridSize(210, 40)
        val lastAdvertised = SharedTmuxGridSize(200, 40)
        val initialCanvas = SharedTmuxGridSize(1, 1)
        val unsafe: sun.misc.Unsafe = sun.misc.Unsafe::class.java
            .getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null) as sun.misc.Unsafe

        /** A 200x40 window split left|right with the right pane (%1) focused. */
        fun snapshot(rightPane: Int) = SharedTmuxSnapshot(
            sessionName = "fixture",
            activeWindowId = 5,
            windows = listOf(
                SharedTmuxWindow(5, 0, "fixture", 1, emptyList(), false,
                    SharedTmuxLayoutNode.Split(
                        horizontal = true,
                        width = 200, height = 40,
                        children = listOf(
                            SharedTmuxLayoutNode.Leaf(paneId = 0, width = 199 - rightPane, height = 40),
                            SharedTmuxLayoutNode.Leaf(paneId = 1, width = rightPane, height = 40, x = 200 - rightPane),
                        ),
                    )),
            ),
            authority = SharedTmuxGridAuthoritySnapshot.Mine(21),
            revision = 1,
            isWindowListHydrated = true,
            isActiveWindowAuthoritative = true,
            rawJson = byteArrayOf(),
        )

        fun compactSizeRole(name: String): Any {
            val type = Class.forName("com.bambouville.tessera.feature.session.SshSessionController\$CompactSizeRole")
            return type.enumConstants.single { (it as Enum<*>).name == name }
        }

        fun memo(word: Long) = SharedTmuxCompactReprojectionMemo(word, 0L)

        fun result(decision: SharedTmuxCompactReprojection, word: Long, stopped: Boolean = false) =
            SharedTmuxCompactReprojectionResult(decision, memo(word), stoppedCycle = stopped)

        fun reproject(word: Long) = result(SharedTmuxCompactReprojection.REPROJECT, word)

        fun stop(word: Long) = result(SharedTmuxCompactReprojection.HOLD_CYCLE, word, stopped = true)

        fun Any.setPrivate(name: String, value: Any?) {
            javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value)
        }

        fun Any.getPrivate(name: String): Any? =
            javaClass.getDeclaredField(name).apply { isAccessible = true }.get(this)
    }
}
