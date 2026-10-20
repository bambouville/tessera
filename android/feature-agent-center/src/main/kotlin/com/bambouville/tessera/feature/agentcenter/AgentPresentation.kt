package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.core.bridge.SharedAgentSnapshot
import com.bambouville.tessera.core.bridge.SharedAgentSnapshotKind
import com.bambouville.tessera.core.bridge.SharedAgentValue
import com.bambouville.tessera.core.bridge.SharedAgentReadStatus
import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import org.json.JSONObject
import java.util.Locale

/** Immutable, display-only projection of a snapshot already reduced by Agent Core. */
data class AgentCenterUiState(
    val loading: Boolean = true,
    val ingestionCapacityThreads: Set<String> = emptySet(),
    val ingestionReadStatuses: Map<String, SharedAgentReadStatus> = emptyMap(),
    val unavailableReason: String? = null,
    val threads: List<AgentThreadRow> = emptyList(),
    /** Live provider-like terminals lacking a proven durable conversation ID. */
    val candidates: List<AgentTerminalCandidate> = emptyList(),
    val selectedThreadKey: String? = null,
    /** Mirrors the persisted shared-runtime grouping, never a client-side sort. */
    val grouping: String = "attention",
    /** View-only DataStore choices; never fed back into shared reduction. */
    val showSystemEvents: Boolean = false,
    val compactTab: String = "live",
    val detail: AgentThreadDetail? = null,
    /**
     * Ephemeral projection details keyed by the shared thread identity.  This
     * lets a compact list expose a newly projected urgent prompt without first
     * navigating into its detail screen.  It is deliberately not persisted.
     */
    val projectedDetails: Map<String, AgentThreadDetail> = emptyMap(),
    val searchQuery: String = "",
    val searchResults: List<AgentSearchResultRow> = emptyList(),
    val unavailableSearchHostCount: Int = 0,
    val notice: String? = null,
    /** The exact current notice carrying a one-shot composer-verification retry. */
    val sendAnywayNotice: String? = null,
    val acceptedSend: AgentAcceptedSend? = null,
    /** Drafts outlive the composed detail and native picker, but stay device-local. */
    val drafts: Map<String, String> = emptyMap(),
    val sendingThreads: Set<String> = emptySet(),
    val pendingActionInFlight: Boolean = false,
    /** Threads with an action in flight; each thread gates only its own prompt controls. */
    val actionThreads: Set<String> = emptySet(),
    val uploadingThreads: Set<String> = emptySet(),
    val loadingTranscriptThreads: Set<String> = emptySet(),
)

/** Core's list tick: new rows and candidates, but no transcript. */
internal fun AgentCenterUiState.withListSnapshot(
    rows: List<AgentThreadRow>,
    candidates: List<AgentTerminalCandidate>,
    retained: AgentHistoricalSelection,
): AgentCenterUiState {
    val rowsByKey = rows.associateBy { it.key }
    val projectedDetails = projectedDetails.filterKeys(retained.retainedDetailKeys::contains)
        .mapValues { it.value.withListedTitle(rowsByKey[it.value.row.key]) }
    val selected = retained.selectedThreadKey
    return copy(
        loading = false,
        threads = rows,
        candidates = candidates,
        selectedThreadKey = selected,
        // Core lists live routes, while an authenticated endpoint
        // owner may still safely back a historical projection.
        // Retain only those two canonical sources of validity.
        detail = detail?.takeIf { it.row.key == selected }?.let { it.withListedTitle(rowsByKey[it.row.key]) }
            ?: selected?.let(projectedDetails::get),
        projectedDetails = projectedDetails,
    )
}

/**
 * Summary/title updates emit a bounded list, not another transcript. Refresh
 * header text without replacing the retained page, lease, prompt, or action
 * capabilities. An unchanged title keeps this instance: Compose compares a
 * detail (it holds Lists) by identity, so a copy would recompose the selected
 * transcript on every other agent's list tick.
 */
internal fun AgentThreadDetail.withListedTitle(listed: AgentThreadRow?): AgentThreadDetail {
    if (listed == null || (listed.title == row.title && listed.titleProvenance == row.titleProvenance &&
            listed.titleSeed == row.titleSeed && listed.livePromptWatch == row.livePromptWatch)) return this
    return copy(row = row.copy(title = listed.title, titleProvenance = listed.titleProvenance,
        titleSeed = listed.titleSeed, livePromptWatch = listed.livePromptWatch))
}

/** One thread's snapshot replaces its row and projection; another selection's detail stays. */
internal fun AgentCenterUiState.withThreadSnapshot(detail: AgentThreadDetail): AgentCenterUiState {
    val detail = detail.withKnownFreshPrompt(projectedDetails[detail.row.key] ?: this.detail)
    val rows = threads.map { if (it.key == detail.row.key) detail.row else it }
    val mayReplaceDetail = selectedThreadKey == null || selectedThreadKey == detail.row.key
    return copy(
        loading = false,
        threads = if (rows == threads) threads else rows,
        selectedThreadKey = selectedThreadKey ?: detail.row.key,
        detail = if (mayReplaceDetail) detail else this.detail,
        projectedDetails = projectedDetails + (detail.row.key to detail),
    )
}

/** Retain display readiness only for the exact unchanged prompt and route.
 * Every action still captures and proves the live process again before writing. */
internal fun AgentThreadDetail.withKnownFreshPrompt(previous: AgentThreadDetail?): AgentThreadDetail {
    val current = prompt ?: return this
    val old = previous?.prompt ?: return this
    if (current.fresh != null || !row.actionAvailable || binding == null || binding != previous.binding ||
        row.key != previous.row.key || row.providerID != previous.row.providerID ||
        current != old.copy(fresh = current.fresh) || !previous.canAnswerPrompt()) return this
    return copy(prompt = current.copy(fresh = old.fresh))
}

data class AgentAcceptedSend(val token: String, val threadKey: String, val text: String)

data class AgentSearchResultRow(val threadKey: String, val recordID: String, val excerpt: String)

data class AgentTerminalCandidate(
    val key: String,
    val hostID: String,
    val providerID: String,
    val provider: String,
    val title: String,
    val host: String,
    val status: String,
    val location: String,
    val liveTail: String,
    val binding: SharedAgentValue.ObjectValue?,
    /** Candidate prompts stay bounded and become actionable only after a fresh terminal parse. */
    val prompt: AgentPrompt? = null,
)

data class AgentThreadRow(
    val key: String,
    val title: String,
    val provider: String,
    val model: String?,
    val preview: String?,
    val status: String,
    val attention: String,
    val location: String,
    val queuedCount: String?,
    val isFork: Boolean,
    val actionAvailable: Boolean,
    val spawnAvailable: Boolean,
    val forkAvailable: Boolean,
    val hostID: String = "",
    val providerID: String = "",
    val providerSessionID: String = "",
    /** Display metadata supplied by the shared summary; never used as identity. */
    val host: String = "",
    val permissionMode: String? = null,
    /** Authoritative summary meter fields, retained as bounded ABI display strings. */
    val contextPercent: String? = null,
    val contextUsedTokens: String? = null,
    val totalCost: String? = null,
    val linesAdded: String? = null,
    val linesRemoved: String? = null,
    /** Shared Core's Date value projected to Unix milliseconds for display only. */
    val lastActivityMillis: Long? = null,
    /**
     * How strong the current title is, from shared Core: placeholder, prompt,
     * generated or native/pinned. A row only wants an on-device summary while
     * it is below `generated`.
     */
    val titleProvenance: String = "placeholder",
    /** The opening user prompt, from shared Core, for on-device summarisation. */
    val titleSeed: String? = null,
    val livePromptWatch: Boolean = false,
)

data class AgentOutgoingMessage(val id: String, val text: String, val status: String)

data class AgentHistoryWindow(val version: Long, val atLiveHead: Boolean, val hasNewer: Boolean,
    val after: String?, val transition: String, val retainsOutgoing: Boolean = false,
    /** At the live head, with room in Core for another older page without evicting it. */
    val olderPageFits: Boolean = false,
    /** Reads as live, but its newest rows are shown, not retained; see `retainBridgedRows`. */
    val bridgesToHead: Boolean = false)

data class AgentThreadDetail(
    val row: AgentThreadRow,
    val live: List<AgentBlock>,
    val activity: List<AgentBlock>,
    val changes: List<AgentBlock>,
    val binding: SharedAgentValue.ObjectValue?,
    val hasMore: Boolean,
    val deliveryGeneration: Long = 0,
    /** Snapshot-provided prompt only; never a terminal macro or local authority. */
    val prompt: AgentPrompt? = null,
    /** Just-proven, ephemeral route paths; never persisted in Room. */
    val provenDirectories: List<String> = emptyList(),
    /** Shared-core grouping metadata, never inferred from rendered text. */
    val toolRuns: List<AgentToolRunDescriptor> = emptyList(),
    /** Shared reducer's oldest loaded continuation, not the last remote response. */
    val cursor: String? = null,
    val outgoingMessages: List<AgentOutgoingMessage> = emptyList(),
    val livePreview: String? = null,
    val livePreviewHasGap: Boolean = false,
    val window: AgentHistoryWindow? = null,
    /**
     * Shared Core's attention epoch: it moves only when the thread enters
     * needsYou or unreadCompletion, so one entry alerts once however often
     * `deliveryGeneration` moves. 0 when Core reported none.
     */
    val attentionEpoch: Long = 0,
    /** Content-free completion identities (hook source time and PID) to persist. */
    val unreadCompletionKey: String? = null,
    val acknowledgedCompletionKey: String? = null,
    /** Message presence is distinct from whether any message has renderable blocks. */
    val hasTranscriptMessages: Boolean = live.isNotEmpty(),
    val conversationEnded: Boolean = false,
)

/**
 * Identity of one alert. A repeat of the same attention entry maps to the
 * same key, so it neither re-notifies nor re-alerts.
 */
internal fun AgentThreadDetail.attentionDeliveryKey(): String? =
    if (attentionEpoch > 0) "${row.key}:${row.attention}:e$attentionEpoch"
    else deliveryGeneration.takeIf { it > 0 }?.let { "${row.key}:${row.attention}:g$it" }

/** Stable live carrier identity for root navigation; no terminal object crosses this boundary. */
fun AgentThreadDetail.liveSessionID(): String? = binding?.string("liveSessionID")?.canonicalAgentUUID()

/** Navigation may reveal an existing carrier, never reconnect a similarly named host. */
fun AgentThreadDetail.targetsLiveSession(hostID: String, liveSessionID: String?): Boolean =
    hostID.isNotBlank() && liveSessionID?.isNotBlank() == true &&
        row.hostID.canonicalAgentUUID() == hostID.canonicalAgentUUID() &&
        this.liveSessionID() == liveSessionID.canonicalAgentUUID()

/** UUID value identity across Swift/Java encoders; opaque route strings stay case-sensitive. */
internal fun String.canonicalAgentUUID(): String =
    if (length == 36) runCatching { java.util.UUID.fromString(this).toString() }.getOrDefault(this) else this

/** The notification route fence is the live transport carrier, not Core's per-thread delivery counter. */
internal fun AgentThreadDetail.liveCarrierGenerationOrNull(): Long? = binding
    ?.number("carrierGeneration")
    ?.toLongOrNull()
    ?.takeIf { it > 0 }

/** Raw SSH and Mosh each have one already-existing terminal rather than a selectable tmux pane. */
fun AgentThreadDetail.isRawSshTarget(): Boolean = binding?.string("transport") in setOf("ssh", "mosh")

/** Candidates use the same raw route semantics, but never acquire a thread identity. */
fun AgentTerminalCandidate.isRawTerminalTarget(): Boolean = binding?.string("transport") in setOf("ssh", "mosh")

data class AgentBlock(
    val title: String,
    val body: String,
    val kind: String = "event",
    val recordID: String? = null,
    /** Shared Core's Date value projected to Unix milliseconds for display only. */
    val displayTimeMillis: Long? = null,
    /** Parent AgentMessage metadata drives the chat layout; blocks do not invent authorship. */
    val role: String = "assistant",
)

data class AgentPrompt(
    val title: String,
    val detail: String?,
    val actionToken: String,
    val options: List<AgentPromptOption>,
    /** Present only after a fresh endpoint capture was parsed by shared Core. */
    val fresh: AgentFreshPrompt? = null,
    val kind: String = "permission",
    val question: String? = null,
    val progress: String? = null,
    val controls: List<AgentPromptControl> = emptyList(),
    val entry: AgentPromptEntry? = null,
    val acceptsText: Boolean = false,
    val isBlocking: Boolean = true,
    val pendingCount: Int? = null,
)

data class AgentPromptOption(val id: String, val label: String, val isDefault: Boolean,
    val detail: String? = null, val role: String = "choice", val isChecked: Boolean? = null, val acceptsText: Boolean = false)
data class AgentPromptControl(val kind: String, val label: String, val isSelected: Boolean = false)
data class AgentPromptEntry(val optionID: String?, val text: String)
sealed interface AgentPromptAnswerChoice {
    data class Option(val id: String) : AgentPromptAnswerChoice
    data class Text(val text: String) : AgentPromptAnswerChoice
    data class Control(val kind: String) : AgentPromptAnswerChoice
}
data class AgentFreshPrompt(val signature: String, val options: List<AgentFreshPromptOption>, val kind: String = "permission")
data class AgentFreshPromptOption(val id: String, val label: String, val responseMacro: String, val isDefault: Boolean)

/**
 * A snapshot can make a prompt visible, but it is actionable only when Core
 * supplied a fresh parser result with the card's signature token. The
 * presenter asks Core to plan each write from another settled capture.
 */
fun AgentThreadDetail.canAnswerPrompt(): Boolean {
    val prompt = prompt ?: return false
    val fresh = prompt.fresh ?: return false
    return row.actionAvailable && livePromptActionToken(fresh.signature) == prompt.actionToken
}

internal object AgentPresentation {
    fun list(snapshot: SharedAgentSnapshot): List<AgentThreadRow> {
        if (snapshot.kind != SharedAgentSnapshotKind.List) return emptyList()
        return snapshot.payload.obj("list")?.array("threads").orEmpty().mapNotNull(::row)
    }

    fun candidates(snapshot: SharedAgentSnapshot): List<AgentTerminalCandidate> {
        if (snapshot.kind != SharedAgentSnapshotKind.List) return emptyList()
        return snapshot.payload.obj("list")?.array("candidates").orEmpty().mapNotNull(::candidate)
    }

    fun detail(snapshot: SharedAgentSnapshot): AgentThreadDetail? {
        if (snapshot.kind !in setOf(
                SharedAgentSnapshotKind.Thread,
                SharedAgentSnapshotKind.Lifecycle,
                SharedAgentSnapshotKind.Projection,
                SharedAgentSnapshotKind.ActionPlan,
            )
        ) return null
        val thread = snapshot.payload.obj("thread") ?: return null
        val row = row(thread.obj("summary") ?: return null) ?: return null
        return AgentThreadDetail(
            row = row,
            live = messageBlocks(thread.array("messages")),
            hasTranscriptMessages = !thread.array("messages").isNullOrEmpty(),
            conversationEnded = thread.bool("conversationEnded") == true,
            activity = activityBlocks(thread.array("activity")),
            changes = changeBlocks(thread.obj("changes")?.array("edits")),
            binding = thread.obj("binding"),
            hasMore = thread.bool("hasMore") ?: false,
            cursor = thread.string("cursor"),
            window = thread.obj("ingestionWindow")?.let { window ->
                AgentHistoryWindow(window.number("version")?.toLongOrNull() ?: 0,
                    window.bool("atLiveHead") == true, window.bool("hasNewer") == true,
                    window.string("after"), window.string("transition") ?: "bootstrap", window.bool("retainsOutgoing") == true,
                    window.bool("olderPageFits") == true, window.bool("bridgesToHead") == true)
            },
            deliveryGeneration = thread.number("deliveryGeneration")?.toLongOrNull() ?: 0,
            attentionEpoch = thread.number("attentionEpoch")?.toLongOrNull() ?: 0,
            unreadCompletionKey = thread.string("unreadCompletionKey"),
            acknowledgedCompletionKey = thread.string("acknowledgedCompletionKey"),
            prompt = prompt(thread.array("messages")),
            toolRuns = agentToolRunDescriptors(snapshot.payload.array("toolRuns")),
            livePreview = thread.obj("livePreview")?.string("text"),
            livePreviewHasGap = thread.obj("livePreview")?.bool("hasGap") ?: false,
            outgoingMessages = thread.array("outgoingMessages").orEmpty().mapNotNull { value ->
                val message = value as? SharedAgentValue.ObjectValue ?: return@mapNotNull null
                AgentOutgoingMessage(message.string("id") ?: return@mapNotNull null,
                    message.string("text") ?: return@mapNotNull null,
                    message.string("status") ?: return@mapNotNull null)
            },
        )
    }

    fun search(snapshot: SharedAgentSnapshot): Pair<List<AgentSearchResultRow>, Int> {
        if (snapshot.kind != SharedAgentSnapshotKind.Search) return emptyList<AgentSearchResultRow>() to 0
        val search = snapshot.payload.obj("search") ?: return emptyList<AgentSearchResultRow>() to 0
        val rows = search.array("results").orEmpty().mapNotNull { value ->
            val result = value as? SharedAgentValue.ObjectValue ?: return@mapNotNull null
            val id = result.obj("threadID") ?: return@mapNotNull null
            val host = id.string("hostID") ?: return@mapNotNull null
            val provider = id.obj("providerID")?.string("rawValue") ?: id.string("providerID") ?: return@mapNotNull null
            val session = id.string("providerSessionID") ?: return@mapNotNull null
            AgentSearchResultRow(
                threadKey = canonicalAgentThreadKey(host, provider, session),
                recordID = result.string("recordID") ?: return@mapNotNull null,
                excerpt = result.string("excerpt")?.take(16_384) ?: return@mapNotNull null,
            )
        }.take(100)
        return rows to search.array("unavailableHostIDs").orEmpty().size
    }

    private fun row(value: SharedAgentValue): AgentThreadRow? {
        val summary = value as? SharedAgentValue.ObjectValue ?: return null
        val id = summary.obj("id") ?: return null
        val hostID = id.string("hostID").orEmpty().canonicalAgentUUID()
        val providerID = id.obj("providerID")?.string("rawValue") ?: id.string("providerID") ?: return null
        val providerSessionID = id.string("providerSessionID") ?: return null
        val key = canonicalAgentThreadKey(hostID, providerID, providerSessionID)
        val availability = summary.obj("availability")
        return AgentThreadRow(
            key = key,
            title = summary.string("title") ?: "untitled",
            provider = summary.string("providerName") ?: "unknown",
            model = summary.string("model"),
            preview = summary.string("preview"),
            status = summary.string("status") ?: "unavailable",
            attention = summary.string("attention") ?: "none",
            location = listOfNotNull(summary.string("projectBasename"), summary.string("branch")).joinToString(" · "),
            queuedCount = summary.number("queuedMessageCount"),
            isFork = summary.bool("isFork") ?: false,
            actionAvailable = availability?.bool("actions") ?: false,
            spawnAvailable = availability?.bool("spawn") ?: false,
            forkAvailable = availability?.bool("fork") ?: false,
            hostID = hostID,
            providerID = providerID,
            providerSessionID = providerSessionID,
            host = summary.string("hostDisplayLabel").orEmpty(),
            // Presentation may hide an unavailable shared value, but never
            // feeds that choice back into Core's fail-closed capabilities.
            permissionMode = agentPermissionModeDisplay(summary.string("permissionMode")),
            contextPercent = summary.obj("context")?.number("percentUsed"),
            contextUsedTokens = summary.obj("context")?.number("usedTokens"),
            totalCost = summary.obj("cost")?.number("totalCost"),
            linesAdded = summary.obj("cost")?.number("linesAdded"),
            linesRemoved = summary.obj("cost")?.number("linesRemoved"),
            lastActivityMillis = summary.agentABIDateMillis("lastActivity"),
            titleProvenance = summary.titleProvenanceName(),
            titleSeed = summary.string("titleSeed"),
            livePromptWatch = summary.bool("livePromptWatch") == true,
        )
    }

    private fun candidate(value: SharedAgentValue): AgentTerminalCandidate? {
        val candidate = value as? SharedAgentValue.ObjectValue ?: return null
        val id = candidate.obj("id") ?: return null
        val hostID = id.string("hostID")?.canonicalAgentUUID() ?: return null
        val providerID = id.obj("providerID")?.string("rawValue") ?: return null
        val sourceIdentity = id.string("sourceIdentity") ?: return null
        val fallback = candidate.obj("fallback") ?: return null
        val binding = fallback.obj("binding")
        return AgentTerminalCandidate(
            key = "$hostID:$providerID:$sourceIdentity",
            hostID = hostID,
            providerID = providerID,
            provider = candidate.string("providerName") ?: providerID,
            title = candidate.string("title") ?: "live terminal",
            host = candidate.string("hostDisplayLabel").orEmpty(),
            status = fallback.string("status") ?: "unavailable",
            location = fallback.string("location").orEmpty(),
            liveTail = fallback.string("liveTail")?.take(16_384).orEmpty(),
            binding = binding,
            prompt = promptFromWire(fallback.obj("prompt")),
        )
    }

    internal fun promptFromWire(wire: SharedAgentValue.ObjectValue?): AgentPrompt? {
        val value = wire ?: return null
        val token = value.obj("token")?.string("rawValue") ?: value.string("actionToken") ?: return null
        val options = value.array("options").orEmpty().mapNotNull { option ->
            val item = option as? SharedAgentValue.ObjectValue ?: return@mapNotNull null
            val id = item.string("id") ?: return@mapNotNull null
            val label = item.string("label") ?: return@mapNotNull null
            AgentPromptOption(id, label, item.bool("isDefault") ?: item.bool("default") ?: false,
                item.string("detail"), item.string("role") ?: "choice", item.bool("isChecked"), item.bool("acceptsText") == true)
        }.take(9)
        val kind = value.string("kind") ?: "permission"
        return AgentPrompt(value.string("title") ?: "Permission requested", value.string("detail"), token, options,
            kind = kind, question = value.string("question"), progress = value.string("progress"),
            controls = value.array("controls").orEmpty().mapNotNull { control ->
                val item = control as? SharedAgentValue.ObjectValue ?: return@mapNotNull null
                AgentPromptControl(item.string("kind") ?: return@mapNotNull null,
                    item.string("label") ?: return@mapNotNull null, item.bool("isSelected") == true)
            },
            entry = value.obj("entry")?.let { AgentPromptEntry(it.string("optionID"), it.string("text").orEmpty()) },
            acceptsText = value.bool("acceptsText") == true, isBlocking = value.bool("isBlocking") != false,
            pendingCount = value.number("pendingCount")?.toIntOrNull())
            .takeIf { it.options.isNotEmpty() || kind in setOf("textEntry", "deferred") }
    }

    /**
     * Messages contain semantic AgentBlock enums, not display strings.  Preserve
     * their parent message record ID for read acknowledgement while exposing a
     * bounded normalized card to Compose.
     */
    private fun messageBlocks(messages: List<SharedAgentValue>?): List<AgentBlock> = messages.orEmpty().flatMap { message ->
        val envelope = message as? SharedAgentValue.ObjectValue ?: return@flatMap emptyList()
        val recordID = envelope.string("recordID") ?: envelope.string("id")
        // Swift's AgentRole is a string-backed enum. Older fixtures predate
        // message roles, and represent assistant transcript content.
        val role = envelope.string("role")?.takeIf { it in AGENT_MESSAGE_ROLES } ?: "assistant"
        val displayTimeMillis = envelope.agentABIDateMillis("displayTime")
        envelope.array("blocks").orEmpty().map { block ->
            semanticBlock(block, recordID, "message", role, displayTimeMillis)
        }
    }

    /** AgentActivityEvent has an authoritative title/detail pair. */
    private fun activityBlocks(events: List<SharedAgentValue>?): List<AgentBlock> = events.orEmpty().map { event ->
        val value = event as? SharedAgentValue.ObjectValue
        AgentBlock(
            title = value?.string("title") ?: value?.string("kind") ?: "activity",
            body = (value?.string("detail") ?: value?.string("title") ?: compact(event)).take(4_096),
            kind = value?.string("kind") ?: "activity",
            recordID = value?.string("id") ?: value?.string("recordID"),
            displayTimeMillis = value?.agentABIDateMillis("displayTime"),
        )
    }

    /** AgentChangeSummary is an edits array; files is a legacy non-ABI shape. */
    private fun changeBlocks(edits: List<SharedAgentValue>?): List<AgentBlock> = edits.orEmpty().map { edit ->
        val value = edit as? SharedAgentValue.ObjectValue
        val path = value?.string("path") ?: "change"
        val totals = listOfNotNull(
            value?.number("additions")?.let { "+$it" },
            value?.number("deletions")?.let { "−$it" },
        ).joinToString(" ")
        AgentBlock(
            title = path,
            body = listOfNotNull(path, totals.takeIf(String::isNotBlank), value?.string("diff")).joinToString("\n").take(4_096),
            kind = "change",
            recordID = value?.string("id") ?: value?.string("recordID"),
        )
    }

    /**
     * Decode Swift's synthesized Codable shape deliberately.  `AgentBlock` is
     * an associated-value enum, so `{ "text": { "_0": "hello" } }` and
     * `{ "toolCall": { "name": "Read", "preview": "…" } }` are not
     * generic display objects.  Treating them as such leaked `_0`, `type`, and
     * other wire labels into the transcript.
     */
    private fun semanticBlock(
        value: SharedAgentValue,
        recordID: String?,
        fallback: String,
        role: String = "assistant",
        displayTimeMillis: Long? = null,
    ): AgentBlock {
        val objectValue = value as? SharedAgentValue.ObjectValue
        val directKind = objectValue?.string("kind")
        val enumEntry = objectValue?.fields?.entries?.firstOrNull { (key, _) -> key in AGENT_BLOCK_KINDS }
        val semanticKind = directKind ?: enumEntry?.key ?: fallback
        val encoded = enumEntry?.value ?: objectValue
        val payload = encoded?.associatedValue() ?: encoded
        val rendered = renderSemanticBlock(semanticKind, payload)
        return AgentBlock(
            title = rendered.title.take(512),
            body = rendered.body.take(MAX_AGENT_BLOCK_BODY_CHARS),
            kind = semanticKind,
            recordID = recordID ?: objectValue?.string("recordID") ?: objectValue?.string("id"),
            displayTimeMillis = displayTimeMillis ?: objectValue?.agentABIDateMillis("displayTime"),
            role = role,
        )
    }

    private data class RenderedBlock(val title: String, val body: String)

    private fun renderSemanticBlock(kind: String, payload: SharedAgentValue?): RenderedBlock {
        val objectValue = payload as? SharedAgentValue.ObjectValue
        fun text(vararg names: String): String? = objectValue?.firstString(*names) ?: payload?.humanText()
        fun labeled(title: String, detail: String?): RenderedBlock = RenderedBlock(title, detail.orEmpty())
        return when (kind) {
            "text" -> labeled("", text("text", "content", "_0"))
            "thinking" -> labeled("thinking", text("text", "content", "_0"))
            "toolCall" -> {
                val name = objectValue?.firstString("name") ?: "tool"
                labeled(name, objectValue?.firstString("preview", "detail", "_1").orEmpty())
            }
            "toolResult" -> {
                val truncated = objectValue?.bool("truncated") == true
                labeled(if (truncated) "result · truncated" else "result", objectValue?.firstString("preview", "detail", "_0").orEmpty())
            }
            "edit" -> {
                val path = objectValue?.firstString("path") ?: "edit"
                labeled(path, objectValue?.firstString("diff", "preview").orEmpty())
            }
            "permission", "question" -> labeled(kind, text("title", "text", "_0"))
            "queuedMessage" -> labeled("queued message", text("text", "content", "_0"))
            "workflow" -> labeled("workflow", text("title", "text", "_0"))
            "subagent" -> {
                val id = objectValue?.firstString("agentID", "id") ?: "subagent"
                val type = objectValue?.firstString("agentType", "type")
                labeled(type ?: "subagent", id)
            }
            "systemEvent" -> labeled("system", text("text", "detail", "_0"))
            "compactSummary" -> labeled("context compacted", text("text", "detail", "_0"))
            "completion" -> labeled("completed", text("text", "detail", "_0") ?: "finished")
            "attachment" -> {
                val name = objectValue?.firstString("name") ?: "attachment"
                labeled(objectValue?.firstString("mediaType") ?: "attachment", name)
            }
            "actionPrompt" -> {
                val prompt = objectValue ?: payload as? SharedAgentValue.ObjectValue
                val title = prompt?.firstString("title") ?: "Action requested"
                val detail = prompt?.firstString("detail")
                val choices = prompt?.array("options").orEmpty().mapNotNull { option ->
                    (option as? SharedAgentValue.ObjectValue)?.firstString("label")
                }.joinToString(" · ")
                labeled(title, listOfNotNull(detail, choices.takeIf { it.isNotBlank() }).joinToString("\n"))
            }
            "workflowTasks" -> labeled("workflow", (payload as? SharedAgentValue.ArrayValue)?.values.orEmpty()
                .mapNotNull { task ->
                    (task as? SharedAgentValue.ObjectValue)?.let { item ->
                        listOfNotNull(item.firstString("title"), item.firstString("owner"), item.firstString("state"))
                            .joinToString(" · ").takeIf { it.isNotBlank() }
                    }
                }.joinToString("\n"))
            "subagentGroup" -> labeled("subagents", (payload as? SharedAgentValue.ArrayValue)?.values.orEmpty()
                .mapNotNull { subagent ->
                    (subagent as? SharedAgentValue.ObjectValue)?.let { item ->
                        val heading = listOfNotNull(item.firstString("type", "id"), item.firstString("status")).joinToString(" · ")
                        listOfNotNull(heading.takeIf(String::isNotBlank), item.firstString("summary")).joinToString("\n\n").takeIf(String::isNotBlank)
                    }
                }.joinToString("\n"))
            "unknown" -> labeled("unsupported event", objectValue?.firstString("type")?.take(128) ?: "unknown")
            else -> labeled("unsupported event", kind.take(128))
        }
    }

    private fun prompt(messages: List<SharedAgentValue>?): AgentPrompt? = messages.orEmpty().asSequence()
        .mapNotNull { it as? SharedAgentValue.ObjectValue }
        .flatMap { message -> message.array("blocks").orEmpty().asSequence() }
        .mapNotNull { block ->
            val objectValue = block as? SharedAgentValue.ObjectValue ?: return@mapNotNull null
            // Swift Codable may wrap an unlabeled associated value under `_0`:
            // {"actionPrompt":{"_0":{...}}}. Accept its direct equivalent
            // too, because the ABI is the reducer's public JSON boundary.
            val encoded = objectValue.obj("actionPrompt")
                ?: objectValue.takeIf { it.string("kind") == "actionPrompt" }
                ?: return@mapNotNull null
            val wire = encoded.obj("_0") ?: encoded
            promptFromWire(wire)
        // The newest projected prompt is the only actionable display candidate;
        // an earlier prompt may already have been answered in the terminal.
        }.lastOrNull()

    private fun compact(value: SharedAgentValue): String = when (value) {
        is SharedAgentValue.StringValue -> value.value
        is SharedAgentValue.NumberValue -> value.value
        is SharedAgentValue.BooleanValue -> value.value.toString()
        SharedAgentValue.Null -> ""
        is SharedAgentValue.ArrayValue -> value.values.joinToString(" ") { compact(it) }
        is SharedAgentValue.ObjectValue -> value.fields.entries.joinToString(" · ") { "${it.key}: ${compact(it.value)}" }
    }
}

/** Known Core modes get compact copy; absent and unproven modes are not displayed. */
internal fun agentPermissionModeDisplay(raw: String?): String? = when (raw?.lowercase(Locale.ROOT)) {
    "default", "defaultmode" -> "default"
    "auto" -> "auto"
    "plan" -> "plan"
    "readonly", "read-only" -> "read only"
    else -> null
}

/** A thread row's status dot tone. iOS `AgentThreadListView.statusColor` is the source of truth. */
internal enum class AgentStatusDotTone { Amber, Green, Faint }

/** Needing you outranks status; working and finished are both green; anything quieter is faint. */
internal fun agentStatusDotTone(status: String, attention: String): AgentStatusDotTone = when {
    attention == "needsYou" || status == "waitingForInput" -> AgentStatusDotTone.Amber
    status == "working" || status == "finished" -> AgentStatusDotTone.Green
    else -> AgentStatusDotTone.Faint
}

private const val MAX_AGENT_BLOCK_BODY_CHARS = 16_384
private val AGENT_MESSAGE_ROLES = setOf("user", "assistant", "system", "tool", "unknown")
private val AGENT_BLOCK_KINDS = setOf(
    "text", "thinking", "toolCall", "toolResult", "edit", "permission", "question", "queuedMessage",
    "workflow", "subagent", "systemEvent", "compactSummary", "completion", "attachment", "actionPrompt", "workflowTasks",
    "subagentGroup", "unknown",
)

private fun SharedAgentValue.associatedValue(): SharedAgentValue = when (this) {
    is SharedAgentValue.ObjectValue -> fields["_0"] ?: this
    else -> this
}

/** Known Codable content only: never render a wire object's field names to the user. */
private fun SharedAgentValue.humanText(): String? = when (this) {
    is SharedAgentValue.StringValue -> value
    is SharedAgentValue.ArrayValue -> values.mapNotNull { it.humanText() }.joinToString("\n").takeIf { it.isNotBlank() }
    else -> null
}

private fun SharedAgentValue.ObjectValue.firstString(vararg names: String): String? =
    names.asSequence().mapNotNull(::string).firstOrNull()

/** One spelling for every thread key: the data module's, shared with persistence. */
internal fun canonicalAgentThreadKey(hostID: String, providerID: String, providerSessionID: String): String =
    com.bambouville.tessera.data.canonicalAgentThreadKey(hostID, providerID, providerSessionID)

internal fun SharedAgentValue.ObjectValue.obj(name: String): SharedAgentValue.ObjectValue? =
    fields[name] as? SharedAgentValue.ObjectValue
internal fun SharedAgentValue.ObjectValue.array(name: String): List<SharedAgentValue>? =
    (fields[name] as? SharedAgentValue.ArrayValue)?.values
internal fun SharedAgentValue.ObjectValue.string(name: String): String? =
    (fields[name] as? SharedAgentValue.StringValue)?.value
internal fun SharedAgentValue.ObjectValue.number(name: String): String? =
    (fields[name] as? SharedAgentValue.NumberValue)?.value
internal fun SharedAgentValue.ObjectValue.bool(name: String): Boolean? =
    (fields[name] as? SharedAgentValue.BooleanValue)?.value

/**
 * `AgentRuntimeABI` uses JSONEncoder's Date representation, whose numeric
 * value is seconds from Apple's 2001 reference date.  Convert it once at the
 * display boundary; it is never an identity, ordering, or action value.
 */
internal fun SharedAgentValue.ObjectValue.agentABIDateMillis(name: String): Long? {
    val seconds = number(name)?.toDoubleOrNull() ?: return null
    val millis = seconds * 1_000.0 + AGENT_ABI_REFERENCE_EPOCH_MILLIS
    if (!millis.isFinite() || millis < MIN_AGENT_DISPLAY_TIME_MILLIS || millis > MAX_AGENT_DISPLAY_TIME_MILLIS) return null
    return millis.toLong()
}

/**
 * `AgentTitleProvenance` is a Swift `Int`-backed enum, so like every other
 * `RawRepresentable` without explicit CodingKeys it crosses the ABI as the bare
 * number rather than a wrapped object. Naming the tiers here keeps the rest of
 * the Android side reading the same words shared Core uses.
 */
internal fun SharedAgentValue.ObjectValue.titleProvenanceName(): String =
    when (number("titleProvenance")?.toDoubleOrNull()?.toInt()) {
        1 -> "prompt"
        2 -> "generated"
        3 -> "native"
        4 -> "pinned"
        else -> "placeholder"
    }

private const val AGENT_ABI_REFERENCE_EPOCH_MILLIS = 978_307_200_000.0
private const val MIN_AGENT_DISPLAY_TIME_MILLIS = -2_208_988_800_000.0 // 1900-01-01
private const val MAX_AGENT_DISPLAY_TIME_MILLIS = 7_258_118_400_000.0 // 2200-01-01

internal fun AgentTerminalCandidate.endpointBindingOrNull(): AgentEndpointBinding? {
    val encoded = binding?.toJson() ?: return null
    return JSONObject().put("binding", encoded).put("threadID", JSONObject().put("hostID", hostID)).endpointBindingOrNull()
}
