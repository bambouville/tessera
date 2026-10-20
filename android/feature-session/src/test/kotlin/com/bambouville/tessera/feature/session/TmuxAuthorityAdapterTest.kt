package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.AgentEndpointResult
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentSemanticKey
import com.bambouville.tessera.agent.platform.AgentSessionKey
import com.bambouville.tessera.agent.platform.AgentTmuxControlAck
import com.bambouville.tessera.agent.platform.AgentTmuxPlacement
import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.core.bridge.SharedBackendCommand
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityClaimPhase
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityClaimReason
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityShowSource
import com.bambouville.tessera.core.bridge.SharedTmuxClaimSettlement
import com.bambouville.tessera.core.bridge.SharedTmuxCompactReprojection
import com.bambouville.tessera.core.bridge.SharedTmuxCompactReprojectionMemo
import com.bambouville.tessera.core.bridge.SharedTmuxCompactReprojectionResult
import com.bambouville.tessera.core.bridge.SharedTmuxCompactSizer
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthorityReason
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxGridPresentation
import com.bambouville.tessera.core.bridge.SharedTmuxGridSize
import com.bambouville.tessera.core.bridge.SharedTmuxPane
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.core.bridge.SharedTmuxEvent
import com.bambouville.tessera.core.bridge.SharedTmuxRenderBytes
import com.bambouville.tessera.core.bridge.SharedTmuxRenderEffect
import com.bambouville.tessera.core.bridge.SharedTmuxRenderFact
import com.bambouville.tessera.core.bridge.SharedTmuxRenderFeedSource
import com.bambouville.tessera.core.bridge.SharedTmuxRenderLedgerOptions
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.core.bridge.SharedTmuxRenderProfile
import com.bambouville.tessera.core.bridge.SharedTmuxRenderStage
import com.bambouville.tessera.core.bridge.SharedTmuxRuntime
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxSurfaceDeclaration
import com.bambouville.tessera.core.bridge.SharedTmuxSurfacePresentation
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import com.bambouville.tessera.core.bridge.TmuxCoreRuntime
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.networking.SshRouteOwner
import com.bambouville.tessera.networking.SshTmuxConnection
import com.bambouville.tessera.terminal.RenderOwner
import com.bambouville.tessera.terminal.TerminalMouseMode
import com.bambouville.tessera.terminal.TerminalSurface
import com.bambouville.tessera.terminal.TerminalSurfaceState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.ExperimentalForInheritanceCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.Before
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.lang.reflect.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn

/**
 * The Android adapter around the shared authority reducer (§6.9): query
 * freshness at the show edge, D4 delivery, geometry evidence, raw stamp edges,
 * the projection and its input gate, and R3's intent clock. The reducer is
 * the real shared session loaded through the host JNI core.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class TmuxAuthorityAdapterTest {
    @get:Rule
    val coroutineFailures = UncaughtCoroutineFailures()
    private val scheduler = TestCoroutineScheduler()
    private val controllers = mutableListOf<SshSessionController>()
    private val peer = SharedTmuxGridAuthoritySnapshot.Peer("ipad-id", "iPad", 4)
    private val viewport = SharedTmuxGridSize(80, 24)
    private val inlineHost = SavedHost("fixture", "fixture", "fixture.invalid", 22, "fixture", null, null,
        transportKind = TransportKinds.SSH, tmuxMode = TmuxModes.AUTOMATIC)

    @Before fun useMainDispatcher() { Dispatchers.setMain(StandardTestDispatcher(scheduler)) }
    @Test fun subscriptionCommandsUseIgnoreAndAreNotElidedWithAnUnchangedSnapshot() {
        val c = ready()
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        val tmux = c.field<SshTmuxConnection>("tmuxConnection")
        wire.drainWire()
        c.setField("tmuxUserInputFactInFlight", true)
        val commands = listOf(
            "refresh-client -B 'tessera-bell.7:%7:#{window_bell_flag}'",
            "refresh-client -B 'tessera-pane-meta.8'",
        )
        val event = SharedTmuxEvent(c.heldSnapshot(), emptyList(), emptyList(), emptyList(), subscriptionCommands = commands)
        c.deliver(event, tmux, generation = 7)
        assertTrue(wire.drainWire().isEmpty())
        c.deliver(event, tmux)
        val sent = generateSequence { wire.tryReceive().getOrNull() }.toList()
        assertEquals(commands, sent.map { it.command })
        assertTrue(sent.all { it.purpose == TmuxResponsePurpose.Ignore })
    }

    @Test fun aParkedMoshRuntimeForgetsFeedsUntilTheNextAttachRequestsThem() = withMainOnTestScheduler {
        val c = ready()
        c.setField("host", inlineHost.copy(transportKind = TransportKinds.MOSH))
        c.setField("tmuxConnection", null)
        val events = mutableListOf<SharedTmuxEvent>()
        SharedTmuxRuntime.create { events += it }.use { runtime ->
            val requested = baseSubscriptions.copy(authority = true, authorityOwnerSessionId = 42)
            c.setField("desiredTmuxSubscriptions", requested)
            c.setField("tmuxCore", runtime)
            assertEquals(CoreCallResult.Accepted, runtime.setSubscriptions(requested))
            val topology = ("%session-changed \$7 work\r\n%begin 1 1 1\r\n" +
                "__tessera_windows__\t@5\t0\t%7\t\t\t0\tmain\r\n%end 1 1 1\r\n").encodeToByteArray()
            assertEquals(CoreCallResult.Accepted, runtime.feed(topology))
            assertTrue(events.flatMap { it.subscriptionCommands }.any { it.contains("tessera-pane-meta.7:%7:") })

            c.resetTransportAndReattach()
            assertEquals(SharedTmuxSubscriptions(), c.field<SharedTmuxSubscriptions>("desiredTmuxSubscriptions"))
            assertFalse(c.field<Boolean>("authoritySubscriptionRequested"))
            assertTrue(c.field<SharedTmuxRuntime?>("parkedMoshTmuxCore") === runtime)
            events.clear()
            runtime.replaceListener { events += it }
            assertEquals(CoreCallResult.Accepted, runtime.feed(topology))
            assertTrue(events.flatMap { it.subscriptionCommands }.isEmpty())
            assertEquals(CoreCallResult.Accepted, runtime.setSubscriptions(baseSubscriptions))
            assertTrue(events.last().subscriptionCommands.any { it.contains("tessera-pane-meta.7:%7:") })
            c.setField("parkedMoshTmuxCore", null)
        }
    }

    @Test fun moshStartupReservesOwnerResolutionRepliesAfterTheTransportFifoReset() {
        val c = ready()
        c.setField("host", inlineHost.copy(transportKind = TransportKinds.MOSH))
        c.setField("tmuxAuthorityOwnerSessionName", "owner")
        c.setField("initiallyRequestedTmuxRenderSurfaces", ConcurrentHashMap.newKeySet<String>())
        val order = mutableListOf<String>()
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        wire.drainWire()
        c.setField("tmuxRenderFactProbe", { fact: SharedTmuxRenderFact ->
            if (fact is SharedTmuxRenderFact.TransportAttached) order += "transport-attached"
            true
        })
        c.setField("tmuxPlatformCommandProbe", { command: TmuxControlCommand ->
            if (command.purpose is TmuxResponsePurpose.AuthorityOwnerResolution) order += "resolve"
            if (command.purpose is TmuxResponsePurpose.AuthorityRederive) order += "read"
            wire.trySend(command).isSuccess
        })
        assertTrue(c.startRenderTransport(c.field("tmuxConnection")))
        assertEquals(listOf("transport-attached", "resolve", "resolve"), order)
        val resolution = generateSequence { wire.tryReceive().getOrNull() }.toList()
        assertEquals(2, resolution.size)
        c.scopeReply(resolution[0].purpose, true, listOf("\$42 group"))
        c.scopeReply(resolution[1].purpose, true, listOf("\$0 group"))
        assertEquals(listOf("transport-attached", "resolve", "resolve", "read"), order)
        assertEquals(listOf(SharedTmuxCommands.authorityQueryCommand(42)), wire.drainWire())
    }

    @Test fun ownerResolutionHoldsTheLatestReadAndSubscriptionUntilBothReplies() {
        val c = ready()
        c.setField("host", inlineHost.copy(transportKind = TransportKinds.MOSH))
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        wire.drainWire()
        c.apply(c.native.resetTransport(0, preservingPeer = true))
        c.beginOwnerResolution()
        c.ownerSubscription()
        c.apply(c.native.attached(0, "android-id"))
        c.shown(SharedTmuxAuthorityShowSource.SHOW)
        val deciding = c.native.state.currentQueryId
        val resolution = generateSequence { wire.tryReceive().getOrNull() }.toList()
        assertEquals(2, resolution.size)
        assertTrue(resolution.all { it.purpose is TmuxResponsePurpose.AuthorityOwnerResolution })
        assertTrue(c.takeSubscriptions().none { it.authority })
        c.scopeReply(resolution[0].purpose, true, listOf("\$42 group"))
        assertEquals(emptyList<String>(), wire.drainWire())
        assertTrue(c.takeSubscriptions().isEmpty())
        c.scopeReply(resolution[1].purpose, true, listOf("\$0 group"))
        val released = generateSequence { wire.tryReceive().getOrNull() }.toList()
        assertEquals(listOf(baseSubscriptions.copy(authority = true, authorityOwnerSessionId = 42)), c.takeSubscriptions())
        assertEquals(listOf(SharedTmuxCommands.authorityQueryCommand(42)), released.map { it.command })
        assertEquals(deciding, (released.last().purpose as TmuxResponsePurpose.AuthorityRederive).sequence)
        assertEquals(null, c.field<Long?>("heldAuthorityQueryId"))
    }

    @Test fun failedOwnerResolutionFallsBackAndInlineAddsNoRoundTrip() {
        val c = ready()
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        wire.drainWire()
        c.beginOwnerResolution()
        c.ownerSubscription()
        assertTrue(wire.drainWire().isEmpty())
        assertEquals(baseSubscriptions.copy(authority = true), c.takeSubscriptions().last())
        c.setField("host", inlineHost.copy(transportKind = TransportKinds.MOSH))
        c.apply(c.native.resetTransport(0, preservingPeer = true))
        c.beginOwnerResolution()
        c.ownerSubscription()
        c.apply(c.native.attached(0, "android-id"))
        val resolution = generateSequence { wire.tryReceive().getOrNull() }.toList()
        c.scopeReply(resolution[0].purpose, false, listOf("\$42 group"))
        c.scopeReply(resolution[1].purpose, true, listOf("\$0 group"))
        assertEquals(listOf(SharedTmuxCommands.authorityQueryCommand()), wire.drainWire())
        assertEquals(baseSubscriptions.copy(authority = true), c.takeSubscriptions().last())
    }

    @Test fun ownerWriteAcknowledgesOnlyTheFirstCommandAndMirrorsTheView() {
        val c = ready()
        c.shown(SharedTmuxAuthorityShowSource.SHOW)
        c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad")
        val generation = c.native.state.claim!!.generation
        c.setField("authorityOwnerSessionId", 42)
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        wire.drainWire()
        c.javaClass.getDeclaredMethod("commitTmuxGridAuthorityStamp", Long::class.javaPrimitiveType!!)
            .apply { isAccessible = true }.invoke(c, generation)
        val writes = generateSequence { wire.tryReceive().getOrNull() }.toList()
        assertEquals(SharedTmuxCommands.authorityWriteCommands("v1 android-id $generation Pixel", 42), writes.map { it.command })
        assertEquals(TmuxResponsePurpose.AuthorityCommit(generation, ownerSessionId = 42), writes[0].purpose)
        assertEquals(TmuxResponsePurpose.Ignore, writes[1].purpose)
    }

    @Test fun aKilledOwnerFallsBackToTheOwnSessionOnItsFirstRead() {
        // A grouped view outlives its killed owner, whose read then finds no
        // owner (`show-options -q -t` would answer an unset stamp): the
        // subscription, the retry and later reads move to our own session,
        // as on iOS.
        val c = ready()
        c.setField("host", inlineHost.copy(transportKind = TransportKinds.MOSH))
        c.setField("authorityOwnerSessionId", 42)
        c.ownerSubscription()
        assertEquals(listOf(baseSubscriptions.copy(authority = true, authorityOwnerSessionId = 42)), c.takeSubscriptions())
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        wire.drainWire()
        c.shown(SharedTmuxAuthorityShowSource.SHOW)
        val read = c.lastQuery()
        assertEquals(42, read.ownerSessionId)
        assertEquals(listOf(SharedTmuxCommands.authorityQueryCommand(42)), wire.drainWire())
        c.recoveryReply(read, true, listOf(""))
        assertNull(c.field<Int?>("authorityOwnerSessionId"))
        assertTrue(wire.drainWire().isEmpty())
        assertEquals(listOf(baseSubscriptions.copy(authority = true)), c.takeSubscriptions())
        scheduler.advanceTimeBy(250); scheduler.runCurrent()
        assertEquals(listOf(SharedTmuxCommands.authorityQueryCommand()), wire.drainWire())
        assertNull(c.lastQuery().ownerSessionId)
    }

    @Test fun aLiveOwnerWithoutAStampKeepsTheOwnerScope() {
        val c = ready()
        c.setField("authorityOwnerSessionId", 42)
        c.shown(SharedTmuxAuthorityShowSource.SHOW)
        val read = c.lastQuery()
        c.recoveryReply(read, true, listOf("\$42|"))
        assertEquals(42, c.field<Int?>("authorityOwnerSessionId"))
        assertNotNull(c.native.state.claim)
    }

    @Test fun onlyTheCurrentOwnersMissingReadOrFailedWriteMovesTheScope() {
        val c = ready()
        c.setField("authorityOwnerSessionId", 84)
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        wire.drainWire()
        val transport = c.field<Long>("tmuxTransportGeneration")
        // A failed read says nothing about the owner; replies for an owner
        // this connection no longer targets say nothing about the current one.
        c.recoveryReply(TmuxResponsePurpose.AuthorityRederive(transport, 900, null, null, ownerSessionId = 84), false, emptyList())
        c.recoveryReply(TmuxResponsePurpose.AuthorityRederive(transport, 901, null, null, ownerSessionId = 42), true, listOf(""))
        c.recoveryReply(TmuxResponsePurpose.AuthorityCommit(1, ownerSessionId = 42), false, emptyList())
        assertEquals(84, c.field<Int?>("authorityOwnerSessionId"))
        c.recoveryReply(TmuxResponsePurpose.AuthorityCommit(1, ownerSessionId = 84), false, emptyList())
        assertNull(c.field<Int?>("authorityOwnerSessionId"))
    }

    @Test fun aMissingOwnerInAnObsoleteRecoveryReadStillMovesTheScope() {
        // The recovery the read served is gone (no recovery is current), but
        // its reply still proves the owner is: act on it, as iOS does.
        val c = ready()
        c.setField("authorityOwnerSessionId", 42)
        c.ownerSubscription()
        c.takeSubscriptions()
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        wire.drainWire()
        c.recoveryReply(TmuxResponsePurpose.OrdinaryWindowAuthority(999, ownerSessionId = 42), true, listOf(""))
        assertNull(c.field<Int?>("authorityOwnerSessionId"))
        assertTrue(wire.drainWire().isEmpty())
        assertEquals(listOf(baseSubscriptions.copy(authority = true)), c.takeSubscriptions())
    }

    @Test fun aPriorConnectionsMissingOwnerReplyLeavesTheSameOwnerResolvedAgain() {
        // A reconnect resolved the same owner id: a reply from the previous
        // connection, even one that found no owner, must not move the scope.
        val c = ready()
        c.setField("authorityOwnerSessionId", 42)
        val previous = c.field<Long>("tmuxTransportGeneration")
        c.setField("tmuxTransportGeneration", previous + 1)
        c.recoveryReply(TmuxResponsePurpose.AuthorityRederive(previous, 902, null, null, ownerSessionId = 42), true, listOf(""))
        assertEquals(42, c.field<Int?>("authorityOwnerSessionId"))
    }

    @Test fun aReconnectResolvesAgainAndDropsThePriorConnectionReplies() {
        val c = ready()
        c.setField("host", inlineHost.copy(transportKind = TransportKinds.MOSH))
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        wire.drainWire()
        c.beginOwnerResolution()
        val old = generateSequence { wire.tryReceive().getOrNull() }.toList()
        c.setField("tmuxTransportGeneration", 9L)
        c.beginOwnerResolution(9)
        val fresh = generateSequence { wire.tryReceive().getOrNull() }.toList()
        old.forEach { c.scopeReply(it.purpose, true, listOf(if ((it.purpose as TmuxResponsePurpose.AuthorityOwnerResolution).owner) "\$42 group" else "\$0 group")) }
        assertNull(c.field<Int?>("authorityOwnerSessionId"))
        fresh.forEach { c.scopeReply(it.purpose, true, listOf(if ((it.purpose as TmuxResponsePurpose.AuthorityOwnerResolution).owner) "\$84 group" else "\$0 group")) }
        assertEquals(84, c.field<Int?>("authorityOwnerSessionId"))
    }

    /**
     * The owner resolution's second command reads the client's current
     * session, so a switch resolves again on the same transport, and a reply
     * the old session answered must not decide the new one's scope (§6.18).
     */
    @Test fun aSessionSwitchResolvesTheOwnerAgainAndDropsTheOldSessionsReplies() {
        val c = ready()
        c.setField("host", inlineHost.copy(transportKind = TransportKinds.MOSH))
        c.setField("tmuxAuthorityOwnerSessionName", "owner")
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        val tmux = c.field<SshTmuxConnection>("tmuxConnection")
        fun resolutionReplies() = generateSequence { wire.tryReceive().getOrNull() }.toList()
            .filter { it.purpose is TmuxResponsePurpose.AuthorityOwnerResolution }
        c.deliver(SharedTmuxEvent(c.heldSnapshot().copy(sessionId = 7), emptyList(), emptyList(), emptyList()), tmux)
        wire.drainWire(); c.beginOwnerResolution()
        val old = resolutionReplies()
        c.deliver(SharedTmuxEvent(c.heldSnapshot().copy(sessionId = 9), emptyList(), emptyList(), emptyList(), controlSessionSwitched = true), tmux)
        val fresh = resolutionReplies()
        assertEquals(2, old.size); assertEquals(2, fresh.size)

        // Session 7 shares the owner's group; session 9 does not.
        old.forEach { c.scopeReply(it.purpose, true, listOf(if ((it.purpose as TmuxResponsePurpose.AuthorityOwnerResolution).owner) "\$42 group" else "\$7 group")) }
        assertNotNull("still resolving the new session", c.field<Any?>("authorityScopeResolution"))
        assertNull(c.field<Int?>("authorityOwnerSessionId"))
        fresh.forEach { c.scopeReply(it.purpose, true, listOf(if ((it.purpose as TmuxResponsePurpose.AuthorityOwnerResolution).owner) "\$42 group" else "\$9 solo")) }
        assertNull(c.field<Any?>("authorityScopeResolution"))
        assertNull("the new session reads its own stamp", c.field<Int?>("authorityOwnerSessionId"))
    }

    /**
     * A redelivered switch issues no read of its own: the read the old
     * resolution held is still the session's, and goes out once the new
     * session's scope resolves (§6.18).
     */
    @Test fun aRedeliveredSwitchKeepsTheReadTheOldResolutionHeld() {
        val c = ready()
        c.setField("host", inlineHost.copy(transportKind = TransportKinds.MOSH))
        c.setField("tmuxAuthorityOwnerSessionName", "owner")
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        val tmux = c.field<SshTmuxConnection>("tmuxConnection")
        fun resolutionReplies() = generateSequence { wire.tryReceive().getOrNull() }.toList()
            .filter { it.purpose is TmuxResponsePurpose.AuthorityOwnerResolution }
        c.deliver(SharedTmuxEvent(c.heldSnapshot().copy(sessionId = 7), emptyList(), emptyList(), emptyList()), tmux)
        wire.drainWire(); c.beginOwnerResolution(); resolutionReplies()
        val read = checkNotNull(c.field<SharedTmuxAuthoritySessionState?>("lastTmuxAuthorityResult")?.currentQueryId)
        c.javaClass.getDeclaredMethod("sendTmuxAuthorityQuery", Long::class.javaPrimitiveType!!)
            .apply { isAccessible = true }.invoke(c, read)
        assertEquals("held under the old resolution", read, c.field<Long?>("heldAuthorityQueryId"))

        c.deliver(SharedTmuxEvent(c.heldSnapshot().copy(sessionId = 9), emptyList(), emptyList(), emptyList(),
            authorityReducedInFeed = true, controlSessionSwitched = true), tmux)
        val fresh = resolutionReplies()
        assertEquals(2, fresh.size)
        fresh.forEach { c.scopeReply(it.purpose, true, listOf(if ((it.purpose as TmuxResponsePurpose.AuthorityOwnerResolution).owner) "\$42 group" else "\$9 solo")) }
        assertNull(c.field<Any?>("authorityScopeResolution"))
        val sent = wire.drainWire()
        assertEquals(sent.toString(), 1, sent.count { it == "show-options -qv @tessera_authority" })
        assertEquals("the held read went out under the new scope", read, c.lastQuery().sequence)
        assertEquals(9, c.lastQuery().sessionId)
    }

    private fun SshSessionController.beginOwnerResolution(generation: Long = 8) {
        synchronized(field<Any>("tmuxTransportLock")) {
            javaClass.getDeclaredMethod("beginTmuxAuthorityScopeResolution", String::class.java, Long::class.javaPrimitiveType!!)
                .apply { isAccessible = true }.invoke(this, "owner", generation)
        }
    }
    private fun SshSessionController.ownerSubscription() {
        javaClass.getDeclaredMethod("sendTmuxAuthoritySubscription").apply { isAccessible = true }.invoke(this)
    }
    private fun SshSessionController.scopeReply(purpose: TmuxResponsePurpose?, success: Boolean, lines: List<String>) {
        synchronized(field<Any>("tmuxTransportLock")) {
            javaClass.getDeclaredMethod("handleTmuxAuthorityScopeReply", TmuxResponsePurpose.AuthorityOwnerResolution::class.java,
                Boolean::class.javaPrimitiveType!!, List::class.java).apply { isAccessible = true }.invoke(this, purpose, success, lines)
        }
    }

    @Test fun aShowStaysResumingThroughABufferedPeerAndItsClaimWithoutEverVeiling() {
        val c = ready(); c.shown(SharedTmuxAuthorityShowSource.SHOW)
        assertEquals(TmuxAuthorityPresentation.Resuming(), c.presentation())
        c.observe(peer); assertEquals(TmuxAuthorityPresentation.Resuming(), c.presentation())
        c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad")
        assertEquals(TmuxAuthorityPresentation.Resuming(), c.presentation())
        assertNotNull(c.native.state.claim)
        assertFalse(c.presentation() is TmuxAuthorityPresentation.Veiled)
    }
    @Test fun theShowEdgeSendsAFreshQueryAndTheOlderReplyIsDroppedUnread() {
        val c = ready(); val before = c.lastQuery(); c.shown(SharedTmuxAuthorityShowSource.SHOW); val show = c.lastQuery()
        assertTrue(show.sequence > before.sequence)
        c.replyTo(before, "v1 android-id 2 Pixel")
        assertNotNull(c.native.state.pendingIntent); assertNull(c.native.state.claim)
        c.replyTo(show, "v1 ipad-id 4 iPad"); assertEquals(SharedTmuxAuthorityClaimReason.SHOW, c.native.state.claim!!.reason)
    }
    @Test fun aReplyWhileHiddenAndBackgroundedStillReachesTheReducer() {
        val c = ready(); val read = c.lastQuery(); c.hidden(); c.apply(c.native.backgrounded(0)); c.replyTo(read, "v1 ipad-id 4 iPad")
        assertEquals(peer, c.native.state.authority); assertNull(c.native.state.claim)
        assertEquals(SharedTmuxAuthorityGeometryHold.WITHHELD, c.native.state.geometryHold)
    }
    @Test fun aReplyBeforeTheLayoutIsKnownIsHeldUntilTheLayoutArrives() {
        val c = ready(snapshot = null); c.replyTo(c.lastQuery(), OWN_STAMP)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, c.native.state.authority)
        assertEquals(SharedTmuxAuthorityGeometryHold.WITHHELD, c.native.state.geometryHold)
        c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = snapshot(viewport)
        c.facts(); assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
    }
    @Test fun aHeldReplyIsDeliveredAsUnknownOnlyAtTheSafetyBound() {
        val c = ready(snapshot = null); c.replyTo(c.lastQuery(), OWN_STAMP)
        scheduler.advanceTimeBy(9999); scheduler.runCurrent(); assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, c.native.state.authority)
        scheduler.advanceTimeBy(1); scheduler.runCurrent(); assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
        assertEquals(SharedTmuxAuthorityGeometryHold.OWNER, c.native.state.geometryHold)
    }
    @Test fun anOwnStampReadWaitsForTheViewportAsWellAsTheLayout() {
        val c = ready(measured = null); c.replyTo(c.lastQuery(), OWN_STAMP)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, c.native.state.authority)
        c.viewportAfterAttach(viewport); assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
    }
    @Test fun aReadThatIsNotOurStampIsNeverHeldForGeometry() {
        for (raw in listOf("v1 ipad-id 4 iPad", "")) {
            val c = ready(snapshot = null); c.replyTo(c.lastQuery(), raw)
            assertEquals(if (raw.isEmpty()) SharedTmuxGridAuthoritySnapshot.Unknown else peer, c.native.state.authority)
            assertEquals(if (raw.isEmpty()) SharedTmuxAuthorityGeometryHold.ADVERTISE_ONLY else SharedTmuxAuthorityGeometryHold.WITHHELD, c.native.state.geometryHold)
        }
    }
    @Test fun outputOnlyBatchesNeverCrossIntoAuthorityAndStampBatchesCrossOnce() {
        val h = nativeAuthority(); val c = ready(h); c.replyTo(c.lastQuery(), OWN_STAMP)
        c.setField("tmuxCore", null)
        val tmux = c.field<SshTmuxConnection>("tmuxConnection")
        val projected = mutableListOf<SharedTmuxGridAuthoritySnapshot>()
        c.setField("tmuxAuthorityProjectionProbe", { authority: SharedTmuxGridAuthoritySnapshot ->
            assertTrue(Thread.holdsLock(c.field<Any>("tmuxTransportLock")))
            projected += authority; SharedTmuxClaimSettlement.Released(emptyList())
        })
        val event = SharedTmuxEvent(c.heldSnapshot(), emptyList(), emptyList(), emptyList())
        c.deliver(event, tmux)
        val before = h.submissions
        repeat(1000) { c.deliver(event, tmux) }
        assertEquals(before, h.submissions); assertTrue(projected.isEmpty())
        c.deliver(event.copy(authorityStamps = listOf("v1 ipad-id 4 iPad", "v1 ipad-id 5 iPad")), tmux)
        assertEquals(before + 1, h.submissions)
        assertEquals(listOf(SharedTmuxGridAuthoritySnapshot.Peer("ipad-id", "iPad", 5)), projected)
        repeat(1000) { c.deliver(event, tmux) }
        assertEquals(before + 1, h.submissions); assertEquals(1, projected.size)
        // A later read's unchanged edge (a new pane's first report) costs its one
        // reduction; the session's memo makes it a no-op, so nothing reprojects.
        val state = c.native.state
        repeat(1000) { c.deliver(event.copy(authorityStamps = listOf("v1 ipad-id 5 iPad")), tmux) }
        assertEquals(before + 1001, h.submissions); assertEquals(1, projected.size)
        assertEquals(state, c.native.state)
    }
    /**
     * §6.17: a runtime that hosts the session reduces a read's stamps inside
     * its feed and projects each verdict as it goes. The read's event carries
     * the session's result; applying it costs no call into the core at all.
     */
    @Test fun aStampTheRuntimeReducedIsAppliedWithoutAnyCallIntoTheCore() {
        val h = nativeAuthority(); val c = ready(h); c.replyTo(c.lastQuery(), OWN_STAMP)
        c.setField("tmuxCore", null)
        val tmux = c.field<SshTmuxConnection>("tmuxConnection")
        val projected = mutableListOf<SharedTmuxGridAuthoritySnapshot>()
        c.setField("tmuxAuthorityProjectionProbe", { authority: SharedTmuxGridAuthoritySnapshot ->
            projected += authority; SharedTmuxClaimSettlement.Released(emptyList())
        })
        val newPeer = SharedTmuxGridAuthoritySnapshot.Peer("ipad-id", "iPad", 5)
        // What the runtime does inside its feed, behind the adapter's back.
        val reduced = c.native.stampsObserved(scheduler.currentTime, listOf("v1 ipad-id 5 iPad"))
        val before = h.submissions
        c.deliver(SharedTmuxEvent(c.heldSnapshot(), emptyList(), emptyList(), emptyList(), authoritySession = reduced), tmux)
        assertEquals("no session call", before, h.submissions)
        assertEquals(1, h.adoptions)
        assertTrue("the runtime already projected it", projected.isEmpty())
        assertEquals(newPeer, c.field<SharedTmuxGridAuthoritySnapshot?>("lastProjectedTmuxAuthority"))
        val applied = c.field<SharedTmuxAuthoritySessionState?>("lastTmuxAuthorityResult")
        assertEquals(newPeer, applied?.authority)
        assertEquals(SharedTmuxAuthorityPresentation.Veiled("iPad"), applied?.presentation)
        assertEquals(newPeer, c.field<MutableStateFlow<SharedTmuxGridAuthoritySnapshot>>("mutableTmuxAuthority").value)
    }
    /**
     * The runtime reduced the read's session change and window facts at
     * their steps, inside the feed (§6.18): the adapter applies the result
     * and reports neither again, so the read the change asked for stands.
     */
    @Test fun aReadTheRuntimeReducedIsNotReducedAgain() {
        val h = nativeAuthority(); val c = ready(h)
        val tmux = c.field<SshTmuxConnection>("tmuxConnection")
        val moved = snapshot(peerGrid).copy(sessionId = 9)
        val now = scheduler.currentTime
        c.native.windowFacts(now, true, SharedTmuxAuthorityActiveWindow(5, peerGrid, true))
        val reduced = c.native.controlSessionChanged(now, false)
        val freshRead = checkNotNull(reduced.state.currentQueryId)
        c.deliver(
            SharedTmuxEvent(moved, emptyList(), emptyList(), emptyList(), authoritySession = reduced, authorityReducedInFeed = true),
            tmux,
        )
        val final = c.field<SharedTmuxAuthoritySessionState?>("lastTmuxAuthorityResult")
        assertEquals("not asked again", freshRead, final?.currentQueryId)
        assertEquals(freshRead, c.native.snapshot(now).currentQueryId)
        assertEquals(true to SharedTmuxAuthorityActiveWindow(5, peerGrid, true), c.field<Any?>("lastAuthorityWindowFacts"))
    }
    /**
     * A switch the runtime reduced at its step (reset, the new session's
     * facts, its attach read) is the adapter's to finish: the owner scope,
     * hydration, subscription and policy probe, but no second reset.
     */
    @Test fun aSwitchTheRuntimeReducedIsFinishedButNotReducedAgain() {
        val h = nativeAuthority(); val c = ready(h)
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); val tmux = c.field<SshTmuxConnection>("tmuxConnection")
        c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = c.heldSnapshot().copy(sessionId = 7)
        c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad"); assertEquals(peer, c.native.state.authority)
        wire.drainWire()
        val now = scheduler.currentTime
        c.native.controlSessionChanged(now, true)
        c.native.windowFacts(now, true, SharedTmuxAuthorityActiveWindow(5, viewport, false))
        val reduced = c.native.attached(now, "android-id")
        val attachRead = checkNotNull(reduced.state.currentQueryId)

        val switched = c.heldSnapshot().copy(sessionId = 9, isActiveWindowAuthoritative = false)
        c.deliver(SharedTmuxEvent(switched, emptyList(), emptyList(), emptyList(), authoritySession = reduced,
            authorityReducedInFeed = true, controlSessionSwitched = true), tmux)

        val sent = wire.drainWire()
        assertEquals(sent.toString(), 1, sent.count { it == "show-options -qv @tessera_authority" })
        assertEquals("the runtime's attach read", attachRead, c.lastQuery().sequence)
        assertEquals(attachRead, c.native.snapshot(now).currentQueryId)
        assertTrue(sent.toString(), sent.containsAll(SharedTmuxCommands.hydrationCommands()))
        assertEquals(baseSubscriptions.copy(authority = true), c.takeSubscriptions().last())
        assertTrue(sent.toString(), "show-options -wA -v -t @5 window-size" in sent)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, c.native.state.authority)
    }
    /**
     * A switch read the runtime reduced whose event was lost: the resync
     * that recovers its snapshot says the session holds it, so the adapter
     * does not reset the session again and drop the new session's verdict.
     */
    @Test fun aResyncTheSessionHoldsIsNoSwitch() {
        val h = nativeAuthority(); val c = ready(h)
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); val tmux = c.field<SshTmuxConnection>("tmuxConnection")
        c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = c.heldSnapshot().copy(sessionId = 7)
        wire.drainWire()
        val now = scheduler.currentTime
        c.native.controlSessionChanged(now, true)
        c.native.attached(now, "android-id")
        c.native.stampsObserved(now, listOf("v1 ipad-id 4 iPad"))
        assertEquals(peer, c.native.state.authority)

        c.deliver(SharedTmuxEvent(c.heldSnapshot().copy(sessionId = 9), emptyList(), emptyList(), emptyList(),
            authorityReducedInFeed = true), tmux)

        assertEquals("the new session's verdict stands", peer, c.native.state.authority)
        val sent = wire.drainWire()
        assertFalse("the switch's own event finishes it: $sent", sent.any { it in SharedTmuxCommands.hydrationCommands() })
        assertTrue(c.takeSubscriptions().isEmpty())
    }
    @Test fun presentationOnlyReductionsDoNotProjectAgainAndANewHandleDoes() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        val projected = mutableListOf<SharedTmuxGridAuthoritySnapshot>()
        c.setField("tmuxAuthorityProjectionProbe", { authority: SharedTmuxGridAuthoritySnapshot ->
            assertTrue(Thread.holdsLock(c.field<Any>("tmuxTransportLock")))
            projected += authority; SharedTmuxClaimSettlement.Released(emptyList())
        })
        c.shown(SharedTmuxAuthorityShowSource.SHOW)
        assertTrue(projected.isEmpty())
        c.observe(peer); assertEquals(listOf(peer), projected)
        c.apply(c.native.tick(0)); assertEquals(listOf(peer), projected)
        c.setField("lastProjectedTmuxAuthority", null)
        c.javaClass.getDeclaredMethod("projectTmuxRuntimeAuthority", SharedTmuxGridAuthoritySnapshot::class.java)
            .apply { isAccessible = true }.invoke(c, peer)
        assertEquals(listOf(peer, peer), projected)
    }

    @Test fun aNewerReductionDuringProjectionKeepsItsPresentation() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        val projected = mutableListOf<SharedTmuxGridAuthoritySnapshot>()
        c.setField("tmuxAuthorityProjectionProbe", { authority: SharedTmuxGridAuthoritySnapshot ->
            projected += authority
            c.apply(c.native.hidden(0))
            SharedTmuxClaimSettlement.Released(emptyList())
        })
        c.observe(peer)
        assertTrue(c.native.state.hidden)
        assertEquals(TmuxAuthorityPresentation.Resuming(), c.presentation())
        assertEquals(listOf(peer), projected)
        assertEquals(peer, c.field<Any>("lastProjectedTmuxAuthority"))
    }

    @Test fun typingIsRefusedForTheWholeResumeButMutationsOnlyWhileAPeerHolds() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); assertTrue(c.acceptsTerminalInput())
        c.shown(SharedTmuxAuthorityShowSource.SHOW)
        assertEquals(TmuxAuthorityPresentation.Resuming(), c.presentation()); assertFalse(c.acceptsTerminalInput()); assertNull(c.refusal())
        c.observe(peer); assertFalse(c.acceptsTerminalInput()); assertEquals("yielded", c.refusal())
        c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad"); assertFalse(c.acceptsTerminalInput()); assertEquals("yielded", c.refusal())
        c.finishNativeClaim(c.native.state.claim!!.generation)
        assertTrue(c.acceptsTerminalInput()); assertNull(c.refusal())
        c.observe(peer.copy(generation = 5)); c.reclaimTmuxGridAuthority()
        assertEquals("reclaiming", c.refusal()); assertFalse(c.acceptsTerminalInput())
    }
    @Test fun aShowClaimOverAPeerRefusesSelectionUntilItSettlesAsOnIOS() {
        val c = ready(); c.shown(SharedTmuxAuthorityShowSource.SHOW); c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad")
        assertEquals(TmuxAuthorityPresentation.Resuming(), c.presentation()); assertEquals("yielded", c.refusal())
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drain()
        assertFalse(c.selectWindow("@5")); assertTrue(wire.isEmpty)
        c.finishNativeClaim(c.native.state.claim!!.generation); wire.drain()
        assertNull(c.refusal()); assertTrue(c.selectWindow("@5"))
        assertTrue(wire.drainWire().last().startsWith("select-window -t "))
    }
    @Test fun theScreensTmuxCommandsObeyTheAgentRefusalWhileATapWaits() {
        for (holder in listOf(SharedTmuxGridAuthoritySnapshot.Unknown, SharedTmuxGridAuthoritySnapshot.Mine(2), peer)) {
            val c = ready(); c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad"); c.apply(c.native.resetTransport(0, true))
            c.apply(c.native.requestTakeBack(0))
            if (holder !is SharedTmuxGridAuthoritySnapshot.Peer) {
                // A reset may forget the projected peer while retaining the tap's captured baseline.
                c.apply(c.native.resetTransport(0, false)); c.observe(holder)
            }
            val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drain()
            assertEquals(TmuxAuthorityPresentation.Reclaiming("iPad", true), c.presentation())
            assertEquals(holder, c.native.state.authority)
            assertFalse("R2 retains the tapped peer as lastKnownHolder", c.acceptsTerminalInput())
            c.perform(SharedBackendCommand.RenameTmuxWindow("@5", "build")); assertEquals("reclaiming", c.refusal()); assertTrue(wire.isEmpty)
            c.cancelPendingTmuxAuthorityIntent(); c.factsAfterReset(); c.apply(c.native.attached(0, "android-id"))
            c.replyTo(c.lastQuery(), "v1 android-id 9 Pixel"); wire.drain()
            assertNull(c.native.state.claim); assertNull(c.refusal()); assertTrue(c.acceptsTerminalInput())
            c.perform(SharedBackendCommand.RenameTmuxWindow("@5", "build"))
            assertTrue(wire.drainWire().last().startsWith("rename-window -t @5 "))
        }
    }
    @Test fun aTakeBackActsOnlyForTheSessionOnScreenInAForegroundApp() {
        for (background in listOf(false, true)) {
            val c = ready(); c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad")
            if (background) c.setField("appForeground", false) else c.setField("presentationActive", false)
            val before = c.harness.submissions; val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drainWire()
            c.reclaimTmuxGridAuthority()
            c.perform(SharedBackendCommand.ReclaimTmuxGridAuthority(SharedTmuxGridAuthorityReason.USER))
            assertEquals(before, c.harness.submissions); assertNull(c.native.state.claim); assertTrue(wire.isEmpty)
            c.setField("appForeground", true); c.setField("presentationActive", true)
            c.reclaimTmuxGridAuthority()
            assertEquals(SharedTmuxAuthorityClaimReason.USER_TAKE_BACK, c.native.state.claim!!.reason)
            assertEquals(listOf(CLAIM_POLICY_READ, "select-window"), wire.drainWire())
        }
    }
    @Test fun aClaimResendsTheClientGridOnlyWhenTheLedgerSaysThisConnectionLacksIt() = withMainOnTestScheduler {
        val t = inlineTakeBack()
        t.take()
        val ledger = t.controller.clientSizeLedger()
        fun claim(size: SharedTmuxGridSize): List<TmuxControlCommand> {
            t.controller.setField("lastTmuxViewport", size)
            t.controller.apply(t.reducer.session.abort(scheduler.currentTime, t.reducer.claim!!.generation, SharedTmuxAuthorityAbortReason.SUPERSEDED))
            t.take()
            t.controller.apply(t.reducer.session.requestTakeBack(scheduler.currentTime))
            return t.take()
        }
        val first = claim(viewport)
        assertEquals(listOf(listOf("refresh-client -C 80,24"), listOf(CLAIM_POLICY_READ), listOf("select-window")), first.map { it.wireCommands })
        assertTrue(first[0].ledgerOwned)
        assertEquals(SharedTmuxRenderLedgerOptions.INLINE_CLIENT_SIZE_REPLAY_BELONGS_TO_CLAIM,
            ledger.optionHistory.last() and SharedTmuxRenderLedgerOptions.INLINE_CLIENT_SIZE_REPLAY_BELONGS_TO_CLAIM)
        assertEquals(listOf(CLAIM_POLICY_READ, "select-window"), claim(viewport).flatMap { it.wireCommands })
        assertEquals(listOf(SharedTmuxRenderFact.ClientSize(80, 24), SharedTmuxRenderFact.ClientSize(80, 24)),
            ledger.facts.filterIsInstance<SharedTmuxRenderFact.ClientSize>())
        val changed = SharedTmuxGridSize(100, 30)
        assertEquals(listOf("refresh-client -C 100,30", CLAIM_POLICY_READ, "select-window"), claim(changed).flatMap { it.wireCommands })
        assertEquals(listOf(CLAIM_POLICY_READ, "select-window"), claim(changed).flatMap { it.wireCommands })
        ledger.submit(SharedTmuxRenderFact.TransportAttached(SharedTmuxRenderProfile.Inline))
        assertEquals(listOf("refresh-client -C 100,30", CLAIM_POLICY_READ, "select-window"), claim(changed).flatMap { it.wireCommands })
    }
    @Test fun aClientSizeTmuxRejectedIsSentAgainByTheNextReplay() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        val ledger = c.clientSizeLedger(); val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drainWire()
        ledger.submit(SharedTmuxRenderFact.ClientSize(80, 24))
        assertEquals(listOf("refresh-client -C 80,24", "select-window"), wire.drainWire())
        ledger.rejected(viewport); ledger.submit(SharedTmuxRenderFact.ClientSize(80, 24))
        assertEquals(listOf("refresh-client -C 80,24", "select-window"), wire.drainWire())
    }
    @Test fun theFirstReplayAfterAnAttachAlwaysSendsItsClientSize() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drainWire()
        val ledger = c.clientSizeLedger(profile = null)
        c.reconcile()
        assertEquals(listOf(SharedTmuxRenderFact.ClientSize(80, 24)), ledger.facts)
        assertEquals("no transport yet", emptyList<String>(), wire.drainWire())
        assertTrue(c.attachRenderTransport(SharedTmuxRenderProfile.Inline))
        c.reconcile()
        assertEquals("withheld until the attach read", emptyList<String>(), wire.drainWire())
        c.factsAfterReset(); c.apply(c.native.attached(scheduler.currentTime, "android-id"))
        assertEquals(listOf("show-options -qv @tessera_authority"), wire.drainWire())
        c.replyTo(c.lastQuery(), OWN_STAMP)
        // The session's ADVERTISE effect does not make an attach take latest.
        assertEquals(listOf("refresh-client -C 80,24"), wire.drainWire())
        assertNull(c.native.state.claim)
        c.reconcile(); assertEquals(emptyList<String>(), wire.drainWire())
    }
    @Test fun anAttachSendsNoClientSizeBeforeItsAuthorityRead() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); val facts = c.probeRenderFacts()
        assertTrue(c.attachRenderTransport(SharedTmuxRenderProfile.Inline)); c.reconcile(true)
        assertTrue(facts.none { it is SharedTmuxRenderFact.ClientSize }); assertTrue(c.geometryWithheld())
    }
    @Test fun theAttachHoldChangesNothingForPathsThatAlreadyWaitedForTheRead() {
        val c = ready(); val before = c.native.state.geometryHold; c.attachRenderTransport(SharedTmuxRenderProfile.Inline)
        assertEquals(before, c.native.state.geometryHold); assertTrue(c.geometryWithheld())
    }
    @Test fun theTransportStartSizesNothingUntilItsReadWhateverReconcilesOnTheWay() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); val facts = c.probeRenderFacts()
        c.setField("initiallyRequestedTmuxRenderSurfaces", ConcurrentHashMap.newKeySet<String>())
        c.setField("declaredTmuxRenderSurfaces", emptyList<SharedTmuxSurfaceDeclaration>())
        assertTrue(c.startRenderTransport(c.field("tmuxConnection")))
        assertTrue(facts.none { it is SharedTmuxRenderFact.ClientSize }); assertNotNull(c.lastQuery())
    }
    @Test fun aSizeCheckedJustBeforeAnAttachIsJudgedAgainUnderTheLock() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        val lock = c.field<Any>("tmuxTransportLock"); var sent: Boolean? = null
        val resize = Thread { sent = c.javaClass.getDeclaredMethod("sendTmuxClientSize", SharedTmuxGridSize::class.java, Boolean::class.javaPrimitiveType!!).apply { isAccessible = true }.invoke(c, viewport, false) as Boolean }
        synchronized(lock) { resize.start(); awaitBlockedOn(resize, lock); c.attachRenderTransport(SharedTmuxRenderProfile.Inline) }
        resize.join(3000); assertFalse(resize.isAlive); assertEquals(false, sent)
    }
    @Test fun anAttachForAConnectionAlreadyReplacedChangesNothing() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        val ledger = c.clientSizeLedger(); ledger.facts.clear(); c.setField("lastPublishedTmuxSize", viewport)
        val before = c.harness.submissions; val tmux = c.field<SshTmuxConnection>("tmuxConnection")
        val replaced = unsafe.allocateInstance(SshTmuxConnection::class.java) as SshTmuxConnection
        assertFalse(c.attachRenderTransport(SharedTmuxRenderProfile.Inline, tmux, 7))
        assertFalse(c.attachRenderTransport(SharedTmuxRenderProfile.Inline, replaced, 8))
        assertFalse(c.startRenderTransport(replaced))
        assertEquals(before, c.harness.submissions); assertTrue(ledger.facts.isEmpty())
        assertEquals(SharedTmuxAuthorityGeometryHold.OWNER, c.native.state.geometryHold)
        assertEquals(viewport, c.field<SharedTmuxGridSize?>("lastPublishedTmuxSize"))
        assertTrue(c.attachRenderTransport(SharedTmuxRenderProfile.Inline, tmux, 8))
        assertEquals(listOf<SharedTmuxRenderFact>(SharedTmuxRenderFact.TransportAttached(SharedTmuxRenderProfile.Inline)), ledger.facts)
        assertTrue(c.geometryWithheld()); assertNull(c.field<SharedTmuxGridSize?>("lastPublishedTmuxSize"))
    }
    @Test fun aReadWhoseSendFailsIsRetriedLikeAFailedReply() {
        val c = ready(); c.setField("tmuxPlatformCommandProbe", { _: TmuxControlCommand -> false })
        c.shown(SharedTmuxAuthorityShowSource.SHOW); assertEquals(250L, c.native.state.nextDeadlineMillis)
        val before = c.harness.submissions; scheduler.advanceTimeBy(250); scheduler.runCurrent()
        assertTrue(c.harness.submissions > before); assertEquals(750L, c.native.state.nextDeadlineMillis)
    }
    @Test fun aReadAnsweredAfterTheSessionChangedIsAskedAgain() {
        val c = ready(); val first = c.lastQuery(); val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        assertNull(first.sessionId); assertEquals(listOf("show-options -qv @tessera_authority"), wire.drainWire())
        c.deliver(SharedTmuxEvent(c.heldSnapshot().copy(sessionId = 7), emptyList(), emptyList(), emptyList()), c.field("tmuxConnection"))
        val second = c.lastQuery(); assertTrue(second.sequence > first.sequence); assertEquals(7, second.sessionId)
        assertEquals(listOf("show-options -qv @tessera_authority"), wire.drainWire())
        c.replyTo(first, OWN_STAMP); assertTrue(c.geometryWithheld()); assertNull(c.native.state.claim)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, c.native.state.authority)
        c.replyTo(second, OWN_STAMP); assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
        assertFalse(c.geometryWithheld()); assertNull(c.native.state.claim)
    }
    @Test fun onlyOurOwnStampOrNoStampReleasesTheReadsHold() {
        for ((raw, withheld) in listOf(OWN_STAMP to false, "" to false, "v9 future" to true, "v1 ipad-id 4 iPad" to true)) {
            val c = ready(); val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
            assertEquals(listOf("show-options -qv @tessera_authority"), wire.drainWire())
            c.clientSizeLedger(); c.replyTo(c.lastQuery(), raw); c.reconcile()
            assertEquals(if (withheld) emptyList<String>() else listOf("refresh-client -C 80,24"), wire.drainWire())
            assertEquals(withheld, c.geometryWithheld()); assertNull(c.native.state.claim)
        }
    }
    @Test fun aNewWindowReplaysOnlyAGridTheLedgerHasNotAdvertised() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); c.clientSizeLedger(); val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drainWire()
        c.replayBeforeNewWindow(); assertEquals(listOf("refresh-client -C 80,24", "select-window"), wire.drainWire())
        c.replayBeforeNewWindow(); assertEquals(listOf("select-window"), wire.drainWire())
    }
    @Test fun theInlineReplayFencesOnlyWhereIOSWould() {
        val suppresses = SharedTmuxRenderLedgerOptions.SUPPRESSES_UNCHANGED_CLIENT_SIZE_REPLAY
        val pipelines = SharedTmuxRenderLedgerOptions.PIPELINES_VISIBLE_CAPTURE
        val belongs = SharedTmuxRenderLedgerOptions.INLINE_CLIENT_SIZE_REPLAY_BELONGS_TO_CLAIM
        val owner = ready(); owner.replyTo(owner.lastQuery(), OWN_STAMP)
        val ledger = owner.clientSizeLedger(); val wire = owner.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drainWire()
        owner.replayBeforeNewWindow(); assertEquals(listOf("refresh-client -C 80,24", "select-window"), wire.drainWire())
        owner.replayBeforeNewWindow(); assertEquals(listOf("select-window"), wire.drainWire())
        assertEquals(2, ledger.facts.filterIsInstance<SharedTmuxRenderFact.ClientSize>().size)
        assertEquals(suppresses or pipelines, ledger.optionHistory.last())
        val unstamped = ready(); unstamped.replyTo(unstamped.lastQuery(), "")
        val bareLedger = unstamped.clientSizeLedger(); val bareWire = unstamped.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); bareWire.drainWire()
        unstamped.reconcile(true); assertEquals(listOf("refresh-client -C 80,24"), bareWire.drainWire())
        unstamped.replayBeforeNewWindow(); assertTrue(bareWire.isEmpty)
        assertEquals(suppresses or pipelines or belongs, bareLedger.optionHistory.last())
        val claim = inlineTakeBack(); claim.take()
        val claimLedger = claim.controller.clientSizeLedger()
        claim.controller.publishClient(viewport, claim = true)
        assertEquals(listOf("refresh-client -C 80,24"), claim.take().flatMap { it.wireCommands })
        assertEquals(suppresses or pipelines or belongs, claimLedger.optionHistory.last())
        assertFalse(claim.controller.selectWindow("@5")); assertTrue(claim.take().isEmpty())
        val sideChannel = ready(); sideChannel.replyTo(sideChannel.lastQuery(), OWN_STAMP)
        sideChannel.setField("host", inlineHost.copy(transportKind = TransportKinds.MOSH))
        sideChannel.clientSizeLedger(SharedTmuxRenderProfile.SideChannel)
        val sideWire = sideChannel.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); sideWire.drainWire()
        sideChannel.replayBeforeNewWindow(); assertEquals(listOf("refresh-client -C 80,24"), sideWire.drainWire())
        sideChannel.replayBeforeNewWindow(); assertTrue(sideWire.isEmpty)
    }
    @Test fun refusedLedgerSwitchesAreLoggedOnceAndNotRetried() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); var switches = 0
        c.setField("tmuxRenderLedgerOptionsProbe", { _: Int -> switches++; false }); c.replayBeforeNewWindow(); c.replayBeforeNewWindow()
        assertEquals(1, switches); assertTrue(c.field<Boolean>("tmuxRenderLedgerOptionsRefused"))
    }
    @Test fun aTabSwitchNamesOurSessionAndTheClaimFenceNamesNoWindow() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drainWire()
        assertTrue(c.selectWindow("@5")); assertEquals(listOf("select-window -t @5"), wire.drainWire())
        c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = snapshot(viewport).copy(sessionId = 3)
        assertTrue(c.selectWindow("@5")); assertEquals(listOf("select-window -t '\$3:@5'"), wire.drainWire())
        val claim = inlineTakeBack(); val write = claim.takeFence()
        val fenceId = claim.reducer.session.state.claimFence!!.id
        assertEquals(TmuxResponsePurpose.AuthorityWindowSizePolicy(8, fenceId, 5), write.policy.purpose)
        assertEquals(listOf(8L, fenceId, 5L), listOf(write.purpose.generation, write.purpose.fenceId, write.purpose.windowId.toLong()))
        assertFalse(write.purpose.refence)
        assertTrue(claim.take().isEmpty()); assertEquals(8L, claim.controller.field<Long?>("authorityClaimWireGeneration"))
        claim.answerFence(write)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, claim.reducer.claim!!.phase)
    }
    @Test fun aThousandOutputEventsNeverReachTheAuthorityReducer() {
        val h = nativeAuthority(); val c = ready(h); c.replyTo(c.lastQuery(), OWN_STAMP)
        val tmux = c.field<SshTmuxConnection>("tmuxConnection"); c.setField("tmuxCore", null)
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drain()
        val facts = c.probeRenderFacts(); c.deliver(outputEvent(c.heldSnapshot(), 0), tmux)
        val before = h.submissions; repeat(1000) { c.deliver(outputEvent(c.heldSnapshot(), it.toLong() + 1), tmux) }
        assertEquals("1,000 output batches submit no session events or snapshots", before, h.submissions)
        assertTrue(wire.drain().isEmpty()); assertTrue(facts.isEmpty())
        assertEquals("every feed still reaches the painter", 1001, c.pendingRenderBatches())
    }
    @Test fun typingGateMakesNoJniCall() {
        val h = nativeAuthority(); val c = ready(h); c.replyTo(c.lastQuery(), OWN_STAMP); val before = h.submissions
        repeat(1000) { assertTrue(c.acceptsTerminalInput()) }; assertEquals(before, h.submissions)
        c.observe(peer); val gated = h.submissions; repeat(1000) { assertFalse(c.acceptsTerminalInput()) }; assertEquals(gated, h.submissions)
    }
    @Test fun aTapWithoutAChannelFormsAnIntentShownAsTakingControlWhenReconnected() {
        val c = controller(nativeAuthority()); c.apply(c.native.adoptShown(0)); c.observe(peer); c.apply(c.native.requestTakeBack(0))
        assertEquals(TmuxAuthorityPresentation.Reclaiming("iPad", true), c.presentation()); assertNull(c.native.state.claim)
    }
    @Test fun anAlreadyDueWakeKeepsTheNextNativeDeadlineRegistered() {
        val c = controller(nativeAuthority()); c.liveChannel()
        c.setField("scope", kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + Dispatchers.Unconfined))
        val query = c.native.attached(0, "android-id").effects.filterIsInstance<SharedTmuxAuthoritySessionEffect.QueryAuthority>().single()
        c.setField("authorityTime", { 250L })
        c.apply(c.native.queryFailed(0, query.queryId))
        assertEquals(5250L, c.native.state.nextDeadlineMillis)
        assertEquals(5250L, c.field<Long?>("authorityWakeDeadline"))
        assertTrue(c.field<kotlinx.coroutines.Job>("authorityWakeJob").isActive)
        assertEquals(listOf("show-options -qv @tessera_authority"), c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel").drainWire())
    }
    @Test fun aShowAtADueRetrySendsOnlyItsOwnRead() {
        // A show landing on a failed read's retry deadline, before the wake,
        // gets the retry and its own read in one batch. Only the session's
        // current read reaches the FIFO, as on iOS.
        val c = ready(); val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drainWire()
        // Liveness already reported, so the show is the deadline's first event.
        c.setField("lastAuthorityChannelLive", true)
        c.apply(c.native.queryFailed(scheduler.currentTime, c.lastQuery().sequence))
        val retryAt = checkNotNull(c.native.state.nextDeadlineMillis)
        c.setField("authorityTime", { retryAt })
        c.shown(SharedTmuxAuthorityShowSource.SHOW)
        assertEquals(listOf("show-options -qv @tessera_authority"), wire.drainWire())
        assertEquals(c.native.state.currentQueryId, c.lastQuery().sequence)
    }
    @Test fun aReadAnsweredPastItsOverdueBoundKeepsTheChannel() {
        // Any answer proves the queue moves: the overdue bound must not fire
        // on the reply that clears it, or a Mosh side channel that just
        // answered would be closed and reconnected.
        val h = nativeAuthority(); val c = ready(h); val read = c.lastQuery()
        c.setField("authorityTime", { 6_000L })
        c.replyTo(read, OWN_STAMP)
        assertTrue(h.effects.none { it == SharedTmuxAuthoritySessionEffect.ControlChannelUnresponsive })
        assertTrue(c.native.state.channelLive)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
    }
    @Test fun aSplitThatMovesTheCompactProjectionOntoTheOldWindowKeepsTheShow() {
        // The compact projection comes from the same snapshot as the window.
        // Submitted ahead of the window, a new projection equal to the *old*
        // window released the show's held own-stamp reply as "at our size":
        // the show ended without a claim and the window kept the split's grid.
        fun split(focusColumns: Int) = snapshot(SharedTmuxGridSize(140, 24)).let { held ->
            held.copy(windows = held.windows.map { window ->
                window.copy(layout = SharedTmuxLayoutNode.Split(horizontal = true, width = 140, height = 24, children = listOf(
                    SharedTmuxLayoutNode.Leaf(7, focusColumns, 24),
                    SharedTmuxLayoutNode.Leaf(8, 139 - focusColumns, 24, x = focusColumns + 1),
                )))
            })
        }
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        c.setField("tmuxGridPresentation", SharedTmuxGridPresentation.SINGLE_PANE)
        val splitSnapshot = split(100)
        val projected = c.javaClass.getDeclaredMethod("compactProjectedClientSize", SharedTmuxSnapshot::class.java, SharedTmuxGridSize::class.java)
            .apply { isAccessible = true }.invoke(c, splitSnapshot, viewport) as SharedTmuxGridSize
        assertNotEquals("the split must move the projection off the viewport", viewport, projected)
        assertNotEquals("and off the split window itself", SharedTmuxGridSize(140, 24), projected)
        val snapshots = c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot")
        // Before the split, a single pane at the grid the split will project.
        snapshots.value = snapshot(projected); c.facts()
        c.shown(SharedTmuxAuthorityShowSource.SHOW); c.replyTo(c.lastQuery(), OWN_STAMP)
        assertNotNull("own stamp off our grid, policy unknown: held", c.native.state.pendingIntent)
        snapshots.value = splitSnapshot; c.facts()
        assertNotNull("the split's facts must not resolve the show against the old window", c.native.state.pendingIntent)
        assertNull(c.native.state.claim)
        c.policyReply(5, "latest")
        assertNotNull("under latest the window is off our grid: the show claims", c.native.state.claim)
    }
    @Test fun anIntentExpiresAboutTwentySecondsAfterTheShow() {
        val c = controller(nativeAuthority()); c.shown(SharedTmuxAuthorityShowSource.SHOW)
        scheduler.advanceTimeBy(19999); scheduler.runCurrent(); assertNotNull(c.native.state.pendingIntent)
        scheduler.advanceTimeBy(1); scheduler.runCurrent(); assertNull(c.native.state.pendingIntent)
        assertEquals(TmuxAuthorityPresentation.None, c.presentation())
    }
    @Test fun cancellingAPendingIntentExpiresItNow() {
        val c = controller(nativeAuthority()); c.shown(SharedTmuxAuthorityShowSource.SHOW); c.cancelPendingTmuxAuthorityIntent()
        assertNull(c.native.state.pendingIntent); assertNull(c.native.state.nextDeadlineMillis)
    }
    @Test fun aStamplessPeerVerdictVeilsEvenWithoutANativeRuntime() {
        val c = controller(nativeAuthority()); c.apply(c.native.adoptShown(0)); c.observe(SharedTmuxGridAuthoritySnapshot.Peer("-", "another device", 0))
        assertEquals(TmuxAuthorityPresentation.Veiled("another device"), c.presentation()); assertFalse(c.acceptsTerminalInput())
    }
    @Test fun anIntentOverdueAfterDeepSleepExpiresBeforeTheWakeReadDecides() {
        val c = ready(); c.shown(SharedTmuxAuthorityShowSource.SHOW); val read = c.lastQuery()
        c.setField("authorityTime", { 30000L }); c.replyTo(read, "v1 ipad-id 4 iPad")
        assertNull(c.native.state.pendingIntent); assertNull(c.native.state.claim); assertEquals(peer, c.native.state.authority)
    }
    @Test fun anIntentStillInsideItsWindowIsDecidedByTheRead() {
        val c = ready(); c.shown(SharedTmuxAuthorityShowSource.SHOW); c.setField("authorityTime", { 19999L }); c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad")
        assertNotNull(c.native.state.claim); assertNull(c.native.state.pendingIntent)
    }
    @Test fun aHiddenTabWithholdsOrdinaryGeometryUntilItsShow() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); c.hidden(); val facts = c.probeRenderFacts(); c.reconcile(true)
        assertTrue(c.geometryWithheld()); assertTrue(facts.none { it is SharedTmuxRenderFact.ClientSize })
        c.shown(SharedTmuxAuthorityShowSource.SHOW); assertNotNull(c.native.state.pendingIntent)
    }
    @Test fun aStamplessReRaiseAfterAFreshOwnReadVeilsAgain() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); c.policyReply(5, "latest")
        fun layout(size: SharedTmuxGridSize) {
            c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = snapshot(size)
            c.facts()
            scheduler.advanceTimeBy(3000); scheduler.runCurrent()
        }
        layout(peerGrid)
        assertEquals(TmuxAuthorityPresentation.Veiled("another device"), c.presentation())
        val projection = c.field<Any>("lastProjectedTmuxAuthority")
        c.apply(c.native.tick(scheduler.currentTime))
        assertEquals(projection, c.field<Any>("lastProjectedTmuxAuthority"))
        layout(viewport)
        c.apply(c.native.foregrounded(scheduler.currentTime)); c.replyTo(c.lastQuery(), OWN_STAMP)
        assertEquals(TmuxAuthorityPresentation.None, c.presentation())
        layout(SharedTmuxGridSize(130, 45))
        assertEquals(TmuxAuthorityPresentation.Veiled("another device"), c.presentation())
        assertFalse(c.acceptsTerminalInput())
    }
    @Test fun aStamplessVerdictFromAReadIsProjectedIntoTheRuntime() {
        val c = ready(); c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = snapshot(peerGrid); c.facts(); c.policyReply(5, "latest"); c.replyTo(c.lastQuery(), OWN_STAMP)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Peer("-", "another device", 0), c.field<Any>("lastProjectedTmuxAuthority"))
    }
    @Test fun aHiddenTabProjectsResumingRatherThanAVeilUntilItsShowResolves() {
        val c = ready(); c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad")
        assertEquals(TmuxAuthorityPresentation.Veiled("iPad"), c.presentation())
        c.hidden(); assertEquals(TmuxAuthorityPresentation.Resuming(), c.presentation())
        c.observe(SharedTmuxGridAuthoritySnapshot.Peer("laptop-id", "Laptop", 6))
        assertEquals(TmuxAuthorityPresentation.Resuming(), c.presentation()); assertFalse(c.acceptsTerminalInput())
        c.shown(SharedTmuxAuthorityShowSource.SHOW)
        assertEquals(TmuxAuthorityPresentation.Resuming(), c.presentation())
        c.replyTo(c.lastQuery(), "v1 laptop-id 6 Laptop")
        assertEquals(TmuxAuthorityPresentation.Resuming(), c.presentation()); assertNotNull(c.native.state.claim)
        // A real native show starts a claim; its timeout may veil, not its own successful read.
        scheduler.advanceTimeBy(10_000); scheduler.runCurrent()
        assertFalse(c.presentation() is TmuxAuthorityPresentation.Resuming)
        assertFalse(c.acceptsTerminalInput())
    }
    @Test fun aTmuxLaunchThatDegradedToAPlainShellNeverResumesOrGates() {
        val c = controller(nativeAuthority()); c.setField("plainSshPainterActive", true); c.shown(SharedTmuxAuthorityShowSource.SHOW)
        assertEquals(TmuxAuthorityPresentation.None, c.presentation()); assertTrue(c.acceptsTerminalInput()); assertNull(c.native.state.pendingIntent)
    }
    @Test fun aShowBeforeTheLaunchDegradedIsDroppedWhenThePlainShellStarts() {
        val c = controller(nativeAuthority()); c.shown(SharedTmuxAuthorityShowSource.SHOW); c.setField("plainSshPainterActive", true); c.releaseForPlainShell()
        assertNull(c.native.state.pendingIntent); assertEquals(TmuxAuthorityPresentation.None, c.presentation()); assertTrue(c.acceptsTerminalInput())
    }
    @Test fun whileAnIntentWaitsForTheChannelTypingFlowsUnlessAPeerHolds() {
        for (holder in listOf(SharedTmuxGridAuthoritySnapshot.Unknown, SharedTmuxGridAuthoritySnapshot.Mine(2), peer)) {
            val c = controller(nativeAuthority()); c.observe(holder); c.shown(SharedTmuxAuthorityShowSource.SHOW)
            assertEquals(holder !is SharedTmuxGridAuthoritySnapshot.Peer, c.acceptsTerminalInput())
            assertEquals(TmuxAuthorityPresentation.Resuming(true), c.presentation())
            assertTrue(c.presentation().gatesInput)
            assertEquals(if (holder is SharedTmuxGridAuthoritySnapshot.Peer) "yielded" else null, c.refusal())
            c.liveChannel(); c.apply(c.native.attached(0, "android-id"))
            assertEquals(TmuxAuthorityPresentation.Resuming(), c.presentation()); assertFalse(c.acceptsTerminalInput())
            c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad"); assertFalse(c.acceptsTerminalInput())
            assertEquals("yielded", c.refusal())
        }
    }
    @Test fun anOwnStampOverAWindowOffOurSizeWaitsForTheWindowSizePolicy() {
        val c = ready(snapshot = snapshot(peerGrid)); c.replyTo(c.lastQuery(), OWN_STAMP)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, c.native.state.authority); c.policyReply(5, "latest")
        assertEquals(SharedTmuxGridAuthoritySnapshot.Peer("-", "another device", 0), c.native.state.authority)
    }
    @Test fun aKnownPolicyDecidesAMismatchAtOnceButOnlyForItsOwnWindow() {
        for ((policy, expected) in listOf(
            "latest" to SharedTmuxGridAuthoritySnapshot.Peer("-", "another device", 0),
            "manual" to SharedTmuxGridAuthoritySnapshot.Mine(2),
            "smallest" to SharedTmuxGridAuthoritySnapshot.Mine(2),
            "largest" to SharedTmuxGridAuthoritySnapshot.Mine(2),
        )) {
            val c = ready(snapshot = snapshot(peerGrid)); c.apply(c.native.windowSizePolicyReplied(0, 5, policy)); c.replyTo(c.lastQuery(), OWN_STAMP)
            assertEquals(expected, c.native.state.authority)
            assertEquals(policy == "latest", c.geometryWithheld())
        }
        for (policy in listOf("latest", "manual")) {
            val c = ready(snapshot = snapshot(peerGrid)); c.apply(c.native.windowSizePolicyReplied(0, 6, policy)); c.replyTo(c.lastQuery(), OWN_STAMP)
            assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, c.native.state.authority)
            assertTrue(c.geometryWithheld()); assertNull(c.native.state.claim)
        }
    }
    @Test fun aPolicyThatNeverLandsIsJudgedUnknownAtTheSafetyBound() {
        val c = ready(snapshot = snapshot(peerGrid)); c.replyTo(c.lastQuery(), OWN_STAMP); scheduler.advanceTimeBy(10000); scheduler.runCurrent()
        assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
    }
    @Test fun aReattachReadOverAnEarlierOwnedSizeIsOursWithoutWaitingForThePolicy() = withMainOnTestScheduler {
        // The native gate's Mosh side-channel drop: this device owned the
        // window through several grids, and the window still has an earlier
        // one (203x30, the pane grid) while the viewport is at the newest
        // (100x30, the Mosh view). Only a history, not the newest size alone,
        // knows 203x30 is ours.
        val window = SharedTmuxGridSize(203, 30); val newest = SharedTmuxGridSize(100, 30)
        val c = ready(snapshot = snapshot(newest), measured = newest); c.replyTo(c.lastQuery(), OWN_STAMP)
        for (size in listOf(SharedTmuxGridSize(200, 30), window, newest)) c.delivered(size)
        val snapshots = c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot")
        c.setField("tmuxCore", null); c.resetTransportAndReattach(); c.liveChannel()
        snapshots.value = snapshot(window).copy(isWindowListHydrated = false); c.factsAfterReset()
        c.apply(c.native.attached(scheduler.currentTime, "android-id"))
        val facts = c.probeRenderFacts()
        c.replyTo(c.lastQuery(), OWN_STAMP)
        assertNotEquals("held for the layout the reattach has not hydrated yet",
            SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
        assertTrue(c.geometryWithheld()); assertTrue(facts.none { it is SharedTmuxRenderFact.ClientSize })

        // Hydration: our earlier owned grid. No policy probe has answered.
        snapshots.value = snapshot(window); c.facts()
        assertEquals("judged at once, not held for the policy", SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
        assertEquals(TmuxAuthorityPresentation.None, c.presentation())
        assertTrue("the owner replays its newest grid over the owned edge: $facts",
            facts.any { it is SharedTmuxRenderFact.ClientSize && it.columns == 100 && it.rows == 30 })
    }
    @Test fun aReattachReadOverASizeWeNeverPublishedWaitsForThePolicyAndYieldsUnderLatest() = withMainOnTestScheduler {
        val foreign = SharedTmuxGridSize(160, 48); val newest = SharedTmuxGridSize(100, 30)
        val c = ready(snapshot = snapshot(newest), measured = newest)
        // Pushed before this device owned the window: not ours either.
        c.delivered(foreign)
        c.replyTo(c.lastQuery(), OWN_STAMP)
        for (size in listOf(SharedTmuxGridSize(200, 30), SharedTmuxGridSize(203, 30), newest)) c.delivered(size)
        val snapshots = c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot")
        c.setField("tmuxCore", null); c.resetTransportAndReattach(); c.liveChannel(); c.setField("windowSizePolicyWindowId", 5)
        snapshots.value = snapshot(foreign); c.factsAfterReset()
        c.apply(c.native.attached(scheduler.currentTime, "android-id"))
        c.replyTo(c.lastQuery(), OWN_STAMP)
        assertNotEquals("a size we never owned is no evidence yet", SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
        assertTrue("the reply stays held until the policy lands", c.geometryWithheld())

        c.policyReply(5, "latest")
        assertEquals(SharedTmuxGridAuthoritySnapshot.Peer("-", "another device", 0), c.native.state.authority)
        assertEquals(TmuxAuthorityPresentation.Veiled("another device"), c.presentation())
    }
    @Test fun aReattachReadWaitsForTmuxToNameTheActiveWindow() {
        val c = ready(snapshot = snapshot(viewport).copy(isActiveWindowAuthoritative = false)); c.replyTo(c.lastQuery(), OWN_STAMP)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, c.native.state.authority)
        c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = snapshot(viewport); c.facts()
        assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
    }
    @Test fun anOwnReadAtOurSizeWithNothingPendingRecordsThatGridAsOwned() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); c.setField("lastTmuxViewport", peerGrid); c.facts()
        c.apply(c.native.foregrounded(0)); c.replyTo(c.lastQuery(), OWN_STAMP)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
    }
    @Test fun theOwnedHistoryIsForgottenOnlyWhenTheControlClientChangesSession() {
        for (changed in listOf(false, true)) {
            val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); c.setField("lastTmuxViewport", peerGrid); c.facts()
            c.apply(c.native.controlSessionChanged(0, changed))
            // A switch resets the session; the adapter reports its facts and attaches again (§6.18).
            if (changed) { c.factsAfterReset(); c.apply(c.native.attached(0, "android-id")) }
            c.apply(c.native.windowSizePolicyReplied(0, 5, "latest")); c.apply(c.native.foregrounded(0)); c.replyTo(c.lastQuery(), OWN_STAMP)
            assertEquals(changed, c.native.state.authority is SharedTmuxGridAuthoritySnapshot.Peer)
        }
    }
    // Left to the adapter (a read fed from a callback): the runtime still names the switch.
    @Test fun aKnownSessionSwitchForgetsTheOldPeerAndReadsTheNewSessionOnce() = knownSessionSwitch(named = true)
    // A read whose event was lost: the recovered snapshot alone shows the switch.
    @Test fun aSwitchSeenOnlyInARecoveredSnapshotStillResets() = knownSessionSwitch(named = false)
    private fun knownSessionSwitch(named: Boolean) {
        val c = ready(); val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); val tmux = c.field<SshTmuxConnection>("tmuxConnection")
        c.deliver(SharedTmuxEvent(c.heldSnapshot().copy(sessionId = 7), emptyList(), emptyList(), emptyList()), tmux)
        c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad")
        assertEquals(peer, c.native.state.authority)
        wire.drainWire(); assertNull("the peer's read resolved", c.field<TmuxResponsePurpose.AuthorityRederive?>("pendingAuthorityQuery"))

        c.deliver(SharedTmuxEvent(c.heldSnapshot().copy(sessionId = 9), emptyList(), emptyList(), emptyList(), controlSessionSwitched = named), tmux)
        val read = c.lastQuery(); assertEquals(9, read.sessionId)
        val sent = wire.drainWire()
        assertEquals(sent.toString(), 1, sent.count { it == "show-options -qv @tessera_authority" })
        assertTrue(sent.toString(), sent.containsAll(SharedTmuxCommands.hydrationCommands()))
        assertEquals(baseSubscriptions.copy(authority = true), c.takeSubscriptions().last())
        assertTrue("the new session's policy is probed again: $sent", "show-options -wA -v -t @5 window-size" in sent)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, c.native.state.authority)

        c.replyTo(read, "")
        assertFalse(c.native.state.authority is SharedTmuxGridAuthoritySnapshot.Peer)
        assertFalse(c.geometryWithheld())
    }
    @Test fun aControllerNotYetShownReadsAuthorityButNeitherSizesTheGridNorVeils() {
        val c = controller(nativeAuthority()); c.liveChannel(); c.probeRenderFacts(); c.facts(); c.apply(c.native.attached(0, "android-id")); c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad")
        assertTrue(c.native.state.hidden); assertEquals(TmuxAuthorityPresentation.Resuming(), c.presentation()); assertTrue(c.geometryWithheld()); assertNull(c.native.state.claim)
    }
    @Test fun aReplacementKeepsTheOriginalTwentySecondShowWindow() = withStore { store, _ ->
        val old = controller(nativeAuthority()); store.open(key(), old)
        store.requestExplicitOpen("host")
        store.reportComposedDisplay("host", displayed = true, startEpoch = 0, explicitOpens = store.explicitOpenRequests.getValue("host"))
        advanceShowSettle()
        val stepAt = store.showClock()
        assertEquals(SharedTmuxAuthorityCarriedShow(SharedTmuxAuthorityShowSource.EXPLICIT_OPEN, stepAt), old.carriedShow())
        scheduler.advanceTimeBy(15000); scheduler.runCurrent(); old.setField("closed", true)
        val created = controller(nativeAuthority()); store.open(key("s2"), created)
        assertEquals(SharedTmuxAuthorityShowSource.EXPLICIT_OPEN, created.native.state.carriedShow!!.source)
        assertEquals(stepAt, created.native.state.carriedShow!!.stepAtMillis)
        val untilExpiry = stepAt + 20_000 - store.showClock()
        scheduler.advanceTimeBy(untilExpiry - 1); scheduler.runCurrent(); assertNotNull(created.native.state.pendingIntent)
        scheduler.advanceTimeBy(1); scheduler.runCurrent(); assertNull(created.native.state.pendingIntent)
    }
    @Test fun collapsedDimensionsNeverReachTheSharedSession() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); val prior = c.harness.submissions
        c.setField("lastTmuxViewport", SharedTmuxGridSize(3, 2)); c.facts()
        assertEquals(prior, c.harness.submissions); assertEquals(viewport, c.field<SharedTmuxGridSize>("lastAuthorityLocalSize"))
    }
    @Test fun aNewerPeerStampInvalidatesAHeldOwnReplyBeforeHydration() {
        val c = ready(snapshot = null); c.shown(SharedTmuxAuthorityShowSource.SHOW); c.replyTo(c.lastQuery(), OWN_STAMP)
        c.deliver(SharedTmuxEvent(snapshot(viewport), emptyList(), emptyList(), emptyList(), authorityStamps = listOf("v1 ipad-id 4 iPad")), c.field("tmuxConnection"))
        assertEquals(peer, c.native.state.authority); assertNull(c.native.state.claim)
    }

    @Test
    fun anInlineClaimConfirmsItsFenceOnlyOnceTheWindowIsAtOurGrid() = withMainOnTestScheduler {
        // tmux resizes the window for its new `latest` client after the
        // fence's burst, so the acknowledgement alone is no geometry: the
        // repaint the confirmation asks for would capture the peer's grid.
        // Under a policy other than `latest` the window never follows a
        // client, and the acknowledgement alone confirms, as on iOS.
        val takeBack = inlineTakeBack(window = peerGrid)
        takeBack.answerFence(takeBack.takeFence())
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim?.phase)
        assertEquals("nothing repainted at the peer's grid", 0, takeBack.repaints)

        takeBack.layout(viewport)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, takeBack.reducer.claim?.phase)
        assertEquals(1, takeBack.repaints)

        val manual = inlineTakeBack(window = peerGrid)
        manual.answerFence(manual.takeFence(), policy = "manual")
        assertEquals("manual: confirmed on the acknowledgement after this claim's own policy read", 1, manual.repaints)
        assertEquals("no settle probe where a size proves nothing", emptyList<String>(), manual.take().map { it.command })
    }

    @Test
    fun anInlineClaimConfirmsWhicheverOfItsFenceReplyAndItsLayoutArrivesFirst() = withMainOnTestScheduler {
        // The fence's reply reaches the adapter only when Main drains the
        // callback that carried it; tmux's resize for its new `latest` can
        // come in an earlier callback, in that one, between it and the drain,
        // or after. Each half confirms if it finds the other already there,
        // under the transport lock, so no order leaves a confirmation waiting
        // for an event that may never come (iOS lost one this way: deferred
        // inside control processing and drained only by its synchronous loop).
        for (order in listOf("layout first", "one callback", "layout before the drain", "reply drained first")) {
            val takeBack = inlineTakeBack(window = peerGrid)
            val write = takeBack.takeFence()
            takeBack.reply(write.policy, lines = listOf("latest"))
            val fence = write.fence
            when (order) {
                "layout first" -> {
                    takeBack.layout(viewport)
                    takeBack.reply(fence)
                }
                "one callback" -> takeBack.reply(fence, window = viewport)
                "layout before the drain" -> {
                    takeBack.queueReply(fence)
                    takeBack.layout(viewport)
                    assertEquals(order, 0, takeBack.repaints)
                    takeBack.drainCallbacks()
                }
                else -> {
                    takeBack.reply(fence)
                    assertEquals(order, 0, takeBack.repaints)
                    takeBack.layout(viewport)
                }
            }
            assertEquals(order, SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, takeBack.reducer.claim?.phase)
            assertEquals(order, 1, takeBack.confirmations)
            assertEquals(order, 1, takeBack.repaints)
            takeBack.repaintAnswered()
            assertEquals(
                order,
                listOf(SETTLE_SIZE_READ, OWN_STAMP_WRITE),
                takeBack.take().map { it.command },
            )
        }
    }

    @Test
    fun anInlineClaimWhoseWindowIsTakenAfterConfirmationFencesAgainBeforeItStamps() = withMainOnTestScheduler {
        // Another client takes tmux's `latest` after the claim confirmed (a
        // reconnect's attach, a laptop's keystroke): the repaint in flight
        // shows that client's grid, so it cannot authorize ours. The claim
        // fences once more instead of stamping, and stamps only at our grid.
        val takeBack = confirmedInlineTakeBack()
        takeBack.layout(peerGrid)
        // The layout itself fences again, so the fence rides alongside the
        // lost repaint's replies rather than waiting for them.
        val refence = takeBack.take()
        assertEquals(listOf("select-window"), refence.map { it.command })
        val purpose = refence.single().purpose as TmuxResponsePurpose.AuthorityClaimFence
        assertTrue("the core's one re-fence", purpose.refence)
        assertEquals("answered under the same fence", takeBack.reducer.session.state.claimFence?.id, purpose.fenceId)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim?.phase)

        takeBack.repaintAnswered()
        takeBack.reply(refence.single())
        assertEquals(
            "no stamp over another client's grid, only the re-fence's settle probe",
            listOf(SETTLE_SIZE_READ),
            takeBack.take().map { it.command },
        )
        assertEquals("nothing repainted until `latest` resizes the window back", 1, takeBack.repaints)

        // tmux applies the second fence's resize after its burst.
        takeBack.layout(viewport)
        assertEquals(2, takeBack.repaints)
        takeBack.repaintAnswered()
        assertEquals(listOf(OWN_STAMP_WRITE), takeBack.take().map { it.command })
        assertEquals("one fence takes `latest` back", 2, takeBack.fences)
    }

    @Test
    fun aStaleForeignLayoutAfterTheFenceNeitherAbortsNorLoopsTheClaim() = withMainOnTestScheduler {
        // M1: a peer's resize that tmux ran in the same server pass as our
        // fence reaches us after the fence's reply, with our fence's own
        // resize right behind it, and both ahead of the settle probe's
        // answer. Before that answer the geometry has not provably landed,
        // so the peer's layout only unsettles the claim: it costs no
        // re-fence, however late Main drains, and the window's return
        // confirms at once on the standing acknowledgement.
        val takeBack = confirmedInlineTakeBack(landed = false)
        takeBack.layout(peerGrid)
        assertEquals("unsettled, not lost", SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim?.phase)
        assertEquals("no re-fence", emptyList<String>(), takeBack.take().map { it.command })
        takeBack.repaintAnswered()
        assertEquals("the repaint of the peer's grid authorizes nothing", emptyList<String>(), takeBack.take().map { it.command })
        takeBack.layout(viewport)
        assertEquals("confirmed again on the standing acknowledgement", 2, takeBack.repaints)

        takeBack.answerSettleProbe(takeBack.probe, viewport)
        assertEquals(true, takeBack.reducer.claim?.geometryLanded)
        takeBack.repaintAnswered()
        assertEquals(listOf(OWN_STAMP_WRITE), takeBack.take().map { it.command })
        assertFalse(takeBack.reducer.calls.toString(), "abort" in takeBack.reducer.calls)
        assertEquals(false, takeBack.reducer.claim?.geometryRefenced)
        assertEquals(1, takeBack.fences)
    }

    @Test
    fun aForeignLayoutAfterTheSettleProbeLandedOurGeometryFencesAgainAtOnce() = withMainOnTestScheduler {
        // M1: tmux delivers our fence's own `%layout-change` before the
        // probe's replies, so a size the claim never advertised that comes
        // after the probe found the window at our grid is a peer's, decided
        // by the wire's order and not by Main's drain.
        val takeBack = confirmedInlineTakeBack()
        takeBack.layout(peerGrid)
        assertEquals(listOf("select-window"), takeBack.take().map { it.command })
        assertEquals(true, takeBack.reducer.claim?.geometryRefenced)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim?.phase)
    }

    @Test
    fun aSettleProbeAnswerIsJudgedInWireOrderDespiteALateMainDrain() = withMainOnTestScheduler {
        val lagging = confirmedInlineTakeBack(landed = false)
        lagging.queueReply(lagging.probe.single(), lines = listOf("tessera-window-size\t@5\t80\t24"))
        assertEquals("the probe landed on IO", true, lagging.reducer.claim?.geometryLanded)
        lagging.layout(peerGrid)
        assertEquals("landed, then a peer's size: fences again", listOf("select-window"), lagging.take().map { it.command })
        lagging.drainCallbacks()
        assertEquals(true, lagging.reducer.claim?.geometryRefenced)

        for (late in listOf(false, true)) for (laggingMain in listOf(false, true)) {
            val recovered = confirmedInlineTakeBack(landed = false)
            if (late) recovered.expirePresentation()
            recovered.layout(peerGrid)
            recovered.queueReply(recovered.probe.single(), window = peerGrid, lines = listOf("tessera-window-size\t@5\t100\t30"))
            if (!laggingMain) recovered.drainCallbacks()
            recovered.layout(viewport)
            recovered.drainCallbacks()
            val case = "late=$late laggingMain=$laggingMain"
            if (late) assertNull(case, recovered.reducer.claim)
            else {
                assertEquals("$case: the return cannot erase a loss", true, recovered.reducer.claim?.geometryRefenced)
                assertEquals(case, SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, recovered.reducer.claim?.phase)
                assertEquals(case, 2, recovered.repaints)
                recovered.repaintAnswered()
                assertEquals(case, listOf("select-window", OWN_STAMP_WRITE), recovered.take().map { it.command })
            }
        }
    }

    @Test
    fun moshClaimFencesEvenAtMatchingGeometryAndRejectsEachFailedMutation() = withMainOnTestScheduler {
        for (failedIndex in 0..2) {
            val t = inlineTakeBack(mosh = true, advertisedSideChannelSize = viewport)
            val begin = t.take()
            val mutations = begin.filter { it.purpose is TmuxResponsePurpose.WindowSizeReplayMutation }
            assertEquals(listOf("resize-window -x 80 -y 24 -t @5", "select-window",
                "set-option -w -u -t @5 window-size"), mutations.map { it.command })
            assertTrue("the ledger already acknowledged this connection's grid (P6)",
                begin.none { it.command.startsWith("refresh-client -C") })
            mutations.forEachIndexed { index, command -> t.reply(command, success = index != failedIndex) }
            assertEquals("failed mutation $failedIndex ends generation 8 and replays the gesture", 9L, t.reducer.claim?.generation)
            assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, t.reducer.claim?.phase)
            assertEquals(0, t.repaints)
            val retry = t.take()
            assertEquals(listOf("resize-window -x 80 -y 24 -t @5", "select-window", "set-option -w -u -t @5 window-size",
                CLAIM_POLICY_READ, "display-message -p ''"), retry.map { it.command })
            assertTrue(retry.filter { it.purpose is TmuxResponsePurpose.WindowSizeReplayMutation }.all { (it.purpose as TmuxResponsePurpose.WindowSizeReplayMutation).token != (mutations.first().purpose as TmuxResponsePurpose.WindowSizeReplayMutation).token })
            assertTrue(retry.none { it.command.startsWith("set-option @tessera_authority") })
        }
    }

    @Test
    fun moshClaimAtAMatchingLayoutForcesOnlyItsOwnWindow() = withMainOnTestScheduler {
        // A background window that already fits keeps its own window-size
        // policy: only the claim's window is forced at a matching layout,
        // and the take-back budget is sizing for the target window (§6.6).
        val t = inlineTakeBack(mosh = true, advertisedSideChannelSize = viewport, backgroundWindow = viewport)
        val mutations = t.take().filter { it.purpose is TmuxResponsePurpose.WindowSizeReplayMutation }
        assertEquals(listOf("resize-window -x 80 -y 24 -t @5", "select-window",
            "set-option -w -u -t @5 window-size"), mutations.map { it.command })
    }

    @Test
    fun moshClaimNeverForcesAMismatchingBackgroundWindow() = withMainOnTestScheduler {
        // D2/§6.6: a claim's sizing commands touch only its own window. A
        // background window at another grid keeps its size and window-size
        // policy, as on iOS; tmux sizes it when it becomes current.
        val t = inlineTakeBack(mosh = true, advertisedSideChannelSize = viewport,
            backgroundWindow = SharedTmuxGridSize(160, 48))
        val begin = t.take()
        val mutations = begin.filter { it.purpose is TmuxResponsePurpose.WindowSizeReplayMutation }
        assertEquals(listOf("resize-window -x 80 -y 24 -t @5", "select-window",
            "set-option -w -u -t @5 window-size"), mutations.map { it.command })
        assertTrue(begin.flatMap { it.wireCommands }.none { it.contains("@6") })
    }

    @Test
    fun moshClaimPublishesNewestControlSizeBeforeItsForceFence() = withMainOnTestScheduler {
        val newest = SharedTmuxGridSize(91, 29)
        val t = inlineTakeBack(window = peerGrid, measured = newest, mosh = true,
            advertisedSideChannelSize = viewport)
        val begin = t.take()
        val wire = begin.flatMap { it.wireCommands }
        assertEquals("refresh-client -C 91,29", wire.first())
        assertEquals(1, wire.count { it.startsWith("refresh-client -C") })
        assertTrue(wire.indexOf("refresh-client -C 91,29") < wire.indexOf("select-window"))
        assertTrue(t.facts.any { it is SharedTmuxRenderFact.ClientSize && it.columns == 91 && it.rows == 29 })
        assertEquals(newest, t.controller.field<SharedTmuxGridSize>("lastPublishedTmuxSize"))
        val mutations = begin.filter { it.purpose is TmuxResponsePurpose.WindowSizeReplayMutation }
        assertEquals(listOf("resize-window -x 91 -y 29 -t @5", "select-window",
            "set-option -w -u -t @5 window-size"), mutations.map { it.command })
        assertEquals(listOf(0, 1, 2), mutations.map { (it.purpose as TmuxResponsePurpose.WindowSizeReplayMutation).commandIndex })
    }

    @Test
    fun aLateMoshProbeReleasesRepaintBeforeCheckingForAStall() = withMainOnTestScheduler {
        val t = inlineTakeBack(window = peerGrid, mosh = true)
        val begin = t.take()
        val mutations = begin.filter { it.purpose is TmuxResponsePurpose.WindowSizeReplayMutation }
        assertEquals(3, mutations.size)
        val ordering = begin.single { it.purpose is TmuxResponsePurpose.AuthorityClaimFence }
        val policy = begin.single { it.purpose is TmuxResponsePurpose.AuthorityWindowSizePolicy }
        t.expirePresentation()
        mutations.forEach { t.reply(it) }
        // Its own read stays unanswered: the probe proves the force.
        assertTrue(t.take().single().purpose is TmuxResponsePurpose.WindowSizeReplayConfirmation)
        t.reply(policy, lines = listOf("latest"))
        t.reply(ordering)
        val probe = t.takeSettleProbe()
        t.layout(viewport)
        t.answerSettleProbe(probe, viewport)
        assertNotNull(t.reducer.claim)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, t.reducer.claim?.phase)
    }

    @Test
    fun aForeignProbeLossSurvivesAWindowReturnBeforeMainDrains() = withMainOnTestScheduler {
        for (mosh in listOf(false, true)) for (late in listOf(false, true)) for (lagging in listOf(false, true)) {
            val t = if (mosh) confirmedMoshTakeBack(landed = false) else confirmedInlineTakeBack(landed = false)
            if (late) t.expirePresentation()
            t.layout(peerGrid)
            if (lagging) {
                t.queueReply(t.probe.single(), window = peerGrid, lines = listOf("tessera-window-size\t@5\t100\t30"))
                t.layout(viewport)
                t.drainCallbacks()
            } else {
                t.answerSettleProbe(t.probe, peerGrid)
                t.layout(viewport)
            }
            val case = "mosh=$mosh late=$late lagging=$lagging"
            if (late) assertNull("$case: a landed foreign loss aborts", t.reducer.claim)
            else {
                assertEquals("$case: the probe observed a landed loss", true, t.reducer.claim?.geometryRefenced)
                assertEquals(case, if (mosh) SharedTmuxAuthorityClaimPhase.AWAITING_FENCE else SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, t.reducer.claim?.phase)
            }
        }
    }

    @Test
    fun coalescedWireRepliesAndLayoutsKeepTheSameLossVerdict() = withMainOnTestScheduler {
        for (probeAtPeer in listOf(false, true)) for (cut in listOf(0, 14, 45, 60)) {
            val t = confirmedInlineTakeBack(landed = false)
            if (probeAtPeer) t.layout(peerGrid)
            val callbacks = StringBuilder()
            val tags = t.probe.map { command ->
                val tag = t.nextReplyTag++
                t.controller.field<ConcurrentHashMap<Long, TmuxResponsePurpose>>("activeTmuxResponses")[tag] = command.purpose!!
                tag
            }
            var replyIndex = 0
            var inReply = false
            var lines = mutableListOf<String>()
            // Model the ABI's final-snapshot projection for one feed, while
            // replies retain their order within that projection's effect list.
            val reader = TmuxAuthorityWireFeed { bytes ->
                callbacks.append(bytes.decodeToString())
                val effects = mutableListOf<SharedTmuxRenderEffect>()
                var window = t.controller.heldSnapshot().activeWindow!!.layout!!.let { SharedTmuxGridSize(it.width, it.height) }
                while ('\n' in callbacks) {
                    val end = callbacks.indexOf("\n")
                    val line = callbacks.substring(0, end)
                    callbacks.delete(0, end + 1)
                    when {
                        line.startsWith("%begin ") -> { inReply = true; lines = mutableListOf() }
                        line.startsWith("%end ") -> {
                            inReply = false
                            effects += SharedTmuxRenderEffect.CommandReply(tags[replyIndex++], true, lines)
                        }
                        inReply -> lines += line
                        line.startsWith("%layout-change ") -> window = if (probeAtPeer) viewport else peerGrid
                    }
                }
                t.controller.deliver(SharedTmuxEvent(paneSnapshot(window), emptyList(), emptyList(), effects), t.tmux)
                com.bambouville.tessera.core.bridge.CoreCallResult.Accepted
            }
            val reported = if (probeAtPeer) peerGrid else viewport
            val wire = "%begin 2 2 1\n" +
                "tessera-window-size\t@5\t${reported.columns}\t${reported.rows}\n%end 2 2 1\n%layout-change @5 shape\n"
            for (part in listOf(wire.substring(0, cut), wire.substring(cut)).filter { it.isNotEmpty() }) {
                val bytes = part.encodeToByteArray()
                reader.feed(bytes, bytes.size, preserveGeometryOrder = true)
            }
            t.drainCallbacks()
            assertEquals("probeAtPeer=$probeAtPeer cut=$cut", true, t.reducer.claim?.geometryRefenced)
            assertEquals(if (probeAtPeer) SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT else SharedTmuxAuthorityClaimPhase.AWAITING_FENCE,
                t.reducer.claim?.phase)
        }
    }

    @Test
    fun aClientSizeIsAdvertisedBeforeItsEchoCanEnterTheTransportLock() = withMainOnTestScheduler {
        val t = confirmedInlineTakeBack()
        val resized = SharedTmuxGridSize(80, 18)
        t.controller.setField("lastTmuxViewport", resized)
        val lock = t.controller.field<Any>("tmuxTransportLock")
        var failure: Throwable? = null
        val echo = Thread {
            try { t.layout(resized) } catch (problem: Throwable) { failure = problem }
        }
        t.controller.setField("tmuxRenderFactProbe", { fact: SharedTmuxRenderFact ->
            if (fact is SharedTmuxRenderFact.ClientSize) {
                assertEquals("advertise before the synchronous fact callback", resized, t.reducer.claim?.targetGrid)
                assertNull("the old fence cannot confirm this new target", t.reducer.session.state.claimFence)
                t.layout(resized) // a synchronous fact echo, while Main holds the lock
                assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, t.reducer.claim?.phase)
                echo.start()
                awaitBlockedOn(echo, lock)
            }
            true
        })
        // Feed IO's echo immediately after admission returns, before any
        // caller-side bookkeeping could run. The send itself owns the record.
        val delivered = t.controller.javaClass.getDeclaredMethod("sendTmuxClientSize",
            SharedTmuxGridSize::class.java, Boolean::class.javaPrimitiveType!!)
            .apply { isAccessible = true }.invoke(t.controller, resized, false)
        echo.join(5_000)
        assertFalse("IO completed", echo.isAlive)
        failure?.let { throw it }
        assertEquals(true, delivered)
        assertEquals(resized, t.reducer.claim?.targetGrid)
        assertEquals(resized, t.controller.field<SharedTmuxGridSize?>("lastPublishedTmuxSize"))
        assertEquals(false, t.reducer.claim?.geometryRefenced)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, t.reducer.claim?.phase)
        assertNull("the old repaint cannot authorize the new grid", t.controller.field<InlineAuthorityRepaintFence>("inlineAuthorityRepaintFence").generation)
    }

    @Test
    fun realLateResizeAndPresentationChangesRetainOutstandingMoshAttempts() = withMainOnTestScheduler {
        for (change in listOf("resize", "presentation")) {
            val t = inlineTakeBack(window = peerGrid, mosh = true)
            val begin = t.take()
            val mutations = begin.filter { it.purpose is TmuxResponsePurpose.WindowSizeReplayMutation }
            val ordering = begin.single { it.purpose is TmuxResponsePurpose.AuthorityClaimFence }
            val policy = begin.single { it.purpose is TmuxResponsePurpose.AuthorityWindowSizePolicy }
            t.expirePresentation()
            mutations.forEach { t.reply(it) }
            val confirmation = t.take().single()
            assertTrue(confirmation.purpose is TmuxResponsePurpose.WindowSizeReplayConfirmation)
            val attempts = t.controller.field<ConcurrentHashMap<Int, PendingTmuxWindowSizeReplay>>("pendingTmuxWindowSizeReplays")
            val attempt = attempts[5]
            assertNotNull(attempt)
            val facts = t.facts.size
            if (change == "resize") t.controller.perform(SharedBackendCommand.Resize(80, 18))
            else t.controller.perform(SharedBackendCommand.SetTmuxGridPresentation(SharedTmuxGridPresentation.SINGLE_PANE))
            assertEquals(change, attempt, attempts[5])
            assertEquals(change, facts, t.facts.size)
            assertEquals(change, viewport, t.reducer.claim?.targetGrid)
            assertTrue(t.wire.isEmpty)
            if (change == "presentation") {
                // Back again: single-pane reconciliation projects through the
                // native core, which JVM tests cannot load.
                t.controller.perform(SharedBackendCommand.SetTmuxGridPresentation(SharedTmuxGridPresentation.PANE_GRID))
                assertEquals(change, attempt, attempts[5])
                assertEquals(change, facts, t.facts.size)
                assertTrue(t.wire.isEmpty)
            }
            t.reply(policy, lines = listOf("latest"))
            t.reply(ordering)
            val probe = t.takeSettleProbe()
            t.layout(viewport)
            t.reply(confirmation, lines = listOf("tessera-window-size\t@5\t80\t24"))
            t.answerSettleProbe(probe, viewport)
            assertEquals(change, SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, t.reducer.claim?.phase)
        }
    }

    @Test
    fun theMoshFencesOwnPolicyReadDecidesItsPreStampRead() = withMainOnTestScheduler {
        // The policy that waives the pre-stamp size check is the one the
        // claim's fence read for its window, never the ordinary cache: under
        // `latest` a foreign size aborts and replays; under a fixed policy the
        // window's size proves nothing, and the claim stamps.
        for (force in listOf(false, true)) for (policy in listOf("latest", "manual")) {
            val case = "force=$force policy=$policy"
            val t = inlineTakeBack(window = if (force) peerGrid else viewport, mosh = true)
            val begin = t.take()
            begin.filter { it.purpose is TmuxResponsePurpose.WindowSizeReplayMutation }.forEach { t.reply(it) }
            val confirmation = t.take().single()
            assertTrue(case, confirmation.purpose is TmuxResponsePurpose.WindowSizeReplayConfirmation)
            t.reply(begin.single { it.purpose is TmuxResponsePurpose.AuthorityWindowSizePolicy }, lines = listOf(policy))
            t.reply(begin.single { it.purpose is TmuxResponsePurpose.AuthorityClaimFence })
            if (policy == "latest") {
                val probe = t.takeSettleProbe()
                if (force) t.layout(viewport)
                t.reply(confirmation, lines = listOf("tessera-window-size\t@5\t80\t24"))
                t.answerSettleProbe(probe, viewport)
            } else {
                assertEquals("$case: confirmed on the acknowledgement, with no settle probe",
                    SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, t.reducer.claim?.phase)
                assertEquals(case, emptyList<String>(), t.take().map { it.command })
                t.reply(confirmation, lines = listOf("tessera-window-size\t@5\t80\t24"))
            }
            assertEquals(case, SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, t.reducer.claim?.phase)
            t.controller.setField("windowSizePolicyIsLatest", policy != "latest") // a stale cache
            t.controller.javaClass.getDeclaredMethod("finishLedgerAuthorityRepaint")
                .apply { isAccessible = true }.invoke(t.controller)
            val read = t.take().single()
            assertTrue(case, read.purpose is TmuxResponsePurpose.AuthorityPaintGeometry)
            assertTrue("$case: the pre-stamp read is the size query: ${read.command}", read.command.contains("'tessera-window-size"))
            t.reply(read, lines = listOf("tessera-window-size\t@5\t100\t30"))
            if (policy == "manual") {
                assertEquals(case, listOf(OWN_STAMP_WRITE), t.take().map { it.command })
                assertEquals(case, 8L, t.reducer.claim?.generation)
            } else {
                assertEquals(case, 9L, t.reducer.claim?.generation)
                assertEquals(case, SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, t.reducer.claim?.phase)
                val replay = t.take()
                assertEquals(case, listOf("resize-window -x 80 -y 24 -t @5", "select-window", "set-option -w -u -t @5 window-size",
                    CLAIM_POLICY_READ, "display-message -p ''"), replay.map { it.command })
                assertTrue("$case: no stamp over a stamp-less client's foreign grid",
                    replay.none { it.command.startsWith("set-option @tessera_authority") })
            }
        }
    }

    @Test
    fun aLocalResizeAfterConfirmationStampsOnlyOnceTheWindowFollows() = withMainOnTestScheduler {
        // M2: this device's grid changes after the claim confirmed (the
        // keyboard, a rotation, a compact reprojection). Its own size is
        // never a loss (§6.10 rule 3): the replay re-targets the claim,
        // which drops the repaint of the old grid and fences for the new one
        // at once, spending no re-fence, and stamps once the window follows.
        val takeBack = confirmedInlineTakeBack()
        val resized = SharedTmuxGridSize(80, 20)
        takeBack.controller.setField("lastTmuxViewport", resized)
        takeBack.controller.reconcile()
        assertEquals(SharedTmuxRenderFact.ClientSize(80, 20), takeBack.facts.last())
        val fence = takeBack.takeFence()
        assertEquals("the churn's own fence", 8L, fence.purpose.generation)
        assertFalse("a new fence, not the one re-fence", fence.purpose.refence)
        assertEquals(resized, takeBack.reducer.claim?.targetGrid)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim?.phase)

        takeBack.repaintAnswered()
        assertEquals("no stamp from a repaint of the old grid", emptyList<String>(), takeBack.take().map { it.command })
        // The old grid's layout, drained late, is our own: not a loss.
        takeBack.layout(viewport)
        assertEquals(false, takeBack.reducer.claim?.geometryRefenced)
        assertNotNull(takeBack.reducer.claim)

        takeBack.answerFence(fence)
        takeBack.takeSettleProbe()
        takeBack.layout(resized)
        assertEquals(2, takeBack.repaints)
        takeBack.repaintAnswered()
        assertEquals(listOf(OWN_STAMP_WRITE), takeBack.take().map { it.command })
        assertEquals(resized, takeBack.reducer.claim?.targetGrid)
        assertFalse(takeBack.reducer.calls.toString(), "abort" in takeBack.reducer.calls)
    }

    @Test
    fun aLateClaimKeepsItsTargetAndFinishesOnItsOwnReplies() = withMainOnTestScheduler {
        val takeBack = inlineTakeBack()
        val fence = takeBack.takeFence()
        takeBack.expirePresentation()
        assertNotNull("the deadline only hides while our fence is out", takeBack.reducer.claim)
        assertFalse(takeBack.reducer.claim!!.presentationVisible)
        takeBack.answerFence(fence)
        takeBack.answerSettleProbe(takeBack.takeSettleProbe(), viewport)
        takeBack.admitFeeds()
        takeBack.queueRepaintAnswer()
        takeBack.drainCallbacks()
        assertEquals(listOf(OWN_STAMP_WRITE), takeBack.take().map { it.command })
        takeBack.settle()
        assertNull(takeBack.reducer.claim)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(8), takeBack.controller.field<MutableStateFlow<SharedTmuxGridAuthoritySnapshot>>("mutableTmuxAuthority").value)
    }

    @Test
    fun theDeadlineEndsTheReclaimFlagOfAClaimStillLive() = withMainOnTestScheduler {
        val takeBack = inlineTakeBack()
        val reclaiming = takeBack.controller.field<MutableStateFlow<Boolean>>("mutableTmuxReclaimInFlight")
        assertTrue(reclaiming.value)
        takeBack.takeFence()
        takeBack.expirePresentation()
        assertNotNull(takeBack.reducer.claim)
        assertFalse(reclaiming.value)
    }

    @Test fun theReclaimFlagIsTheSessionsVisibleClaim() {
        val c = ready(); c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad"); c.observe(peer)
        val reclaiming = c.field<MutableStateFlow<Boolean>>("mutableTmuxReclaimInFlight")
        assertFalse(reclaiming.value)
        c.reclaimTmuxGridAuthority()
        assertTrue(c.native.state.claim!!.presentationVisible); assertTrue(reclaiming.value)
        c.finishNativeClaim(c.native.state.claim!!.generation)
        assertNull(c.native.state.claim); assertFalse("settled", reclaiming.value)

        c.observe(peer.copy(generation = 5)); c.reclaimTmuxGridAuthority()
        assertTrue(c.native.state.claim!!.presentationVisible); assertTrue(reclaiming.value)
        c.apply(c.native.resetTransport(scheduler.currentTime, true))
        assertNull(c.native.state.claim); assertFalse("reset", reclaiming.value)
    }

    @Test
    fun lateRotationKeyboardAndCompactChurnAdvertiseNothingInlineOrMosh() = withMainOnTestScheduler {
        for (mosh in listOf(false, true)) {
            val takeBack = inlineTakeBack(mosh = mosh)
            takeBack.take() // its own unanswered fence remains in flight
            takeBack.expirePresentation()
            val advertised = takeBack.reducer.claim!!.advertisedGrids
            val facts = takeBack.facts.size
            for ((grid, compact) in listOf(
                SharedTmuxGridSize(120, 35) to false,
                SharedTmuxGridSize(80, 18) to false,
                SharedTmuxGridSize(60, 20) to true,
            )) {
                takeBack.controller.setField("lastTmuxViewport", grid)
                if (compact) {
                    // The projection already computed this grid. The claim
                    // gate is below that shared projection (which is JNI).
                    takeBack.controller.javaClass.getDeclaredMethod(
                        "publishTmuxClientSize", SharedTmuxGridSize::class.java, Boolean::class.javaPrimitiveType!!,
                        Boolean::class.javaPrimitiveType!!, java.lang.Long::class.java,
                    ).apply { isAccessible = true }.invoke(takeBack.controller, grid, false, true, null)
                } else takeBack.controller.reconcile(forceAllWindows = true)
                takeBack.controller.sendClaimFence(8) // pending-size/explicit fence entry is gated too
            }
            assertEquals("mosh=$mosh: no new geometry fact", facts, takeBack.facts.size)
            assertEquals("mosh=$mosh: no fence or window force", emptyList<String>(), takeBack.take().map { it.command })
            assertEquals(advertised, takeBack.reducer.claim!!.advertisedGrids)
            assertEquals(viewport, takeBack.reducer.claim!!.targetGrid)
            assertTrue(takeBack.controller.field<SharedTmuxAuthoritySessionState>("lastTmuxAuthorityResult").claimMayAdvertiseGeometry.not())
        }
    }

    @Test
    fun lateChurnReplaysOnlyAfterSettlementAsAnOrdinaryOwnerResize() = withMainOnTestScheduler {
        val takeBack = confirmedInlineTakeBack()
        takeBack.expirePresentation()
        val keyboard = SharedTmuxGridSize(80, 18)
        takeBack.controller.setField("lastTmuxViewport", keyboard)
        takeBack.controller.reconcile()
        assertEquals(emptyList<String>(), takeBack.take().map { it.command })
        takeBack.repaintAnswered()
        assertEquals(listOf(OWN_STAMP_WRITE), takeBack.take().map { it.command })
        assertEquals(viewport, takeBack.reducer.claim?.targetGrid)
        takeBack.settle()
        assertEquals(SharedTmuxRenderFact.ClientSize(80, 18), takeBack.facts.last())
        assertEquals(SharedTmuxAuthorityGeometryHold.OWNER, takeBack.controller.field<SharedTmuxAuthoritySessionState>("lastTmuxAuthorityResult").geometryHold)
        assertEquals(0, takeBack.controller.field<Int>("authorityClaimCommandsInFlight"))
    }

    @Test
    fun twoKeyboardFramesAndTheirOldEchoesNeverSpendTheLossRefence() = withMainOnTestScheduler {
        for (mosh in listOf(false, true)) {
            val takeBack = if (mosh) confirmedMoshTakeBack() else confirmedInlineTakeBack()
            for (grid in listOf(SharedTmuxGridSize(80, 22), SharedTmuxGridSize(80, 20))) {
                takeBack.controller.setField("lastTmuxViewport", grid)
                takeBack.controller.reconcile()
                val sent = takeBack.take()
                assertTrue("mosh=$mosh: a churn fence", sent.any { it.purpose is TmuxResponsePurpose.ClaimCommand })
                assertEquals(grid, takeBack.reducer.claim!!.targetGrid)
                assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim!!.phase)
                takeBack.layout(viewport)
                assertFalse(takeBack.reducer.claim!!.geometryRefenced)
            }
            assertEquals(listOf(viewport, SharedTmuxGridSize(80, 22), SharedTmuxGridSize(80, 20)), takeBack.reducer.claim!!.advertisedGrids)
        }
    }

    @Test
    fun aForeignProbeAnswerCountsEvenBeforeItsLayoutNotification() = withMainOnTestScheduler {
        val takeBack = confirmedInlineTakeBack(landed = false)
        // The held layout is older than this answer. Never replace the answer
        // with that stale target, or the claim misses the landed loss.
        takeBack.answerSettleProbe(takeBack.probe, peerGrid)
        assertTrue(takeBack.reducer.claim!!.geometryRefenced)
        assertEquals(listOf("select-window"), takeBack.take().map { it.command })
        takeBack.repaintAnswered()
        assertEquals(emptyList<String>(), takeBack.take().map { it.command })
    }

    @Test
    fun aFenceWritesItsSettleProbeSeparatelyAndOldProbesCannotLandNewChurn() = withMainOnTestScheduler {
        val takeBack = inlineTakeBack()
        val fence = takeBack.takeFence()
        assertTrue(takeBack.wire.isEmpty)
        takeBack.reply(fence.policy, lines = listOf("latest"))
        takeBack.queueReply(fence.fence)
        assertTrue("IO queues the reply; no probe before Main handles the ack", takeBack.wire.isEmpty)
        takeBack.drainCallbacks()
        val probe = takeBack.takeSettleProbe()
        val keyboard = SharedTmuxGridSize(80, 20)
        takeBack.controller.setField("lastTmuxViewport", keyboard)
        takeBack.controller.reconcile()
        val nextFence = takeBack.takeFence()
        takeBack.answerSettleProbe(probe, peerGrid)
        assertFalse("older probe proves nothing about the re-target", takeBack.reducer.claim!!.geometryLanded)
        assertFalse(takeBack.reducer.claim!!.geometryRefenced)
        takeBack.answerFence(nextFence)
        takeBack.layout(keyboard)
        takeBack.answerSettleProbe(takeBack.takeSettleProbe(), keyboard)
        assertTrue(takeBack.reducer.claim!!.geometryLanded)
    }

    @Test
    fun aLateForeignLossAbortsWithoutAnyNewFenceOrStamp() = withMainOnTestScheduler {
        val takeBack = confirmedInlineTakeBack()
        takeBack.expirePresentation()
        takeBack.layout(peerGrid)
        assertNull(takeBack.reducer.claim)
        takeBack.repaintAnswered()
        assertEquals(emptyList<String>(), takeBack.take().map { it.command })
        assertNull(takeBack.reducer.session.state.carriedShow)
    }

    @Test
    fun aLateClaimEndsWhenItsLastOwnReplyLeavesNothingToProgress() = withMainOnTestScheduler {
        val takeBack = inlineTakeBack(window = peerGrid)
        val fence = takeBack.takeFence()
        takeBack.expirePresentation()
        assertNotNull(takeBack.reducer.claim)
        takeBack.answerFence(fence)
        val probe = takeBack.takeSettleProbe()
        assertNotNull("one own reply is still on the wire", takeBack.reducer.claim)
        takeBack.reply(probe.single(), success = false)
        assertEquals(9L, takeBack.reducer.claim?.generation)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim?.phase)
        assertTrue(takeBack.reducer.calls.toString(), "claimStalled:false" in takeBack.reducer.calls)
        assertEquals(listOf(CLAIM_POLICY_READ, "select-window"), takeBack.take().map { it.command })
        assertEquals(2, takeBack.controller.field<Int>("authorityClaimCommandsInFlight"))
    }

    @Test
    fun aViewportNeverMeasuredAndALateWindowMoveEndWithoutAdvertising() = withMainOnTestScheduler {
        val unmeasured = inlineTakeBack(measured = null)
        assertEquals("no fence before the claim has a grid to ask for", emptyList<String>(), unmeasured.take().map { it.command })
        unmeasured.expirePresentation()
        assertEquals(9L, unmeasured.reducer.claim?.generation)
        assertNull(unmeasured.reducer.claim?.targetGrid)
        assertEquals(emptyList<String>(), unmeasured.take().map { it.command })
        val moved = inlineTakeBack(window = peerGrid)
        moved.take()
        moved.expirePresentation()
        moved.moveTo(6, viewport)
        assertEquals(9L, moved.reducer.claim?.generation)
        val replay = moved.takeFence(policyRead = "show-options -wA -v -t @6 window-size")
        assertEquals(9L, replay.purpose.generation)
        assertEquals(6, replay.purpose.windowId)
    }

    @Test
    fun repaintFailureRetriesWhileVisibleAndEndsWhenLate() = withMainOnTestScheduler {
        for (late in listOf(false, true)) {
            val takeBack = confirmedInlineTakeBack()
            if (late) takeBack.expirePresentation()
            takeBack.queueRender(SharedTmuxRenderEffect.RefreshFailed(TMUX_RENDER_LIVE_SURFACE_ID, 8, "retries-exhausted"))
            takeBack.drainCallbacks()
            assertEquals("late=$late", if (late) 9L else 8L, takeBack.reducer.claim?.generation)
            assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim?.phase)
            assertEquals(listOf(CLAIM_POLICY_READ, "select-window"), takeBack.take().map { it.command })
        }
    }

    @Test
    fun aClaimReadsItsOwnPolicyRatherThanWaivingGeometryWithTheCachedOne() = withMainOnTestScheduler {
        val takeBack = inlineTakeBack(window = peerGrid)
        takeBack.controller.setField("windowSizePolicyIsLatest", false) // stale manual cache
        takeBack.answerFence(takeBack.takeFence(), policy = "latest")
        assertEquals(0, takeBack.repaints)
        takeBack.answerSettleProbe(takeBack.takeSettleProbe(), peerGrid)
        assertTrue(takeBack.reducer.claim!!.geometryRefenced)
        assertEquals(0, takeBack.repaints)
    }

    @Test
    fun onlyTheCurrentFencesOwnPolicyReadWaivesGeometry() = withMainOnTestScheduler {
        // The ordinary cache, another window's, another claim's and an
        // earlier fence's reads never waive this fence's geometry, including
        // after the viewport goes and comes back (A→B→A): each fence of a
        // claim reads its own window's policy.
        val t = inlineTakeBack(window = peerGrid)
        val first = t.takeFence()
        t.controller.setField("windowSizePolicyIsLatest", false) // a cached manual
        assertFalse("a cached policy waives nothing", t.policyIsFixed(5, 8))
        for (grid in listOf(SharedTmuxGridSize(80, 20), viewport)) {
            t.controller.setField("lastTmuxViewport", grid)
            t.controller.reconcile()
        }
        assertEquals(viewport, t.reducer.claim?.targetGrid)
        val fenceId = t.reducer.session.state.claimFence!!.id
        assertNotEquals(first.purpose.fenceId, fenceId)
        val current = t.take().filter {
            (it.purpose as? TmuxResponsePurpose.AuthorityWindowSizePolicy)?.fenceId == fenceId ||
                (it.purpose as? TmuxResponsePurpose.AuthorityClaimFence)?.fenceId == fenceId
        }
        assertEquals(listOf(CLAIM_POLICY_READ, "select-window"), current.map { it.command })

        t.answerFence(first, policy = "smallest")
        assertNull("an earlier fence's read is not this fence's", t.reducer.session.state.claimFence?.policyIsLatest)
        assertFalse(t.policyIsFixed(5, 8))
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, t.reducer.claim?.phase)

        t.reply(current[0], lines = listOf("smallest"))
        assertTrue(t.policyIsFixed(5, 8))
        assertFalse("another window's", t.policyIsFixed(6, 8))
        assertFalse("another claim's", t.policyIsFixed(5, 7))
        t.reply(current[1])
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, t.reducer.claim?.phase)
        assertEquals(1, t.confirmations)
    }

    @Test
    fun aFixedPolicyMoshClaimKeepsTheGridItsForceFindsAndWaitsForItsFrame() = withMainOnTestScheduler {
        // smallest/largest may keep the window off the grid this client
        // asked for: the force's confirmation completes at whatever size it
        // reports, and the claim confirmed on its acknowledgement still waits
        // for its own native frame.
        val t = inlineTakeBack(window = peerGrid, mosh = true)
        val begin = t.take()
        begin.filter { it.purpose is TmuxResponsePurpose.WindowSizeReplayMutation }.forEach { t.reply(it) }
        val confirmation = t.take().single()
        assertTrue(confirmation.purpose is TmuxResponsePurpose.WindowSizeReplayConfirmation)
        t.reply(begin.single { it.purpose is TmuxResponsePurpose.AuthorityWindowSizePolicy }, lines = listOf("smallest"))
        t.reply(begin.single { it.purpose is TmuxResponsePurpose.AuthorityClaimFence })
        assertEquals("confirmed on the acknowledgement with its force still out",
            SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, t.reducer.claim?.phase)
        assertEquals(emptyList<String>(), t.take().map { it.command })

        t.reply(confirmation, lines = listOf("tessera-window-size\t@5\t100\t30"))
        assertTrue(t.controller.field<ConcurrentHashMap<Int, PendingTmuxWindowSizeReplay>>("pendingTmuxWindowSizeReplays").isEmpty())
        assertEquals(8L, t.reducer.claim?.generation)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, t.reducer.claim?.phase)
        assertEquals(8L, t.controller.field<Long?>("pendingAuthorityRepaintGeneration"))
        assertFalse(t.reducer.calls.toString(), "abort" in t.reducer.calls)
    }

    @Test
    fun aMoshClaimRetargetedBeforeItsForceAnswersWaitsForTheNewGrid() = withMainOnTestScheduler {
        // Local churn re-targets a claim whose first force and fence are
        // still out. Their replies belong to a grid the claim no longer asks
        // for: they confirm nothing, and the new grid's own fence does.
        val t = inlineTakeBack(window = peerGrid, mosh = true)
        val begin = t.take()
        val oldFenceId = t.reducer.session.state.claimFence!!.id
        val resized = SharedTmuxGridSize(80, 20)
        t.controller.setField("lastTmuxViewport", resized)
        t.controller.reconcile()
        assertEquals(resized, t.reducer.claim?.targetGrid)
        val churn = t.take()
        assertNotEquals(oldFenceId, t.reducer.session.state.claimFence!!.id)

        begin.forEach { t.reply(it, lines = if (it.purpose is TmuxResponsePurpose.AuthorityWindowSizePolicy) listOf("latest") else emptyList()) }
        assertEquals("the old grid's force and fence confirm nothing", emptyList<String>(), t.take().map { it.command })
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, t.reducer.claim?.phase)
        assertNull(t.reducer.session.state.claimFence?.acknowledged?.takeIf { it })

        val mutations = churn.filter { it.purpose is TmuxResponsePurpose.WindowSizeReplayMutation }
        assertEquals(listOf("resize-window -x 80 -y 20 -t @5", "select-window", "set-option -w -u -t @5 window-size"),
            mutations.map { it.command })
        mutations.forEach { t.reply(it) }
        val confirmation = t.take().single()
        assertTrue(confirmation.purpose is TmuxResponsePurpose.WindowSizeReplayConfirmation)
        t.reply(churn.single { it.purpose is TmuxResponsePurpose.AuthorityWindowSizePolicy }, lines = listOf("latest"))
        t.reply(churn.single { it.purpose is TmuxResponsePurpose.AuthorityClaimFence })
        val probe = t.takeSettleProbe()
        t.layout(resized)
        t.reply(confirmation, lines = listOf("tessera-window-size\t@5\t80\t20"))
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, t.reducer.claim?.phase)
        t.answerSettleProbe(probe, resized)
        assertEquals(true, t.reducer.claim?.geometryLanded)
        assertEquals(1, t.confirmations)
    }

    @Test
    fun aMoshForceWhoseConfirmationReadAnotherSizeStaysUnprovedUntilTheSettleProbe() = withMainOnTestScheduler {
        // As iOS keeps it: the confirmation can run before the unset's
        // recalculation lands, so its size is no claim evidence, and the
        // force stays unproved with nothing of its own left on the wire. The
        // settle probe, which reads the window after it, proves it.
        val t = inlineTakeBack(window = peerGrid, mosh = true)
        val begin = t.take()
        begin.filter { it.purpose is TmuxResponsePurpose.WindowSizeReplayMutation }.forEach { t.reply(it) }
        val confirmation = t.take().single()
        assertTrue(confirmation.purpose is TmuxResponsePurpose.WindowSizeReplayConfirmation)
        // Under the fence's own `latest`, where a size is claim evidence.
        t.reply(begin.single { it.purpose is TmuxResponsePurpose.AuthorityWindowSizePolicy }, lines = listOf("latest"))
        val foreign = SharedTmuxGridSize(90, 28)
        t.reply(confirmation, lines = listOf("tessera-window-size\t@5\t${foreign.columns}\t${foreign.rows}"))
        val attempts = t.controller.field<ConcurrentHashMap<Int, PendingTmuxWindowSizeReplay>>("pendingTmuxWindowSizeReplays")
        assertEquals(true, attempts[5]?.confirmationAnswered)
        assertNotEquals("the read is not an observation", foreign,
            t.controller.field<Pair<*, SharedTmuxGridSize>?>("lastAuthorityClaimObservation")?.second)
        assertEquals(emptyList<String>(), t.take().map { it.command })
        assertFalse(t.reducer.calls.toString(), "abort" in t.reducer.calls)

        t.reply(begin.single { it.purpose is TmuxResponsePurpose.AuthorityClaimFence })
        val probe = t.takeSettleProbe()
        assertEquals(true, t.reducer.session.state.claimFence?.forceOutstanding)
        t.layout(viewport)
        assertEquals("a layout at the target does not prove the force under latest",
            SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, t.reducer.claim?.phase)
        t.answerSettleProbe(probe, viewport)
        assertTrue(attempts.isEmpty())
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, t.reducer.claim?.phase)
        assertEquals(true, t.reducer.claim?.geometryLanded)
        assertEquals(1, t.confirmations)
    }

    @Test
    fun aFenceWaitingForTheWindowListKeepsALateClaimUntilItsGridIsOrdered() = withMainOnTestScheduler {
        // I3: the claim's `-C` is on the wire when its fence waits for tmux
        // to name the current window. A no-op behind it keeps a late claim
        // from ending before tmux processed its own geometry, as on iOS. A
        // late claim fences no window it learns of later (rule 2), so with
        // nothing else of its own out, the no-op's reply ends it (rule 6).
        for (named in listOf(false, true)) {
            val t = inlineTakeBack(window = peerGrid, measured = null)
            assertEquals(emptyList<String>(), t.take().map { it.command })
            val snapshots = t.controller.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot")
            snapshots.value = snapshots.value!!.copy(activeWindowId = null)
            t.controller.setField("lastTmuxViewport", viewport)
            t.controller.reconcile()
            assertEquals(viewport, t.reducer.claim?.targetGrid)
            val ordering = t.take().single()
            assertEquals("display-message -p ''", ordering.command)
            assertEquals(TmuxResponsePurpose.AuthorityClaimOrdering(8), ordering.purpose)
            assertNull(t.reducer.session.state.claimFence)
            t.expirePresentation()
            assertEquals("the deadline only hides while its grid is unordered", 8L, t.reducer.claim?.generation)
            assertFalse(t.reducer.claim!!.presentationVisible)
            assertFalse(t.reducer.calls.toString(), t.reducer.calls.any { it.startsWith("claimStalled") })
            if (named) {
                t.layout(peerGrid)
                assertEquals("a window named late gets no fence", emptyList<String>(),
                    t.take().map { it.command }.filter { it == "select-window" || it.startsWith("show-options") })
                assertEquals(8L, t.reducer.claim?.generation)
            }
            t.reply(ordering)
            assertTrue(t.reducer.calls.toString(), "claimStalled:false" in t.reducer.calls)
            assertNotEquals(8L, t.reducer.claim?.generation)
        }
    }

    @Test
    fun moshUsesTheSameBeforeAndAfterLandingRuleAndOneRefenceBudget() = withMainOnTestScheduler {
        val takeBack = confirmedMoshTakeBack()
        takeBack.layout(peerGrid)
        val refence = takeBack.take()
        assertEquals(listOf("resize-window -x 80 -y 24 -t @5", "select-window", "set-option -w -u -t @5 window-size", "display-message -p ''"), refence.map { it.command })
        assertTrue(takeBack.reducer.claim!!.geometryRefenced)
        takeBack.reply(refence[0])
        takeBack.reply(refence[1])
        takeBack.reply(refence[2])
        val confirmation = takeBack.take().single()
        assertTrue(confirmation.purpose is TmuxResponsePurpose.WindowSizeReplayConfirmation)
        val purpose = refence[3].purpose as TmuxResponsePurpose.AuthorityClaimFence
        assertTrue("the core's one re-fence, under the same fence and policy", purpose.refence)
        takeBack.reply(refence[3])
        val probe = takeBack.takeSettleProbe()
        takeBack.layout(viewport)
        takeBack.reply(confirmation, lines = listOf("tessera-window-size\t@5\t80\t24"))
        takeBack.answerSettleProbe(probe, viewport)
        takeBack.layout(peerGrid)
        assertNull(takeBack.reducer.claim)
        assertTrue(takeBack.wire.isEmpty)
    }

    @Test
    fun moshLateChurnDoesNotInvalidateTheTargetOrThePreStampRead() = withMainOnTestScheduler {
        val takeBack = confirmedMoshTakeBack()
        takeBack.expirePresentation()
        takeBack.controller.setField("lastTmuxViewport", SharedTmuxGridSize(80, 18))
        takeBack.controller.reconcile(forceAllWindows = true)
        assertEquals(viewport, takeBack.reducer.claim!!.targetGrid)
        assertTrue(takeBack.wire.isEmpty)
        // Native frame completion enters the same production completion
        // helper; its pre-stamp geometry read is answered through Main's drain.
        takeBack.controller.javaClass.getDeclaredMethod("finishLedgerAuthorityRepaint").apply { isAccessible = true }.invoke(takeBack.controller)
        val read = takeBack.take().single()
        assertTrue(read.purpose is TmuxResponsePurpose.AuthorityPaintGeometry)
        // Answered by purpose below, so pin the wire text: indexing the
        // replay list once sent its unset here, and every live claim aborted.
        assertTrue("the pre-stamp read is the size query: ${read.command}", read.command.contains("'tessera-window-size"))
        takeBack.reply(read, lines = listOf("tessera-window-size\t@5\t80\t24"))
        assertEquals(listOf(OWN_STAMP_WRITE), takeBack.take().map { it.command })
        assertEquals(viewport, takeBack.reducer.claim?.targetGrid)
    }

    @Test
    fun bothTransportsGiveTheSameLossVerdictWhateverMainDrainsFirst() = withMainOnTestScheduler {
        for (mosh in listOf(false, true)) {
            val fast = if (mosh) confirmedMoshTakeBack(landed = false) else confirmedInlineTakeBack(landed = false)
            fast.answerSettleProbe(fast.probe, viewport)
            fast.layout(peerGrid)
            val fastCommands = fast.take().map { it.command }

            val lagging = if (mosh) confirmedMoshTakeBack(landed = false) else confirmedInlineTakeBack(landed = false)
            lagging.queueReply(lagging.probe.single(), lines = listOf("tessera-window-size\t@5\t80\t24"))
            lagging.layout(peerGrid)
            assertTrue("the probe and following layout are judged on IO", lagging.reducer.claim!!.geometryRefenced)
            lagging.drainCallbacks()
            assertTrue("mosh=$mosh", lagging.reducer.claim!!.geometryRefenced)
            assertEquals(fast.reducer.claim, lagging.reducer.claim)
            assertEquals(fastCommands, lagging.take().map { it.command })

            // The fence acknowledgement itself may also be queued while IO
            // applies the foreign layout. Its later probe sees that layout
            // on the server and reaches the same loss verdict and wire work.
            val delayedFence = inlineTakeBack(mosh = mosh)
            delayedFence.take().forEach { command ->
                val policy = command.purpose is TmuxResponsePurpose.AuthorityWindowSizePolicy
                delayedFence.queueReply(command, lines = if (policy) listOf("latest") else emptyList())
            }
            delayedFence.layout(peerGrid)
            assertFalse(delayedFence.reducer.claim!!.geometryRefenced)
            delayedFence.drainCallbacks()
            val reads = delayedFence.take()
            if (mosh) {
                val confirmation = reads.single { it.purpose is TmuxResponsePurpose.WindowSizeReplayConfirmation }
                delayedFence.reply(confirmation, lines = listOf("tessera-window-size\t@5\t80\t24"))
            }
            delayedFence.answerSettleProbe(reads.filter { it.purpose is TmuxResponsePurpose.AuthoritySettleSize }, peerGrid)
            assertEquals(fast.reducer.claim, delayedFence.reducer.claim)
            assertEquals(fastCommands, delayedFence.take().map { it.command })
        }
    }

    @Test
    fun aTransportResetForgetsTheEndedClaimsGeometryBookkeeping() = withMainOnTestScheduler {
        val takeBack = confirmedInlineTakeBack()
        takeBack.expirePresentation()
        takeBack.controller.setField("lastTmuxViewport", SharedTmuxGridSize(80, 18))
        takeBack.controller.reconcile()
        assertTrue(takeBack.controller.field<SharedTmuxAuthoritySessionState>("lastTmuxAuthorityResult").claimMayAdvertiseGeometry.not())
        takeBack.controller.setField("terminalSurface", null)
        takeBack.controller.resetTransportAndReattach()
        assertEquals(SharedTmuxAuthorityGeometryHold.WITHHELD, takeBack.controller.field<SharedTmuxAuthoritySessionState>("lastTmuxAuthorityResult").geometryHold)
        assertEquals(0, takeBack.controller.field<Int>("authorityClaimCommandsInFlight"))
        assertNull(takeBack.controller.field<Long?>("authorityClaimCommandsGeneration"))
        assertNull(takeBack.controller.field<Any?>("lastAuthorityClaimObservation"))
        assertNull(takeBack.reducer.session.state.claimFence)
    }

    @Test
    fun unchangedOutputDuringAClaimNeverRepeatsAnObservation() = withMainOnTestScheduler {
        for (state in listOf("inline repaint", "mosh fence", "inline deferred", "mosh deferred")) {
            val takeBack = when (state) {
                "mosh fence" -> inlineTakeBack(window = peerGrid, mosh = true)
                "mosh deferred" -> confirmedMoshTakeBack()
                else -> confirmedInlineTakeBack()
            }
            if (state.endsWith("deferred")) {
                takeBack.controller.setField("declaredTmuxRenderSurfaces", emptyList<SharedTmuxSurfaceDeclaration>())
                takeBack.controller.field<InlineAuthorityRepaintFence>("inlineAuthorityRepaintFence").reset()
                takeBack.controller.setField("deferredAuthorityRepaintGeneration", 8L)
            }
            takeBack.queueRender() // establish the unchanged snapshot's observation memo
            val before = takeBack.reducer.calls.size
            val snapshots = takeBack.reducer.snapshotCalls
            val facts = takeBack.facts.size
            val memo = takeBack.controller.field<Any?>("lastAuthorityClaimObservation")
            repeat(1000) { takeBack.queueRender() }
            assertEquals(state, before, takeBack.reducer.calls.size)
            assertEquals("$state: no lifecycle ABI projection on unchanged output", snapshots, takeBack.reducer.snapshotCalls)
            assertEquals(state, facts, takeBack.facts.size)
            assertTrue(state, memo === takeBack.controller.field<Any?>("lastAuthorityClaimObservation"))
        }
    }

    @Test
    fun aPeerClaimTakingTheWindowAfterOurConfirmationWins() = withMainOnTestScheduler {
        // The peer's own take-back fences `latest` away after our claim
        // confirmed, then stamps. A peer that is genuinely claiming wins: we
        // never stamp, and the veil names it.
        val takeBack = confirmedInlineTakeBack()
        takeBack.layout(peerGrid)
        val refence = takeBack.take().single()
        val newer = SharedTmuxGridAuthoritySnapshot.Peer("ipad-id", "iPad", 5)
        takeBack.layout(peerGrid, authority = newer)
        assertNull("contested by the peer's newer stamp", takeBack.reducer.claim)
        assertEquals(TmuxAuthorityPresentation.Veiled("iPad"), takeBack.controller.presentation())

        // Replies still on the wire change nothing.
        takeBack.reply(refence)
        takeBack.repaintAnswered()
        takeBack.layout(viewport)
        assertEquals(emptyList<String>(), takeBack.take().map { it.command })
        assertEquals(newer, takeBack.controller.field<MutableStateFlow<*>>("mutableTmuxAuthority").value)
        assertEquals(2, takeBack.fences)
    }

    @Test
    fun aSecondLossInOneClaimEndsItInsteadOfFencingAgain() = withMainOnTestScheduler {
        // The re-fence is bounded: a second loss of landed geometry in the
        // same claim does not fence again (two devices that both tapped
        // would otherwise trade `latest` forever). The claim ends with
        // `geometryLost` (§6.10 rule 4): the gesture is over, nothing is
        // replayed, and the user taps again.
        val takeBack = confirmedInlineTakeBack()
        takeBack.layout(peerGrid)
        takeBack.reply(takeBack.take().single())
        val probe = takeBack.takeSettleProbe()
        takeBack.repaintAnswered()
        takeBack.layout(viewport)
        assertEquals("the confirmation's repaint", 2, takeBack.repaints)
        takeBack.answerSettleProbe(probe, viewport)

        // Taken a second time before that repaint is answered.
        takeBack.layout(peerGrid)
        assertNull(takeBack.reducer.claim)
        takeBack.repaintAnswered()
        assertEquals("one re-fence per claim, and no stamp", emptyList<String>(), takeBack.take().map { it.command })
        assertEquals(2, takeBack.fences)
        assertNull(takeBack.reducer.session.state.carriedShow)
        assertNull(takeBack.controller.field<Long?>("pendingAuthorityRepaintGeneration"))
    }

    @Test
    fun theWindowSizePolicyReplyWritesThePolicyOnlyUnderTheTransportLock() {
        // L5: Main delivers the policy reply while IO judges a claim's
        // confirmation and loss, and stamp-less layouts, from the policy
        // under the lock. Written ahead of it, a reader could see the policy
        // known and not yet `latest`: confirmation on the acknowledgement
        // alone, losses off, a stamp at a foreign size.
        val controller = controller(nativeAuthority())
        controller.setField("host", inlineHost)
        controller.setField("windowSizePolicyWindowId", 5)
        val lock = controller.field<Any>("tmuxTransportLock")
        var failure: Throwable? = null
        val reply = Thread {
            try {
                controller.recoveryReply(TmuxResponsePurpose.WindowSizePolicy(5), success = true, lines = listOf("latest"))
            } catch (t: Throwable) {
                failure = t
            }
        }
        synchronized(lock) {
            reply.start()
            awaitBlockedOn(reply, lock)
            assertFalse("nothing written ahead of the lock", controller.field<Boolean>("windowSizePolicyKnown"))
            assertFalse(controller.field<Boolean>("windowSizePolicyIsLatest"))
        }
        reply.join(5_000)
        assertFalse("the reply finished", reply.isAlive)
        failure?.let { throw it }
        assertTrue(controller.field<Boolean>("windowSizePolicyKnown"))
        assertTrue(controller.field<Boolean>("windowSizePolicyIsLatest"))
    }

    @Test
    fun anInlineClaimWhoseWindowMovesBeforeItsFenceIsAnsweredFencesTheNewWindow() = withMainOnTestScheduler {
        // L6: another client's `select-window`, or the fenced window
        // closing, moves the session's current window between our fence and
        // its reply. The targetless fence made us `latest` on the window we
        // left, so the claim fences again for the new one, once per move (as
        // iOS does on `%session-window-changed`), and only that fence's
        // reply confirms it.
        val takeBack = inlineTakeBack()
        val fence = takeBack.takeFence()
        takeBack.moveTo(6, viewport)
        val refence = takeBack.takeFence(policyRead = "show-options -wA -v -t @6 window-size")
        assertEquals(6, refence.purpose.windowId)
        assertFalse("a new fence for the new window", refence.purpose.refence)
        assertNotEquals(fence.purpose.fenceId, refence.purpose.fenceId)
        takeBack.moveTo(6, viewport)
        assertEquals("once per move", emptyList<String>(), takeBack.take().map { it.command })

        takeBack.answerFence(fence)
        assertEquals("the left window's reply confirms nothing", SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim?.phase)
        takeBack.answerFence(refence)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, takeBack.reducer.claim?.phase)
        assertEquals(1, takeBack.confirmations)
    }

    @Test
    fun anAcknowledgedClaimWhoseWindowMovesWaitsForTheNewWindowsFence() = withMainOnTestScheduler {
        // L6: the fence was answered, but the window was still at the peer's
        // grid when the session's current window moved to one at ours. That
        // acknowledgement made us `latest` on the window we left, so it no
        // longer confirms: the new window's fence does.
        val takeBack = inlineTakeBack(window = peerGrid)
        takeBack.answerFence(takeBack.takeFence())
        takeBack.takeSettleProbe()
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim?.phase)

        takeBack.moveTo(6, viewport)
        assertEquals("not confirmed by the left window's acknowledgement", SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim?.phase)
        val refence = takeBack.takeFence(policyRead = "show-options -wA -v -t @6 window-size")
        assertEquals(6, refence.purpose.windowId)
        takeBack.answerFence(refence)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, takeBack.reducer.claim?.phase)
    }

    @Test
    fun aStaleRepaintAnswerDrainedAfterTheClaimRepaintsAgainCountsForNothing() = withMainOnTestScheduler {
        // L7: Main drains IO's callback batches late. A loss, its re-fence
        // and the window's return all run on IO, so the claim confirms again
        // on its standing acknowledgement and begins a new repaint under the
        // same generation while the lost repaint's answer still waits in a
        // batch. Counted, its completion would stamp with the new capture in
        // flight and unveil a frame from before the loss; its failure would
        // abort a claim that is fine. Each counts only for the repaint its
        // batch was queued under.
        for (stale in listOf("completion", "failure")) {
            val takeBack = confirmedInlineTakeBack()
            takeBack.admitFeeds()
            if (stale == "completion") takeBack.queueRepaintAnswer()
            else takeBack.queueRender(SharedTmuxRenderEffect.RefreshFailed(TMUX_RENDER_LIVE_SURFACE_ID, 8, "target-unavailable"))
            takeBack.layout(peerGrid)
            takeBack.layout(viewport)
            assertEquals("$stale: confirmed again on the standing acknowledgement", 2, takeBack.repaints)
            assertEquals(stale, listOf("select-window"), takeBack.take().map { it.command })

            takeBack.drainCallbacks()
            assertEquals("$stale: the lost repaint's answer changes nothing", emptyList<String>(), takeBack.take().map { it.command })
            assertEquals(stale, SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, takeBack.reducer.claim?.phase)
            assertFalse(stale, "abort" in takeBack.reducer.calls)

            takeBack.queueRepaintAnswer()
            takeBack.drainCallbacks()
            assertEquals("$stale: the new repaint's answer stamps", listOf(OWN_STAMP_WRITE), takeBack.take().map { it.command })
        }
    }

    @Test
    fun anInlineClaimWithNoGridAskedForWaitsForOneBeforeItConfirms() = withMainOnTestScheduler {
        // L8: a show claim before the viewport is measured (or one whose
        // presentation switched between single pane and grid) asks for no
        // grid. The fence's acknowledgement alone used to confirm it, and the
        // claim stamped whatever size the window had. iOS waits for a local
        // size; the grid's publish brings the layout that confirms.
        val takeBack = inlineTakeBack(window = peerGrid, measured = null)
        assertEquals("no target, so no fence", emptyList<String>(), takeBack.take().map { it.command })
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim?.phase)
        assertEquals(0, takeBack.repaints)

        takeBack.controller.setField("lastTmuxViewport", viewport)
        takeBack.controller.reconcile()
        assertEquals(SharedTmuxRenderFact.ClientSize(viewport.columns, viewport.rows), takeBack.facts.last())
        assertEquals(viewport, takeBack.reducer.claim?.targetGrid)
        // The grid's replay carries its own fence (§6.10 rule 3).
        takeBack.answerFence(takeBack.takeFence())
        takeBack.takeSettleProbe()
        assertEquals(0, takeBack.repaints)
        takeBack.layout(viewport)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, takeBack.reducer.claim?.phase)
        assertEquals(1, takeBack.repaints)
    }

    @Test
    fun aWindowResizedByAnotherClientWhileOurStampFlewYieldsAsTheClaimSettles() = withMainOnTestScheduler {
        // L10 (iOS 7c4a57e30): a foreign resize reaching us while our stamp
        // is on the wire meets a claim that can no longer be recalled and a
        // stamp-less judgement suppressed for the claim in flight. The
        // settlement judges the window once more, without replay
        // suppression, and yields instead of unveiling us as owner of a
        // window another client sized.
        val takeBack = stampedInlineTakeBack()
        takeBack.layout(peerGrid)
        assertEquals("the stamp cannot be recalled", SharedTmuxAuthorityClaimPhase.AWAITING_STAMP_COMMIT, takeBack.reducer.claim?.phase)
        takeBack.settle()
        assertNull(takeBack.reducer.claim)
        assertEquals(
            SharedTmuxGridAuthoritySnapshot.Peer("-", "another device", 0),
            takeBack.controller.field<MutableStateFlow<*>>("mutableTmuxAuthority").value,
        )
        assertEquals(TmuxAuthorityPresentation.Veiled("another device"), takeBack.controller.presentation())
    }

    @Test
    fun aLocalResizeWhileOurStampFlewStillSettlesAsOurs() = withMainOnTestScheduler {
        // L10: a window at the grid we stamped, or at the grid we ask for
        // now, is ours. A rotation while the stamp is in flight has its own
        // replay and echo on the way; the settlement raises no veil over it.
        for (window in listOf(viewport, SharedTmuxGridSize(80, 20))) {
            val takeBack = stampedInlineTakeBack()
            takeBack.controller.setField("lastTmuxViewport", SharedTmuxGridSize(80, 20))
            takeBack.controller.reconcile()
            assertEquals(SharedTmuxRenderFact.ClientSize(80, 20), takeBack.facts.last())
            takeBack.layout(window)
            takeBack.settle()
            assertEquals(
                "$window",
                SharedTmuxGridAuthoritySnapshot.Mine(8),
                takeBack.controller.field<MutableStateFlow<*>>("mutableTmuxAuthority").value,
            )
            assertEquals("$window", TmuxAuthorityPresentation.None, takeBack.controller.presentation())
        }
    }

    @Test
    fun aFailedReFenceAbortsNeitherTheClaimNorItsStamp() = withMainOnTestScheduler {
        // iOS ignores every fence's result. A geometry loss's re-fence that
        // failed used to abort the claim in any phase, even with its stamp
        // on the wire; the first fence's acknowledgement stands, and the
        // window's return is what confirms.
        val takeBack = confirmedInlineTakeBack()
        takeBack.layout(peerGrid)
        val refence = takeBack.take().single()
        takeBack.layout(viewport)
        takeBack.repaintAnswered()
        assertEquals(listOf(OWN_STAMP_WRITE), takeBack.take().map { it.command })

        takeBack.reply(refence, success = false)
        assertFalse(takeBack.reducer.calls.toString(), "abort" in takeBack.reducer.calls)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_STAMP_COMMIT, takeBack.reducer.claim?.phase)
    }

    @Test
    fun anAgentReplyIsAcknowledgedWhileAnotherDeviceHoldsTheGrid() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)) {
            for (refusal in listOf("yielded", "reclaiming", "resuming")) {
                val sent = mutableListOf<TmuxControlCommand>()
                val port = TmuxAgentControlPort()
                port.attach(
                    sender = { command ->
                        if (!SharedTmuxCommands.agentCommandIsAuthorityNeutral(command.command)) false
                        else { sent += command; true }
                    },
                    windowSelector = { _, _ -> false },
                    paneSelector = { _, _, _ -> false },
                    refusal = { refusal },
                )
                val endpoint = SshAgentSessionEndpoint(
                    key = AgentSessionKey("controlled-elsewhere", 1),
                    hostID = "test-host",
                    transport = transport,
                    route = unusedRouteOwner(),
                    tmuxSession = "test-session",
                    tmuxControl = port,
                )
                try {
                    endpoint.updateActiveTmuxTarget(5, 7)
                    val binding = endpoint.binding.value
                    assertNull(endpoint.inputRefusal(binding))
                    val sending = async(start = CoroutineStart.UNDISPATCHED) {
                        endpoint.sendInput(binding, "yes".encodeToByteArray())
                    }
                    assertEquals(listOf("send-keys -t %7 -H 79 65 73"), sent.map { it.command })
                    assertFalse("enqueue is not an acknowledgement", sending.isCompleted)
                    (sent.last().purpose as TmuxResponsePurpose.AgentCommand).response.complete(AgentTmuxControlAck(true, emptyList()))
                    assertEquals(AgentEndpointResult.Success(Unit), sending.await())

                    for ((key, name) in listOf(
                        AgentSemanticKey.RETURN to "Enter", AgentSemanticKey.ESCAPE to "Escape",
                        AgentSemanticKey.TAB to "Tab", AgentSemanticKey.SHIFT_TAB to "BTab",
                    )) {
                        val keySending = async(start = CoroutineStart.UNDISPATCHED) { endpoint.sendSemanticKey(binding, key) }
                        assertEquals("send-keys -t %7 $name", sent.last().command)
                        assertFalse(keySending.isCompleted)
                        (sent.last().purpose as TmuxResponsePurpose.AgentCommand).response.complete(AgentTmuxControlAck(true, emptyList()))
                        assertEquals(AgentEndpointResult.Success(Unit), keySending.await())
                    }
                    assertEquals("a reply must not claim, select, attach or replay geometry", listOf(
                        "send-keys -t %7 -H 79 65 73", "send-keys -t %7 Enter", "send-keys -t %7 Escape",
                        "send-keys -t %7 Tab", "send-keys -t %7 BTab",
                    ), sent.map { it.command })
                    assertEquals(refusal, port.mutationRefusal())
                    // Navigation still waits for the grid: refused before any selection.
                    assertEquals(AgentEndpointResult.Failed("tmux_controlled_elsewhere"), endpoint.focus(binding))
                    assertEquals(5, sent.size)

                    val failedKey = async(start = CoroutineStart.UNDISPATCHED) {
                        endpoint.sendSemanticKey(binding, AgentSemanticKey.RETURN)
                    }
                    (sent.last().purpose as TmuxResponsePurpose.AgentCommand).response.complete(AgentTmuxControlAck(false, emptyList()))
                    assertEquals(AgentEndpointResult.Failed("tmux_write_failed"), failedKey.await())
                } finally {
                    endpoint.close()
                }
            }
        }
    }

    @Test fun agentPlacementAndLaunchStillRefuseWhileAnotherDeviceHoldsTheGrid() = runBlocking {
        val sent = mutableListOf<String>()
        val port = TmuxAgentControlPort()
        port.attach(
            sender = { command -> sent += command.command; true },
            windowSelector = { _, _ -> false },
            paneSelector = { _, _, _ -> false },
            refusal = { "yielded" },
        )
        val endpoint = SshAgentSessionEndpoint(
            key = AgentSessionKey("controlled-elsewhere", 1), hostID = "test-host",
            transport = AgentEndpointTransport.SSH_TMUX, route = unusedRouteOwner(),
            tmuxSession = "test-session", tmuxControl = port,
        )
        try {
            endpoint.updateActiveTmuxTarget(5, 7)
            val binding = endpoint.binding.value
            for (placement in listOf(AgentTmuxPlacement.NewWindow(), AgentTmuxPlacement.Split("%7", true))) {
                assertEquals(AgentEndpointResult.Failed("tmux_controlled_elsewhere"), endpoint.placeTmux(binding, placement))
                assertEquals(AgentEndpointResult.Failed("tmux_controlled_elsewhere"), endpoint.launchTmux(
                    binding, placement, "00000000-0000-0000-0000-000000000001", byteArrayOf(0x61),
                ))
            }
            assertTrue("no launch or placement command reached tmux", sent.isEmpty())
        } finally {
            endpoint.close()
        }
    }

    @Test fun rawAgentSemanticKeysKeepTheirEncodedBytes() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH, AgentEndpointTransport.MOSH)) {
            val bytes = mutableListOf<Byte>()
            // Raw SSH admits input only over a connected route.
            val endpoint = SshAgentSessionEndpoint(
                key = AgentSessionKey("raw-keys", 1), hostID = "test-host", transport = transport,
                route = connectedRouteOwner(), rawWriter = { bytes += it.toList() },
            )
            try {
                for (key in AgentSemanticKey.entries) {
                    assertEquals(AgentEndpointResult.Success(Unit), endpoint.sendSemanticKey(endpoint.binding.value, key))
                }
                assertEquals(AgentSemanticKey.entries.flatMap { it.encoded().toList() }, bytes)
            } finally {
                endpoint.close()
            }
        }
    }

    @Test fun receiptedPaneInputAndKeysPassTheControllerGateWhileGridTypingRefuses() {
        val c = ready(); c.observe(peer)
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drain()
        val receipt = SharedSessionCommandReceipt(java.util.UUID.randomUUID())
        c.perform(SharedBackendCommand.SendTmuxPaneInput("%7", byteArrayOf(0x61), receipt))
        c.perform(SharedBackendCommand.SendTmuxPaneKey("%7", SharedTmuxPaneKey.ENTER, receipt))
        assertEquals(listOf("send-keys -t %7 -H 61", "send-keys -t %7 Enter"), wire.drain())
        assertEquals(peer, c.field<MutableStateFlow<*>>("mutableTmuxAuthority").value)
        c.perform(SharedBackendCommand.SendTmuxPaneInput("%7", byteArrayOf(0x62), null))
        c.perform(SharedBackendCommand.SendTmuxPaneKey("%7", SharedTmuxPaneKey.ESCAPE, null))
        assertTrue("grid typing remains refused", wire.drain().isEmpty())
    }


    @Test fun aScreenTmuxCommandIsRefusedByAVerdictReducedBeforeItsEnqueue() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); assertNull(c.refusal())
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drain()
        val lock = c.field<Any>("tmuxTransportLock")
        var failure: Throwable? = null
        val performer = Thread {
            try { c.perform(SharedBackendCommand.RenameTmuxWindow("@5", "build")) } catch (t: Throwable) { failure = t }
        }
        synchronized(lock) {
            performer.start(); awaitBlockedOn(performer, lock)
            c.observe(peer)
        }
        performer.join(5_000); assertFalse(performer.isAlive); failure?.let { throw it }
        assertEquals("yielded", c.refusal())
        assertTrue(wire.drain().none { it.startsWith("rename-window") })
    }

    @Test fun aClaimRepaintsAPaintedSurfaceAtVisibleRowsAndOnlyAFirstFillDeep() = withMainOnTestScheduler {
        for ((bound, stage) in listOf(
            paintedOwner to SharedTmuxRenderStage.ViewportOnly,
            null to SharedTmuxRenderStage.Deep,
            RenderOwner(5, 6, 3, 8) to SharedTmuxRenderStage.Deep,
            RenderOwner(5, 7, 3, 7) to SharedTmuxRenderStage.Deep,
        )) {
            val t = inlineTakeBack(); val fence = t.takeFence()
            t.controller.setField("terminalSurface", fakeSurface(bound))
            t.answerFence(fence)
            assertEquals(listOf(SharedTmuxRenderFact.CorrelatedRefreshRequested(TMUX_RENDER_LIVE_SURFACE_ID, stage, "authority-reclaim", 8)),
                t.facts.filterIsInstance<SharedTmuxRenderFact.CorrelatedRefreshRequested>())
            assertEquals(8L, t.controller.field<InlineAuthorityRepaintFence>("inlineAuthorityRepaintFence").generation)
        }
    }

    @Test fun aMoshKeyCostsOneFactWhoseEchoSkipsTheSnapshotPass() = withMainOnTestScheduler {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        c.setField("host", c.field<SavedHost>("host").copy(transportKind = TransportKinds.MOSH))
        val tmux = c.liveConnection(); val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drain()
        c.setField("terminalSurface", null)
        val echo = SharedTmuxEvent(c.heldSnapshot(), emptyList(), emptyList(), emptyList())
        val facts = mutableListOf<SharedTmuxRenderFact>()
        c.setField("tmuxRenderFactProbe", { fact: SharedTmuxRenderFact -> facts += fact; c.deliver(echo, tmux); true })
        val before = c.harness.submissions
        c.userInput()
        assertEquals(listOf<SharedTmuxRenderFact>(SharedTmuxRenderFact.UserInput), facts)
        assertEquals(before, c.harness.submissions); assertTrue(wire.drain().isEmpty())
        c.setField("tmuxRenderFactProbe", { fact: SharedTmuxRenderFact -> facts += fact; true })
        c.deliver(echo.copy(authorityStamps = listOf("v1 ipad-id 4 iPad")), tmux)
        assertEquals(before + 1, c.harness.submissions)
    }

    @Test fun anSshTmuxKeyIsOneSendKeysAndNoRuntimeFact() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        val facts = c.probeRenderFacts(); val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drain()
        val before = c.harness.submissions
        c.setField("terminalSurface", null)
        c.userInput(); c.perform(SharedBackendCommand.SendInput("a".encodeToByteArray()))
        assertTrue(facts.isEmpty()); assertEquals(listOf("send-keys -t %7 -H 61"), wire.drain())
        assertEquals(before, c.harness.submissions)
    }

    @Test fun refusedTerminalInputClearsTheImeLineMirror() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        val resets = mutableListOf<TerminalSurface>()
        c.setField("refusedTerminalInputImeReset", { surface: TerminalSurface -> resets += surface })
        val surface = fakeSurface()
        assertTrue(c.admit(surface)); assertTrue(resets.isEmpty())
        c.shown(SharedTmuxAuthorityShowSource.SHOW)
        assertFalse(c.admit(surface)); assertFalse(c.admit(surface))
        assertEquals(listOf(surface, surface), resets)
    }

    /** S5′: typing a peer stamp drops at apply time never reached the pane, nor may the IME believe it did. */
    @Test fun inputDroppedAtApplyTimeResetsTheImeLineModel() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drain()
        val resets = mutableListOf<TerminalSurface>()
        c.setField("refusedTerminalInputImeReset", { surface: TerminalSurface -> resets += surface })
        val surface = fakeSurface(); c.setField("terminalSurface", surface)
        c.perform(SharedBackendCommand.SendInput("ls".encodeToByteArray()))
        assertEquals(listOf("send-keys -t %7 -H 6c 73"), wire.drain())
        assertTrue(resets.isEmpty())
        c.observe(peer)
        c.perform(SharedBackendCommand.SendInput("rm -rf build\r".encodeToByteArray()))
        assertTrue(wire.drain().isEmpty())
        assertEquals(listOf(surface), resets)
    }

    /** Mosh typing with no driver running is dropped like a refused key; a throw ended the ordered input lane. */
    @Test fun moshTypingWithoutADriverIsDroppedAndResetsTheImeLineModel() = runBlocking {
        val mosh = com.bambouville.tessera.networking.mosh.AndroidMoshTransport(
            bootstrapper = com.bambouville.tessera.networking.mosh.MoshBootstrapper { error("unused") })
        try {
            for (tmuxMode in listOf(TmuxModes.OFF, TmuxModes.AUTOMATIC)) {
                val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
                val resets = mutableListOf<TerminalSurface>()
                c.setField("refusedTerminalInputImeReset", { surface: TerminalSurface -> resets += surface })
                val surface = fakeSurface(); c.setField("terminalSurface", surface)
                c.setField("host", inlineHost.copy(transportKind = TransportKinds.MOSH, tmuxMode = tmuxMode))
                c.setField("moshTransport", mosh)
                c.performSuspending(SharedBackendCommand.SendInput("ls".encodeToByteArray()))
                assertEquals("tmuxMode=$tmuxMode", listOf(surface), resets)
            }
        } finally { mosh.close() }
    }

    @Test fun aShowAndATakeBackStartTheCompactCorrectionsOver() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        val held = SharedTmuxCompactReprojectionMemo(5L, 9L)
        val sizer = SharedTmuxCompactSizer(object : SharedTmuxCompactSizer.Core {
            override fun clientSize(viewport: SharedTmuxGridSize, layoutCells: ByteArray?, focusPaneId: Int?, window: SharedTmuxGridSize?, focus: SharedTmuxGridSize?) = viewport
            override fun reprojection(viewport: SharedTmuxGridSize, lastClientSize: SharedTmuxGridSize?, layoutCells: ByteArray?, focusPaneId: Int?, window: SharedTmuxGridSize?, focus: SharedTmuxGridSize?, memo: SharedTmuxCompactReprojectionMemo) =
                SharedTmuxCompactReprojectionResult(SharedTmuxCompactReprojection.HOLD_CYCLE, held)
        })
        c.setField("compactTmuxSizer", sizer)
        sizer.judge(viewport, viewport, null, null, null, null); assertEquals(held, sizer.memo)
        c.shown(SharedTmuxAuthorityShowSource.SHOW); assertEquals(SharedTmuxCompactReprojectionMemo.FRESH, sizer.memo)
        c.replyTo(c.lastQuery(), OWN_STAMP)
        sizer.judge(viewport, viewport, null, null, null, null); assertEquals(held, sizer.memo)
        c.observe(peer); c.reclaimTmuxGridAuthority()
        assertNotNull(c.native.state.claim); assertEquals(SharedTmuxCompactReprojectionMemo.FRESH, sizer.memo)
    }

    @Test fun aFreshOwnReadBringsTheRuntimeOffItsStamplessFallback() = withMainOnTestScheduler {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        val fallback = SharedTmuxGridAuthoritySnapshot.Peer("-", "another device", 0)
        c.observe(fallback)
        val settled = mutableListOf<SharedTmuxGridAuthoritySnapshot>()
        c.setField("tmuxAuthorityProjectionProbe", { authority: SharedTmuxGridAuthoritySnapshot -> settled += authority; SharedTmuxClaimSettlement.Released(emptyList()) })
        c.apply(c.native.foregrounded(0)); c.replyTo(c.lastQuery(), "v1 android-id 9 Pixel")
        assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(9), c.field<Any?>("lastProjectedTmuxAuthority"))
        assertEquals(listOf(SharedTmuxGridAuthoritySnapshot.Mine(9)), settled)
        c.apply(c.native.tick(0)); assertEquals(1, settled.size)
        c.observe(fallback); assertEquals(listOf(SharedTmuxGridAuthoritySnapshot.Mine(9), fallback), settled)
    }

    @Test fun aReadFindingNoStampBringsTheRuntimeOffItsStamplessFallbackToo() = withMainOnTestScheduler {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); c.observe(SharedTmuxGridAuthoritySnapshot.Peer("-", "another device", 0))
        val wire = c.field<Channel<TmuxControlCommand>>("tmuxCommandChannel"); wire.drain()
        val deepen = SharedTmuxRenderEffect.SendCommand("display-message -p -t %1 'pane-1 metadata'")
        var clears = 0
        c.setField("tmuxAuthorityProjectionProbe", { authority: SharedTmuxGridAuthoritySnapshot -> assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, authority); clears++; SharedTmuxClaimSettlement.Released(listOf(deepen)) })
        c.apply(c.native.foregrounded(0)); wire.drain(); c.replyTo(c.lastQuery(), "")
        assertEquals(1, clears); assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, c.field<Any?>("lastProjectedTmuxAuthority"))
        assertEquals(listOf(deepen.command), wire.drainWire()); assertEquals(1, c.pendingRenderBatches())
        c.apply(c.native.tick(0)); assertEquals(1, clears)
        c.apply(c.native.foregrounded(0)); c.replyTo(c.lastQuery(), ""); assertEquals(1, clears)
    }

    @Test fun aSettledClaimWritesItsReleasedWorkAheadOfAnyLaterCommand() = withMainOnTestScheduler {
        for (released in listOf(
            SharedTmuxClaimSettlement.Released(listOf(SharedTmuxRenderEffect.SendCommand("display-message -p 'pane-1 metadata'"), SharedTmuxRenderEffect.SendCommand("display-message -p 'pane-2 metadata'"), SharedTmuxRenderEffect.Diagnostic("yield-debt-released"))),
            SharedTmuxClaimSettlement.Released(emptyList()), SharedTmuxClaimSettlement.StaleHandle,
        )) {
            val t = stampedInlineTakeBack(); val generations = mutableListOf<Long>()
            t.controller.setField("tmuxAuthorityProjectionProbe", { authority: SharedTmuxGridAuthoritySnapshot -> generations += (authority as SharedTmuxGridAuthoritySnapshot.Mine).generation; released })
            synchronized(t.controller.field<Any>("tmuxTransportLock")) {
                t.settle(); assertTrue(t.controller.selectWindow("@5"))
            }
            assertEquals(listOf(8L), generations)
            val work = t.take()
            if (released is SharedTmuxClaimSettlement.Released && released.renderEffects.isNotEmpty()) {
                assertTrue(work.first().ledgerOwned)
                assertEquals(listOf("display-message -p 'pane-1 metadata'", "display-message -p 'pane-2 metadata'"), work.first().wireCommands)
                assertEquals(1, t.controller.pendingRenderBatches())
                assertEquals(listOf("select-window -t @5"), work.drop(1).flatMap { it.wireCommands })
            } else {
                assertEquals(listOf("select-window -t @5"), work.flatMap { it.wireCommands })
                assertEquals(0, t.controller.pendingRenderBatches())
            }
        }
    }

    @Test fun aClaimThatLostItsGeometryEndsTheGestureLikeAPeersVerdict() = withMainOnTestScheduler {
        val t = confirmedInlineTakeBack(); t.layout(peerGrid); t.reply(t.take().single())
        val probe = t.takeSettleProbe(); t.layout(viewport); t.answerSettleProbe(probe, viewport); t.layout(peerGrid)
        assertNull(t.reducer.claim); assertNull(t.controller.carriedShow()); assertNull(t.reducer.session.state.pendingIntent)
        assertNull(t.controller.field<Long?>("pendingAuthorityRepaintGeneration"))
        t.controller.apply(t.reducer.session.paintable(0, false)); t.controller.apply(t.reducer.session.paintable(0, true))
        assertNull(t.reducer.claim)
    }

    @Test fun aShowClaimLostWithItsRemovedSurfaceReplaysOnRemountAndSettles() = withMainOnTestScheduler {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); c.shown(SharedTmuxAuthorityShowSource.SHOW); c.replyTo(c.lastQuery(), "")
        val first = c.native.state.claim!!.generation
        c.unmountLiveSurface(); c.failClaim(first, "surface-removed")
        assertNull(c.native.state.claim); assertNotNull(c.carriedShow())
        c.remountLiveSurface(); assertNotNull(c.native.state.pendingIntent)
        c.replyTo(c.lastQuery(), ""); val second = c.native.state.claim!!.generation
        assertTrue(second > first)
        c.finishNativeClaim(second)
        assertEquals(TmuxAuthorityPresentation.None, c.presentation()); assertNull(c.carriedShow())
        c.unmountLiveSurface(); c.remountLiveSurface(); assertNull(c.native.state.pendingIntent); assertNull(c.native.state.claim)
    }

    @Test fun aRealHideOrTheIntentWindowEndsAParkedReplay() = withMainOnTestScheduler {
        for (hide in listOf(false, true)) {
            val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); c.shown(SharedTmuxAuthorityShowSource.SHOW); c.replyTo(c.lastQuery(), "")
            c.unmountLiveSurface(); c.failClaim(c.native.state.claim!!.generation, "surface-removed"); assertNotNull(c.carriedShow())
            if (hide) c.hidden() else { scheduler.advanceTimeBy(20_001); scheduler.runCurrent() }
            c.remountLiveSurface(); assertNull(c.carriedShow()); assertNull(c.native.state.pendingIntent); assertNull(c.native.state.claim)
        }
    }

    @Test fun aClaimThatFailsAfterARealHideIsNeverReplayed() = withMainOnTestScheduler {
        val t = inlineTakeBack(); t.take(); t.controller.hidden()
        assertEquals(8L, t.reducer.claim?.generation)
        t.controller.unmountLiveSurface(); t.controller.failClaim(8, "surface-removed")
        assertNull(t.reducer.claim); assertNull(t.controller.carriedShow())
        t.controller.remountLiveSurface(); t.controller.apply(t.reducer.session.foregrounded(0))
        assertNull(t.reducer.claim); assertNull(t.reducer.session.state.pendingIntent)
    }

    @Test fun aClaimFailedWhileStoppedWaitsForTheForegroundToReplay() = withMainOnTestScheduler {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); c.shown(SharedTmuxAuthorityShowSource.SHOW); c.replyTo(c.lastQuery(), "")
        val first = c.native.state.claim!!.generation
        c.setField("appForeground", false); c.apply(c.native.backgrounded(0)); c.unmountLiveSurface(); c.failClaim(first, "surface-removed")
        assertNotNull("${c.native.state} calls=${c.harness.calls}", c.carriedShow()); c.remountLiveSurface(); assertNull(c.native.state.pendingIntent); assertNull(c.native.state.claim)
        c.setField("appForeground", true); c.apply(c.native.foregrounded(0))
        c.javaClass.getDeclaredMethod("submitAuthorityPaintability").apply { isAccessible = true }.invoke(c)
        assertNotNull(c.native.state.pendingIntent); c.replyTo(c.lastQuery(), "")
        assertTrue(c.native.state.claim!!.generation > first); assertEquals(0L, c.carriedShow()!!.stepAtMillis)
    }

    @Test fun aHideAbandonsOnlyAClaimThatHasSentNoGridMutation() = withMainOnTestScheduler {
        val t = inlineTakeBack(); t.take(); assertEquals(8L, t.controller.field<Long?>("authorityClaimWireGeneration"))
        t.controller.hidden(); assertEquals(8L, t.reducer.claim?.generation)
        val c = ready(); c.replyTo(c.lastQuery(), "v1 ipad-id 4 iPad")
        // Capture and submit the claim before its wire effect can be delivered.
        val submitted = c.native.requestTakeBack(0)
        c.setField("lastTmuxAuthorityResult", submitted.state)
        c.setField("pendingAuthorityRepaintGeneration", submitted.state.claim!!.generation)
        c.hidden()
        assertNull(c.native.state.claim); assertNull(c.carriedShow()); assertNull(c.native.state.pendingIntent)
    }

    @Test fun aMoshClaimWhoseOnlyGridMutationIsAWindowForceFinishesAfterAHide() = withMainOnTestScheduler {
        val t = inlineTakeBack(mosh = true, window = peerGrid, advertisedSideChannelSize = viewport)
        val begin = t.take(); assertTrue(begin.none { it.command.startsWith("refresh-client -C") }); assertTrue(begin.any { it.command.startsWith("resize-window") })
        t.controller.hidden(); assertEquals(8L, t.reducer.claim?.generation)
        assertEquals(8L, t.controller.field<Long?>("authorityClaimWireGeneration"))
    }
    @Test fun aMoshClaimAtAFittingWindowStillFencesLatestAndFinishesAfterAHide() = withMainOnTestScheduler {
        val t = inlineTakeBack(mosh = true, advertisedSideChannelSize = viewport)
        assertEquals(listOf("resize-window -x 80 -y 24 -t @5", "select-window", "set-option -w -u -t @5 window-size", CLAIM_POLICY_READ, "display-message -p ''"), t.take().map { it.command })
        t.controller.hidden(); assertEquals(8L, t.reducer.claim?.generation)
        assertEquals(8L, t.controller.field<Long?>("authorityClaimWireGeneration"))
    }
    @Test fun aMoshClaimWhoseLedgerSendsItsClientSizeFinishesAfterAHide() = withMainOnTestScheduler {
        val t = inlineTakeBack(mosh = true); t.take()
        val ledger = t.controller.clientSizeLedger(SharedTmuxRenderProfile.SideChannel)
        t.controller.apply(t.reducer.session.abort(0, 8, SharedTmuxAuthorityAbortReason.SUPERSEDED)); t.take()
        t.controller.apply(t.reducer.session.requestTakeBack(0))
        assertEquals(listOf("refresh-client -C 80,24", "resize-window -x 80 -y 24 -t @5", "select-window", "set-option -w -u -t @5 window-size", CLAIM_POLICY_READ, "display-message -p ''"), t.take().flatMap { it.wireCommands })
        assertTrue(ledger.facts.any { it == SharedTmuxRenderFact.ClientSize(80, 24) })
        t.controller.hidden(); assertEquals(9L, t.reducer.claim?.generation)
        assertEquals(9L, t.controller.field<Long?>("authorityClaimWireGeneration"))
    }

    @Test fun aWindowChangeMidRepaintReplaysTheGestureAtOnceWithoutAnInterimProjection() = withMainOnTestScheduler {
        val t = confirmedMoshTakeBack(); val presentations = RecordingStateFlow<TmuxAuthorityPresentation>(t.controller.presentation())
        t.controller.setField("mutableTmuxAuthorityPresentation", presentations)
        t.moveTo(6, viewport)
        assertEquals(9L, t.reducer.claim?.generation)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, t.reducer.claim?.phase)
        assertFalse(presentations.history.any { it is TmuxAuthorityPresentation.Veiled })
        assertTrue("unchanged presentation is deduped", presentations.history.isEmpty())
        assertEquals(TmuxAuthorityPresentation.Reclaiming("iPad"), t.controller.presentation())
    }

    @Test fun aReplacementCarriesOnlyAnUnfinishedShowOfAShownTab() {
        for (source in SharedTmuxAuthorityShowSource.entries) {
            val c = controller(nativeAuthority()); c.shown(source, 0)
            assertEquals(SharedTmuxAuthorityCarriedShow(source, 0), c.carriedShow())
            c.hidden(); assertNull(c.carriedShow())
        }
        val t = inlineTakeBack(); assertNull(t.controller.carriedShow())
        val settled = stampedInlineTakeBack(); settled.settle(); assertNull(settled.controller.carriedShow())
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aHideTheTickMissedIsDeliveredAheadOfTheReturnShow() = withStore { store, clock ->
        val c = controller(nativeAuthority()); val h = c.harness
        store.open(key(), c); store.reportComposedDisplay("host", true, 0, 0)
        advanceShowSettle()
        store.activityStopped(realBackground = true); clock.offset += 10 * 60_000
        store.activityStarted()
        assertEquals(listOf("shown:show", "hidden"), c.showEdges())
        assertTrue(c.native.state.hidden)
        store.reportComposedDisplay("host", true, 1, 0)
        assertEquals(listOf("shown:show", "hidden"), c.showEdges())
        advanceShowSettle()
        assertEquals(listOf("shown:show", "hidden", "shown:show"), h.calls.filter { it == "hidden" || it.startsWith("shown:") })
        assertFalse(c.native.state.hidden)
        assertEquals(store.showClock(), c.carriedShow()!!.stepAtMillis)
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun anExcursionHidesOnlyOnceItOutlastsItsBound() {
        val bound = LiveSessionStore.EXCURSION_TRANSPARENCY_MILLIS
        for (case in listOf("30 s picker", "Home from the picker, 61 s away", "tick stalled", "back in time")) withStore { store, clock ->
            val c = controller(nativeAuthority()); store.open(key(), c); store.reportComposedDisplay("host", true, 0, 0)
            advanceShowSettle()
            // Resolve the gesture so its unrelated intent deadline cannot hide a missed show edge.
            c.cancelPendingTmuxAuthorityIntent()
            store.activityStopped(realBackground = false, duringExcursion = true)
            store.reportComposedDisplay("host", false, 0, 0)
            store.reportComposedDisplay("host", true, 0, 0)
            val away = if (case == "30 s picker") 30_000L else if (case == "Home from the picker, 61 s away") 61_000L else bound - 1
            scheduler.advanceTimeBy(away); scheduler.runCurrent()
            if (case == "tick stalled") clock.offset += 10 * 60_000
            store.activityStarted()
            val returnedHidden = case == "Home from the picker, 61 s away" || case == "tick stalled"
            assertEquals(case, returnedHidden, c.native.state.hidden)
            if (returnedHidden) {
                store.reportComposedDisplay("host", true, 0, 0)
                assertTrue("the stopped epoch cannot undo the cap's hide", c.native.state.hidden)
            }
            if (case == "back in time") { scheduler.advanceTimeBy(1_000); scheduler.runCurrent() }
            store.reportComposedDisplay("host", true, 1, 0)
            advanceShowSettle()
            scheduler.advanceTimeBy(2 * bound); scheduler.runCurrent()
            val expected = if (case == "30 s picker" || case == "back in time") listOf("shown:show") else listOf("shown:show", "hidden", "shown:show")
            assertEquals(case, expected, c.harness.calls.filter { it == "hidden" || it.startsWith("shown:") })
        }
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aReplacementCarriesAnInFlightShowClaimOrAdoptsTheShownSlot() {
        for (case in listOf("in-flight show claim", "settled, slot shown", "settled, slot never shown", "tap claim, slot shown")) withStore { store, _ ->
            val old = ready(); old.replyTo(old.lastQuery(), OWN_STAMP); store.open(key(session = "s1"), old)
            val stepAt = store.showClock() + LiveSessionStore.SHOW_SETTLE_MILLIS
            if (!case.endsWith("never shown")) {
                store.reportComposedDisplay("host", true, 0, 0)
                advanceShowSettle()
            }
            when {
                case.startsWith("in-flight") -> old.replyTo(old.lastQuery(), "")
                case.startsWith("tap") -> { old.cancelPendingTmuxAuthorityIntent(); old.observe(peer); old.reclaimTmuxGridAuthority() }
                else -> old.cancelPendingTmuxAuthorityIntent()
            }
            old.setField("closed", true)
            val created = controller(nativeAuthority()); store.open(key(session = "s2"), created)
            val carries = case.startsWith("in-flight")
            assertEquals(case, carries, created.native.state.pendingIntent != null)
            assertEquals(case, !case.endsWith("never shown"), !created.native.state.hidden)
            if (carries) assertEquals(stepAt, created.carriedShow()!!.stepAtMillis) else assertNull(created.carriedShow())
        }
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aRealBackgroundFiltersTheStoppedEpochEvenForANewSlot() = withStore { store, _ ->
        store.activityStarted()
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", true, 1, 0); advanceShowSettle()
        store.activityStopped(realBackground = true)
        scheduler.advanceTimeBy(LiveSessionStore.HIDE_DEBOUNCE_MILLIS - 1); scheduler.runCurrent()
        assertEquals(listOf("shown:show"), c.showEdges())
        scheduler.advanceTimeBy(1); scheduler.runCurrent()
        assertEquals(listOf("shown:show", "hidden"), c.showEdges())

        val late = controller(nativeAuthority()); store.open(key().copy(hostId = "late"), late)
        for (epoch in listOf(0L, 1L)) {
            store.reportComposedDisplay("host", true, epoch, 0)
            store.reportComposedDisplay("late", true, epoch, 0)
        }
        advanceShowSettle()
        assertEquals(listOf("shown:show", "hidden"), c.showEdges())
        assertTrue(late.showEdges().isEmpty()); assertTrue(late.native.state.hidden)

        store.activityStarted()
        assertEquals(2L, store.startEpoch.longValue)
        store.reportComposedDisplay("host", true, 2, 0)
        store.reportComposedDisplay("late", true, 2, 0)
        scheduler.advanceTimeBy(LiveSessionStore.SHOW_SETTLE_MILLIS - 1); scheduler.runCurrent()
        assertEquals(listOf("shown:show", "hidden"), c.showEdges())
        assertTrue(late.showEdges().isEmpty())
        scheduler.advanceTimeBy(1); scheduler.runCurrent()
        assertEquals(listOf("shown:show", "hidden", "shown:show"), c.showEdges())
        assertEquals(listOf("shown:show"), late.showEdges())
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aNonPresentedTabNeverShowsAcrossARealBackground() = withStore { store, _ ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", false, 0, 0)
        store.activityStopped(realBackground = true)
        scheduler.advanceTimeBy(70_000); scheduler.runCurrent()
        store.activityStarted(); store.reportComposedDisplay("host", false, 1, 0)
        advanceShowSettle()
        assertTrue(c.showEdges().isEmpty()); assertTrue(c.native.state.hidden)
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aBackgroundShorterThanTheDebounceKeepsTheShownSlot() = withStore { store, _ ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
        store.activityStopped(realBackground = true)
        scheduler.advanceTimeBy(1_200); scheduler.runCurrent()
        store.activityStarted(); store.reportComposedDisplay("host", true, 1, 0)
        scheduler.advanceTimeBy(5_000); scheduler.runCurrent()
        assertEquals(listOf("shown:show"), c.showEdges()); assertFalse(c.native.state.hidden)
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aConfigurationChangeNeverOpensAnExcursionOrHides() = withStore { store, _ ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
        store.activityStopped(realBackground = false, duringExcursion = false)
        scheduler.advanceTimeBy(2 * LiveSessionStore.EXCURSION_TRANSPARENCY_MILLIS); scheduler.runCurrent()
        assertEquals(listOf("shown:show"), c.showEdges())
        store.activityStarted()
        // Recreation can briefly compose below STARTED before displaying again.
        store.reportComposedDisplay("host", false, 1, 0)
        scheduler.advanceTimeBy(300); scheduler.runCurrent()
        store.reportComposedDisplay("host", true, 1, 0)
        scheduler.advanceTimeBy(5_000); scheduler.runCurrent()
        assertEquals(listOf("shown:show"), c.showEdges()); assertFalse(c.native.state.hidden)
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aConfigurationRestartLeavesASettlingShowToTheNewComposition() {
        for (locked in listOf(false, true)) withStore { store, clock ->
            val c = controller(nativeAuthority()); store.open(key(), c)
            store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
            c.cancelPendingTmuxAuthorityIntent()
            store.requestExplicitOpen("host")
            store.reportComposedDisplay("host", true, 0, 1)
            scheduler.advanceTimeBy(100); scheduler.runCurrent()
            store.activityStopped(realBackground = false, duringExcursion = false)
            // Recreation holds Main past the settle: the restart's tick runs late.
            clock.offset += 300
            store.activityStarted()
            assertEquals("locked=$locked", listOf("shown:show"), c.showEdges())
            if (locked) {
                store.reportComposedDisplay("host", false, 1, 1)
                scheduler.advanceTimeBy(LiveSessionStore.HIDE_DEBOUNCE_MILLIS); scheduler.runCurrent()
                assertEquals(listOf("shown:show", "hidden"), c.showEdges())
            }
            store.reportComposedDisplay("host", true, 1, 1)
            assertEquals("locked=$locked", if (locked) 2 else 1, c.showEdges().size)
            advanceShowSettle()
            val expected = if (locked) listOf("shown:show", "hidden", "shown:explicitOpen") else listOf("shown:show", "shown:explicitOpen")
            assertEquals("locked=$locked", expected, c.showEdges())
        }
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aTabLeavingTheScreenNeverSettlesItsExplicitOpenThere() = withStore { store, clock ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", true, 0, 0)
        scheduler.advanceTimeBy(100); scheduler.runCurrent()
        store.requestExplicitOpen("host")
        // The settle's tick is late; the tab leaves with the open in the same report.
        clock.offset += 300
        store.reportComposedDisplay("host", false, 0, 1)
        assertEquals(emptyList<String>(), c.showEdges())
        clock.offset += 300
        store.reportComposedDisplay("host", true, 0, 1)
        assertEquals(emptyList<String>(), c.showEdges())
        advanceShowSettle()
        assertEquals("the open waited for the return", listOf("shown:explicitOpen"), c.showEdges())
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun nestedExcursionsStayTransparentUntilTheLastEndsAndARealStopHides() = withStore { store, _ ->
        val excursions = ExternalUiExcursions(); val picker = excursions.slot(); val prompt = excursions.slot()
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
        picker(true); prompt(true); prompt(false)
        store.activityStopped(realBackground = !excursions.active, duringExcursion = excursions.active)
        store.reportComposedDisplay("host", false, 0, 0)
        scheduler.advanceTimeBy(10_000); scheduler.runCurrent()
        assertEquals(listOf("shown:show"), c.showEdges())
        picker(false)
        store.activityStopped(realBackground = !excursions.active, duringExcursion = excursions.active)
        scheduler.advanceTimeBy(LiveSessionStore.HIDE_DEBOUNCE_MILLIS - 1); scheduler.runCurrent()
        assertEquals(listOf("shown:show"), c.showEdges())
        scheduler.advanceTimeBy(1); scheduler.runCurrent()
        assertEquals(listOf("shown:show", "hidden"), c.showEdges())
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aWakeBehindTheLockDeliversTheMissedHideBeforeTheUnlockShow() = withStore { store, clock ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
        assertNotNull(c.native.state.pendingIntent)
        store.activityStopped(realBackground = true); clock.offset += 300_000
        store.activityStarted()
        assertEquals(listOf("shown:show", "hidden"), c.showEdges())
        assertNull("the wake's foreground read must not resolve the old intent", c.native.state.pendingIntent)
        c.apply(c.native.foregrounded(store.showClock()))
        store.reportComposedDisplay("host", false, 1, 0)
        scheduler.advanceTimeBy(5_000); scheduler.runCurrent()
        assertEquals(listOf("shown:show", "hidden"), c.showEdges())
        store.reportComposedDisplay("host", true, 1, 0); advanceShowSettle()
        assertEquals(listOf("shown:show", "hidden", "shown:show"), c.showEdges())
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aLockedNewEpochStillHidesAtTheOriginalBackgroundDeadline() = withStore { store, _ ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
        store.activityStopped(realBackground = true)
        scheduler.advanceTimeBy(200); scheduler.runCurrent()
        store.activityStarted(); store.reportComposedDisplay("host", false, 1, 0)
        scheduler.advanceTimeBy(LiveSessionStore.HIDE_DEBOUNCE_MILLIS - 201); scheduler.runCurrent()
        assertEquals(listOf("shown:show"), c.showEdges())
        scheduler.advanceTimeBy(1); scheduler.runCurrent()
        assertEquals(listOf("shown:show", "hidden"), c.showEdges())
        store.reportComposedDisplay("host", true, 1, 0); advanceShowSettle()
        assertEquals(listOf("shown:show", "hidden", "shown:show"), c.showEdges())
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aSixtyOneSecondExcursionWithAStalledTickHidesAtStartThenSettlesTheShow() = withStore { store, clock ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
        c.cancelPendingTmuxAuthorityIntent()
        store.activityStopped(realBackground = false, duringExcursion = true)
        store.reportComposedDisplay("host", false, 0, 0)
        clock.offset += 61_000 // elapsed realtime advanced, while coroutine delay never ran.
        store.reportComposedDisplay("host", true, 0, 0)
        assertEquals(listOf("shown:show"), c.showEdges())
        store.activityStarted()
        assertEquals(listOf("shown:show", "hidden"), c.showEdges())
        assertTrue(c.native.state.hidden)
        store.reportComposedDisplay("host", true, 0, 0)
        store.reportComposedDisplay("host", true, 1, 0)
        scheduler.advanceTimeBy(LiveSessionStore.SHOW_SETTLE_MILLIS - 1); scheduler.runCurrent()
        assertEquals(listOf("shown:show", "hidden"), c.showEdges())
        scheduler.advanceTimeBy(1); scheduler.runCurrent()
        assertEquals(listOf("shown:show", "hidden", "shown:show"), c.showEdges())
        assertEquals(store.showClock(), c.carriedShow()!!.stepAtMillis)
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aShortExcursionStaysTransparentWhenTheTickOrCompositionRunsLate() {
        for (returnFirst in listOf("start", "composition")) withStore { store, clock ->
            val c = controller(nativeAuthority()); store.open(key(), c)
            store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
            store.activityStopped(realBackground = false, duringExcursion = true)
            clock.offset += LiveSessionStore.EXCURSION_TRANSPARENCY_MILLIS - 1
            if (returnFirst == "start") store.activityStarted() else store.reportComposedDisplay("host", true, 1, 0)
            // The interval really ended inside the cap, even though the next
            // timer/composition work is beyond its former deadline.
            scheduler.advanceTimeBy(LiveSessionStore.EXCURSION_TRANSPARENCY_MILLIS); scheduler.runCurrent()
            store.reportComposedDisplay("host", true, 1, 0)
            assertEquals(returnFirst, listOf("shown:show"), c.showEdges())
            assertFalse(c.native.state.hidden)
        }
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun anExcursionReturnCompositionFirstStillDeliversHideBeforeTheSettledShow() = withStore { store, clock ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
        store.activityStopped(realBackground = false, duringExcursion = true)
        clock.offset += 300_000
        store.reportComposedDisplay("host", true, 1, 0)
        assertEquals(listOf("shown:show", "hidden"), c.showEdges())
        assertTrue(c.native.state.hidden)
        advanceShowSettle()
        assertEquals(listOf("shown:show", "hidden", "shown:show"), c.showEdges())
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aTapThroughWithinTheSettleProducesNoShowOrHide() = withStore { store, _ ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", true, 0, 0)
        scheduler.advanceTimeBy(LiveSessionStore.SHOW_SETTLE_MILLIS - 1); scheduler.runCurrent()
        assertTrue(c.showEdges().isEmpty())
        store.reportComposedDisplay("host", false, 0, 0)
        scheduler.advanceTimeBy(1 + LiveSessionStore.HIDE_DEBOUNCE_MILLIS); scheduler.runCurrent()
        assertTrue(c.showEdges().isEmpty()); assertTrue(c.native.state.hidden)
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aRoutedExplicitOpenOfTheDisplayedTabConsumesEachCountOnce() = withStore { store, _ ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
        for (count in 1L..2L) {
            store.requestExplicitOpen("host")
            assertEquals(count, store.explicitOpenRequests.getValue("host"))
            store.reportComposedDisplay("host", true, 0, count)
            store.reportComposedDisplay("host", true, 0, count)
            scheduler.advanceTimeBy(LiveSessionStore.SHOW_SETTLE_MILLIS - 1); scheduler.runCurrent()
            assertEquals(count.toInt(), c.showEdges().size)
            scheduler.advanceTimeBy(1); scheduler.runCurrent()
            assertEquals(listOf("shown:show") + List(count.toInt()) { "shown:explicitOpen" }, c.showEdges())
            store.reportComposedDisplay("host", true, 0, count); advanceShowSettle()
            assertEquals(count.toInt() + 1, c.showEdges().size)
        }
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun anExplicitOpenAndItsFirstPresentationProduceOneSettledExplicitShow() = withStore { store, _ ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.requestExplicitOpen("host")
        store.reportComposedDisplay("host", true, 0, store.explicitOpenRequests.getValue("host"))
        assertTrue(c.showEdges().isEmpty())
        advanceShowSettle()
        assertEquals(listOf("shown:explicitOpen"), c.showEdges())
        store.reportComposedDisplay("host", true, 0, 1); advanceShowSettle()
        assertEquals(listOf("shown:explicitOpen"), c.showEdges())
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun anExplicitOpenCounterWaitsForItsTabToDisplay() = withStore { store, _ ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.requestExplicitOpen("host")
        store.reportComposedDisplay("host", false, 0, 1)
        scheduler.advanceTimeBy(50); scheduler.runCurrent()
        assertTrue(c.showEdges().isEmpty())
        store.reportComposedDisplay("host", true, 0, 1); advanceShowSettle()
        assertEquals(listOf("shown:explicitOpen"), c.showEdges())
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun anExplicitOpenCounterDuringAPendingHideKeepsTheSlotShown() = withStore { store, _ ->
        val c = controller(nativeAuthority()); store.open(key(), c)
        store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
        store.reportComposedDisplay("host", false, 0, 0)
        scheduler.advanceTimeBy(400); scheduler.runCurrent()
        store.requestExplicitOpen("host"); store.reportComposedDisplay("host", true, 0, 1)
        assertEquals(listOf("shown:show"), c.showEdges())
        advanceShowSettle()
        scheduler.advanceTimeBy(5_000); scheduler.runCurrent()
        assertEquals(listOf("shown:show", "shown:explicitOpen"), c.showEdges())
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aReplacementDuringTheShowSettleKeepsTheTrackerAndItsDeadline() = withStore { store, _ ->
        val trackers = mutableListOf<SharedTmuxShowEdges>()
        store.createShowEdges = { SharedTmuxShowEdges.create().also(trackers::add) }
        val old = controller(nativeAuthority()); store.open(key(), old)
        val stepAt = store.showClock() + LiveSessionStore.SHOW_SETTLE_MILLIS
        store.reportComposedDisplay("host", true, 0, 0)
        scheduler.advanceTimeBy(200); scheduler.runCurrent(); old.setField("closed", true)
        val created = controller(nativeAuthority()); store.open(key("s2"), created)
        assertTrue(created.native.state.hidden)
        scheduler.advanceTimeBy(LiveSessionStore.SHOW_SETTLE_MILLIS - 201); scheduler.runCurrent()
        assertTrue(created.showEdges().isEmpty())
        scheduler.advanceTimeBy(1); scheduler.runCurrent()
        assertEquals(1, trackers.size); assertTrue(old.showEdges().isEmpty())
        assertEquals(listOf("shown:show"), created.showEdges())
        assertEquals(stepAt, created.carriedShow()!!.stepAtMillis)
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun aReplacementDuringTheHideDebounceAdoptsTheShownSlot() = withStore { store, _ ->
        val old = controller(nativeAuthority()); store.open(key(), old)
        store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
        old.cancelPendingTmuxAuthorityIntent()
        store.reportComposedDisplay("host", false, 0, 0)
        scheduler.advanceTimeBy(200); scheduler.runCurrent(); old.setField("closed", true)
        val created = controller(nativeAuthority()); store.open(key("s2"), created)
        assertFalse("a debouncing hide still counts as shown", created.native.state.hidden)
        assertNull(created.carriedShow())
        scheduler.advanceTimeBy(LiveSessionStore.HIDE_DEBOUNCE_MILLIS - 201); scheduler.runCurrent()
        assertTrue(created.showEdges().isEmpty())
        scheduler.advanceTimeBy(1); scheduler.runCurrent()
        assertEquals(listOf("hidden"), created.showEdges()); assertTrue(created.native.state.hidden)
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun closeReleasesTheNativeShowTrackerAndCancelsItsPendingTick() = withStore { store, _ ->
        val trackers = mutableListOf<SharedTmuxShowEdges>()
        store.createShowEdges = { SharedTmuxShowEdges.create().also(trackers::add) }
        val c = controller(nativeAuthority()); store.open(key(), c)
        assertTrue("controller creation alone allocates no show handle", trackers.isEmpty())
        store.reportComposedDisplay("missing", true, 0, 0); assertTrue(trackers.isEmpty())
        store.reportComposedDisplay("host", true, 0, 0); scheduler.runCurrent()
        assertEquals(1, trackers.size)
        c.setField("closed", true); store.close("host"); store.close("host")
        assertShowTrackerClosed(trackers.single(), store.showClock())

        val replacement = controller(nativeAuthority()); store.open(key("s2"), replacement)
        store.reportComposedDisplay("host", true, 0, 0); advanceShowSettle()
        assertEquals(2, trackers.size)
        assertTrue(c.showEdges().isEmpty())
        assertEquals(listOf("shown:show"), replacement.showEdges())
    }

    @Test(timeout = STORE_TEST_TIMEOUT_MS)
    fun closeAllReleasesEveryNativeShowTracker() = withStore { store, _ ->
        val trackers = mutableListOf<SharedTmuxShowEdges>()
        store.createShowEdges = { SharedTmuxShowEdges.create().also(trackers::add) }
        val sessions = listOf("host", "other").map { hostId ->
            controller(nativeAuthority()).also { c ->
                store.open(key().copy(hostId = hostId), c)
                store.reportComposedDisplay(hostId, true, 0, 0)
                c.setField("closed", true)
            }
        }
        assertEquals(2, trackers.size)
        store.closeAll(); store.closeAll()
        assertTrue(store.liveHostIds.isEmpty())
        trackers.forEach { assertShowTrackerClosed(it, store.showClock()) }
        advanceShowSettle()
        sessions.forEach { assertTrue(it.showEdges().isEmpty()) }
    }

    @Test fun aRestoredSelectionRefusedUnderATimedOutClaimWaitsForTheGrid() = withMainOnTestScheduler {
        val t = confirmedInlineTakeBack(); t.expirePresentation()
        t.controller.setField("initialTmuxSelection", "99:99"); t.controller.setField("restoreSelectionApplied", false)
        t.controller.applyRestoredSelection(); scheduler.runCurrent()
        assertFalse(t.controller.field<Boolean>("restoreSelectionApplied"))
        t.repaintAnswered(); t.take(); t.settle(); scheduler.runCurrent()
        assertEquals(TmuxAuthorityPresentation.None, t.controller.presentation()); assertTrue(t.controller.field<Boolean>("restoreSelectionApplied"))
    }

    private fun SshSessionController.finishNativeClaim(generation: Long) {
        native.confirmFence(scheduler.currentTime, generation, viewport, onResult = { apply(it) })
        apply(native.repaintSucceeded(scheduler.currentTime, generation))
        apply(native.stampCommitSucceeded(scheduler.currentTime, generation))
        apply(native.settle(scheduler.currentTime, generation))
    }


    @Test fun aNativeDeadlineBetweenAdmissionAndTheClientSizeReportSendsNoGeometry() = withMainOnTestScheduler {
        val t = confirmedInlineTakeBack(); t.controller.setField("lastPublishedTmuxSize", null)
        val facts = t.controller.probeRenderFacts(); t.controller.setField("authorityTime", { 3001L })
        val sent = t.controller.javaClass.getDeclaredMethod("sendTmuxClientSize", SharedTmuxGridSize::class.java, Boolean::class.javaPrimitiveType!!)
            .apply { isAccessible = true }.invoke(t.controller, peerGrid, true) as Boolean
        assertFalse(sent); assertTrue(facts.none { it is SharedTmuxRenderFact.ClientSize })
        assertFalse(t.reducer.session.state.claimMayAdvertiseGeometry); assertEquals(viewport, t.reducer.claim?.targetGrid)
        assertNull(t.controller.field<SharedTmuxGridSize?>("lastPublishedTmuxSize"))
    }
    @Test fun aDeferredPeerDeadlineBeforeABareAdvertisementSendsNoClientSize() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP)
        var now = 0L; c.setField("authorityTime", { now }); c.apply(c.native.windowSizePolicyReplied(now, 5, "latest")); c.delivered(viewport)
        now = 1500
        c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = snapshot(peerGrid)
        c.facts(); assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
        now = c.native.state.nextDeadlineMillis!!
        c.setField("lastPublishedTmuxSize", null); val facts = c.probeRenderFacts()
        c.javaClass.getDeclaredMethod("advertiseTmuxGeometryOnly", SharedTmuxGridSize::class.java).apply { isAccessible = true }.invoke(c, viewport)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Peer("-", "another device", 0), c.native.state.authority)
        assertTrue(facts.none { it is SharedTmuxRenderFact.ClientSize }); assertNull(c.field<SharedTmuxGridSize?>("lastPublishedTmuxSize"))
    }


    @Test fun anAbortRejudgesForeignGeometryButNeverAnAdvertisedOrOwnedGrid() {
        for ((grid, owned, expectedPeer) in listOf(Triple(peerGrid, false, true), Triple(viewport, false, false), Triple(peerGrid, true, false))) {
            val c = showClaim(seed = if (owned) peerGrid else viewport)
            c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = snapshot(grid); c.facts()
            endExpiredShow(c)
            assertEquals("grid=$grid owned=$owned", expectedPeer, c.native.state.authority is SharedTmuxGridAuthoritySnapshot.Peer)
            assertNull(c.native.state.claim); assertNull(c.field<Any?>("lastAuthorityClaimObservation"))
            assertNull(c.field<Long?>("authorityClaimCommandsGeneration"))
        }
    }
    @Test fun anAbortRecognizesAdvertisedGridsEvictedFromTheAbiProjection() {
        for ((grid, expectedPeer) in listOf(viewport to false, peerGrid to true)) {
            val c = showClaim(seed = SharedTmuxGridSize(96, 32))
            for (rows in 25..45) { c.setField("lastTmuxViewport", SharedTmuxGridSize(80, rows)); c.reconcile() }
            val ended = c.native.state.claim!!
            assertEquals(16, ended.advertisedGrids.size); assertFalse(viewport in ended.advertisedGrids)
            assertEquals(SharedTmuxGridSize(80, 45), ended.targetGrid)
            c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = snapshot(grid); c.facts()
            endExpiredShow(c)
            assertNull(c.native.state.claim); assertEquals("grid=$grid", expectedPeer, c.native.state.authority is SharedTmuxGridAuthoritySnapshot.Peer)
        }
    }
    @Test fun advertisedMembershipBelongsOnlyToTheLiveClaim() {
        val c = showClaim(); val oldGeneration = c.native.state.claim!!.generation; val keyboard = SharedTmuxGridSize(80, 18)
        c.setField("lastTmuxViewport", keyboard); c.reconcile(); assertTrue(keyboard in c.native.state.claim!!.advertisedGrids)
        c.apply(c.native.abort(scheduler.currentTime, oldGeneration, SharedTmuxAuthorityAbortReason.SUPERSEDED))
        c.setField("lastTmuxViewport", viewport); c.shown(SharedTmuxAuthorityShowSource.SHOW); c.replyTo(c.lastQuery(), "")
        val replacement = c.native.state.claim!!
        assertTrue(replacement.generation > oldGeneration); assertEquals(listOf(viewport), replacement.advertisedGrids)
        c.finishNativeClaim(replacement.generation); assertNull(c.native.state.claim); assertNull(c.carriedShow())
    }
    @Test fun aPeerResizeInsideOurReplayEchoWindowIsJudgedWhenTheWindowEnds() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); c.apply(c.native.windowSizePolicyReplied(0, 5, "latest")); c.delivered(viewport)
        c.setField("authorityTime", { 1500L }); c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = snapshot(peerGrid); c.facts()
        assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
        val due = c.native.state.nextDeadlineMillis!!
        c.apply(c.native.tick(due - 1)); assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), c.native.state.authority)
        c.apply(c.native.tick(due)); assertEquals(TmuxAuthorityPresentation.Veiled("another device"), c.presentation())
    }
    @Test fun aRecoveryThatCannotProveOwnershipJudgesTheEdgeItHeldBack() {
        val c = ready(); c.replyTo(c.lastQuery(), "v1 android-id 1 Pixel"); c.apply(c.native.windowSizePolicyReplied(0, 5, "latest"))
        c.setField("authorityTime", { 3000L })
        val taken = c.peerTakesWindow(); c.setField("ordinaryTmuxWindowRecovery", recoveryOf(taken))
        c.apply(c.native.ordinaryRecovery(3000, true)); c.facts()
        assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(1), c.native.state.authority)
        c.recoveryReply(TmuxResponsePurpose.OrdinaryWindowAuthority(1), true, listOf(RECOVERY_STAMP))
        c.recoveryReply(TmuxResponsePurpose.OrdinaryWindowControlClient(1), false, emptyList())
        assertTrue(c.field<PendingTmuxOrdinaryWindowRecovery>("ordinaryTmuxWindowRecovery").completed)
        assertEquals(TmuxAuthorityPresentation.Veiled("another device"), c.presentation())
    }
    @Test fun unchangedWindowAndLocalFactsNeverCrossJni() {
        val c = ready(); c.replyTo(c.lastQuery(), OWN_STAMP); val h = c.harness; val before = h.submissions
        repeat(1000) { c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = snapshot(viewport).copy(revision = it.toLong()); c.facts() }
        assertEquals(before, h.submissions)
        c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = snapshot(viewport).copy(isActiveWindowAuthoritative = false); c.facts()
        assertEquals(before + 1, h.submissions)
        repeat(1000) { c.facts() }; assertEquals(before + 1, h.submissions)
    }
    private fun showClaim(seed: SharedTmuxGridSize = viewport): SshSessionController {
        val c = ready(snapshot = snapshot(seed), measured = seed); c.replyTo(c.lastQuery(), OWN_STAMP)
        c.shown(SharedTmuxAuthorityShowSource.SHOW)
        c.setField("lastTmuxViewport", viewport); c.field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = snapshot(viewport); c.facts()
        c.replyTo(c.lastQuery(), ""); assertNotNull(c.native.state.claim)
        c.apply(c.native.windowSizePolicyReplied(scheduler.currentTime, 5, "latest"))
        return c
    }
    private fun endExpiredShow(c: SshSessionController) {
        c.setField("authorityTime", { scheduler.currentTime + 20_001L })
        c.failClaim(c.native.state.claim!!.generation, "adapter failure after gesture expired")
        assertNull(c.carriedShow())
        c.field<TmuxResponsePurpose.AuthorityRederive?>("pendingAuthorityQuery")?.let { c.replyTo(it, OWN_STAMP) }
    }

    private fun SshSessionController.facts() {
        javaClass.getDeclaredMethod("submitAuthorityGeometryFacts", SharedTmuxSnapshot::class.java)
            .apply { isAccessible = true }.invoke(this, field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value)
    }

    private val SshSessionController.native get() = field<TmuxAuthorityReducer>("tmuxAuthorityLifecycle").session
    private val SshSessionController.harness get() = nativeHarnesses.getValue(native)
    private val nativeHarnesses = mutableMapOf<SharedTmuxAuthoritySession, NativeAuthorityHarness>()
    private val subscriptions = mutableMapOf<SshSessionController, MutableList<SharedTmuxSubscriptions>>()
    private val baseSubscriptions = SharedTmuxSubscriptions(bell = true, paneMetadata = true, windowOrder = true)
    private fun SshSessionController.takeSubscriptions(): List<SharedTmuxSubscriptions> =
        subscriptions.getValue(this).toList().also { subscriptions.getValue(this).clear() }
    private fun ready(h: NativeAuthorityHarness = nativeAuthority(), snapshot: SharedTmuxSnapshot? = snapshot(viewport), measured: SharedTmuxGridSize? = viewport): SshSessionController = controller(h, snapshot = snapshot).apply {
        setField("host", inlineHost)
        setField("diagnosticTransport", "ssh_tmux")
        setField("presentationActive", true)
        setField("terminalSurface", fakeSurface(paintedOwner))
        setField("declaredTmuxRenderSurfaces", listOf(liveDeclaration))
        setField("lastTmuxViewport", measured)
        setField("windowSizePolicyWindowId", 5)
        liveChannel(); probeRenderFacts()
        observe(snapshot?.authority ?: SharedTmuxGridAuthoritySnapshot.Unknown)
        facts(); apply(native.adoptShown(scheduler.currentTime)); apply(native.attached(scheduler.currentTime, "android-id"))
    }
    private fun SshSessionController.factsAfterReset() {
        setField("lastAuthorityWindowFacts", null)
        setField("lastAuthorityOrdinaryRecovery", false)
        facts()
    }
    private fun nativeAuthority(nextGeneration: Int = 0): NativeAuthorityHarness =
        NativeAuthorityHarness { scheduler.currentTime }.also { native ->
            nativeHarnesses[native.session] = native
            repeat(nextGeneration) {
                native.session.adoptShown(scheduler.currentTime)
                native.session.attached(scheduler.currentTime, "android-id")
                native.session.observedAuthority(scheduler.currentTime, peer)
                val claim = native.session.requestTakeBack(scheduler.currentTime).state.claim!!
                native.session.abort(scheduler.currentTime, claim.generation, SharedTmuxAuthorityAbortReason.SUPERSEDED)
            }
            if (nextGeneration > 0) native.session.resetTransport(scheduler.currentTime, true)
        }

    private fun awaitBlockedOn(thread: Thread, lock: Any) {
        val lockName = "${lock.javaClass.name}@${Integer.toHexString(System.identityHashCode(lock))}"
        val threads = java.lang.management.ManagementFactory.getThreadMXBean()
        val deadline = System.nanoTime() + 5_000_000_000L
        while (true) {
            val info = threads.getThreadInfo(thread.id)
            if (info?.threadState == Thread.State.BLOCKED && info.lockName == lockName) return
            check(thread.isAlive && System.nanoTime() < deadline) { "never blocked on the transport lock: ${info?.threadState}" }
            Thread.sleep(1)
        }
    }

    // region fixtures

    private fun snapshot(window: SharedTmuxGridSize) = SharedTmuxSnapshot(
        sessionName = "fixture",
        activeWindowId = 5,
        windows = listOf(
            SharedTmuxWindow(5, 0, "fixture", 7, emptyList(), false, SharedTmuxLayoutNode.Leaf(7, window.columns, window.rows)),
        ),
        authority = SharedTmuxGridAuthoritySnapshot.Unknown,
        revision = 1,
        rawJson = byteArrayOf(),
        isWindowListHydrated = true,
        isActiveWindowAuthoritative = true,
    )

    private fun controller(
        reducer: NativeAuthorityHarness,
        presentations: MutableStateFlow<TmuxAuthorityPresentation> = MutableStateFlow(TmuxAuthorityPresentation.None),
        wire: Channel<TmuxControlCommand> = Channel(Channel.UNLIMITED),
        snapshot: SharedTmuxSnapshot? = snapshot(viewport),
    ): SshSessionController =
        (unsafe.allocateInstance(SshSessionController::class.java) as SshSessionController).also(controllers::add).apply {
            setField("tmuxTransportLock", Any())
            setField("desiredTmuxSubscriptions", baseSubscriptions)
            val requests = mutableListOf<SharedTmuxSubscriptions>()
            subscriptions[this] = requests
            setField("tmuxSubscriptionsProbe", { request: SharedTmuxSubscriptions ->
                assertTrue(Thread.holdsLock(field<Any>("tmuxTransportLock")))
                requests += request
                CoreCallResult.Accepted
            })
            setField("lastProjectedTmuxAuthority", null)
            setField("tmuxAuthorityProjectionProbe", { _: SharedTmuxGridAuthoritySnapshot -> SharedTmuxClaimSettlement.Released(emptyList()) })
            setField("host", SavedHost("fixture", "fixture", "fixture.invalid", 22, "fixture", null, null,
                transportKind = TransportKinds.MOSH, tmuxMode = TmuxModes.AUTOMATIC))
            setField("diagnosticTransport", "mosh_tmux")
            setField("diagnostics", testDiagnosticLogStore())
            setField("scope", coroutineFailures.scope(StandardTestDispatcher(scheduler)))
            setField("mutableState", MutableStateFlow<SshSessionUiState>(SshSessionUiState.Connected))
            setField("tmuxAuthorityLifecycle", reducer.adapter)
            setField("mutableTmuxAuthorityPresentation", presentations)
            setField("declaredTmuxRenderSurfaces", emptyList<SharedTmuxSurfaceDeclaration>())
            setField("authorityTime", { scheduler.currentTime })
            setField("tmuxDeviceIdentity", TmuxDeviceIdentity("android-id", "Pixel"))
            setField("tmuxGridPresentation", SharedTmuxGridPresentation.PANE_GRID)
            setField("mutableTmuxSnapshot", MutableStateFlow(snapshot))
            setField("lastTmuxViewport", viewport)
            setField("pendingTmuxWindowSizeReplays", ConcurrentHashMap<Int, PendingTmuxWindowSizeReplay>())
            setField("tmuxTransportGeneration", 8L)
            setField("tmuxCommandChannel", wire)
            setField("mutableTmuxAuthority", MutableStateFlow<SharedTmuxGridAuthoritySnapshot>(SharedTmuxGridAuthoritySnapshot.Unknown))
            setField("mutableTmuxReclaimInFlight", MutableStateFlow(false))
            setField("inlineAuthorityRepaintFence", InlineAuthorityRepaintFence())
            setField("activeTmuxResponses", ConcurrentHashMap<Long, TmuxResponsePurpose>())
            setField("appForeground", true)
            // Not presented: keeps the native stamp-less layout detector out of
            // these adapter tests. D4 makes authority independent of it anyway.
            setField("presentationActive", false)
            setField("restoreSelectionApplied", true)
            setField("mutableTmuxWindowMutationState", MutableStateFlow<TmuxWindowMutationState>(TmuxWindowMutationState.Unavailable))
            setField("tmuxWindowSelectionCommand", coreWindowSelectionCommand)
            setField("tmuxWindowForceRule", CoreTmuxWindowForceRule)
            setField("tmuxLatestFenceCommand", coreLatestFenceCommand)
            setField("tmuxAuthorityStampValue", coreAuthorityStampValue)
            // What the controller's own coroutines touch, so each can run
            // (the teardown runs whatever a test left due): Main's batch
            // drain and its lock, a transport clear's mosh cleanup, the
            // selection's restore save.
            setField("tmuxRenderEffectMutex", Mutex())
            setField("pendingTmuxRenderBatches", java.util.ArrayDeque<Any>())
            setField("queuedMoshLedgerRepaintFenceBatches", java.util.ArrayDeque<List<Long>>())
            setField("moshPainterHandoff", MoshPainterHandoff())
            val fence = MoshRenderHistoryDeliveryFence { }
            setField("moshRenderHistoryFence", fence)
            setField("moshRenderHistoryRepaintRetryExecutor", MoshRenderHistoryRepaintRetryExecutor(
                scope = coroutineFailures.scope(StandardTestDispatcher(scheduler)),
                fence = fence,
                allocateRepaintRequestId = { 1L },
                forceFullRepaint = { null },
                onSequenceExhausted = { },
                onUnavailable = { },
                onPartialAttach = { },
                onRearmed = { },
                onFullFrameFailure = { },
                launchDispatcher = StandardTestDispatcher(scheduler),
            ))
            setField("renderDropSummaryLock", Any())
            setField("renderDropObserved", java.util.IdentityHashMap<TerminalSurface, Int>())
            setField("sessionId", "fixture-session")
            setField("restore", RecordingSessionRestoreRepository())
            setField("compactTmuxSizer", SharedTmuxCompactSizer())
            setField("closed", false)
            prepareInputPath()
            setField("initiallyRequestedTmuxRenderSurfaces", ConcurrentHashMap.newKeySet<String>())
            setField("mutableMoshCanvasSize", MutableStateFlow<SharedTmuxGridSize?>(null))
            setField("moshResizeRequests", Channel<Any>(Channel.CONFLATED))
            setField("tmuxScreenRenderPresentation", TmuxScreenRenderPresentation.Single)
            setField("mutableTmuxInlineHistory", MutableStateFlow(emptyMap<String, Any>()))
        }

    /** Records every value set, so a transient projection cannot hide behind conflation. */
    @OptIn(ExperimentalForInheritanceCoroutinesApi::class)
    private class RecordingStateFlow<T>(
        initial: T,
        private val delegate: MutableStateFlow<T> = MutableStateFlow(initial),
    ) : MutableStateFlow<T> by delegate {
        val history = mutableListOf<T>()
        override var value: T
            get() = delegate.value
            set(next) {
                history += next
                delegate.value = next
            }
    }

    private val peerGrid = SharedTmuxGridSize(100, 30)
    private val paintedOwner = RenderOwner(5, 7, epoch = 3, transportGeneration = 8)

    /** [snapshot] with its window's active pane listed, as an inline repaint needs. */
    private fun paneSnapshot(
        window: SharedTmuxGridSize,
        authority: SharedTmuxGridAuthoritySnapshot = SharedTmuxGridAuthoritySnapshot.Unknown,
    ) = snapshot(window).let { held ->
        held.copy(
            authority = authority,
            windows = held.windows.map { it.copy(panes = listOf(SharedTmuxPane(7, null, null, active = true))) },
        )
    }

    /** One inline take-back from [peer], driven through the adapter with the core's claim chain. */
    private class InlineTakeBack(
        val controller: SshSessionController,
        val reducer: NativeAuthorityHarness,
        val wire: Channel<TmuxControlCommand>,
        val tmux: SshTmuxConnection,
        val facts: MutableList<SharedTmuxRenderFact>,
    ) {
        /** Every platform command written since the claim began, in order. */
        val sent = mutableListOf<TmuxControlCommand>()
        /** The latest settle probe a fixture took off the wire. */
        var probe: List<TmuxControlCommand> = emptyList()
        var nextReplyTag = 900L
        fun take(): List<TmuxControlCommand> =
            generateSequence { wire.tryReceive().getOrNull() }.toList().also { sent += it }
        val fences get() = sent.count { it.command == "select-window" }
        val repaints get() = facts.count {
            it is SharedTmuxRenderFact.CorrelatedRefreshRequested || it is SharedTmuxRenderFact.CorrelatedTransportFullFrameRequested
        }
    }

    /**
     * Yielded to [peer] with the window at [window], a painted live surface
     * mounted, the window's policy `latest`, and tapped: the claim's fence
     * is on the wire, unanswered.
     */
    private fun inlineTakeBack(
        window: SharedTmuxGridSize = viewport,
        measured: SharedTmuxGridSize? = viewport,
        mosh: Boolean = false,
        advertisedSideChannelSize: SharedTmuxGridSize? = null,
        backgroundWindow: SharedTmuxGridSize? = null,
    ): InlineTakeBack {
        val reducer = nativeAuthority(nextGeneration = 7)
        val wire = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        val snapshot = paneSnapshot(window).let { held ->
            // @6, not current: the claim settles on @5.
            backgroundWindow?.let { size ->
                held.copy(windows = held.windows + SharedTmuxWindow(
                    6, 1, "background", 8, listOf(SharedTmuxPane(8, null, null, active = true)), false,
                    SharedTmuxLayoutNode.Leaf(8, size.columns, size.rows),
                ))
            } ?: held
        }
        val controller = controller(reducer, wire = wire, snapshot = snapshot)
        if (!mosh) {
            controller.setField("host", inlineHost)
            controller.setField("diagnosticTransport", "ssh_tmux")
        }
        controller.setField("tmuxScreenRenderPresentation", TmuxScreenRenderPresentation.Single)
        controller.setField("declaredTmuxRenderSurfaces", listOf(
            SharedTmuxSurfaceDeclaration(TMUX_RENDER_LIVE_SURFACE_ID, SharedTmuxSurfacePresentation.Single, 5, 7),
        ))
        controller.setField("terminalSurface", fakeSurface(paintedOwner))
        controller.setField("windowSizePolicyKnown", true)
        controller.setField("windowSizePolicyIsLatest", true)
        controller.setField("windowSizePolicyWindowId", 5)
        controller.setField("lastTmuxViewport", measured)
        controller.prepareInputPath()
        controller.setField("mutableTmuxRenderHistory", MutableStateFlow<Map<String, TmuxRenderHistoryReady>>(emptyMap()))
        // A reply drained with the shell runtime installed writes its next
        // command (the settle probe) to the wire, as with no runtime.
        controller.setField("tmuxPlatformCommandProbe", { command: TmuxControlCommand -> wire.trySend(command).isSuccess })
        val tmux = controller.liveConnection()
        val facts = controller.probeRenderFacts()
        advertisedSideChannelSize?.let { size ->
            check(mosh)
            val ledger = controller.clientSizeLedger(SharedTmuxRenderProfile.SideChannel)
            ledger.submit(SharedTmuxRenderFact.ClientSize(size.columns, size.rows))
            assertEquals(listOf("refresh-client -C ${size.columns},${size.rows}"), wire.drainWire())
            controller.setField("tmuxRenderFactProbe", { fact: SharedTmuxRenderFact ->
                facts += fact
                ledger.submit(fact)
            })
        }
        controller.setField("presentationActive", true)
        controller.facts()
        controller.apply(reducer.session.adoptShown(scheduler.currentTime))
        controller.apply(reducer.session.attached(scheduler.currentTime, "android-id"))
        controller.replyTo(controller.lastQuery(), "v1 ipad-id 4 iPad")
        controller.observe(peer)
        controller.apply(reducer.session.paintable(scheduler.currentTime, true))
        wire.drainWire()
        controller.apply(reducer.session.requestTakeBack(scheduler.currentTime))
        return InlineTakeBack(controller, reducer, wire, tmux, facts)
    }

    /**
     * [inlineTakeBack] over a window already at our grid, its fence
     * acknowledged: the claim confirmed and asked for its visible repaint,
     * which the ledger has not answered (iOS: `makeConfirmedTakeBack`). The
     * settle probe found the window at our grid, so the geometry [landed]
     * (§6.10 rule 5); otherwise its reads are still on the wire, in
     * [InlineTakeBack.probe].
     */
    private fun InlineTakeBack.expirePresentation() {
        scheduler.advanceTimeBy(3000)
        scheduler.runCurrent()
    }

    private fun confirmedMoshTakeBack(landed: Boolean = true): InlineTakeBack {
        val takeBack = inlineTakeBack(mosh = true)
        val begin = takeBack.take()
        assertEquals(listOf("resize-window -x 80 -y 24 -t @5", "select-window", "set-option -w -u -t @5 window-size",
            CLAIM_POLICY_READ, "display-message -p ''"), begin.map { it.command })
        begin.filter { it.purpose is TmuxResponsePurpose.WindowSizeReplayMutation }.forEach { takeBack.reply(it) }
        val confirmation = takeBack.take().single()
        assertTrue(confirmation.purpose is TmuxResponsePurpose.WindowSizeReplayConfirmation)
        takeBack.reply(begin.single { it.purpose is TmuxResponsePurpose.AuthorityWindowSizePolicy }, lines = listOf("latest"))
        takeBack.reply(begin.single { it.purpose is TmuxResponsePurpose.AuthorityClaimFence })
        val probe = takeBack.takeSettleProbe()
        assertEquals("the window force awaits its proof", SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, takeBack.reducer.claim!!.phase)
        takeBack.reply(confirmation, lines = listOf("tessera-window-size\t@5\t80\t24"))
        takeBack.probe = probe
        if (landed) takeBack.answerSettleProbe(probe, viewport)
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, takeBack.reducer.claim!!.phase)
        assertEquals(landed, takeBack.reducer.claim!!.geometryLanded)
        return takeBack
    }

    private fun confirmedInlineTakeBack(landed: Boolean = true): InlineTakeBack {
        val takeBack = inlineTakeBack()
        takeBack.answerFence(takeBack.takeFence())
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, takeBack.reducer.claim?.phase)
        assertEquals(1, takeBack.repaints)
        takeBack.probe = takeBack.takeSettleProbe()
        if (landed) {
            takeBack.answerSettleProbe(takeBack.probe, viewport)
            assertEquals(true, takeBack.reducer.claim?.geometryLanded)
            assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, takeBack.reducer.claim?.phase)
        }
        return takeBack
    }

    /**
     * [confirmedInlineTakeBack], presented, its repaint answered: the stamp
     * is on the wire, unanswered, and the stamp-less rule is the core's.
     */
    private fun stampedInlineTakeBack(): InlineTakeBack {
        val takeBack = confirmedInlineTakeBack()
        takeBack.controller.setField("presentationActive", true)
        takeBack.repaintAnswered()
        assertEquals(listOf(OWN_STAMP_WRITE), takeBack.take().map { it.command })
        assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_STAMP_COMMIT, takeBack.reducer.claim?.phase)
        return takeBack
    }

    /**
     * The stamp's commit, then the settlement it leads to. The commit's
     * reply hands settlement to the session runtime, which this fixture
     * does not build, so the reducer hears the commit directly.
     */
    private fun InlineTakeBack.settle() {
        controller.apply(reducer.session.stampCommitSucceeded(scheduler.currentTime, 8))
        synchronized(controller.field<Any>("tmuxTransportLock")) {
            controller.javaClass.getDeclaredMethod("settleTmuxGridAuthority", Long::class.javaPrimitiveType!!)
                .apply { isAccessible = true }.invoke(controller, 8L)
        }
    }

    /** The session's current window moves to [windowId], at [window], as tmux reports a `select-window`. */
    private fun InlineTakeBack.moveTo(windowId: Int, window: SharedTmuxGridSize) {
        val held = controller.heldSnapshot()
        val moved = held.copy(
            activeWindowId = windowId,
            windows = held.windows.filter { it.id != windowId } + SharedTmuxWindow(
                windowId, 1, "other", 9, listOf(SharedTmuxPane(9, null, null, active = true)), false,
                SharedTmuxLayoutNode.Leaf(9, window.columns, window.rows),
            ),
        )
        controller.deliver(SharedTmuxEvent(moved, emptyList(), emptyList(), emptyList()), tmux)
    }

    /**
     * Feeds reach the painted live surface, with their bytes resolved in
     * place of the runtime. Resolving them also withdraws the shell
     * [drainCallbacks] installs only so Main executes the batch at all: a
     * command the batch leads to (the stamp) is then written as with no
     * runtime, like every other command in this fixture.
     */
    private fun InlineTakeBack.admitFeeds() {
        controller.setField("tmuxRenderBytesProbe", { _: Long ->
            controller.setField("tmuxCore", null)
            SharedTmuxRenderBytes.Available(byteArrayOf(0x41))
        })
        controller.setField("terminalSurface", fakeSurface(paintedOwner, feeds = true))
    }

    /** [effects] in a runtime callback of their own, queued until Main drains it. */
    private fun InlineTakeBack.queueRender(vararg effects: SharedTmuxRenderEffect) {
        controller.deliver(SharedTmuxEvent(controller.heldSnapshot(), emptyList(), emptyList(), effects.toList()), tmux)
    }

    /**
     * The ledger's answer to the claim's visible refresh as the core
     * delivers it: the capture's feed, then its completion, in one callback
     * batch that Main executes ([admitFeeds] first).
     */
    private fun InlineTakeBack.queueRepaintAnswer() = queueRender(
        SharedTmuxRenderEffect.Feed(
            TMUX_RENDER_LIVE_SURFACE_ID,
            SharedTmuxRenderOwner(5, 7, 3),
            41,
            SharedTmuxRenderFeedSource.ViewportRefresh,
        ),
        SharedTmuxRenderEffect.RefreshCompleted(
            TMUX_RENDER_LIVE_SURFACE_ID,
            SharedTmuxRenderOwner(5, 7, 3),
            SharedTmuxRenderStage.ViewportOnly,
            8,
        ),
    )

    /** A runtime event whose snapshot has the window at [window]. */
    private fun InlineTakeBack.layout(
        window: SharedTmuxGridSize,
        authority: SharedTmuxGridAuthoritySnapshot = SharedTmuxGridAuthoritySnapshot.Unknown,
    ) = controller.deliver(SharedTmuxEvent(
        paneSnapshot(window, authority), emptyList(), emptyList(), emptyList(),
        authorityStamps = (authority as? SharedTmuxGridAuthoritySnapshot.Peer)?.let {
            listOf("v1 ${it.deviceId} ${it.generation} ${it.displayName}")
        }.orEmpty(),
    ), tmux)

    /** [command]'s success, delivered and drained ([queueReply]). */
    private fun InlineTakeBack.reply(
        command: TmuxControlCommand,
        window: SharedTmuxGridSize? = null,
        success: Boolean = true,
        lines: List<String> = emptyList(),
    ) {
        queueReply(command, window, success, lines)
        drainCallbacks()
    }

    /**
     * The settle probe the latest fence's acknowledgement wrote (§6.10 rule
     * 5), in a write of its own: the window's size.
     */
    private fun InlineTakeBack.takeSettleProbe(): List<TmuxControlCommand> =
        take().also { assertEquals(listOf(SETTLE_SIZE_READ), it.map(TmuxControlCommand::command)) }

    /** [probe]'s answer: the window at [window]. */
    private fun InlineTakeBack.answerSettleProbe(probe: List<TmuxControlCommand>, window: SharedTmuxGridSize) {
        reply(probe.single(), lines = listOf("tessera-window-size\t@5\t${window.columns}\t${window.rows}"))
    }

    /** An inline claim fence as written: its own policy read of @5, then the targetless fence. */
    private data class FenceWrite(val policy: TmuxControlCommand, val fence: TmuxControlCommand) {
        val purpose get() = fence.purpose as TmuxResponsePurpose.AuthorityClaimFence
    }

    /** The inline claim fence on the wire, and nothing else. */
    private fun InlineTakeBack.takeFence(policyRead: String = CLAIM_POLICY_READ): FenceWrite = take().let { sent ->
        assertEquals(listOf(policyRead, "select-window"), sent.map(TmuxControlCommand::command))
        FenceWrite(sent[0], sent[1])
    }

    /** [write]'s replies in wire order: the window's [policy], then the fence's, with [window] as its layout if given. */
    private fun InlineTakeBack.answerFence(write: FenceWrite, policy: String = "latest", window: SharedTmuxGridSize? = null) {
        reply(write.policy, lines = listOf(policy))
        reply(write.fence, window = window)
    }

    /** Whether the claim fence's own policy read fixes [windowId]'s size for claim [generation]. */
    private fun InlineTakeBack.policyIsFixed(windowId: Int, generation: Long): Boolean =
        controller.javaClass.getDeclaredMethod("authorityClaimPolicyIsFixed", Int::class.javaPrimitiveType!!,
            Long::class.javaPrimitiveType!!).apply { isAccessible = true }.invoke(controller, windowId, generation) as Boolean

    /** Confirmations the session made, each with the repaint it requested. */
    private val InlineTakeBack.confirmations get() =
        reducer.effects.count { it is SharedTmuxAuthoritySessionEffect.RequestRepaint }

    /**
     * Main's drain of every queued callback batch. It runs only for a live
     * runtime, so a shell stands in for it here and nowhere else: the
     * claim's own calls into the native core stay skipped, as throughout
     * this fixture, and only a feed would call into the shell.
     */
    private fun InlineTakeBack.drainCallbacks() {
        controller.setField("tmuxCore", staleRuntime())
        try {
            scheduler.runCurrent()
        } finally {
            controller.setField("tmuxCore", null)
        }
        assertEquals(
            "every queued reply reached the adapter",
            emptySet<Long>(),
            controller.field<ConcurrentHashMap<Long, TmuxResponsePurpose>>("activeTmuxResponses").keys.filter { it >= 900 }.toSet(),
        )
    }

    /**
     * [command]'s success as the core delivers it: a command reply in a
     * runtime callback, with [window] as that callback's layout if given,
     * which the adapter only handles once Main drains the callback's batch.
     */
    private fun InlineTakeBack.queueReply(
        command: TmuxControlCommand,
        window: SharedTmuxGridSize? = null,
        success: Boolean = true,
        lines: List<String> = emptyList(),
    ) {
        val tag = nextReplyTag++
        controller.field<ConcurrentHashMap<Long, TmuxResponsePurpose>>("activeTmuxResponses")[tag] = command.purpose!!
        val reply = SharedTmuxRenderEffect.CommandReply(tag, success = success, lines = lines)
        val snapshot = window?.let { paneSnapshot(it) } ?: controller.heldSnapshot()
        controller.deliver(SharedTmuxEvent(snapshot, emptyList(), emptyList(), listOf(reply)), tmux)
    }

    /**
     * The ledger's completion of the claim's visible refresh, through the
     * inline fence's own receipt: a repaint the claim stopped counting is
     * ignored, and only a complete one reaches the stamp.
     */
    private fun InlineTakeBack.repaintAnswered() {
        val fence = controller.field<InlineAuthorityRepaintFence>("inlineAuthorityRepaintFence")
        val receipt = fence.noteCompletion(
            correlation = 8,
            surfaceId = TMUX_RENDER_LIVE_SURFACE_ID,
            owner = SharedTmuxRenderOwner(5, 7, 3),
            stage = SharedTmuxRenderStage.ViewportOnly,
            frameAdmitted = true,
            boundOwner = paintedOwner,
            batchEpoch = fence.epoch,
        )
        if (receipt == InlineAuthorityRepaintFence.Receipt.Complete) {
            controller.javaClass.getDeclaredMethod("finishLedgerAuthorityRepaint")
                .apply { isAccessible = true }.invoke(controller)
        }
    }

    private fun SshSessionController.presentation(): TmuxAuthorityPresentation =
        field<MutableStateFlow<TmuxAuthorityPresentation>>("mutableTmuxAuthorityPresentation").value

    private fun SshSessionController.observe(authority: SharedTmuxGridAuthoritySnapshot) {
        apply(harness.adapter.submit(scheduler.currentTime) { session, now -> session.observedAuthority(now, authority) })
    }

    private fun SshSessionController.apply(result: SharedTmuxAuthoritySessionResult) {
        javaClass.getDeclaredMethod("applyTmuxAuthorityLifecycle", SharedTmuxAuthoritySessionResult::class.java)
            .apply { isAccessible = true }.invoke(this, result)
    }

    private fun SshSessionController.refusal(): String? =
        javaClass.getDeclaredMethod("tmuxAuthorityMutationRefusal").apply { isAccessible = true }.invoke(this) as String?

    /** Accepts every render fact in place of the native runtime, recording each. */
    private fun SshSessionController.probeRenderFacts(): MutableList<SharedTmuxRenderFact> {
        val facts = mutableListOf<SharedTmuxRenderFact>()
        setField("tmuxRenderFactProbe", { fact: SharedTmuxRenderFact -> facts += fact; true })
        return facts
    }

    /** A control connection the listener accepts as current; it sends nothing itself. */
    private fun SshSessionController.liveConnection(): SshTmuxConnection =
        (unsafe.allocateInstance(SshTmuxConnection::class.java) as SshTmuxConnection)
            .also { setField("tmuxConnection", it) }

    private fun SshSessionController.heldSnapshot(): SharedTmuxSnapshot =
        field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value!!

    /** One runtime callback, exactly as the core delivers it for [tmux]. */
    private fun SshSessionController.deliver(event: SharedTmuxEvent, tmux: SshTmuxConnection, generation: Long = 8L) {
        javaClass.getDeclaredMethod(
            "handleTmuxRuntimeEvent",
            SharedTmuxEvent::class.java,
            SshTmuxConnection::class.java,
            Long::class.javaPrimitiveType!!,
        ).apply { isAccessible = true }.invoke(this, event, tmux, generation)
    }

    private fun outputEvent(snapshot: SharedTmuxSnapshot, bytesRef: Long) = SharedTmuxEvent(
        snapshot = snapshot,
        bells = emptyList(),
        agentStates = emptyList(),
        renderEffects = listOf(
            SharedTmuxRenderEffect.Feed(
                TMUX_RENDER_LIVE_SURFACE_ID,
                SharedTmuxRenderOwner(5, 7, 1),
                bytesRef,
                SharedTmuxRenderFeedSource.PaneOutput,
            ),
        ),
    )

    private fun SshSessionController.pendingRenderBatches(): Int =
        field<java.util.ArrayDeque<*>>("pendingTmuxRenderBatches").size

    private fun Channel<TmuxControlCommand>.drain(): List<String> =
        generateSequence { tryReceive().getOrNull()?.command }.toList()

    /** Every command written, a ledger transaction's whole run included. */
    private fun Channel<TmuxControlCommand>.drainWire(): List<String> = drainTransactions().flatten()

    /** Each queue element's commands: one ledger run, or one platform command. */
    private fun Channel<TmuxControlCommand>.drainTransactions(): List<List<String>> =
        generateSequence { tryReceive().getOrNull()?.wireCommands }.toList()

    /**
     * The core's client-size ledger in place of the runtime, attached on
     * [profile] (null: published but not yet attached). Its replays reach
     * this controller's writer the way a runtime callback's do.
     */
    private fun SshSessionController.clientSizeLedger(
        profile: SharedTmuxRenderProfile? = SharedTmuxRenderProfile.Inline,
    ): CoreClientSizeLedger {
        val ledger = CoreClientSizeLedger { effects ->
            javaClass.getDeclaredMethod(
                "enqueueLedgerRenderCommands",
                List::class.java,
                SshTmuxConnection::class.java,
                Long::class.javaPrimitiveType!!,
            ).apply { isAccessible = true }.invoke(
                this,
                effects,
                field<SshTmuxConnection>("tmuxConnection"),
                field<Long>("tmuxTransportGeneration"),
            )
        }
        setField("tmuxRenderFactProbe", { fact: SharedTmuxRenderFact -> ledger.submit(fact) })
        setField("tmuxRenderLedgerOptionsProbe", { options: Int -> ledger.setOptions(options) })
        profile?.let { ledger.submit(SharedTmuxRenderFact.TransportAttached(it)) }
        setField("lastPublishedTmuxSize", null)
        return ledger
    }

    /** A side-channel ledger whose connection already advertised [size]. */
    private fun SshSessionController.advertisedOnSideChannel(size: SharedTmuxGridSize) {
        val wire = field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        clientSizeLedger(SharedTmuxRenderProfile.SideChannel)
            .submit(SharedTmuxRenderFact.ClientSize(size.columns, size.rows))
        assertEquals(listOf("refresh-client -C ${size.columns},${size.rows}"), wire.drainWire())
    }

    /** The attach's hand-over of the transport to the ledger, for the current connection unless [tmux]/[generation] say otherwise. */
    private fun SshSessionController.attachRenderTransport(
        profile: SharedTmuxRenderProfile,
        tmux: SshTmuxConnection? = field("tmuxConnection"),
        generation: Long = field("tmuxTransportGeneration"),
    ): Boolean =
        javaClass.getDeclaredMethod(
            "attachTmuxRenderTransport",
            SharedTmuxRenderProfile::class.java,
            SshTmuxConnection::class.java,
            Long::class.javaPrimitiveType!!,
        ).apply { isAccessible = true }.invoke(this, profile, tmux, generation) as Boolean

    /**
     * The attach's hand-over on a new connection, with the runtime's own
     * answer: the core calls back synchronously from inside the attach fact,
     * and the adapter handles that event (reconcile included) before the
     * attach returns. Returns the connection's writer.
     */
    private fun SshSessionController.attachWithRuntimeCallback(
        profile: SharedTmuxRenderProfile,
    ): Channel<TmuxControlCommand> {
        val tmux = liveConnection()
        val ledger = clientSizeLedger(profile = null)
        val event = SharedTmuxEvent(snapshot(viewport), emptyList(), emptyList(), emptyList())
        setField("tmuxRenderFactProbe", { fact: SharedTmuxRenderFact ->
            ledger.submit(fact).also {
                if (fact is SharedTmuxRenderFact.TransportAttached) {
                    deliver(event, tmux, field("tmuxTransportGeneration"))
                }
            }
        })
        attachRenderTransport(profile)
        return field("tmuxCommandChannel")
    }

    /** The rest of the state a key's own bookkeeping and the runtime listener touch. */
    private fun SshSessionController.prepareInputPath() {
        setField("paneSurfaces", ConcurrentHashMap<Int, TerminalSurface>())
        setField("overlaySurfaces", ConcurrentHashMap<Int, TerminalSurface>())
        setField("moshHistoryPresentationAcknowledgements", MoshHistoryPresentationAcknowledgements<TerminalSurface>())
        setField("mutableTmuxRenderHistory", MutableStateFlow(emptyMap<String, Any>()))
    }

    /** What the terminal surface runs for an admitted key before sending it. */
    private fun SshSessionController.userInput() {
        javaClass.getDeclaredMethod("noteTmuxRenderUserInput").apply { isAccessible = true }.invoke(this)
    }

    private fun SshSessionController.beginRepaint(generation: Long) {
        synchronized(field<Any>("tmuxTransportLock")) {
            javaClass.getDeclaredMethod("beginTmuxGridAuthorityRepaint", Long::class.javaPrimitiveType!!)
                .apply { isAccessible = true }.invoke(this, generation)
        }
    }


    private fun SshSessionController.replayBeforeNewWindow() {
        javaClass.getDeclaredMethod("replayTmuxClientGeometryBeforeWindowCreation", SharedTmuxSnapshot::class.java)
            .apply { isAccessible = true }
            .invoke(this, field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value)
    }

    /** The typed window selection the tab strip and Agent Center share. */
    private fun SshSessionController.selectWindow(target: String): Boolean =
        javaClass.getDeclaredMethod("selectTmuxWindow", String::class.java, CompletableDeferred::class.java)
            .apply { isAccessible = true }.invoke(this, target, null) as Boolean

    /** One shared-runtime command, awaited through its suspensions. */
    private suspend fun SshSessionController.performSuspending(command: SharedBackendCommand): Unit =
        suspendCoroutineUninterceptedOrReturn { continuation ->
            try {
                javaClass.getDeclaredMethod("perform", SharedBackendCommand::class.java, Continuation::class.java)
                    .apply { isAccessible = true }.invoke(this, command, continuation)
            } catch (failure: java.lang.reflect.InvocationTargetException) {
                throw failure.targetException
            }
        }

    /** One shared-runtime command, for the branches that never suspend. */
    private fun SshSessionController.perform(command: SharedBackendCommand) {
        javaClass.getDeclaredMethod("perform", SharedBackendCommand::class.java, Continuation::class.java)
            .apply { isAccessible = true }
            .invoke(this, command, Continuation<Unit>(EmptyCoroutineContext) { it.getOrThrow() })
    }

    /**
     * The endpoint requires a route owner it never uses for tmux sends:
     * an unconnected one, so any route use fails the test.
     */
    private fun connectedRouteOwner(): SshRouteOwner {
        val sshClient = object : net.schmizz.sshj.SSHClient() {
            override fun isConnected() = true
            override fun isAuthenticated() = true
            override fun close() {}
        }
        val constructor = SshRouteOwner::class.java.declaredConstructors.single { it.parameterTypes.size == 2 }
        constructor.isAccessible = true
        return constructor.newInstance(sshClient, emptyList<java.io.Closeable>()) as SshRouteOwner
    }

    private fun unusedRouteOwner(): SshRouteOwner {
        val sshClient = Class.forName("net.schmizz.sshj.SSHClient").getDeclaredConstructor().newInstance()
        val constructor = SshRouteOwner::class.java.declaredConstructors.single { it.parameterTypes.size == 2 }
        constructor.isAccessible = true
        return constructor.newInstance(sshClient, emptyList<java.io.Closeable>()) as SshRouteOwner
    }

    private fun SshSessionController.lastQuery(): TmuxResponsePurpose.AuthorityRederive =
        field("pendingAuthorityQuery")

    private fun SshSessionController.replyTo(purpose: TmuxResponsePurpose.AuthorityRederive, raw: String) {
        val responses = field<ConcurrentHashMap<Long, TmuxResponsePurpose>>("activeTmuxResponses")
        val tag = 100L + purpose.sequence
        responses[tag] = purpose
        javaClass.getDeclaredMethod(
            "handleTmuxPlatformReply",
            Long::class.javaPrimitiveType!!,
            Boolean::class.javaPrimitiveType!!,
            List::class.java,
        ).apply { isAccessible = true }.invoke(this, tag, true, listOf(raw))
    }

    /** The steady `window-size` probe's reply for [windowId]. */
    private fun SshSessionController.policyReply(windowId: Int, value: String) {
        val responses = field<ConcurrentHashMap<Long, TmuxResponsePurpose>>("activeTmuxResponses")
        val tag = 900L + windowId
        responses[tag] = TmuxResponsePurpose.WindowSizePolicy(windowId)
        javaClass.getDeclaredMethod(
            "handleTmuxPlatformReply",
            Long::class.javaPrimitiveType!!,
            Boolean::class.javaPrimitiveType!!,
            List::class.java,
        ).apply { isAccessible = true }.invoke(this, tag, true, listOf(value))
    }

    /** A client size the ledger accepted as ordinary geometry (not a claim's). */
    private fun SshSessionController.publishClient(size: SharedTmuxGridSize, claim: Boolean) {
        javaClass.getDeclaredMethod(
            "publishTmuxClientSize", SharedTmuxGridSize::class.java,
            Boolean::class.javaPrimitiveType!!, Boolean::class.javaPrimitiveType!!,
            java.lang.Long::class.java,
        ).apply { isAccessible = true }.invoke(this, size, claim, false, null)
    }

    private fun SshSessionController.delivered(size: SharedTmuxGridSize) {
        javaClass.getDeclaredMethod(
            "noteDeliveredTmuxClientSize",
            SharedTmuxGridSize::class.java,
        ).apply { isAccessible = true }.invoke(this, size)
    }

    /**
     * The real transport reset a Mosh side-channel drop runs, then the
     * reattach's fresh channel. Its cleanup post is queued on Main, which
     * [withMainOnTestScheduler] provides and nothing here advances.
     */
    private fun SshSessionController.resetTransportAndReattach() {
        setField("paneSurfaces", ConcurrentHashMap<Int, TerminalSurface>())
        setField("overlaySurfaces", ConcurrentHashMap<Int, TerminalSurface>())
        setField("renderDropSummaryLock", Any())
        setField("initiallyRequestedTmuxRenderSurfaces", ConcurrentHashMap.newKeySet<String>())
        setField("agentTmuxControl", TmuxAgentControlPort())
        setField("pendingTmuxRenderBatches", java.util.ArrayDeque<Any>())
        setField("renderTimers", ConcurrentHashMap<Long, Any>())
        setField("moshHistoryPresentationAcknowledgements", MoshHistoryPresentationAcknowledgements<TerminalSurface>())
        setField("mutableTmuxRenderHistory", MutableStateFlow(emptyMap<String, Any>()))
        setField("tmuxInlineHistoryTimeouts", ConcurrentHashMap<String, Any>())
        setField("mutableTmuxInlineHistory", MutableStateFlow(emptyMap<String, Any>()))
        javaClass.getDeclaredMethod(
            "clearTmuxTransport",
            Boolean::class.javaPrimitiveType!!,
            Boolean::class.javaPrimitiveType!!,
        ).apply { isAccessible = true }.invoke(this, true, true)
        setField("tmuxCommandChannel", Channel<TmuxControlCommand>(Channel.UNLIMITED))
        setField("activeTmuxResponses", ConcurrentHashMap<Long, TmuxResponsePurpose>())
    }

    /**
     * Runs the work each test left due, then checks that no callback batch
     * was queued without its drain. A test asserts on queued state and need
     * not run what follows it, but that work must neither fail
     * ([coroutineFailures] reports it) nor be lost.
     */
    @After
    fun everyQueuedBatchWasDrained() {
        try {
            withMainOnTestScheduler { scheduler.runCurrent() }
            for (controller in controllers) {
                val stranded = controller.field<java.util.ArrayDeque<*>?>("pendingTmuxRenderBatches")?.size ?: 0
                assertEquals("callback batches queued with no drain to run them", 0, stranded)
            }
        } finally {
            controllers.forEach { it.field<kotlinx.coroutines.CoroutineScope?>("scope")?.cancel() }
            nativeHarnesses.values.forEach { it.close() }
        }
    }

    private fun withMainOnTestScheduler(body: () -> Unit) {
        Dispatchers.setMain(StandardTestDispatcher(scheduler))
        try {
            body()
        } finally {
            Dispatchers.resetMain()
        }
    }


    private fun SshSessionController.liveChannel() {
        setField("tmuxConnection", unsafe.allocateInstance(SshTmuxConnection::class.java))
        setField("tmuxCore", staleRuntime())
        val wire = field<Channel<TmuxControlCommand>>("tmuxCommandChannel")
        setField("tmuxPlatformCommandProbe", { command: TmuxControlCommand -> wire.trySend(command).isSuccess })
    }

    private fun SshSessionController.viewportAfterAttach(size: SharedTmuxGridSize) {
        val state = TerminalSurfaceState(
            columns = size.columns, rows = size.rows, alternateScreen = false, mouseTracking = false,
            mouseMode = TerminalMouseMode.entries.first(), focused = true, cursorRow = 0, cursorColumn = 0,
            cursorVisible = true, topRow = 0, bracketedPaste = false,
        )
        javaClass.getDeclaredMethod("reconcileTmuxViewportAfterAttach", TerminalSurfaceState::class.java)
            .apply { isAccessible = true }.invoke(this, state)
    }

    private fun SshSessionController.admit(surface: TerminalSurface): Boolean =
        javaClass.getDeclaredMethod("admitTmuxTerminalInput", TerminalSurface::class.java)
            .apply { isAccessible = true }.invoke(this, surface) as Boolean

    private fun SshSessionController.geometryWithheld(): Boolean =
        javaClass.getDeclaredMethod("ordinaryTmuxGeometryWithheld").apply { isAccessible = true }.invoke(this) as Boolean

    private fun SshSessionController.reconcile(forceAllWindows: Boolean = false) {
        synchronized(field<Any>("tmuxTransportLock")) { reconcileOutsideTheLock(forceAllWindows) }
    }

    /**
     * A reconcile as the Resize command, the grid presentation and the read's
     * own delivery start it: not holding the transport lock.
     */
    private fun SshSessionController.reconcileOutsideTheLock(forceAllWindows: Boolean = false) {
        javaClass.getDeclaredMethod(
            "reconcileTmuxClientSize",
            SharedTmuxSnapshot::class.java,
            Boolean::class.javaPrimitiveType!!,
        ).apply { isAccessible = true }
            .invoke(this, field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value, forceAllWindows)
    }

    /** runTmuxTransport's start of [tmux]'s render transport: attach, facts, then the lifecycle's read. */
    private fun SshSessionController.startRenderTransport(tmux: SshTmuxConnection, generation: Long = 8L): Boolean =
        javaClass.getDeclaredMethod(
            "startTmuxRenderTransport",
            SshTmuxConnection::class.java,
            Long::class.javaPrimitiveType!!,
        ).apply { isAccessible = true }.invoke(this, tmux, generation) as Boolean

    /**
     * A runtime whose native handle is already gone, as after a teardown race:
     * every command it is asked to queue comes back stale, so the send fails.
     */
    private fun staleRuntime(): SharedTmuxRuntime {
        val core = unsafe.allocateInstance(TmuxCoreRuntime::class.java) as TmuxCoreRuntime
        core.setField("nativeHandle", AtomicLong(0))
        return (unsafe.allocateInstance(SharedTmuxRuntime::class.java) as SharedTmuxRuntime)
            .also { it.setField("core", core) }
    }



    private fun SshSessionController.releaseForPlainShell() {
        javaClass.getDeclaredMethod("releaseTmuxAuthorityForPlainShell").apply { isAccessible = true }.invoke(this)
    }



    private fun SshSessionController.sendClaimFence(generation: Long) {
        synchronized(field<Any>("tmuxTransportLock")) {
            javaClass.getDeclaredMethod(
                "sendTmuxGridAuthorityFence",
                Long::class.javaPrimitiveType!!,
                String::class.java,
            ).apply { isAccessible = true }.invoke(this, generation, "test")
        }
    }

    private fun SshSessionController.applyRestoredSelection() {
        synchronized(field<Any>("tmuxTransportLock")) {
            javaClass.getDeclaredMethod("applyInitialTmuxSelection", SharedTmuxSnapshot::class.java)
                .apply { isAccessible = true }
                .invoke(this, field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value)
        }
    }

    /** The elapsed clock's lead over the coroutine clock: time a stalled `delay` never saw. */
    private class ShowClock { var offset = 0L }

    /** A fresh store (the process singleton is not reset between JVM tests) on the test scheduler. */
    private fun withStore(body: (LiveSessionStore, ShowClock) -> Unit) {
        Dispatchers.setMain(StandardTestDispatcher(scheduler))
        val store = LiveSessionStore::class.java.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
        val clock = ShowClock()
        store.showClock = { scheduler.currentTime + clock.offset }
        try {
            body(store, clock)
        } finally {
            try {
                scheduler.runCurrent()
            } finally {
                // These controllers are allocated without transports; their native
                // authority harnesses are closed by @After. Still close every
                // store-owned show tracker through the production removal path.
                controllers.forEach { it.setField("closed", true) }
                store.closeAll()
                store.scope.cancel()
                Dispatchers.resetMain()
            }
        }
    }

    private fun key(session: String = "s1") = LiveSessionStore.ControllerKey("host", session, null, null)

    private fun LiveSessionStore.open(key: LiveSessionStore.ControllerKey, controller: SshSessionController): SshSessionController {
        controller.setField("authorityTime", { showClock() })
        return controller(key) { controller }
    }

    private fun advanceShowSettle() {
        scheduler.runCurrent()
        scheduler.advanceTimeBy(LiveSessionStore.SHOW_SETTLE_MILLIS)
        scheduler.runCurrent()
    }

    private fun SshSessionController.showEdges(): List<String> =
        harness.calls.filter { it == "hidden" || it.startsWith("shown:") }

    private fun assertShowTrackerClosed(tracker: SharedTmuxShowEdges, now: Long) {
        val failure = runCatching { tracker.tick(nowMillis = now) }.exceptionOrNull()
        assertTrue("closed trackers reject reductions through their public API", failure is IllegalStateException)
        assertEquals("tmux show edges are closed", failure?.message)
    }


    private val liveDeclaration = SharedTmuxSurfaceDeclaration(TMUX_RENDER_LIVE_SURFACE_ID, SharedTmuxSurfacePresentation.Single)

    /** The screen's render bookkeeping, with a terminal attached and the live surface declared. */
    private fun SshSessionController.mountLiveSurface() {
        setField("moshHistoryPresentationAcknowledgements", MoshHistoryPresentationAcknowledgements<TerminalSurface>())
        setField("mutableTmuxRenderHistory", MutableStateFlow<Map<String, TmuxRenderHistoryReady>>(emptyMap()))
        setField("initiallyRequestedTmuxRenderSurfaces", ConcurrentHashMap.newKeySet<String>())
        setField("declaredTmuxRenderSurfaces", emptyList<SharedTmuxSurfaceDeclaration>())
        remountLiveSurface()
    }

    /** What the screen's dispose does: withdraw its declarations, then detach. */
    private fun SshSessionController.unmountLiveSurface() {
        declareTmuxRenderSurfaces(emptyList())
        setField("terminalSurface", null)
    }

    /** A remount: a new terminal attaches, then Compose declares the live surface. */
    private fun SshSessionController.remountLiveSurface() {
        setField("terminalSurface", fakeSurface())
        declareTmuxRenderSurfaces(listOf(liveDeclaration))
    }

    private fun SshSessionController.failClaim(generation: Long, detail: String) {
        synchronized(field<Any>("tmuxTransportLock")) {
            javaClass.getDeclaredMethod("abortTmuxGridAuthorityClaim", Long::class.javaPrimitiveType!!, String::class.java)
                .apply { isAccessible = true }.invoke(this, generation, detail)
        }
    }

    /**
     * The stamp-less detector, presented, under `window-size latest` for the
     * rendered window, judged by the shared session.
     */
    private fun SshSessionController.judgeStamplessPeersLikeTheCore() {
        setField("presentationActive", true)
        setField("windowSizePolicyKnown", true)
        setField("windowSizePolicyIsLatest", true)
        setField("windowSizePolicyWindowId", 5)
    }

    /** A plain client's resize: our window now has its size. */
    private fun SshSessionController.peerTakesWindow(): SharedTmuxSnapshot =
        snapshot(SharedTmuxGridSize(160, 47)).also {
            field<MutableStateFlow<SharedTmuxSnapshot?>>("mutableTmuxSnapshot").value = it
        }

    /** The ordinary recovery the snapshot's reconcile starts for [taken] (its stamp is ours). */
    private fun recoveryOf(taken: SharedTmuxSnapshot) = PendingTmuxOrdinaryWindowRecovery(
        token = 1, transportGeneration = 8, windowId = 5, requested = viewport, observed = SharedTmuxGridSize(160, 47),
        authorityGeneration = 1, expectedStamp = RECOVERY_STAMP, policyIsLatest = true, publishedAtRequest = viewport,
        viewport = viewport, layout = taken.activeWindow?.layout, activePaneId = taken.activePaneId,
        presentation = SharedTmuxGridPresentation.PANE_GRID, observing = false,
    )

    private fun SshSessionController.recoveryReply(purpose: TmuxResponsePurpose, success: Boolean, lines: List<String>) {
        val responses = field<ConcurrentHashMap<Long, TmuxResponsePurpose>>("activeTmuxResponses")
        val tag = 700L + responses.size
        responses[tag] = purpose
        javaClass.getDeclaredMethod(
            "handleTmuxPlatformReply",
            Long::class.javaPrimitiveType!!,
            Boolean::class.javaPrimitiveType!!,
            List::class.java,
        ).apply { isAccessible = true }.invoke(this, tag, success, lines)
    }

    /**
     * A surface nothing is called on but its bound owner (the refusal hook
     * only records it) and the scroll routing each drained snapshot sets.
     */
    /** [feeds]: admits a feed for [boundOwner], as the surface does; otherwise a feed is unexpected. */
    private fun fakeSurface(boundOwner: RenderOwner? = null, feeds: Boolean = false): TerminalSurface =
        Proxy.newProxyInstance(TerminalSurface::class.java.classLoader, arrayOf(TerminalSurface::class.java)) { proxy, method, args ->
            when (method.name) {
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args?.firstOrNull()
                "toString" -> "fakeSurface"
                "getBoundOwner" -> boundOwner
                "feed" -> if (feeds && args?.size == 2) args[0] == boundOwner else throw UnsupportedOperationException(method.name)
                "getDroppedForeignFeeds" -> 0
                "setMouseReportingImpliesAltScreen", "setRemoteTmuxPane", "setPainterFeedAdmission" -> null
                else -> throw UnsupportedOperationException(method.name)
            }
        } as TerminalSurface

    @Suppress("UNCHECKED_CAST")
    private fun <T> Any.field(name: String): T =
        javaClass.getDeclaredField(name).apply { isAccessible = true }.get(this) as T

    private fun Any.setField(name: String, value: Any?) {
        javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value)
    }

    private companion object {
        /** This device's own stamp as the fixture's identity writes it. */
        const val OWN_STAMP = "v1 android-id 2 Pixel"
        /** The stamp write of claim 8 by this fixture's device. */
        const val OWN_STAMP_WRITE = "set-option @tessera_authority 'v1 android-id 8 Pixel'"
        /** A claim fence's own policy read of window @5, queued ahead of the fence (M4). */
        const val CLAIM_POLICY_READ = "show-options -wA -v -t @5 window-size"
        /** The settle probe's size read of window @5 (§6.10 rule 5), written once the fence is answered. */
        const val SETTLE_SIZE_READ =
            "display-message -p -t @5 'tessera-window-size\t#{window_id}\t#{window_width}\t#{window_height}'"
        /** The stamp an ordinary recovery expects for our generation 1. */
        const val RECOVERY_STAMP = "v1 android-id 1 Pixel"
        /**
         * A store tick that never clears its deadline would reschedule itself
         * at zero delay forever inside `advanceTimeBy`: fail rather than hang.
         */
        const val STORE_TEST_TIMEOUT_MS = 20_000L
        val unsafe: sun.misc.Unsafe = sun.misc.Unsafe::class.java
            .getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null) as sun.misc.Unsafe
    }

    // endregion
}
