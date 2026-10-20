package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Method
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow

class TmuxVisibleClientSelectionTest {
    @Test
    fun visibleSwitchStaysInItsGroupedSession() {
        assertEquals("'view:@7'", TmuxVisibleClientSelection.qualifiedTarget("view", 7))
        assertEquals("'view:@7.%9'", TmuxVisibleClientSelection.qualifiedTarget("view", 7, 9))
        assertEquals("'view'\\''s:@7.%9'", TmuxVisibleClientSelection.qualifiedTarget("view's", 7, 9))
        assertNull(TmuxVisibleClientSelection.qualifiedTarget("view\nother", 7))
        assertNull(TmuxVisibleClientSelection.qualifiedTarget("view", -1))
        assertNull(TmuxVisibleClientSelection.qualifiedTarget("view", 7, -1))
    }

    @Test
    fun canonicalWindowTargetsAcceptOnlyAsciiNonnegativeIntIds() {
        assertEquals(0, TmuxVisibleClientSelection.windowId("@0"))
        assertEquals(Int.MAX_VALUE, TmuxVisibleClientSelection.windowId("@${Int.MAX_VALUE}"))

        listOf(
            "0",
            "@",
            "@-1",
            "@+1",
            "@01x",
            "@١",
            "@2147483648",
            "@1\nselect-window -t @2",
        ).forEach { target -> assertNull(target, TmuxVisibleClientSelection.windowId(target)) }
    }

    @Test
    fun canonicalPaneTargetsAcceptOnlyAsciiNonnegativeIntIds() {
        assertEquals(0, TmuxVisibleClientSelection.paneId("%0"))
        assertEquals(Int.MAX_VALUE, TmuxVisibleClientSelection.paneId("%${Int.MAX_VALUE}"))

        listOf(
            "0",
            "%",
            "%-1",
            "%+1",
            "%01x",
            "%١",
            "%2147483648",
            "%1\nselect-pane -t %2",
        ).forEach { target -> assertNull(target, TmuxVisibleClientSelection.paneId(target)) }
    }

    @Test
    fun stampedIdentityRequiresOneExactUnambiguousTuple() {
        val stamp = "/dev/pts/7|222|1700000002"
        assertEquals(
            stamp to TmuxVisibleClientIdentity("/dev/pts/7", 222, 1_700_000_002),
            TmuxVisibleClientSelection.singleStampedIdentity(listOf("", stamp, "")),
        )

        assertNull(TmuxVisibleClientSelection.singleStampedIdentity(emptyList()))
        assertNull(TmuxVisibleClientSelection.singleStampedIdentity(listOf(stamp, stamp)))
        assertNull(TmuxVisibleClientSelection.singleStampedIdentity(listOf(stamp, "unexpected")))
    }

    @Test
    fun stampedIdentityRejectsMalformedAndControlBearingFields() {
        listOf(
            "/dev/pts/7|222",
            "|222|1700000002",
            "/dev/pts/7|0|1700000002",
            "/dev/pts/7|-2|1700000002",
            "/dev/pts/7|٢|1700000002",
            "/dev/pts/7|222|0",
            "/dev/pts/7|222|later",
            "/dev/pts/7|222|1700000002|extra",
            "/dev/pts/\u00007|222|1700000002",
            "/dev/pts/7\nnext|222|1700000002",
        ).forEach { stamp -> assertNull(stamp, TmuxVisibleClientSelection.identity(stamp)) }
    }

    @Test
    fun attachmentProofRequiresTheOriginalTupleExactlyOnce() {
        val stamp = "/dev/pts/7|222|1700000002"
        assertTrue(
            TmuxVisibleClientSelection.isExactlyAttached(
                stamp,
                listOf("/dev/pts/8|333|1700000003", stamp),
            ),
        )
        assertFalse(
            TmuxVisibleClientSelection.isExactlyAttached(
                stamp,
                listOf("/dev/pts/7|999|1700000999"),
            ),
        )
        assertFalse(TmuxVisibleClientSelection.isExactlyAttached(stamp, listOf(stamp, stamp)))
    }

    @Test
    fun selectionFenceRejectsRapidReplacementReconnectRemovalAndYield() {
        fun current(
            expectedSelection: Long = 2,
            expectedTransport: Long = 8,
            currentSelection: Long = 2,
            currentTransport: Long = 8,
            session: String? = "work",
            windows: Set<Int> = setOf(7),
            activeWindow: Int? = 7,
            expectedPane: Int? = 71,
            activePane: Int? = 71,
            admitted: Boolean = true,
            requireActiveWindow: Boolean = true,
        ): Boolean = TmuxVisibleClientSelection.isCurrent(
            expectedWindowId = 7,
            expectedPaneId = expectedPane,
            expectedSession = "work",
            expectedSelectionGeneration = expectedSelection,
            expectedTransportGeneration = expectedTransport,
            currentWindowIds = windows,
            currentActiveWindowId = activeWindow,
            currentActivePaneId = activePane,
            currentSession = session,
            currentSelectionGeneration = currentSelection,
            currentTransportGeneration = currentTransport,
            mutationAdmitted = admitted,
            requireActiveWindow = requireActiveWindow,
        )

        assertTrue(current())
        assertFalse("a newer tap must retire the first proof", current(expectedSelection = 1))
        assertFalse("a replacement control channel must retire old replies", current(expectedTransport = 7))
        assertFalse("a session change must retire the proof", current(session = "other"))
        assertFalse("a removed window must retire the proof", current(windows = emptySet()))
        assertFalse("an externally active window must retire the old proof", current(activeWindow = 9))
        assertFalse("an externally active pane must retire the old proof", current(activePane = 72))
        assertTrue(
            "the primary reply may precede its causal active-target query",
            current(activeWindow = 9, activePane = 72, requireActiveWindow = false),
        )
        assertFalse("yielding authority must stop an in-flight switch", current(admitted = false))
    }

    @Test
    fun tmuxArgumentsAreSingleQuotedAndControlCharactersFailClosed() {
        assertEquals("'/dev/pts/7'", TmuxVisibleClientSelection.quotedArgument("/dev/pts/7"))
        assertEquals("'client'\\''s'", TmuxVisibleClientSelection.quotedArgument("client's"))
        assertNull(TmuxVisibleClientSelection.quotedArgument(""))
        assertNull(TmuxVisibleClientSelection.quotedArgument("client\u0000name"))
        assertNull(TmuxVisibleClientSelection.quotedArgument("client\nname"))
    }

    @Test
    fun inactiveCloseDoesNotSupersedeEarlierMoshVisibleClientSelection() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = bareMoshTmuxController(queue)

        // A is already the causally active tab by the time its primary reply
        // is folded. B is then closed before A reaches the stamped-client
        // stage. The close must remain an Ignore reply: it is not a new
        // visible-client selection and therefore cannot retire A's proof.
        assertTrue(invokeSelectWindow(controller, "@1"))
        val primary = queue.tryReceive().getOrThrow()
        val primaryPurpose = primary.purpose as? TmuxResponsePurpose.VisibleSelectionPrimary
        requireNotNull(primaryPurpose)
        // W2: the side channel's switch names its own session, never a bare
        // `@1` tmux could resolve to the grouped mosh view session.
        assertEquals("select-window -t '\$3:@1'", primary.command)
        assertEquals(1L, primaryPurpose.selectionGeneration)

        invokeClosePreflight(
            controller,
            TmuxResponsePurpose.VisibleSelectionClosePreflight(
                windowId = 2,
                session = "work",
                selectionGeneration = primaryPurpose.selectionGeneration,
                transportGeneration = primaryPurpose.transportGeneration,
            ),
            listOf("__tessera_active_window__\t@1"),
        )
        val inactiveKill = queue.tryReceive().getOrThrow()
        assertEquals("kill-window -t @2", inactiveKill.command)
        assertEquals(
            "closing inactive B must not create a newer visible-client intent",
            TmuxResponsePurpose.Ignore,
            inactiveKill.purpose,
        )
        assertEquals(
            "B's close must leave A's stamped selection generation live",
            1L,
            controller.privateLong("visibleClientSelectionGeneration"),
        )

        // This is the final reply in A's real FIFO chain (primary -> active
        // target -> visible-client option -> stamped attached client). Drive
        // the actual final handler with its exact stamped tuple and verify it
        // still emits the client-targeted painter move for A.
        invokeVisibleClients(
            controller,
            TmuxResponsePurpose.VisibleSelectionClients(
                windowId = 1,
                paneId = null,
                preservingWindowZoom = false,
                session = "work",
                selectionGeneration = primaryPurpose.selectionGeneration,
                transportGeneration = primaryPurpose.transportGeneration,
                stamp = "/dev/pts/7|222|1700000002",
                clientName = "/dev/pts/7",
            ),
            listOf("/dev/pts/7|222|1700000002"),
        )
        val switchClient = queue.tryReceive().getOrThrow()
        assertEquals("switch-client -c '/dev/pts/7' -t 'work:@1'", switchClient.command)
        assertEquals(
            TmuxResponsePurpose.VisibleSelectionCommit(
                windowId = 1,
                paneId = null,
                session = "work",
                selectionGeneration = primaryPurpose.selectionGeneration,
                transportGeneration = primaryPurpose.transportGeneration,
                clientName = "/dev/pts/7",
            ),
            switchClient.purpose,
        )
        assertTrue("the focused race must leave no extra control command", queue.tryReceive().isFailure)
    }

    /**
     * This test deliberately avoids starting a connection or loading the JNI
     * command inventory. The handlers under test only need the controller's
     * Mosh/tmux selection state, so allocate that state directly and exercise
     * the production methods through their private JVM ABI.
     */
    private fun bareMoshTmuxController(
        queue: Channel<TmuxControlCommand>,
    ): SshSessionController {
        val controller = unsafe.allocateInstance(SshSessionController::class.java) as SshSessionController
        controller.setPrivate(
            "host",
            SavedHost(
                id = "visible-client-race",
                displayName = "visible-client-race",
                hostname = "fixture.invalid",
                port = 22,
                username = "fixture",
                jumpHostId = null,
                identityId = null,
                transportKind = TransportKinds.MOSH,
                tmuxMode = TmuxModes.PINNED,
                tmuxTarget = "work",
            ),
        )
        controller.setPrivate("tmuxTransportLock", Any())
        controller.setPrivate("mutableTmuxSnapshot", MutableStateFlow<SharedTmuxSnapshot?>(null))
        controller.setPrivate("tmuxCommandChannel", queue)
        controller.setPrivate("activeTmuxResponses", ConcurrentHashMap<Long, TmuxResponsePurpose>())
        controller.setPrivate("tmuxTransportGeneration", 8L)
        controller.setPrivate("visibleClientSelectionGeneration", 0L)
        controller.setPrivate("closed", false)
        controller.setPrivate("moshUsingSshFallback", false)
        controller.setPrivate("tmuxWindowSelectionCommand", coreWindowSelectionCommand)
        controller.setPrivate(
            "mutableTmuxAuthority",
            MutableStateFlow<SharedTmuxGridAuthoritySnapshot>(SharedTmuxGridAuthoritySnapshot.Unknown),
        )
        // The §6.9 projection gates window selection while yielded or
        // reclaiming; this race fixture owns nothing and is not resuming.
        controller.setPrivate(
            "mutableTmuxAuthorityPresentation",
            MutableStateFlow<TmuxAuthorityPresentation>(TmuxAuthorityPresentation.None),
        )
        controller.setPrivate(
            "mutableTmuxSnapshot",
            MutableStateFlow(
                SharedTmuxSnapshot(
                    sessionId = 3,
                    sessionName = "work",
                    activeWindowId = 1,
                    windows = listOf(
                        SharedTmuxWindow(1, 0, "A", null, emptyList(), false, null),
                        SharedTmuxWindow(2, 1, "B", null, emptyList(), false, null),
                    ),
                    authority = SharedTmuxGridAuthoritySnapshot.Unknown,
                    revision = 1,
                    rawJson = ByteArray(0),
                ),
            ),
        )
        return controller
    }

    private fun invokeSelectWindow(controller: SshSessionController, target: String): Boolean =
        controller.privateMethod("selectTmuxWindow", String::class.java, kotlinx.coroutines.CompletableDeferred::class.java)
            .invoke(controller, target, null) as Boolean

    private fun invokeClosePreflight(
        controller: SshSessionController,
        purpose: TmuxResponsePurpose.VisibleSelectionClosePreflight,
        lines: List<String>,
    ) {
        controller.privateMethod(
            "handleVisibleSelectionClosePreflight",
            TmuxResponsePurpose.VisibleSelectionClosePreflight::class.java,
            Boolean::class.javaPrimitiveType!!,
            List::class.java,
        ).invoke(controller, purpose, true, lines)
    }

    private fun invokeVisibleClients(
        controller: SshSessionController,
        purpose: TmuxResponsePurpose.VisibleSelectionClients,
        lines: List<String>,
    ) {
        controller.privateMethod(
            "handleVisibleSelectionClients",
            TmuxResponsePurpose.VisibleSelectionClients::class.java,
            Boolean::class.javaPrimitiveType!!,
            List::class.java,
        ).invoke(controller, purpose, true, lines)
    }

    private fun SshSessionController.privateLong(name: String): Long =
        javaClass.getDeclaredField(name).apply { isAccessible = true }.getLong(this)

    private fun Any.setPrivate(name: String, value: Any?) {
        javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value)
    }

    private fun Any.privateMethod(name: String, vararg parameterTypes: Class<*>): Method =
        javaClass.getDeclaredMethod(name, *parameterTypes).apply { isAccessible = true }

    private companion object {
        val unsafe: sun.misc.Unsafe = sun.misc.Unsafe::class.java
            .getDeclaredField("theUnsafe")
            .apply { isAccessible = true }
            .get(null) as sun.misc.Unsafe
    }
}
