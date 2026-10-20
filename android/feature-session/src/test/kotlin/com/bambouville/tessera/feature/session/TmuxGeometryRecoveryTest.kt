package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.AgentTmuxControlAck
import com.bambouville.tessera.core.bridge.SharedTmuxGridPresentation
import com.bambouville.tessera.core.bridge.SharedTmuxGridSize
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxPlatformWireCommand
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.networking.SshTmuxConnection
import com.bambouville.tessera.networking.mosh.AndroidMoshTransport
import com.bambouville.tessera.terminal.TerminalMouseMode
import com.bambouville.tessera.terminal.TerminalSurfaceState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.ConcurrentHashMap

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class TmuxGeometryRecoveryTest {
    private val dispatcher = StandardTestDispatcher()
    @org.junit.Before fun useMainDispatcher() { Dispatchers.setMain(dispatcher) }
    private val controllers = mutableListOf<SshSessionController>()
    @org.junit.After fun closeSessions() {
        controllers.forEach { controller ->
            (controller.privateValue("scope") as kotlinx.coroutines.CoroutineScope).coroutineContext[kotlinx.coroutines.Job]?.cancel()
            controller.native.close()
        }
        Dispatchers.resetMain()
    }

    @Test
    fun aFittingFullWindowRestoresTheLocalMoshCanvasAfterAWithheldSplitProjection() {
        assertFittingWindowRestoresLocalMoshCanvas(SharedTmuxGridSize(200, 30))
    }

    @Test
    fun aFittingFullWindowRestoresTheLocalMoshCanvasAfterAWithheldStackedProjection() {
        assertFittingWindowRestoresLocalMoshCanvas(SharedTmuxGridSize(100, 60))
    }

    @Test
    fun reconnectDoesNotProjectAnAlreadyReportedPhysicalViewportAgain() {
        val controller = bareController()
        controller.setPrivate("lastTmuxViewport", SharedTmuxGridSize(56, 30))

        controller.attachGeometry(grid(112, 60))
        controller.attachGeometry(grid(168, 90))

        assertEquals(SharedTmuxGridSize(56, 30), controller.privateValue("lastTmuxViewport"))
    }

    @Test
    fun firstAttachUsesTheMeasuredNativeGridUntilTheOuterViewportReports() {
        val controller = bareController()
        controller.attachGeometry(grid(56, 48))

        assertEquals(SharedTmuxGridSize(56, 48), controller.privateValue("lastTmuxViewport"))
    }

    @Test
    fun absentOrUnusableNativeGeometryDoesNotInventAnInitialViewport() {
        val controller = bareController()
        controller.attachGeometry(null)
        controller.attachGeometry(grid(3, 48))

        assertNull(controller.privateValue("lastTmuxViewport"))
    }

    @Test
    fun allThreeMutationAcknowledgementsDispatchExactlyOneSeparateConfirmation() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = bareController(queue)
        val pending = attempt()
        controller.attempts()[5] = pending

        controller.mutation(mutation(0), true)
        assertNull("resize acknowledgement alone cannot query the temporary grid", queue.tryReceive().getOrNull())
        controller.mutation(mutation(1), true)
        assertNull("latest fence cannot query before policy restore", queue.tryReceive().getOrNull())
        controller.mutation(mutation(2), true)

        val confirmation = queue.tryReceive().getOrThrow()
        assertEquals(pending.confirmationCommand, confirmation.command)
        assertEquals(TmuxResponsePurpose.WindowSizeReplayConfirmation(5, 17, 8, size), confirmation.purpose)
        assertTrue(controller.attempts().getValue(5).confirmationQueued)
        assertEquals(size, controller.attempts().getValue(5).requested)

        controller.mutation(mutation(1), true)
        assertNull("a repeated callback cannot dispatch another confirmation", queue.tryReceive().getOrNull())
    }

    @Test
    fun aFailedResizeCannotBeConfirmedEvenWhenRestoringPolicySucceeds() {
        val pending = attempt().noteMutation(0, false).noteMutation(1, true).noteMutation(2, true)

        assertFalse(pending.readyToConfirm)
        assertEquals(false, pending.resizeSucceeded)
        assertEquals(true, pending.policyRestoreSucceeded)
    }

    @Test
    fun aFailedPolicyRestoreCannotBeConfirmedEvenWhenResizingSucceeds() {
        val pending = attempt().noteMutation(0, true).noteMutation(1, true).noteMutation(2, false)

        assertFalse(pending.readyToConfirm)
        assertEquals(true, pending.resizeSucceeded)
        assertEquals(false, pending.policyRestoreSucceeded)
    }

    @Test
    fun aFailedLatestFenceNeverQueuesConfirmationEvenIfOtherMutationsSucceed() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = bareController(queue)
        controller.attempts()[5] = attempt()
        controller.mutation(mutation(0), true)
        controller.mutation(mutation(1), false)
        controller.mutation(mutation(2), true)
        val pending = controller.attempts().getValue(5)
        assertFalse(pending.readyToConfirm)
        assertEquals(false, pending.fenceSucceeded)
        assertTrue(pending.failureDiagnosed)
        assertNull(queue.tryReceive().getOrNull())
    }

    @Test
    fun pendingReplayRequiresEveryMutationRegardlessOfReplyOrder() {
        for (order in listOf(listOf(0, 1, 2), listOf(2, 0, 1), listOf(1, 2, 0))) {
            var pending = attempt()
            order.forEachIndexed { index, mutation ->
                pending = pending.noteMutation(mutation, true)
                assertEquals(index == 2, pending.readyToConfirm)
            }
            assertFalse(pending.copy(confirmationQueued = true).readyToConfirm)
        }
    }

    @Test
    fun aSupersededAttemptCannotAcknowledgeTheCurrentForce() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = bareController(queue)
        val current = attempt().copy(token = 18)
        controller.attempts()[5] = current

        controller.mutation(mutation(0), true)

        assertEquals(current, controller.attempts()[5])
        assertNull(queue.tryReceive().getOrNull())
    }

    @Test
    fun anOldTransportCannotAcknowledgeOrConfirmTheCurrentForce() {
        val controller = bareController()
        val current = attempt()
        controller.attempts()[5] = current
        controller.setPrivate("tmuxTransportGeneration", 9L)

        controller.mutation(mutation(0), true)
        controller.confirmation(TmuxResponsePurpose.WindowSizeReplayConfirmation(5, 17, 8, size))

        assertEquals(current, controller.attempts()[5])
    }

    @Test
    fun anOldDesiredGridCannotRetireItsReplacementAttempt() {
        val controller = bareController()
        val current = attempt().copy(requested = SharedTmuxGridSize(56, 46))
        controller.attempts()[5] = current

        controller.mutation(mutation(0), true)
        controller.confirmation(TmuxResponsePurpose.WindowSizeReplayConfirmation(5, 17, 8, size))

        assertEquals(current, controller.attempts()[5])
    }

    /**
     * D4: off screen gates repaint and geometry pushes, never authority. The
     * reply reaches the reducer, which (with no show or tap intent) can only
     * project; the adapter starts no claim of its own and no recovery flag
     * waits for the next foreground.
     */
    @Test
    fun aReconnectAuthorityReplyWhileHiddenIsReducedWithoutStartingAClaim() {
        val reducer = claimingReducer()
        val controller = bareController(reducer = reducer)
        controller.setPrivate("presentationActive", false)
        controller.reduce { it.hidden(0) }

        controller.deliverReconnectAuthorityReply()

        // The reducer would have claimed on a show or a take-back: it was asked for neither.
        assertEquals(authority, reducer.session.state.authority)
        assertNull(reducer.session.state.claim)
        assertEquals(authority, controller.privateValue("lastTmuxAuthorityResult").let { it as SharedTmuxAuthoritySessionState }.authority)
        assertNull(controller.privateValue("pendingAuthorityQuery"))
        assertNull(controller.native.state.claim)
        assertNull(controller.privateValue("pendingAuthorityRepaintGeneration"))
        assertNull(controller.privateValue("foregroundAuthorityClaimGeneration"))
    }

    @Test
    fun aReconnectAuthorityReplyWhileBackgroundIsReducedWithoutStartingAClaim() {
        val reducer = claimingReducer()
        val controller = bareController(reducer = reducer)
        controller.setPrivate("appForeground", false)

        controller.deliverReconnectAuthorityReply()

        assertEquals(authority, reducer.session.state.authority)
        assertNull(reducer.session.state.claim)
        assertNull(controller.privateValue("pendingAuthorityQuery"))
        assertNull(controller.native.state.claim)
        assertNull(controller.privateValue("pendingAuthorityRepaintGeneration"))
        // Still backgrounded: ordinary geometry stays withheld for that reason alone.
        assertTrue(controller.javaClass.getDeclaredMethod("ordinaryTmuxGeometryWithheld")
            .apply { isAccessible = true }.invoke(controller) as Boolean)
    }

    @Test
    fun anActualClaimSettlementReleasesFailedQueryAdmissionAndGeometryAttempts() {
        val controller = bareController()
        controller.reduce { it.attached(0, "android-fixture") }
        controller.attempts()[5] = attempt()
        controller.setPrivate("mutableTmuxReclaimInFlight", MutableStateFlow(true))
        val native = controller.native
        native.resetTransport(0, false)
        native.adoptShown(0)
        native.localSize(0, size)
        native.windowFacts(0, true, SharedTmuxAuthorityActiveWindow(5, size, true))
        val query = native.attached(0, "android-fixture").effects.filterIsInstance<SharedTmuxAuthoritySessionEffect.QueryAuthority>().single()
        native.queryReplied(0, query.queryId, "v1 peer-id 3 Peer", "android-fixture")
        val generation = native.requestTakeBack(0).state.claim!!.generation
        native.claimAdvertisedGeometry(0, generation, size.columns, size.rows)
        native.confirmFence(0, generation, size); native.repaintSucceeded(0, generation)
        native.stampCommitSucceeded(0, generation)
        val result = native.settle(0, generation)
        controller.setPrivate("pendingAuthorityRepaintGeneration", generation)

        controller.javaClass.getDeclaredMethod("applyTmuxAuthorityLifecycle", result.javaClass)
            .apply { isAccessible = true }.invoke(controller, result)

        assertNull(controller.native.state.claim)
        assertTrue(controller.attempts().isEmpty())
        assertFalse(controller.javaClass.getDeclaredMethod("ordinaryTmuxGeometryWithheld")
            .apply { isAccessible = true }.invoke(controller) as Boolean)
    }

    @Test
    fun ordinaryWindowRecoveryDoesNotConsumeAttemptsWhileHidden() {
        val controller = bareController()
        controller.setPrivate("presentationActive", false)
        controller.setPrivate("windowSizePolicyKnown", true)
        controller.setPrivate("windowSizePolicyWindowId", 5)
        val pending = attempt()
        controller.attempts()[5] = pending

        controller.javaClass.getDeclaredMethod("forceTmuxWindowSizes", size.javaClass, Boolean::class.javaPrimitiveType!!,
            Int::class.javaObjectType, Long::class.javaObjectType)
            .apply { isAccessible = true }.invoke(controller, size, false, 5, null)

        assertEquals("off-screen recovery returns before touching window attempts", pending, controller.attempts()[5])
    }

    @Test
    fun unresolvedAuthorityDoesNotConsumeTheStamplessLayoutEdge() {
        val controller = bareController()
        controller.reduce { it.attached(0, "android-fixture") }

        controller.stamplessLayout(driftedSnapshot())

        assertEquals(authority, controller.native.state.authority)
        assertTrue(controller.native.state.geometryHold == SharedTmuxAuthorityGeometryHold.WITHHELD)
    }

    @Test
    fun hiddenPresentationDoesNotConsumeTheStamplessLayoutEdge() {
        val controller = bareController()
        controller.setPrivate("presentationActive", false)

        controller.stamplessLayout(driftedSnapshot())

        assertEquals(authority, controller.native.state.authority)
        assertTrue(controller.native.state.geometryHold == SharedTmuxAuthorityGeometryHold.WITHHELD)
    }

    @Test
    fun aFreshForeignStampDefersOrdinaryRepairWithoutClaimingOrResizing() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = ordinaryRecoveryController(queue)

        controller.reply(TmuxResponsePurpose.OrdinaryWindowAuthority(31), listOf("foreign-stamp"))

        assertTrue((controller.privateValue("ordinaryTmuxWindowRecovery") as PendingTmuxOrdinaryWindowRecovery).completed)
        assertEquals(authority, (controller.privateValue("mutableTmuxAuthority") as MutableStateFlow<*>).value)
        assertNull(queue.tryReceive().getOrNull())
        assertTrue(controller.attempts().isEmpty())
    }

    @Test
    fun anEmptyFreshStampCannotAuthorizeOrdinaryRepair() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = ordinaryRecoveryController(queue)

        controller.reply(TmuxResponsePurpose.OrdinaryWindowAuthority(31), emptyList())

        assertTrue((controller.privateValue("ordinaryTmuxWindowRecovery") as PendingTmuxOrdinaryWindowRecovery).completed)
        assertNull(queue.tryReceive().getOrNull())
    }

    @Test
    fun clientProofFromAnOldTransportCannotReachTheSharedAdmissionOrForce() {
        val controller = ordinaryRecoveryController()
        controller.setPrivate("tmuxTransportGeneration", 9L)

        controller.reply(clientProofPurpose(), ownInventory)

        assertTrue(controller.attempts().isEmpty())
        assertTrue((controller.privateValue("ordinaryTmuxWindowRecovery") as PendingTmuxOrdinaryWindowRecovery).completed)
    }

    @Test
    fun clientProofForThePreviousPhysicalWindowCannotForceTheCurrentWindow() {
        val controller = ordinaryRecoveryController()
        controller.setPrivate("mutableTmuxSnapshot", MutableStateFlow(driftedSnapshot().copy(activeWindowId = 6)))

        controller.reply(clientProofPurpose(), ownInventory)

        assertTrue(controller.attempts().isEmpty())
    }

    @Test
    fun clientProofCannotReplayAChangedDesiredViewport() {
        val controller = ordinaryRecoveryController()
        controller.setPrivate("lastPublishedTmuxSize", SharedTmuxGridSize(56, 47))

        controller.reply(clientProofPurpose(), ownInventory)

        assertTrue(controller.attempts().isEmpty())
    }

    @Test
    fun clientProofRequiresTheSameOwnAuthorityGeneration() {
        val controller = ordinaryRecoveryController()
        controller.setPrivate("mutableTmuxAuthority", MutableStateFlow<SharedTmuxGridAuthoritySnapshot>(SharedTmuxGridAuthoritySnapshot.Mine(22)))

        controller.reply(clientProofPurpose(), ownInventory)

        assertTrue(controller.attempts().isEmpty())
    }

    @Test
    fun clientProofCannotForceWhileThePresentationIsHidden() {
        val controller = ordinaryRecoveryController()
        controller.setPrivate("presentationActive", false)

        controller.reply(clientProofPurpose(), ownInventory)

        assertTrue(controller.attempts().isEmpty())
    }

    @Test
    fun clientProofCannotOutliveAnEffectivePolicyChange() {
        val controller = ordinaryRecoveryController()
        controller.setPrivate("windowSizePolicyIsLatest", false)

        controller.reply(clientProofPurpose(), ownInventory)

        assertTrue(controller.attempts().isEmpty())
    }

    @Test
    fun aPostFrameQueryFromAnOldTransportCannotCommitTheAuthorityStamp() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = bareController(queue)
        val purpose = TmuxResponsePurpose.AuthorityPaintGeometry(21, 7, 5, size)
        controller.setPrivate("pendingAuthorityPaintGeometry", purpose)

        controller.reply(purpose, listOf("tessera-window-size\t@5\t56\t48"))

        assertEquals(purpose, controller.privateValue("pendingAuthorityPaintGeometry"))
        assertNull(queue.tryReceive().getOrNull())
    }

    @Test
    fun aMetadataProjectionChangeCannotPublishOrForceBeforeExclusiveProof() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = ordinaryRecoveryController(queue)
        val projected = SharedTmuxGridSize(112, 48)
        val recovery = controller.privateValue("ordinaryTmuxWindowRecovery") as PendingTmuxOrdinaryWindowRecovery
        controller.setPrivate("ordinaryTmuxWindowRecovery", recovery.copy(requested = projected))
        val backgroundAttempt = attempt()
        controller.attempts()[6] = backgroundAttempt

        controller.publishGeometry(projected)

        assertEquals(size, controller.privateValue("lastPublishedTmuxSize"))
        assertEquals(backgroundAttempt, controller.attempts()[6])
        assertNull("no ClientSize replay or resize may precede the exclusive proof", queue.tryReceive().getOrNull())
    }

    @Test
    fun aFittingUnchangedProjectionDoesNotRequestAnotherProof() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = ordinaryRecoveryController(queue)
        val snapshot = driftedSnapshot()
        controller.setPrivate("mutableTmuxSnapshot", MutableStateFlow(snapshot.copy(windows = listOf(
            snapshot.windows.single().copy(layout = SharedTmuxLayoutNode.Leaf(7, 56, 48)),
        ))))
        controller.setPrivate("ordinaryTmuxWindowRecovery", null)

        controller.publishGeometry(size)

        assertNull(controller.privateValue("ordinaryTmuxWindowRecovery"))
        assertNull(queue.tryReceive().getOrNull())
    }

    @Test
    fun anEqualRootPaneReplacementStartsAFreshProofInsteadOfCoalescingForever() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = ordinaryRecoveryController(queue)
        val previous = controller.privateValue("ordinaryTmuxWindowRecovery") as PendingTmuxOrdinaryWindowRecovery
        controller.setPrivate("ordinaryTmuxWindowRecoveryToken", previous.token)
        val snapshot = driftedSnapshot()
        val replacement = snapshot.copy(windows = listOf(snapshot.windows.single().copy(
            activePaneId = 8, layout = SharedTmuxLayoutNode.Leaf(8, 56, 46),
        )))
        controller.setPrivate("mutableTmuxSnapshot", MutableStateFlow(replacement))

        controller.javaClass.getDeclaredMethod("requestOrdinaryTmuxWindowRecovery", Int::class.javaPrimitiveType!!,
            size.javaClass, size.javaClass).apply { isAccessible = true }
            .invoke(controller, 5, size, SharedTmuxGridSize(56, 46))

        val refreshed = controller.privateValue("ordinaryTmuxWindowRecovery") as PendingTmuxOrdinaryWindowRecovery
        assertEquals(32L, refreshed.token)
        assertEquals(previous.requested, refreshed.requested)
        assertEquals(previous.observed, refreshed.observed)
        assertEquals(8, refreshed.activePaneId)
        assertEquals(replacement.activeWindow?.layout, refreshed.layout)
        assertFalse(refreshed.completed)
        assertEquals(TmuxResponsePurpose.OrdinaryWindowAuthority(32), queue.tryReceive().getOrThrow().purpose)
        controller.reply(TmuxResponsePurpose.OrdinaryWindowClients(31, "control|123|456", "visible|124|456"), ownInventory)
        assertEquals(refreshed, controller.privateValue("ordinaryTmuxWindowRecovery"))
    }

    @Test
    fun anInlinePolicyReplyStillHydratesWhileItsAuthorityClaimIsPending() {
        val controller = bareController()
        controller.setPrivate("host", SavedHost("fixture", "fixture", "fixture.invalid", 22, "fixture", null, null,
            transportKind = TransportKinds.SSH, tmuxMode = TmuxModes.AUTOMATIC))
        controller.setPrivate("pendingAuthorityRepaintGeneration", 21L)
        controller.setPrivate("windowSizePolicyWindowId", 5)

        // The mounted viewport and native reducer are absent; ordinary policy
        // hydration must complete without trying to advance or restart g21.
        controller.reply(TmuxResponsePurpose.WindowSizePolicy(5), listOf("latest"))

        assertTrue(controller.privateValue("windowSizePolicyKnown") as Boolean)
        assertTrue(controller.privateValue("windowSizePolicyIsLatest") as Boolean)
        assertEquals(21L, controller.privateValue("pendingAuthorityRepaintGeneration"))
    }

    @Test
    fun aCoreWireCallbackQueuesTheExactTagBeforeItsReplyPurposeExists() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = bareController(queue)
        val connection = unsafe.allocateInstance(SshTmuxConnection::class.java) as SshTmuxConnection
        controller.setPrivate("tmuxConnection", connection)
        val commands = listOf(
            SharedTmuxPlatformWireCommand(12, "show-options -wA -v -t @5 window-size"),
            SharedTmuxPlatformWireCommand(13, "display-message -p ''"),
        )

        assertTrue(controller.enqueueCoreWire(commands, connection, 8))

        commands.forEach { expected ->
            val actual = queue.tryReceive().getOrThrow()
            assertEquals(expected.command, actual.command)
            assertEquals(expected.tag, actual.fifoTag)
            assertNull("reply purpose registration follows the callback", actual.purpose)
            assertFalse(actual.ledgerOwned)
        }
        assertNull(queue.tryReceive().getOrNull())
    }

    @Test
    fun anOldCoreWireCallbackCannotWriteToTheReplacementTransport() {
        val queue = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = bareController(queue)
        val oldConnection = unsafe.allocateInstance(SshTmuxConnection::class.java) as SshTmuxConnection
        val replacement = unsafe.allocateInstance(SshTmuxConnection::class.java) as SshTmuxConnection
        controller.setPrivate("tmuxConnection", replacement)
        val commands = listOf(SharedTmuxPlatformWireCommand(12, "display-message -p ''"))

        assertFalse(controller.enqueueCoreWire(commands, oldConnection, 8))
        assertFalse(controller.enqueueCoreWire(commands, replacement, 7))

        assertNull(queue.tryReceive().getOrNull())
    }

    @Test
    fun aDroppedTaggedWriteFailsItsCapturedAgentReplyWithoutTouchingTheReplacement() = runBlocking {
        val controller = bareController()
        val oldReply = CompletableDeferred<AgentTmuxControlAck>()
        val replacementReply = CompletableDeferred<AgentTmuxControlAck>()
        val capturedResponses = ConcurrentHashMap<Long, TmuxResponsePurpose>().apply {
            put(12, TmuxResponsePurpose.AgentCommand(oldReply))
        }
        val replacementResponses = ConcurrentHashMap<Long, TmuxResponsePurpose>().apply {
            put(12, TmuxResponsePurpose.AgentCommand(replacementReply))
        }
        controller.setPrivate("activeTmuxResponses", replacementResponses)

        // Ordered callbacks carry only the FIFO tag. A stale writer must use
        // its captured map even if the replacement has already reused tag 12.
        controller.failPlatformWrite(TmuxControlCommand("display-message -p ''", fifoTag = 12), capturedResponses)

        assertTrue(oldReply.isCompleted)
        assertEquals(AgentTmuxControlAck(false, emptyList()), oldReply.await())
        assertTrue(capturedResponses.isEmpty())
        assertFalse(replacementReply.isCompleted)
        assertEquals(TmuxResponsePurpose.AgentCommand(replacementReply), replacementResponses[12])
    }

    @Test
    fun aWriteFailureStillFailsTheHydratedAgentPurposeAfterItsTagHasBeenRemoved() = runBlocking {
        val controller = bareController()
        val reply = CompletableDeferred<AgentTmuxControlAck>()
        val purpose = TmuxResponsePurpose.AgentCommand(reply)
        val capturedResponses = ConcurrentHashMap<Long, TmuxResponsePurpose>()

        controller.failPlatformWrite(TmuxControlCommand("display-message -p ''", purpose, fifoTag = 12), capturedResponses)

        assertTrue(reply.isCompleted)
        assertEquals(AgentTmuxControlAck(false, emptyList()), reply.await())
        assertTrue(capturedResponses.isEmpty())
    }

    @Test
    fun backgroundNewWindowWithForeignClientDoesNotForceOrChangeLocalCanvas() {
        val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = presentedWindowController(wire)
        val canvas = MutableStateFlow<SharedTmuxGridSize?>(size)
        controller.setPrivate("moshTransport", unsafe.allocateInstance(AndroidMoshTransport::class.java))
        controller.setPrivate("mutableMoshCanvasSize", canvas)
        val resizeRequests = Channel<Any>(Channel.UNLIMITED)
        controller.setPrivate("moshResizeRequests", resizeRequests)
        // The laptop's physical window is in topology, but this device still presents @5.
        controller.presentedSnapshot(newWindowSnapshot(presented = false), wire)
        assertEquals(size, canvas.value)
        // Ordinary reconciliation may reassert this device's canvas, never the outside window's grid.
        while (true) {
            val resize = resizeRequests.tryReceive().getOrNull() ?: break
            assertEquals(size, resize.privateValue("size"))
        }
        assertNull(wire.tryReceive().getOrNull())
        assertTrue(controller.attempts().isEmpty())
    }

    @Test
    fun presentingKnownNewWindowUsesFreshAuthorityAndOwnClientsBeforeForce() {
        val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = presentedWindowController(wire)
        controller.presentedSnapshot(newWindowSnapshot(presented = true), wire)
        assertTrue(controller.attempts().isEmpty())
        controller.provePresentedWindow(wire)
        val commands = (0..2).map { wire.tryReceive().getOrThrow() }
        assertEquals(listOf("resize-window -x 56 -y 48 -t @6", "select-window", "set-option -w -u -t @6 window-size"),
            commands.map { it.command })
        assertNull("confirmation waits for all mutation replies", wire.tryReceive().getOrNull())
        commands.forEach { controller.reply(requireNotNull(it.purpose), emptyList()) }
        val confirmation = wire.tryReceive().getOrThrow()
        assertTrue(confirmation.purpose is TmuxResponsePurpose.WindowSizeReplayConfirmation)
        controller.reply(requireNotNull(confirmation.purpose), listOf("tessera-window-size\t@6\t56\t48"))
        assertTrue("matching confirmation retires the force", controller.attempts().isEmpty())
        controller.assertOwnedWithoutVeil()
        assertNull(wire.tryReceive().getOrNull())
    }

    @Test
    fun foreignClientOnPresentedNewWindowBlocksRepair() {
        val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = presentedWindowController(wire)
        controller.presentedSnapshot(newWindowSnapshot(presented = true), wire)
        controller.provePresentedWindow(wire, foreign = true)
        assertTrue(controller.native.state.authority is SharedTmuxGridAuthoritySnapshot.Peer)
        assertNull(wire.tryReceive().getOrNull())
        assertTrue(controller.attempts().isEmpty())
    }

    @Test
    fun presentedNewWindowCannotForceWhileAdvertiseOnlyHiddenPeerOrCoreClaimIsPending() {
        for (gate in listOf("advertiseOnly", "hidden", "background", "peer", "claim")) {
            val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
            val controller = presentedWindowController(wire, hasStamp = gate != "advertiseOnly")
            when (gate) {
                "hidden" -> controller.setPrivate("presentationActive", false)
                "background" -> controller.setPrivate("appForeground", false)
                "advertiseOnly" -> assertEquals(SharedTmuxAuthorityGeometryHold.ADVERTISE_ONLY, controller.native.state.geometryHold)
                "peer" -> controller.native.stampObserved(3_000, "v1 peer 99 Laptop")
                "claim" -> {
                    controller.native.stampObserved(0, "v1 peer-id 3 Laptop")
                    val state = controller.native.requestTakeBack(0).state
                    assertTrue(state.claim != null)
                    controller.setPrivate("lastTmuxAuthorityResult", state)
                }
            }
            controller.presentedSnapshot(newWindowSnapshot(presented = true), wire, expectOwned = false)
            when (gate) {
                "advertiseOnly" -> assertFalse(controller.native.state.geometryHold == SharedTmuxAuthorityGeometryHold.OWNER)
                "peer" -> assertTrue(controller.native.state.authority is SharedTmuxGridAuthoritySnapshot.Peer)
                "claim" -> assertTrue(controller.native.state.claim != null)
            }
            assertNull(gate, wire.tryReceive().getOrNull())
            assertTrue(gate, controller.attempts().isEmpty())
        }
    }

    @Test
    fun presentedNewWindowWaitsForLayoutDetails() {
        val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = presentedWindowController(wire)
        val known = newWindowSnapshot(presented = true)
        controller.presentedSnapshot(known.copy(windows = known.windows.map { if (it.id == 6) it.copy(layout = null) else it }), wire)
        assertNull(wire.tryReceive().getOrNull())
        controller.presentedSnapshot(known, wire)
        controller.provePresentedWindow(wire)
        assertTrue(wire.tryReceive().getOrThrow().command.startsWith("resize-window"))
    }

    @Test
    fun policyBeforeDetailsKeepsNativeLayoutJudgmentBehindPassiveProof() {
        val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = presentedWindowController(wire)
        val known = newWindowSnapshot(presented = true)
        val unknown = known.copy(windows = known.windows.map { if (it.id == 6) it.copy(layout = null) else it })
        controller.presentedSnapshot(unknown, wire)
        assertNull(wire.tryReceive().getOrNull())
        assertEquals(true, controller.privateValue("presentedTmuxWindowRecoveryReserved"))
        controller.presentedSnapshot(known, wire)
        controller.provePresentedWindow(wire)
        assertTrue(wire.tryReceive().getOrThrow().command.startsWith("resize-window"))
    }

    @Test
    fun mismatchedPassiveConfirmationAfterLayoutEchoDoesNotBlockLaterVisitRepair() {
        val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = presentedWindowController(wire)
        controller.presentedSnapshot(newWindowSnapshot(presented = true), wire)
        controller.provePresentedWindow(wire)
        val commands = (0..2).map { wire.tryReceive().getOrThrow() }
        // The resize echo invalidates the mutable ordinary proof context before the unset confirms.
        controller.setPrivate("ordinaryTmuxWindowRecovery", null)
        commands.forEach { controller.mutation(it.purpose as TmuxResponsePurpose.WindowSizeReplayMutation, true) }
        val confirmation = wire.tryReceive().getOrThrow().purpose as TmuxResponsePurpose.WindowSizeReplayConfirmation
        controller.javaClass.getDeclaredMethod("handleTmuxWindowSizeConfirmation", confirmation.javaClass,
            Boolean::class.javaPrimitiveType!!, List::class.java).apply { isAccessible = true }
            .invoke(controller, confirmation, true, listOf("tessera-window-size\t@6\t80\t24"))
        assertTrue("failed passive force must retire its own immutable attempt", controller.attempts().isEmpty())
        val drift = newWindowSnapshot(presented = true).let { it.copy(windows = it.windows.map { w ->
            if (w.id == 6) w.copy(layout = SharedTmuxLayoutNode.Leaf(8, 81, 24)) else w
        }) }
        controller.presentedSnapshot(newWindowSnapshot(presented = false), wire)
        controller.presentedSnapshot(drift, wire)
        controller.provePresentedWindow(wire)
        assertTrue(wire.tryReceive().getOrThrow().command.startsWith("resize-window"))
    }

    @Test
    fun nonLatestPresentedWindowsNeverRecoverOrVeilAcrossRepeatedVisits() {
        for (policy in listOf("smallest", "largest", "manual")) {
            val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
            val controller = presentedWindowController(wire)
            repeat(3) {
                controller.presentedSnapshot(newWindowSnapshot(presented = true), wire, policy)
                controller.assertOwnedWithoutVeil()
                assertEquals(false, controller.privateValue("presentedTmuxWindowRecoveryReserved"))
                assertNull("$policy must not even start passive proof", controller.privateValue("ordinaryTmuxWindowRecovery"))
                assertTrue(controller.attempts().isEmpty())
                assertNull("$policy must not resize, select, or unset policy", wire.tryReceive().getOrNull())
                controller.presentedSnapshot(newWindowSnapshot(presented = false), wire)
                controller.assertOwnedWithoutVeil()
                assertNull(wire.tryReceive().getOrNull())
            }
        }
    }

    @Test
    fun ordinaryRecoveryRequiresAKnownPolicyForItsWindow() {
        for (policy in listOf("unknown", "other-window")) {
            val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
            val controller = presentedWindowController(wire)
            controller.setPrivate("windowSizePolicyKnown", policy != "unknown")
            controller.setPrivate("windowSizePolicyWindowId", if (policy == "other-window") 6 else 5)
            controller.javaClass.getDeclaredMethod("requestOrdinaryTmuxWindowRecovery", Int::class.javaPrimitiveType!!,
                SharedTmuxGridSize::class.java, SharedTmuxGridSize::class.java).apply { isAccessible = true }
                .invoke(controller, 5, size, SharedTmuxGridSize(80, 24))
            assertNull(policy, wire.tryReceive().getOrNull())
            assertNull(policy, controller.privateValue("ordinaryTmuxWindowRecovery"))
        }
    }

    @Test
    fun nonLatestNewLocalGridStillPublishesAfterProofButNeverForces() {
        // tmux keeps sizing the window by its own rule; a stale control
        // client size would still constrain it under smallest or largest.
        for (policy in listOf("smallest", "largest", "manual")) {
            val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
            val controller = presentedWindowController(wire)
            val facts = mutableListOf<SharedTmuxRenderFact>()
            controller.setPrivate("tmuxRenderFactProbe", { fact: SharedTmuxRenderFact -> facts += fact; true })
            controller.presentedSnapshot(newWindowSnapshot(presented = true), wire, policy)
            assertNull(policy, wire.tryReceive().getOrNull())
            val rotated = SharedTmuxGridSize(60, 40)
            controller.publishGeometry(rotated)
            controller.provePresentedWindow(wire)
            assertTrue(policy, facts.contains(SharedTmuxRenderFact.ClientSize(rotated.columns, rotated.rows)))
            assertNull("$policy must not resize, select, or unset policy", wire.tryReceive().getOrNull())
            assertTrue(policy, controller.attempts().isEmpty())
            controller.assertOwnedWithoutVeil()
        }
    }

    @Test
    fun reservationSkipsKnownNonLatestPolicy() {
        for (policy in listOf("smallest", "manual")) {
            val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
            val controller = presentedWindowController(wire)
            controller.setPrivate("windowSizePolicyIsLatest", false)
            controller.javaClass.getDeclaredMethod("reservePresentedTmuxWindowRecovery", SharedTmuxSnapshot::class.java)
                .apply { isAccessible = true }.invoke(controller, driftedSnapshot())
            assertEquals(policy, false, controller.privateValue("presentedTmuxWindowRecoveryReserved"))
            assertNull(wire.tryReceive().getOrNull())
            controller.assertOwnedWithoutVeil()
        }
    }

    private fun newWindowSnapshot(presented: Boolean) = driftedSnapshot().let { baseline ->
        baseline.copy(activeWindowId = if (presented) 6 else 5, windows = listOf(
            baseline.windows.single().copy(layout = SharedTmuxLayoutNode.Leaf(7, 56, 48)),
            baseline.windows.single().copy(id = 6, activePaneId = 8, layout = SharedTmuxLayoutNode.Leaf(8, 80, 24)),
        ))
    }

    private fun presentedWindowController(wire: Channel<TmuxControlCommand>, hasStamp: Boolean = true) =
        bareController(wire, claimingReducer(hasStamp)).apply {
        setPrivate("scope", kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + dispatcher))
        setPrivate("authorityTime", { 3_000L }) // Outside replay echo suppression.
        native.windowSizePolicyReplied(0, 5, "latest")
        setPrivate("lastPublishedTmuxSize", size)
        setPrivate("lastTmuxViewport", size)
        setPrivate("tmuxGridPresentation", SharedTmuxGridPresentation.PANE_GRID)
        setPrivate("tmuxWindowForceRule", TmuxWindowForceRule.Shared)
        setPrivate("tmuxRenderEffectMutex", kotlinx.coroutines.sync.Mutex())
        setPrivate("pendingTmuxRenderBatches", java.util.ArrayDeque<Any>())
        setPrivate("tmuxConnection", unsafe.allocateInstance(SshTmuxConnection::class.java))
        setPrivate("windowSizePolicyKnown", true)
        setPrivate("windowSizePolicyIsLatest", true)
        setPrivate("windowSizePolicyWindowId", 5)
        setPrivate("lastAuthorityWindowFacts", true to SharedTmuxAuthorityActiveWindow(5, size, true))
        setPrivate("mutableTmuxSnapshot", MutableStateFlow<SharedTmuxSnapshot?>(newWindowSnapshot(false)))
    }

    /** A feed-reduced read delivered to the same callback as the mosh side channel. */
    private fun SshSessionController.presentedSnapshot(
        snapshot: SharedTmuxSnapshot,
        wire: Channel<TmuxControlCommand>,
        policy: String = "latest",
        expectOwned: Boolean = true,
    ) {
        val switchedWindow = (privateValue("mutableTmuxSnapshot") as MutableStateFlow<*>).value
            .let { (it as? SharedTmuxSnapshot)?.activeWindowId != snapshot.activeWindowId }
        val window = snapshot.activeWindow
        val facts = snapshot.isWindowListHydrated to window?.let {
            SharedTmuxAuthorityActiveWindow(it.id, it.layout?.let { layout -> SharedTmuxGridSize(layout.width, layout.height) },
                snapshot.isActiveWindowAuthoritative)
        }
        // The native feed reduces window facts before publishing the event.
        val reduced = native.windowFacts(3_000, facts.first, facts.second)
        javaClass.getDeclaredMethod("handleTmuxRuntimeEvent", SharedTmuxEvent::class.java,
            SshTmuxConnection::class.java, Long::class.javaPrimitiveType!!).apply { isAccessible = true }
            .invoke(this, SharedTmuxEvent(snapshot, emptyList(), emptyList(), emptyList(),
                authoritySession = reduced, authorityReducedInFeed = true), privateValue("tmuxConnection"), 8L)
        assertEquals("feed facts must already be memoized before submit", facts, privateValue("lastAuthorityWindowFacts"))
        if (expectOwned) assertOwnedWithoutVeil()
        if (switchedWindow) {
            assertEquals("switch must invalidate the previous window's policy", false, privateValue("windowSizePolicyKnown"))
            assertEquals(false, privateValue("presentedTmuxWindowRecoveryReserved"))
            assertTrue(attempts().isEmpty())
            val query = wire.tryReceive().getOrThrow()
            assertEquals("show-options -wA -v -t @${window!!.id} window-size", query.command)
            assertEquals(TmuxResponsePurpose.WindowSizePolicy(window.id), query.purpose)
            assertNull("no force before policy", wire.tryReceive().getOrNull())
            reply(requireNotNull(query.purpose), listOf(policy))
            if (expectOwned) assertOwnedWithoutVeil()
        }
    }

    private fun SshSessionController.assertOwnedWithoutVeil() {
        assertEquals(authority, native.state.authority)
        assertEquals(authority, (privateValue("mutableTmuxAuthority") as MutableStateFlow<*>).value)
        assertFalse(native.state.presentation is SharedTmuxAuthorityPresentation.Veiled)
    }

    private fun SshSessionController.provePresentedWindow(wire: Channel<TmuxControlCommand>, foreign: Boolean = false) {
        assertOwnedWithoutVeil()
        val authority = wire.tryReceive().getOrThrow()
        assertTrue(authority.purpose is TmuxResponsePurpose.OrdinaryWindowAuthority)
        reply(requireNotNull(authority.purpose), listOf("v1 android-fixture 21 Pixel"))
        assertOwnedWithoutVeil()
        assertTrue(attempts().isEmpty())
        val control = wire.tryReceive().getOrThrow()
        assertTrue(control.purpose is TmuxResponsePurpose.OrdinaryWindowControlClient)
        reply(requireNotNull(control.purpose), listOf("control|123|456"))
        assertOwnedWithoutVeil()
        val visible = wire.tryReceive().getOrThrow()
        assertTrue(visible.purpose is TmuxResponsePurpose.OrdinaryWindowVisibleClient)
        reply(requireNotNull(visible.purpose), listOf("visible|124|456"))
        assertOwnedWithoutVeil()
        val clients = wire.tryReceive().getOrThrow()
        assertTrue(clients.command.startsWith("list-clients -F "))
        assertTrue(attempts().isEmpty())
        reply(requireNotNull(clients.purpose), listOf("@6\tcontrol\t123\t456", "@6\tvisible\t124\t456") +
            if (foreign) listOf("@6\tlaptop\t200\t500") else emptyList())
        if (!foreign) assertOwnedWithoutVeil()
    }

    private fun claimingReducer(hasStamp: Boolean = true) = TmuxAuthorityReducer().also { reducer ->
        reducer.session.adoptShown(0)
        reducer.session.localSize(0, size)
        reducer.session.windowFacts(0, true, SharedTmuxAuthorityActiveWindow(5, size, true))
        val query = reducer.session.attached(0, "android-fixture").effects.filterIsInstance<SharedTmuxAuthoritySessionEffect.QueryAuthority>().single()
        reducer.session.queryReplied(0, query.queryId, if (hasStamp) "v1 android-fixture 21 Pixel" else "", "android-fixture")
    }

    private fun bareController(
        queue: Channel<TmuxControlCommand> = Channel(Channel.UNLIMITED),
        reducer: TmuxAuthorityReducer = claimingReducer(),
    ): SshSessionController =
        (unsafe.allocateInstance(SshSessionController::class.java) as SshSessionController).also(controllers::add).apply {
            setPrivate("tmuxTransportLock", Any())
            setPrivate("tmuxAuthorityLifecycle", reducer)
            setPrivate("mutableTmuxAuthorityPresentation", MutableStateFlow<TmuxAuthorityPresentation>(TmuxAuthorityPresentation.None))
            setPrivate("lastTmuxAuthorityResult", reducer.session.state)
            setPrivate("authorityTime", { 0L })
            setPrivate("scope", kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Unconfined))
            setPrivate("declaredTmuxRenderSurfaces", emptyList<SharedTmuxSurfaceDeclaration>())
            setPrivate("compactTmuxSizer", SharedTmuxCompactSizer())
            setPrivate("diagnostics", testDiagnosticLogStore())
            setPrivate("diagnosticTransport", "mosh_tmux")
            setPrivate("restoreSelectionApplied", true)
            setPrivate("mutableTmuxWindowMutationState", MutableStateFlow<TmuxWindowMutationState>(TmuxWindowMutationState.Unavailable))
            setPrivate("tmuxDeviceIdentity", TmuxDeviceIdentity("android-fixture", "Pixel"))
            setPrivate("tmuxGridPresentation", SharedTmuxGridPresentation.SINGLE_PANE)
            setPrivate("mutableTmuxSnapshot", MutableStateFlow<SharedTmuxSnapshot?>(null))
            setPrivate("pendingTmuxWindowSizeReplays", ConcurrentHashMap<Int, PendingTmuxWindowSizeReplay>())
            setPrivate("tmuxTransportGeneration", 8L)
            setPrivate("tmuxCommandChannel", queue)
            setPrivate("host", SavedHost("fixture", "fixture", "fixture.invalid", 22, "fixture", null, null,
                transportKind = TransportKinds.MOSH, tmuxMode = TmuxModes.AUTOMATIC))
            setPrivate("mutableTmuxAuthority", MutableStateFlow<SharedTmuxGridAuthoritySnapshot>(authority))
            setPrivate("mutableTmuxReclaimInFlight", MutableStateFlow(false))
            setPrivate("inlineAuthorityRepaintFence", InlineAuthorityRepaintFence())
            setPrivate("activeTmuxResponses", ConcurrentHashMap<Long, TmuxResponsePurpose>())
            setPrivate("appForeground", true)
            setPrivate("presentationActive", true)
            setPrivate("closed", false)
        }

    private fun ordinaryRecoveryController(queue: Channel<TmuxControlCommand> = Channel(Channel.UNLIMITED)) =
        bareController(queue).apply {
            setPrivate("mutableTmuxSnapshot", MutableStateFlow(driftedSnapshot()))
            setPrivate("lastTmuxViewport", size)
            setPrivate("lastPublishedTmuxSize", size)
            setPrivate("windowSizePolicyKnown", true)
            setPrivate("windowSizePolicyIsLatest", true)
            setPrivate("windowSizePolicyWindowId", 5)
            setPrivate("ordinaryTmuxWindowRecovery", PendingTmuxOrdinaryWindowRecovery(
                31, 8, 5, size, SharedTmuxGridSize(56, 46), 21, "expected-own-stamp", true,
                size, size, driftedSnapshot().activeWindow?.layout, 7, SharedTmuxGridPresentation.SINGLE_PANE, false,
            ))
        }

    private fun clientProofPurpose() = TmuxResponsePurpose.OrdinaryWindowClients(31, "control|123|456", "visible|124|456")

    private fun SshSessionController.reply(purpose: TmuxResponsePurpose, lines: List<String>) {
        @Suppress("UNCHECKED_CAST")
        val responses = privateValue("activeTmuxResponses") as ConcurrentHashMap<Long, TmuxResponsePurpose>
        responses[43] = purpose
        javaClass.getDeclaredMethod("handleTmuxPlatformReply", Long::class.javaPrimitiveType!!, Boolean::class.javaPrimitiveType!!, List::class.java)
            .apply { isAccessible = true }.invoke(this, 43L, true, lines)
    }

    private fun SshSessionController.publishGeometry(size: SharedTmuxGridSize) {
        javaClass.getDeclaredMethod("publishTmuxClientSize", size.javaClass,
            Boolean::class.javaPrimitiveType!!, Boolean::class.javaPrimitiveType!!, Long::class.javaObjectType)
            .apply { isAccessible = true }.invoke(this, size, false, false, null)
    }

    private fun SshSessionController.enqueueCoreWire(
        commands: List<SharedTmuxPlatformWireCommand>, connection: SshTmuxConnection, generation: Long,
    ): Boolean = javaClass.getDeclaredMethod("enqueueTmuxPlatformWireCommands", List::class.java,
        SshTmuxConnection::class.java, Long::class.javaPrimitiveType!!).apply { isAccessible = true }
        .invoke(this, commands, connection, generation) as Boolean

    private fun SshSessionController.failPlatformWrite(
        request: TmuxControlCommand, responses: ConcurrentHashMap<Long, TmuxResponsePurpose>,
    ) {
        javaClass.getDeclaredMethod("failTmuxPlatformWrite", TmuxControlCommand::class.java, ConcurrentHashMap::class.java)
            .apply { isAccessible = true }.invoke(this, request, responses)
    }

    private fun assertFittingWindowRestoresLocalMoshCanvas(previousCanvas: SharedTmuxGridSize) {
        val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val controller = bareController(wire)
        val desired = SharedTmuxGridSize(100, 30)
        val canvas = MutableStateFlow<SharedTmuxGridSize?>(previousCanvas)
        val resizeRequests = Channel<Any>(Channel.CONFLATED)
        val transport = unsafe.allocateInstance(AndroidMoshTransport::class.java) as AndroidMoshTransport
        controller.setPrivate("moshTransport", transport)
        controller.setPrivate("mutableMoshCanvasSize", canvas)
        controller.setPrivate("moshResizeRequests", resizeRequests)
        controller.setPrivate("mutableTmuxAuthority", MutableStateFlow<SharedTmuxGridAuthoritySnapshot>(SharedTmuxGridAuthoritySnapshot.Unknown))
        controller.setPrivate("lastPublishedTmuxSize", desired)
        // This is the existing fitting branch's actual target sink. Unknown
        // sizing policy keeps remote mutations fail-closed before JNI, while
        // the device's own Mosh PTY must still return to its full-window grid.
        controller.javaClass.getDeclaredMethod("forceTmuxWindowSizes", desired.javaClass,
            Boolean::class.javaPrimitiveType!!, Int::class.javaObjectType, Long::class.javaObjectType)
            .apply { isAccessible = true }.invoke(controller, desired, false, 5, null)

        assertEquals(desired, canvas.value)
        val resize = resizeRequests.tryReceive().getOrThrow()
        assertTrue(resize.privateValue("transport") === transport)
        assertEquals(desired, resize.privateValue("size"))
        assertEquals(desired, controller.privateValue("lastPublishedTmuxSize"))
        assertTrue(controller.attempts().isEmpty())
        assertNull(wire.tryReceive().getOrNull())
    }

    private fun SshSessionController.deliverReconnectAuthorityReply() {
        // The real session's own read retains authority without a gesture.
        if (!(privateValue("appForeground") as Boolean)) reduce { it.backgrounded(0) }
        val query = native.attached(0, "android-fixture").effects.filterIsInstance<SharedTmuxAuthoritySessionEffect.QueryAuthority>().single()
        val drifted = driftedSnapshot()
        val purpose = TmuxResponsePurpose.AuthorityRederive(8, query.queryId, null, drifted.sessionId)
        setPrivate("pendingAuthorityQuery", purpose)
        // Known geometry (PANE_GRID: the viewport is the local size), so the
        // reply is judged now rather than held for a layout.
        setPrivate("tmuxGridPresentation", SharedTmuxGridPresentation.PANE_GRID)
        setPrivate("mutableTmuxSnapshot", MutableStateFlow<SharedTmuxSnapshot?>(drifted))
        setPrivate("lastTmuxViewport", size)
        // The advertised grid, so the stamp-less layout judgment after the
        // reply (native) is reached only by the foreground, presented case.
        setPrivate("lastPublishedTmuxSize", size)
        @Suppress("UNCHECKED_CAST")
        val responses = privateValue("activeTmuxResponses") as ConcurrentHashMap<Long, TmuxResponsePurpose>
        responses[41] = purpose
        javaClass.getDeclaredMethod("handleTmuxPlatformReply", Long::class.javaPrimitiveType!!, Boolean::class.javaPrimitiveType!!, List::class.java)
            .apply { isAccessible = true }.invoke(this, 41L, true, listOf("v1 android-fixture 21 Pixel"))
    }

    private fun SshSessionController.stamplessLayout(snapshot: SharedTmuxSnapshot) {
        setPrivate("lastTmuxViewport", size)
        setPrivate("lastPublishedTmuxSize", size)
        setPrivate("windowSizePolicyKnown", true)
        setPrivate("windowSizePolicyIsLatest", true)
        setPrivate("windowSizePolicyWindowId", 5)
        if (!(privateValue("presentationActive") as Boolean)) reduce { it.hidden(0) }
        setPrivate("mutableTmuxSnapshot", MutableStateFlow<SharedTmuxSnapshot?>(snapshot))
        javaClass.getDeclaredMethod("submitAuthorityGeometryFacts", SharedTmuxSnapshot::class.java)
            .apply { isAccessible = true }.invoke(this, snapshot)
        reduce { it.windowSizePolicyReplied(0, 5, "latest") }
    }

    private fun driftedSnapshot() = SharedTmuxSnapshot(
        sessionName = "fixture",
        activeWindowId = 5,
        windows = listOf(SharedTmuxWindow(5, 0, "fixture", 7, emptyList(), false,
            SharedTmuxLayoutNode.Leaf(7, 56, 46))),
        authority = authority,
        revision = 1,
        rawJson = byteArrayOf(),
        isWindowListHydrated = true,
        isActiveWindowAuthoritative = true,
    )

    private val SshSessionController.native get() = (privateValue("tmuxAuthorityLifecycle") as TmuxAuthorityReducer).session
    private fun SshSessionController.reduce(event: (SharedTmuxAuthoritySession) -> SharedTmuxAuthoritySessionResult) {
        val result = event(native)
        javaClass.getDeclaredMethod("applyTmuxAuthorityLifecycle", SharedTmuxAuthoritySessionResult::class.java)
            .apply { isAccessible = true }.invoke(this, result)
    }

    @Suppress("UNCHECKED_CAST")
    private fun SshSessionController.attempts(): ConcurrentHashMap<Int, PendingTmuxWindowSizeReplay> =
        privateValue("pendingTmuxWindowSizeReplays") as ConcurrentHashMap<Int, PendingTmuxWindowSizeReplay>

    private fun SshSessionController.attachGeometry(state: TerminalSurfaceState?) {
        javaClass.getDeclaredMethod("reconcileTmuxViewportAfterAttach", TerminalSurfaceState::class.java)
            .apply { isAccessible = true }.invoke(this, state)
    }

    private fun SshSessionController.mutation(purpose: TmuxResponsePurpose.WindowSizeReplayMutation, success: Boolean) {
        javaClass.getDeclaredMethod("handleTmuxWindowSizeMutation", purpose.javaClass, Boolean::class.javaPrimitiveType!!)
            .apply { isAccessible = true }.invoke(this, purpose, success)
    }

    private fun SshSessionController.confirmation(purpose: TmuxResponsePurpose.WindowSizeReplayConfirmation) {
        javaClass.getDeclaredMethod("handleTmuxWindowSizeConfirmation", purpose.javaClass, Boolean::class.javaPrimitiveType!!, List::class.java)
            .apply { isAccessible = true }.invoke(this, purpose, true, listOf("tessera-window-size\t@5\t56\t48"))
    }

    private fun attempt() = PendingTmuxWindowSizeReplay(17, 8, size,
        "display-message -p -t @5 'tessera-window-size\t#{window_id}\t#{window_width}\t#{window_height}'")

    private fun mutation(index: Int) = TmuxResponsePurpose.WindowSizeReplayMutation(5, 17, 8, size, index)

    private fun grid(columns: Int, rows: Int) = TerminalSurfaceState(
        columns, rows, false, false, TerminalMouseMode.Off, true, 0, 0, true, 0, false,
    )

    private fun Any.privateValue(name: String): Any? =
        javaClass.getDeclaredField(name).apply { isAccessible = true }.get(this)

    private fun Any.setPrivate(name: String, value: Any?) {
        javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value)
    }

    private companion object {
        val size = SharedTmuxGridSize(56, 48)
        val authority = SharedTmuxGridAuthoritySnapshot.Mine(21)
        val ownInventory = listOf("@5\tcontrol\t123\t456", "@5\tvisible\t124\t456")
        val unsafe: sun.misc.Unsafe = sun.misc.Unsafe::class.java
            .getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null) as sun.misc.Unsafe
    }
}
