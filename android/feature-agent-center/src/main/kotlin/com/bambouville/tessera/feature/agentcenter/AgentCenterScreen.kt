package com.bambouville.tessera.feature.agentcenter

import androidx.compose.ui.res.stringResource
import android.Manifest
import android.content.res.Configuration
import com.bambouville.tessera.core.bridge.SharedAgentReadStatus
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.Icon
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.ensureActive
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraEmptyState
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraPageHeader
import com.bambouville.tessera.design.TesseraSearchField
import com.bambouville.tessera.design.TesseraSegmented
import com.bambouville.tessera.design.TesseraStatusDot
import com.bambouville.tessera.design.TesseraSubPageHeader
import com.bambouville.tessera.design.TesseraTextField
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.markdown.TesseraMarkdownText
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest

/** Both 16dp row gutters. */
private const val AGENT_ROW_HORIZONTAL_PADDING_DP = 32f
/** Average advance of `rowTitle` in the bundled face, near enough for a clip budget. */
private const val AGENT_ROW_TITLE_GLYPH_DP = 7.4f

/** Clear only the exact draft accepted in Core's asynchronous ActionPlan. */
internal fun draftAfterActionPlan(draft: String, acceptedText: String): String = if (draft == acceptedText) "" else draft

/**
 * Shared phone/tablet composition. Width chooses split layout; it does not make
 * a device-idiom assumption, so split windows and large accessibility font sizes
 * retain the phone list-to-detail route.
 */
@Composable
fun AgentCenterScreen(
    presenter: AgentCenterPresenter,
    onOpenTerminal: (AgentThreadDetail) -> Unit,
    modifier: Modifier = Modifier,
    /** Wired by the app only once it has a generation-safe launch executor. */
    onLaunchRequested: ((AgentLaunchRequest) -> Unit)? = null,
    /** Candidates have no conversation authority; this only reveals their host terminal. */
    onOpenCandidateTerminal: (AgentTerminalCandidate) -> Unit = {},
    captureProtectionEnabled: Boolean = true,
) {
    val state by presenter.state.collectAsState()
    AgentCenterWindowPrivacy(enabled = captureProtectionEnabled)
    val context = LocalContext.current
    val speech = remember(context) { AndroidAgentSpeechAdapter(context) }
    val draftKey = state.selectedThreadKey.orEmpty()
    val draft = state.drafts[draftKey].orEmpty()
    val setDraft: (String) -> Unit = { presenter.setDraft(draftKey, it) }
    val openAttachmentPicker = rememberAgentAttachmentPicker(presenter::completeAttachmentSelection)
    val openPhotoPicker = rememberAgentPhotoPicker(presenter::completeAttachmentSelection)
    var pendingSpeech by remember { mutableStateOf<(() -> Unit)?>(null) }
    val microphonePermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) pendingSpeech?.invoke()
        pendingSpeech = null
    }
    val startSpeech = {
        val originKey = draftKey
        val acceptDraft: (String) -> Unit = { spoken ->
            presenter.appendDraft(originKey, spoken)
        }
        speech.start(onDraft = acceptDraft, requestPermission = {
            pendingSpeech = { speech.start(onDraft = acceptDraft, requestPermission = {}) }
            microphonePermission.launch(Manifest.permission.RECORD_AUDIO)
        })
    }
    var launchKind by remember { mutableStateOf<AgentLaunchKind?>(null) }
    var compactDetail by remember { mutableStateOf(false) }
    val searchFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) { presenter.activate() }

    BoxWithConstraints(modifier.fillMaxSize().onKeyEvent { event ->
        if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
        val command = event.isCtrlPressed || event.isMetaPressed
        val selected = state.detail ?: state.projectedDetails[state.selectedThreadKey]
        when {
            command && event.key == Key.N -> {
                // The sheet remains capability-gated; this shortcut never
                // fabricates a launch target for a list-only summary.
                if (selected?.row?.spawnAvailable == true && selected.launchTargetOrNull() != null) {
                    launchKind = AgentLaunchKind.Spawn
                    true
                } else false
            }
            command && event.key == Key.F -> {
                // A phone detail route does not compose its list search field;
                // do not request focus from an unattached FocusRequester.
                if (!compactDetail) {
                    searchFocus.requestFocus()
                    true
                } else false
            }
            command && event.key == Key.Enter -> selected?.let { onOpenTerminal(it); true } ?: false
            event.key.promptOptionIndexOrNull() != null -> {
                val detail = selected ?: return@onKeyEvent false
                val prompt = detail.prompt ?: return@onKeyEvent false
                val option = prompt.options.getOrNull(event.key.promptOptionIndexOrNull()!!) ?: return@onKeyEvent false
                if (detail.row.key in state.actionThreads) Unit
                else if (detail.canAnswerPrompt() && !option.acceptsText)
                    presenter.requestPromptAnswer(detail, prompt, AgentPromptAnswerChoice.Option(option.id))
                else if (!detail.canAnswerPrompt()) onOpenTerminal(detail)
                true
            }
            // Escape is intentionally only an interrupt shortcut with a clear
            // detail/action context and no unsent composer text to lose.
            event.key == Key.Escape && draft.isBlank() && selected?.row?.actionAvailable == true -> {
                presenter.requestAction(selected, "interrupt")
            }
            else -> false
        }
    }) {
        // 300dp list + a usable detail reading width. At larger font scale Compose
        // reports less effective width and naturally falls into the compact route.
        val expanded = maxWidth >= 760.dp
        val visibleThreadKey = state.selectedThreadKey.takeIf { expanded || compactDetail }
        DisposableEffect(visibleThreadKey) {
            presenter.setOpenDetail(visibleThreadKey)
            onDispose { presenter.setOpenDetail(null) }
        }
        LaunchedEffect(visibleThreadKey) {
            val threadKey = visibleThreadKey ?: return@LaunchedEffect
            while (true) {
                presenter.refreshVisibleTranscript(threadKey)
                kotlinx.coroutines.delay(3_000)
            }
        }
        val selected = state.detail ?: state.projectedDetails[state.selectedThreadKey] ?: state.threads.firstOrNull { it.key == state.selectedThreadKey }?.let {
            AgentThreadDetail(it, emptyList(), emptyList(), emptyList(), null, false)
        }
        if (expanded) {
            Row(Modifier.fillMaxSize()) {
                AgentListPane(
                    state = state,
                    onSearch = presenter::search,
                    onSelect = presenter::select,
                    onGroupingChange = presenter::setGrouping,
                    onSpawn = { launchKind = AgentLaunchKind.Spawn },
                    onPromptAnswer = presenter::requestPromptAnswer,
                    onCandidatePromptAnswer = presenter::requestCandidatePromptAnswer,
                    onOpenTerminal = onOpenTerminal,
                    onOpenCandidateTerminal = onOpenCandidateTerminal,
                    searchFocus = searchFocus,
                    onTitleWidthChange = presenter::setTitleCharacterBudget,
                    onCardVisibility = presenter::setCardVisible,
                    modifier = Modifier.widthIn(min = 300.dp, max = 360.dp).fillMaxHeight(),
                )
                TesseraHairline(Modifier.width(1.dp).fillMaxHeight())
                AgentDetailPane(
                    detail = selected,
                    draft = draft,
                    onDraftChange = setDraft,
                    onSend = { selected?.let { detail ->
                        presenter.requestAction(detail, "send", draft)
                    } },
                    onInterrupt = { selected?.let { presenter.requestAction(it, "interrupt") } },
                    onPromptAnswer = { prompt, option -> selected?.let { presenter.requestPromptAnswer(it, prompt, option) } },
                    onNewestVisible = { recordID -> selected?.let { presenter.acknowledge(it.row.key, recordID) } },
                    onCompletionVisible = { selected?.let { presenter.acknowledgeCompletion(it.row.key) } },
                    onLoadNewer = { selected?.let { presenter.loadNewer(it.row.key) } },
                    onReturnToLatest = { selected?.let { presenter.loadNewer(it.row.key, latest = true) } },
                    onViewportAnchor = { recordID -> selected?.let { presenter.viewportAnchor(it.row.key, recordID) } },
                    onLoadMore = { selected?.let { presenter.loadMore(it.row.key) } },
                    onFillHistory = { selected?.let { presenter.fillHistory(it.row.key) } },
                    onRetainBridgedRows = { selected?.let { presenter.retainBridgedRows(it.row.key) } },
                    onOpenTerminal = { selected?.let(onOpenTerminal) },
                    onFork = { launchKind = AgentLaunchKind.Fork },
                    onStartSpeech = startSpeech,
                    speechAvailable = speech.isAvailable,
                    onAttach = { selected?.let { if (presenter.beginAttachmentSelection(it)) openAttachmentPicker() } },
                    onAttachPhoto = { selected?.let { if (presenter.beginAttachmentSelection(it)) openPhotoPicker() } },
                    onQueue = { selected?.let { presenter.requestAction(it, "queue", draft) } },
                    sending = draftKey in state.sendingThreads,
                    promptActionPending = draftKey in state.actionThreads,
                    uploading = draftKey in state.uploadingThreads,
                    loadingTranscript = draftKey in state.loadingTranscriptThreads,
                    capacityLimited = draftKey in state.ingestionCapacityThreads,
                    readStatus = state.ingestionReadStatuses[draftKey],
                    modifier = Modifier.weight(1f),
                )
            }
        } else if (compactDetail && selected != null) {
            AgentDetailPane(
                detail = selected,
                draft = draft,
                onDraftChange = setDraft,
                onSend = {
                    presenter.requestAction(selected, "send", draft)
                },
                onInterrupt = { presenter.requestAction(selected, "interrupt") },
                onPromptAnswer = { prompt, option -> presenter.requestPromptAnswer(selected, prompt, option) },
                onNewestVisible = { recordID -> presenter.acknowledge(selected.row.key, recordID) },
                onCompletionVisible = { presenter.acknowledgeCompletion(selected.row.key) },
                onLoadNewer = { presenter.loadNewer(selected.row.key) },
                onReturnToLatest = { presenter.loadNewer(selected.row.key, latest = true) },
                onViewportAnchor = { presenter.viewportAnchor(selected.row.key, it) },
                onLoadMore = { presenter.loadMore(selected.row.key) },
                onFillHistory = { presenter.fillHistory(selected.row.key) },
                onRetainBridgedRows = { presenter.retainBridgedRows(selected.row.key) },
                onOpenTerminal = { onOpenTerminal(selected) },
                onFork = { launchKind = AgentLaunchKind.Fork },
                onStartSpeech = startSpeech,
                    speechAvailable = speech.isAvailable,
                onAttach = { if (presenter.beginAttachmentSelection(selected)) openAttachmentPicker() },
                onAttachPhoto = { if (presenter.beginAttachmentSelection(selected)) openPhotoPicker() },
                onQueue = { presenter.requestAction(selected, "queue", draft) },
                sending = draftKey in state.sendingThreads,
                promptActionPending = draftKey in state.actionThreads,
                uploading = draftKey in state.uploadingThreads,
                loadingTranscript = draftKey in state.loadingTranscriptThreads,
                capacityLimited = draftKey in state.ingestionCapacityThreads,
                readStatus = state.ingestionReadStatuses[draftKey],
                onBack = { compactDetail = false },
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            AgentListPane(
                state = state,
                onSearch = presenter::search,
                onSelect = { key -> presenter.select(key); compactDetail = true },
                onGroupingChange = presenter::setGrouping,
                onSpawn = { launchKind = AgentLaunchKind.Spawn },
                onPromptAnswer = presenter::requestPromptAnswer,
                onCandidatePromptAnswer = presenter::requestCandidatePromptAnswer,
                onOpenTerminal = onOpenTerminal,
                onOpenCandidateTerminal = onOpenCandidateTerminal,
                searchFocus = searchFocus,
                onTitleWidthChange = presenter::setTitleCharacterBudget,
                onCardVisibility = presenter::setCardVisible,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
    state.notice?.let { notice ->
        AgentNoticeDialog(notice, presenter::clearNotice,
            onSendAnyway = if (state.sendAnywayNotice == notice) ({ presenter.sendAnyway(); Unit }) else null,
            captureProtectionEnabled = captureProtectionEnabled)
    }
    launchKind?.let { kind ->
        AgentSpawnSheet(
            kind = kind,
            captureProtectionEnabled = captureProtectionEnabled,
            onDismiss = { launchKind = null },
            selected = state.detail ?: state.projectedDetails[state.selectedThreadKey],
            onLaunchRequested = onLaunchRequested,
        )
    }
}

/** The one-shot retry is offered only for a settled refusal before any input. */
@Composable
internal fun AgentNoticeDialog(
    notice: String,
    onDismiss: () -> Unit,
    onSendAnyway: (() -> Unit)? = null,
    captureProtectionEnabled: Boolean = false,
) {
    AlertDialog(
        properties = androidx.compose.ui.window.DialogProperties(securePolicy = if (captureProtectionEnabled)
            androidx.compose.ui.window.SecureFlagPolicy.SecureOn else androidx.compose.ui.window.SecureFlagPolicy.Inherit),
        onDismissRequest = onDismiss,
        title = { Text("agents", style = TesseraType.sheet) },
        text = { Text(notice, style = TesseraType.body) },
        confirmButton = { TesseraButton("ok", onDismiss, compact = true) },
        dismissButton = onSendAnyway?.let { send -> { TesseraButton("Send anyway", send, compact = true) } },
    )
}

@Composable
internal fun AgentListPane(
    state: AgentCenterUiState,
    onSearch: (String) -> Unit,
    onSelect: (String) -> Unit,
    onGroupingChange: (String) -> Unit,
    onSpawn: () -> Unit,
    modifier: Modifier,
    searchFocus: FocusRequester = FocusRequester(),
    onPromptAnswer: (AgentThreadDetail, AgentPrompt, AgentPromptAnswerChoice) -> Unit = { _, _, _ -> },
    onCandidatePromptAnswer: (AgentTerminalCandidate, AgentPrompt, AgentPromptOption) -> Unit = { _, _, _ -> },
    onOpenTerminal: (AgentThreadDetail) -> Unit = {},
    onOpenCandidateTerminal: (AgentTerminalCandidate) -> Unit = {},
    /**
     * How many characters of an opening prompt this pane can show in a row
     * title. Shared Core owns the clipping so both platforms agree on it; this
     * screen only knows how wide it is.
     */
    onTitleWidthChange: (Int) -> Unit = {},
    onCardVisibility: (String, Boolean) -> Unit = { _, _ -> },
) {
    val tokens = LocalTesseraTokens.current
    // A list row's capability is not enough to launch: this sheet needs the
    // exact currently bound tmux target.  Do not open a misleading blank sheet.
    val selectedDetail = state.detail ?: state.projectedDetails[state.selectedThreadKey]
    val spawnAvailable = selectedDetail?.let { it.row.spawnAvailable && it.launchTargetOrNull() != null } == true
    val density = LocalDensity.current
    Column(
        modifier.background(tokens.bg).onSizeChanged { size ->
            // A row title is one line of `rowTitle` between the 16dp gutters.
            // Estimating from the average glyph advance is deliberate: the
            // exact answer needs a text measurer per row, and this only picks
            // how much of a prompt to keep, which the reader can always widen.
            val available = with(density) { size.width.toDp().value } - AGENT_ROW_HORIZONTAL_PADDING_DP
            if (available > 0f) onTitleWidthChange((available / AGENT_ROW_TITLE_GLYPH_DP).toInt())
        },
    ) {
        TesseraPageHeader("agents", trailing = {
            TesseraIconButton(TesseraIcons.Plus, "spawn agent", onSpawn, enabled = spawnAvailable)
        })
        TesseraSearchField(
            value = state.searchQuery,
            onValueChange = onSearch,
            placeholder = "search agents",
            clearContentDescription = "clear agent search",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            inputModifier = Modifier.focusRequester(searchFocus),
            inputTestTag = "agent-search",
        )
        TesseraSegmented(
            options = AGENT_GROUPINGS,
            selectedIndex = AGENT_GROUPINGS.indexOf(state.grouping).coerceAtLeast(0),
            onSelect = { index -> onGroupingChange(AGENT_GROUPINGS[index]) },
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp).testTag("agent-grouping"),
        )
        // On a compact device this remains visible after navigating back from
        // the detail route: answering does not require a second drill-in.
        if (state.searchQuery.isNotBlank() && state.unavailableSearchHostCount > 0) {
            Text(
                "${state.unavailableSearchHostCount} connected host${if (state.unavailableSearchHostCount == 1) "" else "s"} unavailable",
                Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                style = TesseraType.rowMicro,
                color = tokens.fgMuted,
            )
        }
        when {
            state.loading -> Text("loading agent center…", Modifier.padding(20.dp), style = TesseraType.body, color = tokens.fgMuted)
            state.unavailableReason != null -> TesseraEmptyState("agents unavailable", state.unavailableReason, modifier = Modifier.fillMaxSize(), icon = TesseraIcons.Sessions)
            state.searchQuery.isNotBlank() && state.searchResults.isEmpty() -> TesseraEmptyState("no transcript matches", "Available connected-host transcripts did not contain this query.", modifier = Modifier.fillMaxSize(), icon = TesseraIcons.Sessions)
            state.searchQuery.isNotBlank() -> LazyColumn(Modifier.fillMaxSize()) {
                items(state.searchResults, key = { "${it.threadKey}:${it.recordID}" }) { result ->
                    Column(
                        Modifier.fillMaxWidth().clickable(role = Role.Button) { onSelect(result.threadKey) }
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                    ) {
                        Text(state.threads.firstOrNull { it.key == result.threadKey }?.title ?: "agent thread", style = TesseraType.rowTitle, color = tokens.fg)
                        Text(result.excerpt, Modifier.padding(top = 4.dp), style = TesseraType.bodySmall, color = tokens.fgMuted, maxLines = 4, overflow = TextOverflow.Ellipsis)
                    }
                    TesseraHairline()
                }
            }
            state.threads.isEmpty() && state.candidates.isEmpty() -> TesseraEmptyState("no live agents", "Connect an SSH, SSH+tmux, Mosh, or Mosh+tmux session with an available agent integration.", modifier = Modifier.fillMaxSize(), icon = TesseraIcons.Sessions)
            else -> LazyColumn(Modifier.fillMaxSize().onKeyEvent { event ->
                if (event.type == KeyEventType.KeyDown && (event.key == Key.DirectionDown || event.key == Key.DirectionUp)) {
                    val current = state.threads.indexOfFirst { it.key == state.selectedThreadKey }.coerceAtLeast(0)
                    val target = (current + if (event.key == Key.DirectionDown) 1 else -1).coerceIn(0, state.threads.lastIndex)
                    onSelect(state.threads[target].key); true
                } else false
            }) {
                if (state.candidates.isNotEmpty()) {
                    item { Text("live terminals", Modifier.fillMaxWidth().padding(start = 16.dp, top = 12.dp, bottom = 5.dp), style = TesseraType.rowMicro, color = tokens.fgDim) }
                    items(state.candidates, key = { it.key }) { candidate ->
                        AgentCandidateRow(candidate, onOpenCandidateTerminal, onCandidatePromptAnswer)
                        TesseraHairline()
                    }
                }
                itemsIndexed(state.threads, key = { _, row -> row.key }) { index, row ->
                    DisposableEffect(row.key) {
                        onCardVisibility(row.key, true)
                        onDispose { onCardVisibility(row.key, false) }
                    }
                    val group = row.groupLabel(state.grouping)
                    if (index == 0 || state.threads[index - 1].groupLabel(state.grouping) != group) {
                        Text(
                            group,
                            Modifier.fillMaxWidth().padding(start = 16.dp, top = 12.dp, bottom = 5.dp),
                            style = TesseraType.rowMicro,
                            color = if (state.grouping == "attention" && row.attention == "needsYou") tokens.amber else tokens.fgDim,
                        )
                    }
                    AgentThreadRow(row, selected = row.key == state.selectedThreadKey, onClick = { onSelect(row.key) })
                    // Projection data is snapshot-derived and ephemeral. This
                    // keeps a phone's urgent action at zero drill-down depth
                    // without guessing a prompt from the row summary.
                    state.projectedDetails[row.key]
                        ?.takeIf { it.row.attention == "needsYou" }
                        ?.prompt
                        ?.let { prompt ->
                            val detail = state.projectedDetails.getValue(row.key)
                            AgentUrgentPrompt(
                                prompt = prompt,
                                actionAvailable = detail.canAnswerPrompt(),
                                pending = row.key in state.actionThreads,
                                onAnswer = { answer -> onPromptAnswer(detail, prompt, answer) },
                                onOpenTerminal = { onOpenTerminal(detail) },
                            )
                        }
                    TesseraHairline()
                }
            }
        }
    }
}

/** An unproven live terminal is deliberately terminal-only: no transcript or action authority is invented. */
@Composable
private fun AgentCandidateRow(
    candidate: AgentTerminalCandidate,
    onOpenTerminal: (AgentTerminalCandidate) -> Unit,
    onPromptAnswer: (AgentTerminalCandidate, AgentPrompt, AgentPromptOption) -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TesseraStatusDot(if (candidate.status == "waitingForInput") tokens.amber else tokens.fgFaint, size = 7.dp)
            Text(candidate.title, Modifier.padding(start = 10.dp).weight(1f), style = TesseraType.rowTitle, color = tokens.fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
            TesseraButton("open terminal", { onOpenTerminal(candidate) }, compact = true)
        }
        Text(listOf(candidate.provider, candidate.host, candidate.location).filter(String::isNotBlank).joinToString(" · "), Modifier.padding(start = 17.dp, top = 4.dp), style = TesseraType.rowMeta, color = tokens.fgMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text("Transcript identity unavailable; review in terminal.", Modifier.padding(start = 17.dp, top = 3.dp), style = TesseraType.rowMicro, color = tokens.fgDim)
        candidate.prompt?.let { prompt ->
            Text(prompt.title, Modifier.padding(start = 17.dp, top = 8.dp), style = TesseraType.bodySmall, color = tokens.fg)
            if (candidate.canAnswerPrompt()) {
                prompt.options.forEach { option ->
                    TesseraButton(
                        option.label,
                        { onPromptAnswer(candidate, prompt, option) },
                        style = if (option.isDefault) TesseraButtonStyle.Primary else TesseraButtonStyle.Default,
                        compact = true,
                        modifier = Modifier.padding(start = 17.dp, top = 5.dp),
                    )
                }
            } else {
                TesseraButton("Open terminal to answer", { onOpenTerminal(candidate) }, compact = true, modifier = Modifier.padding(start = 17.dp, top = 5.dp))
            }
        }
        if (candidate.liveTail.isNotBlank()) Text(candidate.liveTail, Modifier.padding(start = 17.dp, top = 5.dp), style = TesseraType.bodySmall, color = tokens.fgMuted, maxLines = 3, overflow = TextOverflow.Ellipsis)
    }
}

/** Same capability rule as iOS: fallback text alone never authorizes an answer. */
internal fun AgentTerminalCandidate.canAnswerPrompt(): Boolean =
    prompt != null && (binding?.number("capabilities")?.toIntOrNull()?.and(8) == 8) &&
        (binding.number("agentPID")?.toIntOrNull() ?: -1) > 1

@Composable
private fun AgentThreadRow(row: AgentThreadRow, selected: Boolean, onClick: () -> Unit) {
    val tokens = LocalTesseraTokens.current
    Row(
        Modifier.fillMaxWidth().semantics {
            contentDescription = listOfNotNull(
                row.title,
                row.provider,
                row.permissionMode,
                row.host.takeIf { it.isNotBlank() }?.let { "host $it" },
                row.status.replaceFirstChar(Char::uppercase),
                row.queuedCount?.let { "$it queued" },
                if (row.isFork) "fork" else null,
                row.attention.takeIf { it == "needsYou" }?.let { "needs your attention" },
            ).joinToString(", ")
        }.clickable(role = Role.Button, onClick = onClick)
            .background(if (selected) tokens.accentSoft else tokens.bg).padding(horizontal = 16.dp, vertical = 13.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        AgentStatusDot(row)
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(row.title, Modifier.weight(1f), style = TesseraType.rowTitle, color = tokens.fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (row.attention == "needsYou") Text("needs you", style = TesseraType.rowMicro, color = tokens.amber)
                row.lastActivityMillis?.let { lastActivity ->
                    Text(
                        agentRelativeTime(lastActivity),
                        Modifier.padding(start = 6.dp).testTag("agent-thread-last-activity"),
                        style = TesseraType.rowMicro,
                        color = tokens.fgDim,
                    )
                }
            }
            Text(listOfNotNull(row.provider, row.model, row.permissionMode, row.status.takeIf { it.isNotBlank() }).joinToString(" · "), style = TesseraType.rowMeta, color = tokens.fgMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            row.queuedCount?.takeIf { it != "0" }?.let { Text("$it queued", Modifier.padding(top = 2.dp), style = TesseraType.rowMicro, color = tokens.fgDim) }
            row.preview?.let { Text(it, Modifier.padding(top = 3.dp), style = TesseraType.bodySmall, color = tokens.fgMuted, maxLines = 2, overflow = TextOverflow.Ellipsis) }
            row.summaryMeter(row.tokenMeterText())?.let { Text(it, Modifier.padding(top = 3.dp), style = TesseraType.rowMicro, color = tokens.fgDim, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            if (row.host.isNotBlank()) {
                val host = row.host
                Text(listOf(host, row.location).filter(String::isNotBlank).joinToString(" · "), Modifier.padding(top = 3.dp), style = TesseraType.rowMicro, color = tokens.fgDim, maxLines = 1, overflow = TextOverflow.Ellipsis)
            } else if (row.location.isNotBlank()) {
                Text(row.location, Modifier.padding(top = 3.dp), style = TesseraType.rowMicro, color = tokens.fgDim, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

private val AGENT_GROUPINGS = listOf("attention", "host")

/** Headers merely expose the contiguous shared-runtime order; Android never re-sorts rows. */
private fun AgentThreadRow.groupLabel(grouping: String): String = when (grouping) {
    "host" -> host.ifBlank { "unlabeled host" }
    else -> when {
        attention == "needsYou" -> "needs you"
        status == "working" -> "working"
        attention == "unreadCompletion" -> "finished"
        else -> "recent"
    }
}

/** Shared by phone/tablet rows and the detail metadata header. */
@Composable
private fun AgentThreadRow.tokenMeterText(): String? = compactContextTokens()?.let {
    stringResource(R.string.agent_context_tokens, it)
}

private fun String.trimTrailingZero(): String = removeSuffix(".0")

/** Derived context is fractional; show whole percent like iOS. */
internal fun String.wholePercent(): String = toDoubleOrNull()?.toInt()?.toString() ?: trimTrailingZero()

/** Same display semantics as iOS `Text(date, style: .relative)`, in compact terminal copy. */
internal fun agentRelativeTime(timestampMillis: Long, nowMillis: Long = System.currentTimeMillis()): String {
    val delta = timestampMillis - nowMillis
    val future = delta > 0
    val seconds = (kotlin.math.abs(delta) / 1_000).coerceAtLeast(0)
    val (value, unit) = when {
        seconds < 60 -> 0L to "m"
        seconds < 3_600 -> seconds / 60 to "m"
        seconds < 86_400 -> seconds / 3_600 to "h"
        else -> seconds / 86_400 to "d"
    }
    val label = if (value == 0L) "now" else "$value$unit"
    return if (future && value != 0L) "in $label" else if (value == 0L) label else "$label ago"
}

/** iOS renders activity `displayTime` in a locale-independent 24-hour HH:mm form. */
internal fun agentDisplayTime(timestampMillis: Long, timeZone: TimeZone = TimeZone.getDefault()): String =
    SimpleDateFormat("HH:mm", Locale.ROOT).apply { this.timeZone = timeZone }.format(Date(timestampMillis))

/**
 * The read status shown above a transcript. A working agent appends
 * constantly and the host re-validates a grown file before serving it, so
 * most refreshes briefly report progress: over a transcript already on
 * screen that row pushed the conversation down and back on nearly every
 * refresh. Progress shows only while there is nothing else to show; a
 * failure shows with Retry, except before a live agent creates its first transcript.
 */
internal fun agentVisibleReadStatus(status: SharedAgentReadStatus?, transcriptShown: Boolean,
    hasLiveBinding: Boolean = false, hasTranscriptMessages: Boolean = transcriptShown): SharedAgentReadStatus? =
    status?.takeUnless { (it.isProgress && transcriptShown) ||
        (it.code == "sourceMissing" && hasLiveBinding && !hasTranscriptMessages) }

@Composable
internal fun AgentDetailPane(
    detail: AgentThreadDetail?,
    draft: String,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onInterrupt: () -> Unit,
    onPromptAnswer: (AgentPrompt, AgentPromptAnswerChoice) -> Unit,
    onNewestVisible: (String) -> Unit,
    onLoadMore: () -> Unit,
    onOpenTerminal: () -> Unit,
    onFork: () -> Unit,
    onStartSpeech: () -> Unit,
    modifier: Modifier,
    speechAvailable: Boolean = true,
    onBack: (() -> Unit)? = null,
    onAttach: () -> Unit = {},
    onAttachPhoto: () -> Unit = onAttach,
    onQueue: () -> Unit = {},
    sending: Boolean = false,
    promptActionPending: Boolean = false,
    uploading: Boolean = false,
    loadingTranscript: Boolean = false,
    capacityLimited: Boolean = false,
    readStatus: SharedAgentReadStatus? = null,
    onLoadNewer: () -> Unit = {},
    onReturnToLatest: () -> Unit = {},
    /** History for a transcript shorter than the list; see `fillHistory`. */
    onFillHistory: () -> Unit = {},
    /** The newer page that retains a bridged window's rows; see `retainBridgedRows`. */
    onRetainBridgedRows: () -> Unit = {},
    onViewportAnchor: (String?) -> Unit = {},
    onCompletionVisible: () -> Unit = {},
) {
    val tokens = LocalTesseraTokens.current
    if (detail == null) {
        TesseraEmptyState("select an agent", "Choose a live agent from the list.", modifier = modifier.background(tokens.bg), icon = TesseraIcons.Sessions)
        return
    }
    Column(modifier.background(tokens.bg).imePadding()) {
        if (onBack != null) TesseraSubPageHeader(detail.row.title, onBack, "back to agents", trailing = { DetailActions(detail, onInterrupt, onOpenTerminal, onFork) })
        else TesseraPageHeader(detail.row.title, trailing = { DetailActions(detail, onInterrupt, onOpenTerminal, onFork) })
        Text(listOfNotNull(detail.row.provider, detail.row.model, detail.row.location.takeIf { it.isNotBlank() }).joinToString(" · "), Modifier.padding(horizontal = 18.dp), style = TesseraType.rowMeta, color = tokens.fgMuted)
        AgentDetailMetadata(detail)
        // Weighted children measure after the composer: a tall prompt card
        // takes its space from the transcript, never from the composer.
        Column(Modifier.weight(1f).fillMaxWidth()) {
        detail.prompt?.let { prompt ->
            AgentUrgentPrompt(
                prompt = prompt,
                actionAvailable = detail.canAnswerPrompt(),
                pending = promptActionPending,
                onAnswer = { answer -> onPromptAnswer(prompt, answer) },
                onOpenTerminal = onOpenTerminal,
            )
        }
        val blocks = detail.live
        val blockListState = rememberLazyListState()
        // A record may carry several blocks, so its record ID alone is not a
        // LazyColumn key. The per-record ordinal stays stable when older data
        // is prepended, which is the important scroll-preservation case.
        val transcriptItems = remember(blocks, detail.toolRuns) { agentTranscriptItems(blocks, detail.toolRuns) }
        var expandedToolEntries by androidx.compose.runtime.saveable.rememberSaveable(detail.row.key) { mutableStateOf(emptyList<String>()) }
        // Expanded entries are independent lazy rows. Their record/block keys
        // survive an older-page merge; the run header keeps its row key too.
        val rowKeys = remember(detail.row.key) { AgentTranscriptRowKeys() }
        val anchoredItems = remember(detail.row.key, transcriptItems) { rowKeys.apply(transcriptItems) }
        val displayItems = remember(anchoredItems, expandedToolEntries) {
            agentTranscriptDisplayItems(anchoredItems, expandedToolEntries)
        }
        // A send the transcript already shows is that transcript row; its
        // local bubble would repeat it under the newest reply.
        val outgoingMessages = remember(detail.outgoingMessages) { detail.outgoingMessages.filter { it.status != "observed" } }
        val pagesForward = detail.window == null && detail.row.providerID in setOf("pi", "opencode")
        // A tall expanded run can be partly visible with its newest output still
        // offscreen. Only the separate tail sentinel can acknowledge that output.
        val newestBlockKey = blocks.lastOrNull()?.recordID?.let { "agent-tail:$it" }
        val newestListIndex = displayItems.size
        val outgoingTail = outgoingMessages.lastOrNull()?.id
        var observedOutgoingTail by remember(detail.row.key) { mutableStateOf<String?>(null) }
        // Follow is a reader choice, not the visibility of yesterday's tail.
        var followingLatest by remember(detail.row.key) { mutableStateOf(detail.window?.atLiveHead != false) }
        var positioned by remember(detail.row.key) { mutableStateOf(false) }
        var nearHistoryEdge by remember(detail.row.key) { mutableStateOf(false) }
        var requestedCursor by remember(detail.row.key) { mutableStateOf<String?>(null) }
        var nextPageAttempt by remember(detail.row.key) { mutableStateOf(0L) }
        var pageRetryDelay by remember(detail.row.key) { mutableStateOf(1_000L) }
        var historyDemand by remember(detail.row.key) { mutableStateOf("") }
        var automaticPages by remember(detail.row.key) { mutableStateOf(0) }
        var historyDemandGeneration by remember(detail.row.key) { mutableStateOf(0) }
        // Pages asked for to fill a short transcript since it last filled.
        var fillPages by remember(detail.row.key) { mutableStateOf(0) }
        val currentDisplayItems by rememberUpdatedState(displayItems)
        val currentViewportAnchor by rememberUpdatedState(onViewportAnchor)
        val chatScrollConnection = remember(detail.row.key, blockListState) {
            object : NestedScrollConnection {
                override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                    // Programmatic correction, layout, and key anchoring do not
                    // count as a user's request for history or loss of follow.
                    if (source == NestedScrollSource.UserInput && available.y != 0f) {
                        val direction = if (available.y > 0f) "before" else "after"
                        if (direction == "before") followingLatest = false
                        if (direction != historyDemand || automaticPages >= 4) {
                            automaticPages = 0; historyDemandGeneration++
                        }
                        historyDemand = direction
                    }
                    return Offset.Zero
                }
            }
        }
        // The runtime preserves explicit reading anchors when a rolling head
        // drops older records. Live-follow is the opposite intent: release the
        // anchor even before layout moves (for example Return to latest).
        // A run that grew at its start keeps pinning the entry its row key
        // names, as iOS keeps the pin while the row ID is unchanged. A reader
        // always names a row (the first visible one with a record): Core
        // reads no anchor as following, which never trades the live head
        // for older history.
        fun visibleViewportAnchor(): String? {
            if (followingLatest) return null
            val items = currentDisplayItems
            for (index in blockListState.firstVisibleItemIndex until items.size) {
                val recordID = when (val item = items[index]) {
                    is AgentTranscriptItem.Block -> item.block.recordID
                    is AgentTranscriptItem.ToolRun -> (item.entries.firstOrNull { it.key == item.key } ?: item.entries.firstOrNull())?.block?.recordID
                }
                if (recordID != null) return recordID
            }
            return null
        }
        LaunchedEffect(detail.row.key, blockListState) {
            // A reading position is sent once its first visible row settles,
            // not for every row a fling passes. The index stays in the key:
            // rows changing above the reader (a re-bootstrap, which clears
            // Core's anchor) resend it. Releasing follow is immediate, and
            // paging below sends the current anchor before it asks.
            snapshotFlow { visibleViewportAnchor()?.let { blockListState.firstVisibleItemIndex to it } }
                .collectLatest { reading ->
                    if (reading != null) kotlinx.coroutines.delay(VIEWPORT_ANCHOR_SETTLE_MILLIS)
                    currentViewportAnchor(reading?.second)
                }
        }
        val currentLoadMore by rememberUpdatedState(onLoadMore)
        val currentFillHistory by rememberUpdatedState(onFillHistory)
        LaunchedEffect(detail.row.key, detail.cursor, detail.hasMore, loadingTranscript, positioned, historyDemand,
            historyDemandGeneration, detail.window?.olderPageFits) {
            if (!positioned) return@LaunchedEffect
            snapshotFlow {
                val layout = blockListState.layoutInfo
                // Estimate one viewport of lookahead from measured visible
                // rows, including tall expanded tool results.
                val visible = layout.visibleItemsInfo
                val averageHeight = visible.map { it.size }.average().takeUnless { it.isNaN() } ?: 1.0
                val lookahead = ((layout.viewportEndOffset - layout.viewportStartOffset) / averageHeight).toInt().coerceAtLeast(2)
                val nearEdge = blocks.isEmpty() || (visible.isNotEmpty() && if (pagesForward) {
                    visible.last().index >= layout.totalItemsCount - lookahead - 1
                } else blockListState.firstVisibleItemIndex <= lookahead)
                // A transcript shorter than the viewport cannot be scrolled,
                // so no gesture will ever ask for its history. Fill it while
                // Core has room for an older page beside the live head.
                nearEdge to (visible.isNotEmpty() && !blockListState.canScrollBackward && !blockListState.canScrollForward)
            }.collectLatest { (nearEdge, underfilled) ->
                nearHistoryEdge = nearEdge
                if (!nearEdge) {
                    requestedCursor = null
                    pageRetryDelay = 1_000L
                    nextPageAttempt = 0L
                }
                if (!underfilled) fillPages = 0
                val cursor = detail.cursor
                val demanded = detail.window == null || (historyDemand == "before" && automaticPages < 4)
                // A fill stops where a page would trim the live head, and
                // at a page limit: rows that collapse into one tool run
                // could otherwise read every page.
                val fill = underfilled && fillPages < AGENT_FILL_PAGE_LIMIT && detail.window?.olderPageFits == true
                if (nearEdge && detail.hasMore && !loadingTranscript && cursor != null && (demanded || fill)) {
                    // An unchanged cursor can mean a transient read failure or
                    // an in-flight refresh. Retry without a button or a tight loop.
                    if (cursor == requestedCursor) {
                        kotlinx.coroutines.delay((nextPageAttempt - android.os.SystemClock.uptimeMillis()).coerceAtLeast(0))
                        pageRetryDelay = (pageRetryDelay * 2).coerceAtMost(30_000L)
                    } else pageRetryDelay = 1_000L
                    requestedCursor = cursor
                    nextPageAttempt = android.os.SystemClock.uptimeMillis() + pageRetryDelay
                    // A fill never spends the pages a history gesture is allowed.
                    if (demanded) {
                        automaticPages++
                        currentViewportAnchor(visibleViewportAnchor())
                        currentLoadMore()
                    } else {
                        fillPages++
                        currentFillHistory()
                    }
                }
            }
        }
        val currentLoadNewer by rememberUpdatedState(onLoadNewer)
        LaunchedEffect(detail.row.key, detail.window?.version, loadingTranscript, positioned, historyDemand, historyDemandGeneration) {
            if (!positioned || loadingTranscript || detail.window?.hasNewer != true || historyDemand != "after" || automaticPages >= 4) return@LaunchedEffect
            snapshotFlow { blockListState.layoutInfo.let { layout ->
                layout.visibleItemsInfo.lastOrNull()?.index?.let { it >= layout.totalItemsCount - 3 } == true
            } }.filter { it }.first()
            automaticPages++
            currentViewportAnchor(visibleViewportAnchor())
            currentLoadNewer()
        }
        val currentAtLiveHead by rememberUpdatedState(detail.window?.atLiveHead != false || outgoingTail != null)
        // The bottom sentinel's index; keep in step with the LazyColumn below.
        val bottomIndex = displayItems.size + listOfNotNull(newestBlockKey, detail.livePreview).size +
            outgoingMessages.size + (if (pagesForward) 1 else 0)
        val followsLatestHead = followingLatest && currentAtLiveHead
        // The list state outlives a thread switch, and so can a fling.
        val shownThread = remember { arrayOfNulls<String>(1) }
        SideEffect {
            // Content changes land in the same measure as the end position.
            // Scrolling after that frame drew the old position once, so every
            // append, growing reply and thread switch jumped a frame late. A
            // new thread takes its end even over the last thread's fling.
            val switched = shownThread[0] != detail.row.key
            shownThread[0] = detail.row.key
            if (followsLatestHead && (switched || !blockListState.isScrollInProgress)) blockListState.requestScrollToItem(bottomIndex)
        }
        val currentFollowsLatestHead by rememberUpdatedState(followsLatestHead)
        val currentBottomIndex by rememberUpdatedState(bottomIndex)
        val measuredListHeight = remember { intArrayOf(-1) }
        val currentReturnToLatest by rememberUpdatedState(onReturnToLatest)
        val sawLiveHead = remember(detail.row.key) { booleanArrayOf(false) }
        LaunchedEffect(detail.row.key, detail.window?.version) {
            val window = detail.window ?: return@LaunchedEffect
            if (window.atLiveHead) { sawLiveHead[0] = true; return@LaunchedEffect }
            // The window left the head under a following reader, across more
            // rows than Core bridges (`bridgesToHead`). Take them back to it
            // rather than onto history. A window that opened away from the
            // head is history the reader left there.
            if (followingLatest && sawLiveHead[0] && window.transition in setOf("revisions", "head")) currentReturnToLatest()
        }
        // A bridged window reads as live: its newest rows are shown but not
        // retained, so nothing revises them. A follower asks for the newer
        // page that retains them, backing off an unchanged cursor.
        val currentRetainBridgedRows by rememberUpdatedState(onRetainBridgedRows)
        var requestedBridgeCursor by remember(detail.row.key) { mutableStateOf<String?>(null) }
        var bridgeRetryDelay by remember(detail.row.key) { mutableStateOf(1_000L) }
        LaunchedEffect(detail.row.key, detail.window?.version, detail.window?.bridgesToHead, loadingTranscript, followingLatest) {
            val cursor = detail.window?.takeIf { it.bridgesToHead }?.after
            if (!followingLatest || loadingTranscript || cursor == null) return@LaunchedEffect
            if (cursor == requestedBridgeCursor) {
                kotlinx.coroutines.delay(bridgeRetryDelay)
                bridgeRetryDelay = (bridgeRetryDelay * 2).coerceAtMost(30_000L)
            } else bridgeRetryDelay = 1_000L
            requestedBridgeCursor = cursor
            currentRetainBridgedRows()
        }
        LaunchedEffect(detail.row.key, blockListState) {
            snapshotFlow {
                // layoutInfo invalidates on measurement, including same-ID
                // text growth and IME/viewport changes. No timer or file poll.
                Triple(blockListState.layoutInfo, followingLatest && currentAtLiveHead,
                    blockListState.isScrollInProgress)
            }.collect { (layout, follow, scrolling) ->
                if (!blockListState.canScrollForward && historyDemand == "after" && currentAtLiveHead) {
                    followingLatest = true
                }
                // Landscape IME + a prompt can temporarily leave no transcript
                // height. Seeking an invisible tail then remeasures forever.
                if (!scrolling && layout.totalItemsCount > 0 &&
                    layout.viewportSize.height > layout.beforeContentPadding + layout.afterContentPadding) {
                    // Growth that recomposed nothing above (the IME, a row's own
                    // relayout) is corrected at the next measure.
                    // Re-read at collection: a drag may have started since.
                    if (follow && followingLatest && currentAtLiveHead && !blockListState.isScrollInProgress &&
                        blockListState.canScrollForward) blockListState.requestScrollToItem(layout.totalItemsCount - 1)
                    positioned = true
                }
            }
        }
        LaunchedEffect(detail.row.key, outgoingTail) {
            if (outgoingTail != null && outgoingTail != observedOutgoingTail) {
                followingLatest = true; historyDemand = ""; automaticPages = 0
            }
            observedOutgoingTail = outgoingTail
        }
        LaunchedEffect(detail.row.key, newestBlockKey, newestListIndex, blocks.lastOrNull()?.recordID, detail.window?.atLiveHead, detail.window?.hasNewer) {
            if (detail.window?.let { !it.atLiveHead || it.hasNewer } == true) return@LaunchedEffect
            val newestRecordID = blocks.lastOrNull()?.recordID
            if (newestRecordID == null || blocks.isEmpty()) return@LaunchedEffect
            snapshotFlow {
                blockListState.layoutInfo.visibleItemsInfo.any { it.index == newestListIndex && it.key == newestBlockKey }
            }.filter { it }.first()
            onNewestVisible(newestRecordID)
        }
        // A finish that adds no record, or lands while the tail is already on
        // screen, changes no key above. Read it once the live end is in view.
        val unreadCompletionEpoch = detail.attentionEpoch.takeIf { detail.row.attention == "unreadCompletion" && it > 0 }
        LaunchedEffect(detail.row.key, unreadCompletionEpoch, newestBlockKey, newestListIndex, loadingTranscript,
            detail.window?.atLiveHead, detail.window?.hasNewer) {
            if (unreadCompletionEpoch == null || loadingTranscript) return@LaunchedEffect
            if (detail.window?.let { !it.atLiveHead || it.hasNewer } == true) return@LaunchedEffect
            if (blocks.isNotEmpty()) {
                if (newestBlockKey == null) return@LaunchedEffect
                snapshotFlow {
                    blockListState.layoutInfo.visibleItemsInfo.any { it.index == newestListIndex && it.key == newestBlockKey }
                }.filter { it }.first()
            }
            onCompletionVisible()
        }
        val shownReadStatus = agentVisibleReadStatus(readStatus,
            transcriptShown = blocks.isNotEmpty() || outgoingMessages.isNotEmpty() || detail.livePreview != null,
            hasLiveBinding = (detail.binding?.number("agentPID")?.toIntOrNull() ?: -1) > 1 && !detail.conversationEnded,
            hasTranscriptMessages = detail.hasTranscriptMessages)
        if (shownReadStatus != null) Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text(shownReadStatus.message, Modifier.weight(1f).testTag("agent-read-status"),
                style = TesseraType.rowMeta, color = tokens.fgMuted)
            if (!shownReadStatus.isProgress) androidx.compose.material3.TextButton(
                onClick = onReturnToLatest, enabled = !loadingTranscript,
                modifier = Modifier.heightIn(min = 48.dp).testTag("agent-read-retry")) {
                Text("Retry", style = TesseraType.rowMeta, color = tokens.fg)
            }
        }
        if (!followingLatest || detail.window?.atLiveHead == false || capacityLimited) {
            if (capacityLimited) Text("Live updates paused while this history view is retained.",
                Modifier.padding(horizontal = 16.dp), style = TesseraType.rowMeta, color = tokens.fgMuted)
            androidx.compose.material3.TextButton(onClick = {
                followingLatest = true
                historyDemand = ""; automaticPages = 0; historyDemandGeneration++
                if (detail.window?.atLiveHead == false || capacityLimited) onReturnToLatest()
            }, enabled = !loadingTranscript,
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("agent-return-latest")) {
                Text("Return to latest", style = TesseraType.rowMeta, color = tokens.fg)
            }
        }
        if (blocks.isEmpty() && outgoingMessages.isEmpty() && detail.livePreview == null && !detail.hasMore) Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            if (readStatus == null) Text(if (loadingTranscript) "loading conversation…" else "live projection is unavailable",
                style = TesseraType.body, color = tokens.fgMuted)
        } else Box(Modifier.weight(1f).fillMaxWidth()) {
        // A short transcript sits against the composer, as a chat does.
        LazyColumn(Modifier.fillMaxSize().layout { measurable, constraints ->
            // The IME and window resizes relayout the list without
            // recomposing this pane. Ask for the end before the list measures
            // at its new height, so the frame that resizes it shows the tail.
            if (constraints.maxHeight != measuredListHeight[0]) {
                if (measuredListHeight[0] >= 0 && currentFollowsLatestHead && !blockListState.isScrollInProgress) {
                    blockListState.requestScrollToItem(currentBottomIndex)
                }
                measuredListHeight[0] = constraints.maxHeight
            }
            val placeable = measurable.measure(constraints)
            layout(placeable.width, placeable.height) { placeable.place(0, 0) }
        }.nestedScroll(chatScrollConnection).testTag("agent-transcript-list"), state = blockListState,
            contentPadding = PaddingValues(top = 24.dp), verticalArrangement = Arrangement.Bottom) {
            items(displayItems, key = { it.key }, contentType = { item ->
                if (item is AgentTranscriptItem.ToolRun) "agent-tool-run" else "agent-block"
            }) { item ->
                when (item) {
                    is AgentTranscriptItem.Block -> AgentBlockCard(item.block)
                    is AgentTranscriptItem.ToolRun -> AgentToolRunCard(item,
                        expanded = item.entries.any { it.key in expandedToolEntries },
                        onExpandedChange = { expanded ->
                            val keys = item.entries.map { it.key }
                            expandedToolEntries = if (expanded) (expandedToolEntries + keys).distinct() else expandedToolEntries - keys.toSet()
                        },
                    )
                }
            }
            if (newestBlockKey != null) item(key = newestBlockKey) { Spacer(Modifier.height(1.dp)) }
            if (detail.livePreview != null) item(key = "agent-live-preview") {
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("agent-live-preview")) {
                    Text(if (detail.livePreviewHasGap) "live preview · awaiting missing text" else "live preview · syncing transcript",
                        style = TesseraType.rowMicro, color = tokens.fgDim)
                    SelectionContainer { Text(detail.livePreview, style = TesseraType.bodySmall, color = tokens.fg) }
                }
            }
            items(outgoingMessages, key = { "agent-outgoing:${it.id}" }, contentType = { "agent-outgoing" }) { message ->
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), horizontalAlignment = Alignment.End) {
                    Column(Modifier.fillMaxWidth(0.8f).background(tokens.panelBg, RoundedCornerShape(11.dp))
                        .border(1.dp, tokens.border, RoundedCornerShape(11.dp)).padding(10.dp)
                        .testTag("agent-outgoing-${message.status}")) {
                        SelectionContainer { Text(message.text, style = TesseraType.bodySmall, color = tokens.fgDim) }
                        Text(when (message.status) {
                            "sending" -> "sending…"
                            "queueing" -> "queueing…"
                            "awaitingReceipt" -> "sent · waiting for transcript…"
                            "sentUnconfirmed" -> "sent · transcript receipt unavailable"
                            else -> "receipt unconfirmed · check terminal before retrying"
                        }, Modifier.padding(top = 4.dp), style = TesseraType.rowMicro, color = tokens.fgDim)
                    }
                }
            }
            if (pagesForward) item(key = "agent-history-forward-loading") {
                AgentHistoryLoadingGlyph(loadingTranscript && detail.hasMore)
            }
            item(key = "agent-conversation-bottom") { Spacer(Modifier.height(1.dp)) }
        }
        // A keyed loading header would remain the first visible item at the
        // very top and pin the reader to the new page. Only messages anchor.
        if (!pagesForward) AgentHistoryLoadingGlyph(loadingTranscript && detail.hasMore && nearHistoryEdge)
        }
        }
        Composer(
            draft = draft,
            onDraftChange = onDraftChange,
            onSend = onSend,
            onInterrupt = onInterrupt,
            onStartSpeech = onStartSpeech,
            speechAvailable = speechAvailable,
            enabled = detail.row.actionAvailable && detail.binding != null,
            onAttach = onAttach,
            onAttachPhoto = onAttachPhoto,
            onQueue = onQueue.takeIf { detail.row.providerID == "codex" && detail.row.status == "working" },
            sending = sending,
            uploading = uploading,
        )
    }
}

private const val VIEWPORT_ANCHOR_SETTLE_MILLIS = 150L
/** Older pages a short transcript may ask for before it fills. */
private const val AGENT_FILL_PAGE_LIMIT = 8

@Composable
private fun AgentHistoryLoadingGlyph(loading: Boolean) {
    val tokens = LocalTesseraTokens.current
    var showGlyph by remember { mutableStateOf(false) }
    LaunchedEffect(loading) {
        showGlyph = false
        if (loading) {
            kotlinx.coroutines.delay(250)
            showGlyph = true
        }
    }
    Box(Modifier.fillMaxWidth().height(24.dp), contentAlignment = Alignment.Center) {
        if (showGlyph) CircularProgressIndicator(Modifier.size(18.dp).testTag("agent-history-loading")
            .semantics { contentDescription = "loading messages" }, color = tokens.fgMuted, strokeWidth = 2.dp)
    }
}

/** Bounded shared-summary/binding metadata only; never infer provider state. */
@Composable
private fun AgentDetailMetadata(detail: AgentThreadDetail) {
    val tokens = LocalTesseraTokens.current
    val binding = detail.binding
    val terminal = listOfNotNull(
        detail.row.host.takeIf { it.isNotBlank() }?.let { "host $it" },
        binding?.string("transport"),
        binding?.string("tmuxSession")?.let { "session $it" },
        binding?.string("windowID")?.let { "window $it" },
        binding?.string("paneID")?.let { "pane $it" },
    ).joinToString(" · ")
    val summary = listOfNotNull(
        detail.row.permissionMode?.let { "mode $it" },
        detail.row.contextPercent?.let { "${it.wholePercent()}% context" } ?: detail.row.tokenMeterText(),
        detail.row.totalCost?.let { "$$it" },
        detail.row.queuedCount?.takeIf { it != "0" }?.let { "$it queued" },
        if (detail.row.isFork) "fork" else null,
    ).joinToString(" · ")
    if (terminal.isNotBlank()) Text(terminal, Modifier.padding(horizontal = 18.dp, vertical = 2.dp), style = TesseraType.rowMicro, color = tokens.fgDim, maxLines = 1, overflow = TextOverflow.Ellipsis)
    if (summary.isNotBlank()) Text(summary, Modifier.padding(horizontal = 18.dp, vertical = 2.dp), style = TesseraType.rowMicro, color = tokens.fgDim, maxLines = 1, overflow = TextOverflow.Ellipsis)
}

@Composable
private fun AgentToolRunCard(run: AgentTranscriptItem.ToolRun, expanded: Boolean, onExpandedChange: (Boolean) -> Unit) {
    val tokens = LocalTesseraTokens.current
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)
        .border(1.dp, tokens.border, RoundedCornerShape(8.dp)).padding(horizontal = 10.dp, vertical = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(run.summaryTitle, Modifier.weight(1f), style = TesseraType.rowMeta, color = tokens.fg)
            TesseraButton(if (expanded) "collapse" else "details", { onExpandedChange(!expanded) }, compact = true,
                modifier = Modifier.testTag("agent-tool-run-${run.key}"))
        }
        run.latestSummary?.let {
            Text(it, style = TesseraType.rowMicro, color = tokens.fgMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun AgentUrgentPrompt(
    prompt: AgentPrompt,
    actionAvailable: Boolean,
    pending: Boolean,
    onAnswer: (AgentPromptAnswerChoice) -> Unit,
    onOpenTerminal: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    val enabled = actionAvailable && !pending
    var detailExpanded by remember(prompt.actionToken) { mutableStateOf(false) }
    var textRow by remember(prompt.actionToken) { mutableStateOf<String?>(null) }
    var answerText by remember(prompt.actionToken, textRow) { mutableStateOf("") }
    val reveal = remember(prompt.actionToken) { BringIntoViewRequester() }
    fun sendText() {
        if (enabled && answerText.isNotBlank()) onAnswer(AgentPromptAnswerChoice.Text(answerText))
    }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
            .border(1.dp, tokens.borderStrong, RoundedCornerShape(8.dp))
            .layout { measurable, constraints ->
                // Leave the transcript a strip for its newest lines; when the
                // IME leaves less than that, split the space. No fixed ceiling
                // there: a short card clipped under empty space hides its
                // controls. In an unbounded list the card scrolls within 360dp.
                val cap = if (constraints.hasBoundedHeight) {
                    maxOf(constraints.maxHeight / 2, constraints.maxHeight - 96.dp.roundToPx())
                } else {
                    360.dp.roundToPx()
                }
                val placeable = measurable.measure(constraints.copy(maxHeight = maxOf(constraints.minHeight, cap)))
                layout(placeable.width, placeable.height) { placeable.place(0, 0) }
            }
            .verticalScroll(rememberScrollState()).padding(12.dp),
    ) {
        TesseraKicker("needs your answer")
        if (prompt.kind == "deferred") {
            // Collapsed async questions: the count is the whole message.
            val count = prompt.pendingCount ?: 0
            Text(if (count == 1) "1 question waiting" else "$count questions waiting", Modifier.padding(top = 4.dp),
                style = TesseraType.section, color = tokens.fg)
            Text("Codex keeps working while they wait", style = TesseraType.rowMicro, color = tokens.fgMuted)
        } else {
            Text(prompt.title, Modifier.padding(top = 4.dp), style = TesseraType.section, color = tokens.fg)
            prompt.progress?.let { Text(it, Modifier.padding(top = 4.dp), style = TesseraType.rowMicro, color = tokens.fgDim) }
            prompt.question?.let { Text(it, Modifier.padding(top = 6.dp), style = TesseraType.body.copy(fontWeight = FontWeight.Medium), color = tokens.fg) }
        }
        prompt.detail?.let { detail ->
            Column(Modifier.fillMaxWidth().padding(top = 8.dp).background(tokens.inputBgSoft, RoundedCornerShape(6.dp))
                .border(1.dp, tokens.border, RoundedCornerShape(6.dp)).padding(8.dp)) {
                Text(detail, style = TesseraType.bodySmall, color = tokens.fgMuted,
                    maxLines = if (detailExpanded) Int.MAX_VALUE else 8, overflow = TextOverflow.Ellipsis)
                if (detail.lines().size > 8 || detail.length > 400) {
                    TesseraButton(if (detailExpanded) "less" else "more", { detailExpanded = !detailExpanded },
                        compact = true, modifier = Modifier.padding(top = 4.dp).heightIn(min = 48.dp))
                }
            }
        }
        if (!prompt.isBlocking && prompt.kind != "deferred") Text("The agent keeps working while this waits", Modifier.padding(top = 6.dp),
            style = TesseraType.rowMicro, color = tokens.fgMuted)
        prompt.entry?.text?.takeIf(String::isNotEmpty)?.let {
            Text("In the terminal: $it", Modifier.padding(top = 6.dp), style = TesseraType.rowMicro, color = tokens.fgMuted)
        }
        if (prompt.options.isNotEmpty()) {
            Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                prompt.options.forEach { option ->
                    Column {
                        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
                            .border(1.dp, if (option.isDefault) tokens.borderStrong else tokens.border, RoundedCornerShape(6.dp))
                            .clickable(enabled = enabled) {
                                if (option.acceptsText) textRow = option.id
                                else onAnswer(AgentPromptAnswerChoice.Option(option.id))
                            }.testTag("agent-answer-${option.id}").padding(horizontal = 10.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            if (prompt.kind == "multiSelect") {
                                Box(Modifier.size(20.dp).border(1.dp, tokens.fgMuted, RoundedCornerShape(3.dp)), contentAlignment = Alignment.Center) {
                                    if (option.isChecked == true) Icon(TesseraIcons.Check, null, Modifier.size(16.dp), tint = tokens.fg)
                                }
                                Spacer(Modifier.width(9.dp))
                            }
                            Column(Modifier.weight(1f)) {
                                Text(option.label, style = TesseraType.bodySmall,
                                    color = if (option.role == "chat") tokens.fgMuted else tokens.fg)
                                option.detail?.let { Text(it, style = TesseraType.rowMicro, color = tokens.fgMuted) }
                            }
                        }
                        if (option.acceptsText && textRow == option.id) {
                            AgentPromptTextField(answerText, { answerText = it }, enabled, ::sendText, reveal,
                                Modifier.padding(top = 6.dp))
                        }
                    }
                }
            }
        }
        if (prompt.kind == "textEntry") {
            AgentPromptTextField(answerText, { answerText = it }, enabled, ::sendText, reveal,
                Modifier.padding(top = 8.dp))
        }
        if (prompt.controls.isNotEmpty()) {
            Column(Modifier.fillMaxWidth().padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                prompt.controls.chunked(2).forEach { controls ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        controls.forEach { control ->
                            val label = when (control.kind) {
                                "next" -> "Next"
                                "skip" -> "Skip"
                                "cancel" -> "Cancel"
                                "open" -> "Answer"
                                else -> control.label
                            }
                            TesseraButton(label, { onAnswer(AgentPromptAnswerChoice.Control(control.kind)) },
                                modifier = Modifier.weight(1f).testTag("agent-answer-control-${control.kind}").heightIn(min = 48.dp),
                                style = if (control.kind == "open") TesseraButtonStyle.Primary else TesseraButtonStyle.Default,
                                enabled = enabled, compact = true)
                        }
                        if (controls.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
        }
        if (!actionAvailable && !pending) {
            Text("Open terminal to answer", Modifier.padding(top = 8.dp), style = TesseraType.bodySmall, color = tokens.fgMuted)
            TesseraButton("open terminal", onOpenTerminal, modifier = Modifier.padding(top = 4.dp).heightIn(min = 48.dp))
        }
    }
}

@Composable
private fun AgentPromptTextField(value: String, onValueChange: (String) -> Unit, enabled: Boolean,
    onSend: () -> Unit, reveal: BringIntoViewRequester, modifier: Modifier) {
    val tokens = LocalTesseraTokens.current
    var focused by remember { mutableStateOf(false) }
    // Focus lands before the IME shrinks the card; reveal again at each inset
    // so the field and Send end fully visible once the keyboard settles.
    val imeBottom = WindowInsets.ime.getBottom(LocalDensity.current)
    LaunchedEffect(focused, imeBottom) { if (focused) reveal.bringIntoView() }
    Row(modifier.fillMaxWidth().bringIntoViewRequester(reveal), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        BasicTextField(value, { onValueChange(it.replace('\n', ' ').replace('\r', ' ')) },
            Modifier.weight(1f).heightIn(min = 48.dp).background(tokens.inputBg, RoundedCornerShape(6.dp))
                .border(1.dp, tokens.borderStrong, RoundedCornerShape(6.dp)).testTag("agent-answer-text")
                .onFocusChanged { focused = it.isFocused }.padding(12.dp),
            enabled = enabled, singleLine = true, textStyle = TesseraType.body.copy(color = tokens.fg),
            cursorBrush = SolidColor(tokens.fg), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { onSend() }))
        TesseraButton("Send", onSend, modifier = Modifier.testTag("agent-answer-send").heightIn(min = 48.dp),
            style = TesseraButtonStyle.Primary, enabled = enabled && value.isNotBlank(), compact = true)
    }
}

@Composable private fun DetailActions(detail: AgentThreadDetail, onInterrupt: () -> Unit, onOpenTerminal: () -> Unit, onFork: () -> Unit) {
    TesseraIconButton(TesseraIcons.Sessions, "open terminal", onOpenTerminal)
    TesseraIconButton(TesseraIcons.Plus, "fork agent", onFork, enabled = detail.row.forkAvailable && detail.launchTargetOrNull() != null)
    TesseraIconButton(TesseraIcons.Close, "interrupt agent", onInterrupt, danger = true, enabled = detail.row.actionAvailable && detail.binding != null)
}

@Composable private fun AgentBlockCard(block: AgentBlock) {
    val tokens = LocalTesseraTokens.current
    var expanded by remember(block.recordID, block.body) { mutableStateOf(false) }
    // Prose is the conversation itself.  It deliberately has no event card or
    // wire-derived heading: assistant turns read as a transcript and user turns
    // read as a compact right-aligned message bubble.
    if (block.kind == "text") {
        val isUser = block.role == "user"
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            horizontalAlignment = if (isUser) Alignment.End else Alignment.Start,
        ) {
            SelectionContainer {
                TesseraMarkdownText(
                    source = block.body,
                    modifier = Modifier.then(
                        if (isUser) Modifier.fillMaxWidth(0.8f)
                            .background(tokens.accentSoft, RoundedCornerShape(11.dp))
                            .border(1.dp, tokens.accent.copy(alpha = 0.35f), RoundedCornerShape(11.dp))
                            .padding(11.dp)
                        else Modifier.fillMaxWidth(),
                    ),
                )
            }
            block.displayTimeMillis?.let { displayTime ->
                Text(agentDisplayTime(displayTime), Modifier.padding(top = 4.dp), style = TesseraType.rowMicro, color = tokens.fgDim)
            }
        }
        return
    }
    val semanticTitle = when (block.kind.lowercase()) {
        "thinking" -> "thinking"
        "toolcall", "tool_call" -> listOf("tool call", block.title.takeIf { it.isNotBlank() && it != "tool" }).filterNotNull().joinToString(" · ")
        "toolresult", "tool_result" -> "tool result"
        "workflow", "workflowtasks" -> "workflow"
        "subagent", "subagentgroup" -> "subagents"
        "edit", "change", "diff" -> listOf("change", block.title.takeIf { it.isNotBlank() && it != "edit" }).filterNotNull().joinToString(" · ")
        "completion" -> "completed"
        "compactsummary" -> "context compacted"
        else -> block.title
    }
    val collapsible = block.kind.lowercase() in setOf("thinking", "toolcall", "tool_call", "toolresult", "tool_result", "workflow", "workflowtasks", "subagent", "subagentgroup", "edit", "change", "diff", "compactsummary")
    // A compaction summary is long provider boilerplate: collapsed, it is a
    // single marker row with no preview line.
    val collapsedPreview = block.kind != "compactSummary"
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 7.dp).border(1.dp, tokens.border, RoundedCornerShape(8.dp)).padding(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TesseraKicker(semanticTitle)
            Spacer(Modifier.weight(1f))
            block.displayTimeMillis?.let { displayTime ->
                Text(agentDisplayTime(displayTime), style = TesseraType.rowMicro, color = tokens.fgDim)
                Spacer(Modifier.width(8.dp))
            }
            if (collapsible) TesseraButton(if (expanded) "collapse" else "details", { expanded = !expanded }, compact = true,
                modifier = Modifier.testTag("agent-block-expand-${block.recordID}"))
        }
        val summary = block.body.lineSequence().firstOrNull().orEmpty()
        if (collapsible && !expanded) {
            if (collapsedPreview) Text(summary, Modifier.padding(top = 5.dp), style = TesseraType.bodySmall, color = tokens.fgMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        } else {
            SelectionContainer {
                if (block.kind == "subagentGroup" || block.kind == "compactSummary") {
                    TesseraMarkdownText(block.body, Modifier.padding(top = 5.dp))
                } else {
                    Text(block.body, Modifier.padding(top = 5.dp), style = TesseraType.bodySmall, color = tokens.fg)
                }
            }
        }
    }
}

/** Uses Android's document provider picker for local, cloud and removable files. */
@Composable internal fun rememberAgentAttachmentPicker(onResult: (List<String>) -> Unit): () -> Unit {
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        onResult(uris.map { it.toString() })
    }
    return { picker.launch(arrayOf("*/*")) }
}

/** The system photo picker grants access only to the selected images. */
@Composable internal fun rememberAgentPhotoPicker(
    onResult: (List<String>, suspend () -> List<String>, () -> Unit) -> Unit,
): () -> Unit {
    val context = LocalContext.current.applicationContext
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris ->
        // The presenter captures selection authority immediately and owns preparation
        // through upload completion, so leaving this composition cannot orphan a copy.
        val directory = java.io.File(context.cacheDir, "exports/agent-photos/${java.util.UUID.randomUUID()}")
        onResult(uris.map { it.toString() }, {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                val jobContext = kotlin.coroutines.coroutineContext
                copyAgentPhotoAttachments(context, uris, directory) {
                    jobContext.ensureActive()
                }
            }
        }, { directory.deleteRecursively(); Unit })
    }
    return { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
}

/** Internal so the hardware-keyboard composer can be exercised in Compose tests. */
@Composable internal fun Composer(
    draft: String,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onInterrupt: () -> Unit,
    onStartSpeech: () -> Unit,
    speechAvailable: Boolean = true,
    enabled: Boolean,
    onAttach: () -> Unit,
    onAttachPhoto: () -> Unit = onAttach,
    onQueue: (() -> Unit)?,
    sending: Boolean,
    uploading: Boolean,
) {
    val tokens = LocalTesseraTokens.current
    val configuration = LocalConfiguration.current
    val showSendShortcutHint = configuration.keyboard == Configuration.KEYBOARD_QWERTY &&
        configuration.hardKeyboardHidden == Configuration.HARDKEYBOARDHIDDEN_NO &&
        enabled && !uploading && !sending && draft.isSafeComposerDraft()
    var queueMenu by remember { mutableStateOf(false) }
    var attachmentMenu by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().background(tokens.panelBg)) {
        TesseraHairline()
        Row(Modifier.padding(horizontal = 12.dp, vertical = 7.dp).fillMaxWidth()
            .border(1.dp, tokens.border, RoundedCornerShape(24.dp)).testTag("agent-composer-frame"), verticalAlignment = Alignment.Bottom) {
        if (uploading) ComposerProgress("uploading attachment", "agent-upload-progress")
        else Box {
            TesseraIconButton(TesseraIcons.Plus, "add attachment", { attachmentMenu = true },
                enabled = enabled && !sending, modifier = Modifier.testTag("agent-attach"))
            DropdownMenu(expanded = attachmentMenu, onDismissRequest = { attachmentMenu = false }) {
                DropdownMenuItem(text = { Text("File") }, onClick = {
                    attachmentMenu = false
                    onAttach()
                }, enabled = enabled && !sending, modifier = Modifier.testTag("agent-attach-file"))
                DropdownMenuItem(text = { Text("Photo") }, onClick = {
                    attachmentMenu = false
                    onAttachPhoto()
                }, enabled = enabled && !sending, modifier = Modifier.testTag("agent-attach-photo"))
            }
        }
        BasicTextField(
            value = draft, onValueChange = onDraftChange,
            singleLine = false, maxLines = 5, enabled = enabled,
            textStyle = TesseraType.body.copy(color = tokens.fg), cursorBrush = SolidColor(tokens.fg),
            decorationBox = { field ->
                Box { if (draft.isEmpty()) Text(if (enabled) "message…" else "open terminal to continue", style = TesseraType.body, color = tokens.fgDim); field() }
            },
            modifier = Modifier.weight(1f).padding(top = 14.dp, bottom = 14.dp)
                .testTag("agent-composer")
                .onPreviewKeyEvent { event ->
                    handleComposerSendShortcut(
                        isEnterKey = event.key == Key.Enter || event.key == Key.NumPadEnter,
                        isKeyDown = event.type == KeyEventType.KeyDown,
                        isRepeat = event.nativeKeyEvent.repeatCount > 0,
                        isCtrlPressed = event.isCtrlPressed,
                        isMetaPressed = event.isMetaPressed,
                        draft = draft,
                        enabled = enabled,
                        sending = sending,
                        uploading = uploading,
                        onSend = onSend,
                    )
                }
                .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                when {
                    // Escape only interrupts when the focused composer has no
                    // draft, making the destructive intent unambiguous.
                    event.key == Key.Escape && draft.isBlank() -> {
                        onInterrupt(); true
                    }
                    else -> false
                }
            },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
        )
        if (sending) ComposerProgress("sending message", "agent-send-progress")
        else Box {
            Box(Modifier.size(48.dp)
                .testTag(if (draft.isBlank()) "agent-dictation" else "agent-send")
                .semantics { contentDescription = if (draft.isBlank()) { if (speechAvailable) "dictate message" else "on-device dictation unavailable" } else "send" }
                .combinedClickable(
                    enabled = enabled && !uploading && (if (draft.isBlank()) speechAvailable else draft.isSafeComposerDraft()),
                    role = Role.Button,
                    onLongClickLabel = if (onQueue != null && draft.isNotBlank()) "queue options" else null,
                    onLongClick = if (onQueue != null && draft.isNotBlank()) ({ queueMenu = true }) else null,
                    onClick = { if (draft.isBlank()) onStartSpeech() else onSend() },
                ), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center) {
                    Icon(if (draft.isBlank()) TesseraIcons.Microphone else TesseraIcons.ArrowUp,
                        contentDescription = null, tint = if (enabled && !uploading) tokens.fg else tokens.fgDim,
                        modifier = Modifier.size(if (showSendShortcutHint) 20.dp else 22.dp))
                    if (showSendShortcutHint) {
                        Text("ctrl ↵", Modifier.clearAndSetSemantics { testTag = "agent-send-shortcut-hint" },
                            style = TesseraType.rowMicro, color = tokens.fgMuted)
                    }
                }
            }
            DropdownMenu(expanded = queueMenu, onDismissRequest = { queueMenu = false }) {
                DropdownMenuItem(text = { Text("Queue message") }, onClick = {
                    queueMenu = false
                    if (enabled && !uploading && !sending && draft.isSafeComposerDraft()) onQueue?.invoke()
                })
            }
        }
        }
        if (draft.any { (it.code < 32 && it != '\n') || it.code == 127 }) {
            Text("Control-key paste requires Open terminal.", Modifier.padding(top = 4.dp), style = TesseraType.rowMicro, color = tokens.fgMuted)
        }
    }
}

@Composable private fun ComposerProgress(label: String, tag: String) {
    val tokens = LocalTesseraTokens.current
    Box(Modifier.size(48.dp).testTag(tag).semantics {
        contentDescription = label
        liveRegion = LiveRegionMode.Polite
    }, contentAlignment = Alignment.Center) {
        CircularProgressIndicator(Modifier.size(20.dp), color = tokens.fgMuted, strokeWidth = 2.dp)
    }
}

private fun String.isSafeComposerDraft(): Boolean = isNotBlank() && none { (it.code < 32 && it != '\n') || it.code == 127 }

/** Return true for every command-Enter in the composer, including drafts that cannot send. */
internal fun handleComposerSendShortcut(
    isEnterKey: Boolean,
    isKeyDown: Boolean,
    isRepeat: Boolean,
    isCtrlPressed: Boolean,
    isMetaPressed: Boolean,
    draft: String,
    enabled: Boolean,
    sending: Boolean,
    uploading: Boolean,
    onSend: () -> Unit,
): Boolean {
    if (!isEnterKey || !isKeyDown || (!isCtrlPressed && !isMetaPressed)) return false
    if (!isRepeat && enabled && !uploading && !sending && draft.isSafeComposerDraft()) onSend()
    return true
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
internal fun AgentSpawnSheet(
    kind: AgentLaunchKind,
    captureProtectionEnabled: Boolean = true,
    onDismiss: () -> Unit,
    selected: AgentThreadDetail?,
    onLaunchRequested: ((AgentLaunchRequest) -> Unit)?,
) {
    val target = selected?.launchTargetOrNull()
    val providerIDs = selected?.launchProviderIDs(kind).orEmpty()
    var providerID by remember(kind, selected?.row?.key, providerIDs) {
        mutableStateOf(providerIDs.firstOrNull().orEmpty())
    }
    var draft by remember(kind, selected?.row?.key, target?.provenDirectories) {
        mutableStateOf(AgentLaunchDraft(
            directory = target?.provenDirectories?.firstOrNull().orEmpty(),
            placement = if (kind == AgentLaunchKind.Fork) AgentLaunchPlacement.SplitRight else AgentLaunchPlacement.NewWindow,
        ))
    }
    val capable = providerID in providerIDs
    val request = draft.toRequestOrNull(kind, providerID, target)
    val executable = capable && onLaunchRequested != null && request != null
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        properties = androidx.compose.material3.ModalBottomSheetProperties(securePolicy = if (captureProtectionEnabled) androidx.compose.ui.window.SecureFlagPolicy.SecureOn else androidx.compose.ui.window.SecureFlagPolicy.Inherit),
        sheetState = sheetState,
        modifier = Modifier.imePadding(),
    ) {
        Column(
            Modifier.fillMaxWidth().imePadding().padding(horizontal = 18.dp).padding(bottom = 18.dp),
        ) {
            Text(if (kind == AgentLaunchKind.Fork) "fork agent" else "spawn agent", style = TesseraType.sheet)
            // The form takes whatever height the sheet has left once the
            // keyboard and the action row are placed, so "cancel" and
            // "spawn" stay reachable on a phone while a field is focused.
            Column(
                Modifier.weight(1f, fill = false).heightIn(max = 520.dp).verticalScroll(rememberScrollState()).padding(top = 14.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (!capable || target == null) {
                    Text("This live endpoint does not currently advertise ${if (kind == AgentLaunchKind.Fork) "fork" else "spawn"}.", style = TesseraType.body)
                } else {
                    TesseraKicker("provider")
                    TesseraSegmented(
                        providerIDs.map(::launchProviderLabel),
                        providerIDs.indexOf(providerID).coerceAtLeast(0),
                        onSelect = { index -> providerID = providerIDs[index] },
                    )
                    Text("Target: ${target.hostLabel} · ${target.tmuxSession ?: "tmux"}", style = TesseraType.bodySmall)
                    TesseraTextField(draft.task, { draft = draft.copy(task = it) }, label = "task", placeholder = "instruction", singleLine = false, inputTestTag = "agent-launch-task")
                    TesseraTextField(draft.name, { draft = draft.copy(name = it) }, label = "name (optional)", placeholder = "agent name", inputTestTag = "agent-launch-name")
                    TesseraKicker("directory")
                    // Choices are the only just-proven paths this route may
                    // launch in.  Typing is retained for accessibility/paste,
                    // but it must exactly match one of those live proofs.
                    target.provenDirectories.forEach { directory ->
                        TesseraButton(
                            directory,
                            { draft = draft.copy(directory = directory) },
                            style = if (draft.directory.trim() == directory) TesseraButtonStyle.Primary else TesseraButtonStyle.Default,
                            compact = true,
                            modifier = Modifier.fillMaxWidth().testTag("agent-launch-directory-choice"),
                        )
                    }
                    val directoryIsProven = draft.directory.trim() in target.provenDirectories && validProvenDirectory(draft.directory.trim())
                    TesseraTextField(
                        draft.directory,
                        { draft = draft.copy(directory = it.take(2_048)) },
                        label = "directory",
                        placeholder = "choose a proven directory",
                        supporting = if (directoryIsProven) "currently proven for this pane" else "must exactly match a currently proven directory",
                        inputTestTag = "agent-launch-directory",
                        isError = draft.directory.isNotBlank() && !directoryIsProven,
                    )
                    TesseraKicker("placement")
                    TesseraSegmented(listOf("new window", "split right", "split down"), draft.placement.ordinal, { index ->
                        draft = draft.copy(placement = AgentLaunchPlacement.entries[index])
                    })
                    if (draft.placement != AgentLaunchPlacement.NewWindow) {
                        Text("Window ${target.windowID ?: "unavailable"} · pane ${target.paneID ?: "unavailable"}", style = TesseraType.bodySmall)
                    }
                    TesseraKicker("isolation")
                    TesseraSegmented(listOf("current worktree", "new worktree"), if (draft.newWorktree) 1 else 0, { index ->
                        draft = draft.copy(newWorktree = index == 1)
                    })
                    if (draft.newWorktree) TesseraTextField(draft.branch, { draft = draft.copy(branch = it) }, label = "branch", placeholder = "feature/agent-task", inputTestTag = "agent-launch-branch")
                    if (onLaunchRequested == null) Text("Launch execution is unavailable until this app binds a generation-safe endpoint executor.", style = TesseraType.bodySmall)
                }
            }
            Row(
                Modifier.fillMaxWidth().padding(top = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
            ) {
                TesseraButton("cancel", onDismiss, compact = true)
                TesseraButton(if (kind == AgentLaunchKind.Fork) "fork" else "spawn", {
                    request?.let { onLaunchRequested?.invoke(it); onDismiss() }
                }, style = TesseraButtonStyle.Primary, compact = true, enabled = executable)
            }
        }
    }
}

/** Spawn is a route capability: it is not limited to the provider of the selected transcript. */
internal fun AgentThreadDetail.launchProviderIDs(kind: AgentLaunchKind): List<String> = when (kind) {
    AgentLaunchKind.Spawn -> if (row.spawnAvailable && launchTargetOrNull() != null) listOf("claude", "codex") else emptyList()
    AgentLaunchKind.Fork -> if (row.forkAvailable && row.providerID == "claude" && launchTargetOrNull() != null) listOf("claude") else emptyList()
}

internal fun launchProviderLabel(id: String): String = when (id) {
    "claude" -> "Claude"
    "codex" -> "Codex"
    else -> id
}

private fun Key.promptOptionIndexOrNull(): Int? = when (this) {
    Key.One -> 0
    Key.Two -> 1
    Key.Three -> 2
    Key.Four -> 3
    Key.Five -> 4
    Key.Six -> 5
    Key.Seven -> 6
    Key.Eight -> 7
    Key.Nine -> 8
    else -> null
}

/** The iOS thread-row dot: 7dp, toned by [agentStatusDotTone], with a soft halo while the agent works. */
@Composable
private fun AgentStatusDot(row: AgentThreadRow) {
    val tokens = LocalTesseraTokens.current
    val color = when (agentStatusDotTone(row.status, row.attention)) {
        AgentStatusDotTone.Amber -> tokens.amber
        AgentStatusDotTone.Green -> tokens.green
        AgentStatusDotTone.Faint -> tokens.fgFaint
    }
    val halo = if (row.status == "working") Modifier.drawBehind {
        // SwiftUI's shadow(radius: 4) at 60% opacity: a blurred copy of the
        // dot, about half strength at its edge, gone 4dp beyond it.
        val dotRadius = size.minDimension / 2
        val haloRadius = dotRadius + 4.dp.toPx()
        drawCircle(
            Brush.radialGradient(
                0f to color.copy(alpha = 0.6f),
                dotRadius / haloRadius to color.copy(alpha = 0.3f),
                1f to Color.Transparent,
                center = center,
                radius = haloRadius,
            ),
            radius = haloRadius,
        )
    } else Modifier
    TesseraStatusDot(color, halo.testTag("agent-status-dot-${row.key}"), size = 7.dp)
}
