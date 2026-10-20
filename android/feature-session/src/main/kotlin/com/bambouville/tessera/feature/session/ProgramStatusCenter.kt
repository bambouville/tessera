package com.bambouville.tessera.feature.session

import androidx.compose.runtime.Composable
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import com.bambouville.tessera.core.bridge.SharedProgramStatusAttention
import com.bambouville.tessera.core.bridge.SharedProgramStatusBlockedKind
import com.bambouville.tessera.core.bridge.SharedProgramStatusEntry
import com.bambouville.tessera.core.bridge.SharedProgramStatusSnapshot
import com.bambouville.tessera.core.bridge.SharedProgramStatusState
import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminal
import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminalSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.design.LocalTesseraTokens
import java.text.NumberFormat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Cue precedence, most urgent first; also the order of attention rows. */
enum class ProgramAttentionTone { NEEDS_INPUT, FAILED, FINISHED }

val SharedProgramStatusAttention.tone: ProgramAttentionTone
    get() = when (this) {
        SharedProgramStatusAttention.NEEDS_INPUT -> ProgramAttentionTone.NEEDS_INPUT
        SharedProgramStatusAttention.FAILED -> ProgramAttentionTone.FAILED
        SharedProgramStatusAttention.FINISHED -> ProgramAttentionTone.FINISHED
    }

/** One merged cue per terminal, retaining the native blocked vocabulary. */
data class ProgramAttention(
    val tone: ProgramAttentionTone,
    val kind: SharedProgramStatusBlockedKind? = null,
)

val SharedProgramStatusTerminalSnapshot.programAttention: ProgramAttention?
    get() = attention?.let { ProgramAttention(it.tone, blockedKind) }

private val SharedProgramStatusTerminal.paneNumber: Int?
    get() = (this as? SharedProgramStatusTerminal.Pane)?.paneId

/** Where a pane sits; position is one-based in the visible tab order. */
data class ProgramStatusPaneLocation(
    val windowId: Int,
    val windowPosition: Int,
    val windowName: String,
)

/** Uses the tab's live display name, with its position kept separately. */
fun programStatusPaneLocations(snapshot: SharedTmuxSnapshot): Map<Int, ProgramStatusPaneLocation> =
    buildMap {
        snapshot.windows.forEachIndexed { index, window ->
            val location = ProgramStatusPaneLocation(window.id, index + 1, window.displayName)
            window.panes.forEach { put(it.id, location) }
            window.activePaneId?.let { put(it, location) }
        }
    }

data class ProgramStatusPaneRef(val hostId: String, val paneId: Int?)

data class ProgramStatusAgentPane(
    val windowId: Int?,
    val needsInput: Boolean,
    val unreadCompletion: Boolean,
)

/** App-owned Agent Center projection. Pass [NONE] when Agent Center is off. */
data class ProgramStatusAgentInput(
    val waiting: Int = 0,
    val finished: Int = 0,
    val panes: Map<ProgramStatusPaneRef, ProgramStatusAgentPane> = emptyMap(),
) {
    companion object { val NONE = ProgramStatusAgentInput() }
}

/** Native live work owns the cue; otherwise urgency wins, native first on ties. */
object ProgramAttentionMerge {
    fun attention(
        agentNeedsInput: Boolean,
        agentUnreadCompletion: Boolean,
        program: SharedProgramStatusTerminalSnapshot?,
    ): ProgramAttention? {
        val native = program?.programAttention
        if (program?.entries?.any {
                !it.isHistorical &&
                    (it.state == SharedProgramStatusState.WORKING || it.state == SharedProgramStatusState.BLOCKED)
            } == true
        ) return native
        val agent = when {
            agentNeedsInput -> ProgramAttention(ProgramAttentionTone.NEEDS_INPUT)
            agentUnreadCompletion -> ProgramAttention(ProgramAttentionTone.FINISHED)
            else -> null
        }
        return listOfNotNull(native, agent).minByOrNull { it.tone }
    }
}

/** Chip, badge and session counts. Specific words require every waiting kind to agree. */
class ProgramAttentionCounts(
    var needsInput: Int = 0,
    var failed: Int = 0,
    var finished: Int = 0,
) {
    private val kinds = mutableSetOf<SharedProgramStatusBlockedKind?>().apply {
        if (needsInput > 0) add(null)
    }
    val needsInputKinds: Set<SharedProgramStatusBlockedKind?> get() = kinds.toSet()
    val uniformNeedsInputKind: SharedProgramStatusBlockedKind? get() = kinds.singleOrNull()
    val total: Int get() = needsInput + failed + finished
    val tone: ProgramAttentionTone?
        get() = when {
            needsInput > 0 -> ProgramAttentionTone.NEEDS_INPUT
            failed > 0 -> ProgramAttentionTone.FAILED
            finished > 0 -> ProgramAttentionTone.FINISHED
            else -> null
        }

    fun add(attention: ProgramAttention?, delta: Int = 1) {
        when (attention?.tone) {
            ProgramAttentionTone.NEEDS_INPUT -> {
                needsInput += delta
                if (delta > 0) kinds.add(attention.kind)
            }
            ProgramAttentionTone.FAILED -> failed += delta
            ProgramAttentionTone.FINISHED -> finished += delta
            null -> Unit
        }
    }

    override fun equals(other: Any?): Boolean = other is ProgramAttentionCounts &&
        needsInput == other.needsInput && failed == other.failed && finished == other.finished &&
        kinds == other.kinds

    override fun hashCode(): Int = 31 * (31 * (31 * needsInput + failed) + finished) + kinds.hashCode()
}

data class ProgramTerminalAttention(
    val windowId: Int?,
    val paneId: Int?,
    val hasAgent: Boolean,
    val attention: ProgramAttention?,
    val program: SharedProgramStatusTerminalSnapshot?,
)

data class ProgramAttentionItem(
    val hostId: String,
    val hostLabel: String,
    val terminal: SharedProgramStatusTerminal,
    val location: ProgramStatusPaneLocation?,
    val attention: ProgramAttention,
    val entry: SharedProgramStatusEntry?,
    val hasAgent: Boolean = false,
    val status: ProgramStatusStatusWords,
) {
    val id: String get() = "$hostId|${terminal.paneNumber?.let { "%$it" } ?: "raw"}"
    val tone: ProgramAttentionTone get() = attention.tone
}

data class ProgramStatusSessionState(
    val hostLabel: String,
    val snapshot: SharedProgramStatusSnapshot,
    val locations: Map<Int, ProgramStatusPaneLocation>,
)

/**
 * Every live session's chrome projection. Visiting a presented terminal checks
 * unread results while active; queries and lists acknowledge nothing.
 *
 * State mutations are serialized across threads. Callbacks run after releasing
 * the state lock, so a native acknowledgement may synchronously publish again.
 */
class ProgramStatusCenter {
    private val lock = Any()
    private val mutableSessions = MutableStateFlow<Map<String, ProgramStatusSessionState>>(emptyMap())
    val sessions: StateFlow<Map<String, ProgramStatusSessionState>> = mutableSessions.asStateFlow()
    private val acknowledgers = mutableMapOf<String, (SharedProgramStatusTerminal, Long) -> Unit>()
    private val presented = mutableMapOf<String, Set<SharedProgramStatusTerminal>>()
    private var applicationActive = true
    private data class PresentedCheck(
        val hostId: String,
        val terminal: SharedProgramStatusTerminal,
        val token: Long,
        val acknowledge: (SharedProgramStatusTerminal, Long) -> Unit,
    )

    @Volatile
    var onOpenTerminal: ((hostId: String, windowId: Int?, paneId: Int?) -> Unit)? = null

    fun publish(
        hostId: String,
        state: ProgramStatusSessionState,
        acknowledge: (SharedProgramStatusTerminal, Long) -> Unit,
    ) {
        val checks = synchronized(lock) {
            acknowledgers[hostId] = acknowledge
            // Keep live locations even without native reports: fallback agents use the same routes.
            if (mutableSessions.value[hostId] != state) {
                mutableSessions.value = mutableSessions.value + (hostId to state)
            }
            presentedChecks(hostId)
        }
        dispatchChecks(checks)
    }

    fun remove(hostId: String) {
        synchronized(lock) {
            if (hostId in mutableSessions.value) mutableSessions.value = mutableSessions.value - hostId
            acknowledgers.remove(hostId)
            presented.remove(hostId)
        }
    }

    fun setPresented(hostId: String, terminals: Set<SharedProgramStatusTerminal>) {
        val checks = synchronized(lock) {
            val next = terminals.takeIf { it.isNotEmpty() }?.toSet()
            if (presented[hostId] == next) return
            if (next == null) presented.remove(hostId) else presented[hostId] = next
            presentedChecks(hostId)
        }
        dispatchChecks(checks)
    }

    fun setApplicationActive(active: Boolean) {
        val checks = synchronized(lock) {
            applicationActive = active
            if (active) presented.keys.flatMap { presentedChecks(it) } else emptyList()
        }
        dispatchChecks(checks)
    }

    /** Called under the lock; capture tokens before callbacks can publish new state. */
    private fun presentedChecks(hostId: String): List<PresentedCheck> {
        if (!applicationActive) return emptyList()
        val state = mutableSessions.value[hostId] ?: return emptyList()
        val acknowledge = acknowledgers[hostId] ?: return emptyList()
        return presented[hostId].orEmpty().mapNotNull { terminal ->
            state.snapshot.terminal(terminal)?.latestUnreadResultToken?.let { token ->
                PresentedCheck(hostId, terminal, token, acknowledge)
            }
        }
    }

    /** Reentry may hide/remove another terminal; prove each check at dispatch. */
    private fun dispatchChecks(checks: List<PresentedCheck>) {
        for (check in checks) {
            val current = synchronized(lock) {
                applicationActive && check.terminal in presented[check.hostId].orEmpty() &&
                    acknowledgers[check.hostId] === check.acknowledge &&
                    mutableSessions.value[check.hostId]?.snapshot?.terminal(check.terminal)
                        ?.latestUnreadResultToken == check.token
            }
            if (current) check.acknowledge(check.terminal, check.token)
        }
    }

    fun open(item: ProgramAttentionItem) = openTerminal(item.hostId, item.terminal)

    /** Re-proves the live route; navigation never starts a connection. */
    fun openTerminal(hostId: String, terminal: SharedProgramStatusTerminal) {
        val route = synchronized(lock) {
            val state = mutableSessions.value[hostId] ?: return
            val paneId = terminal.paneNumber
            val location = paneId?.let { state.locations[it] }
            if (paneId != null && location == null) return
            location?.windowId to paneId
        }
        onOpenTerminal?.invoke(hostId, route.first, route.second)
    }
}

data class ProgramStatusDetailEntry(val entry: SharedProgramStatusEntry, val location: ProgramStatusPaneLocation?)
data class ProgramWindowCue(val hasAgent: Boolean, val tone: ProgramAttentionTone?) {
    fun iconTone(active: Boolean): ProgramAttentionTone? = tone?.takeIf {
        it == ProgramAttentionTone.NEEDS_INPUT || !active
    }
    fun titleTone(active: Boolean): ProgramAttentionTone? = tone?.takeIf {
        !active && it != ProgramAttentionTone.NEEDS_INPUT
    }
}

/** Pure queries over the collected projection, mirroring iOS ProgramStatusCenter. */
object ProgramStatusQueries {
    fun programItems(
        sessions: Map<String, ProgramStatusSessionState>,
        agents: ProgramStatusAgentInput = ProgramStatusAgentInput.NONE,
    ): List<ProgramAttentionItem> = (sessions.keys + agents.panes.keys.map { it.hostId }).flatMap { hostId ->
        val state = sessions[hostId]
        mergedTerminals(sessions, hostId, agents).mapNotNull { terminal ->
            val attention = terminal.attention ?: return@mapNotNull null
            val key = terminal.paneId?.let { SharedProgramStatusTerminal.Pane(it) } ?: SharedProgramStatusTerminal.Raw
            val entry = terminal.program?.primaryEntry
            ProgramAttentionItem(hostId, state?.hostLabel ?: hostId, key,
                terminal.paneId?.let { state?.locations?.get(it) }, attention,
                entry?.takeIf { terminal.program?.programAttention == attention }, terminal.hasAgent,
                checkNotNull(ProgramStatusWordsModel.status(terminal)))
        }
    }.sortedWith(compareBy<ProgramAttentionItem> { it.tone }
        .thenBy { it.hostLabel }.thenBy { it.location?.windowPosition ?: 0 })

    fun detailEntries(
        sessions: Map<String, ProgramStatusSessionState>,
        hostId: String,
    ): List<ProgramStatusDetailEntry> {
        val state = sessions[hostId] ?: return emptyList()
        return state.snapshot.terminals.flatMap { terminal ->
            terminal.entries.map { ProgramStatusDetailEntry(it,
                terminal.terminal.paneNumber?.let { pane -> state.locations[pane] }) }
        }.sortedWith(compareBy<ProgramStatusDetailEntry> { it.entry.attention?.tone?.ordinal ?: 3 }
            .thenBy { it.location?.windowPosition ?: 0 })
    }

    fun mergedTerminals(
        sessions: Map<String, ProgramStatusSessionState>,
        hostId: String,
        agents: ProgramStatusAgentInput = ProgramStatusAgentInput.NONE,
    ): List<ProgramTerminalAttention> {
        val state = sessions[hostId]
        val remaining = agents.panes.filterKeys { it.hostId == hostId }.toMutableMap()
        return buildList {
            state?.snapshot?.terminals.orEmpty().forEach { terminal ->
                val paneId = terminal.terminal.paneNumber
                val agent = remaining.remove(ProgramStatusPaneRef(hostId, paneId))
                val windowId = paneId?.let { state?.locations?.get(it)?.windowId }
                add(ProgramTerminalAttention(windowId ?: agent?.windowId, paneId, agent != null,
                    if (agent == null) terminal.programAttention else ProgramAttentionMerge.attention(
                        agent.needsInput, agent.unreadCompletion, terminal), terminal))
            }
            remaining.forEach { (ref, agent) ->
                add(ProgramTerminalAttention(agent.windowId, ref.paneId, true,
                    ProgramAttentionMerge.attention(agent.needsInput, agent.unreadCompletion, null), null))
            }
        }
    }

    fun windowCue(
        sessions: Map<String, ProgramStatusSessionState>,
        hostId: String,
        windowId: Int,
        agents: ProgramStatusAgentInput = ProgramStatusAgentInput.NONE,
    ): ProgramWindowCue {
        val terminals = mergedTerminals(sessions, hostId, agents).filter { it.windowId == windowId }
        return ProgramWindowCue(terminals.any { it.hasAgent }, terminals.mapNotNull { it.attention?.tone }.minOrNull())
    }

    fun windowStatus(
        sessions: Map<String, ProgramStatusSessionState>,
        hostId: String,
        windowId: Int,
        agents: ProgramStatusAgentInput = ProgramStatusAgentInput.NONE,
    ): ProgramStatusStatusWords? {
        val terminals = mergedTerminals(sessions, hostId, agents).filter { it.windowId == windowId }
        val urgent = terminals.filter { it.attention != null }.minByOrNull { it.attention!!.tone }
        return (urgent ?: terminals.firstOrNull { it.program != null })?.let { ProgramStatusWordsModel.status(it) }
    }

    fun paneStatus(
        sessions: Map<String, ProgramStatusSessionState>,
        hostId: String,
        paneId: Int,
        agents: ProgramStatusAgentInput = ProgramStatusAgentInput.NONE,
    ): ProgramStatusStatusWords? = mergedTerminals(sessions, hostId, agents)
        .firstOrNull { it.paneId == paneId }?.let { ProgramStatusWordsModel.status(it) }

    fun sessionCounts(
        sessions: Map<String, ProgramStatusSessionState>,
        hostId: String,
        agents: ProgramStatusAgentInput = ProgramStatusAgentInput.NONE,
    ): ProgramAttentionCounts = ProgramAttentionCounts().apply {
        mergedTerminals(sessions, hostId, agents).forEach { add(it.attention) }
    }

    fun counts(
        sessions: Map<String, ProgramStatusSessionState>,
        agents: ProgramStatusAgentInput = ProgramStatusAgentInput.NONE,
    ): ProgramAttentionCounts = ProgramAttentionCounts(needsInput = agents.waiting, finished = agents.finished).apply {
        // Agent Center's counts include agents with no live pane row; adjust
        // only where a bound agent's pane also reports, exactly as on iOS.
        sessions.forEach { (hostId, state) ->
            state.snapshot.terminals.forEach { terminal ->
                val agent = agents.panes[ProgramStatusPaneRef(hostId, terminal.terminal.paneNumber)]
                if (agent == null) {
                    add(terminal.programAttention)
                } else {
                    val before = ProgramAttentionMerge.attention(agent.needsInput, agent.unreadCompletion, null)
                    val merged = ProgramAttentionMerge.attention(agent.needsInput, agent.unreadCompletion, terminal)
                    if (before?.tone != merged?.tone) {
                        add(before, -1)
                        add(merged)
                    }
                }
            }
        }
        needsInput = needsInput.coerceAtLeast(0)
        finished = finished.coerceAtLeast(0)
    }
}

/** Resource-free vocabulary; only the resolvers below know about Compose. */
sealed interface ProgramStatusPhrase {
    data class Blocked(val kind: SharedProgramStatusBlockedKind?) : ProgramStatusPhrase
    data object Failed : ProgramStatusPhrase
    data object Finished : ProgramStatusPhrase
    data object Ready : ProgramStatusPhrase
    data object Working : ProgramStatusPhrase
    data object Unavailable : ProgramStatusPhrase
    data object Program : ProgramStatusPhrase
    data class Literal(val text: String) : ProgramStatusPhrase
}

data class ProgramStatusStatusWords(
    val app: String?,
    val phrase: ProgramStatusPhrase,
    val progress: Int?,
    val tone: ProgramAttentionTone?,
)

enum class CountKind { NEED_INPUT, NEED_APPROVAL, NEED_ANSWER, NEED_SIGN_IN, FAILED, FINISHED }
data class ProgramCountPart(val kind: CountKind, val count: Int, val tone: ProgramAttentionTone)

object ProgramStatusWordsModel {
    fun state(entry: SharedProgramStatusEntry): ProgramStatusPhrase = if (entry.isHistorical) {
        ProgramStatusPhrase.Unavailable
    } else when (entry.state) {
        SharedProgramStatusState.IDLE -> ProgramStatusPhrase.Ready
        SharedProgramStatusState.WORKING -> ProgramStatusPhrase.Working
        SharedProgramStatusState.BLOCKED -> ProgramStatusPhrase.Blocked(entry.kind)
        SharedProgramStatusState.DONE -> ProgramStatusPhrase.Finished
        SharedProgramStatusState.ERROR -> ProgramStatusPhrase.Failed
    }

    fun attention(attention: ProgramAttention): ProgramStatusPhrase = when (attention.tone) {
        ProgramAttentionTone.NEEDS_INPUT -> ProgramStatusPhrase.Blocked(attention.kind)
        ProgramAttentionTone.FAILED -> ProgramStatusPhrase.Failed
        ProgramAttentionTone.FINISHED -> ProgramStatusPhrase.Finished
    }

    fun progressPercent(entry: SharedProgramStatusEntry): Int? = entry.progress.takeUnless { entry.isHistorical }

    fun name(entry: SharedProgramStatusEntry, windowName: String?): ProgramStatusPhrase =
        listOfNotNull(entry.title, entry.app, windowName).firstOrNull { it.isNotEmpty() }
            ?.let { ProgramStatusPhrase.Literal(it) } ?: ProgramStatusPhrase.Program

    /** Uses entry state/progress only when its attention is the merged verdict. */
    fun status(terminal: ProgramTerminalAttention): ProgramStatusStatusWords? {
        val entry = terminal.program?.primaryEntry
        val attention = terminal.attention
        if (attention == null && entry == null) return null
        val native = entry?.attention?.let {
            ProgramAttention(it.tone, if (it == SharedProgramStatusAttention.NEEDS_INPUT) entry.kind else null)
        }
        val useEntry = entry != null && (attention == null || native == attention)
        return ProgramStatusStatusWords(entry?.app,
            if (useEntry) state(entry!!) else this.attention(attention!!),
            if (useEntry) progressPercent(entry!!) else null, attention?.tone)
    }

    fun countParts(counts: ProgramAttentionCounts, specificKinds: Boolean = false): List<ProgramCountPart> = buildList {
        if (counts.needsInput > 0) {
            val kind = when (if (specificKinds) counts.uniformNeedsInputKind else null) {
                SharedProgramStatusBlockedKind.PERMISSION -> CountKind.NEED_APPROVAL
                SharedProgramStatusBlockedKind.QUESTION -> CountKind.NEED_ANSWER
                SharedProgramStatusBlockedKind.AUTH -> CountKind.NEED_SIGN_IN
                null -> CountKind.NEED_INPUT
            }
            add(ProgramCountPart(kind, counts.needsInput, ProgramAttentionTone.NEEDS_INPUT))
        }
        if (counts.failed > 0) add(ProgramCountPart(CountKind.FAILED, counts.failed, ProgramAttentionTone.FAILED))
        if (counts.finished > 0) add(ProgramCountPart(CountKind.FINISHED, counts.finished, ProgramAttentionTone.FINISHED))
    }
}

@Composable
fun programStatusText(phrase: ProgramStatusPhrase): String = when (phrase) {
    is ProgramStatusPhrase.Literal -> phrase.text
    is ProgramStatusPhrase.Blocked -> stringResource(when (phrase.kind) {
        SharedProgramStatusBlockedKind.PERMISSION -> R.string.program_status_needs_approval
        SharedProgramStatusBlockedKind.QUESTION -> R.string.program_status_needs_answer
        SharedProgramStatusBlockedKind.AUTH -> R.string.program_status_sign_in_needed
        null -> R.string.program_status_needs_input
    })
    ProgramStatusPhrase.Failed -> stringResource(R.string.program_status_failed)
    ProgramStatusPhrase.Finished -> stringResource(R.string.program_status_finished)
    ProgramStatusPhrase.Ready -> stringResource(R.string.program_status_ready)
    ProgramStatusPhrase.Working -> stringResource(R.string.program_status_working)
    ProgramStatusPhrase.Unavailable -> stringResource(R.string.program_status_unavailable)
    ProgramStatusPhrase.Program -> stringResource(R.string.program_status_program)
}

@Composable
fun programStatusLine(entry: SharedProgramStatusEntry): String {
    val state = programStatusText(ProgramStatusWordsModel.state(entry))
    val progress = ProgramStatusWordsModel.progressPercent(entry)?.let {
        NumberFormat.getPercentInstance().apply { maximumFractionDigits = 0 }.format(it / 100.0)
    }
    return listOfNotNull(entry.app?.takeIf { it.isNotEmpty() }, state, progress).joinToString(" · ")
}

/** Each count part's words with its tone: "1 needs approval", "1 failed". */
@Composable
fun programStatusCountTexts(
    counts: ProgramAttentionCounts,
    specificKinds: Boolean = false,
): List<Pair<String, ProgramAttentionTone>> = ProgramStatusWordsModel.countParts(counts, specificKinds).map { part ->
    val resource = when (part.kind) {
        CountKind.NEED_INPUT -> R.plurals.program_status_count_need_input
        CountKind.NEED_APPROVAL -> R.plurals.program_status_count_need_approval
        CountKind.NEED_ANSWER -> R.plurals.program_status_count_need_answer
        CountKind.NEED_SIGN_IN -> R.plurals.program_status_count_need_sign_in
        CountKind.FAILED -> R.plurals.program_status_count_failed
        CountKind.FINISHED -> R.plurals.program_status_count_finished
    }
    pluralStringResource(resource, part.count, part.count) to part.tone
}

@Composable
fun programStatusCountSummary(counts: ProgramAttentionCounts, specificKinds: Boolean = false): String =
    programStatusCountTexts(counts, specificKinds).joinToString(" · ") { it.first }

/** Session-row counts, each part in its own tint (the chip uses one tint for the whole summary). */
@Composable
fun programStatusCountLine(counts: ProgramAttentionCounts, specificKinds: Boolean = true): AnnotatedString {
    val parts = programStatusCountTexts(counts, specificKinds).map { (text, tone) -> text to programStatusToneColor(tone) }
    val separator = LocalTesseraTokens.current.fgDim
    return buildAnnotatedString {
        parts.forEachIndexed { index, (text, color) ->
            if (index > 0) withStyle(SpanStyle(color = separator)) { append(" · ") }
            withStyle(SpanStyle(color = color)) { append(text) }
        }
    }
}
