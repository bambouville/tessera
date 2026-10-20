package com.bambouville.tessera.feature.session

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.bambouville.tessera.core.bridge.SharedProgramStatusAttention
import com.bambouville.tessera.core.bridge.SharedProgramStatusBlockedKind
import com.bambouville.tessera.core.bridge.SharedProgramStatusEntry
import com.bambouville.tessera.core.bridge.SharedProgramStatusSnapshot
import com.bambouville.tessera.core.bridge.SharedProgramStatusState
import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminal
import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminalSnapshot
import com.bambouville.tessera.core.bridge.SharedArmedModifiers
import com.bambouville.tessera.core.bridge.SharedInputEncoding
import com.bambouville.tessera.core.bridge.SharedModifierArming
import com.bambouville.tessera.core.bridge.SharedModifierArmingEvent
import com.bambouville.tessera.core.bridge.SharedModifierName
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.core.bridge.SharedTmuxPane
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.terminal.TerminalFont
import com.bambouville.tessera.terminal.TerminalTheme
import com.bambouville.tessera.terminal.TermuxTerminalSurface
import java.util.UUID
import kotlinx.coroutines.delay

/**
 * Debug-only visual harness for the session surfaces that only exist while a real
 * SSH connection is up.
 *
 * It renders the shipping composables — [SessionChrome], [TerminalSoftwareAccessory],
 * [TmuxChrome], [PasswordDialog], [HostKeyDialog] — against typed mock state, so the
 * compact-phone presentation of a connected terminal, a tmux window/pane bar, and
 * the three host-key verdicts can be reviewed and screenshotted without automation
 * ever opening a connection. This file lives in the debug source set, so nothing
 * here reaches a release build.
 *
 * The connected-terminal scene uses the shipping [TermuxTerminalSurface]. Its
 * `TerminalView` is a regular canvas-backed Android `View`, so external screenshots
 * and recordings exercise the same pixels a connected session renders without
 * opening a host connection. Other scenes retain a labelled stand-in where the
 * surrounding session or tmux chrome is the subject under review.
 */
enum class SessionHarnessScene(val slug: String, val label: String) {
    TerminalConnected("terminal", "terminal"),
    TerminalDisconnected("disconnected", "disconnected"),
    Tmux("tmux", "tmux"),
    Switcher("switcher", "switcher"),
    Programs("programs", "programs"),
    ProgramsSwitcher("programs-switcher", "programs switcher"),
    TmuxContinuedElsewhere("tmux-peer", "tmux peer"),
    LaunchFailed("launch-failed", "launch failed"),
    Password("password", "password"),
    HostKeyUnknown("key-new", "key: new"),
    HostKeyChanged("key-changed", "key: changed"),
    HostKeyReverted("key-reverted", "key: reverted"),
}

private val harnessHost = SavedHost(
    id = "harness-host",
    displayName = "orbital-relay",
    hostname = "relay.example.net",
    port = 22,
    username = "dev",
    jumpHostId = null,
    identityId = null,
    tmuxMode = TmuxModes.AUTOMATIC,
    tmuxTarget = null,
)

private fun challenge(changed: Boolean, reverted: Boolean) = HostKeyChallenge(
    host = "relay.example.net",
    port = 22,
    algorithm = "ssh-ed25519",
    fingerprint = "SHA256:tQ8vK1nZ0pR6mYd3wLxJ2sBfHgC7eUaN9iOrPzXkQ4M",
    changed = changed,
    reverted = reverted,
    previousFingerprint = if (changed || reverted) {
        "SHA256:aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7dE9f"
    } else {
        null
    },
    challengeId = UUID.fromString("00000000-0000-4000-8000-000000000001"),
    attemptId = UUID.fromString("00000000-0000-4000-8000-000000000002"),
    policyGeneration = 1,
)

private val harnessWindows = listOf(
    SharedTmuxWindow(
        id = 1,
        index = 0,
        name = "edit",
        activePaneId = 11,
        panes = listOf(
            SharedTmuxPane(id = 11, title = "nvim", currentCommand = "nvim", active = true),
            SharedTmuxPane(id = 12, title = "test", currentCommand = "pytest", active = false),
        ),
        zoomed = false,
        layout = SharedTmuxLayoutNode.Split(
            horizontal = true,
            width = 160,
            height = 40,
            children = listOf(
                SharedTmuxLayoutNode.Leaf(paneId = 11, width = 100, height = 40),
                SharedTmuxLayoutNode.Leaf(paneId = 12, width = 60, height = 40),
            ),
        ),
    ),
    SharedTmuxWindow(
        id = 2,
        index = 1,
        name = "logs",
        activePaneId = 21,
        panes = listOf(SharedTmuxPane(id = 21, title = "journalctl", currentCommand = "journalctl", active = true)),
        zoomed = false,
        layout = SharedTmuxLayoutNode.Leaf(paneId = 21, width = 160, height = 40),
    ),
    SharedTmuxWindow(
        id = 3,
        index = 2,
        name = "deploy",
        activePaneId = 31,
        panes = listOf(SharedTmuxPane(id = 31, title = null, currentCommand = "bash", active = true)),
        zoomed = false,
        layout = SharedTmuxLayoutNode.Leaf(paneId = 31, width = 160, height = 40),
    ),
)

/**
 * Switcher fixtures: a split window, two single-pane windows, and three live
 * host sessions in three connection states, so one screenshot shows every row
 * variant the sheet can draw.
 */
private val harnessSwitcherWindows =
    SharedTmuxSnapshot(
        sessionName = "orbital",
        activeWindowId = 1,
        windows = harnessWindows,
        authority = SharedTmuxGridAuthoritySnapshot.Mine(generation = 1),
        revision = 1,
        rawJson = ByteArray(0),
    ).switcherWindows()

private val harnessSwitcherSessions = listOf(
    SessionSwitcherSession(
        hostId = "harness-host",
        title = "orbital-relay",
        endpoint = "dev@relay.example.net:22",
        status = SessionSwitcherStatus.CONNECTED,
        isCurrent = true,
        lastTouchedEpochMilliseconds = 3,
        paneTitle = "edit",
    ),
    SessionSwitcherSession(
        hostId = "builder",
        title = "builder-01",
        endpoint = "ci@builder.example.net:22",
        status = SessionSwitcherStatus.CONNECTED,
        isCurrent = false,
        unread = true,
        lastTouchedEpochMilliseconds = 2,
    ),
    SessionSwitcherSession(
        hostId = "archive",
        title = "archive",
        endpoint = "dev@archive.example.net:2222",
        status = SessionSwitcherStatus.FAILED,
        isCurrent = false,
        lastTouchedEpochMilliseconds = 1,
    ),
)

private val harnessProgramWindows = harnessWindows.map { window ->
    window.copy(panes = window.panes.map { pane ->
        when (pane.id) {
            11 -> pane.copy(title = "deploy prod", currentCommand = "deploy")
            12 -> pane.copy(title = "cargo", currentCommand = "cargo")
            21 -> pane.copy(title = "pytest", currentCommand = "pytest")
            else -> pane.copy(title = "build", currentCommand = "npm")
        }
    })
}

private fun harnessProgramTmux(activeWindowId: Int) = SharedTmuxSnapshot(
    sessionName = "orbital",
    activeWindowId = activeWindowId,
    windows = harnessProgramWindows,
    authority = SharedTmuxGridAuthoritySnapshot.Mine(generation = 1),
    revision = 1,
    rawJson = ByteArray(0),
)

/** Typed Core verdicts: no parser, native handle or host connection needed. */
private fun harnessProgramStatus(): SharedProgramStatusSnapshot {
    fun terminal(paneId: Int, state: SharedProgramStatusState, app: String,
        title: String? = null, progress: Int? = null,
        kind: SharedProgramStatusBlockedKind? = null,
        attention: SharedProgramStatusAttention? = null): SharedProgramStatusTerminalSnapshot {
        val terminal = SharedProgramStatusTerminal.Pane(paneId)
        val unread = state == SharedProgramStatusState.DONE || state == SharedProgramStatusState.ERROR
        val entry = SharedProgramStatusEntry(
            terminal = terminal, idPath = emptyList(), state = state, kind = kind,
            progress = progress, app = app, title = title, message = null,
            isHistorical = false, isUnreadResult = unread, updateToken = paneId.toLong(),
            resultToken = paneId.toLong().takeIf { unread }, attention = attention,
        )
        return SharedProgramStatusTerminalSnapshot(terminal, listOf(entry), entry, entry.resultToken)
    }
    return SharedProgramStatusSnapshot(1, listOf(
        terminal(11, SharedProgramStatusState.BLOCKED, "deploy", title = "deploy prod",
            kind = SharedProgramStatusBlockedKind.PERMISSION, attention = SharedProgramStatusAttention.NEEDS_INPUT),
        terminal(12, SharedProgramStatusState.ERROR, "cargo", attention = SharedProgramStatusAttention.FAILED),
        terminal(21, SharedProgramStatusState.DONE, "pytest", attention = SharedProgramStatusAttention.FINISHED),
        terminal(31, SharedProgramStatusState.WORKING, "npm", progress = 42),
    ))
}

@Composable
fun SessionVisualHarness(
    scene: SessionHarnessScene,
    modifier: Modifier = Modifier,
    resizeTerminalWithKeyboard: Boolean = false,
    terminalFixture: String = "fresh",
) {
    val tokens = LocalTesseraTokens.current
    var filesOpen by remember { mutableStateOf(false) }
    var armedModifiers by remember { mutableStateOf(SharedArmedModifiers()) }
    var activeWindowId by remember { mutableStateOf(1) }
    var activePaneId by remember { mutableStateOf(11) }
    val programScene = scene == SessionHarnessScene.Programs || scene == SessionHarnessScene.ProgramsSwitcher
    var switcherOpen by remember(scene) {
        mutableStateOf(scene == SessionHarnessScene.Switcher || scene == SessionHarnessScene.ProgramsSwitcher)
    }
    val programCenter = remember(scene) {
        ProgramStatusCenter().apply {
            if (programScene) publish(harnessHost.id, ProgramStatusSessionState(
                harnessHost.displayName, harnessProgramStatus(), programStatusPaneLocations(harnessProgramTmux(1)),
            ), acknowledge = { _, _ -> })
        }
    }
    val programSessions by programCenter.sessions.collectAsState()
    SideEffect {
        programCenter.onOpenTerminal = { _, windowId, paneId ->
            windowId?.let { activeWindowId = it }
            paneId?.let { activePaneId = it }
            switcherOpen = false
        }
    }
    var keyboardToggle by remember { mutableStateOf<(() -> Unit)?>(null) }
    var fixtureGeneration by remember { mutableStateOf(0) }
    var renderedTerminalFixture by remember { mutableStateOf<String?>(null) }
    var takeBackRequested by remember(scene) { mutableStateOf(false) }
    val density = LocalDensity.current
    val softwareKeyboardVisible = WindowInsets.ime.getBottom(density) > 0
    val context = LocalContext.current
    val captureSurface = remember(context) {
        TermuxTerminalSurface(context).apply {
            setTheme(TerminalTheme("#D8D8D8", "#000000", "#FFFFFF"))
            setFont(TerminalFont(sizeSp = 15))
        }
    }
    DisposableEffect(captureSurface) {
        onDispose { captureSurface.close() }
    }

    if (scene == SessionHarnessScene.TerminalConnected) {
        val keyboardLayout = rememberTerminalKeyboardViewportLayout(
            resizeTerminalWithKeyboard = resizeTerminalWithKeyboard,
            terminal = captureSurface,
            caretFollowingEnabled = true,
        )
        // The scene mounts the shipping Scaffold, not only the shipping
        // composables inside it. Where the accessory bar lands is a contract
        // between three parties - the Scaffold's content insets, the IME lift
        // and the bar's own navigation-bar padding - so a harness that skipped
        // the Scaffold could not reproduce a gap between the bar and the
        // keyboard, which is exactly the bug this scene has to be able to show.
        Scaffold(
            modifier = modifier,
            containerColor = Color.Black,
            contentWindowInsets = sessionContentWindowInsets(),
            topBar = {
                SessionChrome(
                    host = harnessHost,
                    state = SshSessionUiState.Connected,
                    filesOpen = filesOpen,
                    compact = true,
                    tmuxEnabled = true,
                    onBack = {},
                    onConnect = {},
                    onPaste = {},
                    onToggleFiles = { filesOpen = !filesOpen },
                    onCloseSession = {},
                )
            },
        ) { contentPadding ->
            Box(
                Modifier
                    .fillMaxSize()
                    .padding(contentPadding)
                    .clipToBounds(),
            ) {
                Column(
                    Modifier
                        .fillMaxSize()
                        .then(keyboardLayout.sessionModifier),
                ) {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .weight(1f)
                            .clipToBounds(),
                    ) {
                        CaptureTerminal(
                            surface = captureSurface,
                            fixture = terminalFixture,
                            onKeyboardToggleReady = { keyboardToggle = it },
                            onFixtureRendered = {
                                renderedTerminalFixture = terminalFixture
                                fixtureGeneration += 1
                            },
                            modifier = Modifier
                                .fillMaxSize()
                                .then(keyboardLayout.terminalCounterShiftModifier),
                        )
                    }
                    TerminalSoftwareAccessory(
                        armed = armedModifiers,
                        keyboardVisible = softwareKeyboardVisible,
                        onModifier = { name -> armedModifiers = armedModifiers.armingTap(name) },
                        onKey = { key -> sendAccessoryKey(captureSurface, key, armedModifiers) },
                        onKeyboard = { keyboardToggle?.invoke() },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                // The view commits a layout resize after its settle delay, which
                // usually lands after the IME animation's last frame recomposed
                // this scene; poll so the probe republishes the grid the surface
                // finally committed instead of the one it had mid-animation.
                var probeState by remember(captureSurface) {
                    mutableStateOf(captureSurface.snapshotNonSecretState())
                }
                LaunchedEffect(captureSurface) {
                    while (true) {
                        val latest = captureSurface.snapshotNonSecretState()
                        if (latest != probeState) probeState = latest
                        delay(50)
                    }
                }
                // Where the caret row starts in the terminal slot: the lift the
                // canvas keeps (ime - counter) must not exceed it, or the
                // prompt is pushed off the top. -1 when the surface keeps the
                // whole lift (no clearance).
                val caretTop = captureSurface.caretClearance()?.abovePixels?.toInt() ?: -1
                Text(
                    "ime=${keyboardLayout.imeOverlapPixels};" +
                        "counter=${keyboardLayout.terminalCounterShiftPixels};" +
                        "caretTop=$caretTop;" +
                        "rows=${probeState.rows};cursor=${probeState.cursorRow};" +
                        "columns=${probeState.columns};alt=${probeState.alternateScreen};" +
                        "mouse=${probeState.mouseTracking};fixture=$terminalFixture;" +
                        "rendered=${renderedTerminalFixture.orEmpty()};" +
                        "generation=$fixtureGeneration",
                    modifier = Modifier
                        .testTag("terminal-viewport-probe")
                        .graphicsLayer { alpha = 0.01f },
                    color = Color.White,
                )
            }
        }
        return
    }

    Column(
        modifier
            .then(Modifier.terminalKeyboardBehaviorModifier(resizeTerminalWithKeyboard))
            .fillMaxSize()
            .background(Color.Black),
    ) {
        when (scene) {
            SessionHarnessScene.TerminalConnected,
            SessionHarnessScene.TmuxContinuedElsewhere,
            SessionHarnessScene.LaunchFailed,
            SessionHarnessScene.Password,
            SessionHarnessScene.HostKeyUnknown,
            SessionHarnessScene.HostKeyChanged,
            SessionHarnessScene.HostKeyReverted,
            -> SessionChrome(
                host = harnessHost,
                state = SshSessionUiState.Connected,
                filesOpen = filesOpen,
                compact = true,
                tmuxEnabled = true,
                onBack = {},
                onConnect = {},
                onPaste = {},
                onToggleFiles = { filesOpen = !filesOpen },
                onCloseSession = {},
            )
            SessionHarnessScene.TerminalDisconnected -> {
                SessionChrome(
                    host = harnessHost,
                    state = SshSessionUiState.Disconnected,
                    filesOpen = false,
                    compact = true,
                    tmuxEnabled = true,
                    onBack = {},
                    onConnect = {},
                    onPaste = {},
                    onToggleFiles = {},
                    onCloseSession = {},
                )
                SessionStatus(SshSessionUiState.Disconnected)
            }
            SessionHarnessScene.Tmux,
            SessionHarnessScene.Switcher,
            SessionHarnessScene.Programs,
            SessionHarnessScene.ProgramsSwitcher -> {
                SessionChrome(
                    host = harnessHost,
                    state = SshSessionUiState.Connected,
                    filesOpen = false,
                    // The wide bar (and its attention chip) only where the
                    // session screen would draw it: below 700dp it is compact.
                    compact = scene != SessionHarnessScene.Programs || with(density) {
                        LocalWindowInfo.current.containerSize.width.toDp() < 700.dp
                    },
                    programStatusCenter = programCenter,
                    programAttentionInitiallyOpen = scene == SessionHarnessScene.Programs,
                    tmuxEnabled = true,
                    onBack = {},
                    onConnect = {},
                    onPaste = {},
                    onToggleFiles = {},
                    // The switcher scene drives the real affordance: tapping the
                    // session name is how it opens in the shipping app, so the
                    // hit target and the dismiss path are exercised too.
                    onOpenSwitcher = { switcherOpen = true },
                    onCloseSession = {},
                )
                if (scene == SessionHarnessScene.Programs) {
                    TmuxChrome(
                        windows = harnessProgramWindows,
                        activeWindowId = activeWindowId,
                        activeWindow = harnessProgramWindows.firstOrNull { it.id == activeWindowId },
                        programSessions = programSessions,
                        programHostId = harnessHost.id,
                        onSelectWindow = { activeWindowId = it },
                        onNewWindow = {}, onRenameWindow = {}, onCloseWindow = {},
                        onSplit = { _, _ -> }, onZoom = { _, _ -> },
                        onSelectPane = { activePaneId = it }, onClosePane = {},
                    )
                }
            }
        }

        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
            Text(
                TERMINAL_PLACEHOLDER,
                style = TesseraType.code,
                // The scene paints a terminal-black body regardless of app theme, so
                // this label cannot take its colour from the theme's dim token.
                color = Color(0xFF6B6B6B),
                modifier = Modifier.padding(24.dp),
            )
        }

        if (scene == SessionHarnessScene.TerminalConnected ||
            scene == SessionHarnessScene.Tmux ||
            scene == SessionHarnessScene.TmuxContinuedElsewhere
        ) {
            TerminalSoftwareAccessory(
                armed = armedModifiers,
                keyboardVisible = softwareKeyboardVisible,
                onModifier = { name -> armedModifiers = armedModifiers.armingTap(name) },
                onKey = { key -> sendAccessoryKey(captureSurface, key, armedModifiers) },
                onKeyboard = { keyboardToggle?.invoke() },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }

    when (scene) {
        SessionHarnessScene.Password -> PasswordDialog(
            username = "dev",
            host = "relay.example.net",
            onConnect = {},
            onCancel = {},
        )
        SessionHarnessScene.HostKeyUnknown ->
            HostKeyDialog(challenge(changed = false, reverted = false)) {}
        SessionHarnessScene.HostKeyChanged ->
            HostKeyDialog(challenge(changed = true, reverted = false)) {}
        SessionHarnessScene.HostKeyReverted ->
            HostKeyDialog(challenge(changed = false, reverted = true)) {}
        SessionHarnessScene.TmuxContinuedElsewhere -> ContinuedElsewhereOverlay(
            peerDisplayName = "iPad",
            onTakeBack = { takeBackRequested = true },
            isReclaiming = takeBackRequested,
            modifier = Modifier.fillMaxSize(),
        )
        SessionHarnessScene.Switcher,
        SessionHarnessScene.ProgramsSwitcher -> if (switcherOpen) {
            SessionSwitcherSheet(
                windows = if (programScene) harnessProgramTmux(activeWindowId).switcherWindows() else harnessSwitcherWindows,
                programStatusCenter = programCenter,
                programHostId = harnessHost.id,
                activeWindowId = activeWindowId,
                activePaneId = activePaneId,
                sessions = harnessSwitcherSessions.map {
                    if (programScene && it.hostId == harnessHost.id) it.copy(
                        programAttention = ProgramStatusQueries.sessionCounts(programSessions, harnessHost.id))
                    else it
                },
                currentSessionTitle = harnessHost.displayName,
                unreadWindowIds = setOf(2),
                allowsTmuxMutation = true,
                notice = if (programScene) null else SessionSwitcherNotice(
                    title = "Agent integration not installed",
                    message = "Installs Tessera's local hook files and PATH shims, then loads them " +
                        "here so future agents report accurate status.",
                    actionLabel = "Install and enable",
                ),
                onNoticeAction = { switcherOpen = false },
                onHome = { switcherOpen = false },
                onSelectSession = { switcherOpen = false },
                // Selecting moves the current marker, so a tap is visibly a
                // switch and not just a dismiss.
                onSelectWindow = { id ->
                    activeWindowId = id
                    activePaneId = harnessSwitcherWindows
                        .first { it.id == id }
                        .panes
                        .first()
                        .id
                    switcherOpen = false
                },
                onSelectPane = { activePaneId = it; switcherOpen = false },
                onNewWindow = {},
                onRenameWindow = { _, _ -> },
                onCloseWindow = {},
                onSplitPane = { _, _ -> },
                onSetPaneZoomed = { _, _ -> },
                onClosePane = {},
                onDismiss = { switcherOpen = false },
            )
        }
        SessionHarnessScene.LaunchFailed -> SessionLaunchOverlay(
            phase = SessionLaunchPhase.ATTACHING_PANE,
            subtitle = "windows",
            failureReason = "The tmux control channel closed before the pane was ready.",
            onEditHost = {},
            onRetry = {},
            onBack = {},
            modifier = Modifier.fillMaxSize(),
        )
        else -> Unit
    }
}

@Composable
private fun CaptureTerminal(
    surface: TermuxTerminalSurface,
    fixture: String,
    onKeyboardToggleReady: ((() -> Unit)?) -> Unit,
    onFixtureRendered: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val currentKeyboardToggleReady by rememberUpdatedState(onKeyboardToggleReady)
    val currentFixtureRendered by rememberUpdatedState(onFixtureRendered)

    DisposableEffect(surface) {
        surface.onSoftwareKeyboardRequested = surface::requestSoftwareKeyboard
        currentKeyboardToggleReady(surface::toggleSoftwareKeyboard)
        onDispose {
            currentKeyboardToggleReady(null)
            surface.onSoftwareKeyboardRequested = null
        }
    }
    LaunchedEffect(surface, fixture) {
        // Wait for AndroidView's first layout: terminal dimensions are part of the
        // fixture contract, particularly for middle/bottom/status rows.
        var availableRows = 0
        repeat(40) {
            availableRows = surface.view.mEmulator?.mRows ?: 0
            if (availableRows <= 0) delay(25)
        }
        val rows = availableRows.coerceAtLeast(4)
        // Cursor blink is paint-only. Freeze this debug fixture in its visible
        // phase so the geometry assertion cannot intermittently see a blank
        // frame while the cursor position itself remains valid.
        surface.view.mEmulator?.setCursorBlinkingEnabled(false)
        surface.feed("\u001b[?1049l\u001b[?1000l\u001b[2J\u001b[H".encodeToByteArray())
        when (fixture) {
            "middle" -> {
                // Two-thirds down is safely inside the visible band but leaves
                // less than a docked Pixel IME below the cursor, so it proves
                // the policy's partial (rather than full or zero) counter-shift.
                val middle = (rows * 2 / 3).coerceIn(2, rows - 1)
                surface.feed("\u001b[${middle};1H\u001b[38;5;45mMIDDLE CURSOR\u001b[0m".encodeToByteArray())
            }
            "scroll" -> {
                surface.feed(buildString {
                    repeat(600) { row ->
                        val color = if (row % 12 < 6) 22 else 52
                        append("\u001b[48;5;${color}m")
                        append("%04d  |  pixel scrolling  |\u001b[K\r\n".format(row))
                    }
                    append("\u001b[0m\u001b[?25l")
                }.encodeToByteArray())
                surface.view.topRow = -200
            }
            "tail" -> {
                repeat(rows * 2) { surface.feed("long output line ${it + 1}\r\n".encodeToByteArray()) }
                // Reposition after the deliberately wrapping output: the tail
                // contract is the final visible row, independent of phone width.
                surface.feed("\u001b[${rows};1H\u001b[38;5;45mTAIL\u001b[0m\u001b[${rows};1H".encodeToByteArray())
            }
            "alt" -> {
                surface.feed("\u001b[?1049h\u001b[2J\u001b[H".encodeToByteArray())
                for (row in 1 until rows) {
                    surface.feed("\u001b[${row};1Halternate screen row $row".encodeToByteArray())
                }
                surface.feed("\u001b[${rows};1HSTATUS LINE MUST REMAIN VISIBLE\u001b[2;1H".encodeToByteArray())
            }
            "mouse" -> {
                for (row in 1 until rows) {
                    surface.feed("\u001b[${row};1Hmouse screen row $row".encodeToByteArray())
                }
                surface.feed(
                    "\u001b[${rows};1HMOUSE STATUS LINE MUST REMAIN VISIBLE\u001b[?1000h\u001b[2;1H"
                        .encodeToByteArray(),
                )
            }
            else -> {
                surface.feed(CAPTURE_TERMINAL_HEADER.encodeToByteArray())
                // The "fresh" fixture represents a prompt near the top of a
                // newly opened terminal. Keep its caret there so the keyboard
                // policy deterministically has enough blank space to cancel
                // the full terminal lift on every supported screen size.
                surface.feed("\u001b[1;1H".encodeToByteArray())
            }
        }
        currentFixtureRendered()
    }
    // The normal terminal scene must use the exact plain SSH/Mosh AndroidView
    // path. A geometry-neutral tmux viewport would freeze the local grid at an
    // authoritative pane size and make the resize-on row-change fixture inert.
    AndroidView(factory = { surface.view }, modifier = modifier)
}

private const val TERMINAL_PLACEHOLDER =
    "terminal surface\n(rendered by TermuxTerminalSurface in the app)"

private const val CAPTURE_TERMINAL_HEADER =
    "\u001b[2J\u001b[H" +
        "\u001b[1;36mTessera Android capture proof\u001b[0m\r\n" +
        "shipping TermuxTerminalSurface\r\n" +
        "UTF-8: café  界\r\n" +
        "screenshot + screen recording\r\n" +
        "diagnostics remain locally exportable\r\n"

/**
 * The same shared transition production uses, so a captured bar cannot show an
 * armed state the real one would not reach.
 * Swift authority: `TesseraInputCore.ModifierArming`.
 */
private fun SharedArmedModifiers.armingTap(name: SharedModifierName): SharedArmedModifiers =
    SharedInputEncoding.modifierArmingTransition(
        SharedModifierArming(armed = this),
        SharedModifierArmingEvent.Tap(name),
    ).state.armed
