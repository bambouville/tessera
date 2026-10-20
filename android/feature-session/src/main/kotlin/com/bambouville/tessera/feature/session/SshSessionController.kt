package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentSessionKey
import com.bambouville.tessera.agent.platform.AgentSessionRegistration
import com.bambouville.tessera.agent.platform.AgentTmuxControlAck
import com.bambouville.tessera.agent.platform.LiveAgentSessionRegistry
import com.bambouville.tessera.core.bridge.CoreCallResult
import com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySession
import com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySessionResult
import com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySessionState
import com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySessionEffect
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityActiveWindow
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityCarriedShow
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityGeometryHold
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityGeometryRelease
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityAbortReason
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityPromptScope
import com.bambouville.tessera.core.bridge.SharedBackendCommand
import com.bambouville.tessera.core.bridge.SharedCommandAuthorityGate
import com.bambouville.tessera.core.bridge.SharedChallengeDecision
import com.bambouville.tessera.core.bridge.SharedConnectionIntent
import com.bambouville.tessera.core.bridge.SharedRedaction
import com.bambouville.tessera.core.bridge.SharedMoshServerLiveness
import com.bambouville.tessera.core.bridge.SharedMoshServerLivenessPolicy.Outcome
import com.bambouville.tessera.core.bridge.SharedSessionEvent
import com.bambouville.tessera.core.bridge.SharedTmuxLaunch
import com.bambouville.tessera.core.bridge.SharedTmuxLaunchFailure
import com.bambouville.tessera.core.bridge.SharedSessionCommandCompletion
import com.bambouville.tessera.core.bridge.SharedSessionCommandReceipt
import com.bambouville.tessera.core.bridge.SharedSessionCommandResult
import com.bambouville.tessera.core.bridge.SharedSessionListener
import com.bambouville.tessera.core.bridge.SharedSessionPolicy
import com.bambouville.tessera.core.bridge.SharedTmuxClaimSettlement
import com.bambouville.tessera.core.bridge.SharedTmuxCellRect
import com.bambouville.tessera.core.bridge.SharedTmuxCommands
import com.bambouville.tessera.core.bridge.SharedTmuxEvent
import com.bambouville.tessera.core.bridge.SharedTmuxPlatformWireCommand
import com.bambouville.tessera.core.bridge.SharedSessionRuntime
import com.bambouville.tessera.core.bridge.SharedSessionState
import com.bambouville.tessera.core.bridge.SharedTerminalOutputReceipt
import com.bambouville.tessera.core.bridge.SharedForwardingState
import com.bambouville.tessera.core.bridge.SharedTmuxRuntime
import com.bambouville.tessera.core.bridge.SharedTmuxSubscriptions
import com.bambouville.tessera.core.bridge.SharedTmuxCommandSubmission
import com.bambouville.tessera.core.bridge.SharedTmuxRenderBytes
import com.bambouville.tessera.core.bridge.SharedTmuxRenderEffect
import com.bambouville.tessera.core.bridge.SharedTmuxRenderFact
import com.bambouville.tessera.core.bridge.SharedTmuxRenderHistoryPlacement
import com.bambouville.tessera.core.bridge.SharedTmuxRenderLedgerOptions
import com.bambouville.tessera.core.bridge.SharedTmuxRenderMouseMode
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.core.bridge.SharedTmuxRenderProfile
import com.bambouville.tessera.core.bridge.SharedTmuxRenderStage
import com.bambouville.tessera.core.bridge.SharedTmuxSurfaceDeclaration
import com.bambouville.tessera.core.bridge.SharedTmuxSurfacePresentation
import com.bambouville.tessera.core.bridge.SharedTmuxCompactReprojection
import com.bambouville.tessera.core.bridge.SharedTmuxCompactSizer
import com.bambouville.tessera.core.bridge.SharedTmuxBell
import com.bambouville.tessera.core.bridge.SharedAutomaticTmuxTarget
import com.bambouville.tessera.core.bridge.SharedTmuxGridPresentation
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityClaimPhase
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityClaimReason
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityLifecycleClaim
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityShowSource
import com.bambouville.tessera.core.bridge.SharedTmuxGridSize
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import com.bambouville.tessera.core.bridge.SharedTmuxWindowSizeReplay
import com.bambouville.tessera.core.bridge.SharedTmuxPaneKey
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.core.bridge.SharedProgramStatusSnapshot
import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminal
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.authorityGate
import com.bambouville.tessera.data.CredentialKinds
import com.bambouville.tessera.data.HostRepository
import com.bambouville.tessera.data.HostTrustEvaluation
import com.bambouville.tessera.data.IdentityRepository
import com.bambouville.tessera.data.KnownHostKeys
import com.bambouville.tessera.data.KnownHostsRepository
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.SessionRestoreRecord
import com.bambouville.tessera.data.SessionRestoreRepository
import com.bambouville.tessera.data.continuity.SessionRestorePolicy
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.AuthenticatedForwardingSideChannel
import com.bambouville.tessera.networking.SshRouteConstruction
import com.bambouville.tessera.networking.SshAuthentication
import com.bambouville.tessera.networking.SshEndpoint
import com.bambouville.tessera.networking.SshHostKeyObservation
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshKeyAuthorizationProvider
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRouteHop
import com.bambouville.tessera.networking.SshRouteRequest
import com.bambouville.tessera.networking.SshRouteOwner
import com.bambouville.tessera.networking.SshFileConnection
import com.bambouville.tessera.networking.SshTerminalConnection
import com.bambouville.tessera.networking.SshTmuxConnection
import com.bambouville.tessera.networking.mosh.AndroidMoshTransport
import com.bambouville.tessera.networking.mosh.AndroidSshMoshBootstrapper
import com.bambouville.tessera.networking.mosh.JniMoshNativeClientFactory
import com.bambouville.tessera.networking.mosh.MoshBootstrapRequest
import com.bambouville.tessera.networking.mosh.MoshConnectRequest
import com.bambouville.tessera.networking.mosh.MoshConnectionState
import com.bambouville.tessera.networking.mosh.MoshInputNotAdmittedException
import com.bambouville.tessera.networking.mosh.MoshOutageTiming
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardingManager
import com.bambouville.tessera.forwarding.PortForwardingState
import com.bambouville.tessera.forwarding.PortForwardingStatus
import com.bambouville.tessera.terminal.RemoteTmuxPane
import com.bambouville.tessera.terminal.RenderOwner
import com.bambouville.tessera.terminal.TerminalMouseMode
import com.bambouville.tessera.terminal.TerminalSurface
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import com.bambouville.tessera.lifecycle.DiagnosticLogStore
import java.io.InputStream
import android.security.keystore.KeyPermanentlyInvalidatedException
import java.util.ArrayDeque
import java.util.IdentityHashMap
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.yield

sealed interface SshSessionUiState {
    data object Disconnected : SshSessionUiState
    data object Connecting : SshSessionUiState
    data class AwaitingCredential(val challenge: CredentialChallenge) : SshSessionUiState
    data class AwaitingHostKey(val challenge: HostKeyChallenge) : SshSessionUiState
    data class AwaitingOwnerAuthorization(val challenge: OwnerAuthorizationChallenge) : SshSessionUiState
    data object Connected : SshSessionUiState
    /** The remote shell/session ended normally; this is not a reconnectable network failure. */
    data object Terminated : SshSessionUiState
    data class Failed(val message: String) : SshSessionUiState
}

/** UI-facing admission/result state for tmux window ordering mutations. */
internal sealed interface TmuxWindowMutationState {
    data object Unavailable : TmuxWindowMutationState
    data object Available : TmuxWindowMutationState
    data object Pending : TmuxWindowMutationState
    data class Error(val message: String) : TmuxWindowMutationState
}

/** Presentation-neutral side-channel history handoff for a mounted overlay. */
internal data class TmuxRenderHistoryReady(
    /** Incremented for every delivery, including a same-shaped refill. */
    val deliveryToken: Long,
    val surfaceId: String,
    val owner: SharedTmuxRenderOwner,
    val depth: Int,
    val historySize: Int,
    val placement: SharedTmuxRenderHistoryPlacement,
)

/** Client-only modes that tmux capture-pane cannot describe on older servers. */
internal class TmuxRenderClientModeStore {
    private data class Key(val windowId: Int, val paneId: Int?)
    private val bracketedPasteByOwner = mutableMapOf<Key, Boolean>()

    fun save(windowId: Int, paneId: Int?, bracketedPaste: Boolean) {
        bracketedPasteByOwner[Key(windowId, paneId)] = bracketedPaste
    }

    fun bracketedPaste(windowId: Int, paneId: Int?): Boolean =
        bracketedPasteByOwner[Key(windowId, paneId)] ?: false
}

/** Exact tmux identity stamped by the visible Mosh client at bootstrap. */
internal data class TmuxVisibleClientIdentity(
    val name: String,
    val pid: Long,
    val created: Long,
)

/**
 * Pure validation for the two-step visible-client proof used by mosh+tmux
 * window selection. Values cross a tmux command boundary, so ambiguity and
 * control characters fail closed before a client-targeted mutation is built.
 */
internal object TmuxVisibleClientSelection {
    fun windowId(target: String): Int? {
        if (target.length !in 2..16 || target.firstOrNull() != '@') return null
        val digits = target.drop(1)
        if (digits.isEmpty() || !digits.all { it in '0'..'9' }) return null
        return digits.toIntOrNull()?.takeIf { it >= 0 }
    }

    fun paneId(target: String): Int? {
        if (target.length !in 2..16 || target.firstOrNull() != '%') return null
        val digits = target.drop(1)
        if (digits.isEmpty() || !digits.all { it in '0'..'9' }) return null
        return digits.toIntOrNull()?.takeIf { it >= 0 }
    }

    fun singleStampedIdentity(lines: List<String>): Pair<String, TmuxVisibleClientIdentity>? {
        val values = lines.filter(String::isNotBlank)
        if (values.size != 1) return null
        val stamp = values.single()
        return stamp to (identity(stamp) ?: return null)
    }

    fun identity(stamp: String): TmuxVisibleClientIdentity? {
        val fields = stamp.split('|')
        if (fields.size != 3) return null
        val name = fields[0]
        if (!fields[1].all { it in '0'..'9' } || !fields[2].all { it in '0'..'9' }) return null
        val pid = fields[1].toLongOrNull()
        val created = fields[2].toLongOrNull()
        if (name.isBlank() || name.length > 100 || name.any(Char::isISOControl)) return null
        if (pid == null || pid <= 0 || created == null || created <= 0) return null
        return TmuxVisibleClientIdentity(name, pid, created)
    }

    fun isExactlyAttached(stamp: String, attachedLines: List<String>): Boolean =
        attachedLines.count { it == stamp } == 1

    fun isCurrent(
        expectedWindowId: Int,
        expectedPaneId: Int? = null,
        expectedSession: String,
        expectedSelectionGeneration: Long,
        expectedTransportGeneration: Long,
        currentWindowIds: Set<Int>,
        currentActiveWindowId: Int?,
        currentActivePaneId: Int? = null,
        currentSession: String?,
        currentSelectionGeneration: Long,
        currentTransportGeneration: Long,
        mutationAdmitted: Boolean,
        requireActiveWindow: Boolean = true,
    ): Boolean = mutationAdmitted &&
        expectedWindowId in currentWindowIds &&
        // A selection callback may arrive after an external tmux client has
        // changed the active window.  The ledger snapshot is authoritative
        // for that active target, so never let an old local proof pull the
        // pixel-producing Mosh client back to its stale window.
        (!requireActiveWindow || (
            expectedWindowId == currentActiveWindowId &&
                (expectedPaneId == null || expectedPaneId == currentActivePaneId)
        )) &&
        expectedSession == currentSession &&
        expectedSelectionGeneration == currentSelectionGeneration &&
        expectedTransportGeneration == currentTransportGeneration

    fun quotedArgument(value: String): String? {
        if (value.isBlank() || value.length > 100 || value.any(Char::isISOControl)) return null
        return "'${value.replace("'", "'\\''")}'"
    }

    fun qualifiedTarget(session: String, windowId: Int, paneId: Int? = null): String? {
        if (quotedArgument(session) == null || windowId < 0 || (paneId != null && paneId < 0)) return null
        // Bare @window/%pane ids are shared by grouped sessions. Switching
        // a visible client by id alone can silently leave its mosh view.
        val address = "$session:@$windowId" + (paneId?.let { ".%$it" } ?: "")
        return "'${address.replace("'", "'\\''")}'"
    }
}

/**
 * One exact control transport epoch. Reducer effects are born on a particular
 * `tmux -CC` connection; neither their commands nor their follow-up facts may
 * cross onto a replacement channel which happens to occupy the same fields.
 */
internal object TmuxTransportEpochGate {
    fun isCurrent(
        closed: Boolean,
        expectedConnection: Any,
        expectedGeneration: Long,
        currentConnection: Any?,
        currentGeneration: Long,
    ): Boolean = !closed &&
        expectedConnection === currentConnection &&
        expectedGeneration == currentGeneration
}

internal object TmuxWindowMutationContext {
    fun isCurrent(
        closed: Boolean,
        expectedConnection: Any,
        expectedRuntime: Any,
        expectedGeneration: Long,
        expectedSession: String,
        currentConnection: Any?,
        currentRuntime: Any?,
        currentGeneration: Long,
        currentSession: String?,
    ): Boolean = !closed &&
        expectedConnection === currentConnection &&
        expectedRuntime === currentRuntime &&
        expectedGeneration == currentGeneration &&
        expectedSession == currentSession

}

private fun PortForwardingStatus.sharedStateName(): String = when (this) {
    PortForwardingStatus.Idle -> "idle"
    PortForwardingStatus.Starting -> "starting"
    is PortForwardingStatus.Listening -> "listening"
    is PortForwardingStatus.Active -> "active"
    is PortForwardingStatus.Failed -> "failed"
}

internal data class TmuxControlCommand(
    val command: String,
    /** Platform commands enter the core-owned FIFO; ledger commands already did. */
    val purpose: TmuxResponsePurpose? = null,
    val ledgerOwned: Boolean = false,
    /** The core FIFO slot this request already holds; trace evidence only. */
    val fifoTag: Long? = null,
    /**
     * A contiguous ledger effect run must remain contiguous on the one tmux
     * control wire.  A channel element is therefore a wire transaction, not
     * necessarily just one control command.  Platform requests keep the
     * one-command default because each is individually enqueued in the core
     * FIFO and has one platform reply purpose.
     */
    val wireCommands: List<String> = listOf(command),
) {
    init {
        require(wireCommands.isNotEmpty()) { "tmux control transaction must contain a command" }
        require(wireCommands.none(String::isBlank)) { "tmux control transaction contains a blank command" }
        require(!ledgerOwned || purpose == null) { "ledger commands cannot carry a platform reply purpose" }
    }
}

private data class PendingAuthorityMoshRepaint(
    val requestId: Long,
    val outputTarget: Long,
    val claimGeneration: Long,
    /** Null while the live surface has no ledger owner yet (untagged painter feed). */
    val owner: RenderOwner?,
)

/**
 * One issue of a ledger-held transport frame reservation that has not been
 * forced yet, because the painter handoff still owns the surface. The owner is
 * whichever the ledger named; a reservation taken before the surface's first
 * bind carries none, and its frame rides the untagged painter feed.
 */
private data class DeferredAuthorityMoshRepaint(
    val claimGeneration: Long,
    val requestId: Long,
    val owner: RenderOwner?,
)

/**
 * One reducer effect batch, held until the main-thread executor reaches it.
 *
 * The transport identity travels with the batch: a queued batch outlives the
 * connection it was produced for, and the executor must be able to tell that
 * before it touches a surface.
 */
private class PendingTmuxRenderBatch(
    val effects: List<SharedTmuxRenderEffect>,
    val tmux: SshTmuxConnection,
    val transportGeneration: Long,
    /**
     * The inline authority repaint current when the batch was queued
     * ([InlineAuthorityRepaintFence.epoch]). Main drains a batch after IO
     * may have begun a newer repaint for the same claim generation, and a
     * completion queued before it belongs to the older one.
     */
    val repaintEpoch: Long,
)

/**
 * A verified visible-client switch whose Mosh painter still needs a causal
 * redraw.  The tmux control reply proves the server mutation, but it does not
 * prove that the independent Mosh driver has consumed the resulting screen.
 */
private data class PendingVisibleClientRefresh(
    val windowId: Int,
    val paneId: Int?,
    val session: String,
    val selectionGeneration: Long,
    val transportGeneration: Long,
    val clientName: String,
)

private enum class TmuxWindowMutationKind { REORDER, RENUMBER }

internal data class PendingTmuxWindowSizeReplay(
    val token: Long,
    val transportGeneration: Long,
    val requested: SharedTmuxGridSize,
    val confirmationCommand: String,
    val resizeSucceeded: Boolean? = null,
    val fenceSucceeded: Boolean? = null,
    val policyRestoreSucceeded: Boolean? = null,
    val confirmationQueued: Boolean = false,
    val failureDiagnosed: Boolean = false,
    /**
     * A claim force whose confirmation read another size, kept as iOS keeps
     * it: unproved (the claim's settle probe proves it, or its loss forces
     * again), but with nothing of its own left on the wire.
     */
    val confirmationAnswered: Boolean = false,
    /** Passive proof must remain retryable even after its layout context changes. */
    val passiveRecovery: Boolean = false,
) {
    val readyToConfirm: Boolean
        get() = resizeSucceeded == true && fenceSucceeded == true && policyRestoreSucceeded == true && !confirmationQueued

    fun noteMutation(commandIndex: Int, success: Boolean): PendingTmuxWindowSizeReplay = when (commandIndex) {
        0 -> copy(resizeSucceeded = success)
        1 -> copy(fenceSucceeded = success)
        2 -> copy(policyRestoreSucceeded = success)
        else -> error("unknown window-size mutation")
    }
}

internal data class PendingTmuxOrdinaryWindowRecovery(
    val token: Long,
    val transportGeneration: Long,
    val windowId: Int,
    val requested: SharedTmuxGridSize,
    val observed: SharedTmuxGridSize,
    val authorityGeneration: Long,
    val expectedStamp: String,
    val policyIsLatest: Boolean,
    val publishedAtRequest: SharedTmuxGridSize?,
    val viewport: SharedTmuxGridSize?,
    val layout: SharedTmuxLayoutNode?,
    val activePaneId: Int?,
    val presentation: SharedTmuxGridPresentation,
    val observing: Boolean,
    val completed: Boolean = false,
)

/** The shared window force rule (`SharedTmuxWindowSizeReplay`), behind an interface JVM tests can stand in for. */
internal interface TmuxWindowForceRule {
    fun decision(
        requested: SharedTmuxGridSize,
        observed: SharedTmuxGridSize?,
        lastAttempt: SharedTmuxGridSize?,
    ): SharedTmuxWindowSizeReplay.Decision

    fun commands(windowId: Int, requested: SharedTmuxGridSize): List<String>

    /** The tagged size read alone, which a claim writes as its settle probe (§6.10 rule 5). */
    fun sizeQuery(windowId: Int): String

    /** The grid a [sizeQuery] reply reports for [windowId], or null for a malformed one. */
    fun reportedGeometry(windowId: Int, reply: String): SharedTmuxGridSize?

    object Shared : TmuxWindowForceRule {
        override fun decision(
            requested: SharedTmuxGridSize,
            observed: SharedTmuxGridSize?,
            lastAttempt: SharedTmuxGridSize?,
        ) = SharedTmuxWindowSizeReplay.decision(requested, observed, lastAttempt)

        override fun commands(windowId: Int, requested: SharedTmuxGridSize) =
            SharedTmuxWindowSizeReplay.commands(windowId, requested)

        override fun sizeQuery(windowId: Int) = SharedTmuxWindowSizeReplay.sizeQuery(windowId)

        override fun reportedGeometry(windowId: Int, reply: String) =
            SharedTmuxWindowSizeReplay.reportedGeometry(windowId, reply)
    }
}

/** One mutation bound to the exact runtime/control-channel epoch that admitted it. */
private data class PendingTmuxWindowMutation(
    val token: Long,
    val kind: TmuxWindowMutationKind,
    val expectedOrder: List<Int>,
    val sourceOrder: List<Int>,
    val sessionName: String,
    val tmux: SshTmuxConnection,
    val runtime: SharedTmuxRuntime,
    val transportGeneration: Long,
    val commands: List<String> = emptyList(),
    val mutationCommandCount: Int = 0,
    val nextCommandIndex: Int = 0,
    val mutationStarted: Boolean = false,
    val hadFailure: Boolean = false,
    val awaitingTruth: Boolean = false,
    val timeoutJob: Job? = null,
)

/**
 * Credentials retained only long enough to retire the exact detached
 * `mosh-server` after an explicit user disconnect. Unexpected transport loss
 * deliberately discards this lease without killing the resumable server.
 */
private class PendingMoshServerCleanup(
    val intent: SharedConnectionIntent,
    val route: SshRouteRequest,
    val serverPid: Int,
    private val passwords: Map<String, CharArray>,
    val authenticatedRoute: SshRouteOwner?,
) {
    fun passwordFor(hop: SshRouteHop): CharArray =
        passwords[hop.id]?.copyOf()
            ?: error("cached credential unavailable for explicit mosh cleanup")

    fun wipe() {
        authenticatedRoute?.close()
        passwords.values.forEach { it.fill('\u0000') }
    }
}

internal sealed interface TmuxResponsePurpose {
    data object Ignore : TmuxResponsePurpose
    data object ClientFlags : TmuxResponsePurpose
    data class WindowSizePolicy(val windowId: Int) : TmuxResponsePurpose
    data class WindowSizeReplayMutation(
        val windowId: Int,
        val token: Long,
        val transportGeneration: Long,
        val requested: SharedTmuxGridSize,
        val commandIndex: Int,
    ) : TmuxResponsePurpose
    data class WindowSizeReplayConfirmation(
        val windowId: Int,
        val token: Long,
        val transportGeneration: Long,
        val requested: SharedTmuxGridSize,
    ) : TmuxResponsePurpose
    /** [ownerSessionId] is the owner scope the read targeted, null for our own session. */
    data class OrdinaryWindowAuthority(val token: Long, val ownerSessionId: Int? = null) : TmuxResponsePurpose
    data class OrdinaryWindowControlClient(val token: Long) : TmuxResponsePurpose
    data class OrdinaryWindowVisibleClient(val token: Long, val control: String) : TmuxResponsePurpose
    data class OrdinaryWindowClients(
        val token: Long, val control: String, val visible: String,
    ) : TmuxResponsePurpose
    data class CurrentDirectory(val onResult: (String?) -> Unit) : TmuxResponsePurpose
    data class CommandCompletion(val receipt: SharedSessionCommandReceipt) : TmuxResponsePurpose
    /**
     * One of a live claim's own commands, counted while its reply is out
     * ([authorityClaimCommandsInFlight]): a late claim with none left and no
     * repaint in flight cannot progress (§6.10 rule 6).
     */
    sealed interface ClaimCommand : TmuxResponsePurpose {
        val generation: Long
    }
    /**
     * The claim's own read of [windowId]'s `window-size` policy, queued
     * behind its geometry and ahead of the session's claim fence [fenceId]:
     * only this read tells that fence how the window is sized (a cached
     * policy can predate the claim, M4).
     */
    data class AuthorityWindowSizePolicy(
        override val generation: Long,
        val fenceId: Long,
        val windowId: Int,
    ) : ClaimCommand

    /**
     * The session's claim fence [fenceId] on [windowId]: inline the
     * targetless `latest` fence, on the side channel a no-op
     * `display-message` behind the window force. [epoch] is the claim
     * geometry it went out for ([authorityClaimGeometryEpoch]); an
     * acknowledgement from an older one still counts, but writes no settle
     * probe. [refence] marks the core's one re-fence after a geometry loss
     * (§6.10 rule 4), which answers under the same fence.
     */
    data class AuthorityClaimFence(
        override val generation: Long,
        val fenceId: Long,
        val windowId: Int,
        val epoch: Long,
        val refence: Boolean,
    ) : ClaimCommand

    /**
     * A claim's settle probe (§6.10 rule 5), the fenced window's size,
     * written once fence [fenceId] was acknowledged. Its reply follows the
     * fence's `%layout-change`, so the size proves where the claim's
     * geometry landed. A newer advertisement or re-fence ([epoch]) makes it
     * moot.
     */
    data class AuthoritySettleSize(
        override val generation: Long,
        val fenceId: Long,
        val windowId: Int,
        val epoch: Long,
    ) : ClaimCommand

    /**
     * A no-op behind a claim's geometry whose fence waits for the window
     * list: until its reply, the claim's own `-C` may still be on the wire,
     * and no claim aborts over its own geometry (I3).
     */
    data class AuthorityClaimOrdering(override val generation: Long) : ClaimCommand
    data class AuthorityCommit(val generation: Long, val ownerSessionId: Int? = null) : TmuxResponsePurpose
    data class AuthorityPaintGeometry(
        val generation: Long, val transportGeneration: Long, val windowId: Int, val requested: SharedTmuxGridSize,
    ) : TmuxResponsePurpose
    /** [resolution] names the resolution it answers: a session switch starts another on the same transport. */
    data class AuthorityOwnerResolution(val transportGeneration: Long, val owner: Boolean, val resolution: Long) : TmuxResponsePurpose
    /**
     * One `show-options @tessera_authority` read. [sequence] makes every query
     * distinct, so only the newest outstanding one is ever delivered to the
     * reducer: a reply queued before a show cannot stand in for the show's own
     * fresh read. [renderOwner] is the painter bound when the query was sent,
     * which a show claim's repaint preserves. [sessionId] is the control
     * client's session when it was sent, as iOS records `ownSessionId`.
     * [ownerSessionId] is the owner scope it targeted, null for our own session.
     */
    data class AuthorityRederive(
        val transportGeneration: Long,
        val sequence: Long,
        val renderOwner: RenderOwner?,
        val sessionId: Int?,
        val ownerSessionId: Int? = null,
    ) : TmuxResponsePurpose
    data class VisibleSelectionPrimary(
        /** Null for mutations such as `new-window` whose selected id is causal output. */
        val windowId: Int?,
        val paneId: Int?,
        val preservingWindowZoom: Boolean,
        val session: String,
        val selectionGeneration: Long,
        val transportGeneration: Long,
        val agentResponse: CompletableDeferred<AgentTmuxControlAck>? = null,
    ) : TmuxResponsePurpose
    data class VisibleSelectionActiveWindow(
        /** Expected id when known; null asks the strict reply to discover it. */
        val windowId: Int?,
        val paneId: Int?,
        val preservingWindowZoom: Boolean,
        val session: String,
        val selectionGeneration: Long,
        val transportGeneration: Long,
        val agentResponse: CompletableDeferred<AgentTmuxControlAck>? = null,
    ) : TmuxResponsePurpose
    data class VisibleSelectionClosePreflight(
        val windowId: Int,
        val session: String,
        val selectionGeneration: Long,
        val transportGeneration: Long,
    ) : TmuxResponsePurpose
    data class VisibleSelectionOption(
        val windowId: Int,
        val paneId: Int?,
        val preservingWindowZoom: Boolean,
        val session: String,
        val selectionGeneration: Long,
        val transportGeneration: Long,
        val agentResponse: CompletableDeferred<AgentTmuxControlAck>? = null,
    ) : TmuxResponsePurpose
    data class VisibleSelectionClients(
        val windowId: Int,
        val paneId: Int?,
        val preservingWindowZoom: Boolean,
        val session: String,
        val selectionGeneration: Long,
        val transportGeneration: Long,
        val stamp: String,
        val clientName: String,
        val agentResponse: CompletableDeferred<AgentTmuxControlAck>? = null,
    ) : TmuxResponsePurpose
    data class VisibleSelectionCommit(
        val windowId: Int,
        val paneId: Int?,
        val session: String,
        val selectionGeneration: Long,
        val transportGeneration: Long,
        val clientName: String,
        val agentResponse: CompletableDeferred<AgentTmuxControlAck>? = null,
    ) : TmuxResponsePurpose
    data class VisibleSelectionRefresh(
        val selectionGeneration: Long,
        val transportGeneration: Long,
        val clientName: String,
    ) : TmuxResponsePurpose
    data class AgentCommand(val response: CompletableDeferred<AgentTmuxControlAck>) : TmuxResponsePurpose
    data class WindowMutationCommand(val token: Long, val commandIndex: Int) : TmuxResponsePurpose
    data class WindowMutationGroupMembers(val token: Long) : TmuxResponsePurpose
}

private val TmuxResponsePurpose.agentResponse: CompletableDeferred<AgentTmuxControlAck>?
    get() = when (this) {
        is TmuxResponsePurpose.AgentCommand -> response
        is TmuxResponsePurpose.VisibleSelectionPrimary -> agentResponse
        is TmuxResponsePurpose.VisibleSelectionActiveWindow -> agentResponse
        is TmuxResponsePurpose.VisibleSelectionOption -> agentResponse
        is TmuxResponsePurpose.VisibleSelectionClients -> agentResponse
        is TmuxResponsePurpose.VisibleSelectionCommit -> agentResponse
        is TmuxResponsePurpose.VisibleSelectionRefresh -> null
        is TmuxResponsePurpose.VisibleSelectionClosePreflight -> null
        is TmuxResponsePurpose.WindowMutationCommand,
        is TmuxResponsePurpose.WindowMutationGroupMembers -> null
        else -> null
    }

/** A detached, teardown-safe port held by the Agent endpoint, never by Compose. */
internal class TmuxAgentControlPort(
    private val directResponder: (suspend (String) -> AgentTmuxControlAck)? = null,
    private val directWindowSelector: (suspend (String) -> AgentTmuxControlAck)? = null,
    private val directPaneSelector: (suspend (String, Boolean) -> AgentTmuxControlAck)? = null,
) {
    /**
     * The controller owns admission to the shared tmux command FIFO.  Keeping
     * this as a sender rather than exposing its channel prevents Agent Center
     * commands from leapfrogging an already-enqueued ledger capture.
     */
    private data class Attachment(
        val sender: (TmuxControlCommand) -> Boolean,
        val windowSelector: (String, CompletableDeferred<AgentTmuxControlAck>) -> Boolean,
        val paneSelector: (String, Boolean, CompletableDeferred<AgentTmuxControlAck>) -> Boolean,
        val refusal: () -> String?,
    )

    private val attachment = AtomicReference<Attachment?>(null)

    fun attach(
        sender: (TmuxControlCommand) -> Boolean,
        windowSelector: (String, CompletableDeferred<AgentTmuxControlAck>) -> Boolean,
        paneSelector: (String, Boolean, CompletableDeferred<AgentTmuxControlAck>) -> Boolean,
        refusal: () -> String? = { null },
    ) {
        attachment.set(Attachment(sender, windowSelector, paneSelector, refusal))
    }

    fun detach() { attachment.set(null) }

    /**
     * Why the controller would refuse a mutation now (D7), or null. Only a
     * reason for the endpoint's placement check, so a launch refused before
     * its first command reports as such rather than as a failed write: the
     * sender still decides, atomically with the enqueue.
     */
    fun mutationRefusal(): String? {
        if (directResponder != null) return null
        return attachment.get()?.refusal?.invoke()
    }

    suspend fun send(command: String): AgentTmuxControlAck {
        directResponder?.let { return it(command) }
        val target = attachment.get()?.sender ?: return AgentTmuxControlAck(false, emptyList())
        val deferred = CompletableDeferred<AgentTmuxControlAck>()
        if (!target(TmuxControlCommand(command, TmuxResponsePurpose.AgentCommand(deferred)))) {
            return AgentTmuxControlAck(false, emptyList())
        }
        return await(deferred)
    }

    /**
     * Window selection is typed because mosh+tmux must also move the stamped
     * pixel-producing client. A raw Agent command would move only the -CC
     * metadata client and let the ledger bind a window the user cannot see.
     */
    suspend fun selectWindow(target: String): AgentTmuxControlAck {
        directWindowSelector?.let { return it(target) }
        // Standalone endpoint tests may provide only a direct tmux responder;
        // production ports always install the controller-owned typed route.
        directResponder?.let { return it("select-window -t $target") }
        val selector = attachment.get()?.windowSelector
            ?: return AgentTmuxControlAck(false, emptyList())
        val deferred = CompletableDeferred<AgentTmuxControlAck>()
        if (!selector(target, deferred)) return AgentTmuxControlAck(false, emptyList())
        return await(deferred)
    }

    /** Pane counterpart to [selectWindow], including visible Mosh mirroring. */
    suspend fun selectPane(
        target: String,
        preservingWindowZoom: Boolean,
    ): AgentTmuxControlAck {
        directPaneSelector?.let { return it(target, preservingWindowZoom) }
        directResponder?.let {
            val zoom = if (preservingWindowZoom) "-Z " else ""
            return it("select-pane ${zoom}-t $target")
        }
        val selector = attachment.get()?.paneSelector
            ?: return AgentTmuxControlAck(false, emptyList())
        val deferred = CompletableDeferred<AgentTmuxControlAck>()
        if (!selector(target, preservingWindowZoom, deferred)) {
            return AgentTmuxControlAck(false, emptyList())
        }
        return await(deferred)
    }

    private suspend fun await(
        deferred: CompletableDeferred<AgentTmuxControlAck>,
    ): AgentTmuxControlAck {
        return try {
            // A missed ack is a failed command, not a cancellation: a thrown
            // timeout would read as the caller's own cancel.
            kotlinx.coroutines.withTimeoutOrNull(TMUX_AGENT_ACK_TIMEOUT_MILLISECONDS) { deferred.await() }
                ?: AgentTmuxControlAck(false, emptyList())
        } catch (failure: Throwable) {
            if (failure is CancellationException) throw failure
            AgentTmuxControlAck(false, emptyList())
        }
    }

    companion object { const val TMUX_AGENT_ACK_TIMEOUT_MILLISECONDS = 15_000L }
}

data class OwnerAuthorizationChallenge(
    val challengeId: UUID,
    val attemptId: UUID,
    val policyGeneration: Long,
    val reason: String,
)

data class CredentialChallenge(
    val hopId: String,
    val username: String,
    val host: String,
    val challengeId: UUID,
    val attemptId: UUID,
    val policyGeneration: Long,
)

data class HostKeyChallenge(
    val host: String,
    val port: Int,
    val algorithm: String,
    val fingerprint: String,
    val changed: Boolean,
    val reverted: Boolean,
    val previousFingerprint: String?,
    val challengeId: UUID,
    val attemptId: UUID,
    val policyGeneration: Long,
)

internal class SshSessionController(
    private val host: SavedHost,
    private val hosts: HostRepository,
    private val identities: IdentityRepository,
    private val knownHosts: KnownHostsRepository,
    private val restore: SessionRestoreRepository,
    private val credentialStore: AndroidKeystoreCredentialStore,
    private val diagnostics: DiagnosticLogStore,
    private val scope: CoroutineScope,
    private val agentSessions: LiveAgentSessionRegistry,
    private val backend: AndroidSshBackend = AndroidSshBackend(),
    private val initialTmuxSelection: String? = null,
    initialTmuxGridPresentation: SharedTmuxGridPresentation = SharedTmuxGridPresentation.PANE_GRID,
    /** Attempt-scoped target from a verified continuation descriptor, never a restore pane id. */
    private val tmuxSessionTargetOverride: String? = null,
    private val tmuxDeviceIdentity: TmuxDeviceIdentity,
    private val scrollbackLines: Int,
    private val sessionId: String = UUID.randomUUID().toString(),
    sessionRestorePolicy: Flow<SessionRestorePolicy> = flowOf(SessionRestorePolicy.ASK),
    private val moshServerLostMessage: () -> String = {
        "The mosh-server for this session is no longer running — the host may have restarted."
    },
) {
    private val mutableState = MutableStateFlow<SshSessionUiState>(SshSessionUiState.Disconnected)
    val state: StateFlow<SshSessionUiState> = mutableState.asStateFlow()

    /**
     * Transport-level reachability, where the transport reports one. `null`
     * means it does not, and [state] is then all there is.
     *
     * Mosh keeps its session state at connected across network loss by
     * design — that is the whole point of SSP — so at a wake `state` proves
     * nothing about a Mosh session and this is the only signal that does.
     * Without it the foreground restore window retires a Mosh zombie as alive
     * and the user comes back to a terminal that will never take another
     * keystroke. SSH has no equivalent, which is why that side leans on the
     * window's alive floor instead.
     */
    private val mutableTransportReachable = MutableStateFlow<Boolean?>(null)
    val transportReachable: StateFlow<Boolean?> = mutableTransportReachable.asStateFlow()

    private var announcedMoshOutageStart: Long? = null
    private val mutableMoshOutageTiming: MutableStateFlow<MoshOutageTiming?>? = MutableStateFlow(null)
    val moshOutageTiming = requireNotNull(mutableMoshOutageTiming).asStateFlow()

    fun claimMoshOutageAnnouncement(startedAtMillis: Long): Boolean {
        if (mutableMoshOutageTiming?.value?.startedAtMillis != startedAtMillis ||
            announcedMoshOutageStart == startedAtMillis
        ) return false
        announcedMoshOutageStart = startedAtMillis
        return true
    }

    private val mutableTmuxSnapshot = MutableStateFlow<SharedTmuxSnapshot?>(null)
    val tmuxSnapshot: StateFlow<SharedTmuxSnapshot?> = mutableTmuxSnapshot.asStateFlow()

    /**
     * OSC 7501 records. Nullable only for constructor-less test harnesses,
     * which never set it: every use is a safe call.
     */
    private val sessionProgramStatus: SessionProgramStatus? = SessionProgramStatus()

    /** What programs in this session report (OSC 7501): the raw terminal, then tmux panes. */
    val programStatus: StateFlow<SharedProgramStatusSnapshot>
        get() = sessionProgramStatus?.snapshot ?: NO_PROGRAM_STATUS

    /** Settings → Terminal → program status. Off discards every record and the raw-SSH reply. */
    fun setProgramStatusEnabled(enabled: Boolean) {
        synchronized(tmuxTransportLock) {
            if (closed) return
            sessionProgramStatus?.setEnabled(enabled, tmuxCore)
        }
    }

    /** Check this terminal's results through [through]: the user is looking at it. */
    fun acknowledgeProgramStatus(terminal: SharedProgramStatusTerminal, through: Long) {
        synchronized(tmuxTransportLock) {
            if (closed) return
            sessionProgramStatus?.acknowledge(terminal, through, tmuxCore)
        }
    }
    private val mutableTmuxWindowMutationState =
        MutableStateFlow<TmuxWindowMutationState>(TmuxWindowMutationState.Unavailable)
    val tmuxWindowMutationState: StateFlow<TmuxWindowMutationState> =
        mutableTmuxWindowMutationState.asStateFlow()
    private val mutableTmuxAuthority = MutableStateFlow<SharedTmuxGridAuthoritySnapshot>(
        SharedTmuxGridAuthoritySnapshot.Unknown,
    )
    val tmuxAuthority: StateFlow<SharedTmuxGridAuthoritySnapshot> = mutableTmuxAuthority.asStateFlow()
    private val mutableTmuxReclaimInFlight = MutableStateFlow(false)
    private val tmuxAuthorityLifecycle: TmuxAuthorityReducer = TmuxAuthorityReducer()

    /**
     * True while a claim's progress presentation is visible: from the
     * take-back gesture until the claim settles, aborts, or its presentation
     * deadline passes. Projected from the session's claim with every result,
     * as iOS derives `gridAuthorityReclaimInFlight`.
     */
    val tmuxReclaimInFlight: StateFlow<Boolean> = mutableTmuxReclaimInFlight.asStateFlow()

    /**
     * The single authority projection the screen renders and the input gate
     * reads (`none | resuming | veiled | reclaiming`). Derived from each
     * reducer result, never from `tmuxAuthority` alone, and a StateFlow, so
     * it emits only on change.
     */
    private val mutableTmuxAuthorityPresentation =
        MutableStateFlow<TmuxAuthorityPresentation>(TmuxAuthorityPresentation.None)
    internal val tmuxAuthorityPresentation: StateFlow<TmuxAuthorityPresentation> =
        mutableTmuxAuthorityPresentation.asStateFlow()

    /** O(1) typing gate derived with [tmuxAuthorityPresentation] for the input path (§6.6 input budget, M7). */
    @Volatile private var tmuxInputGated = false
    /**
     * Clears a surface's IME line mirror after its input was refused, posted
     * so it runs after the IME operation that produced the input. A JVM test
     * substitutes a recorder.
     */
    private var refusedTerminalInputImeReset: (TerminalSurface) -> Unit = { surface ->
        val view = surface.view
        view.post { view.resetImeLineContext() }
    }
    private var refusedTmuxInputCount = 0L
    var onTmuxBell: ((SharedTmuxBell) -> Unit)? = null

    private var currentIntent: SharedConnectionIntent? = null
    private var terminalSurface: TerminalSurface? = null
    private var connection: SshTerminalConnection? = null
    private var tmuxConnection: SshTmuxConnection? = null
    private val forwardingManager = PortForwardingManager(
        diagnostics = { code, values -> diagnostics.record(code, values + ("transport" to diagnosticTransport)) },
    )
    val forwardingStates: StateFlow<Map<UUID, PortForwardingState>> = forwardingManager.states
    private var forwardingRules: List<PortForwardRule> = emptyList()
    private var forwardingAttached = false
    private var forwardingSideChannel: AuthenticatedForwardingSideChannel? = null
    private var moshTransport: AndroidMoshTransport? = null
    private var moshRepaintRequestCounter = 0L
    private val moshPainterHandoff = MoshPainterHandoff()
    private var immediateMoshPainterHandoffJob: Job? = null
    private var moshPainterCausalWatchdogJob: Job? = null
    /**
     * Newest untagged Mosh delivery the terminal feed has seen. The painter
     * attaches to the same tmux session as the control client, so the frame
     * carrying a newly selected window arrives whenever mosh-server notices
     * the PTY change, in no fixed order with the ledger bind or the control
     * reply. Written on Main by the feed; read wherever a handoff opens.
     */
    @Volatile private var lastNaturalMoshDeliveryId = 0L
    private var moshPainterReceiptWatchdogJob: Job? = null
    private val queuedMoshLedgerRepaintFenceBatches = ArrayDeque<List<Long>>()
    private var deferredAuthorityMoshRepaint: DeferredAuthorityMoshRepaint? = null
    private var pendingAuthorityMoshRepaintTarget: PendingAuthorityMoshRepaint? = null
    private var authorityMoshRepaintRequestId: Long? = null
    /**
     * Owner reserved for the authority frame, including the interval after
     * forceFullRepaint starts but before its exact delivery target is known.
     */
    private var authorityMoshRepaintOwner: RenderOwner? = null
    /**
     * The very owner value the ledger named when it issued this frame, kept
     * verbatim so the acknowledgement matches the reservation exactly. The
     * projection into [RenderOwner] needs a window and a pane id and would
     * silently drop an owner that has neither.
     */
    private var authorityMoshRepaintLedgerOwner: SharedTmuxRenderOwner? = null
    private var authorityMoshAcceptedDelivery: Pair<Long, Long>? = null
    // Nullable for constructor-less controller fixtures, like sessionProgramStatus.
    private val mutableMoshPrimaryHistoryVisible: MutableStateFlow<Boolean>? = MutableStateFlow(false)
    val moshPrimaryHistoryVisible = requireNotNull(mutableMoshPrimaryHistoryVisible).asStateFlow()
    private var moshLiveHistoryRevealed = false
        set(value) {
            field = value
            mutableMoshPrimaryHistoryVisible?.value = value
        }
    private val moshRenderHistoryFence = MoshRenderHistoryDeliveryFence(
        onDelivery = ::deliverMoshRenderHistory,
    )
    private val moshRenderHistoryRepaintRetryExecutor = MoshRenderHistoryRepaintRetryExecutor(
        scope = scope,
        fence = moshRenderHistoryFence,
        allocateRepaintRequestId = ::allocateMoshRepaintRequestId,
        forceFullRepaint = { repaintRequestId -> moshTransport?.forceFullRepaint(repaintRequestId) },
        onSequenceExhausted = {
            diagnostics.record(
                "render_transport_sequence_exhausted",
                mapOf("transport" to diagnosticTransport),
            )
        },
        onUnavailable = { detail ->
            diagnostics.record(
                "render_history_repaint_unavailable",
                mapOf(
                    "detail" to detail,
                    "transport" to diagnosticTransport,
                ),
            )
        },
        onPartialAttach = { detail ->
            diagnostics.record(
                "render_history_repaint_partial_attach",
                mapOf(
                    "detail" to detail,
                    "transport" to diagnosticTransport,
                ),
            )
        },
        onRearmed = { detail ->
            diagnostics.record(
                "render_history_repaint_rearmed",
                mapOf(
                    "detail" to detail,
                    "transport" to diagnosticTransport,
                ),
            )
        },
        onFullFrameFailure = { failure ->
            diagnostics.record(
                "render_transport_full_frame_failed",
                mapOf("detail" to redactedFailure(failure), "transport" to diagnosticTransport),
            )
        },
        timing = MoshRenderHistoryRepaintRetryExecutor.Timing(
            receiptTimeoutMilliseconds = MOSH_RENDER_HISTORY_RECEIPT_TIMEOUT_MS,
        ),
    )
    private var moshOutputJob: Job? = null
    private var moshConnectivityJob: Job? = null
    private var moshServerLivenessWatcher: MoshServerLivenessWatcher? = null
    private var updateMoshServerLiveness: (() -> Unit)? = null
    // Cancellation cannot interrupt every pre-route SSHJ call. Keep a retired
    // worker/cleanup from accumulating new SSH connections on later timers.
    private val moshServerLivenessProbeSlot = MoshServerLivenessProbeSlot()
    // The probe's own owner challenge is up. Its credential screen stops this
    // activity, which must not read as the app leaving: the watcher would
    // cancel the probe and lose the answer, then ask again on return.
    @Volatile private var moshLivenessOwnerPromptPending = false
    // A probe needed the owner while the session was off screen (another tab,
    // the app lock), where nobody can answer. Showing it asks straight away.
    @Volatile private var moshLivenessDeferredForPresentation = false
    private var moshSideChannelJob: Job? = null
    private var moshAuthoritativeSize: SharedTmuxGridSize? = null
    private val mutableTmuxWindowIsPaintedWhole = MutableStateFlow(false)
    private val mutableMoshCanvasSize = MutableStateFlow<SharedTmuxGridSize?>(null)

    /**
     * The latest requested grid for this device's Mosh PTY. Compose lays the
     * terminal out at exactly this grid while Mosh paints the whole window.
     * Laying it out at the server's
     * window layout instead (a peer's 160x48 while this PTY is 50x30) is what
     * produced a scaled-down crop in the corner of the screen whenever
     * another client held the window.
     */
    val moshCanvasSize: StateFlow<SharedTmuxGridSize?> = mutableMoshCanvasSize.asStateFlow()

    /**
     * Whether the primary terminal receives the whole tmux window's paint
     * rather than the focused pane's capture. Mosh streams the window as the
     * server draws it, so a compact device must lay the terminal out at the
     * window grid and pan to the focused pane; the inline `-CC` path is fed
     * pane capture and so measures at the pane itself.
     */
    val tmuxWindowIsPaintedWhole: StateFlow<Boolean> =
        mutableTmuxWindowIsPaintedWhole.asStateFlow()
    private var moshUsingSshFallback = false
    private var routeOwner: SshRouteOwner? = null
    private var agentEndpoint: SshAgentSessionEndpoint? = null
    private var agentRegistration: AgentSessionRegistration? = null
    private var agentEndpointBindingJob: Job? = null
    private val mutableAgentEndpointBinding = MutableStateFlow<AgentEndpointBinding?>(null)
    val agentEndpointBinding: StateFlow<AgentEndpointBinding?> = mutableAgentEndpointBinding.asStateFlow()
    private val agentTmuxControl = TmuxAgentControlPort()
    private var carrierGeneration = 0L
    private var tmuxCore: SharedTmuxRuntime? = null
    private var tmuxPlatformWireAdmissionFailedGeneration: Long? = null
    /**
     * A mosh session outlives any one SSH `-CC` side channel.  Park the native
     * runtime between those retries so its logical-session render ledger keeps
     * the owners which the replacement transport must invalidate.  The ABI's
     * TransportLost transition resets only wire/parser state.
     */
    private var parkedMoshTmuxCore: SharedTmuxRuntime? = null
    private val paneSurfaces = ConcurrentHashMap<Int, TerminalSurface>()
    private val overlaySurfaces = ConcurrentHashMap<Int, TerminalSurface>()
    private val tmuxRenderClientModes = TmuxRenderClientModeStore()
    /** Exact presentation topology last declared by SshSessionScreen. */
    private var declaredTmuxRenderSurfaces: List<SharedTmuxSurfaceDeclaration> = emptyList()
    /**
     * Initial captures are adapter-owned: the shared ledger deliberately does
     * not repaint a declaration until its physical surface is mounted. Track
     * that handshake per control-transport generation and surface lifetime.
     */
    private val initiallyRequestedTmuxRenderSurfaces = ConcurrentHashMap.newKeySet<String>()
    /** Session-lifetime, identity-keyed seam totals survive surface detach. */
    private val renderDropObserved = IdentityHashMap<TerminalSurface, Int>()
    private val renderDropSummaryLock = Any()
    private var renderDroppedForeignTotal = 0L
    private var renderDropSummaryJob: Job? = null
    /** Platform-purpose replies are keyed by the shared engine FIFO tag. */
    private var activeTmuxResponses: ConcurrentHashMap<Long, TmuxResponsePurpose>? = null
    private val renderTimers = ConcurrentHashMap<Long, Job>()
    private val mutableTmuxRenderHistory = MutableStateFlow<Map<String, TmuxRenderHistoryReady>>(emptyMap())
    val tmuxRenderHistory: StateFlow<Map<String, TmuxRenderHistoryReady>> = mutableTmuxRenderHistory.asStateFlow()
    /**
     * Inline (SSH+tmux) history ladder state, one record per render surface.
     *
     * Deliberately separate from [tmuxRenderHistory]: that map is the mosh
     * side channel's *delivery* handoff and is retired by ordinary events such
     * as local input, while this is the ledger's inline `canDeepen` belief,
     * which only an `inlineHistorySettled`, an identity rebind or transport
     * loss may change.
     */
    private val mutableTmuxInlineHistory = MutableStateFlow<Map<String, InlineTmuxHistoryRecord>>(emptyMap())
    val tmuxInlineHistory: StateFlow<Map<String, InlineTmuxHistoryRecord>> =
        mutableTmuxInlineHistory.asStateFlow()
    /** Defensive release timers for an inline request the ledger never settled. */
    private val tmuxInlineHistoryTimeouts = ConcurrentHashMap<String, Job>()
    private var nextTmuxRenderHistoryDeliveryToken = 0L
    /**
     * `historyReady` only reaches Compose after the bytes have fed the exact
     * physical terminal. The registry keeps that terminal identity until its
     * `View.post` has placed the top row and acknowledged the matching token.
     */
    private val moshHistoryPresentationAcknowledgements =
        MoshHistoryPresentationAcknowledgements<TerminalSurface>()
    private val tmuxTransportLock = Any()
    /** Serializes complete callback batches even when one effect hops to IO. */
    private val tmuxRenderEffectMutex = Mutex()
    @Volatile private var tmuxTransportGeneration = 0L
    /** Latest mosh+tmux window intent; fenced independently of wire replies. */
    private var visibleClientSelectionGeneration = 0L
    /**
     * [lastNaturalMoshDeliveryId] when the latest selection intent was queued.
     * Every natural delivery above it is output tmux produced at or after the
     * `select-window`, whichever side of the ledger bind it lands on. Guarded
     * by [tmuxTransportLock].
     */
    private var visibleSelectionNaturalFloor = 0L
    /** Latest selection whose exact stamped `switch-client` reply succeeded. */
    private var visibleClientCommittedSelectionGeneration = 0L
    /**
     * Retained until a post-commit, owner-correlated full frame reaches the
     * mounted Mosh surface. Epoch churn can therefore re-arm the same proof.
     */
    private var pendingVisibleClientRefresh: PendingVisibleClientRefresh? = null
    private var pendingTmuxWindowMutation: PendingTmuxWindowMutation? = null
    private var tmuxWindowMutationToken = 0L
    private var tmuxWindowMutationError: String? = null
    private var activeVisibleClientRefreshGeneration: Long? = null
    private var acknowledgedVisibleClientRefreshGeneration: Long? = null
    private var connectionJob: Job? = null
    private var reconnectJob: Job? = null
    private var resizeDispatchJob: Job? = null
    private val resizeCoalescer = TerminalResizeCoalescer()
    private var errorReaderJob: Job? = null
    private var commandWriterJob: Job? = null
    private var commandChannel: Channel<TransportCommand>? = null
    private var tmuxCommandWriterJob: Job? = null
    private var tmuxCommandChannel: Channel<TmuxControlCommand>? = null
    /**
     * Reducer effect batches waiting for the main-thread executor, in the
     * order the reducer produced them.  Guarded by [tmuxTransportLock].
     *
     * `Dispatchers.Main.immediate` runs inline whenever the submitter is
     * already on main, so a batch produced later can reach the executor's
     * mutex ahead of one still queued on the looper.  Draining this FIFO under
     * that mutex keeps the batches in reducer order whichever coroutine wins
     * the handoff.
     */
    private val pendingTmuxRenderBatches = ArrayDeque<PendingTmuxRenderBatch>()
    private var pendingCredential: PendingCredential? = null
    private var pendingHostKey: PendingHostKey? = null
    private var pendingOwnerAuthorization: PendingOwnerAuthorization? = null
    @Volatile private var closed = false
    private var explicitDisconnect = false
    // Closing the session from the terminal chrome ends it outright: the row
    // leaves the sessions tab. That is a stronger statement than the transport
    // merely going down, and it must not be confused with close()'s own
    // teardown, which raises explicitDisconnect too.
    private var explicitClose = false
    private var transportConnected = false
    private var hasConnectedTransport = false
    private var recoveringUnexpectedDisconnect = false
    private var remoteSessionTerminated = false
    /// Set when a tmux launch failed before control mode ever engaged, so the
    /// connection job can degrade to a plain shell instead of presenting a dead
    /// session. Consumed exactly once, by the job that set it.
    private var pendingTmuxDegrade: SharedTmuxLaunchFailure? = null
    private val tmuxLaunchOutput = StringBuilder()
    private var tmuxControlEngaged = false
    /** The configured tmux launch degraded and the active renderer is now a plain SSH PTY. */
    @Volatile private var plainSshPainterActive = false
    private val mutableTmuxDegradeNotice = MutableStateFlow<String?>(null)
    val tmuxDegradeNotice: StateFlow<String?> = mutableTmuxDegradeNotice
    @Volatile private var presentationActive = false
    @Volatile private var appForeground = true
    private var reconnectAttempt = 0
    private var restoreSelectionApplied = initialTmuxSelection == null
    private var lastStoredSelection: String? = null
    private var tmuxGridPresentation = initialTmuxGridPresentation
    /** The topology Compose is actually presenting; independent of size policy. */
    private var tmuxScreenRenderPresentation = TmuxScreenRenderPresentation.None
    private var lastTmuxViewport: SharedTmuxGridSize? = null
    /**
     * The grid this device's geometry bookkeeping last handed the ledger. A
     * claim or a presentation change clears it to re-run that bookkeeping.
     * Whether the connection's client already has the grid is the ledger's
     * question, not this (P6): it remembers the `-C` it sent per connection
     * and forgets it when tmux rejects one, on attach, on transport loss and
     * on `%session-changed`.
     */
    private var lastPublishedTmuxSize: SharedTmuxGridSize? = null
    /**
     * When the last delivered client size went out, on [authorityTime]'s
     * clock. Nothing decides on it: the shared session keeps its own echo
     * window. The live height lane reads it to place its drift inside that
     * window.
     */
    @Volatile private var lastDeliveredTmuxClientSizeAtMillis: Long? = null
    /**
     * The compact canvas solver for this tmux client, and the memo that stops
     * a resize cycle should tmux ever distribute cells differently from the
     * shared model. Reset with the transport (a new client starts a new
     * count) and on every forced replay, [restartCompactTmuxSizing].
     */
    private val compactTmuxSizer = SharedTmuxCompactSizer()
    private var lastDiagnosedTmuxLayout: Pair<Int, SharedTmuxGridSize>? = null
    /** A force remains pending until its mutations and fresh post-command query succeed. */
    private val pendingTmuxWindowSizeReplays = ConcurrentHashMap<Int, PendingTmuxWindowSizeReplay>()
    private var tmuxWindowSizeReplayToken = 0L
    private var ordinaryTmuxWindowRecovery: PendingTmuxOrdinaryWindowRecovery? = null
    private var ordinaryTmuxWindowRecoveryToken = 0L
    private var presentedTmuxWindowRecoveryReserved = false
    private var reconcilingPresentedTmuxWindowSize = false
    private var pendingAuthorityPaintGeometry: TmuxResponsePurpose.AuthorityPaintGeometry? = null
    /**
     * Counts the live claim's geometry: every advertisement and the core's
     * re-fence move it on. A settle probe answers only for the geometry it
     * was written for ([TmuxResponsePurpose.AuthoritySettleSize.epoch]), as
     * iOS's `gridClaimGeometryEpoch` does: one written before a re-fence
     * would otherwise report the loss that re-fence answers as a second one.
     * Guarded by [tmuxTransportLock].
     */
    private var authorityClaimGeometryEpoch = 0L
    /**
     * The live claim's own commands ([TmuxResponsePurpose.ClaimCommand])
     * still awaiting replies, for [authorityClaimCommandsGeneration] only. A
     * late claim with none left and no repaint in flight cannot progress
     * (§6.10 rule 6). Guarded by [tmuxTransportLock].
     */
    private var authorityClaimCommandsInFlight = 0
    private var authorityClaimCommandsGeneration: Long? = null
    /**
     * The window size the live claim last reported to the core with the
     * claim as it then stood, so a snapshot that changes neither is not
     * reduced again. Guarded by [tmuxTransportLock].
     */
    private var lastAuthorityClaimObservation: Pair<SharedTmuxAuthorityLifecycleClaim, SharedTmuxGridSize>? = null
    @Volatile private var lastWithheldTmuxClientSize: Pair<SharedTmuxGridSize, String>? = null
    private val moshResizeRequests = Channel<MoshResizeRequest>(Channel.CONFLATED)
    private val moshCanvasResizeMutex = Mutex()
    private val moshResizeWriterJob = scope.launch {
        for (request in moshResizeRequests) {
            moshCanvasResizeMutex.withLock {
                if (closed || moshTransport !== request.transport || mutableMoshCanvasSize.value != request.size) {
                    return@withLock
                }
                runCatching { request.transport.resize(request.size.columns, request.size.rows) }
            }
        }
    }
    private var compactSizeRole = CompactSizeRole.Unresolved
    private var compactSizeRoleQueryAttempts = 0
    /**
     * The claim generation this adapter's own per-claim bookkeeping belongs
     * to: its commands in flight, repaint fence and Mosh frame issue. Set
     * when the session's `BeginClaim` runs here and cleared when that claim
     * ends. It holds no claim fact: the session alone knows the claim's
     * phase and what its fence proved ([SharedTmuxAuthoritySessionState.claimFence]).
     * It is what lets an abort tell its own claim from one a nested
     * reduction began, and a reply to an ended claim find nothing to act on.
     * Volatile like the shared projection: publication checks it before the
     * send checks it again under [tmuxTransportLock].
     */
    @Volatile private var pendingAuthorityRepaintGeneration: Long? = null
    /**
     * A claim whose repaint is waiting for a prerequisite: an active pane and a
     * mounted surface inline, the declared live surface its reservation is
     * taken against on Mosh.
     */
    private var deferredAuthorityRepaintGeneration: Long? = null
    private val inlineAuthorityRepaintFence = InlineAuthorityRepaintFence()
    private data class AuthorityScopeResolution(
        val transportGeneration: Long,
        val id: Long,
        var ownerReply: List<String>? = null,
        var ownReply: List<String>? = null,
        var ownerDone: Boolean = false,
        var ownDone: Boolean = false,
    )
    private var tmuxAuthorityOwnerSessionName: String? = null
    private var authorityOwnerSessionId: Int? = null
    private var authorityScopeResolution: AuthorityScopeResolution? = null
    private var lastAuthorityScopeResolutionId = 0L
    private var authoritySubscriptionRequested = false
    /** Replaced as a whole in the runtime; guarded by [tmuxTransportLock]. */
    private var desiredTmuxSubscriptions = SharedTmuxSubscriptions()
    private var heldAuthorityQueryId: Long? = null
    private var heldOrdinaryAuthorityRead: Long? = null
    private var pendingAuthorityQuery: TmuxResponsePurpose.AuthorityRederive? = null
    /** Last authority sent to this handle; compare and call under [tmuxTransportLock]. */
    private var lastProjectedTmuxAuthority: SharedTmuxGridAuthoritySnapshot? = null
    @Volatile private var lastTmuxAuthorityResult: SharedTmuxAuthoritySessionState? = null
    /** Counts reducer results applied; a nested one makes the outer stand down. */
    private var tmuxAuthorityReductions = 0L
    private var authorityWakeJob: Job? = null
    private var authorityWakeDeadline: Long? = null
    private var lastAuthorityWindowFacts: Pair<Boolean, SharedTmuxAuthorityActiveWindow?>? = null
    private var lastAuthorityLocalSize: SharedTmuxGridSize? = null
    private var authorityLocalSizeSubmitted = false
    private var lastAuthorityPaintable: Boolean? = null
    private var lastAuthorityChannelLive: Boolean? = null
    private var lastAuthorityOrdinaryRecovery: Boolean? = null

    /**
     * Milliseconds for R3's clock. Elapsed realtime, which keeps counting in
     * deep sleep (`nanoTime` does not), so an intent formed before the phone
     * slept is overdue when it wakes. A JVM test substitutes virtual time.
     */
    private var authorityTime: () -> Long = { android.os.SystemClock.elapsedRealtime() }
    /** The claim generation that has sent its first grid mutation (L2: a hide abandons one that has not). */
    private var authorityClaimWireGeneration: Long? = null
    private var foregroundAuthorityQueryOwner: RenderOwner? = null
    private var foregroundAuthorityClaimGeneration: Long? = null
    private var foregroundAuthorityClaimOwner: RenderOwner? = null
    private var windowSizePolicyKnown = false
    private var windowSizePolicyIsLatest = false
    private var windowSizePolicyWindowId: Int? = null
    /** True only while a keystroke's `UserInput` fact is being submitted; guarded by [tmuxTransportLock]. */
    private var tmuxUserInputFactInFlight = false
    /**
     * When set, accepts render facts in place of the runtime: a field so JVM
     * tests can inject refusals and count the facts a wire path submits.
     * Always null in production.
     */
    private var tmuxRenderFactProbe: ((SharedTmuxRenderFact) -> Boolean)? = null
    /**
     * When set, takes the render-ledger switches in place of the runtime,
     * like [tmuxRenderFactProbe]: true when they were accepted. Always null
     * in production.
     */
    private var tmuxRenderLedgerOptionsProbe: ((Int) -> Boolean)? = null
    /** When set, takes feed requests in place of the runtime. Always null in production. */
    private var tmuxSubscriptionsProbe: ((SharedTmuxSubscriptions) -> CoreCallResult)? = null
    /** When set, projects authority in place of the runtime. Always null in production. */
    private var tmuxAuthorityProjectionProbe: ((SharedTmuxGridAuthoritySnapshot) -> SharedTmuxClaimSettlement)? = null
    /** When set, resolves a render feed's bytes in place of the runtime. Always null in production. */
    private var tmuxRenderBytesProbe: ((Long) -> SharedTmuxRenderBytes)? = null
    /**
     * When set, takes platform commands in place of the runtime, like
     * [tmuxRenderFactProbe]: a reply handled in a drained callback batch can
     * write the next command (a settle probe). Always null in production.
     */
    private var tmuxPlatformCommandProbe: ((TmuxControlCommand) -> Boolean)? = null
    /**
     * The switches [tmuxCore] last accepted ([SharedTmuxRenderLedgerOptions]);
     * null for a runtime that has none from this controller yet. Guarded by
     * [tmuxTransportLock].
     */
    private var appliedTmuxRenderLedgerOptions: Int? = null
    /** The runtime refused its switches; logged once and not retried on that runtime. */
    private var tmuxRenderLedgerOptionsRefused = false
    /**
     * The core's `latest` fence, a targetless `select-window` (W2), for the
     * one an inline claim sends itself. A field so JVM tests, which cannot
     * load the core, can stand in for it.
     */
    private var tmuxLatestFenceCommand: () -> String = { SharedTmuxCommands.clientSizeLatestFenceCommand }
    /**
     * The core's `@tessera_authority` stamp spelling, for a claim's stamp
     * write. A field for tests that inject a failed wire operation.
     */
    private var tmuxAuthorityStampValue: (String, String, Long) -> String = { deviceId, displayName, generation ->
        SharedTmuxCommands.authorityStampValue(deviceId, displayName, generation)
    }
    /** The core's window force rule; a field for wire-failure injection in tests. */
    private var tmuxWindowForceRule: TmuxWindowForceRule = TmuxWindowForceRule.Shared
    /**
     * The core's tab-switch spelling (W2): `'$S:@W'` once tmux has named our
     * session, the bare `@W` only before it has. A field for wire-failure injection in tests.
     */
    private var tmuxWindowSelectionCommand: (windowId: Int, ownSessionId: Int?) -> String = { windowId, ownSessionId ->
        if (ownSessionId != null) SharedTmuxCommands.selectWindowInOwnSession(windowId, ownSessionId)
        else SharedTmuxCommands.selectWindow(windowId)
    }
    private val diagnosticTransport = buildString {
        append(if (host.transportKind == com.bambouville.tessera.data.TransportKinds.MOSH) "mosh" else "ssh")
        if (host.tmuxMode != TmuxModes.OFF) append("_tmux")
    }
    private val attemptPasswords = ConcurrentHashMap<String, CharArray>()
    private val pendingMoshServerCleanup = AtomicReference<PendingMoshServerCleanup?>(null)

    /**
     * User input keeps its submission order; every other command stays
     * independent. See [BackendCommandDispatcher] - a coroutine per command let
     * an autocorrect revision's DELs and characters race each other into the
     * transport.
     */
    private val backendCommands = BackendCommandDispatcher(scope) { perform(it) }
    private val shared = SharedSessionRuntime.create(object : SharedSessionListener {
        override fun onEvent(event: SharedSessionEvent) {
            scope.launch(Dispatchers.Main.immediate) { receive(event) }
        }

        override fun onBackendCommand(command: SharedBackendCommand) {
            backendCommands.dispatch(command)
        }
    })

    // The effective preference as the screen supplies it: compact presentation reads ask as always.
    @Volatile private var currentSessionRestorePolicy = SessionRestorePolicy.ASK
    private val sessionRestorePolicyJob = scope.launch {
        sessionRestorePolicy.catch { emit(SessionRestorePolicy.ASK) }.collect {
            currentSessionRestorePolicy = it
        }
    }

    private val forwardingStateJob = scope.launch {
        // Keyed on listener status alone: service liveness is local chrome,
        // and a probe changing it must not become a shared-session event.
        forwardingManager.states
            .map { states ->
                states.values.map { state ->
                    SharedForwardingState(state.rule.id, state.status.sharedStateName())
                }
            }
            .distinctUntilChanged()
            .collect { states ->
                emitSharedIfOpen { emitForwardingStateChanged(states) }
            }
    }

    fun updateForwardingRules(rules: List<PortForwardRule>) {
        forwardingRules = rules
        if (closed) return
        scope.launch {
            if (rules.isEmpty()) {
                detachForwarding()
            } else if (forwardingAttached) {
                forwardingManager.reconcile(rules)
            } else if (transportConnected) {
                currentIntent?.let { attachForwardingIfNeeded(it, buildRoute()) }
            }
        }
    }

    fun startForwardingRule(ruleId: UUID) { scope.launch { forwardingManager.start(ruleId) } }

    fun stopForwardingRule(ruleId: UUID) { scope.launch { forwardingManager.stop(ruleId) } }

    /**
     * Keeps forwarded services' liveness current until cancelled. The screen
     * runs it only while someone is looking at this session.
     */
    suspend fun monitorForwardedServices(): Nothing = forwardingManager.monitorServices()

    /** The forwarding panel just opened: check every probeable rule now. */
    fun probeForwardedServicesNow() {
        if (closed) return
        scope.launch { forwardingManager.probeServicesNow() }
    }

    fun attachTerminal(surface: TerminalSurface) {
        val replacingSurface = terminalSurface !== surface
        if (terminalSurface !== surface) {
            terminalSurface?.let(::observeRenderDrops)
            terminalSurface?.onInput = null
            terminalSurface?.onResize = null
        }
        terminalSurface = surface
        // A Compose remount can replace the physical single-pane emulator
        // without changing its logical ledger surface ID.  The reducer treats
        // that declaration as unchanged, so the adapter must invalidate its
        // one-shot latch and explicitly ask tmux for an authoritative first
        // repaint after the seam has attached.
        if (replacingSurface) {
            initiallyRequestedTmuxRenderSurfaces.remove(TMUX_RENDER_LIVE_SURFACE_ID)
            clearTmuxRenderHistory(TMUX_RENDER_LIVE_SURFACE_ID)
            // The record's in-flight latch named the physical view that just
            // went away; the replacement is rebound before it can scroll.
            clearTmuxInlineHistory(TMUX_RENDER_LIVE_SURFACE_ID)
            resetMoshPainterHandoff()
            moshLiveHistoryRevealed = false
        }
        ensureRenderDropSummaryJob()
        configurePainterFeedAdmission()
        publishScrollRouting()
        synchronized(tmuxTransportLock) { submitAuthorityPaintability() }
        agentEndpoint?.noteRawSnapshot(surface.snapshotText())
        surface.onInput = { bytes ->
            // Gate first (one volatile read), then the render fact: refused
            // input must not cost a Main-thread runtime pass (§6.4 P4) or
            // retire a reader's history it never changed.
            if (bytes.isNotEmpty() && admitTmuxTerminalInput(surface)) {
                noteTmuxRenderUserInput()
                shared.sendInput(bytes)
            }
        }
        // The IME's line mirror is the only place an autocorrect revision can
        // be seen; a device report has to carry its shape (never its text) or
        // "typed X, got Y" cannot be attributed to the mirror, the pty echo,
        // or Mosh prediction.
        surface.imeTraceSink = { line ->
            diagnostics.record("ime", mapOf("detail" to line, "transport" to diagnosticTransport))
        }
        surface.onResize = { columns, rows ->
            // A compact tmux surface is measured at the authoritative pane
            // grid, not at the physical phone viewport. Its outer
            // GeometryNeutralTerminalViewport reports the latter explicitly.
            if (columns >= 4 && rows >= 4 &&
                (host.tmuxMode == TmuxModes.OFF ||
                    tmuxGridPresentation == SharedTmuxGridPresentation.PANE_GRID)
            ) requestResize(columns, rows, geometrySettled = true)
        }
    }

    fun detachTerminal(surface: TerminalSurface) {
        if (terminalSurface !== surface) return
        observeRenderDrops(surface)
        surface.onInput = null
        surface.onResize = null
        surface.imeTraceSink = null
        terminalSurface = null
        synchronized(tmuxTransportLock) { submitAuthorityPaintability() }
        clearTmuxRenderHistory(TMUX_RENDER_LIVE_SURFACE_ID)
        clearTmuxInlineHistory(TMUX_RENDER_LIVE_SURFACE_ID)
        resetMoshPainterHandoff()
        moshLiveHistoryRevealed = false
        configurePainterFeedAdmission()
    }

    fun updateTmuxViewport(columns: Int, rows: Int) {
        if (closed || host.tmuxMode == TmuxModes.OFF || columns < 4 || rows < 4) return
        requestResize(columns, rows)
    }

    /**
     * Native surfaces commit settled geometry; compact tmux viewports still submit proposals.
     * Publish committed grids immediately and settle proposals here, through the same shared
     * runtime for plain SSH, plain Mosh, and both tmux modes.
     */
    private fun requestResize(columns: Int, rows: Int, geometrySettled: Boolean = false) {
        if (closed || columns < 4 || rows < 4) return
        val next = SharedTmuxGridSize(columns, rows)
        when (resizeCoalescer.offer(next)) {
            TerminalResizeOffer.Unchanged -> return
            TerminalResizeOffer.CancelPending -> {
                // An animation can briefly propose B and then settle back at
                // already-published A. Cancel B instead of dispatching it late.
                resizeDispatchJob?.cancel()
                resizeDispatchJob = null
                return
            }
            TerminalResizeOffer.Deliver -> {
                // The first geometry is not a proposal to settle: a session
                // that has been told nothing cannot start without it.
                resizeDispatchJob?.cancel()
                resizeDispatchJob = null
                shared.resize(next.columns, next.rows)
                return
            }
            TerminalResizeOffer.Schedule -> Unit
        }
        resizeDispatchJob?.cancel()
        if (geometrySettled) {
            // Native surfaces already settled before committing their emulator
            // grid. Publish that same grid now; compact viewport proposals
            // still use the trailing-edge path below.
            resizeDispatchJob = null
            val settled = resizeCoalescer.settle(next) ?: return
            shared.resize(settled.columns, settled.rows)
            return
        }
        resizeDispatchJob = scope.launch {
            delay(SharedSessionPolicy.resizeSettleMilliseconds())
            val settled = resizeCoalescer.settle(next) ?: return@launch
            if (!closed) {
                shared.resize(settled.columns, settled.rows)
            }
        }
    }

    fun setPresentationActive(active: Boolean) {
        if (closed) return
        // Presentation gates painting, focus and geometry pushes only. It is
        // never a show: the show rule's edges arrive through [shown]/[hidden],
        // which the screen derives from the composed Displayed value.
        presentationActive = active
        synchronized(tmuxTransportLock) { submitAuthorityPaintability() }
        updatePresentationState()
        if (!active && moshLivenessOwnerPromptPending) {
            // The session left the screen before its credential screen came
            // up (that screen covers the app), so nobody can answer: withdraw
            // the challenge and ask again once the session is shown.
            moshLivenessDeferredForPresentation = true
            pendingOwnerAuthorization?.let { pending ->
                if (pending.responseSubmitted.compareAndSet(false, true)) {
                    val result = shared.submitChallengeResponse(
                        challengeResponseId(pending),
                        pending.challenge.attemptId,
                        pending.challenge.policyGeneration,
                        SharedChallengeDecision.CANCEL,
                    )
                    if (result != CoreCallResult.Accepted) pending.responseSubmitted.set(false)
                }
            }
        }
        if (active && moshLivenessDeferredForPresentation) {
            moshLivenessDeferredForPresentation = false
            moshServerLivenessWatcher?.stop("presented")
            updateMoshServerLiveness?.invoke()
        }
    }

    private fun updatePresentationState(notifyTmuxForeground: Boolean = true) {
        val active = presentationActive && appForeground
        shared.setFocused(active)
        shared.setVisibility(
            if (active) com.bambouville.tessera.core.bridge.SharedSessionVisibility.ACTIVE
            else com.bambouville.tessera.core.bridge.SharedSessionVisibility.BACKGROUND,
        )
        terminalSurface?.setFocused(active)
        if (active && appForeground && transportConnected) {
            // A Mosh tmux wake that is about to resolve authority replays its
            // own frame once the claim (if any) repaints; an earlier generic
            // repaint cannot stand in for it.
            val recoveringMoshForeground = usesMoshPrimaryTransport() && host.tmuxMode != TmuxModes.OFF &&
                ((lastTmuxAuthorityResult?.geometryHold == SharedTmuxAuthorityGeometryHold.WITHHELD) || pendingAuthorityRepaintGeneration != null ||
                    lastTmuxAuthorityResult?.pendingIntent != null)
            if (recoveringMoshForeground || (usesMoshPrimaryTransport() && moshLiveHistoryRevealed)) {
                terminalSurface?.requestFullRepaint()
            } else {
                shared.requestFullRepaint()
            }
            if (notifyTmuxForeground) submitTmuxRenderFact(SharedTmuxRenderFact.AppForeground)
        }
    }

    /** Painting/liveness input, never a show edge. */
    fun setAppForeground(foreground: Boolean) {
        if (closed || appForeground == foreground) return
        recordRenderDropSummary(if (foreground) "app-foreground" else "app-background")
        appForeground = foreground
        synchronized(tmuxTransportLock) {
            reduceTmuxAuthority { session, now ->
                if (foreground) session.foregrounded(now) else session.backgrounded(now)
            }
            submitAuthorityPaintability()
        }
        if (foreground) restartCompactTmuxSizing()
        updateMoshServerLiveness?.invoke()
        updatePresentationState(notifyTmuxForeground = false)
        submitTmuxRenderFact(if (foreground) SharedTmuxRenderFact.AppForeground else SharedTmuxRenderFact.AppBackground)
        if (foreground) reconcileTmuxClientSize()
    }

    /** Receives the core tracker's settled show; [stepAtMillis] starts its authority intent window. */
    fun shown(
        source: SharedTmuxAuthorityShowSource = SharedTmuxAuthorityShowSource.SHOW,
        stepAtMillis: Long? = null,
    ) {
        if (closed || host.tmuxMode == TmuxModes.OFF) return
        synchronized(tmuxTransportLock) {
            if (closed) return
            diagnostics.record(
                "tmux_authority_show",
                mapOf(
                    "detail" to "source=${source.wireValue} channel=${controlChannelLive()} " +
                        "authority=${mutableTmuxAuthority.value.traceLabel()}",
                    "transport" to diagnosticTransport,
                ),
            )
            restartCompactTmuxSizing()
            if (!tmuxAuthorityParticipates()) {
                publishTmuxAuthorityPresentation()
                return
            }
            submitAuthorityChannelLiveness()
            reduceTmuxAuthority { session, now -> session.shown(now, source, stepAtMillis ?: now) }
        }
    }

    /** Drops unsent intents; a sent claim keeps its own acknowledgements. */
    fun hidden() {
        if (closed || host.tmuxMode == TmuxModes.OFF) return
        synchronized(tmuxTransportLock) {
            if (closed) return
            if (lastTmuxAuthorityResult?.pendingIntent != null) {
                diagnostics.record(
                    "tmux_authority_hide",
                    mapOf("detail" to "intent dropped", "transport" to diagnosticTransport),
                )
            }
            // Hide first so an unsent abort cannot park or replay this gesture.
            reduceTmuxAuthority { session, now -> session.hidden(now) }
            abandonUnsentTmuxAuthorityClaim()
        }
    }

    /**
     * A grid mutation (a `-C`, a window force, the `latest` fence) sent while
     * a claim runs is that claim's wire work (L2): from then on a hide lets
     * the claim finish instead of leaving the window resized with no stamp.
     */
    private fun noteAuthorityClaimGridMutation() {
        pendingAuthorityRepaintGeneration?.let { authorityClaimWireGeneration = it }
    }

    /**
     * L2: a claim still waiting for its geometry fence that has not sent a
     * single grid mutation (nothing has resized or fenced the window yet:
     * it began before the viewport was measured, or at a grid this
     * connection's client already has over a window that fits it) is
     * abandoned rather than carried out from a hidden tab. One whose wire
     * work has started finishes on its own (S4′). The abort is never
     * replayed: the tab is hidden. Caller holds the lock.
     */
    private fun abandonUnsentTmuxAuthorityClaim() {
        val claim = lastTmuxAuthorityResult?.claim ?: return
        if (claim.phase != SharedTmuxAuthorityClaimPhase.AWAITING_FENCE ||
            authorityClaimWireGeneration == claim.generation || !isLiveAuthorityClaim(claim.generation)
        ) return
        reduceTmuxAuthority { session, now -> session.abort(now, claim.generation, SharedTmuxAuthorityAbortReason.SUPERSEDED) }
    }

    fun cancelPendingTmuxAuthorityIntent() {
        reduceTmuxAuthority { session, now -> session.cancelIntent(now) }
    }

    /** Slot replacement carries the user's original R3 step, never a tap. */
    internal fun carriedShow(): SharedTmuxAuthorityCarriedShow? = synchronized(tmuxTransportLock) {
        if (closed) lastTmuxAuthorityResult?.carriedShow
        else tmuxAuthorityLifecycle.snapshot(authorityNow()).carriedShow
    }

    internal fun adoptShownSlot() {
        if (closed || host.tmuxMode == TmuxModes.OFF) return
        reduceTmuxAuthority { session, now -> session.adoptShown(now) }
    }

    /**
     * The input chokepoint: keys, paste and injected paths are refused while
     * resuming, veiled or reclaiming, except while an intent only waits for
     * the control channel over a non-peer grid (M7, the shared typing gate). Refusals
     * are counted, not logged per key.
     */
    private fun admitTmuxTerminalInput(surface: TerminalSurface): Boolean {
        if (acceptsTerminalInput()) return true
        // The IME's line mirror already recorded what it committed; the bytes
        // never reached the pty. Left as is, its next revision would send
        // DELs for characters that were never typed (out-of-band rule).
        refusedTerminalInputImeReset(surface)
        refusedTmuxInputCount += 1
        if (refusedTmuxInputCount == 1L || refusedTmuxInputCount % 100L == 0L) {
            diagnostics.record(
                "tmux_input_refused",
                mapOf(
                    "detail" to "count=$refusedTmuxInputCount presentation=${mutableTmuxAuthorityPresentation.value::class.java.simpleName}",
                    "transport" to diagnosticTransport,
                ),
            )
        }
        return false
    }

    /** Whether the tmux control channel can carry a claim right now. */
    private fun controlChannelLive(): Boolean =
        !closed && tmuxConnection != null && tmuxCommandChannel != null && tmuxCore != null

    /**
     * Gate for keys, paste and path injection: false while resuming, veiled
     * or reclaiming, but not while an intent only waits for the control
     * channel and no peer is known (M7). Window chrome, selection and Agent
     * Center mutations keep their own, unchanged gates. One volatile read.
     */
    fun acceptsTerminalInput(): Boolean = !tmuxAuthorityParticipates() || !tmuxInputGated

    /**
     * Whether this connection takes part in tmux grid authority: a tmux host
     * whose launch did not degrade to a plain SSH shell. A degraded session
     * has no control channel to read or claim, so it never resumes, veils or
     * gates input.
     */
    private fun tmuxAuthorityParticipates(): Boolean =
        host.tmuxMode != TmuxModes.OFF && !plainSshPainterActive

    /**
     * Standard diagnostics must prove the seam stayed quiet even when no
     * refusal happened. Surface counters are sampled by object identity so a
     * Compose detach/re-attach cannot double-count, and retired pane/overlay
     * surfaces remain represented in the session-lifetime total.
     */
    private fun recordRenderDropSummary(boundary: String) {
        terminalSurface?.let(::observeRenderDrops)
        paneSurfaces.values.forEach(::observeRenderDrops)
        overlaySurfaces.values.forEach(::observeRenderDrops)
        val total = synchronized(renderDropSummaryLock) { renderDroppedForeignTotal }
        diagnostics.record(
            "render_ledger_summary",
            mapOf(
                "detail" to "boundary=$boundary dropped_foreign=$total",
                "transport" to diagnosticTransport,
            ),
        )
        recordMoshPumpStats(boundary)
    }

    /**
     * The Mosh pump's own counters: how it woke, how long ticks took, how
     * much output it delivered and whether the collector ever pushed back. A
     * "laggy" report is otherwise unanswerable from the device.
     */
    private fun recordMoshPumpStats(boundary: String) {
        val stats = moshTransport?.pumpStats() ?: return
        diagnostics.record(
            "mosh_pump",
            mapOf(
                "detail" to "boundary=$boundary ${stats.summary()}",
                "transport" to diagnosticTransport,
            ),
        )
    }

    private fun observeRenderDrops(surface: TerminalSurface) {
        synchronized(renderDropSummaryLock) {
            val current = surface.droppedForeignFeeds
            val previous = renderDropObserved[surface] ?: 0
            if (current > previous) {
                renderDroppedForeignTotal += (current - previous).toLong()
            }
            renderDropObserved[surface] = maxOf(previous, current)
        }
    }

    private fun ensureRenderDropSummaryJob() {
        if (renderDropSummaryJob?.isActive == true || closed) return
        renderDropSummaryJob = scope.launch(Dispatchers.Main.immediate) {
            recordRenderDropSummary("periodic-start")
            while (!closed) {
                delay(RENDER_DROP_SUMMARY_INTERVAL_MILLISECONDS)
                if (!closed) recordRenderDropSummary("periodic")
            }
        }
    }

    fun setTmuxGridPresentation(presentation: SharedTmuxGridPresentation) {
        val changed = tmuxGridPresentation != presentation
        tmuxGridPresentation = presentation
        if (changed) restartCompactTmuxSizing()
        synchronized(tmuxTransportLock) { submitAuthorityGeometryFacts() }
        shared.setTmuxGridPresentation(presentation)
        if (transportConnected) reconcileTmuxClientSize(forceAllWindows = changed)
    }

    fun setTmuxScreenRenderPresentation(presentation: TmuxScreenRenderPresentation) {
        if (tmuxScreenRenderPresentation == presentation) return
        tmuxScreenRenderPresentation = presentation
        // A single/grid remount is an authority boundary even before the
        // following declaration effect publishes the new concrete surfaces.
        validatePendingInlineAuthorityRepaintTopology()
    }

    fun attachTmuxPane(paneId: Int, surface: TerminalSurface) {
        val previous = paneSurfaces.put(paneId, surface)
        previous?.takeIf { it !== surface }?.let(::observeRenderDrops)
        // Pane IDs survive a grid recomposition.  A new Termux surface under
        // the same ID has no cache to retain, even though the core's surface
        // declaration is structurally identical.  Re-arm the explicit
        // surface-mounted refresh before redeclaring below.
        if (previous !== surface) {
            initiallyRequestedTmuxRenderSurfaces.remove("$TMUX_RENDER_PANE_SURFACE_PREFIX$paneId")
        }
        ensureRenderDropSummaryJob()
        configurePainterFeedAdmission()
        surface.onInput = { bytes ->
            if (bytes.isNotEmpty() && admitTmuxTerminalInput(surface)) {
                noteTmuxRenderUserInput()
                sendTmuxInput(paneId, bytes)
            }
        }
        surface.onResize = { _, _ -> Unit }
        surface.imeTraceSink = { line ->
            diagnostics.record(
                "ime",
                mapOf("detail" to "pane=%$paneId $line", "transport" to diagnosticTransport),
            )
        }
    }

    fun detachTmuxPane(paneId: Int, surface: TerminalSurface) {
        observeRenderDrops(surface)
        if (paneSurfaces.remove(paneId, surface)) {
            // The record describes a physical view that is gone. Its
            // replacement is rebound before it can scroll, and leaving a
            // stale in-flight latch behind would refuse that surface's first
            // deepen until the watchdog expired.
            clearTmuxInlineHistory("$TMUX_RENDER_PANE_SURFACE_PREFIX$paneId")
        }
        surface.onInput = null
        surface.onResize = null
        surface.imeTraceSink = null
        configurePainterFeedAdmission()
    }

    /** Attach the detached history presentation mounted by the screen. */
    fun attachTmuxOverlay(paneId: Int, surface: TerminalSurface) {
        val previous = overlaySurfaces.put(paneId, surface)
        previous?.takeIf { it !== surface }?.let(::observeRenderDrops)
        if (previous !== surface) {
            clearTmuxRenderHistory("$TMUX_RENDER_OVERLAY_SURFACE_PREFIX$paneId")
        }
        ensureRenderDropSummaryJob()
        configurePainterFeedAdmission()
        surface.onResize = { _, _ -> Unit }
    }

    fun detachTmuxOverlay(paneId: Int, surface: TerminalSurface) {
        observeRenderDrops(surface)
        overlaySurfaces.remove(paneId, surface)
        clearTmuxRenderHistory("$TMUX_RENDER_OVERLAY_SURFACE_PREFIX$paneId")
        surface.onResize = null
        configurePainterFeedAdmission()
    }

    fun requestTmuxScrollback(surfaceId: String, pointsY: Double, isInertial: Boolean) {
        val hasOverlay = surfaceId.startsWith(TMUX_RENDER_OVERLAY_SURFACE_PREFIX)
        val splitMoshWindow = usesMoshPrimaryTransport() &&
            mutableTmuxSnapshot.value?.activeWindow?.let { it.panes.size > 1 && !it.zoomed } == true
        if (splitMoshWindow && !hasOverlay) {
            diagnostics.record(
                "render_ledger_history_refused",
                mapOf("detail" to "mosh multi-pane requires overlay", "transport" to diagnosticTransport),
            )
            return
        }
        if (!submitTmuxRenderFact(SharedTmuxRenderFact.ScrollbackRequested(surfaceId, pointsY, isInertial))) {
            renderSurfaceForId(surfaceId)?.view?.cancelHistoryScroll()
        }
    }

    fun returnTmuxScrollbackToTail(surfaceId: String) {
        if (surfaceId == TMUX_RENDER_LIVE_SURFACE_ID) {
            moshLiveHistoryRevealed = false
        }
        clearTmuxRenderHistory(surfaceId)
        submitTmuxRenderFact(SharedTmuxRenderFact.ScrollbackReturnedToTail(surfaceId))
    }

    /**
     * Ask the ledger for older inline (SSH+tmux) history on this surface.
     *
     * Deliberately not routed through [requestTmuxScrollback]: that path
     * carries the mosh multi-pane refusal, which has no meaning inline.
     *
     * The latch and the gesture are taken *before* the fact is submitted, and
     * rolled back if the ledger will not take it. They cannot be taken
     * afterwards: this runs on the main thread, so the render callback and
     * its `Dispatchers.Main.immediate` drain re-enter synchronously inside
     * `submitTmuxRenderFact`. A request the ledger ignores — exhausted,
     * already pending, unowned — is answered with an immediate
     * `inlineHistorySettled` from inside that call, and a latch taken after
     * it returned would be one nothing is left to release: local scrolling
     * would then be frozen (`TerminalView.scrollLocalPixels` swallows every
     * delta while a history scroll is pending) until the watchdog fired.
     *
     * Main thread only: it touches the terminal view.
     */
    fun requestTmuxInlineHistory(surfaceId: String) {
        val record = mutableTmuxInlineHistory.value[surfaceId]
        if (record?.requestInFlight == true) return
        val surface = renderSurfaceForId(surfaceId) ?: return
        // The one terminal outcome the ledger answers with a diagnostic
        // (`inline-history-request-ignored ... reason=unowned`) instead of a
        // settle. Latching a gesture here would leave nothing to release it
        // but the watchdog, and freeze local scrolling meanwhile.
        if (surface.boundOwner == null) return
        val view = surface.view
        mutableTmuxInlineHistory.value = mutableTmuxInlineHistory.value +
            (surfaceId to (record ?: InlineTmuxHistoryRecord.Initial).requestSubmitted())
        view.beginHistoryScroll()
        if (!submitTmuxRenderFact(SharedTmuxRenderFact.ScrollbackRequested(surfaceId, -1.0, false))) {
            // Nothing reached the ledger, so nothing will settle this.
            mutableTmuxInlineHistory.value = if (record == null) {
                mutableTmuxInlineHistory.value - surfaceId
            } else {
                mutableTmuxInlineHistory.value + (surfaceId to record)
            }
            view.cancelHistoryScroll()
            return
        }
        armTmuxInlineHistoryTimeout(surfaceId)
    }

    /**
     * The ledger promises one `inlineHistorySettled` for every request it
     * admits, ignores or aborts, so this should never fire. It exists because
     * the cost of a lost settle is not a missing capture but a terminal whose
     * scrolling is stuck: `mHistoryScrollPending` swallows every subsequent
     * scroll delta until it is completed or cancelled.
     */
    private fun armTmuxInlineHistoryTimeout(surfaceId: String) {
        tmuxInlineHistoryTimeouts.remove(surfaceId)?.cancel()
        tmuxInlineHistoryTimeouts[surfaceId] = scope.launch(Dispatchers.Main.immediate) {
            delay(INLINE_HISTORY_SETTLE_TIMEOUT_MILLIS)
            tmuxInlineHistoryTimeouts.remove(surfaceId)
            val pending = mutableTmuxInlineHistory.value[surfaceId] ?: return@launch
            if (!pending.requestInFlight) return@launch
            mutableTmuxInlineHistory.value =
                mutableTmuxInlineHistory.value + (surfaceId to pending.timedOut())
            renderSurfaceForId(surfaceId)?.view?.let { view ->
                view.completeHistoryScroll(view.topRow)
            }
            diagnostics.record(
                "render_ledger_inline_history_timeout",
                mapOf("detail" to "surface=$surfaceId", "transport" to diagnosticTransport),
            )
        }
    }

    private fun clearTmuxInlineHistory(surfaceId: String? = null) {
        if (surfaceId == null) {
            tmuxInlineHistoryTimeouts.values.forEach { it.cancel() }
            tmuxInlineHistoryTimeouts.clear()
            mutableTmuxInlineHistory.value = emptyMap()
        } else {
            tmuxInlineHistoryTimeouts.remove(surfaceId)?.cancel()
            mutableTmuxInlineHistory.value = mutableTmuxInlineHistory.value - surfaceId
        }
    }

    /** Opens find through the shared ledger for this exact render surface. */
    fun openTmuxFind(surfaceId: String) {
        submitTmuxRenderFact(SharedTmuxRenderFact.FindOpened(surfaceId))
    }

    fun selectTmuxWindow(id: Int) { shared.selectTmuxWindow("@$id") }
    fun selectTmuxPane(id: Int) { shared.selectTmuxPane("%$id") }

    suspend fun queryTmuxPaneContentRects(windowId: Int): Map<Int, SharedTmuxCellRect> {
        val response = CompletableDeferred<AgentTmuxControlAck>()
        val generation = synchronized(tmuxTransportLock) {
            if (!controlChannelLive()) return emptyMap()
            val currentGeneration = tmuxTransportGeneration
            if (!sendTmuxControl(
                    "list-panes -t @$windowId -F '#{pane_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}'",
                    TmuxResponsePurpose.AgentCommand(response),
                )
            ) return emptyMap()
            currentGeneration
        }
        val result = withTimeoutOrNull(3_000) { response.await() } ?: return emptyMap()
        if (!result.success || synchronized(tmuxTransportLock) { tmuxTransportGeneration != generation }) {
            return emptyMap()
        }
        return result.lines.mapNotNull { line ->
            val fields = line.split('|')
            if (fields.size != 5) return@mapNotNull null
            val paneId = fields[0].removePrefix("%").toIntOrNull() ?: return@mapNotNull null
            val x = fields[1].toIntOrNull() ?: return@mapNotNull null
            val y = fields[2].toIntOrNull() ?: return@mapNotNull null
            val width = fields[3].toIntOrNull()?.takeIf { it > 0 } ?: return@mapNotNull null
            val height = fields[4].toIntOrNull()?.takeIf { it > 0 } ?: return@mapNotNull null
            paneId to SharedTmuxCellRect(columns = width, rows = height, x = x, y = y)
        }.toMap()
    }

    fun sendTmuxPaneScrollInput(paneId: Int, bytes: ByteArray) {
        if (bytes.isNotEmpty()) shared.sendTmuxPaneInput("%$paneId", bytes)
    }

    fun createTmuxWindow() { shared.createTmuxWindow() }
    fun moveTmuxWindow(id: Int, destination: Int) {
        shared.moveTmuxWindow("@$id", destination)
    }
    fun renumberTmuxWindows() {
        shared.renumberTmuxWindows()
    }
    fun clearTmuxWindowMutationError() {
        synchronized(tmuxTransportLock) {
            tmuxWindowMutationError = null
            updateTmuxWindowMutationState()
        }
    }
    fun closeTmuxWindow(id: Int) { shared.closeTmuxWindow("@$id") }
    fun closeTmuxPane(id: Int) { shared.closeTmuxPane("%$id") }
    /** Resolve the target pane from the live window, then reveal the result. */
    fun splitTmuxWindow(id: Int, vertical: Boolean, before: Boolean) {
        val snapshot = mutableTmuxSnapshot.value ?: return
        if (!snapshot.isWindowListHydrated || mutableTmuxAuthority.value is SharedTmuxGridAuthoritySnapshot.Peer) return
        val window = snapshot.windows.firstOrNull { it.id == id } ?: return
        val paneId = tmuxWindowSplitTargetPane(window) ?: return
        splitTmuxPane(paneId, vertical, before)
        if (snapshot.activeWindowId != id) shared.selectTmuxWindow("@$id")
    }

    fun splitTmuxPane(id: Int, vertical: Boolean, before: Boolean = false) {
        shared.splitTmuxPane(
            "%$id",
            if (vertical) com.bambouville.tessera.core.bridge.SharedTmuxSplitAxis.VERTICAL
            else com.bambouville.tessera.core.bridge.SharedTmuxSplitAxis.HORIZONTAL,
            before = before,
        )
    }
    fun setTmuxZoomed(id: Int, zoomed: Boolean) { shared.setTmuxPaneZoomed("%$id", zoomed) }
    fun renameTmuxWindow(id: Int, name: String) { shared.renameTmuxWindow("@$id", name) }
    /**
     * The veil gesture (§6.9 R4): a pointer tap, Enter or a printable key on
     * the veil. On a live control channel it claims at once; without one it
     * forms a tap intent bound to the peer the veil names, shown as "takes
     * control when reconnected" until the channel returns or ~20 s pass.
     */
    fun reclaimTmuxGridAuthority() {
        synchronized(tmuxTransportLock) {
            if (closed || host.tmuxMode == TmuxModes.OFF) return
            if (takeBackRefusedOffScreen("veil")) return
            submitAuthorityChannelLiveness()
            val channelLive = controlChannelLive()
            // The tap itself is evidence: a report that shows three taps and
            // one lifecycle claim tells a different story from three claims.
            diagnostics.record(
                "tmux_authority_take_back_tap",
                mapOf(
                    "detail" to "channelLive=$channelLive authority=${mutableTmuxAuthority.value.traceLabel()} " +
                        "reclaimInFlight=${mutableTmuxReclaimInFlight.value} " +
                        "pendingGeneration=${pendingAuthorityRepaintGeneration ?: "none"}",
                    "transport" to diagnosticTransport,
                ),
            )
            reduceTmuxAuthority { session, now -> session.requestTakeBack(now) }
        }
    }

    /**
     * D8: a take-back acts only for the session on screen in a foreground
     * app. The veil of a session composed but not presented neither holds
     * focus nor takes taps, but a key or tap delivered in the frame the
     * presentation changes, or a runtime command, must not reclaim a session
     * the user cannot see (and would then move the peer's grid for).
     * [presentationActive] is the screen's `isPresented`, already false while
     * the app is locked. Caller holds [tmuxTransportLock].
     */
    private fun takeBackRefusedOffScreen(source: String): Boolean {
        if (presentationActive && appForeground) return false
        diagnostics.record(
            "tmux_authority_take_back_ignored",
            mapOf(
                "detail" to "source=$source presented=$presentationActive foreground=$appForeground",
                "transport" to diagnosticTransport,
            ),
        )
        return true
    }

    private fun SharedTmuxGridAuthoritySnapshot.traceLabel(): String = when (this) {
        SharedTmuxGridAuthoritySnapshot.Unknown -> "unknown"
        is SharedTmuxGridAuthoritySnapshot.Mine -> "mine#$generation"
        is SharedTmuxGridAuthoritySnapshot.Peer -> "peer($deviceId/$displayName#$generation)"
    }

    fun connect() {
        if (closed || currentIntent != null) return
        val intent = SharedConnectionIntent(
            requestId = UUID.randomUUID(),
            hostId = UUID.fromString(host.id),
            policyGeneration = System.currentTimeMillis().coerceAtLeast(1),
        )
        currentIntent = intent
        explicitDisconnect = false
        explicitClose = false
        scope.launch {
            // A new attempt supersedes any crash record for this host and prevents duplicate
            // reconnect affordances when a process-restored session receives a fresh runtime ID.
            restore.deleteForHost(host.id)
            shared.connect(intent)
        }
    }

    fun submitPassword(password: String) {
        val pending = pendingCredential ?: return
        if (password.isEmpty()) return
        if (!pending.responseSubmitted.compareAndSet(false, true)) return
        pending.secret?.fill('\u0000')
        pending.secret = password.toCharArray()
        noteAuthorityIntentUserStep()
        val result = shared.submitChallengeResponse(
            challengeResponseId(pending),
            pending.challenge.attemptId,
            pending.challenge.policyGeneration,
            SharedChallengeDecision.APPROVE,
        )
        if (result != CoreCallResult.Accepted) pending.responseSubmitted.set(false)
    }

    fun decideHostKey(accept: Boolean) {
        val pending = pendingHostKey ?: return
        if (!pending.responseSubmitted.compareAndSet(false, true)) return
        noteAuthorityIntentUserStep()
        val result = shared.submitChallengeResponse(
            challengeResponseId(pending),
            pending.challenge.attemptId,
            pending.challenge.policyGeneration,
            if (accept) SharedChallengeDecision.APPROVE else SharedChallengeDecision.REJECT,
        )
        if (result != CoreCallResult.Accepted) pending.responseSubmitted.set(false)
    }

    fun cancelChallenge() {
        pendingCredential?.let { pending ->
            if (!pending.responseSubmitted.compareAndSet(false, true)) return
            val result = shared.submitChallengeResponse(
                challengeResponseId(pending),
                pending.challenge.attemptId,
                pending.challenge.policyGeneration,
                SharedChallengeDecision.CANCEL,
            )
            if (result != CoreCallResult.Accepted) pending.responseSubmitted.set(false)
        }
        pendingHostKey?.let { pending ->
            if (!pending.responseSubmitted.compareAndSet(false, true)) return
            val result = shared.submitChallengeResponse(
                challengeResponseId(pending),
                pending.challenge.attemptId,
                pending.challenge.policyGeneration,
                SharedChallengeDecision.CANCEL,
            )
            if (result != CoreCallResult.Accepted) pending.responseSubmitted.set(false)
        }
        pendingOwnerAuthorization?.let { pending ->
            if (!pending.responseSubmitted.compareAndSet(false, true)) return
            val result = shared.submitChallengeResponse(
                challengeResponseId(pending),
                pending.challenge.attemptId,
                pending.challenge.policyGeneration,
                SharedChallengeDecision.CANCEL,
            )
            if (result != CoreCallResult.Accepted) pending.responseSubmitted.set(false)
        }
    }

    fun decideOwnerAuthorization(approved: Boolean) {
        val pending = pendingOwnerAuthorization ?: return
        if (!pending.responseSubmitted.compareAndSet(false, true)) return
        noteAuthorityIntentUserStep()
        val result = shared.submitChallengeResponse(
            challengeResponseId(pending),
            pending.challenge.attemptId,
            pending.challenge.policyGeneration,
            if (approved) SharedChallengeDecision.APPROVE else SharedChallengeDecision.REJECT,
        )
        if (result != CoreCallResult.Accepted) pending.responseSubmitted.set(false)
    }

    fun prepareRetry() {
        // Retry is one of the user's steps that restarts R3's intent window.
        noteAuthorityIntentUserStep()
        if (mutableState.value is SshSessionUiState.Failed) {
            // A rejected password is not a reusable credential. Retry must
            // return to the prompt rather than resubmitting the same secret.
            attemptPasswords.values.forEach { it.fill('\u0000') }
            attemptPasswords.clear()
            reconnectJob?.cancel()
            reconnectJob = null
            reconnectAttempt = 0
            recoveringUnexpectedDisconnect = false
            currentIntent = null
            publishSessionState(SshSessionUiState.Disconnected)
        }
    }

    /**
     * Ends the session for good, rather than parking it as reconnectable: the
     * state settles on [SshSessionUiState.Terminated] so the host drops out of
     * the sessions tab on a single press.
     */
    fun closeSession() {
        explicitDisconnect = true
        explicitClose = true
        reconnectJob?.cancel()
        reconnectJob = null
        resizeDispatchJob?.cancel()
        resizeDispatchJob = null
        resizeCoalescer.reset()
        recoveringUnexpectedDisconnect = false
        if (currentIntent != null) {
            shared.disconnect()
        } else {
            // Never connected, so no backend state change is coming to settle
            // the state for us. Retire the session here instead.
            teardownTransport()
            transportConnected = false
            scope.launch { runCatching { restore.delete(sessionId) } }
            publishSessionState(SshSessionUiState.Terminated)
        }
    }

    suspend fun fileRouteRequest(): SshRouteRequest {
        checkNotNull(currentIntent) { "The terminal session is not active" }
        return SshRouteRequest(buildRoute())
    }

    suspend fun openLiveFileChannel(): SshFileConnection {
        check(transportConnected) { "The terminal session is not connected" }
        return checkNotNull(routeOwner) { "The authenticated SSH route is unavailable" }.openFiles()
    }

    suspend fun filePassword(hop: SshRouteHop): CharArray = try {
        requestPassword(checkNotNull(currentIntent) { "The terminal session is not active" }, hop)
    } finally {
        restoreConnectedUiAfterSideChannelChallenge()
    }

    suspend fun fileHostKey(observation: SshHostKeyObservation): Boolean = try {
        verifyHostKey(checkNotNull(currentIntent) { "The terminal session is not active" }, observation)
    } finally {
        restoreConnectedUiAfterSideChannelChallenge()
    }

    suspend fun fileKeyAuthorization(hop: SshRouteHop) = try {
        authorizeKey(checkNotNull(currentIntent) { "The terminal session is not active" }, hop)
    } finally {
        restoreConnectedUiAfterSideChannelChallenge()
    }

    /**
     * Which shell the cwd probe should follow on a transport with no tmux: the
     * remote mosh-server's child when mosh owns the terminal (the bootstrap
     * banner captured its PID), otherwise null. File polling can additionally
     * scope a plain SSH lookup to the terminal's authenticated route.
     */
    fun cwdProbeMoshServerPid(): Int? = moshTransport
        ?.takeIf { usesMoshPrimaryTransport() }
        ?.bootstrapServerPid

    /** Only a plain SSH terminal shares process ancestry with the file route. */
    fun liveFileCwdProbeCommand(): String = RemoteCwdProbe.discoveryCommand(
        moshServerPid = cwdProbeMoshServerPid(),
        sameSshRoute = !usesMoshPrimaryTransport(),
    )

    /**
     * Resolves the active tmux pane cwd at the moment an action is invoked.
     * The pane subscription refreshes snapshots periodically. Selection actions
     * query explicitly so a `cd` just before the action cannot use the previous tick.
     */
    fun queryTerminalDirectory(
        reportedDirectory: String?,
        focusedTmuxPaneId: Int?,
        onResult: (String?) -> Unit,
    ) {
        if (host.tmuxMode == TmuxModes.OFF) {
            val reported = reportedDirectory?.takeIf {
                it.startsWith('/') && it.none(Char::isISOControl)
            }
            if (reported != null) {
                scope.launch(Dispatchers.Main.immediate) { onResult(reported) }
                return
            }
            val intent = currentIntent
            if (intent == null) {
                scope.launch(Dispatchers.Main.immediate) { onResult(null) }
                return
            }
            val transport = moshTransport
            val moshServerPid = transport?.bootstrapServerPid.takeIf {
                usesMoshPrimaryTransport() && transport != null
            }
            scope.launch {
                val path = try {
                    val transcript = backend.executeRouteCommand(
                        request = SshRouteRequest(buildRoute()),
                        commandText = RemoteCwdProbe.discoveryCommand(moshServerPid),
                        passwordProvider = SshPasswordProvider { hop -> requestPassword(intent, hop) },
                        hostKeyPolicy = SshHostKeyPolicy { observation -> verifyHostKey(intent, observation) },
                        keyAuthorizationProvider = SshKeyAuthorizationProvider { hop -> authorizeKey(intent, hop) },
                    )
                    RemoteCwdProbe.reportedPath(transcript.standardOutput)
                } catch (_: CancellationException) {
                    return@launch
                } catch (failure: Throwable) {
                    diagnostics.record(
                        "terminal_cwd_probe_failed",
                        mapOf("detail" to redactedFailure(failure), "transport" to diagnosticTransport),
                    )
                    null
                } finally {
                    restoreConnectedUiAfterSideChannelChallenge()
                }
                if (!closed && currentIntent?.requestId == intent.requestId) onResult(path)
            }
            return
        }

        // The UI updates its local pane focus before tmux acknowledges
        // `select-pane`. Use that synchronous identity so a selection action
        // cannot query the previously active pane during the acknowledgement
        // window.
        val paneId = focusedTmuxPaneId ?: mutableTmuxSnapshot.value?.activePaneId
        if (paneId == null || tmuxConnection == null) {
            scope.launch(Dispatchers.Main.immediate) { onResult(null) }
            return
        }
        sendTmuxControl(
            "display-message -p -t %$paneId '#{pane_current_path}'",
            TmuxResponsePurpose.CurrentDirectory(onResult),
        )
    }

    fun close() {
        synchronized(tmuxTransportLock) {
            if (closed) return
            // Serialize the closed edge with every reducer operation. Merely
            // checking a volatile flag before entering the lifecycle lock
            // leaves a window where a queued backend completion can call a
            // native handle after this method destroys it.
            closed = true
        }
        recordRenderDropSummary("session-close")
        renderDropSummaryJob?.cancel()
        renderDropSummaryJob = null
        diagnostics.record(
            "session_controller_close",
            mapOf("state" to mutableState.value::class.java.simpleName, "transport" to diagnosticTransport),
        )
        explicitDisconnect = true
        reconnectJob?.cancel()
        reconnectJob = null
        if (currentIntent != null) runCatching { shared.disconnect() }
        teardownTransport()
        sessionRestorePolicyJob.cancel()
        forwardingStateJob.cancel()
        backendCommands.close()
        moshResizeRequests.close()
        moshResizeWriterJob.cancel()
        forwardingManager.close()
        terminalSurface?.onInput = null
        terminalSurface?.onResize = null
        terminalSurface = null
        onTmuxBell = null
        synchronized(tmuxTransportLock) {
            authorityWakeJob?.cancel()
            tmuxAuthorityLifecycle.close()
            // No session, no claim: nothing projects the flag after this.
            mutableTmuxReclaimInFlight.value = false
        }
        sessionProgramStatus?.close()
        shared.close()
    }

    private suspend fun receive(event: SharedSessionEvent) {
        when (event) {
            is SharedSessionEvent.StateChanged -> when (event.state) {
                SharedSessionState.IDLE, SharedSessionState.DISCONNECTED -> {
                    if (explicitClose || (remoteSessionTerminated && !explicitDisconnect)) {
                        transportConnected = false
                        diagnostics.record(
                            "session_state",
                            mapOf("state" to "terminated", "transport" to diagnosticTransport),
                        )
                        restore.delete(sessionId)
                        publishSessionState(SshSessionUiState.Terminated)
                        currentIntent = null
                        return
                    }
                    val shouldRecover = !explicitDisconnect &&
                        (hasConnectedTransport || recoveringUnexpectedDisconnect)
                    transportConnected = false
                    diagnostics.record("session_state", mapOf("state" to "disconnected", "transport" to diagnosticTransport))
                    if (explicitDisconnect) restore.delete(sessionId)
                    else if (currentIntent != null) {
                        restore.save(
                            SessionRestoreRecord(
                                sessionId = sessionId,
                                hostId = host.id,
                                transportKind = diagnosticTransport,
                                tmuxTarget = host.tmuxTarget,
                                lastSelection = currentTmuxSelection(),
                                reconnectRequired = true,
                                updatedAtEpochMilliseconds = System.currentTimeMillis(),
                            ),
                        )
                    }
                    publishSessionState(SshSessionUiState.Disconnected)
                    currentIntent = null
                    if (shouldRecover) scheduleReconnect("transport_disconnected")
                }
                SharedSessionState.CONNECTING -> if (
                    mutableState.value !is SshSessionUiState.AwaitingCredential &&
                    mutableState.value !is SshSessionUiState.AwaitingHostKey &&
                    mutableState.value !is SshSessionUiState.AwaitingOwnerAuthorization
                ) publishSessionState(SshSessionUiState.Connecting)
                SharedSessionState.CONNECTED -> {
                    transportConnected = true
                    hasConnectedTransport = true
                    recoveringUnexpectedDisconnect = false
                    reconnectAttempt = 0
                    reconnectJob?.cancel()
                    reconnectJob = null
                    diagnostics.record("session_state", mapOf("state" to "connected", "transport" to diagnosticTransport))
                    publishSessionState(SshSessionUiState.Connected)
                    restore.save(
                        SessionRestoreRecord(
                            sessionId = sessionId,
                            hostId = host.id,
                            transportKind = diagnosticTransport,
                            tmuxTarget = host.tmuxTarget,
                            lastSelection = currentTmuxSelection(),
                            reconnectRequired = false,
                            updatedAtEpochMilliseconds = System.currentTimeMillis(),
                        ),
                    )
                    // A reconnect may finish while the phone is still locked or this
                    // session is no longer presented. Reapply the real lifecycle state
                    // instead of promoting every successful transport to foreground.
                    updatePresentationState()
                }
                SharedSessionState.FAILED -> Unit
            }
            is SharedSessionEvent.TerminalBytes -> terminalSurface?.let { surface ->
                val receipt = event.receipt
                val repaintRequestId = receipt?.repaintRequestId
                if (usesMoshPrimaryTransport() && event.bytes.isNotEmpty() && repaintRequestId == null &&
                    !moshPainterHandoff.awaitingCausalBoundary && !visibleClientSelectionAwaitingCommit()
                ) {
                    val observedOwner = surface.boundOwner
                    synchronized(tmuxTransportLock) {
                        val snapshot = mutableTmuxSnapshot.value
                        if (snapshot != null && observedOwner != null &&
                            moshPainterHandoff.admitsTransportActivity(
                                observedOwner,
                                tmuxTransportGeneration,
                                snapshot.activeWindowId,
                            )
                        ) {
                            // SSP is the side channel's output source. Report
                            // activity even while history holds the painter
                            // closed, before admission can discard these bytes.
                            // An unproven window switch and a forced cached
                            // framebuffer cannot provide this evidence.
                            submitTmuxRenderFact(
                                SharedTmuxRenderFact.TransportOutputObserved(
                                    surfaceId = TMUX_RENDER_LIVE_SURFACE_ID,
                                    owner = SharedTmuxRenderOwner(
                                        observedOwner.windowId,
                                        observedOwner.paneId,
                                        observedOwner.epoch,
                                    ),
                                ),
                            )
                        }
                    }
                }
                // Activity may invalidate history and rebind the same pane
                // synchronously; admission must use the resulting owner.
                val liveOwner = surface.boundOwner
                if (repaintRequestId == null) {
                    receipt?.deliveryId?.let { deliveryId ->
                        if (deliveryId > lastNaturalMoshDeliveryId) {
                            lastNaturalMoshDeliveryId = deliveryId
                        }
                    }
                }
                var startCausalRepaintFor: RenderOwner? = null
                val handoffAdmission = moshPainterHandoff.admission(
                    deliveryId = receipt?.deliveryId,
                    repaintRequestId = repaintRequestId,
                    liveOwner = liveOwner,
                )
                val admission = when (handoffAdmission) {
                    MoshPainterHandoff.Admission.PassThrough -> {
                        if (repaintRequestId != null && repaintRequestId == authorityMoshRepaintRequestId) {
                            // Nullable equality is the exact check: a claim
                            // forced before the first ledger bind is accepted
                            // through the untagged painter feed, like every
                            // other frame before that bind.
                            val authorityOwner = authorityMoshRepaintOwner
                            if (authorityOwner == liveOwner) {
                                MoshRenderHistoryDeliveryFence.TransportOutputAdmission(
                                    accepted = true,
                                    feedOwner = authorityOwner,
                                )
                            } else {
                                MoshRenderHistoryDeliveryFence.TransportOutputAdmission.Rejected
                            }
                        } else {
                            moshRenderHistoryFence.admitTransportOutput(repaintRequestId, liveOwner)
                        }
                    }
                    MoshPainterHandoff.Admission.Reject ->
                        MoshRenderHistoryDeliveryFence.TransportOutputAdmission.Rejected
                    is MoshPainterHandoff.Admission.RejectAndStart -> {
                        // The painter shares the control client's tmux
                        // session, so this natural redraw is already the
                        // selected window: `select-window` moved every client
                        // and the stamped `switch-client` that follows is a
                        // no-op. Waiting for that reply before attributing a
                        // full frame left the surface blank until the quiet
                        // watchdog, because an unchanged screen never yields
                        // another SSP delta.
                        startCausalRepaintFor = handoffAdmission.owner
                        MoshRenderHistoryDeliveryFence.TransportOutputAdmission.Rejected
                    }
                    is MoshPainterHandoff.Admission.AcceptOwned -> {
                        val isAuthorityFrame = repaintRequestId != null &&
                            repaintRequestId == authorityMoshRepaintRequestId
                        val authorityOwnerMatches = !isAuthorityFrame ||
                            authorityMoshRepaintOwner == handoffAdmission.owner
                        if (authorityOwnerMatches) {
                            MoshRenderHistoryDeliveryFence.TransportOutputAdmission(
                                accepted = true,
                                feedOwner = handoffAdmission.owner,
                            )
                        } else {
                            MoshRenderHistoryDeliveryFence.TransportOutputAdmission.Rejected
                        }
                    }
                }
                val rendered = admission.accepted && surface.feed(admission.feedOwner, event.bytes)
                if (!rendered) {
                    diagnostics.record(
                        "render_transport_frame_rejected",
                        mapOf(
                            "detail" to "request=${event.receipt?.repaintRequestId} delivery=${receipt?.deliveryId} admission=${handoffAdmission::class.simpleName} owner=${liveOwner?.let { "${it.windowId}/${it.paneId}" }}",
                            "transport" to diagnosticTransport,
                        ),
                    )
                }
                receipt?.deliveryId?.let { deliveryId ->
                    moshRenderHistoryFence.noteTransportOutputResult(
                        deliveryId = deliveryId,
                        repaintRequestId = repaintRequestId,
                        renderedFully = rendered,
                        livePainterOwner = surface.boundOwner,
                    )
                    if (repaintRequestId != null) {
                        handleMoshPainterHandoffResolution(
                            moshPainterHandoff.noteRendered(
                                requestId = repaintRequestId,
                                deliveryId = deliveryId,
                                renderedFully = rendered,
                                liveOwner = surface.boundOwner,
                            ),
                        )
                    }
                    val requestId = repaintRequestId
                    if (rendered && requestId != null && requestId == authorityMoshRepaintRequestId) {
                        authorityMoshAcceptedDelivery = requestId to deliveryId
                    }
                    completeAuthorityMoshRepaintIfReady()
                }
                startCausalRepaintFor?.let(::startMoshPainterHandoffRepaint)
            }
            is SharedSessionEvent.Challenge -> when (event.kind) {
                "credential" -> pendingCredential?.let {
                    if (!it.responseSubmitted.get()) {
                        publishSessionState(SshSessionUiState.AwaitingCredential(it.challenge))
                    }
                }
                "host_key" -> pendingHostKey?.let {
                    if (!it.responseSubmitted.get()) {
                        publishSessionState(SshSessionUiState.AwaitingHostKey(it.challenge))
                    }
                }
                "owner_authorization" -> pendingOwnerAuthorization?.let {
                    if (!it.responseSubmitted.get()) {
                        publishSessionState(SshSessionUiState.AwaitingOwnerAuthorization(it.challenge))
                    }
                }
            }
            is SharedSessionEvent.Failure -> {
                // Swift authority:
                // `Packages/TesseraCore/Sources/TesseraSessionCore/SessionEndClassification.swift`
                // (`SessionRetryPolicy`) — the transient-marker table and the
                // structural rules in front of it.
                val transient = SharedSessionPolicy.shouldRetry(
                    explicitDisconnect = explicitDisconnect,
                    hadConnectedTransport = hasConnectedTransport,
                    alreadyRecovering = recoveringUnexpectedDisconnect,
                    code = event.code,
                    arguments = event.arguments,
                )
                transportConnected = false
                // The detail is what says WHY — "mosh-server is not available
                // on the remote host", a UDP timeout, a native error. Dropping
                // it left every transport failure indistinguishable in the log.
                // It is already shown on screen via failureMessage(); redact it
                // through the shared authority before it also lands in the log.
                val failureDetail = event.arguments["detail"]
                    ?.takeIf(String::isNotBlank)
                    ?.let { SharedRedaction.redact(it) }
                diagnostics.record(
                    "session_failure",
                    buildMap {
                        put("code", event.code)
                        put("transport", diagnosticTransport)
                        if (failureDetail != null) put("detail", failureDetail)
                    },
                )
                if (transient) {
                    publishSessionState(SshSessionUiState.Connecting)
                    recoveringUnexpectedDisconnect = true
                    currentIntent = null
                    scheduleReconnect(event.code)
                } else {
                    publishSessionState(SshSessionUiState.Failed(failureMessage(event.code, event.arguments)))
                }
                restore.save(
                    SessionRestoreRecord(
                        sessionId = sessionId,
                        hostId = host.id,
                        transportKind = diagnosticTransport,
                        tmuxTarget = host.tmuxTarget,
                        lastSelection = currentTmuxSelection(),
                        reconnectRequired = true,
                        updatedAtEpochMilliseconds = System.currentTimeMillis(),
                    ),
                )
            }
            is SharedSessionEvent.CommandRejected -> handleCommandRejected(event.code, event.commandCode)
            is SharedSessionEvent.RecoverableWarning -> diagnostics.record(
                "session_warning",
                event.arguments + mapOf("code" to event.code, "transport" to diagnosticTransport),
            )
            is SharedSessionEvent.Diagnostics -> diagnostics.record(
                event.code,
                event.values + mapOf("transport" to diagnosticTransport),
            )
            is SharedSessionEvent.ProtocolFailure -> {
                diagnostics.record(
                    "session_protocol_failure",
                    mapOf("detail" to event.detail, "transport" to diagnosticTransport),
                )
                publishSessionState(SshSessionUiState.Failed(event.detail))
            }
            is SharedSessionEvent.Unhandled -> diagnostics.record(
                "session_unhandled_event",
                mapOf("detail" to event.kind, "transport" to diagnosticTransport),
            )
            is SharedSessionEvent.Destroyed -> diagnostics.record(
                "session_runtime_destroyed",
                mapOf("transport" to diagnosticTransport),
            )
            else -> Unit
        }
    }

    private suspend fun perform(command: SharedBackendCommand) {
        if (closed) return
        val gate = command.authorityGate
        if (host.tmuxMode != TmuxModes.OFF && gate != SharedCommandAuthorityGate.UNGATED) {
            if (gate == SharedCommandAuthorityGate.MUTATION) {
                // The screen's tmux commands obey the same gate as Agent
                // Center's placement (D7), a running take-back included, and
                // decide in the critical section of their enqueue: a peer
                // verdict or take-back reduced between an unlocked check and
                // the write would otherwise let a command it refuses through.
                synchronized(tmuxTransportLock) {
                    if (mutableTmuxAuthority.value is SharedTmuxGridAuthoritySnapshot.Peer ||
                        tmuxAuthorityMutationRefusal() != null) {
                        refusePeerBlockedTmuxMutation(command)
                    } else {
                        performTmuxMutation(command)
                    }
                }
                return
            }
            // Typing keeps its own gate: M7 lets keys reach a live mosh link
            // while a tap only waits for the channel over no known peer.
            if (mutableTmuxAuthority.value is SharedTmuxGridAuthoritySnapshot.Peer) {
                refusePeerBlockedTmuxMutation(command)
                if (command is SharedBackendCommand.SendInput) dropAdmittedTmuxInput()
                return
            }
        }
        when (command) {
            is SharedBackendCommand.Connect -> startConnection(command.intent)
            is SharedBackendCommand.CancelConnect -> withContext(Dispatchers.IO) { teardownTransport() }
            SharedBackendCommand.Disconnect -> withContext(Dispatchers.IO) { teardownTransport() }
            is SharedBackendCommand.SendInput -> if (host.tmuxMode == TmuxModes.OFF) {
                if (usesMoshPrimaryTransport()) {
                    moshTransport?.let { sendMoshInput(it, command.bytes.copyOf()) }
                } else {
                    commandChannel?.send(TransportCommand.Input(command.bytes.copyOf()))
                }
            } else if (mutableTmuxAuthority.value !is SharedTmuxGridAuthoritySnapshot.Peer && !tmuxInputGated) {
                // Re-checked at apply time: the gate may have closed while the
                // command waited in the ordered input queue.
                if (usesMoshPrimaryTransport()) {
                    moshTransport?.let { sendMoshInput(it, command.bytes.copyOf()) }
                } else {
                    mutableTmuxSnapshot.value?.activePaneId?.let { sendTmuxInput(it, command.bytes) }
                }
            } else {
                dropAdmittedTmuxInput()
            }
            is SharedBackendCommand.Resize -> if (host.tmuxMode == TmuxModes.OFF) {
                if (usesMoshPrimaryTransport()) {
                    moshTransport?.resize(command.columns, command.rows)
                } else {
                    commandChannel?.send(TransportCommand.Resize(command.columns, command.rows))
                }
            } else {
                val viewport = SharedTmuxGridSize(command.columns, command.rows)
                synchronized(tmuxTransportLock) {
                    val invalidatesRecovery = lastTmuxViewport != viewport
                    if (invalidatesRecovery) discardObsoleteTmuxWindowSizeReplays()
                    lastTmuxViewport = viewport
                    // Submit the new measurement while recovery still protects its old echo.
                    submitAuthorityGeometryFacts()
                    if (invalidatesRecovery) {
                        ordinaryTmuxWindowRecovery = null
                        submitAuthorityOrdinaryRecovery()
                    }
                }
                diagnostics.record(
                    "tmux_viewport",
                    mapOf("detail" to "${command.columns}x${command.rows}", "transport" to diagnosticTransport),
                )
                // A held own-stamp read may have been waiting for this size.
                // Reconcile even while yielded. publishTmuxClientSize withholds
                // everything that would touch the peer's session but still
                // tracks this device's own mosh canvas, and the latched
                // viewport is what the take-back replays. It owns the mosh PTY
                // size under tmux because a compact client's canvas is the
                // projected grid, not the raw viewport.
                reconcileTmuxClientSize(forceAllWindows = true)
            }
            is SharedBackendCommand.SubmitChallengeResponse -> applyChallengeDecision(command)
            is SharedBackendCommand.SetFocused -> Unit
            is SharedBackendCommand.SetVisibility -> Unit
            SharedBackendCommand.RequestFullRepaint -> withContext(Dispatchers.Main.immediate) {
                terminalSurface?.requestFullRepaint()
                if (usesMoshPrimaryTransport() && !moshPainterHandoff.isActive) {
                    val repaintRequestId = allocateMoshRepaintRequestId()
                    if (repaintRequestId == null) {
                        diagnostics.record(
                            "render_transport_sequence_exhausted",
                            mapOf("transport" to diagnosticTransport),
                        )
                    } else {
                        moshTransport?.forceFullRepaint(repaintRequestId)
                    }
                }
            }
            is SharedBackendCommand.SelectTmuxWindow,
            is SharedBackendCommand.SelectTmuxPane,
            is SharedBackendCommand.SendTmuxPaneInput,
            is SharedBackendCommand.SendTmuxPaneKey,
            SharedBackendCommand.CreateTmuxWindow,
            is SharedBackendCommand.CloseTmuxWindow,
            is SharedBackendCommand.CloseTmuxPane,
            is SharedBackendCommand.SplitTmuxPane,
            is SharedBackendCommand.CycleTmuxPane,
            is SharedBackendCommand.SetTmuxPaneZoomed,
            is SharedBackendCommand.MoveTmuxWindow,
            SharedBackendCommand.RenumberTmuxWindows,
            is SharedBackendCommand.RenameTmuxWindow,
            is SharedBackendCommand.ClaimTmuxGridAuthority,
            -> performTmuxMutation(command)
            is SharedBackendCommand.SetTmuxGridPresentation -> {
                synchronized(tmuxTransportLock) {
                    if (tmuxGridPresentation != command.presentation) {
                        tmuxGridPresentation = command.presentation
                        if (!authorityClaimLate()) lastPublishedTmuxSize = null
                        restartCompactTmuxSizing()
                        discardObsoleteTmuxWindowSizeReplays()
                        submitAuthorityGeometryFacts()
                        ordinaryTmuxWindowRecovery = null
                        submitAuthorityOrdinaryRecovery()
                    }
                }
                if (mutableTmuxAuthority.value !is SharedTmuxGridAuthoritySnapshot.Peer) {
                    reconcileTmuxClientSize(forceAllWindows = true)
                }
            }
            is SharedBackendCommand.ReclaimTmuxGridAuthority -> synchronized(tmuxTransportLock) {
                if (!closed) claimTmuxGridAuthority()
            }
            is SharedBackendCommand.CompleteTmuxGridAuthorityRepaint -> synchronized(tmuxTransportLock) {
                if (!closed) settleTmuxGridAuthority(command.authorityGeneration)
            }
        }
    }

    /**
     * Typing the gate closed on after the surface admitted it (S5′). The
     * IME's line model recorded the dropped text: reset it as for a refusal
     * at the surface. A paste is one write (`TerminalEmulator.paste`), so the
     * gate never cuts one between its delimiters.
     */
    private fun dropAdmittedTmuxInput() {
        terminalSurface?.let(refusedTerminalInputImeReset)
    }

    /**
     * Typing reaches Mosh only through a live driver. While none runs
     * (connecting, reconnecting, closed) the transport admits nothing; the
     * keys are dropped, as a refused tmux key is, and must not end the
     * ordered input lane.
     */
    private suspend fun sendMoshInput(transport: AndroidMoshTransport, bytes: ByteArray) {
        try {
            transport.send(bytes)
        } catch (_: MoshInputNotAdmittedException) {
            dropAdmittedTmuxInput()
        }
    }

    private fun refusePeerBlockedTmuxMutation(command: SharedBackendCommand) {
        diagnostics.record(
            "tmux_peer_mutation_blocked",
            mapOf("command" to command::class.java.simpleName, "transport" to diagnosticTransport),
        )
        when (command) {
            is SharedBackendCommand.SendTmuxPaneInput -> complete(command.receipt, "tmux_owned_by_peer")
            is SharedBackendCommand.SendTmuxPaneKey -> complete(command.receipt, "tmux_owned_by_peer")
            else -> Unit
        }
    }

    /**
     * The screen's tmux mutations (the shared gate's MUTATION commands).
     * Never suspends: under tmux, [perform] runs it in the critical section
     * that admitted it.
     */
    private fun performTmuxMutation(command: SharedBackendCommand) {
        when (command) {
            is SharedBackendCommand.SelectTmuxWindow -> selectTmuxWindow(command.id)
            is SharedBackendCommand.SelectTmuxPane ->
                selectTmuxPane(command.id, preservingWindowZoom = true)
            is SharedBackendCommand.SendTmuxPaneInput -> {
                val paneId = command.paneId.removePrefix("%").toIntOrNull()
                if (paneId == null) complete(command.receipt, "invalid_tmux_pane")
                else sendTmuxInput(paneId, command.bytes, command.receipt)
            }
            is SharedBackendCommand.SendTmuxPaneKey -> {
                val paneId = command.paneId.removePrefix("%").toIntOrNull()
                if (paneId == null) complete(command.receipt, "invalid_tmux_pane")
                else sendTmuxControl(
                    "send-keys -t %$paneId ${if (command.key == SharedTmuxPaneKey.ENTER) "Enter" else "Escape"}",
                    command.receipt?.let(TmuxResponsePurpose::CommandCompletion) ?: TmuxResponsePurpose.Ignore,
                )
            }
            SharedBackendCommand.CreateTmuxWindow -> {
                val snapshot = mutableTmuxSnapshot.value
                val target = snapshot?.sessionId?.let { "\$$it" }
                replayTmuxClientGeometryBeforeWindowCreation(snapshot)
                selectTmuxDynamicWindow(SharedTmuxCommands.newWindowAtEnd(target))
            }
            is SharedBackendCommand.CloseTmuxWindow -> closeTmuxWindow(command.id)
            is SharedBackendCommand.CloseTmuxPane -> sendTmuxControl("kill-pane -t ${command.id}", TmuxResponsePurpose.Ignore)
            is SharedBackendCommand.SplitTmuxPane -> {
                val paneId = command.id.removePrefix("%").toIntOrNull()
                if (mutableTmuxSnapshot.value?.windows?.any { window -> window.panes.any { it.id == paneId } } == true &&
                    mutableTmuxSnapshot.value?.isWindowListHydrated == true) {
                    sendTmuxControl(SharedTmuxCommands.splitPane(command.id,
                        command.axis == com.bambouville.tessera.core.bridge.SharedTmuxSplitAxis.HORIZONTAL, command.before), TmuxResponsePurpose.Ignore)
                }
            }
            is SharedBackendCommand.CycleTmuxPane -> cycleTmuxPane(command.forward)
            is SharedBackendCommand.SetTmuxPaneZoomed -> {
                val paneId = command.id.removePrefix("%").toIntOrNull()
                val currentlyZoomed = mutableTmuxSnapshot.value?.activeWindow?.zoomed == true
                if (paneId != null && currentlyZoomed != command.zoomed) {
                    sendTmuxControl("resize-pane -Z -t %$paneId", TmuxResponsePurpose.Ignore)
                }
            }
            is SharedBackendCommand.MoveTmuxWindow -> command.id.removePrefix("@").toIntOrNull()?.let {
                beginTmuxWindowReorder(it, command.destination)
            }
            SharedBackendCommand.RenumberTmuxWindows -> beginTmuxWindowRenumber()
            is SharedBackendCommand.RenameTmuxWindow -> sendTmuxControl(
                "rename-window -t ${command.id} ${quoteTmux(command.name)}",
                TmuxResponsePurpose.Ignore,
            )
            is SharedBackendCommand.ClaimTmuxGridAuthority -> synchronized(tmuxTransportLock) {
                if (!closed) claimTmuxGridAuthority()
            }
            else -> Unit
        }
    }

    private fun startConnection(intent: SharedConnectionIntent) {
        if (connectionJob?.isActive == true || intent.requestId != currentIntent?.requestId) return
        moshUsingSshFallback = false
        scope.launch(Dispatchers.Main.immediate) {
            plainSshPainterActive = false
            configurePainterFeedAdmission()
            publishScrollRouting()
        }
        refreshTmuxWindowPaintScope()
        remoteSessionTerminated = false
        pendingTmuxDegrade = null
        tmuxControlEngaged = false
        synchronized(tmuxLaunchOutput) { tmuxLaunchOutput.setLength(0) }
        connectionJob = scope.launch {
            try {
                val hops = buildRoute()
                diagnostics.record(
                    "connect_start",
                    mapOf("hops" to hops.size.toString(), "tmux" to (host.tmuxMode != TmuxModes.OFF).toString(), "transport" to diagnosticTransport),
                )
                if (usesMoshPrimaryTransport()) {
                    check(JniMoshNativeClientFactory.isAvailable) {
                        "This Android build was assembled with -Ptessera.enableMoshNative=false " +
                            "and does not include Mosh. Rebuild without that flag."
                    }
                    val result = runMoshTransport(intent, hops)
                    if (result == MoshRunResult.FALLBACK_TO_SSH && currentIntent?.requestId == intent.requestId) {
                        moshUsingSshFallback = true
                        scope.launch(Dispatchers.Main.immediate) {
                            configurePainterFeedAdmission()
                            publishScrollRouting()
                        }
                        refreshTmuxWindowPaintScope()
                        diagnostics.record(
                            "mosh_jump_fallback_start",
                            mapOf("hops" to hops.size.toString(), "transport" to diagnosticTransport),
                        )
                        if (host.tmuxMode != TmuxModes.OFF) runTmuxTransport(intent, hops)
                        else {
                            activatePlainSshPainter()
                            runPlainSshTransport(intent, hops)
                        }
                    }
                    return@launch
                }
                if (host.tmuxMode != TmuxModes.OFF) {
                    runTmuxTransport(intent, hops)
                    // iOS degrades a failed tmux launch to a plain shell for
                    // both auto and pinned modes rather than stranding the
                    // user on a dead session; it records the outcome for its
                    // host badge but always re-attempts tmux next time, so a
                    // host that gains tmux later simply starts working again.
                    val degrade = pendingTmuxDegrade
                    if (degrade != null && currentIntent?.requestId == intent.requestId) {
                        pendingTmuxDegrade = null
                        releaseTmuxRouteForDegrade()
                        diagnostics.record(
                            "tmux_launch_degraded",
                            mapOf("code" to degrade.name, "transport" to diagnosticTransport),
                        )
                        mutableTmuxDegradeNotice.value = degradeNotice(degrade)
                        activatePlainSshPainter()
                        // The failed tmux launch already ran the startup snippet.
                        // Reapply environment in the replacement shell, not the snippet.
                        runPlainSshTransport(intent, hops, includeStartupSnippet = false)
                    }
                    return@launch
                }
                activatePlainSshPainter()
                runPlainSshTransport(intent, hops)
            } catch (_: CancellationException) {
                if (currentIntent?.requestId == intent.requestId) {
                    runCatching { shared.cancelConnect(intent.requestId) }
                }
            } catch (failure: Throwable) {
                if (currentIntent?.requestId == intent.requestId) {
                    diagnostics.record(
                        "session_transport_exception",
                        mapOf("detail" to redactedFailure(failure), "transport" to diagnosticTransport),
                    )
                    emitSharedIfOpen {
                        emitFailure(
                            intent.requestId,
                            "ssh_connection_failed",
                            mapOf("detail" to redactedFailure(failure)),
                        )
                    }
                }
            } finally {
                withContext(NonCancellable) {
                    finishMoshServerCleanup(
                        intent = intent,
                        terminate = explicitDisconnect,
                    )
                }
                clearPendingChallenges()
                detachForwarding()
                clearMoshAttemptTransport(preserveYieldedAuthority = !explicitDisconnect)
                connection?.close()
                connection = null
                sessionProgramStatus?.noteRawTransportLost()
                commandChannel?.close()
                commandChannel = null
                commandWriterJob?.cancelAndJoin()
                commandWriterJob = null
                errorReaderJob?.cancelAndJoin()
                errorReaderJob = null
                // This controller represents one logical session across an
                // automatic transport replacement. Keep a known peer verdict
                // fail-closed until the replacement channel re-queries the
                // server; only an explicit disconnect may clear it here.
                clearTmuxTransport(preserveYieldedAuthority = !explicitDisconnect)
                invalidateAgentEndpoint()
                routeOwner?.close()
                routeOwner = null
            }
        }
    }

    private suspend fun runPlainSshTransport(intent: SharedConnectionIntent, hops: List<SshRouteHop>, includeStartupSnippet: Boolean = true) {
        val geometry = withContext(Dispatchers.Main.immediate) {
            terminalSurface?.snapshotNonSecretState()
        }
        val route = backend.openRoute(
            request = SshRouteRequest(
                hops = hops,
                initialColumns = geometry?.columns?.takeIf { it >= 4 } ?: 80,
                initialRows = geometry?.rows?.takeIf { it >= 4 } ?: 24,
            ),
            passwordProvider = SshPasswordProvider { hop -> requestPassword(intent, hop) },
            hostKeyPolicy = SshHostKeyPolicy { observation -> verifyHostKey(intent, observation) },
            keyAuthorizationProvider = SshKeyAuthorizationProvider { hop -> authorizeKey(intent, hop) },
        )
        routeOwner = route
        val established = route.openTerminal(
            columns = geometry?.columns?.takeIf { it >= 4 } ?: 80,
            rows = geometry?.rows?.takeIf { it >= 4 } ?: 24,
            routeMarker = UUID.randomUUID().toString(),
        )
        connection = established
        // Sent before interactive input, shared with the mosh/tmux prologue.
        // A continuation into an existing tmux pane never injects shell text.
        com.bambouville.tessera.data.HostLaunchSettings.stdin(host, includeStartupSnippet).takeIf { it.isNotEmpty() }?.let {
            established.write(it.encodeToByteArray())
        }
        registerAgentEndpoint(
            route = route,
            transport = AgentEndpointTransport.SSH,
            rawWriter = established::write,
            routeMarker = established.routeMarker,
        )
        attachForwardingIfNeeded(intent, hops)
        val commands = Channel<TransportCommand>(Channel.UNLIMITED)
        commandChannel = commands
        commandWriterJob = scope.launch(Dispatchers.IO) {
            try {
                for (transportCommand in commands) {
                    when (transportCommand) {
                        is TransportCommand.Input -> established.write(transportCommand.bytes)
                        is TransportCommand.Resize -> established.resize(transportCommand.columns, transportCommand.rows)
                    }
                }
            } catch (failure: Throwable) {
                if (failure !is CancellationException && currentIntent?.requestId == intent.requestId && !closed) {
                    emitSharedIfOpen {
                        emitFailure(
                            intent.requestId,
                            "ssh_writer_failed",
                            mapOf("detail" to redactedFailure(failure)),
                        )
                    }
                }
            }
        }
        emitSharedIfOpen { emitTransportConnected(intent) }
        errorReaderJob = scope.launch(Dispatchers.IO) {
            try {
                readStream(established.standardError, intent, scansProgramStatus = false)
            } catch (failure: Throwable) {
                if (failure !is CancellationException && currentIntent?.requestId == intent.requestId && !closed) {
                    diagnostics.record("ssh_stderr_reader_closed", mapOf("detail" to redactedFailure(failure)))
                }
            }
        }
        withContext(Dispatchers.IO) { readStream(established.standardOutput, intent) }
        val primaryExitStatus = established.awaitRemoteExitStatus()
        // EOF alone is recoverable transport loss; only an authenticated
        // remote status — including 0 — proves the shell itself finished.
        val remoteExited = SharedSessionPolicy.remoteProcessEnded(primaryExitStatus)
        diagnostics.record(
            "ssh_stream_ended",
            mapOf(
                "code" to (primaryExitStatus?.toString() ?: "none"),
                "result" to remoteExited.toString(),
            ),
        )
        established.close()
        if (currentIntent?.requestId == intent.requestId) {
            remoteSessionTerminated = remoteExited
            emitSharedIfOpen { emitTransportDisconnected(intent.requestId) }
        }
    }

    /**
     * The shared scroll rule's one session-supplied input (iOS passes
     * `!moshPaneCycleEnabled` to the same core policy): mouse reporting stands
     * in for the alternate screen only while this session has no local
     * scrollback to offer — plain mosh, or mosh+tmux before the side channel
     * has produced a pane grid. Once the grid exists, a swipe on the primary
     * screen stays on the local overlay even with tmux's `mouse on` in force,
     * instead of putting the pane into copy-mode.
     */
    private fun publishScrollRouting() {
        val surface = terminalSurface ?: return
        val snapshot = mutableTmuxSnapshot.value
        val hasMoshScrollbackOverlay = snapshot?.activePaneId != null
        surface.setMouseReportingImpliesAltScreen(
            usesMoshPrimaryTransport() && !hasMoshScrollbackOverlay,
        )
        surface.setRemoteTmuxPane(
            snapshot?.takeIf { usesMoshPrimaryTransport() }?.activeRemoteTmuxPane(),
        )
    }

    /**
     * The active pane's modes as the pane-metadata feed reports them (iOS
     * reads the same cached state for its scroll and click forwards). Wheel
     * reports aim at the pane's centre, so tmux hands them to that pane even
     * when the gesture started over another one.
     */
    private fun SharedTmuxSnapshot.activeRemoteTmuxPane(): RemoteTmuxPane? {
        val window = activeWindow ?: return null
        val paneId = activePaneId ?: return null
        val pane = window.panes.firstOrNull { it.id == paneId } ?: return null
        val alternateScreen = pane.isAlternateScreen == true
        val mouseReporting = pane.isMouseReporting == true
        if (!alternateScreen && !mouseReporting) return null
        val rect = window.layout?.findPane(paneId)
        return RemoteTmuxPane(
            alternateScreen = alternateScreen,
            mouseReporting = mouseReporting,
            column = rect?.let { it.x + it.width / 2 + 1 } ?: 0,
            row = rect?.let { it.y + it.height / 2 + 1 } ?: 0,
        )
    }

    private fun usesMoshPrimaryTransport(): Boolean =
        host.transportKind == com.bambouville.tessera.data.TransportKinds.MOSH && !moshUsingSshFallback

    /**
     * Republish what the primary terminal is being painted with. A mosh
     * session that fell back to SSH is fed pane capture like any other SSH
     * session, so the compact renderer must follow the live predicate rather
     * than the host's configured transport.
     */
    private fun refreshTmuxWindowPaintScope() {
        mutableTmuxWindowIsPaintedWhole.value = usesMoshPrimaryTransport()
    }

    /**
     * A plain terminal PTY and mosh's SSP may use the untagged painter entry
     * point while it is explicitly admitted. Ledger repaint feeds remain
     * owner-tagged, including when side-channel history has a bound owner.
     * This follows [publishScrollRouting]'s main-confined terminal contract.
     */
    private fun configurePainterFeedAdmission() {
        terminalSurface?.setPainterFeedAdmission(
            host.tmuxMode == TmuxModes.OFF ||
                (usesMoshPrimaryTransport() &&
                    !moshLiveHistoryRevealed &&
                    !moshPainterHandoff.isActive) ||
                plainSshPainterActive,
        )
        paneSurfaces.values.forEach { it.setPainterFeedAdmission(false) }
        overlaySurfaces.values.forEach { it.setPainterFeedAdmission(false) }
    }

    /**
     * Switch the final ingress seam before the first byte can arrive from a
     * plain SSH PTY.  This is load-bearing for tmux launch degradation: the
     * host remains configured for tmux even though the live renderer no
     * longer is one.
     */
    private suspend fun activatePlainSshPainter() = withContext(Dispatchers.Main.immediate) {
        plainSshPainterActive = true
        configurePainterFeedAdmission()
        publishScrollRouting()
        if (host.tmuxMode != TmuxModes.OFF) releaseTmuxAuthorityForPlainShell()
    }

    /**
     * The configured tmux launch degraded to a plain shell. A show that
     * arrived first (the tab composes before it connects) left an intent the
     * missing channel can never resolve: drop it, and project nothing, so
     * typing is not gated for its ~20 s window.
     */
    private fun releaseTmuxAuthorityForPlainShell() {
        synchronized(tmuxTransportLock) {
            if (closed) return
            lastTmuxAuthorityResult?.pendingIntent?.token?.let { token ->
                diagnostics.record(
                    "tmux_authority_intent_dropped",
                    mapOf("detail" to "token=$token plain shell", "transport" to diagnosticTransport),
                )
                reduceTmuxAuthority { session, now -> session.cancelIntent(now) }
            }
            publishTmuxAuthorityPresentation()
        }
    }

    private suspend fun attachForwardingIfNeeded(
        intent: SharedConnectionIntent,
        hops: List<SshRouteHop>,
    ) {
        if (closed || currentIntent?.requestId != intent.requestId || forwardingRules.isEmpty()) return
        runCatching {
            detachForwarding()
            val runtime = when {
                usesMoshPrimaryTransport() -> {
                    val sideChannel = backend.openForwardingSideChannel(
                        request = SshRouteRequest(hops),
                        passwordProvider = SshPasswordProvider { hop -> requestPassword(intent, hop) },
                        hostKeyPolicy = SshHostKeyPolicy { observation -> verifyHostKey(intent, observation) },
                        keyAuthorizationProvider = SshKeyAuthorizationProvider { hop -> authorizeKey(intent, hop) },
                    )
                    forwardingSideChannel = sideChannel
                    sideChannel.runtime()
                }
                connection != null -> checkNotNull(connection).createForwardingRuntime()
                tmuxConnection != null -> checkNotNull(tmuxConnection).createForwardingRuntime()
                else -> return
            }
            forwardingManager.attach(runtime, forwardingRules)
            forwardingAttached = true
            diagnostics.record(
                "forwarding_attached",
                mapOf("rules" to forwardingRules.size.toString(), "transport" to diagnosticTransport),
            )
        }.onFailure { failure ->
            forwardingAttached = false
            forwardingSideChannel?.close()
            forwardingSideChannel = null
            forwardingManager.reportTransportUnavailable(
                forwardingRules,
                "Forwarding side channel is unavailable: ${redactedFailure(failure)}",
            )
            diagnostics.record(
                "forwarding_attach_failed",
                mapOf("detail" to redactedFailure(failure), "transport" to diagnosticTransport),
            )
        }
    }

    private suspend fun detachForwarding() {
        forwardingManager.detach()
        forwardingAttached = false
        forwardingSideChannel?.close()
        forwardingSideChannel = null
    }

    private fun detachForwardingBlocking() {
        forwardingManager.detachBlocking()
        forwardingAttached = false
        forwardingSideChannel?.close()
        forwardingSideChannel = null
    }

    private suspend fun runTmuxTransport(
        intent: SharedConnectionIntent,
        hops: List<SshRouteHop>,
        emitTransportLifecycle: Boolean = true,
        sideChannelRoute: SshRouteOwner? = null,
    ) {
        val target = tmuxSessionTargetOverride
            ?: if (host.tmuxMode == TmuxModes.PINNED) requireNotNull(host.tmuxTarget)
            else SharedAutomaticTmuxTarget.sessionName(host.username, host.hostname, host.port)
        diagnostics.record(
            "tmux_launch",
            mapOf(
                "tmux" to if (host.tmuxMode == TmuxModes.PINNED) "pinned" else "auto",
                "detail" to target,
                "phase" to if (emitTransportLifecycle) "primary" else "side_channel",
            ),
        )
        val (tmux, authenticatedRoute) = if (emitTransportLifecycle) {
            val route = backend.openRoute(
                request = SshRouteRequest(hops),
                passwordProvider = SshPasswordProvider { hop -> requestPassword(intent, hop) },
                hostKeyPolicy = SshHostKeyPolicy { observation -> verifyHostKey(intent, observation) },
                keyAuthorizationProvider = SshKeyAuthorizationProvider { hop -> authorizeKey(intent, hop) },
            )
            routeOwner = route
            // The -CC control client is this device's sizing participant on
            // every form factor, exactly like iOS' `.resizeTmux` controller.
            // A compact client narrows the grid through the shared compact
            // projection below, never by attaching as a permanent
            // `ignore-size` observer: an observer can never fit the phone and
            // can never take control back from a peer.
            route.openTmux(sessionTarget = target, commandTransform = {
                com.bambouville.tessera.data.HostLaunchSettings.beforeCommand(host, it)
            }) to route
        } else {
            val route = checkNotNull(sideChannelRoute) {
                "Mosh tmux control requires an attempt-owned authenticated route"
            }
            route.openTmux(
                sessionTarget = target,
                // Mosh's side channel and its visible client share Tessera's
                // view session for presentation options. The authority stamp
                // is written to the owner, shared with inline clients.
                moshViewSession = true,
            ) to route
        }
        val pendingTmuxResponses = ConcurrentHashMap<Long, TmuxResponsePurpose>()
        val transportGeneration = synchronized(tmuxTransportLock) {
            tmuxTransportGeneration += 1
            initiallyRequestedTmuxRenderSurfaces.clear()
            tmuxConnection = tmux
            activeTmuxResponses = pendingTmuxResponses
            tmuxTransportGeneration
        }
        if (emitTransportLifecycle) attachForwardingIfNeeded(intent, hops)
        val tmuxCommands = Channel<TmuxControlCommand>(Channel.UNLIMITED)
        synchronized(tmuxTransportLock) {
            if (transportGeneration != tmuxTransportGeneration || tmuxConnection !== tmux) {
                tmuxCommands.close()
                tmux.close()
                return
            }
        }
        // The other half of the wire trace: what this side wrote, in wire
        // order, with the FIFO tag the core assigned. Read together with
        // `tmux_control_wire` this shows which reply the ledger attributed to
        // which command.
        var sendTraceBudget = TMUX_WIRE_TRACE_SENDS
        val writerJob = scope.launch(Dispatchers.IO) {
            for (request in tmuxCommands) {
                // Every request already holds its slot in the core's reply
                // FIFO, taken in the same critical section that queued it
                // here.  The writer therefore only writes: it can no longer
                // reorder the FIFO against the wire.
                val current = synchronized(tmuxTransportLock) {
                    val matches = !closed &&
                        transportGeneration == tmuxTransportGeneration &&
                        tmuxConnection === tmux
                    if (matches) request.copy(
                        purpose = request.purpose ?: request.fifoTag?.let { pendingTmuxResponses[it] },
                    ) else null
                }
                if (current == null) {
                    failTmuxPlatformWrite(request, pendingTmuxResponses)
                    continue
                }
                try {
                    // `wireCommands` is an atomic queue element.  In
                    // particular, a capture sequence emitted by one ledger
                    // reduce cannot be split by a platform query and corrupt
                    // the shared core's command-response FIFO.
                    for (command in current.wireCommands) {
                        tmux.sendControl(command)
                        if (sendTraceBudget > 0) {
                            sendTraceBudget -= 1
                            diagnostics.record(
                                "tmux_control_send",
                                mapOf(
                                    "owner" to if (current.ledgerOwned) "ledger" else "platform",
                                    "tag" to (current.fifoTag?.toString() ?: "-"),
                                    "detail" to tmuxWireSnippet(tmuxWireTraceCommand(command), 200),
                                    "transport" to diagnosticTransport,
                                ),
                            )
                        }
                    }
                } catch (failure: Throwable) {
                    failTmuxPlatformWrite(current, pendingTmuxResponses)
                    if (!emitTransportLifecycle) {
                        diagnostics.record(
                            "mosh_tmux_control_writer_closed",
                            mapOf("detail" to redactedFailure(failure), "transport" to diagnosticTransport),
                        )
                        tmux.close()
                    } else currentIntent?.let {
                        emitSharedIfOpen {
                            emitFailure(
                                it.requestId,
                                "tmux_command_failed",
                                mapOf("detail" to redactedFailure(failure)),
                            )
                        }
                    }
                }
            }
        }
        synchronized(tmuxTransportLock) {
            if (transportGeneration == tmuxTransportGeneration && tmuxConnection === tmux) {
                tmuxCommandWriterJob = writerJob
            } else {
                writerJob.cancel()
            }
        }
        val tmuxEventListener: (SharedTmuxEvent) -> Unit = { event ->
            handleTmuxRuntimeEvent(event, tmux, transportGeneration)
        }
        val runtime = synchronized(tmuxTransportLock) {
            val retained = if (!emitTransportLifecycle) parkedMoshTmuxCore else null
            if (retained != null) parkedMoshTmuxCore = null
            retained?.also { it.replaceListener(tmuxEventListener) }
                ?: SharedTmuxRuntime.create(tmuxEventListener)
        }
        synchronized(tmuxTransportLock) {
            if (transportGeneration != tmuxTransportGeneration || tmuxConnection !== tmux) {
                tmuxCommands.close()
                runtime.close()
                return
            }
            // Publish the writer channel with the runtime, never before it: a
            // queued command has to be able to take its slot in the reply FIFO
            // in the same critical section that queued it.
            tmuxCore = runtime
            tmuxCommandChannel = tmuxCommands
            sessionProgramStatus?.attachTmux(runtime)
            // Each read's stamps are then reduced inside its feed, in wire
            // order (§6.17). A runtime that cannot host the session (it was
            // closed) hands them over raw, as before.
            runtime.attachAuthoritySession(tmuxAuthorityLifecycle.session)
            lastProjectedTmuxAuthority = null
            projectTmuxRuntimeAuthority(lastTmuxAuthorityResult?.authority ?: mutableTmuxAuthority.value)
            // The ledger's switches, before any fact: a new handle has none.
            appliedTmuxRenderLedgerOptions = null
            tmuxRenderLedgerOptionsRefused = false
            applyTmuxRenderLedgerOptions(tmuxRenderLedgerOptions(belongsToAuthorityClaim = false))
            // Agent Center shares this control client. Placement and focus
            // obey the user's authority gate; reads and proved pane-targeted
            // `send-keys` leave grid authority unchanged.
            agentTmuxControl.attach(
                // The check and the enqueue share one critical section: a peer
                // verdict or take-back reduced in between would otherwise let
                // a mutation it refuses reach the FIFO anyway.
                sender = { command ->
                    synchronized(tmuxTransportLock) {
                        val refusal = tmuxAuthorityMutationRefusal()
                        if (refusal != null && !SharedTmuxCommands.agentCommandIsAuthorityNeutral(command.command)) {
                            recordAgentTmuxRefusal(command.command.substringBefore(' '), refusal)
                            false
                        } else {
                            enqueueTmuxPlatformCommand(command)
                        }
                    }
                },
                // Advisory, so unlocked: the sender above decides.
                refusal = ::tmuxAuthorityMutationRefusal,
                windowSelector = { target, response -> selectTmuxWindow(target, response) },
                paneSelector = { target, preservingWindowZoom, response ->
                    selectTmuxPane(target, preservingWindowZoom, response)
                },
            )
        }
        synchronized(tmuxTransportLock) { tmuxAuthorityOwnerSessionName = target }
        if (!startTmuxRenderTransport(tmux, transportGeneration)) return
        SharedTmuxCommands.hydrationCommands().forEach { command ->
            sendTmuxControl(command, TmuxResponsePurpose.Ignore)
        }
        synchronized(tmuxTransportLock) { sendTmuxAuthoritySubscription() }
        // Built before the pane-metadata subscription, never after. tmux
        // answers `refresh-client -B` by announcing the subscription's current
        // value for every pane, and for an idle agent that one announcement is
        // the only time its `@tessera_agent_state` is ever spoken. Registering
        // afterwards left that reply racing a local call, and losing the race
        // meant the agent stayed invisible for as long as it stayed idle.
        registerAgentEndpoint(
            route = authenticatedRoute,
            transport = if (emitTransportLifecycle) {
                AgentEndpointTransport.SSH_TMUX
            } else {
                AgentEndpointTransport.MOSH_TMUX
            },
            tmuxSession = target,
            tmuxControl = agentTmuxControl,
        )
        // tmux announces window renames but never pane title changes, and a
        // pane title is what a shell, editor or agent actually sets. Without
        // this feed the tab labels freeze at whatever `#{window_name}` said at
        // attach. The core owns the formats and registers feeds as topology
        // arrives, including window order once it knows the server version.
        synchronized(tmuxTransportLock) {
            if (transportGeneration == tmuxTransportGeneration && tmuxConnection === tmux) {
                desiredTmuxSubscriptions = desiredTmuxSubscriptions.copy(bell = true, paneMetadata = true, windowOrder = true)
                pushTmuxSubscriptions()
            }
        }
        requestCompactSizeRole()
        if (emitTransportLifecycle) {
            emitSharedIfOpen { emitTransportConnected(intent) }
        }
        val geometry = withContext(Dispatchers.Main.immediate) { terminalSurface?.snapshotNonSecretState() }
        reconcileTmuxViewportAfterAttach(geometry)
        errorReaderJob = scope.launch(Dispatchers.IO) {
            try {
                val buffer = ByteArray(8 * 1024)
                while (true) {
                    val count = tmux.standardError.read(buffer)
                    if (count < 0) break
                    if (count > 0) {
                        // The byte count alone never said *what* tmux
                        // complained about. The store sanitizes, truncates and
                        // redacts every value it writes.
                        val text = String(buffer, 0, count, Charsets.UTF_8)
                        noteTmuxLaunchOutput(text)
                        diagnostics.record(
                            "tmux_stderr",
                            mapOf("bytes" to count.toString(), "detail" to text),
                        )
                        emitSharedIfOpen {
                            emitDiagnostics(
                                "tmux_stderr",
                                mapOf("bytes" to count.toString()),
                            )
                        }
                    }
                }
            } catch (failure: Throwable) {
                if (failure !is CancellationException && currentIntent?.requestId == intent.requestId && !closed) {
                    diagnostics.record(
                        "tmux_stderr_reader_closed",
                        mapOf("detail" to redactedFailure(failure)),
                    )
                }
            }
        }
        val controlBytes = withContext(Dispatchers.IO) {
            readTmuxStream(
                input = tmux.standardOutput,
                intent = intent,
                runtime = runtime,
                tmux = tmux,
                transportGeneration = transportGeneration,
            )
        }
        if (emitTransportLifecycle && currentIntent?.requestId == intent.requestId) {
            val exitStatus = tmux.awaitRemoteExitStatus()
            // Only a launch that never engaged control mode is a candidate for
            // degrading. A session that ran and then died is a disconnect, and
            // must keep its existing recovery path.
            val launchFailure = if (tmuxControlEngaged) {
                null
            } else {
                SharedTmuxLaunch.classifyFailure(exitStatus, currentTmuxLaunchOutput())
            }
            if (launchFailure != null) {
                diagnostics.record(
                    "tmux_launch_failed",
                    mapOf("code" to launchFailure.name, "detail" to (exitStatus?.toString() ?: "none")),
                )
                pendingTmuxDegrade = launchFailure
                return
            }
            remoteSessionTerminated = SharedSessionPolicy.remoteProcessEnded(exitStatus)
            // A session that reports Terminated seconds after Connected is the
            // remote command exiting. Without the status and the byte count
            // there is no way to tell "tmux refused to start" from "the control
            // stream closed under us".
            diagnostics.record(
                "tmux_stream_ended",
                mapOf(
                    "code" to (exitStatus?.toString() ?: "none"),
                    "result" to remoteSessionTerminated.toString(),
                    "bytes" to controlBytes.toString(),
                ),
            )
            emitSharedIfOpen { emitTransportDisconnected(intent.requestId) }
        }
    }

    private suspend fun runMoshTransport(
        intent: SharedConnectionIntent,
        hops: List<SshRouteHop>,
    ): MoshRunResult {
        val route = SshRouteRequest(hops)
        val passwordProvider = SshPasswordProvider { hop -> requestPassword(intent, hop) }
        val hostKeyPolicy = SshHostKeyPolicy { observation -> verifyHostKey(intent, observation) }
        val keyAuthorization = SshKeyAuthorizationProvider { hop -> authorizeKey(intent, hop) }
        val target = if (host.tmuxMode == TmuxModes.OFF) null else tmuxSessionTargetOverride
            ?: if (host.tmuxMode == TmuxModes.PINNED) requireNotNull(host.tmuxTarget)
            else SharedAutomaticTmuxTarget.sessionName(host.username, host.hostname, host.port)
        val visibleGeometry = withContext(Dispatchers.Main.immediate) {
            terminalSurface?.snapshotNonSecretState()
        }
        val physicalSize = SharedTmuxGridSize(
            visibleGeometry?.columns?.takeIf { it >= 4 } ?: 80,
            visibleGeometry?.rows?.takeIf { it >= 4 } ?: 24,
        )
        // Mosh always starts at this device's physical grid. Adopting the
        // server's existing grid here is what made a phone render a peer-sized
        // canvas scaled down to illegibility; the tmux window is instead
        // brought to this grid by the -CC side channel below.
        moshAuthoritativeSize = physicalSize
        mutableMoshCanvasSize.value = physicalSize
        refreshTmuxWindowPaintScope()
        // Keep the bootstrap's already-authorized SSH route as the exact
        // server cleanup capability. This avoids a second biometric/key-use
        // authorization when an explicit disconnect retires mosh-server.
        val authenticatedCleanupRoute = backend.openRoute(
            request = route,
            passwordProvider = passwordProvider,
            hostKeyPolicy = hostKeyPolicy,
            keyAuthorizationProvider = keyAuthorization,
        )
        val cleanupRouteTransferred = AtomicBoolean(false)
        val bootstrapper = AndroidSshMoshBootstrapper(
            backend,
            passwordProvider,
            hostKeyPolicy,
            keyAuthorization,
            authenticatedRoute = authenticatedCleanupRoute,
        )
        val transport = AndroidMoshTransport(
            bootstrapper = bootstrapper,
            onBootstrapServerStarted = { serverPid ->
                if (rememberMoshServerCleanup(
                        intent = intent,
                        route = route,
                        serverPid = serverPid,
                        authenticatedRoute = authenticatedCleanupRoute,
                    )
                ) {
                    cleanupRouteTransferred.set(true)
                } else {
                    authenticatedCleanupRoute.close()
                }
            },
        )
        moshTransport = transport
        lastNaturalMoshDeliveryId = 0L
        synchronized(tmuxTransportLock) { visibleSelectionNaturalFloor = 0L }
        withContext(Dispatchers.Main.immediate) {
            retireMoshRepaintsThroughCurrent()
            moshRenderHistoryFence.resetForNewTransport()
            resetMoshPainterHandoff()
            moshLiveHistoryRevealed = false
            authorityMoshRepaintRequestId = null
            authorityMoshRepaintOwner = null
            authorityMoshAcceptedDelivery = null
            configurePainterFeedAdmission()
        }
        if (target == null) {
            val agentRoute = backend.openRoute(
                request = route,
                passwordProvider = passwordProvider,
                hostKeyPolicy = hostKeyPolicy,
                keyAuthorizationProvider = keyAuthorization,
            )
            routeOwner = agentRoute
            registerAgentEndpoint(
                route = agentRoute,
                transport = AgentEndpointTransport.MOSH,
                rawWriter = { bytes -> transport.send(bytes) },
                processRootPID = { transport.bootstrapServerPid },
                renewAuxiliaryRoute = { previous ->
                    fun isCurrent() = currentIntent?.requestId == intent.requestId &&
                        moshTransport === transport && routeOwner === previous
                    if (!isCurrent()) throw CancellationException("Mosh auxiliary route retired")
                    val renewed = backend.openRoute(
                        request = route,
                        passwordProvider = SshPasswordProvider { hop ->
                            try { requestPassword(intent, hop) }
                            finally { restoreConnectedUiAfterSideChannelChallenge() }
                        },
                        hostKeyPolicy = SshHostKeyPolicy { observation ->
                            try { verifyHostKey(intent, observation) }
                            finally { restoreConnectedUiAfterSideChannelChallenge() }
                        },
                        keyAuthorizationProvider = SshKeyAuthorizationProvider { hop ->
                            try { authorizeKey(intent, hop) }
                            finally { restoreConnectedUiAfterSideChannelChallenge() }
                        },
                    )
                    if (!isCurrent()) {
                        renewed.close()
                        throw CancellationException("Mosh auxiliary route retired")
                    }
                    renewed
                },
                publishAuxiliaryRoute = { previous, renewed ->
                    if (currentIntent?.requestId == intent.requestId && moshTransport === transport && routeOwner === previous) {
                        routeOwner = renewed
                        diagnostics.record("mosh_agent_route_renewed", mapOf("transport" to diagnosticTransport))
                        true
                    } else false
                },
            )
        }
        val finished = CompletableDeferred<MoshRunResult>()
        var connectedEmitted = false
        val livenessWatcher = MoshServerLivenessWatcher(
            scope = scope,
            probe = { pid -> probeMoshServerLiveness(intent, route, transport, pid) },
            graceMillis = MoshSessionRecoveryPolicy::serverLivenessGraceMillis,
            nextProbe = MoshSessionRecoveryPolicy::serverLivenessNextProbe,
            onServerGone = { pid ->
                if (currentIntent?.requestId == intent.requestId && moshTransport === transport &&
                    finished.complete(MoshRunResult.COMPLETED)
                ) {
                    val decision = MoshSessionRecoveryPolicy.serverLossDecision(
                        hasTmuxTarget = target != null,
                        launchCommand = host.launchCommand,
                        restorePolicy = currentSessionRestorePolicy,
                    )
                    diagnostics.record(
                        "mosh_server_lost",
                        mapOf("pid" to "$pid", "transport" to diagnosticTransport, "decision" to decision.diagnosticValue),
                    )
                    when (decision) {
                        MoshSessionRecoveryPolicy.ServerLossDecision.REBUILD -> {
                            remoteSessionTerminated = MoshSessionRecoveryPolicy.remoteProcessEndedOnTransportDisconnect()
                            emitSharedIfOpen { emitTransportDisconnected(intent.requestId) }
                        }
                        MoshSessionRecoveryPolicy.ServerLossDecision.KEEP_FOR_LAUNCH_COMMAND -> {
                            emitSharedIfOpen {
                                emitFailure(intent.requestId, "mosh_server_lost", mapOf("decision" to decision.diagnosticValue))
                            }
                        }
                    }
                }
            },
            record = { code, fields -> diagnostics.record(code, fields + ("transport" to diagnosticTransport)) },
        )
        moshServerLivenessWatcher = livenessWatcher
        updateMoshServerLiveness = {
            livenessWatcher.update(
                MoshServerLivenessWatcher.Conditions(
                    connectedEmitted = connectedEmitted && !finished.isCompleted &&
                        currentIntent?.requestId == intent.requestId && moshTransport === transport,
                    transportReachable = transport.connectivity.value.transportReachable,
                    appForeground = appForeground,
                    serverPid = transport.bootstrapServerPid,
                    ownerPromptPending = moshLivenessOwnerPromptPending,
                ),
            )
        }
        val preconnectOutput = ArrayDeque<com.bambouville.tessera.networking.mosh.MoshOutputChunk>()
        var preconnectOutputBytes = 0
        moshOutputJob = scope.launch {
            transport.output.collect { chunk ->
                if (target == null) agentEndpoint?.noteRawOutput(chunk.bytes)
                if (connectedEmitted) {
                    emitSharedIfOpen {
                        emitTerminalBytes(
                            chunk.bytes,
                            SharedTerminalOutputReceipt(
                                deliveryId = chunk.sequence,
                                repaintRequestId = chunk.repaintRequestId,
                            ),
                            attemptId = intent.requestId,
                        )
                    }
                } else {
                    preconnectOutputBytes += chunk.bytes.size
                    if (preconnectOutputBytes > MAX_MOSH_PRECONNECT_OUTPUT_BYTES) {
                        val detail = "Mosh produced too much terminal output before becoming ready"
                        if (finished.complete(MoshRunResult.COMPLETED)) {
                            emitSharedIfOpen {
                                emitFailure(intent.requestId, "mosh_preconnect_output_overflow", mapOf("detail" to detail))
                            }
                        }
                        error(detail)
                    }
                    preconnectOutput.addLast(chunk)
                }
            }
        }
        moshConnectivityJob = scope.launch {
            transport.connectivity.collect { connectivity ->
                // Published for every state, not just the connected one: at a
                // wake the interesting case is precisely a Mosh session that
                // still calls itself connected while nothing is getting
                // through.
                mutableTransportReachable.value = connectivity.transportReachable
                mutableMoshOutageTiming?.value = connectivity.outageTiming
                when (connectivity.state) {
                    MoshConnectionState.CONNECTED -> if (!connectedEmitted) {
                        emitSharedIfOpen { emitTransportConnected(intent) }
                        connectedEmitted = true
                        recordMoshPumpStats("connected")
                        while (preconnectOutput.isNotEmpty()) {
                            val chunk = preconnectOutput.removeFirst()
                            emitSharedIfOpen {
                                emitTerminalBytes(
                                    chunk.bytes,
                                    SharedTerminalOutputReceipt(
                                        deliveryId = chunk.sequence,
                                        repaintRequestId = chunk.repaintRequestId,
                                    ),
                                    attemptId = intent.requestId,
                                )
                            }
                        }
                        preconnectOutputBytes = 0
                    }
                    MoshConnectionState.FAILED -> {
                        if (finished.complete(MoshRunResult.COMPLETED)) {
                            emitSharedIfOpen {
                                emitFailure(
                                    intent.requestId,
                                    "mosh_connection_failed",
                                    mapOf("detail" to (connectivity.message ?: "native Mosh transport failed")),
                                )
                            }
                        }
                    }
                    MoshConnectionState.DISCONNECTED -> if (connectedEmitted) {
                        if (finished.complete(MoshRunResult.COMPLETED)) {
                            remoteSessionTerminated =
                                MoshSessionRecoveryPolicy.remoteProcessEndedOnTransportDisconnect()
                            emitSharedIfOpen { emitTransportDisconnected(intent.requestId) }
                        }
                    } else {
                        if (finished.complete(MoshRunResult.COMPLETED)) {
                            emitSharedIfOpen {
                                emitFailure(
                                    intent.requestId,
                                    "mosh_connection_ended_before_ready",
                                    mapOf("detail" to "Mosh ended before the terminal became ready"),
                                )
                            }
                        }
                    }
                    else -> Unit
                }
                updateMoshServerLiveness?.invoke()
            }
        }
        try {
            transport.connect(
                MoshConnectRequest(
                    bootstrap = MoshBootstrapRequest(
                        route = route,
                        udpHost = host.hostname,
                        // Stamp @tessera-visible-<id> naming this device's mosh
                        // PTY client, as iOS does. Without it the peer-presence
                        // proof can never identify our own visible client, so it
                        // abandons before the client census and mosh+tmux
                        // take-back never auto-reclaims after a peer leaves.
                        launchCommand = com.bambouville.tessera.data.HostLaunchSettings.moshCommand(host, target?.let {
                            SharedTmuxCommands.moshVisibleClientCommand(it, tmuxDeviceIdentity.id)
                        }),
                    ),
                    columns = moshAuthoritativeSize!!.columns,
                    rows = moshAuthoritativeSize!!.rows,
                ),
            )
            if (!cleanupRouteTransferred.get()) authenticatedCleanupRoute.close()
            attachForwardingIfNeeded(intent, hops)
        } catch (failure: CancellationException) {
            if (!cleanupRouteTransferred.get()) authenticatedCleanupRoute.close()
            throw failure
        } catch (failure: Throwable) {
            if (!cleanupRouteTransferred.get()) authenticatedCleanupRoute.close()
            if (finished.complete(MoshRunResult.COMPLETED)) {
                emitSharedIfOpen {
                    emitFailure(
                        intent.requestId,
                        "mosh_connection_failed",
                        mapOf("detail" to redactedFailure(failure)),
                    )
                }
            }
        }
        val jumpFallbackWatchdog = if (hops.size > 1) scope.launch {
            delay(MOSH_JUMP_FALLBACK_TIMEOUT_MS)
            if (currentIntent?.requestId == intent.requestId &&
                MoshSessionRecoveryPolicy.shouldFallBackFromJumpRoute(
                    hopCount = hops.size,
                    connected = connectedEmitted,
                    remoteServerPid = transport.bootstrapServerPid,
                )
            ) {
                diagnostics.record(
                    "mosh_jump_fallback_recommended",
                    mapOf("hops" to hops.size.toString(), "transport" to diagnosticTransport),
                )
                finished.complete(MoshRunResult.FALLBACK_TO_SSH)
            }
        } else null
        if (target != null) {
            moshSideChannelJob = scope.launch {
                runMoshTmuxControlLoop(intent, hops, transport)
            }
        }
        var result = finished.await()
        jumpFallbackWatchdog?.cancelAndJoin()
        if (result == MoshRunResult.FALLBACK_TO_SSH) {
            val serverPid = transport.bootstrapServerPid
            result = if (serverPid != null && terminateRemoteMoshServer(
                    intent,
                    route,
                    serverPid,
                    passwordProvider,
                    hostKeyPolicy,
                    keyAuthorization,
                    authenticatedRoute = pendingMoshServerCleanup.get()
                        ?.takeIf {
                            it.intent.requestId == intent.requestId && it.serverPid == serverPid
                        }
                        ?.authenticatedRoute,
                )
            ) {
                discardMoshServerCleanup(intent, serverPid)
                MoshRunResult.FALLBACK_TO_SSH
            } else {
                emitSharedIfOpen {
                    emitFailure(
                        intent.requestId,
                        "mosh_jump_fallback_cleanup_failed",
                        mapOf("detail" to "remote mosh-server cleanup could not be verified"),
                    )
                }
                MoshRunResult.COMPLETED
            }
        }
        detachForwarding()
        clearMoshAttemptTransport(preserveYieldedAuthority = !explicitDisconnect)
        if (result == MoshRunResult.FALLBACK_TO_SSH) {
            invalidateAgentEndpoint()
            routeOwner?.close()
            routeOwner = null
        }
        return result
    }

    private suspend fun clearMoshAttemptTransport(
        preserveYieldedAuthority: Boolean = false,
    ) {
        updateMoshServerLiveness = null
        moshServerLivenessWatcher?.stop("attempt-cleared")
        moshServerLivenessWatcher = null
        // Cancellation does not interrupt SSHJ's blocking InputStream.read.
        // Close the -CC channel first, then join the loop it unblocks.
        val sideChannel = moshSideChannelJob
        sideChannel?.cancel()
        clearTmuxTransport(preserveYieldedAuthority)
        sideChannel?.join()
        moshSideChannelJob = null
        moshConnectivityJob?.cancelAndJoin()
        moshConnectivityJob = null
        moshOutputJob?.cancelAndJoin()
        moshOutputJob = null
        recordMoshPumpStats("teardown")
        moshTransport?.close()
        moshTransport = null
        // Back to "this transport reports nothing". Leaving the last Mosh
        // reading behind would let a torn-down session answer a restore
        // verdict with a fact about a transport that no longer exists.
        mutableTransportReachable.value = null
        mutableMoshOutageTiming?.value = null
        moshAuthoritativeSize = null
        mutableMoshCanvasSize.value = null
        refreshTmuxWindowPaintScope()
    }

    /** A fresh direct/jump SSH command, with no password or host-trust challenges. */
    private suspend fun probeMoshServerLiveness(
        intent: SharedConnectionIntent,
        route: SshRouteRequest,
        transport: AndroidMoshTransport,
        pid: Int,
    ): MoshServerLivenessWatcher.ProbeResult {
        if (!moshServerLivenessProbeSlot.reserve()) {
            return MoshServerLivenessWatcher.ProbeResult(Outcome.HOST_UNREACHABLE)
        }
        val active = AtomicBoolean(true)
        val needsUser = AtomicBoolean(false)
        val ownerAuthorization = AtomicBoolean(false)
        val ownerAuthorizationPending = AtomicBoolean(false)
        val probeRoute = AtomicReference<SshRouteOwner?>()
        val routeAcquired = AtomicBoolean(false)
        val cleanupFinished = CompletableDeferred<Unit>()
        // Abandoning closes a route still being built: SSHJ waits for a silent
        // server's banner with no read timeout, beyond cancellation's reach.
        val construction = SshRouteConstruction()
        fun closeProbeRoute() {
            probeRoute.getAndSet(null)?.let { retired ->
                // SSHJ channel close can wait for the peer, especially on jump
                // routes. Cleanup must not block the watcher's deadline/main thread.
                scope.launch(Dispatchers.IO + NonCancellable) {
                    try { runCatching { retired.close() } }
                    finally { cleanupFinished.complete(Unit) }
                }
            }
        }
        fun requireCurrentProbe() {
            if (!active.get() || closed || currentIntent?.requestId != intent.requestId ||
                moshTransport !== transport
            ) throw CancellationException("Mosh liveness probe retired")
        }
        // SSHJ's IO calls can block past coroutine cancellation. Await an IO
        // task from the controller scope so the watcher still gets its 12 s
        // deadline; close the acquired route to unblock command reads, and
        // fence late connection callbacks before they can authorize a key.
        val command = scope.async(Dispatchers.IO) {
            try {
                requireCurrentProbe()
                val freshRoute = backend.openRoute(
                    request = route,
                    passwordProvider = SshPasswordProvider { hop ->
                        requireCurrentProbe()
                        attemptPasswords[hop.id]?.copyOf() ?: run {
                            needsUser.set(true)
                            throw CancellationException("Mosh liveness password unavailable")
                        }
                    },
                    hostKeyPolicy = SshHostKeyPolicy { observation ->
                        requireCurrentProbe()
                        val trusted = knownHosts.evaluate(
                            observation.host, observation.port, observation.algorithm, observation.canonicalKeyBlob,
                        ) == HostTrustEvaluation.Trusted
                        if (!trusted) needsUser.set(true)
                        trusted
                    },
                    keyAuthorizationProvider = SshKeyAuthorizationProvider { hop ->
                        try {
                            authorizeKey(intent, hop) {
                                requireCurrentProbe()
                                // Admission and emission share the main-thread
                                // boundary with foreground/attempt cancellation.
                                if (pendingOwnerAuthorization != null) {
                                    needsUser.set(true)
                                    throw CancellationException("Owner authorization already pending")
                                }
                                // The challenge launches only for the session on
                                // screen; anywhere else it would wait unseen.
                                if (!presentationActive || !appForeground) {
                                    moshLivenessDeferredForPresentation = true
                                    needsUser.set(true)
                                    throw CancellationException("Owner authorization needs the session on screen")
                                }
                                ownerAuthorization.set(true)
                                ownerAuthorizationPending.set(true)
                                moshLivenessOwnerPromptPending = true
                            }
                        } catch (cancelled: CancellationException) {
                            needsUser.set(true)
                            throw cancelled
                        } finally {
                            // Answered or not, the probe deadline runs again from here.
                            ownerAuthorizationPending.set(false)
                            withContext(NonCancellable + Dispatchers.Main.immediate) {
                                if (moshLivenessOwnerPromptPending) {
                                    moshLivenessOwnerPromptPending = false
                                    updateMoshServerLiveness?.invoke()
                                }
                            }
                            withContext(NonCancellable) { restoreConnectedUiAfterSideChannelChallenge() }
                        }
                    },
                    construction = construction,
                )
                routeAcquired.set(true)
                probeRoute.set(freshRoute)
                requireCurrentProbe()
                val output = freshRoute.executeBoundedCommand(MoshSessionRecoveryPolicy.serverLivenessCommand(pid))
                val outcome = when (MoshSessionRecoveryPolicy.serverLiveness(output.standardOutput)) {
                    SharedMoshServerLiveness.ALIVE -> Outcome.ALIVE
                    SharedMoshServerLiveness.GONE -> Outcome.GONE
                    SharedMoshServerLiveness.UNKNOWN -> Outcome.UNKNOWN
                }
                MoshServerLivenessWatcher.ProbeResult(outcome, ownerAuthorization.get())
            } catch (cancelled: CancellationException) {
                currentCoroutineContext().ensureActive()
                MoshServerLivenessWatcher.ProbeResult(Outcome.UNKNOWN, ownerAuthorization.get())
            } catch (_: Exception) {
                MoshServerLivenessWatcher.ProbeResult(
                    if (needsUser.get()) Outcome.UNKNOWN else Outcome.HOST_UNREACHABLE,
                    ownerAuthorization.get(),
                )
            } finally {
                closeProbeRoute()
            }
        }
        moshServerLivenessProbeSlot.releaseAfter(command) {
            cleanupFinished.takeIf { routeAcquired.get() }
        }
        return try {
            awaitProbeDeadline(command, budgetMillis = 12_000, ownerPrompting = ownerAuthorizationPending::get)
                ?: MoshServerLivenessWatcher.ProbeResult.timedOut(
                    ownerAuthorization.get(), ownerAuthorizationPending.get(),
                )
        } finally {
            active.set(false)
            command.cancel()
            if (!command.isCompleted) {
                scope.launch(Dispatchers.IO + NonCancellable) { construction.abandon() }
            }
            closeProbeRoute()
        }
    }

    private suspend fun runMoshTmuxControlLoop(
        intent: SharedConnectionIntent,
        hops: List<SshRouteHop>,
        transport: AndroidMoshTransport,
    ) {
        var retry = 0
        while (currentIntent?.requestId == intent.requestId && moshTransport === transport) {
            var attemptRoute: SshRouteOwner? = null
            try {
                // The visible Mosh transport is independent of this SSH
                // route. A forced control-channel drop can kill the route's
                // sshd worker, not merely its tmux child, so every retry must
                // authenticate a fresh route instead of calling openTmux on
                // an owner already known to be dead.
                attemptRoute = backend.openRoute(
                    request = SshRouteRequest(hops),
                    passwordProvider = SshPasswordProvider { hop ->
                        try { requestPassword(intent, hop) }
                        finally { restoreConnectedUiAfterSideChannelChallenge() }
                    },
                    hostKeyPolicy = SshHostKeyPolicy { observation ->
                        try { verifyHostKey(intent, observation) }
                        finally { restoreConnectedUiAfterSideChannelChallenge() }
                    },
                    keyAuthorizationProvider = SshKeyAuthorizationProvider { hop ->
                        try { authorizeKey(intent, hop) }
                        finally { restoreConnectedUiAfterSideChannelChallenge() }
                    },
                )
                if (currentIntent?.requestId != intent.requestId || moshTransport !== transport) return
                routeOwner = attemptRoute
                runTmuxTransport(
                    intent,
                    hops,
                    emitTransportLifecycle = false,
                    sideChannelRoute = attemptRoute,
                )
                diagnostics.record(
                    "mosh_tmux_control_closed",
                    mapOf("retry" to retry.toString(), "transport" to diagnosticTransport),
                )
            } catch (failure: Throwable) {
                if (failure is CancellationException) throw failure
                diagnostics.record(
                    "mosh_tmux_control_retry",
                    mapOf(
                        "retry" to retry.toString(),
                        "detail" to redactedFailure(failure),
                        "transport" to diagnosticTransport,
                    ),
                )
            } finally {
                invalidateAgentEndpoint()
                clearTmuxTransport(
                    preserveYieldedAuthority = true,
                    retainSideChannelRuntime = true,
                )
                if (routeOwner === attemptRoute) routeOwner = null
                attemptRoute?.close()
            }
            retry += 1
            delay(MoshSessionRecoveryPolicy.sideChannelRetryDelayMillis(retry))
        }
    }

    private fun rememberMoshServerCleanup(
        intent: SharedConnectionIntent,
        route: SshRouteRequest,
        serverPid: Int?,
        authenticatedRoute: SshRouteOwner? = null,
    ): Boolean {
        val pid = serverPid?.takeIf { it > 0 } ?: return false
        val current = pendingMoshServerCleanup.get()
        if (current?.intent?.requestId == intent.requestId && current.serverPid == pid) return true
        val retainedPasswords = attemptPasswords.entries.associate { (hopID, password) ->
            hopID to password.copyOf()
        }
        pendingMoshServerCleanup.getAndSet(
            PendingMoshServerCleanup(
                intent = intent,
                route = route,
                serverPid = pid,
                passwords = retainedPasswords,
                authenticatedRoute = authenticatedRoute,
            ),
        )?.wipe()
        return true
    }

    private fun takeMoshServerCleanup(intent: SharedConnectionIntent): PendingMoshServerCleanup? {
        while (true) {
            val current = pendingMoshServerCleanup.get() ?: return null
            if (current.intent.requestId != intent.requestId) return null
            if (pendingMoshServerCleanup.compareAndSet(current, null)) return current
        }
    }

    private fun discardMoshServerCleanup(intent: SharedConnectionIntent, serverPid: Int) {
        while (true) {
            val current = pendingMoshServerCleanup.get() ?: return
            if (current.intent.requestId != intent.requestId || current.serverPid != serverPid) return
            if (pendingMoshServerCleanup.compareAndSet(current, null)) {
                current.wipe()
                return
            }
        }
    }

    private suspend fun finishMoshServerCleanup(
        intent: SharedConnectionIntent,
        terminate: Boolean,
    ) {
        val cleanup = takeMoshServerCleanup(intent) ?: return
        try {
            if (!terminate) return
            val terminated = runCatching {
                withTimeout(MOSH_EXPLICIT_CLEANUP_TIMEOUT_MS) {
                    withContext(Dispatchers.IO) {
                        terminateRemoteMoshServer(
                            intent = cleanup.intent,
                            route = cleanup.route,
                            serverPid = cleanup.serverPid,
                            passwordProvider = SshPasswordProvider(cleanup::passwordFor),
                            hostKeyPolicy = SshHostKeyPolicy { observation ->
                                knownHosts.evaluate(
                                    observation.host,
                                    observation.port,
                                    observation.algorithm,
                                    observation.canonicalKeyBlob,
                                ) == HostTrustEvaluation.Trusted
                            },
                            // The retained bootstrap route is tried first, so
                            // owner-authorized keys need no second prompt. The
                            // no-op provider applies only to the password/
                            // non-owner-auth fallback route.
                            keyAuthorizationProvider = SshKeyAuthorizationProvider { },
                            authenticatedRoute = cleanup.authenticatedRoute,
                            requireCurrentIntent = false,
                            failureDiagnosticCode = "mosh_explicit_cleanup_failed",
                        )
                    }
                }
            }.getOrElse { failure ->
                diagnostics.record(
                    "mosh_explicit_cleanup_failed",
                    mapOf(
                        "detail" to redactedFailure(failure),
                        "transport" to diagnosticTransport,
                    ),
                )
                false
            }
            diagnostics.record(
                if (terminated) "mosh_explicit_cleanup_succeeded" else "mosh_explicit_cleanup_failed",
                mapOf(
                    "detail" to "pid=${cleanup.serverPid}",
                    "transport" to diagnosticTransport,
                ),
            )
        } finally {
            cleanup.wipe()
        }
    }

    private suspend fun terminateRemoteMoshServer(
        intent: SharedConnectionIntent,
        route: SshRouteRequest,
        serverPid: Int,
        passwordProvider: SshPasswordProvider,
        hostKeyPolicy: SshHostKeyPolicy,
        keyAuthorizationProvider: SshKeyAuthorizationProvider,
        authenticatedRoute: SshRouteOwner? = null,
        requireCurrentIntent: Boolean = true,
        failureDiagnosticCode: String = "mosh_jump_fallback_cleanup_failed",
    ): Boolean {
        if (serverPid <= 0 || (requireCurrentIntent && currentIntent?.requestId != intent.requestId)) return false
        return runCatching {
            val command = MoshSessionRecoveryPolicy.remoteServerTerminationCommand(serverPid)
            val authenticatedTranscript = authenticatedRoute?.let { retainedRoute ->
                runCatching { retainedRoute.executeBoundedCommand(command) }.getOrNull()
            }
            val transcript = authenticatedTranscript ?: backend.executeRouteCommand(
                request = route,
                commandText = command,
                passwordProvider = passwordProvider,
                hostKeyPolicy = hostKeyPolicy,
                keyAuthorizationProvider = keyAuthorizationProvider,
            )
            transcript.exitStatus == 0
        }.onFailure { failure ->
            diagnostics.record(
                failureDiagnosticCode,
                mapOf("detail" to redactedFailure(failure), "transport" to diagnosticTransport),
            )
        }.getOrDefault(false)
    }

    /** @return how many control-mode bytes the remote produced before it ended. */
    private suspend fun readTmuxStream(
        input: InputStream,
        intent: SharedConnectionIntent,
        runtime: SharedTmuxRuntime,
        tmux: SshTmuxConnection,
        transportGeneration: Long,
    ): Long {
        val buffer = ByteArray(32 * 1024)
        val authorityWireFeed = TmuxAuthorityWireFeed { bytes -> runtime.feed(bytes, authorityNow()) }
        var total = 0L
        var loggedPrefix = false
        // See TmuxWireTrace.kt: the first lines of every attachment, escaped
        // and with pane content withheld, so a reply the ledger cannot parse
        // can be read as bytes rather than as its own failure summary.
        var wireTraceBudget = TMUX_WIRE_TRACE_LINES
        var wireChunk = 0
        while (currentIntent?.requestId == intent.requestId) {
            val count = input.read(buffer)
            if (count < 0) break
            if (count > 0) {
                var rejectedResult: CoreCallResult? = null
                val accepted = synchronized(tmuxTransportLock) {
                    if (closed || transportGeneration != tmuxTransportGeneration ||
                        tmuxConnection !== tmux || tmuxCore !== runtime
                    ) return@synchronized false
                    if (!tmuxControlEngaged) {
                        val text = String(buffer, 0, count, Charsets.UTF_8)
                        noteTmuxLaunchOutput(text)
                        // tmux -CC announces itself with the DCS 1000p; %begin is
                        // the first thing every control frame carries. Either one
                        // means the launch succeeded and nothing downstream may
                        // treat a later exit as a failed launch.
                        if (text.contains("\u001bP1000p") || text.contains("%begin")) {
                            tmuxControlEngaged = true
                        }
                    }
                    if (!loggedPrefix) {
                        loggedPrefix = true
                        // A cold-start tmux that never emits the DCS looks
                        // identical to a healthy one until you can see whether the
                        // first bytes were control mode or an error message.
                        diagnostics.record(
                            "tmux_control_first_bytes",
                            mapOf("detail" to tmuxWireSnippet(String(buffer, 0, count, Charsets.UTF_8), 200)),
                        )
                    }
                    if (wireTraceBudget > 0) {
                        wireChunk += 1
                        var index = 0
                        for (line in String(buffer, 0, count, Charsets.UTF_8).lineSequence()) {
                            if (wireTraceBudget <= 0) break
                            val recorded = tmuxWireTraceLine(line) ?: continue
                            wireTraceBudget -= 1
                            index += 1
                            diagnostics.record(
                                "tmux_control_wire",
                                mapOf(
                                    "n" to "$wireChunk.$index",
                                    "detail" to recorded,
                                    "transport" to diagnosticTransport,
                                ),
                            )
                        }
                    }
                    val result = authorityWireFeed.feed(buffer, count, liveAuthorityClaim()?.inGeometryPhase == true)
                    if (result != CoreCallResult.Accepted) rejectedResult = result
                    result == CoreCallResult.Accepted
                }
                if (!accepted) {
                    // A rejected core feed cannot be retried against the same
                    // byte stream: preserving the channel would desynchronise
                    // the control parser and its reply FIFO. Stop this exact
                    // channel; the normal mosh side-channel loop may recover.
                    rejectedResult?.let { result ->
                        diagnostics.record(
                            "tmux_render_feed_rejected",
                            mapOf(
                                "detail" to result.name,
                                "transport" to diagnosticTransport,
                            ),
                        )
                        tmux.close()
                    }
                    break
                }
                total += count
            }
        }
        return total
    }

    /// Bounded: only the launch window matters, and the remote controls this
    /// text. The diagnostics store sanitizes whatever is recorded from it.
    private fun noteTmuxLaunchOutput(text: String) {
        synchronized(tmuxLaunchOutput) {
            if (tmuxLaunchOutput.length < MAX_TMUX_LAUNCH_OUTPUT_CHARS) tmuxLaunchOutput.append(text)
        }
    }

    private fun currentTmuxLaunchOutput(): String =
        synchronized(tmuxLaunchOutput) { tmuxLaunchOutput.toString() }

    private fun degradeNotice(failure: SharedTmuxLaunchFailure): String = when (failure) {
        SharedTmuxLaunchFailure.UNAVAILABLE ->
            "tmux isn't on this host's PATH — opened a plain shell instead."
        SharedTmuxLaunchFailure.NESTED ->
            "This host is already inside tmux — opened a plain shell instead."
        SharedTmuxLaunchFailure.START_FAILED ->
            "tmux couldn't start a session — opened a plain shell instead."
    }

    /// The subset of the connection job's `finally` that has to run before a
    /// second transport opens on the same intent. Order matters: forwarding was
    /// attached to the tmux route, so it must detach before that route closes.
    private suspend fun releaseTmuxRouteForDegrade() {
        detachForwarding()
        errorReaderJob?.cancelAndJoin()
        errorReaderJob = null
        clearTmuxTransport()
        routeOwner?.close()
        routeOwner = null
    }

    private fun requestCompactSizeRole() {
        compactSizeRoleQueryAttempts += 1
        sendTmuxControl("display-message -p '#{client_flags}'", TmuxResponsePurpose.ClientFlags)
    }

    private fun scheduleCompactSizeRoleRetry() {
        if (compactSizeRoleQueryAttempts >= 3 || tmuxConnection == null) return
        val connection = tmuxConnection
        scope.launch {
            delay(150L * compactSizeRoleQueryAttempts)
            if (tmuxConnection === connection && compactSizeRole == CompactSizeRole.Unresolved) {
                requestCompactSizeRole()
            }
        }
    }

    private fun reconcileTmuxViewportAfterAttach(geometry: com.bambouville.tessera.terminal.TerminalSurfaceState?) {
        // A compact native terminal is measured at the projected canvas. Only
        // use it as the initial fallback; the outer viewport owns later reports.
        if (lastTmuxViewport == null && geometry != null && geometry.columns >= 4 && geometry.rows >= 4) {
            lastTmuxViewport = SharedTmuxGridSize(geometry.columns, geometry.rows)
        }
        reconcileTmuxClientSize()
    }

    private fun reconcileTmuxClientSize(
        snapshot: SharedTmuxSnapshot? = mutableTmuxSnapshot.value,
        forceAllWindows: Boolean = false,
    ) {
        synchronized(tmuxTransportLock) { submitAuthorityGeometryFacts(snapshot) }
        val viewport = lastTmuxViewport ?: return
        if (tmuxGridPresentation == SharedTmuxGridPresentation.PANE_GRID) {
            publishTmuxClientSize(viewport, forceAllWindows = forceAllWindows)
            return
        }
        if (snapshot == null) return
        val window = snapshot.activeWindow ?: return
        val layout = window.layout
        val focus = layout?.findPane(window.activePaneId ?: snapshot.activePaneId)
        val windowSize = layout?.gridSize()
        val focusSize = focus?.let { SharedTmuxGridSize(it.width, it.height) }

        // Only a resolved Observer adopts the server grid; Unresolved sizes
        // like an owner. Tessera attaches its control client without
        // `ignore-size`, so ownership is the truth until tmux says otherwise,
        // and a server that never answers `#{client_flags}` must not leave the
        // compact grid unpublished — that is the phone rendering an inherited
        // canvas scaled to nothing. A client that really is ignored cannot
        // resize the server with `refresh-client -C` anyway, so the optimistic
        // publish is inert in the case it gets wrong.
        //
        // An Observer has ceded the grid — it is `ignore-size`, so it is
        // rendering a peer's canvas. Give its control canvas the complete
        // server grid, but never clear ignore-size: doing so would make this
        // device resize every peer's panes behind their back. Taking control
        // back is the explicit reclaim gesture, not a side effect of sizing.
        if (compactSizeRole == CompactSizeRole.Observer) {
            windowSize?.let { publishTmuxClientSize(it, forceAllWindows = forceAllWindows) }
            return
        }
        // One judgement per set of inputs: an event that changed nothing the
        // decision reads (a withheld advertisement leaves
        // `lastPublishedTmuxSize` as it was) gets the same answer back
        // without the core counting it again.
        val judgement = compactTmuxSizer.judge(
            viewport = viewport,
            lastClientSize = lastPublishedTmuxSize,
            layout = layout,
            focusPaneId = focus?.paneId,
            window = windowSize,
            focus = focusSize,
        )
        val projected = judgement.clientSize
        when (judgement.decision) {
            SharedTmuxCompactReprojection.REPROJECT ->
                publishTmuxClientSize(projected, forceAllWindows = forceAllWindows)
            // A settled projection can still drift. Passive recovery first
            // proves fresh own authority and that both clients on this
            // physical window are ours, so it cannot undo a peer's
            // not-yet-stamped claim.
            SharedTmuxCompactReprojection.HOLD ->
                forceTmuxWindowSizes(projected, onlyWindowId = if (forceAllWindows) null else window.id)
            // tmux kept missing the projection on our own canvas. Repairing
            // toward it through `resize-window` would only continue the
            // storm on another route, so keep the size already advertised.
            SharedTmuxCompactReprojection.HOLD_CYCLE -> {
                if (judgement.stoppedCycle) {
                    diagnostics.record(
                        "tmux_compact_resize_cycle_held",
                        mapOf(
                            "detail" to "@${window.id} held=${lastPublishedTmuxSize?.let { "${it.columns}x${it.rows}" }} " +
                                "projected=${projected.columns}x${projected.rows} " +
                                "layout=${windowSize?.let { "${it.columns}x${it.rows}" }} " +
                                "focus=${focusSize?.let { "${it.columns}x${it.rows}" }}",
                            "transport" to diagnosticTransport,
                        ),
                    )
                }
                lastPublishedTmuxSize?.let {
                    forceTmuxWindowSizes(it, onlyWindowId = if (forceAllWindows) null else window.id)
                }
            }
        }
    }

    /**
     * Start this tmux client's compact corrections over, as iOS does on
     * every forced replay (activation, foreground, refresh): a new client, the
     * app returning, a show, a take-back or a presentation change is not a
     * layout update, so it cannot feed a resize cycle, and a cycle held
     * before it gets a fresh attempt. The next reconcile asks the core again
     * even if no input changed.
     */
    private fun restartCompactTmuxSizing() {
        compactTmuxSizer.reset()
    }

    /**
     * Put the real mounted-client geometry on the shared FIFO immediately
     * before `new-window`. Under `latest`, tmux sizes the window `new-window`
     * creates from the issuing client's grid (`default_window_size`), so the
     * resize coalescer's previous publication could create one at a stale
     * keyboard/rotation size. A grid this connection's client already has
     * is not sent again (P6): the new window takes it all the same, and the
     * ledger sends only the inline fence ([sendTmuxClientSize]).
     */
    private fun replayTmuxClientGeometryBeforeWindowCreation(snapshot: SharedTmuxSnapshot?) {
        val viewport = lastTmuxViewport ?: return
        if (lastTmuxAuthorityResult?.geometryHold != SharedTmuxAuthorityGeometryHold.OWNER) return
        val size = if (tmuxGridPresentation == SharedTmuxGridPresentation.PANE_GRID) {
            viewport
        } else {
            compactProjectedClientSize(snapshot, viewport)
        }
        sendTmuxClientSize(size, belongsToAuthorityClaim = false)
    }

    /**
     * Hands [size] to the ledger as this connection's client grid. The
     * ledger owns the exact replay, as on iOS: the `-C` unless this
     * connection already advertised that grid (P6, W10), and on the inline
     * path the `latest` fence unless the replay belongs to a claim
     * ([tmuxRenderLedgerOptions]). False when the ledger refused it.
     */
    private fun sendTmuxClientSize(
        size: SharedTmuxGridSize,
        belongsToAuthorityClaim: Boolean,
    ): Boolean = synchronized(tmuxTransportLock) {
        if (size.columns < 4 || size.rows < 4) return@synchronized false
        // Judged again under the lock: the callers' check runs outside it, so
        // a transport attach (whose hold the attached ledger relies on) or a
        // peer verdict can land between that check and this send. A size
        // that slipped through would reach the freshly attached ledger as a
        // bare `-C` ahead of the attach read and resize a peer's window; it
        // is withheld instead, and the read's reconcile publishes it once.
        tmuxClientSizeWithheldReason(belongsToAuthorityClaim)?.let { reason ->
            noteWithheldTmuxClientSize(size, reason)
            return@synchronized false
        }
        if (tmuxCore == null && tmuxRenderFactProbe == null) return@synchronized false
        // A fact can synchronously echo its geometry, and IO can enter as
        // soon as this lock is released. Record the target and retire its old
        // repaint before either can classify that echo as a foreign loss.
        val previousSize = lastPublishedTmuxSize
        val admittedGeneration = liveAuthorityClaim()?.generation
        noteDeliveredTmuxClientSize(size)
        // JNI fires due deadlines before the report; its newer gate is final.
        val withholding = tmuxClientSizeWithheldReason(belongsToAuthorityClaim)
        if (withholding != null || liveAuthorityClaim()?.generation != admittedGeneration) {
            if (lastPublishedTmuxSize == size &&
                (liveAuthorityClaim() == null || liveAuthorityClaim()?.generation == admittedGeneration)
            ) lastPublishedTmuxSize = previousSize
            noteWithheldTmuxClientSize(size, withholding ?: "claim replaced before client size write")
            return@synchronized false
        }
        val churnGeneration = liveAuthorityClaim()?.takeIf {
            !belongsToAuthorityClaim && it.phase == SharedTmuxAuthorityClaimPhase.AWAITING_FENCE
        }?.generation
        applyTmuxRenderLedgerOptions(tmuxRenderLedgerOptions(belongsToAuthorityClaim))
        if (!submitTmuxRenderFact(SharedTmuxRenderFact.ClientSize(size.columns, size.rows))) {
            lastPublishedTmuxSize = previousSize
            liveAuthorityClaim()?.let { abortTmuxGridAuthorityClaim(it.generation, "client size fact refused") }
            return@synchronized false
        }
        // The churn's fence must follow its -C, in the same critical section:
        // a fence sent before this geometry cannot confirm it.
        if (churnGeneration != null && liveAuthorityClaim()?.generation == churnGeneration && !usesMoshPrimaryTransport()) {
            sendTmuxGridAuthorityFence(churnGeneration, "churn")
        }
        true
    }

    /**
     * The render-ledger switches this adapter runs with, iOS' set
     * (`updateRenderLedgerConfiguration`): every `-C` goes through the
     * ledger's client-size replay, so it may drop one the connection already
     * has (P6), and a take-back's visible capture rides with its metadata
     * (P8). The inline replay belongs to a claim, and so carries no `latest`
     * fence, while a claim is in flight (its own fence follows) and for a
     * session whose read found no stamp: that sizes with a bare refresh and
     * never takes `latest` outside a claim (M3). The side channel never
     * fences. Caller holds [tmuxTransportLock].
     */
    private fun tmuxRenderLedgerOptions(belongsToAuthorityClaim: Boolean): Int {
        val claimPending = belongsToAuthorityClaim || pendingAuthorityRepaintGeneration != null
        val unstamped = tmuxAuthorityParticipates() && lastTmuxAuthorityResult?.claim == null &&
            mutableTmuxAuthority.value == SharedTmuxGridAuthoritySnapshot.Unknown
        var options = SharedTmuxRenderLedgerOptions.SUPPRESSES_UNCHANGED_CLIENT_SIZE_REPLAY or
            SharedTmuxRenderLedgerOptions.PIPELINES_VISIBLE_CAPTURE
        if (claimPending || unstamped) {
            options = options or SharedTmuxRenderLedgerOptions.INLINE_CLIENT_SIZE_REPLAY_BELONGS_TO_CLAIM
        }
        return options
    }

    /**
     * Gives the runtime [options] unless it already has them. A refusal is
     * logged once and not retried on that runtime: the core refuses only a
     * bit it does not define, which no later call would fix, and the ledger
     * then keeps its defaults (every `-C` sent, inline ones fenced). Caller
     * holds [tmuxTransportLock].
     */
    private fun applyTmuxRenderLedgerOptions(options: Int) {
        if (appliedTmuxRenderLedgerOptions == options || tmuxRenderLedgerOptionsRefused) return
        val accepted = tmuxRenderLedgerOptionsProbe?.invoke(options)
            ?: when (tmuxCore?.setRenderLedgerOptions(options) ?: return) {
                CoreCallResult.Accepted -> true
                // A closed handle; its replacement gets the switches when it is published.
                CoreCallResult.StaleHandle -> return
                CoreCallResult.InvalidArguments -> false
            }
        if (accepted) {
            appliedTmuxRenderLedgerOptions = options
            return
        }
        tmuxRenderLedgerOptionsRefused = true
        diagnostics.record(
            "tmux_render_ledger_options_refused",
            mapOf("detail" to "options=$options", "transport" to diagnosticTransport),
        )
    }

    /** Report admission before the ledger can synchronously echo the size. */
    private fun noteDeliveredTmuxClientSize(size: SharedTmuxGridSize) {
        lastPublishedTmuxSize = size
        lastDeliveredTmuxClientSizeAtMillis = authorityNow()
        if (liveAuthorityClaim() != null) noteAuthorityClaimAdvertised(size)
        else reduceTmuxAuthority { session, now -> session.sizeAdvertised(now, size) }
    }

    /**
     * This device's compact canvas for [viewport]: the focused pane keeps the
     * physical grid while the advertised client grows by that pane's share of
     * the saved tmux layout. Degrades to the raw viewport before hydration,
     * which is what a pre-snapshot authority claim needs.
     */
    private fun compactProjectedClientSize(
        snapshot: SharedTmuxSnapshot?,
        viewport: SharedTmuxGridSize,
    ): SharedTmuxGridSize {
        val window = snapshot?.activeWindow
        val layout = window?.layout
        val focus = layout?.findPane(window.activePaneId ?: snapshot.activePaneId)
        return compactTmuxSizer.clientSize(
            viewport = viewport,
            layout = layout,
            focusPaneId = focus?.paneId,
            window = layout?.gridSize(),
            focus = focus?.let { SharedTmuxGridSize(it.width, it.height) },
        )
    }

    /**
     * True while a peer owns the tmux grid and no reclaim is in flight. Local
     * churn — the software keyboard, rotation, a layout event the peer itself
     * caused — must never resize the session behind the peer's back; only the
     * explicit take-back replays a size. iOS' `replayClientSize` guard.
     */
    private fun yieldedToPeer(): Boolean =
        mutableTmuxAuthority.value is SharedTmuxGridAuthoritySnapshot.Peer &&
            pendingAuthorityRepaintGeneration == null

    /**
     * Transport the shared runtime's fixed topology queries.
     *
     * tmux announces a created window with `%session-window-changed` followed
     * by `%window-add` and then goes silent: no `%layout-change` ever fires for
     * creation, so the window enters topology with no panes and no layout and
     * nothing in the notification stream ever fills them in. The core decides
     * which window needs describing and owns both the query grammar and the
     * tagged reply parser; this only puts the string on the wire. `Ignore`
     * is the right purpose precisely because the reply is not ours to read.
     */
    private fun sendTmuxTopologyQueries(queries: List<String>) {
        if (queries.isEmpty()) return
        for (query in queries) {
            sendTmuxControl(query, TmuxResponsePurpose.Ignore)
        }
    }

    /**
     * Keep the stamp-less layout fallback aligned with the rendered window's
     * effective `window-size`. Only `latest` ties the window to a client at
     * all; under `manual` or a fixed size a mismatch proves nothing. Unknown
     * policy disables the fallback until this targeted query answers, which is
     * the safe direction. iOS' `probeSteadyGridAuthorityWindowSizePolicy`.
     */
    private fun probeWindowSizePolicy(windowId: Int) {
        if (pendingAuthorityRepaintGeneration != null) return
        // Probe on window change, not on every snapshot: a server that refuses
        // the query would otherwise be asked again for each event, and leaving
        // the policy unknown already disables the fallback, which is the safe
        // direction. A reconnect clears the latch and re-probes.
        if (windowSizePolicyWindowId == windowId) return
        windowSizePolicyKnown = false
        windowSizePolicyWindowId = windowId
        // Only a delivered command justifies the latch: a probe that no channel
        // accepted would otherwise leave the policy unknown for the rest of the
        // connection, silently retiring the fallback.
        if (!sendTmuxControl(
                "show-options -wA -v -t @$windowId window-size",
                TmuxResponsePurpose.WindowSizePolicy(windowId),
            )
        ) {
            windowSizePolicyWindowId = null
        }
    }

    /**
     * One line per change of the rendered window's grid, next to what this
     * device asked for. A phone showing a window scaled down to a peer's or
     * a stale geometry is otherwise invisible in the log.
     */
    private fun noteTmuxLayoutForDiagnostics(snapshot: SharedTmuxSnapshot?) {
        val window = snapshot?.activeWindow ?: return
        val size = window.layout?.gridSize() ?: return
        val observed = window.id to size
        if (lastDiagnosedTmuxLayout == observed) return
        lastDiagnosedTmuxLayout = observed
        diagnostics.record(
            "tmux_layout",
            mapOf(
                "detail" to buildString {
                    append("@${window.id} ${size.columns}x${size.rows}")
                    append(" viewport=")
                    append(lastTmuxViewport?.let { "${it.columns}x${it.rows}" } ?: "none")
                    append(" published=")
                    append(lastPublishedTmuxSize?.let { "${it.columns}x${it.rows}" } ?: "none")
                },
                "transport" to diagnosticTransport,
            ),
        )
    }

    private fun reconcileLocalMoshCanvas(size: SharedTmuxGridSize) {
        if (closed || size.columns < 4 || size.rows < 4) return
        // The mosh PTY is this device's own canvas, not the session's: the
        // visible mosh client is `ignore-size` and cannot resize tmux, so the
        // emulator tracks the device even while yielded and even while the -CC
        // side channel is between retries. iOS keeps the same split — only the
        // tmux client replay is withheld from a yielded device.
        //
        // Conflated + single consumer, so two publishes in quick succession
        // (rotation then keyboard) can never land on the PTY inverted and
        // strand it at the older grid.
        if (usesMoshPrimaryTransport()) {
            moshTransport?.let {
                mutableMoshCanvasSize.value = size
                moshResizeRequests.trySend(MoshResizeRequest(it, size))
            }
        }
    }

    private fun publishTmuxClientSize(
        size: SharedTmuxGridSize,
        belongsToAuthorityClaim: Boolean = false,
        forceAllWindows: Boolean = false,
        ordinaryProofToken: Long? = null,
    ) {
        if (size.columns < 4 || size.rows < 4) return
        reconcileLocalMoshCanvas(size)
        if (!belongsToAuthorityClaim && liveAuthorityClaim() == null &&
            lastTmuxAuthorityResult?.geometryHold == SharedTmuxAuthorityGeometryHold.ADVERTISE_ONLY
        ) {
            synchronized(tmuxTransportLock) { advertiseTmuxGeometryOnly(size) }
            return
        }
        tmuxClientSizeWithheldReason(belongsToAuthorityClaim)?.let { reason ->
            noteWithheldTmuxClientSize(size, reason)
            return
        }
        if (usesMoshPrimaryTransport() && liveAuthorityClaim() == null && !belongsToAuthorityClaim && !forceAllWindows) {
            val window = mutableTmuxSnapshot.value?.activeWindow ?: return
            if (!presentationActive || !windowSizePolicyKnown || windowSizePolicyWindowId != window.id) return
            // Under any other policy tmux sizes the window by its own rule:
            // only a new local grid is published, and no window is forced.
            if (!windowSizePolicyIsLatest && ordinaryProofToken == null && lastPublishedTmuxSize == size) return
            if (ordinaryProofToken == null) {
                if (lastPublishedTmuxSize == size && pendingTmuxWindowSizeReplayInFlight(window.id)?.requested == size) return
                if (lastPublishedTmuxSize != size || window.layout?.gridSize() != size) {
                    requestOrdinaryTmuxWindowRecovery(window.id, size, window.layout?.gridSize())
                }
                return
            }
            if (currentOrdinaryTmuxWindowRecovery(ordinaryProofToken)?.let {
                    it.completed && it.windowId == window.id && it.requested == size
                } != true
            ) return
        }
        lastWithheldTmuxClientSize = null
        // Even when the ledger already has the client grid (P6), the claim
        // must record its target: the fence/force still advertises that grid.
        if (belongsToAuthorityClaim && liveAuthorityClaim()?.targetGrid == null) {
            noteAuthorityClaimAdvertised(size)
        }
        val publishesNewSize = lastPublishedTmuxSize != size
        if (publishesNewSize) {
            synchronized(tmuxTransportLock) { discardObsoleteTmuxWindowSizeReplays() }
            if (ordinaryProofToken == null) {
                ordinaryTmuxWindowRecovery = null
                submitAuthorityOrdinaryRecovery()
            }
            // RenderLedger owns the exact replay sequence and places it in
            // the same FIFO as captures and platform-originated commands. A
            // claim (which clears the memo above) re-sends only a grid this
            // connection's client does not have yet (P6): its own fence or
            // window forces apply the grid either way. A `-C` the ledger
            // does send while a claim runs is that claim's wire work
            // ([enqueueLedgerRenderCommands]).
            val delivered = sendTmuxClientSize(size, belongsToAuthorityClaim)
            diagnostics.record(
                "tmux_client_size",
                mapOf(
                    "detail" to "${size.columns}x${size.rows} delivered=$delivered ledger=true",
                    "transport" to diagnosticTransport,
                ),
            )
            if (!delivered) return
        }
        // After the refresh, never before it: `set-option -w -u window-size`
        // triggers tmux's recalculation, and running that while the server
        // still knows the old client size snaps the window back for a round
        // trip. Idempotent and self-limiting, so re-asserting on every
        // reconcile costs nothing once the window agrees.
        if (belongsToAuthorityClaim || forceAllWindows || liveAuthorityClaim() != null) {
            // While a claim runs, a foreign layout alone is not permission
            // to force it back: its settle probe decides whether it landed
            // and the core grants the one loss re-fence. Only local churn,
            // hydration or the claim's explicit begin advertises here (M1).
            if (belongsToAuthorityClaim || forceAllWindows || publishesNewSize) {
                forceTmuxWindowSizes(size, belongsToAuthorityClaim || liveAuthorityClaim() != null)
            }
            // Visible churn re-targeted the claim and dropped its fence (the
            // core's `claimAdvertisedGeometry`); its own fence follows the
            // forces just queued.
            if (!belongsToAuthorityClaim && publishesNewSize && usesMoshPrimaryTransport()) {
                liveAuthorityClaim()?.let { sendTmuxGridAuthorityFence(it.generation, "churn") }
            }
        } else {
            mutableTmuxSnapshot.value?.activeWindow?.id?.let {
                forceTmuxWindowSizes(size, onlyWindowId = it, ordinaryProofToken = ordinaryProofToken)
            }
        }
    }

    /**
     * Ordinary (non-claim) geometry waits for a fresh authority read on both
     * transports, is never pushed from the background, and never from a tab
     * the show rule hid: its next show's read decides (R5/D5). Visibility
     * gates only these pushes and repaints, never the authority reply itself
     * (D4).
     */
    private fun ordinaryTmuxGeometryWithheld(): Boolean =
        lastTmuxAuthorityResult?.geometryHold != SharedTmuxAuthorityGeometryHold.OWNER &&
            lastTmuxAuthorityResult?.geometryHold != SharedTmuxAuthorityGeometryHold.ADVERTISE_ONLY

    private fun tmuxClientSizeWithheldReason(belongsToAuthorityClaim: Boolean): String? = when {
        authorityClaimLate() -> LATE_CLAIM_WITHHOLDING
        belongsToAuthorityClaim && lastTmuxAuthorityResult?.claimMayAdvertiseGeometry == true -> null
        ordinaryTmuxGeometryWithheld() -> "shared session withholds geometry"
        else -> null
    }

    private fun noteWithheldTmuxClientSize(size: SharedTmuxGridSize, reason: String) {
        val withheld = size to reason
        if (lastWithheldTmuxClientSize == withheld) return
        lastWithheldTmuxClientSize = withheld
        diagnostics.record(
            "tmux_client_size_withheld",
            mapOf("detail" to "${size.columns}x${size.rows} $reason", "transport" to diagnosticTransport),
        )
    }

    /**
     * A Mosh visible client takes `latest` on every keystroke despite
     * `ignore-size`; the recalculation then finds no usable candidate and the
     * window FREEZES at whatever size it last applied, leaving the pane a
     * top-left crop. A plain laptop can hold `latest` too. Advertise our
     * control client's grid first, then use the shared resize/fence/unset
     * sequence. Its targetless `select-window` makes this side channel latest
     * in its own session before unset recalculates, so the window does not
     * snap back to the plain client (D2); a bare @W can reach a grouped
     * sibling (W2). The unset keeps a plain laptop attaching later able to
     * resize windows natively. Keep resize/unset until the next protocol
     * step's lane proves they can be removed, and confirm in a later,
     * separate write. iOS does the same in `forceWindowSizesToClientSize`.
     *
     * Scoped to mosh: an inline `-CC` client has no separate visible PTY, so it
     * cannot freeze its own session.
     */
    private fun forceTmuxWindowSizes(
        size: SharedTmuxGridSize,
        belongsToAuthorityClaim: Boolean = false,
        onlyWindowId: Int? = null,
        ordinaryProofToken: Long? = null,
    ) = forceTmuxWindowSizesImpl(size, belongsToAuthorityClaim, onlyWindowId, ordinaryProofToken, evenIfLayoutMatches = belongsToAuthorityClaim)

    private fun forceTmuxWindowSizesImpl(
        size: SharedTmuxGridSize,
        belongsToAuthorityClaim: Boolean,
        onlyWindowId: Int?,
        ordinaryProofToken: Long?,
        evenIfLayoutMatches: Boolean,
    ) = synchronized(tmuxTransportLock) {
        // A withheld split projection can change the local Mosh PTY while
        // the remote publication memo stays at the full-window grid. Returning
        // to that fitting window must still restore this device's canvas.
        reconcileLocalMoshCanvas(size)
        // A late claim forces nothing, its own window included (§6.10 rule 2).
        if (closed || !usesMoshPrimaryTransport() || yieldedToPeer() || authorityClaimLate() ||
            (!belongsToAuthorityClaim && lastTmuxAuthorityResult?.geometryHold != SharedTmuxAuthorityGeometryHold.OWNER)
        ) return@synchronized
        // Ordinary layout recovery must first know whether a mismatch means
        // a stamp-less peer. Claims, hydration and real size replays bypass it.
        if (onlyWindowId != null &&
            (!appForeground || !presentationActive || lastTmuxAuthorityResult?.claim != null ||
                !windowSizePolicyKnown || !windowSizePolicyIsLatest || windowSizePolicyWindowId != onlyWindowId)
        ) return@synchronized
        if (onlyWindowId != null) {
            if (ordinaryProofToken == null) {
                val window = mutableTmuxSnapshot.value?.activeWindow?.takeIf { it.id == onlyWindowId }
                    ?: return@synchronized
                val previous = pendingTmuxWindowSizeReplayInFlight(window.id)
                if (tmuxWindowForceRule.decision(size, window.layout?.gridSize(), previous?.requested) ==
                    SharedTmuxWindowSizeReplay.Decision.REPLAY
                ) requestOrdinaryTmuxWindowRecovery(window.id, size, window.layout?.gridSize())
                return@synchronized
            }
            if (currentOrdinaryTmuxWindowRecovery(ordinaryProofToken)?.let {
                    it.windowId == onlyWindowId && it.requested == size && it.completed
                } != true
            ) return@synchronized
        }
        val windows = mutableTmuxSnapshot.value?.windows.orEmpty()
        pendingTmuxWindowSizeReplays.keys.retainAll(windows.mapTo(mutableSetOf()) { it.id })
        // A claim forces only its own window, even at a matching layout: a
        // background window keeps its own size and window-size policy (D2,
        // §6.6), as iOS's `forceWindowSizesToClientSize` does.
        val claimWindowId = mutableTmuxSnapshot.value?.activeWindow?.id
        windows.filter { onlyWindowId == null || it.id == onlyWindowId }
            .filter { !belongsToAuthorityClaim || it.id == claimWindowId }.forEach { window ->
            val previous = pendingTmuxWindowSizeReplayInFlight(window.id)
            if (!evenIfLayoutMatches || window.id != claimWindowId) {
                when (tmuxWindowForceRule.decision(size, window.layout?.gridSize(), previous?.requested)) {
                    SharedTmuxWindowSizeReplay.Decision.FITTING,
                    SharedTmuxWindowSizeReplay.Decision.WAITING -> {
                        return@forEach
                    }
                    SharedTmuxWindowSizeReplay.Decision.REPLAY -> Unit
                }
            }
            if (tmuxWindowSizeReplayToken == Long.MAX_VALUE) return@forEach
            val commands = tmuxWindowForceRule.commands(window.id, size)
            check(commands.size == 4) { "window-size replay must have three mutations and one query" }
            val attempt = PendingTmuxWindowSizeReplay(
                token = ++tmuxWindowSizeReplayToken,
                transportGeneration = tmuxTransportGeneration,
                requested = size,
                confirmationCommand = commands[3],
                passiveRecovery = ordinaryProofToken != null,
            )
            // Register before the first send: its reply can re-enter this
            // adapter immediately. Once a force is accepted, keep its attempt
            // latched on partial failure until an explicit geometry boundary.
            pendingTmuxWindowSizeReplays[window.id] = attempt
            reportAuthorityClaimFenceForce()
            if (!sendTmuxControl(commands[0], TmuxResponsePurpose.WindowSizeReplayMutation(
                    window.id, attempt.token, attempt.transportGeneration, size, 0,
                ))) {
                pendingTmuxWindowSizeReplays.remove(window.id, attempt)
                reportAuthorityClaimFenceForce()
                return@forEach
            }
            // The resize is on the wire: with this connection's client already
            // at the grid (P6), the shared force sequence needs no extra -C.
            noteAuthorityClaimGridMutation()
            for (commandIndex in 1..2) {
                if (!sendTmuxControl(commands[commandIndex], TmuxResponsePurpose.WindowSizeReplayMutation(
                        window.id, attempt.token, attempt.transportGeneration, size, commandIndex,
                    ))) {
                    failTmuxWindowSizeReplay(window.id, attempt.token, "mutation $commandIndex unsent")
                    return@forEach
                }
            }
            diagnostics.record(
                "tmux_window_force",
                mapOf("detail" to "@${window.id} ${size.columns}x${size.rows} attempt=${attempt.token}",
                    "transport" to diagnosticTransport),
            )
        }
    }

    /** Reuse ordinary sizing, including compact projection, after readiness changes. */
    private fun reconcilePresentedTmuxWindowSize(snapshot: SharedTmuxSnapshot) = synchronized(tmuxTransportLock) {
        if (!presentedTmuxWindowRecoveryReserved || reconcilingPresentedTmuxWindowSize) return@synchronized
        if (snapshot.activeWindow?.layout == null && !closed && appForeground && presentationActive &&
            lastTmuxAuthorityResult?.claim == null && mutableTmuxAuthority.value is SharedTmuxGridAuthoritySnapshot.Mine
        ) return@synchronized // Keep the reservation through the native details reply.
        reconcilingPresentedTmuxWindowSize = true
        try {
            reconcileTmuxClientSize(snapshot)
        } finally {
            presentedTmuxWindowRecoveryReserved = false
            submitAuthorityOrdinaryRecovery()
            reconcilingPresentedTmuxWindowSize = false
        }
    }

    /** Reserve passive proof before known layout/policy can be judged stamp-less. */
    private fun reservePresentedTmuxWindowRecovery(snapshot: SharedTmuxSnapshot?) {
        if (presentedTmuxWindowRecoveryReserved || ordinaryTmuxWindowRecovery?.completed == false ||
            closed || !usesMoshPrimaryTransport() || !appForeground || !presentationActive ||
            compactSizeRole == CompactSizeRole.Observer || lastTmuxAuthorityResult?.claim != null ||
            lastTmuxAuthorityResult?.geometryHold != SharedTmuxAuthorityGeometryHold.OWNER ||
            mutableTmuxAuthority.value !is SharedTmuxGridAuthoritySnapshot.Mine ||
            snapshot?.isWindowListHydrated != true || !snapshot.isActiveWindowAuthoritative
        ) return
        val window = snapshot.activeWindow ?: return
        val requested = lastPublishedTmuxSize ?: return
        if (windowSizePolicyKnown && windowSizePolicyWindowId == window.id && !windowSizePolicyIsLatest) return
        if (window.layout?.gridSize() == requested) return
        presentedTmuxWindowRecoveryReserved = true
        submitAuthorityOrdinaryRecovery()
    }

    private fun requestOrdinaryTmuxWindowRecovery(windowId: Int, requested: SharedTmuxGridSize, observed: SharedTmuxGridSize?) {
        val mine = mutableTmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Mine ?: return
        if (lastTmuxAuthorityResult?.claim != null || !windowSizePolicyKnown || windowSizePolicyWindowId != windowId) return
        if (observed == null || pendingAuthorityRepaintGeneration != null) return
        val previous = ordinaryTmuxWindowRecovery
        if (previous?.let { it.transportGeneration == tmuxTransportGeneration && it.windowId == windowId &&
                it.requested == requested && it.observed == observed && it.authorityGeneration == mine.generation &&
                it.publishedAtRequest == lastPublishedTmuxSize && it.viewport == lastTmuxViewport &&
                it.layout == mutableTmuxSnapshot.value?.activeWindow?.layout &&
                it.activePaneId == mutableTmuxSnapshot.value?.activePaneId && it.presentation == tmuxGridPresentation &&
                it.observing == (compactSizeRole == CompactSizeRole.Observer) && it.policyIsLatest == windowSizePolicyIsLatest } == true
        ) return
        if (ordinaryTmuxWindowRecoveryToken == Long.MAX_VALUE) return
        val recovery = PendingTmuxOrdinaryWindowRecovery(
            ++ordinaryTmuxWindowRecoveryToken, tmuxTransportGeneration, windowId, requested, observed, mine.generation,
            previous?.takeIf { it.transportGeneration == tmuxTransportGeneration && it.authorityGeneration == mine.generation }
                ?.expectedStamp ?: SharedTmuxCommands.authorityStampValue(tmuxDeviceIdentity.id, tmuxDeviceIdentity.displayName, mine.generation),
            windowSizePolicyIsLatest,
            lastPublishedTmuxSize, lastTmuxViewport, mutableTmuxSnapshot.value?.activeWindow?.layout,
            mutableTmuxSnapshot.value?.activePaneId, tmuxGridPresentation, compactSizeRole == CompactSizeRole.Observer,
        )
        ordinaryTmuxWindowRecovery = recovery
        submitAuthorityOrdinaryRecovery()
        if (authorityScopeResolution != null) {
            heldOrdinaryAuthorityRead = recovery.token
            return
        }
        if (!sendTmuxControl(SharedTmuxCommands.authorityQueryCommand(authorityOwnerSessionId),
                TmuxResponsePurpose.OrdinaryWindowAuthority(recovery.token, authorityOwnerSessionId))) {
            finishOrdinaryTmuxWindowRecovery(recovery.token)
        }
    }

    private fun currentOrdinaryTmuxWindowRecovery(token: Long): PendingTmuxOrdinaryWindowRecovery? {
        val recovery = ordinaryTmuxWindowRecovery?.takeIf { it.token == token } ?: return null
        val window = mutableTmuxSnapshot.value?.activeWindow ?: return null
        val mine = mutableTmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Mine ?: return null
        return recovery.takeIf {
            !closed && appForeground && presentationActive && !ordinaryTmuxGeometryWithheld() &&
                pendingAuthorityRepaintGeneration == null && it.transportGeneration == tmuxTransportGeneration &&
                it.authorityGeneration == mine.generation && mutableTmuxSnapshot.value?.activeWindowId == it.windowId && window.id == it.windowId &&
                window.layout?.gridSize() == it.observed && window.layout == it.layout &&
                mutableTmuxSnapshot.value?.activePaneId == it.activePaneId && lastTmuxViewport == it.viewport &&
                tmuxGridPresentation == it.presentation && (compactSizeRole == CompactSizeRole.Observer) == it.observing &&
                (lastPublishedTmuxSize == it.publishedAtRequest || (it.completed && lastPublishedTmuxSize == it.requested)) &&
                windowSizePolicyKnown && windowSizePolicyWindowId == it.windowId && windowSizePolicyIsLatest == it.policyIsLatest
        }
    }

    /**
     * Ends an ordinary recovery. One that could not prove the window ours
     * alone re-judges a layout edge its run kept from the stamp-less rule:
     * nothing else may follow (no snapshot need arrive), and the edge memo
     * still keeps an edge that was already judged from being judged twice.
     * A proof repairs the window instead, and a foreign stamp leaves the
     * verdict to that peer's own report. Caller holds the lock.
     */
    private fun finishOrdinaryTmuxWindowRecovery(token: Long, rejudgeStamplessPeer: Boolean = true) {
        ordinaryTmuxWindowRecovery?.takeIf { it.token == token }?.let {
            ordinaryTmuxWindowRecovery = it.copy(completed = true)
            submitAuthorityOrdinaryRecovery(proven = !rejudgeStamplessPeer)
        }
    }

    private fun handleOrdinaryTmuxWindowRecovery(purpose: TmuxResponsePurpose, success: Boolean, lines: List<String>) =
        synchronized(tmuxTransportLock) {
            val token = when (purpose) {
                is TmuxResponsePurpose.OrdinaryWindowAuthority -> purpose.token
                is TmuxResponsePurpose.OrdinaryWindowControlClient -> purpose.token
                is TmuxResponsePurpose.OrdinaryWindowVisibleClient -> purpose.token
                is TmuxResponsePurpose.OrdinaryWindowClients -> purpose.token
                else -> return@synchronized
            }
            // A missing owner is evidence about the connection, not the
            // recovery: act on it even when the recovery itself is obsolete.
            val stampLines = (purpose as? TmuxResponsePurpose.OrdinaryWindowAuthority)
                ?.takeIf { success }
                ?.let { SharedTmuxCommands.authorityQueryReplyLines(lines, it.ownerSessionId) }
            if (purpose is TmuxResponsePurpose.OrdinaryWindowAuthority && success && stampLines == null) {
                abandonTmuxAuthorityOwnerScope(purpose.ownerSessionId, "owner-missing")
                finishOrdinaryTmuxWindowRecovery(token)
                return@synchronized
            }
            val recovery = currentOrdinaryTmuxWindowRecovery(token)?.takeUnless { it.completed }
            if (recovery == null) {
                finishOrdinaryTmuxWindowRecovery(token)
                return@synchronized
            }
            if (!success) {
                finishOrdinaryTmuxWindowRecovery(token)
                return@synchronized
            }
            val next = when (purpose) {
                is TmuxResponsePurpose.OrdinaryWindowAuthority -> {
                    val stamp = stampLines?.singleOrNull()
                    if (stamp != recovery.expectedStamp) {
                        finishOrdinaryTmuxWindowRecovery(token, rejudgeStamplessPeer = stamp.isNullOrEmpty())
                        return@synchronized
                    }
                    "display-message -p '#{client_name}|#{client_pid}|#{client_created}'" to
                        TmuxResponsePurpose.OrdinaryWindowControlClient(token)
                }
                is TmuxResponsePurpose.OrdinaryWindowControlClient -> {
                    val identity = lines.singleOrNull()?.takeIf { it.isNotEmpty() }
                    if (identity == null) {
                        finishOrdinaryTmuxWindowRecovery(token)
                        return@synchronized
                    }
                    "show-options -qv ${SharedTmuxCommands.authorityVisibleClientOption(tmuxDeviceIdentity.id)}" to
                        TmuxResponsePurpose.OrdinaryWindowVisibleClient(token, identity)
                }
                is TmuxResponsePurpose.OrdinaryWindowVisibleClient -> {
                    val identity = lines.singleOrNull()?.takeIf { it.isNotEmpty() }
                    if (identity == null) {
                        finishOrdinaryTmuxWindowRecovery(token)
                        return@synchronized
                    }
                    "list-clients -F '#{window_id}\t#{client_name}\t#{client_pid}\t#{client_created}'" to
                        TmuxResponsePurpose.OrdinaryWindowClients(token, purpose.control, identity)
                }
                is TmuxResponsePurpose.OrdinaryWindowClients -> {
                    val proved = SharedTmuxWindowSizeReplay.provesExclusiveOwnership(
                        recovery.windowId, purpose.control, purpose.visible, lines.joinToString("\n"),
                    )
                    finishOrdinaryTmuxWindowRecovery(token, rejudgeStamplessPeer = !proved)
                    if (proved) publishTmuxClientSize(recovery.requested, ordinaryProofToken = token)
                    return@synchronized
                }
                else -> return@synchronized
            }
            if (!sendTmuxControl(next.first, next.second)) finishOrdinaryTmuxWindowRecovery(token)
        }

    /** [windowId]'s force on this transport whose commands are still on the wire. Caller holds the lock. */
    private fun pendingTmuxWindowSizeReplayInFlight(windowId: Int): PendingTmuxWindowSizeReplay? =
        pendingTmuxWindowSizeReplays[windowId]?.takeIf { it.transportGeneration == tmuxTransportGeneration && !it.confirmationAnswered }

    /** Local churn retires ordinary attempts, never the live claim's own force. Caller holds the lock. */
    private fun discardObsoleteTmuxWindowSizeReplays() {
        pendingTmuxWindowSizeReplays.entries.removeIf { (windowId, attempt) -> !isAuthorityClaimForce(windowId, attempt) }
        reportAuthorityClaimFenceForce()
    }

    /**
     * Whether [attempt] is the live claim's own window force: at the claim's
     * target, on the window its fence names (the active window before its
     * first fence), on this transport. As on iOS, the force is known by what
     * it asked for, not by a token the claim keeps. Caller holds the lock.
     */
    private fun isAuthorityClaimForce(windowId: Int, attempt: PendingTmuxWindowSizeReplay): Boolean {
        val claim = liveAuthorityClaim() ?: return false
        if (attempt.transportGeneration != tmuxTransportGeneration || attempt.requested != claim.targetGrid) return false
        val fenced = lastTmuxAuthorityResult?.claimFence?.takeIf { it.generation == claim.generation }?.windowId
        return windowId == (fenced ?: mutableTmuxSnapshot.value?.activeWindowId)
    }

    /**
     * Tells the session whether the side channel's window force at the
     * claim's target on its fenced window still awaits proof
     * ([SharedTmuxAuthorityClaimFence.forceOutstanding]), as iOS's
     * `reportGridClaimFenceForce` does. Under `latest` the window can show
     * the target before the force's unset recalculated it, so that layout
     * alone confirms nothing. Called wherever such an attempt is registered
     * or retired. Caller holds the lock.
     */
    private fun reportAuthorityClaimFenceForce() {
        val claim = liveAuthorityClaim() ?: return
        val fence = lastTmuxAuthorityResult?.claimFence?.takeIf { it.generation == claim.generation } ?: return
        val outstanding = pendingTmuxWindowSizeReplays[fence.windowId]?.let { isAuthorityClaimForce(fence.windowId, it) } == true
        if (outstanding == fence.forceOutstanding) return
        reduceTmuxAuthority { session, now -> session.claimFenceForce(now, fence.id, outstanding) }
    }

    private fun failTmuxWindowSizeReplay(windowId: Int, token: Long, reason: String) {
        val pending = pendingTmuxWindowSizeReplays[windowId]?.takeIf { it.token == token } ?: return
        if (pending.failureDiagnosed) return
        if (pending.passiveRecovery) pendingTmuxWindowSizeReplays.remove(windowId, pending)
        else pendingTmuxWindowSizeReplays[windowId] = pending.copy(failureDiagnosed = true)
        diagnostics.record("tmux_window_force_failed", mapOf(
            "detail" to "@$windowId attempt=$token $reason", "transport" to diagnosticTransport,
        ))
        if (isAuthorityClaimForce(windowId, pending)) liveAuthorityClaim()?.let { abortTmuxGridAuthorityClaim(it.generation, reason) }
    }

    private fun handleTmuxWindowSizeMutation(purpose: TmuxResponsePurpose.WindowSizeReplayMutation, success: Boolean) =
        synchronized(tmuxTransportLock) {
            if (closed) return@synchronized
            val pending = pendingTmuxWindowSizeReplays[purpose.windowId]?.takeIf {
                it.token == purpose.token && it.transportGeneration == purpose.transportGeneration &&
                    purpose.transportGeneration == tmuxTransportGeneration && it.requested == purpose.requested
            } ?: return@synchronized
            val updated = pending.noteMutation(purpose.commandIndex, success)
            pendingTmuxWindowSizeReplays[purpose.windowId] = updated
            if (!success) {
                failTmuxWindowSizeReplay(purpose.windowId, purpose.token, "mutation ${purpose.commandIndex} failed")
                return@synchronized
            }
            if (!updated.readyToConfirm) return@synchronized
            pendingTmuxWindowSizeReplays[purpose.windowId] = updated.copy(confirmationQueued = true)
            // A claim's force reads no policy of its own: the fence's policy
            // read, queued behind the unset, is the claim's (M4).
            // Unsetting window-size schedules a later tmux recalculation.
            // A query in the mutation batch can see the temporary forced grid;
            // dispatch this one only after all three mutation replies arrived.
            if (!sendTmuxControl(updated.confirmationCommand, TmuxResponsePurpose.WindowSizeReplayConfirmation(
                    purpose.windowId, updated.token, updated.transportGeneration, updated.requested,
                ))) failTmuxWindowSizeReplay(purpose.windowId, purpose.token, "confirmation unsent")
        }

    private fun handleTmuxWindowSizeConfirmation(
        purpose: TmuxResponsePurpose.WindowSizeReplayConfirmation,
        success: Boolean,
        lines: List<String>,
    ) = synchronized(tmuxTransportLock) {
        if (closed) return@synchronized
        val pending = pendingTmuxWindowSizeReplays[purpose.windowId]?.takeIf {
            it.token == purpose.token && it.transportGeneration == purpose.transportGeneration &&
                purpose.transportGeneration == tmuxTransportGeneration && it.requested == purpose.requested
        } ?: return@synchronized
        val claimGeneration = liveAuthorityClaim()?.generation?.takeIf { isAuthorityClaimForce(purpose.windowId, pending) }
        val acceptsPolicyGeometry = claimGeneration != null && authorityClaimPolicyIsFixed(purpose.windowId, claimGeneration)
        val reported = if (success && !acceptsPolicyGeometry) tmuxWindowForceRule.reportedGeometry(purpose.windowId, lines.joinToString("\n")) else null
        // The size this read reports is no claim evidence, as on iOS: Main
        // drains it after IO judged the settle probe written behind it, so
        // as an observation it could outdate that newer answer.
        if (success && pending.confirmationQueued && pending.resizeSucceeded == true && pending.policyRestoreSucceeded == true &&
            (acceptsPolicyGeometry || reported == pending.requested)
        ) {
            pendingTmuxWindowSizeReplays.remove(purpose.windowId, pending)
            // A proven force can confirm the fence (the core's `claimFenceForce`).
            if (claimGeneration != null) reportAuthorityClaimFenceForce()
        } else if (claimGeneration != null && reported != null) {
            // A valid foreign size may precede the unset's recalculation.
            // The force stays unproved, as iOS keeps it: the settle probe,
            // which reads the window after it, proves it, or its loss forces
            // again (§6.10 rule 4).
            pendingTmuxWindowSizeReplays[purpose.windowId] = pending.copy(confirmationAnswered = true)
            recordAuthorityClaimGeometry("force-unproved", claimGeneration, "@${purpose.windowId} ${reported.columns}x${reported.rows}")
        } else {
            failTmuxWindowSizeReplay(purpose.windowId, purpose.token, "post-command geometry unconfirmed")
        }
    }

    private fun SharedTmuxLayoutNode.findPane(paneId: Int?): SharedTmuxLayoutNode.Leaf? = when (this) {
        is SharedTmuxLayoutNode.Leaf -> takeIf { paneId == null || it.paneId == paneId }
        is SharedTmuxLayoutNode.Split -> children.firstNotNullOfOrNull { it.findPane(paneId) }
    }

    private fun SharedTmuxLayoutNode.paneIdsInLayoutOrder(): List<Int> = when (this) {
        is SharedTmuxLayoutNode.Leaf -> listOf(paneId)
        is SharedTmuxLayoutNode.Split -> children.flatMap { it.paneIdsInLayoutOrder() }
    }

    private fun SharedTmuxLayoutNode.gridSize(): SharedTmuxGridSize = when (this) {
        is SharedTmuxLayoutNode.Leaf -> SharedTmuxGridSize(width, height)
        is SharedTmuxLayoutNode.Split -> SharedTmuxGridSize(width, height)
    }

    private fun applyInitialTmuxSelection(snapshot: SharedTmuxSnapshot) {
        if (restoreSelectionApplied || snapshot.windows.isEmpty()) return
        if (tmuxAuthorityMutationRefusal() != null) {
            // Not this device's grid to change yet: a show still resuming, a
            // claim running (or one whose presentation timed out to the veil,
            // S4′), or a peer working here, whose window must not switch
            // under it. Keep the restored selection for when this device has
            // the grid, after the show's claim or a take-back settles (see
            // publishTmuxAuthorityPresentation), rather than lose it to the
            // gate.
            return
        }
        val parts = initialTmuxSelection?.split(':', limit = 2).orEmpty()
        val windowId = parts.getOrNull(0)?.toIntOrNull()
        val paneId = parts.getOrNull(1)?.toIntOrNull()
        windowId?.takeIf { id -> snapshot.windows.any { it.id == id } }?.let(::selectTmuxWindow)
        paneId?.takeIf { id -> snapshot.windows.any { window -> window.panes.any { it.id == id } } }
            ?.let(::selectTmuxPane)
        restoreSelectionApplied = true
    }

    private fun persistTmuxSelection(snapshot: SharedTmuxSnapshot) {
        val windowId = snapshot.activeWindowId ?: return
        val paneId = snapshot.activePaneId ?: return
        val selection = "$windowId:$paneId"
        if (selection == lastStoredSelection) return
        lastStoredSelection = selection
        scope.launch {
            restore.save(
                SessionRestoreRecord(
                    sessionId = sessionId,
                    hostId = host.id,
                    transportKind = diagnosticTransport,
                    tmuxTarget = host.tmuxTarget,
                    lastSelection = selection,
                    reconnectRequired = false,
                    updatedAtEpochMilliseconds = System.currentTimeMillis(),
                ),
            )
        }
    }

    private fun currentTmuxSelection(): String? {
        val snapshot = mutableTmuxSnapshot.value ?: return null
        val windowId = snapshot.activeWindowId ?: return null
        val paneId = snapshot.activePaneId ?: return null
        return "$windowId:$paneId"
    }

    private fun sendTmuxInput(
        paneId: Int,
        bytes: ByteArray,
        receipt: SharedSessionCommandReceipt? = null,
    ) {
        if (bytes.isEmpty()) return
        val chunks = bytes.asList().chunked(256)
        chunks.forEachIndexed { index, chunk ->
            val hex = chunk.joinToString(" ") { "%02x".format(it.toInt() and 0xff) }
            val purpose = if (receipt != null && index == chunks.lastIndex) {
                TmuxResponsePurpose.CommandCompletion(receipt)
            } else {
                TmuxResponsePurpose.Ignore
            }
            sendTmuxControl("send-keys -t %$paneId -H $hex", purpose)
        }
    }

    /**
     * Applies one reducer result. Every reducer call's result comes through
     * here, under [tmuxTransportLock] (the IO listener and the Main reply
     * drain both reach the reducer, so the lock is what keeps its calls
     * serial). A nested call made while handling this result's effects
     * publishes its own, newer projection; this one then stands down.
     */
    private fun applyTmuxAuthorityLifecycle(result: SharedTmuxAuthoritySessionResult) {
        synchronized(tmuxTransportLock) {
            if (!result.changed) return
            val reduction = ++tmuxAuthorityReductions
            val endingWireGeneration = pendingAuthorityRepaintGeneration
            val state = result.state
            lastTmuxAuthorityResult = state
            mutableTmuxReclaimInFlight.value = state.claim?.presentationVisible == true
            result.trace?.let { diagnostics.record("tmux_authority_lifecycle",
                mapOf("detail" to it, "transport" to diagnosticTransport)) }
            if (mutableTmuxAuthority.value != state.authority) {
                mutableTmuxAuthority.value = state.authority
                if (state.authority is SharedTmuxGridAuthoritySnapshot.Peer) {
                    pendingTmuxWindowMutation?.takeUnless { it.mutationStarted }?.token?.let {
                        abandonTmuxWindowMutationLocked(it, "Another device controls this tmux session.")
                    }
                } else updateTmuxWindowMutationState()
                emitSharedIfOpen { emitGridAuthorityChanged(state.authority) }
            }
            result.effects.forEach { effect ->
                when (effect) {
                    // One reduction can replace a due retry with a newer
                    // read; a nested one can supersede this batch's read.
                    // Only the session's current read reaches the FIFO.
                    is SharedTmuxAuthoritySessionEffect.QueryAuthority ->
                        if (lastTmuxAuthorityResult?.currentQueryId == effect.queryId) sendTmuxAuthorityQuery(effect.queryId)
                    is SharedTmuxAuthoritySessionEffect.BeginClaim -> {
                        if (lastTmuxAuthorityResult?.claim?.generation != effect.generation) return@forEach
                        if (effect.reason == SharedTmuxAuthorityClaimReason.SHOW || effect.reason == SharedTmuxAuthorityClaimReason.EXPLICIT_OPEN) {
                            foregroundAuthorityClaimGeneration = effect.generation
                            foregroundAuthorityClaimOwner = foregroundAuthorityQueryOwner
                        }
                        beginTmuxGridAuthorityClaim(effect.generation)
                    }
                    is SharedTmuxAuthoritySessionEffect.RequestRepaint -> beginTmuxGridAuthorityRepaint(effect.generation)
                    is SharedTmuxAuthoritySessionEffect.CommitAuthorityStamp -> {
                        if (isLiveAuthorityClaim(effect.generation)) {
                            if (usesMoshPrimaryTransport()) {
                                // The window the confirmed fence named, at the claim's target.
                                val windowId = lastTmuxAuthorityResult?.claimFence?.takeIf { it.generation == effect.generation }?.windowId
                                val requested = liveAuthorityClaim()?.targetGrid
                                if (windowId == null || requested == null) {
                                    abortTmuxGridAuthorityClaim(effect.generation, "post-frame geometry target missing")
                                } else if (pendingAuthorityPaintGeometry == null) {
                                    val confirmation = TmuxResponsePurpose.AuthorityPaintGeometry(effect.generation, tmuxTransportGeneration, windowId, requested)
                                    pendingAuthorityPaintGeometry = confirmation
                                    if (!sendTmuxControl(tmuxWindowForceRule.sizeQuery(windowId), confirmation)) {
                                        pendingAuthorityPaintGeometry = null
                                        abortTmuxGridAuthorityClaim(effect.generation, "post-frame geometry query unsent")
                                    }
                                }
                            } else commitTmuxGridAuthorityStamp(effect.generation)
                        }
                    }
                    is SharedTmuxAuthoritySessionEffect.AuthorityChanged -> Unit
                    SharedTmuxAuthoritySessionEffect.HideReclaimPresentation -> {
                        // Aborts, resets and hides end the presentation too. Only the
                        // deadline leaves the claim live with its presentation gone.
                        if (!state.hidden && state.claim != null) diagnostics.record(
                            "tmux_authority_claim_slow",
                            mapOf("detail" to "ack budget elapsed", "transport" to diagnosticTransport),
                        )
                        endTmuxGridAuthorityClaimIfStalledLate("deadline")
                    }
                    is SharedTmuxAuthoritySessionEffect.ClaimAborted -> {
                        if (pendingAuthorityRepaintGeneration == endingWireGeneration) finishAbortedTmuxGridAuthorityClaim()
                        diagnostics.record("tmux_authority_claim_failed", mapOf("detail" to effect.reason, "transport" to diagnosticTransport))
                    }
                    is SharedTmuxAuthoritySessionEffect.ClaimSettled -> {
                        if (pendingAuthorityRepaintGeneration != effect.generation) return@forEach
                        pendingTmuxWindowSizeReplays.clear()
                        ordinaryTmuxWindowRecovery = null
                        lastAuthorityOrdinaryRecovery = false
                        presentedTmuxWindowRecoveryReserved = false
                        foregroundAuthorityClaimGeneration = null
                        foregroundAuthorityClaimOwner = null
                        pendingAuthorityRepaintGeneration = null
                        clearAuthorityRepaintBookkeeping()
                    }
                    is SharedTmuxAuthoritySessionEffect.RefenceClaim -> refenceTmuxGridAuthorityClaim(effect.generation)
                    is SharedTmuxAuthoritySessionEffect.ReleaseGeometry -> when (effect.release) {
                        SharedTmuxAuthorityGeometryRelease.NONE -> Unit
                        SharedTmuxAuthorityGeometryRelease.ADVERTISE -> advertiseTmuxGeometryOnly()
                        SharedTmuxAuthorityGeometryRelease.OWNER_REPLAY -> reconcileTmuxClientSize(forceAllWindows = true)
                    }
                    SharedTmuxAuthoritySessionEffect.RaiseStamplessPeer -> Unit
                    SharedTmuxAuthoritySessionEffect.ControlChannelUnresponsive -> {
                        diagnostics.record("tmux_authority_channel_unresponsive", mapOf("transport" to diagnosticTransport))
                        // Closing this SSH side channel invokes the existing retry. Never close the Mosh primary.
                        if (usesMoshPrimaryTransport()) tmuxConnection?.close()
                    }
                }
            }
            if (presentedTmuxWindowRecoveryReserved &&
                (state.hidden || !appForeground || state.claim != null || state.authority !is SharedTmuxGridAuthoritySnapshot.Mine)
            ) {
                presentedTmuxWindowRecoveryReserved = false
                submitAuthorityOrdinaryRecovery()
            }
            // Effects can reduce synchronously. Their newer projection always stands.
            if (reduction == tmuxAuthorityReductions) {
                projectTmuxRuntimeAuthority(state.authority)
                if (reduction != tmuxAuthorityReductions) return
                publishTmuxAuthorityPresentation(state)
                scheduleAuthorityWake(state.nextDeadlineMillis)
            }
        }
    }

    /**
     * The shared session alone judges authority. Project only a changed value
     * into the runtime and carry out the released P7/P8 work in the same
     * transport-order critical section. Move the memo before calling: queued
     * runtime callbacks can re-enter with a newer session reduction.
     */
    private fun projectTmuxRuntimeAuthority(authority: SharedTmuxGridAuthoritySnapshot) {
        synchronized(tmuxTransportLock) {
            if (lastProjectedTmuxAuthority == authority) return
            val project = tmuxAuthorityProjectionProbe
            val runtime = tmuxCore
            if (project == null && runtime == null) return
            lastProjectedTmuxAuthority = authority
            carryOutReleasedTmuxRenderWork(
                project?.invoke(authority) ?: runtime!!.projectAuthorityReleasing(authority),
                "authority projected",
            )
        }
    }

    /**
     * Carries out render work an authority change released, as the
     * projection's ([projectTmuxRuntimeAuthority]): commands on the
     * writer now, in order, the rest in the ordered render batches; a
     * refusal fences the connection. Caller holds [tmuxTransportLock].
     */
    private fun carryOutReleasedTmuxRenderWork(settlement: SharedTmuxClaimSettlement, detail: String) {
        when (settlement) {
            SharedTmuxClaimSettlement.StaleHandle -> Unit
            SharedTmuxClaimSettlement.Refused -> {
                diagnostics.record(
                    "tmux_render_settlement_refused",
                    mapOf("detail" to detail, "transport" to diagnosticTransport),
                )
                tmuxConnection?.close()
            }
            is SharedTmuxClaimSettlement.Released -> {
                val effects = settlement.renderEffects
                val tmux = tmuxConnection
                if (effects.isEmpty() || tmux == null) return
                val transportGeneration = tmuxTransportGeneration
                if (!enqueueLedgerRenderCommands(effects, tmux, transportGeneration)) {
                    diagnostics.record(
                        "render_ledger_command_unsent",
                        mapOf("detail" to "settlement $detail", "transport" to diagnosticTransport),
                    )
                }
                pendingTmuxRenderBatches.addLast(
                    PendingTmuxRenderBatch(effects, tmux, transportGeneration, inlineAuthorityRepaintFence.epoch),
                )
                scope.launch(Dispatchers.Main.immediate) {
                    tmuxRenderEffectMutex.withLock { drainTmuxRenderBatches() }
                }
            }
        }
    }

    /**
     * Applies the reduction a runtime made of one read's stamps inside its
     * feed (§6.17). The runtime projected each verdict as it went, so the
     * projection memo moves first and this costs no call into the core.
     */
    private fun adoptRuntimeAuthorityReduction(result: SharedTmuxAuthoritySessionResult) {
        synchronized(tmuxTransportLock) {
            lastProjectedTmuxAuthority = result.state.authority
            applyTmuxAuthorityLifecycle(tmuxAuthorityLifecycle.adopt(result))
        }
    }

    private inline fun reduceTmuxAuthority(
        crossinline call: (SharedTmuxAuthoritySession, Long) -> SharedTmuxAuthoritySessionResult,
    ) {
        synchronized(tmuxTransportLock) {
            if (closed) return
            applyTmuxAuthorityLifecycle(tmuxAuthorityLifecycle.submit(authorityNow()) { session, now -> call(session, now) })
        }
    }

    private fun beginTmuxAuthorityScopeResolution(ownerName: String, transportGeneration: Long) {
        authorityOwnerSessionId = null
        authoritySubscriptionRequested = false
        heldAuthorityQueryId = null
        heldOrdinaryAuthorityRead = null
        authorityScopeResolution = null
        // A switch keeps the pane feeds, but cannot read the previous owner's
        // stamp while the new session's scope is unresolved.
        desiredTmuxSubscriptions = desiredTmuxSubscriptions.copy(authority = false, authorityOwnerSessionId = null)
        if (!usesMoshPrimaryTransport()) {
            pushTmuxSubscriptions()
            return
        }
        val resolution = AuthorityScopeResolution(transportGeneration, ++lastAuthorityScopeResolutionId)
        authorityScopeResolution = resolution
        pushTmuxSubscriptions()
        SharedTmuxCommands.authorityOwnerResolutionCommands(ownerName).forEachIndexed { index, command ->
            val purpose = TmuxResponsePurpose.AuthorityOwnerResolution(transportGeneration, owner = index == 0, resolution.id)
            if (!sendTmuxControl(command, purpose)) handleTmuxAuthorityScopeReply(purpose, false, emptyList())
        }
    }

    /**
     * A grouped view outlives a killed owner: owner reads then find no owner
     * and owner writes fail. Fall back to our own session (the behaviour
     * before owner resolution) rather than reading a dead owner as
     * unstamped; the caller's retry uses the new scope. Reconnecting
     * resolves the owner afresh. Caller holds the lock.
     */
    private fun abandonTmuxAuthorityOwnerScope(ownerSessionId: Int?, reason: String) {
        if (ownerSessionId == null || authorityOwnerSessionId != ownerSessionId) return
        authorityOwnerSessionId = null
        diagnostics.record("tmux_authority_scope", mapOf(
            "detail" to "scope=own reason=$reason",
            "transport" to diagnosticTransport,
        ))
        if (authoritySubscriptionRequested) sendTmuxAuthoritySubscription()
    }

    private fun sendTmuxAuthoritySubscription() {
        synchronized(tmuxTransportLock) {
            if (closed) return
            authoritySubscriptionRequested = true
            if (authorityScopeResolution != null) return
            desiredTmuxSubscriptions = desiredTmuxSubscriptions.copy(authority = true, authorityOwnerSessionId = authorityOwnerSessionId)
            pushTmuxSubscriptions()
        }
    }

    /** Caller holds [tmuxTransportLock], including across synchronous callbacks. */
    private fun pushTmuxSubscriptions() {
        if (closed) return
        tmuxSubscriptionsProbe?.let { it(desiredTmuxSubscriptions); return }
        tmuxCore?.setSubscriptions(desiredTmuxSubscriptions)
    }

    private fun handleTmuxAuthorityScopeReply(purpose: TmuxResponsePurpose.AuthorityOwnerResolution, success: Boolean, lines: List<String>) {
        val resolution = authorityScopeResolution ?: return
        // The second command reads the client's current session: a reply
        // from before a switch would scope the new session by the old one.
        if (closed || purpose.transportGeneration != tmuxTransportGeneration ||
            resolution.transportGeneration != purpose.transportGeneration || resolution.id != purpose.resolution) return
        if (purpose.owner) {
            resolution.ownerDone = true
            resolution.ownerReply = lines.takeIf { success }
        } else {
            resolution.ownDone = true
            resolution.ownReply = lines.takeIf { success }
        }
        if (!resolution.ownerDone || !resolution.ownDone) return
        authorityOwnerSessionId = SharedTmuxCommands.authorityResolveOwner(resolution.ownerReply, resolution.ownReply)
        authorityScopeResolution = null
        diagnostics.record("tmux_authority_scope", mapOf(
            "detail" to "scope=${if (authorityOwnerSessionId == null) "own" else "owner"} reason=${if (authorityOwnerSessionId == null) "unresolved-group" else "group-owner"}",
            "transport" to diagnosticTransport,
        ))
        if (authoritySubscriptionRequested) sendTmuxAuthoritySubscription()
        val held = heldAuthorityQueryId
        heldAuthorityQueryId = null
        if (held != null && lastTmuxAuthorityResult?.currentQueryId == held) sendTmuxAuthorityQuery(held)
        val ordinary = heldOrdinaryAuthorityRead
        heldOrdinaryAuthorityRead = null
        if (ordinary != null && currentOrdinaryTmuxWindowRecovery(ordinary) != null &&
            !sendTmuxControl(SharedTmuxCommands.authorityQueryCommand(authorityOwnerSessionId),
                TmuxResponsePurpose.OrdinaryWindowAuthority(ordinary, authorityOwnerSessionId))) {
            finishOrdinaryTmuxWindowRecovery(ordinary)
        }
    }

    private fun sendTmuxAuthorityQuery(queryId: Long) {
        if (authorityScopeResolution != null) {
            heldAuthorityQueryId = queryId
            return
        }
        val query = TmuxResponsePurpose.AuthorityRederive(tmuxTransportGeneration, queryId,
            terminalSurface?.boundOwner, mutableTmuxSnapshot.value?.sessionId, authorityOwnerSessionId)
        pendingAuthorityQuery = query
        if (!sendTmuxControl(SharedTmuxCommands.authorityQueryCommand(authorityOwnerSessionId), query)) {
            if (pendingAuthorityQuery == query) pendingAuthorityQuery = null
            reduceTmuxAuthority { session, now -> session.queryFailed(now, queryId) }
        }
    }

    /** The client size this device would advertise now; null before the viewport is measured. */
    private fun currentTmuxAuthorityLocalSize(
        snapshot: SharedTmuxSnapshot? = mutableTmuxSnapshot.value,
    ): SharedTmuxGridSize? = lastTmuxViewport?.let { viewport ->
        if (tmuxGridPresentation == SharedTmuxGridPresentation.PANE_GRID) viewport
        else compactProjectedClientSize(snapshot, viewport)
    }

    private fun publishTmuxAuthorityPresentation(state: SharedTmuxAuthoritySessionState? = lastTmuxAuthorityResult) {
        val participates = tmuxAuthorityParticipates()
        val presentation = if (participates) state?.presentation?.forAndroid() ?: TmuxAuthorityPresentation.None else TmuxAuthorityPresentation.None
        tmuxInputGated = participates && state?.gatesTyping == true
        val previous = mutableTmuxAuthorityPresentation.value
        if (previous != presentation) mutableTmuxAuthorityPresentation.value = presentation
        if (previous != TmuxAuthorityPresentation.None && presentation == TmuxAuthorityPresentation.None && !restoreSelectionApplied) {
            scope.launch {
                synchronized(tmuxTransportLock) { if (!closed) mutableTmuxSnapshot.value?.let(::applyInitialTmuxSelection) }
            }
        }
    }

    private fun noteAuthorityIntentUserStep() {
        reduceTmuxAuthority { session, now -> session.userStep(now) }
    }

    private var authorityPromptScope: SharedTmuxAuthorityPromptScope? = null

    /** Prompt edges are captured synchronously, before the next intent deadline can decide. */
    private fun publishSessionState(state: SshSessionUiState) {
        mutableState.value = state
        synchronized(tmuxTransportLock) {
            val prompting = when (state) {
                is SshSessionUiState.AwaitingCredential -> SharedTmuxAuthorityPromptScope.SESSION
                is SshSessionUiState.AwaitingHostKey, is SshSessionUiState.AwaitingOwnerAuthorization -> SharedTmuxAuthorityPromptScope.CONNECT
                else -> null
            }
            if (authorityPromptScope == prompting) return
            val previous = authorityPromptScope
            authorityPromptScope = prompting
            previous?.let { scope -> reduceTmuxAuthority { session, now -> session.prompt(now, scope, false) } }
            prompting?.let { scope -> reduceTmuxAuthority { session, now -> session.prompt(now, scope, true) } }
        }
    }

    /** Only the shared deadline owns an authority wake. */
    private fun scheduleAuthorityWake(deadline: Long?) {
        if (authorityWakeDeadline == deadline && authorityWakeJob?.isActive == true) return
        authorityWakeJob?.cancel()
        authorityWakeDeadline = deadline
        // Publish the handle before starting: an already-due wake can tick
        // synchronously on Main.immediate and install the next wake itself.
        val wake = deadline?.let { due ->
            scope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
                delay((due - authorityNow()).coerceAtLeast(0))
                synchronized(tmuxTransportLock) {
                    if (closed || authorityWakeDeadline != due) return@synchronized
                    authorityWakeDeadline = null
                    authorityWakeJob = null
                    reduceTmuxAuthority { session, now -> session.tick(now) }
                }
            }
        }
        authorityWakeJob = wake
        wake?.start()
    }

    /**
     * Deduped in Kotlin: output-only batches never submit window or layout
     * facts. The window goes first. The compact projection is derived from
     * the same snapshot, and each submission is judged on its own, so a new
     * projection submitted against the old window could falsely match it and
     * release a held reply (the show it carried would end without a claim).
     * iOS reports in this order too: its projection follows the layout.
     */
    /** As the runtime derives them in its feed (`TmuxAuthorityGeometryEvidence.WindowFacts`). */
    private fun authorityWindowFacts(snapshot: SharedTmuxSnapshot?): Pair<Boolean, SharedTmuxAuthorityActiveWindow?> {
        val window = snapshot?.windows?.firstOrNull { it.id == snapshot.activeWindowId }
        return (snapshot?.isWindowListHydrated == true) to window?.let {
            SharedTmuxAuthorityActiveWindow(it.id, it.layout?.gridSize(), snapshot.isActiveWindowAuthoritative)
        }
    }

    private fun submitAuthorityGeometryFacts(snapshot: SharedTmuxSnapshot? = mutableTmuxSnapshot.value) {
        if (closed || !tmuxAuthorityParticipates()) return
        val facts = authorityWindowFacts(snapshot)
        if (lastAuthorityWindowFacts != facts) {
            lastAuthorityWindowFacts = facts
            reduceTmuxAuthority { session, now -> session.windowFacts(now, facts.first, facts.second) }
        }
        val local = currentTmuxAuthorityLocalSize(snapshot)
        // Reject collapsed measurements before submitting them to the core.
        if (local == null || (local.columns >= 4 && local.rows >= 4)) {
            if (!authorityLocalSizeSubmitted || lastAuthorityLocalSize != local) {
                authorityLocalSizeSubmitted = true
                lastAuthorityLocalSize = local
                reduceTmuxAuthority { session, now -> session.localSize(now, local) }
            }
        }
        submitAuthorityOrdinaryRecovery()
    }

    private fun submitAuthorityPaintability() {
        val paintable = appForeground && presentationActive && authorityRepaintSurfacesReady()
        if (lastAuthorityPaintable == paintable) return
        lastAuthorityPaintable = paintable
        reduceTmuxAuthority { session, now -> session.paintable(now, paintable) }
    }

    private fun submitAuthorityChannelLiveness() {
        val live = controlChannelLive()
        if (lastAuthorityChannelLive == live) return
        lastAuthorityChannelLive = live
        reduceTmuxAuthority { session, now -> session.channelLiveness(now, live) }
    }

    private fun submitAuthorityOrdinaryRecovery(proven: Boolean = false) {
        val active = presentedTmuxWindowRecoveryReserved || ordinaryTmuxWindowRecovery?.completed == false
        if (lastAuthorityOrdinaryRecovery == active) return
        lastAuthorityOrdinaryRecovery = active
        reduceTmuxAuthority { session, now -> session.ordinaryRecovery(now, active, proven) }
    }

    /** Bare client advertisement: no latest fence, window force or stamp. */
    private fun advertiseTmuxGeometryOnly(size: SharedTmuxGridSize? = currentTmuxAuthorityLocalSize()) = synchronized(tmuxTransportLock) {
        size ?: return@synchronized
        if (size.columns < 4 || size.rows < 4 || ordinaryTmuxGeometryWithheld() || liveAuthorityClaim() != null) return@synchronized
        reconcileLocalMoshCanvas(size)
        if (lastPublishedTmuxSize == size) return@synchronized
        val previousSize = lastPublishedTmuxSize
        noteDeliveredTmuxClientSize(size)
        if (ordinaryTmuxGeometryWithheld() || liveAuthorityClaim() != null) {
            if (lastPublishedTmuxSize == size && liveAuthorityClaim() == null) lastPublishedTmuxSize = previousSize
            noteWithheldTmuxClientSize(size, "shared session withholds geometry")
            return@synchronized
        }
        applyTmuxRenderLedgerOptions(tmuxRenderLedgerOptions(belongsToAuthorityClaim = true))
        if (!submitTmuxRenderFact(SharedTmuxRenderFact.ClientSize(size.columns, size.rows))) lastPublishedTmuxSize = previousSize
    }

    /**
     * A known session switch resets the authority session (§6.18): the old
     * session's stamp, claim and windows say nothing about the new one. As
     * at a transport attach (and as iOS's hydration does), forget the facts
     * reported for the old session and resolve the new one's scope before
     * its attach read can go out. The session forgot the window-size policy,
     * so the next snapshot probes it again even when a grouped session
     * shares the window. Caller holds the transport lock.
     */
    private fun beginTmuxAuthoritySessionSwitch(transportGeneration: Long) {
        resetAuthorityFactMemos()
        windowSizePolicyKnown = false
        windowSizePolicyIsLatest = false
        windowSizePolicyWindowId = null
        // A read the old resolution held is still the session's when the
        // switch itself issued none (a redelivered switch): it goes out
        // once the new scope resolves, if the session still awaits it.
        val held = heldAuthorityQueryId
        tmuxAuthorityOwnerSessionName?.let { beginTmuxAuthorityScopeResolution(it, transportGeneration) }
        if (authorityScopeResolution != null) heldAuthorityQueryId = held
        else if (held != null && heldAuthorityQueryId == null && lastTmuxAuthorityResult?.currentQueryId == held) sendTmuxAuthorityQuery(held)
    }

    /** After a switch's attach: hydrate and subscribe again. Caller holds the transport lock. */
    private fun finishTmuxAuthoritySessionSwitch() {
        submitAuthorityPaintability()
        lastAuthorityChannelLive = true
        SharedTmuxCommands.hydrationCommands().forEach { command -> sendTmuxControl(command, TmuxResponsePurpose.Ignore) }
        sendTmuxAuthoritySubscription()
    }

    private fun resetAuthorityFactMemos() {
        lastAuthorityWindowFacts = null
        lastAuthorityPaintable = null
        lastAuthorityChannelLive = null
        // resetTransport preserves local measurements, but clears recovery.
        lastAuthorityOrdinaryRecovery = false
        presentedTmuxWindowRecoveryReserved = false
    }

    private fun authorityNow(): Long = authorityTime()

    private fun tmuxAuthorityMutationRefusal(): String? = when {
        closed -> "closed"
        !tmuxAuthorityParticipates() -> null
        else -> lastTmuxAuthorityResult?.mutationRefusal?.wireValue
    }

    private fun recordAgentTmuxRefusal(verb: String, refusal: String) {
        diagnostics.record(
            "tmux_agent_command_refused",
            mapOf("detail" to "$verb $refusal", "transport" to diagnosticTransport),
        )
    }

    private fun commitTmuxGridAuthorityStamp(generation: Long) {
        if (!isLiveAuthorityClaim(generation)) return
        val stamp = tmuxAuthorityStampValue(tmuxDeviceIdentity.id, tmuxDeviceIdentity.displayName, generation)
        // The claim's target, not the local grid: churn while the stamp waits
        // is either advertised (visible) or held back (late).
        val commands = SharedTmuxCommands.authorityWriteCommands(stamp, authorityOwnerSessionId)
        if (!sendTmuxControl(commands.first(), TmuxResponsePurpose.AuthorityCommit(generation, authorityOwnerSessionId))) {
            abortTmuxGridAuthorityClaim(generation, "authority stamp unsent")
            return
        }
        commands.drop(1).forEach { sendTmuxControl(it, TmuxResponsePurpose.Ignore) }
    }

    private fun claimTmuxGridAuthority() {
        synchronized(tmuxTransportLock) {
            if (closed || takeBackRefusedOffScreen("command")) return
            submitAuthorityChannelLiveness()
            reduceTmuxAuthority { session, now -> session.requestTakeBack(now) }
        }
    }

    private fun beginTmuxGridAuthorityClaim(generation: Long) {
        if (tmuxConnection == null) {
            reduceTmuxAuthority { session, now -> session.abort(now, generation) }
            return
        }
        if (pendingAuthorityRepaintGeneration != null && pendingAuthorityRepaintGeneration != generation) {
            // A second gesture superseded a claim whose presentation had timed
            // out. Its repaint bookkeeping must neither complete the new
            // generation's chain nor keep an old forced frame admitted.
            clearAuthorityRepaintBookkeeping()
        }
        pendingAuthorityRepaintGeneration = generation
        resetAuthorityClaimGeometryState()
        // The claim decides authority itself. A read sent before it began
        // reports the stamp this claim is about to replace, so its reply is
        // dropped rather than allowed to re-veil a settled claim.
        pendingAuthorityQuery = null
        if (foregroundAuthorityClaimGeneration != generation) {
            foregroundAuthorityClaimGeneration = null
            foregroundAuthorityClaimOwner = null
        }
        // A reclaim is a geometry + repaint fence even when the target size did
        // not change: clearing the memo re-runs this device's geometry
        // bookkeeping (and the mosh window forces) for the claim. The
        // `refresh-client -C` itself goes out only if this connection's
        // client lacks the grid (P6); the claim's `latest` fence (inline) or
        // window forces (mosh) apply it, and its reply ack still follows
        // everything queued before it.
        lastPublishedTmuxSize = null
        restartCompactTmuxSizing()
        pendingTmuxWindowSizeReplays.clear()
        ordinaryTmuxWindowRecovery = null
        submitAuthorityOrdinaryRecovery()
        val forcedSize = if (tmuxGridPresentation == SharedTmuxGridPresentation.SINGLE_PANE) {
            // A reclaim re-asserts THIS device's grid. Republishing the peer's
            // server grid instead is what left a compact client permanently
            // rendering a scaled-down canvas after taking control back.
            lastTmuxViewport?.let { compactProjectedClientSize(mutableTmuxSnapshot.value, it) }
        } else {
            lastTmuxViewport
        }
        if (usesMoshPrimaryTransport()) {
            windowSizePolicyKnown = false
            windowSizePolicyWindowId = null
        }
        forcedSize?.let { publishTmuxClientSize(it, belongsToAuthorityClaim = true) }
        // Inline, the `latest` fence goes out in the same FIFO burst as the
        // replay. It used to wait one round trip (a `display-message` read of
        // the current window) so that a `select-window -t @W` built from a
        // pre-replay snapshot could not name a window the peer had already
        // left. The fence now names no window (W2): tmux resolves it to our
        // session's current window when it runs, so the hop had nothing left
        // to protect, and a take-back saves one round trip, as on iOS. The
        // mosh side channel's window forces are already queued; a no-op
        // `display-message` reply alone orders their confirmation after them.
        // Without a measured viewport or a known window the fence waits:
        // the snapshot that brings them sends it.
        sendTmuxGridAuthorityFence(generation, "begin")
    }

    /**
     * Sends the live claim a new fence on the session's current window, as
     * iOS's `queueGridClaimFenceSequence` does. The session opens it
     * (`claimFenceSent`, which retires every reply to an older fence); the
     * claim's own read of the window's `window-size` policy goes out behind
     * the geometry already queued, then the fence itself
     * ([sendTmuxGridAuthorityClaimFence]), all in one FIFO burst. Only a
     * claim awaiting its fence, with geometry of its own to fence and leave
     * to advertise it, sends one. With no window known yet the fence waits
     * for the snapshot that names one
     * ([fenceTmuxGridAuthorityClaimOnCurrentWindow]).
     *
     * `refresh-client -C` alone does not reliably transfer tmux's
     * `window-size latest` ownership: the recalculation follows the window's
     * latest-active client, and a control client that only refreshes never
     * becomes it — so a take-back can stamp, repaint and settle while the
     * window still sits at the peer's grid. A no-op `select-window` on the
     * *current* window does make this client latest, and the core's
     * targetless one ([tmuxLatestFenceCommand], the fence its inline replay
     * ends with) is always that: it can neither switch a window nor reach a
     * grouped sibling (W2). The mosh side channel includes that same fence
     * in its shared resize/fence/unset sequence, so the policy read behind
     * it sees the restored policy rather than the force's temporary one.
     * iOS follows the same command list.
     */
    private fun sendTmuxGridAuthorityFence(generation: Long, context: String) = synchronized(tmuxTransportLock) {
        if (!isLiveAuthorityClaim(generation) || lastTmuxAuthorityResult?.claimMayAdvertiseGeometry != true) return@synchronized
        val claim = liveAuthorityClaim() ?: return@synchronized
        if (claim.phase != SharedTmuxAuthorityClaimPhase.AWAITING_FENCE || claim.targetGrid == null) return@synchronized
        val windowId = mutableTmuxSnapshot.value?.activeWindowId ?: run {
            recordAuthorityClaimGeometry("fence-deferred", generation, context)
            sendTmuxControl("display-message -p ''", TmuxResponsePurpose.AuthorityClaimOrdering(generation))
            return@synchronized
        }
        reduceTmuxAuthority { session, now -> session.claimFenceSent(now, generation, windowId) }
        val fence = lastTmuxAuthorityResult?.claimFence
            ?.takeIf { it.generation == generation && it.windowId == windowId && isLiveAuthorityClaim(generation) }
            ?: return@synchronized
        // The replay's window force went out before this fence existed.
        reportAuthorityClaimFenceForce()
        if (!sendTmuxControl(
                "show-options -wA -v -t @$windowId window-size",
                TmuxResponsePurpose.AuthorityWindowSizePolicy(generation, fence.id, windowId),
            )
        ) {
            abortTmuxGridAuthorityClaim(generation, "claim window-size policy query unsent")
            return@synchronized
        }
        sendTmuxGridAuthorityClaimFence(generation, fence.id, windowId, refence = false)
    }

    /**
     * The command for the session's claim fence [fenceId] on [windowId]:
     * inline the targetless `latest` fence; on the side channel, whose
     * resize/fence/unset is already queued, a no-op `display-message` whose
     * reply alone orders the confirmation after it. Caller holds
     * [tmuxTransportLock].
     */
    private fun sendTmuxGridAuthorityClaimFence(generation: Long, fenceId: Long, windowId: Int, refence: Boolean) {
        val sideChannel = usesMoshPrimaryTransport()
        if (!sendTmuxControl(
                if (sideChannel) "display-message -p ''" else tmuxLatestFenceCommand(),
                TmuxResponsePurpose.AuthorityClaimFence(generation, fenceId, windowId, authorityClaimGeometryEpoch, refence),
            )
        ) {
            abortTmuxGridAuthorityClaim(generation, if (sideChannel) "geometry fence unsent" else "latest-client fence unsent")
        } else if (!sideChannel) {
            // The `latest` fence is a grid mutation (L2).
            authorityClaimWireGeneration = generation
        }
    }

    /**
     * Fences the live claim on the session's current window when it awaits
     * a fence it has not sent there, as iOS does on hydration and on
     * `%session-window-changed` (`refenceGridClaimIfCurrentWindowMoved`):
     * - none yet: its geometry went out before any window was known. A Mosh
     *   claim runs ahead of hydration by design; the window force that
     *   hydration just queued is the one this fence follows.
     * - one on a window the session has left (another client's
     *   `select-window`, or the fenced window closing). The fence made us
     *   `latest` on the window we left, so the claim would wait on a window
     *   it never fenced and linger. The target is advertised again first:
     *   the new window has not seen it land (§6.10). A late claim fences no
     *   other window (rule 2) and cannot finish on the one it fenced, so it
     *   ends (rule 6). The side channel's forces went to the window it left,
     *   so there a move stalls the claim ([validateAuthorityMoshGeometry]).
     * A claim already repainting is neither: its repaint targets fail
     * validation against the new window and abort it. Caller holds
     * [tmuxTransportLock].
     */
    private fun fenceTmuxGridAuthorityClaimOnCurrentWindow(snapshot: SharedTmuxSnapshot) {
        val claim = liveAuthorityClaim() ?: return
        if (claim.phase != SharedTmuxAuthorityClaimPhase.AWAITING_FENCE) return
        val target = claim.targetGrid ?: return
        val current = snapshot.activeWindowId ?: return
        val fence = lastTmuxAuthorityResult?.claimFence?.takeIf { it.generation == claim.generation }
        if (fence?.windowId == current) return
        val generation = claim.generation
        // A late claim that never fenced ends at its deadline (rule 6).
        if (fence == null) {
            sendTmuxGridAuthorityFence(generation, "window-known")
            return
        }
        if (usesMoshPrimaryTransport()) return
        if (authorityClaimLate()) {
            stallTmuxGridAuthorityClaim(generation, "current-window-moved", canProgress = false, fenceAgain = false)
            return
        }
        recordAuthorityClaimGeometry("refence-window-moved", generation, "from=${fence.windowId}")
        advertiseAuthorityClaimGeometry(generation, target)
        sendTmuxGridAuthorityFence(generation, "window-moved")
    }

    /**
     * Whether the claimed window is at the live claim's target, the grid it
     * last advertised while it could (§6.10 rule 3), as the session's fence
     * judges it: true under a policy the claim's fence read as not `latest`
     * on that window, where it never follows a client by design; false
     * when the fence's settle probe found it off target. Null while the
     * active window or its layout is unknown, and while the claim has no
     * target: a show claim before the viewport is measured, or one whose
     * presentation switched between single pane and grid. Allocation-free:
     * it runs for every runtime event while a claim waits.
     */
    private fun authorityClaimWindowAtTarget(snapshot: SharedTmuxSnapshot?): Boolean? {
        val claim = liveAuthorityClaim() ?: return null
        val requested = claim.targetGrid ?: return null
        val windows = snapshot?.windows ?: return null
        val activeWindowId = snapshot.activeWindowId ?: return null
        var window: SharedTmuxWindow? = null
        for (index in windows.indices) {
            if (windows[index].id == activeWindowId) {
                window = windows[index]
                break
            }
        }
        if (window == null) return null
        val fence = lastTmuxAuthorityResult?.claimFence?.takeIf { it.generation == claim.generation }
        if (fence?.windowId == activeWindowId && fence.policyIsLatest == false) return true
        if (fence?.probeOffTarget == true) return false
        val layout = window.layout ?: return null
        return layout.width == requested.columns && layout.height == requested.rows
    }

    /**
     * Asks the session to confirm the live claim's fence once a layout was
     * applied, as iOS's `confirmGridClaimIfSettled` does. The session
     * confirms by itself on the fence's acknowledgement, its policy read, a
     * proven force and a settle probe at the target; a layout reaching the
     * target is a window fact, and the render path must have it before the
     * repaint the confirmation requests. Checked here first, so the
     * per-snapshot path crosses JNI only when the fence has settled:
     * acknowledged, its policy read, and under `latest` its window at the
     * target with no probe off it and no force unproved
     * ([SharedTmuxAuthorityClaimFence]). Caller holds [tmuxTransportLock].
     */
    private fun confirmTmuxGridAuthorityClaim(snapshot: SharedTmuxSnapshot?) {
        val claim = liveAuthorityClaim() ?: return
        if (claim.phase != SharedTmuxAuthorityClaimPhase.AWAITING_FENCE) return
        val fence = lastTmuxAuthorityResult?.claimFence ?: return
        if (fence.generation != claim.generation || !fence.acknowledged) return
        val latest = fence.policyIsLatest ?: return
        if (latest && (fence.forceOutstanding || snapshot?.activeWindowId != fence.windowId ||
                authorityClaimWindowAtTarget(snapshot) != true)
        ) return
        reduceTmuxAuthority { session, now -> session.confirmClaimFence(now) }
    }

    /**
     * §6.10 rules 3–4: reports the claimed window at [size] to the core, which
     * tells this device's own geometry and a stale layout from a loss. Every
     * snapshot reports the active window's layout, and so does the repaint's
     * completion, the last point before the stamp; the settle probe reports
     * its answer ([settleProbe]), which marks the claim's geometry landed
     * first. Only on the window the claim's fence read a `latest` policy
     * for: under any other the size proves nothing. An unchanged size and
     * claim are not reduced again. A claim sent back to its fence phase
     * (unsettled, or lost and fencing again) stops counting the repaint in
     * flight, which shows a grid other than its target. Both control paths
     * report observations; the side channel also re-reads before stamping.
     * True when the claim left its repaint phase or ended. Caller holds
     * [tmuxTransportLock].
     */
    private fun observeAuthorityClaimWindow(
        windowId: Int,
        size: SharedTmuxGridSize,
        settleProbe: Boolean,
        context: String,
    ): Boolean {
        val claim = liveAuthorityClaim() ?: return false
        if (!claim.inGeometryPhase) return false
        if (!authorityClaimFenceIsLatestOn(windowId, claim.generation)) return false
        if (!settleProbe && lastAuthorityClaimObservation?.let { it.first == claim && it.second == size } == true) return false
        val generation = claim.generation
        reduceTmuxAuthority { session, now -> session.claimObservedGeometry(now, generation, size.columns, size.rows, settleProbe) }
        val after = liveAuthorityClaim()?.takeIf { it.generation == generation }
        lastAuthorityClaimObservation = after?.let { it to size }
        val leftRepaint = claim.phase == SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT &&
            after?.phase != SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT
        if (after == null || after.geometryRefenced != claim.geometryRefenced) {
            recordAuthorityClaimGeometry("lost", generation, context)
        } else if (leftRepaint) {
            recordAuthorityClaimGeometry("unsettled", generation, context)
        }
        if (after != null && leftRepaint) dropAuthorityClaimRepaint()
        return leftRepaint
    }

    /** The active window's layout, reported to a waiting claim. Caller holds [tmuxTransportLock]. */
    private fun observeAuthorityClaimLayout(snapshot: SharedTmuxSnapshot?, context: String): Boolean {
        val claim = liveAuthorityClaim() ?: return false
        if (!claim.inGeometryPhase) return false
        val window = snapshot?.activeWindow ?: return false
        if (!authorityClaimFenceIsLatestOn(window.id, claim.generation)) return false
        val layout = window.layout ?: return false
        // %output keeps this path allocation-free: compare the primitive
        // dimensions before constructing a grid or crossing the JSON ABI.
        val memo = lastAuthorityClaimObservation
        if (memo?.first == claim && memo.second.columns == layout.width && memo.second.rows == layout.height) return false
        return observeAuthorityClaimWindow(window.id, layout.gridSize(), settleProbe = false, context)
    }

    /**
     * The live claim's fence read a `latest` policy for [windowId]: only
     * then does that window's size say where the claim's geometry stands.
     * The read is the fence's own, queued behind the claim's geometry; a
     * cached policy can predate the claim (M4).
     */
    private fun authorityClaimFenceIsLatestOn(windowId: Int, generation: Long): Boolean =
        lastTmuxAuthorityResult?.claimFence?.let {
            it.generation == generation && it.windowId == windowId && it.policyIsLatest == true
        } == true

    /**
     * The live claim's fence read a policy other than `latest` for
     * [windowId]: the window never follows a client, so its size proves
     * nothing either way.
     */
    private fun authorityClaimPolicyIsFixed(windowId: Int, generation: Long): Boolean =
        lastTmuxAuthorityResult?.claimFence?.let {
            it.generation == generation && it.windowId == windowId && it.policyIsLatest == false
        } == true

    /**
     * §6.10 rule 2: a live claim whose presentation deadline passed. It
     * finishes on the geometry it already sent and advertises nothing more:
     * no client-size replay, fence, re-fence or window force. The core's own
     * predicate (`claimMayAdvertiseGeometry`), never `claim != null`.
     */
    private fun authorityClaimLate(): Boolean {
        val result = lastTmuxAuthorityResult ?: return false
        return result.claim != null && !result.claimMayAdvertiseGeometry
    }

    /** The claim this adapter runs ([pendingAuthorityRepaintGeneration]), as the core last reduced it. */
    private fun liveAuthorityClaim(): SharedTmuxAuthorityLifecycleClaim? {
        val generation = pendingAuthorityRepaintGeneration ?: return null
        return lastTmuxAuthorityResult?.claim?.takeIf { it.generation == generation }
    }

    private val SharedTmuxAuthorityLifecycleClaim.inGeometryPhase: Boolean
        get() = phase == SharedTmuxAuthorityClaimPhase.AWAITING_FENCE ||
            phase == SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT

    /**
     * The claim is back in its fence phase: the repaint in flight shows a
     * grid other than its target and no longer counts. Caller holds
     * [tmuxTransportLock].
     */
    private fun dropAuthorityClaimRepaint() {
        inlineAuthorityRepaintFence.reset()
        deferredAuthorityRepaintGeneration = null
        clearOutstandingAuthorityMoshRepaintIssue()
    }

    /** Caller holds [tmuxTransportLock]. */
    private fun noteAuthorityClaimCommandSent(generation: Long) {
        if (authorityClaimCommandsGeneration != generation) {
            authorityClaimCommandsGeneration = generation
            authorityClaimCommandsInFlight = 0
        }
        authorityClaimCommandsInFlight += 1
    }

    /** Caller holds [tmuxTransportLock]. */
    private fun noteAuthorityClaimReplyReceived(generation: Long) {
        if (authorityClaimCommandsGeneration == generation && authorityClaimCommandsInFlight > 0) {
            authorityClaimCommandsInFlight -= 1
        }
    }

    /**
     * The claim's own commands still awaiting replies: the counted ones, and
     * the side channel's window force for its target. Caller holds
     * [tmuxTransportLock].
     */
    private fun authorityClaimHasOwnCommandsInFlight(generation: Long): Boolean {
        if (authorityClaimCommandsGeneration == generation && authorityClaimCommandsInFlight > 0) return true
        if (liveAuthorityClaim()?.generation != generation) return false
        return pendingTmuxWindowSizeReplays.entries.any { (windowId, attempt) ->
            !attempt.confirmationAnswered && isAuthorityClaimForce(windowId, attempt)
        }
    }

    /**
     * A repaint [claim] asked for and has not yet consumed: the inline
     * fence's surfaces, or the side channel's frame, which is out from its
     * request in `awaitingRepaint` until its completion moves the claim on
     * or its failure ends it. A repaint deferred for a missing surface is
     * not in flight. Caller holds [tmuxTransportLock].
     */
    private fun authorityClaimRepaintInFlight(claim: SharedTmuxAuthorityLifecycleClaim): Boolean {
        if (inlineAuthorityRepaintFence.generation == claim.generation) return true
        return usesMoshPrimaryTransport() && claim.phase == SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT &&
            deferredAuthorityRepaintGeneration != claim.generation
    }

    /**
     * §6.10 rule 6 for a late claim: with no command of its own awaiting a
     * reply and no repaint in flight, nothing can confirm or repaint it any
     * more, so it ends now rather than waiting under the veil. Checked at the
     * deadline and after each of its own replies, which bounds a late claim
     * to the round trips already on the wire. Caller holds
     * [tmuxTransportLock].
     */
    private fun endTmuxGridAuthorityClaimIfStalledLate(context: String) {
        val claim = liveAuthorityClaim() ?: return
        if (claim.presentationVisible || !claim.inGeometryPhase) return
        if (authorityClaimHasOwnCommandsInFlight(claim.generation) || authorityClaimRepaintInFlight(claim)) return
        stallTmuxGridAuthorityClaim(claim.generation, "late-$context", canProgress = false, fenceAgain = false)
    }

    /**
     * §6.10 rule 6: the claim cannot progress as it stands. The core sends a
     * visible claim that a new fence can still move ([canProgress]) back to
     * its fence phase, where it fences again ([fenceAgain]) or waits for its
     * next observation; anything else ends as an adapter failure, which
     * replays the gesture under R3 (§6.9). Caller holds [tmuxTransportLock].
     */
    private fun stallTmuxGridAuthorityClaim(
        generation: Long,
        context: String,
        canProgress: Boolean,
        fenceAgain: Boolean,
    ) {
        diagnostics.record(
            "tmux_authority_claim_stalled",
            mapOf("detail" to "g$generation $context canProgress=$canProgress", "transport" to diagnosticTransport),
        )
        reduceTmuxAuthority { session, now -> session.claimStalled(now, generation, canProgress) }
        val claim = liveAuthorityClaim()?.takeIf { it.generation == generation } ?: return
        if (claim.phase != SharedTmuxAuthorityClaimPhase.AWAITING_FENCE) return
        dropAuthorityClaimRepaint()
        // A new fence, as iOS's: the stalled one's settlement is spent.
        if (fenceAgain) sendTmuxGridAuthorityFence(generation, "stalled")
    }

    /**
     * §6.10 rule 3: a grid the live claim advertised, recorded so its echo is
     * never a loss. The begin replay sets the target; local churn while the
     * claim is visible re-targets it, which drops its fence in the core; its
     * caller then sends a fence after the ledger's `-C` (which carries none
     * while a claim runs). A confirmed claim returns to its fence phase and
     * drops the repaint in flight, which shows the old grid. In the stamp
     * phases the grid is only recorded. A late claim advertises nothing: its
     * sizes are withheld before they get here. Caller holds
     * [tmuxTransportLock].
     */
    private fun noteAuthorityClaimAdvertised(size: SharedTmuxGridSize) {
        val claim = liveAuthorityClaim() ?: return
        if (lastTmuxAuthorityResult?.claimMayAdvertiseGeometry != true) return
        val generation = claim.generation
        advertiseAuthorityClaimGeometry(generation, size)
        val after = liveAuthorityClaim()?.takeIf { it.generation == generation } ?: return
        if (claim.phase == SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT &&
            after.phase == SharedTmuxAuthorityClaimPhase.AWAITING_FENCE
        ) {
            recordAuthorityClaimGeometry("re-targeted", generation, "${size.columns}x${size.rows}")
            dropAuthorityClaimRepaint()
        }
    }

    /**
     * Record before reducing: its synchronous effects may end this claim. A
     * settle probe written for earlier geometry no longer answers. Caller
     * holds the lock.
     */
    private fun advertiseAuthorityClaimGeometry(generation: Long, size: SharedTmuxGridSize) {
        authorityClaimGeometryEpoch += 1
        reduceTmuxAuthority { session, now -> session.claimAdvertisedGeometry(now, generation, size.columns, size.rows) }
    }

    /**
     * §6.10 rule 5: once claim fence [fenceId] is acknowledged, read the
     * fenced window's size in a write of its own. tmux delivers the fence's
     * `%layout-change` before this reply (verified on 3.4 and 3.6a), so the
     * size shows where the claim's geometry landed: from then on a size the
     * claim never advertised is a loss, not a stale layout, and how fast
     * Main drains no longer decides that (M1). Confirmation never waits for
     * it. Under a policy the fence read as not `latest` a size proves
     * nothing, so none is read. A newer fence or claim geometry makes the
     * answer moot. Caller holds [tmuxTransportLock].
     */
    private fun sendTmuxGridAuthoritySettleProbe(generation: Long, fenceId: Long, windowId: Int) {
        val claim = liveAuthorityClaim()?.takeIf { it.generation == generation && it.inGeometryPhase } ?: return
        if (claim.targetGrid == null || lastTmuxAuthorityResult?.claimFence?.policyIsLatest == false) return
        if (mutableTmuxSnapshot.value?.activeWindowId != windowId) return
        sendTmuxControl(
            tmuxWindowForceRule.sizeQuery(windowId),
            TmuxResponsePurpose.AuthoritySettleSize(generation, fenceId, windowId, authorityClaimGeometryEpoch),
        )
    }

    /**
     * The core's one re-fence for a claim whose landed geometry another
     * client took (§6.10 rule 4), as iOS's
     * `refenceGridClaimAfterGeometryLoss`: only the fence goes out again,
     * under the same session fence and queued under the lock like the first.
     * Inline that is the targetless `latest` fence (W2); on the side
     * channel the window force at the target goes first, even over a layout
     * that still shows it (a settle probe can find the loss before its
     * notification). The fenced window's policy is already read and the
     * acknowledgement stands, so confirmation needs only the window back
     * at the target; this fence's own settle probe lands it again. The
     * repaint confirmation then requests queues behind it.
     */
    private fun refenceTmuxGridAuthorityClaim(generation: Long) {
        val claim = liveAuthorityClaim()?.takeIf { it.generation == generation } ?: return
        if (lastTmuxAuthorityResult?.claimMayAdvertiseGeometry != true) return
        val fence = lastTmuxAuthorityResult?.claimFence?.takeIf { it.generation == generation } ?: return
        if (mutableTmuxSnapshot.value?.activeWindowId != fence.windowId) return
        recordAuthorityClaimGeometry("refence", generation, "core")
        authorityClaimGeometryEpoch += 1
        if (usesMoshPrimaryTransport()) {
            val target = claim.targetGrid ?: return
            pendingTmuxWindowSizeReplays.remove(fence.windowId)
            forceTmuxWindowSizesImpl(target, belongsToAuthorityClaim = true, onlyWindowId = null, ordinaryProofToken = null, evenIfLayoutMatches = true)
        }
        sendTmuxGridAuthorityClaimFence(generation, fence.id, fence.windowId, refence = true)
    }

    private fun recordAuthorityClaimGeometry(stage: String, generation: Long, context: String) {
        val window = mutableTmuxSnapshot.value?.let { snapshot ->
            snapshot.windows.firstOrNull { it.id == snapshot.activeWindowId }
        }
        diagnostics.record(
            "tmux_authority_claim_geometry",
            mapOf(
                "detail" to "$stage g$generation window=${window?.id ?: "-"} " +
                    "layout=${window?.layout?.let { "${it.width}x${it.height}" } ?: "-"} " +
                    "local=${lastPublishedTmuxSize?.let { "${it.columns}x${it.rows}" } ?: "-"} context=$context",
                "transport" to diagnosticTransport,
            ),
        )
    }

    /**
     * The side channel's claim stalls when the session's current window is
     * no longer the one its fence named: its force and settle probe went to
     * that window. Before its repaint completes, a confirmed claim's layout
     * is observed once more. False when the claim cannot go on as it
     * stands. Caller holds [tmuxTransportLock].
     */
    private fun validateAuthorityMoshGeometry(snapshot: SharedTmuxSnapshot?): Boolean {
        if (!usesMoshPrimaryTransport()) return true
        val claim = liveAuthorityClaim() ?: return true
        val fence = lastTmuxAuthorityResult?.claimFence?.takeIf { it.generation == claim.generation } ?: return true
        val window = snapshot?.activeWindow ?: return true
        if (window.id != fence.windowId) {
            stallTmuxGridAuthorityClaim(claim.generation, "mosh-window-moved", canProgress = false, fenceAgain = false)
            return false
        }
        if (claim.phase != SharedTmuxAuthorityClaimPhase.AWAITING_FENCE && observeAuthorityClaimLayout(snapshot, "mosh-repaint")) return false
        return liveAuthorityClaim()?.phase == claim.phase
    }

    private fun beginTmuxGridAuthorityRepaint(generation: Long) {
        if (!isLiveAuthorityClaim(generation)) return
        val activePaneKnown = mutableTmuxSnapshot.value?.activePaneId != null
        if (usesMoshPrimaryTransport()) {
            inlineAuthorityRepaintFence.reset()
            deferredAuthorityRepaintGeneration = null
            // A hydrated active pane and a bound painter owner are not
            // prerequisites here: Mosh paints the whole PTY, so the forced
            // frame goes through the untagged painter feed exactly like every
            // other frame before the first bind. Aborting for a missing owner
            // is what left a freshly launched phone veiled behind a departed
            // peer's stamp with nothing left to retry.
            //
            // The declared surface *is* one, though: the reservation belongs to
            // the ledger and is held per surface, so the live surface has to
            // exist there before one can be taken against it. Compose declares
            // it after the snapshot that creates it and the initial-attach
            // claim deliberately runs ahead of both, so reserving anyway would
            // be refused as "unknown-surface" and abort the launch claim. The
            // next declaration re-enters this phase.
            if (declaredTmuxRenderSurfaces.none { it.surfaceId == TMUX_RENDER_LIVE_SURFACE_ID }) {
                deferTmuxGridAuthorityRepaint(generation, "live render surface undeclared")
                return
            }
            // Mosh owns the visible viewport; there is no inline capture to
            // commit. Its ledger profile will rebuild history on demand.
            // An unchanged foreground owner can repaint its live tail under
            // the reader's retained transcript without taking them to the
            // bottom. A geometry rebind changes the owner epoch and retires
            // that history through the normal ledger path.
            val preservesForegroundHistory = foregroundAuthorityClaimGeneration == generation &&
                foregroundAuthorityClaimOwner != null &&
                terminalSurface?.boundOwner == foregroundAuthorityClaimOwner
            if (!preservesForegroundHistory) retireVisibleMoshHistoryForAuthoritativeRepaint()
            // The reservation itself belongs to the ledger, not here: the
            // ledger is what rebinds surfaces and advances owner epochs, so it
            // is what must decide whether a frame reserved against the owner it
            // is replacing is re-issued or failed. That rule used to live here
            // *and*, separately, in the Apple controller -- which got it wrong
            // and aborted every Mosh take-back on the claim's own geometry
            // force. What stays on this side is the *issue*: a request id, the
            // painter handoff that adopts it, and the exact delivery receipt.
            if (!submitTmuxRenderFact(
                    SharedTmuxRenderFact.CorrelatedTransportFullFrameRequested(
                        surfaceId = TMUX_RENDER_LIVE_SURFACE_ID,
                        reason = "authority-reclaim",
                        correlation = generation,
                    ),
                )
            ) abortTmuxGridAuthorityClaim(generation, "ledger transport frame request unsent")
            return
        }
        // The inline path captures the active pane into mounted surfaces, so
        // it does need both; Compose declares them after the snapshot that
        // created them and the next snapshot or declaration re-enters here.
        if (!activePaneKnown) {
            deferTmuxGridAuthorityRepaint(generation, "active pane unavailable")
            return
        }
        val targets = inlineAuthorityRepaintTargets()
        // P8: unveil on visible rows. A deep capture of 2,000 rows used to sit
        // between the fence and the stamp on every take-back. A surface this
        // connection already painted with its pane is refreshed in place at
        // visible rows instead; the ledger rebuilds it, and deepens its
        // history once no peer holds the grid, if a relayout went by while
        // yielded. A surface with no frame of its pane yet keeps the deep
        // capture: that is its first fill, the only one that gives it history.
        val firstFills = targets.filterNot { target ->
            renderSurfaceForId(target.surfaceId)?.boundOwner?.let {
                it.windowId == target.windowId && it.paneId == target.paneId &&
                    it.transportGeneration == tmuxTransportGeneration
            } == true
        }.mapTo(mutableSetOf(), InlineAuthorityRepaintTarget::surfaceId)
        if (!inlineAuthorityRepaintFence.begin(generation, targets, firstFills)) {
            // Compose declares its surfaces after the snapshot that created
            // them; the next declaration re-enters this phase.
            deferTmuxGridAuthorityRepaint(generation, "no mounted render surfaces")
            return
        }
        deferredAuthorityRepaintGeneration = null
        recordAuthorityRepaint("requested", generation, "surfaces=${targets.size} firstFills=${firstFills.size}")
        for (target in targets) {
            if (!submitTmuxRenderFact(
                    SharedTmuxRenderFact.CorrelatedRefreshRequested(
                        surfaceId = target.surfaceId,
                        stage = inlineAuthorityRepaintFence.stage(target.surfaceId),
                        reason = "authority-reclaim",
                        correlation = generation,
                    ),
                )
            ) {
                inlineAuthorityRepaintFence.reset()
                abortTmuxGridAuthorityClaim(generation, "ledger repaint request unsent")
                return
            }
        }
    }

    /**
     * The repaint waits for a missing prerequisite, which the next snapshot
     * or surface declaration supplies. A late claim waits only while its own
     * replies are still coming (§6.10 rule 6): a surface that never comes
     * back would otherwise hold the veil. Caller holds [tmuxTransportLock].
     */
    private fun deferTmuxGridAuthorityRepaint(generation: Long, detail: String) {
        deferredAuthorityRepaintGeneration = generation
        recordAuthorityRepaint("deferred", generation, detail)
        endTmuxGridAuthorityClaimIfStalledLate("repaint-deferred")
    }

    /**
     * Re-enters the repaint phase of a claim that deferred for a missing
     * prerequisite. Driven by geometry edges that can supply the inline
     * path's active pane, and by a surface declaration (inline
     * targets, and the live surface the Mosh reservation is taken against).
     * Once reserved, the Mosh path defers no further: the ledger owns the
     * reservation and re-issues it on the bind that adopts the new owner.
     */
    private fun redriveDeferredAuthorityRepaint(source: String) {
        val generation = deferredAuthorityRepaintGeneration ?: return
        val claim = lastTmuxAuthorityResult?.claim
        if (pendingAuthorityRepaintGeneration != generation || claim?.generation != generation) {
            deferredAuthorityRepaintGeneration = null
            return
        }
        if (claim.phase != com.bambouville.tessera.core.bridge.SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT) return
        // Only the inline path captures the active pane; the Mosh claim runs
        // ahead of hydration by design and waits on the declaration alone.
        if (usesMoshPrimaryTransport()) {
            if (declaredTmuxRenderSurfaces.none { it.surfaceId == TMUX_RENDER_LIVE_SURFACE_ID }) return
        } else if (mutableTmuxSnapshot.value?.activePaneId == null || inlineAuthorityRepaintTargets().isEmpty()) return
        recordAuthorityRepaint("redrive", generation, source)
        beginTmuxGridAuthorityRepaint(generation)
    }

    private fun recordAuthorityRepaint(stage: String, generation: Long, detail: String) {
        diagnostics.record(
            "tmux_authority_repaint",
            mapOf("detail" to "$stage g$generation $detail", "transport" to diagnosticTransport),
        )
    }

    private fun RenderOwner?.traceLabel(): String = this?.let {
        "window=${it.windowId} pane=${it.paneId} epoch=${it.epoch} generation=${it.transportGeneration}"
    } ?: "owner=none"

    private fun completeAuthorityMoshRepaintIfReady() {
        val pending = pendingAuthorityMoshRepaintTarget ?: return
        if (authorityMoshRepaintOwner != pending.owner || terminalSurface?.boundOwner != pending.owner) {
            failOutstandingAuthorityMoshRepaint("mosh render owner changed before exact repaint receipt")
            return
        }
        val accepted = authorityMoshAcceptedDelivery
            ?.takeIf { it.first == pending.requestId }
            ?.second
            ?: return
        if (accepted != pending.outputTarget) return
        val ledgerOwner = authorityMoshRepaintLedgerOwner
        clearOutstandingAuthorityMoshRepaintIssue()
        // Acceptance is reported to the ledger, which holds the reservation and
        // is therefore the only thing that can say whether this frame still
        // authorises anything; `transportFullFrameCompleted` comes back and
        // settles the claim.
        submitTmuxRenderFact(
            SharedTmuxRenderFact.TransportFullFramePresented(
                surfaceId = TMUX_RENDER_LIVE_SURFACE_ID,
                owner = ledgerOwner,
                correlation = pending.claimGeneration,
            ),
        )
    }

    /**
     * True while [generation] is still the claim the chain is running for.
     * Only `AuthorityCommit` used to check this, so an aborted or superseded
     * claim still walked all the way to writing its stamp — overwriting the
     * peer verdict the abort had just accepted.
     */
    private fun isLiveAuthorityClaim(generation: Long): Boolean =
        pendingAuthorityRepaintGeneration == generation &&
            lastTmuxAuthorityResult?.claim?.generation == generation

    /**
     * Whether a replayed claim's repaint could run now: the same surfaces the
     * repaint phase waits for (the live surface for Mosh, any mounted one
     * inline), on an attached terminal. (The foreground is checked apart.)
     */
    private fun authorityRepaintSurfacesReady(): Boolean =
        terminalSurface != null && if (usesMoshPrimaryTransport()) {
            declaredTmuxRenderSurfaces.any { it.surfaceId == TMUX_RENDER_LIVE_SURFACE_ID }
        } else {
            declaredTmuxRenderSurfaces.isNotEmpty()
        }

    private fun abortTmuxGridAuthorityClaim(generation: Long, detail: String) {
        if (!isLiveAuthorityClaim(generation)) return
        // Recorded first: the abort can replay the gesture inline, and the
        // log should read failure, then replay.
        diagnostics.record(
            "tmux_authority_claim_failed",
            mapOf("detail" to detail, "transport" to diagnosticTransport),
        )
        reduceTmuxAuthority { session, now -> session.abort(now, generation) }
    }

    private fun clearAuthorityRepaintBookkeeping() {
        resetAuthorityClaimGeometryState()
        pendingAuthorityPaintGeometry = null
        inlineAuthorityRepaintFence.reset()
        deferredAuthorityRepaintGeneration = null
        clearOutstandingAuthorityMoshRepaintIssue()
    }

    /**
     * Forgets the §6.10 bookkeeping of the claim that ended or is replaced:
     * its commands in flight and the observation memo. What its fences
     * proved ends with the claim in the session. Caller holds
     * [tmuxTransportLock].
     */
    private fun resetAuthorityClaimGeometryState() {
        authorityClaimCommandsInFlight = 0
        authorityClaimCommandsGeneration = null
        lastAuthorityClaimObservation = null
    }

    private fun finishAbortedTmuxGridAuthorityClaim() {
        foregroundAuthorityClaimGeneration = null
        foregroundAuthorityClaimOwner = null
        pendingAuthorityRepaintGeneration = null
        clearAuthorityRepaintBookkeeping()
    }

    private fun settleTmuxGridAuthority(generation: Long) {
        if (!isLiveAuthorityClaim(generation)) return
        reduceTmuxAuthority { session, now -> session.settle(now, generation) }
    }

    private fun complete(receipt: SharedSessionCommandReceipt?, failureCode: String?) {
        if (receipt == null) return
        emitSharedIfOpen {
            emitCommandCompleted(
                SharedSessionCommandCompletion(
                    receipt,
                    if (failureCode == null) SharedSessionCommandResult.Succeeded
                    else SharedSessionCommandResult.Failed(
                        com.bambouville.tessera.core.bridge.SharedSessionFailure(failureCode),
                    ),
                ),
            )
        }
    }

    /**
     * Select a tmux window on the metadata client and, for mosh+tmux, begin a
     * proof that lets the same intent be mirrored to the pixel-producing PTY
     * client. Each proof stage starts only after the previous command succeeds;
     * Agent focus therefore cannot report success when the metadata client
     * rejected its selection but the visible client happened to move.
     */
    private fun selectTmuxWindow(
        target: String,
        agentResponse: CompletableDeferred<AgentTmuxControlAck>? = null,
    ): Boolean {
        val windowId = TmuxVisibleClientSelection.windowId(target)
        if (windowId == null) {
            agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            diagnostics.record(
                "tmux_visible_selection_skipped",
                mapOf("detail" to "invalid window target", "transport" to diagnosticTransport),
            )
            return false
        }
        // W2: name our own session. A bare `@W` resolves to the most recently
        // active session holding W, which in a group is often a sibling (the
        // mosh view session, a user's `tmux new -t`), so the switch would land
        // on someone else's screen. Fails open to the bare spelling only
        // before `%session-changed` names our session, as on iOS.
        return selectTmuxAcrossClients(
            windowId = windowId,
            paneId = null,
            preservingWindowZoom = false,
            primaryCommand = tmuxWindowSelectionCommand(windowId, mutableTmuxSnapshot.value?.sessionId),
            agentResponse = agentResponse,
        )
    }

    private fun beginTmuxWindowReorder(windowId: Int, destination: Int) {
        var failure: String? = null
        synchronized(tmuxTransportLock) {
            tmuxWindowMutationError = null
            val snapshot = mutableTmuxSnapshot.value
            val tmux = tmuxConnection
            val runtime = tmuxCore
            if (!isTmuxWindowMutationAvailable(snapshot) || tmux == null || runtime == null) {
                failure = "Window ordering is not available yet."
                return@synchronized
            }
            val sessionId = snapshot!!.sessionId
            val capabilities = snapshot.capabilities
            val activeWindowId = snapshot.activeWindowId
            if (sessionId == null || capabilities == null || activeWindowId == null) {
                failure = "Window ordering is not hydrated yet."
                return@synchronized
            }
            val plan = SharedTmuxCommands.windowReorderPlan(
                order = snapshot.windows.map { it.id },
                moving = windowId,
                destination = destination,
                capabilities = capabilities,
                sessionId = sessionId,
                activeWindowId = null,
                highestIndex = snapshot.windows.mapNotNull { it.index }.maxOrNull(),
            )
            if (plan == null) {
                failure = "That window move is no longer valid."
                return@synchronized
            }
            if (plan.commands.isEmpty()) {
                updateTmuxWindowMutationState(snapshot)
                return
            }
            beginTmuxWindowMutationLocked(
                kind = TmuxWindowMutationKind.REORDER,
                expectedOrder = plan.expectedOrder,
                sessionName = snapshot.sessionName!!,
                tmux = tmux,
                runtime = runtime,
                commands = plan.commands,
            )
        }
        failure?.let(::publishTmuxWindowMutationError)
    }

    private fun beginTmuxWindowRenumber() {
        var failure: String? = null
        synchronized(tmuxTransportLock) {
            tmuxWindowMutationError = null
            val snapshot = mutableTmuxSnapshot.value
            val tmux = tmuxConnection
            val runtime = tmuxCore
            if (!isTmuxWindowMutationAvailable(snapshot) || tmux == null || runtime == null) {
                failure = "Window ordering is not available yet."
                return@synchronized
            }
            beginTmuxWindowMutationLocked(
                kind = TmuxWindowMutationKind.RENUMBER,
                expectedOrder = snapshot!!.windows.map { it.id },
                sessionName = snapshot.sessionName!!,
                tmux = tmux,
                runtime = runtime,
                commands = emptyList(),
            )
        }
        failure?.let(::publishTmuxWindowMutationError)
    }

    /** Caller holds [tmuxTransportLock]. */
    private fun beginTmuxWindowMutationLocked(
        kind: TmuxWindowMutationKind,
        expectedOrder: List<Int>,
        sessionName: String,
        tmux: SshTmuxConnection,
        runtime: SharedTmuxRuntime,
        commands: List<String>,
    ) {
        if (tmuxWindowMutationToken == Long.MAX_VALUE) {
            publishTmuxWindowMutationError("Window ordering token space is exhausted for this connection.")
            return
        }
        tmuxWindowMutationToken += 1
        val token = tmuxWindowMutationToken
        val generation = tmuxTransportGeneration
        pendingTmuxWindowMutation = PendingTmuxWindowMutation(
            token = token,
            kind = kind,
            expectedOrder = expectedOrder,
            sourceOrder = mutableTmuxSnapshot.value?.authoritativeWindowOrder.orEmpty(),
            sessionName = sessionName,
            tmux = tmux,
            runtime = runtime,
            transportGeneration = generation,
            commands = commands,
        )
        mutableTmuxWindowMutationState.value = TmuxWindowMutationState.Pending
        if (runtime.submitFact(SharedTmuxRenderFact.ReorderBegan(token, expectedOrder)) != CoreCallResult.Accepted) {
            pendingTmuxWindowMutation = null
            publishTmuxWindowMutationError("Window ordering could not start.")
            return
        }
        armTmuxWindowMutationDeadlineLocked(token)

        val accepted = enqueueTmuxPlatformCommand(
            TmuxControlCommand(
                SharedTmuxCommands.sessionGroupQueryCommand(),
                TmuxResponsePurpose.WindowMutationGroupMembers(token),
            ),
        )
        if (!accepted) {
            abandonTmuxWindowMutationLocked(token, "The tmux control path is unavailable.")
        }
    }

    private fun armTmuxWindowMutationDeadlineLocked(token: Long) {
        val pending = currentTmuxWindowMutationLocked(token) ?: return
        pending.timeoutJob?.cancel()
        val timeout = scope.launch {
            delay(TMUX_WINDOW_MUTATION_TIMEOUT_MILLIS)
            abandonTmuxWindowMutation(token, "Window ordering timed out.")
        }
        pendingTmuxWindowMutation = pending.copy(timeoutJob = timeout)
    }

    /**
     * Admit the complete mutation and restore suffix through the ordered core
     * wire stream. The outer lock and nonreactive platform callbacks keep all
     * admissions adjacent while preserving each command's correlation tag.
     * The five-second UI deadline may abandon optimism while replies are late;
     * the already-written restore suffix still repairs every group member.
     * Caller holds [tmuxTransportLock].
     */
    private fun enqueueTmuxWindowMutationBatchLocked(token: Long): Boolean {
        val pending = currentTmuxWindowMutationLocked(token) ?: return false
        if (tmuxCommandChannel == null || activeTmuxResponses == null) return false
        if (pending.commands.isEmpty()) return false
        for ((index, command) in pending.commands.withIndex()) {
            if (currentTmuxWindowMutationLocked(token) == null || !enqueueTmuxPlatformCommand(
                    TmuxControlCommand(command, TmuxResponsePurpose.WindowMutationCommand(token, index)),
                )) {
                // Earlier admissions may already have deferred wire callbacks
                // behind ledger writes, so they are not a cancellable suffix.
                pending.tmux.close()
                return false
            }
        }
        return true
    }

    private fun handleTmuxWindowMutationCommand(
        purpose: TmuxResponsePurpose.WindowMutationCommand,
        success: Boolean,
    ) {
        synchronized(tmuxTransportLock) {
            val pending = currentTmuxWindowMutationLocked(purpose.token) ?: return
            if (purpose.commandIndex != pending.nextCommandIndex) return
            val next = purpose.commandIndex + 1
            val mutationFailed = !success && purpose.commandIndex < pending.mutationCommandCount
            if (!success && !mutationFailed) diagnostics.record("tmux_window_selection_restore_failed", mapOf("command" to pending.commands[purpose.commandIndex]))
            if (next < pending.commands.size) {
                pendingTmuxWindowMutation = pending.copy(
                    nextCommandIndex = next,
                    hadFailure = pending.hadFailure || mutationFailed,
                )
                return
            }
            if (pending.hadFailure || mutationFailed) {
                abandonTmuxWindowMutationLocked(purpose.token, "tmux only partially updated the window order.")
                return
            }
            pendingTmuxWindowMutation = pending.copy(nextCommandIndex = next, awaitingTruth = true)
            if (pending.runtime.submitFact(SharedTmuxRenderFact.ReorderConfirmed(purpose.token)) != CoreCallResult.Accepted) {
                abandonTmuxWindowMutationLocked(purpose.token, "Window order confirmation failed.")
                return
            }
            armTmuxWindowMutationDeadlineLocked(purpose.token)
            finishTmuxWindowMutationIfAuthoritativeLocked(mutableTmuxSnapshot.value)
        }
    }

    private fun handleTmuxWindowMutationGroupMembers(
        purpose: TmuxResponsePurpose.WindowMutationGroupMembers,
        success: Boolean,
        lines: List<String>,
    ) {
        synchronized(tmuxTransportLock) {
            val pending = currentTmuxWindowMutationLocked(purpose.token) ?: return
            val attachedSessionId = mutableTmuxSnapshot.value?.sessionId
            val members = if (success && attachedSessionId != null) {
                SharedTmuxCommands.sessionGroupMembers(lines, attachedSessionId)
            } else null
            if (members.isNullOrEmpty() || attachedSessionId == null) {
                abandonTmuxWindowMutationLocked(purpose.token, "tmux session membership is unavailable.")
                return
            }
            if (pending.kind == TmuxWindowMutationKind.REORDER &&
                mutableTmuxSnapshot.value?.authoritativeWindowOrder != pending.sourceOrder) {
                abandonTmuxWindowMutationLocked(purpose.token, "The window order changed. Try again.")
                return
            }
            val grouped = SharedTmuxCommands.renumberPlan(members, attachedSessionId)
            if (grouped == null) {
                abandonTmuxWindowMutationLocked(purpose.token, "tmux could not preserve grouped selections.")
                return
            }
            val mutations = if (pending.kind == TmuxWindowMutationKind.RENUMBER) grouped.mutationCommands else pending.commands
            val commands = mutations + grouped.selectionRestoreCommands
            if (mutableTmuxAuthority.value is SharedTmuxGridAuthoritySnapshot.Peer) {
                abandonTmuxWindowMutationLocked(purpose.token, "Another device controls this tmux session.")
                return
            }
            pendingTmuxWindowMutation = pending.copy(
                commands = commands,
                mutationCommandCount = mutations.size,
                mutationStarted = true,
            )
            armTmuxWindowMutationDeadlineLocked(purpose.token)
            if (!enqueueTmuxWindowMutationBatchLocked(purpose.token)) {
                abandonTmuxWindowMutationLocked(purpose.token, "The tmux control path is unavailable.")
            }
        }
    }

    private fun currentTmuxWindowMutationLocked(token: Long): PendingTmuxWindowMutation? {
        val pending = pendingTmuxWindowMutation?.takeIf { it.token == token } ?: return null
        return pending.takeIf {
            TmuxWindowMutationContext.isCurrent(
                closed = closed,
                expectedConnection = it.tmux,
                expectedRuntime = it.runtime,
                expectedGeneration = it.transportGeneration,
                expectedSession = it.sessionName,
                currentConnection = tmuxConnection,
                currentRuntime = tmuxCore,
                currentGeneration = tmuxTransportGeneration,
                currentSession = mutableTmuxSnapshot.value?.sessionName,
            )
        }
    }

    private fun abandonTmuxWindowMutation(token: Long, message: String) {
        synchronized(tmuxTransportLock) { abandonTmuxWindowMutationLocked(token, message) }
    }

    /** Caller holds [tmuxTransportLock]. */
    private fun abandonTmuxWindowMutationLocked(token: Long, message: String) {
        val pending = pendingTmuxWindowMutation?.takeIf { it.token == token } ?: return
        pending.timeoutJob?.cancel()
        if (tmuxCore === pending.runtime) {
            pending.runtime.submitFact(SharedTmuxRenderFact.ReorderAbandoned(token))
        }
        pendingTmuxWindowMutation = null
        tmuxWindowMutationError = message
        mutableTmuxWindowMutationState.value = TmuxWindowMutationState.Error(message)
        requestTmuxOrderRefreshLocked()
        diagnostics.record(
            "tmux_window_mutation_failed",
            mapOf("detail" to message, "transport" to diagnosticTransport),
        )
    }

    /** Caller holds [tmuxTransportLock]. */
    private fun requestTmuxOrderRefreshLocked() {
        val command = SharedTmuxCommands.hydrationCommands().firstOrNull() ?: return
        enqueueTmuxPlatformCommand(TmuxControlCommand(command, TmuxResponsePurpose.Ignore))
    }

    private fun publishTmuxWindowMutationError(message: String) {
        synchronized(tmuxTransportLock) {
            tmuxWindowMutationError = message
            mutableTmuxWindowMutationState.value = TmuxWindowMutationState.Error(message)
        }
    }

    /** Caller holds [tmuxTransportLock]. */
    private fun finishTmuxWindowMutationIfAuthoritativeLocked(snapshot: SharedTmuxSnapshot?) {
        val pending = pendingTmuxWindowMutation ?: return
        if (!pending.awaitingTruth || snapshot?.isReorderPending != false) return
        pending.timeoutJob?.cancel()
        pendingTmuxWindowMutation = null
        tmuxWindowMutationError = null
        updateTmuxWindowMutationState(snapshot)
    }

    /** Caller holds [tmuxTransportLock]. */
    private fun updateTmuxWindowMutationState(snapshot: SharedTmuxSnapshot? = mutableTmuxSnapshot.value) {
        mutableTmuxWindowMutationState.value = when {
            pendingTmuxWindowMutation != null || snapshot?.isReorderPending == true ->
                TmuxWindowMutationState.Pending
            tmuxWindowMutationError != null -> TmuxWindowMutationState.Error(tmuxWindowMutationError!!)
            isTmuxWindowMutationAvailable(snapshot) -> TmuxWindowMutationState.Available
            else -> TmuxWindowMutationState.Unavailable
        }
    }

    /** Caller holds [tmuxTransportLock]. */
    private fun isTmuxWindowMutationAvailable(snapshot: SharedTmuxSnapshot?): Boolean =
        !closed && tmuxConnection != null && tmuxCore != null && tmuxCommandChannel != null &&
            mutableTmuxAuthority.value !is SharedTmuxGridAuthoritySnapshot.Peer &&
            pendingTmuxWindowMutation == null && snapshot != null &&
            snapshot.sessionId != null && snapshot.sessionName != null && snapshot.capabilities != null &&
            snapshot.isWindowListHydrated && snapshot.windows.isNotEmpty() && snapshot.windows.all { it.index != null } &&
            snapshot.activeWindowId != null && snapshot.windows.any { it.id == snapshot.activeWindowId } &&
            !snapshot.isReorderPending

    /**
     * Run a mutation whose resulting selected window is assigned by tmux.
     * The strict active-window reply supplies that id before the stamped Mosh
     * painter is moved, so `new-window` cannot leave pixels on the old tab.
     */
    private fun selectTmuxDynamicWindow(primaryCommand: String): Boolean =
        selectTmuxAcrossClients(
            windowId = null,
            paneId = null,
            preservingWindowZoom = false,
            primaryCommand = primaryCommand,
            agentResponse = null,
        )

    /**
     * Closing an inactive window must not move the separately attached Mosh
     * painter. Query the control client's exact active id first; only an
     * active close enters the dynamic post-mutation mirror pipeline.
     */
    private fun closeTmuxWindow(target: String): Boolean {
        val windowId = TmuxVisibleClientSelection.windowId(target)
        if (windowId == null) {
            recordVisibleSelectionSkip(null, null, "invalid-close-window-target")
            return false
        }
        val canonicalTarget = "@$windowId"
        val command = "kill-window -t $canonicalTarget"
        if (!usesMoshPrimaryTransport()) {
            return sendTmuxControl(command, TmuxResponsePurpose.Ignore)
        }
        val activeWindowQuery = SharedTmuxCommands.activeWindowHydrationCommand()
        if (activeWindowQuery == null) {
            recordVisibleSelectionSkip(windowId, null, "resolve-close-preflight-query")
            return false
        }

        var accepted = false
        var skipDetail: String? = null
        synchronized(tmuxTransportLock) {
            val snapshot = mutableTmuxSnapshot.value
            val session = snapshot?.sessionName
            if (closed || yieldedToPeer()) {
                skipDetail = "close no longer admitted"
                return@synchronized
            }
            if (snapshot?.windows?.none { it.id == windowId } != false) {
                skipDetail = "window is no longer in the session"
                return@synchronized
            }
            if (session == null) {
                skipDetail = "session identity is unavailable"
                return@synchronized
            }

            val selectionGeneration = visibleClientSelectionGeneration
            val transportGeneration = tmuxTransportGeneration
            accepted = enqueueTmuxPlatformCommand(
                TmuxControlCommand(
                    activeWindowQuery,
                    TmuxResponsePurpose.VisibleSelectionClosePreflight(
                        windowId = windowId,
                        session = session,
                        selectionGeneration = selectionGeneration,
                        transportGeneration = transportGeneration,
                    ),
                ),
            )
            if (!accepted) {
                skipDetail = "tmux control writer is unavailable"
            }
        }
        if (!accepted) recordVisibleSelectionSkip(windowId, null, skipDetail ?: "queue-close-preflight")
        return accepted
    }

    private fun selectTmuxPane(
        target: String,
        preservingWindowZoom: Boolean,
        agentResponse: CompletableDeferred<AgentTmuxControlAck>? = null,
    ): Boolean {
        val paneId = TmuxVisibleClientSelection.paneId(target)
        if (paneId == null) {
            agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            diagnostics.record(
                "tmux_visible_selection_skipped",
                mapOf("detail" to "invalid pane target", "transport" to diagnosticTransport),
            )
            return false
        }
        val canonicalTarget = "%$paneId"
        val zoomFlag = if (preservingWindowZoom) "-Z " else ""
        if (!usesMoshPrimaryTransport()) {
            // The inline control client needs no visible-client mirror, but it
            // passes the same authority gate as every other selection.
            return selectTmuxAcrossClients(
                windowId = null,
                paneId = paneId,
                preservingWindowZoom = preservingWindowZoom,
                primaryCommand = "select-pane ${zoomFlag}-t $canonicalTarget",
                agentResponse = agentResponse,
            )
        }

        val windowId = mutableTmuxSnapshot.value?.windows
            ?.singleOrNull { window -> window.panes.any { it.id == paneId } }
            ?.id
        if (windowId == null) {
            agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            recordVisibleSelectionSkip(null, paneId, "pane-is-no-longer-in-session")
            return false
        }
        return selectTmuxAcrossClients(
            windowId = windowId,
            paneId = paneId,
            preservingWindowZoom = preservingWindowZoom,
            primaryCommand = "select-pane ${zoomFlag}-t $canonicalTarget",
            agentResponse = agentResponse,
        )
    }

    private fun cycleTmuxPane(forward: Boolean): Boolean {
        val window = mutableTmuxSnapshot.value?.activeWindow ?: return false
        val paneIds = (window.layout?.paneIdsInLayoutOrder() ?: window.panes.map { it.id })
            .distinct()
        val activePaneId = window.activePaneId ?: return false
        val currentIndex = paneIds.indexOf(activePaneId)
        if (currentIndex < 0 || paneIds.size < 2) return false
        val nextIndex = if (forward) {
            (currentIndex + 1) % paneIds.size
        } else {
            (currentIndex - 1 + paneIds.size) % paneIds.size
        }
        return selectTmuxPane(
            target = "%${paneIds[nextIndex]}",
            preservingWindowZoom = false,
        )
    }

    private fun selectTmuxAcrossClients(
        windowId: Int?,
        paneId: Int?,
        preservingWindowZoom: Boolean,
        primaryCommand: String,
        agentResponse: CompletableDeferred<AgentTmuxControlAck>?,
    ): Boolean {
        // The one authority gate for window and pane selection, from the tab
        // strip and Agent Center alike (D7): a yielded, resuming or reclaiming
        // device must not switch every attached client's window or become
        // tmux's `latest` client, which would resize the peer's grid.
        tmuxAuthorityMutationRefusal()?.let { refusal ->
            agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            recordVisibleSelectionSkip(windowId, paneId, "authority $refusal")
            return false
        }
        if (!usesMoshPrimaryTransport()) {
            val purpose = agentResponse?.let(TmuxResponsePurpose::AgentCommand)
                ?: TmuxResponsePurpose.Ignore
            // Re-checked with the enqueue in one critical section: a verdict
            // reduced since the check above must not let the switch through.
            var refusal: String? = null
            val accepted = synchronized(tmuxTransportLock) {
                refusal = tmuxAuthorityMutationRefusal()
                refusal == null && sendTmuxControl(primaryCommand, purpose)
            }
            if (!accepted) agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            refusal?.let { recordVisibleSelectionSkip(windowId, paneId, "authority $it") }
            return accepted
        }

        var accepted = false
        var skipDetail: String? = null
        synchronized(tmuxTransportLock) {
            if (closed || tmuxAuthorityMutationRefusal() != null) {
                skipDetail = "selection no longer admitted"
                return@synchronized
            }
            val snapshot = mutableTmuxSnapshot.value
            val session = snapshot?.sessionName
            val quotedSession = session?.let(TmuxVisibleClientSelection::quotedArgument)
            val targetWindow = windowId?.let { expected ->
                snapshot?.windows?.firstOrNull { it.id == expected }
            }
            if ((windowId != null && targetWindow == null) || paneId?.let { targetPane ->
                    targetWindow?.panes?.none { it.id == targetPane } != false
                } == true
            ) {
                skipDetail = if (paneId == null) {
                    "window is no longer in the session"
                } else {
                    "pane is no longer in the session"
                }
                return@synchronized
            }
            if (session == null || quotedSession == null) {
                skipDetail = "session identity is unavailable"
                return@synchronized
            }

            visibleClientSelectionGeneration += 1
            visibleSelectionNaturalFloor = lastNaturalMoshDeliveryId
            pendingVisibleClientRefresh = null
            activeVisibleClientRefreshGeneration = null
            acknowledgedVisibleClientRefreshGeneration = null
            val selectionGeneration = visibleClientSelectionGeneration
            val transportGeneration = tmuxTransportGeneration
            val primary = TmuxControlCommand(
                primaryCommand,
                TmuxResponsePurpose.VisibleSelectionPrimary(
                    windowId = windowId,
                    paneId = paneId,
                    preservingWindowZoom = preservingWindowZoom,
                    session = session,
                    selectionGeneration = selectionGeneration,
                    transportGeneration = transportGeneration,
                    agentResponse = agentResponse,
                ),
            )
            if (!enqueueTmuxPlatformCommand(primary)) {
                visibleClientSelectionGeneration += 1
                visibleClientCommittedSelectionGeneration = visibleClientSelectionGeneration
                skipDetail = "tmux control writer is unavailable"
                return@synchronized
            }
            accepted = true
        }

        if (!accepted) {
            agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            diagnostics.record(
                "tmux_visible_selection_skipped",
                mapOf(
                    "detail" to (skipDetail ?: "selection was not queued"),
                    "window" to (windowId?.let { "@$it" } ?: "dynamic"),
                    "pane" to (paneId?.let { "%$it" } ?: "none"),
                    "transport" to diagnosticTransport,
                ),
            )
        }
        return accepted
    }

    /** Must be evaluated and followed by an enqueue under [tmuxTransportLock]. */
    private fun isCurrentVisibleSelection(
        windowId: Int,
        paneId: Int? = null,
        session: String,
        selectionGeneration: Long,
        transportGeneration: Long,
        requireActiveWindow: Boolean = true,
    ): Boolean {
        val snapshot = mutableTmuxSnapshot.value
        return isCurrentVisibleSelectionContext(
            session,
            selectionGeneration,
            transportGeneration,
        ) && TmuxVisibleClientSelection.isCurrent(
            expectedWindowId = windowId,
            expectedPaneId = paneId,
            expectedSession = session,
            expectedSelectionGeneration = selectionGeneration,
            expectedTransportGeneration = transportGeneration,
            currentWindowIds = snapshot?.windows?.mapTo(mutableSetOf()) { it.id } ?: emptySet(),
            currentActiveWindowId = snapshot?.activeWindowId,
            currentActivePaneId = snapshot?.activePaneId,
            currentSession = snapshot?.sessionName,
            currentSelectionGeneration = visibleClientSelectionGeneration,
            currentTransportGeneration = tmuxTransportGeneration,
            // Admission, session, and generations were checked above. Keep
            // the pure helper's complete contract explicit for unit tests.
            mutationAdmitted = true,
            requireActiveWindow = requireActiveWindow,
        )
    }

    private fun isCurrentVisibleSelectionContext(
        session: String,
        selectionGeneration: Long,
        transportGeneration: Long,
    ): Boolean {
        val snapshot = mutableTmuxSnapshot.value
        return !closed && usesMoshPrimaryTransport() && !yieldedToPeer() &&
            snapshot?.sessionName == session &&
            visibleClientSelectionGeneration == selectionGeneration &&
            tmuxTransportGeneration == transportGeneration
    }

    private fun visibleClientSelectionAwaitingCommit(): Boolean =
        synchronized(tmuxTransportLock) {
            visibleClientCommittedSelectionGeneration < visibleClientSelectionGeneration
        }

    /** Must be evaluated while [tmuxTransportLock] is held. */
    private fun pendingVisibleClientRefreshFor(owner: RenderOwner): PendingVisibleClientRefresh? {
        val pending = pendingVisibleClientRefresh ?: return null
        if (visibleClientCommittedSelectionGeneration != pending.selectionGeneration ||
            !isCurrentVisibleSelection(
                pending.windowId,
                pending.paneId,
                pending.session,
                pending.selectionGeneration,
                pending.transportGeneration,
            ) ||
            owner.transportGeneration != pending.transportGeneration ||
            owner.windowId != pending.windowId ||
            (pending.paneId != null && owner.paneId != pending.paneId)
        ) return null
        return pending
    }

    /**
     * Queue the redraw only after the Mosh driver publishes its post-commit
     * sequence cut. The named client was obtained from an exact stamped tuple;
     * revalidate every generation and owner before using it as a tmux target.
     */
    private fun enqueuePendingVisibleClientRefresh(
        expected: PendingVisibleClientRefresh,
        owner: RenderOwner,
    ): Boolean = synchronized(tmuxTransportLock) {
        if (pendingVisibleClientRefreshFor(owner) != expected ||
            activeVisibleClientRefreshGeneration != expected.selectionGeneration ||
            terminalSurface?.boundOwner != owner ||
            moshPainterHandoff.activeOwner != owner
        ) return@synchronized false
        val quotedClient = TmuxVisibleClientSelection.quotedArgument(expected.clientName)
            ?: return@synchronized false
        enqueueTmuxPlatformCommand(
            TmuxControlCommand(
                "refresh-client -t $quotedClient",
                TmuxResponsePurpose.VisibleSelectionRefresh(
                    selectionGeneration = expected.selectionGeneration,
                    transportGeneration = expected.transportGeneration,
                    clientName = expected.clientName,
                ),
            ),
        )
    }

    private fun recordVisibleSelectionSkip(
        windowId: Int?,
        paneId: Int? = null,
        stage: String,
    ) {
        diagnostics.record(
            "tmux_visible_selection_skipped",
            mapOf(
                "detail" to "stage=$stage",
                "window" to (windowId?.let { "@$it" } ?: "unknown"),
                "pane" to (paneId?.let { "%$it" } ?: "none"),
                "transport" to diagnosticTransport,
            ),
        )
    }

    /**
     * False when no control channel accepted the command, so the caller must
     * not latch state that only a delivered command can justify.
     */
    private fun sendTmuxControl(command: String, purpose: TmuxResponsePurpose): Boolean {
        // Counted before it can be answered: Main drains the reply, possibly
        // before this thread would get to count it afterwards.
        val claimCommand = purpose as? TmuxResponsePurpose.ClaimCommand
        if (claimCommand != null) synchronized(tmuxTransportLock) { noteAuthorityClaimCommandSent(claimCommand.generation) }
        if (!enqueueTmuxPlatformCommand(TmuxControlCommand(command, purpose))) {
            if (claimCommand != null) synchronized(tmuxTransportLock) { noteAuthorityClaimReplyReceived(claimCommand.generation) }
            currentIntent?.let {
                emitSharedIfOpen {
                    emitFailure(
                        it.requestId,
                        "tmux_command_failed",
                        mapOf("detail" to "tmux control writer is unavailable"),
                    )
                }
            }
            return false
        }
        return true
    }

    /**
     * Admit all platform-owned commands through the same gate as Agent Center.
     *
     * A control-mode reply names no command, so the FIFO is the only thing
     * that says which reply answers which purpose. The core delivers platform
     * writes through the same callback queue as ledger writes, including facts
     * reduced reentrantly whose callbacks wait for the current callback to
     * return. Queuing a platform write here would overtake those earlier facts.
     *
     * This method is deliberately lock-only and non-suspending: callers use a
     * `true` result as the acceptance edge for local latches.  The actual wire
     * writer remains the single consumer of [tmuxCommandChannel].
     */
    private fun enqueueTmuxPlatformCommand(request: TmuxControlCommand): Boolean =
        synchronized(tmuxTransportLock) {
            if (closed) return@synchronized false
            tmuxPlatformCommandProbe?.let { return@synchronized it(request) }
            val channel = tmuxCommandChannel ?: return@synchronized false
            val runtime = tmuxCore ?: return@synchronized channel.trySend(request).isSuccess
            val connection = tmuxConnection
            val generation = tmuxTransportGeneration
            val tag = when (val submission = runtime.queueCommand(request.command)) {
                is SharedTmuxCommandSubmission.Accepted -> submission.tag
                SharedTmuxCommandSubmission.InvalidArguments,
                SharedTmuxCommandSubmission.StaleHandle -> return@synchronized false
            }
            // A synchronous callback can queue the write before returning its
            // tag. Its ACK cannot enter this monitor before purpose registration.
            // It can also replace the transport, so never install an old tag
            // in the replacement's response map.
            val current = !closed && tmuxCore === runtime && tmuxCommandChannel === channel &&
                tmuxConnection === connection && tmuxTransportGeneration == generation &&
                tmuxPlatformWireAdmissionFailedGeneration != generation
            if (!current) {
                // Later callbacks can already own FIFO slots. This old tag is
                // not necessarily an unwritten suffix, so close its exact
                // transport rather than cancel it and continue out of order.
                connection?.close()
                return@synchronized false
            }
            request.purpose?.let { activeTmuxResponses?.put(tag, it) }
            true
        }

    /** Queue an opt-in core wire callback without consulting its later reply purpose. */
    private fun enqueueTmuxPlatformWireCommands(
        commands: List<SharedTmuxPlatformWireCommand>,
        expectedTmux: SshTmuxConnection,
        expectedGeneration: Long,
    ): Boolean = synchronized(tmuxTransportLock) {
        if (!TmuxTransportEpochGate.isCurrent(
                closed, expectedTmux, expectedGeneration, tmuxConnection, tmuxTransportGeneration,
            )) return@synchronized false
        val channel = tmuxCommandChannel ?: return@synchronized false
        commands.all { command ->
            channel.trySend(TmuxControlCommand(command.command, fifoTag = command.tag)).isSuccess
        }
    }

    /** Complete failures against the response map captured by this writer's transport. */
    private fun failTmuxPlatformWrite(
        request: TmuxControlCommand,
        responses: ConcurrentHashMap<Long, TmuxResponsePurpose>,
    ) {
        val purpose = request.purpose ?: request.fifoTag?.let { responses[it] }
        if (purpose != null) request.fifoTag?.let { responses.remove(it, purpose) }
        purpose?.agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
    }

    /**
     * Queue every command in one reducer batch on the writer, in batch order.
     *
     * A control-mode reply names no command, so the reply FIFO is the only
     * thing that says which reply answers which purpose.  Queuing the commands
     * anywhere after this critical section — on the main-thread executor, say
     * — lets a batch produced later reach the channel first and hands every
     * later reply to its neighbour's purpose, which is silent until a reply
     * has to be parsed and then never recovers on its own.
     *
     * A `-C` among them while a claim runs is that claim's wire work (L2).
     * Only the ledger knows whether a client size went out (P6), and its
     * replay can arrive here after the fact that asked for it, behind the
     * callback that was being delivered, so this is where it is noted.
     *
     * Must be called while [tmuxTransportLock] is held.
     */
    private fun enqueueLedgerRenderCommands(
        effects: List<SharedTmuxRenderEffect>,
        tmux: SshTmuxConnection,
        transportGeneration: Long,
    ): Boolean {
        var index = 0
        var queued = true
        while (index < effects.size) {
            if (effects[index] !is SharedTmuxRenderEffect.SendCommand) {
                index += 1
                continue
            }
            // A contiguous run is one atomic queue element: a capture sequence
            // the reducer emitted together must not be split by a platform
            // query on the wire.
            val commands = buildList {
                do {
                    add((effects[index] as SharedTmuxRenderEffect.SendCommand).command)
                    index += 1
                } while (index < effects.size && effects[index] is SharedTmuxRenderEffect.SendCommand)
            }
            if (!enqueueLedgerTmuxCommands(
                    commands = commands,
                    expectedTmux = tmux,
                    expectedGeneration = transportGeneration,
                )
            ) {
                queued = false
            } else if (pendingAuthorityRepaintGeneration != null &&
                commands.any { it.startsWith(TMUX_CLIENT_SIZE_COMMAND_PREFIX) }
            ) {
                noteAuthorityClaimGridMutation()
            }
        }
        return queued
    }

    /**
     * One shared-runtime callback for the control connection [tmux] at
     * [transportGeneration]. Synchronous with the runtime call that caused
     * it (a feed, a queued command, a submitted fact), on that caller's
     * thread, and serialized per handle by the core.
     */
    private fun handleTmuxRuntimeEvent(
        event: SharedTmuxEvent,
        tmux: SshTmuxConnection,
        transportGeneration: Long,
    ) {
        synchronized(tmuxTransportLock) {
            if (closed || transportGeneration != tmuxTransportGeneration || tmuxConnection !== tmux) {
                return
            }
            sessionProgramStatus?.observeTmuxEvent(tmuxCore, event.programStatusRevision)
            if (event.platformWireCommands.isNotEmpty()) {
                // These callbacks only deliver a previously admitted
                // platform write. Reconciliation here would turn a policy
                // query into another policy query before its reply arrives.
                if (!enqueueTmuxPlatformWireCommands(event.platformWireCommands, tmux, transportGeneration)) {
                    tmuxPlatformWireAdmissionFailedGeneration = transportGeneration
                    diagnostics.record("tmux_platform_wire_unsent", mapOf("transport" to diagnosticTransport))
                    tmux.close()
                }
                return
            }
            // P4: a keystroke's own fact echo (mosh only) retires side-channel
            // history and changes nothing else. Read before the snapshot is
            // republished below.
            val userInputEcho = tmuxUserInputFactInFlight && event.changesOnlyRender(mutableTmuxSnapshot.value)
            // The reducer admitted these commands to its reply FIFO while
            // this critical section was held.  Queue them on the writer
            // before leaving it, so no other producer can take a FIFO slot
            // ahead of a command that already holds one.
            val renderCommandsQueued = enqueueLedgerRenderCommands(event.renderEffects, tmux, transportGeneration)
            fun abortClaimForUnsentRenderCommands() {
                inlineAuthorityRepaintFence.generation?.let { generation ->
                    abortTmuxGridAuthorityClaim(
                        generation,
                        "ledger repaint command was not accepted by the control writer",
                    )
                }
            }
            if (!renderCommandsQueued) {
                diagnostics.record(
                    "render_ledger_command_unsent",
                    mapOf("transport" to diagnosticTransport),
                )
                // The runtime's reduction of this read is the session's
                // latest until it is applied below, so no reduction precedes it.
                if (event.authoritySession == null) abortClaimForUnsentRenderCommands()
            }
            if (userInputEcho) {
                // Its render effects keep their order. The snapshot pass below
                // would only republish and re-judge the snapshot every view
                // already holds, on Main, for every key: nothing it derives
                // from that snapshot can have changed. What may still wait for
                // "the next event" is a claim or a held read, never the
                // snapshot, so those redrives stay; each is a field check.
                if (event.renderEffects.isNotEmpty()) {
                    pendingTmuxRenderBatches.addLast(
                        PendingTmuxRenderBatch(event.renderEffects, tmux, transportGeneration, inlineAuthorityRepaintFence.epoch),
                    )
                    scope.launch(Dispatchers.Main.immediate) {
                        tmuxRenderEffectMutex.withLock { drainTmuxRenderBatches() }
                    }
                }
                event.snapshot.activeWindow?.id?.let(::probeWindowSizePolicy)
                return
            }
            val previousWindow = mutableTmuxSnapshot.value?.activeWindow
            val nextWindow = event.snapshot.activeWindow
            val geometryChanged = previousWindow?.id != nextWindow?.id || previousWindow?.layout != nextWindow?.layout ||
                mutableTmuxSnapshot.value?.activePaneId != event.snapshot.activePaneId
            pendingTmuxRenderBatches.addLast(
                PendingTmuxRenderBatch(event.renderEffects, tmux, transportGeneration, inlineAuthorityRepaintFence.epoch),
            )
            val initialWindowHydration = event.snapshot.isWindowListHydrated &&
                mutableTmuxSnapshot.value?.isWindowListHydrated != true
            val priorSession = mutableTmuxSnapshot.value?.sessionId
            // The runtime names every switch in a read it delivered. One whose
            // event was lost shows only in the next snapshot (a recovery):
            // two known sessions that differ switched all the same.
            val switched = event.controlSessionSwitched || (!event.authorityReducedInFeed &&
                priorSession != null && event.snapshot.sessionId != null && priorSession != event.snapshot.sessionId)
            mutableTmuxSnapshot.value = event.snapshot
            if (switched) beginTmuxAuthoritySessionSwitch(transportGeneration)
            // The runtime reduced this read in wire order, before anything
            // this callback reduces: apply that first.
            event.authoritySession?.let { result ->
                adoptRuntimeAuthorityReduction(result)
                if (!renderCommandsQueued) abortClaimForUnsentRenderCommands()
            }
            if (event.authorityReducedInFeed) {
                // Its window facts are the session's: report them again only
                // once they change.
                lastAuthorityWindowFacts = authorityWindowFacts(event.snapshot)
            } else if (switched) {
                reduceTmuxAuthority { session, now -> session.controlSessionChanged(now, true) }
                submitAuthorityGeometryFacts(event.snapshot)
                reduceTmuxAuthority { session, now -> session.attached(now, tmuxDeviceIdentity.id) }
            } else if (priorSession != event.snapshot.sessionId) {
                reduceTmuxAuthority { session, now -> session.controlSessionChanged(now, false) }
            }
            if (switched) finishTmuxAuthoritySessionSwitch()
            // A newer stamp invalidates a held own reply before window facts
            // can release it and begin a claim.
            if (event.authorityStamps.isNotEmpty()) {
                reduceTmuxAuthority { session, now -> session.stampsObserved(now, event.authorityStamps) }
            }
            val obsoleteRecovery = ordinaryTmuxWindowRecovery?.takeIf {
                event.snapshot.activeWindowId != it.windowId || event.snapshot.activeWindow?.layout?.gridSize() != it.observed
            }
            submitAuthorityGeometryFacts(event.snapshot)
            if (ordinaryTmuxWindowRecovery === obsoleteRecovery && obsoleteRecovery != null) {
                ordinaryTmuxWindowRecovery = null
                submitAuthorityOrdinaryRecovery()
            }
            finishTmuxWindowMutationIfAuthoritativeLocked(event.snapshot)
            updateTmuxWindowMutationState(event.snapshot)
            // Geometry first: a window sent back to its fence phase makes the
            // repaint's target shape moot, as on iOS.
            observeAuthorityClaimLayout(event.snapshot, "layout-change")
            validatePendingInlineAuthorityRepaintTopology()
            if (geometryChanged) redriveDeferredAuthorityRepaint("snapshot")
            if (!usesMoshPrimaryTransport()) {
                fenceTmuxGridAuthorityClaimOnCurrentWindow(event.snapshot)
                confirmTmuxGridAuthorityClaim(event.snapshot)
            }
            scope.launch(Dispatchers.Main.immediate) { publishScrollRouting() }
            emitSharedIfOpen { emitTmuxSnapshot(event.snapshot.rawJson) }
            // A peer leaving is not a show (§6.9 R5): departure is only a
            // runtime fact now, never an authority event.
            event.bells.forEach { bell ->
                scope.launch(Dispatchers.Main.immediate) {
                    synchronized(tmuxTransportLock) {
                        if (closed || transportGeneration != tmuxTransportGeneration ||
                            tmuxConnection !== tmux
                        ) return@synchronized
                        onTmuxBell?.invoke(bell)
                    }
                }
            }
            // A callback batch is one ordered ledger transaction.  Do not
            // launch output, reply and capture work independently: the core
            // deliberately emits these effects in transport order.
            scope.launch(Dispatchers.Main.immediate) {
                tmuxRenderEffectMutex.withLock { drainTmuxRenderBatches() }
            }
            // tmux publishes `@tessera_agent_state` for every pane of the
            // attached session, so this is the only lifecycle source for an
            // agent working in a window this client is not painting — which is
            // most of them. Rendered output reaches the OSC scanner instead.
            if (event.agentStates.isNotEmpty()) {
                val endpoint = agentEndpoint
                // Recorded because this feed had no diagnostic at all, and its
                // absence made an empty Agent Center unreadable: nothing said
                // whether tmux was silent, whether the payloads arrived before
                // an endpoint existed, or whether a later gate refused them.
                diagnostics.record(
                    "agent_pane_state",
                    mapOf(
                        "detail" to "panes=${event.agentStates.map { "%${it.paneId}" }} " +
                            "endpoint=${endpoint != null}",
                        "transport" to diagnosticTransport,
                    ),
                )
                event.agentStates.forEach { state ->
                    endpoint?.noteTmuxAgentState(state.windowId, state.paneId, state.json)
                }
            }
            val selectedPane = event.snapshot.activePaneId
            agentEndpoint?.let { endpoint ->
                val changed = endpoint.updateActiveTmuxTarget(event.snapshot.activeWindowId, selectedPane)
                if (agentRegistration == null) {
                    // A tmux endpoint has no usable route binding until the
                    // initial control snapshot identifies a concrete pane.
                    // Publishing the provisional nil/nil binding starts the
                    // session probe and projector, then immediately cancels
                    // both when hydration supplies the pane. On SSHJ that
                    // close/open overlap can reset the parent SSH transport.
                    publishAgentEndpointIfReady(endpoint)
                } else if (changed) {
                    agentSessions.refresh(endpoint.key)
                }
            }
            sendTmuxTopologyQueries(event.topologyQueries)
            event.subscriptionCommands.forEach { command -> sendTmuxControl(command, TmuxResponsePurpose.Ignore) }
            applyInitialTmuxSelection(event.snapshot)
            persistTmuxSelection(event.snapshot)
            event.snapshot.activeWindow?.id?.let(::probeWindowSizePolicy)
            noteTmuxLayoutForDiagnostics(event.snapshot)
            reconcileTmuxClientSize(event.snapshot, forceAllWindows = initialWindowHydration)
            reconcilePresentedTmuxWindowSize(event.snapshot)
            // The side channel fences after the forces reconcile just queued
            // (a claim ahead of hydration has its first window now).
            if (usesMoshPrimaryTransport()) {
                fenceTmuxGridAuthorityClaimOnCurrentWindow(event.snapshot)
                if (validateAuthorityMoshGeometry(event.snapshot) && geometryChanged) confirmTmuxGridAuthorityClaim(event.snapshot)
            }
            // Settle evidence is parsed in stream order with layout changes.
            // Consume its tag here; Main later skips that reply while retaining
            // the order of every surface effect in the callback batch.
            for (effect in event.renderEffects) {
                if (effect !is SharedTmuxRenderEffect.CommandReply) continue
                val purpose = activeTmuxResponses?.get(effect.tag)
                if (purpose is TmuxResponsePurpose.AuthoritySettleSize) handleTmuxPlatformReply(effect.tag, effect.success, effect.lines)
            }
            if (geometryChanged) endTmuxGridAuthorityClaimIfStalledLate("layout-change")
        }
    }

    /**
     * A runtime event that carries nothing but render effects: the snapshot
     * the adapter already holds (the decoder hands back the same instance
     * while the core elides it) and no bell, agent state, topology query or subscription,
     * raw stamp edge or session result, departure or platform write.
     */
    private fun SharedTmuxEvent.changesOnlyRender(current: SharedTmuxSnapshot?): Boolean =
        snapshot === current && bells.isEmpty() && agentStates.isEmpty() && topologyQueries.isEmpty() &&
            subscriptionCommands.isEmpty() &&
            authorityStamps.isEmpty() && authoritySession == null && !peerDepartureObserved &&
            platformWireCommands.isEmpty()

    /**
     * Apply reducer effect batches in the order the reducer produced them.
     *
     * Callers hold [tmuxRenderEffectMutex], so exactly one drain runs at a
     * time and it always takes the oldest batch first — including batches a
     * re-entrant fact appended while this drain was suspended.
     */
    private suspend fun drainTmuxRenderBatches() {
        while (true) {
            val batch = synchronized(tmuxTransportLock) {
                pendingTmuxRenderBatches.poll()
            } ?: return
            val current = synchronized(tmuxTransportLock) {
                !closed && tmuxConnection === batch.tmux &&
                    tmuxTransportGeneration == batch.transportGeneration
            }
            // A batch from a replaced transport is dropped, never allowed to
            // stop the drain: batches behind it may belong to the live one.
            if (current) {
                executeTmuxRenderEffects(batch.effects, batch.tmux, batch.transportGeneration, batch.repaintEpoch)
            }
        }
    }

    /**
     * Hands the ledger its new control client: [profile] from here on.
     *
     * Ordinary geometry is withheld from here until the attach's authority
     * read resolves (§6.9 R5; iOS holds it from control-mode entry, D3). The
     * attach fact's own runtime callback reconciles, and a pane grid
     * publishes its viewport with no snapshot needed: with the hold raised
     * only alongside the lifecycle's read, a first connect, or a reconnect
     * to a window this device had owned, wrote its `-C` ahead of
     * `show-options @tessera_authority` and resized whichever peer had taken
     * the window meanwhile. A reconcile outside [tmuxTransportLock] can have
     * passed its check just before this attach; [sendTmuxClientSize] judges
     * it again under the lock.
     *
     * The runtime is published (so facts reach it) a little before this,
     * and a size published in between reached a ledger with no transport
     * yet, which records the grid and sends nothing. The P6 memory is the
     * ledger's and starts empty on attach; [lastPublishedTmuxSize] is not,
     * so a later reconcile at that grid would publish nothing and this
     * connection's client would sit at tmux's default 80x24 until the
     * device's grid changed. It is forgotten in the same critical section,
     * so the first replay once the read releases the hold always reaches
     * the ledger, which sends its `-C`.
     *
     * False, changing nothing, once [tmux] is no longer the current
     * connection.
     */
    private fun attachTmuxRenderTransport(
        profile: SharedTmuxRenderProfile,
        tmux: SshTmuxConnection,
        transportGeneration: Long,
    ): Boolean {
        synchronized(tmuxTransportLock) {
            // A connection replaced or closed while it was being set up must
            // not raise the hold on, or hand its profile to, its successor's
            // ledger.
            if (transportGeneration != tmuxTransportGeneration || tmuxConnection !== tmux) return false
            // This is a new wire epoch. Reset before the ledger's synchronous
            // attach callback so its reconcile sees the shared read hold.
            reduceTmuxAuthority { session, now -> session.resetTransport(now, preservingPeer = true) }
            resetAuthorityFactMemos()
            if (!appForeground) reduceTmuxAuthority { session, now -> session.backgrounded(now) }
            reduceTmuxAuthority { session, now -> session.channelLiveness(now, false) }
            lastAuthorityChannelLive = false
            // Both before the fact: its callback reconciles inside it.

            lastPublishedTmuxSize = null
            submitTmuxRenderFact(SharedTmuxRenderFact.TransportAttached(profile))
            return true
        }
    }

    /**
     * Gives the runtime its transport, then the facts that follow it, then
     * the lifecycle's attach read, in that order; false once [tmux] is no
     * longer the current connection.
     *
     * Render policy is established before any platform command, as iOS does
     * at control-mode entry. The engine owns capture stages and the FIFO
     * from this point forward, and its transport-attached reduction resets
     * that FIFO: a command the wire writer had already admitted (the
     * initial-attach claim's geometry fence) lost its reply to that reset
     * whenever the writer won the race, and the launch claim then waited on
     * a fence that could never complete.
     */
    private fun startTmuxRenderTransport(tmux: SshTmuxConnection, transportGeneration: Long): Boolean {
        val profile = if (usesMoshPrimaryTransport()) {
            SharedTmuxRenderProfile.SideChannel
        } else {
            SharedTmuxRenderProfile.Inline
        }
        if (!attachTmuxRenderTransport(profile, tmux, transportGeneration)) return false
        recordRenderDropSummary("transport-attached")
        submitTmuxRenderFact(SharedTmuxRenderFact.ScrollbackLimit(scrollbackLines.coerceAtLeast(0)))
        submitTmuxRenderFact(
            if (appForeground) SharedTmuxRenderFact.AppForeground else SharedTmuxRenderFact.AppBackground,
        )
        publishDeclaredTmuxRenderSurfaces()
        synchronized(tmuxTransportLock) {
            if (transportGeneration != tmuxTransportGeneration || tmuxConnection !== tmux) return false
            // The lifecycle event is deliberately ahead of hydration: it only
            // queries (§6.9 R5), and ordinary geometry stays withheld until
            // that read resolves, so no snapshot can replay this device's size
            // before it knows who owns the grid. The hold went up with the
            // transport's attach. A claim settled or aborted since may have
            // released it, but `attached()` always asks, and the read raises
            // the hold again in this critical section before anything can
            // publish. A pending show or tap intent is decided by this same
            // read.
            // TransportAttached has reset the command FIFO. Only now may
            // resolution reserve its two reply slots, ahead of authority reads.
            tmuxAuthorityOwnerSessionName?.let { beginTmuxAuthorityScopeResolution(it, transportGeneration) }
            submitAuthorityGeometryFacts()
            submitAuthorityPaintability()
            reduceTmuxAuthority { session, now -> session.attached(now, tmuxDeviceIdentity.id) }
            lastAuthorityChannelLive = true
        }
        return true
    }

    /**
     * Submit an adapter fact to the v2 runtime.  Render callbacks can be
     * synchronous, which is intentional: they are scheduled as a single main
     * batch by the listener below rather than being split by effect kind.
     */
    private fun submitTmuxRenderFact(fact: SharedTmuxRenderFact): Boolean {
        return synchronized(tmuxTransportLock) {
            tmuxRenderFactProbe?.let { return@synchronized it(fact) }
            val runtime = tmuxCore ?: return@synchronized false
            runtime.submitFact(fact) == CoreCallResult.Accepted
        }
    }

    private fun submitTmuxRenderFact(
        fact: SharedTmuxRenderFact,
        expectedTmux: SshTmuxConnection,
        expectedRuntime: SharedTmuxRuntime,
        expectedGeneration: Long,
    ): Boolean = synchronized(tmuxTransportLock) {
        if (!TmuxTransportEpochGate.isCurrent(
                closed = closed,
                expectedConnection = expectedTmux,
                expectedGeneration = expectedGeneration,
                currentConnection = tmuxConnection,
                currentGeneration = tmuxTransportGeneration,
            ) || tmuxCore !== expectedRuntime
        ) return@synchronized false
        expectedRuntime.submitFact(fact) == CoreCallResult.Accepted
    }

    private fun noteTmuxRenderUserInput() {
        val window = mutableTmuxSnapshot.value?.activeWindow
        if (usesMoshPrimaryTransport() && window != null && window.panes.size > 1 && !window.zoomed) {
            // Split readers are per-pane: the global UserInput fact would
            // invalidate a reader on an unfocused pane as well.
            returnMoshPaneHistoryInputToTail(
                paneId = mutableTmuxSnapshot.value?.activePaneId,
                hasHistory = { surfaceId ->
                    surfaceId in mutableTmuxRenderHistory.value ||
                        renderSurfaceForId(surfaceId)?.view?.isHistoryScrollPending == true
                },
                cancelHistoryScroll = { renderSurfaceForId(it)?.view?.cancelHistoryScroll() },
            ) { surfaceId ->
                synchronized(tmuxTransportLock) {
                    tmuxUserInputFactInFlight = true
                    try {
                        returnTmuxScrollbackToTail(surfaceId)
                    } finally {
                        tmuxUserInputFactInFlight = false
                    }
                }
            }
            return
        }
        // An old side-channel capture is no longer a valid presentation after
        // local input, even before the core reports its invalidation edge.
        val replacedLivePainter = moshLiveHistoryRevealed
        moshLiveHistoryRevealed = false
        if (replacedLivePainter || moshPainterHandoff.isActive) {
            terminalSurface?.boundOwner?.let { owner ->
                beginMoshPainterHandoff(owner, waitsForNaturalOutput = false)
            } ?: configurePainterFeedAdmission()
        } else {
            configurePainterFeedAdmission()
        }
        clearTmuxRenderHistory()
        // P4: the fact only retires side-channel history; the inline ledger
        // ignores it (iOS submits it for mosh alone), so an SSH+tmux key
        // costs no runtime pass at all. Its synchronous echo comes back
        // through [handleTmuxRuntimeEvent] inside this critical section,
        // which is how that pass recognizes it.
        if (!usesMoshPrimaryTransport()) return
        synchronized(tmuxTransportLock) {
            tmuxUserInputFactInFlight = true
            try {
                submitTmuxRenderFact(SharedTmuxRenderFact.UserInput)
            } finally {
                tmuxUserInputFactInFlight = false
            }
        }
    }

    private fun retireVisibleMoshHistoryForAuthoritativeRepaint() {
        val visibleSurfaces = mutableTmuxRenderHistory.value.keys.toList()
        visibleSurfaces.forEach(::returnTmuxScrollbackToTail)
        if (moshLiveHistoryRevealed && TMUX_RENDER_LIVE_SURFACE_ID !in visibleSurfaces) {
            moshLiveHistoryRevealed = false
            terminalSurface?.boundOwner?.let { owner ->
                beginMoshPainterHandoff(owner, waitsForNaturalOutput = false)
            } ?: configurePainterFeedAdmission()
            retireMoshRepaintsThroughCurrent()
            moshRenderHistoryFence.discardSurface(TMUX_RENDER_LIVE_SURFACE_ID)
            submitTmuxRenderFact(
                SharedTmuxRenderFact.ScrollbackReturnedToTail(TMUX_RENDER_LIVE_SURFACE_ID),
            )
        }
    }

    private fun clearTmuxRenderHistory(surfaceId: String? = null, preservingHistoryScroll: Boolean = false) {
        if (!preservingHistoryScroll && (surfaceId == null || surfaceId == TMUX_RENDER_LIVE_SURFACE_ID)) {
            terminalSurface?.view?.cancelHistoryScroll()
        }
        val abandonedPresentations = if (surfaceId == null) {
            moshHistoryPresentationAcknowledgements.discardAll()
        } else {
            listOfNotNull(moshHistoryPresentationAcknowledgements.discardSurface(surfaceId))
        }
        retireMoshRepaintsThroughCurrent()
        if (surfaceId == null) moshRenderHistoryFence.discardPending()
        else moshRenderHistoryFence.discardSurface(surfaceId)
        mutableTmuxRenderHistory.value = if (surfaceId == null) {
            emptyMap()
        } else {
            mutableTmuxRenderHistory.value - surfaceId
        }
        abandonedPresentations.forEach { delivery ->
            rejectMoshHistoryPresentation(
                surfaceId = delivery.surfaceId,
                owner = delivery.owner,
                deliveryToken = delivery.deliveryToken,
                reason = "physical-surface-cleared",
            )
        }
    }

    private fun enqueueLedgerTmuxCommands(
        commands: List<String>,
        expectedTmux: SshTmuxConnection,
        expectedGeneration: Long,
    ): Boolean = synchronized(tmuxTransportLock) {
        if (commands.isEmpty()) return true
        if (!TmuxTransportEpochGate.isCurrent(
                closed = closed,
                expectedConnection = expectedTmux,
                expectedGeneration = expectedGeneration,
                currentConnection = tmuxConnection,
                currentGeneration = tmuxTransportGeneration,
            )
        ) return@synchronized false
        val channel = tmuxCommandChannel ?: return@synchronized false
        channel.trySend(
            TmuxControlCommand(
                command = commands.first(),
                ledgerOwned = true,
                wireCommands = commands,
            ),
        ).isSuccess
    }

    private fun renderSurfaceForId(surfaceId: String): TerminalSurface? = when {
        surfaceId == TMUX_RENDER_LIVE_SURFACE_ID -> terminalSurface
        surfaceId.startsWith(TMUX_RENDER_PANE_SURFACE_PREFIX) ->
            surfaceId.removePrefix(TMUX_RENDER_PANE_SURFACE_PREFIX).toIntOrNull()?.let(paneSurfaces::get)
        surfaceId.startsWith(TMUX_RENDER_OVERLAY_SURFACE_PREFIX) ->
            surfaceId.removePrefix(TMUX_RENDER_OVERLAY_SURFACE_PREFIX).toIntOrNull()?.let(overlaySurfaces::get)
        else -> null
    }

    private fun renderSurfaceOwner(
        owner: SharedTmuxRenderOwner,
        transportGeneration: Long,
    ): RenderOwner? {
        val windowId = owner.windowId ?: return null
        val paneId = owner.paneId ?: return null
        return RenderOwner(
            windowId = windowId,
            paneId = paneId,
            epoch = owner.epoch,
            transportGeneration = transportGeneration,
        )
    }

    private fun bindRenderSurface(surface: TerminalSurface, owner: RenderOwner, source: String) {
        val previous = surface.boundOwner
        surface.bind(owner)
        if (previous != owner) {
            diagnostics.record(
                "render_surface_bind",
                mapOf(
                    "detail" to "source=$source owner=@${owner.windowId},%${owner.paneId},e${owner.epoch},g${owner.transportGeneration} " +
                        "droppedForeign=${surface.droppedForeignFeeds}",
                    "transport" to diagnosticTransport,
                ),
            )
        }
    }

    private fun feedOwnedRenderBytes(
        surface: TerminalSurface,
        owner: RenderOwner,
        bytes: ByteArray,
        source: String,
    ): Boolean {
        val before = surface.droppedForeignFeeds
        val admitted = surface.feed(owner, bytes)
        if (surface.droppedForeignFeeds > before) {
            diagnostics.record(
                "render_surface_dropped",
                mapOf(
                    "detail" to "source=$source owner=@${owner.windowId},%${owner.paneId},e${owner.epoch},g${owner.transportGeneration} " +
                        "droppedForeign=${surface.droppedForeignFeeds}",
                    "transport" to diagnosticTransport,
                ),
            )
        }
        return admitted
    }

    /** Final Main-thread handoff after the correlated Mosh frame was applied. */
    private fun deliverMoshRenderHistory(
        delivery: MoshRenderHistoryDeliveryFence.Delivery,
    ) {
        moshRenderHistoryRepaintRetryExecutor.cancelReceiptWatchdog(delivery.repaintRequestId)
        val currentGeneration = synchronized(tmuxTransportLock) { tmuxTransportGeneration }
        val surface = renderSurfaceForId(delivery.surfaceId)
        if (!usesMoshPrimaryTransport() ||
            delivery.owner.transportGeneration != currentGeneration ||
            surface?.boundOwner != delivery.owner
        ) {
            rejectMoshHistoryPresentation(
                surfaceId = delivery.surfaceId,
                owner = delivery.ready.owner,
                deliveryToken = null,
                reason = "delivery-stale",
            )
            diagnostics.record(
                "render_history_delivery_stale",
                mapOf(
                    "detail" to "surface=${delivery.surfaceId}",
                    "transport" to diagnosticTransport,
                ),
            )
            return
        }
        if (!feedOwnedRenderBytes(surface, delivery.owner, delivery.bytes, "mosh-history")) {
            rejectMoshHistoryPresentation(
                surfaceId = delivery.surfaceId,
                owner = delivery.ready.owner,
                deliveryToken = null,
                reason = "delivery-feed-rejected",
            )
            diagnostics.record(
                "render_history_delivery_rejected",
                mapOf(
                    "detail" to "surface=${delivery.surfaceId} request=${delivery.repaintRequestId}",
                    "transport" to diagnosticTransport,
                ),
            )
            return
        }
        agentEndpoint?.noteTmuxOutput(
            delivery.owner.windowId,
            delivery.owner.paneId,
            delivery.bytes,
        )
        if (delivery.surfaceId == TMUX_RENDER_LIVE_SURFACE_ID) {
            moshLiveHistoryRevealed = true
            configurePainterFeedAdmission()
        }
        val ready = TmuxRenderHistoryReady(
            deliveryToken = ++nextTmuxRenderHistoryDeliveryToken,
            surfaceId = delivery.surfaceId,
            owner = delivery.ready.owner,
            depth = delivery.ready.depth,
            historySize = delivery.ready.historySize,
            placement = delivery.ready.placement,
        )
        moshHistoryPresentationAcknowledgements.publish(
            MoshHistoryPresentationAcknowledgements.Delivery(
                deliveryToken = ready.deliveryToken,
                surfaceId = delivery.surfaceId,
                owner = delivery.ready.owner,
                physicalOwner = delivery.owner,
                surface = surface,
            ),
        )
        mutableTmuxRenderHistory.value = mutableTmuxRenderHistory.value + (delivery.surfaceId to ready)
    }

    /**
     * Called only by the terminal view after its `View.post` has placed the
     * delivered capture's top row. A ready token is not an acknowledgement:
     * it must still describe the current map entry, owner, generation, and
     * exact Compose-mounted physical terminal.
     */
    internal fun acknowledgeTmuxRenderHistoryPresented(surfaceId: String, deliveryToken: Long) {
        val ready = mutableTmuxRenderHistory.value[surfaceId]
        if (ready?.deliveryToken != deliveryToken) {
            diagnostics.record(
                "render_history_presentation_ack_stale",
                mapOf(
                    "detail" to "surface=$surfaceId delivery=$deliveryToken reason=token",
                    "transport" to diagnosticTransport,
                ),
            )
            return
        }
        val currentGeneration = synchronized(tmuxTransportLock) { tmuxTransportGeneration }
        val surface = renderSurfaceForId(surfaceId)
        when (val acknowledgement = moshHistoryPresentationAcknowledgements.acknowledge(
            surfaceId = surfaceId,
            deliveryToken = deliveryToken,
            currentGeneration = currentGeneration,
            currentSurface = surface,
            currentOwner = surface?.boundOwner,
        )) {
            is MoshHistoryPresentationAcknowledgements.Acknowledgement.Accepted -> {
                if (!submitTmuxRenderFact(
                        SharedTmuxRenderFact.HistoryPresented(
                            surfaceId = surfaceId,
                            owner = acknowledgement.delivery.owner,
                        ),
                    )
                ) {
                    rejectMoshHistoryPresentation(
                        surfaceId = surfaceId,
                        owner = acknowledgement.delivery.owner,
                        deliveryToken = deliveryToken,
                        reason = "ack-submit-rejected",
                    )
                    tmuxConnection?.close()
                } else {
                    diagnostics.record(
                        "render_history_presentation_acknowledged",
                        mapOf(
                            "detail" to "surface=$surfaceId delivery=$deliveryToken " +
                                "owner=@${acknowledgement.delivery.owner.windowId}," +
                                "%${acknowledgement.delivery.owner.paneId}," +
                                "e${acknowledgement.delivery.owner.epoch}",
                            "transport" to diagnosticTransport,
                        ),
                    )
                }
            }
            is MoshHistoryPresentationAcknowledgements.Acknowledgement.Stale ->
                rejectMoshHistoryPresentation(
                    surfaceId = surfaceId,
                    owner = acknowledgement.delivery.owner,
                    deliveryToken = deliveryToken,
                    reason = "ack-physical-surface-stale",
                )
            MoshHistoryPresentationAcknowledgements.Acknowledgement.Duplicate -> diagnostics.record(
                "render_history_presentation_ack_stale",
                mapOf(
                    "detail" to "surface=$surfaceId delivery=$deliveryToken reason=duplicate",
                    "transport" to diagnosticTransport,
                ),
            )
            // A current visible delivery without registry state is an
            // adapter ordering failure, not a harmless stale callback. Clear
            // the exact core latch rather than leaving Mosh frozen forever.
            MoshHistoryPresentationAcknowledgements.Acknowledgement.Unknown ->
                rejectMoshHistoryPresentation(
                    surfaceId = surfaceId,
                    owner = ready.owner,
                    deliveryToken = deliveryToken,
                    reason = "ack-registry-missing",
                )
        }
    }

    /**
     * Releases the exact shared-core latch when a fenced delivery cannot ever
     * be presented. Do not reuse those bytes on a replacement surface.
     */
    private fun rejectMoshHistoryPresentation(
        surfaceId: String,
        owner: SharedTmuxRenderOwner,
        deliveryToken: Long?,
        reason: String,
    ) {
        if (deliveryToken == null ||
            mutableTmuxRenderHistory.value[surfaceId]?.deliveryToken == deliveryToken
        ) {
            mutableTmuxRenderHistory.value = mutableTmuxRenderHistory.value - surfaceId
        }
        if (surfaceId == TMUX_RENDER_LIVE_SURFACE_ID) {
            moshLiveHistoryRevealed = false
            configurePainterFeedAdmission()
        }
        if (!submitTmuxRenderFact(SharedTmuxRenderFact.HistoryPresentationFailed(surfaceId, owner))) {
            diagnostics.record(
                "render_history_presentation_failure_rejected",
                mapOf(
                    "detail" to "surface=$surfaceId delivery=$deliveryToken reason=$reason",
                    "transport" to diagnosticTransport,
                ),
            )
        }
    }

    private fun handleVisibleSelectionOption(
        purpose: TmuxResponsePurpose.VisibleSelectionOption,
        success: Boolean,
        lines: List<String>,
    ) {
        val stamped = lines.takeIf { success }
            ?.let(TmuxVisibleClientSelection::singleStampedIdentity)
        val quotedSession = TmuxVisibleClientSelection.quotedArgument(purpose.session)
        if (stamped == null || quotedSession == null) {
            purpose.agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            recordVisibleSelectionSkip(purpose.windowId, purpose.paneId, "resolve-option")
            return
        }
        val (stamp, identity) = stamped
        val queued = synchronized(tmuxTransportLock) {
            if (!isCurrentVisibleSelection(
                    purpose.windowId,
                    purpose.paneId,
                    purpose.session,
                    purpose.selectionGeneration,
                    purpose.transportGeneration,
                )
            ) return@synchronized false
            enqueueTmuxPlatformCommand(
                TmuxControlCommand(
                    "list-clients -t $quotedSession -F '#{client_name}|#{client_pid}|#{client_created}'",
                    TmuxResponsePurpose.VisibleSelectionClients(
                        windowId = purpose.windowId,
                        paneId = purpose.paneId,
                        preservingWindowZoom = purpose.preservingWindowZoom,
                        session = purpose.session,
                        selectionGeneration = purpose.selectionGeneration,
                        transportGeneration = purpose.transportGeneration,
                        stamp = stamp,
                        clientName = identity.name,
                        agentResponse = purpose.agentResponse,
                    ),
                ),
            )
        }
        if (!queued) {
            purpose.agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            recordVisibleSelectionSkip(purpose.windowId, purpose.paneId, "queue-client-proof")
        }
    }

    private fun handleVisibleSelectionPrimary(
        purpose: TmuxResponsePurpose.VisibleSelectionPrimary,
        success: Boolean,
    ) {
        if (!success) {
            purpose.agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            recordVisibleSelectionSkip(purpose.windowId, purpose.paneId, "select-control-client")
            return
        }
        val activeTargetQuery = if (purpose.paneId != null) {
            purpose.windowId?.let(SharedTmuxCommands::activePaneHydrationCommand)
        } else {
            SharedTmuxCommands.activeWindowHydrationCommand()
        }
        if (activeTargetQuery == null) {
            purpose.agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            recordVisibleSelectionSkip(purpose.windowId, purpose.paneId, "resolve-active-target-query")
            return
        }
        val queued = synchronized(tmuxTransportLock) {
            val stillCurrent = purpose.windowId?.let { windowId ->
                isCurrentVisibleSelection(
                    windowId,
                    purpose.paneId,
                    purpose.session,
                    purpose.selectionGeneration,
                    purpose.transportGeneration,
                    requireActiveWindow = false,
                )
            } ?: isCurrentVisibleSelectionContext(
                purpose.session,
                purpose.selectionGeneration,
                purpose.transportGeneration,
            )
            if (!stillCurrent) return@synchronized false
            enqueueTmuxPlatformCommand(
                TmuxControlCommand(
                    activeTargetQuery,
                    TmuxResponsePurpose.VisibleSelectionActiveWindow(
                        windowId = purpose.windowId,
                        paneId = purpose.paneId,
                        preservingWindowZoom = purpose.preservingWindowZoom,
                        session = purpose.session,
                        selectionGeneration = purpose.selectionGeneration,
                        transportGeneration = purpose.transportGeneration,
                        agentResponse = purpose.agentResponse,
                    ),
                ),
            )
        }
        if (!queued) {
            purpose.agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            recordVisibleSelectionSkip(purpose.windowId, purpose.paneId, "queue-active-target-proof")
        }
    }

    /**
     * The primary select reply and `%session-window-changed` are not atomic on
     * tmux's control stream. This fixed query is admitted only after the
     * primary reply, and the shared core folds its tagged result into the
     * snapshot before delivering this purpose. It therefore proves both that
     * the select took effect and that the ledger now names the same owner.
     */
    private fun handleVisibleSelectionActiveWindow(
        purpose: TmuxResponsePurpose.VisibleSelectionActiveWindow,
        success: Boolean,
        lines: List<String>,
    ) {
        val quotedSession = TmuxVisibleClientSelection.quotedArgument(purpose.session)
        val activeWindowId = if (purpose.paneId != null) {
            purpose.windowId?.takeIf { windowId ->
                SharedTmuxCommands.activePaneHydrationMatches(
                    windowId = windowId,
                    paneId = purpose.paneId,
                    lines = lines,
                )
            }
        } else {
            mutableTmuxSnapshot.value?.activeWindowId
                ?.takeIf { SharedTmuxCommands.activeWindowHydrationMatches(it, lines) }
                ?.takeIf { purpose.windowId == null || purpose.windowId == it }
        }
        if (!success || quotedSession == null || activeWindowId == null) {
            purpose.agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            recordVisibleSelectionSkip(purpose.windowId, purpose.paneId, "prove-active-target")
            return
        }
        val visibleOption = SharedTmuxCommands.authorityVisibleClientOption(tmuxDeviceIdentity.id)
        val queued = synchronized(tmuxTransportLock) {
            if (!isCurrentVisibleSelection(
                    activeWindowId,
                    purpose.paneId,
                    purpose.session,
                    purpose.selectionGeneration,
                    purpose.transportGeneration,
                )
            ) return@synchronized false
            enqueueTmuxPlatformCommand(
                TmuxControlCommand(
                    "show-options -qv -t $quotedSession $visibleOption",
                    TmuxResponsePurpose.VisibleSelectionOption(
                        windowId = activeWindowId,
                        paneId = purpose.paneId,
                        preservingWindowZoom = purpose.preservingWindowZoom,
                        session = purpose.session,
                        selectionGeneration = purpose.selectionGeneration,
                        transportGeneration = purpose.transportGeneration,
                        agentResponse = purpose.agentResponse,
                    ),
                ),
            )
        }
        if (!queued) {
            purpose.agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            recordVisibleSelectionSkip(activeWindowId, purpose.paneId, "queue-visible-option")
        }
    }

    private fun handleVisibleSelectionClosePreflight(
        purpose: TmuxResponsePurpose.VisibleSelectionClosePreflight,
        success: Boolean,
        lines: List<String>,
    ) {
        val activeWindowId = mutableTmuxSnapshot.value?.activeWindowId
            ?.takeIf { success && SharedTmuxCommands.activeWindowHydrationMatches(it, lines) }
        val command = "kill-window -t @${purpose.windowId}"
        val queued = synchronized(tmuxTransportLock) {
            if (activeWindowId == null ||
                !isCurrentVisibleSelectionContext(
                    purpose.session,
                    purpose.selectionGeneration,
                    purpose.transportGeneration,
                ) ||
                mutableTmuxSnapshot.value?.windows?.none { it.id == purpose.windowId } != false
            ) return@synchronized false

            val nextPurpose = if (activeWindowId == purpose.windowId) {
                // An active close changes the selected window to a successor
                // chosen by tmux, so it becomes the newest selection intent.
                // An inactive close below deliberately does not: otherwise a
                // close queued behind `select A` would retire A's still-live
                // visible-client proof and strand the Mosh painter.
                visibleClientSelectionGeneration += 1
                visibleSelectionNaturalFloor = lastNaturalMoshDeliveryId
                pendingVisibleClientRefresh = null
                activeVisibleClientRefreshGeneration = null
                acknowledgedVisibleClientRefreshGeneration = null
                TmuxResponsePurpose.VisibleSelectionPrimary(
                    windowId = null,
                    paneId = null,
                    preservingWindowZoom = false,
                    session = purpose.session,
                    selectionGeneration = visibleClientSelectionGeneration,
                    transportGeneration = purpose.transportGeneration,
                )
            } else {
                TmuxResponsePurpose.Ignore
            }
            enqueueTmuxPlatformCommand(TmuxControlCommand(command, nextPurpose))
        }
        if (!queued) {
            recordVisibleSelectionSkip(purpose.windowId, null, "close-preflight")
        }
    }

    private fun handleVisibleSelectionClients(
        purpose: TmuxResponsePurpose.VisibleSelectionClients,
        success: Boolean,
        lines: List<String>,
    ) {
        val quotedClient = TmuxVisibleClientSelection.quotedArgument(purpose.clientName)
        if (!success || quotedClient == null ||
            !TmuxVisibleClientSelection.isExactlyAttached(purpose.stamp, lines)
        ) {
            purpose.agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            recordVisibleSelectionSkip(purpose.windowId, purpose.paneId, "verify-attached")
            return
        }
        val queued = synchronized(tmuxTransportLock) {
            if (!isCurrentVisibleSelection(
                    purpose.windowId,
                    purpose.paneId,
                    purpose.session,
                    purpose.selectionGeneration,
                    purpose.transportGeneration,
                )
            ) return@synchronized false
            val target = TmuxVisibleClientSelection.qualifiedTarget(
                purpose.session, purpose.windowId, purpose.paneId,
            ) ?: return@synchronized false
            val zoomFlag = if (purpose.paneId != null && purpose.preservingWindowZoom) {
                "-Z "
            } else {
                ""
            }
            enqueueTmuxPlatformCommand(
                TmuxControlCommand(
                    "switch-client ${zoomFlag}-c $quotedClient -t $target",
                    TmuxResponsePurpose.VisibleSelectionCommit(
                        windowId = purpose.windowId,
                        paneId = purpose.paneId,
                        session = purpose.session,
                        selectionGeneration = purpose.selectionGeneration,
                        transportGeneration = purpose.transportGeneration,
                        clientName = purpose.clientName,
                        agentResponse = purpose.agentResponse,
                    ),
                ),
            )
        }
        if (!queued) {
            purpose.agentResponse?.complete(AgentTmuxControlAck(false, emptyList()))
            recordVisibleSelectionSkip(purpose.windowId, purpose.paneId, "queue-visible-switch")
        }
    }

    /**
     * The server reply proves the stamped client mutation, but the independent
     * Mosh driver may not have consumed that screen yet. Retain the exact
     * client identity, take a fresh driver-output cut, then ask tmux to redraw
     * that client. The first natural frame newer than that cut remains
     * rejected and starts one owner-correlated full repaint.
     */
    private fun handleVisibleSelectionCommit(
        purpose: TmuxResponsePurpose.VisibleSelectionCommit,
        success: Boolean,
        lines: List<String>,
    ) {
        var committed = false
        var pending: PendingVisibleClientRefresh? = null
        val owner = synchronized(tmuxTransportLock) {
            if (!success || TmuxVisibleClientSelection.quotedArgument(purpose.clientName) == null ||
                !isCurrentVisibleSelection(
                    purpose.windowId,
                    purpose.paneId,
                    purpose.session,
                    purpose.selectionGeneration,
                    purpose.transportGeneration,
                )
            ) return@synchronized null
            visibleClientCommittedSelectionGeneration = purpose.selectionGeneration
            pending = PendingVisibleClientRefresh(
                windowId = purpose.windowId,
                paneId = purpose.paneId,
                session = purpose.session,
                selectionGeneration = purpose.selectionGeneration,
                transportGeneration = purpose.transportGeneration,
                clientName = purpose.clientName,
            ).also { pendingVisibleClientRefresh = it }
            committed = true
            terminalSurface?.boundOwner?.takeIf { bound ->
                bound.transportGeneration == purpose.transportGeneration &&
                    bound.windowId == purpose.windowId &&
                    (purpose.paneId == null || bound.paneId == purpose.paneId)
            }
        }
        diagnostics.record(
            "tmux_visible_selection_commit",
            mapOf(
                "detail" to "success=$success ${owner?.let { "window=${it.windowId} pane=${it.paneId} epoch=${it.epoch} generation=${it.transportGeneration}" } ?: "owner=none"}",
                "transport" to diagnosticTransport,
            ),
        )
        purpose.agentResponse?.complete(AgentTmuxControlAck(committed, lines.take(32)))
        if (!success) {
            recordVisibleSelectionSkip(purpose.windowId, purpose.paneId, "switch-visible-client")
            return
        }
        if (!committed) {
            recordVisibleSelectionSkip(purpose.windowId, purpose.paneId, "commit-visible-selection")
            return
        }
        if (owner == null) {
            // Compose may not have mounted the owner yet. The retained proof
            // is consumed by the first exact live-surface bind.
            return
        }
        val handoffState = when {
            moshPainterHandoff.activeOwner != owner -> "inactive"
            moshPainterHandoff.awaitingCausalBoundary -> "awaiting"
            else -> "bounded"
        }
        diagnostics.record(
            "render_painter_handoff",
            mapOf(
                "detail" to "commit window=${owner.windowId} pane=${owner.paneId} epoch=${owner.epoch} generation=${owner.transportGeneration} handoff=$handoffState",
                "transport" to diagnosticTransport,
            ),
        )
        if (handoffState == "awaiting") {
            beginMoshPainterHandoff(
                owner,
                waitsForNaturalOutput = true,
                expectedVisibleRefresh = checkNotNull(pending),
            )
            return
        }
        // The bound handoff already saw the selected window's natural frame
        // (or finished its owned repaint) before this reply. A targeted
        // redraw of that same screen produces no SSP delta, so the retained
        // proof would only make the next rebind wait for output that cannot
        // come.
        synchronized(tmuxTransportLock) {
            if (pendingVisibleClientRefresh == pending) {
                pendingVisibleClientRefresh = null
                activeVisibleClientRefreshGeneration = null
                acknowledgedVisibleClientRefreshGeneration = null
            }
        }
    }

    private fun handleVisibleSelectionRefresh(
        purpose: TmuxResponsePurpose.VisibleSelectionRefresh,
        success: Boolean,
    ) {
        if (success) {
            val scheduling = synchronized(tmuxTransportLock) {
                val pending = pendingVisibleClientRefresh
                val owner = terminalSurface?.boundOwner
                if (pending == null || owner == null ||
                    pending.selectionGeneration != purpose.selectionGeneration ||
                    pending.transportGeneration != purpose.transportGeneration ||
                    pending.clientName != purpose.clientName ||
                    activeVisibleClientRefreshGeneration != purpose.selectionGeneration ||
                    pendingVisibleClientRefreshFor(owner) != pending ||
                    moshPainterHandoff.activeOwner != owner
                ) {
                    null
                } else {
                    val transport = moshTransport ?: return@synchronized null
                    acknowledgedVisibleClientRefreshGeneration = purpose.selectionGeneration
                    owner to transport
                }
            }
            if (scheduling != null) {
                val (owner, transportAtCut) = scheduling
                diagnostics.record(
                    "tmux_visible_selection_refresh_completed",
                    mapOf(
                        "detail" to "generation=${purpose.selectionGeneration} client=${purpose.clientName}",
                        "transport" to diagnosticTransport,
                    ),
                )
                scheduleMoshPainterCausalWatchdog(
                    owner = owner,
                    transportAtCut = transportAtCut,
                    expectedSelectionGeneration = purpose.selectionGeneration,
                )
            }
            return
        }
        val connectionToClose = synchronized(tmuxTransportLock) {
            val pending = pendingVisibleClientRefresh
            if (pending == null ||
                pending.selectionGeneration != purpose.selectionGeneration ||
                pending.transportGeneration != purpose.transportGeneration ||
                pending.clientName != purpose.clientName
            ) null else tmuxConnection
        }
        if (connectionToClose != null) {
            diagnostics.record(
                "tmux_visible_selection_refresh_failed",
                mapOf("transport" to diagnosticTransport),
            )
            // A successful visible switch without its causal redraw cannot be
            // rendered safely. Reconnect the side channel and rehydrate from
            // tmux truth while the UDP Mosh transport remains alive.
            connectionToClose.close()
        }
    }

    private fun scheduleMoshPainterCausalWatchdog(
        owner: RenderOwner,
        transportAtCut: AndroidMoshTransport?,
        expectedSelectionGeneration: Long?,
    ) {
        moshPainterCausalWatchdogJob?.cancel()
        moshPainterCausalWatchdogJob = scope.launch(Dispatchers.Main.immediate) {
            while (true) {
                delay(MOSH_PAINTER_CAUSAL_TIMEOUT_MS)
                val exactSelectionStillCurrent = synchronized(tmuxTransportLock) {
                    expectedSelectionGeneration == null ||
                        (activeVisibleClientRefreshGeneration == expectedSelectionGeneration &&
                            acknowledgedVisibleClientRefreshGeneration == expectedSelectionGeneration &&
                            pendingVisibleClientRefreshFor(owner)?.selectionGeneration ==
                                expectedSelectionGeneration)
                }
                if (moshTransport !== transportAtCut || terminalSurface?.boundOwner != owner ||
                    moshPainterHandoff.activeOwner != owner || !moshPainterHandoff.awaitingCausalBoundary ||
                    moshPainterHandoff.requestInFlight || !exactSelectionStillCurrent
                ) return@launch

                val connectivity = transportAtCut?.connectivity?.value
                if (connectivity?.state != MoshConnectionState.CONNECTED ||
                    !connectivity.transportReachable
                ) {
                    diagnostics.record(
                        "render_painter_handoff",
                        mapOf(
                            "detail" to "quiet-wait-unreachable window=${owner.windowId} pane=${owner.paneId} epoch=${owner.epoch} generation=${owner.transportGeneration}",
                            "transport" to diagnosticTransport,
                        ),
                    )
                    continue
                }
                val admission = moshPainterHandoff.settleQuietCanvas(owner)
                diagnostics.record(
                    "render_painter_handoff",
                    mapOf(
                        "detail" to "quiet-settle window=${owner.windowId} pane=${owner.paneId} epoch=${owner.epoch} generation=${owner.transportGeneration} admission=${admission::class.simpleName}",
                        "transport" to diagnosticTransport,
                    ),
                )
                moshPainterCausalWatchdogJob = null
                if (admission is MoshPainterHandoff.Admission.RejectAndStart) {
                    startMoshPainterHandoffRepaint(admission.owner)
                }
                return@launch
            }
        }
    }

    /** Only platform commands arrive here; the ledger consumed its own FIFO entries. */
    private fun handleTmuxPlatformReply(tag: Long, success: Boolean, lines: List<String>) = synchronized(tmuxTransportLock) {
        val purpose = activeTmuxResponses?.remove(tag) ?: return@synchronized
        val claimCommand = purpose as? TmuxResponsePurpose.ClaimCommand
        // The last reply is still progress until dispatch releases its repaint
        // or queues its next command. IO must never see just the decrement.
        if (claimCommand != null) noteAuthorityClaimReplyReceived(claimCommand.generation)
        try {
            dispatchTmuxPlatformReply(purpose, success, lines)
        } finally {
            // §6.10 rule 6: a late claim whose own last reply this was, with
            // no repaint in flight, has nothing left to finish it.
            if (claimCommand != null || purpose is TmuxResponsePurpose.WindowSizeReplayMutation ||
                purpose is TmuxResponsePurpose.WindowSizeReplayConfirmation
            ) endTmuxGridAuthorityClaimIfStalledLate("reply")
            // Finish a presented-window readiness reservation through ordinary
            // sizing, never a discovery force or claim permission.
            mutableTmuxSnapshot.value?.let(::reconcilePresentedTmuxWindowSize)
        }
    }

    private fun dispatchTmuxPlatformReply(purpose: TmuxResponsePurpose, success: Boolean, lines: List<String>) {
        when (purpose) {
            TmuxResponsePurpose.Ignore -> Unit
            TmuxResponsePurpose.ClientFlags -> {
                val flags = lines.firstOrNull { it.isNotBlank() }
                if (!success || flags == null) {
                    scheduleCompactSizeRoleRetry()
                } else {
                    compactSizeRole = if (flags.split(',', ' ', '\t').any { it == "ignore-size" }) {
                        CompactSizeRole.Observer
                    } else {
                        CompactSizeRole.Owner
                    }
                    reconcileTmuxClientSize()
                }
            }
            // Main delivers this reply, and the transport's callbacks read
            // the policy under the lock (a claim's confirmation and loss, the
            // stamp-less rule). Written outside it, a reader could see the
            // policy known but not yet `latest`, confirm on the fence's
            // acknowledgement alone and stamp at a foreign size; so the
            // check, the writes and everything judged from them share one
            // critical section, as the transport reset's clear does.
            is TmuxResponsePurpose.WindowSizePolicy -> synchronized(tmuxTransportLock) {
                // A side-channel claim's forces make the window `manual` for a
                // moment, which an ordinary read can catch; its fence reads
                // the policy behind them instead.
                if (!success || windowSizePolicyWindowId != purpose.windowId ||
                    (usesMoshPrimaryTransport() && liveAuthorityClaim() != null)
                ) {
                    return
                }
                val value = lines.firstOrNull { it.isNotBlank() }?.trim().orEmpty()
                windowSizePolicyKnown = true
                windowSizePolicyIsLatest = value.isEmpty() || value == "latest"
                reservePresentedTmuxWindowRecovery(mutableTmuxSnapshot.value)
                reduceTmuxAuthority { session, now -> session.windowSizePolicyReplied(now, purpose.windowId, value) }
                reconcileTmuxClientSize()
                // An own-stamp read whose window was off our size waited for
                // this: under a non-latest policy the mismatch is tmux's rule.
            }
            is TmuxResponsePurpose.AuthorityWindowSizePolicy -> synchronized(tmuxTransportLock) {
                // Speaks for the fence only while it is the claim's latest.
                if (closed || !isLiveAuthorityClaim(purpose.generation) ||
                    lastTmuxAuthorityResult?.claimFence?.id != purpose.fenceId
                ) return
                val value = lines.singleOrNull()?.trim()
                if (!success || value !in setOf("latest", "smallest", "largest", "manual")) {
                    abortTmuxGridAuthorityClaim(purpose.generation, "claim window-size policy unconfirmed")
                    return
                }
                // The ordinary cache follows the claim's own read. Updating it
                // must not reconcile geometry in the middle of this claim's
                // already ordered fence.
                windowSizePolicyKnown = true
                windowSizePolicyWindowId = purpose.windowId
                windowSizePolicyIsLatest = value == "latest"
                // The session confirms the fence once it has settled.
                reduceTmuxAuthority { session, now ->
                    session.windowSizePolicyReplied(now, purpose.windowId, value.orEmpty(), purpose.fenceId)
                }
            }
            is TmuxResponsePurpose.WindowSizeReplayMutation -> handleTmuxWindowSizeMutation(purpose, success)
            is TmuxResponsePurpose.WindowSizeReplayConfirmation -> handleTmuxWindowSizeConfirmation(purpose, success, lines)
            is TmuxResponsePurpose.OrdinaryWindowAuthority,
            is TmuxResponsePurpose.OrdinaryWindowControlClient,
            is TmuxResponsePurpose.OrdinaryWindowVisibleClient,
            is TmuxResponsePurpose.OrdinaryWindowClients -> handleOrdinaryTmuxWindowRecovery(purpose, success, lines)
            is TmuxResponsePurpose.CurrentDirectory -> {
                val path = lines.firstOrNull { line -> line.startsWith('/') && line.none(Char::isISOControl) }
                    .takeIf { success }
                purpose.onResult(path)
            }
            is TmuxResponsePurpose.CommandCompletion ->
                complete(purpose.receipt, if (success) null else "tmux_command_failed")
            is TmuxResponsePurpose.AuthorityClaimFence -> synchronized(tmuxTransportLock) {
                // A reply that outlived its claim or its fence acknowledges
                // nothing for the next one; nor does one for a window the
                // session has left, whose own fence follows.
                if (!isLiveAuthorityClaim(purpose.generation) ||
                    lastTmuxAuthorityResult?.claimFence?.id != purpose.fenceId ||
                    mutableTmuxSnapshot.value?.activeWindowId?.let { it != purpose.windowId } == true
                ) return
                // A re-fence's result is ignored, as iOS ignores every
                // fence's: it counts as answered either way. Its failure
                // used to abort the claim in any phase, even with the stamp
                // on the wire; a geometry loss's re-fence leaves the first
                // acknowledgement standing, and the window's return is what
                // confirms.
                if (!success && !purpose.refence) {
                    abortTmuxGridAuthorityClaim(
                        purpose.generation,
                        if (usesMoshPrimaryTransport()) "geometry fence failed" else "latest-client fence failed",
                    )
                    return
                }
                // The probe goes out first: a repaint the acknowledgement
                // confirms then queues behind it rather than ahead of it.
                if (purpose.epoch == authorityClaimGeometryEpoch) {
                    sendTmuxGridAuthoritySettleProbe(purpose.generation, purpose.fenceId, purpose.windowId)
                }
                reduceTmuxAuthority { session, now -> session.claimFenceAcknowledged(now, purpose.fenceId) }
                // Once per acknowledgement, never per event.
                if (liveAuthorityClaim()?.phase == SharedTmuxAuthorityClaimPhase.AWAITING_FENCE) {
                    recordAuthorityClaimGeometry("awaits-window", purpose.generation, "claim-fence")
                }
            }
            // Its reply is the progress: the stall check follows every claim reply.
            is TmuxResponsePurpose.AuthorityClaimOrdering -> Unit
            is TmuxResponsePurpose.AuthoritySettleSize -> synchronized(tmuxTransportLock) {
                if (!isLiveAuthorityClaim(purpose.generation) ||
                    lastTmuxAuthorityResult?.claimFence?.id != purpose.fenceId ||
                    purpose.epoch != authorityClaimGeometryEpoch ||
                    mutableTmuxSnapshot.value?.activeWindowId != purpose.windowId
                ) return
                val reported = if (success) tmuxWindowForceRule.reportedGeometry(purpose.windowId, lines.joinToString("\n")) else null
                if (reported == null) {
                    // Unanswered, the claim never lands: foreign layouts stay
                    // unsettled, and it confirms or stalls as before.
                    recordAuthorityClaimGeometry("settle-probe-unreadable", purpose.generation, "@${purpose.windowId}")
                    return
                }
                recordAuthorityClaimGeometry(
                    "settle-probe",
                    purpose.generation,
                    "@${purpose.windowId} reported=${reported.columns}x${reported.rows}",
                )
                // This answer is judged at its wire position on IO, and first:
                // a force proven below confirms the fence only on a window the
                // probe found at the target. A later return to our grid cannot
                // erase a foreign size already seen.
                observeAuthorityClaimWindow(purpose.windowId, reported, settleProbe = true, "settle-probe")
                // Side channel: a read after the unset's recalculation that
                // finds the window at a force's size proves that force, even
                // one whose own read caught another size first.
                pendingTmuxWindowSizeReplays[purpose.windowId]?.takeIf {
                    it.transportGeneration == tmuxTransportGeneration && it.requested == reported
                }?.let { attempt ->
                    pendingTmuxWindowSizeReplays.remove(purpose.windowId, attempt)
                    reportAuthorityClaimFenceForce()
                }
            }
            is TmuxResponsePurpose.AuthorityCommit -> {
                if (success && pendingAuthorityRepaintGeneration == purpose.generation) {
                    val result = synchronized(tmuxTransportLock) {
                        if (closed) return
                        tmuxAuthorityLifecycle.submit(authorityNow()) { session, now -> session.stampCommitSucceeded(now, purpose.generation) }
                            .also(::applyTmuxAuthorityLifecycle)
                    }
                    val claim = result.state.claim
                    if (claim?.generation == purpose.generation &&
                        claim.phase == com.bambouville.tessera.core.bridge.SharedTmuxAuthorityClaimPhase.AWAITING_SETTLEMENT
                    ) shared.completeTmuxGridAuthorityRepaint(purpose.generation)
                } else {
                    if (!success) synchronized(tmuxTransportLock) { abandonTmuxAuthorityOwnerScope(purpose.ownerSessionId, "owner-write-failed") }
                    abortTmuxGridAuthorityClaim(purpose.generation, "authority stamp failed")
                }
            }
            is TmuxResponsePurpose.AuthorityPaintGeometry -> {
                if (closed || pendingAuthorityPaintGeometry != purpose || purpose.transportGeneration != tmuxTransportGeneration) return
                pendingAuthorityPaintGeometry = null
                if (!isLiveAuthorityClaim(purpose.generation)) return
                if (success && mutableTmuxSnapshot.value?.activeWindowId == purpose.windowId &&
                    liveAuthorityClaim()?.targetGrid == purpose.requested &&
                    (authorityClaimPolicyIsFixed(purpose.windowId, purpose.generation) ||
                        tmuxWindowForceRule.reportedGeometry(purpose.windowId, lines.joinToString("\n")) == purpose.requested)
                ) commitTmuxGridAuthorityStamp(purpose.generation)
                else abortTmuxGridAuthorityClaim(purpose.generation, "post-frame geometry unconfirmed")
            }
            is TmuxResponsePurpose.AuthorityOwnerResolution -> synchronized(tmuxTransportLock) {
                handleTmuxAuthorityScopeReply(purpose, success, lines)
            }
            is TmuxResponsePurpose.AuthorityRederive -> synchronized(tmuxTransportLock) {
                if (closed || purpose.transportGeneration != tmuxTransportGeneration) return
                if (pendingAuthorityQuery == purpose) {
                    pendingAuthorityQuery = null
                    // Wire ownership accompanies the current read, including a held own reply.
                    foregroundAuthorityQueryOwner = purpose.renderOwner
                }
                diagnostics.record(
                    "tmux_authority_query_reply",
                    mapOf(
                        "detail" to "query=${purpose.sequence} success=$success",
                        "transport" to diagnosticTransport,
                    ),
                )
                val stampLines = if (success) SharedTmuxCommands.authorityQueryReplyLines(lines, purpose.ownerSessionId) else null
                if (stampLines != null) reduceTmuxAuthority { session, now -> session.queryReplied(now, purpose.sequence,
                    stampLines.joinToString("\n"), tmuxDeviceIdentity.id) }
                else {
                    if (success) abandonTmuxAuthorityOwnerScope(purpose.ownerSessionId, "owner-missing")
                    reduceTmuxAuthority { session, now -> session.queryFailed(now, purpose.sequence) }
                }
            }
            is TmuxResponsePurpose.VisibleSelectionPrimary ->
                handleVisibleSelectionPrimary(purpose, success)
            is TmuxResponsePurpose.VisibleSelectionActiveWindow ->
                handleVisibleSelectionActiveWindow(purpose, success, lines)
            is TmuxResponsePurpose.VisibleSelectionClosePreflight ->
                handleVisibleSelectionClosePreflight(purpose, success, lines)
            is TmuxResponsePurpose.VisibleSelectionOption ->
                handleVisibleSelectionOption(purpose, success, lines)
            is TmuxResponsePurpose.VisibleSelectionClients ->
                handleVisibleSelectionClients(purpose, success, lines)
            is TmuxResponsePurpose.VisibleSelectionCommit ->
                handleVisibleSelectionCommit(purpose, success, lines)
            is TmuxResponsePurpose.VisibleSelectionRefresh ->
                handleVisibleSelectionRefresh(purpose, success)
            is TmuxResponsePurpose.AgentCommand -> purpose.response.complete(agentTmuxControlReply(success, lines))
            is TmuxResponsePurpose.WindowMutationCommand ->
                handleTmuxWindowMutationCommand(purpose, success)
            is TmuxResponsePurpose.WindowMutationGroupMembers ->
                handleTmuxWindowMutationGroupMembers(purpose, success, lines)
        }
    }

    private fun finishLedgerAuthorityRepaint() {
        synchronized(tmuxTransportLock) {
            val generation = pendingAuthorityRepaintGeneration ?: return
            if (!isLiveAuthorityClaim(generation)) return
            if (!validateAuthorityMoshGeometry(mutableTmuxSnapshot.value)) return
            // The stamp follows this in the same turn, so this is the last
            // point at which a window off the claim's target can stop it:
            // the core tells our own geometry and a stale layout from a loss.
            if (authorityClaimWindowAtTarget(mutableTmuxSnapshot.value) == false) {
                observeAuthorityClaimLayout(mutableTmuxSnapshot.value, "repaint")
                endTmuxGridAuthorityClaimIfStalledLate("repaint")
                return
            }
            inlineAuthorityRepaintFence.reset()
            reduceTmuxAuthority { session, now -> session.repaintSucceeded(now, generation) }
        }
    }

    private fun inlineAuthorityRepaintTargets(
        declarations: List<SharedTmuxSurfaceDeclaration> = declaredTmuxRenderSurfaces,
    ): List<InlineAuthorityRepaintTarget> {
        val snapshot = mutableTmuxSnapshot.value ?: return emptyList()
        val windowId = snapshot.activeWindowId ?: return emptyList()
        val activeWindow = snapshot.windows.firstOrNull { it.id == windowId } ?: return emptyList()
        val mountedSurfaceIds = declarations.asSequence()
            .map(SharedTmuxSurfaceDeclaration::surfaceId)
            .filter { renderSurfaceForId(it) != null }
            .toSet()
        return validatedInlineAuthorityRepaintTargets(
            declarations = declarations,
            presentation = tmuxScreenRenderPresentation,
            activeWindowId = windowId,
            activePaneId = activeWindow.activePaneId,
            activePaneIds = activeWindow.panes.mapTo(mutableSetOf()) { it.id },
            mountedSurfaceIds = mountedSurfaceIds,
        )
    }

    private fun validatePendingInlineAuthorityRepaintTopology() {
        val generation = inlineAuthorityRepaintFence.generation ?: return
        if (!inlineAuthorityRepaintFence.matches(generation, inlineAuthorityRepaintTargets())) {
            abortTmuxGridAuthorityClaim(
                generation,
                "render surface topology changed during authority repaint",
            )
        }
    }

    private fun allocateMoshRepaintRequestId(): Long? {
        if (moshRepaintRequestCounter == Long.MAX_VALUE) return null
        moshRepaintRequestCounter += 1
        return moshRepaintRequestCounter
    }

    private fun retireMoshRepaintsThroughCurrent() {
        moshRenderHistoryRepaintRetryExecutor.cancelAllReceiptWatchdogs()
        moshRenderHistoryFence.retireRepaintsThrough(moshRepaintRequestCounter)
    }

    /** The claim an outstanding issue belongs to, if there is one. */
    private fun outstandingAuthorityMoshRepaintGeneration(): Long? =
        deferredAuthorityMoshRepaint?.claimGeneration
            ?: pendingAuthorityMoshRepaintTarget?.claimGeneration
            ?: pendingAuthorityRepaintGeneration?.takeIf { authorityMoshRepaintRequestId != null }

    /** Drop the local issue without deciding anything about the reservation. */
    private fun clearOutstandingAuthorityMoshRepaintIssue() {
        authorityMoshRepaintRequestId?.let(moshRenderHistoryFence::retireRepaintsThrough)
        deferredAuthorityMoshRepaint = null
        pendingAuthorityMoshRepaintTarget = null
        authorityMoshRepaintRequestId = null
        authorityMoshRepaintOwner = null
        authorityMoshRepaintLedgerOwner = null
        authorityMoshAcceptedDelivery = null
    }

    /**
     * Report that the frame this issue forced can no longer prove anything.
     *
     * Whether that kills the *claim* is not decided here: the fact goes to the
     * ledger, which holds the reservation, and the `transportFullFrameFailed`
     * effect it returns is the single place the claim is aborted. Both
     * platforms used to make that call privately and disagree about it.
     */
    private fun failOutstandingAuthorityMoshRepaint(detail: String) {
        val generation = outstandingAuthorityMoshRepaintGeneration() ?: return
        val ledgerOwner = authorityMoshRepaintLedgerOwner
        clearOutstandingAuthorityMoshRepaintIssue()
        if (!submitTmuxRenderFact(
                SharedTmuxRenderFact.TransportFullFramePresentationFailed(
                    surfaceId = TMUX_RENDER_LIVE_SURFACE_ID,
                    owner = ledgerOwner,
                    correlation = generation,
                    reason = detail,
                ),
            )
        ) abortTmuxGridAuthorityClaim(generation, detail)
    }

    /**
     * Take up a reservation the ledger has just (re-)issued.
     *
     * Called once per issue and once per re-issue: a claim's own geometry force
     * re-lays the window out, which rebinds the surface at a new epoch, and the
     * ledger re-emits the request against the replacement owner. Nothing here
     * asks whether the claim survives that -- it paints for the owner named and
     * lets the ledger discharge the reservation.
     */
    private fun issueAuthorityMoshRepaint(
        ledgerOwner: SharedTmuxRenderOwner?,
        transportGeneration: Long,
        generation: Long,
        reason: String,
    ) {
        if (!isLiveAuthorityClaim(generation)) {
            clearOutstandingAuthorityMoshRepaintIssue()
            return
        }
        val owner = ledgerOwner?.let { renderSurfaceOwner(it, transportGeneration) }
        if (ledgerOwner != null && owner == null) {
            // An owner the terminal seam cannot name can never be matched
            // against `boundOwner`, so the frame could never be proven.
            failOutstandingAuthorityMoshRepaint("ledger owner has no window or pane")
            return
        }
        // A frame already forced for a previous issue is rejected by the new
        // handoff; ask again under a request the handoff can adopt.
        authorityMoshRepaintRequestId?.let(moshRenderHistoryFence::retireRepaintsThrough)
        val requestId = allocateMoshRepaintRequestId() ?: run {
            failOutstandingAuthorityMoshRepaint("mosh repaint sequence exhausted")
            return
        }
        pendingAuthorityMoshRepaintTarget = null
        authorityMoshAcceptedDelivery = null
        authorityMoshRepaintRequestId = requestId
        authorityMoshRepaintOwner = owner
        authorityMoshRepaintLedgerOwner = ledgerOwner
        deferredAuthorityMoshRepaint = DeferredAuthorityMoshRepaint(generation, requestId, owner)
        recordAuthorityRepaint("issued", generation, "request=$requestId reason=$reason ${owner.traceLabel()}")
        if (!moshPainterHandoff.isActive) {
            scope.launch(Dispatchers.Main.immediate) {
                startDeferredAuthorityMoshRepaintIfReady()
            }
        } else {
            recordAuthorityRepaint(
                "waiting-for-painter-handoff",
                generation,
                "request=$requestId ${owner.traceLabel()}",
            )
        }
    }

    /**
     * The ledger re-issues a reservation only when it rebinds the surface to a
     * *different* owner. A handoff that keeps the same owner -- local input, a
     * revealed history retiring, a visible-selection commit -- produces no
     * ledger edge at all, yet [retireMoshRepaintsThroughCurrent] has just
     * invalidated the frame this issue forced. Ask the ledger to re-issue the
     * reservation it still holds; it supersedes the old issue and hands back a
     * fresh request. Whether the reservation survives is still never decided
     * here, and an owner change is left entirely to the rebind.
     */
    private fun reissueAuthorityMoshRepaintForUnchangedOwner(owner: RenderOwner) {
        val generation = outstandingAuthorityMoshRepaintGeneration() ?: return
        if (authorityMoshRepaintOwner != owner) return
        submitTmuxRenderFact(
            SharedTmuxRenderFact.CorrelatedTransportFullFrameRequested(
                surfaceId = TMUX_RENDER_LIVE_SURFACE_ID,
                reason = "painter-handoff",
                correlation = generation,
            ),
        )
    }

    /**
     * Starts a fail-closed bridge from an emptied ledger surface back to the
     * Mosh painter. A real window/pane identity switch must first observe one
     * natural SSP callback; initial and same-pane epoch binds can serialize a
     * repaint directly on the driver's queue after the current effect batch.
     */
    private fun beginMoshPainterHandoff(
        owner: RenderOwner,
        waitsForNaturalOutput: Boolean,
        expectedVisibleRefresh: PendingVisibleClientRefresh? = null,
    ) {
        if (!usesMoshPrimaryTransport()) return
        val visibleRefresh = synchronized(tmuxTransportLock) {
            val current = pendingVisibleClientRefreshFor(owner)
            if (expectedVisibleRefresh != null && current != expectedVisibleRefresh) return
            activeVisibleClientRefreshGeneration = current?.selectionGeneration
            acknowledgedVisibleClientRefreshGeneration = null
            current
        }
        val waitsForCausalOutput = waitsForNaturalOutput || visibleRefresh != null
        immediateMoshPainterHandoffJob?.cancel()
        immediateMoshPainterHandoffJob = null
        moshPainterCausalWatchdogJob?.cancel()
        moshPainterCausalWatchdogJob = null
        moshPainterReceiptWatchdogJob?.cancel()
        moshPainterReceiptWatchdogJob = null
        retireMoshRepaintsThroughCurrent()
        moshRenderHistoryFence.discardPending()
        queuedMoshLedgerRepaintFenceBatches.clear()
        reissueAuthorityMoshRepaintForUnchangedOwner(owner)
        // A switch this client asked for is bounded by the delivery seen when
        // the intent was queued: the selected window's frame may already have
        // landed, before or after the bind, and it counts. A switch observed
        // from the peer has no earlier instant to anchor to, so it waits for
        // the next delivery and the quiet watchdog covers a frame that raced
        // ahead of the bind.
        val observedNaturalDelivery = lastNaturalMoshDeliveryId
        val naturalOutputFloor = synchronized(tmuxTransportLock) {
            if (visibleRefresh != null || visibleClientSelectionAwaitingCommit()) {
                visibleSelectionNaturalFloor
            } else {
                observedNaturalDelivery
            }
        }
        moshPainterHandoff.begin(
            owner = owner,
            naturalOutputFloor = naturalOutputFloor,
            waitsForNaturalOutput = waitsForCausalOutput,
            observedNaturalDeliveryHighWater = observedNaturalDelivery,
        )
        val bounded = !moshPainterHandoff.awaitingCausalBoundary
        diagnostics.record(
            "render_painter_handoff",
            mapOf(
                "detail" to "begin window=${owner.windowId} pane=${owner.paneId} epoch=${owner.epoch} generation=${owner.transportGeneration} natural=$waitsForCausalOutput refresh=${visibleRefresh != null} floor=$naturalOutputFloor observed=$observedNaturalDelivery bounded=$bounded",
                "transport" to diagnosticTransport,
            ),
        )
        configurePainterFeedAdmission()
        if (visibleRefresh != null && !enqueuePendingVisibleClientRefresh(visibleRefresh, owner)) {
            val refreshStillCurrent = synchronized(tmuxTransportLock) {
                pendingVisibleClientRefreshFor(owner) == visibleRefresh &&
                    activeVisibleClientRefreshGeneration == visibleRefresh.selectionGeneration
            }
            if (refreshStillCurrent) {
                diagnostics.record(
                    "tmux_visible_selection_refresh_failed",
                    mapOf("detail" to "queue", "transport" to diagnosticTransport),
                )
                tmuxConnection?.close()
            }
            return
        }
        if (bounded) {
            scheduleMoshPainterHandoffRepaint(owner, retryAttempt = 0)
        } else if (visibleRefresh == null) {
            scheduleMoshPainterCausalWatchdog(
                owner = owner,
                transportAtCut = moshTransport,
                expectedSelectionGeneration = null,
            )
        }
    }

    private fun resetMoshPainterHandoff() {
        immediateMoshPainterHandoffJob?.cancel()
        immediateMoshPainterHandoffJob = null
        moshPainterCausalWatchdogJob?.cancel()
        moshPainterCausalWatchdogJob = null
        moshPainterReceiptWatchdogJob?.cancel()
        moshPainterReceiptWatchdogJob = null
        synchronized(tmuxTransportLock) {
            activeVisibleClientRefreshGeneration = null
            acknowledgedVisibleClientRefreshGeneration = null
        }
        moshPainterHandoff.reset()
        queuedMoshLedgerRepaintFenceBatches.clear()
        failOutstandingAuthorityMoshRepaint("mosh painter handoff reset")
    }

    /** Called only on Main; the driver operation itself moves to IO. */
    private fun startMoshPainterHandoffRepaint(expectedOwner: RenderOwner) {
        if (terminalSurface?.boundOwner != expectedOwner) return
        val admission = moshPainterHandoff.admission(
            deliveryId = null,
            repaintRequestId = null,
            liveOwner = expectedOwner,
        )
        if (admission !is MoshPainterHandoff.Admission.RejectAndStart) return

        moshPainterCausalWatchdogJob?.cancel()
        moshPainterCausalWatchdogJob = null
        moshPainterReceiptWatchdogJob?.cancel()
        moshPainterReceiptWatchdogJob = null
        immediateMoshPainterHandoffJob?.cancel()
        immediateMoshPainterHandoffJob = null
        val reservedAuthority = deferredAuthorityMoshRepaint
        val authority = reservedAuthority?.takeIf {
            isLiveAuthorityClaim(it.claimGeneration) &&
                it.requestId != null &&
                it.owner == expectedOwner &&
                authorityMoshRepaintOwner == expectedOwner
        }
        // The bind that started this handoff already had the ledger re-issue
        // any live reservation to its owner; one still pointing elsewhere is
        // stale.
        if (reservedAuthority != null && authority == null) {
            failOutstandingAuthorityMoshRepaint(
                "mosh render owner changed before authority repaint",
            )
        }
        val requestId = authority?.requestId ?: allocateMoshRepaintRequestId()
        if (requestId == null) {
            diagnostics.record(
                "render_transport_sequence_exhausted",
                mapOf("transport" to diagnosticTransport),
            )
            return
        }
        val start = moshPainterHandoff.start(requestId) ?: return
        diagnostics.record(
            "render_painter_handoff",
            mapOf(
                "detail" to "start request=$requestId window=${start.owner.windowId} pane=${start.owner.paneId} epoch=${start.owner.epoch} generation=${start.owner.transportGeneration}",
                "transport" to diagnosticTransport,
            ),
        )
        val attached = start.repaintFenceIds.all { fenceId ->
            moshRenderHistoryFence.attachTransportRequest(fenceId, requestId)
        }
        if (!attached) {
            retireMoshRepaintsThroughCurrent()
            moshRenderHistoryFence.discardPending()
            moshPainterHandoff.reset()
            configurePainterFeedAdmission()
            diagnostics.record(
                "render_history_repaint_unavailable",
                mapOf("detail" to "request=$requestId attach failed", "transport" to diagnosticTransport),
            )
            return
        }

        scope.launch {
            val outputTarget = try {
                if (authority != null) forceMoshAuthorityFullRepaint(requestId)
                else moshTransport?.forceFullRepaint(requestId)
            } catch (failure: Throwable) {
                if (failure is CancellationException) throw failure
                diagnostics.record(
                    "render_transport_full_frame_failed",
                    mapOf("detail" to redactedFailure(failure), "transport" to diagnosticTransport),
                )
                null
            }
            withContext(Dispatchers.Main.immediate) {
                val stillReservedForAuthority = deferredAuthorityMoshRepaint
                    ?.takeIf { it.requestId == requestId }
                if (stillReservedForAuthority != null) {
                    deferredAuthorityMoshRepaint = null
                    if (outputTarget == null) {
                        abortTmuxGridAuthorityClaim(
                            stillReservedForAuthority.claimGeneration,
                            "mosh repaint unavailable",
                        )
                    } else {
                        pendingAuthorityMoshRepaintTarget = PendingAuthorityMoshRepaint(
                            requestId = requestId,
                            outputTarget = outputTarget,
                            claimGeneration = stillReservedForAuthority.claimGeneration,
                            owner = stillReservedForAuthority.owner ?: start.owner,
                        )
                    }
                }

                if (outputTarget != null) {
                    start.repaintFenceIds.forEach { fenceId ->
                        moshRenderHistoryFence.resolveRepaint(fenceId, outputTarget)
                    }
                }
                diagnostics.record(
                    "render_painter_handoff",
                    mapOf(
                        "detail" to "resolved request=$requestId output=${outputTarget ?: "none"}",
                        "transport" to diagnosticTransport,
                    ),
                )
                val resolution = moshPainterHandoff.resolve(
                    requestId = requestId,
                    outputTarget = outputTarget,
                    liveOwner = terminalSurface?.boundOwner,
                )
                handleMoshPainterHandoffResolution(resolution)
                if (resolution == MoshPainterHandoff.Resolution.Pending && outputTarget != null) {
                    armMoshPainterReceiptWatchdog(
                        requestId = requestId,
                        outputTarget = outputTarget,
                        owner = start.owner,
                    )
                }
                completeAuthorityMoshRepaintIfReady()
            }
        }
    }

    private fun handleMoshPainterHandoffResolution(
        resolution: MoshPainterHandoff.Resolution,
    ) {
        when (resolution) {
            MoshPainterHandoff.Resolution.Pending,
            MoshPainterHandoff.Resolution.Stale,
            -> Unit
            is MoshPainterHandoff.Resolution.Rearmed -> {
                moshPainterReceiptWatchdogJob?.cancel()
                moshPainterReceiptWatchdogJob = null
                resolution.repaintFenceIds.forEach { fenceId ->
                    moshRenderHistoryFence.rearmCorrelatedRepaint(
                        fenceId,
                        resolution.retiredRequestId,
                    )
                }
                if (authorityMoshRepaintRequestId == resolution.retiredRequestId) {
                    failOutstandingAuthorityMoshRepaint("mosh repaint was not fully rendered")
                }
                configurePainterFeedAdmission()
                scheduleMoshPainterHandoffRepaint(
                    resolution.owner,
                    resolution.retryAttempt,
                )
            }
            is MoshPainterHandoff.Resolution.Completed -> {
                moshPainterReceiptWatchdogJob?.cancel()
                moshPainterReceiptWatchdogJob = null
                diagnostics.record(
                    "render_painter_handoff",
                    mapOf(
                        "detail" to "completed window=${resolution.owner.windowId} pane=${resolution.owner.paneId} epoch=${resolution.owner.epoch} generation=${resolution.owner.transportGeneration}",
                        "transport" to diagnosticTransport,
                    ),
                )
                synchronized(tmuxTransportLock) {
                    val generation = activeVisibleClientRefreshGeneration
                    val pending = pendingVisibleClientRefresh
                    if (generation != null && pending?.selectionGeneration == generation &&
                        pendingVisibleClientRefreshFor(resolution.owner) == pending
                    ) {
                        pendingVisibleClientRefresh = null
                    }
                    activeVisibleClientRefreshGeneration = null
                    acknowledgedVisibleClientRefreshGeneration = null
                }
                configurePainterFeedAdmission()
                drainQueuedMoshRepaints()
            }
        }
    }

    private fun armMoshPainterReceiptWatchdog(
        requestId: Long,
        outputTarget: Long,
        owner: RenderOwner,
    ) {
        moshPainterReceiptWatchdogJob?.cancel()
        moshPainterReceiptWatchdogJob = scope.launch(Dispatchers.Main.immediate) {
            delay(MOSH_RENDER_HISTORY_RECEIPT_TIMEOUT_MS)
            moshPainterReceiptWatchdogJob = null
            val resolution = moshPainterHandoff.receiptTimedOut(
                requestId = requestId,
                outputTarget = outputTarget,
                liveOwner = terminalSurface?.boundOwner,
            )
            if (resolution is MoshPainterHandoff.Resolution.Rearmed) {
                diagnostics.record(
                    "render_painter_handoff",
                    mapOf(
                        "detail" to "target-timeout request=$requestId target=$outputTarget window=${owner.windowId} pane=${owner.paneId} epoch=${owner.epoch} generation=${owner.transportGeneration}",
                        "transport" to diagnosticTransport,
                    ),
                )
            }
            handleMoshPainterHandoffResolution(resolution)
        }
    }

    private fun scheduleMoshPainterHandoffRepaint(
        owner: RenderOwner,
        retryAttempt: Int,
    ) {
        immediateMoshPainterHandoffJob?.cancel()
        immediateMoshPainterHandoffJob = scope.launch(Dispatchers.Main.immediate) {
            // Let the remainder of this ledger batch attach any ordered
            // history fence before the one full-frame request starts.
            yield()
            val retryDelaysMilliseconds = longArrayOf(0, 50, 200, 1_000)
            val retryDelay = retryDelaysMilliseconds[
                retryAttempt.coerceAtMost(retryDelaysMilliseconds.lastIndex)
            ]
            if (retryDelay > 0) delay(retryDelay)
            if (terminalSurface?.boundOwner == owner && moshPainterHandoff.activeOwner == owner &&
                !moshPainterHandoff.requestInFlight
            ) {
                startMoshPainterHandoffRepaint(owner)
            } else {
                diagnostics.record(
                    "render_painter_handoff",
                    mapOf(
                        "detail" to "scheduled-start-stale window=${owner.windowId} pane=${owner.paneId} epoch=${owner.epoch} generation=${owner.transportGeneration}",
                        "transport" to diagnosticTransport,
                    ),
                )
            }
        }
    }

    private suspend fun requestMoshLedgerRepaint() {
        val fenceId = moshRenderHistoryFence.reserveCorrelatedRepaint(
            painterOwner = terminalSurface?.boundOwner,
        )
        if (moshPainterHandoff.isActive) {
            if (!moshPainterHandoff.deferRepaintFence(fenceId)) {
                queuedMoshLedgerRepaintFenceBatches.addLast(listOfNotNull(fenceId))
            }
            return
        }
        runMoshLedgerRepaint(listOfNotNull(fenceId))
    }

    private suspend fun runMoshLedgerRepaint(
        fenceIds: List<Long>,
        retryAttempt: Int = 0,
    ) = moshRenderHistoryRepaintRetryExecutor.run(fenceIds, retryAttempt)

    private fun drainQueuedMoshRepaints() {
        if (queuedMoshLedgerRepaintFenceBatches.isEmpty() && deferredAuthorityMoshRepaint == null) {
            return
        }
        val batches = buildList {
            while (queuedMoshLedgerRepaintFenceBatches.isNotEmpty()) {
                add(queuedMoshLedgerRepaintFenceBatches.removeFirst())
            }
        }
        scope.launch(Dispatchers.Main.immediate) {
            batches.forEach { runMoshLedgerRepaint(it) }
            startDeferredAuthorityMoshRepaintIfReady()
        }
    }

    private suspend fun forceMoshAuthorityFullRepaint(requestId: Long): Long? {
        val transport = moshTransport ?: return null
        val resized = moshCanvasResizeMutex.withLock {
            val canvas = mutableMoshCanvasSize.value ?: return@withLock false
            if (closed || moshTransport !== transport) return@withLock false
            // The SSH geometry fence can beat the asynchronous resize writer.
            // Apply the latest device canvas before the native fence captures
            // its resize, sharing the writer's lock so an old queued request
            // cannot overwrite this resize after passing its stale-size check.
            transport.resize(canvas.columns, canvas.rows)
            true
        }
        if (!resized || closed || moshTransport !== transport) return null
        return transport.forceFullRepaint(requestId, requiringFreshRemoteState = true)
    }

    private suspend fun startDeferredAuthorityMoshRepaintIfReady() {
        if (moshPainterHandoff.isActive) return
        val reserved = deferredAuthorityMoshRepaint ?: return
        val generation = reserved.claimGeneration
        if (!isLiveAuthorityClaim(generation)) {
            deferredAuthorityMoshRepaint = null
            return
        }
        // A reservation made before any ledger bind carries no owner; the
        // forced frame then rides the untagged painter feed.
        val owner = reserved.owner
        val requestId = reserved.requestId
        if (authorityMoshRepaintRequestId != requestId ||
            authorityMoshRepaintOwner != owner ||
            terminalSurface?.boundOwner != owner
        ) {
            failOutstandingAuthorityMoshRepaint(
                "mosh render owner changed before authority repaint",
            )
            return
        }
        deferredAuthorityMoshRepaint = null
        recordAuthorityRepaint("forcing", generation, "request=$requestId ${owner.traceLabel()}")
        val outputTarget = try {
            forceMoshAuthorityFullRepaint(requestId)
        } catch (failure: Throwable) {
            if (failure is CancellationException) throw failure
            diagnostics.record(
                "render_transport_full_frame_failed",
                mapOf("detail" to redactedFailure(failure), "transport" to diagnosticTransport),
            )
            null
        }
        if (!isLiveAuthorityClaim(generation)) {
            moshRenderHistoryFence.retireRepaintsThrough(requestId)
            return
        }
        if (authorityMoshRepaintRequestId != requestId ||
            authorityMoshRepaintOwner != owner ||
            terminalSurface?.boundOwner != owner
        ) {
            // The painter rebound while the force was in flight. This issue is
            // dead, but the reservation is the ledger's: the rebind either
            // re-issued it against the new owner or failed it outright, and
            // that verdict has already been queued behind this batch.
            moshRenderHistoryFence.retireRepaintsThrough(requestId)
            recordAuthorityRepaint(
                "superseded",
                generation,
                "painter rebound during force ${terminalSurface?.boundOwner.traceLabel()}",
            )
            return
        }
        if (outputTarget == null) {
            failOutstandingAuthorityMoshRepaint("mosh repaint unavailable")
        } else {
            pendingAuthorityMoshRepaintTarget = PendingAuthorityMoshRepaint(
                requestId = requestId,
                outputTarget = outputTarget,
                claimGeneration = generation,
                owner = owner,
            )
            completeAuthorityMoshRepaintIfReady()
        }
    }

    /** One Main.immediate transaction for a wire callback's ordered effects. */
    private suspend fun executeTmuxRenderEffects(
        effects: List<SharedTmuxRenderEffect>,
        tmux: SshTmuxConnection,
        transportGeneration: Long,
        repaintEpoch: Long,
    ) {
        val runtime = synchronized(tmuxTransportLock) {
            tmuxCore.takeIf {
                !closed && tmuxConnection === tmux && tmuxTransportGeneration == transportGeneration
            }
        } ?: return
        val refreshAdmissions = RefreshFeedAdmissions()
        for (effect in effects) {
            val stillCurrent = synchronized(tmuxTransportLock) {
                !closed && tmuxConnection === tmux && tmuxTransportGeneration == transportGeneration
            }
            if (!stillCurrent) return
            when (effect) {
                // Already on the writer channel: `enqueueLedgerRenderCommands`
                // queued it inside the critical section that gave it its slot
                // in the reply FIFO.
                is SharedTmuxRenderEffect.SendCommand -> Unit
                is SharedTmuxRenderEffect.CommandReply ->
                    handleTmuxPlatformReply(effect.tag, effect.success, effect.lines)
                is SharedTmuxRenderEffect.BindSurface -> {
                    val surface = renderSurfaceForId(effect.surfaceId)
                    val owner = renderSurfaceOwner(effect.owner, transportGeneration)
                    if (surface == null || owner == null) {
                        diagnostics.record(
                            "render_surface_bind_unavailable",
                            mapOf("detail" to "surface=${effect.surfaceId}", "transport" to diagnosticTransport),
                        )
                    } else {
                        val ownerChanged = surface.boundOwner != owner
                        if (ownerChanged) {
                            val replacesHistory = effects.any { next ->
                                next is SharedTmuxRenderEffect.Feed && next.surfaceId == effect.surfaceId &&
                                    next.owner == effect.owner && next.source == com.bambouville.tessera.core.bridge.SharedTmuxRenderFeedSource.MoshHistory
                            }
                            // An inline deepen is a continuity break: the new
                            // owner epoch rebinds this surface immediately
                            // before the full-depth capture feeds it. The
                            // reader's latched gesture is what places them in
                            // the rebuilt transcript, so it must survive the
                            // bind exactly as a mosh history replacement does.
                            // Gated on this surface's own in-flight inline
                            // request, which mosh never takes, and on the
                            // rebind keeping the same window/pane: a request
                            // overtaken by a window switch is answered by the
                            // new pane's capture, and the gesture's pixel
                            // position measured the old transcript.
                            val inlineRecord = mutableTmuxInlineHistory.value[effect.surfaceId]
                            val inlineIdentityChanged = surface.boundOwner?.let {
                                it.windowId != owner.windowId || it.paneId != owner.paneId ||
                                    it.transportGeneration != owner.transportGeneration
                            } ?: false
                            val replacesInlineHistory = inlineRecord?.requestInFlight == true &&
                                !inlineIdentityChanged &&
                                effects.any { next ->
                                    next is SharedTmuxRenderEffect.Feed && next.surfaceId == effect.surfaceId &&
                                        next.owner == effect.owner &&
                                        next.source == com.bambouville.tessera.core.bridge.SharedTmuxRenderFeedSource.DeepRepaint
                                }
                            if (inlineRecord?.requestInFlight == true && inlineIdentityChanged) {
                                // `clearTmuxRenderHistory` only cancels the
                                // live surface's gesture; a grid pane's view
                                // is this surface's own. Cancelling leaves the
                                // new pane on its tail, exactly as a window
                                // switch without a request would, and the
                                // settle that answers the request then finds
                                // nothing pending to place.
                                surface.view.cancelHistoryScroll()
                            }
                            clearTmuxRenderHistory(
                                effect.surfaceId,
                                preservingHistoryScroll = replacesHistory || replacesInlineHistory,
                            )
                            // A window/pane move resets the ledger's own
                            // inline state, so the platform's exhaustion
                            // belief goes with it; an epoch-only rebind (the
                            // deepen itself) keeps it.
                            inlineRecord?.let { record ->
                                mutableTmuxInlineHistory.value = mutableTmuxInlineHistory.value +
                                    (effect.surfaceId to record.ownerRebound(inlineIdentityChanged))
                            }
                        }
                        moshRenderHistoryFence.retireSurfaceUnlessOwnedBy(effect.surfaceId, owner)
                        val previousOwner = surface.boundOwner
                        bindRenderSurface(surface, owner, "ledger")
                        if (ownerChanged && effect.surfaceId == TMUX_RENDER_LIVE_SURFACE_ID) {
                            moshLiveHistoryRevealed = false
                            val identityChanged = previousOwner?.let {
                                it.windowId != owner.windowId || it.paneId != owner.paneId
                            } ?: false
                            val carriesUnprovenBoundary = moshPainterHandoff.awaitingCausalBoundary &&
                                moshPainterHandoff.activeOwner?.let {
                                    it.windowId == owner.windowId && it.paneId == owner.paneId
                                } == true
                            beginMoshPainterHandoff(
                                owner = owner,
                                waitsForNaturalOutput = identityChanged || carriesUnprovenBoundary ||
                                    visibleClientSelectionAwaitingCommit(),
                            )
                        }
                    }
                }
                is SharedTmuxRenderEffect.Feed -> {
                    val result = synchronized(tmuxTransportLock) {
                        if (closed || tmuxConnection !== tmux || tmuxTransportGeneration != transportGeneration) {
                            SharedTmuxRenderBytes.StaleHandle
                        } else {
                            tmuxRenderBytesProbe?.invoke(effect.bytesRef) ?: runtime.takeRenderBytes(effect.bytesRef)
                        }
                    }
                    val bytes = when (result) {
                        is SharedTmuxRenderBytes.Available -> result.bytes
                        SharedTmuxRenderBytes.InvalidReference,
                        SharedTmuxRenderBytes.StaleHandle -> {
                            diagnostics.record(
                                "render_ledger_bytes_unavailable",
                                mapOf("detail" to "surface=${effect.surfaceId}", "transport" to diagnosticTransport),
                            )
                            // A promised ref becoming unreadable is a core /
                            // adapter ordering failure. Continuing on this
                            // control stream would leave a permanent hole in
                            // the terminal while the reply FIFO advances, so
                            // fence this exact channel and let the normal
                            // reconnect path rebuild from tmux truth.
                            tmux.close()
                            return
                        }
                    }
                    val surface = renderSurfaceForId(effect.surfaceId)
                    val owner = renderSurfaceOwner(effect.owner, transportGeneration)
                    if (surface != null && owner != null) {
                        if (effect.source == com.bambouville.tessera.core.bridge.SharedTmuxRenderFeedSource.MoshHistory) {
                            moshRenderHistoryFence.stageHistory(effect.surfaceId, owner, bytes)
                        } else {
                            val admitted = feedOwnedRenderBytes(
                                surface,
                                owner,
                                bytes,
                                effect.source.wireValue,
                            )
                            refreshAdmissions.noteFeed(effect.surfaceId, effect.owner, effect.source, admitted)
                            agentEndpoint?.noteTmuxOutput(owner.windowId, owner.paneId, bytes)
                        }
                    }
                }
                is SharedTmuxRenderEffect.SaveWindowModes -> {
                    val surface = renderSurfaceForId(effect.surfaceId)
                    val owner = surface?.boundOwner
                    if (surface != null) {
                        tmuxRenderClientModes.save(
                            windowId = effect.windowId,
                            paneId = owner?.paneId,
                            bracketedPaste = surface.snapshotNonSecretState().bracketedPaste,
                        )
                    }
                }
                is SharedTmuxRenderEffect.RestoreWindowModes -> {
                    val surface = renderSurfaceForId(effect.surfaceId)
                    val owner = surface?.boundOwner
                    if (surface != null && owner != null) {
                        val enabled = tmuxRenderClientModes.bracketedPaste(
                            windowId = effect.windowId,
                            paneId = owner.paneId,
                        )
                        feedOwnedRenderBytes(
                            surface,
                            owner,
                            (if (enabled) "\u001b[?2004h" else "\u001b[?2004l").encodeToByteArray(),
                            "window-mode-restore",
                        )
                    }
                }
                is SharedTmuxRenderEffect.ResolveSurfaceState -> {
                    val state = renderSurfaceForId(effect.surfaceId)?.snapshotNonSecretState()
                    if (state != null) {
                        val submitted = submitTmuxRenderFact(
                            fact = SharedTmuxRenderFact.SurfaceState(
                                surfaceId = effect.surfaceId,
                                request = effect.request,
                                altScreen = state.alternateScreen,
                                mouseMode = if (state.mouseMode == TerminalMouseMode.Tracking) {
                                    SharedTmuxRenderMouseMode.Tracking
                                } else {
                                    SharedTmuxRenderMouseMode.Off
                                },
                                columns = state.columns,
                                rows = state.rows,
                            ),
                            expectedTmux = tmux,
                            expectedRuntime = runtime,
                            expectedGeneration = transportGeneration,
                        )
                        if (!submitted) {
                            inlineAuthorityRepaintFence.generation?.let { generation ->
                                if (inlineAuthorityRepaintFence.expects(generation, effect.surfaceId)) {
                                    abortTmuxGridAuthorityClaim(
                                        generation,
                                        "authority repaint surface state was rejected for ${effect.surfaceId}",
                                    )
                                }
                            }
                        }
                    } else {
                        inlineAuthorityRepaintFence.generation?.let { generation ->
                            if (inlineAuthorityRepaintFence.expects(generation, effect.surfaceId)) {
                                abortTmuxGridAuthorityClaim(
                                    generation,
                                    "authority repaint surface state unavailable for ${effect.surfaceId}",
                                )
                            }
                        }
                    }
                }
                is SharedTmuxRenderEffect.ArmTimer -> {
                    renderTimers.remove(effect.token)?.cancel()
                    renderTimers[effect.token] = scope.launch(Dispatchers.Main.immediate) {
                        delay(effect.milliseconds.toLong())
                        submitTmuxRenderFact(
                            fact = SharedTmuxRenderFact.TimerFired(effect.token),
                            expectedTmux = tmux,
                            expectedRuntime = runtime,
                            expectedGeneration = transportGeneration,
                        )
                    }
                }
                is SharedTmuxRenderEffect.CancelTimer -> renderTimers.remove(effect.token)?.cancel()
                SharedTmuxRenderEffect.InitialRenderReady -> terminalSurface?.requestFullRepaint()
                SharedTmuxRenderEffect.RequestTransportFullFrame -> requestMoshLedgerRepaint()
                is SharedTmuxRenderEffect.HistoryReady -> {
                    val owner = renderSurfaceOwner(effect.owner, transportGeneration)
                    val accepted = owner != null && moshRenderHistoryFence.markReady(
                        surfaceId = effect.surfaceId,
                        owner = owner,
                        ready = MoshRenderHistoryDeliveryFence.Ready(
                            owner = effect.owner,
                            depth = effect.depth,
                            historySize = effect.historySize,
                            placement = effect.placement,
                        ),
                    )
                    if (!accepted) {
                        rejectMoshHistoryPresentation(
                            surfaceId = effect.surfaceId,
                            owner = effect.owner,
                            deliveryToken = null,
                            reason = "history-ready-fence-missing",
                        )
                        diagnostics.record(
                            "render_history_ready_dropped",
                            mapOf(
                                "detail" to "surface=${effect.surfaceId}",
                                "transport" to diagnosticTransport,
                            ),
                        )
                    }
                }
                is SharedTmuxRenderEffect.InlineHistorySettled -> {
                    val previous = mutableTmuxInlineHistory.value[effect.surfaceId]
                        ?: InlineTmuxHistoryRecord.Initial
                    tmuxInlineHistoryTimeouts.remove(effect.surfaceId)?.cancel()
                    mutableTmuxInlineHistory.value = mutableTmuxInlineHistory.value + (
                        effect.surfaceId to previous.settled(
                            owner = effect.owner,
                            depth = effect.depth,
                            historySize = effect.historySize,
                            canDeepen = effect.canDeepen,
                        )
                        )
                    // The bind before the capture reset this surface to the
                    // tail while keeping the gesture latched. Releasing it
                    // here places the reader at the distance from the bottom
                    // they had dragged to, now measured in the deeper
                    // transcript. A settle with no latched gesture only
                    // updates the record.
                    renderSurfaceForId(effect.surfaceId)?.view?.let { view ->
                        scope.launch(Dispatchers.Main.immediate) {
                            if (view.isHistoryScrollPending) view.completeHistoryScroll(view.topRow)
                        }
                    }
                    diagnostics.record(
                        "render_ledger_inline_history_settled",
                        mapOf(
                            "detail" to "surface=${effect.surfaceId} depth=${effect.depth} " +
                                "history=${effect.historySize} canDeepen=${effect.canDeepen}",
                            "transport" to diagnosticTransport,
                        ),
                    )
                }
                is SharedTmuxRenderEffect.RefreshCompleted -> {
                    val frameAdmitted = refreshAdmissions.take(effect.surfaceId, effect.owner)
                    val boundOwner = renderSurfaceForId(effect.surfaceId)?.boundOwner
                    // Judged under the lock IO begins and resets the fence
                    // under, and only for the repaint this batch was queued
                    // under: after a loss, a re-fence and a re-confirmation
                    // on IO, a completion of the lost repaint drained only
                    // now carries the same claim generation as the new one,
                    // and counting it would stamp while the new capture is
                    // in flight, unveiling a frame from before the loss.
                    synchronized(tmuxTransportLock) {
                        when (val receipt = inlineAuthorityRepaintFence.noteCompletion(
                            correlation = effect.correlation,
                            surfaceId = effect.surfaceId,
                            owner = effect.owner,
                            stage = effect.stage,
                            frameAdmitted = frameAdmitted,
                            boundOwner = boundOwner,
                            batchEpoch = repaintEpoch,
                        )) {
                            InlineAuthorityRepaintFence.Receipt.Ignored,
                            InlineAuthorityRepaintFence.Receipt.Pending,
                            -> Unit
                            InlineAuthorityRepaintFence.Receipt.Complete -> finishLedgerAuthorityRepaint()
                            is InlineAuthorityRepaintFence.Receipt.Rejected -> {
                                val generation = pendingAuthorityRepaintGeneration
                                if (generation == effect.correlation) {
                                    abortTmuxGridAuthorityClaim(generation, receipt.detail)
                                }
                            }
                        }
                    }
                }
                is SharedTmuxRenderEffect.RefreshFailed -> {
                    refreshAdmissions.forget(effect.surfaceId)
                    synchronized(tmuxTransportLock) {
                        val generation = pendingAuthorityRepaintGeneration
                        if (generation == effect.correlation &&
                            inlineAuthorityRepaintFence.isCurrent(effect.correlation, repaintEpoch)
                        ) {
                            // §6.10 rule 6: never wait on a repaint nothing
                            // retries. A visible claim fences and repaints
                            // again; a late one ends.
                            inlineAuthorityRepaintFence.reset()
                            stallTmuxGridAuthorityClaim(
                                generation,
                                "ledger repaint failed surface=${effect.surfaceId} reason=${effect.reason}",
                                canProgress = true,
                                fenceAgain = true,
                            )
                        }
                    }
                }
                is SharedTmuxRenderEffect.RequestCorrelatedTransportFullFrame ->
                    issueAuthorityMoshRepaint(
                        ledgerOwner = effect.owner,
                        transportGeneration = transportGeneration,
                        generation = effect.correlation,
                        reason = effect.reason,
                    )
                is SharedTmuxRenderEffect.TransportFullFrameCompleted -> {
                    if (pendingAuthorityRepaintGeneration == effect.correlation) {
                        finishLedgerAuthorityRepaint()
                    }
                }
                is SharedTmuxRenderEffect.TransportFullFrameFailed -> {
                    diagnostics.record(
                        "tmux_authority_repaint",
                        mapOf(
                            "detail" to "frame-failed g${effect.correlation} reason=${effect.reason}",
                            "transport" to diagnosticTransport,
                        ),
                    )
                    // "superseded" means a replacement request for this same
                    // correlation was emitted in the very same batch: the frame
                    // died, the reservation did not, and aborting would leave
                    // the veil up over a surface about to be repainted.
                    //
                    // Every other reason, "owner-changed" included, ends the
                    // claim here. A frame forced for a departed pane can never
                    // authorise the surface now on screen, and unlike the Apple
                    // controller this lifecycle has no re-fence transition to
                    // fall back into -- keeping the claim alive would strand it
                    // in awaitingRepaint with nothing left to re-issue it.
                    if (effect.reason != "superseded") {
                        clearOutstandingAuthorityMoshRepaintIssue()
                        if (pendingAuthorityRepaintGeneration == effect.correlation) {
                            abortTmuxGridAuthorityClaim(
                                effect.correlation,
                                "ledger transport frame failed surface=${effect.surfaceId} " +
                                    "reason=${effect.reason}",
                            )
                        }
                    }
                }
                is SharedTmuxRenderEffect.Diagnostic -> {
                    // These are the reducer's terminal outcomes for this exact
                    // live request. Stale presentation failures and normal
                    // freezing after a successful placement must not stop a glide.
                    val endedLiveRequest = effect.message.startsWith("render-ledger side-channel-request-ignored surface=live ") ||
                        effect.message == "render-ledger side-channel-watchdog surface=live" ||
                        effect.message == "render-ledger side-channel-frozen surface=live" ||
                        effect.message == "render-ledger history-presentation-failed surface=live"
                    if (endedLiveRequest) {
                        terminalSurface?.view?.takeIf { it.isHistoryScrollPending }?.cancelHistoryScroll()
                    }
                    if (effect.message.contains("side-channel-invalidated") ||
                        effect.message.contains("side-channel-skipped")
                    ) clearTmuxRenderHistory()
                    diagnostics.record(
                        "render_ledger",
                        mapOf("detail" to effect.message, "transport" to diagnosticTransport),
                    )
                }
            }
        }
    }

    /**
     * Publishes the exact surface topology chosen by Compose. Physical maps
     * remain executor lookup tables only; they must never infer whether the
     * user is looking at the single, grid, or detached-overlay presentation.
     */
    fun declareTmuxRenderSurfaces(declarations: List<SharedTmuxSurfaceDeclaration>) {
        require(declarations.map { it.surfaceId }.distinct().size == declarations.size) {
            "tmux render surface IDs must be unique"
        }
        synchronized(tmuxTransportLock) {
            // Snapshot callbacks redrive claims under this same monitor. They
            // must not observe the local live-surface flag before the ledger
            // has received the declaration that makes its reservation valid.
            declaredTmuxRenderSurfaces = declarations.sortedBy { it.surfaceId }
            // Withdraw admission before rejecting an old paint; admit a remount
            // only after its ledger declaration is valid.
            if (!authorityRepaintSurfacesReady()) submitAuthorityPaintability()
            validatePendingInlineAuthorityRepaintTopology()
            publishDeclaredTmuxRenderSurfaces()
            submitAuthorityPaintability()
            if (!closed) redriveDeferredAuthorityRepaint("surfaces-declared")
            // A remounted surface can paint a claim again.
        }
    }

    private fun publishDeclaredTmuxRenderSurfaces() = synchronized(tmuxTransportLock) {
        val declarations = declaredTmuxRenderSurfaces
        val declaredIds = declarations.mapTo(mutableSetOf()) { it.surfaceId }
        // A topology change can remove a parked overlay without running its
        // AndroidView callback first. Its old post must not acknowledge the
        // newly declared topology (or leave the shared latch pending).
        moshHistoryPresentationAcknowledgements.discardUndeclared(declaredIds).forEach { delivery ->
            rejectMoshHistoryPresentation(
                surfaceId = delivery.surfaceId,
                owner = delivery.owner,
                deliveryToken = delivery.deliveryToken,
                reason = "surface-no-longer-declared",
            )
        }
        mutableTmuxRenderHistory.value = mutableTmuxRenderHistory.value.filterKeys { id ->
            declarations.any { it.surfaceId == id }
        }
        initiallyRequestedTmuxRenderSurfaces.retainAll(declaredIds)
        if (!submitTmuxRenderFact(SharedTmuxRenderFact.SurfacesDeclared(declarations))) return@synchronized
        if (!usesMoshPrimaryTransport()) {
            declarations.forEach { declaration ->
                val authorityGeneration = inlineAuthorityRepaintFence.generation
                if (authorityGeneration != null && isLiveAuthorityClaim(authorityGeneration) &&
                    inlineAuthorityRepaintFence.expects(authorityGeneration, declaration.surfaceId)
                ) {
                    // Declaring the surface can synchronously redrive its
                    // deferred claim. That exact correlated capture (deep for
                    // a surface with no frame yet) also owns the first fill;
                    // an ordinary mount capture here would supersede it and
                    // abort the claim.
                    initiallyRequestedTmuxRenderSurfaces += declaration.surfaceId
                    return@forEach
                }
                if (declaration.surfaceId !in initiallyRequestedTmuxRenderSurfaces &&
                    submitTmuxRenderFact(
                        SharedTmuxRenderFact.RefreshRequested(
                            surfaceId = declaration.surfaceId,
                            stage = SharedTmuxRenderStage.Deep,
                            reason = "surface-mounted",
                        ),
                    )
                ) {
                    initiallyRequestedTmuxRenderSurfaces += declaration.surfaceId
                }
            }
        }
    }

    private fun quoteTmux(value: String): String {
        require(value.isNotBlank() && value.length <= 100 && value.none { it == '\n' || it == '\r' })
        return "'${value.replace("'", "'\\''")}'"
    }

    private suspend fun buildRoute(): List<SshRouteHop> = hosts.resolveRoute(host.id).map { saved ->
        val identity = saved.identityId?.let { identities.identity(it) }
        check(saved.identityId == null || identity != null) { "Saved route identity is unavailable" }
        SshRouteHop(
            id = saved.id,
            endpoint = SshEndpoint(saved.hostname, saved.port),
            username = saved.username,
            authentication = when {
                identity == null -> SshAuthentication.Password
                identity.credentialKind == CredentialKinds.ANDROID_KEYSTORE_P256 ->
                    SshAuthentication.AndroidKeystoreP256(identity.credentialReference)
                else -> error("Unsupported credential kind")
            },
        )
    }

    private suspend fun requestPassword(intent: SharedConnectionIntent, hop: SshRouteHop): CharArray {
        attemptPasswords[hop.id]?.let { return it.copyOf() }
        val challenge = CredentialChallenge(
            hopId = hop.id,
            username = hop.username,
            host = hop.endpoint.host,
            challengeId = UUID.randomUUID(),
            attemptId = intent.requestId,
            policyGeneration = intent.policyGeneration,
        )
        val pending = PendingCredential(challenge)
        pendingCredential = pending
        emitCredentialChallenge(challenge, challenge.challengeId)
        val accepted = pending.decision.await()
        pendingCredential = null
        if (!accepted) {
            pending.secret?.fill('\u0000')
            throw CancellationException("credential challenge cancelled")
        }
        return checkNotNull(pending.secret) { "approved credential response had no password" }.also {
            attemptPasswords[hop.id]?.fill('\u0000')
            attemptPasswords[hop.id] = it.copyOf()
        }
    }

    private suspend fun authorizeKey(
        intent: SharedConnectionIntent,
        hop: SshRouteHop,
        onOwnerAuthorization: () -> Unit = {},
    ) {
        val auth = hop.authentication as? SshAuthentication.AndroidKeystoreP256 ?: return
        if (!credentialStore.load(auth.alias).capabilities.ownerAuthenticationRequired) return
        withContext(Dispatchers.Main.immediate) {
            onOwnerAuthorization()
            val challenge = OwnerAuthorizationChallenge(
                challengeId = UUID.randomUUID(),
                attemptId = intent.requestId,
                policyGeneration = intent.policyGeneration,
                reason = "Use ${hop.username}@${hop.endpoint.host} key",
            )
            val pending = PendingOwnerAuthorization(challenge)
            pendingOwnerAuthorization = pending
            val accepted = try {
                emitOwnerAuthorizationChallenge(challenge, challenge.challengeId)
                pending.decision.await()
            } finally {
                if (pendingOwnerAuthorization === pending) pendingOwnerAuthorization = null
            }
            if (!accepted) throw CancellationException("owner authorization cancelled")
        }
    }

    private suspend fun verifyHostKey(
        intent: SharedConnectionIntent,
        observation: SshHostKeyObservation,
    ): Boolean {
        val evaluation = knownHosts.evaluate(
            observation.host,
            observation.port,
            observation.algorithm,
            observation.canonicalKeyBlob,
        )
        if (evaluation == HostTrustEvaluation.Trusted) return true
        val challenge = HostKeyChallenge(
            host = observation.host,
            port = observation.port,
            algorithm = observation.algorithm,
            fingerprint = fingerprint(observation.canonicalKeyBlob),
            changed = evaluation is HostTrustEvaluation.Changed,
            reverted = evaluation is HostTrustEvaluation.Reverted,
            previousFingerprint = when (evaluation) {
                is HostTrustEvaluation.Changed -> fingerprint(evaluation.previousCanonicalKeyBlob)
                is HostTrustEvaluation.Reverted -> fingerprint(evaluation.currentCanonicalKeyBlob)
                else -> null
            },
            challengeId = UUID.randomUUID(),
            attemptId = intent.requestId,
            policyGeneration = intent.policyGeneration,
        )
        val pending = PendingHostKey(challenge)
        pendingHostKey = pending
        emitHostKeyChallenge(challenge, challenge.challengeId)
        val accepted = pending.decision.await()
        pendingHostKey = null
        if (accepted) {
            knownHosts.trust(
                observation.host,
                observation.port,
                observation.algorithm,
                observation.canonicalKeyBlob,
            )
        }
        return accepted
    }

    private fun emitCredentialChallenge(challenge: CredentialChallenge, id: UUID): CoreCallResult =
        shared.emitCredentialChallenge(
            id,
            challenge.attemptId,
            challenge.policyGeneration,
            credentialId = null,
            kind = "password",
            lifetimeSeconds = SharedChallengeTiming.lifetimeSeconds,
        )

    private fun emitHostKeyChallenge(challenge: HostKeyChallenge, id: UUID): CoreCallResult =
        shared.emitHostKeyChallenge(
            id,
            challenge.attemptId,
            challenge.policyGeneration,
            challenge.host,
            challenge.port,
            challenge.fingerprint,
            hint = when {
                challenge.reverted -> "reverted"
                challenge.changed -> "changed"
                else -> "unknown"
            },
            lifetimeSeconds = SharedChallengeTiming.lifetimeSeconds,
        )

    private fun emitOwnerAuthorizationChallenge(challenge: OwnerAuthorizationChallenge, id: UUID): CoreCallResult =
        shared.emitOwnerAuthorizationChallenge(
            id,
            challenge.attemptId,
            challenge.policyGeneration,
            reasonCode = "ssh_key_use",
            lifetimeSeconds = SharedChallengeTiming.lifetimeSeconds,
        )

    private fun challengeResponseId(pending: PendingCredential): UUID = pending.registration.idForResponse(
        onRenewed = { recordChallengeRenewal("credential", it) },
    ) { emitCredentialChallenge(pending.challenge, it) }

    private fun challengeResponseId(pending: PendingHostKey): UUID = pending.registration.idForResponse(
        onRenewed = { recordChallengeRenewal("host_key", it) },
    ) { emitHostKeyChallenge(pending.challenge, it) }

    private fun challengeResponseId(pending: PendingOwnerAuthorization): UUID = pending.registration.idForResponse(
        onRenewed = { recordChallengeRenewal("owner_authorization", it) },
    ) { emitOwnerAuthorizationChallenge(pending.challenge, it) }

    private fun recordChallengeRenewal(kind: String, ageSeconds: Long) {
        diagnostics.record(
            "session_challenge_renewed",
            mapOf("kind" to kind, "ageSeconds" to ageSeconds.toString(), "transport" to diagnosticTransport),
        )
    }

    private fun applyChallengeDecision(command: SharedBackendCommand.SubmitChallengeResponse) {
        pendingCredential?.takeIf { it.registration.matches(command.challengeId) }?.let { pending ->
            pending.decision.complete(command.decision == SharedChallengeDecision.APPROVE)
            return
        }
        pendingHostKey?.takeIf { it.registration.matches(command.challengeId) }?.let { pending ->
            pending.decision.complete(command.decision == SharedChallengeDecision.APPROVE)
            return
        }
        pendingOwnerAuthorization?.takeIf { it.registration.matches(command.challengeId) }?.let { pending ->
            pending.decision.complete(command.decision == SharedChallengeDecision.APPROVE)
        }
    }

    private suspend fun restoreConnectedUiAfterSideChannelChallenge() {
        withContext(Dispatchers.Main.immediate) {
            if (transportConnected && currentIntent != null) {
                publishSessionState(SshSessionUiState.Connected)
            }
        }
    }

    private suspend fun readStream(
        input: InputStream,
        intent: SharedConnectionIntent,
        scansProgramStatus: Boolean = true,
    ) {
        val buffer = ByteArray(32 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (count == 0) continue
            if (currentIntent?.requestId != intent.requestId) break
            val copy = buffer.copyOf(count)
            if (scansProgramStatus) {
                // The detection reply goes out ahead of anything the
                // terminal answers for these bytes (DA follows the query).
                sessionProgramStatus?.feedRaw(copy)?.takeIf { it.isNotEmpty() }?.let { reply ->
                    commandChannel?.trySend(TransportCommand.Input(reply))
                }
            }
            agentEndpoint?.noteRawOutput(copy)
            emitSharedIfOpen { emitTerminalBytes(copy, attemptId = intent.requestId) }
        }
    }

    private fun teardownTransport() {
        invalidateAgentEndpoint()
        clearPendingChallenges()
        detachForwardingBlocking()
        attemptPasswords.values.forEach { it.fill('\u0000') }
        attemptPasswords.clear()
        updateMoshServerLiveness = null
        moshServerLivenessWatcher?.stop("transport-teardown")
        moshServerLivenessWatcher = null
        moshConnectivityJob?.cancel()
        moshConnectivityJob = null
        moshOutputJob?.cancel()
        moshOutputJob = null
        moshSideChannelJob?.cancel()
        moshSideChannelJob = null
        moshTransport?.close()
        moshTransport = null
        // Back to "this transport reports nothing". Leaving the last Mosh
        // reading behind would let a torn-down session answer a restore
        // verdict with a fact about a transport that no longer exists.
        mutableTransportReachable.value = null
        mutableMoshOutageTiming?.value = null
        moshAuthoritativeSize = null
        mutableMoshCanvasSize.value = null
        refreshTmuxWindowPaintScope()
        commandChannel?.close()
        commandChannel = null
        commandWriterJob?.cancel()
        commandWriterJob = null
        connection?.close()
        connection = null
        clearTmuxTransport()
        routeOwner?.close()
        routeOwner = null
        connectionJob?.cancel()
        connectionJob = null
        errorReaderJob?.cancel()
        errorReaderJob = null
    }

    /**
     * [preserveYieldedAuthority] keeps a peer verdict across a control-channel
     * retry. The mosh side channel is a separate SSH channel and drops on a
     * flaky link; resetting to Unknown there would lift the veil, unblock
     * input, and let this device resize the peer's windows on re-attach, with
     * both devices then typing into one grid. Fail closed instead — the user's
     * explicit take-back is the only way out. iOS' `resetGridAuthorityState`
     * takes the same `preserveYieldedPresentation` parameter.
     */
    private fun clearTmuxTransport(
        preserveYieldedAuthority: Boolean = false,
        retainSideChannelRuntime: Boolean = false,
    ) {
        recordRenderDropSummary("transport-lost")
        var commandChannel: Channel<TmuxControlCommand>? = null
        var writerJob: Job? = null
        var connectionToClose: SshTmuxConnection? = null
        var runtimeToClose: SharedTmuxRuntime? = null
        var parkedRuntimeToClose: SharedTmuxRuntime? = null
        var responses: ConcurrentHashMap<Long, TmuxResponsePurpose>? = null
        var bufferedCommands: List<TmuxControlCommand> = emptyList()
        var invalidatedTransportGeneration = 0L
        synchronized(tmuxTransportLock) {
            // Invalidate first. A callback already processing an old channel
            // holds this same lock; once this advances, no old callback or
            // writer can touch the logical-session reducer or the replacement
            // channel's response correlation.
            tmuxTransportGeneration += 1
            invalidatedTransportGeneration = tmuxTransportGeneration
            tmuxAuthorityOwnerSessionName = null
            authorityOwnerSessionId = null
            authorityScopeResolution = null
            authoritySubscriptionRequested = false
            desiredTmuxSubscriptions = SharedTmuxSubscriptions()
            heldAuthorityQueryId = null
            heldOrdinaryAuthorityRead = null
            declaredTmuxRenderSurfaces = emptyList()
            inlineAuthorityRepaintFence.reset()
            initiallyRequestedTmuxRenderSurfaces.clear()
            pendingTmuxWindowMutation?.timeoutJob?.cancel()
            pendingTmuxWindowMutation = null
            tmuxWindowMutationError = null
            mutableTmuxWindowMutationState.value = TmuxWindowMutationState.Unavailable
            pendingVisibleClientRefresh = null
            activeVisibleClientRefreshGeneration = null
            acknowledgedVisibleClientRefreshGeneration = null
            visibleClientCommittedSelectionGeneration = visibleClientSelectionGeneration
            // `close()` takes the closed edge under this lock before it
            // destroys the lifecycle handle, and the mosh side channel's
            // `finally` arrives here on the main dispatcher after that. The
            // reducer it would call is gone and the screen that would have
            // shown the reset has already disposed, so skip it the way every
            // other reducer site does; reducing anyway raised "tmux authority
            // lifecycle is closed" out of a `finally` and took the process
            // down on mosh+tmux teardown.
            reduceTmuxAuthority { session, now -> session.resetTransport(now, preservingPeer = preserveYieldedAuthority) }
            resetAuthorityFactMemos()
            commandChannel = tmuxCommandChannel
            tmuxCommandChannel = null
            agentTmuxControl.detach()
            pendingTmuxRenderBatches.clear()
            // The transport's callbacks read the policy under this lock, and
            // the policy reply writes it under it.
            windowSizePolicyKnown = false
            windowSizePolicyIsLatest = false
            windowSizePolicyWindowId = null
            writerJob = tmuxCommandWriterJob
            tmuxCommandWriterJob = null
            connectionToClose = tmuxConnection
            tmuxConnection = null
            // Let the ledger retire its pending generations before the ABI
            // handle is closed. The adapter also cancels its local timer jobs
            // below, so a queued callback cannot revive a dead transport.
            val activeRuntime = tmuxCore
            // Mosh can park this handle across retries, and requests survive
            // TransportLost. Clear them before parking so attach asks afresh
            // after its Agent endpoint exists; the old listener is fenced.
            if (retainSideChannelRuntime && !closed && usesMoshPrimaryTransport()) {
                activeRuntime?.setSubscriptions(desiredTmuxSubscriptions)
            }
            activeRuntime?.submitFact(SharedTmuxRenderFact.TransportLost)
            // Its event is filtered out above (the connection is gone): copy
            // the now-historical records directly.
            sessionProgramStatus?.pullTmux(activeRuntime)
            tmuxCore = null
            appliedTmuxRenderLedgerOptions = null
            if (retainSideChannelRuntime && !closed && usesMoshPrimaryTransport() && activeRuntime != null) {
                // The replacement listener captures a new connection and
                // transport generation.  Silence the old listener while the
                // control path is absent, but retain the ledger owners so
                // TransportAttached emits fresh-epoch binds on retry.
                activeRuntime.clearListener()
                parkedRuntimeToClose = parkedMoshTmuxCore?.takeUnless { it === activeRuntime }
                parkedMoshTmuxCore = activeRuntime
            } else {
                runtimeToClose = activeRuntime
                parkedRuntimeToClose = parkedMoshTmuxCore
                parkedMoshTmuxCore = null
            }
            responses = activeTmuxResponses
            activeTmuxResponses = null
        }
        commandChannel?.close()
        writerJob?.cancel()
        commandChannel?.let { channel ->
            val drained = mutableListOf<TmuxControlCommand>()
            while (true) {
                val request = channel.tryReceive().getOrNull() ?: break
                drained += request
            }
            bufferedCommands = drained
        }
        connectionToClose?.close()
        runtimeToClose?.close()
        parkedRuntimeToClose?.close()
        responses?.values?.forEach { pending ->
            pending.agentResponse?.complete(
                AgentTmuxControlAck(false, emptyList()),
            )
        }
        responses?.clear()
        bufferedCommands.forEach { request ->
            request.purpose?.agentResponse?.complete(
                AgentTmuxControlAck(false, emptyList()),
            )
        }
        renderTimers.values.forEach { it.cancel() }
        renderTimers.clear()
        // The reducer has just received TransportLost (or has been closed),
        // so there is no current latch to fail. Forget view callbacks before
        // their old posts can observe a replacement side channel.
        moshHistoryPresentationAcknowledgements.discardAll()
        mutableTmuxRenderHistory.value = emptyMap()
        // The ledger resets its inline state on transport loss, so the
        // platform's `canDeepen` belief and any in-flight latch go with it.
        // Note that ordinary `clearTmuxRenderHistory()` calls deliberately do
        // not: local input retires a mosh delivery but changes nothing about
        // how deep the inline capture is, and forgetting that here would
        // silently disable deepening after the first keystroke.
        clearTmuxInlineHistory()
        mutableTmuxSnapshot.value = null
        scope.launch(Dispatchers.Main.immediate) {
            val cleanupIsCurrent = synchronized(tmuxTransportLock) {
                tmuxTransportGeneration == invalidatedTransportGeneration && tmuxCore == null
            }
            if (!cleanupIsCurrent) return@launch
            retireMoshRepaintsThroughCurrent()
            moshRenderHistoryFence.discardPending()
            resetMoshPainterHandoff()
            moshLiveHistoryRevealed = false
            configurePainterFeedAdmission()
            publishScrollRouting()
        }
        pendingAuthorityRepaintGeneration = null
        pendingAuthorityMoshRepaintTarget = null
        authorityMoshRepaintRequestId = null
        authorityMoshRepaintOwner = null
        authorityMoshAcceptedDelivery = null
        // A read sent on the old channel can never be delivered; the
        // replacement's `attached()` asks again. A pending show or tap intent
        // survives in the reducer (R3), and so does its clock.

        pendingAuthorityQuery = null
        foregroundAuthorityClaimGeneration = null
        foregroundAuthorityClaimOwner = null
        lastPublishedTmuxSize = null
        restartCompactTmuxSizing()
        pendingTmuxWindowSizeReplays.clear()
        ordinaryTmuxWindowRecovery = null
        submitAuthorityOrdinaryRecovery()
        pendingAuthorityPaintGeometry = null
        resetAuthorityClaimGeometryState()
        lastWithheldTmuxClientSize = null
        compactSizeRole = CompactSizeRole.Unresolved
        compactSizeRoleQueryAttempts = 0
    }

    var agentAttachmentUpload: (suspend (SshRouteOwner, String) -> com.bambouville.tessera.agent.platform.AgentEndpointResult<String>)? = null
    var agentHostAsset: ((String) -> ByteArray)? = null

    private fun registerAgentEndpoint(
        route: SshRouteOwner,
        transport: AgentEndpointTransport,
        tmuxSession: String? = null,
        rawWriter: (suspend (ByteArray) -> Unit)? = null,
        tmuxControl: TmuxAgentControlPort? = null,
        routeMarker: String? = null,
        processRootPID: (() -> Int?)? = null,
        renewAuxiliaryRoute: (suspend (SshRouteOwner) -> SshRouteOwner)? = null,
        publishAuxiliaryRoute: (SshRouteOwner, SshRouteOwner) -> Boolean = { _, _ -> true },
    ) {
        invalidateAgentEndpoint()
        carrierGeneration += 1
        val endpoint = SshAgentSessionEndpoint(
            key = AgentSessionKey(sessionId, carrierGeneration),
            hostID = host.id,
            hostDisplayLabel = host.displayName.ifBlank { host.id },
            transport = transport,
            route = route,
            tmuxSession = tmuxSession,
            rawWriter = rawWriter,
            tmuxControl = tmuxControl,
            routeMarker = routeMarker,
            processRootPID = processRootPID,
            diagnostics = { code, values -> diagnostics.record(code, values) },
            attachmentUpload = { uploadRoute, uri ->
                agentAttachmentUpload?.invoke(uploadRoute, uri)
                    ?: com.bambouville.tessera.agent.platform.AgentEndpointResult.Unavailable("File uploads are unavailable")
            },
            hostAsset = { name -> checkNotNull(agentHostAsset) { "Bundled host artifacts unavailable" }(name) },
            renewAuxiliaryRoute = renewAuxiliaryRoute,
            publishAuxiliaryRoute = publishAuxiliaryRoute,
            retireFailedControlRoute = if (transport == AgentEndpointTransport.MOSH_TMUX) { failed ->
                if (routeOwner === failed) scope.launch(Dispatchers.IO) {
                    // The existing control-loop reconnects this SSH sidecar;
                    // the visible Mosh transport and remote server survive.
                    failed.close()
                }
                Unit
            } else null,
        )
        agentEndpoint = endpoint
        mutableAgentEndpointBinding.value = endpoint.binding.value
        agentEndpointBindingJob = scope.launch {
            endpoint.binding.collect { binding ->
                if (agentEndpoint === endpoint) mutableAgentEndpointBinding.value = binding
            }
        }
        endpoint.noteRawSnapshot(terminalSurface?.snapshotText())
        // Agent Center inspections read the live screen when they happen;
        // the terminal owns its state on Main.
        endpoint.setRawSnapshotSource {
            withContext(Dispatchers.Main.immediate) { terminalSurface?.snapshotText() }
        }
        if (endpoint.binding.value.isPublishableAgentBinding()) {
            agentRegistration = agentSessions.register(endpoint)
        }
    }

    private fun publishAgentEndpointIfReady(endpoint: SshAgentSessionEndpoint) {
        if (agentEndpoint !== endpoint || agentRegistration != null) return
        val binding = endpoint.binding.value
        if (!binding.isPublishableAgentBinding()) return
        agentRegistration = agentSessions.register(endpoint)
    }

    private fun invalidateAgentEndpoint() {
        val endpoint = agentEndpoint
        val registration = agentRegistration
        registration?.close()
        if (registration == null) endpoint?.close()
        agentRegistration = null
        agentEndpointBindingJob?.cancel()
        agentEndpointBindingJob = null
        agentEndpoint = null
        mutableAgentEndpointBinding.value = null
        carrierGeneration += 1
    }

    private fun clearPendingChallenges() {
        pendingCredential?.let {
            it.secret?.fill('\u0000')
            it.decision.cancel()
        }
        pendingCredential = null
        pendingHostKey?.decision?.cancel()
        pendingHostKey = null
        pendingOwnerAuthorization?.decision?.cancel()
        pendingOwnerAuthorization = null
    }

    private fun handleCommandRejected(code: String, commandCode: String?) {
        diagnostics.record(
            "command_rejected",
            mapOf("code" to code, "command" to (commandCode ?: "unknown")),
        )
        // Disconnect first advances the shared state to disconnected and then asks the backend
        // to tear down. A transportDisconnected callback that wins that race is correctly
        // rejected as stale by the core, but it cannot turn an explicit user teardown into a
        // failed session.
        if (explicitDisconnect) return
        val challengeResponseRejected = commandCode == "submit_challenge_response"
        if (!code.startsWith("challenge_") && !challengeResponseRejected) {
            publishSessionState(SshSessionUiState.Failed("Session command rejected: $code"))
            return
        }
        clearPendingChallenges()
        if (transportConnected && currentIntent != null) {
            publishSessionState(SshSessionUiState.Connected)
            return
        }
        val attemptId = currentIntent?.requestId
        teardownTransport()
        currentIntent = null
        if (attemptId != null) runCatching { shared.cancelConnect(attemptId) }
        publishSessionState(SshSessionUiState.Failed("Session command rejected: $code"))
    }

    private inline fun emitSharedIfOpen(action: SharedSessionRuntime.() -> Unit) {
        if (!closed) runCatching { shared.action() }
    }

    /**
     * Swift authority:
     * `Packages/TesseraCore/Sources/TesseraTrustCore/HostKeyFingerprint.swift`
     * (`SSHHostPublicKey.sha256Fingerprint`) via `KnownHostKeys`. One
     * implementation of the spelling the user compares by eye.
     */
    private fun fingerprint(bytes: ByteArray): String = KnownHostKeys.fingerprint(bytes)

    private fun failureMessage(code: String, arguments: Map<String, String>): String = when {
        code == "mosh_server_lost" -> moshServerLostMessage()
        code == "ssh_connection_failed" && SharedSessionPolicy.shouldRetry(
            explicitDisconnect = false,
            hadConnectedTransport = true,
            alreadyRecovering = false,
            code = code,
            arguments = arguments,
        ) ->
            "Connection interrupted. Check the network and retry."
        else -> arguments["detail"]?.takeIf(String::isNotBlank) ?: code.replace('_', ' ')
    }

    private fun scheduleReconnect(reason: String) {
        if (closed || explicitDisconnect || reconnectJob?.isActive == true) return
        if (reconnectAttempt >= SharedSessionPolicy.retryMaxAttempts()) {
            recoveringUnexpectedDisconnect = false
            publishSessionState(SshSessionUiState.Failed(
                "Connection interrupted. Check the network and retry.",
            ))
            diagnostics.record(
                "session_reconnect_exhausted",
                mapOf("reason" to reason, "transport" to diagnosticTransport),
            )
            return
        }
        recoveringUnexpectedDisconnect = true
        reconnectAttempt += 1
        publishSessionState(SshSessionUiState.Connecting)
        val attempt = reconnectAttempt
        diagnostics.record(
            "session_reconnect_scheduled",
            mapOf("attempt" to attempt.toString(), "reason" to reason, "transport" to diagnosticTransport),
        )
        reconnectJob = scope.launch {
            connectionJob?.join()
            // The ladder and the attempt cap are the shared core's.
            delay(SharedSessionPolicy.retryDelayMilliseconds(attempt))
            if (closed || explicitDisconnect) return@launch
            if (!appForeground || !presentationActive) {
                // Parked, not connecting. The wait below has no bound — a tab
                // the user is not looking at stays here for as long as they
                // leave it there — and claiming `Connecting` through it tells
                // the session list about an attempt that has not started, and
                // hands the foreground restore window a verdict of `pending`
                // that can never change on a session it exists to rescue.
                publishSessionState(SshSessionUiState.Disconnected)
                diagnostics.record(
                    "session_reconnect_parked",
                    mapOf("attempt" to attempt.toString(), "transport" to diagnosticTransport),
                )
                while (!closed && !explicitDisconnect && (!appForeground || !presentationActive)) delay(100)
                if (closed || explicitDisconnect) return@launch
                publishSessionState(SshSessionUiState.Connecting)
            }
            diagnostics.record(
                "session_reconnect_start",
                mapOf("attempt" to attempt.toString(), "transport" to diagnosticTransport),
            )
            currentIntent = null
            reconnectJob = null
            connect()
        }
    }

    /**
     * Reconnect because the foreground restore window ruled this session dead.
     *
     * Distinct from the ladder in two ways that matter. It does not wait to be
     * presented: the wake owes the user every session that died, not just the
     * one on screen. And it cancels any parked ladder attempt first, because
     * that attempt ends with `currentIntent = null` followed by `connect()` —
     * it forces the guard that would otherwise make a second connect a no-op.
     * Leaving it armed next to this one is how a single host ends up with two
     * transports: a ghost shell, or a second tmux -CC control client fighting
     * the first for the window.
     *
     * The caller is the restore window, which defers behind the app lock, so
     * this never fires while a credential or host-key prompt would be raised
     * under the lock overlay where nobody can answer it.
     */
    fun reconnectForRestore() {
        if (closed || explicitDisconnect) return
        reconnectJob?.cancel()
        reconnectJob = null
        // The wake is a fresh start for the ladder's budget: whatever exhausted
        // it belonged to the network the app was on before it went away.
        reconnectAttempt = 0
        recoveringUnexpectedDisconnect = false
        if (currentIntent != null) {
            diagnostics.record(
                "session_restore_reconnect_skipped",
                mapOf("reason" to "connect-in-flight", "transport" to diagnosticTransport),
            )
            return
        }
        diagnostics.record(
            "session_restore_reconnect",
            mapOf("state" to mutableState.value::class.java.simpleName, "transport" to diagnosticTransport),
        )
        publishSessionState(SshSessionUiState.Connecting)
        connect()
    }

    private fun redactedFailure(failure: Throwable): String = when (failure) {
        is CancellationException -> "cancelled"
        is KeyPermanentlyInvalidatedException -> "Android Keystore key was invalidated; generate and select a replacement key"
        else -> buildString {
            append(failure::class.java.simpleName)
            failure.message?.let { message ->
                append(": ")
                append(
                    message.replace(
                        Regex("(?i)(password|passphrase|secret|token)=[^ ]+"),
                        "$1=<redacted>",
                    ),
                )
            }
        }.take(300)
    }

    private class PendingCredential(val challenge: CredentialChallenge) {
        val registration = SharedChallengeRegistration(challenge.challengeId)
        val decision = CompletableDeferred<Boolean>()
        val responseSubmitted = AtomicBoolean(false)
        var secret: CharArray? = null
    }

    private class PendingHostKey(val challenge: HostKeyChallenge) {
        val registration = SharedChallengeRegistration(challenge.challengeId)
        val decision = CompletableDeferred<Boolean>()
        val responseSubmitted = AtomicBoolean(false)
    }

    private class PendingOwnerAuthorization(val challenge: OwnerAuthorizationChallenge) {
        val registration = SharedChallengeRegistration(challenge.challengeId)
        val decision = CompletableDeferred<Boolean>()
        val responseSubmitted = AtomicBoolean(false)
    }

    private sealed interface TransportCommand {
        data class Input(val bytes: ByteArray) : TransportCommand
        data class Resize(val columns: Int, val rows: Int) : TransportCommand
    }

    private data class MoshResizeRequest(
        val transport: AndroidMoshTransport,
        val size: SharedTmuxGridSize,
    )

    private enum class CompactSizeRole { Unresolved, Observer, Owner }
    private enum class MoshRunResult { COMPLETED, FALLBACK_TO_SSH }

    private companion object {
        /** A harness-built controller's records: none, ever. */
        val NO_PROGRAM_STATUS: StateFlow<SharedProgramStatusSnapshot> =
            MutableStateFlow(SharedProgramStatusSnapshot.EMPTY).asStateFlow()
        const val TMUX_WINDOW_MUTATION_TIMEOUT_MILLIS = 5_000L
        /** Why a late claim held a client size back (§6.10 rule 2); its settlement replays it. */
        const val LATE_CLAIM_WITHHOLDING = "late claim"
        /**
         * How the ledger's `refresh-client -C` begins, to recognise one in a
         * run it emitted as a claim's wire work (L2). Recognition only: the
         * core spells and sends every `-C` (`TmuxClientSizeReplay`).
         */
        const val TMUX_CLIENT_SIZE_COMMAND_PREFIX = "refresh-client -C "
        /**
         * Quiet-settle bound for a handoff still waiting on its first natural
         * delivery. A selected window whose canvas equals the previous one
         * produces no SSP delta at all, so this is the only way such a switch
         * ever paints; a frame that is merely late still lands afterwards and
         * heals a premature settle. Kept short for that reason.
         */
        const val MOSH_PAINTER_CAUSAL_TIMEOUT_MS = 400L
        const val MOSH_RENDER_HISTORY_RECEIPT_TIMEOUT_MS = 4_000L
        /**
         * Watchdog for an inline `scrollbackRequested` whose
         * `inlineHistorySettled` never arrived. A full-depth capture of a
         * 10 000-line pane is well inside this, and the cost of firing early
         * is only a placement at the current top row.
         */
        const val INLINE_HISTORY_SETTLE_TIMEOUT_MILLIS = 4_000L
        const val RENDER_DROP_SUMMARY_INTERVAL_MILLISECONDS = 60_000L
        const val MOSH_JUMP_FALLBACK_TIMEOUT_MS = 8_000L
        const val MOSH_EXPLICIT_CLEANUP_TIMEOUT_MS = 15_000L
        const val MAX_MOSH_PRECONNECT_OUTPUT_BYTES = 8 * 1024 * 1024
        /// Enough to hold a shell's "command not found" plus a banner; the
        /// classification never needs more than the launch window.
        const val MAX_TMUX_LAUNCH_OUTPUT_CHARS = 4 * 1024
    }
}

internal fun AgentEndpointBinding.isPublishableAgentBinding(): Boolean = when (transport) {
    AgentEndpointTransport.SSH, AgentEndpointTransport.MOSH -> true
    AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX ->
        windowID != null && paneID != null
}
