package com.bambouville.tessera.feature.session

import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminal
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraSearchField
import com.bambouville.tessera.design.TesseraStatusDot
import com.bambouville.tessera.design.TesseraType

/** An agent-integration warning, rendered above the switcher's navigation rows. */
internal data class SessionSwitcherNotice(
    val title: String,
    val message: String,
    val actionLabel: String?,
)

/**
 * The session-name switcher.
 *
 * Tapping the host name in the top bar lands here. It is the compact client's
 * whole navigation surface, so it lists everything reachable from a live
 * terminal in the order iOS's palette lists it: hosts home, this session's tmux
 * windows and panes, then every live host session. Before this, the sheet
 * offered only windows and panes as chips, and a second host session could be
 * reached only by leaving the terminal for the tab bar.
 *
 * Rows rather than chips: a chip row can only carry a label, and each of these
 * targets needs a second line — what a window's panes are running, where a
 * session is connected — to be picked correctly on a phone. The verbs that act
 * on a tmux target moved onto each row's own menu for the same reason: the old
 * single verb row acted on whichever window happened to be active, which is
 * never the row the user is reaching for.
 *
 * The query field does not take focus on open. iOS's palette does, but its card
 * is top-anchored on a taller screen; here, raising the IME immediately would
 * cover the list the user came for. Typing is one tap away, and the list is
 * the primary interaction on touch.
 */
@Composable
internal fun SessionSwitcherSheet(
    windows: List<SessionSwitcherWindow>,
    activeWindowId: Int?,
    activePaneId: Int?,
    sessions: List<SessionSwitcherSession>,
    currentSessionTitle: String,
    programStatusCenter: ProgramStatusCenter? = null,
    programHostId: String = "",
    programStatusAgents: ProgramStatusAgentInput = ProgramStatusAgentInput.NONE,
    unreadWindowIds: Set<Int> = emptySet(),
    glowingWindowId: Int? = null,
    /** False while another device holds the grid, or before tmux has hydrated. */
    allowsTmuxMutation: Boolean = true,
    /** Remains true during this device's in-flight mutation so its dropped row can be revealed. */
    tmuxMutationContextValid: Boolean = allowsTmuxMutation,
    reorderContextKey: Any? = null,
    notice: SessionSwitcherNotice? = null,
    onNoticeAction: () -> Unit = {},
    /** Opens the full warning: its whole message, every action and Help. */
    onNoticeDetails: (() -> Unit)? = null,
    onHome: () -> Unit,
    onSelectSession: (String) -> Unit,
    onSelectWindow: (Int) -> Unit,
    onSelectPane: (Int) -> Unit,
    onNewWindow: () -> Unit,
    onRenameWindow: (Int, String) -> Unit,
    onCloseWindow: (Int) -> Unit,
    onMoveWindow: (Int, Int) -> Unit = { _, _ -> },
    onRenumberWindows: () -> Unit = {},
    onSplitWindow: ((Int, Boolean, Boolean) -> Unit)? = null,
    onSplitPane: (Int, Boolean) -> Unit,
    onSetPaneZoomed: (Int, Boolean) -> Unit,
    onClosePane: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    val programSessions = programStatusCenter?.sessions?.collectAsState()?.value.orEmpty()
    val programDetails = ProgramStatusQueries.detailEntries(programSessions, programHostId)
    var query by remember { mutableStateOf("") }
    var renameWindow by remember { mutableStateOf<SessionSwitcherWindow?>(null) }
    var closeWindow by remember { mutableStateOf<SessionSwitcherWindow?>(null) }
    var closePane by remember { mutableStateOf<Int?>(null) }
    var menuWindowId by remember { mutableStateOf<Int?>(null) }
    var pendingReveal by remember { mutableStateOf<TmuxWindowRevealRequest?>(null) }
    val listScroll = rememberScrollState()
    val density = LocalDensity.current
    val hapticView = LocalView.current
    val rowReorder = remember(density) {
        TmuxWindowReorderState(TmuxReorderAxis.VERTICAL, spacingPx = 0f)
    }
    val results = SessionSwitcherEntries.results(
        query = query,
        windows = windows,
        sessions = sessions,
    )
    val orderedWindowIds = windows.map { it.id }
    val tmuxWindowGroups = results.tmux
        .filterIsInstance<SessionSwitcherEntry.Window>()
        .map { windowEntry ->
            listOf<SessionSwitcherEntry>(windowEntry) + results.tmux.filterIsInstance<SessionSwitcherEntry.Pane>()
                .filter { it.window.id == windowEntry.window.id }
        }
    val reorderContext = listOf(reorderContextKey ?: currentSessionTitle, allowsTmuxMutation, orderedWindowIds)
    LaunchedEffect(reorderContext) { rowReorder.updateContext(reorderContext, orderedWindowIds) }
    val currentWindowOrder = rememberUpdatedState(orderedWindowIds)
    val currentReorderEnabled = rememberUpdatedState(allowsTmuxMutation && query.isBlank())
    val currentMenuRequest = rememberUpdatedState<(Int) -> Unit> { menuWindowId = it }
    val currentLiftHaptic = rememberUpdatedState<() -> Unit> {
        hapticView.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
    }
    val currentCrossHaptic = rememberUpdatedState<() -> Unit> {
        hapticView.performHapticFeedback(android.view.HapticFeedbackConstants.CLOCK_TICK)
    }
    val currentMoveWindow = rememberUpdatedState<(Int, Int) -> Unit> { id, destination ->
        movedTmuxWindowOrder(orderedWindowIds, id, destination)?.let { expected ->
            pendingReveal = TmuxWindowRevealRequest(
                id = id,
                sourceOrder = orderedWindowIds,
                expectedOrder = expected,
                contextKey = reorderContextKey,
            )
        }
        onMoveWindow(id, destination)
    }
    TmuxWindowEdgeAutoScroll(
        state = rowReorder,
        scrollState = listScroll,
        edgePx = with(density) { 44.dp.toPx() },
        onCross = currentCrossHaptic.value,
    )

    Dialog(
        onDismissRequest = onDismiss,
        // The sheet paints edge to edge and insets itself, the way the app's
        // full-screen form does. Letting the dialog window inset instead leaves
        // a scrim band above a card that is meant to sit under the status bar.
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        Box(Modifier.fillMaxSize()) {
            // Tapping past the card dismisses. The card fills the dialog window
            // once it is told not to size itself, so the platform's own
            // outside-click never fires; this scrim is what replaces it. It is a
            // sibling rather than the card's parent so the card itself never
            // becomes a clickable node.
            Box(
                Modifier
                    .matchParentSize()
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onDismiss,
                    ),
            )
            Surface(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .imePadding()
                    .padding(horizontal = 12.dp, vertical = 10.dp)
                    .widthIn(max = 560.dp)
                    .testTag("session-switcher"),
                shape = RoundedCornerShape(16.dp),
                color = if (tokens.isLight) tokens.panelBg else tokens.inputBg,
                border = BorderStroke(1.dp, tokens.borderStrong),
            ) {
                Column {
                    TesseraSearchField(
                        value = query,
                        onValueChange = { query = it },
                        placeholder = "switch session, window or pane",
                        clearContentDescription = "Clear switcher search",
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                        inputTestTag = "session-switcher-query",
                    )
                    TesseraHairline()
                    if (notice != null && query.isBlank()) {
                        SwitcherNotice(notice, onNoticeAction, onNoticeDetails)
                        TesseraHairline()
                    }
                    Column(
                        modifier = Modifier
                            // Takes what the card has left after the query row,
                            // any notice, and the footer, and no more — so the
                            // counts stay on screen however long the list is.
                            .weight(1f, fill = false)
                            .verticalScroll(listScroll)
                            .tmuxWindowReorderGesture(
                                state = rowReorder,
                                order = currentWindowOrder,
                                enabled = currentReorderEnabled,
                                onMenu = currentMenuRequest,
                                onLift = currentLiftHaptic,
                                onCross = currentCrossHaptic,
                                onCommit = currentMoveWindow,
                            )
                            .onGloballyPositioned(rowReorder::reportContainer),
                    ) {
                        if (results.isEmpty) {
                            Text(
                                if (sessions.isEmpty() && windows.isEmpty()) {
                                    "no active sessions"
                                } else {
                                    "no matches"
                                },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 16.dp, vertical = 18.dp),
                                style = TesseraType.rowMeta,
                                color = tokens.fgMuted,
                            )
                        }
                        results.home.forEach {
                            SwitcherRow(
                                icon = TesseraIcons.Hosts,
                                title = "hosts home",
                                subtitle = "back to the tab bar · session keeps running",
                                isCurrent = false,
                                onClick = onHome,
                                modifier = Modifier.testTag("session-switcher-home"),
                            )
                            TesseraHairline(Modifier.padding(start = 44.dp))
                        }
                        if (results.tmux.isNotEmpty()) {
                            SwitcherSectionHeader("windows · $currentSessionTitle")
                        }
                        tmuxWindowGroups.forEach { group ->
                            val windowEntry = group.first() as SessionSwitcherEntry.Window
                            val window = windowEntry.window
                            val revealRequester = remember(window.id) { BringIntoViewRequester() }
                            LaunchedEffect(
                                pendingReveal,
                                orderedWindowIds,
                                tmuxMutationContextValid,
                                reorderContextKey,
                            ) {
                                val request = pendingReveal ?: return@LaunchedEffect
                                when (
                                    tmuxWindowRevealAction(
                                        request,
                                        orderedWindowIds,
                                        reorderContextKey,
                                        tmuxMutationContextValid,
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
                            Column(
                                Modifier
                                    .bringIntoViewRequester(revealRequester)
                                    .onGloballyPositioned { rowReorder.reportItem(window.id, it) }
                                    .graphicsLayer {
                                        translationY = rowReorder.offsetFor(window.id).y.toFloat()
                                        val scale = if (rowReorder.draggingId == window.id) 1.02f else 1f
                                        scaleX = scale
                                        scaleY = scale
                                    }
                                    .zIndex(if (rowReorder.draggingId == window.id) 1f else 0f)
                                    .then(
                                        if (rowReorder.draggingId == window.id) {
                                            Modifier.shadow(10.dp, RoundedCornerShape(10.dp))
                                        } else Modifier,
                                    ),
                            ) {
                                WindowRow(
                                    window = window,
                                    status = ProgramStatusQueries.windowStatus(programSessions, programHostId, window.id, programStatusAgents),
                                    cue = ProgramStatusQueries.windowCue(programSessions, programHostId, window.id, programStatusAgents),
                                    isCurrent = window.id == activeWindowId,
                                    unread = window.id in unreadWindowIds,
                                    glowing = window.id == glowingWindowId,
                                    allowsTmuxMutation = allowsTmuxMutation,
                                    orderedWindowIds = orderedWindowIds,
                                    menuRequested = menuWindowId == window.id,
                                    onMenuDismissed = { if (menuWindowId == window.id) menuWindowId = null },
                                    onMove = { action ->
                                        tmuxWindowMoveDestination(orderedWindowIds, window.id, action)
                                            ?.let { onMoveWindow(window.id, it) }
                                    },
                                    onTidy = onRenumberWindows,
                                    onSplitWindow = onSplitWindow?.takeIf { window.splitTargetReady }?.let { split ->
                                        { option -> split(window.id, option.vertical, option.before) }
                                    },
                                    onClick = { onSelectWindow(window.id) },
                                    onRename = { renameWindow = window },
                                    onClose = { closeWindow = window },
                                    onToggleZoom = {
                                        window.focusedPaneId(activeWindowId, activePaneId)
                                            ?.let { onSetPaneZoomed(it, !window.zoomed) }
                                    },
                                )
                                TesseraHairline(Modifier.padding(start = 44.dp))
                                group.drop(1).filterIsInstance<SessionSwitcherEntry.Pane>().forEach { entry ->
                                    PaneRow(
                                        window = entry.window,
                                        pane = entry.pane,
                                        status = ProgramStatusQueries.paneStatus(programSessions, programHostId, entry.pane.id, programStatusAgents),
                                        isCurrent = entry.window.id == activeWindowId &&
                                            entry.pane.id == activePaneId,
                                        allowsTmuxMutation = allowsTmuxMutation,
                                        onClick = { onSelectPane(entry.pane.id) },
                                        onSplit = { vertical -> onSplitPane(entry.pane.id, vertical) },
                                        onClose = { closePane = entry.pane.id },
                                    )
                                    TesseraHairline(Modifier.padding(start = 58.dp))
                                }
                            }
                        }
                        if (results.sessions.isNotEmpty()) {
                            SwitcherSectionHeader("sessions")
                        }
                        results.sessions.forEachIndexed { index, session ->
                            if (index > 0) TesseraHairline(Modifier.padding(start = 35.dp))
                            SessionRow(
                                session = session,
                                onClick = { onSelectSession(session.hostId) },
                            )
                        }
                        if (programDetails.isNotEmpty()) {
                            SwitcherSectionHeader(stringResource(R.string.program_status_programs))
                            programDetails.forEachIndexed { index, row ->
                                val name = programStatusText(ProgramStatusWordsModel.name(row.entry, row.location?.windowName))
                                val place = programStatusPlace(
                                    programSessions[programHostId]?.hostLabel.orEmpty(), row.entry.terminal, row.location)
                                val canOpen = !row.entry.isHistorical &&
                                    (row.entry.terminal == SharedProgramStatusTerminal.Raw || row.location != null)
                                SwitcherRow(
                                    icon = TesseraIcons.Sessions,
                                    title = if (row.entry.idPath.isEmpty()) name else "$name · ${row.entry.idPath.joinToString("/")}",
                                    subtitle = row.entry.app.orEmpty(),
                                    statusWords = programStatusLine(row.entry.copy(app = null)),
                                    subtitleTone = row.entry.attention?.tone,
                                    detail = if (canOpen) place else "$place · ${stringResource(R.string.program_status_pane_unavailable)}",
                                    message = row.entry.message,
                                    isCurrent = false,
                                    enabled = canOpen,
                                    onClick = {
                                        programStatusCenter?.openTerminal(programHostId, row.entry.terminal)
                                        onDismiss()
                                    },
                                    modifier = Modifier.testTag("program-status-detail-$index"),
                                )
                                TesseraHairline(Modifier.padding(start = 44.dp))
                            }
                        }
                    }
                    TesseraHairline()
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp)
                            .padding(start = 16.dp, end = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "${windows.size} windows · ${sessions.size} sessions",
                            modifier = Modifier.weight(1f),
                            style = TesseraType.rowMicro,
                            color = tokens.fgDim,
                            maxLines = 1,
                        )
                        if (allowsTmuxMutation && windows.isNotEmpty()) {
                            Box(
                                Modifier
                                    .heightIn(min = 44.dp)
                                    .clip(RoundedCornerShape(8.dp))
                                    .clickable(onClick = onRenumberWindows)
                                    .padding(horizontal = 10.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text("tidy numbers", style = TesseraType.rowMicro, color = tokens.fgMuted)
                            }
                        }
                        if (allowsTmuxMutation && windows.isNotEmpty()) {
                            TesseraIconButton(
                                icon = TesseraIcons.Plus,
                                contentDescription = "New tmux window",
                                onClick = onNewWindow,
                            )
                        }
                        TesseraIconButton(
                            icon = TesseraIcons.Close,
                            contentDescription = "Dismiss switcher",
                            onClick = onDismiss,
                        )
                    }
                }
            }
        }
    }

    renameWindow?.let { window ->
        TmuxRenameDialog(
            initial = window.renameSeed,
            onDismiss = { renameWindow = null },
            onConfirm = { name -> onRenameWindow(window.id, name); renameWindow = null },
        )
    }
    closeWindow?.let { window ->
        TmuxCloseDialog(
            title = "Close ${window.title}?",
            onDismiss = { closeWindow = null },
            onConfirm = { onCloseWindow(window.id); closeWindow = null },
        )
    }
    closePane?.let { paneId ->
        TmuxCloseDialog(
            title = "Close pane %$paneId?",
            onDismiss = { closePane = null },
            onConfirm = { onClosePane(paneId); closePane = null },
        )
    }
}

/**
 * The pane a verb on a window row acts on.
 *
 * Splitting and zooming are pane operations, but tmux only reports an active
 * pane for the window the client is attached to. For any other row the window's
 * own `activePaneId` — recorded by the server — is the target, which is where
 * tmux itself would put a new split.
 */
private fun SessionSwitcherWindow.focusedPaneId(
    activeWindowId: Int?,
    activePaneId: Int?,
): Int? = if (id == activeWindowId) {
    activePaneId ?: panes.firstOrNull()?.id
} else {
    panes.firstOrNull { it.id == activePaneId }?.id ?: panes.firstOrNull()?.id
}

@Composable
private fun SwitcherSectionHeader(title: String) {
    TesseraKicker(
        title,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 5.dp),
    )
}

@Composable
private fun SwitcherNotice(
    notice: SessionSwitcherNotice,
    onAction: () -> Unit,
    onDetails: (() -> Unit)?,
) {
    val tokens = LocalTesseraTokens.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (onDetails == null) Modifier
                else Modifier.clickable(onClickLabel = "Show details", onClick = onDetails)
            )
            .testTag("session-switcher-notice")
            .background(tokens.amber.copy(alpha = 0.06f))
            .padding(start = 16.dp, end = 10.dp, top = 10.dp, bottom = 10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                TesseraIcons.Alert,
                contentDescription = null,
                tint = tokens.amber,
                modifier = Modifier.size(15.dp),
            )
            Text(
                notice.title,
                modifier = Modifier.weight(1f).padding(start = 9.dp, end = 8.dp),
                style = TesseraType.rowMeta,
                color = tokens.fg,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            notice.actionLabel?.let { label ->
                Box(
                    modifier = Modifier
                        .heightIn(min = 40.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .clickable(onClick = onAction)
                        .background(tokens.amber.copy(alpha = 0.12f))
                        .padding(horizontal = 10.dp)
                        .testTag("session-switcher-notice-action"),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        label,
                        style = TesseraType.rowMicro,
                        color = tokens.amber,
                        maxLines = 1,
                    )
                }
            }
            if (onDetails != null) {
                Icon(
                    TesseraIcons.ChevronRight,
                    contentDescription = null,
                    tint = tokens.fgMuted,
                    modifier = Modifier.padding(start = 6.dp).size(14.dp),
                )
            }
        }
        Text(
            notice.message,
            style = TesseraType.rowMicro,
            color = tokens.fgDim,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun WindowRow(
    window: SessionSwitcherWindow,
    status: ProgramStatusStatusWords?,
    cue: ProgramWindowCue,
    isCurrent: Boolean,
    unread: Boolean,
    glowing: Boolean,
    allowsTmuxMutation: Boolean,
    orderedWindowIds: List<Int>,
    menuRequested: Boolean,
    onMenuDismissed: () -> Unit,
    onMove: (TmuxWindowMoveAction) -> Unit,
    onTidy: () -> Unit,
    onSplitWindow: ((TmuxWindowSplitOption) -> Unit)?,
    onClick: () -> Unit,
    onRename: () -> Unit,
    onClose: () -> Unit,
    onToggleZoom: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    val detail = when {
        // A reporting split names its program instead of the hint: "2 panes · cargo · working · 42%".
        window.panes.size > 1 && status != null -> pluralStringResource(R.plurals.program_status_pane_count, window.panes.size, window.panes.size)
        window.panes.size > 1 -> "${pluralStringResource(R.plurals.program_status_pane_count, window.panes.size, window.panes.size)} · each opens full-screen"
        else -> window.panes.firstOrNull()?.let { it.command ?: it.title } ?: "tmux window"
    }
    // A single pane already shows its command, so its words leave the app out.
    val statusText = status?.let { programStatusWordsLine(it.copy(app = null)) }
    val withStatus = listOfNotNull(detail, status?.app?.takeIf { window.panes.size > 1 && it.isNotEmpty() }).joinToString(" · ")
    val subtitle = if (window.index != null && window.index != window.position) {
        stringResource(R.string.tmux_window_index_detail, window.index, withStatus)
    } else withStatus
    // The current window is being looked at: only input requests tint it, as on tabs.
    val tone = cue.iconTone(isCurrent)
    val title = window.title.substringAfter(':', window.title)
    val accessibilityLabel = if (window.index != null && window.index != window.position)
        stringResource(R.string.tmux_window_index_label, window.position, title, window.index)
    else stringResource(R.string.tmux_window_label, window.position, title)
    val actions = if (!allowsTmuxMutation) emptyList() else TmuxWindowMoveAction.entries.mapNotNull { action ->
        tmuxWindowMoveDestination(orderedWindowIds, window.id, action) ?: return@mapNotNull null
        val label = when (action) {
            TmuxWindowMoveAction.PREVIOUS -> stringResource(R.string.tmux_move_up)
            TmuxWindowMoveAction.NEXT -> stringResource(R.string.tmux_move_down)
            TmuxWindowMoveAction.START -> stringResource(R.string.tmux_move_start)
            TmuxWindowMoveAction.END -> stringResource(R.string.tmux_move_end)
        }
        CustomAccessibilityAction(label) { onMove(action); true }
    }
    val splitActions = tmuxWindowSplitAccessibilityActions(onSplitWindow.takeIf { allowsTmuxMutation && window.panes.isNotEmpty() })
    SwitcherRow(
        icon = if (cue.hasAgent) TesseraIcons.Agents else if (window.panes.size > 1) TesseraIcons.SplitHorizontal else TesseraIcons.Sessions,
        title = window.title,
        subtitle = subtitle,
        statusWords = statusText,
        titleTone = cue.titleTone(isCurrent),
        iconTone = tone.takeIf { cue.hasAgent },
        subtitleTone = status?.tone?.takeIf { it == ProgramAttentionTone.NEEDS_INPUT || !isCurrent },
        accessibilityLabel = listOfNotNull(accessibilityLabel, status?.let { programStatusWordsLine(it) }).joinToString(", "),
        isCurrent = isCurrent,
        glowing = glowing,
        onClick = onClick,
        modifier = modifier
            .semantics {
                customActions = actions + splitActions
            }
            .testTag("tmux-window-${window.id}"),
        trailing = {
            if (tone != null || unread) {
                TesseraStatusDot(if (tone != null) programStatusToneColor(tone) else tokens.accent, size = 6.dp)
                Spacer(Modifier.width(6.dp))
            }
            SwitcherRowMenu(
                contentDescription = "Actions for ${window.title}",
                enabled = allowsTmuxMutation,
                openRequest = menuRequested,
                onDismiss = onMenuDismissed,
            ) { dismiss ->
                DropdownMenuItem(
                    text = { Text("switch to") },
                    onClick = { dismiss(); onClick() },
                )
                DropdownMenuItem(
                    text = { Text("rename") },
                    onClick = { dismiss(); onRename() },
                )
                TmuxWindowMoveAction.entries.forEach { action ->
                    val destination = tmuxWindowMoveDestination(orderedWindowIds, window.id, action)
                    val label = when (action) {
                        TmuxWindowMoveAction.PREVIOUS -> stringResource(R.string.tmux_move_up)
                        TmuxWindowMoveAction.NEXT -> stringResource(R.string.tmux_move_down)
                        TmuxWindowMoveAction.START -> stringResource(R.string.tmux_move_start)
                        TmuxWindowMoveAction.END -> stringResource(R.string.tmux_move_end)
                    }
                    DropdownMenuItem(
                        text = { Text(label) },
                        enabled = destination != null,
                        onClick = { dismiss(); onMove(action) },
                    )
                }
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.tmux_tidy)) },
                    enabled = orderedWindowIds.isNotEmpty(),
                    onClick = { dismiss(); onTidy() },
                )
                if (onSplitWindow != null && window.panes.isNotEmpty()) {
                    TmuxWindowSplitMenuItems { option -> dismiss(); onSplitWindow(option) }
                }
                if (window.panes.size > 1) {
                    DropdownMenuItem(
                        text = { Text(if (window.zoomed) "unzoom pane" else "zoom pane") },
                        onClick = { dismiss(); onToggleZoom() },
                    )
                }
                DropdownMenuItem(
                    text = { Text("close window", color = tokens.red) },
                    onClick = { dismiss(); onClose() },
                )
            }
        },
    )
}

@Composable
private fun PaneRow(
    window: SessionSwitcherWindow,
    pane: SessionSwitcherPane,
    status: ProgramStatusStatusWords?,
    isCurrent: Boolean,
    allowsTmuxMutation: Boolean,
    onClick: () -> Unit,
    onSplit: (Boolean) -> Unit,
    onClose: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    val words = status?.let { programStatusWordsLine(it.copy(app = null)) }
    val tone = status?.tone?.takeIf { it == ProgramAttentionTone.NEEDS_INPUT || !isCurrent }
    SwitcherRow(
        icon = null,
        title = pane.title,
        subtitle = "%${pane.id} · ${status?.app ?: pane.command ?: window.title}",
        statusWords = words,
        subtitleTone = tone,
        isCurrent = isCurrent,
        indented = true,
        onClick = onClick,
        modifier = Modifier.testTag("tmux-pane-${pane.id}"),
        trailing = {
            tone?.let {
                TesseraStatusDot(programStatusToneColor(it), size = 6.dp)
                Spacer(Modifier.width(6.dp))
            }
            SwitcherRowMenu(
                contentDescription = "Actions for pane %${pane.id}",
                enabled = allowsTmuxMutation,
            ) { dismiss ->
                DropdownMenuItem(
                    text = { Text("switch to") },
                    onClick = { dismiss(); onClick() },
                )
                DropdownMenuItem(
                    text = { Text("split left / right") },
                    onClick = { dismiss(); onSplit(false) },
                )
                DropdownMenuItem(
                    text = { Text("split top / bottom") },
                    onClick = { dismiss(); onSplit(true) },
                )
                if (window.panes.size > 1) {
                    DropdownMenuItem(
                        text = { Text("close pane", color = tokens.red) },
                        onClick = { dismiss(); onClose() },
                    )
                }
            }
        },
    )
}

@Composable
private fun SessionRow(session: SessionSwitcherSession, onClick: () -> Unit) {
    val tokens = LocalTesseraTokens.current
    val tone = when (session.status) {
        SessionSwitcherStatus.CONNECTED -> tokens.green
        SessionSwitcherStatus.PENDING -> tokens.amber
        SessionSwitcherStatus.FAILED -> tokens.red
        SessionSwitcherStatus.IDLE -> tokens.fgDim
    }
    val counts = session.programAttention?.takeIf { it.total > 0 }
    val summary = counts?.let { programStatusCountSummary(it, specificKinds = true) }
    val subtitle = listOfNotNull(
        session.endpoint,
        session.paneTitle?.takeIf { it.isNotBlank() },
    ).joinToString(" · ")
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .background(if (session.isCurrent) tokens.accentSoft else Color.Transparent)
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) {
                selected = session.isCurrent
                contentDescription = listOfNotNull(session.title, subtitle, summary).joinToString(", ")
            }
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 8.dp)
            .testTag("session-switcher-session-${session.hostId}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TesseraStatusDot(tone, size = 7.dp)
        Column(Modifier.weight(1f).padding(start = 12.dp)) {
            Text(
                session.title,
                style = TesseraType.rowMeta,
                color = tokens.fg,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
            Text(
                subtitle,
                style = TesseraType.rowMicro,
                color = tokens.fgDim,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
            if (summary != null && counts != null) {
                Text(programStatusCountLine(counts), style = TesseraType.rowMicro,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.testTag("session-switcher-program-attention"))
            }
        }
        if (session.unread) {
            Spacer(Modifier.width(8.dp))
            TesseraStatusDot(tokens.accent, size = 6.dp)
        }
        if (session.isCurrent) {
            Spacer(Modifier.width(8.dp))
            // The row already announces itself as selected; the glyph is the
            // sighted half of that and would otherwise be read as "black circle".
            Text(
                "●",
                modifier = Modifier.clearAndSetSemantics {},
                style = TesseraType.rowMicro,
                color = tokens.green,
            )
        }
    }
}

/**
 * One navigation row: glyph, two lines, and whatever the caller pins to the
 * trailing edge. The current target carries the accent wash and a filled dot,
 * so the row the user is already on is never mistaken for a destination.
 */
@Composable
private fun SwitcherRow(
    icon: ImageVector?,
    title: String,
    subtitle: String,
    isCurrent: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    indented: Boolean = false,
    glowing: Boolean = false,
    subtitleTone: ProgramAttentionTone? = null,
    titleTone: ProgramAttentionTone? = null,
    iconTone: ProgramAttentionTone? = null,
    statusWords: String? = null,
    detail: String? = null,
    message: String? = null,
    accessibilityLabel: String? = null,
    enabled: Boolean = true,
    trailing: (@Composable () -> Unit)? = null,
) {
    val tokens = LocalTesseraTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .background(if (isCurrent || glowing) tokens.accentSoft else Color.Transparent)
            .clickable(enabled = enabled, onClick = onClick)
            .semantics(mergeDescendants = true) {
                selected = isCurrent
                contentDescription = accessibilityLabel ?: listOfNotNull(title, subtitle, statusWords, message, detail).joinToString(", ")
            }
            .padding(start = if (indented) 30.dp else 16.dp, end = if (trailing == null) 16.dp else 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
            when {
                indented -> Text(
                    "↳",
                    modifier = Modifier.clearAndSetSemantics {},
                    style = TesseraType.rowMeta,
                    color = tokens.fgDim,
                )
                icon != null -> Icon(
                    icon,
                    contentDescription = null,
                    tint = if (iconTone != null) programStatusToneColor(iconTone) else tokens.fgMuted,
                    modifier = Modifier.size(15.dp),
                )
            }
        }
        Column(Modifier.weight(1f).padding(start = 12.dp, top = 8.dp, bottom = 8.dp)) {
            Text(
                title,
                style = TesseraType.rowMeta,
                color = if (titleTone != null) programStatusToneColor(titleTone) else tokens.fg,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                if (subtitle.isNotEmpty()) Text(
                    subtitle,
                    style = TesseraType.rowMicro,
                    color = if (statusWords != null) tokens.fgDim else programStatusToneColor(subtitleTone),
                    maxLines = 1,
                    overflow = TextOverflow.MiddleEllipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                statusWords?.let {
                    if (subtitle.isNotEmpty()) Text("·", style = TesseraType.rowMicro, color = tokens.fgDim)
                    Text(it, style = TesseraType.rowMicro, color = programStatusToneColor(subtitleTone))
                }
            }
            message?.takeIf { it.isNotEmpty() }?.let {
                Text(it, color = tokens.fgMuted, modifier = Modifier.padding(top = 2.dp))
            }
            detail?.let {
                Text(it, style = TesseraType.rowMicro, color = tokens.fgDim,
                    maxLines = 2, overflow = TextOverflow.MiddleEllipsis)
            }
        }
        if (isCurrent) {
            Text(
                "●",
                modifier = Modifier.padding(start = 6.dp).clearAndSetSemantics {},
                style = TesseraType.rowMicro,
                color = tokens.green,
            )
        }
        trailing?.invoke()
    }
}

/**
 * The trailing per-row verb menu, matching the Hosts list's own row menu rather
 * than iOS's long press: a hidden gesture is the wrong place to keep the only
 * way to rename or close a window.
 */
@Composable
private fun SwitcherRowMenu(
    contentDescription: String,
    enabled: Boolean,
    openRequest: Boolean = false,
    onDismiss: () -> Unit = {},
    items: @Composable (dismiss: () -> Unit) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    LaunchedEffect(openRequest, enabled) { if (openRequest && enabled) open = true }
    fun dismiss() {
        open = false
        onDismiss()
    }
    Box {
        TesseraIconButton(
            icon = TesseraIcons.MoreVertical,
            contentDescription = contentDescription,
            onClick = { open = true },
            enabled = enabled,
        )
        DropdownMenu(expanded = open && enabled, onDismissRequest = ::dismiss) {
            items(::dismiss)
        }
    }
}
