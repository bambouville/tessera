package com.bambouville.tessera.feature.session

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.res.Resources
import android.graphics.Typeface
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.indication
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.text.KeyboardActions
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Icon
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.LongState
import androidx.compose.runtime.MutableLongState
import androidx.compose.runtime.NonRestartableComposable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.zIndex
import androidx.core.net.toUri
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import com.bambouville.tessera.core.bridge.SharedProgramStatusSnapshot
import com.bambouville.tessera.core.bridge.SharedArtifacts
import com.bambouville.tessera.core.bridge.SharedArtifactsLinkClass
import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminal
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedArmedModifiers
import com.bambouville.tessera.core.bridge.SharedInputEncoding
import com.bambouville.tessera.core.bridge.SharedModifierArming
import com.bambouville.tessera.core.bridge.SharedModifierArmingEvent
import com.bambouville.tessera.core.bridge.SharedModifierBehavior
import com.bambouville.tessera.core.bridge.SharedModifierName
import com.bambouville.tessera.core.bridge.SharedTmuxCellRect
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.core.bridge.SharedTmuxPane
import com.bambouville.tessera.core.bridge.SharedTmuxPeerLabel
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import com.bambouville.tessera.core.bridge.SharedTmuxGridPresentation
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.data.KnownHostsRepository
import com.bambouville.tessera.data.HostRepository
import com.bambouville.tessera.data.IdentityRepository
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.AutomaticTerminalThemeId
import com.bambouville.tessera.data.resolvedTerminalThemeId
import com.bambouville.tessera.data.SessionRestoreRepository
import com.bambouville.tessera.data.continuity.AndroidForegroundRestoreStore
import com.bambouville.tessera.data.continuity.SessionRestorePresentationPolicy
import com.bambouville.tessera.data.continuity.SessionRestorePolicy
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationActionRequest
import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationCoordinator
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationStatus
import com.bambouville.tessera.agent.platform.AgentSessionKey
import com.bambouville.tessera.agent.platform.LiveAgentSessionRegistry
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.data.AccessoryBarKey
import com.bambouville.tessera.data.accessoryBarDefaults
import com.bambouville.tessera.terminal.TermuxTerminalSurface
import com.bambouville.tessera.terminal.TerminalFont
import com.bambouville.tessera.terminal.TerminalTheme
import com.bambouville.tessera.terminal.hideSoftwareKeyboard
import com.bambouville.tessera.terminal.TerminalCursorStyle
import com.bambouville.tessera.terminal.TerminalSearchResult
import com.bambouville.tessera.terminal.TerminalKeyboardViewportPolicy
import com.bambouville.tessera.terminal.TerminalSelectionPathAction
import com.bambouville.tessera.terminal.TerminalBackgroundFillMode
import com.bambouville.tessera.terminal.TerminalBackgroundImage
import com.bambouville.tessera.terminal.TerminalBackgroundImageStore
import com.bambouville.tessera.files.PendingShareUpload
import com.bambouville.tessera.files.RemoteFileKind
import com.bambouville.tessera.files.RemoteFilesController
import com.bambouville.tessera.files.RemoteFilesScreen
import com.bambouville.tessera.files.RemoteSelectionPathResolver
import com.bambouville.tessera.files.SelectedArtifactLinkRoute
import com.bambouville.tessera.files.SelectedArtifactLinks
import com.bambouville.tessera.files.SelectedPathIntent
import com.bambouville.tessera.files.RemoteTerminalPath
import com.bambouville.tessera.files.RemoteTerminalPathSink
import com.bambouville.tessera.files.RemoteTransferStrip
import com.bambouville.tessera.files.TransferItem
import com.bambouville.tessera.files.inFlight
import com.bambouville.tessera.files.remoteFileDropTarget
import com.bambouville.tessera.files.ShareUploadDelivery
import com.bambouville.tessera.files.ShareUploadDeliveryOutcome
import com.bambouville.tessera.files.ShareUploadDestination
import com.bambouville.tessera.files.ShareUploadFailure
import com.bambouville.tessera.forwarding.AndroidPortForwardRuleStore
import com.bambouville.tessera.forwarding.ForwardingChromePresentation
import com.bambouville.tessera.forwarding.PortForwardingPanel
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardingState
import com.bambouville.tessera.networking.mosh.MoshOutageTiming
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshKeyAuthorizationProvider
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import com.bambouville.tessera.security.confirmDeviceOwner
import com.bambouville.tessera.lifecycle.DiagnosticLogStore
import com.bambouville.tessera.feature.session.bell.AndroidBellController
import com.bambouville.tessera.feature.session.bell.BellEvent
import com.bambouville.tessera.feature.session.bell.BellPreferences
import com.bambouville.tessera.feature.session.bell.BellSource
import com.bambouville.tessera.feature.session.bell.BellUnreadState
import com.bambouville.tessera.feature.session.bell.BellVisualPulse
import com.bambouville.tessera.design.LocalArtifactOpener
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TerminalFontCatalog
import com.bambouville.tessera.design.TesseraBanner
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraConfirmDialog
import com.bambouville.tessera.design.TesseraDialog
import com.bambouville.tessera.design.TesseraEmptyState
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraStatusDot
import com.bambouville.tessera.design.TesseraTextField
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.design.text
import kotlin.math.roundToInt
import java.text.NumberFormat
import java.util.UUID

/** Only Open in Artifacts reads a selection as a link; Reveal in Files is always a path. */
internal fun selectedArtifactLinkRoute(
    action: TerminalSelectionPathAction,
    selection: String,
    hostId: String,
    sessionHint: String?,
    openerAvailable: Boolean,
    classifyLink: (String) -> SharedArtifactsLinkClass = SharedArtifacts::classifyLink,
): SelectedArtifactLinkRoute {
    if (action != TerminalSelectionPathAction.QuickOpen) return SelectedArtifactLinkRoute.Default
    return SelectedArtifactLinks.route(selection, hostId, sessionHint, openerAvailable, classifyLink)
}

/**
 * A path selected in an Agent Center transcript, for this session's Files.
 * [tmuxPaneId] is the bound agent pane; a new [token] is a new request.
 */
data class TranscriptSelectionPathRequest(
    val intent: SelectedPathIntent,
    val selection: String,
    val tmuxPaneId: Int?,
    val token: Long,
)

/** Where a transcript path's relative reading anchors, before Files resolves it. */
internal sealed interface TranscriptSelectionDirectory {
    /** This directory, or none: a relative path then misses with the terminal's message. */
    data class Known(val directory: String?) : TranscriptSelectionDirectory
    /** Ask tmux, over its control channel, for the pane's current path; [fallback] if it has none. */
    data class QueryPane(val paneId: Int, val fallback: String?) : TranscriptSelectionDirectory
}

/**
 * The agent's pane, never the focused one. tmux answers for that pane as it
 * does for the terminal's selection. A plain shell has one cwd, the one it
 * reported; the terminal's fallback probe dials a side connection, so a
 * transcript never uses it. A tmux binding on a plain session has no signal.
 */
internal fun transcriptSelectionDirectory(
    selection: String,
    tmuxOff: Boolean,
    paneId: Int?,
    reportedShellDirectory: String?,
    paneCurrentPath: (Int) -> String?,
): TranscriptSelectionDirectory = when {
    selection.trim().startsWith('/') -> TranscriptSelectionDirectory.Known(null)
    tmuxOff -> TranscriptSelectionDirectory.Known(
        reportedShellDirectory?.takeIf { paneId == null && it.startsWith('/') && it.none(Char::isISOControl) },
    )
    paneId == null -> TranscriptSelectionDirectory.Known(null)
    else -> TranscriptSelectionDirectory.QueryPane(paneId, paneCurrentPath(paneId))
}

/** How a [TranscriptSelectionPathRequest] ended; an Artifacts open reports nothing. */
sealed interface TranscriptSelectionPathOutcome {
    /** Files is open on this session at the path's directory. */
    data object Revealed : TranscriptSelectionPathOutcome
    /** The terminal's own miss message, for the requester to show. */
    data class Missed(val message: String) : TranscriptSelectionPathOutcome
}

/** A Hosts-row open starts only an idle transport; active and failed surfaces keep their own controls. */
internal fun shouldConnectFromHostOpen(state: SshSessionUiState): Boolean =
    state == SshSessionUiState.Disconnected

internal fun hasPendingPresentedHostOpen(
    request: Long,
    consumed: Long,
    isPresented: Boolean,
): Boolean = isPresented && request > consumed

/** Focus one terminal of this session (from the chip's list or another surface). New token = new request. */
data class ProgramStatusFocusRequest(val windowId: Int?, val paneId: Int?, val token: Long)

/** The same grid decision as TmuxPresentation; a whole-window Mosh canvas checks only its focused pane. */
internal fun presentedProgramStatusTerminals(
    isPresented: Boolean,
    tmuxActive: Boolean,
    snapshot: SharedTmuxSnapshot?,
    compact: Boolean,
    tmuxWindowIsPaintedWhole: Boolean,
    terminalCovered: Boolean = false,
): Set<SharedProgramStatusTerminal> {
    if (!isPresented || terminalCovered) return emptySet()
    if (!tmuxActive || snapshot == null) return setOf(SharedProgramStatusTerminal.Raw)
    val window = snapshot.activeWindow ?: return emptySet()
    val tabletGrid = !compact && !tmuxWindowIsPaintedWhole && window.panes.size > 1 && !window.zoomed
    if (tabletGrid) return window.panes.mapTo(mutableSetOf()) { SharedProgramStatusTerminal.Pane(it.id) }
    return snapshot.activePaneId?.takeIf { pane -> window.panes.any { it.id == pane } || window.activePaneId == pane }
        ?.let { setOf(SharedProgramStatusTerminal.Pane(it)) } ?: emptySet()
}

/** Consume a failed jump; it must never resume on a later ordinary visit. */
internal suspend fun awaitProgramStatusWindow(
    snapshots: Flow<SharedTmuxSnapshot?>,
    windowId: Int,
    isCurrent: (SharedTmuxSnapshot?) -> Boolean,
    timeoutMillis: Long = 3_000,
): SharedTmuxSnapshot? = withTimeoutOrNull(timeoutMillis) {
    snapshots.first { !isCurrent(it) || it?.activeWindowId == windowId }
        ?.takeIf { isCurrent(it) && it.activeWindowId == windowId }
}

@Composable
fun SshSessionScreen(
    host: SavedHost,
    hosts: HostRepository,
    identities: IdentityRepository,
    knownHosts: KnownHostsRepository,
    restore: SessionRestoreRepository,
    credentialStore: AndroidKeystoreCredentialStore,
    bellController: AndroidBellController,
    bellPreferences: BellPreferences,
    agentSessions: LiveAgentSessionRegistry,
    agentIntegration: AgentSessionIntegrationCoordinator,
    /**
     * Process-scoped owner of the controller behind this screen. The screen
     * borrows it; it does not own it, and disposal no longer ends the session.
     */
    sessions: LiveSessionStore,
    modifier: Modifier = Modifier,
    liveSessionId: String = host.id,
    terminalTextSizeSp: Int = 13,
    /** `TerminalFontCatalog` id; resolved to a face once, here. */
    terminalFontId: String = TerminalFontCatalog.DEFAULT_ID,
    scrollbackLines: Int = 10_000,
    resizeTerminalWithKeyboard: Boolean = false,
    terminalThemeId: String = resolvedTerminalThemeId(AutomaticTerminalThemeId, isSystemInDarkTheme()),
    terminalCursorStyle: String = "block",
    terminalCursorBlink: Boolean = true,
    /** Raw stored slot IDs; null when the user never edited the bar. */
    accessoryBarKeys: List<String>? = null,
    /** Wire value of Swift `ModifierBehaviorMode`: `oneShot` or `sticky`. */
    modifierBehavior: String = SharedModifierBehavior.OneShot.wireValue,
    /** Wire value of Swift `KeyChordNotation`: `glyph` or `words`. */
    modifierNotation: String = SharedInputEncoding.ChordNotation.Glyph.wireValue,
    terminalBackgroundUsesImage: Boolean = false,
    terminalBackgroundImageId: String? = null,
    terminalBackgroundDim: Float = 0.5f,
    terminalBackgroundBlur: Int = 0,
    terminalBackgroundFillMode: String = "fill",
    smoothScrollingEnabled: Boolean = true,
    smoothScrollingSpeed: Float = 0.5f,
    onTerminalTextSizeChanged: (Int) -> Unit = {},
    isPresented: Boolean = true,
    programStatusCenter: ProgramStatusCenter? = null,
    programStatusEnabled: Boolean = true,
    programStatusAgents: ProgramStatusAgentInput = ProgramStatusAgentInput.NONE,
    programStatusFocusRequest: ProgramStatusFocusRequest? = null,
    /**
     * A transcript path for this session's Files. The screen takes it once,
     * reports [onTranscriptSelectionConsumed] straight away, and an outcome
     * only for a reveal or a miss. It never connects: a session that is not
     * connected answers with a miss.
     */
    transcriptSelectionRequest: TranscriptSelectionPathRequest? = null,
    onTranscriptSelectionConsumed: (TranscriptSelectionPathRequest) -> Unit = {},
    onTranscriptSelectionOutcome: (TranscriptSelectionPathRequest, TranscriptSelectionPathOutcome) -> Unit = { _, _ -> },
    onOpenAgentCenter: (() -> Unit)? = null,
    /** Verified providers supplied by app wiring; keyed by exact live carrier and pane. */
    paneAgentProviders: Map<AgentSessionKey, Map<Int, String>> = emptyMap(),
    initialTmuxSelection: String? = null,
    /**
     * A share the ingress sheet already routed to this host. Runs once the
     * session is connected; the screen owns the file connection and the
     * terminal, so it is the only place that can both upload and paste.
     */
    shareUpload: PendingShareUpload? = null,
    onShareUploadConsumed: () -> Unit = {},
    /** Publishes this session's cwd so the ingress sheet can offer it. */
    onTerminalDirectoryChanged: (String?) -> Unit = {},
    onAgentTerminalVisible: (String, String?) -> Unit = { _, _ -> },
    /** Whether a system picker is up, for the picker keep-alive service. */
    onSystemPickerActiveChanged: (Boolean) -> Unit = {},
    /**
     * The activity's excursion counter (§6.9 transparent intervals). Each of
     * this screen's pickers and prompts takes its own slot. Null in harnesses
     * that have no activity-level notion of one.
     */
    externalUi: ExternalUiExcursions? = null,
    onOpenKeys: () -> Unit = {},
    onEditHost: () -> Unit = {},
    onContinueOnAnotherDevice: () -> Unit = {},
    /**
     * Every live host session, this one included, for the top bar's switcher.
     * The screen cannot assemble it: each session is a sibling mounted by the
     * app shell, which is also the only thing that can reveal another one.
     */
    switcherSessions: List<SessionSwitcherSession> = emptyList(),
    onSelectSession: (String) -> Unit = {},
    onStateChanged: (SshSessionUiState) -> Unit = {},
    /**
     * Transport-level reachability, or null where the transport reports none.
     * The foreground restore window needs it to tell a live Mosh session from
     * one that only still calls itself connected.
     */
    onTransportReachableChanged: (Boolean?) -> Unit = {},
    pairingTmuxTarget: String? = null,
    pairingAttemptId: String? = null,
    reconnectOnMount: Boolean = false,
    connectOnOpenRequest: Long = 0L,
    /**
     * Bumped by the foreground restore window when it rules this session dead.
     * Unlike [connectOnOpenRequest] it does not wait to be presented: a wake
     * owes the user every session that died, not just the one on screen.
     */
    restoreReconnectRequest: Long = 0L,
    onTerminalRenderedReady: (String, String?, String?) -> Unit = { _, _, _ -> },
    onBack: () -> Unit,
) {
    SshSessionScreenBody(
        host = host,
        hosts = hosts,
        identities = identities,
        knownHosts = knownHosts,
        restore = restore,
        credentialStore = credentialStore,
        bellController = bellController,
        bellPreferences = bellPreferences,
        agentSessions = agentSessions,
        agentIntegration = agentIntegration,
        sessions = sessions,
        modifier = modifier,
        liveSessionId = liveSessionId,
        terminalTextSizeSp = terminalTextSizeSp,
        terminalFontId = terminalFontId,
        scrollbackLines = scrollbackLines,
        resizeTerminalWithKeyboard = resizeTerminalWithKeyboard,
        terminalThemeId = terminalThemeId,
        terminalCursorStyle = terminalCursorStyle,
        terminalCursorBlink = terminalCursorBlink,
        accessoryBarKeys = accessoryBarKeys,
        modifierBehavior = modifierBehavior,
        modifierNotation = modifierNotation,
        terminalBackgroundUsesImage = terminalBackgroundUsesImage,
        terminalBackgroundImageId = terminalBackgroundImageId,
        terminalBackgroundDim = terminalBackgroundDim,
        terminalBackgroundBlur = terminalBackgroundBlur,
        terminalBackgroundFillMode = terminalBackgroundFillMode,
        smoothScrollingEnabled = smoothScrollingEnabled,
        smoothScrollingSpeed = smoothScrollingSpeed,
        onTerminalTextSizeChanged = onTerminalTextSizeChanged,
        isPresented = isPresented,
        programStatusCenter = programStatusCenter,
        programStatusEnabled = programStatusEnabled,
        programStatusAgents = programStatusAgents,
        programStatusFocusRequest = programStatusFocusRequest,
        transcriptSelectionRequest = transcriptSelectionRequest,
        onTranscriptSelectionConsumed = onTranscriptSelectionConsumed,
        onTranscriptSelectionOutcome = onTranscriptSelectionOutcome,
        onOpenAgentCenter = onOpenAgentCenter,
        paneAgentProviders = paneAgentProviders,
        initialTmuxSelection = initialTmuxSelection,
        shareUpload = shareUpload,
        onShareUploadConsumed = onShareUploadConsumed,
        onTerminalDirectoryChanged = onTerminalDirectoryChanged,
        onAgentTerminalVisible = onAgentTerminalVisible,
        onSystemPickerActiveChanged = onSystemPickerActiveChanged,
        externalUi = externalUi,
        onEditHost = onEditHost,
        onContinueOnAnotherDevice = onContinueOnAnotherDevice,
        switcherSessions = switcherSessions,
        onSelectSession = onSelectSession,
        onStateChanged = onStateChanged,
        onTransportReachableChanged = onTransportReachableChanged,
        pairingTmuxTarget = pairingTmuxTarget,
        pairingAttemptId = pairingAttemptId,
        reconnectOnMount = reconnectOnMount,
        connectOnOpenRequest = connectOnOpenRequest,
        restoreReconnectRequest = restoreReconnectRequest,
        onTerminalRenderedReady = onTerminalRenderedReady,
        onBack = onBack,
    )
}

/**
 * The body of [SshSessionScreen]. It is non-restartable, so it runs in the
 * screen's own restart scope and composes exactly as if it were still inline;
 * it is separate only so neither half reaches ART's 10,000-code-unit limit,
 * past which the compiler leaves a method interpreted.
 */
@Composable
@NonRestartableComposable
private fun SshSessionScreenBody(
    host: SavedHost,
    hosts: HostRepository,
    identities: IdentityRepository,
    knownHosts: KnownHostsRepository,
    restore: SessionRestoreRepository,
    credentialStore: AndroidKeystoreCredentialStore,
    bellController: AndroidBellController,
    bellPreferences: BellPreferences,
    agentSessions: LiveAgentSessionRegistry,
    agentIntegration: AgentSessionIntegrationCoordinator,
    sessions: LiveSessionStore,
    modifier: Modifier,
    liveSessionId: String,
    terminalTextSizeSp: Int,
    terminalFontId: String,
    scrollbackLines: Int,
    resizeTerminalWithKeyboard: Boolean,
    terminalThemeId: String,
    terminalCursorStyle: String,
    terminalCursorBlink: Boolean,
    accessoryBarKeys: List<String>?,
    modifierBehavior: String,
    modifierNotation: String,
    terminalBackgroundUsesImage: Boolean,
    terminalBackgroundImageId: String?,
    terminalBackgroundDim: Float,
    terminalBackgroundBlur: Int,
    terminalBackgroundFillMode: String,
    smoothScrollingEnabled: Boolean,
    smoothScrollingSpeed: Float,
    onTerminalTextSizeChanged: (Int) -> Unit,
    isPresented: Boolean,
    programStatusCenter: ProgramStatusCenter?,
    programStatusEnabled: Boolean,
    programStatusAgents: ProgramStatusAgentInput,
    programStatusFocusRequest: ProgramStatusFocusRequest?,
    transcriptSelectionRequest: TranscriptSelectionPathRequest?,
    onTranscriptSelectionConsumed: (TranscriptSelectionPathRequest) -> Unit,
    onTranscriptSelectionOutcome: (TranscriptSelectionPathRequest, TranscriptSelectionPathOutcome) -> Unit,
    onOpenAgentCenter: (() -> Unit)?,
    paneAgentProviders: Map<AgentSessionKey, Map<Int, String>>,
    initialTmuxSelection: String?,
    shareUpload: PendingShareUpload?,
    onShareUploadConsumed: () -> Unit,
    onTerminalDirectoryChanged: (String?) -> Unit,
    onAgentTerminalVisible: (String, String?) -> Unit,
    onSystemPickerActiveChanged: (Boolean) -> Unit,
    externalUi: ExternalUiExcursions?,
    onEditHost: () -> Unit,
    onContinueOnAnotherDevice: () -> Unit,
    switcherSessions: List<SessionSwitcherSession>,
    onSelectSession: (String) -> Unit,
    onStateChanged: (SshSessionUiState) -> Unit,
    onTransportReachableChanged: (Boolean?) -> Unit,
    pairingTmuxTarget: String?,
    pairingAttemptId: String?,
    reconnectOnMount: Boolean,
    connectOnOpenRequest: Long,
    restoreReconnectRequest: Long,
    onTerminalRenderedReady: (String, String?, String?) -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val density = LocalDensity.current
    val compactTmux = with(density) {
        LocalWindowInfo.current.containerSize.width.toDp() < 700.dp
    }
    val softwareKeyboardVisible = WindowInsets.ime.getBottom(density) > 0
    val scope = rememberCoroutineScope()
    // Scrollback capacity is an attempt/session construction policy. Changing
    // Settings while this controller is alive must not replace its terminal
    // View, discard the visible transcript, or leave a Mosh side-channel on a
    // stale depth. The new value takes effect the next time this screen owns a
    // newly constructed session.
    val sessionScrollbackLines = remember(host.id, pairingTmuxTarget, pairingAttemptId) {
        scrollbackLines
    }
    val terminalTheme = remember(terminalThemeId) { TerminalTheme.fromId(terminalThemeId) }
    val cursorStyle = remember(terminalCursorStyle) { TerminalCursorStyle.fromPersisted(terminalCursorStyle) }
    // A bar the user never edited takes the row for this idiom, the way
    // `AccessoryChip.defaultBarOrder(for:)` does on iOS — a tablet was silently
    // taking the phone row before.
    val accessoryBarDefaults = LocalConfiguration.current.accessoryBarDefaults()
    val resolvedAccessoryBarKeys = remember(accessoryBarKeys, accessoryBarDefaults) {
        AccessoryBarKey.resolve(accessoryBarKeys, accessoryBarDefaults)
    }
    val chordNotation = remember(modifierNotation) {
        SharedInputEncoding.ChordNotation.entries
            .firstOrNull { it.wireValue == modifierNotation }
            ?: SharedInputEncoding.ChordNotation.Glyph
    }
    val armingBehavior = remember(modifierBehavior) {
        SharedModifierBehavior.entries
            .firstOrNull { it.wireValue == modifierBehavior }
            ?: SharedModifierBehavior.OneShot
    }
    val terminalBackgroundStore = remember(context.applicationContext) {
        TerminalBackgroundImageStore(context.applicationContext)
    }
    val terminalBackground = remember(
        terminalBackgroundUsesImage,
        terminalBackgroundImageId,
        terminalBackgroundDim,
        terminalBackgroundBlur,
        terminalBackgroundFillMode,
    ) {
        if (!terminalBackgroundUsesImage || terminalBackgroundImageId == null) null
        else runCatching {
            TerminalBackgroundImage(
                imageId = terminalBackgroundImageId,
                dim = terminalBackgroundDim.coerceIn(0f, 0.85f),
                fillMode = TerminalBackgroundFillMode.fromPersisted(terminalBackgroundFillMode),
                blurRadiusDp = terminalBackgroundBlur.coerceIn(0, 24).toFloat(),
            )
        }.getOrNull()
    }
    // Resolved once for the whole screen and handed down as a value, the way
    // the theme is: every pane, overlay, and the primary surface must render
    // the same face, and re-resolving per surface would load the font file
    // once per pane.
    val terminalTypeface = remember(context, terminalFontId) {
        TerminalFontCatalog.typeface(context, terminalFontId)
    }
    val terminal = remember(host.id, pairingTmuxTarget, pairingAttemptId) {
        TermuxTerminalSurface(
            context,
            transcriptRows = sessionScrollbackLines,
            initialFontSizeSp = terminalTextSizeSp,
            initialTheme = terminalTheme,
            initialCursorStyle = cursorStyle,
            initialCursorBlink = terminalCursorBlink,
            initialTypeface = terminalTypeface,
        )
    }
    val surfaceState = remember(host.id, pairingTmuxTarget, pairingAttemptId) { SessionSurfaceState() }
    val paneSurfaces = surfaceState.paneSurfaces
    // The screen, rather than the controller's physical-surface registry,
    // owns the presentation set it submits to the render ledger.  Mosh keeps
    // detached overlay terminals parked for each pane in an active split, so
    // visible-overlay state alone is not sufficient to describe that set.
    val overlaySurfaces = surfaceState.overlaySurfaces
    val primaryTerminalAttached by surfaceState.primaryTerminalAttached
    // A physical Termux surface can be replaced under an unchanged pane ID.
    // Its logical declaration is structurally identical, but it still needs a
    // new SurfaceDeclared/initial repaint after the seam is reattached.
    var surfaceMountGeneration by surfaceState.surfaceMountGeneration
    val diagnostics = remember(context) { DiagnosticLogStore(context.applicationContext) }
    val capturedInitialTmuxSelection = remember(host.id) { initialTmuxSelection }
    val capturedInitialTmuxPresentation = remember(host.id) {
        if (compactTmux) SharedTmuxGridPresentation.SINGLE_PANE
        else SharedTmuxGridPresentation.PANE_GRID
    }
    // Acquired, not constructed: the transport belongs to the process, and the
    // composition that shows it is replaced routinely. The key list is what it
    // always was — a change in any of these is a different session, and the
    // store retires the old controller for real rather than rebinding it.
    val controller = remember(
        liveSessionId,
        host.id,
        pairingTmuxTarget,
        pairingAttemptId,
        hosts,
        identities,
        knownHosts,
        restore,
        agentSessions,
    ) {
        sessions.controller(
            LiveSessionStore.ControllerKey(
                hostId = host.id,
                sessionId = liveSessionId,
                tmuxTarget = pairingTmuxTarget,
                pairingAttemptId = pairingAttemptId,
            ),
        ) {
            val applicationContext = context.applicationContext
            SshSessionController(
                host,
                hosts,
                identities,
                knownHosts,
                restore,
                credentialStore,
                diagnostics,
                sessions.scope,
                agentSessions,
                initialTmuxSelection = capturedInitialTmuxSelection,
                initialTmuxGridPresentation = capturedInitialTmuxPresentation,
                tmuxSessionTargetOverride = pairingTmuxTarget,
                tmuxDeviceIdentity = tmuxDeviceIdentity(context),
                ownedGeometryStore = TmuxOwnedGeometryStore.shared(context),
                scrollbackLines = sessionScrollbackLines,
                sessionId = liveSessionId,
                sessionRestorePolicy = combine(
                    // An unreadable store reads as ask, and the compact shell
                    // is still followed after it.
                    AndroidForegroundRestoreStore(applicationContext).restorePolicy
                        .catch { emit(SessionRestorePolicy.ASK) },
                    sessions.usesCompactShell,
                ) { stored, compact -> SessionRestorePresentationPolicy.effective(stored, compact) },
            )
        }
    }
    val state by controller.state.collectAsState()
    val integrationStatuses by agentIntegration.statuses.collectAsState()
    val exactAgentBinding by controller.agentEndpointBinding.collectAsState()
    val integrationStatus = exactAgentBinding?.key?.let(integrationStatuses::get)
    // Warning chrome (status-dot ring, switcher notice, warning sheet) appears
    // only once this exact session's warning has held for Core's presentation
    // delay, so probe and reconnect transients never flash UI. The held flow
    // reads the same sources as `integrationStatus` and holds the session key,
    // so a stale value from another binding or controller never shows; the
    // live value gates clearing, so it hides in this frame, not after delivery.
    val integrationWarningDelayMillis = remember { integrationWarningPresentationDelayMillis() }
    val heldIntegrationWarningKey by remember(controller, agentIntegration, integrationWarningDelayMillis) {
        combine(agentIntegration.statuses, controller.agentEndpointBinding) { statuses, binding ->
            binding?.key?.takeIf { statuses[it]?.showsWarning == true }
        }.presentedAfterContinuousHold(integrationWarningDelayMillis)
    }.collectAsState(initial = null)
    val integrationWarningVisible = heldIntegrationWarningKey != null &&
        heldIntegrationWarningKey == exactAgentBinding?.key &&
        integrationStatus?.showsWarning == true
    val currentState by rememberUpdatedState(state)
    val presented = rememberUpdatedState(isPresented)
    val currentPresented by presented
    var renderedReadyReported by surfaceState.renderedReadyReported
    // The launch overlay lifts on the first output drawn on screen. An attach
    // that lands on a split -CC window draws only on the grid's pane surfaces
    // and never mounts the primary canvas, so a pane's first draw counts too;
    // waiting for the primary alone left that attach on "attaching pane".
    val reportRenderedReady = {
        if (!renderedReadyReported && currentPresented && currentState is SshSessionUiState.Connected) {
            renderedReadyReported = true
            onTerminalRenderedReady(host.id, pairingTmuxTarget, pairingAttemptId)
        }
    }
    val transportReachable by controller.transportReachable.collectAsState()
    val programStatus by controller.programStatus.collectAsState()
    val programSessions = programStatusCenter?.sessions?.collectAsState()?.value.orEmpty()
    val tmuxSnapshot by controller.tmuxSnapshot.collectAsState()
    val tmuxRenderHistory by controller.tmuxRenderHistory.collectAsState()
    val tmuxWindowIsPaintedWhole by controller.tmuxWindowIsPaintedWhole.collectAsState()
    val tmuxAuthority by controller.tmuxAuthority.collectAsState()
    val tmuxAuthorityPresentation by controller.tmuxAuthorityPresentation.collectAsState()
    val tmuxWindowMutationState by controller.tmuxWindowMutationState.collectAsState()
    val bellUnread by bellController.unread.state.collectAsState()
    val bellVisualPulse by bellController.visualPulse.collectAsState()
    val hostState = remember(host.id) {
        SessionHostState(startsInForeground = lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
    }
    val glowingTmuxWindowId by hostState.glowingTmuxWindowId
    var filesOpen by hostState.filesOpen
    var forwardingOpen by hostState.forwardingOpen
    var tmuxSwitcherOpen by hostState.tmuxSwitcherOpen
    var findOpen by hostState.findOpen
    var findQuery by hostState.findQuery
    /** Whether one of this session's Compose editors (Find's field, a panel's) has focus. */
    val sessionFocus = remember { mutableStateOf(false) }
    var sessionHoldsFocus by sessionFocus
    var findResult by hostState.findResult
    // Split mosh paints its live window into the primary surface, but an
    // ordered full-depth capture belongs in the detached focused-pane overlay.
    // Keep both the pending ledger request and the delivered surface explicit
    // so a find never accidentally scans the whole-window live canvas.
    var moshFindOverlaySurface by hostState.moshFindOverlaySurface
    var pendingMoshFindSurfaceId by hostState.pendingMoshFindSurfaceId
    var pendingMoshFindAfterDeliveryToken by hostState.pendingMoshFindAfterDeliveryToken
    var pendingMoshFindCanReuseExistingDelivery by hostState.pendingMoshFindCanReuseExistingDelivery
    var openMoshFindSurfaceId by hostState.openMoshFindSurfaceId
    // Split-pane Mosh history is placed asynchronously in a detached
    // Termux view. Find must wait for that exact post callback, just as the
    // shared ledger waits for the controller acknowledgement.
    var appliedMoshOverlayHistoryDeliveryTokens by hostState.appliedMoshOverlayHistoryDeliveryTokens
    var appliedMoshLiveHistoryDeliveryToken by hostState.appliedMoshLiveHistoryDeliveryToken
    var pendingMoshLiveFindAfterDeliveryToken by hostState.pendingMoshLiveFindAfterDeliveryToken
    var pendingMoshLiveFindCanReuseExistingDelivery by hostState.pendingMoshLiveFindCanReuseExistingDelivery
    var openMoshLiveFind by hostState.openMoshLiveFind
    // The accessory bar owns the armed set; the terminal surface applies it to
    // the bytes a typed key produces and reports what survives. Every
    // transition goes through the shared machine
    // (`TesseraInputCore.ModifierArming`) so sticky and one-shot cannot drift
    // between the two platforms.
    var armedModifiers by hostState.armedModifiers
    val plainTerminalDirectory by hostState.plainTerminalDirectory
    var terminalToast by hostState.terminalToast
    // Callbacks and effects below resolve their toasts through this; composable
    // bodies use stringResource.
    val resources = LocalResources.current
    val integrationPrompts = remember(liveSessionId) { SessionIntegrationPrompts() }
    TmuxDegradeNoticeEffect(controller = controller, hostState = hostState, resources = resources)
    var selectedPathPresentationActive by hostState.selectedPathPresentationActive
    val appForeground by hostState.appForeground
    var locallyFocusedTmuxPaneId by hostState.locallyFocusedTmuxPaneId
    val programStatusNavigation = remember(controller) { mutableLongStateOf(0L) }
    var programStatusNavigationEpoch by programStatusNavigation
    ProgramStatusRegistration(
        host = host,
        controller = controller,
        programStatusCenter = programStatusCenter,
        programStatusEnabled = programStatusEnabled,
    )
    val usesTmuxPaneGrid = host.tmuxMode != TmuxModes.OFF && !compactTmux && !tmuxWindowIsPaintedWhole &&
        tmuxSnapshot?.activeWindow?.let { it.panes.size > 1 && !it.zoomed } == true
    val activeTmuxPaneIds = tmuxSnapshot?.activeWindow?.panes?.mapTo(mutableSetOf()) { it.id } ?: emptySet()
    val mountedGridPaneIds = paneSurfaces.keys.toSet()
    val mountedOverlayPaneIds = overlaySurfaces.keys.toSet()
    val tmuxScreenRenderPresentation = when {
        host.tmuxMode == TmuxModes.OFF || state != SshSessionUiState.Connected || !primaryTerminalAttached ->
            TmuxScreenRenderPresentation.None
        usesTmuxPaneGrid -> TmuxScreenRenderPresentation.Grid
        else -> TmuxScreenRenderPresentation.Single
    }
    // `usesTmuxPaneGrid` is the same presentation decision that chooses the
    // actual CompactTmuxTerminal/TmuxLayout branch below.  Publishing it here
    // makes layout and remount changes facts from the screen, rather than a
    // controller inference from whichever surfaces happen to be registered.
    TmuxRenderDeclarationEffects(
        controller = controller,
        tmuxScreenRenderPresentation = tmuxScreenRenderPresentation,
        tmuxSnapshot = tmuxSnapshot,
        activeTmuxPaneIds = activeTmuxPaneIds,
        mountedGridPaneIds = mountedGridPaneIds,
        mountedOverlayPaneIds = mountedOverlayPaneIds,
        surfaceMountGeneration = surfaceMountGeneration,
    )
    val inputTerminal = if (usesTmuxPaneGrid) {
        (locallyFocusedTmuxPaneId ?: tmuxSnapshot?.activePaneId)?.let(paneSurfaces::get) ?: terminal
    } else {
        terminal
    }
    val focusedMoshSplitPaneId = tmuxSnapshot?.activeWindow
        ?.takeIf { tmuxWindowIsPaintedWhole && it.panes.size > 1 && !it.zoomed }
        ?.let { locallyFocusedTmuxPaneId ?: tmuxSnapshot?.activePaneId }
    val focusedMoshSplitSurfaceId = focusedMoshSplitPaneId?.let(::moshPaneHistoryOverlaySurfaceId)
    val usesMoshLiveFind = host.tmuxMode != TmuxModes.OFF && tmuxWindowIsPaintedWhole &&
        focusedMoshSplitSurfaceId == null
    val findTerminal = if (focusedMoshSplitSurfaceId != null) {
        moshFindOverlaySurface ?: inputTerminal
    } else {
        inputTerminal
    }
    MoshFindEffects(
        hostState = hostState,
        controller = controller,
        focusedMoshSplitSurfaceId = focusedMoshSplitSurfaceId,
        usesMoshLiveFind = usesMoshLiveFind,
        tmuxRenderHistory = tmuxRenderHistory,
        inputTerminal = inputTerminal,
        sessionScrollbackLines = sessionScrollbackLines,
    )
    val filesChallengeActive = filesOpen && (
        state is SshSessionUiState.AwaitingCredential ||
            state is SshSessionUiState.AwaitingHostKey ||
            state is SshSessionUiState.AwaitingOwnerAuthorization
        )
    val artifactOpener by rememberUpdatedState(LocalArtifactOpener.current)
    val filesController = remember(host.id, controller, liveSessionId) {
        RemoteFilesController(
            context = context.applicationContext,
            route = controller::fileRouteRequest,
            passwordProvider = SshPasswordProvider(controller::filePassword),
            hostKeyPolicy = SshHostKeyPolicy(controller::fileHostKey),
            keyAuthorizationProvider = SshKeyAuthorizationProvider(controller::fileKeyAuthorization),
            liveConnection = controller::openLiveFileChannel,
            recordDiagnostic = diagnostics::record,
            hostId = host.id,
            sessionHint = liveSessionId,
            artifactOpener = { artifactOpener },
        )
    }
    DisposableEffect(controller, filesController) {
        val hostAsset: (String) -> ByteArray = { name ->
            require(name == "manifest.json" || name in listOf("darwin-arm64", "darwin-x86_64", "linux-aarch64", "linux-x86_64").map { "tessera-agent-host-$it" })
            context.applicationContext.assets.open(name).use { stream ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(65536)
                while (true) {
                    val count = stream.read(buffer)
                    if (count < 0) break
                    check(output.size() + count <= 16 * 1024 * 1024)
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        }
        controller.agentHostAsset = hostAsset
        val activeUploads = mutableSetOf<RemoteFilesController>()
        var closed = false
        val upload: suspend (com.bambouville.tessera.networking.SshRouteOwner, String) -> com.bambouville.tessera.agent.platform.AgentEndpointResult<String> = { originalRoute, uri ->
            withContext(Dispatchers.Main.immediate) {
                check(!closed) { "The upload session closed" }
                // Use the shared Files service with one pinned carrier. Its
                // connection can never fall through to the controller's new
                // routeOwner if reconnect occurs while opening SFTP.
                val transfer = RemoteFilesController(
                    context = context.applicationContext,
                    route = { error("An attachment requires its original live route") },
                    passwordProvider = SshPasswordProvider { error("An attachment cannot reconnect") },
                    hostKeyPolicy = SshHostKeyPolicy { false },
                    keyAuthorizationProvider = SshKeyAuthorizationProvider { error("An attachment cannot reconnect") },
                    liveConnection = { originalRoute.openFiles() },
                    recordDiagnostic = diagnostics::record,
                )
                activeUploads += transfer
                try {
                    com.bambouville.tessera.agent.platform.AgentEndpointResult.Success(
                        transfer.uploadAttachment(uri.toUri()),
                    )
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    com.bambouville.tessera.agent.platform.AgentEndpointResult.Failed("File upload failed")
                } finally {
                    activeUploads -= transfer
                    transfer.closeAfterTransfers()
                }
            }
        }
        controller.agentAttachmentUpload = upload
        onDispose {
            if (controller.agentHostAsset === hostAsset) controller.agentHostAsset = null
            closed = true
            if (controller.agentAttachmentUpload === upload) controller.agentAttachmentUpload = null
            activeUploads.toList().forEach { it.cancelPendingTransfers() }
        }
    }
    val terminalPaneId = if (host.tmuxMode == TmuxModes.OFF) {
        null
    } else {
        locallyFocusedTmuxPaneId ?: tmuxSnapshot?.activePaneId
    }
    val terminalDirectory = if (host.tmuxMode == TmuxModes.OFF) {
        plainTerminalDirectory
    } else {
        tmuxSnapshot?.activeWindow?.panes
            ?.firstOrNull { it.id == terminalPaneId }
            ?.currentPath
    }
    val currentTerminalDirectory by rememberUpdatedState(terminalDirectory)
    val currentTerminalPaneId by rememberUpdatedState(terminalPaneId)
    val currentSystemPickerActiveChanged by rememberUpdatedState(onSystemPickerActiveChanged)
    val excursions = remember(externalUi) { externalUi ?: ExternalUiExcursions() }
    // This screen's pickers, counted on their own for the keep-alive service.
    val pickerExcursions = hostState.pickerExcursions
    fun pickerSlot(): (Boolean) -> Unit {
        val outer = excursions.slot()
        val local = pickerExcursions.slot()
        return { active ->
            outer(active)
            local(active)
            currentSystemPickerActiveChanged(pickerExcursions.active)
        }
    }
    val quickOpenExcursion = remember(excursions) { pickerSlot() }
    val filesPickerExcursion = remember(excursions) { pickerSlot() }
    val filesOutboundExcursion = remember(excursions) { pickerSlot() }
    // A screen disposed while one of its excursions is up (the tab closed,
    // the host switched) never reports its end. Release them, or the count
    // sticks and `isRealBackgroundEdge()` stays false: no hide, no app lock.
    DisposableEffect(quickOpenExcursion, filesPickerExcursion, filesOutboundExcursion) {
        onDispose {
            quickOpenExcursion(false)
            filesPickerExcursion(false)
            filesOutboundExcursion(false)
        }
    }
    val currentSelectionPathAction by rememberUpdatedState<(TerminalSelectionPathAction, String) -> Unit> selectionAction@ {
            action, selection ->
        val opener = artifactOpener
        when (val route = selectedArtifactLinkRoute(action, selection, host.id, liveSessionId, opener != null)) {
            SelectedArtifactLinkRoute.Refused -> {
                terminalToast = resources.getString(R.string.session_link_not_opened)
                return@selectionAction
            }
            is SelectedArtifactLinkRoute.Page -> {
                // The toolbar has already ended selection, as for a file open.
                (paneSurfaces.values + terminal).forEach { it.view.hideSoftwareKeyboard() }
                opener?.open(route.request)
                return@selectionAction
            }
            SelectedArtifactLinkRoute.Default -> Unit
        }
        val perform: (String?) -> Unit = { directory ->
            val onFailure: (String) -> Unit = { terminalToast = it }
            when (action) {
                TerminalSelectionPathAction.RevealInFiles -> filesController.revealSelectedPath(
                    selection = selection,
                    terminalDirectory = directory,
                    onRevealRequested = {
                        forwardingOpen = false
                        findOpen = false
                        filesOpen = true
                    },
                    onFailure = onFailure,
                )
                TerminalSelectionPathAction.QuickOpen -> filesController.quickOpenSelectedFile(
                    selection = selection,
                    terminalDirectory = directory,
                    onPresentationLaunched = {
                        // Only the legacy activity/intent takes a picker excursion.
                        selectedPathPresentationActive = true
                        quickOpenExcursion(true)
                    },
                    onFailure = onFailure,
                )
            }
        }
        if (selection.trim().startsWith('/')) {
            perform(currentTerminalDirectory)
        } else {
            controller.queryTerminalDirectory(currentTerminalDirectory, currentTerminalPaneId) { freshDirectory ->
                perform(freshDirectory ?: currentTerminalDirectory)
            }
        }
    }
    TranscriptSelectionEffect(
        transcriptSelectionRequest = transcriptSelectionRequest,
        onTranscriptSelectionConsumed = onTranscriptSelectionConsumed,
        onTranscriptSelectionOutcome = onTranscriptSelectionOutcome,
        host = host,
        controller = controller,
        filesController = filesController,
        hostState = hostState,
        quickOpenExcursion = quickOpenExcursion,
    )
    val forwardingRuleStore = remember(context.applicationContext) {
        AndroidPortForwardRuleStore(context.applicationContext)
    }
    val forwardingRules by forwardingRuleStore.observe(host.id).collectAsState(initial = emptyList())
    val forwardingStates by controller.forwardingStates.collectAsState()
    SessionStateEffects(
        host = host,
        state = state,
        isPresented = isPresented,
        transportReachable = transportReachable,
        tmuxSnapshot = tmuxSnapshot,
        terminal = terminal,
        paneSurfaces = paneSurfaces,
        bellController = bellController,
        bellPreferences = bellPreferences,
        bellVisualPulse = bellVisualPulse,
        hostState = hostState,
        reportRenderedReady = reportRenderedReady,
        onStateChanged = onStateChanged,
        onTransportReachableChanged = onTransportReachableChanged,
    )

    PrimaryTerminalAttachment(
        host = host,
        controller = controller,
        terminal = terminal,
        surfaceState = surfaceState,
        hostState = hostState,
        bellController = bellController,
        bellPreferences = bellPreferences,
        presented = presented,
        currentSelectionPathAction = { action, selection -> currentSelectionPathAction(action, selection) },
        reportRenderedReady = reportRenderedReady,
        onTerminalTextSizeChanged = onTerminalTextSizeChanged,
    )
    ArtifactLiveRegistrations(
        host = host,
        liveSessionId = liveSessionId,
        controller = controller,
        filesController = filesController,
        state = state,
        forwardingStates = forwardingStates,
    )
    // No `onDispose { controller.close() }`. A composition ending is a window
    // being rebuilt, not a session being ended — and closing here was
    // indistinguishable from a user disconnect at the record layer, so every
    // Activity destroy raised `explicitDisconnect` and deleted a restore record
    // it should have kept. The surface teardown above already unbinds the view;
    // the transport is ended only by `LiveSessionStore.close`, which the
    // in-session close action, the sessions list and task removal reach.
    //
    // The screen it comes back to is a new one: `TermuxTerminalSurface` owns an
    // Android `View` and cannot outlive the Activity that themed it. tmux
    // repaints the new grid from the server (see `attachTerminal`) and mosh
    // re-reveals from its own model; a plain-SSH screen starts empty under a
    // shell that is still exactly where the user left it. Rebuilding that grid
    // means keeping the emulator without its view, which is a separate change.
    SessionLifecycleEffects(
        host = host,
        controller = controller,
        terminal = terminal,
        paneSurfaces = paneSurfaces,
        isPresented = isPresented,
        sessionFocus = sessionFocus,
        forwardingRules = forwardingRules,
        lifecycleOwner = lifecycleOwner,
        hostState = hostState,
        quickOpenExcursion = quickOpenExcursion,
        pairingTmuxTarget = pairingTmuxTarget,
        pairingAttemptId = pairingAttemptId,
        diagnostics = diagnostics,
    )
    SessionConnectEffects(
        host = host,
        liveSessionId = liveSessionId,
        controller = controller,
        sessions = sessions,
        lifecycleOwner = lifecycleOwner,
        state = state,
        isPresented = isPresented,
        diagnostics = diagnostics,
        reconnectOnMount = reconnectOnMount,
        connectOnOpenRequest = connectOnOpenRequest,
        restoreReconnectRequest = restoreReconnectRequest,
    )
    TerminalSurfaceEffects(
        controller = controller,
        terminal = terminal,
        inputTerminal = inputTerminal,
        paneSurfaces = paneSurfaces,
        hostState = hostState,
        state = state,
        isPresented = isPresented,
        compactTmux = compactTmux,
        tmuxSnapshot = tmuxSnapshot,
        usesTmuxPaneGrid = usesTmuxPaneGrid,
        terminalTextSizeSp = terminalTextSizeSp,
        terminalTypeface = terminalTypeface,
        terminalTheme = terminalTheme,
        cursorStyle = cursorStyle,
        terminalCursorBlink = terminalCursorBlink,
        terminalBackground = terminalBackground,
        terminalBackgroundStore = terminalBackgroundStore,
        smoothScrollingEnabled = smoothScrollingEnabled,
        smoothScrollingSpeed = smoothScrollingSpeed,
        armingBehavior = armingBehavior,
    )

    // --- Share-in execution -------------------------------------------------

    var shareConflict by hostState.shareConflict
    // A transfer the user is about to cancel that was going to deliver a path.
    var shareCancelPrompt by hostState.shareCancelPrompt
    // True while an upload that owes this session a pasted path is moving, so
    // cancelling it can say what else is lost. iOS asks the same question from
    // its sheet before cancelling a foreground-paste upload.
    var pastePathInFlight by hostState.pastePathInFlight
    val transfers by filesController.transfers.collectAsState()
    val systemClipboard = remember(context) {
        context.getSystemService(ClipboardManager::class.java)
    }
    fun runShareUpload(uri: Uri, pending: PendingShareUpload, replaceExisting: Boolean) {
        if (pending.pastePath) pastePathInFlight = true
        filesController.enqueueShareUpload(
            source = uri,
            destination = pending.destination,
            replaceExisting = replaceExisting,
            onUploaded = { path ->
                pastePathInFlight = false
                val outcome = ShareUploadDelivery.deliver(
                    path = path,
                    pastePath = pending.pastePath,
                    injectIntoTerminal = { remotePath ->
                        // The session may have dropped between the upload
                        // starting and finishing, and the user may have moved
                        // to another host meanwhile. Typing into a terminal
                        // they are no longer looking at hides the path in a
                        // buffer they have to go find; iOS makes the same call
                        // and copies once its sheet is gone.
                        if (currentState != SshSessionUiState.Connected || !currentPresented ||
                            !controller.acceptsTerminalInput()
                        ) {
                            // Also while resuming, veiled or reclaiming: the
                            // grid is not this device's to type into.
                            false
                        } else {
                            inputTerminal.sendInput(
                                RemoteTerminalPath(remotePath).shellQuoted.encodeToByteArray(),
                            )
                            inputTerminal.setFocused(true)
                            true
                        }
                    },
                    copyToClipboard = { remotePath ->
                        systemClipboard?.setPrimaryClip(
                            ClipData.newPlainText(resources.getString(R.string.session_clip_label_remote_path), remotePath),
                        )
                    },
                )
                terminalToast = when (outcome) {
                    // The path is on the command line, under the banner that
                    // would announce it. Saying so covers the one thing the
                    // user is looking at; the transfer strip already carried
                    // the upload while it ran.
                    ShareUploadDeliveryOutcome.TERMINAL -> null
                    ShareUploadDeliveryOutcome.CLIPBOARD,
                    ShareUploadDeliveryOutcome.CLIPBOARD_FALLBACK,
                    -> resources.getString(R.string.session_upload_path_copied)
                    ShareUploadDeliveryOutcome.NONE -> resources.getString(R.string.session_uploaded_to, path)
                }
            },
            onFailed = { failure ->
                pastePathInFlight = false
                when (failure) {
                    is ShareUploadFailure.Conflict ->
                        shareConflict = PendingShareConflict(uri, pending, failure)
                    is ShareUploadFailure.Message -> terminalToast = failure.detail
                }
            },
        )
    }
    // One reference for the share effect and the conflict dialog alike.
    val startShareUpload: (Uri, PendingShareUpload, Boolean) -> Unit = ::runShareUpload

    TerminalDirectoryEffects(
        host = host,
        controller = controller,
        filesController = filesController,
        hostState = hostState,
        state = state,
        isPresented = isPresented,
        terminalDirectory = terminalDirectory,
        onTerminalDirectoryChanged = onTerminalDirectoryChanged,
    )

    ShareUploadEffect(
        shareUpload = shareUpload,
        onShareUploadConsumed = onShareUploadConsumed,
        controller = controller,
        state = state,
        tmuxAuthorityPresentation = tmuxAuthorityPresentation,
        inputTerminal = inputTerminal,
        hostState = hostState,
        resources = resources,
        systemClipboard = systemClipboard,
        runShareUpload = startShareUpload,
    )
    SessionNoticeEffects(
        controller = controller,
        state = state,
        isPresented = isPresented,
        tmuxWindowMutationState = tmuxWindowMutationState,
        integrationWarningVisible = integrationWarningVisible,
        hostState = hostState,
        integrationPrompts = integrationPrompts,
        context = context,
        resources = resources,
    )

    val keyboardLayout = rememberTerminalKeyboardViewportLayout(
        resizeTerminalWithKeyboard = resizeTerminalWithKeyboard,
        terminal = inputTerminal,
        caretFollowingEnabled = state == SshSessionUiState.Connected &&
            !filesOpen && !forwardingOpen && !findOpen,
    )
    val launchFailure = (state as? SshSessionUiState.Failed)?.message?.text()
    val launchPhase = when {
        state == SshSessionUiState.Connected && host.tmuxMode != TmuxModes.OFF && tmuxSnapshot == null ->
            SessionLaunchPhase.STARTING_TMUX
        state == SshSessionUiState.Connected && !renderedReadyReported -> SessionLaunchPhase.ATTACHING_PANE
        else -> SessionLaunchPhase.CONNECTING
    }
    val showsLaunchOverlay = state != SshSessionUiState.Disconnected &&
        state != SshSessionUiState.Terminated &&
        (state != SshSessionUiState.Connected || !renderedReadyReported)
    // The veil follows the one presentation projection, never the raw
    // authority: a peer stamp seen while a show is resolving is `resuming`,
    // not a veil. Named once: it mounts the veil and pauses the terminals
    // under it (P9).
    val veilShown = tmuxAuthorityVeilShown(
        presentation = tmuxAuthorityPresentation,
        launchOverlayShown = showsLaunchOverlay,
        connected = state == SshSessionUiState.Connected,
    )
    val terminalDrawing = terminalDrawingEnabled(presented = isPresented, veilShown = veilShown)
    // P9: a hidden session stays composed (at alpha 0), so anything that
    // animates on the frame clock would keep recomposing and drawing it.
    val sessionAnimates = isPresented && appForeground

    // What actually covers the terminal right now. Named once because the back
    // gesture below has to unwind exactly the layer the user can see, and a
    // panel whose open flag is set while its page is not rendered — files held
    // open across a reconnect, find left armed under an open panel — would
    // otherwise eat a gesture with nothing visible changing.
    val forwardingPanelVisible = forwardingOpen && state == SshSessionUiState.Connected
    val filesPanelVisible = !forwardingPanelVisible && filesOpen &&
        (state == SshSessionUiState.Connected || filesChallengeActive)
    val findBarVisible = findOpen && state == SshSessionUiState.Connected &&
        !filesOpen && !forwardingOpen

    val presentedPrograms = presentedProgramStatusTerminals(
        isPresented = isPresented,
        tmuxActive = host.tmuxMode != TmuxModes.OFF && state == SshSessionUiState.Connected,
        snapshot = tmuxSnapshot,
        compact = compactTmux,
        tmuxWindowIsPaintedWhole = tmuxWindowIsPaintedWhole,
        terminalCovered = filesPanelVisible || forwardingPanelVisible || tmuxSwitcherOpen ||
            showsLaunchOverlay || veilShown,
    )
    ProgramStatusEffects(
        host = host,
        liveSessionId = liveSessionId,
        controller = controller,
        programStatusCenter = programStatusCenter,
        programStatusEnabled = programStatusEnabled,
        programStatus = programStatus,
        tmuxSnapshot = tmuxSnapshot,
        presentedPrograms = presentedPrograms,
        state = state,
        isPresented = isPresented,
        hostState = hostState,
        onAgentTerminalVisible = onAgentTerminalVisible,
    )

    /**
     * Close the find chrome and hand back whatever surface it detached.
     *
     * Shared by the find bar's own close control and the back gesture, which are
     * the same act: mosh find opens over a detached full-depth capture, so every
     * exit has to return that surface to the tail or the pane stays parked in
     * history.
     */
    val closeFind: () -> Unit = {
        val moshSurfaceId = openMoshFindSurfaceId ?: pendingMoshFindSurfaceId ?: when {
            openMoshLiveFind || pendingMoshLiveFindAfterDeliveryToken != null -> "live"
            else -> null
        }
        findOpen = false
        findQuery = ""
        findResult = findTerminal.find("")
        pendingMoshFindSurfaceId = null
        pendingMoshFindAfterDeliveryToken = null
        pendingMoshFindCanReuseExistingDelivery = false
        openMoshFindSurfaceId = null
        pendingMoshLiveFindAfterDeliveryToken = null
        pendingMoshLiveFindCanReuseExistingDelivery = false
        openMoshLiveFind = false
        // Closing mosh Find returns either its detached pane overlay or live
        // primary history to the tail and asks mosh for a full live frame
        // through the ledger.
        moshSurfaceId?.let(controller::returnTmuxScrollbackToTail)
        inputTerminal.setFocused(true)
    }

    ProgramStatusFocusEffect(
        liveSessionId = liveSessionId,
        controller = controller,
        programStatusFocusRequest = programStatusFocusRequest,
        state = state,
        isPresented = isPresented,
        exactAgentBinding = exactAgentBinding,
        tmuxSnapshot = tmuxSnapshot,
        programStatusNavigation = programStatusNavigation,
        presented = presented,
        hostState = hostState,
        closeFind = closeFind,
    )

    // The system back gesture is this screen's leading chevron, one layer at a
    // time: the panel or find bar covering the terminal first, then out to the
    // tab bar. Without it the gesture reaches the activity and leaves the app
    // from inside a live session. Every live session stays composed while
    // another is presented, so only the visible one answers — and `isPresented`
    // is already false under the app lock, which must not be navigable.
    BackHandler(enabled = isPresented) {
        when {
            forwardingPanelVisible -> forwardingOpen = false
            filesPanelVisible -> filesOpen = false
            findBarVisible -> closeFind()
            else -> onBack()
        }
    }
    Scaffold(
        modifier = modifier.onFocusChanged { sessionHoldsFocus = it.hasFocus },
        containerColor = Color.Black,
        // The session owns its own bottom inset. Its bottom-most surface is the
        // accessory bar, whose material has to reach behind the gesture pill,
        // and the keyboard lift below is measured from the true window bottom —
        // a Scaffold inset here would be counted a second time by both.
        contentWindowInsets = sessionContentWindowInsets(),
        topBar = {
            SessionChrome(
                host = host,
                state = state,
                filesOpen = filesOpen,
                forwardingOpen = forwardingOpen,
                forwarding = ForwardingChromePresentation.of(
                    rules = forwardingRules,
                    states = forwardingStates,
                    panelOpen = forwardingOpen,
                ),
                compact = compactTmux,
                programStatusCenter = programStatusCenter,
                programStatusAgents = programStatusAgents,
                onOpenAgentCenter = onOpenAgentCenter,
                tmuxEnabled = host.tmuxMode != TmuxModes.OFF,
                integrationStatus = integrationStatus,
                integrationWarningVisible = integrationWarningVisible,
                onBack = {
                    onBack()
                },
                onConnect = controller::connect,
                onPaste = inputTerminal::pasteClipboard,
                onToggleFiles = {
                    programStatusNavigationEpoch += 1
                    filesOpen = !filesOpen
                    if (filesOpen) forwardingOpen = false
                },
                onToggleForwarding = {
                    programStatusNavigationEpoch += 1
                    forwardingOpen = !forwardingOpen
                    if (forwardingOpen) filesOpen = false
                },
                onOpenSwitcher = { programStatusNavigationEpoch += 1; tmuxSwitcherOpen = true },
                onNewTmuxWindow = { programStatusNavigationEpoch += 1; controller.createTmuxWindow() },
                onSearch = {
                    val moshSurfaceId = focusedMoshSplitSurfaceId
                    if (moshSurfaceId != null) {
                        // FindOpened asks the ledger for a full-depth capture
                        // and the effect delivery below chooses the detached
                        // focused-pane surface before opening the chrome.
                        findOpen = false
                        findQuery = ""
                        findResult = null
                        val existingDelivery = tmuxRenderHistory[moshSurfaceId]
                        val canReuseExistingDelivery = moshFindCanReuseFullDepthDelivery(
                            requestedSurfaceId = moshSurfaceId,
                            deliveredSurfaceId = existingDelivery?.surfaceId,
                            deliveredDepth = existingDelivery?.depth ?: 0,
                            scrollbackLimit = sessionScrollbackLines,
                        )
                        if (canReuseExistingDelivery && existingDelivery != null &&
                            moshFindCanOpenAfterAppliedDelivery(
                                requestedSurfaceId = moshSurfaceId,
                                deliveredSurfaceId = existingDelivery.surfaceId,
                                deliveredToken = existingDelivery.deliveryToken,
                                requiredNewerThanToken = existingDelivery.deliveryToken,
                                deliveredDepth = existingDelivery.depth,
                                scrollbackLimit = sessionScrollbackLines,
                                appliedDeliveryToken = appliedMoshOverlayHistoryDeliveryTokens[moshSurfaceId] ?: 0L,
                                mayReuseExistingDelivery = true,
                            ) && moshFindOverlaySurface != null
                        ) {
                            // Full-depth content is already mounted. The
                            // ledger emits no replacement at its depth limit.
                            controller.openTmuxFind(moshSurfaceId)
                            openMoshFindSurfaceId = moshSurfaceId
                            pendingMoshFindSurfaceId = null
                            pendingMoshFindAfterDeliveryToken = null
                            pendingMoshFindCanReuseExistingDelivery = false
                            findOpen = true
                        } else {
                            pendingMoshFindSurfaceId = moshSurfaceId
                            pendingMoshFindAfterDeliveryToken = existingDelivery?.deliveryToken ?: 0L
                            pendingMoshFindCanReuseExistingDelivery = canReuseExistingDelivery
                        }
                    } else if (usesMoshLiveFind) {
                        // The whole-window primary surface is mosh-owned, so
                        // request its full-depth side-channel capture before
                        // allowing Find to inspect it.
                        findOpen = false
                        findQuery = ""
                        findResult = null
                        val existingDelivery = tmuxRenderHistory["live"]
                        val canReuseExistingDelivery = moshFindCanReuseFullDepthDelivery(
                            requestedSurfaceId = "live",
                            deliveredSurfaceId = existingDelivery?.surfaceId,
                            deliveredDepth = existingDelivery?.depth ?: 0,
                            scrollbackLimit = sessionScrollbackLines,
                        )
                        controller.openTmuxFind("live")
                        if (canReuseExistingDelivery && existingDelivery != null &&
                            moshFindCanOpenAfterAppliedDelivery(
                                requestedSurfaceId = "live",
                                deliveredSurfaceId = existingDelivery.surfaceId,
                                deliveredToken = existingDelivery.deliveryToken,
                                requiredNewerThanToken = existingDelivery.deliveryToken,
                                deliveredDepth = existingDelivery.depth,
                                scrollbackLimit = sessionScrollbackLines,
                                appliedDeliveryToken = appliedMoshLiveHistoryDeliveryToken,
                                mayReuseExistingDelivery = true,
                            )
                        ) {
                            // The ledger is already at full depth and will
                            // not emit HistoryReady again. Its last delivery
                            // is confirmed applied to the live primary view.
                            openMoshLiveFind = true
                            pendingMoshLiveFindAfterDeliveryToken = null
                            pendingMoshLiveFindCanReuseExistingDelivery = false
                            findOpen = true
                            findResult = inputTerminal.find(findQuery, forward = true)
                        } else {
                            pendingMoshLiveFindAfterDeliveryToken = existingDelivery?.deliveryToken ?: 0L
                            pendingMoshLiveFindCanReuseExistingDelivery = canReuseExistingDelivery
                            openMoshLiveFind = false
                        }
                    } else {
                        findOpen = true
                    }
                },
                onContinueOnAnotherDevice = onContinueOnAnotherDevice,
                onCloseSession = controller::closeSession,
            )
        },
    ) { contentPadding ->
        // Edge-to-edge windows are not resized by `adjustResize`, so without this the
        // software-keyboard accessory row — the only way to send Escape, Tab, or a
        // control chord on a phone — sits underneath the IME that made it necessary.
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(contentPadding)
                .clipToBounds(),
        ) {
            Column(
                Modifier
                    .fillMaxSize()
                    // The lift keeps the terminal grid still; a panel in its
                    // place has no grid to keep, and lifting it would carry
                    // its header and rows off the top of the clip.
                    .then(
                        if (forwardingPanelVisible || filesPanelVisible) Modifier.imePadding()
                        else keyboardLayout.sessionModifier,
                    )
                    .then(
                        if (tmuxAuthorityPresentation is TmuxAuthorityPresentation.Veiled ||
                            tmuxAuthorityPresentation is TmuxAuthorityPresentation.Reclaiming
                        ) {
                            Modifier.blur(7.dp)
                        } else {
                            Modifier
                        },
                    ),
            ) {
                if (findBarVisible) {
                TerminalFindBar(
                    query = findQuery,
                    result = findResult,
                    onQueryChange = {
                        findQuery = it
                        findResult = findTerminal.find(it, forward = true)
                    },
                    onPrevious = { findResult = findTerminal.find(findQuery, forward = false) },
                    onNext = { findResult = findTerminal.find(findQuery, forward = true) },
                    onClose = closeFind,
                    modifier = keyboardLayout.chromeCounterShiftModifier,
                )
                }
                if (state != SshSessionUiState.Connected) SessionStatus(state)
                if (forwardingPanelVisible) {
                    PortForwardingPanel(
                        hostId = host.id,
                        sessionHint = liveSessionId,
                        rules = forwardingRules,
                        states = forwardingStates,
                        onRulesChanged = { updated ->
                            scope.launch { forwardingRuleStore.replace(host.id, updated) }
                        },
                        onStartRule = controller::startForwardingRule,
                        onStopRule = controller::stopForwardingRule,
                        onProbeServices = controller::probeForwardedServicesNow,
                        modifier = Modifier.fillMaxWidth().weight(1f).sessionBottomInsetPadding(),
                    )
                } else if (filesPanelVisible) {
                    RemoteFilesScreen(
                        controller = filesController,
                        onOpenPath = filesController::quickOpenPath,
                        onSystemPickerActiveChanged = filesPickerExcursion,
                        onOutboundPresentationActiveChanged = filesOutboundExcursion,
                        terminalPathSink = RemoteTerminalPathSink { path ->
                            filesOpen = false
                            inputTerminal.sendInput(path.shellQuoted.encodeToByteArray())
                            inputTerminal.setFocused(true)
                        },
                        modifier = Modifier.fillMaxWidth().weight(1f).sessionBottomInsetPadding(),
                    )
                } else {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .weight(1f)
                            // Drop-on-terminal, matching the desktop convention
                            // iOS follows: the file goes to the reaped temp
                            // directory and its quoted path is typed at the
                            // cursor, so the drop reads as an argument.
                            .remoteFileDropTarget(
                                enabled = state == SshSessionUiState.Connected,
                                onDropped = { uris ->
                                    uris.forEach { uri ->
                                        runShareUpload(
                                            uri = uri,
                                            pending = PendingShareUpload(
                                                hostId = host.id,
                                                uris = listOf(uri),
                                                destination = ShareUploadDestination.Temp,
                                                pastePath = true,
                                            ),
                                            replaceExisting = false,
                                        )
                                    }
                                },
                            )
                            .clipToBounds(),
                    ) {
                        if (host.tmuxMode != TmuxModes.OFF && state == SshSessionUiState.Connected) {
                            TmuxPresentation(
                                snapshot = tmuxSnapshot,
                                onNavigate = { programStatusNavigationEpoch += 1 },
                                programSessions = programSessions,
                                programHostId = host.id,
                                programStatusAgents = programStatusAgents,
                                agentProvider = { paneId -> exactAgentBinding?.key?.let(paneAgentProviders::get)?.get(paneId) },
                                tmuxRenderHistory = tmuxRenderHistory,
                                pendingMoshFindPaneId = pendingMoshFindSurfaceId?.substringAfter("overlay:")?.toIntOrNull(),
                                primaryTerminal = terminal,
                                controller = controller,
                                allowsWindowOrdering = tmuxWindowMutationState == TmuxWindowMutationState.Available,
                                windowOrderingContextValid =
                                    tmuxWindowMutationState == TmuxWindowMutationState.Available ||
                                        tmuxWindowMutationState == TmuxWindowMutationState.Pending,
                                windowOrderAuthorityKey = tmuxAuthority,
                                compact = compactTmux,
                                scrollbackLines = sessionScrollbackLines,
                                terminalTextSizeSp = terminalTextSizeSp,
                                terminalTypeface = terminalTypeface,
                                terminalTheme = terminalTheme,
                                cursorStyle = cursorStyle,
                                cursorBlink = terminalCursorBlink,
                                terminalDrawingEnabled = terminalDrawing,
                                activePaneId = locallyFocusedTmuxPaneId ?: tmuxSnapshot?.activePaneId,
                                terminalCounterShiftModifier = keyboardLayout.terminalCounterShiftModifier,
                                outageBannerModifier = keyboardLayout.chromeCounterShiftModifier,
                                onPaneFocused = { programStatusNavigationEpoch += 1; locallyFocusedTmuxPaneId = it },
                                onPaneSurfaceChanged = { paneId, surface, attached ->
                                    if (attached) {
                                        paneSurfaces[paneId] = surface
                                        surface.onFirstOutputRendered = reportRenderedReady
                                        surface.onSoftwareModifiersConsumed = { surviving ->
                                            armedModifiers = surviving
                                        }
                                        surface.isRemotePathSelection = RemoteSelectionPathResolver::isPlausiblePath
                                        surface.onSelectionPathAction = { action, selection ->
                                            currentSelectionPathAction(action, selection)
                                        }
                                    } else if (paneSurfaces[paneId] === surface) {
                                        paneSurfaces.remove(paneId)
                                        surface.onFirstOutputRendered = null
                                        surface.onSoftwareModifiersConsumed = null
                                        surface.isRemotePathSelection = null
                                        surface.onSelectionPathAction = null
                                    }
                                    // Emit even if the logical pane ID is
                                    // unchanged: the physical surface may
                                    // have been recreated by Compose.
                                    surfaceMountGeneration += 1
                                },
                                onMoshOverlaySurfaceChanged = { paneId, surface, attached ->
                                    if (attached) {
                                        overlaySurfaces[paneId] = surface
                                        controller.attachTmuxOverlay(paneId, surface)
                                    } else {
                                        if (overlaySurfaces[paneId] === surface) {
                                            overlaySurfaces.remove(paneId)
                                        }
                                        controller.detachTmuxOverlay(paneId, surface)
                                    }
                                    // A lazy reader's first gesture requests
                                    // history in this same call stack. Publish
                                    // its declaration before that request.
                                    controller.declareTmuxRenderSurfaces(
                                        tmuxScreenRenderSurfaceDeclarations(
                                            presentation = tmuxScreenRenderPresentation,
                                            activeWindowId = tmuxSnapshot?.activeWindowId,
                                            activePaneId = tmuxSnapshot?.activePaneId,
                                            activePaneIds = activeTmuxPaneIds,
                                            mountedGridPaneIds = paneSurfaces.keys.toSet(),
                                            mountedOverlayPaneIds = overlaySurfaces.keys.toSet(),
                                        ),
                                    )
                                    // Mosh parked overlays use stable pane
                                    // IDs, so identity must be represented by
                                    // the separate mount generation.
                                    surfaceMountGeneration += 1
                                },
                                onMoshHistoryOverlaySurfaceChanged = { surface ->
                                    moshFindOverlaySurface = surface
                                },
                                onMoshHistoryDeliveryApplied = { surfaceId, deliveryToken ->
                                    if (surfaceId == "live") {
                                        appliedMoshLiveHistoryDeliveryToken = maxOf(
                                            appliedMoshLiveHistoryDeliveryToken,
                                            deliveryToken,
                                        )
                                    } else {
                                        val prior = appliedMoshOverlayHistoryDeliveryTokens[surfaceId] ?: 0L
                                        if (deliveryToken > prior) {
                                            appliedMoshOverlayHistoryDeliveryTokens =
                                                appliedMoshOverlayHistoryDeliveryTokens + (surfaceId to deliveryToken)
                                        }
                                    }
                                    controller.acknowledgeTmuxRenderHistoryPresented(surfaceId, deliveryToken)
                                },
                                unreadWindowIds = if (bellPreferences.visualEnabled) {
                                    bellUnread.tmuxWindowIdsBySession[host.id].orEmpty()
                                } else emptySet(),
                                glowingWindowId = glowingTmuxWindowId.takeIf { bellPreferences.visualEnabled },
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else {
                            // Never hand the shared terminal view to a
                            // holder directly: it is long-lived and may
                            // still be parented by the viewport this
                            // branch is replacing. The viewport with no
                            // grid measures it exactly as a bare mount
                            // did, and owns the attach/detach discipline.
                            TerminalViewport(
                                terminal = terminal,
                                drawingEnabled = terminalDrawing,
                                modifier = Modifier
                                    .fillMaxSize()
                                    .then(keyboardLayout.terminalCounterShiftModifier),
                            )
                        }
                    }
                    if (state == SshSessionUiState.Connected && !filesOpen && !forwardingOpen) {
                        TerminalSoftwareAccessory(
                            keys = resolvedAccessoryBarKeys,
                            armed = armedModifiers,
                            notation = chordNotation,
                            keyboardVisible = softwareKeyboardVisible,
                            onModifier = { name ->
                                armedModifiers = SharedInputEncoding.modifierArmingTransition(
                                    SharedModifierArming(armingBehavior, armedModifiers),
                                    SharedModifierArmingEvent.Tap(name),
                                ).state.armed
                            },
                            onKey = { key -> sendAccessoryKey(inputTerminal, key, armedModifiers) },
                            onKeyboard = inputTerminal::toggleSoftwareKeyboard,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
            if (showsLaunchOverlay) {
                SessionLaunchOverlay(
                    phase = launchPhase,
                    // `displayName` falls back to the window id, and "@1" is a
                    // worse subtitle than none — it is not blank, so the
                    // overlay would render it.
                    subtitle = host.tmuxTarget ?: tmuxSnapshot?.activeWindow?.namedLabel,
                    failureReason = launchFailure,
                    onEditHost = onEditHost,
                    onRetry = {
                        controller.prepareRetry()
                        controller.connect()
                    },
                    onBack = onBack,
                    modifier = Modifier.fillMaxSize().zIndex(2f),
                    animated = sessionAnimates,
                )
            }
            // Toast and transfer strip share one stack so a failure banner and
            // a still-running upload never land on top of each other.
            val movingTransfers = transfers.inFlight()
            // Its indeterminate track animates; a hidden session shows it on return (P9).
            val stripVisible = movingTransfers.isNotEmpty() && !filesOpen && !showsLaunchOverlay && isPresented
            // `resuming`: the terminal stays readable; only this pill says a
            // show is still deciding who owns the grid (input is gated).
            val resuming = (tmuxAuthorityPresentation as? TmuxAuthorityPresentation.Resuming)
                ?.takeIf { !showsLaunchOverlay }
            if (terminalToast != null || stripVisible || resuming != null) {
                Column(
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(12.dp)
                        .zIndex(4f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    resuming?.let {
                        TmuxResumingIndicator(
                            awaitingConnection = it.awaitingConnection,
                            onCancelPending = controller::cancelPendingTmuxAuthorityIntent,
                            animated = sessionAnimates,
                        )
                    }
                    terminalToast?.let { message -> TesseraBanner(text = message) }
                    // Progress for work the panel would be showing if it were
                    // open. A share to the temp directory never opens it, so
                    // this is the only place that upload is visible while it
                    // runs.
                    if (stripVisible) {
                        RemoteTransferStrip(
                            items = movingTransfers,
                            onCancel = { item ->
                                if (pastePathInFlight) {
                                    shareCancelPrompt = item
                                } else {
                                    filesController.cancel(item.id)
                                }
                            },
                            onOpenPanel = {
                                filesOpen = true
                                forwardingOpen = false
                            },
                        )
                    }
                }
            }
            val veil = tmuxAuthorityPresentation
            val veilPeerName = when (veil) {
                is TmuxAuthorityPresentation.Veiled -> veil.peerName
                is TmuxAuthorityPresentation.Reclaiming -> veil.peerName
                else -> null
            }
            val veilAwaitingConnection = (veil as? TmuxAuthorityPresentation.Reclaiming)?.awaitingConnection == true
            if (veilShown) {
                // Both are stable for the life of the takeover, and one crosses
                // JNI while the other reads SharedPreferences — neither belongs
                // on a recomposition path this hot.
                val selfDeviceName = remember(context) { tmuxDeviceIdentity(context).displayName }
                val peerLabel = remember(veilPeerName, selfDeviceName) {
                    SharedTmuxPeerLabel.display(
                        peerDisplayName = veilPeerName,
                        selfDisplayName = selfDeviceName,
                    )
                }
                ContinuedElsewhereOverlay(
                    peerDisplayName = peerLabel,
                    isReclaiming = veil is TmuxAuthorityPresentation.Reclaiming,
                    onTakeBack = controller::reclaimTmuxGridAuthority,
                    acceptsFocus = isPresented,
                    awaitingConnection = veilAwaitingConnection,
                    onCancelPending = controller::cancelPendingTmuxAuthorityIntent,
                    modifier = Modifier.fillMaxSize().zIndex(3f),
                )
            }
        }
    }

    SessionDialogs(
        controller = controller,
        filesController = filesController,
        agentIntegration = agentIntegration,
        state = state,
        isPresented = isPresented,
        integrationStatus = integrationStatus,
        integrationWarningVisible = integrationWarningVisible,
        exactAgentBinding = exactAgentBinding,
        hostState = hostState,
        integrationPrompts = integrationPrompts,
        runShareUpload = startShareUpload,
    )

    if (isPresented && tmuxSwitcherOpen) {
        SessionTmuxSwitcher(
            host = host,
            controller = controller,
            tmuxSnapshot = tmuxSnapshot,
            tmuxAuthority = tmuxAuthority,
            tmuxAuthorityPresentation = tmuxAuthorityPresentation,
            tmuxWindowMutationState = tmuxWindowMutationState,
            exactAgentBinding = exactAgentBinding,
            paneAgentProviders = paneAgentProviders,
            integrationStatus = integrationStatus,
            integrationWarningVisible = integrationWarningVisible,
            switcherSessions = switcherSessions,
            programStatusCenter = programStatusCenter,
            programStatusAgents = programStatusAgents,
            programStatusNavigation = programStatusNavigation,
            bellPreferences = bellPreferences,
            bellUnread = bellUnread,
            hostState = hostState,
            integrationPrompts = integrationPrompts,
            onSelectSession = onSelectSession,
            onBack = onBack,
        )
    }

    if (isPresented) (state as? SshSessionUiState.AwaitingHostKey)?.let { awaiting ->
        HostKeyDialog(
            challenge = awaiting.challenge,
            onDecision = controller::decideHostKey,
        )
    }

}

/**
 * The screen state that belongs to one host and resets with it. Each field was
 * a `remember(host.id)` of its own; one holder keeps the screen under ART's
 * method-size limit.
 */
private class SessionHostState(startsInForeground: Boolean) {
    val glowingTmuxWindowId = mutableStateOf<Int?>(null)
    val terminalTitle = mutableStateOf<String?>(null)
    val filesOpen = mutableStateOf(false)
    val forwardingOpen = mutableStateOf(false)
    val tmuxSwitcherOpen = mutableStateOf(false)
    val findOpen = mutableStateOf(false)
    val findQuery = mutableStateOf("")
    val findResult = mutableStateOf<TerminalSearchResult?>(null)
    val moshFindOverlaySurface = mutableStateOf<TermuxTerminalSurface?>(null)
    val pendingMoshFindSurfaceId = mutableStateOf<String?>(null)
    val pendingMoshFindAfterDeliveryToken = mutableStateOf<Long?>(null)
    val pendingMoshFindCanReuseExistingDelivery = mutableStateOf(false)
    val openMoshFindSurfaceId = mutableStateOf<String?>(null)
    val appliedMoshOverlayHistoryDeliveryTokens = mutableStateOf<Map<String, Long>>(emptyMap())
    val appliedMoshLiveHistoryDeliveryToken = mutableLongStateOf(0L)
    val pendingMoshLiveFindAfterDeliveryToken = mutableStateOf<Long?>(null)
    val pendingMoshLiveFindCanReuseExistingDelivery = mutableStateOf(false)
    val openMoshLiveFind = mutableStateOf(false)
    val armedModifiers = mutableStateOf(SharedArmedModifiers())
    val plainTerminalDirectory = mutableStateOf<String?>(null)
    val terminalToast = mutableStateOf<String?>(null)
    val selectedPathPresentationActive = mutableStateOf(false)
    val appForeground = mutableStateOf(startsInForeground)
    val locallyFocusedTmuxPaneId = mutableStateOf<Int?>(null)
    val pickerExcursions = ExternalUiExcursions()
    val shareConflict = mutableStateOf<PendingShareConflict?>(null)
    val shareCancelPrompt = mutableStateOf<TransferItem?>(null)
    val pastePathInFlight = mutableStateOf(false)
}

/** The screen's terminal surfaces and their mount state, reset with the terminal. */
private class SessionSurfaceState {
    val paneSurfaces = mutableStateMapOf<Int, TermuxTerminalSurface>()
    val overlaySurfaces = mutableStateMapOf<Int, TermuxTerminalSurface>()
    val primaryTerminalAttached = mutableStateOf(false)
    val surfaceMountGeneration = mutableLongStateOf(0L)
    val renderedReadyReported = mutableStateOf(false)
}

/** The integration warning, its help and an action awaiting confirmation, per live session. */
private class SessionIntegrationPrompts {
    val integrationWarningOpen = mutableStateOf(false)
    val integrationHelpOpen = mutableStateOf(false)
    val pendingIntegrationAction = mutableStateOf<AgentSessionIntegrationActionRequest?>(null)
}

/**
 * A tmux launch that degraded to a plain shell is silent otherwise: the
 * session connects and works, just without tmux, and the user is left
 * wondering where their windows went.
 */
@Composable
@NonRestartableComposable
private fun TmuxDegradeNoticeEffect(
    controller: SshSessionController,
    hostState: SessionHostState,
    resources: Resources,
) {
    var terminalToast by hostState.terminalToast
    val tmuxDegradeNotice by controller.tmuxDegradeNotice.collectAsState()
    LaunchedEffect(tmuxDegradeNotice) {
        tmuxDegradeNotice?.let { terminalToast = it.resolve(resources) }
    }
}

/** Switches program status on and off, and takes this host out of the center when it leaves. */
@Composable
@NonRestartableComposable
private fun ProgramStatusRegistration(
    host: SavedHost,
    controller: SshSessionController,
    programStatusCenter: ProgramStatusCenter?,
    programStatusEnabled: Boolean,
) {
    LaunchedEffect(controller, programStatusEnabled) {
        controller.setProgramStatusEnabled(programStatusEnabled)
    }
    DisposableEffect(programStatusCenter, host.id, controller) {
        onDispose { programStatusCenter?.remove(host.id) }
    }
}

/**
 * Publishes the presentation the screen chose and the surfaces it mounted for
 * it to the render ledger.
 */
@Composable
@NonRestartableComposable
private fun TmuxRenderDeclarationEffects(
    controller: SshSessionController,
    tmuxScreenRenderPresentation: TmuxScreenRenderPresentation,
    tmuxSnapshot: SharedTmuxSnapshot?,
    activeTmuxPaneIds: Set<Int>,
    mountedGridPaneIds: Set<Int>,
    mountedOverlayPaneIds: Set<Int>,
    surfaceMountGeneration: Long,
) {
    SideEffect {
        controller.setTmuxScreenRenderPresentation(tmuxScreenRenderPresentation)
    }
    LaunchedEffect(
        controller,
        tmuxScreenRenderPresentation,
        tmuxSnapshot?.activeWindowId,
        tmuxSnapshot?.activePaneId,
        activeTmuxPaneIds,
        mountedGridPaneIds,
        mountedOverlayPaneIds,
        surfaceMountGeneration,
    ) {
        controller.declareTmuxRenderSurfaces(
            tmuxScreenRenderSurfaceDeclarations(
                presentation = tmuxScreenRenderPresentation,
                activeWindowId = tmuxSnapshot?.activeWindowId,
                activePaneId = tmuxSnapshot?.activePaneId,
                activePaneIds = activeTmuxPaneIds,
                mountedGridPaneIds = mountedGridPaneIds,
                mountedOverlayPaneIds = mountedOverlayPaneIds,
            ),
        )
    }
}

/**
 * Opens Find once the full-depth mosh capture it waits for has been applied,
 * and returns a capture to the tail when its pane or live surface stops
 * being the one Find would search.
 */
@Composable
@NonRestartableComposable
private fun MoshFindEffects(
    hostState: SessionHostState,
    controller: SshSessionController,
    focusedMoshSplitSurfaceId: String?,
    usesMoshLiveFind: Boolean,
    tmuxRenderHistory: Map<String, TmuxRenderHistoryReady>,
    inputTerminal: TermuxTerminalSurface,
    sessionScrollbackLines: Int,
) {
    var findOpen by hostState.findOpen
    var findQuery by hostState.findQuery
    var findResult by hostState.findResult
    val moshFindOverlaySurface by hostState.moshFindOverlaySurface
    var pendingMoshFindSurfaceId by hostState.pendingMoshFindSurfaceId
    var pendingMoshFindAfterDeliveryToken by hostState.pendingMoshFindAfterDeliveryToken
    var pendingMoshFindCanReuseExistingDelivery by hostState.pendingMoshFindCanReuseExistingDelivery
    var openMoshFindSurfaceId by hostState.openMoshFindSurfaceId
    val appliedMoshOverlayHistoryDeliveryTokens by hostState.appliedMoshOverlayHistoryDeliveryTokens
    val appliedMoshLiveHistoryDeliveryToken by hostState.appliedMoshLiveHistoryDeliveryToken
    var pendingMoshLiveFindAfterDeliveryToken by hostState.pendingMoshLiveFindAfterDeliveryToken
    var pendingMoshLiveFindCanReuseExistingDelivery by hostState.pendingMoshLiveFindCanReuseExistingDelivery
    var openMoshLiveFind by hostState.openMoshLiveFind
    LaunchedEffect(
        pendingMoshFindSurfaceId,
        pendingMoshFindAfterDeliveryToken,
        pendingMoshFindCanReuseExistingDelivery,
        focusedMoshSplitSurfaceId,
        tmuxRenderHistory,
        moshFindOverlaySurface,
        appliedMoshOverlayHistoryDeliveryTokens,
    ) {
        val pendingSurfaceId = pendingMoshFindSurfaceId ?: return@LaunchedEffect
        if (pendingSurfaceId != focusedMoshSplitSurfaceId) {
            pendingMoshFindSurfaceId = null
            return@LaunchedEffect
        }
        // Delay the find chrome until the controller has delivered full-depth
        // content *and* the detached pane surface is the one under it. A
        // previously delivered full-depth capture is equally valid: FindOpened
        // is intentionally a no-op at that ledger depth.
        val delivery = tmuxRenderHistory[pendingSurfaceId]
        val minimumDeliveryToken = pendingMoshFindAfterDeliveryToken ?: Long.MAX_VALUE
        val canOpen = delivery != null && moshFindCanOpenAfterAppliedDelivery(
            requestedSurfaceId = pendingSurfaceId,
            deliveredSurfaceId = delivery.surfaceId,
            deliveredToken = delivery.deliveryToken,
            requiredNewerThanToken = minimumDeliveryToken,
            deliveredDepth = delivery.depth,
            scrollbackLimit = sessionScrollbackLines,
            appliedDeliveryToken = appliedMoshOverlayHistoryDeliveryTokens[pendingSurfaceId] ?: 0L,
            mayReuseExistingDelivery = pendingMoshFindCanReuseExistingDelivery,
        )
        if (canOpen && moshFindOverlaySurface != null) {
            openMoshFindSurfaceId = pendingSurfaceId
            pendingMoshFindSurfaceId = null
            pendingMoshFindAfterDeliveryToken = null
            pendingMoshFindCanReuseExistingDelivery = false
            findOpen = true
        }
    }
    LaunchedEffect(focusedMoshSplitSurfaceId) {
        val openSurfaceId = openMoshFindSurfaceId
        if (openSurfaceId != null && openSurfaceId != focusedMoshSplitSurfaceId) {
            controller.returnTmuxScrollbackToTail(openSurfaceId)
            openMoshFindSurfaceId = null
            findOpen = false
            findQuery = ""
            findResult = null
        }
        if (pendingMoshFindSurfaceId != null && pendingMoshFindSurfaceId != focusedMoshSplitSurfaceId) {
            pendingMoshFindSurfaceId = null
            pendingMoshFindAfterDeliveryToken = null
            pendingMoshFindCanReuseExistingDelivery = false
        }
    }
    LaunchedEffect(
        pendingMoshLiveFindAfterDeliveryToken,
        pendingMoshLiveFindCanReuseExistingDelivery,
        appliedMoshLiveHistoryDeliveryToken,
        tmuxRenderHistory,
        usesMoshLiveFind,
    ) {
        val minimumDeliveryToken = pendingMoshLiveFindAfterDeliveryToken ?: return@LaunchedEffect
        if (!usesMoshLiveFind) return@LaunchedEffect
        val delivery = tmuxRenderHistory["live"] ?: return@LaunchedEffect
        val canOpen = moshFindCanOpenAfterAppliedDelivery(
            requestedSurfaceId = "live",
            deliveredSurfaceId = delivery.surfaceId,
            deliveredToken = delivery.deliveryToken,
            requiredNewerThanToken = minimumDeliveryToken,
            deliveredDepth = delivery.depth,
            scrollbackLimit = sessionScrollbackLines,
            appliedDeliveryToken = appliedMoshLiveHistoryDeliveryToken,
            mayReuseExistingDelivery = pendingMoshLiveFindCanReuseExistingDelivery,
        )
        if (canOpen) {
            pendingMoshLiveFindAfterDeliveryToken = null
            pendingMoshLiveFindCanReuseExistingDelivery = false
            openMoshLiveFind = true
            findOpen = true
            findResult = inputTerminal.find(findQuery, forward = true)
        }
    }
    LaunchedEffect(usesMoshLiveFind) {
        if (!usesMoshLiveFind && (openMoshLiveFind || pendingMoshLiveFindAfterDeliveryToken != null)) {
            controller.returnTmuxScrollbackToTail("live")
            openMoshLiveFind = false
            pendingMoshLiveFindAfterDeliveryToken = null
            pendingMoshLiveFindCanReuseExistingDelivery = false
            findOpen = false
            findQuery = ""
            findResult = null
        }
    }
}

/**
 * An Agent Center transcript path: the terminal's own Files resolution,
 * anchored to the agent's pane (see `transcriptSelectionDirectory`).
 */
@Composable
@NonRestartableComposable
private fun TranscriptSelectionEffect(
    transcriptSelectionRequest: TranscriptSelectionPathRequest?,
    onTranscriptSelectionConsumed: (TranscriptSelectionPathRequest) -> Unit,
    onTranscriptSelectionOutcome: (TranscriptSelectionPathRequest, TranscriptSelectionPathOutcome) -> Unit,
    host: SavedHost,
    controller: SshSessionController,
    filesController: RemoteFilesController,
    hostState: SessionHostState,
    quickOpenExcursion: (Boolean) -> Unit,
) {
    var filesOpen by hostState.filesOpen
    var forwardingOpen by hostState.forwardingOpen
    var findOpen by hostState.findOpen
    var selectedPathPresentationActive by hostState.selectedPathPresentationActive
    val plainTerminalDirectory by hostState.plainTerminalDirectory
    val currentTranscriptSelectionConsumed by rememberUpdatedState(onTranscriptSelectionConsumed)
    val currentTranscriptSelectionOutcome by rememberUpdatedState(onTranscriptSelectionOutcome)
    val currentPlainTerminalDirectory by rememberUpdatedState(plainTerminalDirectory)
    LaunchedEffect(transcriptSelectionRequest?.token) {
        val request = transcriptSelectionRequest ?: return@LaunchedEffect
        currentTranscriptSelectionConsumed(request)
        val missed: (String) -> Unit = { message ->
            currentTranscriptSelectionOutcome(request, TranscriptSelectionPathOutcome.Missed(message))
        }
        if (controller.state.value != SshSessionUiState.Connected || controller.transportReachable.value == false) {
            // English, as Agent Center keeps its notices; it translates this one as it shows it.
            missed(TERMINAL_SESSION_NOT_CONNECTED)
            return@LaunchedEffect
        }
        val perform: (String?) -> Unit = { directory ->
            filesController.openTranscriptSelectedPath(
                selection = request.selection,
                paneDirectory = directory,
                intent = request.intent,
                onRevealRequested = {
                    forwardingOpen = false
                    findOpen = false
                    filesOpen = true
                    currentTranscriptSelectionOutcome(request, TranscriptSelectionPathOutcome.Revealed)
                },
                onPresentationLaunched = {
                    selectedPathPresentationActive = true
                    quickOpenExcursion(true)
                },
                onFailure = missed,
            )
        }
        when (val anchor = transcriptSelectionDirectory(
            selection = request.selection,
            tmuxOff = host.tmuxMode == TmuxModes.OFF,
            paneId = request.tmuxPaneId,
            reportedShellDirectory = currentPlainTerminalDirectory,
        ) { pane ->
            controller.tmuxSnapshot.value?.windows
                ?.firstNotNullOfOrNull { window -> window.panes.firstOrNull { it.id == pane } }?.currentPath
        }) {
            is TranscriptSelectionDirectory.Known -> perform(anchor.directory)
            is TranscriptSelectionDirectory.QueryPane ->
                controller.queryTerminalDirectory(anchor.fallback, anchor.paneId) { fresh -> perform(fresh ?: anchor.fallback) }
        }
    }
}

/** Reports state and reachability out, and keeps the bell's read marks and glow current. */
@Composable
@NonRestartableComposable
private fun SessionStateEffects(
    host: SavedHost,
    state: SshSessionUiState,
    isPresented: Boolean,
    transportReachable: Boolean?,
    tmuxSnapshot: SharedTmuxSnapshot?,
    terminal: TermuxTerminalSurface,
    paneSurfaces: Map<Int, TermuxTerminalSurface>,
    bellController: AndroidBellController,
    bellPreferences: BellPreferences,
    bellVisualPulse: BellVisualPulse?,
    hostState: SessionHostState,
    reportRenderedReady: () -> Unit,
    onStateChanged: (SshSessionUiState) -> Unit,
    onTransportReachableChanged: (Boolean?) -> Unit,
) {
    var glowingTmuxWindowId by hostState.glowingTmuxWindowId
    val sessionView = LocalView.current
    LaunchedEffect(transportReachable) {
        onTransportReachableChanged(transportReachable)
    }
    LaunchedEffect(state, isPresented) {
        // A terminated session leaves composition in the same pass that ends
        // its presentation, so the presentation effect never sees it go, and
        // by now its terminal may have left focus (tmux modes remount it; a
        // side panel replaces it). A presented session covers the app, so a
        // keyboard on this window is its own: take it down before the host
        // drops the session.
        if (state == SshSessionUiState.Terminated && isPresented) sessionView.hideSoftwareKeyboard()
        onStateChanged(state)
        if (terminal.hasRenderedOutput || paneSurfaces.values.any { it.hasRenderedOutput }) reportRenderedReady()
    }
    LaunchedEffect(isPresented, tmuxSnapshot?.activeWindowId) {
        if (isPresented) {
            bellController.markSessionRead(host.id)
            tmuxSnapshot?.activeWindowId?.let { bellController.markTmuxWindowRead(host.id, it) }
        }
    }
    LaunchedEffect(bellVisualPulse, bellPreferences.visualEnabled) {
        if (!bellPreferences.visualEnabled) {
            glowingTmuxWindowId = null
            return@LaunchedEffect
        }
        val source = bellVisualPulse?.source as? BellSource.TmuxWindow
        if (source?.sessionId == host.id) {
            glowingTmuxWindowId = source.windowId
            kotlinx.coroutines.delay(600)
            if (glowingTmuxWindowId == source.windowId) glowingTmuxWindowId = null
        }
    }
}

/**
 * Attaches the primary terminal to the controller while both last, and routes
 * its callbacks (modifiers, title, cwd, selection, bell) to the screen.
 */
@Composable
@NonRestartableComposable
private fun PrimaryTerminalAttachment(
    host: SavedHost,
    controller: SshSessionController,
    terminal: TermuxTerminalSurface,
    surfaceState: SessionSurfaceState,
    hostState: SessionHostState,
    bellController: AndroidBellController,
    bellPreferences: BellPreferences,
    presented: State<Boolean>,
    /** Reads the screen's current action each time it runs. */
    currentSelectionPathAction: (TerminalSelectionPathAction, String) -> Unit,
    reportRenderedReady: () -> Unit,
    onTerminalTextSizeChanged: (Int) -> Unit,
) {
    var primaryTerminalAttached by surfaceState.primaryTerminalAttached
    var surfaceMountGeneration by surfaceState.surfaceMountGeneration
    var armedModifiers by hostState.armedModifiers
    var terminalTitle by hostState.terminalTitle
    var plainTerminalDirectory by hostState.plainTerminalDirectory
    val currentPresented by presented
    val currentBellPreferences by rememberUpdatedState(bellPreferences)
    val currentTerminalTitle by rememberUpdatedState(terminalTitle)
    DisposableEffect(controller, terminal) {
        controller.attachTerminal(terminal)
        primaryTerminalAttached = true
        surfaceMountGeneration += 1
        terminal.onSoftwareModifiersConsumed = { surviving -> armedModifiers = surviving }
        terminal.onFontSizeChanged = onTerminalTextSizeChanged
        terminal.onTitleChanged = { terminalTitle = it }
        terminal.onHostDirectoryChanged = { plainTerminalDirectory = it }
        terminal.isRemotePathSelection = RemoteSelectionPathResolver::isPlausiblePath
        terminal.onSelectionPathAction = { action, selection ->
            currentSelectionPathAction(action, selection)
        }
        terminal.onSoftwareKeyboardRequested = {
            terminal.requestSoftwareKeyboard()
        }
        terminal.onFirstOutputRendered = reportRenderedReady
        terminal.onBell = {
            if (host.tmuxMode == TmuxModes.OFF) {
                bellController.ring(
                    BellEvent(
                        source = BellSource.Session(host.id),
                        originOnScreen = currentPresented,
                        hostDisplayName = host.displayName,
                        paneTitle = currentTerminalTitle,
                    ),
                    currentBellPreferences,
                )
            }
        }
        controller.onTmuxBell = { bell ->
            bellController.ring(
                BellEvent(
                    source = BellSource.TmuxWindow(host.id, bell.windowId),
                    originOnScreen = currentPresented && bell.isActiveWindow,
                    hostDisplayName = host.displayName,
                    paneTitle = bell.windowName,
                ),
                currentBellPreferences,
            )
        }
        onDispose {
            terminal.onSoftwareModifiersConsumed = null
            terminal.onFontSizeChanged = null
            terminal.onTitleChanged = null
            terminal.onHostDirectoryChanged = null
            terminal.isRemotePathSelection = null
            terminal.onSelectionPathAction = null
            terminal.onSoftwareKeyboardRequested = null
            terminal.onFirstOutputRendered = null
            terminal.onBell = null
            controller.onTmuxBell = null
            primaryTerminalAttached = false
            surfaceMountGeneration += 1
            // Composition is leaving before a new declaration effect can
            // run. Retract the exact screen-owned set before closing its
            // physical surface so a queued ledger callback cannot target it.
            controller.declareTmuxRenderSurfaces(emptyList())
            controller.detachTerminal(terminal)
            terminal.close()
        }
    }
}

/** Offers this session's Files and forwarding to Artifacts while they are live. */
@Composable
@NonRestartableComposable
private fun ArtifactLiveRegistrations(
    host: SavedHost,
    liveSessionId: String,
    controller: SshSessionController,
    filesController: RemoteFilesController,
    state: SshSessionUiState,
    forwardingStates: Map<UUID, PortForwardingState>,
) {
    DisposableEffect(filesController, controller, host.id, liveSessionId) {
        val registration = com.bambouville.tessera.files.ArtifactLiveFilesRegistry.register(
            host.id, liveSessionId, filesController,
            sessionLive = { controller.hasLiveArtifactFilesOwner },
            channelOpenable = { controller.canOpenArtifactFilesChannel },
        )
        onDispose {
            registration.close()
            filesController.close()
        }
    }
    LaunchedEffect(filesController) {
        filesController.state.collect { com.bambouville.tessera.files.ArtifactLiveFilesRegistry.changed() }
    }
    DisposableEffect(controller, host.id, liveSessionId) {
        val registration = com.bambouville.tessera.forwarding.ArtifactLiveForwardingRegistry.register(
            host.id, liveSessionId, controller.forwardingStates,
            transportLive = { controller.state.value == SshSessionUiState.Connected },
        )
        onDispose { registration.close() }
    }
    LaunchedEffect(state, forwardingStates) {
        com.bambouville.tessera.files.ArtifactLiveFilesRegistry.changed()
        com.bambouville.tessera.forwarding.ArtifactLiveForwardingRegistry.changed()
    }
}

/**
 * Follows presentation and the activity lifecycle: the keyboard, forwarded
 * service probes, the foreground, and a pairing session's one connect.
 */
@Composable
@NonRestartableComposable
private fun SessionLifecycleEffects(
    host: SavedHost,
    controller: SshSessionController,
    terminal: TermuxTerminalSurface,
    paneSurfaces: Map<Int, TermuxTerminalSurface>,
    isPresented: Boolean,
    sessionFocus: State<Boolean>,
    forwardingRules: List<PortForwardRule>,
    lifecycleOwner: LifecycleOwner,
    hostState: SessionHostState,
    quickOpenExcursion: (Boolean) -> Unit,
    pairingTmuxTarget: String?,
    pairingAttemptId: String?,
    diagnostics: DiagnosticLogStore,
) {
    val sessionHoldsFocus by sessionFocus
    var appForeground by hostState.appForeground
    var selectedPathPresentationActive by hostState.selectedPathPresentationActive
    var pairingAutoConnectConsumed by remember(host.id, pairingAttemptId) { mutableStateOf(false) }
    val sessionView = LocalView.current
    val focusManager = LocalFocusManager.current
    LaunchedEffect(controller, isPresented) {
        // A session leaving the screen takes down the keyboard its own editor
        // raised (a terminal, or a field such as Find's) while that editor
        // still has focus. Presentation clears the terminal's focus, and with
        // nothing focused the window has no editor left to hide, so the
        // keyboard would stay over the screen that replaces this one. A
        // destination that has already taken focus keeps its keyboard.
        if (!isPresented && (sessionHoldsFocus || (paneSurfaces.values + terminal).any { it.view.hasFocus() })) {
            sessionView.hideSoftwareKeyboard()
            if (sessionHoldsFocus) focusManager.clearFocus(force = true)
        }
        controller.setPresentationActive(isPresented)
    }
    LaunchedEffect(forwardingRules) {
        controller.updateForwardingRules(forwardingRules)
    }
    // Forwarded-service liveness is probed only while someone can see it:
    // this session presented and the activity resumed. Each probe is a
    // channel on the user's own SSH connection, and a refused one a line in
    // the host's sshd log. The forwarding panel is not a reason of its own:
    // it is visible only while presented, and `forwardingOpen` outlives a
    // switch to another session, which stays composed behind it.
    val monitorsForwardedServices = forwardingRules.isNotEmpty() && isPresented
    LaunchedEffect(controller, lifecycleOwner, monitorsForwardedServices) {
        if (!monitorsForwardedServices) return@LaunchedEffect
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            controller.monitorForwardedServices()
        }
    }
    DisposableEffect(controller, lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START, Lifecycle.Event.ON_RESUME -> {
                    appForeground = true
                    controller.setAppForeground(true)
                    if (event == Lifecycle.Event.ON_RESUME && selectedPathPresentationActive) {
                        selectedPathPresentationActive = false
                        quickOpenExcursion(false)
                    }
                }
                Lifecycle.Event.ON_STOP -> {
                    appForeground = false
                    controller.setAppForeground(false)
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        controller.setAppForeground(lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            if (selectedPathPresentationActive) {
                selectedPathPresentationActive = false
                quickOpenExcursion(false)
            }
        }
    }
    LaunchedEffect(pairingAttemptId, isPresented) {
        if (pairingAttemptId != null && isPresented && !pairingAutoConnectConsumed) {
            pairingAutoConnectConsumed = true
            diagnostics.record(
                "pairing_session_connect_start",
                mapOf("transport" to host.transportKind, "tmux" to (pairingTmuxTarget != null).toString()),
            )
            controller.connect()
        }
    }
}

/** Reports what is displayed to the session store, and connects once per restore or Hosts-row request. */
@Composable
@NonRestartableComposable
private fun SessionConnectEffects(
    host: SavedHost,
    liveSessionId: String,
    controller: SshSessionController,
    sessions: LiveSessionStore,
    lifecycleOwner: LifecycleOwner,
    state: SshSessionUiState,
    isPresented: Boolean,
    diagnostics: DiagnosticLogStore,
    reconnectOnMount: Boolean,
    connectOnOpenRequest: Long,
    restoreReconnectRequest: Long,
) {
    var reconnectOnMountConsumed by remember(liveSessionId) { mutableStateOf(false) }
    var consumedConnectOnOpenRequest by remember(liveSessionId) { mutableLongStateOf(0L) }
    var consumedRestoreReconnectRequest by remember(liveSessionId) { mutableLongStateOf(0L) }
    // §6.9 show edges. Displayed = presented (which already folds in the app
    // lock) ∧ the activity is at least STARTED. The pairing continuation no
    // longer claims here: MainActivity routes it as an explicit open, which
    // the same rule decides from a fresh authority read.
    val lifecycleState by lifecycleOwner.lifecycle.currentStateAsState()
    val displayed = isPresented && lifecycleState.isAtLeast(Lifecycle.State.STARTED)
    val startEpoch by sessions.startEpoch
    val explicitOpens = sessions.explicitOpenRequests[host.id] ?: 0L
    LaunchedEffect(controller, displayed, startEpoch, explicitOpens) {
        sessions.reportComposedDisplay(host.id, displayed, startEpoch, explicitOpens)
    }
    LaunchedEffect(reconnectOnMount) {
        if (reconnectOnMount && !reconnectOnMountConsumed) {
            reconnectOnMountConsumed = true
            diagnostics.record("restore_reconnect_start", mapOf("transport" to host.transportKind))
            controller.connect()
        }
    }
    LaunchedEffect(restoreReconnectRequest) {
        if (restoreReconnectRequest > consumedRestoreReconnectRequest) {
            consumedRestoreReconnectRequest = restoreReconnectRequest
            diagnostics.record("restore_window_reconnect", mapOf("transport" to host.transportKind))
            controller.reconnectForRestore()
        }
    }
    LaunchedEffect(connectOnOpenRequest, isPresented) {
        if (!hasPendingPresentedHostOpen(connectOnOpenRequest, consumedConnectOnOpenRequest, isPresented)) {
            return@LaunchedEffect
        }
        consumedConnectOnOpenRequest = connectOnOpenRequest
        if (shouldConnectFromHostOpen(state)) {
            diagnostics.record("host_open_connect_start", mapOf("transport" to host.transportKind))
            controller.connect()
        }
    }
}

/**
 * Keeps the terminal surfaces in step with the screen: grid presentation,
 * focus, font, theme, cursor, background, scrolling and the armed modifiers.
 */
@Composable
@NonRestartableComposable
private fun TerminalSurfaceEffects(
    controller: SshSessionController,
    terminal: TermuxTerminalSurface,
    inputTerminal: TermuxTerminalSurface,
    paneSurfaces: Map<Int, TermuxTerminalSurface>,
    hostState: SessionHostState,
    state: SshSessionUiState,
    isPresented: Boolean,
    compactTmux: Boolean,
    tmuxSnapshot: SharedTmuxSnapshot?,
    usesTmuxPaneGrid: Boolean,
    terminalTextSizeSp: Int,
    terminalTypeface: Typeface,
    terminalTheme: TerminalTheme,
    cursorStyle: TerminalCursorStyle,
    terminalCursorBlink: Boolean,
    terminalBackground: TerminalBackgroundImage?,
    terminalBackgroundStore: TerminalBackgroundImageStore,
    smoothScrollingEnabled: Boolean,
    smoothScrollingSpeed: Float,
    armingBehavior: SharedModifierBehavior,
) {
    var filesOpen by hostState.filesOpen
    var forwardingOpen by hostState.forwardingOpen
    val armedModifiers by hostState.armedModifiers
    val appForeground by hostState.appForeground
    var locallyFocusedTmuxPaneId by hostState.locallyFocusedTmuxPaneId
    LaunchedEffect(compactTmux) {
        controller.setTmuxGridPresentation(
            if (compactTmux) SharedTmuxGridPresentation.SINGLE_PANE
            else SharedTmuxGridPresentation.PANE_GRID,
        )
    }
    LaunchedEffect(tmuxSnapshot?.activePaneId) {
        locallyFocusedTmuxPaneId = tmuxSnapshot?.activePaneId
    }
    val attachedPaneIds = paneSurfaces.keys.toSet()
    LaunchedEffect(
        isPresented,
        appForeground,
        state,
        usesTmuxPaneGrid,
        locallyFocusedTmuxPaneId,
        attachedPaneIds,
    ) {
        val panesVisible = isPresented && appForeground && state == SshSessionUiState.Connected && usesTmuxPaneGrid
        terminal.setFocused(isPresented && appForeground && state == SshSessionUiState.Connected && !usesTmuxPaneGrid)
        paneSurfaces.forEach { (paneId, surface) ->
            surface.setFocused(panesVisible && paneId == locallyFocusedTmuxPaneId)
        }
    }
    LaunchedEffect(terminalTextSizeSp, terminalTypeface) {
        terminal.setFont(TerminalFont(terminalTextSizeSp.coerceIn(8, 40), terminalTypeface))
    }
    LaunchedEffect(terminalTheme) {
        terminal.setTheme(terminalTheme)
    }
    LaunchedEffect(cursorStyle, terminalCursorBlink) {
        terminal.setCursorAppearance(cursorStyle, terminalCursorBlink)
    }
    LaunchedEffect(terminalBackground, attachedPaneIds) {
        terminalBackground?.let { background ->
            withContext(Dispatchers.IO) { terminalBackgroundStore.prewarm(listOf(background)) }
        }
        terminal.setBackgroundImage(terminalBackground)
        paneSurfaces.values.forEach { it.setBackgroundImage(terminalBackground) }
    }
    LaunchedEffect(smoothScrollingEnabled, smoothScrollingSpeed, attachedPaneIds) {
        val speed = smoothScrollingSpeed.coerceIn(0.15f, 1.25f)
        terminal.view.setSmoothScrollingSpeed(speed)
        terminal.view.setSmoothScrollingEnabled(smoothScrollingEnabled)
        paneSurfaces.values.forEach { surface ->
            surface.view.setSmoothScrollingSpeed(speed)
            surface.view.setSmoothScrollingEnabled(smoothScrollingEnabled)
        }
    }
    LaunchedEffect(armedModifiers, armingBehavior, inputTerminal, attachedPaneIds) {
        // Only the surface taking input may hold an armed set. A pane that
        // loses focus mid-chord would otherwise still be holding it when focus
        // came back, and spend it on a key the user typed much later.
        (paneSurfaces.values.toList() + terminal).distinct().forEach { surface ->
            surface.setSoftwareModifiers(
                if (surface === inputTerminal) armedModifiers else SharedArmedModifiers(),
                armingBehavior,
            )
        }
    }

    LaunchedEffect(state, isPresented) {
        if (state == SshSessionUiState.Connected && isPresented) {
            inputTerminal.requestSoftwareKeyboard()
        }
    }
    LaunchedEffect(state) {
        if (state == SshSessionUiState.Disconnected || state == SshSessionUiState.Terminated ||
            state is SshSessionUiState.Failed
        ) {
            filesOpen = false
            forwardingOpen = false
        }
    }
}

/** Publishes this session's cwd and keeps Files following it. */
@Composable
@NonRestartableComposable
private fun TerminalDirectoryEffects(
    host: SavedHost,
    controller: SshSessionController,
    filesController: RemoteFilesController,
    hostState: SessionHostState,
    state: SshSessionUiState,
    isPresented: Boolean,
    terminalDirectory: String?,
    onTerminalDirectoryChanged: (String?) -> Unit,
) {
    val filesOpen by hostState.filesOpen
    var plainTerminalDirectory by hostState.plainTerminalDirectory
    // Publish this session's cwd so the share ingress sheet can offer "session
    // cwd" as a destination for a host that is already connected.
    LaunchedEffect(terminalDirectory, state) {
        onTerminalDirectoryChanged(terminalDirectory.takeIf { state == SshSessionUiState.Connected })
    }
    DisposableEffect(Unit) { onDispose { onTerminalDirectoryChanged(null) } }

    // A reconnect starts a new remote shell. Dropping the last OSC 7 report
    // keeps a value from the previous shell out of the follow standdown below,
    // where it would suppress the probe against a shell that never reports.
    LaunchedEffect(state) {
        if (state != SshSessionUiState.Connected) plainTerminalDirectory = null
    }

    // Files follows the terminal. Pushed signals — tmux pane metadata and the
    // terminal's own OSC 7 — land the moment they change; reports stop while
    // the browser is closed so a cwd change can never dial SFTP on its own.
    LaunchedEffect(filesOpen, terminalDirectory, state) {
        if (!filesOpen || state != SshSessionUiState.Connected) return@LaunchedEffect
        filesController.terminalReportedDirectory(terminalDirectory)
    }

    // Zero-setup follow for the transports that report no cwd in band: plain
    // mosh, where a stock mosh-server drops OSC 7 before it enters the state
    // sync, and plain SSH before shell integration is installed. Under tmux the
    // pane-metadata subscription already carries every cd, so the poll stays
    // out of those sessions entirely; it also rides the file channel the
    // browser itself opened, so it never authenticates a route of its own.
    val cwdFollowKey = RemoteCwdProbe.followTaskKey(
        panelOpen = filesOpen,
        sessionActive = isPresented && state == SshSessionUiState.Connected,
        tmuxAttached = host.tmuxMode != TmuxModes.OFF,
        moshServerPid = controller.cwdProbeMoshServerPid(),
    )
    LaunchedEffect(cwdFollowKey) {
        if (!filesOpen || !isPresented) return@LaunchedEffect
        if (host.tmuxMode != TmuxModes.OFF || state != SshSessionUiState.Connected) return@LaunchedEffect
        val command = controller.liveFileCwdProbeCommand()
        val debounce = RemoteCwdProbe.FollowDebounce()
        while (true) {
            val tick = if (plainTerminalDirectory != null) {
                // OSC 7 is instant and per-shell exact, so the probe stands
                // down while the shell reports it — this host runs shell
                // integration, or our mosh fork.
                RemoteCwdProbe.Tick.OscSignalLive
            } else {
                filesController.probeOnLiveChannel(command)
                    ?.let(RemoteCwdProbe.Tick::Probed)
                    ?: RemoteCwdProbe.Tick.NotPolled
            }
            when (val outcome = debounce.step(tick)) {
                is RemoteCwdProbe.Outcome.Report -> filesController.terminalReportedDirectory(outcome.path)
                RemoteCwdProbe.Outcome.ClearFollow -> filesController.terminalReportedDirectory(null)
                RemoteCwdProbe.Outcome.Hold -> Unit
            }
            delay(RemoteCwdProbe.POLL_INTERVAL_MILLIS)
        }
    }
}

/** Runs a share the ingress sheet routed to this session, once it is connected. */
@Composable
@NonRestartableComposable
private fun ShareUploadEffect(
    shareUpload: PendingShareUpload?,
    onShareUploadConsumed: () -> Unit,
    controller: SshSessionController,
    state: SshSessionUiState,
    tmuxAuthorityPresentation: TmuxAuthorityPresentation,
    inputTerminal: TermuxTerminalSurface,
    hostState: SessionHostState,
    resources: Resources,
    systemClipboard: ClipboardManager?,
    runShareUpload: (Uri, PendingShareUpload, Boolean) -> Unit,
) {
    var filesOpen by hostState.filesOpen
    var terminalToast by hostState.terminalToast
    // A share the ingress sheet routed here. It runs exactly once, when the
    // session is connected: the sheet's decision was made against this host,
    // and re-running it on a later reconnect would upload the same payload
    // twice.
    LaunchedEffect(shareUpload?.hostId, shareUpload?.uris, shareUpload?.text, state, tmuxAuthorityPresentation) {
        val pending = shareUpload ?: return@LaunchedEffect
        // A routed share is a one-shot instruction aimed at one session. If
        // that session gives up or is torn down, drop it — replaying an
        // hours-old payload on some later reconnect is the worse surprise.
        if (state is SshSessionUiState.Failed || state == SshSessionUiState.Terminated) {
            onShareUploadConsumed()
            terminalToast = resources.getString(R.string.session_share_cancelled)
            return@LaunchedEffect
        }
        if (state != SshSessionUiState.Connected) return@LaunchedEffect
        // A show or take-back is deciding who owns the grid; it resolves in
        // moments, so the share waits for it rather than racing it.
        if (pending.isTextPaste && (
                tmuxAuthorityPresentation is TmuxAuthorityPresentation.Resuming ||
                    tmuxAuthorityPresentation is TmuxAuthorityPresentation.Reclaiming
                )
        ) {
            return@LaunchedEffect
        }
        onShareUploadConsumed()
        if (pending.isTextPaste) {
            val text = requireNotNull(pending.text)
            if (!controller.acceptsTerminalInput()) {
                // Another device is working in this grid: keep the text, but
                // never type it under them.
                systemClipboard?.setPrimaryClip(
                    ClipData.newPlainText(resources.getString(R.string.session_clip_label_shared_text), text),
                )
                terminalToast = resources.getString(R.string.session_share_copied_take_back)
                return@LaunchedEffect
            }
            inputTerminal.sendInput(text.encodeToByteArray())
            inputTerminal.setFocused(true)
            return@LaunchedEffect
        }
        // Watching a file land in the directory you chose is the point of the
        // cwd destination; a temp upload exists only to be pasted, so it must
        // not shove the terminal aside.
        if (pending.destination is ShareUploadDestination.SessionCwd) filesOpen = true
        pending.uris.forEach { uri -> runShareUpload(uri, pending, false) }
    }
}

/**
 * Times the toast out and raises the ones window ordering owes, closes the
 * integration prompts once they no longer apply, and asks the device owner to
 * unlock a key the session is waiting on.
 */
@Composable
@NonRestartableComposable
private fun SessionNoticeEffects(
    controller: SshSessionController,
    state: SshSessionUiState,
    isPresented: Boolean,
    tmuxWindowMutationState: TmuxWindowMutationState,
    integrationWarningVisible: Boolean,
    hostState: SessionHostState,
    integrationPrompts: SessionIntegrationPrompts,
    context: Context,
    resources: Resources,
) {
    var terminalToast by hostState.terminalToast
    var integrationWarningOpen by integrationPrompts.integrationWarningOpen
    var integrationHelpOpen by integrationPrompts.integrationHelpOpen
    var pendingIntegrationAction by integrationPrompts.pendingIntegrationAction
    LaunchedEffect(terminalToast) {
        if (terminalToast != null) {
            delay(4_000)
            terminalToast = null
        }
    }
    LaunchedEffect(tmuxWindowMutationState) {
        (tmuxWindowMutationState as? TmuxWindowMutationState.Error)?.message?.let {
            terminalToast = resources.getString(when (it) {
                "The window order changed. Try again.", "That window move is no longer valid." -> R.string.tmux_order_changed
                "Window ordering timed out." -> R.string.tmux_order_timeout
                "Window ordering is not available yet.", "Window ordering is not hydrated yet." -> R.string.tmux_order_unavailable
                else -> R.string.tmux_order_failed
            })
            controller.clearTmuxWindowMutationError()
        }
    }
    LaunchedEffect(integrationWarningVisible) {
        if (!integrationWarningVisible) integrationWarningOpen = false
    }
    LaunchedEffect(isPresented) {
        if (!isPresented) {
            integrationWarningOpen = false
            integrationHelpOpen = false
            pendingIntegrationAction = null
        }
    }
    LaunchedEffect(
        (state as? SshSessionUiState.AwaitingOwnerAuthorization)?.challenge?.challengeId,
        isPresented,
    ) {
        if (!isPresented) return@LaunchedEffect
        val awaiting = state as? SshSessionUiState.AwaitingOwnerAuthorization ?: return@LaunchedEffect
        controller.decideOwnerAuthorization(
            confirmDeviceOwner(
                context,
                resources.getString(R.string.session_unlock_key_title),
                awaiting.challenge.reason.resolve(resources),
            ),
        )
    }
}

/** Publishes this session's program status, and reports the agent terminal on screen. */
@Composable
@NonRestartableComposable
private fun ProgramStatusEffects(
    host: SavedHost,
    liveSessionId: String,
    controller: SshSessionController,
    programStatusCenter: ProgramStatusCenter?,
    programStatusEnabled: Boolean,
    programStatus: SharedProgramStatusSnapshot,
    tmuxSnapshot: SharedTmuxSnapshot?,
    presentedPrograms: Set<SharedProgramStatusTerminal>,
    state: SshSessionUiState,
    isPresented: Boolean,
    hostState: SessionHostState,
    onAgentTerminalVisible: (String, String?) -> Unit,
) {
    val appForeground by hostState.appForeground
    val locallyFocusedTmuxPaneId by hostState.locallyFocusedTmuxPaneId
    LaunchedEffect(programStatusCenter, controller, host.id, host.displayName,
        programStatusEnabled, programStatus, tmuxSnapshot, presentedPrograms) {
        val center = programStatusCenter ?: return@LaunchedEffect
        // Update visibility before publishing: a newly hidden pane must not be checked by the new snapshot.
        center.setPresented(host.id, presentedPrograms)
        center.publish(host.id, ProgramStatusSessionState(
            hostLabel = host.displayName,
            snapshot = if (programStatusEnabled) programStatus else SharedProgramStatusSnapshot.EMPTY,
            locations = tmuxSnapshot?.let(::programStatusPaneLocations).orEmpty(),
        ), acknowledge = controller::acknowledgeProgramStatus)
    }

    // Agent Center's own read rule (the focused pane, as on iOS) is unchanged by program status.
    LaunchedEffect(isPresented, appForeground, state, locallyFocusedTmuxPaneId, tmuxSnapshot?.activePaneId) {
        while (isPresented && appForeground && state == SshSessionUiState.Connected) {
            onAgentTerminalVisible(liveSessionId, (locallyFocusedTmuxPaneId ?: tmuxSnapshot?.activePaneId)?.let { "%$it" })
            kotlinx.coroutines.delay(1_000)
        }
    }
}

/** Takes the screen to the window and pane a program-status request names, once per request. */
@Composable
@NonRestartableComposable
private fun ProgramStatusFocusEffect(
    liveSessionId: String,
    controller: SshSessionController,
    programStatusFocusRequest: ProgramStatusFocusRequest?,
    state: SshSessionUiState,
    isPresented: Boolean,
    exactAgentBinding: AgentEndpointBinding?,
    tmuxSnapshot: SharedTmuxSnapshot?,
    programStatusNavigation: LongState,
    presented: State<Boolean>,
    hostState: SessionHostState,
    closeFind: () -> Unit,
) {
    var filesOpen by hostState.filesOpen
    var forwardingOpen by hostState.forwardingOpen
    var tmuxSwitcherOpen by hostState.tmuxSwitcherOpen
    val findOpen by hostState.findOpen
    val pendingMoshFindSurfaceId by hostState.pendingMoshFindSurfaceId
    val pendingMoshLiveFindAfterDeliveryToken by hostState.pendingMoshLiveFindAfterDeliveryToken
    val currentPresented by presented
    val programStatusNavigationEpoch by programStatusNavigation
    val currentProgramStatusFocusRequest by rememberUpdatedState(programStatusFocusRequest)
    var consumedProgramStatusFocusToken by remember(liveSessionId) { mutableStateOf<Long?>(null) }
    LaunchedEffect(controller, isPresented, state, exactAgentBinding?.key,
        tmuxSnapshot?.sessionName, programStatusNavigationEpoch, programStatusFocusRequest?.token) {
        val request = programStatusFocusRequest ?: return@LaunchedEffect
        if (!isPresented || consumedProgramStatusFocusToken == request.token) return@LaunchedEffect
        consumedProgramStatusFocusToken = request.token
        filesOpen = false
        forwardingOpen = false
        tmuxSwitcherOpen = false
        if (findOpen || pendingMoshFindSurfaceId != null || pendingMoshLiveFindAfterDeliveryToken != null) closeFind()
        val windowId = request.windowId ?: return@LaunchedEffect
        val snapshot = controller.tmuxSnapshot.value ?: return@LaunchedEffect
        val window = snapshot.windows.firstOrNull { it.id == windowId } ?: return@LaunchedEffect
        if (request.paneId != null && window.panes.none { it.id == request.paneId }) return@LaunchedEffect
        val carrier = controller.agentEndpointBinding.value?.key ?: return@LaunchedEffect
        val navigationEpoch = programStatusNavigationEpoch
        val sessionName = snapshot.sessionName
        fun current(selected: SharedTmuxSnapshot?): Boolean =
            currentPresented && currentProgramStatusFocusRequest?.token == request.token &&
                programStatusNavigationEpoch == navigationEpoch &&
                controller.state.value == SshSessionUiState.Connected &&
                controller.agentEndpointBinding.value?.key == carrier &&
                controller.transportReachable.value != false && selected != null && selected.sessionName == sessionName &&
                when (selected.activeWindowId) {
                    snapshot.activeWindowId -> selected.activePaneId == snapshot.activePaneId
                    windowId -> true
                    else -> false
                }
        if (!current(snapshot)) return@LaunchedEffect
        if (snapshot.activeWindowId != windowId) controller.selectTmuxWindow(windowId)
        val selected = awaitProgramStatusWindow(
            combine(controller.tmuxSnapshot, controller.state, controller.agentEndpointBinding,
                controller.transportReachable) { next, sessionState, binding, reachable ->
                next.takeIf { sessionState == SshSessionUiState.Connected && binding?.key == carrier && reachable != false }
            }, windowId, ::current,
        ) ?: return@LaunchedEffect
        request.paneId?.takeIf { pane -> selected.activeWindow?.panes?.any { it.id == pane } == true }?.let {
            if (current(controller.tmuxSnapshot.value)) controller.selectTmuxPane(it)
        }
    }
}

/**
 * The session's dialogs, each while it applies: the integration warning, a
 * stopped or colliding share upload, an integration action to confirm, the
 * integration help and a password challenge.
 */
@Composable
@NonRestartableComposable
private fun SessionDialogs(
    controller: SshSessionController,
    filesController: RemoteFilesController,
    agentIntegration: AgentSessionIntegrationCoordinator,
    state: SshSessionUiState,
    isPresented: Boolean,
    integrationStatus: AgentSessionIntegrationStatus?,
    integrationWarningVisible: Boolean,
    exactAgentBinding: AgentEndpointBinding?,
    hostState: SessionHostState,
    integrationPrompts: SessionIntegrationPrompts,
    runShareUpload: (Uri, PendingShareUpload, Boolean) -> Unit,
) {
    var integrationWarningOpen by integrationPrompts.integrationWarningOpen
    var integrationHelpOpen by integrationPrompts.integrationHelpOpen
    var pendingIntegrationAction by integrationPrompts.pendingIntegrationAction
    var shareConflict by hostState.shareConflict
    var shareCancelPrompt by hostState.shareCancelPrompt
    var pastePathInFlight by hostState.pastePathInFlight
    if (isPresented && integrationWarningOpen) {
        val presentation = integrationStatus?.takeIf { integrationWarningVisible }?.presentation()
        if (presentation != null) {
            TesseraDialog(
                title = presentation.title,
                onDismissRequest = { integrationWarningOpen = false },
                actions = {
                    TesseraButton(stringResource(R.string.session_help), onClick = { integrationHelpOpen = true }, compact = true)
                    TesseraButton(
                        stringResource(R.string.session_close),
                        onClick = { integrationWarningOpen = false },
                        compact = true,
                        style = TesseraButtonStyle.Primary,
                    )
                },
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(presentation.message, color = LocalTesseraTokens.current.fgMuted, style = TesseraType.body)
                    presentation.action?.let { action ->
                        TesseraButton(
                            presentation.actionLabel.orEmpty(),
                            onClick = {
                                integrationWarningOpen = false
                                exactAgentBinding?.let { binding ->
                                    pendingIntegrationAction = AgentSessionIntegrationActionRequest(binding, action)
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                            style = TesseraButtonStyle.Primary,
                        )
                    }
                    presentation.secondaryAction?.let { action ->
                        TesseraButton(
                            presentation.secondaryActionLabel.orEmpty(),
                            onClick = {
                                integrationWarningOpen = false
                                exactAgentBinding?.let { binding ->
                                    pendingIntegrationAction = AgentSessionIntegrationActionRequest(binding, action)
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        }
    }

    shareCancelPrompt?.let { item ->
        TesseraConfirmDialog(
            title = stringResource(R.string.session_stop_upload_title),
            body = stringResource(R.string.session_stop_upload_body, item.displayName),
            confirmLabel = stringResource(R.string.session_stop_upload),
            cancelLabel = stringResource(R.string.session_keep_uploading),
            destructive = true,
            onConfirm = {
                filesController.cancel(item.id)
                pastePathInFlight = false
                shareCancelPrompt = null
            },
            onDismiss = { shareCancelPrompt = null },
        )
    }

    shareConflict?.let { conflict ->
        val name = conflict.failure.name
        if (conflict.failure.kind == RemoteFileKind.FILE) {
            TesseraConfirmDialog(
                title = stringResource(R.string.session_replace_title, name),
                body = stringResource(R.string.session_replace_body),
                confirmLabel = stringResource(R.string.session_replace),
                cancelLabel = stringResource(R.string.session_skip),
                destructive = true,
                onConfirm = {
                    shareConflict = null
                    runShareUpload(conflict.uri, conflict.pending, true)
                },
                onDismiss = { shareConflict = null },
            )
        } else {
            TesseraConfirmDialog(
                title = stringResource(R.string.session_cannot_replace_title, name),
                body = stringResource(R.string.session_cannot_replace_body),
                confirmLabel = stringResource(R.string.session_ok),
                cancelLabel = stringResource(R.string.session_ok),
                onConfirm = { shareConflict = null },
                onDismiss = { shareConflict = null },
            )
        }
    }

    if (isPresented) pendingIntegrationAction?.let { request ->
        val action = request.action
        TesseraConfirmDialog(
            title = action.confirmationTitle(),
            body = action.confirmationMessage(),
            confirmLabel = action.confirmationLabel(),
            cancelLabel = stringResource(R.string.session_cancel),
            onConfirm = {
                agentIntegration.requestAction(request)
                pendingIntegrationAction = null
            },
            onDismiss = { pendingIntegrationAction = null },
        )
    }

    if (isPresented && integrationHelpOpen) {
        TesseraDialog(
            title = stringResource(R.string.session_integration_help_title),
            onDismissRequest = { integrationHelpOpen = false },
            actions = {
                TesseraButton(
                    stringResource(R.string.session_done),
                    onClick = { integrationHelpOpen = false },
                    compact = true,
                    style = TesseraButtonStyle.Primary,
                )
            },
        ) {
            Text(
                stringResource(R.string.session_integration_help_body),
                color = LocalTesseraTokens.current.fgMuted,
                style = TesseraType.body,
            )
        }
    }

    if (isPresented) (state as? SshSessionUiState.AwaitingCredential)?.let { awaiting ->
        PasswordDialog(
            username = awaiting.challenge.username,
            host = awaiting.challenge.host,
            onConnect = controller::submitPassword,
            onCancel = controller::cancelChallenge,
        )
    }
}

/** The tmux switcher sheet, carrying the integration notice while one holds. */
@Composable
@NonRestartableComposable
private fun SessionTmuxSwitcher(
    host: SavedHost,
    controller: SshSessionController,
    tmuxSnapshot: SharedTmuxSnapshot?,
    tmuxAuthority: SharedTmuxGridAuthoritySnapshot,
    tmuxAuthorityPresentation: TmuxAuthorityPresentation,
    tmuxWindowMutationState: TmuxWindowMutationState,
    exactAgentBinding: AgentEndpointBinding?,
    paneAgentProviders: Map<AgentSessionKey, Map<Int, String>>,
    integrationStatus: AgentSessionIntegrationStatus?,
    integrationWarningVisible: Boolean,
    switcherSessions: List<SessionSwitcherSession>,
    programStatusCenter: ProgramStatusCenter?,
    programStatusAgents: ProgramStatusAgentInput,
    programStatusNavigation: MutableLongState,
    bellPreferences: BellPreferences,
    bellUnread: BellUnreadState,
    hostState: SessionHostState,
    integrationPrompts: SessionIntegrationPrompts,
    onSelectSession: (String) -> Unit,
    onBack: () -> Unit,
) {
    var tmuxSwitcherOpen by hostState.tmuxSwitcherOpen
    var locallyFocusedTmuxPaneId by hostState.locallyFocusedTmuxPaneId
    val glowingTmuxWindowId by hostState.glowingTmuxWindowId
    var integrationWarningOpen by integrationPrompts.integrationWarningOpen
    var pendingIntegrationAction by integrationPrompts.pendingIntegrationAction
    var programStatusNavigationEpoch by programStatusNavigation
    val switcherNotice = integrationStatus?.takeIf { integrationWarningVisible }?.presentation()
    SessionSwitcherSheet(
        windows = tmuxSnapshot?.switcherWindows { paneId ->
            exactAgentBinding?.key?.let(paneAgentProviders::get)?.get(paneId)
        }.orEmpty(),
        activeWindowId = tmuxSnapshot?.activeWindowId,
        activePaneId = locallyFocusedTmuxPaneId ?: tmuxSnapshot?.activePaneId,
        // The screen knows its own tmux window label; the other sessions are
        // mounted but unobserved from here, so they carry only their endpoint.
        sessions = switcherSessions.map { session ->
            if (session.hostId == host.id) {
                session.copy(paneTitle = tmuxSnapshot?.activeWindow?.namedLabel)
            } else {
                session
            }
        },
        currentSessionTitle = host.displayName,
        programStatusCenter = programStatusCenter,
        programHostId = host.id,
        programStatusAgents = programStatusAgents,
        unreadWindowIds = if (bellPreferences.visualEnabled) {
            bellUnread.tmuxWindowIdsBySession[host.id].orEmpty()
        } else emptySet(),
        glowingWindowId = glowingTmuxWindowId.takeIf { bellPreferences.visualEnabled },
        // A peer device holding the grid may not be issued window or pane
        // commands, nor may this one while a show or take-back is still
        // resolving; nothing is mutable before the snapshot hydrates.
        allowsTmuxMutation = tmuxSnapshot != null &&
            tmuxAuthority !is SharedTmuxGridAuthoritySnapshot.Peer &&
            !tmuxAuthorityPresentation.gatesInput &&
            tmuxWindowMutationState == TmuxWindowMutationState.Available,
        tmuxMutationContextValid = tmuxSnapshot != null &&
            tmuxAuthority !is SharedTmuxGridAuthoritySnapshot.Peer &&
            !tmuxAuthorityPresentation.gatesInput &&
            (tmuxWindowMutationState == TmuxWindowMutationState.Available ||
                tmuxWindowMutationState == TmuxWindowMutationState.Pending),
        reorderContextKey = tmuxSnapshot?.sessionName to tmuxAuthority,
        notice = switcherNotice?.let {
            SessionSwitcherNotice(
                title = it.title,
                message = it.message,
                actionLabel = it.actionLabel,
            )
        },
        onNoticeAction = {
            tmuxSwitcherOpen = false
            val action = switcherNotice?.action
            val binding = exactAgentBinding
            if (action != null && binding != null) {
                pendingIntegrationAction = AgentSessionIntegrationActionRequest(binding, action)
            } else {
                integrationWarningOpen = true
            }
        },
        onNoticeDetails = {
            tmuxSwitcherOpen = false
            integrationWarningOpen = true
        },
        onHome = { tmuxSwitcherOpen = false; onBack() },
        onSelectSession = { hostId ->
            tmuxSwitcherOpen = false
            if (hostId != host.id) onSelectSession(hostId)
        },
        onSelectWindow = { programStatusNavigationEpoch += 1; controller.selectTmuxWindow(it); tmuxSwitcherOpen = false },
        onSelectPane = {
            programStatusNavigationEpoch += 1
            locallyFocusedTmuxPaneId = it
            controller.selectTmuxPane(it)
            tmuxSwitcherOpen = false
        },
        onNewWindow = { programStatusNavigationEpoch += 1; controller.createTmuxWindow() },
        onRenameWindow = controller::renameTmuxWindow,
        onCloseWindow = controller::closeTmuxWindow,
        onMoveWindow = controller::moveTmuxWindow,
        onRenumberWindows = controller::renumberTmuxWindows,
        onSplitWindow = controller::splitTmuxWindow,
        onSplitPane = controller::splitTmuxPane,
        onSetPaneZoomed = controller::setTmuxZoomed,
        onClosePane = controller::closeTmuxPane,
        onDismiss = { tmuxSwitcherOpen = false },
    )
}

/** A share upload paused on a name collision, awaiting the user's answer. */
private data class PendingShareConflict(
    val uri: Uri,
    val pending: PendingShareUpload,
    val failure: ShareUploadFailure.Conflict,
)

/**
 * The window insets the session Scaffold applies to its body.
 *
 * Only the horizontal ones: the top is the chrome's own business (it pads for
 * the status bar itself) and the bottom belongs to whatever the session puts
 * last — the accessory bar, or a panel standing in for it. An inset here would
 * be spent twice, because the keyboard lift below already measures the IME from
 * the true window bottom, and the accessory bar already clears the gesture pill
 * on its own. That double count is what put a two-pill-high black gap between
 * the bar and the keyboard.
 */
@Composable
internal fun sessionContentWindowInsets(): WindowInsets =
    WindowInsets.systemBars.only(WindowInsetsSides.Horizontal)

/**
 * The navigation-bar strip a bottom-most session surface still owes.
 *
 * The gesture pill needs clearing only while nothing else covers it. A visible
 * IME occupies that strip and the session content is lifted onto the keyboard's
 * top edge, so padding for the navigation bar there would hold the surface a
 * pill's height off the keyboard.
 */
@Composable
internal fun Modifier.sessionBottomInsetPadding(): Modifier {
    val density = LocalDensity.current
    val remaining = sessionBottomInsetPixels(density)
    return padding(bottom = with(density) { remaining.toDp() })
}

@Composable
private fun sessionBottomInsetPixels(density: Density): Int {
    val navigationBars = WindowInsets.navigationBars.getBottom(density)
    val ime = WindowInsets.ime.getBottom(density)
    return (navigationBars - ime).coerceAtLeast(0)
}

@Composable
internal fun Modifier.terminalKeyboardBehaviorModifier(resizeTerminalWithKeyboard: Boolean): Modifier {
    val density = LocalDensity.current
    val imeBottom = WindowInsets.ime.getBottom(density)
    return if (resizeTerminalWithKeyboard) {
        imePadding()
    } else {
        offset { IntOffset(0, -imeBottom) }
    }
}

internal data class TerminalKeyboardViewportLayout(
    val sessionModifier: Modifier,
    val terminalCounterShiftModifier: Modifier,
    val chromeCounterShiftModifier: Modifier,
    val imeOverlapPixels: Int,
    val terminalCounterShiftPixels: Int,
)

/**
 * Keeps the terminal grid stable while the IME is shown, without losing a primary-screen cursor.
 *
 * The session and accessory keep the full IME lift. Only the terminal canvas receives the
 * caret-aware counter-shift, and its parent clips that canvas to the original terminal slot.
 * Surfaces whose swipes leave the device (the shared scroll route's alternate-screen verdict:
 * the alternate screen itself, or mouse reporting standing in for it where no local scrollback
 * exists) and obstructing panels return no clearance and therefore retain the full historical
 * lift. In a wide tmux grid, only the synchronously focused pane is
 * sampled and counter-shifted; the other panes keep their authoritative geometry and position.
 */
@Composable
internal fun rememberTerminalKeyboardViewportLayout(
    resizeTerminalWithKeyboard: Boolean,
    terminal: TermuxTerminalSurface,
    caretFollowingEnabled: Boolean,
): TerminalKeyboardViewportLayout {
    val density = LocalDensity.current
    val imeBottom = WindowInsets.ime.getBottom(density)
    val imeVisible = imeBottom > 0
    val currentOverlap by rememberUpdatedState(imeBottom.toFloat())
    var caretHold by remember(terminal) { mutableStateOf<Float?>(null) }

    LaunchedEffect(resizeTerminalWithKeyboard, caretFollowingEnabled, imeVisible, terminal) {
        if (resizeTerminalWithKeyboard || !caretFollowingEnabled || !imeVisible) {
            caretHold = null
            return@LaunchedEffect
        }
        var firstSample = true
        while (isActive) {
            val clearance = terminal.caretClearance()
            caretHold = if (clearance == null) {
                0f
            } else {
                TerminalKeyboardViewportPolicy.holdPixels(
                    previousHoldPixels = if (firstSample) null else caretHold,
                    clearance = clearance,
                    imeOverlapPixels = currentOverlap,
                )
            }
            firstSample = false
            delay(150)
        }
    }

    val immediateHold = if (!resizeTerminalWithKeyboard && caretFollowingEnabled && imeVisible) {
        caretHold ?: terminal.caretClearance()?.belowPixels ?: 0f
    } else {
        0f
    }
    val terminalCounterShift = TerminalKeyboardViewportPolicy.counterShiftPixels(
        holdPixels = immediateHold,
        imeOverlapPixels = imeBottom.toFloat(),
    ).roundToInt()

    return TerminalKeyboardViewportLayout(
        sessionModifier = if (resizeTerminalWithKeyboard) {
            Modifier.imePadding()
        } else {
            Modifier.offset { IntOffset(0, -imeBottom) }
        },
        terminalCounterShiftModifier = Modifier.offset {
            IntOffset(0, terminalCounterShift)
        },
        // Chrome held in place overlaps the lifted terminal, which is placed
        // after it and would otherwise draw over it and take its taps (iOS
        // raises `KeyboardLiftExemptChrome` the same way).
        chromeCounterShiftModifier = if (!resizeTerminalWithKeyboard) {
            Modifier.offset { IntOffset(0, imeBottom) }.zIndex(1f)
        } else {
            Modifier
        },
        imeOverlapPixels = imeBottom,
        terminalCounterShiftPixels = terminalCounterShift,
    )
}

/**
 * Sends one accessory-bar tile's bytes to the surface taking input.
 *
 * Keyboard visibility belongs to the ⌨ tile alone: a key tile only re-points
 * input at the terminal, so arrows and Escape stay usable with the software
 * keyboard down and cannot shove it back over the screen. The debug harness
 * calls this same function, so the instrumented visibility guard exercises the
 * shipping behaviour rather than a copy of it.
 */
internal fun sendAccessoryKey(
    surface: TermuxTerminalSurface,
    key: AccessoryBarKey,
    armed: SharedArmedModifiers,
) {
    // Bytes come from the shared catalog keyed by canonical ID, never from the
    // chip's label.
    SharedInputEncoding.encodeAccessoryKey(
        id = key.persistedId,
        modifiers = armed,
        applicationCursorMode = surface.isCursorKeysApplicationMode(),
    )?.let(surface::sendInput)
    surface.focusForInput()
}

@Composable
internal fun TerminalSoftwareAccessory(
    armed: SharedArmedModifiers,
    onModifier: (SharedModifierName) -> Unit,
    onKey: (AccessoryBarKey) -> Unit,
    modifier: Modifier = Modifier,
    keys: List<AccessoryBarKey> = AccessoryBarKey.defaultOrder(),
    notation: SharedInputEncoding.ChordNotation = SharedInputEncoding.ChordNotation.Glyph,
    keyboardVisible: Boolean = false,
    onKeyboard: () -> Unit = {},
) {
    val tokens = LocalTesseraTokens.current
    // Labels are rendered by the shared chord renderer, so a notation
    // preference reaches every chip at once. Display only: the bytes a chip
    // sends come from its catalog ID and cannot follow the label.
    val labels = remember(notation) { AccessoryBarKey.labels(notation) }
    Surface(modifier, color = tokens.panelBg) {
        Column {
            TesseraHairline()
            Row(
                // The band the bar occupies is constant, and only the reserve's
                // side changes: below the chips it clears the gesture pill,
                // above them it absorbs the strip the keyboard now covers. A bar
                // that simply dropped the reserve would grow the terminal by a
                // pill's height on every keyboard toggle, and a grid that
                // resizes whenever the keyboard appears is a worse bargain than
                // a band that stays put (iOS reserves the same way).
                modifier = Modifier
                    .fillMaxWidth()
                    .accessoryBarReservedBand()
                    .padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    modifier = Modifier
                        .weight(1f)
                        .horizontalScroll(rememberScrollState())
                        .padding(start = 8.dp, end = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // The live strip deliberately shares the exact persisted order used by
                    // Settings. It overflows compact width; the fixed keyboard control stays
                    // outside the scroll container so it never scrolls away.
                    keys.forEach { key ->
                        val modifierName = key.armsModifier
                        AccessoryKey(
                            id = key.persistedId,
                            label = labels[key] ?: key.persistedId,
                            selected = when (modifierName) {
                                SharedModifierName.Control -> armed.control
                                SharedModifierName.Alternate -> armed.alternate
                                SharedModifierName.Shift -> armed.shift
                                SharedModifierName.Command -> armed.command
                                null -> false
                            },
                        ) {
                            if (modifierName != null) onModifier(modifierName) else onKey(key)
                        }
                    }
                }
                AccessoryKey(
                    id = "keyboard",
                    label = "⌨",
                    accessibilityLabel = stringResource(
                        if (keyboardVisible) R.string.session_hide_keyboard else R.string.session_show_keyboard,
                    ),
                    onClick = onKeyboard,
                    modifier = Modifier.padding(start = 4.dp, end = 8.dp),
                )
            }
        }
    }
}

/**
 * Reserves a constant navigation-bar band around the accessory row: under the
 * chips while the gesture pill is exposed, over them while the keyboard covers
 * it. The bar's own material fills the reserve either way.
 */
@Composable
private fun Modifier.accessoryBarReservedBand(): Modifier {
    val density = LocalDensity.current
    val reserve = with(density) { WindowInsets.navigationBars.getBottom(density).toDp() }
    val owed = with(density) { sessionBottomInsetPixels(density).toDp() }
    return padding(top = reserve - owed, bottom = owed)
}

/**
 * One accessory key. Sized to the platform touch minimum rather than to its label,
 * so `esc` and `←` present the same target, and given a real surface so the row
 * reads as keys instead of as a line of scrolling text.
 */
@Composable
internal fun AccessoryKey(
    id: String,
    label: String,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    accessibilityLabel: String? = null,
    onClick: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    Box(
        modifier = modifier
            .testTag("accessory-key-$id")
            .semantics {
                accessibilityLabel?.let { contentDescription = it }
            }
            .widthIn(min = 48.dp)
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(7.dp))
            .background(if (selected) tokens.accentSoft else tokens.inputBg)
            .border(
                1.dp,
                if (selected) tokens.accent.copy(alpha = 0.55f) else tokens.border,
                RoundedCornerShape(7.dp),
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = TesseraType.button,
            color = if (selected) tokens.accent else tokens.fg,
            maxLines = 1,
        )
    }
}

@Composable
internal fun SessionChrome(
    host: SavedHost,
    state: SshSessionUiState,
    filesOpen: Boolean,
    forwardingOpen: Boolean = false,
    forwarding: ForwardingChromePresentation = ForwardingChromePresentation.Hidden,
    compact: Boolean = false,
    tmuxEnabled: Boolean = false,
    programStatusCenter: ProgramStatusCenter? = null,
    programStatusAgents: ProgramStatusAgentInput = ProgramStatusAgentInput.NONE,
    onOpenAgentCenter: (() -> Unit)? = null,
    programAttentionInitiallyOpen: Boolean = false,
    integrationStatus: AgentSessionIntegrationStatus? = null,
    /** Already held for Core's presentation delay by the caller. */
    integrationWarningVisible: Boolean = false,
    onBack: () -> Unit,
    onConnect: () -> Unit,
    onPaste: () -> Unit,
    onToggleFiles: () -> Unit,
    onToggleForwarding: () -> Unit = {},
    onOpenSwitcher: () -> Unit = {},
    onNewTmuxWindow: () -> Unit = {},
    onSearch: () -> Unit = {},
    onContinueOnAnotherDevice: () -> Unit = {},
    onCloseSession: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    // The integration warning no longer takes its own top-bar tile: it rings
    // the connection dot (whose colour stays the connection state) and its
    // notice and action live in the switcher this target opens.
    val integrationAttention = integrationWarningVisible &&
        integrationStatus?.showsWarning == true &&
        state == SshSessionUiState.Connected
    val switcherLabel = integrationStatus?.takeIf { integrationAttention }?.presentation()?.let {
        stringResource(R.string.session_switcher_label_with_notice, it.title)
    } ?: stringResource(R.string.session_switcher_label)
    // Green only while something answers behind a tunnel; a listener that is
    // merely up, unconfirmed, or refused keeps the plain glyph colour. The
    // selected highlight is the open panel alone.
    val forwardingGlyphTint = if (forwarding.serving) tokens.green else tokens.fgMuted
    val dot = when (state) {
        SshSessionUiState.Connected -> tokens.green
        SshSessionUiState.Connecting,
        is SshSessionUiState.AwaitingCredential,
        is SshSessionUiState.AwaitingHostKey,
        is SshSessionUiState.AwaitingOwnerAuthorization -> tokens.amber
        is SshSessionUiState.Failed -> tokens.red
        SshSessionUiState.Disconnected, SshSessionUiState.Terminated -> tokens.fgDim
    }
    if (compact) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 10.dp, vertical = 8.dp),
            shape = RoundedCornerShape(22.dp),
            color = tokens.panelBg,
            border = androidx.compose.foundation.BorderStroke(1.dp, tokens.border),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(horizontal = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SessionIconButton(TesseraIcons.ChevronLeft, stringResource(R.string.session_back), onBack)
                // Always live. The switcher carries this client's other host
                // sessions and the way back to the tab bar, not only tmux
                // targets, so a session that is failing or has no tmux at all
                // still has somewhere to go.
                SessionSwitcherTarget(
                    title = host.displayName,
                    dot = dot,
                    attention = integrationAttention,
                    label = switcherLabel,
                    minHeight = 40.dp,
                    horizontalPadding = 3.dp,
                    titlePadding = PaddingValues(start = 7.dp),
                    onClick = onOpenSwitcher,
                )
                when (state) {
                    SshSessionUiState.Disconnected -> SessionIconButton(
                        TesseraIcons.Power, stringResource(R.string.session_connect), onConnect, selected = true,
                    )
                    SshSessionUiState.Connected -> {
                        if (tmuxEnabled) {
                            SessionIconButton(TesseraIcons.Plus, stringResource(R.string.session_new_tmux_window), onNewTmuxWindow)
                        }
                        SessionIconButton(TesseraIcons.Search, stringResource(R.string.session_find_in_terminal), onSearch)
                        SessionIconButton(
                            TesseraIcons.Folder,
                            if (filesOpen) stringResource(R.string.session_terminal) else stringResource(R.string.session_files),
                            onToggleFiles,
                            selected = filesOpen,
                        )
                        if (forwarding.visible) {
                            SessionIconButton(
                                TesseraIcons.Tunnels,
                                forwarding.localizedAccessibilityLabel(),
                                onToggleForwarding,
                                modifier = Modifier.testTag("session-forwarding-button"),
                                selected = forwardingOpen,
                                tint = forwardingGlyphTint,
                            )
                        }
                        SessionIconButton(
                            TesseraIcons.Copy,
                            stringResource(R.string.session_continue_on_another_device),
                            onContinueOnAnotherDevice,
                        )
                        SessionIconButton(TesseraIcons.Close, stringResource(R.string.session_disconnect), onCloseSession, danger = true)
                    }
                    else -> Unit
                }
            }
        }
        return
    }
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 8.dp, vertical = 6.dp),
        shape = RoundedCornerShape(14.dp),
        color = tokens.panelBg,
        border = androidx.compose.foundation.BorderStroke(1.dp, tokens.border),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TesseraIconButton(
                icon = TesseraIcons.ChevronLeft,
                contentDescription = stringResource(R.string.session_back),
                onClick = onBack,
                prominent = true,
            )
            // The wide bar reaches the same switcher. Its tmux chrome already
            // carries windows and panes, but backing out to the tab bar was
            // still the only route to another host session.
            SessionSwitcherTarget(
                title = host.displayName,
                dot = dot,
                attention = integrationAttention,
                label = switcherLabel,
                minHeight = 44.dp,
                horizontalPadding = 4.dp,
                titlePadding = PaddingValues(horizontal = 8.dp),
                onClick = onOpenSwitcher,
            )
            ProgramStatusAttentionChip(
                center = programStatusCenter,
                agents = programStatusAgents,
                onOpenAgentCenter = onOpenAgentCenter,
                initiallyOpen = programAttentionInitiallyOpen,
            )
            when (state) {
                SshSessionUiState.Disconnected -> TesseraIconButton(
                    icon = TesseraIcons.Power,
                    contentDescription = stringResource(R.string.session_connect),
                    onClick = onConnect,
                    selected = true,
                )
                SshSessionUiState.Connected -> {
                    TesseraIconButton(
                        icon = TesseraIcons.Share,
                        contentDescription = if (host.tmuxMode == TmuxModes.OFF) {
                            stringResource(R.string.session_reconnect_on_another_device)
                        } else {
                            stringResource(R.string.session_continue_on_another_device_lower)
                        },
                        onClick = onContinueOnAnotherDevice,
                    )
                    if (!filesOpen) {
                        TesseraIconButton(
                            icon = TesseraIcons.Search,
                            contentDescription = stringResource(R.string.session_find_in_terminal),
                            onClick = onSearch,
                        )
                        TesseraIconButton(
                            icon = TesseraIcons.Paste,
                            contentDescription = stringResource(R.string.session_paste),
                            onClick = onPaste,
                        )
                    }
                    TesseraIconButton(
                        icon = TesseraIcons.PanelRight,
                        contentDescription = if (filesOpen) {
                            stringResource(R.string.session_terminal)
                        } else {
                            stringResource(R.string.session_files)
                        },
                        onClick = onToggleFiles,
                        selected = filesOpen,
                    )
                    if (forwarding.visible) {
                        TesseraIconButton(
                            icon = TesseraIcons.Tunnels,
                            contentDescription = forwarding.localizedAccessibilityLabel(),
                            onClick = onToggleForwarding,
                            modifier = Modifier.testTag("session-forwarding-button"),
                            selected = forwardingOpen,
                            tint = forwardingGlyphTint,
                        )
                    }
                    TesseraIconButton(
                        icon = TesseraIcons.Power,
                        contentDescription = stringResource(R.string.session_disconnect),
                        onClick = onCloseSession,
                        danger = true,
                    )
                }
                else -> Unit
            }
        }
    }
}

/** The English of `R.string.session_switcher_label`, which instrumented tests match on. */
internal const val SESSION_SWITCHER_LABEL = "Switch session, window, or pane"
internal const val SESSION_STATUS_ATTENTION_RING_TAG = "session-status-attention-ring"

@Composable
internal fun programStatusToneColor(tone: ProgramAttentionTone?): Color {
    val tokens = LocalTesseraTokens.current
    return when (tone) {
        ProgramAttentionTone.NEEDS_INPUT -> tokens.amber
        ProgramAttentionTone.FAILED -> tokens.red
        ProgramAttentionTone.FINISHED -> tokens.green
        null -> tokens.fgDim
    }
}

/** Resolve the merged vocabulary without manufacturing a native record for an agent. */
@Composable
internal fun programStatusWordsLine(words: ProgramStatusStatusWords): String {
    val phrase = programStatusText(words.phrase)
    val progress = words.progress?.let {
        NumberFormat.getPercentInstance().apply { maximumFractionDigits = 0 }.format(it / 100.0)
    }
    return listOfNotNull(words.app?.takeIf { it.isNotEmpty() }, phrase, progress).joinToString(" · ")
}

@Composable
internal fun programStatusPlace(
    hostLabel: String,
    terminal: SharedProgramStatusTerminal,
    location: ProgramStatusPaneLocation?,
): String {
    val place = when (terminal) {
        SharedProgramStatusTerminal.Raw -> stringResource(R.string.program_status_raw_session)
        is SharedProgramStatusTerminal.Pane -> {
            val window = location?.let {
                if (it.windowName.isEmpty()) stringResource(R.string.program_status_window, it.windowPosition)
                else stringResource(R.string.program_status_named_window, it.windowPosition, it.windowName)
            }
            listOfNotNull(window, stringResource(R.string.program_status_pane, "%${terminal.paneId}"))
                .joinToString(" · ")
        }
    }
    return listOf(hostLabel, place).filter { it.isNotEmpty() }.joinToString(" · ")
}

@Composable
private fun ProgramStatusAttentionChip(
    center: ProgramStatusCenter?,
    agents: ProgramStatusAgentInput,
    onOpenAgentCenter: (() -> Unit)?,
    initiallyOpen: Boolean,
) {
    val sessions = center?.sessions?.collectAsState()?.value.orEmpty()
    val items = ProgramStatusQueries.programItems(sessions, agents)
    val counts = ProgramStatusQueries.counts(sessions, agents)
    if (counts.total == 0) return
    val tokens = LocalTesseraTokens.current
    val tint = programStatusToneColor(counts.tone)
    val summary = programStatusCountSummary(counts)
    // Agents without a live pane row are counted too; the footer reaches them.
    val hasAgents = agents.waiting + agents.finished > 0 || items.any { it.hasAgent }
    var open by remember(center) { mutableStateOf(initiallyOpen) }
    Box {
        Row(
            Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp))
                .background(tokens.inputBg).border(1.dp, tint.copy(alpha = 0.36f), RoundedCornerShape(24.dp))
                .clickable { open = true }.semantics { contentDescription = summary }
                .padding(horizontal = 12.dp).testTag("program-attention-summary"),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(if (hasAgents) TesseraIcons.Agents else TesseraIcons.Sessions,
                contentDescription = null, tint = tokens.fgMuted, modifier = Modifier.size(14.dp))
            Text(summary, style = TesseraType.rowMicro, color = tint,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 280.dp).clearAndSetSemantics {})
        }
        DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
            containerColor = tokens.panelBg,
            tonalElevation = 0.dp,
            shadowElevation = 0.dp,
            border = androidx.compose.foundation.BorderStroke(1.dp, tokens.border),
            modifier = Modifier.widthIn(max = 420.dp).testTag("program-attention-list"),
        ) {
            Column(Modifier.padding(horizontal = 14.dp, vertical = 8.dp)) {
                Text(stringResource(R.string.program_status_needs_attention),
                    style = TesseraType.rowMeta, color = tokens.fg)
                Text(stringResource(R.string.program_status_visit_checks),
                    style = TesseraType.rowMicro, color = tokens.fgDim,
                    modifier = Modifier.padding(top = 4.dp, bottom = 12.dp))
                if (items.isEmpty() && !hasAgents) {
                    Text(stringResource(R.string.program_status_all_caught_up),
                        style = TesseraType.rowMicro, color = tokens.fgMuted)
                }
                // Bound the row area so a busy fleet leaves the header and Agent Center footer reachable.
                Column(Modifier.heightIn(max = 340.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    items.forEach { item ->
                        val canOpen = item.hostId in sessions &&
                            (item.terminal == SharedProgramStatusTerminal.Raw || item.location != null)
                        ProgramStatusAttentionRow(item, canOpen) { center?.open(item); open = false }
                    }
                }
                if (hasAgents && onOpenAgentCenter != null) {
                    TesseraHairline(Modifier.padding(top = 10.dp))
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.program_status_open_agent_center),
                            style = TesseraType.rowMicro, color = tokens.fgMuted) },
                        leadingIcon = { Icon(TesseraIcons.Agents, contentDescription = null,
                            tint = tokens.fgMuted, modifier = Modifier.size(14.dp)) },
                        onClick = { open = false; onOpenAgentCenter() },
                        modifier = Modifier.heightIn(min = 48.dp).testTag("program-attention-open-agent-center"),
                    )
                }
            }
        }
    }
}

@Composable
private fun ProgramStatusAttentionRow(item: ProgramAttentionItem, canOpen: Boolean, onOpen: () -> Unit) {
    val tokens = LocalTesseraTokens.current
    val entry = item.entry
    val name = programStatusText(entry?.let { ProgramStatusWordsModel.name(it, item.location?.windowName) }
        ?: item.location?.windowName?.let { ProgramStatusPhrase.Literal(it) } ?: ProgramStatusPhrase.Program)
    val words = programStatusWordsLine(item.status.copy(app = null))
    val app = item.status.app?.takeIf { it.isNotEmpty() && it != name }
    val place = programStatusPlace(item.hostLabel, item.terminal, item.location)
    val label = listOfNotNull(name, app, words, entry?.message?.takeIf { it.isNotEmpty() }, place).joinToString(", ")
    val openLabel = stringResource(if (canOpen) R.string.program_status_open_pane else R.string.program_status_pane_unavailable)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).clip(RoundedCornerShape(8.dp))
            .background(tokens.inputBg).border(1.dp, tokens.border, RoundedCornerShape(8.dp))
            .padding(start = 10.dp, end = 4.dp).testTag("program-attention-row-${item.id}"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(Modifier.weight(1f).heightIn(min = 48.dp).clickable(enabled = canOpen, onClick = onOpen)
            .semantics(mergeDescendants = true) { contentDescription = label }
            .padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(if (item.hasAgent) TesseraIcons.Agents else when (item.tone) {
                ProgramAttentionTone.NEEDS_INPUT -> TesseraIcons.Alert
                ProgramAttentionTone.FAILED -> TesseraIcons.Close
                ProgramAttentionTone.FINISHED -> TesseraIcons.Check
            }, contentDescription = null, tint = programStatusToneColor(item.tone), modifier = Modifier.size(16.dp))
            Column(Modifier.weight(1f).clearAndSetSemantics {}) {
                Text(name, style = TesseraType.rowMeta, color = tokens.fg,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                    app?.let {
                        Text(it, style = TesseraType.rowMicro, color = tokens.fgDim,
                            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    }
                    Text(words, style = TesseraType.rowMicro, color = programStatusToneColor(item.tone))
                }
                entry?.message?.takeIf { it.isNotEmpty() }?.let {
                    Text(it, color = tokens.fgMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Text(place, style = TesseraType.rowMicro, color = tokens.fgDim,
                    maxLines = 2, overflow = TextOverflow.MiddleEllipsis)
            }
        }
        Box(Modifier.heightIn(min = 48.dp).widthIn(min = 48.dp).clip(RoundedCornerShape(8.dp))
            .background(tokens.accentSoft).clickable(enabled = canOpen, onClick = onOpen)
            .semantics { contentDescription = "$openLabel, $label" }.padding(horizontal = 10.dp),
            contentAlignment = Alignment.Center) {
            Text(openLabel, modifier = Modifier.clearAndSetSemantics {},
                style = TesseraType.rowMicro, color = tokens.accent)
        }
    }
}

/**
 * The top bar's host-name target that opens the session switcher. Only its
 * press ripple is clipped to the rounded target shape: the status dot's
 * attention ring ripples past the target's edge and must not be cut off.
 */
@Composable
private fun RowScope.SessionSwitcherTarget(
    title: String,
    dot: Color,
    attention: Boolean,
    label: String,
    minHeight: Dp,
    horizontalPadding: Dp,
    titlePadding: PaddingValues,
    onClick: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    val interactions = remember { MutableInteractionSource() }
    Box(
        modifier = Modifier
            .weight(1f)
            .heightIn(min = minHeight)
            .clickable(interactionSource = interactions, indication = null, onClick = onClick)
            .semantics { contentDescription = label }
            .testTag("session-switcher-button"),
        contentAlignment = Alignment.CenterStart,
    ) {
        Box(
            Modifier
                .matchParentSize()
                .clip(RoundedCornerShape(12.dp))
                .indication(interactions, LocalIndication.current),
        )
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = horizontalPadding),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TesseraStatusDot(
                dot,
                size = 7.dp,
                attention = attention,
                attentionColor = tokens.amber,
                attentionRingModifier = Modifier.testTag(SESSION_STATUS_ATTENTION_RING_TAG),
            )
            Text(
                title,
                modifier = Modifier.weight(1f).padding(titlePadding),
                color = tokens.fg,
                style = TesseraType.rowTitle,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
            Icon(
                TesseraIcons.ChevronDown,
                contentDescription = null,
                tint = tokens.fgMuted,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

@Composable
internal fun TerminalFindBar(
    query: String,
    result: TerminalSearchResult?,
    onQueryChange: (String) -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    // The field takes focus when the bar appears, as on iOS. Otherwise the
    // terminal keeps it, and the query and Search's Enter go to the shell.
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }
    Surface(modifier = modifier, color = tokens.panelBg) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TesseraTextField(
                value = query,
                onValueChange = onQueryChange,
                placeholder = stringResource(R.string.session_find_placeholder),
                leading = TesseraIcons.Search,
                modifier = Modifier.weight(1f),
                inputModifier = Modifier.focusRequester(focusRequester),
                inputTestTag = "terminal-find-field",
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { onNext() }),
            )
            Text(
                result?.let { "${it.current}/${it.total}" } ?: "",
                color = tokens.fgMuted,
                style = TesseraType.rowMeta,
                modifier = Modifier.padding(horizontal = 6.dp),
            )
            SessionIconButton(TesseraIcons.ChevronLeft, stringResource(R.string.session_previous_match), onPrevious)
            SessionIconButton(TesseraIcons.ChevronRight, stringResource(R.string.session_next_match), onNext)
            SessionIconButton(TesseraIcons.Close, stringResource(R.string.session_close_find), onClose)
        }
    }
}

@Composable
private fun SessionIconButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    danger: Boolean = false,
    /** Overrides the glyph colour; see `TesseraIconButton`'s `tint`. */
    tint: Color? = null,
) {
    val tokens = LocalTesseraTokens.current
    val iconTint = when {
        danger -> tokens.red
        tint != null -> tint
        selected -> tokens.accent
        else -> tokens.fgMuted
    }
    Box(
        modifier = modifier
            .size(40.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(if (selected) tokens.accentSoft else Color.Transparent)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription, tint = iconTint, modifier = Modifier.size(21.dp))
    }
}

/**
 * Speaks a Mosh outage the terminal cannot show: a polite live region
 * beside the banner, so a screen reader hears it once while the banner's
 * ticking seconds stay quiet. It is there only while the claimed outage
 * lasts, with [text].
 */
@Composable
internal fun MoshOutageAnnouncement(text: String?, modifier: Modifier = Modifier) {
    if (text == null) return
    Box(modifier.size(1.dp).testTag("mosh-outage-announcement").semantics {
        liveRegion = LiveRegionMode.Polite
        contentDescription = text
    })
}

@Composable
@SuppressLint("ModifierParameter")
private fun TmuxPresentation(
    snapshot: com.bambouville.tessera.core.bridge.SharedTmuxSnapshot?,
    programSessions: Map<String, ProgramStatusSessionState>,
    programHostId: String,
    programStatusAgents: ProgramStatusAgentInput,
    agentProvider: (Int) -> String?,
    tmuxRenderHistory: Map<String, TmuxRenderHistoryReady>,
    pendingMoshFindPaneId: Int?,
    primaryTerminal: TermuxTerminalSurface,
    controller: SshSessionController,
    allowsWindowOrdering: Boolean,
    windowOrderingContextValid: Boolean,
    windowOrderAuthorityKey: Any?,
    compact: Boolean,
    scrollbackLines: Int,
    terminalTextSizeSp: Int,
    terminalTypeface: Typeface,
    terminalTheme: TerminalTheme,
    cursorStyle: TerminalCursorStyle,
    cursorBlink: Boolean,
    terminalDrawingEnabled: Boolean,
    activePaneId: Int?,
    terminalCounterShiftModifier: Modifier,
    outageBannerModifier: Modifier,
    onPaneFocused: (Int) -> Unit,
    onNavigate: () -> Unit,
    onPaneSurfaceChanged: (Int, TermuxTerminalSurface, Boolean) -> Unit,
    onMoshOverlaySurfaceChanged: (Int, TermuxTerminalSurface, Boolean) -> Unit,
    onMoshHistoryOverlaySurfaceChanged: (TermuxTerminalSurface?) -> Unit,
    onMoshHistoryDeliveryApplied: (surfaceId: String, deliveryToken: Long) -> Unit,
    unreadWindowIds: Set<Int>,
    glowingWindowId: Int?,
    modifier: Modifier,
) {
    val context = LocalContext.current
    val activeWindow = snapshot?.activeWindow
    val tmuxWindowIsPaintedWhole by controller.tmuxWindowIsPaintedWhole.collectAsState()
    val moshCanvasSize by controller.moshCanvasSize.collectAsState()
    val moshHistoryDeliveries = remember(tmuxRenderHistory) {
        tmuxRenderHistory
            .filterKeys { it.startsWith("overlay:") }
            .mapValues { (_, delivery) -> delivery.asMoshPaneHistoryReadyDelivery() }
    }
    val moshLiveHistoryDelivery = tmuxRenderHistory["live"]
    val outageTiming by controller.moshOutageTiming.collectAsState()
    val moshPrimaryHistoryVisible by controller.moshPrimaryHistoryVisible.collectAsState()
    var moshHistoryCoversNotification by remember(controller) { mutableStateOf(false) }
    val layout = activeWindow?.layout
    var moshPaneContentRects by remember(controller, activeWindow?.id) {
        mutableStateOf<Map<Int, SharedTmuxCellRect>>(emptyMap())
    }
    LaunchedEffect(controller, tmuxWindowIsPaintedWhole, activeWindow?.id, layout) {
        moshPaneContentRects = emptyMap()
        if (tmuxWindowIsPaintedWhole && activeWindow != null && !activeWindow.zoomed &&
            activeWindow.panes.size > 1
        ) {
            while (isActive && moshPaneContentRects.isEmpty()) {
                moshPaneContentRects = controller.queryTmuxPaneContentRects(activeWindow.id)
                if (moshPaneContentRects.isEmpty()) delay(500)
            }
        }
    }
    val focus = layout?.findPaneForPresentation(snapshot.activePaneId)
    val moshNotificationCropped = layout != null && moshCanvasSize != null && focus != null &&
        layout.width == moshCanvasSize?.columns && layout.height == moshCanvasSize?.rows &&
        (focus.x != 0 || focus.y != 0 || focus.width != layout.width || focus.height != layout.height)
    val needsNativeOutageBanner = tmuxWindowIsPaintedWhole &&
        (moshNotificationCropped || moshHistoryCoversNotification || moshPrimaryHistoryVisible)
    val outageAnnouncement = stringResource(R.string.mosh_outage_announcement)
    var spokenOutageStart by remember(controller) { mutableStateOf<Long?>(null) }
    LaunchedEffect(needsNativeOutageBanner, outageTiming?.startedAtMillis, terminalDrawingEnabled) {
        val startedAt = outageTiming?.startedAtMillis
        if (needsNativeOutageBanner && terminalDrawingEnabled && startedAt != null &&
            controller.claimMoshOutageAnnouncement(startedAt)
        ) {
            spokenOutageStart = startedAt
        }
    }
    val inlineTmuxHistory by controller.tmuxInlineHistory.collectAsState()
    var renameWindow by remember { mutableStateOf<SharedTmuxWindow?>(null) }
    var closeWindow by remember { mutableStateOf<SharedTmuxWindow?>(null) }
    var closePane by remember { mutableStateOf<Int?>(null) }
    Column(modifier) {
        if (!compact) TmuxChrome(
            windows = snapshot?.windows.orEmpty(),
            programSessions = programSessions,
            programHostId = programHostId,
            programStatusAgents = programStatusAgents,
            agentProvider = agentProvider,
            activeWindowId = snapshot?.activeWindowId,
            activeWindow = activeWindow,
            unreadWindowIds = unreadWindowIds,
            glowingWindowId = glowingWindowId,
            onSelectWindow = { onNavigate(); controller.selectTmuxWindow(it) },
            onNewWindow = { onNavigate(); controller.createTmuxWindow() },
            onRenameWindow = { id -> renameWindow = snapshot?.windows?.firstOrNull { it.id == id } },
            onCloseWindow = { id -> closeWindow = snapshot?.windows?.firstOrNull { it.id == id } },
            onMoveWindow = controller::moveTmuxWindow,
            onRenumberWindows = controller::renumberTmuxWindows,
            onSplitWindow = controller::splitTmuxWindow,
            allowsWindowOrdering = allowsWindowOrdering,
            windowOrderingContextValid = windowOrderingContextValid,
            reorderContextKey = snapshot?.sessionName to windowOrderAuthorityKey,
            onSplit = { paneId, vertical -> controller.splitTmuxPane(paneId, vertical) },
            onZoom = { paneId, zoomed -> controller.setTmuxZoomed(paneId, zoomed) },
            onSelectPane = { paneId ->
                onPaneFocused(paneId)
                controller.selectTmuxPane(paneId)
            },
            onClosePane = { closePane = it },
        )
        // Mosh owns a single whole-window terminal canvas even on a tablet.
        // A grid of per-pane terminals is valid only for inline `-CC`; a
        // mosh+tmux split puts its focused pane history on the detached overlay
        // below, leaving the SSP-painted live canvas untouched.
        val tabletGrid = !compact && !tmuxWindowIsPaintedWhole && activeWindow != null &&
            activeWindow.panes.size > 1 && !activeWindow.zoomed
        val showsMoshPaneHistoryOverlay = tmuxWindowIsPaintedWhole && activeWindow != null &&
            activeWindow.panes.size > 1 && !activeWindow.zoomed
        LaunchedEffect(showsMoshPaneHistoryOverlay) {
            if (showsMoshPaneHistoryOverlay) {
                // The single-pane presentation coroutine may still have a
                // posted top-row callback. Retire its exact ledger reader
                // before split overlays become the only valid history path.
                controller.returnTmuxScrollbackToTail(TMUX_RENDER_LIVE_SURFACE_ID)
            } else {
                onMoshHistoryOverlaySurfaceChanged(null)
            }
        }
        Box(
            Modifier
                .fillMaxSize()
                .background(Color(terminalTheme.backgroundArgb))
                .then(
                    if (tabletGrid) Modifier.onSizeChanged { size ->
                        val metrics = primaryTerminal.gridMetrics()
                        controller.updateTmuxViewport(
                            metrics.columnsFor(size.width),
                            metrics.rowsFor(size.height),
                        )
                    } else Modifier,
                ),
        ) {
            if (tabletGrid) {
                val layout = activeWindow.layout
                if (layout != null) {
                    TmuxLayout(
                        layout,
                        activeWindow.panes,
                        controller,
                        context,
                        scrollbackLines,
                        terminalTextSizeSp,
                        terminalTypeface,
                        terminalTheme,
                        cursorStyle,
                        cursorBlink,
                        terminalDrawingEnabled,
                        activePaneId,
                        terminalCounterShiftModifier,
                        onPaneFocused,
                        onPaneSurfaceChanged,
                        Modifier.fillMaxSize(),
                    )
                } else {
                    Column(Modifier.fillMaxSize()) {
                        activeWindow.panes.forEach { pane ->
                            TmuxPaneTerminal(
                                pane,
                                controller,
                                context,
                                scrollbackLines,
                                paneColumns = null,
                                paneRows = null,
                                terminalTextSizeSp = terminalTextSizeSp,
                                terminalTypeface = terminalTypeface,
                                terminalTheme = terminalTheme,
                                cursorStyle = cursorStyle,
                                cursorBlink = cursorBlink,
                                drawingEnabled = terminalDrawingEnabled,
                                focused = pane.id == activePaneId,
                                terminalCounterShiftModifier = terminalCounterShiftModifier,
                                onPaneFocused = onPaneFocused,
                                onPaneSurfaceChanged = onPaneSurfaceChanged,
                                modifier = Modifier.fillMaxWidth().weight(1f),
                            )
                        }
                    }
                }
            } else {
                if (compact || tmuxWindowIsPaintedWhole) {
                    CompactTmuxTerminal(
                        snapshot = snapshot,
                        terminal = primaryTerminal,
                        controller = controller,
                        paintsWholeWindow = tmuxWindowIsPaintedWhole,
                        panToFocusedPane = compact,
                        moshCanvas = moshCanvasSize,
                        drawingEnabled = terminalDrawingEnabled,
                        modifier = Modifier
                            .fillMaxSize()
                            .then(terminalCounterShiftModifier),
                    )
                } else {
                    TerminalViewport(
                        terminal = primaryTerminal,
                        drawingEnabled = terminalDrawingEnabled,
                        modifier = Modifier
                            .fillMaxSize()
                            .then(terminalCounterShiftModifier),
                    )
                }
            }
            if (showsMoshPaneHistoryOverlay) {
                MoshPaneHistoryOverlayHost(
                    context = context,
                    activeWindow = activeWindow,
                    focusedPaneId = activePaneId,
                    findPaneId = pendingMoshFindPaneId,
                    paneContentRects = moshPaneContentRects,
                    primaryTerminal = primaryTerminal,
                    deliveries = moshHistoryDeliveries,
                    scrollbackLines = scrollbackLines,
                    terminalTextSizeSp = terminalTextSizeSp,
                    terminalTypeface = terminalTypeface,
                    terminalTheme = terminalTheme,
                    cursorStyle = cursorStyle,
                    cursorBlink = cursorBlink,
                    drawingEnabled = terminalDrawingEnabled,
                    onSurfaceAttached = { paneId, surface ->
                        onMoshOverlaySurfaceChanged(paneId, surface, true)
                    },
                    onSurfaceDetached = { paneId, surface ->
                        onMoshOverlaySurfaceChanged(paneId, surface, false)
                    },
                    onHistoryRequested = controller::requestTmuxScrollback,
                    onFindRequested = controller::openTmuxFind,
                    onReturnedToLiveTail = controller::returnTmuxScrollbackToTail,
                    onAltScreenScroll = { paneId, rowsDown ->
                        val pane = activeWindow.panes.firstOrNull { it.id == paneId }
                        val rect = activeWindow.layout?.findPaneForPresentation(paneId)
                        val contentRect = moshPaneContentRects[paneId]
                        if (pane?.isMouseReporting == true && rect != null) {
                            val button = if (rowsDown < 0) 64 else 65
                            val column = contentRect?.let { it.x + it.columns / 2 + 1 }
                                ?: (rect.x + rect.width / 2 + 1)
                            val row = contentRect?.let { it.y + it.rows / 2 + 1 }
                                ?: (rect.y + rect.height / 2 + 1)
                            val bytes = "\u001b[<$button;$column;${row}M"
                                .repeat(kotlin.math.abs(rowsDown)).toByteArray()
                            primaryTerminal.sendInput(bytes)
                        } else {
                            val arrow = if (rowsDown < 0) "\u001b[A" else "\u001b[B"
                            primaryTerminal.view.resetImeLineContext()
                            controller.sendTmuxPaneScrollInput(
                                paneId, arrow.repeat(kotlin.math.abs(rowsDown)).toByteArray(),
                            )
                        }
                    },
                    onHistoryDeliveryApplied = onMoshHistoryDeliveryApplied,
                    onVisibleOverlaySurfaceChanged = { surface ->
                        moshHistoryCoversNotification = surface != null
                        onMoshHistoryOverlaySurfaceChanged(surface)
                    },
                    modifier = Modifier.fillMaxSize(),
                )
            } else if (tmuxWindowIsPaintedWhole) {
                // A one-pane (or zoomed) mosh+tmux window keeps its primary
                // terminal. Its first scroll-up still needs a ledger-backed
                // `live` capture because mosh itself has no local scrollback.
                MoshPrimaryLiveHistoryController(
                    primaryTerminal = primaryTerminal,
                    delivery = moshLiveHistoryDelivery,
                    enabled = true,
                    onHistoryRequested = controller::requestTmuxScrollback,
                    onReturnedToLiveTail = controller::returnTmuxScrollbackToTail,
                    onHistoryDeliveryApplied = onMoshHistoryDeliveryApplied,
                )
            } else if (!tabletGrid) {
                // Inline `-CC` single presentation: the primary terminal *is*
                // the `live` render surface and holds real local scrollback,
                // so ordinary scrolling stays native. This only asks the
                // ledger for tmux history deeper than the first capture. The
                // grid's per-pane surfaces mount their own below, and mosh
                // never reaches here.
                InlineTmuxHistoryController(
                    surfaceId = TMUX_RENDER_LIVE_SURFACE_ID,
                    terminal = primaryTerminal,
                    record = inlineTmuxHistory[TMUX_RENDER_LIVE_SURFACE_ID],
                    enabled = true,
                    onRequest = controller::requestTmuxInlineHistory,
                )
            }
            if (needsNativeOutageBanner) {
                outageTiming?.let { timing ->
                    val tokens = LocalTesseraTokens.current
                    Text(
                        text = stringResource(
                            if (timing.kind == MoshOutageTiming.Kind.CONTACT)
                                R.string.mosh_outage_last_contact else R.string.mosh_outage_last_reply,
                            timing.seconds,
                        ),
                        style = TesseraType.rowMicro,
                        color = tokens.fg,
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .then(outageBannerModifier)
                            .fillMaxWidth()
                            .background(tokens.panelBg)
                            .border(0.5.dp, tokens.border)
                            .padding(horizontal = 10.dp, vertical = 5.dp),
                    )
                }
            }
            // Outside the banner, so a banner that comes back within the
            // same outage does not speak it again.
            MoshOutageAnnouncement(
                outageAnnouncement.takeIf { spokenOutageStart != null && spokenOutageStart == outageTiming?.startedAtMillis },
                Modifier.align(Alignment.TopCenter).then(outageBannerModifier),
            )
        }
    }
    renameWindow?.let { window ->
        TmuxRenameDialog(
            initial = window.name.orEmpty(),
            onDismiss = { renameWindow = null },
            onConfirm = { controller.renameTmuxWindow(window.id, it); renameWindow = null },
        )
    }
    closeWindow?.let { window ->
        TmuxCloseDialog(
            title = stringResource(R.string.session_tmux_close_window_title, window.displayName),
            onDismiss = { closeWindow = null },
            onConfirm = { controller.closeTmuxWindow(window.id); closeWindow = null },
        )
    }
    closePane?.let { paneId ->
        TmuxCloseDialog(
            title = stringResource(R.string.session_tmux_close_pane_title, "%$paneId"),
            onDismiss = { closePane = null },
            onConfirm = { controller.closeTmuxPane(paneId); closePane = null },
        )
    }
}

/**
 * The single-surface compact tmux terminal.
 *
 * What the surface is measured at depends on what the transport paints into
 * it, not on the form factor. Mosh streams the whole window, so the terminal
 * must be laid out at the window grid; on a compact screen it is then panned
 * until the focused pane fills the screen, while a wide one shows the whole
 * window, as the iPad does. The inline `-CC` path is fed the focused pane's
 * capture, so the window and focus rects are the same and the transform
 * degenerates to centring that pane. iOS draws the line in the same place.
 */
@Composable
private fun CompactTmuxTerminal(
    snapshot: com.bambouville.tessera.core.bridge.SharedTmuxSnapshot?,
    terminal: TermuxTerminalSurface,
    controller: SshSessionController,
    paintsWholeWindow: Boolean,
    panToFocusedPane: Boolean,
    moshCanvas: com.bambouville.tessera.core.bridge.SharedTmuxGridSize?,
    drawingEnabled: Boolean,
    modifier: Modifier = Modifier,
) {
    val viewportGridChanged = remember(controller) {
        { columns: Int, rows: Int -> controller.updateTmuxViewport(columns, rows) }
    }
    val layout = snapshot?.activeWindow?.layout
    val activePane = layout?.findPaneForPresentation(snapshot.activePaneId)
    val paneRect = activePane?.let {
        SharedTmuxCellRect(columns = it.width, rows = it.height, x = it.x, y = it.y)
    }
    val windowRect: SharedTmuxCellRect?
    val focusRect: SharedTmuxCellRect?
    if (paintsWholeWindow) {
        // Mosh paints its own PTY, never the server's window layout. The two
        // agree only while this device holds the grid; while a peer's client
        // is `latest` the window is the peer's size and the PTY shows a crop
        // of it. Laying the terminal out at the layout then measured it at
        // the peer's grid, scaled the whole thing down to fit, and left the
        // PTY's content as a tiny block in the corner. Pan to the focused
        // pane only when the layout really is this canvas. A wide screen
        // already fits the canvas: centring the focused pane there pushed
        // the window sideways, blank on one side and its other panes cut off.
        windowRect = moshCanvas?.let { SharedTmuxCellRect(columns = it.columns, rows = it.rows, x = 0, y = 0) }
        focusRect = moshCanvasFocusRect(windowRect, layout, paneRect, panToFocusedPane)
    } else {
        windowRect = paneRect
        focusRect = paneRect
    }
    TerminalViewport(
        terminal = terminal,
        drawingEnabled = drawingEnabled,
        onCreated = { onViewportGridChanged = viewportGridChanged },
        update = { viewport ->
            viewport.onViewportGridChanged = viewportGridChanged
            viewport.setWindowGrid(windowRect, focusRect)
        },
        modifier = modifier,
    )
}

/** What a Mosh canvas frames: its focused pane when panning, otherwise all of it. */
internal fun moshCanvasFocusRect(
    canvas: SharedTmuxCellRect?,
    layout: SharedTmuxLayoutNode?,
    pane: SharedTmuxCellRect?,
    panToFocusedPane: Boolean,
): SharedTmuxCellRect? {
    val layoutIsThisCanvas = layout != null && canvas != null &&
        layout.width == canvas.columns && layout.height == canvas.rows
    return if (panToFocusedPane && layoutIsThisCanvas) pane ?: canvas else canvas
}

internal fun SharedTmuxLayoutNode.findPaneForPresentation(paneId: Int?): SharedTmuxLayoutNode.Leaf? =
    when (this) {
        is SharedTmuxLayoutNode.Leaf -> takeIf { paneId == null || this.paneId == paneId }
        is SharedTmuxLayoutNode.Split -> children.firstNotNullOfOrNull {
            it.findPaneForPresentation(paneId)
        }
    }

/**
 * tmux window and pane chrome.
 *
 * Split out of [TmuxPresentation] and driven by the shared snapshot plus typed
 * callbacks rather than by the controller, so the debug harness can render the real
 * bars from a canned snapshot. Windows and panes are selectable chips; the verbs
 * that act on the active window are icons, which is what lets a five-verb bar fit a
 * phone at full touch size.
 */
@Composable
internal fun TmuxChrome(
    windows: List<SharedTmuxWindow>,
    activeWindowId: Int?,
    activeWindow: SharedTmuxWindow?,
    programSessions: Map<String, ProgramStatusSessionState> = emptyMap(),
    programHostId: String = "",
    programStatusAgents: ProgramStatusAgentInput = ProgramStatusAgentInput.NONE,
    agentProvider: (Int) -> String? = { null },
    unreadWindowIds: Set<Int> = emptySet(),
    glowingWindowId: Int? = null,
    onSelectWindow: (Int) -> Unit,
    onNewWindow: () -> Unit,
    onRenameWindow: (Int) -> Unit,
    onCloseWindow: (Int) -> Unit,
    onMoveWindow: (Int, Int) -> Unit = { _, _ -> },
    onRenumberWindows: () -> Unit = {},
    onSplitWindow: ((Int, Boolean, Boolean) -> Unit)? = null,
    allowsWindowOrdering: Boolean = true,
    windowOrderingContextValid: Boolean = allowsWindowOrdering,
    reorderContextKey: Any? = null,
    onSplit: (Int, Boolean) -> Unit,
    onZoom: (Int, Boolean) -> Unit,
    onSelectPane: (Int) -> Unit,
    onClosePane: (Int) -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    val windowScroll = rememberScrollState()
    val density = LocalDensity.current
    val hapticView = LocalView.current
    val reorder = remember(density) {
        TmuxWindowReorderState(
            TmuxReorderAxis.HORIZONTAL,
            with(density) { 6.dp.toPx() },
        )
    }
    val orderedIds = windows.map { it.id }
    var menuWindowId by remember { mutableStateOf<Int?>(null) }
    var pendingReveal by remember { mutableStateOf<TmuxWindowRevealRequest?>(null) }
    val reorderContext = listOf(reorderContextKey, allowsWindowOrdering, orderedIds)
    LaunchedEffect(reorderContext) { reorder.updateContext(reorderContext, orderedIds) }
    val currentWindowOrder = rememberUpdatedState(orderedIds)
    val currentReorderEnabled = rememberUpdatedState(allowsWindowOrdering)
    val currentMenuRequest = rememberUpdatedState<(Int) -> Unit> { menuWindowId = it }
    val currentLiftHaptic = rememberUpdatedState<() -> Unit> {
        hapticView.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
    }
    val currentCrossHaptic = rememberUpdatedState<() -> Unit> {
        hapticView.performHapticFeedback(android.view.HapticFeedbackConstants.CLOCK_TICK)
    }
    val currentMoveWindow = rememberUpdatedState<(Int, Int) -> Unit> { id, destination ->
        movedTmuxWindowOrder(orderedIds, id, destination)?.let { expected ->
            pendingReveal = TmuxWindowRevealRequest(
                id = id,
                sourceOrder = orderedIds,
                expectedOrder = expected,
                contextKey = reorderContextKey,
            )
        }
        onMoveWindow(id, destination)
    }
    TmuxWindowEdgeAutoScroll(
        state = reorder,
        scrollState = windowScroll,
        edgePx = with(density) { 44.dp.toPx() },
        onCross = currentCrossHaptic.value,
    )
    Row(
        modifier = Modifier.fillMaxWidth().background(tokens.panelBg),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = Modifier
                .weight(1f)
                .horizontalScroll(windowScroll)
                .tmuxWindowReorderGesture(
                    state = reorder,
                    order = currentWindowOrder,
                    enabled = currentReorderEnabled,
                    onMenu = currentMenuRequest,
                    onLift = currentLiftHaptic,
                    onCross = currentCrossHaptic,
                    onCommit = currentMoveWindow,
                )
                .onGloballyPositioned(reorder::reportContainer)
                .padding(horizontal = 8.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            windows.forEachIndexed { index, window ->
                val revealRequester = remember(window.id) { BringIntoViewRequester() }
                LaunchedEffect(
                    pendingReveal,
                    orderedIds,
                    windowOrderingContextValid,
                    reorderContextKey,
                ) {
                    val request = pendingReveal ?: return@LaunchedEffect
                    when (
                        tmuxWindowRevealAction(
                            request,
                            orderedIds,
                            reorderContextKey,
                            windowOrderingContextValid,
                        )
                    ) {
                        TmuxWindowRevealAction.CANCEL -> pendingReveal = null
                        TmuxWindowRevealAction.REVEAL -> if (request.id == window.id) {
                            withFrameNanos { }
                            revealRequester.bringIntoView()
                            if (pendingReveal == request) pendingReveal = null
                        }
                        TmuxWindowRevealAction.WAIT -> Unit
                    }
                }
                Box(
                    Modifier
                        .bringIntoViewRequester(revealRequester)
                        .onGloballyPositioned { reorder.reportItem(window.id, it) }
                        .graphicsLayer {
                            translationX = reorder.offsetFor(window.id).x.toFloat()
                            val scale = if (reorder.draggingId == window.id) 1.04f else 1f
                            scaleX = scale
                            scaleY = scale
                        }
                        .zIndex(if (reorder.draggingId == window.id) 1f else 0f)
                        .then(
                            if (reorder.draggingId == window.id) {
                                Modifier.shadow(10.dp, RoundedCornerShape(8.dp))
                            } else Modifier,
                        ),
                ) {
                    val cue = ProgramStatusQueries.windowCue(programSessions, programHostId, window.id, programStatusAgents)
                    val status = ProgramStatusQueries.windowStatus(programSessions, programHostId, window.id, programStatusAgents)
                    val statusText = status?.let { programStatusWordsLine(it) }
                    val position = index + 1
                    val windowLabel = window.agentDisplayName(agentProvider)
                    val accessibilityLabel = if (window.index != null && window.index != position)
                        stringResource(R.string.tmux_window_index_label, position, windowLabel, window.index!!)
                    else stringResource(R.string.tmux_window_label, position, windowLabel)
                    val moveActions = TmuxWindowMoveAction.entries.mapNotNull { action ->
                        if (!allowsWindowOrdering ||
                            tmuxWindowMoveDestination(orderedIds, window.id, action) == null
                        ) return@mapNotNull null
                        val label = when (action) {
                            TmuxWindowMoveAction.PREVIOUS -> stringResource(R.string.tmux_move_left)
                            TmuxWindowMoveAction.NEXT -> stringResource(R.string.tmux_move_right)
                            TmuxWindowMoveAction.START -> stringResource(R.string.tmux_move_start)
                            TmuxWindowMoveAction.END -> stringResource(R.string.tmux_move_end)
                        }
                        CustomAccessibilityAction(label) {
                            tmuxWindowMoveDestination(orderedIds, window.id, action)?.let {
                                onMoveWindow(window.id, it)
                            } != null
                        }
                    }
                    val splitWindow: ((TmuxWindowSplitOption) -> Unit)? =
                        if (allowsWindowOrdering && tmuxWindowSplitTargetPane(window) != null && onSplitWindow != null) {
                            { option -> onSplitWindow(window.id, option.vertical, option.before) }
                        } else null
                    val splitActions = tmuxWindowSplitAccessibilityActions(splitWindow)
                    TmuxChip(
                        label = "$position:$windowLabel",
                        selected = window.id == activeWindowId,
                        unread = window.id in unreadWindowIds,
                        glowing = window.id == glowingWindowId,
                        // The active window is already being looked at: only input requests show there.
                        tone = cue.iconTone(window.id == activeWindowId),
                        titleTone = cue.titleTone(window.id == activeWindowId),
                        hasAgent = cue.hasAgent,
                        onClick = { onSelectWindow(window.id) },
                        accessibilityLabel = listOfNotNull(accessibilityLabel, statusText).joinToString(", "),
                        modifier = Modifier.semantics {
                            customActions = moveActions + splitActions
                        },
                    )
                    TmuxWindowChipMenu(
                        expanded = menuWindowId == window.id,
                        enabled = allowsWindowOrdering,
                        orderedIds = orderedIds,
                        window = window,
                        onDismiss = { if (menuWindowId == window.id) menuWindowId = null },
                        onRename = { onRenameWindow(window.id) },
                        onMove = { action ->
                            tmuxWindowMoveDestination(orderedIds, window.id, action)
                                ?.let { onMoveWindow(window.id, it) }
                        },
                        onTidy = onRenumberWindows,
                        onSplit = splitWindow,
                        onClose = { onCloseWindow(window.id) },
                    )
                }
            }
        }
        TesseraIconButton(
            icon = TesseraIcons.Plus,
            contentDescription = stringResource(R.string.session_new_tmux_window),
            onClick = onNewWindow,
        )
    }
    TesseraHairline()
    activeWindow?.let { window ->
        val activePane = window.activePaneId ?: window.panes.firstOrNull()?.id
        Row(
            Modifier.fillMaxWidth().background(tokens.bg).horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TesseraIconButton(
                icon = TesseraIcons.Pencil,
                contentDescription = stringResource(R.string.session_tmux_rename_window_description),
                onClick = { onRenameWindow(window.id) },
            )
            activePane?.let { paneId ->
                TesseraIconButton(
                    icon = TesseraIcons.SplitHorizontal,
                    contentDescription = stringResource(R.string.session_tmux_split_left_right_description),
                    onClick = { onSplit(paneId, false) },
                )
                TesseraIconButton(
                    icon = TesseraIcons.SplitVertical,
                    contentDescription = stringResource(R.string.session_tmux_split_top_bottom_description),
                    onClick = { onSplit(paneId, true) },
                )
                TesseraIconButton(
                    icon = if (window.zoomed) TesseraIcons.Minimize else TesseraIcons.Maximize,
                    contentDescription = stringResource(
                        if (window.zoomed) R.string.session_tmux_unzoom_pane_description
                        else R.string.session_tmux_zoom_pane_description,
                    ),
                    onClick = { onZoom(paneId, !window.zoomed) },
                    selected = window.zoomed,
                )
            }
            if (window.panes.size > 1) {
                Box(Modifier.padding(horizontal = 4.dp)) {
                    TesseraKicker(stringResource(R.string.session_tmux_panes_kicker))
                }
                window.panes.forEachIndexed { index, pane ->
                    val status = ProgramStatusQueries.paneStatus(programSessions, programHostId, pane.id, programStatusAgents)
                    val statusText = status?.let { programStatusWordsLine(it) }
                    val label = buildString {
                        append(index + 1)
                        pane.title?.takeIf { it.isNotBlank() }?.let { append(':').append(it) }
                    }
                    TmuxChip(
                        label = label,
                        selected = pane.id == activePane,
                        tone = status?.tone,
                        accessibilityLabel = listOfNotNull(label, statusText).joinToString(", "),
                        onClick = { onSelectPane(pane.id) },
                    )
                }
                activePane?.let { paneId ->
                    TesseraIconButton(
                        icon = TesseraIcons.Close,
                        contentDescription = stringResource(R.string.session_tmux_close_pane_description),
                        onClick = { onClosePane(paneId) },
                        danger = true,
                    )
                }
            }
            TesseraIconButton(
                icon = TesseraIcons.Trash,
                contentDescription = stringResource(R.string.session_tmux_close_window_description),
                onClick = { onCloseWindow(window.id) },
                danger = true,
            )
        }
        TesseraHairline()
    }
}

@Composable
private fun TmuxWindowChipMenu(
    expanded: Boolean,
    enabled: Boolean,
    orderedIds: List<Int>,
    window: SharedTmuxWindow,
    onDismiss: () -> Unit,
    onRename: () -> Unit,
    onMove: (TmuxWindowMoveAction) -> Unit,
    onTidy: () -> Unit,
    onSplit: ((TmuxWindowSplitOption) -> Unit)?,
    onClose: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    DropdownMenu(expanded = expanded && enabled, onDismissRequest = onDismiss) {
        if (onSplit != null) TmuxWindowSplitMenuItems { option -> onDismiss(); onSplit(option) }
        DropdownMenuItem(text = { Text(stringResource(R.string.session_tmux_rename)) }, onClick = { onDismiss(); onRename() })
        TmuxWindowMoveAction.entries.forEach { action ->
            val destination = tmuxWindowMoveDestination(orderedIds, window.id, action)
            val label = when (action) {
                TmuxWindowMoveAction.PREVIOUS -> stringResource(R.string.tmux_move_left)
                TmuxWindowMoveAction.NEXT -> stringResource(R.string.tmux_move_right)
                TmuxWindowMoveAction.START -> stringResource(R.string.tmux_move_start)
                TmuxWindowMoveAction.END -> stringResource(R.string.tmux_move_end)
            }
            DropdownMenuItem(
                text = { Text(label) },
                enabled = destination != null,
                onClick = { onDismiss(); onMove(action) },
            )
        }
        DropdownMenuItem(
            text = { Text(stringResource(R.string.tmux_tidy)) },
            enabled = orderedIds.isNotEmpty(),
            onClick = { onDismiss(); onTidy() },
        )
        DropdownMenuItem(
            text = { Text(stringResource(R.string.session_tmux_close_window_menu), color = tokens.red) },
            onClick = { onDismiss(); onClose() },
        )
    }
}

@Composable
internal fun TmuxChip(
    label: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    unread: Boolean = false,
    glowing: Boolean = false,
    tone: ProgramAttentionTone? = null,
    hasAgent: Boolean = false,
    titleTone: ProgramAttentionTone? = tone?.takeIf { !selected && it != ProgramAttentionTone.NEEDS_INPUT },
    accessibilityLabel: String = label,
    onClick: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    val tint = programStatusToneColor(tone)
    Row(
        modifier = modifier
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(7.dp))
            .background(if (selected || glowing) tokens.accentSoft else tokens.inputBg)
            .border(
                1.dp,
                if (tone != null) tint.copy(alpha = 0.55f)
                else if (selected || glowing) tokens.accent.copy(alpha = 0.55f) else tokens.border,
                RoundedCornerShape(7.dp),
            )
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = accessibilityLabel }
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        if (hasAgent) Icon(TesseraIcons.Agents, contentDescription = null,
            tint = if (tone != null) tint else tokens.fgMuted, modifier = Modifier.size(12.dp))
        // The label is a live pane title now, not a short tmux window name, so
        // it has to be bounded: "vim /some/long/path.swift" would otherwise
        // stretch one chip past the width of the scrolling row.
        Text(
            label,
            style = TesseraType.rowMeta,
            color = if (titleTone != null) programStatusToneColor(titleTone) else if (selected || glowing) tokens.accent else tokens.fgMuted,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.widthIn(max = 168.dp),
        )
        if (tone != null) TesseraStatusDot(tint, size = 6.dp)
        else if (unread) TesseraStatusDot(tokens.accent, size = 6.dp)
    }
}

@Composable
@SuppressLint("ModifierParameter")
private fun TmuxLayout(
    node: SharedTmuxLayoutNode,
    panes: List<SharedTmuxPane>,
    controller: SshSessionController,
    context: Context,
    scrollbackLines: Int,
    terminalTextSizeSp: Int,
    terminalTypeface: Typeface,
    terminalTheme: TerminalTheme,
    cursorStyle: TerminalCursorStyle,
    cursorBlink: Boolean,
    terminalDrawingEnabled: Boolean,
    activePaneId: Int?,
    terminalCounterShiftModifier: Modifier,
    onPaneFocused: (Int) -> Unit,
    onPaneSurfaceChanged: (Int, TermuxTerminalSurface, Boolean) -> Unit,
    modifier: Modifier,
) {
    when (node) {
        is SharedTmuxLayoutNode.Leaf -> panes.firstOrNull { it.id == node.paneId }?.let { pane ->
            TmuxPaneTerminal(
                pane = pane,
                controller = controller,
                context = context,
                scrollbackLines = scrollbackLines,
                paneColumns = node.width,
                paneRows = node.height,
                terminalTextSizeSp = terminalTextSizeSp,
                terminalTypeface = terminalTypeface,
                terminalTheme = terminalTheme,
                cursorStyle = cursorStyle,
                cursorBlink = cursorBlink,
                drawingEnabled = terminalDrawingEnabled,
                focused = pane.id == activePaneId,
                terminalCounterShiftModifier = terminalCounterShiftModifier,
                onPaneFocused = onPaneFocused,
                onPaneSurfaceChanged = onPaneSurfaceChanged,
                modifier = modifier,
            )
        }
        is SharedTmuxLayoutNode.Split -> if (node.horizontal) {
            Row(modifier) {
                node.children.forEach { child ->
                    TmuxLayout(
                        child,
                        panes,
                        controller,
                        context,
                        scrollbackLines,
                        terminalTextSizeSp,
                        terminalTypeface,
                        terminalTheme,
                        cursorStyle,
                        cursorBlink,
                        terminalDrawingEnabled,
                        activePaneId,
                        terminalCounterShiftModifier,
                        onPaneFocused,
                        onPaneSurfaceChanged,
                        Modifier.weight(child.layoutWidth().toFloat()),
                    )
                }
            }
        } else {
            Column(modifier) {
                node.children.forEach { child ->
                    TmuxLayout(
                        child,
                        panes,
                        controller,
                        context,
                        scrollbackLines,
                        terminalTextSizeSp,
                        terminalTypeface,
                        terminalTheme,
                        cursorStyle,
                        cursorBlink,
                        terminalDrawingEnabled,
                        activePaneId,
                        terminalCounterShiftModifier,
                        onPaneFocused,
                        onPaneSurfaceChanged,
                        Modifier.weight(child.layoutHeight().toFloat()),
                    )
                }
            }
        }
    }
}

@Composable
@SuppressLint("ModifierParameter")
private fun TmuxPaneTerminal(
    pane: SharedTmuxPane,
    controller: SshSessionController,
    context: Context,
    scrollbackLines: Int,
    paneColumns: Int?,
    paneRows: Int?,
    terminalTextSizeSp: Int,
    terminalTypeface: Typeface,
    terminalTheme: TerminalTheme,
    cursorStyle: TerminalCursorStyle,
    cursorBlink: Boolean,
    drawingEnabled: Boolean,
    focused: Boolean,
    terminalCounterShiftModifier: Modifier,
    onPaneFocused: (Int) -> Unit,
    onPaneSurfaceChanged: (Int, TermuxTerminalSurface, Boolean) -> Unit,
    modifier: Modifier,
) {
    val surface = remember(pane.id, scrollbackLines) {
        TermuxTerminalSurface(
            context,
            transcriptRows = scrollbackLines,
            initialFontSizeSp = terminalTextSizeSp,
            initialTheme = terminalTheme,
            initialCursorStyle = cursorStyle,
            initialCursorBlink = cursorBlink,
            initialTypeface = terminalTypeface,
        )
    }
    DisposableEffect(pane.id, surface) {
        controller.attachTmuxPane(pane.id, surface)
        surface.onSoftwareKeyboardRequested = surface::requestSoftwareKeyboard
        onPaneSurfaceChanged(pane.id, surface, true)
        onDispose {
            onPaneSurfaceChanged(pane.id, surface, false)
            surface.onSoftwareKeyboardRequested = null
            controller.detachTmuxPane(pane.id, surface)
            surface.close()
        }
    }
    LaunchedEffect(surface, terminalTextSizeSp, terminalTypeface) {
        surface.setFont(TerminalFont(terminalTextSizeSp.coerceIn(8, 40), terminalTypeface))
    }
    LaunchedEffect(surface, terminalTheme) { surface.setTheme(terminalTheme) }
    LaunchedEffect(surface, cursorStyle, cursorBlink) {
        surface.setCursorAppearance(cursorStyle, cursorBlink)
    }
    // The pane grid is inline `-CC` only — a mosh+tmux split paints the whole
    // window into the primary canvas and takes the detached overlay path —
    // but the guard is explicit so a future grid caller cannot silently give
    // a mosh surface an inline ladder.
    val paneSurfaceId = "$TMUX_RENDER_PANE_SURFACE_PREFIX${pane.id}"
    val tmuxWindowIsPaintedWhole by controller.tmuxWindowIsPaintedWhole.collectAsState()
    val inlineTmuxHistory by controller.tmuxInlineHistory.collectAsState()
    InlineTmuxHistoryController(
        surfaceId = paneSurfaceId,
        terminal = surface,
        record = inlineTmuxHistory[paneSurfaceId],
        enabled = !tmuxWindowIsPaintedWhole,
        onRequest = controller::requestTmuxInlineHistory,
    )
    TerminalViewport(
        terminal = surface,
        drawingEnabled = drawingEnabled,
        onCreated = {
            surface.view.apply {
                setOnFocusChangeListener { _, focused ->
                    if (focused) {
                        onPaneFocused(pane.id)
                        if (!pane.active) controller.selectTmuxPane(pane.id)
                    }
                }
            }
        },
        update = { viewport ->
            // One surface per pane: the pane is the whole canvas, at its own origin.
            val rect = if (paneColumns != null && paneRows != null) {
                SharedTmuxCellRect(columns = paneColumns, rows = paneRows)
            } else {
                null
            }
            viewport.setWindowGrid(rect, rect)
        },
        modifier = modifier
            .padding(1.dp)
            .clipToBounds()
            .then(if (focused) terminalCounterShiftModifier else Modifier),
    )
}

@Composable
internal fun TmuxRenameDialog(
    initial: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var value by remember(initial) { mutableStateOf(initial) }
    TesseraDialog(
        title = stringResource(R.string.session_tmux_rename_window_title),
        onDismissRequest = onDismiss,
        actions = {
            TesseraButton(text = stringResource(R.string.session_cancel), onClick = onDismiss, compact = true)
            TesseraButton(
                text = stringResource(R.string.session_tmux_rename_confirm),
                onClick = { onConfirm(value) },
                style = TesseraButtonStyle.Primary,
                enabled = value.isNotBlank(),
                compact = true,
            )
        },
    ) {
        TesseraTextField(
            value = value,
            onValueChange = { value = it.take(100) },
            modifier = Modifier.fillMaxWidth(),
            label = stringResource(R.string.session_tmux_window_name),
        )
    }
}

@Composable
internal fun TmuxCloseDialog(title: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    TesseraConfirmDialog(
        title = title,
        body = stringResource(R.string.session_tmux_close_body),
        confirmLabel = stringResource(R.string.session_close),
        cancelLabel = stringResource(R.string.session_cancel),
        destructive = true,
        onConfirm = onConfirm,
        onDismiss = onDismiss,
    )
}

private fun SharedTmuxLayoutNode.layoutWidth(): Int = when (this) {
    is SharedTmuxLayoutNode.Leaf -> width
    is SharedTmuxLayoutNode.Split -> width
}

private fun SharedTmuxLayoutNode.layoutHeight(): Int = when (this) {
    is SharedTmuxLayoutNode.Leaf -> height
    is SharedTmuxLayoutNode.Split -> height
}

@Composable
internal fun SessionStatus(state: SshSessionUiState) {
    val message = when (state) {
        SshSessionUiState.Disconnected, SshSessionUiState.Terminated -> R.string.session_disconnected
        SshSessionUiState.Connecting -> R.string.session_connecting
        is SshSessionUiState.AwaitingCredential -> R.string.session_awaiting_credential
        is SshSessionUiState.AwaitingHostKey -> R.string.session_checking_host_key
        is SshSessionUiState.AwaitingOwnerAuthorization -> R.string.session_owner_authorization
        SshSessionUiState.Connected -> R.string.session_connected
        is SshSessionUiState.Failed -> R.string.session_failed
    }
    val tokens = LocalTesseraTokens.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 18.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = stringResource(message),
            style = TesseraType.rowMeta,
            color = tokens.fgMuted,
        )
    }
}

@Composable
internal fun PasswordDialog(
    username: String,
    host: String,
    onConnect: (String) -> Unit,
    onCancel: () -> Unit,
) {
    var password by remember { mutableStateOf("") }
    val focusRequester = remember { FocusRequester() }
    fun connect() {
        if (password.isNotEmpty()) {
            val submitted = password
            password = ""
            onConnect(submitted)
        }
    }

    TesseraDialog(
        title = stringResource(R.string.session_password_title, username, host),
        onDismissRequest = onCancel,
        dismissOnClickOutside = false,
        actions = {
            TesseraButton(text = stringResource(R.string.session_cancel), onClick = onCancel, compact = true)
            TesseraButton(
                text = stringResource(R.string.session_connect),
                onClick = ::connect,
                style = TesseraButtonStyle.Primary,
                enabled = password.isNotEmpty(),
                compact = true,
            )
        },
    ) {
        Text(
            stringResource(R.string.session_password_not_saved),
            style = TesseraType.body,
            color = LocalTesseraTokens.current.fgMuted,
        )
        TesseraTextField(
            value = password,
            onValueChange = { password = it },
            modifier = Modifier.fillMaxWidth().focusRequester(focusRequester),
            label = stringResource(R.string.session_password),
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Password,
                imeAction = ImeAction.Go,
            ),
            keyboardActions = KeyboardActions(onGo = { connect() }),
        )
    }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }
}

@Composable
internal fun HostKeyDialog(
    challenge: HostKeyChallenge,
    onDecision: (Boolean) -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    val risky = challenge.changed || challenge.reverted
    TesseraDialog(
        title = stringResource(
            when {
                challenge.reverted -> R.string.host_key_reverted
                challenge.changed -> R.string.host_key_changed
                else -> R.string.host_key_unknown
            },
        ).lowercase(),
        onDismissRequest = { onDecision(false) },
        dismissOnClickOutside = false,
        actions = {
            TesseraButton(
                text = stringResource(R.string.session_cancel),
                onClick = { onDecision(false) },
                compact = true,
            )
            TesseraButton(
                text = stringResource(
                    if (challenge.changed) R.string.host_key_replace else R.string.host_key_trust,
                ),
                onClick = { onDecision(true) },
                style = if (risky) TesseraButtonStyle.Danger else TesseraButtonStyle.Primary,
                compact = true,
            )
        },
    ) {
        if (risky) {
            TesseraBanner(
                text = stringResource(
                    if (challenge.reverted) R.string.host_key_reverted_warning
                    else R.string.host_key_changed_warning,
                ),
            )
        }
        HostKeyDetail(
            label = stringResource(R.string.host_key_endpoint_label),
            value = stringResource(R.string.host_key_endpoint, challenge.host, challenge.port),
        )
        HostKeyDetail(label = stringResource(R.string.host_key_algorithm_label), value = challenge.algorithm)
        HostKeyDetail(label = stringResource(R.string.host_key_fingerprint_label), value = challenge.fingerprint)
        challenge.previousFingerprint?.let {
            HostKeyDetail(label = stringResource(R.string.host_key_previous_label), value = it)
        }
        if (!risky) {
            Text(
                stringResource(R.string.host_key_unknown_body),
                style = TesseraType.bodySmall,
                color = tokens.fgMuted,
            )
        }
    }
}

@Composable
internal fun HostKeyDetail(label: String, value: String) {
    val tokens = LocalTesseraTokens.current
    Column(Modifier.fillMaxWidth()) {
        TesseraKicker(label, Modifier.padding(bottom = 6.dp))
        Text(
            value,
            modifier = Modifier
                .fillMaxWidth()
                .background(tokens.inputBg, RoundedCornerShape(8.dp))
                .border(1.dp, tokens.border, RoundedCornerShape(8.dp))
                .padding(horizontal = 10.dp, vertical = 8.dp),
            style = TesseraType.code,
            color = tokens.fg,
        )
    }
}
