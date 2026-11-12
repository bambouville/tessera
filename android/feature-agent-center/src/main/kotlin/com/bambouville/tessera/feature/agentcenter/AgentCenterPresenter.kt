package com.bambouville.tessera.feature.agentcenter

import android.content.ComponentCallbacks2
import com.bambouville.tessera.agent.platform.AndroidAgentSessionCoordinator
import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointResult
import com.bambouville.tessera.agent.platform.AgentIssuedBinding
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentExecRequest
import com.bambouville.tessera.agent.platform.AgentProofProvider
import com.bambouville.tessera.agent.platform.AgentRemoteStreamDrain
import com.bambouville.tessera.agent.platform.AgentLifecycleFrame
import com.bambouville.tessera.agent.platform.AgentProcessDiscoveryCommands
import com.bambouville.tessera.agent.platform.AgentOccupancySnapshot
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationCoordinator
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationEvent
import com.bambouville.tessera.agent.platform.AgentTierACandidateRegistration
import com.bambouville.tessera.agent.platform.AgentSemanticKey
import com.bambouville.tessera.agent.platform.AgentSessionEndpoint
import com.bambouville.tessera.agent.platform.AgentSessionKey
import com.bambouville.tessera.agent.platform.AgentTerminalObservation
import com.bambouville.tessera.agent.platform.AgentTerminalFocusOutcome
import com.bambouville.tessera.agent.platform.terminalFocusOutcome
import com.bambouville.tessera.agent.platform.AgentTierCProvider
import com.bambouville.tessera.agent.platform.AgentTierCRemoteInventory
import com.bambouville.tessera.agent.platform.AgentTmuxPlacement
import com.bambouville.tessera.agent.platform.AgentTmuxLaunchReceipt
import com.bambouville.tessera.core.bridge.CoreCallResult
import com.bambouville.tessera.core.bridge.SharedAgentMarkdown
import com.bambouville.tessera.core.bridge.SharedAgentRuntime
import com.bambouville.tessera.core.bridge.SharedAgentHostSearch
import com.bambouville.tessera.core.bridge.SharedAgentPageSearch
import com.bambouville.tessera.core.bridge.SharedAgentInitialLoadPolicy
import com.bambouville.tessera.core.bridge.SharedAgentReadStatus
import com.bambouville.tessera.core.bridge.SharedAgentComposerEvidence
import com.bambouville.tessera.core.bridge.SharedAgentComposerEvidence.Assessment
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationParsing
import com.bambouville.tessera.core.bridge.SharedAgentLifecycleHookEvent
import com.bambouville.tessera.core.bridge.SharedAgentRuntimeEvent
import com.bambouville.tessera.core.bridge.SharedAgentSnapshot
import com.bambouville.tessera.core.bridge.SharedAgentSnapshotKind
import com.bambouville.tessera.core.bridge.SharedAgentValue
import com.bambouville.tessera.core.bridge.SharedAgentPromptAnswerStep
import com.bambouville.tessera.core.bridge.SharedTargetValidation
import com.bambouville.tessera.core.bridge.SharedTmuxTargetKind
import com.bambouville.tessera.data.AndroidAgentCenterViewPreferences
import com.bambouville.tessera.data.AndroidAgentMetadataRepository
import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject

/** `ActivityManager.MemoryInfo.totalMem` and `ActivityManager.isLowRamDevice`. */
data class AgentDeviceMemory(val physicalMemoryBytes: Long, val lowRAMDevice: Boolean)

/**
 * Android presentation adapter for the shared reducer. This class never ranks
 * threads, infers action safety, parses provider output, or performs SSH work;
 * it only preserves the latest canonical display snapshots and forwards intents.
 */
class AgentCenterPresenter(
    private val coordinator: AndroidAgentSessionCoordinator,
    private val metadata: AndroidAgentMetadataRepository,
    val viewPreferences: AndroidAgentCenterViewPreferences,
    private val scope: CoroutineScope,
    private val sessionIntegration: AgentSessionIntegrationCoordinator,
    /** Optional app delivery adapter; Core remains the source of attention state. */
    private val attentionNotifier: AndroidAgentAttentionNotifier? = null,
    /**
     * Optional diagnostics sink. Lifecycle admission has many silent refusals
     * and had no instrumentation at all, which made "Agent Center is empty"
     * indistinguishable from "no agent is running" in a device log.
     */
    private val diagnostics: ((String, Map<String, String>) -> Unit)? = null,
    /**
     * The middle tier of the title waterfall. Absent, or reporting that the
     * device has no model, the list keeps shared Core's clipped opening prompt.
     */
    private val titleGenerator: AgentTitleGenerator? = null,
    /**
     * Physical memory reported to shared Core, which owns the transcript
     * retention tiers. Absent, Core keeps its compact default.
     */
    private val deviceMemory: AgentDeviceMemory? = null,
) : AutoCloseable {
    private val mutableState = MutableStateFlow(AgentCenterUiState())
    val state: StateFlow<AgentCenterUiState> = mutableState.asStateFlow()
    private val mutablePaneAgentProviders = MutableStateFlow<Map<AgentSessionKey, Map<Int, String>>>(emptyMap())
    val paneAgentProviders: StateFlow<Map<AgentSessionKey, Map<Int, String>>> = mutablePaneAgentProviders.asStateFlow()

    private fun refreshPaneAgentProviders() {
        mutablePaneAgentProviders.value = derivePaneAgentProviders(
            enabled, mutableState.value.projectedDetails, threadOwners, coordinator.directory,
        )
    }

    private var runtime: SharedAgentRuntime? = null
    private var observer: Job? = null
    private var sessionObserver: Job? = null
    private var integrationEventObserver: Job? = null
    private var viewPreferencesObserver: Job? = null
    private val endpointObservers = linkedMapOf<AgentSessionKey, Job>()
    private val tierCInventoryJobs = ConcurrentHashMap<AgentSessionKey, Job>()
    private val tierCInventoryBindings = ConcurrentHashMap<AgentSessionKey, AgentEndpointBinding>()
    private val tierCConformances = ConcurrentHashMap<AgentSessionKey, TierCEndpointConformance>()
    private val tierACandidateJobs = ConcurrentHashMap<AgentSessionKey, Job>()
    private val tierACandidateBindings = ConcurrentHashMap<AgentSessionKey, AgentEndpointBinding>()
    private val tierACandidates = ConcurrentHashMap<AgentSessionKey, Map<String, AgentTierACandidateRegistration>>()
    private val threadOwners = ConcurrentHashMap<String, ThreadOwner>()
    private data class PendingOwner(val owner: ThreadOwner, val accepted: CompletableDeferred<Boolean>)
    private val pendingOwners = ConcurrentHashMap<String, PendingOwner>()
    private val ownerBindingLocks = ConcurrentHashMap<String, Mutex>()
    private val retiredOwnerThreads = ConcurrentHashMap.newKeySet<String>()
    /** Catalog observations retired here; Core retires their tokens later, on replacement. */
    private val retiredObservationTokens = ConcurrentHashMap.newKeySet<String>()
    private val endedConversations = ConcurrentHashMap.newKeySet<String>()
    private val occupancySweepJobs = ConcurrentHashMap<AgentSessionKey, Job>()
    private val occupancySweepLocks = ConcurrentHashMap<AgentSessionKey, Mutex>()
    private val occupancyRetirements = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
    /** Runtime-minted authority tokens, indexed by thread and canonical binding. */
    private val bindingTokens = ConcurrentHashMap<String, String>()
    private val pendingActions = ConcurrentHashMap<String, PendingAction>()
    private var composerRetryGeneration = 0L
    private var sendAnywayCandidate: SendAnywayCandidate? = null
    /** Candidates wait for Core to prove that the original bubble was withdrawn. */
    private val composerRefusals = ConcurrentHashMap<String, SendAnywayCandidate>()
    private val pendingActionRequests = java.util.concurrent.ConcurrentLinkedQueue<PendingAction>()
    private val actionRequestOrderReliable = java.util.concurrent.atomic.AtomicBoolean(true)
    private var lastRuntimeEventGeneration = 0L
    private val actionBindingTokens = ConcurrentHashMap<String, String>()
    private val outgoingArms = ConcurrentHashMap<String, kotlinx.coroutines.CompletableDeferred<Boolean>>()
    /** Core's reply to an answer's check before a write, by lease token. */
    private val promptAnswerChecks = ConcurrentHashMap<String, kotlinx.coroutines.CompletableDeferred<Boolean>>()
    /**
     * Core input that can move a thread's waiting prompt (its hooks, head and
     * bootstrap pages, and live captures of a changed screen), counted by
     * thread as it is forwarded. History pages and summaries cannot move it,
     * nor can the screen Core was last shown, so they pass uncounted: every
     * count costs an answer another check. An answer takes the count with its
     * Core check, under the same lock: input counted since then sits behind
     * that check in Core's queue, so its write waits for a check that saw it.
     */
    private val questionInputLock = Any()
    private val questionInputs = HashMap<String, Long>()
    private val questionScreens = HashMap<String, String>()

    private fun forwardQuestionInput(threadKey: String?, send: () -> Boolean): Boolean = synchronized(questionInputLock) {
        send().also { if (it && threadKey != null) questionInputs[threadKey] = (questionInputs[threadKey] ?: 0L) + 1 }
    }

    private fun forwardQuestionScreen(threadKey: String, observation: JSONObject, send: () -> Boolean): Boolean =
        synchronized(questionInputLock) {
            // Its fence is part of what Core was told: Core refuses a capture
            // under a stale fence, so the same screen under a newer one is new.
            val screen = listOf(observation.opt("observedLifecycleSequence"), observation.opt("observedGeneration"),
                observation.opt("bindingToken"), observation.optBoolean("onDisplay"),
                observation.optJSONObject("promptObservation")?.optString("visibleText"),
                observation.optJSONObject("promptObservation")?.optString("currentCursorLine")).joinToString("\u0000")
            send().also { sent ->
                if (sent && questionScreens.put(threadKey, screen) != screen) {
                    questionInputs[threadKey] = (questionInputs[threadKey] ?: 0L) + 1
                }
            }
        }

    private fun questionInputCount(threadKey: String): Long = synchronized(questionInputLock) { questionInputs[threadKey] ?: 0L }
    private val actionJobs = ConcurrentHashMap<String, ActionJob>()
    /** Queued `notSent` results by thread, until Core withdraws or keeps the bubble. */
    private val notSentLedger = AgentNotSentLedger()
    /** Each wait's fallback clock, by wait identity. */
    private val notSentClocks = ConcurrentHashMap<AgentNotSentWait, Job>()
    private val candidateActionsInFlight = ConcurrentHashMap<String, JSONObject>()
    private var attachmentSelection: AttachmentTarget? = null
    private val attachmentJobs = linkedMapOf<String, Job>()
    @Volatile private var pendingLaunch: PendingLaunch? = null
    /** Correlate parser replies by request ID; serialize reads to keep one pending owner. */
    private var pendingPromptObservation: PendingPromptObservation? = null
    private val promptObservationMutex = Mutex()
    private data class PromptObservationJob(val token: String, val binding: SharedAgentValue.ObjectValue?, val job: Job)
    private val promptObservationJobs = linkedMapOf<String, PromptObservationJob>()
    private val pendingLifecycleLaunches = ConcurrentHashMap<String, PendingLifecycleLaunch>()
    private val projectionJobs = ConcurrentHashMap<String, Job>()
    private val initialPrefetchJobs = ConcurrentHashMap<String, Job>()
    private val readRetryJobs = ConcurrentHashMap<String, Job>()
    private val readRetryFailures = ConcurrentHashMap<String, Int>()
    private val readRetryRequests = ConcurrentHashMap<String, Pair<String?, String>>()
    private val firstProjectionRetryJobs = ConcurrentHashMap<String, Job>()
    private val firstProjectionRetryTokens = ConcurrentHashMap<String, String>()
    private val lifecycleProofRetries = AgentLifecycleProofRetry<Pair<AgentSessionKey, String?>>(scope, mayAttempt = { applicationForeground })
    private val livePromptWatchJobs = ConcurrentHashMap<String, Job>()
    private val latestPromptLifecycleSequence = ConcurrentHashMap<String, Long>()
    private val latestPromptLifecycleNanos = ConcurrentHashMap<String, Long>()
    private data class TerminalRead(val generation: Long, val bindingToken: String, val recordID: String?)
    private val pendingTerminalReads = ConcurrentHashMap<String, TerminalRead>()
    private val pendingProjectionRefreshes = ConcurrentHashMap.newKeySet<String>()
    private val pendingHistoryRequests = ConcurrentHashMap.newKeySet<String>()
    /** Fill requests waiting for the read ahead of them (see [fillHistory]). */
    private val pendingFillRequests = ConcurrentHashMap.newKeySet<String>()
    private val pendingLatestRequests = ConcurrentHashMap.newKeySet<String>()
    /** A search match to read around once the thread's current read ends. */
    private val pendingSeekRequests = ConcurrentHashMap<String, AgentSearchResultRow>()
    private val searchLandingIDs = java.util.concurrent.atomic.AtomicLong()
    /** Core's replies to [readerPlace], by request id. */
    private val readerPlaceChecks = ConcurrentHashMap<String, kotlinx.coroutines.CompletableDeferred<AgentSearchResultRow?>>()
    private val readerPlaceIDs = java.util.concurrent.atomic.AtomicLong()
    /**
     * A reader's place in history ([readerPlace]), kept from the read that
     * opens it until a seek lands there, the host refuses it, or the reader
     * moves on: a read cut off in between (the app away again, the
     * connection dropped) leaves it to the next, as Core's window by then
     * holds the newest page.
     */
    private val readerPlaces = ConcurrentHashMap<String, AgentSearchResultRow>()
    /**
     * Threads whose place a notification gave up ([openNotificationThread]):
     * no read opens it until the thread's next opening read ends, whatever
     * row Core is told meanwhile.
     */
    private val readerPlacesGivenUp = ConcurrentHashMap.newKeySet<String>()
    /** The row each detail last reported its viewport starts at; none while it follows the newest page. */
    private val viewportAnchors = ConcurrentHashMap<String, String>()
    /**
     * Threads a seek opens on a connection with no window, by the read's
     * token: their snapshots wait in [heldDetails] until the seek ends, so
     * the newest page it starts from never shows.
     */
    private val presentationHolds = mutableMapOf<String, Any>()
    private val heldDetails = mutableMapOf<String, AgentThreadDetail>()
    private val presentationHoldLock = Any()
    private val projectionSources = ConcurrentHashMap<String, ProjectionSource>()
    private val directoryProofs = ConcurrentHashMap<String, DirectoryProof>()
    /** Newest record already acknowledged per thread, to drop scroll repeats. */
    private val acknowledgedRecords = ConcurrentHashMap<String, String>()
    /** Core's completion identities last handed to Room, per thread (unread to acknowledged). */
    private val persistedCompletionKeys = ConcurrentHashMap<String, Pair<String?, String?>>()
    /** Attention epoch last reported read per thread, to drop recomposition repeats. */
    private val acknowledgedCompletionEpochs = ConcurrentHashMap<String, Long>()
    internal class NativeThread(val handle: String) {
        val operation = Mutex()
        @Volatile var liveCursor: String? = null
        @Volatile var window: JSONObject? = null
        @Volatile var fast: Boolean? = null
        @Volatile var paused = false
        @Volatile var coreEvicted = false
        @Volatile var initialPrefetchStarted = false
        @Volatile var metadataJob: Job? = null
    }
    private data class NativeHostKey(val session: AgentSessionKey, val context: String = "default")
    internal class NativeHost(val endpoint: AgentSessionEndpoint, scope: CoroutineScope, contextPID: Int? = null, contextScope: String? = null,
                              diagnostics: ((String, Map<String, String>) -> Unit)? = null) {
        var admitted = false // Access only under ingestionPoolLock.
        var openingWaiters = 0 // Access only under ingestionPoolLock.
        val claimedThreads = ConcurrentHashMap.newKeySet<String>()
        val interests = Mutex()
        val threads = ConcurrentHashMap<String, NativeThread>()
        private val handleClaims = mutableMapOf<String, String>()
        private val threadClaims = mutableMapOf<String, String>()
        @Synchronized fun reserveHandles(claims: List<Pair<String, String>>) {
            val handles = handleClaims.toMutableMap()
            val identities = threadClaims.toMutableMap()
            for ((key, handle) in claims) {
                check(handles[handle]?.let { it == key } != false &&
                    identities[key]?.let { it == handle } != false &&
                    threads[key]?.let { it.handle == handle } != false) { "contextIdentityConflict" }
                handles[handle] = key; identities[key] = handle
            }
            handleClaims.putAll(handles); threadClaims.putAll(identities)
        }
        private val closing = java.util.concurrent.atomic.AtomicBoolean(false)
        @Volatile var connection: AgentIngestionConnection? = null
        val opening = scope.async {
            AgentIngestionConnection.open(endpoint, scope, contextPID, contextScope, diagnostics).also { opened ->
                connection = opened
                if (closing.get()) opened.close()
            }
        }
        fun close() {
            closing.set(true); opening.cancel(); connection?.close()
            threads.values.forEach { it.metadataJob?.cancel() }
        }
    }
    private data class NativeCommit(val accepted: Boolean, val window: JSONObject? = null, val code: String? = null)
    private val ingestionHosts = ConcurrentHashMap<NativeHostKey, NativeHost>()
    private val ingestionScopes = ConcurrentHashMap<NativeHostKey, String>()
    private val ingestionPoolLock = Any()
    private val ingestionInventories = ConcurrentHashMap<AgentSessionKey, Job>()
    /** Lifecycle frames ask the endpoint's inventory job for another pass. */
    private class NativeInventoryRequests(val endpoint: AgentSessionEndpoint) {
        val passes = Channel<Unit>(Channel.CONFLATED)
        /** Conversations that asked once; a refused hook repeats every few seconds. */
        val asked: MutableSet<String> = ConcurrentHashMap.newKeySet()
        /** Whether this tab's last pass reached the end; a dropped carrier's fails each time. */
        @Volatile var worked = false
        /** The pass listing the host now, if any. */
        @Volatile var running: InventoryPass? = null
    }

    /**
     * What one pass skipped because another owner held it, and which owners
     * left while it ran. A thread whose owner left needs another pass only if
     * this one had already skipped it: one it has yet to reach, it lists.
     */
    private class InventoryPass {
        private val skipped = hashSetOf<String>()
        private val left = hashSetOf<String>()
        private var finished = false
        @Synchronized fun skip(threadKey: String) { skipped += threadKey }
        /** False once the pass has finished: the caller asks for a new one. */
        @Synchronized fun leave(threadKeys: Collection<String>): Boolean {
            if (finished) return false
            left += threadKeys
            return true
        }
        /** Whether an owner left a thread this pass skipped. */
        @Synchronized fun finish(): Boolean {
            finished = true
            return left.any { it in skipped }
        }
    }
    private val nativeInventoryRequests = ConcurrentHashMap<AgentSessionKey, NativeInventoryRequests>()
    /** No inventory pass starts sooner than this after the last one began. */
    internal var nativeInventoryIntervalMillis = 10_000L
    /** How long a thread whose token was replaced waits for the successor's bind. */
    internal var successorBindGraceMillis = 10_000L
    private val ingestionVisibleCards = ConcurrentHashMap.newKeySet<String>()
    @Volatile private var ingestionOpenDetail: String? = null
    private var ingestionInterestJob: Job? = null
    private var ingestionInterestRevision = 0L
    private val ingestionCommits = ConcurrentHashMap<String, CompletableDeferred<NativeCommit>>()
    private var searchJob: Job? = null
    /** The needle whose rows the list shows, and the results last sent for it. */
    private var presentedSearchNeedle = ""
    private var presentedSearchResults = JSONArray()
    /** One OS notification per reduced attention/generation tuple for this process. */
    private val deliveredAttention = ConcurrentHashMap.newKeySet<String>()
    private val lifecycleArrivalSequence = AtomicLong(0)
    /** Seeds already sent to the on-device model, so a list refresh is not a re-run. */
    private val requestedTitleSeeds = ConcurrentHashMap.newKeySet<String>()
    private var titleGenerationJob: Job? = null
    @Volatile private var titleCharacterBudget = 0
    @Volatile private var applicationForeground = true
    @Volatile private var enabled = false
    @Volatile private var savedHostDisplayLabels: Map<String, String> = emptyMap()

    fun updateHostDisplayLabels(labels: Map<String, String>) {
        val current = labels.entries.take(1_024).associate { it.key.canonicalAgentUUID() to it.value.take(512) }
        if (current == savedHostDisplayLabels) return
        savedHostDisplayLabels = current
        if (runtime != null) forward(JSONObject().put("v", 1).put("kind", "configure")
            .put("hostDisplayLabels", JSONObject(current)))
    }

    fun setEnabled(value: Boolean) {
        if (enabled == value) return
        diagnostics?.invoke("agent_enabled_changed", mapOf("enabled" to value.toString()))
        enabled = value
        if (value) activate() else deactivate()
    }

    /**
     * The OS asked for memory back. Parsed Markdown goes at any real pressure;
     * transcript content (re-read from the host, like iOS's memory warning)
     * goes when pressure is critical or the app is a candidate for killing.
     * Merely leaving the foreground (`TRIM_MEMORY_UI_HIDDEN`) is not pressure.
     */
    @Suppress("DEPRECATION")
    fun trimMemory(level: Int) {
        if (level < ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW || level == ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) return
        SharedAgentMarkdown.clearCache()
        if (runtime == null) return
        if (level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL || level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND) {
            diagnostics?.invoke("agent_memory_warning", mapOf("level" to level.toString()))
            forward(JSONObject().put("v", 1).put("kind", "memoryWarning"))
        }
    }

    fun setApplicationForeground(foreground: Boolean) {
        val returning = foreground && !applicationForeground
        applicationForeground = foreground
        sessionIntegration.setApplicationForeground(foreground)
        if (!foreground) {
            occupancySweepJobs.values.forEach(Job::cancel); occupancySweepJobs.clear()
            searchJob?.cancel(); searchJob = null
            mutableState.value = mutableState.value.copy(searching = false)
            livePromptWatchJobs.values.forEach(Job::cancel); livePromptWatchJobs.clear()
            cancelProjectionReads()
            closeIngestionHosts()
        }
        if (foreground) mutableState.value.detail?.let { attentionNotifier?.withdraw(it.row.key) }
        if (returning) {
            coordinator.directory.sessions.value.forEach { coordinator.directory.resolve(it.key)?.let(::scheduleOccupancySweeps) }
            mutableState.value.projectedDetails.values.filter { it.row.livePromptWatch }.forEach(::startLivePromptWatchFromSnapshot)
            startDisplayedLivePromptWatch()
            coordinator.directory.sessions.value.forEach { binding -> coordinator.directory.resolve(binding.key)?.let(::startNativeInventory) }
            mutableState.value.selectedThreadKey?.let(::refreshVisibleTranscript)
            mutableState.value.searchQuery.takeIf { it.isNotBlank() }?.let(::search)
        }
    }

    /** Lazily opens the independent ABI after the Agent destination is visible. */
    fun activate() {
        if (!enabled) return
        if (runtime != null || observer != null) {
            // Opening the screen lists what changed since the last pass, as on
            // iOS; a completed pass otherwise waits for agent activity. Any
            // one tab's pass lists its whole host.
            nativeInventoryRequests.values.map { it.endpoint.binding.value.hostID }.distinct()
                .forEach { hostID -> hostLister(hostID)?.passes?.trySend(Unit) }
            return
        }
        mutableState.value = mutableState.value.copy(loading = true, unavailableReason = null)
        val created = runCatching { coordinator.runtime() }.getOrElse { failure ->
            mutableState.value = mutableState.value.copy(loading = false, unavailableReason = failure.message ?: "Agent runtime unavailable")
            return
        }
        runtime = created
        created.droppedEventSink = { fields ->
            actionRequestOrderReliable.set(false)
            diagnostics?.invoke("agent_core_event_dropped", fields)
        }
        // Before any bootstrap: Core sizes retention (and so each new window)
        // from this tier. Sent synchronously so no page can precede it.
        deviceMemory?.takeIf { it.physicalMemoryBytes > 0 }?.let { memory ->
            forward(JSONObject().put("v", 1).put("kind", "configure")
                .put("physicalMemoryBytes", memory.physicalMemoryBytes)
                .put("lowRAMDevice", memory.lowRAMDevice))
        }
        observer = scope.launch {
            created.events.collect(::consume)
        }
        // DataStore owns only this view choice. Reapply it to each newly-created
        // runtime so process recreation cannot silently fall back to a different
        // shared ordering/grouping.
        viewPreferencesObserver = scope.launch {
            var firstValue = true
            viewPreferences.values.collect { preferences ->
                val changed = mutableState.value.grouping != preferences.grouping
                mutableState.value = mutableState.value.copy(
                    grouping = preferences.grouping,
                    showSystemEvents = preferences.showSystemEvents,
                    compactTab = preferences.compactTab,
                )
                if (firstValue || changed) {
                    forward(JSONObject().put("v", 1).put("kind", "filter").put("grouping", preferences.grouping))
                }
                firstValue = false
            }
        }
        val metadataRestore = scope.launch {
            val restored = JSONArray()
            metadata.restoredThreads().forEach { item ->
                item.threadKey.threadIDJson()?.let { threadID ->
                    restored.put(JSONObject().put("threadID", threadID).putOpt("lastReadRecordID", item.lastReadRecordID)
                        .putOpt("unreadCompletionKey", item.unreadCompletionKey)
                        .putOpt("acknowledgedCompletionKey", item.acknowledgedCompletionKey))
                    persistedCompletionKeys[item.threadKey] = item.unreadCompletionKey to item.acknowledgedCompletionKey
                }
            }
            forward(JSONObject().put("v", 1).put("kind", "configure").put("metadata", restored)
                .put("hostDisplayLabels", JSONObject(savedHostDisplayLabels)))
        }
        sessionObserver = scope.launch {
            // Read state first: a pane's retained Stop replayed before it
            // would resurrect a finish the reader already saw.
            metadataRestore.join()
            coordinator.directory.sessions.collect { bindings ->
                refreshPaneAgentProviders()
                val live = bindings.mapTo(linkedSetOf()) { it.key }
                retireEndpoints(endpointObservers.keys.filterNot(live::contains))
                for (binding in bindings) {
                    val endpoint = coordinator.directory.resolve(binding.key) ?: continue
                    startNativeInventory(endpoint)
                    if (endpointObservers[binding.key] == null) {
                        scheduleOccupancySweeps(endpoint)
                        endpointObservers[binding.key] = launch { observeEndpointEvents(endpoint) }
                    }
                    val previousInventoryBinding = tierCInventoryBindings.put(binding.key, binding)
                    if (previousInventoryBinding != binding) {
                        tierCInventoryJobs.remove(binding.key)?.cancel()
                        // A pane/window focus change refreshes inventory, not
                        // the carrier's lifetime. Retiring all owners here
                        // erased the very thread whose terminal we must open.
                        // Endpoint-key disappearance above owns full teardown;
                        // each action still re-proves its exact pane binding.
                        if (previousInventoryBinding != null &&
                            !previousInventoryBinding.retainsAgentThreadOwners(binding)) {
                            teardownEndpointOwners(binding.key)
                        }
                        tierCConformances.remove(binding.key)
                        reconfigureTierCConformances()
                        tierCInventoryJobs[binding.key] = scope.launch {
                            inventoryTierCProviders(endpoint, binding)
                        }
                    }
                    val previousCandidateBinding = tierACandidateBindings.put(binding.key, binding)
                    if (previousCandidateBinding != binding) {
                        tierACandidateJobs.remove(binding.key)?.cancel()
                        previousCandidateBinding?.let { removeTierACandidates(binding.key, it) }
                        tierACandidateJobs[binding.key] = scope.launch { monitorTierACandidates(endpoint, binding) }
                    }
                }
            }
        }
        integrationEventObserver = scope.launch {
            sessionIntegration.events.collect { event ->
                if (event is AgentSessionIntegrationEvent.Installed) {
                    val endpoint = coordinator.directory.resolve(event.sessionKey) ?: return@collect
                    if (endpoint.binding.value == event.binding) restartTierCInventory(endpoint, event.binding)
                }
            }
        }
    }

    fun select(threadKey: String?) {
        if (mutableState.value.selectedThreadKey != threadKey) invalidateSendAnyway()
        initialPrefetchJobs.keys.filter { it != threadKey }.forEach(::cancelInitialPrefetch)
        pendingFillRequests.removeIf { it != threadKey }
        pendingSeekRequests.keys.removeIf { it != threadKey }
        readerPlaces.keys.removeIf { it != threadKey }
        readRetryJobs.keys.filter { it != threadKey && it !in ingestionVisibleCards }.forEach { readRetryJobs.remove(it)?.cancel() }
        val current = mutableState.value
        // Do not render an old selected thread while Core resolves the new
        // one. A same-thread projection can be shown immediately, but a row
        // summary never substitutes for a detail/binding lease.
        mutableState.value = current.copy(
            selectedThreadKey = threadKey,
            detail = threadKey?.let(current.projectedDetails::get)?.let(::withKnownDirectoryProof),
            searchLanding = current.searchLanding?.takeIf { it.threadKey == threadKey },
            latestOpening = current.latestOpening?.takeIf { it == threadKey },
        )
        publishSendingThreads()
        // A thread key is a display identity. The native ABI remains authoritative
        // for resolving provider IDs; an unresolvable key is a harmless rejection.
        forward(JSONObject().put("v", 1).put("kind", "select").putOpt("threadID", threadKey?.threadIDJson()))
        // Search can select a historical inventory thread that Core deliberately
        // omits from its live-only list. Reuse only its current registered
        // projection source and owner; this does not mint a binding or send to
        // the terminal.
        // A newest page left queued when the reader left it comes first.
        if (threadKey != null && pendingLatestRequests.remove(threadKey)) loadNewer(threadKey, latest = true)
        else threadKey?.let(::scheduleExistingProjection)
        startDisplayedLivePromptWatch()
    }

    fun search(query: String) {
        mutableState.value = mutableState.value.copy(searchQuery = query)
        searchJob?.cancel()
        // One needle for the host request, the paged pages and the exact
        // re-match: the Agent Host refuses more than 512 UTF-8 bytes.
        val bounded = agentSearchNeedle(query)
        if (!enabled || !applicationForeground) {
            searchJob = null
            mutableState.value = mutableState.value.copy(searching = false)
            return
        }
        // A new query shows none of the last one's rows, even before hosts
        // answer; the same query run again keeps its rows until it ends.
        if (bounded != presentedSearchNeedle) {
            presentedSearchNeedle = bounded
            publishSearch(JSONArray(), JSONArray())
        }
        if (bounded.isEmpty()) {
            searchJob = null
            mutableState.value = mutableState.value.copy(searching = false)
            return
        }
        mutableState.value = mutableState.value.copy(searching = true)
        searchJob = scope.launch {
            val job = currentCoroutineContext().job
            try { runRemoteSearch(bounded) }
            finally {
                if (searchJob === job) {
                    searchJob = null
                    mutableState.value = mutableState.value.copy(searching = false)
                }
            }
        }
    }

    /** Hands Core the rows to show; a search's rows show as it finds them. */
    private fun publishSearch(results: JSONArray, unavailableHosts: JSONArray) {
        presentedSearchResults = results
        forward(JSONObject().put("v", 1).put("kind", "search")
            .put("searchSnapshot", JSONObject().put("results", results).put("unavailableHostIDs", unavailableHosts)))
    }

    fun setGrouping(value: String) {
        if (value !in AGENT_GROUPINGS) return
        if (mutableState.value.grouping == value) return
        mutableState.value = mutableState.value.copy(grouping = value)
        scope.launch { viewPreferences.setGrouping(value) }
        forward(JSONObject().put("v", 1).put("kind", "filter").put("grouping", value))
    }

    fun setShowSystemEvents(value: Boolean) {
        if (mutableState.value.showSystemEvents == value) return
        mutableState.value = mutableState.value.copy(showSystemEvents = value)
        scope.launch { viewPreferences.setShowSystemEvents(value) }
    }

    fun setCompactTab(value: String) {
        if (value !in AGENT_DETAIL_TABS || mutableState.value.compactTab == value) return
        mutableState.value = mutableState.value.copy(compactTab = value)
        scope.launch { viewPreferences.setCompactTab(value) }
    }

    fun loadMore(threadKey: String, fill: Boolean = false) {
        if (!enabled || !applicationForeground || mutableState.value.selectedThreadKey != threadKey) return
        if (mutableState.value.projectedDetails[threadKey]?.hasMore != true) return
        if (!fill) {
            cancelInitialPrefetch(threadKey)
            clearNativeReadStatus(threadKey)
        }
        val source = projectionSources[threadKey] ?: return
        val cursor = mutableState.value.projectedDetails[threadKey]?.cursor ?: return
        val endpoint = coordinator.directory.resolve(source.endpointKey) ?: return
        scheduleProjection(endpoint, source.binding, JSONObject(source.threadID), source.provider,
            source.transcriptRef, threadKey, source.bindingToken, cursor)
    }

    /**
     * History for a transcript shorter than its viewport, which no gesture can
     * ask for. It never trims the live head, waits for a read in progress
     * rather than cancelling it (the initial prefetch is reading that same
     * history), and leaves a failed read and its Retry on screen.
     */
    fun fillHistory(threadKey: String) {
        if (!enabled || !applicationForeground || mutableState.value.selectedThreadKey != threadKey) return
        val detail = mutableState.value.projectedDetails[threadKey] ?: return
        if (!detail.hasMore || detail.window?.olderPageFits != true ||
            mutableState.value.ingestionReadStatuses[threadKey]?.isProgress == false || readRetryJobs.containsKey(threadKey)) return
        if (projectionJobs[threadKey]?.isActive == true || initialPrefetchJobs.containsKey(threadKey)) {
            pendingFillRequests.add(threadKey); return
        }
        loadMore(threadKey, fill = true)
    }

    /**
     * The newer page that retains rows a bridged window only shows (Core's
     * `bridgesToHead`: a revision split or roll dropped them from the host's
     * window). Optional, like a fill: it never clears a failed read, and a
     * read in progress is left alone (the pane asks again as the window moves).
     */
    fun retainBridgedRows(threadKey: String) {
        if (!enabled || !applicationForeground || mutableState.value.selectedThreadKey != threadKey) return
        val window = mutableState.value.projectedDetails[threadKey]?.window ?: return
        if (!window.bridgesToHead || window.after == null || mutableState.value.ingestionReadStatuses[threadKey]?.isProgress == false ||
            readRetryJobs.containsKey(threadKey) || projectionJobs[threadKey]?.isActive == true) return
        val source = projectionSources[threadKey] ?: return
        val endpoint = coordinator.directory.resolve(source.endpointKey) ?: return
        scheduleProjection(endpoint, source.binding, JSONObject(source.threadID), source.provider,
            source.transcriptRef, threadKey, source.bindingToken, window.after, nativeDirection = "after")
    }

    fun acknowledge(threadKey: String, recordID: String) {
        val detail = mutableState.value.projectedDetails[threadKey]
        if (detail?.window?.let { !it.atLiveHead || it.hasNewer } == true) return
        // The newest row reports itself again whenever the list settles. Once
        // it is read and the row is quiet, a repeat changes nothing in Core
        // (which no longer echoes a snapshot for it) and must not rewrite Room.
        if (acknowledgedRecords[threadKey] == recordID &&
            detail?.row?.let { it.attention == "none" && it.status != "finished" } == true) return
        acknowledgedRecords[threadKey] = recordID
        scope.launch {
            metadata.rememberRead(threadKey, recordID, unread = false, now = System.currentTimeMillis())
        }
        val thread = threadKey.threadIDJson() ?: return
        forward(JSONObject().put("v", 1).put("kind", "acknowledge").put("threadID", thread).put("recordID", recordID))
    }

    /**
     * The reader has the live end of a finished thread on screen. This reads
     * the finish even when it added no record, or when the newest row was
     * already visible as it arrived. Core fences it to the epoch shown.
     */
    fun acknowledgeCompletion(threadKey: String) {
        if (!enabled || !applicationForeground) return
        val detail = mutableState.value.projectedDetails[threadKey] ?: return
        if (detail.row.attention != "unreadCompletion" || detail.attentionEpoch <= 0) return
        if (detail.window?.let { !it.atLiveHead || it.hasNewer } == true) return
        // Recomposition repeats the report until Core's snapshot lands.
        if (acknowledgedCompletionEpochs.put(threadKey, detail.attentionEpoch) == detail.attentionEpoch) return
        forward(JSONObject().put("v", 1).put("kind", "acknowledgeCompletion")
            .put("threadID", detail.row.threadIDJson()).put("attentionEpoch", detail.attentionEpoch))
    }

    fun viewportAnchor(threadKey: String, recordID: String?) {
        // A reader who follows the newest page has left any kept place.
        if (recordID == null) { viewportAnchors.remove(threadKey); readerPlaces.remove(threadKey) }
        else viewportAnchors[threadKey] = recordID
        val thread = threadKey.threadIDJson() ?: return
        forward(JSONObject().put("v", 1).put("kind", "viewportAnchor").put("threadID", thread).putOpt("recordID", recordID))
    }

    /** Opens the result's thread at its match. */
    fun openSearchResult(result: AgentSearchResultRow) {
        select(result.threadKey)
        mutableState.value = mutableState.value.copy(searchLanding =
            AgentSearchLanding(result.threadKey, result.recordID, searchLandingIDs.incrementAndGet()))
        // The match supersedes navigation queued before it, and the place.
        readerPlaces.remove(result.threadKey)
        pendingLatestRequests.remove(result.threadKey)
        pendingHistoryRequests.remove(result.threadKey)
        pendingFillRequests.remove(result.threadKey)
        requestSeek(result)
    }

    /** The reader chose the newest page over a match still opening. */
    fun returnToLatest(threadKey: String) {
        pendingSeekRequests.remove(threadKey)
        readerPlaces.remove(threadKey)
        dropSearchLanding(threadKey)
        loadNewer(threadKey, latest = true)
    }

    /**
     * Opens a notification's conversation at its newest reply, unless a
     * window on a live connection still shows the reader's place there: a
     * notification never waits on a read of that place ([readerPlace]). A
     * place read already under way shows the newest page it read first.
     */
    fun openNotificationThread(threadKey: String) {
        val shown = ingestionHosts.values.any { host -> host.connection?.isClosed == false && host.threads[threadKey]?.window != null }
        if (!shown || readerPlaces.containsKey(threadKey)) {
            readerPlacesGivenUp.add(threadKey)
            viewportAnchor(threadKey, null)
            mutableState.value.searchLanding?.takeIf { it.threadKey == threadKey && !it.marked }?.let {
                dropSearchLanding(threadKey)
                synchronized(presentationHoldLock) {
                    if (presentationHolds.remove(threadKey) != null) {
                        heldDetails.remove(threadKey)?.let { detail ->
                            // The newest page shows; the seek's reply, dropped, is not waited on.
                            val current = mutableState.value.withThreadSnapshot(detail)
                            mutableState.value = current.copy(loadingTranscriptThreads = current.loadingTranscriptThreads - threadKey)
                        }
                    }
                }
            }
            mutableState.value = mutableState.value.copy(latestOpening = threadKey)
        }
        select(threadKey)
    }

    /** The detail opened [threadKey] at its newest page ([openNotificationThread]). */
    fun finishLatestOpening(threadKey: String) {
        if (mutableState.value.latestOpening == threadKey) mutableState.value = mutableState.value.copy(latestOpening = null)
    }

    /** An index the host rebuilt since the search names the landed match anew; the landing follows it. */
    private fun retargetSearchLanding(threadKey: String, recordID: String, landed: String): Boolean {
        val landing = mutableState.value.searchLanding ?: return false
        if (landing.threadKey != threadKey || landing.recordID != recordID) return false
        mutableState.value = mutableState.value.copy(searchLanding = landing.copy(recordID = landed))
        return true
    }

    /** The detail landed on [landing]; a later page never moves the reader for it. */
    fun finishSearchLanding(landing: AgentSearchLanding) {
        if (mutableState.value.searchLanding == landing) mutableState.value = mutableState.value.copy(searchLanding = null)
    }

    /**
     * The match could not be read: the thread stays at its newest page, and a
     * later page holding the record must not move the reader there. Without a
     * record, the thread's landing still unread is abandoned.
     */
    private fun abandonSearchLanding(threadKey: String, recordID: String? = null) {
        val current = mutableState.value
        val landing = current.searchLanding ?: return
        if (landing.threadKey != threadKey || (recordID != null && landing.recordID != recordID)) return
        if (current.projectedDetails[threadKey]?.live?.any { it.recordID == landing.recordID } == true) return
        mutableState.value = current.copy(searchLanding = null)
    }

    /** The reader chose the newest page, or (without a thread) every read was reset. */
    private fun dropSearchLanding(threadKey: String? = null) {
        val landing = mutableState.value.searchLanding ?: return
        if (threadKey != null && landing.threadKey != threadKey) return
        mutableState.value = mutableState.value.copy(searchLanding = null)
    }

    /**
     * Opens a search match where it lies, for as long as the reader waits on
     * it. A read in flight may still move the window, so the match waits for
     * its end and is checked again. A match loaded by then needs no read;
     * otherwise the host reads the page around it from the live cursor
     * (`window.seek.v1`), opening the thread first if it has no window yet. A
     * provider that cannot seek opens an empty thread at its newest page,
     * which may hold the match. A refused or unreadable match leaves the
     * thread at its newest page.
     */
    private fun requestSeek(result: AgentSearchResultRow, replayed: Boolean = false) {
        val threadKey = result.threadKey
        pendingSeekRequests.remove(threadKey)
        val landing = mutableState.value.searchLanding
        if (landing == null || landing.threadKey != threadKey || landing.recordID != result.recordID) return
        if (projectionJobs[threadKey]?.isActive == true) {
            pendingSeekRequests[threadKey] = result
            // The read in flight (the selection's own, at least) may replace
            // the rows on screen; the detail lands only once it ends, which
            // clears this.
            mutableState.value = mutableState.value.copy(loadingTranscriptThreads = mutableState.value.loadingTranscriptThreads + threadKey)
            return
        }
        val live = mutableState.value.projectedDetails[threadKey]?.live.orEmpty()
        if (live.any { it.recordID == result.recordID }) return
        val provider = threadKey.threadIDJson()?.optJSONObject("providerID")?.optString("rawValue")
        val seeks = result.sequence?.seekOrder() != null && provider in setOf("codex", "claude", "pi", "kimi")
        val source = projectionSources[threadKey]
        val endpoint = source?.let { coordinator.directory.resolve(it.endpointKey) }
        if (!(seeks || (live.isEmpty() && !replayed)) || !enabled || !applicationForeground ||
            mutableState.value.selectedThreadKey != threadKey || source == null || endpoint == null) {
            abandonSearchLanding(threadKey, result.recordID)
            return
        }
        cancelInitialPrefetch(threadKey)
        clearNativeReadStatus(threadKey)
        // The match's read replaces the window any queued navigation was for.
        pendingLatestRequests.remove(threadKey)
        pendingHistoryRequests.remove(threadKey)
        pendingFillRequests.remove(threadKey)
        scheduleProjection(endpoint, source.binding, JSONObject(source.threadID), source.provider,
            source.transcriptRef, threadKey, source.bindingToken, null,
            nativeDirection = if (seeks) "seek" else "before", seek = result.takeIf { seeks })
        if (!seeks) {
            // The newest page's end checks it once more.
            if (projectionJobs[threadKey]?.isActive == true) pendingSeekRequests[threadKey] = result
            else abandonSearchLanding(threadKey, result.recordID)
        }
    }

    fun loadNewer(threadKey: String, latest: Boolean = false) {
        if (!enabled || !applicationForeground || mutableState.value.selectedThreadKey != threadKey) return
        cancelInitialPrefetch(threadKey)
        clearNativeReadStatus(threadKey)
        val source = projectionSources[threadKey] ?: return
        val endpoint = coordinator.directory.resolve(source.endpointKey) ?: return
        val window = mutableState.value.projectedDetails[threadKey]?.window
        if (!latest && window?.hasNewer != true) return
        scheduleProjection(endpoint, source.binding, JSONObject(source.threadID), source.provider,
            source.transcriptRef, threadKey, source.bindingToken, if (latest) null else window?.after,
            nativeDirection = if (latest) "bootstrap" else "after")
    }

    fun setDraft(threadKey: String, text: String) {
        if (sendAnywayCandidate?.let { it.threadKey == threadKey && it.draftSnapshot != text } == true) invalidateSendAnyway()
        mutableState.value = mutableState.value.copy(drafts = mutableState.value.drafts + (threadKey to text))
    }

    fun terminalVisible(liveSessionID: String, paneID: String?) {
        if (!enabled || !applicationForeground) return
        for (detail in mutableState.value.projectedDetails.values) {
            if (detail.row.attention != "unreadCompletion") continue
            val binding = detail.binding ?: continue
            if (binding.string("liveSessionID")?.canonicalAgentUUID() != liveSessionID.canonicalAgentUUID()
                || binding.string("paneID") != paneID) continue
            val owner = threadOwners[detail.row.key] ?: continue
            pendingTerminalReads[detail.row.key] = TerminalRead(detail.deliveryGeneration, owner.bindingToken,
                detail.live.lastOrNull { it.recordID != null }?.recordID)
            forward(JSONObject().put("v", 1).put("kind", "terminalVisible")
                .put("threadID", detail.row.threadIDJson()).put("bindingToken", owner.bindingToken)
                .put("observedGeneration", detail.deliveryGeneration))
        }
    }

    fun appendDraft(threadKey: String, text: String) {
        setDraft(threadKey, listOf(mutableState.value.drafts[threadKey].orEmpty(), text)
            .filter { it.isNotEmpty() }.joinToString("\n"))
    }

    /** Captures authority at picker launch, before its result can arrive on another thread. */
    fun beginAttachmentSelection(thread: AgentThreadDetail): Boolean {
        if (attachmentSelection != null || thread.row.key in attachmentJobs) return false
        val coreBinding = thread.binding?.toJson()
        val binding = coreBinding?.let { JSONObject().put("binding", it).put("threadID", thread.row.threadIDJson()).endpointBindingOrNull() }
        val endpoint = binding?.let { coordinator.directory.resolve(it.key) }
        val currentRuntime = runtime
        if (!thread.row.actionAvailable || binding == null || endpoint == null || currentRuntime == null) {
            mutableState.value = mutableState.value.copy(notice = "The original upload terminal is unavailable")
            return false
        }
        val target = AttachmentTarget(thread.row.key, coreBinding, binding, endpoint, currentRuntime)
        if (!attachmentTargetIsCurrent(target)) {
            mutableState.value = mutableState.value.copy(notice = "The terminal changed; reopen it before attaching a file")
            return false
        }
        attachmentSelection = target
        return true
    }

    fun completeAttachmentSelection(sourceURIs: List<String>) = completeAttachmentSelection(sourceURIs, { sourceURIs }, {})

    /** Photo copies must outlive the asynchronous upload, including cancellation before it starts. */
    fun completeAttachmentSelection(
        sourceURIs: List<String>,
        prepare: suspend () -> List<String>,
        onFinished: () -> Unit,
    ) {
        val target = attachmentSelection ?: run { onFinished(); return }
        attachmentSelection = null
        if (sourceURIs.isEmpty()) { onFinished(); return }
        if (!attachmentTargetIsCurrent(target)) {
            mutableState.value = mutableState.value.copy(notice = "Attachment cancelled: the original terminal changed")
            onFinished()
            return
        }
        val key = target.threadKey
        mutableState.value = mutableState.value.copy(uploadingThreads = mutableState.value.uploadingThreads + key)
        val job = scope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
            try {
                for (uri in prepare()) {
                    currentCoroutineContext().ensureActive()
                    if (!attachmentTargetIsCurrent(target)) {
                        mutableState.value = mutableState.value.copy(notice = "Upload stopped: the original terminal changed")
                        break
                    }
                    val result = target.endpoint.uploadAttachment(target.binding, uri)
                    currentCoroutineContext().ensureActive()
                    when (result) {
                        is AgentEndpointResult.Success -> {
                            currentCoroutineContext().ensureActive()
                            val path = result.value
                            if (path.isBlank() || path.any { it.isISOControl() }) {
                                mutableState.value = mutableState.value.copy(notice = "The upload returned an unsupported file path")
                                break
                            }
                            if (!attachmentTargetIsCurrent(target)) {
                                mutableState.value = mutableState.value.copy(notice = "File uploaded to ${quoteAgentAttachmentPath(path)}; the terminal changed, so no draft was changed")
                                break
                            }
                            appendDraft(key, quoteAgentAttachmentPath(path))
                        }
                        else -> {
                            mutableState.value = mutableState.value.copy(notice = "File upload failed; your draft was preserved")
                            break
                        }
                    }
                }
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                currentCoroutineContext().ensureActive()
                if (attachmentTargetIsCurrent(target)) {
                    mutableState.value = mutableState.value.copy(notice = "File upload failed; your draft was preserved")
                }
            } finally {
                // A disabled/re-enabled runtime may already own a replacement job.
                if (attachmentJobs[key] === currentCoroutineContext()[Job]) {
                    attachmentJobs.remove(key)
                    mutableState.value = mutableState.value.copy(uploadingThreads = mutableState.value.uploadingThreads - key)
                }
            }
        }
        job.invokeOnCompletion { onFinished() }
        attachmentJobs[key] = job
        job.start()
    }

    private fun attachmentTargetIsCurrent(target: AttachmentTarget): Boolean {
        val owner = threadOwners[target.threadKey] ?: return false
        return enabled && runtime === target.runtime && coordinator.directory.resolve(target.binding.key) === target.endpoint &&
            target.endpoint.isCurrentRoute(target.binding) &&
            owner.endpointKey == target.binding.key && target.coreBinding.tokenKey() == owner.canonicalBinding
    }

    private fun publishSendingThreads() {
        mutableState.value = mutableState.value.copy(
            sendingThreads = pendingActions.values.filter { it.kind in setOf("send", "queue", "answerPrompt") }
                .map { it.threadKey }.toSet(),
            pendingActionInFlight = mutableState.value.selectedThreadKey?.let(pendingActions::containsKey) == true,
            actionThreads = pendingActions.keys.toSet())
    }

    private fun isActionTargetBusy(threadKey: String, binding: JSONObject): Boolean =
        pendingActions.values.any { agentActionTargetBusy(threadKey, binding, it.threadKey, it.binding) } ||
            candidateActionsInFlight.values.any { agentActionTargetBusy(threadKey, binding, "candidate", it) }

    /** A composer only asks shared core to plan an action; it never writes a terminal itself. */
    /** True means enqueued only; the view clears drafts on correlated ActionPlan acceptance. */
    fun requestAction(thread: AgentThreadDetail, kind: String, text: String? = null): Boolean =
        requestAction(thread, kind, text, bypassComposerVerification = false)

    private fun requestAction(thread: AgentThreadDetail, kind: String, text: String?, bypassComposerVerification: Boolean,
        retryDraftSnapshot: String? = null, retryDraftRemainder: String? = null): Boolean {
        invalidateSendAnyway()
        val binding = thread.binding?.toJson() ?: run {
            mutableState.value = mutableState.value.copy(notice = "Open terminal to continue")
            return false
        }
        if (isActionTargetBusy(thread.row.key, binding)) {
            mutableState.value = mutableState.value.copy(notice = "An action is already in progress")
            return false
        }
        if (thread.row.key in mutableState.value.uploadingThreads && kind in setOf("send", "queue")) return false
        val id = thread.row.threadIDJson()
        val bindingToken = bindingTokens[binding.tokenKey(thread.row.key)] ?: run {
            mutableState.value = mutableState.value.copy(notice = "Terminal action proof is unavailable")
            return false
        }
        if (kind in setOf("send", "queue") && text.isNullOrBlank()) return false
        val pending = PendingAction(thread.row.key, kind, text?.take(32_768), binding, bindingToken = bindingToken,
            bypassComposerVerification = bypassComposerVerification, composerRetryGeneration = composerRetryGeneration,
            retryDraftSnapshot = retryDraftSnapshot, retryDraftRemainder = retryDraftRemainder)
        cancelInitialPrefetch(thread.row.key)
        pendingActions[thread.row.key] = pending
        if (pendingActionRequests.isEmpty()) actionRequestOrderReliable.set(true)
        pendingActionRequests.add(pending)
        publishSendingThreads()
        val payload = when (kind) {
            "send", "queue" -> JSONObject().put("text", JSONObject()
                .put("threadID", id).put("binding", binding).put("text", text?.take(32_768))
                .put("queueWhenWorking", kind == "queue")
                .put("composerVerification", if (bypassComposerVerification) "userOverride" else "required"))
            "interrupt", "openTerminal" -> JSONObject().put("targetBinding", binding)
            else -> null
        }
        val accepted = forward(JSONObject().put("v", 1).put("kind", "action").put("threadID", id)
            .put("bindingToken", bindingToken).put("action", kind).putOpt("actionPayload", payload))
        diagnostics?.invoke("agent_action_requested", mapOf("action" to kind, "accepted" to accepted.toString()))
        if (!accepted) {
            pendingActionRequests.remove(pending)
            pendingActions.remove(thread.row.key, pending)
            publishSendingThreads()
            mutableState.value = mutableState.value.copy(notice = "The send could not start; your draft was preserved")
        }
        return accepted
    }

    /** The card carries a choice; Core plans terminal bytes from each fresh capture. */
    fun requestPromptAnswer(thread: AgentThreadDetail, prompt: AgentPrompt, answer: AgentPromptAnswerChoice) {
        invalidateSendAnyway()
        val binding = thread.binding?.toJson() ?: return
        if (isActionTargetBusy(thread.row.key, binding)) return
        if (!thread.canAnswerPrompt()) {
            mutableState.value = mutableState.value.copy(notice = "Open terminal to answer")
            return
        }
        val fresh = prompt.fresh ?: return
        val optionID = when (answer) {
            is AgentPromptAnswerChoice.Option -> answer.id
            is AgentPromptAnswerChoice.Text -> prompt.options.firstOrNull { it.acceptsText }?.id ?: "text"
            is AgentPromptAnswerChoice.Control -> answer.kind
        }
        if (livePromptActionToken(fresh.signature) != prompt.actionToken ||
            (answer is AgentPromptAnswerChoice.Option && prompt.options.none { it.id == answer.id }) ||
            (answer is AgentPromptAnswerChoice.Control && prompt.controls.none { it.kind == answer.kind }) ||
            (answer is AgentPromptAnswerChoice.Text && (!prompt.acceptsText || answer.text.isBlank()))) {
            mutableState.value = mutableState.value.copy(notice = "Prompt changed; review it in the terminal")
            return
        }
        val bindingToken = bindingTokens[binding.tokenKey(thread.row.key)] ?: run {
            mutableState.value = mutableState.value.copy(notice = "Terminal action proof is unavailable")
            return
        }
        val pending = PendingAction(
            thread.row.key,
            "answerPrompt",
            null,
            binding,
            actionToken = prompt.actionToken,
            optionID = optionID,
            promptSignature = fresh.signature,
            promptText = (answer as? AgentPromptAnswerChoice.Text)?.text,
            control = (answer as? AgentPromptAnswerChoice.Control)?.kind,
            bindingToken = bindingToken,
        )
        pendingActions[thread.row.key] = pending
        if (pendingActionRequests.isEmpty()) actionRequestOrderReliable.set(true)
        pendingActionRequests.add(pending)
        val accepted = forward(JSONObject().put("v", 1).put("kind", "action")
            .put("threadID", thread.row.threadIDJson()).put("bindingToken", bindingToken)
            .put("action", "answerPrompt").put("actionPayload", JSONObject().put("promptAnswer", JSONObject()
                .put("threadID", thread.row.threadIDJson()).put("binding", binding)
                .put("actionToken", JSONObject().put("rawValue", prompt.actionToken)).put("expectedSignature", fresh.signature)
                .put("optionID", optionID)
                .putOpt("text", pending.promptText).putOpt("control", pending.control))))
        if (!accepted) {
            pendingActionRequests.remove(pending)
            pendingActions.remove(thread.row.key, pending)
        }
        publishSendingThreads()
    }

    private fun invalidateSendAnyway() {
        composerRetryGeneration++
        sendAnywayCandidate = null
        composerRefusals.clear()
        mutableState.value = mutableState.value.copy(sendAnywayNotice = null)
    }

    fun clearNotice() {
        invalidateSendAnyway()
        mutableState.value = mutableState.value.copy(notice = null)
    }

    /** Consumes exactly the refused message; newer or merged draft text stays in the box. */
    fun sendAnyway(): Boolean {
        val candidate = sendAnywayCandidate ?: return false
        val current = mutableState.value
        val detail = current.projectedDetails[candidate.threadKey]
            ?: current.detail?.takeIf { it.row.key == candidate.threadKey }
        val valid = current.notice == current.sendAnywayNotice && current.notice == candidate.notice &&
            detail != null && sendAnywayTargetIsCurrent(candidate, detail)
        invalidateSendAnyway()
        if (!valid) return false
        mutableState.value = mutableState.value.copy(notice = null)
        return requestAction(detail, candidate.kind, candidate.text, bypassComposerVerification = true,
            retryDraftSnapshot = candidate.draftSnapshot, retryDraftRemainder = candidate.draftRemainder)
    }

    private fun sendAnywayTargetIsCurrent(candidate: SendAnywayCandidate, detail: AgentThreadDetail): Boolean {
        if (!enabled || runtime !== candidate.runtime || composerRetryGeneration != candidate.generation ||
            mutableState.value.selectedThreadKey != candidate.threadKey || candidate.threadKey in endedConversations || !candidate.binding.sameCoreBinding(detail.binding?.toJson()) ||
            (candidate.draftSnapshot != null && mutableState.value.drafts[candidate.threadKey].orEmpty() != candidate.draftSnapshot)) return false
        val owner = threadOwners[candidate.threadKey] ?: return false
        if (owner.canonicalBinding != candidate.binding.tokenKey() || owner.bindingToken != candidate.bindingToken) return false
        val exact = JSONObject().put("threadID", detail.row.threadIDJson()).put("binding", candidate.binding).endpointBindingOrNull()
            ?: return false
        return coordinator.directory.resolve(exact.key)?.isCurrentRoute(exact) == true
    }

    fun requestLaunch(request: AgentLaunchRequest) {
        invalidateSendAnyway()
        if (pendingLaunch != null) {
            mutableState.value = mutableState.value.copy(notice = "Another agent launch is already in progress")
            return
        }
        val detail = mutableState.value.detail ?: return
        val binding = detail.binding?.toJson() ?: return
        if (request.providerID !in detail.launchProviderIDs(request.kind) || !request.matchesDisplayedBinding(detail)) {
            mutableState.value = mutableState.value.copy(notice = "Launch target is stale")
            return
        }
        val exact = JSONObject().put("binding", binding).put("threadID", detail.row.threadIDJson()).endpointBindingOrNull() ?: run {
            mutableState.value = mutableState.value.copy(notice = "Launch target is stale")
            return
        }
        val endpoint = coordinator.directory.resolve(exact.key) ?: run {
            mutableState.value = mutableState.value.copy(notice = "Terminal session disconnected")
            return
        }
        val bindingToken = bindingTokens[binding.tokenKey(detail.row.key)] ?: run {
            mutableState.value = mutableState.value.copy(notice = "Launch authority is unavailable")
            return
        }
        scope.launch {
            if (!endpoint.isCurrentRoute(exact) || !request.matchesEndpointBinding(exact)) {
                mutableState.value = mutableState.value.copy(notice = "Launch target is stale")
                return@launch
            }
            val directories = (endpoint.validatedDirectories(exact) as? AgentEndpointResult.Success)?.value.orEmpty()
            if (request.directory.trim() !in directories) {
                mutableState.value = mutableState.value.copy(notice = "Choose the current proven tmux pane directory")
                return@launch
            }
            val parentRecordID = detail.live.lastOrNull()?.recordID
            val intent = request.coreIntent(detail, parentRecordID) ?: run {
                mutableState.value = mutableState.value.copy(notice = "Launch configuration is invalid")
                return@launch
            }
            val launch = PendingLaunch(
                request = request,
                threadKey = detail.row.key,
                threadID = detail.row.threadIDJson().toString(),
                binding = binding.toString(),
                intent = intent.toString(),
                parentRecordID = parentRecordID,
            )
            pendingLaunch = launch
            val accepted = forward(JSONObject().put("v", 1).put("kind", "launch")
                .put("threadID", detail.row.threadIDJson()).put("bindingToken", bindingToken).put("launch", intent))
            if (!accepted && pendingLaunch === launch) pendingLaunch = null
        }
    }

    /** Guarded exact-binding focus for the app's existing terminal navigator. */
    suspend fun focusExact(thread: AgentThreadDetail, isStillPresented: () -> Boolean = { true }): AgentTerminalFocusOutcome {
        val encodedBinding = thread.binding?.toJson() ?: return AgentTerminalFocusOutcome.RouteGone
        val envelope = JSONObject().put("binding", encodedBinding).put("threadID", thread.row.threadIDJson())
        val exact = envelope.endpointBindingOrNull() ?: return AgentTerminalFocusOutcome.RouteGone
        val endpoint = coordinator.directory.resolve(exact.key) ?: return AgentTerminalFocusOutcome.RouteGone
        fun current() = isStillPresented() && isTerminalBindingCurrent(thread)
        if (!current()) return AgentTerminalFocusOutcome.RouteGone
        if (exact.transport == AgentEndpointTransport.SSH || exact.transport == AgentEndpointTransport.MOSH) return AgentTerminalFocusOutcome.Success
        val outcome = endpoint.focus(exact, ::current).terminalFocusOutcome()
        return if (current()) outcome else AgentTerminalFocusOutcome.RouteGone
    }

    fun isTerminalBindingCurrent(thread: AgentThreadDetail): Boolean {
        if (!enabled || !applicationForeground) return false
        val encoded = thread.binding?.toJson() ?: return false
        val exact = JSONObject().put("binding", encoded).put("threadID", thread.row.threadIDJson()).endpointBindingOrNull() ?: return false
        val current = mutableState.value.projectedDetails[thread.row.key]?.binding?.toJson() ?: return false
        return current.sameCoreBinding(encoded) && coordinator.directory.resolve(exact.key)?.isCurrentRoute(exact) == true
    }

    fun isTerminalCarrierCurrent(thread: AgentThreadDetail): Boolean {
        val encoded = thread.binding?.toJson() ?: return false
        val exact = JSONObject().put("binding", encoded).put("threadID", thread.row.threadIDJson()).endpointBindingOrNull() ?: return false
        return coordinator.directory.resolve(exact.key)?.let { it.isCurrentIngestion(it.ingestionBinding) } == true
    }

    fun candidateTargetsLiveSession(candidate: AgentTerminalCandidate, hostID: String, liveSessionID: String?): Boolean {
        val exact = candidate.endpointBindingOrNull() ?: return false
        return exact.hostID.canonicalAgentUUID() == hostID.canonicalAgentUUID() &&
            exact.key.liveSessionID.canonicalAgentUUID() == liveSessionID?.canonicalAgentUUID() &&
            coordinator.directory.resolve(exact.key)?.let { it.isCurrentIngestion(it.ingestionBinding) } == true
    }

    fun reportTerminalNavigationOutcome(outcome: AgentTerminalNavigationOutcome, candidate: Boolean = false) {
        val notice = when (outcome) {
            AgentTerminalNavigationOutcome.UNAVAILABLE -> if (candidate) "The original terminal is unavailable"
                else "This terminal is no longer available. Open its session to continue."
            AgentTerminalNavigationOutcome.AUTHORITY_PENDING -> "Terminal opened; control has not settled yet"
            AgentTerminalNavigationOutcome.FAILED -> "Terminal opened; the requested pane could not be focused"
            AgentTerminalNavigationOutcome.CANCELLED, AgentTerminalNavigationOutcome.FOCUSED -> return
        }
        mutableState.value = mutableState.value.copy(notice = notice)
    }

    fun reportTerminalUnavailable() {
        mutableState.value = mutableState.value.copy(notice = "This terminal is no longer available. Open its session to continue.")
    }

    /** A transcript selection action missed; the message is the terminal's own. */
    fun reportSelectionMiss(message: String) {
        mutableState.value = mutableState.value.copy(notice = message)
    }

    /** Candidate focus is route-checked like thread focus; it never synthesizes a thread action. */
    suspend fun focusCandidateExact(candidate: AgentTerminalCandidate, isStillPresented: () -> Boolean = { true }): AgentTerminalFocusOutcome {
        val exact = candidate.endpointBindingOrNull() ?: return AgentTerminalFocusOutcome.RouteGone
        val endpoint = coordinator.directory.resolve(exact.key) ?: return AgentTerminalFocusOutcome.RouteGone
        fun current() = isStillPresented() && isCandidateBindingCurrent(candidate)
        if (!current()) return AgentTerminalFocusOutcome.RouteGone
        if (candidate.isRawTerminalTarget()) return AgentTerminalFocusOutcome.Success
        val outcome = endpoint.focus(exact, ::current).terminalFocusOutcome()
        return if (current()) outcome else AgentTerminalFocusOutcome.RouteGone
    }

    /** Raw SSH/Mosh has no focus command, but still needs this equality fence before navigation. */
    fun isCandidateBindingCurrent(candidate: AgentTerminalCandidate): Boolean {
        if (!enabled || !applicationForeground) return false
        val exact = candidate.endpointBindingOrNull() ?: return false
        return mutableState.value.candidates.any { it.key == candidate.key && it.binding == candidate.binding } &&
            coordinator.directory.resolve(exact.key)?.isCurrentRoute(exact) == true
    }

    /**
     * Candidates have no durable conversation identity, but their bounded
     * fallback prompt can be answered when its exact provider process and
     * terminal capture are freshly revalidated. This deliberately bypasses no
     * Core lease: it never sends text or accepts a snapshot-only option.
     */
    fun requestCandidatePromptAnswer(
        candidate: AgentTerminalCandidate,
        displayed: AgentPrompt,
        option: AgentPromptOption,
    ) {
        invalidateSendAnyway()
        val binding = candidate.binding?.toJson()
        if (!candidate.canAnswerPrompt() || option !in displayed.options || binding == null || isActionTargetBusy(candidate.key, binding) ||
            candidateActionsInFlight.putIfAbsent(candidate.key, binding) != null) {
            mutableState.value = mutableState.value.copy(notice = "Open terminal to answer")
            return
        }
        scope.launch {
            try {
                answerCandidatePrompt(candidate, displayed, option)
            } finally {
                candidateActionsInFlight.remove(candidate.key, binding)
            }
        }
    }

    fun reportCandidateTerminalUnavailable() {
        mutableState.value = mutableState.value.copy(notice = "The original terminal is unavailable")
    }

    /** A notification action may focus a prompt, but never accepts it. */
    fun prearmPromptReview(threadKey: String) {
        invalidateSendAnyway()
        mutableState.value = mutableState.value.copy(
            selectedThreadKey = threadKey,
            searchLanding = mutableState.value.searchLanding?.takeIf { it.threadKey == threadKey },
            notice = "Review the current prompt before answering.",
        )
    }

    internal suspend fun consume(event: SharedAgentRuntimeEvent) {
        if (lastRuntimeEventGeneration == 0L) {
            firstReadLifecycleOrderReliable = true
            firstReadLifecycleSources.clear()
        }
        if (lastRuntimeEventGeneration != 0L && event.runtimeGeneration > lastRuntimeEventGeneration + 1) {
            firstReadLifecycleOrderReliable = false
            firstReadLifecycleSources.clear()
        }
        if (lastRuntimeEventGeneration != 0L && event.runtimeGeneration > lastRuntimeEventGeneration + 1) actionRequestOrderReliable.set(false)
        lastRuntimeEventGeneration = maxOf(lastRuntimeEventGeneration, event.runtimeGeneration)
        when (event) {
            is SharedAgentRuntimeEvent.Snapshot -> {
                try { consumeSnapshot(event.snapshot) } finally { refreshPaneAgentProviders() }
            }
            is SharedAgentRuntimeEvent.RoutesRetired -> {
                for (retirement in event.retirements) {
                    // Already retired here, all at once, at its endpoint's teardown.
                    if (retiredObservationTokens.remove(retirement.bindingToken)) continue
                    val id = retirement.threadID.toJson()
                    val key = canonicalAgentThreadKey(id.getString("hostID"), id.getJSONObject("providerID").getString("rawValue"),
                        id.getString("providerSessionID"))
                    val successor = retirement.successor?.toJson()?.let {
                        canonicalAgentThreadKey(it.getString("hostID"), it.getJSONObject("providerID").getString("rawValue"),
                            it.getString("providerSessionID"))
                    }
                    if (retirement.reason == "replaced" && successor != null && successor != key) {
                        actionJobs.values.filter { it.threadKey == key && it.bindingToken == retirement.bindingToken }
                            .forEach { it.conversationRemoved = true }
                        settleRemovedConversation(key, retirement.bindingToken)
                    }
                    cancelUnwrittenActions(key, retirement.bindingToken)
                    val owner = threadOwners[key]
                    pendingOwners[key]?.takeIf { it.owner.bindingToken == retirement.bindingToken }?.accepted?.complete(false)
                    if (owner?.bindingToken == retirement.bindingToken) {
                        if (retireThreadOwner(key, owner, successor) && retirement.reason == "absent") {
                            val binding = JSONObject(owner.coreBindingJSON)
                            diagnostics?.invoke("agent_route_retired", mapOf("reason" to "absent",
                                "pane" to (binding.optNullableString("paneID") ?: "raw"), "pid" to binding.optString("agentPID")))
                        }
                    }
                    bindingTokens.entries.filter { it.value == retirement.bindingToken }.forEach { bindingTokens.remove(it.key, it.value) }
                    occupancyRetirements.remove(retirement.bindingToken)?.complete(Unit)
                }
            }
            is SharedAgentRuntimeEvent.Failure -> {
                if (event.code == "abi_event_too_large") {
                    firstReadLifecycleOrderReliable = false
                    firstReadLifecycleSources.clear()
                } else if (event.code.substringAfter('@', "") == "lifecycle" || event.code in setOf(
                        "unknownProvider", "unsupportedVersion", "pidMismatch", "sourceMismatch", "invalidV9Locator", "lifecycle_staleBinding")) {
                    firstReadLifecycleSources.poll()
                }
                if (event.code == "abi_event_too_large") actionRequestOrderReliable.set(false)
                // Core refuses asynchronously, long after `forward` returned
                // true, so this is the only place that knows a command was
                // rejected. It used to reach the user as a notice and reach a
                // device log not at all -- a screenshot reading "abi
                // invalidField" with nothing in diagnostics naming which
                // command it was.
                // '@' made the endpoint redactor erase the entire old code.
                diagnostics?.invoke("agent_core_rejected", mapOf(
                    "error" to event.code.substringBefore('@'),
                    "command" to event.code.substringAfter('@', "unknown"),
                ))
                if (event.code == "bind_liveElsewhere") {
                    event.details.obj("thread")?.obj("summary")?.obj("id")?.let { id ->
                        val key = canonicalAgentThreadKey(id.string("hostID") ?: return@let,
                            id.obj("providerID")?.string("rawValue") ?: return@let, id.string("providerSessionID") ?: return@let)
                        pendingOwners[key]?.accepted?.complete(false)
                    }
                    return
                }
                val reaction = agentRejectionReaction(event.code) ?: return
                if (reaction.endsPendingActions) {
                    // ABI command replies preserve request order. Accepted
                    // plans already left this queue; a rejection owns one request.
                    val rejectedID = event.details.obj("threadID") ?: event.details.obj("thread")?.obj("summary")?.obj("id")
                    val rejectedKey = rejectedID?.toJson()?.let { agentLeaseThreadKey(JSONObject().put("threadID", it)) }
                    val rejected = rejectedKey?.let(pendingActions::get)?.takeIf { it.leaseToken == null }
                        ?: if (rejectedKey == null && actionRequestOrderReliable.get()) pendingActionRequests.poll() else null
                    rejected?.let { pendingActionRequests.remove(it); pendingActions.remove(it.threadKey, it) }
                    publishSendingThreads()
                }
                // A fallback probe can already be queued when its original
                // notSent snapshot proves withdrawal. Only that exact lease's
                // obsolete result may preserve the proven one-shot dialog.
                val current = mutableState.value
                val candidate = sendAnywayCandidate
                val candidateDetail = candidate?.let { current.projectedDetails[it.threadKey]
                    ?: current.detail?.takeIf { detail -> detail.row.key == it.threadKey } }
                val rejectedLease = event.details.obj("lease")?.toJson()
                val preserveRetryNotice = event.code.substringAfter('@', "") == "result" && candidate != null &&
                    rejectedLease != null && rejectedLease.optString("token").equals(candidate.leaseToken, ignoreCase = true) &&
                    agentLeaseThreadKey(rejectedLease) == candidate.threadKey && candidate.binding.sameCoreBinding(rejectedLease.optJSONObject("binding")) &&
                    candidateDetail != null && current.notice == candidate.notice && current.sendAnywayNotice == candidate.notice &&
                    sendAnywayTargetIsCurrent(candidate, candidateDetail)
                mutableState.value = current.copy(
                    loading = false,
                    notice = if (preserveRetryNotice) current.notice else reaction.notice,
                )
                // Unattributed: it may be a launch receipt's or another
                // thread's. It settles no queued notSent; each asks Core again
                // (or may now probe, once the pending actions ended).
                notSentLedger.noteRejection(event.code).forEach { advanceNotSent(it, 0) }
            }
            is SharedAgentRuntimeEvent.Notice -> if (event.kind == "readerPlace") {
                event.details.string("ingestionRequestID")?.let { id ->
                    readerPlaceChecks.remove(id)?.complete(event.details.obj("search")?.let(AgentPresentation::searchResults)?.firstOrNull())
                }
            }
        }
    }

    private suspend fun answerCandidatePrompt(
        candidate: AgentTerminalCandidate,
        displayed: AgentPrompt,
        option: AgentPromptOption,
    ) {
        val binding = candidate.endpointBindingOrNull() ?: return candidateActionFailed()
        val endpoint = coordinator.directory.resolve(binding.key) ?: return candidateActionFailed()
        val provider = AgentProofProvider.fromWire(candidate.providerID) ?: return candidateActionFailed()
        val claimedPID = candidate.binding?.number("agentPID")?.toIntOrNull()?.takeIf { it > 1 } ?: return candidateActionFailed()
        if (!isCandidateCurrent(candidate, displayed) || endpoint.binding.value != binding) return candidateActionFailed()
        val proof = endpoint.proveProcess(binding, claimedPID, provider, requireForeground = true) as? AgentEndpointResult.Success
            ?: return candidateActionFailed()
        if (proof.value.provider != provider || claimedPID !in proof.value.processIDs) return candidateActionFailed()
        val first = parseFreshPrompt(endpoint, binding, candidate.key, displayed.actionToken, candidate.providerID, displayed.options)
            ?: return candidateActionFailed()
        if (!candidateActionTokenMatches(displayed.actionToken, first.signature)) return candidateActionFailed()
        val before = (endpoint.inspect(binding) as? AgentEndpointResult.Success)?.value
            ?.takeIf { it.authoritative && !it.truncated && !it.captureWaitedForFrame } ?: return candidateActionFailed()
        // Close the parse-to-write race: the current capture must parse to the
        // same signature and option before its macro is ever sent.
        val current = parseFreshPrompt(endpoint, binding, candidate.key, displayed.actionToken, candidate.providerID, displayed.options)
            ?.takeIf { it.signature == first.signature }
            ?.options?.firstOrNull { it.id == option.id && it.label == option.label && it.isDefault == option.isDefault }
            ?: return candidateActionFailed()
        if (!isCandidateCurrent(candidate, displayed) || endpoint.binding.value != binding) return candidateActionFailed()
        val semanticKey = AgentSemanticKey.entries.firstOrNull { it.encoded().decodeToString() == current.responseMacro }?.tmuxName
        val freshProof = endpoint.proveProcess(binding, claimedPID, provider, requireForeground = true) as? AgentEndpointResult.Success
            ?: return candidateActionFailed()
        if (freshProof.value != proof.value || !isCandidateCurrent(candidate, displayed) ||
            !endpoint.isCurrentRoute(binding) || endpoint.inputRefusal(binding) != null) return candidateActionFailed()
        val sent = sendAgentPromptStep(endpoint, binding, current.responseMacro, semanticKey)
        if (sent !is AgentEndpointResult.Success) return candidateActionFailed()
        // A capture with no text (tmux raced a redraw) proves nothing.
        val changed = awaitObservation(endpoint, binding) { observed ->
            observed.authoritative && !observed.truncated && agentCaptureHasText(observed) &&
                !observed.visibleTail.contentEquals(before.visibleTail)
        } ?: return candidateActionFailed()
        val after = settledFreshPrompt(endpoint, binding, candidate.key, displayed.actionToken, candidate.providerID, displayed.options)
            ?: return candidateActionFailed()
        if (!isCandidateCurrent(candidate, displayed) || after.prompt?.signature == first.signature || changed.visibleTail.contentEquals(before.visibleTail)) return candidateActionFailed()
    }

    private fun isCandidateCurrent(candidate: AgentTerminalCandidate, displayed: AgentPrompt): Boolean =
        mutableState.value.candidates.any {
            it.key == candidate.key && it.binding == candidate.binding && it.prompt?.actionToken == displayed.actionToken
        }

    private fun candidateActionFailed() {
        mutableState.value = mutableState.value.copy(notice = "Prompt changed; review it in the terminal")
    }

    private suspend fun consumeSnapshot(snapshot: SharedAgentSnapshot) {
        val acceptedLifecycleSource = if (snapshot.kind == SharedAgentSnapshotKind.Lifecycle) firstReadLifecycleSources.poll() else null
        val outgoingPhase = snapshot.payload.string("code")
        if (outgoingPhase == "outgoingArmed" || outgoingPhase == "outgoingDispatched") {
            snapshot.payload.obj("lease")?.string("token")?.let { outgoingArms.remove("$it:$outgoingPhase")?.complete(true) }
        }
        if (outgoingPhase == "promptCurrent" || outgoingPhase == "promptChanged") {
            snapshot.payload.obj("lease")?.string("token")?.let { promptAnswerChecks.remove(it)?.complete(outgoingPhase == "promptCurrent") }
        }
        val previous = mutableState.value
        when (snapshot.kind) {
            SharedAgentSnapshotKind.List -> {
                val rows = AgentPresentation.list(snapshot)
                // Which threads Core actually lists, so a row that never
                // arrives can be told apart from one that arrives and is then
                // dropped -- the two have identical symptoms in the UI.
                diagnostics?.invoke(
                    "agent_list_snapshot",
                    mapOf(
                        "detail" to "rows=${rows.size} " +
                            rows.joinToString(",") { "${it.providerID}:${it.providerSessionID.take(8)}" },
                    ),
                )
                val candidates = AgentPresentation.candidates(snapshot)
                val retained = resolveAgentHistoricalSelection(
                    previousSelection = previous.selectedThreadKey,
                    cachedDetailKeys = previous.projectedDetails.keys,
                    visibleRowKeys = rows.map { it.key },
                    ownedThreadKeys = threadOwners.keys.toSet(),
                )
                mutableState.value = previous.withListSnapshot(rows, candidates, retained)
                mutableState.value.projectedDetails.values.filter { it.row.livePromptWatch }.forEach(::startLivePromptWatchFromSnapshot)
                startDisplayedLivePromptWatch()
                generateMissingTitles(rows)
            }
            SharedAgentSnapshotKind.Thread,
            SharedAgentSnapshotKind.Lifecycle,
            SharedAgentSnapshotKind.Projection -> {
                // Main.immediate resumes the awaiting page reader inline the
                // moment its commit completes, and that reader and its
                // cleanup publish state of their own (spinner, prefetch).
                // Complete the commit only after this snapshot is published,
                // and build the publication from the state current at the
                // write rather than from `previous`.
                val commit = (snapshot.payload.string("ingestionRequestID") ?: snapshot.payload.obj("ingestion")?.string("requestID"))
                    ?.let(ingestionCommits::remove)?.let { waiter ->
                        waiter to NativeCommit(
                            snapshot.payload.string("code") in setOf("applied", "sourceReset", "duplicate", "summaryApplied", "hookApplied", "hookIgnored"),
                            snapshot.payload.obj("thread")?.obj("ingestionWindow")?.toJson(),
                            snapshot.payload.string("code"))
                    }
                try {
                    // Mapping a near-MiB snapshot is pure; only that leaves
                    // Main. A small one maps inline: a burst of them must not
                    // wait for Main once per event while the bounded runtime
                    // event buffer fills. This collector stays sequential, and
                    // publication below still reads the state current at the write.
                    val thread = snapshot.payload.obj("thread")
                    thread?.let { currentThread ->
                        val id = currentThread.obj("summary")?.obj("id") ?: return@let
                        val key = canonicalAgentThreadKey(id.string("hostID") ?: return@let,
                            id.obj("providerID")?.string("rawValue") ?: return@let, id.string("providerSessionID") ?: return@let)
                        when (currentThread.bool("conversationEnded")) {
                            true -> { endedConversations.add(key); cancelUnwrittenActions(key) }
                            false -> endedConversations.remove(key)
                            null -> Unit
                        }
                        if (snapshot.kind == SharedAgentSnapshotKind.Thread) pendingOwners[key]?.let { pending ->
                            if (currentThread.obj("binding")?.toJson()?.sameCoreBinding(JSONObject(pending.owner.coreBindingJSON)) == true) {
                                pending.accepted.complete(true)
                            }
                        }
                    }
                    val items = (thread?.array("messages")?.size ?: 0) + (thread?.array("activity")?.size ?: 0) +
                        (thread?.obj("changes")?.array("edits")?.size ?: 0)
                    val mapped = (if (items <= INLINE_DETAIL_ITEMS) AgentPresentation.detail(snapshot)
                        else kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
                            AgentPresentation.detail(snapshot)
                        }) ?: return
                    if (mapped.row.key in retiredOwnerThreads && threadOwners[mapped.row.key] == null) {
                        settleNotSent(mapped, agentNotSentEvidence(snapshot.payload.string("code")))
                        return
                    }
                    val detail = withKnownDirectoryProof(mapped)
                    if (snapshot.kind == SharedAgentSnapshotKind.Lifecycle && thread?.bool("conversationEnded") == true) {
                        threadOwners[detail.row.key]?.endpointKey?.let(coordinator.directory::resolve)?.let(::scheduleOccupancySweeps)
                    }
                    if (snapshot.payload.string("code") == "cacheEvicted") {
                        for (host in ingestionHosts.values) host.threads[detail.row.key]?.let { it.coreEvicted = true }
                        scheduleNativeInterests()
                    }
                    pendingTerminalReads.remove(detail.row.key)?.let { read ->
                        if (detail.row.attention == "none" && detail.row.status == "idle"
                            && detail.deliveryGeneration == read.generation + 1
                            && threadOwners[detail.row.key]?.bindingToken == read.bindingToken) {
                            read.recordID?.let { recordID -> scope.launch {
                                metadata.rememberRead(detail.row.key, recordID, unread = false, now = System.currentTimeMillis())
                            } }
                        }
                    }
                    synchronized(presentationHoldLock) {
                        if (detail.row.key in presentationHolds) heldDetails[detail.row.key] = detail
                        else mutableState.value = mutableState.value.withThreadSnapshot(detail)
                    }
                    acceptedLifecycleSource?.let { restartMissingFirstRead(detail, it) }
                    settleNotSent(detail, agentNotSentEvidence(snapshot.payload.string("code")))
                    schedulePromptObservation(detail)
                    if (detail.row.livePromptWatch || isDisplayingThread(detail.row.key)) startLivePromptWatchFromSnapshot(detail)
                    scheduleDirectoryProof(detail)
                    publishAttentionIfNeeded(detail)
                    persistCompletionKeys(detail)
                } finally {
                    commit?.let { (waiter, result) -> waiter.complete(result) }
                }
            }
            SharedAgentSnapshotKind.ActionPlan -> {
                val mapped = AgentPresentation.detail(snapshot)?.let(::withKnownDirectoryProof) ?: run {
                    actionRequestOrderReliable.set(false)
                    return
                }
                val detail = mapped.withKnownFreshPrompt(previous.projectedDetails[mapped.row.key] ?: previous.detail)
                pendingActions[detail.row.key]?.let { pending ->
                    pendingActionRequests.remove(pending)
                    if (pendingActionRequests.isEmpty()) actionRequestOrderReliable.set(true)
                    snapshot.payload.obj("lease")?.string("token")?.let { token ->
                        pending.leaseToken = token
                        actionBindingTokens[token] = pending.bindingToken
                    }
                }
                // Each write gets its own fresh capture and process proof.
                promptObservationJobs.remove(detail.row.key)?.job?.cancel()
                val sentText = snapshot.payload.obj("actionPayload")?.obj("text")?.string("text")
                val token = snapshot.payload.obj("lease")?.string("token")
                // Recorded per lease: a refusal returns the message only if
                // this ActionPlan actually took it out of the box.
                val draftBeforePlan = previous.drafts[detail.row.key].orEmpty()
                val pendingTextAction = pendingActions[detail.row.key]
                val draftAfterPlan = if (sentText == null) draftBeforePlan else
                    if (pendingTextAction?.bypassComposerVerification == true &&
                        pendingTextAction.text == sentText && pendingTextAction.retryDraftSnapshot == draftBeforePlan)
                        pendingTextAction.retryDraftRemainder ?: draftAfterActionPlan(draftBeforePlan, sentText)
                    else draftAfterActionPlan(draftBeforePlan, sentText)
                val draftCleared = sentText != null && token != null && draftAfterPlan != draftBeforePlan
                // A held thread's plan waits with its other snapshots.
                val held = synchronized(presentationHoldLock) {
                    (detail.row.key in presentationHolds).also { if (it) heldDetails[detail.row.key] = detail }
                }
                mutableState.value = previous.copy(
                    detail = if (!held && previous.selectedThreadKey == detail.row.key) detail else previous.detail,
                    projectedDetails = if (held) previous.projectedDetails else previous.projectedDetails + (detail.row.key to detail),
                    acceptedSend = if (sentText != null && token != null) AgentAcceptedSend(token, detail.row.key, sentText) else previous.acceptedSend,
                    drafts = if (sentText != null && token != null) previous.drafts +
                        (detail.row.key to draftAfterPlan) else previous.drafts,
                )
                // Core plans a new lease only after processing every result
                // queued before it, including this thread's `notSent`.
                notSentLedger.settleByActionPlan(detail, sentText)?.let { (wait, settlement) ->
                    applyNotSentSettlement(wait, settlement, source = "actionPlan")
                }
                publishAttentionIfNeeded(detail)
                val actionToken = snapshot.payload.obj("lease")?.string("token") ?: return
                val actionRuntime = runtime
                val writes = AgentTerminalWriteLatch()
                // Only a throw before the write latch is provably unwritten;
                // after it the write is ambiguous and keeps its legacy code.
                fun finishAborted(cancelled: Boolean) {
                    if (!enabled || runtime !== actionRuntime) return
                    val lease = runCatching { snapshot.payload.obj("lease")?.toJson() }.getOrNull() ?: run {
                        // No lease to answer Core with; at least stop this
                        // thread's pending action from blocking every action.
                        pendingActions.remove(detail.row.key)
                        publishSendingThreads()
                        return
                    }
                    val finish = agentAbortedActionFinish(lease.optString("action"), writes, cancelled)
                    val routeChanged = actionJobs[actionToken]?.routeChanged == true
                    val legacyCode = if (routeChanged) "staleBinding" else finish.legacyCode
                    finish.notSent?.let { reason ->
                        finishNotSent(lease, detail, if (routeChanged) AgentNotSentReason.ROUTE_CHANGED else reason,
                            legacyCode, sentText, draftCleared, actionRuntime)
                    } ?: finishAction(lease, legacyCode, threadKey = detail.row.key)
                }
                val started = java.util.concurrent.atomic.AtomicBoolean(false)
                val job = scope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
                    started.set(true)
                    try { executeActionPlan(snapshot, detail, writes, actionRuntime, draftCleared) }
                    catch (failure: Throwable) {
                        // A decode or read that throws must still finish the
                        // lease, or the action stays pending and Core's bubble
                        // stays sending. The class name is the only detail logged.
                        agentEndActionJob(failure, currentCoroutineContext().isActive, ::finishAborted, onUnexpected = {
                            diagnostics?.invoke("agent_action_unexpected_failure", mapOf(
                                "action" to (snapshot.payload.obj("lease")?.string("action") ?: "unknown"),
                                "errorType" to it.javaClass.simpleName.ifEmpty { "anonymous" },
                                "written" to writes.mayHaveWritten.toString(),
                            ))
                        }, onFinishFailure = {
                            diagnostics?.invoke("agent_action_finish_failed", mapOf(
                                "errorType" to it.javaClass.simpleName.ifEmpty { "anonymous" }))
                        })
                    }
                }
                actionJobs[actionToken] = ActionJob(detail.row.key, actionBindingTokens[actionToken], writes, job)
                job.invokeOnCompletion {
                    try {
                        // Cancellation before dispatch never enters the body's catch.
                        if (!started.get()) finishAborted(cancelled = true)
                    } finally { actionJobs.remove(actionToken); actionBindingTokens.remove(actionToken) }
                }
                job.start()
            }
            SharedAgentSnapshotKind.Search -> {
                val search = AgentPresentation.search(snapshot)
                diagnostics?.invoke("agent_search_presented", mapOf("count" to search.first.size.toString()))
                mutableState.value = previous.copy(
                    loading = false,
                    searchResults = search.first,
                    unavailableSearchHostCount = search.second,
                )
            }
            SharedAgentSnapshotKind.PromptObservation -> resolvePromptObservation(snapshot)
            SharedAgentSnapshotKind.LaunchPlan -> scope.launch { executeLaunchPlan(snapshot) }
            SharedAgentSnapshotKind.Unknown -> Unit
        }
    }

    /** Core parses a fresh terminal capture before a snapshot card becomes actionable. */
    private fun cancelPromptObservations() {
        val retired = promptObservationJobs.values.toList()
        promptObservationJobs.clear()
        retired.forEach { it.job.cancel() }
    }

    private fun schedulePromptObservation(snapshot: AgentThreadDetail) {
        val detail = mutableState.value.projectedDetails[snapshot.row.key] ?: snapshot
        val key = detail.row.key
        val prompt = detail.prompt
        val active = promptObservationJobs[key]
        if (active != null && (prompt == null || active.token != prompt.actionToken || active.binding != detail.binding)) {
            promptObservationJobs.remove(key)
            active.job.cancel()
        }
        if (prompt == null || detail.canAnswerPrompt() || pendingActions.containsKey(key)) return
        // Reserve before launching, including the time spent waiting for the
        // parser mutex. Repeated snapshots must not build a capture backlog.
        if (promptObservationJobs[key] != null) return
        val envelope = JSONObject().put("binding", detail.binding?.toJson()).put("threadID", detail.row.threadIDJson())
        val binding = envelope.endpointBindingOrNull() ?: return
        val endpoint = coordinator.directory.resolve(binding.key) ?: return
        val ownerRuntime = runtime ?: return
        lateinit var job: Job
        job = scope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
            try {
                val fresh = observeFreshPrompt(endpoint, binding, key, prompt.actionToken, detail.row.providerID, prompt.options)
                    ?: return@launch
                if (!enabled || runtime !== ownerRuntime || coordinator.directory.resolve(binding.key) !== endpoint ||
                    !endpoint.isCurrentRoute(binding)) return@launch
                val state = mutableState.value
                fun refreshed(current: AgentThreadDetail?): AgentThreadDetail? {
                    val currentPrompt = current?.prompt ?: return null
                    return current.takeIf { it.row.key == key && currentPrompt.actionToken == prompt.actionToken &&
                        it.binding == detail.binding }?.copy(prompt = currentPrompt.copy(fresh = fresh))
                }
                val selected = refreshed(state.detail)
                val projected = refreshed(state.projectedDetails[key])
                updateHeldDetail(key) { refreshed(it) }
                if (selected != null || projected != null) mutableState.value = state.copy(
                    detail = selected ?: state.detail,
                    projectedDetails = if (projected == null) state.projectedDetails else state.projectedDetails + (key to projected))
            } finally {
                if (promptObservationJobs[key]?.job === job) promptObservationJobs.remove(key)
            }
        }
        promptObservationJobs[key] = PromptObservationJob(prompt.actionToken, detail.binding, job)
        job.start()
    }

    /** A route's proven directories, reused while its exact binding holds. */
    private data class DirectoryProof(val binding: SharedAgentValue.ObjectValue, val directories: List<String>?)

    /** Snapshots are mapped fresh; carry an already-proven binding's paths. */
    private fun withKnownDirectoryProof(detail: AgentThreadDetail): AgentThreadDetail {
        val proof = directoryProofs[detail.row.key] ?: return detail
        val directories = proof.directories ?: return detail
        return if (proof.binding == detail.binding && detail.provenDirectories != directories) {
            detail.copy(provenDirectories = directories)
        } else detail
    }

    /**
     * Keep exact pane-path evidence in memory only and refresh it from tmux
     * when the binding changes. Transcript snapshots of the same binding
     * reuse it; a launch re-proves its directory before any side effect.
     */
    private fun scheduleDirectoryProof(detail: AgentThreadDetail) {
        val proven = detail.binding ?: return
        val key = detail.row.key
        if (directoryProofs[key]?.binding == proven) return
        val envelope = JSONObject().put("binding", proven.toJson()).put("threadID", detail.row.threadIDJson())
        val binding = envelope.endpointBindingOrNull() ?: return
        val endpoint = coordinator.directory.resolve(binding.key) ?: return
        val pending = DirectoryProof(proven, null)
        directoryProofs[key] = pending
        scope.launch {
            var settled = false
            try {
                if (!endpoint.isCurrentRoute(binding)) return@launch
                // A failed query stays unproven, so the next snapshot retries.
                val directories = (endpoint.validatedDirectories(binding) as? AgentEndpointResult.Success)?.value
                    ?.filter(::validProvenDirectory) ?: return@launch
                settled = directoryProofs.replace(key, pending, DirectoryProof(proven, directories))
                if (!settled) return@launch
                val state = mutableState.value
                val current = state.detail?.takeIf { it.row.key == key && it.binding == proven && it.provenDirectories != directories }
                val projected = state.projectedDetails[key]?.takeIf { it.binding == proven && it.provenDirectories != directories }
                updateHeldDetail(key) { held ->
                    held.takeIf { it.binding == proven && it.provenDirectories != directories }?.copy(provenDirectories = directories)
                }
                if (current == null && projected == null) return@launch
                mutableState.value = state.copy(
                    detail = current?.copy(provenDirectories = directories) ?: state.detail,
                    projectedDetails = if (projected == null) state.projectedDetails
                        else state.projectedDetails + (key to projected.copy(provenDirectories = directories)),
                )
            } finally {
                if (!settled) directoryProofs.remove(key, pending)
            }
        }
    }

    private fun resolvePromptObservation(snapshot: SharedAgentSnapshot) {
        val pending = pendingPromptObservation ?: return
        // A reply to a request that timed out would plan on an older capture.
        if (snapshot.payload.string("promptRequestID") != pending.requestID) return
        val result = snapshot.payload.obj("promptObservation")
        val signature = result?.string("signature")
        val options = result?.array("options").orEmpty().mapNotNull { value ->
            val option = value as? com.bambouville.tessera.core.bridge.SharedAgentValue.ObjectValue ?: return@mapNotNull null
            val id = option.string("id") ?: return@mapNotNull null
            val label = option.string("label") ?: return@mapNotNull null
            val macro = option.string("responseMacro") ?: return@mapNotNull null
            val isDefault = option.bool("isDefault") ?: false
            AgentFreshPromptOption(id, label, macro, isDefault)
        }
        val candidate = pending.actionToken.startsWith("candidate-")
        val canonicalOptions = if (candidate) options.mapIndexed { index, option ->
            if (pending.displayed.getOrNull(index)?.id == option.responseMacro) option.copy(id = option.responseMacro) else option
        } else options
        val fresh = signature?.let { AgentFreshPrompt(it, canonicalOptions, result.string("kind") ?: "permission") }?.takeIf {
            if (candidate) it.options.size == pending.displayed.size && it.options.zip(pending.displayed).all { (parsed, displayed) ->
                parsed.id == displayed.id && parsed.label == displayed.label && parsed.isDefault == displayed.isDefault
            } else livePromptActionToken(it.signature) == pending.actionToken
        }
        val plan = snapshot.payload.obj("promptAnswerPlan")?.let { SharedAgentPromptAnswerStep.decode(it) }
        pending.deferred.complete(FreshPromptRead(fresh, plan))
    }

    private suspend fun parseFreshPrompt(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        threadKey: String,
        actionToken: String,
        providerID: String,
        displayed: List<AgentPromptOption>,
    ): AgentFreshPrompt? = observeFreshPrompt(endpoint, binding, threadKey, actionToken, providerID, displayed)

    /**
     * Core's prompt-observation ABI intentionally returns no request identity.
     * Serialize the entire inspect -> parse -> response interval so a response
     * can never be attached to a different thread's pending request.
     */
    private suspend fun observeFreshPrompt(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        threadKey: String,
        actionToken: String,
        providerID: String,
        displayed: List<AgentPromptOption>,
    ): AgentFreshPrompt? = readFreshPrompt(endpoint, binding, threadKey, actionToken, providerID, displayed)?.prompt

    /** One parsed capture; [prompt] is null when that capture shows no matching prompt. */
    private class FreshPromptRead(val prompt: AgentFreshPrompt?, val plan: SharedAgentPromptAnswerStep? = null)

    /** Null when no settled capture with text was parsed in time. */
    private suspend fun readFreshPrompt(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        threadKey: String,
        actionToken: String,
        providerID: String,
        displayed: List<AgentPromptOption>,
        planInput: JSONObject? = null,
    ): FreshPromptRead? = withTimeoutOrNull(2_000) {
        promptObservationMutex.withLock {
            val ownerRuntime = runtime ?: return@withLock null
            fun current() = enabled && runtime === ownerRuntime &&
                coordinator.directory.resolve(binding.key) === endpoint && endpoint.isCurrentRoute(binding)
            if (!current()) return@withLock null
            val observed = (endpoint.inspect(binding) as? AgentEndpointResult.Success)?.value ?: return@withLock null
            if (!current() || !observed.binding.sameRouteAs(binding) || !observed.authoritative ||
                observed.truncated || observed.captureWaitedForFrame) return@withLock null
            val visible = promptRows(observed)
            if (visible.isBlank()) return@withLock null
            val cursor = boundedPromptCursor(observed.currentCursorLine)
            val deferred = CompletableDeferred<FreshPromptRead>()
            val pending = PendingPromptObservation(threadKey, actionToken, displayed, providerID, deferred)
            pendingPromptObservation = pending
            // A thread's capture is read as its card was: a dialog whose
            // question scrolled off only through the call that names it.
            val thread = if (actionToken.startsWith("candidate-")) null else threadKey.threadIDJson()
            try {
                if (!forward(JSONObject().put("v", 1).put("kind", "promptObservation").put("promptObservation", JSONObject()
                        .put("providerID", providerID(providerID)).put("visibleText", visible).putOpt("currentCursorLine", cursor))
                        .putOpt("threadID", thread).putOpt("promptAnswerPlan", planInput).put("promptRequestID", pending.requestID))) {
                    return@withLock null
                }
                deferred.await().takeIf { current() }
            } finally {
                if (pendingPromptObservation === pending) pendingPromptObservation = null
            }
        }
    }

    /**
     * Before and after a prompt answer: re-reads within the readiness window until a
     * capture with text parses. Null (verification failed) when none does.
     */
    private suspend fun settledFreshPrompt(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        threadKey: String,
        actionToken: String,
        providerID: String,
        displayed: List<AgentPromptOption>,
        planInput: JSONObject? = null,
    ): FreshPromptRead? {
        val policy = AgentSendPreflightPolicy()
        val started = System.nanoTime()
        // A stalled read (its tmux ack fails only after 15 s) must not hold
        // the lease past the preflight deadline.
        return withTimeoutOrNull(policy.deadlineMillis) {
            var read = readFreshPrompt(endpoint, binding, threadKey, actionToken, providerID, displayed, planInput)
            while (read == null && (System.nanoTime() - started) / 1_000_000 + policy.intervalMillis <= policy.windowMillis) {
                delay(policy.intervalMillis)
                read = readFreshPrompt(endpoint, binding, threadKey, actionToken, providerID, displayed, planInput)
            }
            read
        }
    }

    private fun publishAttentionIfNeeded(detail: AgentThreadDetail) {
        if (detail.row.attention !in setOf("needsYou", "unreadCompletion")) {
            deliveredAttention.removeIf { it.startsWith("${detail.row.key}:") }
            attentionNotifier?.withdraw(detail.row.key)
            return
        }
        if (applicationForeground) return
        // Keyed on Core's attention epoch, not the per-frame generation: an
        // idle notification, a rebind or a replayed Stop is the same finish.
        val deliveryKey = detail.attentionDeliveryKey() ?: return
        if (!deliveredAttention.add(deliveryKey)) return
        scope.launch { attentionNotifier?.publish(detail) }
    }

    /**
     * Keeps Core's content-free completion identities in Room, so a relaunch
     * neither resurrects a finish already read nor loses one still unread.
     * Each write stores the newest pair, so writes may land in any order.
     */
    private fun persistCompletionKeys(detail: AgentThreadDetail) {
        val key = detail.row.key
        val keys = detail.unreadCompletionKey to detail.acknowledgedCompletionKey
        val previous = persistedCompletionKeys.put(key, keys) ?: (null to null)
        if (previous == keys) return
        scope.launch {
            val latest = persistedCompletionKeys[key] ?: return@launch
            metadata.rememberCompletion(key, latest.first, latest.second, now = System.currentTimeMillis())
        }
    }

    /**
     * Reports how many characters of an opening prompt a list row can show.
     *
     * The bottom tier of the title waterfall is a clipped prompt, and how much
     * of it fits is a property of this screen, so the width comes from the UI
     * and the clipping stays in shared Core where both platforms get it.
     */
    fun setTitleCharacterBudget(characters: Int) {
        val bounded = characters.coerceIn(MIN_TITLE_CHARACTERS, MAX_TITLE_CHARACTERS)
        if (bounded == titleCharacterBudget) return
        titleCharacterBudget = bounded
        forward(JSONObject().put("v", 1).put("kind", "title").put("titleBudget", bounded))
    }

    /**
     * Asks the on-device model for a title for every listed thread still
     * resting on a clipped prompt.
     *
     * Core decides what is worth generating (it publishes the tier and the
     * seed) and whether the answer is still current when it arrives, so a row
     * that gains the agent own title meanwhile simply refuses the late answer.
     */
    private fun generateMissingTitles(rows: List<AgentThreadRow>) {
        val generator = titleGenerator ?: return
        val wanted = rows.filter { row ->
            row.titleProvenance in TITLE_TIERS_WORTH_GENERATING &&
                row.titleSeed?.isNotBlank() == true &&
                requestedTitleSeeds.add(row.titleSeed)
        }
        if (wanted.isEmpty()) return
        // Serialised behind one job: the device model is a single session and a
        // list refresh can want a dozen titles at once.
        val previous = titleGenerationJob
        titleGenerationJob = scope.launch {
            previous?.join()
            for (row in wanted) {
                if (!enabled) break
                val seed = row.titleSeed ?: continue
                val threadID = row.key.threadIDJson() ?: continue
                val generated = runCatching { generator.title(seed) }.getOrNull()
                if (generated.isNullOrBlank()) continue
                forward(
                    JSONObject().put("v", 1).put("kind", "title")
                        .put("threadID", threadID)
                        .put("generatedTitle", generated)
                        .put("titleSeed", seed),
                )
            }
        }
    }

    private fun forward(command: JSONObject): Boolean =
        forwardEncoded(command.toString().toByteArray(StandardCharsets.UTF_8))

    /** [forward] for a command already encoded off the Main thread. */
    private fun forwardEncoded(command: ByteArray): Boolean {
        val target = runtime ?: run {
            mutableState.value = mutableState.value.copy(notice = "Agent request unavailable")
            return false
        }
        val result = runCatching {
            target.sendCanonical(command)
        }.getOrElse { CoreCallResult.StaleHandle }
        if (result != CoreCallResult.Accepted) {
            mutableState.value = mutableState.value.copy(notice = "Agent request unavailable")
        }
        return result == CoreCallResult.Accepted
    }

    private suspend fun monitorTierACandidates(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
    ) {
        var nextOccupancyNanos = 0L
        while (enabled && endpoint.binding.value == binding && tierACandidateBindings[binding.key] == binding) {
            try {
                if (applicationForeground && System.nanoTime() >= nextOccupancyNanos) {
                    nextOccupancyNanos = System.nanoTime() + OCCUPANCY_REFRESH_MILLIS * 1_000_000
                    reconcileEndpointOccupancy(endpoint)
                }
                refreshTierACandidates(endpoint, binding)
            } catch (failure: Throwable) {
                if (failure is kotlinx.coroutines.CancellationException) throw failure
            }
            delay(if (applicationForeground) ((nextOccupancyNanos - System.nanoTime()) / 1_000_000)
                .coerceIn(1, TIER_A_REFRESH_MILLIS) else TIER_A_REFRESH_MILLIS)
        }
    }

    internal suspend fun observeEndpointEvents(endpoint: AgentSessionEndpoint): Unit = coroutineScope {
        launch {
            endpoint.tmuxPaneRemovals.collect { scheduleOccupancySweeps(endpoint) }
        }
        endpoint.lifecycleFrames.collect { frame ->
            val retained = endpoint.retainedLifecycleFrame(frame.binding)
            if (retained != null && (!retained.binding.sameRouteAs(frame.binding) ||
                    !retained.payload.contentEquals(frame.payload))) return@collect
            val retryKey = endpoint.key to frame.binding.paneID
            lifecycleProofRetries.cancel(retryKey)
            if (consumeLifecycle(endpoint, frame)) {
                lifecycleProofRetries.schedule(retryKey,
                    isCurrent = {
                        coordinator.directory.resolve(endpoint.key) === endpoint &&
                            endpoint.isCurrentRoute(frame.binding) &&
                            (endpoint.retainedLifecycleFrame(frame.binding)?.let { latest ->
                                latest.binding.sameRouteAs(frame.binding) && latest.payload.contentEquals(frame.payload)
                            } ?: true)
                    },
                    attempt = { consumeLifecycle(endpoint, frame) },
                )
            }
        }
    }

    private fun scheduleOccupancySweeps(endpoint: AgentSessionEndpoint) {
        if (!enabled || !applicationForeground) return
        occupancySweepJobs.remove(endpoint.key)?.cancel()
        lateinit var job: Job
        job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val started = System.nanoTime()
                for (at in listOf(300L, 1_500L, 4_000L)) {
                    delay((at - (System.nanoTime() - started) / 1_000_000).coerceAtLeast(0))
                    if (coordinator.directory.resolve(endpoint.key) !== endpoint || !enabled || !applicationForeground) return@launch
                    try { reconcileEndpointOccupancy(endpoint) }
                    catch (failure: CancellationException) { throw failure }
                    catch (_: Throwable) { /* An unavailable inventory cannot prove absence. */ }
                }
            } catch (failure: CancellationException) { throw failure }
            finally { occupancySweepJobs.remove(endpoint.key, job) }
        }
        occupancySweepJobs[endpoint.key] = job
        job.start()
    }

    internal suspend fun reconcileEndpointOccupancy(endpoint: AgentSessionEndpoint): AgentOccupancySnapshot? =
        occupancySweepLocks.getOrPut(endpoint.key) { Mutex() }.withLock {
            val ownerRuntime = runtime ?: return@withLock null
            val carrier = endpoint.ingestionBinding
            fun current() = enabled && applicationForeground && runtime === ownerRuntime &&
                coordinator.directory.resolve(endpoint.key) === endpoint && endpoint.isCurrentIngestion(carrier)
            if (!current()) return@withLock null
            val owners = threadOwners.filterValues { it.endpointKey == endpoint.key }
            if (pendingOwners.any { it.key in owners || it.value.owner.endpointKey == endpoint.key }) return@withLock null
            val bindings = owners.values.mapNotNull { owner ->
                val binding = JSONObject(owner.coreBindingJSON)
                if (binding.optInt("agentPID", 0) <= 1) null else owner.endpointBinding?.takeIf {
                    it.copy(windowID = carrier.windowID, paneID = carrier.paneID).sameRouteAs(carrier)
                }
            }.distinctBy { it.paneID }.take(256)
            if (bindings.isEmpty()) return@withLock null
            val result = endpoint.observeOccupancy(bindings)
            currentCoroutineContext().ensureActive()
            // A proof arriving during this read needs a newer inventory.
            if (!current() || threadOwners.filterValues { it.endpointKey == endpoint.key } != owners ||
                pendingOwners.any { it.key in owners || it.value.owner.endpointKey == endpoint.key }) return@withLock null
            val observed = (result as? AgentEndpointResult.Success)?.value ?: return@withLock null
            val panes = JSONArray()
            observed.panes.forEach { pane ->
                panes.put(JSONObject().putOpt("paneID", pane.paneID).put("exists", pane.exists).put("complete", pane.complete)
                    .put("processes", JSONArray().also { processes -> pane.processes.forEach {
                        processes.put(JSONObject().put("pid", it.pid).put("providerID", providerID(it.provider.wireID)))
                    } }).put("unclassifiedPIDs", JSONArray(pane.unclassifiedPIDs)))
            }
            val binding = JSONObject(threadOwners.values.firstOrNull { it.endpointKey == endpoint.key }?.coreBindingJSON
                ?: return@withLock null)
            val observation = JSONObject().put("hostID", carrier.hostID).put("liveSessionID", carrier.key.liveSessionID)
                .put("carrierGeneration", carrier.key.carrierGeneration).put("transport", binding.getString("transport"))
                .putOpt("tmuxSession", carrier.tmuxSession).put("panes", panes)
                .putOpt("allPaneIDs", observed.allPaneIDs?.let(::JSONArray))
            if (forward(JSONObject().put("v", 1).put("kind", "occupancy").put("occupancy", observation))) observed else null
        }

    private suspend fun refreshTierACandidates(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
    ): List<com.bambouville.tessera.agent.platform.AgentDiscoveredProcess> {
        val scopeResult = endpoint.processDiscoveryScope(binding)
        currentCoroutineContext().ensureActive()
        if (!tierABindingIsCurrent(endpoint, binding)) return emptyList()
        val scope = (scopeResult as? AgentEndpointResult.Success)?.value ?: return emptyList()
        val result = endpoint.discoverProcesses(binding, AgentProcessDiscoveryCommands.command(scope))
        currentCoroutineContext().ensureActive()
        if (!tierABindingIsCurrent(endpoint, binding)) return emptyList()
        val processes = (result as? AgentEndpointResult.Success)?.value?.processes ?: return emptyList()
        val observation = (endpoint.inspect(binding) as? AgentEndpointResult.Success)?.value
        currentCoroutineContext().ensureActive()
        if (!tierABindingIsCurrent(endpoint, binding)) return emptyList()
        val liveTail = observation?.visibleTail?.decodeToString()?.takeLast(16_384).orEmpty()
        val previous = tierACandidates[binding.key].orEmpty()
        val processIDs = processes.mapTo(linkedSetOf()) { it.processID }
        val refreshed = linkedMapOf<String, AgentTierACandidateRegistration>()
        processes.forEach { process ->
            coordinator.registerTierACandidate(
                binding,
                process,
                processIDs,
                liveTail,
                previous,
            )?.let { refreshed[it.sourceIdentity] = it }
        }
        previous.filterKeys { it !in refreshed }.values.forEach { stale ->
            coordinator.removeTierACandidate(binding, stale.providerID, stale.sourceIdentity)
        }
        tierACandidates[binding.key] = refreshed
        return processes
    }

    private fun tierABindingIsCurrent(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
    ): Boolean = enabled && coordinator.directory.resolve(binding.key) === endpoint &&
        endpoint.binding.value == binding && tierACandidateBindings[binding.key] == binding

    private fun removeTierACandidates(key: AgentSessionKey, binding: AgentEndpointBinding) {
        tierACandidates.remove(key).orEmpty().values.forEach { candidate ->
            coordinator.removeTierACandidate(binding, candidate.providerID, candidate.sourceIdentity)
        }
    }

    private fun restartTierCInventory(endpoint: AgentSessionEndpoint, binding: AgentEndpointBinding) {
        tierCInventoryJobs.remove(binding.key)?.cancel()
        tierCConformances.remove(binding.key)
        reconfigureTierCConformances()
        tierCInventoryJobs[binding.key] = scope.launch { inventoryTierCProviders(endpoint, binding) }
    }

    /**
     * Tier-C discovery is a remote-data operation only. It never calls
     * inspect(), reads a terminal snapshot, or sends bytes to a visible PTY.
     * A provider becomes visible only after its own inventory stream is fully
     * bounded and structurally accepted, then native Core applies its compiled
     * adapter/digest attestation before this method binds any discovered row.
     */
    private suspend fun inventoryTierCProviders(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
    ) {
        for (provider in AgentTierCProvider.entries) {
            if (provider in setOf(AgentTierCProvider.Pi, AgentTierCProvider.OpenCode, AgentTierCProvider.Kimi)) continue // Native readers own inventory and subscriptions.
            if (endpoint.binding.value != binding || !enabled) return
            val records = ArrayList<com.bambouville.tessera.agent.platform.AgentTierCInventoryRecord>()
            val seenCursors = linkedSetOf<String>()
            var cursor: String? = null
            var completed = false
            for (pageIndex in 0 until MAX_TIER_C_INVENTORY_PAGES) {
                val result = AgentTierCRemoteInventory.inventory(endpoint, binding, provider, cursor)
                val inventory = (result as? AgentEndpointResult.Success)?.value
                if (inventory == null) {
                    val reason = when (result) {
                        is AgentEndpointResult.Failed -> result.code
                        is AgentEndpointResult.Unavailable -> "unavailable"
                        else -> "stale-binding"
                    }
                    diagnostics?.invoke("agent_tierc_inventory", mapOf("provider" to provider.providerID, "reason" to reason))
                    break
                }
                records += inventory.records
                if (!inventory.hasMore) {
                    completed = true
                    break
                }
                val next = inventory.cursor ?: break
                if (!seenCursors.add(next)) break
                cursor = next
            }
            if (!completed || endpoint.binding.value != binding || !enabled) continue
            tierCConformances.compute(binding.key) { _, current ->
                if (current?.binding == binding) current.copy(providers = current.providers + provider)
                else TierCEndpointConformance(binding, setOf(provider))
            }
            if (!reconfigureTierCConformances()) {
                diagnostics?.invoke("agent_tierc_inventory", mapOf("provider" to provider.providerID, "reason" to "conformance-rejected"))
                tierCConformances.computeIfPresent(binding.key) { _, current ->
                    current.copy(providers = current.providers - provider)
                }
                continue
            }
            records.forEach { record ->
                registerTierCInventoryRecord(endpoint, binding, record.provider.providerID, record.providerSessionID, record.transcriptRef)
            }
        }
    }

    private fun reconfigureTierCConformances(): Boolean {
        val conformances = tierCConformances.values.associate { it.binding to it.providers }
        return coordinator.registerTierCConformances(conformances)
    }

    private fun tierCConforms(
        endpointKey: AgentSessionKey,
        binding: AgentEndpointBinding,
        provider: AgentTierCProvider,
    ): Boolean {
        if (provider in setOf(AgentTierCProvider.Pi, AgentTierCProvider.OpenCode, AgentTierCProvider.Kimi)) return tierCConformances[endpointKey]?.let {
            it.binding.retainsAgentThreadOwners(binding) && provider in it.providers
        } == true && ingestionHosts.values.any {
            it.endpoint.key == endpointKey && it.admitted && it.connection?.let { connection ->
                !connection.isClosed && connection.supportsProvider(provider.providerID) } == true
        }
        return tierCConformances[endpointKey]?.let { it.binding == binding && provider in it.providers } == true
    }

    /** Tears down endpoints whose keys left the directory. */
    private fun retireEndpoints(keys: List<AgentSessionKey>) {
        // Every vanished tab's inventory stops first: each retired owner asks
        // a same-host tab for a pass, and one closing in the same update
        // dropped the ask with it.
        keys.forEach { key -> ingestionInventories.remove(key)?.cancel(); nativeInventoryRequests.remove(key) }
        for (key in keys) {
            occupancySweepJobs.remove(key)?.cancel()
            occupancySweepLocks.remove(key)
            ingestionHosts.filterKeys { it.session == key }.values.distinct().forEach(::discardNativeHost)
            ingestionScopes.keys.removeIf { it.session == key }
            endpointObservers.remove(key)?.cancel()
            tierACandidateJobs.remove(key)?.cancel()
            tierACandidateBindings.remove(key)?.let { old -> removeTierACandidates(key, old) }
            tierCInventoryJobs.remove(key)?.cancel()
            tierCInventoryBindings.remove(key)
            tierCConformances.remove(key)
            teardownEndpointOwners(key)
            bindingTokens.keys.filter { it.startsWith("${key.liveSessionID.canonicalAgentUUID()}\u001f") }.forEach(bindingTokens::remove)
            reconfigureTierCConformances()
        }
    }

    private fun teardownEndpointOwners(endpointKey: AgentSessionKey) {
        val (observed, routed) = threadOwners.entries.filter { it.value.endpointKey == endpointKey }
            .map { it.key to it.value }
            .partition { (key, owner) -> projectionSources[key]?.let { it.hostObservation && it.bindingToken == owner.bindingToken } == true }
        routed.forEach { (_, owner) ->
            // Core's retirement event names the token that actually left.
            forward(JSONObject().put("v", 1).put("kind", "unbind").put("threadID", JSONObject(owner.threadID))
                .put("bindingToken", owner.bindingToken))
        }
        retireObservations(observed)
    }

    /**
     * Drops catalog observations without unbinding each one. Core answered
     * every unbind with a thread and a list snapshot: thousands per reconnect
     * to a host with thousands of stored conversations, and a live pane's new
     * proof waited behind all of them, for a minute. An observation presents
     * no row, and the next inventory replaces its token in Core.
     */
    private fun retireObservations(observed: List<Pair<String, ThreadOwner>>) {
        val retired = observed.filter { (key, owner) -> threadOwners.remove(key, owner) }
        if (retired.isEmpty()) return
        val keys = retired.mapTo(hashSetOf()) { it.first }
        val tokens = retired.mapTo(hashSetOf()) { it.second.bindingToken }
        keys.forEach(::releaseOwnerWork)
        bindingTokens.entries.removeIf { it.value in tokens }
        retiredObservationTokens.addAll(tokens)
        refreshPaneAgentProviders()
        mutableState.value = mutableState.value.copy(loadingTranscriptThreads = mutableState.value.loadingTranscriptThreads - keys)
        retireRevokedOwners(keys)
        requestNativeInventory(retired)
    }

    /**
     * A pass lists no row another owner holds, and its last page waits for a
     * request. Once that owner leaves (a closed tab, a killed pane, an ended
     * conversation), only another pass lists what it held. Any tab's pass
     * lists the whole host: ask the owner's own tab, else one still open.
     * A pass already listing covers what it has yet to reach.
     */
    private fun requestNativeInventory(owners: Collection<Pair<String, ThreadOwner>>) {
        owners.groupBy { JSONObject(it.second.threadID).getString("hostID") }.forEach { (hostID, held) ->
            val requests = held.firstNotNullOfOrNull { (_, owner) -> nativeInventoryRequests[owner.endpointKey]?.takeIf { it.worked } }
                ?: hostLister(hostID) ?: return@forEach
            if (requests.running?.leave(held.map { it.first }) != true) requests.passes.trySend(Unit)
        }
    }

    /** The tab that lists a host: any one lists all of it, preferably one whose last pass worked. */
    private fun hostLister(hostID: String): NativeInventoryRequests? =
        nativeInventoryRequests.values.filter { it.endpoint.binding.value.hostID == hostID }
            .let { tabs -> tabs.firstOrNull { it.worked } ?: tabs.firstOrNull() }

    private suspend fun reconcilePreviousOwner(threadKey: String, incoming: AgentEndpointBinding, agentPID: Int?): Boolean {
        val owner = threadOwners[threadKey] ?: return true
        val held = owner.endpointBinding ?: return true
        val pid = JSONObject(owner.coreBindingJSON).optInt("agentPID", 0)
        if (pid <= 1 || held.copy(windowID = incoming.windowID).sameRouteAs(incoming) && pid == agentPID) return true
        val endpoint = coordinator.directory.resolve(owner.endpointKey) ?: return true
        val retired = CompletableDeferred<Unit>()
        occupancyRetirements[owner.bindingToken] = retired
        try {
            val observed = reconcileEndpointOccupancy(endpoint)
            if (threadOwners[threadKey]?.bindingToken != owner.bindingToken) return true
            // Core admits newer carriers directly; only this carrier can
            // establish whether a competing pane's process is still alive.
            if (held.key != incoming.key) return true
            val pane = observed?.panes?.firstOrNull { it.paneID == held.paneID }
            val provider = JSONObject(owner.threadID).getJSONObject("providerID").getString("rawValue")
            val absent = pane?.let { !it.exists || it.complete && it.processes.none { process ->
                process.pid == pid && process.provider.wireID == provider
            } } ?: (held.paneID != null && observed?.allPaneIDs?.let { held.paneID !in it } == true)
            if (!absent) return false
            withTimeoutOrNull(5_000) { retired.await() }
            return threadOwners[threadKey]?.bindingToken != owner.bindingToken
        } finally { occupancyRetirements.remove(owner.bindingToken, retired) }
    }

    /** Remove a revoked endpoint's local projection before Core's next list tick. */
    private fun retireRevokedOwners(threadKeys: Set<String>) {
        val previous = mutableState.value
        val rows = previous.threads.filterNot { it.key in threadKeys }
        val retained = resolveAgentHistoricalSelection(
            previousSelection = previous.selectedThreadKey,
            cachedDetailKeys = previous.projectedDetails.keys,
            visibleRowKeys = rows.map { it.key },
            ownedThreadKeys = threadOwners.keys.toSet(),
        )
        val projectedDetails = previous.projectedDetails.filterKeys(retained.retainedDetailKeys::contains)
        val selected = retained.selectedThreadKey
        mutableState.value = previous.copy(
            threads = rows,
            selectedThreadKey = selected,
            detail = previous.detail?.takeIf { it.row.key == selected }
                ?: selected?.let(projectedDetails::get),
            projectedDetails = projectedDetails,
            searchLanding = previous.searchLanding?.takeIf { it.threadKey == selected },
        )
    }

    private suspend fun registerTierCInventoryRecord(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        provider: String,
        providerSessionID: String,
        transcriptRef: String,
    ) {
        if (endpoint.binding.value != binding || provider !in TIER_C_PROVIDER_IDS) return
        val id = threadID(binding.hostID, provider, providerSessionID)
        val issuedResult = coordinator.issueRouteBinding(id, binding, claimedPID = null, providerID = provider)
        val issued = (issuedResult as? AgentEndpointResult.Success<*>)?.value as? AgentIssuedBinding ?: return
        val coreBinding = issued.coreBinding
        val bindingToken = issued.bindingToken
        val key = canonicalAgentThreadKey(binding.hostID, provider, providerSessionID)
        bindingTokens[coreBinding.tokenKey(key)] = bindingToken
        if (!installThreadOwner(key, endpoint, id, coreBinding.toString(), bindingToken, binding.hostDisplayLabel)) return
        projectionSources[key] = ProjectionSource(endpoint.key, binding, id.toString(), provider, transcriptRef, bindingToken)
        scheduleProjection(endpoint, binding, id, provider, transcriptRef, key, bindingToken)
    }

    internal suspend fun consumeLifecycle(endpoint: AgentSessionEndpoint, frame: AgentLifecycleFrame): Boolean {
        fun refuse(reason: String): Boolean {
            if (reason == "blank-session-id" || reason.startsWith("route-binding=failed(")) scheduleOccupancySweeps(endpoint)
            diagnostics?.invoke(
                "agent_lifecycle_refused",
                mapOf("detail" to "pane=${frame.binding.paneID ?: "raw"} reason=$reason"),
            )
            return false
        }
        val arrivalSequence = lifecycleArrivalSequence.incrementAndGet()
        val wire = runCatching { SharedAgentIntegrationParsing.lifecycleHookEvent(frame.payload) }.getOrNull()
            ?: return refuse("unparsable")
        val provider = wire.providerID.takeIf { it in setOf("claude", "codex", "kimi") }
            ?: return refuse("provider=${wire.providerID}")
        val providerSessionID = wire.providerSessionID?.takeIf(String::isNotBlank)
        if (providerSessionID == null) {
            if (provider != "codex" || wire.agentPID == null || wire.agentID != null) return refuse("blank-session-id")
            clearHeldConversations(endpoint, frame, wire, provider, successorSessionID = null)?.let { return refuse(it) }
            return false
        }
        // A conversation not held here may have written a transcript the
        // inventory has not listed. One held here is listed, live or not, and
        // its owner leaving asks again. Every hook of a working agent asking
        // walked and resent the whole host catalog every 10 s, so it asks at
        // its first hook and again when its first turn ends, when its
        // transcript exists.
        val unlisted = canonicalAgentThreadKey(frame.binding.hostID, provider, providerSessionID)
        if (projectionSources[unlisted] == null) nativeInventoryRequests[endpoint.key]?.let { requests ->
            if (requests.asked.size >= 1024) requests.asked.clear()
            val first = requests.asked.add(unlisted)
            val stop = wire.event in setOf("Stop", "StopFailure", "SessionEnd") && requests.asked.add("$unlisted:stop")
            if (first || stop) requests.passes.trySend(Unit)
        }
        if (provider == "kimi" && !tierCConforms(endpoint.key, frame.binding, AgentTierCProvider.Kimi)) {
            return refuse("kimi-not-conformant")
        }
        val transcriptRef = wire.transcriptRef?.takeIf(String::isNotBlank)
        val version = wire.version
        if (version >= 9 && transcriptRef == null) {
            // A different, newer root in the held process is a successor even
            // before its transcript can be located (/clear, /resume, /new): the
            // pane no longer hosts the held conversation, so do not leave it
            // actionable. Core spares any tenure that began at or after it.
            if (wire.agentPID != null && wire.agentID == null) {
                clearHeldConversations(endpoint, frame, wire, provider, successorSessionID = providerSessionID)
                    ?.takeIf { it != "no-replaced-root" }?.let(::refuse)
            }
            return refuse("v$version-no-transcript")
        }
        val event = wire.event
        val state = wire.status
        val agentPID = wire.agentPID
        val id = threadID(frame.binding.hostID, provider, providerSessionID)
        val key = canonicalAgentThreadKey(frame.binding.hostID, provider, providerSessionID)
        // Retiring the previous owner below may drop the source it read.
        val heldSource = projectionSources[key]
        if (!reconcilePreviousOwner(key, frame.binding, agentPID)) return refuse("bind_liveElsewhere")
        // The OSC PID is only a claim. Upgrade the binding only after the
        // endpoint independently relates that process to this exact raw PTY or
        // tmux pane; absence/failure remains truthful observe-only state.
        // Only the coordinator-owned route authority can turn endpoint proof
        // into Core authority. Lifecycle PID fields remain untrusted hints.
        val issuedResult = coordinator.issueRouteBinding(id, frame.binding, agentPID, provider)
        currentCoroutineContext().ensureActive()
        if (coordinator.directory.resolve(endpoint.key) !== endpoint) return refuse("replaced-endpoint")
        val issued = (issuedResult as? AgentEndpointResult.Success<*>)?.value as? AgentIssuedBinding
            // `Failed` has half a dozen distinct sources between the authority
            // and the endpoint's remote proof, so the class name alone says
            // nothing a device log can act on. Carry the code, and the claimed
            // PID that decided whether a proof was even attempted.
            ?: run {
                refuse("route-binding=${issuedResult.describeFailure()} pid=${agentPID ?: "none"} provider=$provider")
                return agentRouteRefreshFailureReason(issuedResult) in setOf(
                    AgentNotSentReason.INPUT_NOT_READY, AgentNotSentReason.INPUT_UNAVAILABLE,
                )
            }
        val retained = endpoint.retainedLifecycleFrame(frame.binding)
        if (!endpoint.isCurrentRoute(frame.binding) || (retained != null &&
                (!retained.binding.sameRouteAs(frame.binding) || !retained.payload.contentEquals(frame.payload)))) {
            return refuse("superseded-frame")
        }
        val binding = issued.coreBinding
        val bindingToken = issued.bindingToken
        bindingTokens[binding.tokenKey(key)] = bindingToken
        // As Core decides, from the frame alone: a Codex child agent reports
        // under its own thread beside its root; Claude reports its subagents
        // under the root's own session, which stays a root.
        if (!installThreadOwner(key, endpoint, id, binding.toString(), bindingToken, frame.binding.hostDisplayLabel,
                child = wire.agentID != null && provider == "codex")) return refuse("core-bind-refused")
        // The new owner reads the transcript this pane already named. A frame
        // that names none (an older integration), or that Core then refuses,
        // must not leave the source on the previous owner's token, where
        // search and the inventory would read it as another owner's, nor
        // leave none when Core retired that owner before this bind landed.
        val currentSource = projectionSources[key]
        val heldTranscript = (currentSource ?: heldSource)?.takeIf { !it.hostObservation &&
                (currentSource == null || it.endpointKey != endpoint.key || it.bindingToken != bindingToken) }
            ?.also { projectionSources[key] = it.copy(endpointKey = endpoint.key, binding = frame.binding, bindingToken = bindingToken) }
            ?.transcriptRef
        val lifecycle = JSONObject()
            .put("version", version)
            .put("providerID", providerID(provider))
            .put("event", event)
            .put("status", if (event == "Stop") "finished" else state)
            .put("providerSessionID", providerSessionID)
            .putOpt("transcriptRef", transcriptRef)
            .putOpt("agentID", wire.agentID)
            .putOpt("agentType", wire.agentType)
            .putOpt("rootAgentID", wire.rootAgentID)
            .putOpt("agentPID", agentPID)
            .putOpt("inputHint", wire.reason.takeIf { event in setOf("PreToolUse", "PostToolUse") &&
                it in setOf("question", "deferred-question") })
            // Core keeps it only beside a hint: the question call this boundary names.
            .putOpt("toolUseID", wire.toolUseID)
            .put("eventSequence", arrivalSequence)
            .put("sourceTimestampNanoseconds", wire.timestampNanoseconds)
        // `threadID` is not optional here. Core's `.lifecycle` rule requires it
        // and then cross-checks the envelope's providerID/providerSessionID
        // against it, so omitting it failed the whole command asynchronously as
        // `abi_missingField` long after `forward` had already returned true.
        val lifecycleSource = FirstReadLifecycleSource(key, binding.toString(), arrivalSequence,
            transcriptRef?.let { ProjectionSource(endpoint.key, frame.binding, id.toString(), provider, it, bindingToken) })
        if (firstReadLifecycleOrderReliable) {
            if (firstReadLifecycleSources.size < 256) firstReadLifecycleSources.add(lifecycleSource)
            else { firstReadLifecycleOrderReliable = false; firstReadLifecycleSources.clear() }
        }
        if (!forwardQuestionInput(key) {
                forward(JSONObject().put("v", 1).put("kind", "lifecycle").put("threadID", id)
                    .put("bindingToken", bindingToken).put("lifecycle", lifecycle))
            }
        ) {
            firstReadLifecycleSources.remove(lifecycleSource)
            return refuse("core-rejected")
        }
        latestPromptLifecycleSequence[key] = arrivalSequence
        latestPromptLifecycleNanos[key] = System.nanoTime()
        if (event !in setOf("SubagentStart", "SubagentStop")) {
            livePromptWatchJobs.remove(key)?.cancel()
            startLivePromptWatch(key, id, endpoint, frame.binding, provider, bindingToken)
        }
        diagnostics?.invoke(
            // Forwarded, not accepted: `forward` only proves the C ABI took
            // the bytes. Acceptance or refusal arrives later as an event, so
            // read this together with `agent_core_rejected`.
            "agent_lifecycle_forwarded",
            mapOf("detail" to "pane=${frame.binding.paneID ?: "raw"} provider=$provider event=$event"),
        )
        // Core reconciles the exact provider, terminal surface and process
        // evidence after accepting the lifecycle. An event from another pane
        // must not remove this endpoint's current fallback candidates.
        pendingLifecycleLaunches.remove("${endpoint.key.liveSessionID}:${frame.binding.paneID}")?.let { launch ->
            if (launch.providerID == provider) {
                scope.launch {
                    val now = System.currentTimeMillis()
                    metadata.rememberLineage(
                        threadKey = key,
                        parentThreadKey = launch.parentThreadKey,
                        parentRecordID = launch.parentRecordID,
                        now = now,
                    )
                    metadata.rememberLaunchReceipt(
                        threadKey = key,
                        requestID = launch.requestID,
                        parentThreadKey = launch.parentThreadKey,
                        parentRecordID = launch.parentRecordID,
                        windowID = launch.windowID,
                        paneID = launch.paneID,
                        worktreeCreated = launch.worktreeCreated,
                        now = now,
                    )
                }
                mutableState.value = mutableState.value.copy(notice = "Agent launched in ${frame.binding.paneID ?: "tmux"}")
            }
        }
        (transcriptRef ?: heldTranscript)?.let { located ->
            val source = ProjectionSource(endpoint.key, frame.binding, id.toString(), provider, located, bindingToken)
            val previousSource = projectionSources[key]
            if (previousSource != null && previousSource.transcriptRef != located) {
                cancelFirstProjectionRetry(key)
                clearNativeReadStatus(key)
            }
            projectionSources[key] = source
            scheduleProjection(endpoint, frame.binding, id, provider, located, key, bindingToken)
        }
        return false
    }

    /**
     * Ends the root conversations this frame's process held, fenced by the
     * frame's timestamp. [successorSessionID] null is Codex's blank root after
     * /clear; otherwise only a held root of another session is replaced.
     * Returns a refusal reason, or null once Core was asked to clear.
     */
    private suspend fun clearHeldConversations(
        endpoint: AgentSessionEndpoint,
        frame: AgentLifecycleFrame,
        wire: SharedAgentLifecycleHookEvent,
        provider: String,
        successorSessionID: String?,
    ): String? {
        val agentPID = wire.agentPID ?: return "no-agent-pid"
        val roots = threadOwners.values.filter { owner ->
            val id = JSONObject(owner.threadID)
            !owner.child && owner.endpointBinding?.sameRouteAs(frame.binding) == true &&
                JSONObject(owner.coreBindingJSON).optInt("agentPID") == agentPID &&
                id.getJSONObject("providerID").getString("rawValue") == provider
        }
        val sessionOf = { owner: ThreadOwner -> JSONObject(owner.threadID).optString("providerSessionID") }
        if (successorSessionID != null && roots.none { sessionOf(it) != successorSessionID }) return "no-replaced-root"
        val held = roots.firstOrNull { successorSessionID == null || sessionOf(it) != successorSessionID }
        val id = held?.threadID?.let(::JSONObject) ?: threadID(frame.binding.hostID, provider, "conversation-cleared")
        val result = coordinator.issueRouteBinding(id, frame.binding, agentPID, provider)
        currentCoroutineContext().ensureActive()
        val issued = (result as? AgentEndpointResult.Success)?.value
            ?: return "route-binding=${result.describeFailure()} pid=$agentPID provider=$provider"
        if (!issued.actionable || issued.coreBinding.optInt("agentPID") != agentPID) {
            return "route-binding=failed(unproved-process) pid=$agentPID provider=$provider"
        }
        if (coordinator.directory.resolve(endpoint.key) !== endpoint || !endpoint.isCurrentRoute(frame.binding)) {
            return "replaced-endpoint"
        }
        val retained = endpoint.retainedLifecycleFrame(frame.binding)
        if (retained != null && !retained.payload.contentEquals(frame.payload)) return "superseded-frame"
        forward(JSONObject().put("v", 1).put("kind", "conversationCleared").put("providerID", providerID(provider))
            .put("binding", issued.coreBinding).put("sourceTimestampNanoseconds", wire.timestampNanoseconds))
        // A blank observation creates no row; retire its temporary proof.
        if (held == null) forward(JSONObject().put("v", 1).put("kind", "unbind").put("threadID", id)
            .put("bindingToken", issued.bindingToken))
        diagnostics?.invoke(
            "agent_conversation_cleared",
            mapOf("detail" to "pane=${frame.binding.paneID ?: "raw"} provider=$provider successor=${if (successorSessionID == null) "blank" else "unlocatable"}"),
        )
        scheduleOccupancySweeps(endpoint)
        return null
    }

    private suspend fun installThreadOwner(
        threadKey: String,
        endpoint: AgentSessionEndpoint,
        threadID: JSONObject,
        coreBindingJSON: String,
        bindingToken: String,
        hostDisplayLabel: String,
        child: Boolean = false,
    ): Boolean = ownerBindingLocks.getOrPut(threadKey) { Mutex() }.withLock {
        val owner = ThreadOwner(endpoint.key, threadID.toString(), coreBindingJSON, bindingToken, child, endpoint)
        val pending = PendingOwner(owner, CompletableDeferred())
        pendingOwners[threadKey] = pending
        try {
            if (!forward(JSONObject().put("v", 1).put("kind", "bind").put("threadID", threadID).put("bindingToken", bindingToken)
                    .put("hostDisplayLabel", hostDisplayLabel.take(512))) ||
                withTimeoutOrNull(5_000) { pending.accepted.await() } != true) return@withLock false
            currentCoroutineContext().ensureActive()
        } finally { pendingOwners.remove(threadKey, pending) }
        retiredObservationTokens.remove(bindingToken)
        val previous = threadOwners.put(threadKey, owner)
        retiredOwnerThreads.remove(threadKey)
        refreshPaneAgentProviders()
        if (previous?.bindingToken != bindingToken) {
            previous?.let { cancelUnwrittenActions(threadKey, it.bindingToken) }
            cancelFirstProjectionRetry(threadKey)
            livePromptWatchJobs.remove(threadKey)?.cancel()
            cancelInitialPrefetch(threadKey)
            clearNativeReadStatus(threadKey)
            pendingProjectionRefreshes.remove(threadKey)
            pendingHistoryRequests.remove(threadKey)
            pendingFillRequests.remove(threadKey)
            pendingLatestRequests.remove(threadKey)
            pendingSeekRequests.remove(threadKey)
            projectionJobs.remove(threadKey)?.cancel()
            abandonSearchLanding(threadKey)
            mutableState.value = mutableState.value.copy(loadingTranscriptThreads = mutableState.value.loadingTranscriptThreads - threadKey)
        }
        true
    }

    private fun isDisplayingThread(key: String): Boolean = isAgentThreadDisplayed(
        key, mutableState.value, enabled, applicationForeground, ingestionOpenDetail,
    )

    private fun startDisplayedLivePromptWatch() {
        val current = mutableState.value
        val detail = current.detail ?: current.selectedThreadKey?.let(current.projectedDetails::get) ?: return
        if (isDisplayingThread(detail.row.key)) startLivePromptWatchFromSnapshot(detail)
    }

    private fun startLivePromptWatchFromSnapshot(detail: AgentThreadDetail) {
        if (!enabled || !applicationForeground || livePromptWatchJobs[detail.row.key]?.isActive == true) return
        val owner = threadOwners[detail.row.key] ?: return
        val exact = JSONObject().put("threadID", detail.row.threadIDJson())
            .put("binding", detail.binding?.toJson()).endpointBindingOrNull() ?: return
        val endpoint = coordinator.directory.resolve(exact.key) ?: return
        if (owner.endpointKey != endpoint.key || owner.canonicalBinding != detail.binding?.toJson()?.tokenKey()) return
        startLivePromptWatch(detail.row.key, detail.row.threadIDJson(), endpoint, exact, detail.row.providerID, owner.bindingToken)
    }

    private fun startLivePromptWatch(key: String, id: JSONObject, endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding, provider: String, bindingToken: String) {
        if (!enabled || !applicationForeground || livePromptWatchJobs[key]?.isActive == true) return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                watchAgentLivePrompt(id, bindingToken, provider,
                    current = {
                        if (!enabled || !applicationForeground || coordinator.directory.resolve(endpoint.key) !== endpoint ||
                            !endpoint.isCurrentRoute(binding) || threadOwners[key]?.bindingToken != bindingToken) null
                        else AgentLivePromptWatchSnapshot(
                            watch = mutableState.value.projectedDetails[key]?.row?.livePromptWatch == true,
                            displayed = isDisplayingThread(key),
                            lifecycleNanos = latestPromptLifecycleNanos[key],
                            lifecycleSequence = latestPromptLifecycleSequence[key],
                            deliveryGeneration = mutableState.value.projectedDetails[key]?.deliveryGeneration,
                        )
                    },
                    inspect = { (endpoint.inspect(binding) as? AgentEndpointResult.Success)?.value },
                    forward = { observation -> forwardQuestionScreen(key, observation) { forward(observation) } },
                )
            } finally {
                currentCoroutineContext()[Job]?.let { livePromptWatchJobs.remove(key, it) }
            }
        }
        livePromptWatchJobs[key] = job
        job.start()
    }

    private fun cancelUnwrittenActions(threadKey: String, bindingToken: String? = null) {
        actionJobs.values.filter { it.threadKey == threadKey && (bindingToken == null || it.bindingToken == bindingToken) &&
            !it.writes.mayHaveWritten }.forEach {
            it.routeChanged = true
            it.job.cancel()
        }
    }

    /** A retirement for an older proof cannot drop its newer owner. */
    private fun retireThreadOwner(threadKey: String, owner: ThreadOwner, successor: String?): Boolean {
        if (!threadOwners.remove(threadKey, owner)) return false
        refreshPaneAgentProviders()
        releaseOwnerWork(threadKey)
        // A token replaced for the same thread leaves it held, once the
        // successor binds. One that never does (a refused or superseded bind)
        // left the conversation unlisted until something else asked.
        if (successor != threadKey) requestNativeInventory(listOf(threadKey to owner))
        else scope.launch {
            delay(successorBindGraceMillis)
            if (threadOwners[threadKey] == null) requestNativeInventory(listOf(threadKey to owner))
        }
        val followed = mutableState.value.selectedThreadKey == threadKey
        mutableState.value = mutableState.value.copy(loadingTranscriptThreads = mutableState.value.loadingTranscriptThreads - threadKey)
        retireRevokedOwners(setOf(threadKey))
        if (followed && successor != null) select(successor)
        return true
    }

    /** Stops the work a retired owner was doing for its thread; publishes no list. */
    private fun releaseOwnerWork(threadKey: String) {
        if (sendAnywayCandidate?.threadKey == threadKey) invalidateSendAnyway()
        retiredOwnerThreads.add(threadKey)
        // The owner's last screen goes with it; its count stays, so an answer
        // still comparing it never sees a reset count match by chance.
        synchronized(questionInputLock) { questionScreens.remove(threadKey) }
        cancelFirstProjectionRetry(threadKey)
        cancelInitialPrefetch(threadKey)
        clearNativeReadStatus(threadKey)
        pendingTerminalReads.remove(threadKey)
        livePromptWatchJobs.remove(threadKey)?.cancel()
        latestPromptLifecycleSequence.remove(threadKey)
        latestPromptLifecycleNanos.remove(threadKey)
        pendingProjectionRefreshes.remove(threadKey)
        pendingHistoryRequests.remove(threadKey)
        pendingFillRequests.remove(threadKey)
        pendingLatestRequests.remove(threadKey)
        pendingSeekRequests.remove(threadKey)
        projectionJobs.remove(threadKey)?.cancel()
        abandonSearchLanding(threadKey)
        projectionSources.remove(threadKey)
    }

    private fun scheduleProjection(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        threadID: JSONObject,
        provider: String,
        transcriptRef: String,
        threadKey: String,
        bindingToken: String,
        cursor: String? = null,
        nativeDirection: String = "before",
        seek: AgentSearchResultRow? = null,
    ) {
        val refused = { seek?.let { abandonSearchLanding(threadKey, it.recordID) }; Unit }
        if (!enabled || !applicationForeground) return refused()
        if (cursor == null && nativeDirection != "bootstrap" &&
            (mutableState.value.ingestionReadStatuses[threadKey]?.recovery == "manual" || readRetryJobs.containsKey(threadKey))) return refused()
        val owner = threadOwners[threadKey]
        if (owner?.endpointKey != endpoint.key || owner.bindingToken != bindingToken) return refused()
        AgentTierCProvider.fromWire(provider)?.let { tierC ->
            if (!tierCConforms(endpoint.key, binding, tierC)) return refused()
        }
        if (coalesceProjectionIfRunning(threadKey, cursor, nativeDirection)) {
            seek?.let { pendingSeekRequests[threadKey] = it }
            return
        }
        lateinit var job: Job
        job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                project(endpoint, binding, threadID, provider, transcriptRef, threadKey, cursor = cursor,
                    bindingToken = bindingToken, nativeDirection = nativeDirection, seek = seek,
                    initialPagesRemaining = if (cursor == null && mutableState.value.projectedDetails[threadKey]?.cursor == null
                        && mutableState.value.projectedDetails[threadKey]?.live.isNullOrEmpty()) SharedAgentInitialLoadPolicy.initialPageCount - 1 else 0)
            } finally {
                if (projectionJobs.remove(threadKey, job)) {
                    mutableState.value = mutableState.value.copy(loadingTranscriptThreads = mutableState.value.loadingTranscriptThreads - threadKey)
                    val queuedSeek = pendingSeekRequests.remove(threadKey)
                    // A read that ended short of the match opens at the newest
                    // page, as does a queued match a cancelled read won't replay.
                    listOfNotNull(seek.takeIf { queuedSeek == null }, queuedSeek.takeIf { job.isCancelled })
                        .forEach { abandonSearchLanding(threadKey, it.recordID) }
                    if (queuedSeek != null && !job.isCancelled) requestSeek(queuedSeek, replayed = true)
                    // A match that needs no read leaves navigation queued
                    // after it (the newest page chosen over it) to run.
                    val idle = projectionJobs[threadKey]?.isActive != true && !pendingSeekRequests.containsKey(threadKey)
                    val latest = idle && threadKey in pendingLatestRequests
                    if (latest) {
                        pendingHistoryRequests.remove(threadKey)
                        pendingProjectionRefreshes.remove(threadKey)
                        // A thread left meanwhile reads it when chosen again.
                        if (mutableState.value.selectedThreadKey == threadKey) {
                            pendingLatestRequests.remove(threadKey)
                            loadNewer(threadKey, latest = true)
                        }
                    } else if (idle && pendingHistoryRequests.remove(threadKey)) loadMore(threadKey)
                    else if (idle && pendingProjectionRefreshes.remove(threadKey)) scheduleExistingProjection(threadKey)
                    else if (idle && pendingFillRequests.remove(threadKey)) fillHistory(threadKey)
                }
            }
        }
        projectionJobs[threadKey] = job
        if (nativeDirection == "bootstrap" || nativeDirection == "seek" || cursor != null ||
            mutableState.value.projectedDetails[threadKey]?.live.isNullOrEmpty()) {
            mutableState.value = mutableState.value.copy(loadingTranscriptThreads = mutableState.value.loadingTranscriptThreads + threadKey)
        }
        job.start()
    }

    /**
     * Where a read that opens the selected thread on a connection with no
     * window for it (the app came back, the connection dropped) opens a
     * reader who was in history: the page around the row their detail
     * starts at, landed there unmarked. A place kept from an interrupted read
     * comes first ([readerPlaces]); Core knows it only until the newest page
     * replaces its window, so it is asked only for a detail with a window
     * that named a row. A reader following the newest page, or one the
     * newest page or a match is already opening for, has none.
     */
    private suspend fun readerPlace(threadKey: String): AgentSearchResultRow? {
        fun open() = enabled && applicationForeground && ingestionOpenDetail == threadKey &&
            mutableState.value.selectedThreadKey == threadKey && mutableState.value.searchLanding?.threadKey != threadKey &&
            threadKey !in pendingLatestRequests && threadKey !in readerPlacesGivenUp
        if (!open()) return null
        val place = readerPlaces[threadKey] ?: run {
            if (mutableState.value.projectedDetails[threadKey]?.window == null || viewportAnchors[threadKey] == null) return null
            val thread = threadKey.threadIDJson() ?: return null
            val id = "place-${readerPlaceIDs.incrementAndGet()}"
            val reply = kotlinx.coroutines.CompletableDeferred<AgentSearchResultRow?>()
            readerPlaceChecks[id] = reply
            try {
                if (!forward(JSONObject().put("v", 1).put("kind", "readerPlace").put("threadID", thread).put("ingestionRequestID", id))) return null
                withTimeoutOrNull(READER_PLACE_TIMEOUT_MILLIS) { reply.await() }.also {
                    if (!reply.isCompleted) diagnostics?.invoke("agent_reader_place_timeout", mapOf("thread" to threadKey))
                }
            } finally { readerPlaceChecks.remove(id, reply) }
        } ?: return null
        currentCoroutineContext().ensureActive()
        if (place.threadKey != threadKey || place.sequence?.seekOrder() == null || !open()) return null
        readerPlaces[threadKey] = place
        val current = mutableState.value
        mutableState.value = current.copy(
            searchLanding = AgentSearchLanding(threadKey, place.recordID, searchLandingIDs.incrementAndGet(), marked = false),
            loadingTranscriptThreads = current.loadingTranscriptThreads + threadKey)
        return place
    }

    /** How a seek ended: its page applied for the reader still waiting on it, refused or left, or cut off with its connection. */
    private enum class SeekOutcome { LANDED, ENDED, INTERRUPTED }

    /**
     * Ends a held read (see [presentationHolds]) unless a later read holds the
     * thread now. A read cut off opening a reader's place keeps the place,
     * and the rows before, for the next read; any other end shows what it
     * applied and settles the place. A place that did not land leaves no
     * landing behind.
     */
    private fun settlePresentationHold(threadKey: String, hold: Any, place: AgentSearchResultRow?, outcome: SeekOutcome) {
        val kept = place != null && outcome == SeekOutcome.INTERRUPTED
        synchronized(presentationHoldLock) {
            if (presentationHolds[threadKey] !== hold) return
            presentationHolds.remove(threadKey)
            val detail = heldDetails.remove(threadKey)
            if (!kept && detail != null) mutableState.value = mutableState.value.withThreadSnapshot(detail)
        }
        if (place == null) return
        if (!kept) readerPlaces.remove(threadKey, place)
        if (outcome != SeekOutcome.LANDED) mutableState.value.searchLanding
            ?.takeIf { it.threadKey == threadKey && !it.marked && it.recordID == place.recordID }?.let(::finishSearchLanding)
    }

    /** Applies [change] to the detail a held thread's read waits to show. */
    private fun updateHeldDetail(threadKey: String, change: (AgentThreadDetail) -> AgentThreadDetail?) =
        synchronized(presentationHoldLock) { heldDetails[threadKey]?.let(change)?.let { heldDetails[threadKey] = it } }

    internal fun coalesceProjectionIfRunning(threadKey: String, cursor: String?, direction: String): Boolean {
        if (projectionJobs[threadKey]?.isActive != true) return false
        if (direction == "bootstrap") {
            pendingLatestRequests.add(threadKey)
            pendingHistoryRequests.remove(threadKey)
            pendingProjectionRefreshes.remove(threadKey)
        } else if (direction == "before") {
            if (cursor == null) pendingProjectionRefreshes.add(threadKey)
            else pendingHistoryRequests.add(threadKey)
        }
        return true
    }

    /**
     * Selecting a search-only historical thread may be the first time its
     * transcript needs projecting. Its source and authority were registered
     * earlier; selection merely asks that proven source for a current page.
     */
    private fun scheduleExistingProjection(threadKey: String) {
        val source = projectionSources[threadKey] ?: return
        val owner = threadOwners[threadKey] ?: return
        if (owner.endpointKey != source.endpointKey || owner.bindingToken != source.bindingToken) return
        val endpoint = coordinator.directory.resolve(source.endpointKey) ?: return
        if (!isProjectionSourceCurrent(endpoint, source)) return
        val threadID = runCatching { JSONObject(source.threadID) }.getOrNull() ?: return
        scheduleProjection(
            endpoint = endpoint,
            binding = source.binding,
            threadID = threadID,
            provider = source.provider,
            transcriptRef = source.transcriptRef,
            threadKey = threadKey,
            bindingToken = source.bindingToken,
        )
    }

    /** Called only by the composed detail surface. No new connection or
     * authority is created; the existing owner and exact route are rechecked. */
    fun refreshVisibleTranscript(threadKey: String) {
        if (!enabled || !applicationForeground || mutableState.value.selectedThreadKey != threadKey) return
        scheduleExistingProjection(threadKey)
    }

    private fun isProjectionSourceCurrent(endpoint: AgentSessionEndpoint, source: ProjectionSource): Boolean =
        if (source.hostObservation) endpoint.isCurrentIngestion(source.binding) else endpoint.isCurrentRoute(source.binding)

    private fun startNativeInventory(endpoint: AgentSessionEndpoint) {
        if (!enabled || !applicationForeground) return
        // A finished pass waits for a request, so a job left by an endpoint
        // re-registered under the same key would otherwise wait forever.
        if (ingestionInventories[endpoint.key]?.isActive == true && nativeInventoryRequests[endpoint.key]?.endpoint === endpoint) return
        ingestionInventories.remove(endpoint.key)?.cancel()
        val requests = NativeInventoryRequests(endpoint)
        nativeInventoryRequests[endpoint.key] = requests
        ingestionInventories[endpoint.key] = scope.launch {
            var retriedIncomplete = false
            while (enabled && applicationForeground && coordinator.directory.resolve(endpoint.key) === endpoint) {
                val started = System.nanoTime()
                var completed = false
                var refused = 0
                var unbound = 0
                // A request made before this pass lists is answered by it.
                requests.passes.tryReceive()
                val pass = InventoryPass().also { requests.running = it }
                try {
                    val (host, connection) = nativeConnection(endpoint)
                    var cursor: String? = null
                    val seen = hashSetOf<String>()
                    for (pageIndex in 0 until 164) {
                        val reply = connection.request(JSONObject().put("kind", "inventory").put("limit", 500).putOpt("cursor", cursor))
                        requireCurrentNativeConnection(host, connection)
                        val claims = reply.inventory.map { row ->
                            val provider = row.getString("provider")
                            require(connection.supportsProvider(provider))
                            val session = row.getString("sessionID")
                            val path = row.getString("transcriptRef")
                            require(path.startsWith("/") || (path.isEmpty() && provider in setOf("codex", "opencode") && row.optString("nativeSessionID") == session))
                            canonicalAgentThreadKey(connection.binding.hostID, provider, session) to row.getString("thread")
                        }
                        // Two rows for one thread (one rollout in two directories):
                        // keep the first rather than fail every pass for good.
                        val firstClaims = claims.distinctBy { it.first }
                        host.reserveHandles(firstClaims)
                        val claimed = firstClaims.toMap()
                        var ownersReplaced = false
                        for (row in reply.inventory) {
                            val provider = row.getString("provider")
                            require(connection.supportsProvider(provider))
                            val session = row.getString("sessionID")
                            val key = canonicalAgentThreadKey(connection.binding.hostID, provider, session)
                            if (claimed[key] != row.getString("thread")) continue
                            val handle = row.getString("thread")
                            claimNativeThread(key, host)
                            host.threads.putIfAbsent(key, NativeThread(handle))
                            val old = projectionSources[key]
                            // Canonical thread ownership spans host sessions.
                            // Keep any current owner, not just this endpoint's
                            // owner, so sibling inventories cannot churn its
                            // token or downgrade a proved live pane.
                            val oldEndpoint = old?.let { coordinator.directory.resolve(it.endpointKey) }
                            if (old != null && oldEndpoint != null && isProjectionSourceCurrent(oldEndpoint, old)) { pass.skip(key); continue }
                            val path = row.getString("transcriptRef")
                            require(path.startsWith("/") || (path.isEmpty() && provider in setOf("codex", "opencode") && row.optString("nativeSessionID") == session))
                            val locator = if (path.isEmpty()) "native:$session" else Base64.getUrlEncoder().withoutPadding().encodeToString(path.encodeToByteArray())
                            val id = threadID(connection.binding.hostID, provider, session)
                            val issuance = coordinator.issueIngestionBinding(id, endpoint.key)
                            currentCoroutineContext().ensureActive()
                            requireCurrentNativeConnection(host, connection)
                            // A live lifecycle event can prove a pane while issuing
                            // the observational binding suspends. The ABI refuses
                            // to revoke its live token; do not let that refusal
                            // abort discovery of the rest of this valid page.
                            if (projectionSources[key] !== old) { pass.skip(key); continue }
                            val issued = when (issuance) {
                                is AgentEndpointResult.Success -> issuance.value
                                // Core refuses to observe a thread a live pane holds,
                                // which already presents it. Refusing one row used to
                                // end the pass, so later rows were never listed and
                                // the whole pass repeated every 18 s.
                                is AgentEndpointResult.Failed ->
                                    if (issuance.code == "platform_binding_rejected") { refused++; pass.skip(key); continue }
                                    // Core refuses the row's identity itself (a session
                                    // ID no thread can carry): a retry gets the same
                                    // answer, so list the rest and finish.
                                    else { unbound++; continue }
                                else -> error("staleBinding")
                            }
                            require(!issued.actionable)
                            // Core hands back a token it still holds for an identical
                            // authority; its later retirement is a real one.
                            retiredObservationTokens.remove(issued.bindingToken)
                            bindingTokens[issued.coreBinding.tokenKey(key)] = issued.bindingToken
                            val owner = ThreadOwner(endpoint.key, id.toString(), issued.coreBinding.toString(), issued.bindingToken, endpoint = endpoint)
                            val previousOwner = threadOwners.put(key, owner)
                            if (previousOwner != null) ownersReplaced = true
                            if (previousOwner?.bindingToken != owner.bindingToken) {
                                previousOwner?.let { cancelUnwrittenActions(key, it.bindingToken) }
                                cancelFirstProjectionRetry(key)
                            }
                            retiredOwnerThreads.remove(key)
                            projectionSources[key] = ProjectionSource(endpoint.key, connection.binding, id.toString(), provider,
                                locator, issued.bindingToken, hostObservation = true)
                            check(forward(JSONObject().put("v", 1).put("kind", "bind").put("threadID", id)
                                .put("bindingToken", issued.bindingToken).put("hostDisplayLabel", connection.binding.hostDisplayLabel.take(512))
                                .put("inventoryModified", row.getLong("modified"))))
                        }
                        // An observation has no pane, so only a replaced owner
                        // can change the providers: once a page, not per row.
                        if (ownersReplaced) refreshPaneAgentProviders()
                        // One shared list projection per page, no transcript
                        // bootstrap and no selection side effect per row.
                        forward(JSONObject().put("v", 1).put("kind", "filter").put("grouping", mutableState.value.grouping))
                        scheduleNativeInterests()
                        if (!reply.end.getBoolean("hasMore")) {
                            requests.worked = true
                            // The host skipped a source still being written: one
                            // retry lists it once written. Only one: a source the
                            // host cannot read while its agent keeps writing ends
                            // every pass incomplete.
                            val incomplete = reply.end.optBoolean("incomplete")
                            completed = !incomplete || retriedIncomplete
                            retriedIncomplete = incomplete && !retriedIncomplete
                            if (!completed) diagnostics?.invoke("agent_native_inventory", mapOf("reason" to "incomplete"))
                            break
                        }
                        val next = reply.end.getString("cursor")
                        check(seen.add(next) && pageIndex < 163)
                        cursor = next
                    }
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    // Transport Deferred cancellation is a reconnectable failure;
                    // only cancellation of this inventory job ends discovery.
                    currentCoroutineContext().ensureActive()
                }
                catch (failure: Throwable) {
                    requests.worked = false
                    diagnostics?.invoke("agent_native_inventory", AgentIngestionDiagnostics.failure(failure) + mapOf("reason" to "inventory-failed"))
                }
                finally {
                    if (requests.running === pass) requests.running = null
                    // An owner left a thread this pass skipped: list it again.
                    if (pass.finish()) requests.passes.trySend(Unit)
                }
                if (refused > 0) diagnostics?.invoke("agent_native_inventory", mapOf("reason" to "live-threads-skipped", "count" to refused.toString()))
                if (unbound > 0) diagnostics?.invoke("agent_native_inventory", mapOf("reason" to "threads-unbound", "count" to unbound.toString()))
                // A complete pass is current until agent activity on this host
                // asks again (as on iOS); a failed one retries. Either way passes
                // start at most once per interval, since each one walks every
                // transcript on the host.
                if (completed) requests.passes.receive()
                delay((nativeInventoryIntervalMillis - (System.nanoTime() - started) / 1_000_000).coerceAtLeast(0))
            }
        }
    }

    private fun closeIngestionHosts() {
        initialPrefetchJobs.keys.toList().forEach(::cancelInitialPrefetch)
        readRetryJobs.values.forEach(Job::cancel); readRetryJobs.clear()
        readRetryRequests.clear()
        ingestionInterestJob?.cancel(); ingestionInterestJob = null
        ingestionInventories.values.forEach { it.cancel() }; ingestionInventories.clear()
        nativeInventoryRequests.clear()
        ingestionHosts.values.distinct().forEach { it.close() }; ingestionHosts.clear()
        ingestionCommits.values.forEach { it.cancel() }; ingestionCommits.clear()
        // Preparation belongs to the retired read, not the conversation.
        // Its closed connection cannot deliver completion; real failures
        // remain visible until their own recovery succeeds.
        mutableState.value = mutableState.value.copy(
            ingestionReadStatuses = mutableState.value.ingestionReadStatuses.filterValues { it.survivesReaderClosure },
        )
    }

    private fun isNativeHostCurrent(host: NativeHost): Boolean = ingestionHosts.values.any { it === host }

    internal fun requireCurrentNativeConnection(host: NativeHost, connection: AgentIngestionConnection) {
        check(enabled && applicationForeground) { "projectionInactive" }
        check(isNativeHostCurrent(host) && host.connection === connection && !connection.isClosed) { "staleEpoch" }
        check(host.endpoint.isCurrentIngestion(connection.binding)) { "staleBinding" }
    }

    internal fun claimNativeThread(key: String, host: NativeHost) = synchronized(ingestionPoolLock) {
        check(ingestionHosts.values.none {
            it !== host && it.connection?.isClosed == false && it.claimedThreads.contains(key) &&
                it.connection?.epoch != host.connection?.epoch
        }) { "contextIdentityConflict" }
        host.claimedThreads.add(key)
    }

    private fun discardNativeHost(host: NativeHost) {
        host.threads.keys.forEach(::cancelInitialPrefetch)
        synchronized(ingestionPoolLock) { ingestionHosts.entries.removeIf { it.value === host } }
        host.close()
        val retained = ingestionHosts.values.filter { it.connection?.isClosed == false }
            .flatMap { it.threads.keys }.toSet()
        val retired = host.threads.keys - retained
        mutableState.value = mutableState.value.copy(
            ingestionReadStatuses = mutableState.value.ingestionReadStatuses.filter { (key, status) ->
                key !in retired || status.survivesReaderClosure
            },
        )
    }

    private fun nativeAliasesFor(session: AgentSessionKey): Set<NativeHostKey> =
        (ingestionHosts.keys.asSequence() + ingestionScopes.keys.asSequence())
            .filter { it.session == session }.toSet()

    /** PID/incarnation aliases outlive their stream so historical transcripts
     * can reopen after the process exits. Reclaim only unreferenced aliases,
     * and only under pressure; hiding or backgrounding a thread is not expiry. */
    private fun pruneNativeAliases(requested: NativeHostKey) {
        val session = requested.session
        val aliases = nativeAliasesFor(session)
        if (aliases.size < 128 && ingestionHosts.filterKeys { it.session == session }.values.distinct().size < 8) return
        val retained = mutableSetOf(requested, NativeHostKey(session))
        for (owner in threadOwners.values) {
            if (owner.endpointKey != session) continue
            val context = runCatching { JSONObject(owner.coreBindingJSON) }.getOrNull() ?: continue
            val pid = (context.opt("agentPID") as? Number)?.toLong()?.takeIf { it in 2..Int.MAX_VALUE } ?: continue
            val incarnation = context.optJSONObject("incarnation")?.optString("rawValue") ?: ""
            retained.add(NativeHostKey(session, "$pid:$incarnation"))
        }
        for (alias in aliases) {
            val host = ingestionHosts[alias]
            if (alias in retained || host?.openingWaiters?.let { it > 0 } == true) continue
            ingestionScopes.remove(alias)
            if (host != null && ingestionHosts.remove(alias, host) && !isNativeHostCurrent(host)) host.close()
        }
    }

    internal suspend fun nativeConnection(endpoint: AgentSessionEndpoint, contextPID: Int? = null,
                                         incarnation: String = ""): Pair<NativeHost, AgentIngestionConnection> {
        check(enabled && applicationForeground)
        val poolKey = NativeHostKey(endpoint.key, contextPID?.let { "$it:$incarnation" } ?: "default")
        fun acquire(): NativeHost = synchronized(ingestionPoolLock) {
            ingestionHosts.values.distinct().filter { it.connection?.isClosed == true || it.opening.isCancelled }
                .forEach(::discardNativeHost)
            ingestionHosts[poolKey] ?: run {
                pruneNativeAliases(poolKey)
                check(ingestionScopes.containsKey(poolKey) || nativeAliasesFor(endpoint.key).size < 128) { "context capacity" }
                check(ingestionHosts.keys.count { it.session == endpoint.key } < 128 &&
                    ingestionHosts.filterKeys { it.session == endpoint.key }.values.distinct().size < 8) { "context capacity" }
                NativeHost(endpoint, scope, contextPID, ingestionScopes[poolKey], diagnostics).also { ingestionHosts[poolKey] = it }
            }
        }
        var host = acquire()
        val previous = host.connection
        if (host.endpoint !== endpoint || previous?.let { it.isClosed || !endpoint.isCurrentIngestion(it.binding) } == true) {
            discardNativeHost(host)
            host = acquire()
        }
        val borrowed = host
        synchronized(ingestionPoolLock) { borrowed.openingWaiters++ }
        try {
        var connection = try { host.opening.await() } catch (failure: Throwable) {
            if ((host.opening.isCancelled || failure !is kotlinx.coroutines.CancellationException) &&
                isNativeHostCurrent(host)) discardNativeHost(host)
            throw failure
        }
        currentCoroutineContext().ensureActive()
        synchronized(ingestionPoolLock) {
            val winner = ingestionHosts[poolKey]
            val winnerConnection = winner?.connection
            if (winner != null && winner !== host && winner.endpoint === endpoint &&
                winnerConnection != null && winnerConnection.epoch == connection.epoch) {
                host = winner; connection = winnerConnection
            }
            if (ingestionHosts[poolKey] !== host || connection.isClosed || !endpoint.isCurrentIngestion(connection.binding)) {
                if (!host.admitted && isNativeHostCurrent(host)) discardNativeHost(host)
                error("stale ingestion binding")
            }
            val shared = if (host.admitted) null else ingestionHosts.filterKeys { it.session == endpoint.key }.values.firstOrNull {
                it !== host && it.admitted && it.endpoint === endpoint && it.connection?.let { existing ->
                    !existing.isClosed && existing.epoch == connection.epoch } == true
            }
            if (shared != null) {
                val redundant = host
                ingestionHosts[poolKey] = shared; host = shared; connection = checkNotNull(shared.connection)
                redundant.close()
            }
            host.admitted = true
            if (contextPID != null) connection.contextScope?.let { ingestionScopes[poolKey] = it }
        }
        connection.onPage = { handle, reply ->
            val key = host.threads.entries.firstOrNull { it.value.handle == handle }?.key
            val source = key?.let(projectionSources::get)
            if (key == null || source == null || source.endpointKey != endpoint.key || !isProjectionSourceCurrent(endpoint, source)) false
            else {
                val owner = threadOwners[key]
                val committed = owner?.takeIf { it.endpointKey == endpoint.key }?.let {
                    commitNative(host, connection, handle, reply, JSONObject(source.threadID), it.bindingToken)
                }
                if (committed?.accepted == true && reply.end.getString("kind") == "page.end") {
                    host.threads[key]?.liveCursor = reply.end.getString("liveCursor")
                }
                committed?.accepted == true
            }
        }
        connection.onResync = resync@ { handle ->
            if (runCatching { requireCurrentNativeConnection(host, connection) }.isFailure) return@resync
            host.threads.entries.firstOrNull { it.value.handle == handle }?.let { (key, thread) ->
                cancelInitialPrefetch(key)
                thread.liveCursor = null; thread.window = null; thread.fast = null
                thread.initialPrefetchStarted = false
                if (mutableState.value.selectedThreadKey == key) scheduleExistingProjection(key)
                // The service removes a failed watch. Visible cards also need
                // their slow subscription restored, even when no detail is
                // selected and no lifecycle event follows the failure.
                scheduleNativeInterests()
            }
        }
        connection.onCapacity = capacity@ { handle ->
            if (runCatching { requireCurrentNativeConnection(host, connection) }.isFailure) return@capacity
            host.threads.entries.firstOrNull { it.value.handle == handle }?.let { (key, thread) ->
                cancelInitialPrefetch(key)
                thread.paused = true; thread.fast = null
                mutableState.value = mutableState.value.copy(ingestionCapacityThreads = mutableState.value.ingestionCapacityThreads + key)
                scheduleNativeInterests()
            }
        }
        connection.onReadStatus = status@ { handle, status ->
            if (runCatching { requireCurrentNativeConnection(host, connection) }.isFailure) return@status
            val key = host.threads.entries.firstOrNull { it.value.handle == handle }?.key ?: return@status
            if (mutableState.value.ingestionReadStatuses[key] != status) diagnostics?.invoke("agent_ingestion_read_status", mapOf(
                "state" to status.state, "domain" to status.domain, "recovery" to status.recovery, "code" to status.code,
            ))
            mutableState.value = mutableState.value.copy(ingestionReadStatuses = mutableState.value.ingestionReadStatuses + (key to status))
            if (!status.isProgress) {
                cancelInitialPrefetch(key)
                if (status.recovery == "manual") {
                    readRetryJobs.remove(key)?.cancel()
                    host.threads[key]?.paused = true
                    scheduleNativeInterests()
                } else if (status.recovery in setOf("retryRead", "renewConnection")) {
                    scheduleNativeReadRetry(key, host, connection, status)
                }
            }
        }
        connection.onReadComplete = complete@ { handle ->
            if (runCatching { requireCurrentNativeConnection(host, connection) }.isFailure) return@complete
            val key = host.threads.entries.firstOrNull { it.value.handle == handle }?.key ?: return@complete
            // The connection has matched request/thread/epoch ownership. A
            // successful unchanged read ends preparation, but cannot erase a
            // later terminal failure or reset an unrelated retry budget.
            if (mutableState.value.ingestionReadStatuses[key]?.isProgress == true) {
                mutableState.value = mutableState.value.copy(ingestionReadStatuses = mutableState.value.ingestionReadStatuses - key)
            }
        }
        connection.onWindowPage = { handle, reply ->
            val key = host.threads.entries.firstOrNull { it.value.handle == handle }?.key
            val source = key?.let(projectionSources::get)
            if (key == null || source == null || source.endpointKey != endpoint.key || !isProjectionSourceCurrent(endpoint, source)) null
            else {
                val owner = threadOwners[key]
                val committed = owner?.takeIf { it.endpointKey == endpoint.key }?.let {
                    commitNative(host, connection, handle, reply, JSONObject(source.threadID), it.bindingToken)
                }
                if (committed?.accepted == true) committed.window?.also {
                    host.threads[key]?.window = it
                    host.threads[key]?.liveCursor = it.optString("liveCursor").takeIf(String::isNotEmpty)
                }?.let { AgentIngestionConnection.WindowCommit(it, true) }
                else if (committed?.code == "capacityExceeded") host.threads[key]?.window?.let { AgentIngestionConnection.WindowCommit(it, false) }
                else null
            }
        }
        for (nativeProvider in listOf(AgentTierCProvider.Pi, AgentTierCProvider.OpenCode, AgentTierCProvider.Kimi).filter { connection.supportsProvider(it.providerID) }) {
            val selectedBinding = endpoint.binding.value
            var changed = false
            tierCConformances.compute(endpoint.key) { _, current ->
                if (current?.binding == selectedBinding && nativeProvider in current.providers) current
                else {
                    changed = true
                    TierCEndpointConformance(selectedBinding,
                        (if (current?.binding == selectedBinding) current.providers else emptySet()) + nativeProvider)
                }
            }
            if (changed && !reconfigureTierCConformances()) {
                tierCConformances.computeIfPresent(endpoint.key) { _, current ->
                    if (current.binding == selectedBinding) current.copy(providers = current.providers - nativeProvider)
                    else current
                }
                error("native provider conformance rejected")
            }
        }
        return host to connection
        } finally {
            synchronized(ingestionPoolLock) {
                borrowed.openingWaiters--
                if (borrowed.openingWaiters == 0 && !borrowed.admitted && isNativeHostCurrent(borrowed)) discardNativeHost(borrowed)
            }
        }
    }

    private suspend fun commitNative(host: NativeHost, connection: AgentIngestionConnection, handle: String, reply: AgentIngestionConnection.Reply,
                                     threadID: JSONObject, token: String, movesPrompt: Boolean = true): NativeCommit {
        // A successful request may resume after reader EOF, a foreground
        // boundary, or pool replacement. Core deliberately accepts a fresh
        // bootstrap epoch, so only this adapter can reject the retired owner.
        currentCoroutineContext().ensureActive()
        requireCurrentNativeConnection(host, connection)
        val id = reply.end.getString("id")
        // Base64 and JSON escaping of up to a MiB of page bytes is pure work;
        // do it off Main, then re-fence the owner before anything is shared.
        val epoch = connection.epoch
        val command = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            JSONObject().put("v", 1).put("kind", "projection").put("threadID", threadID).put("bindingToken", token)
                .put("ingestionEpoch", epoch).put("ingestionThread", handle)
                .put("ingestionRequestID", id)
                .put(when (reply.end.getString("kind")) {
                    "summary" -> "ingestionSummaryWire"
                    "hookPreview" -> "ingestionHookWire"
                    else -> "ingestionWire"
                },
                    java.util.Base64.getEncoder().encodeToString(checkNotNull(reply.wire)))
                .toString().toByteArray(StandardCharsets.UTF_8)
        }
        currentCoroutineContext().ensureActive()
        requireCurrentNativeConnection(host, connection)
        val deferred = CompletableDeferred<NativeCommit>()
        check(ingestionCommits.size < 16 && ingestionCommits.putIfAbsent(id, deferred) == null)
        try {
            val forwarded = forwardQuestionInput(
                agentLeaseThreadKey(JSONObject().put("threadID", threadID)).takeIf { movesPrompt }) { forwardEncoded(command) }
            val committed = if (!forwarded) NativeCommit(false, code = "commitNotForwarded")
                else withTimeoutOrNull(15_000) { deferred.await() } ?: NativeCommit(false, code = "commitTimeout")
            currentCoroutineContext().ensureActive()
            requireCurrentNativeConnection(host, connection)
            diagnostics?.invoke("agent_ingestion_commit", mapOf("request" to id,
                "accepted" to committed.accepted.toString(), "code" to AgentIngestionDiagnostics.code(committed.code),
                "wireBytes" to (reply.wire?.size ?: 0).toString(), "window" to (committed.window != null).toString()))
            if (committed.accepted && reply.end.optString("kind") == "page.end") {
                host.threads.entries.firstOrNull { it.value.handle == handle }?.key?.let(::clearNativeReadStatus)
            }
            return committed
        } finally { ingestionCommits.remove(id, deferred); deferred.cancel() }
    }

    fun setCardVisible(key: String, visible: Boolean) {
        if (visible) ingestionVisibleCards.add(key) else ingestionVisibleCards.remove(key)
        if (!visible && ingestionOpenDetail != key) readRetryJobs.remove(key)?.cancel()
        scheduleNativeInterests()
    }

    fun setOpenDetail(key: String?) {
        initialPrefetchJobs.keys.filter { it != key }.forEach(::cancelInitialPrefetch)
        ingestionOpenDetail = key
        startDisplayedLivePromptWatch()
        scheduleNativeInterests()
        key?.let(::scheduleExistingProjection)
    }

    private fun cancelInitialPrefetch(key: String) { initialPrefetchJobs.remove(key)?.cancel() }

    private fun clearNativeReadStatus(key: String) {
        readRetryJobs.remove(key)?.cancel()
        readRetryFailures.remove(key); readRetryRequests.remove(key)
        firstReadFailureLifecycleSequences.remove(key)
        if (mutableState.value.ingestionReadStatuses.containsKey(key)) {
            mutableState.value = mutableState.value.copy(ingestionReadStatuses = mutableState.value.ingestionReadStatuses - key)
        }
    }

    // Core emits lifecycle acceptance/rejection in command order. Keep the
    // source alongside each forwarded frame, including frames without a ref;
    // a snapshot alone contains neither the ref nor a neutral child's sequence.
    private data class FirstReadLifecycleSource(val key: String, val coreBindingJSON: String, val sequence: Long,
        val source: ProjectionSource?)
    private val firstReadLifecycleSources = java.util.concurrent.ConcurrentLinkedQueue<FirstReadLifecycleSource>()
    private var firstReadLifecycleOrderReliable = true
    /** The newest forwarded lifecycle sequence when the first read failed. */
    private val firstReadFailureLifecycleSequences = ConcurrentHashMap<String, Long>()

    /** Core accepted this source; a forwarded or rejected hook cannot renew the budget. */
    private fun restartMissingFirstRead(detail: AgentThreadDetail, accepted: FirstReadLifecycleSource) {
        val key = detail.row.key
        if (!firstReadLifecycleOrderReliable || accepted.key != key) return
        // Only a frame forwarded after the failure is evidence of progress.
        if (accepted.sequence <= (firstReadFailureLifecycleSequences[key] ?: return)) return
        if (mutableState.value.ingestionReadStatuses[key]?.code != "sourceMissing" ||
            detail.window != null || detail.hasTranscriptMessages ||
            (detail.binding?.number("agentPID")?.toIntOrNull() ?: -1) <= 1) return
        val source = projectionSources[key] ?: return
        if (accepted.source != source || detail.binding?.toJson()?.sameCoreBinding(JSONObject(accepted.coreBindingJSON)) != true) return
        val owner = threadOwners[key] ?: return
        val endpoint = coordinator.directory.resolve(source.endpointKey) ?: return
        if (owner.bindingToken != source.bindingToken ||
            !detail.binding.toJson().sameCoreBinding(JSONObject(owner.coreBindingJSON)) ||
            !isProjectionSourceCurrent(endpoint, source)) return
        cancelFirstProjectionRetry(key)
        clearNativeReadStatus(key)
        scheduleProjection(endpoint, source.binding, JSONObject(source.threadID), source.provider,
            source.transcriptRef, key, source.bindingToken)
    }

    private fun cancelFirstProjectionRetry(key: String) {
        firstProjectionRetryJobs.remove(key)?.cancel()
        firstProjectionRetryTokens.remove(key)
    }

    /** A just-started CLI can publish its identity before creating its file. */
    private fun scheduleFirstProjectionRetry(key: String, token: String) {
        if (firstProjectionRetryTokens.putIfAbsent(key, token) != null) return
        lateinit var retry: Job
        retry = scope.launch(start = CoroutineStart.LAZY) {
            fun current() = enabled && threadOwners[key]?.bindingToken == token && firstProjectionRetryJobs[key] === retry
            try {
                for (pause in listOf(500L, 1_000L, 2_000L, 4_000L, 8_000L)) {
                    delay(pause)
                    while (current() && !applicationForeground) delay(500)
                    if (!current()) return@launch
                    projectionJobs[key]?.join()
                    if (!current() || mutableState.value.ingestionReadStatuses[key]?.code != "sourceMissing") return@launch
                    val source = projectionSources[key]?.takeIf { it.bindingToken == token } ?: return@launch
                    val endpoint = coordinator.directory.resolve(source.endpointKey) ?: return@launch
                    if (!isProjectionSourceCurrent(endpoint, source)) return@launch
                    try {
                        projectNative(endpoint, source.binding, JSONObject(source.threadID), source.provider, source.transcriptRef,
                            key, token, cursor = null)
                        return@launch
                    } catch (failure: CancellationException) {
                        if (!currentCoroutineContext().isActive || applicationForeground) throw failure
                    } catch (failure: Throwable) {
                        if (((failure as? AgentIngestionReadFailure)?.status?.code ?: failure.message) != "sourceMissing") return@launch
                    }
                }
            } finally { firstProjectionRetryJobs.remove(key, retry) }
        }
        firstProjectionRetryJobs[key] = retry
        retry.start()
    }

    private fun scheduleNativeReadRetry(key: String, host: NativeHost, connection: AgentIngestionConnection, status: SharedAgentReadStatus) {
        if (readRetryJobs.containsKey(key) || (key != ingestionOpenDetail && key !in ingestionVisibleCards)) return
        val failures = readRetryFailures.compute(key) { _, count -> ((count ?: 0) + 1).coerceAtMost(30) } ?: 1
        lateinit var retry: Job
        retry = scope.launch(start = CoroutineStart.LAZY) {
            try {
                delay(SharedAgentInitialLoadPolicy.readRetryDelayMilliseconds(failures))
                check(enabled && applicationForeground && isNativeHostCurrent(host) && host.connection === connection &&
                    host.endpoint.isCurrentIngestion(connection.binding)) { "staleEpoch" }
                if (readRetryJobs[key] !== retry || (key != ingestionOpenDetail && key !in ingestionVisibleCards) ||
                    mutableState.value.ingestionReadStatuses[key] != status) return@launch
                readRetryJobs.remove(key, retry)
                val requested = readRetryRequests.remove(key)
                if (status.recovery == "renewConnection" || connection.isClosed) {
                    discardNativeHost(host)
                    ingestionInventories.remove(host.endpoint.key)?.cancel()
                    startNativeInventory(host.endpoint)
                }
                if (key == mutableState.value.selectedThreadKey) {
                    val source = projectionSources[key] ?: return@launch
                    val endpoint = coordinator.directory.resolve(source.endpointKey) ?: return@launch
                    scheduleProjection(endpoint, source.binding, JSONObject(source.threadID), source.provider,
                        source.transcriptRef, key, source.bindingToken, requested?.first,
                        nativeDirection = requested?.second ?: "before")
                }
                scheduleNativeInterests()
            } catch (failure: CancellationException) { throw failure }
            catch (_: Throwable) { /* A retired route owns its foreground recovery. */ }
            finally { readRetryJobs.remove(key, retry) }
        }
        readRetryJobs[key] = retry
        retry.start()
    }

    private fun scheduleInitialPrefetch(host: NativeHost, connection: AgentIngestionConnection,
                                        selected: NativeThread, key: String) {
        if (selected.initialPrefetchStarted || mutableState.value.selectedThreadKey != key || ingestionOpenDetail != key ||
            pendingActions.containsKey(key) || key in mutableState.value.ingestionCapacityThreads || selected.window == null) return
        selected.initialPrefetchStarted = true
        lateinit var job: Job
        job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                // The first page's foreground task owns publication/ACK. This
                // dependency points only from optional work to required work.
                projectionJobs[key]?.join()
                var completed = 1
                while (true) {
                    kotlinx.coroutines.yield()
                    currentCoroutineContext().ensureActive()
                    requireCurrentNativeConnection(host, connection)
                    val window = selected.window ?: return@launch
                    val current = mutableState.value.selectedThreadKey == key && ingestionOpenDetail == key &&
                        initialPrefetchJobs[key] === job
                    val priority = pendingActions.containsKey(key) || key in pendingHistoryRequests || key in pendingLatestRequests ||
                        key in mutableState.value.ingestionCapacityThreads
                    if (!SharedAgentInitialLoadPolicy.shouldPrefetch(completed, window.optBoolean("hasOlder"), current, priority)) return@launch
                    val source = projectionSources[key] ?: return@launch
                    val endpoint = coordinator.directory.resolve(source.endpointKey) ?: return@launch
                    projectNative(endpoint, source.binding, JSONObject(source.threadID), source.provider, source.transcriptRef,
                        key, source.bindingToken, window.getString("before"),
                        prefetchConnection = connection)
                    completed++
                }
            } catch (failure: CancellationException) { throw failure }
            catch (failure: Throwable) {
                diagnostics?.invoke("agent_ingestion_prefetch_failed", AgentIngestionDiagnostics.failure(failure))
            } finally {
                if (initialPrefetchJobs.remove(key, job) && pendingFillRequests.remove(key)) fillHistory(key)
            }
        }
        initialPrefetchJobs[key] = job
        job.start()
    }

    private fun scheduleNativeInterests() {
        ingestionInterestRevision++
        if (ingestionInterestJob?.isActive == true || !enabled || !applicationForeground) return
        ingestionInterestJob = scope.launch {
            do {
                val revision = ingestionInterestRevision
                delay(50)
                for (host in ingestionHosts.values.distinct()) {
                    try { updateNativeInterests(host, host.opening.await()) }
                    catch (cancelled: kotlinx.coroutines.CancellationException) { currentCoroutineContext().ensureActive() }
                    catch (failure: Throwable) {
                        diagnostics?.invoke("agent_ingestion_interest_failed", AgentIngestionDiagnostics.failure(failure))
                    }
                }
            } while (revision != ingestionInterestRevision && enabled && applicationForeground)
        }
    }

    private suspend fun updateNativeInterests(host: NativeHost, connection: AgentIngestionConnection) = host.interests.withLock {
        requireCurrentNativeConnection(host, connection)
        val revision = ingestionInterestRevision
        fun stillCurrent(): Boolean {
            requireCurrentNativeConnection(host, connection)
            return revision == ingestionInterestRevision
        }
        val desired = host.threads.entries.filter { !it.value.paused && it.key !in mutableState.value.ingestionCapacityThreads &&
            mutableState.value.ingestionReadStatuses[it.key]?.recovery != "manual" && !readRetryJobs.containsKey(it.key) &&
            (it.key == ingestionOpenDetail || it.key in ingestionVisibleCards) }
            .sortedWith(compareByDescending<Map.Entry<String, NativeThread>> { it.key == ingestionOpenDetail }.thenBy { it.key })
            .take(64).mapTo(hashSetOf()) { it.key }
        for ((key, thread) in host.threads) {
            // Typed retryable resyncs retire a watch without invalidating the
            // retained window. Explicit request rejection does not; reconcile
            // only the connection's acknowledged subscription fact.
            if (thread.fast != null && !connection.isSubscribed(thread.handle)) thread.fast = null
            if (thread.coreEvicted && !thread.paused) {
                connection.request(JSONObject().put("kind", "unsubscribe").put("thread", thread.handle))
                requireCurrentNativeConnection(host, connection)
                thread.fast = null
                if (!stillCurrent()) return@withLock
                connection.request(JSONObject().put("kind", "window.release").put("thread", thread.handle))
                requireCurrentNativeConnection(host, connection)
                thread.window = null; thread.liveCursor = null
                if (!stillCurrent()) return@withLock
                thread.coreEvicted = false
                if (key == ingestionOpenDetail) scheduleExistingProjection(key)
            }
            if (thread.window != null && key != ingestionOpenDetail && (!thread.paused || key in mutableState.value.ingestionCapacityThreads) &&
                mutableState.value.projectedDetails[key]?.window?.retainsOutgoing != true) {
                connection.request(JSONObject().put("kind", "unsubscribe").put("thread", thread.handle))
                requireCurrentNativeConnection(host, connection)
                thread.fast = null
                if (!stillCurrent()) return@withLock
                connection.request(JSONObject().put("kind", "window.release").put("thread", thread.handle))
                requireCurrentNativeConnection(host, connection)
                // A confirmed release invalidates the old remote window even
                // if visibility changed while its acknowledgement was in flight.
                thread.window = null; thread.liveCursor = null
                key.threadIDJson()?.let { forward(JSONObject().put("v", 1).put("kind", "releaseIngestionWindow").put("threadID", it)) }
                if (!stillCurrent()) return@withLock
                val resumed = thread.paused || key in mutableState.value.ingestionCapacityThreads
                thread.paused = false
                mutableState.value = mutableState.value.copy(ingestionCapacityThreads = mutableState.value.ingestionCapacityThreads - key)
                if (resumed) {
                    // Desired was captured while this card was paused. Rebuild
                    // it now that releasing the old window freed its capacity.
                    scheduleNativeInterests()
                    return@withLock
                }
            }
            if (key !in desired) {
                if (thread.fast != null) {
                    connection.request(JSONObject().put("kind", "unsubscribe").put("thread", thread.handle))
                    requireCurrentNativeConnection(host, connection)
                    thread.fast = null
                    if (!stillCurrent()) return@withLock
                }
                continue
            }
            val fast = key == ingestionOpenDetail && thread.liveCursor != null
            if (thread.fast == fast) continue
            thread.fast = null
            connection.request(JSONObject().put("kind", "subscribe").put("thread", thread.handle)
                .putOpt("liveCursor", if (fast) thread.liveCursor else null)
                .putOpt("windowVersion", if (fast) thread.window?.getLong("version") else null)
                .put("interest", if (fast) "fast" else "slow"))
            requireCurrentNativeConnection(host, connection)
            // An ACK can arrive after either a resync or a visibility change.
            // Track its remote watch until compensation succeeds; otherwise a
            // hidden card could retain an untracked subscription indefinitely.
            thread.fast = fast
            if (!stillCurrent()) {
                connection.request(JSONObject().put("kind", "unsubscribe").put("thread", thread.handle))
                requireCurrentNativeConnection(host, connection)
                thread.fast = null
                return@withLock
            }
        }
    }

    private suspend fun projectNative(endpoint: AgentSessionEndpoint, binding: AgentEndpointBinding, threadID: JSONObject,
                                      provider: String, transcriptRef: String, key: String, token: String,
                                      cursor: String?, direction: String = "before",
                                      prefetchConnection: AgentIngestionConnection? = null,
                                      seek: AgentSearchResultRow? = null) {
        var stage = "binding"
        val started = System.nanoTime()
        try {
        val context = threadOwners[key]?.coreBindingJSON?.let(::JSONObject)
        val rawPID = context?.opt("agentPID")
        require(rawPID == null || rawPID == JSONObject.NULL || rawPID is Int || rawPID is Long)
        val contextPID = (rawPID as? Number)?.toLong()?.also { require(it in 2..Int.MAX_VALUE) }?.toInt()
        stage = "connection"
        val (host, connection) = nativeConnection(endpoint, contextPID, context?.optJSONObject("incarnation")?.optString("rawValue") ?: "")
        if (prefetchConnection != null) check(connection === prefetchConnection) { "staleEpoch" }
        require(connection.supportsProvider(provider)) { "unsupported native session reader" }
        var thread = host.threads[key]
        if (thread == null) {
            stage = "resolve"
            val nativeLocator = provider in setOf("codex", "opencode") && transcriptRef.startsWith("native:")
            val resolved = connection.request(JSONObject().put("kind", "resolve").put("provider", provider)
                .put(if (nativeLocator) "nativeSessionID" else "transcriptRef", if (nativeLocator) transcriptRef.removePrefix("native:") else transcriptRef))
            requireCurrentNativeConnection(host, connection)
            check(resolved.end.optString("provider") == provider &&
                resolved.end.optString("sessionID") == threadID.getString("providerSessionID")) { "contextIdentityConflict" }
            val proposed = NativeThread(resolved.end.getString("thread"))
            host.reserveHandles(listOf(key to proposed.handle))
            claimNativeThread(key, host)
            thread = host.threads.putIfAbsent(key, proposed) ?: proposed
        } else claimNativeThread(key, host)
        val selected = thread
        selected.operation.withLock {
            projectNativeLocked(endpoint, binding, threadID, provider, key, token, cursor, direction, prefetchConnection,
                host, connection, selected, seek) { stage = it }
        }
        } catch (failure: Throwable) {
            val status = (failure as? AgentIngestionReadFailure)?.status ?: if (failure.message == "sourceMissing") {
                SharedAgentReadStatus.decode(JSONObject().put("v", 1).put("state", "failed").put("domain", "source")
                    .put("recovery", "manual").put("code", "sourceMissing"))
            } else null
            if (status != null && threadOwners[key]?.bindingToken == token) {
                if (stage == "resolve") mutableState.value = mutableState.value.copy(
                    ingestionReadStatuses = mutableState.value.ingestionReadStatuses + (key to status))
                // The frame that started this read may be accepted after it fails.
                if (status.code == "sourceMissing") firstReadFailureLifecycleSequences.putIfAbsent(key, latestPromptLifecycleSequence[key] ?: 0L)
                if (status.code == "sourceMissing" && (firstProjectionRetryTokens[key] != token ||
                        firstProjectionRetryJobs[key]?.isActive == true)) {
                    mutableState.value = mutableState.value.copy(ingestionReadStatuses = mutableState.value.ingestionReadStatuses + (key to status))
                    scheduleFirstProjectionRetry(key, token)
                }
            }
            if (mutableState.value.ingestionReadStatuses[key]?.recovery == "retryRead") {
                // A retried seek has lost its landing; it reads the newest page.
                readRetryRequests[key] = cursor to if (direction == "seek") "before" else direction
            }
            // Normal background/route cancellation is not a loading error.
            if (failure !is kotlinx.coroutines.CancellationException || failure is kotlinx.coroutines.TimeoutCancellationException) {
                diagnostics?.invoke("agent_ingestion_projection_failed", AgentIngestionDiagnostics.failure(failure) + mapOf(
                    "stage" to stage, "provider" to provider, "transport" to binding.transport.name,
                    "thread" to key, "elapsedMs" to ((System.nanoTime() - started) / 1_000_000).toString()))
            }
            throw failure
        }
    }

    /**
     * [projectNative]'s reads of [selected], under its operation lock. [onStage]
     * names each step as it starts, for the failure [projectNative] reports.
     */
    private suspend fun projectNativeLocked(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        threadID: JSONObject,
        provider: String,
        key: String,
        token: String,
        cursor: String?,
        direction: String,
        prefetchConnection: AgentIngestionConnection?,
        host: NativeHost,
        connection: AgentIngestionConnection,
        selected: NativeThread,
        seek: AgentSearchResultRow?,
        onStage: (String) -> Unit,
    ) {
        if (prefetchConnection == null && (direction == "bootstrap" || cursor != null)) {
            mutableState.value = mutableState.value.copy(ingestionCapacityThreads = mutableState.value.ingestionCapacityThreads - key)
        }
        // A host from before seeks reads no page around a match: the thread
        // opens at its newest page, as for a refused seek.
        val seeking = direction == "seek" && connection.supportsWindowSeek
        if (selected.window != null && cursor == null && direction != "bootstrap" && !seeking) {
            if (direction == "seek" && seek != null &&
                mutableState.value.searchLanding?.let { it.threadKey == key && it.recordID == seek.recordID } == true &&
                mutableState.value.projectedDetails[key]?.window?.atLiveHead == false) pendingLatestRequests.add(key)
            scheduleInitialPrefetch(host, connection, selected, key)
            updateNativeInterests(host, connection)
            return
        }
        // An opening read ends a place a notification gave up, however it ends.
        val opening = selected.window == null && prefetchConnection == null
        // Any other read that opens the thread here opens a reader who was in
        // history at their place instead ([readerPlace]).
        val place = if (selected.window == null && seek == null && direction != "bootstrap" && prefetchConnection == null &&
            // OpenCode orders count from wherever a read began: the host
            // reads around no row there.
            connection.supportsWindowSeek && provider != "opencode") readerPlace(key) else null
        val target = seek ?: place
        val seeks = seeking || place != null
        // A seek that starts its window here keeps the rows on screen
        // until it ends: the newest page it reads first never shows.
        val hold = if (seeks && selected.window == null && prefetchConnection == null) Any() else null
        if (hold != null) synchronized(presentationHoldLock) { presentationHolds[key] = hold }
        var outcome = SeekOutcome.INTERRUPTED
        selected.paused = true
        try {
            onStage("unsubscribe")
            // A control abandoned in flight leaves the remote watch unknown,
            // so the connection retires with every thread on it. Optional
            // history is cancelled by any tap or selection; its unsubscribe
            // runs to the reply.
            kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
                host.interests.withLock {
                    connection.request(JSONObject().put("kind", "unsubscribe").put("thread", selected.handle)); selected.fast = null
                }
            }
            currentCoroutineContext().ensureActive()
            suspend fun read(operation: String, anchor: String? = null, wanted: () -> Boolean = { true },
                             fields: JSONObject.() -> Unit = {}): AgentIngestionConnection.Reply {
                var limit = 100
                while (true) {
                    onStage("pageRead")
                    val previousWindow = selected.window
                    val reply = connection.request(JSONObject().put("kind", "window.read").put("operation", operation)
                        .put("thread", selected.handle).putOpt("cursor", anchor).put("limit", limit)
                        .put("windowVersion", if (operation == "bootstrap") 0 else checkNotNull(selected.window).getLong("version"))
                        .apply(fields))
                    val source = checkNotNull(projectionSources[key])
                    try {
                        onStage("pageAuthority")
                        check(enabled && applicationForeground) { "projectionInactive" }
                        check(isNativeHostCurrent(host)) { "staleEpoch" }
                        // Core leases contain terminal addresses, not host
                        // display names. Compare every route field without
                        // rejecting the same address's presentation label.
                        check(source.binding.sameRouteAs(binding)) { "projectionRouteChanged" }
                        check(source.bindingToken == token) { "projectionOwnerChanged" }
                        check(isProjectionSourceCurrent(endpoint, source)) { "staleBinding" }
                        if (prefetchConnection != null) check(selected.window === previousWindow) { "resyncRequired" }
                        check(wanted()) { "seekDropped" }
                        currentCoroutineContext().ensureActive()
                        // Once Core accepts a page its remote lease must be
                        // ACKed even if optional prefetch is cancelled in
                        // that local commit interval. This never waits for
                        // another history response or blocks Send's frontier.
                        val commit = kotlinx.coroutines.withContext(if (prefetchConnection != null)
                            kotlinx.coroutines.NonCancellable else currentCoroutineContext()) {
                            onStage("pageCommit")
                            val committed = commitNative(host, connection, selected.handle, reply, threadID, token,
                                movesPrompt = operation == "bootstrap")
                            if (committed.accepted) {
                                val checkpoint = checkNotNull(committed.window)
                                onStage("pageAck")
                                connection.acknowledgeWindow(reply, checkpoint)
                                requireCurrentNativeConnection(host, connection)
                                if (prefetchConnection != null) check(selected.window === previousWindow) { "resyncRequired" }
                                selected.window = checkpoint; selected.liveCursor = checkpoint.getString("liveCursor")
                            }
                            committed
                        }
                        if (commit.accepted) {
                            diagnostics?.invoke("agent_ingestion_window_read", mapOf(
                                "operation" to operation, "provider" to provider,
                                "transport" to binding.transport.name,
                                "request" to reply.end.getString("id"), "accepted" to "true"))
                            return reply
                        }
                        connection.cancelWindow(reply.end.getString("id"), selected.handle)
                        if (commit.code != "capacityExceeded" || limit == 1) error(commit.code ?: "ingestion rejected")
                        limit = (limit / 2).coerceAtLeast(1)
                    } catch (failure: Throwable) {
                        kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
                            connection.cancelWindow(reply.end.getString("id"), selected.handle)
                        }
                        throw failure
                    }
                }
            }
            if (selected.window == null || direction == "bootstrap") {
                // A bootstrap sizes its new window from this connection's
                // hello. Legacy hosts are reported too, as four segments,
                // so a window never outgrows the host it acknowledges to.
                forward(JSONObject().put("v", 1).put("kind", "hostCapacity").put("threadID", threadID).put("hostWindowSegments",
                    JSONObject().put(threadID.getString("hostID"), connection.maxWindowSegments)))
                read("bootstrap")
                if (threadOwners[key]?.bindingToken == token) {
                    firstProjectionRetryTokens.putIfAbsent(key, token)
                    if (mutableState.value.ingestionReadStatuses[key]?.code == "sourceMissing") clearNativeReadStatus(key)
                }
                selected.initialPrefetchStarted = false
                if (!seeks) scheduleInitialPrefetch(host, connection, selected, key)
                // Optional title metadata cannot keep the first-page
                // spinner or the older-page prefetch waiting on its RTT.
                if (provider == "codex" && selected.metadataJob?.isActive != true) {
                    val metadata = scope.launch(start = CoroutineStart.LAZY) {
                        try {
                            val summary = connection.request(JSONObject().put("kind", "summary").put("thread", selected.handle))
                            commitNative(host, connection, selected.handle, summary, threadID, token, movesPrompt = false)
                        } catch (failure: CancellationException) { throw failure }
                        catch (failure: Throwable) {
                            diagnostics?.invoke("agent_ingestion_metadata_failed", AgentIngestionDiagnostics.failure(failure))
                        } finally { selected.metadataJob = null }
                    }
                    selected.metadataJob = metadata
                    metadata.start()
                }
            }
            else if (cursor != null) read(direction, cursor)
            // The page around a match, read from the live cursor into a
            // viewport apart from the head. A refusal (the record moved, a
            // source that cannot seek, a cursor the head moved past) opens
            // the thread at its newest page.
            val order = target?.sequence?.seekOrder()
            val live = selected.liveCursor
            // A reader who left the match (another thread, the newest page)
            // keeps the window they chose.
            var landingID = target?.recordID
            val awaited = { mutableState.value.searchLanding?.let { it.threadKey == key && it.recordID == landingID } == true }
            outcome = SeekOutcome.ENDED
            if (seeks && target != null && order != null && live != null && awaited()) {
                outcome = SeekOutcome.INTERRUPTED
                try {
                    val reply = read("seek", live, wanted = awaited) {
                        // The record ID names the generation the order counts in.
                        put("order", order).put("recordID", target.recordID)
                        target.sourceOffset?.seekOrder()?.let { put("sourceOffset", it) }
                        target.seekToken?.let { put("seekToken", it) }
                    }
                    // An index the host rebuilt since the search (its cache
                    // evicted it) numbers the same record under a new ID.
                    val landed = reply.recordIDs[order]
                    if (landed != null && landed != landingID && retargetSearchLanding(key, target.recordID, landed)) landingID = landed
                    // Core clears the anchor with the old viewport; a head
                    // that rolls before the reader lands keeps the match. A
                    // reader who left it while the page applied goes back to
                    // the newest page; one who tapped another match here
                    // lands there instead.
                    outcome = if (awaited()) {
                        viewportAnchor(key, checkNotNull(landingID))
                        readerPlaces.remove(key)
                        SeekOutcome.LANDED
                    } else {
                        if (mutableState.value.searchLanding?.threadKey != key) pendingLatestRequests.add(key)
                        SeekOutcome.ENDED
                    }
                } catch (failure: CancellationException) {
                    // A seek that timed out on a live connection ended there,
                    // as on iOS: its newest page shows and the place settles.
                    if (failure is kotlinx.coroutines.TimeoutCancellationException && !connection.isClosed &&
                        isNativeHostCurrent(host)) outcome = SeekOutcome.ENDED
                    throw failure
                } catch (failure: Throwable) {
                    val left = !awaited()
                    diagnostics?.invoke(if (left) "agent_ingestion_seek_dropped" else "agent_ingestion_seek_refused",
                        AgentIngestionDiagnostics.failure(failure) + mapOf("provider" to provider, "transport" to binding.transport.name))
                    // The connection went, not the record: the next one tries again.
                    if (!connection.isClosed && isNativeHostCurrent(host)) {
                        outcome = SeekOutcome.ENDED
                        // Even from another match's page; the read's end reads
                        // it. A held detail still shows the rows before: Core's
                        // window is the one the newest page would replace.
                        val shown = synchronized(presentationHoldLock) { heldDetails[key] } ?: mutableState.value.projectedDetails[key]
                        if (!left && shown?.window?.atLiveHead == false) pendingLatestRequests.add(key)
                        // A newest page the refusal leaves pages older as any
                        // newly opened thread's does.
                        else if (!left && hold != null) scheduleInitialPrefetch(host, connection, selected, key)
                    }
                }
            }
        } finally {
            if (hold != null) settlePresentationHold(key, hold, place, outcome)
            if (opening) readerPlacesGivenUp.remove(key)
            selected.paused = false
            // Subscription maintenance is independently coalesced; page
            // loading never waits for every visible card's control ACK.
            scheduleNativeInterests()
        }
    }

    private suspend fun project(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        threadID: JSONObject,
        provider: String,
        transcriptRef: String,
        threadKey: String,
        cursor: String? = null,
        bindingToken: String,
        initialPagesRemaining: Int = 0,
        nativeDirection: String = "before",
        seek: AgentSearchResultRow? = null,
    ) {
        // Every exit below used to be a bare `return`. A transcript projection
        // is what supplies a row's title, status and model, so when it stopped
        // silently the whole of Agent Center read "untitled - unavailable" with
        // nothing in any log to say which step gave up.
        fun refuse(reason: String) = diagnostics?.invoke(
            "agent_projection_refused",
            mapOf("detail" to "thread=$threadKey provider=$provider $reason"),
        )
        val owner = threadOwners[threadKey]
        if (owner?.endpointKey != endpoint.key || owner.bindingToken != bindingToken) {
            return refuse("stale-owner") ?: Unit
        }
        AgentTierCProvider.fromWire(provider)?.let { tierC ->
            if (!tierCConforms(endpoint.key, binding, tierC)) return refuse("tierC-not-conformant") ?: Unit
        }
        if (provider in setOf("codex", "claude", "pi", "opencode", "kimi")) {
            try {
                projectNative(endpoint, binding, threadID, provider, transcriptRef, threadKey, bindingToken,
                    cursor, direction = nativeDirection, seek = seek)
            } catch (failure: kotlinx.coroutines.CancellationException) { throw failure }
            catch (failure: Throwable) { refuse("native-ingestion-failed errorType=${failure.javaClass.simpleName}") }
            return
        }
        val request = JSONObject().put("v", 1).put("kind", "project").put("provider", provider)
            // Lifecycle/output refreshes always ask for the newest page. The
            // retained cursor is an older-page token for an explicit paging
            // intent; feeding it into every refresh would freeze live updates.
            .put("transcriptRef", transcriptRef)
            .put("limitBytes", 262_144).put("limitRecords", 100)
            .putOpt("cursor", cursor)
            .putOpt("continuationCursor", if (cursor == null)
                mutableState.value.projectedDetails[threadKey]?.cursor else null)
            .toString().plus("\n").encodeToByteArray()
        val opened = endpoint.execute(binding, AgentExecRequest("tessera-agent-project", request))
        val stream = (opened as? AgentEndpointResult.Success)?.value
            ?: return refuse("exec=${opened.describeFailure()}") ?: Unit
        when (val drained = AgentRemoteStreamDrain.drain(stream, MAX_PROJECTOR_OUTPUT_BYTES, PROJECTOR_STREAM_TIMEOUT_MILLIS)) {
            is AgentRemoteStreamDrain.Result.Complete -> {
                if (drained.exit.code != 0) {
                    val fields = runCatching { SharedAgentIntegrationParsing.projectorDiagnostics(drained.stdout) }.getOrDefault(emptyMap())
                    diagnostics?.invoke("agent_projector_failure", fields + mapOf(
                        "thread" to threadKey, "provider" to provider, "pane" to (binding.paneID ?: "raw"),
                        "exit" to drained.exit.code.toString(),
                    ))
                    return refuse("projector-exit=${drained.exit.code} error=${fields["error"] ?: "unknown"}") ?: Unit
                }
                val frames = drained.stdout.decodeToString().lineSequence().filter(String::isNotBlank).map(::JSONObject).toList()
                frames.firstOrNull { it.optString("kind") == "error" }?.let {
                    return refuse("projector-error=${it.optString("code").ifBlank { "unknown" }}") ?: Unit
                }
                val pageFrame = frames.firstOrNull { it.optString("kind") == "page" }
                    ?: return refuse("no-page-frame kinds=${frames.map { it.optString("kind") }}") ?: Unit
                val end = frames.lastOrNull { it.optString("kind") == "end" }
                    ?: return refuse("no-end-frame kinds=${frames.map { it.optString("kind") }}") ?: Unit
                val records = JSONArray()
                frames.filter { it.optString("kind") == "record" }.take(100).forEachIndexed { index, frame ->
                    projectionRecordBoundsIssue(frame)?.let { issue ->
                        diagnostics?.invoke("agent_projection_record_bounds", mapOf(
                            "thread" to threadKey, "provider" to provider,
                            "recordType" to frame.optJSONObject("record")?.optString("type").orEmpty().take(64),
                            "index" to index.toString(), "issue" to issue,
                        ))
                    }
                    records.put(JSONObject().put("sequence", frame.getLong("sequence"))
                        .put("recordID", frame.getString("recordID")).put("record", frame.get("record"))
                        .putOpt("sourceOffset", frame.opt("sourceOffset")).putOpt("sourceHash", frame.opt("sourceHash")))
                }
                val page = JSONObject().put("sourceIdentity", pageFrame.getString("sourceIdentity"))
                    .putOpt("from", pageFrame.opt("from")).putOpt("to", end.opt("cursor"))
                    .put("records", records).putOpt("cursor", end.opt("cursor"))
                    .putOpt("summary", pageFrame.opt("summary"))
                    .put("hasMore", end.optBoolean("hasMore", false))
                if (threadOwners[threadKey]?.bindingToken == bindingToken) {
                    val sent = forwardQuestionInput(threadKey) {
                        forward(JSONObject().put("v", 1).put("kind", "projection").put("threadID", threadID).put("bindingToken", bindingToken).put("projection", page))
                    }
                    // A positive marker as well as the refusals: without it,
                    // "no projection diagnostic" is ambiguous between "never
                    // ran" and "ran and was accepted", which is the difference
                    // between a client bug and a Core one.
                    if (sent) {
                        diagnostics?.invoke(
                            "agent_projection_forwarded",
                            mapOf("detail" to "thread=$threadKey records=${records.length()} hasMore=${end.optBoolean("hasMore", false)}"),
                        )
                        val next = end.optString("cursor").takeIf { it.isNotBlank() && it != cursor }
                        if (initialPagesRemaining > 0 && end.optBoolean("hasMore") && next != null) {
                            project(endpoint, binding, threadID, provider, transcriptRef, threadKey,
                                cursor = next, bindingToken = bindingToken,
                                initialPagesRemaining = (initialPagesRemaining - 1).coerceAtLeast(0))
                        }
                    } else refuse("core-rejected records=${records.length()}")
                } else {
                    refuse("owner-changed-before-forward")
                }
            }
            AgentRemoteStreamDrain.Result.TimedOut -> refuse("drain-timeout")
            is AgentRemoteStreamDrain.Result.Failed -> refuse("drain-failed")
        }
    }

    /** The agent process a thread's search connection is scoped to, read
     * from its owner's Core binding: its PID and incarnation, or none. */
    private fun searchContext(key: String): Pair<Int?, String> {
        val context = threadOwners[key]?.coreBindingJSON?.let(::JSONObject)
        val rawPID = context?.opt("agentPID")
        require(rawPID == null || rawPID == JSONObject.NULL || rawPID is Int || rawPID is Long)
        val contextPID = (rawPID as? Number)?.toLong()?.also { require(it in 2..Int.MAX_VALUE) }?.toInt()
        return contextPID to (context?.optJSONObject("incarnation")?.optString("rawValue") ?: "")
    }

    /** The pooled connection [searchConnection] would use, keyed as
     * [nativeConnection] keys it, so one failed open fences all its threads. */
    private fun searchConnectionKey(endpoint: AgentSessionEndpoint, key: String): Pair<AgentSessionKey, String> =
        endpoint.key to runCatching { searchContext(key) }.fold(
            onSuccess = { (pid, incarnation) -> pid?.let { "$it:$incarnation" } ?: "default" },
            onFailure = { "invalid:$key" },
        )

    private suspend fun searchConnection(endpoint: AgentSessionEndpoint, key: String): Pair<NativeHost, AgentIngestionConnection> {
        val (contextPID, incarnation) = searchContext(key)
        return nativeConnection(endpoint, contextPID, incarnation)
    }

    private fun isSearchSourceCurrent(endpoint: AgentSessionEndpoint, key: String, source: ProjectionSource): Boolean =
        isProjectionSourceCurrent(endpoint, source) && projectionSources[key] === source && threadOwners[key]?.bindingToken == source.bindingToken

    private class SearchSource(val key: String, val source: ProjectionSource, val endpoint: AgentSessionEndpoint)

    /** One host's pass: its matches, the threads to page instead, and
     * whether any thread was left not fully searched (the budget, a failed
     * request, a changed source or matches the host could not send). */
    private class HostSearch(val results: List<JSONObject>, val paged: List<SearchSource>, val incomplete: Boolean)

    /** Searches every thread a host holds a handle for in a few host passes,
     * a few hundred kilobytes a reply. The threads to page instead are those
     * it has no handle for, those the host skipped as having no file to scan,
     * and a batch the host refused outright. */
    private suspend fun searchHost(group: List<SearchSource>, needle: String, admitted: Int, deadline: Long,
                                   progress: suspend (List<JSONObject>) -> Unit): HostSearch {
        val first = group.first()
        val remaining = (deadline - System.nanoTime()) / 1_000_000
        if (remaining <= 0) return HostSearch(emptyList(), emptyList(), incomplete = true)
        val (host, connection) = withTimeout(remaining) { searchConnection(first.endpoint, first.key) }
        if (!connection.supportsSearch) return HostSearch(emptyList(), group, incomplete = false)
        val held = linkedMapOf<String, SearchSource>()
        val paged = mutableListOf<SearchSource>()
        for (entry in group) {
            // As on iOS: a reader this host lacks is paged, and fails there,
            // so its host reads as not fully searched rather than the thread
            // silently matching nothing.
            val handle = host.threads[entry.key]?.handle
            if (connection.supportsProvider(entry.source.provider) && handle != null && handle !in held) held[handle] = entry
            else paged += entry
        }
        if (held.isEmpty()) return HostSearch(emptyList(), paged, incomplete = false)
        val handles = held.entries.associate { it.value.key to it.key }
        val threadIDs = held.mapValues { JSONObject(it.value.source.threadID) }
        val outcome = runAgentHostSearch(held.keys.toList(), needle, AGENT_SEARCH_HOST_RESULTS - admitted, deadline,
            request = { fields, timeoutMillis ->
                check(isNativeHostCurrent(host)) { "staleBinding" }
                connection.request(fields, timeoutMillis).also { requireCurrentNativeConnection(host, connection) }
            },
            match = { reply, batch ->
                val wire = checkNotNull(reply.wire)
                val epoch = connection.epoch
                val requestID = reply.end.getString("id")
                val threads = batch.associateWith { threadIDs.getValue(it) }
                // Decoding and matching a few hundred kilobytes of records
                // stays off Main, like a large page's parse.
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
                    SharedAgentHostSearch.matches(wire, epoch, requestID, needle, threads)
                }
            },
            admit = { match ->
                val id = match.getJSONObject("threadID")
                val key = canonicalAgentThreadKey(id.getString("hostID"), id.getJSONObject("providerID").getString("rawValue"), id.getString("providerSessionID"))
                val handle = handles[key]
                val entry = handle?.let { held[it] }
                if (entry != null && isSearchSourceCurrent(entry.endpoint, key, entry.source)) handle else null
            },
            handleOf = { match ->
                val id = match.getJSONObject("threadID")
                handles[canonicalAgentThreadKey(id.getString("hostID"), id.getJSONObject("providerID").getString("rawValue"), id.getString("providerSessionID"))]
            },
            progress = progress,
        )
        return HostSearch(outcome.results, paged + outcome.paged.map { held.getValue(it) }, outcome.incomplete)
    }

    private suspend fun searchNativeProvider(endpoint: AgentSessionEndpoint, key: String, source: ProjectionSource, query: String): JSONArray = withTimeout(30_000) {
        val (host, connection) = searchConnection(endpoint, key)
        check(connection.supportsProvider(source.provider))
        val nativeLocator = source.provider in setOf("codex", "opencode") && source.transcriptRef.startsWith("native:")
        val resolved = connection.request(JSONObject().put("kind", "resolve").put("provider", source.provider)
            .put(if (nativeLocator) "nativeSessionID" else "transcriptRef", if (nativeLocator) source.transcriptRef.removePrefix("native:") else source.transcriptRef))
        val id = JSONObject(source.threadID)
        check(resolved.end.optString("provider") == source.provider && resolved.end.optString("sessionID") == id.getString("providerSessionID"))
        val handle = resolved.end.getString("thread")
        val results = JSONArray()
        var cursor: String? = null
        var identity: String? = null
        var previousOrder: java.math.BigInteger? = null
        repeat(512) {
            currentCoroutineContext().ensureActive()
            check(isNativeHostCurrent(host) && isProjectionSourceCurrent(endpoint, source) &&
                projectionSources[key] === source && threadOwners[key]?.bindingToken == source.bindingToken)
            val reply = connection.request(JSONObject().put("kind", if (cursor == null) "bootstrap" else "history")
                .put("thread", handle).put("limit", 100).putOpt("cursor", cursor))
            requireCurrentNativeConnection(host, connection)
            check(isProjectionSourceCurrent(endpoint, source) && projectionSources[key] === source &&
                threadOwners[key]?.bindingToken == source.bindingToken) { "staleBinding" }
            val matches = SharedAgentPageSearch.matches(checkNotNull(reply.wire), connection.epoch, handle, id, query)
            // Core first validates the original wire, including exact integers.
            // These boundaries additionally fence independent search pages.
            val order = reply.firstOrder?.toBigIntegerOrNull()
            check(reply.sourceIdentity != null && (identity == null || identity == reply.sourceIdentity) &&
                (previousOrder == null || (order != null && order < previousOrder)))
            identity = reply.sourceIdentity; previousOrder = order
            for (index in 0 until matches.length()) if (results.length() < 25) results.put(matches.getJSONObject(index))
            if (results.length() == 25 || !reply.end.getBoolean("hasOlder")) return@withTimeout results
            val next = reply.end.getString("historyCursor")
            check(next.isNotEmpty() && next != cursor)
            cursor = next
        }
        error("native search page budget exceeded")
    }

    private suspend fun runRemoteSearch(query: String) {
        // Hosts are searched once typing pauses: each keystroke's search
        // would otherwise queue on the hosts ahead of transcript reads.
        delay(300)
        // The rows shown when the search starts stay while it runs, and each
        // reply that finds more adds them; the end shows what it found.
        val shown = presentedSearchResults
        val results = JSONArray()
        val unavailableHosts = linkedSetOf<String>()
        val resultCounts = mutableMapOf<String, Int>()
        val deadline = System.nanoTime() + 30_000_000_000L
        // Each host connection searches all the threads it holds in one pass;
        // only the threads it cannot scan are paged one by one. Open
        // conversations go first, then inventory, as on iOS.
        val groups = linkedMapOf<NativeHost, MutableList<SearchSource>>()
        val paged = mutableListOf<SearchSource>()
        // A connection that could not open stays failed for this search, so
        // its other threads are not reopened one by one past the deadline.
        val failedConnections = mutableSetOf<Pair<AgentSessionKey, String>>()
        // Each connection is opened once a search: thousands of threads would
        // otherwise each repeat its setup on Main.
        val openConnections = mutableMapOf<Pair<AgentSessionKey, String>, NativeHost>()
        var visited = 0
        for ((sourceKey, source) in projectionSources.entries
            .sortedWith(compareBy<Map.Entry<String, ProjectionSource>>({ it.value.hostObservation }, { it.value.threadID }))) {
            currentCoroutineContext().ensureActive()
            if (++visited % 64 == 0) kotlinx.coroutines.yield()
            if (!enabled || !applicationForeground) return
            val hostID = JSONObject(source.threadID).getString("hostID")
            val owner = threadOwners[sourceKey]
            // A thread another owner holds now is not searched from a source
            // left on the old one: its host reads as not fully searched.
            if (owner?.endpointKey != source.endpointKey || owner.bindingToken != source.bindingToken) {
                hostID.takeIf(::isUUID)?.let(unavailableHosts::add)
                continue
            }
            val endpoint = coordinator.directory.resolve(source.endpointKey)
            if (endpoint == null) {
                hostID.takeIf(::isUUID)?.let(unavailableHosts::add)
                continue
            }
            val entry = SearchSource(sourceKey, source, endpoint)
            val connectionKey = searchConnectionKey(endpoint, sourceKey)
            val remaining = (deadline - System.nanoTime()) / 1_000_000
            if (connectionKey in failedConnections || remaining <= 0) { unavailableHosts.add(hostID); continue }
            try {
                val host = openConnections[connectionKey]
                    ?: withTimeout(remaining) { searchConnection(endpoint, sourceKey) }.first.also { openConnections[connectionKey] = it }
                // A Tier-C reader is judged on the connection just opened,
                // which proves its conformance; one that still does not
                // conform is not read, and its host reads as not fully
                // searched rather than the thread silently matching nothing.
                val tierCProvider = AgentTierCProvider.fromWire(source.provider)
                if (tierCProvider != null && !tierCConforms(source.endpointKey, source.binding, tierCProvider)) {
                    unavailableHosts.add(hostID)
                    continue
                }
                groups.getOrPut(host) { mutableListOf() } += entry
            } catch (failure: Exception) {
                // Only this search's own cancellation ends it; a nested
                // timeout or a cancelled opening is a failed connection.
                if (failure is CancellationException) currentCoroutineContext().ensureActive()
                failedConnections += connectionKey
                unavailableHosts.add(hostID)
            }
        }
        for (group in groups.values) {
            currentCoroutineContext().ensureActive()
            if (!enabled || !applicationForeground) return
            val hostID = JSONObject(group.first().source.threadID).getString("hostID")
            if ((resultCounts[hostID] ?: 0) >= AGENT_SEARCH_HOST_RESULTS) continue
            if (deadline - System.nanoTime() <= 0) { unavailableHosts.add(hostID); continue }
            try {
                val earlier = results.length()
                val found = searchHost(group, query, resultCounts[hostID] ?: 0, deadline) { hostFound ->
                    if (enabled && applicationForeground) {
                        val sofar = JSONArray()
                        for (index in 0 until earlier) sofar.put(results.get(index))
                        hostFound.forEach(sofar::put)
                        publishSearch(agentSearchMerged(shown, sofar), JSONArray())
                    }
                }
                // What the host found before its budget ran out still shows;
                // the host is reported incomplete, as a paged search that ran
                // out of time is.
                for (match in found.results) if ((resultCounts[hostID] ?: 0) < AGENT_SEARCH_HOST_RESULTS) {
                    results.put(match)
                    resultCounts[hostID] = (resultCounts[hostID] ?: 0) + 1
                }
                paged += found.paged
                if (found.incomplete) unavailableHosts.add(hostID)
            } catch (failure: Exception) {
                if (failure is CancellationException) currentCoroutineContext().ensureActive()
                unavailableHosts.add(hostID)
            }
        }
        for (entry in paged) {
            currentCoroutineContext().ensureActive()
            if (!enabled || !applicationForeground) return
            val sourceKey = entry.key; val source = entry.source; val endpoint = entry.endpoint
            val hostID = JSONObject(source.threadID).getString("hostID")
            if ((resultCounts[hostID] ?: 0) >= 100) continue
            val remaining = (deadline - System.nanoTime()) / 1_000_000
            if (remaining <= 0) { unavailableHosts.add(hostID); continue }
            try {
                val matches = withTimeout(remaining) { searchNativeProvider(endpoint, sourceKey, source, query) }
                currentCoroutineContext().ensureActive()
                if (isSearchSourceCurrent(endpoint, sourceKey, source)) {
                    val before = results.length()
                    for (index in 0 until matches.length()) if ((resultCounts[hostID] ?: 0) < 100) {
                        results.put(matches.getJSONObject(index))
                        resultCounts[hostID] = (resultCounts[hostID] ?: 0) + 1
                    }
                    if (results.length() > before) publishSearch(agentSearchMerged(shown, results), JSONArray())
                }
                // A thread whose route changed meanwhile shows nothing it
                // found, and its host reads as not fully searched, as on iOS.
                else unavailableHosts.add(hostID)
            } catch (failure: Exception) {
                // A closed connection cancels its waiting reads; that fails
                // this source, not the whole search.
                if (failure is CancellationException) currentCoroutineContext().ensureActive()
                unavailableHosts.add(hostID)
            }
        }
        currentCoroutineContext().ensureActive()
        if (!enabled || !applicationForeground) return
        // A host that stopped early is reported even when it returned
        // matches: they are partial. Core's AgentSearchSnapshot refuses more
        // than four hosts in all, so both lists are bounded as its
        // constructor bounds them.
        val admittedResults = agentSearchResultsWithinHostCap(results)
        val resultHosts = (0 until admittedResults.length()).mapNotNull { index ->
            admittedResults.optJSONObject(index)?.optJSONObject("threadID")?.optString("hostID")
        }.toSet()
        val incompleteHosts = agentSearchUnavailableHosts(unavailableHosts, resultHosts)
        publishSearch(admittedResults, JSONArray(incompleteHosts))
        diagnostics?.invoke("agent_search_completed", mapOf("count" to admittedResults.length().toString(),
            "unavailableHosts" to incompleteHosts.size.toString(), "paged" to paged.size.toString()))
    }

    private suspend fun executeLaunchPlan(snapshot: SharedAgentSnapshot) {
        val pending = pendingLaunch ?: return
        val plan = snapshot.payload.obj("launchPlan")?.toJson() ?: return
        val requestID = plan.optString("requestID").takeIf { runCatching { java.util.UUID.fromString(it) }.isSuccess }
            ?: return failLaunch("Launch plan did not include a correlation ID")
        val plannedIntent = plan.optJSONObject("intent") ?: return failLaunch("Launch plan was malformed")
        if (!plannedIntent.matches(pending.request, JSONObject(pending.threadID), pending.parentRecordID)) return failLaunch("Launch plan changed before execution")
        val bindingEnvelope = JSONObject().put("binding", JSONObject(pending.binding)).put("threadID", JSONObject(pending.threadID))
        val exact = bindingEnvelope.endpointBindingOrNull() ?: return failLaunch("Terminal binding is stale")
        val endpoint = coordinator.directory.resolve(exact.key) ?: return failLaunch("Terminal session disconnected")
        // A launch sheet is a lease on the exact route shown when it opened.
        // Compare every address field before any tmux side effect; never
        // substitute the currently active window or pane for a stale target.
        if (!pending.request.matchesEndpointBinding(exact)) {
            return failLaunch("Launch target is stale")
        }
        val agentPID = JSONObject(pending.binding).optInt("agentPID", -1).takeIf { it > 1 }
            ?: return failLaunch("Agent process proof is unavailable")
        // Reissue authority from a just-proven process immediately before the
        // helper launch. A prior lifecycle token is never enough for a spawn.
        val pendingThreadID = JSONObject(pending.threadID)
        val pendingProvider = pendingThreadID.getJSONObject("providerID").getString("rawValue")
        val refreshed = coordinator.issueRouteBinding(pendingThreadID, exact, agentPID, pendingProvider)
        val freshAuthority = (refreshed as? AgentEndpointResult.Success<*>)?.value as? AgentIssuedBinding
        if (freshAuthority == null || !freshAuthority.actionable ||
            !freshAuthority.coreBinding.sameCoreBinding(JSONObject(pending.binding))) {
            return failLaunch("Agent process changed before launch")
        }
        if (pending.request.directory.trim() !in freshAuthority.provenDirectories) {
            return failLaunch("Launch directory proof changed")
        }
        bindingTokens[freshAuthority.coreBinding.tokenKey(pending.threadKey)] = freshAuthority.bindingToken
        val placement = when (pending.request.placement) {
            AgentLaunchPlacement.NewWindow -> AgentTmuxPlacement.NewWindow(pending.request.name)
            AgentLaunchPlacement.SplitRight -> AgentTmuxPlacement.Split(pending.request.target.paneID ?: return failLaunch("Split target is unavailable"), vertical = false)
            AgentLaunchPlacement.SplitDown -> AgentTmuxPlacement.Split(pending.request.target.paneID ?: return failLaunch("Split target is unavailable"), vertical = true)
        }
        if (pending.request.kind == AgentLaunchKind.Fork && pending.parentRecordID.isNullOrBlank()) {
            return failLaunch("Fork provenance is unavailable")
        }
        val helperRequest = pending.request.helperRequest(requestID, JSONObject(pending.threadID), pending.parentRecordID)
        val result = endpoint.launchTmux(exact, placement, requestID, helperRequest.toString().encodeToByteArray())
        when (result) {
            is AgentEndpointResult.Success -> {
                if (pending.request.isolation is AgentLaunchIsolation.NewWorktree && !result.value.worktreeCreated) {
                    return failLaunch("Remote worktree creation was not acknowledged")
                }
                // The helper mutation alone is not a product-level success.
                // First ask Core to validate and accept the correlated receipt;
                // only its acceptance may create local success state.
                val (abiWindowID, abiPaneID) = result.value.abiReceiptCoordinates(pending.request.placement, exact)
                val coreAccepted = forward(JSONObject().put("v", 1).put("kind", "result")
                    .put("bindingToken", freshAuthority.bindingToken)
                    .put("launchReceipt", JSONObject()
                        .put("value", "android-tmux-helper-ack")
                        .put("requestID", result.value.requestID)
                        .putOpt("windowID", abiWindowID)
                        .putOpt("paneID", abiPaneID)
                        .put("createdWorktree", result.value.worktreeCreated)))
                if (!coreAccepted) {
                    return failLaunch("Launch receipt was not accepted by Agent Core; review the terminal before retrying")
                }
                // Core accepted the bounded receipt. Persist it before waiting
                // for a later lifecycle frame so process death cannot erase an
                // acknowledged launch. A lifecycle frame later records the
                // target-thread association and fork lineage separately.
                val receiptPersisted = try {
                    metadata.rememberLaunchReceipt(
                        threadKey = pending.threadKey,
                        requestID = result.value.requestID,
                        parentThreadKey = pending.threadKey.takeIf { pending.request.kind == AgentLaunchKind.Fork },
                        parentRecordID = pending.parentRecordID,
                        windowID = result.value.windowID,
                        paneID = result.value.paneID,
                        worktreeCreated = result.value.worktreeCreated,
                        now = System.currentTimeMillis(),
                    )
                    true
                } catch (failure: Throwable) {
                    if (failure is kotlinx.coroutines.CancellationException) throw failure
                    false
                }
                pendingLifecycleLaunches["${endpoint.key.liveSessionID}:${result.value.paneID}"] = PendingLifecycleLaunch(
                    providerID = pending.request.providerID,
                    parentThreadKey = pending.threadKey.takeIf { pending.request.kind == AgentLaunchKind.Fork },
                    parentRecordID = pending.parentRecordID,
                    requestID = result.value.requestID,
                    windowID = result.value.windowID,
                    paneID = result.value.paneID,
                    worktreeCreated = result.value.worktreeCreated,
                )
                pendingLaunch = null
                mutableState.value = mutableState.value.copy(notice = if (receiptPersisted) {
                    "Launch acknowledged; waiting for the agent lifecycle in ${result.value.paneID}"
                } else {
                    "Launch acknowledged, but receipt persistence needs attention"
                })
            }
            AgentEndpointResult.StaleBinding -> failLaunch("Terminal binding is stale")
            is AgentEndpointResult.Unavailable -> failLaunch(result.reason)
            is AgentEndpointResult.Failed -> failLaunch("Launch failed: ${result.code.replace('_', ' ')}")
        }
    }

    private fun failLaunch(message: String) {
        pendingLaunch = null
        mutableState.value = mutableState.value.copy(notice = message)
    }

    private suspend fun executeActionPlan(
        snapshot: SharedAgentSnapshot,
        detail: AgentThreadDetail,
        writes: AgentTerminalWriteLatch,
        actionRuntime: SharedAgentRuntime?,
        draftCleared: Boolean,
    ) {
        val lease = snapshot.payload.obj("lease")?.toJson() ?: run {
            // No lease to answer Core with; at least stop this thread's
            // pending action from blocking every action.
            pendingActions.remove(detail.row.key)
            publishSendingThreads()
            return
        }
        val leasedAction = lease.optString("action")
        val actionPayload = snapshot.payload.obj("actionPayload")?.toJson()
        // Every early return below finishes the lease: Core's bubble must
        // never stay sending, nor the action stay pending.
        val pendingOrNull = pendingActions[detail.row.key]
        // The text Core planned is exactly what the ActionPlan cleared from
        // the composer, so it is what a not-sent refusal returns there.
        val plannedText = actionPayload?.optJSONObject("text")?.optString("text")?.takeIf { it.isNotEmpty() } ?: pendingOrNull?.text
        // Every refusal before the terminal write is provably unwritten. A text
        // lease then reports notSent (Core drops its bubble) instead of an
        // ambiguous failure; other actions keep their legacy result codes.
        fun refuse(legacyCode: String, reason: AgentNotSentReason, attempts: Int? = null, composerRefusal: Boolean = false) {
            if (leasedAction in AGENT_TEXT_ACTIONS && !writes.mayHaveWritten) {
                if (composerRefusal && pendingOrNull != null && plannedText != null && actionRuntime != null &&
                    !pendingOrNull.bypassComposerVerification) {
                    composerRefusals[lease.optString("token")] = SendAnywayCandidate(detail.row.key, leasedAction, plannedText,
                        JSONObject(pendingOrNull.binding.toString()), pendingOrNull.bindingToken,
                        pendingOrNull.composerRetryGeneration, actionRuntime, lease.optString("token"))
                }
                finishNotSent(lease, detail, reason, legacyCode, plannedText, draftCleared, actionRuntime, attempts)
            } else finishAction(lease, legacyCode, threadKey = detail.row.key)
        }
        diagnostics?.invoke("agent_action_plan", mapOf("action" to (pendingOrNull?.kind ?: leasedAction)))
        // No request of this kind is pending (another rejection cleared it):
        // the plan no longer matches anything the composer asked for.
        val pending = pendingOrNull?.takeIf { it.kind == leasedAction }
            ?: return refuse("verificationFailed", AgentNotSentReason.PLAN_MISMATCH)
        fun sendTiming(stage: String) {
            if (pending.kind !in AGENT_TEXT_ACTIONS) return
            diagnostics?.invoke("agent_send_latency", mapOf("stage" to stage,
                "elapsedMs" to ((System.nanoTime() - pending.requestedAtNanos) / 1_000_000).toString()))
        }
        sendTiming("action_plan")
        val leasedBinding = lease.endpointBindingOrNull() ?: run {
            diagnostics?.invoke("agent_action_route_refused", mapOf("stage" to "decode"))
            refuse("staleBinding", AgentNotSentReason.ROUTE_CHANGED); return
        }
        val endpoint = coordinator.directory.resolve(leasedBinding.key) ?: run {
            diagnostics?.invoke("agent_action_route_refused", mapOf("stage" to "resolve"))
            refuse("staleBinding", AgentNotSentReason.ROUTE_CHANGED); return
        }
        // The ActionLease binds the action to every address field. Never replace
        // it with the currently active pane/window after Core has granted it.
        if (!endpoint.isCurrentRoute(leasedBinding)) {
            diagnostics?.invoke("agent_action_route_refused", mapOf("stage" to "currentRoute"))
            refuse("staleBinding", AgentNotSentReason.ROUTE_CHANGED)
            return
        }
        val claimedPID = lease.optJSONObject("binding")?.optInt("agentPID", -1)?.takeIf { it > 1 }
        val leaseThreadID = lease.optJSONObject("threadID") ?: run {
            refuse("staleBinding", AgentNotSentReason.ROUTE_CHANGED); return
        }
        val coreBinding = lease.getJSONObject("binding")
        fun routeCurrent(): Boolean {
            val owner = threadOwners[detail.row.key] ?: return false
            return coordinator.directory.resolve(leasedBinding.key) === endpoint && endpoint.isCurrentRoute(leasedBinding) &&
                owner.endpointKey == leasedBinding.key && owner.canonicalBinding == coreBinding.tokenKey() &&
                owner.bindingToken == pending.bindingToken && !endedConversations.contains(detail.row.key)
        }
        fun preWriteRefusal(): AgentNotSentReason? = if (!routeCurrent()) AgentNotSentReason.ROUTE_CHANGED
            else endpoint.inputRefusal(leasedBinding)?.let {
                if (it == "stale_binding") AgentNotSentReason.ROUTE_CHANGED else AgentNotSentReason.INPUT_UNAVAILABLE
            }
        fun preWriteFailure(): AgentEndpointResult.Failed? = preWriteRefusal()?.let {
            AgentEndpointResult.Failed(if (it == AgentNotSentReason.ROUTE_CHANGED) "staleBinding" else "raw_input_unavailable",
                inputNotAdmitted = true)
        }
        // A binding token is single-route authority, not a durable permission.
        // Reissue route authority (discovery may reuse a short-lived memo),
        // then separately probe the live process immediately before each write.
        // Receipt preparation can outlive the memo and the agent itself.
        val leaseProvider = leaseThreadID.getJSONObject("providerID").getString("rawValue")
        val preflightPolicy = AgentSendPreflightPolicy()
        val refresh = retryAgentRouteBinding(preflightPolicy) {
            ensureActionActive()
            if (!routeCurrent()) {
                AgentEndpointResult.StaleBinding
            } else coordinator.issueRouteBinding(leaseThreadID, leasedBinding, claimedPID, leaseProvider)
        }
        val refreshed = refresh.result
        val freshAuthority = (refreshed as? AgentEndpointResult.Success<*>)?.value as? AgentIssuedBinding
        if (freshAuthority == null) {
            val reason = agentRouteRefreshFailureReason(refreshed)
            diagnostics?.invoke("agent_action_route_refused", mapOf("stage" to "authority", "reason" to reason.code))
            refuse(if (reason == AgentNotSentReason.ROUTE_CHANGED) "staleBinding" else "terminal_input_not_ready", reason, refresh.attempts)
            return
        }
        if (!freshAuthority.actionable) {
            refuse("unavailable", AgentNotSentReason.INPUT_UNAVAILABLE)
            return
        }
        if (!routeCurrent() || !freshAuthority.coreBinding.sameCoreBinding(coreBinding)) {
            refuse("staleBinding", AgentNotSentReason.ROUTE_CHANGED)
            return
        }
        val freshBindingToken = freshAuthority.bindingToken
        bindingTokens[freshAuthority.coreBinding.tokenKey(detail.row.key)] = freshBindingToken
        // GONE is final: the route is no longer current, the endpoint says the
        // binding is stale, or the proof names another process (iOS's
        // staleBinding). UNPROVEN is a missed probe (timeout, exec or tmux
        // failure) or momentarily absent input capabilities; a send retries
        // that within its readiness window, as iOS does.
        suspend fun currentInputTargetProof(timeoutMillis: Long = 5_000): AgentInputTargetProof {
            ensureActionActive()
            val pid = claimedPID ?: return AgentInputTargetProof.GONE
            val provider = AgentProofProvider.fromWire(leaseProvider) ?: return AgentInputTargetProof.GONE
            val start = freshAuthority.processStart ?: return AgentInputTargetProof.GONE
            if (!routeCurrent()) return AgentInputTargetProof.GONE
            // Bypass discovery's memo without paying for launch directories or
            // manufacturing a new action token. This read never retries input.
            val proofResult = withTimeoutOrNull(timeoutMillis.coerceAtMost(5_000)) {
                endpoint.proveProcess(leasedBinding, pid, provider, requireForeground = true)
            }
            ensureActionActive()
            val currentCapabilities = endpoint.capabilities.value
            return agentInputTargetProof(proofResult, routeCurrent(), pid, provider, start,
                inputCapable = currentCapabilities.verifiedInput && currentCapabilities.semanticKeys)
        }
        suspend fun currentInputTarget(): Boolean = currentInputTargetProof() == AgentInputTargetProof.PROVEN
        val capability = endpoint.capabilities.value
        if (!capability.verifiedInput || !capability.semanticKeys) {
            refuse("unavailable", AgentNotSentReason.INPUT_UNAVAILABLE)
            return
        }
        val result = when (pending.kind) {
            "send", "queue" -> executeTextAction(
                lease, detail, pending, actionPayload, endpoint, leasedBinding, leaseProvider, freshAuthority,
                freshBindingToken, writes, refresh, preflightPolicy,
                refuse = { legacyCode, reason, attempts, composerRefusal ->
                    refuse(legacyCode, reason, attempts, composerRefusal)
                    null
                },
                sendTiming = ::sendTiming,
                currentInputTargetProof = { currentInputTargetProof(it) },
                currentInputTarget = { currentInputTarget() },
                preWriteRefusal = ::preWriteRefusal,
                preWriteFailure = ::preWriteFailure,
            ) ?: return
            "interrupt" -> executeInterruptAction(
                lease, actionPayload, endpoint, leasedBinding, writes,
                currentInputTarget = { currentInputTarget() },
                preWriteFailure = ::preWriteFailure,
            ) ?: return
            "answerPrompt" -> executePromptAnswerAction(
                lease, detail, pending, actionPayload, endpoint, leasedBinding, freshBindingToken, writes,
                currentInputTarget = { currentInputTarget() },
                preWriteFailure = ::preWriteFailure,
            ) ?: return
            "openTerminal" -> {
                if (actionPayload?.optJSONObject("targetBinding")?.sameCoreBinding(lease.optJSONObject("binding")) != true) {
                    return finishAction(lease, "verificationFailed")
                }
                ensureActionActive()
                endpoint.focus(leasedBinding)
            }
            else -> AgentEndpointResult.Unavailable("unsupported action")
        }
        val code = when (result) {
            is AgentEndpointResult.Success -> "success"
            AgentEndpointResult.StaleBinding -> "staleBinding"
            is AgentEndpointResult.Unavailable -> "unavailable"
            is AgentEndpointResult.Failed -> result.code
        }
        finishAction(lease, code, freshBindingToken)
    }

    /**
     * A send or queue lease: arms the receipt, then delivers the planned text
     * behind the composer guard. Null once [refuse] has finished the lease.
     */
    private suspend fun executeTextAction(
        lease: JSONObject,
        detail: AgentThreadDetail,
        pending: PendingAction,
        actionPayload: JSONObject?,
        endpoint: AgentSessionEndpoint,
        leasedBinding: AgentEndpointBinding,
        leaseProvider: String,
        freshAuthority: AgentIssuedBinding,
        freshBindingToken: String,
        writes: AgentTerminalWriteLatch,
        refresh: AgentRouteBindingRefresh<*>,
        preflightPolicy: AgentSendPreflightPolicy,
        refuse: (legacyCode: String, reason: AgentNotSentReason, attempts: Int?, composerRefusal: Boolean) -> Nothing?,
        sendTiming: (String) -> Unit,
        currentInputTargetProof: suspend (timeoutMillis: Long) -> AgentInputTargetProof,
        currentInputTarget: suspend () -> Boolean,
        preWriteRefusal: () -> AgentNotSentReason?,
        preWriteFailure: () -> AgentEndpointResult.Failed?,
    ): AgentEndpointResult<Unit>? {
        val planned = actionPayload?.optJSONObject("text")
        val text = planned?.optString("text")?.takeIf { it == pending.text }
            ?: return refuse("verificationFailed", AgentNotSentReason.PLAN_MISMATCH, null, false)
        if (planned.optBoolean("queueWhenWorking") != (pending.kind == "queue") ||
            planned.optString("composerVerification", "required") !=
                (if (pending.bypassComposerVerification) "userOverride" else "required")) {
            return refuse("verificationFailed", AgentNotSentReason.PLAN_MISMATCH, null, false)
        }
        // Known provider editors accept bracketed-paste events. Raw
        // newlines must never be sent as separate terminal commands.
        if (!text.isSafeTerminalInsert() || ('\n' in text && leaseProvider !in setOf("codex", "claude"))) {
            return refuse("unsupported_multiline_input", AgentNotSentReason.UNSUPPORTED_INPUT, null, false)
        }
        val source = projectionSources[detail.row.key]
        if (source != null && (source.endpointKey != endpoint.key || !source.binding.sameRouteAs(leasedBinding) || source.provider != leaseProvider)) {
            return refuse("staleBinding", AgentNotSentReason.ROUTE_CHANGED, null, false)
        }
        suspend fun outgoingPhase(kind: String, frontier: JSONObject? = null) {
            val replyCode = if (kind == "armOutgoing") "outgoingArmed" else "outgoingDispatched"
            val key = "${lease.getString("token")}:$replyCode"
            val accepted = kotlinx.coroutines.CompletableDeferred<Boolean>()
            outgoingArms[key] = accepted
            try {
                check(forward(JSONObject().put("v", 1).put("kind", kind).put("lease", lease)
                    .put("bindingToken", freshBindingToken).putOpt("frontier", frontier)) &&
                    withTimeoutOrNull(2_000) { accepted.await() } == true) { "receipt_baseline_unavailable" }
            } finally { outgoingArms.remove(key)?.cancel() }
        }
        // Source observation is independent of selected.operation,
        // bootstrap, history prefetch, and native index preparation.
        // A missing/slow observer does not prevent guarded delivery.
        val leaseThread = lease.getJSONObject("threadID")
        val unavailable = JSONObject().put("version", 1).put("actionID", lease.getString("token"))
            .put("provider", leaseProvider).put("providerSessionID", leaseThread.getString("providerSessionID"))
            .put("consistency", "unavailable")
        // A foreign cancellation (closing the ingestion connection
        // cancels its pending requests) is an unavailable frontier,
        // exactly as a missed read is; only the action's own propagates.
        val frontier = agentOptionalRead(unavailable = { failure ->
            diagnostics?.invoke("agent_send_frontier_unavailable", AgentIngestionDiagnostics.failure(failure))
            unavailable
        }) {
            withTimeoutOrNull(2_000) {
                if (source == null) return@withTimeoutOrNull unavailable
                val context = freshAuthority.coreBinding
                val (host, connection) = nativeConnection(endpoint, context.optInt("agentPID", -1).takeIf { it > 1 },
                    context.optJSONObject("incarnation")?.optString("rawValue") ?: "")
                val existing = host.threads[detail.row.key]?.handle
                val handle = existing ?: run {
                    val nativeLocator = source.provider in setOf("codex", "opencode") && source.transcriptRef.startsWith("native:")
                    val resolved = connection.request(JSONObject().put("kind", "resolve").put("provider", source.provider)
                        .put(if (nativeLocator) "nativeSessionID" else "transcriptRef",
                            if (nativeLocator) source.transcriptRef.removePrefix("native:") else source.transcriptRef))
                    check(resolved.end.optString("provider") == leaseProvider &&
                        resolved.end.optString("sessionID") == leaseThread.getString("providerSessionID")) { "contextIdentityConflict" }
                    resolved.end.getString("thread")
                }
                val reply = connection.request(JSONObject().put("kind", "receipt.frontier").put("thread", handle)
                    .put("actionID", lease.getString("token")), timeoutMillis = 2_000)
                requireCurrentNativeConnection(host, connection)
                val observed = reply.end.getJSONObject("frontier")
                check(observed.optString("actionID").equals(lease.getString("token"), ignoreCase = true) &&
                    observed.optString("serviceEpoch") == connection.epoch && observed.optString("provider") == leaseProvider &&
                    observed.optString("providerSessionID") == leaseThread.getString("providerSessionID")) { "staleBinding" }
                observed
            } ?: unavailable
        }
        // Arming precedes the final process/composer proof so a fast
        // receipt cannot be missed; nothing has been written yet, so a
        // baseline that cannot be armed is a clean refusal.
        val armed = try {
            outgoingPhase("armOutgoing", frontier)
            outgoingPhase("outgoingDispatched")
            true
        } catch (failure: Exception) {
            if (agentThrowIsCancellation(failure, currentCoroutineContext().isActive)) throw failure
            false
        }
        if (!armed) return refuse("receipt_baseline_unavailable", AgentNotSentReason.RECEIPT_UNAVAILABLE, null, false)
        sendTiming("receipt_ready")
        fun composer(observation: com.bambouville.tessera.agent.platform.AgentTerminalObservation, requireEmpty: Boolean = false, literalImagePathsOnly: Boolean = false) =
            SharedAgentComposerEvidence.assess(
                leaseProvider, observation.visibleTail.decodeToString(), observation.currentCursorLine, text, pending.kind == "queue",
                cursorRow = observation.cursorRow,
                safetyOnly = leaseProvider in setOf("codex", "claude"), requireEmpty = requireEmpty, cursorVisible = observation.cursorVisible,
                cursorColumn = observation.cursorColumn,
                screen = observation.screenEvidence, literalImagePathsOnly = literalImagePathsOnly,
            )
        val ready = setOf(Assessment.RETURN, Assessment.TAB)
        var targetProvenOnce = false
        val delivery = deliverAgentGuardedText(object : AgentTextDeliveryPort {
            override suspend fun ensureActive() = ensureActionActive()
            override suspend fun proveInputTarget(timeoutMillis: Long) = currentInputTargetProof(timeoutMillis).also { proof ->
                if (proof == AgentInputTargetProof.PROVEN && !targetProvenOnce) { targetProvenOnce = true; sendTiming("text_target_proven") }
            }
            override suspend fun inspect(timeoutMillis: Long) =
                (withTimeoutOrNull(timeoutMillis) { endpoint.inspect(leasedBinding) } as? AgentEndpointResult.Success)?.value
            override fun assessEmptyComposer(observation: com.bambouville.tessera.agent.platform.AgentTerminalObservation) =
                composer(observation, requireEmpty = true)
            override fun insertion() = SharedAgentComposerEvidence.insertion(leaseProvider, text)
            override fun writeRefusal() = preWriteRefusal()?.also { refusal ->
                diagnostics?.invoke("agent_composer_guard_refused", mapOf("stage" to "before_insert",
                    "reason" to refusal.code, "written" to "false"))
            }
            override suspend fun write(input: ByteArray) = endpoint.sendInput(leasedBinding, input).also {
                if (it is AgentEndpointResult.Success) sendTiming("text_write_ack")
            }
            override suspend fun submit(): AgentEndpointResult<Unit> {
                if (pending.bypassComposerVerification) {
                    // Give image paths time to become attachments without refusing an explicit override.
                    if (leaseProvider in setOf("claude", "codex") && agentDraftAttachesImages(text)) {
                        awaitObservation(endpoint, leasedBinding, attempts = if (leaseProvider == "claude") 40 else 20,
                            budgetMillis = AGENT_OVERRIDE_IMAGE_WAIT_MILLIS, beforeInspect = { currentInputTarget() }) {
                            it.authoritative && !it.truncated && composer(it) in ready
                        }
                    }
                    // The explicit choice bypasses composer recognition only;
                    // the route, process and transport gate still precede the key.
                    if (!currentInputTarget()) return AgentEndpointResult.Failed("staleBinding")
                    ensureActionActive()
                    preWriteFailure()?.let { return it }
                    val key = if (leaseProvider == "codex" && pending.kind == "queue") AgentSemanticKey.TAB else AgentSemanticKey.RETURN
                    return endpoint.sendSemanticKey(leasedBinding, key).also {
                        if (it is AgentEndpointResult.Success) sendTiming("submit_key_ack")
                    }
                }
                // Claude reads each attached image before it shows the marker.
                val claudeImages = leaseProvider == "claude" && agentDraftAttachesImages(text)
                var literalImagePathsOnly = false
                var observed = awaitObservation(endpoint, leasedBinding, attempts = if (claudeImages) 40 else 20, beforeInspect = {
                    currentInputTarget().also { if (it) sendTiming("key_target_proven") }
                }) { it.authoritative && !it.truncated && composer(it) in ready }
                if (observed == null && claudeImages) {
                    // The full upload wait is exhausted. Only an unchanged
                    // literal draft earns the shared plain-text fallback.
                    observed = awaitObservation(endpoint, leasedBinding, attempts = 1,
                        beforeInspect = { currentInputTarget() }) {
                        it.authoritative && !it.truncated && composer(it, literalImagePathsOnly = true) in ready
                    }
                    literalImagePathsOnly = observed != null
                }
                val safeAfter = observed?.let { composer(it, literalImagePathsOnly = literalImagePathsOnly) }
                if (observed == null || !observed.authoritative || observed.truncated || safeAfter !in ready) {
                    diagnostics?.invoke("agent_composer_guard_refused", mapOf("stage" to "before_submit",
                        "reason" to (safeAfter?.name?.lowercase() ?: "capture_unavailable"), "written" to "true"))
                    return AgentEndpointResult.Failed("terminal_input_not_ready")
                }
                val key = if (safeAfter == Assessment.TAB) AgentSemanticKey.TAB else AgentSemanticKey.RETURN
                ensureActionActive()
                preWriteFailure()?.let { return it }
                val sent = endpoint.sendSemanticKey(leasedBinding, key)
                if (sent !is AgentEndpointResult.Success) return sent
                sendTiming("submit_key_ack")
                // Claude can swallow Return while reading an image.
                // Shared presence recognizes the rendered markers too.
                if (claudeImages && !literalImagePathsOnly && awaitObservation(endpoint, leasedBinding,
                        attempts = 40, beforeInspect = { currentInputTarget() }) { after ->
                        agentComposerDeparted(after, SharedAgentComposerEvidence.assess(leaseProvider,
                            after.visibleTail.decodeToString(), after.currentCursorLine, text, pending.kind == "queue",
                            cursorRow = after.cursorRow))
                    } == null) return AgentEndpointResult.Failed("verificationFailed")
                return sent
            }
        }, writes, knownEditor = leaseProvider in setOf("codex", "claude"), policy = refresh.remainingPolicy(preflightPolicy),
            bypassComposerVerification = pending.bypassComposerVerification)
        return when (delivery) {
            is AgentTextDeliveryResult.NotSent -> {
                if (delivery.reason == AgentNotSentReason.INPUT_NOT_READY || delivery.reason == AgentNotSentReason.TERMINAL_DRAFT ||
                    delivery.last == AgentInputSurfaceSample.TargetUnproven) {
                    diagnostics?.invoke("agent_composer_guard_refused", agentComposerGuardFields(delivery.last, delivery.attempts))
                }
                return refuse(when (delivery.reason) {
                    AgentNotSentReason.ROUTE_CHANGED -> "staleBinding"
                    AgentNotSentReason.TERMINAL_DRAFT -> "terminal_has_unsent_draft"
                    AgentNotSentReason.UNSUPPORTED_INPUT -> "invalid_input"
                    else -> "terminal_input_not_ready"
                }, delivery.reason, delivery.attempts, delivery.canSkipComposerVerification(leaseProvider))
            }
            is AgentTextDeliveryResult.Attempted -> {
                if (delivery.attempts > 1) {
                    diagnostics?.invoke("agent_send_input_settled", mapOf("attempts" to delivery.attempts.toString()))
                }
                delivery.result
            }
        }
    }

    /** An interrupt lease: Escape against a settled baseline. Null once the lease is finished. */
    private suspend fun executeInterruptAction(
        lease: JSONObject,
        actionPayload: JSONObject?,
        endpoint: AgentSessionEndpoint,
        leasedBinding: AgentEndpointBinding,
        writes: AgentTerminalWriteLatch,
        currentInputTarget: suspend () -> Boolean,
        preWriteFailure: () -> AgentEndpointResult.Failed?,
    ): AgentEndpointResult<Unit>? {
        suspend fun inspectInputSurface(): com.bambouville.tessera.agent.platform.AgentTerminalObservation? {
            val first = (endpoint.inspect(leasedBinding) as? AgentEndpointResult.Success)?.value ?: return null
            if (!first.captureWaitedForFrame) return first
            // Frame readiness can outlive a process. Refresh authority, then
            // accept only an immediate capture; do not age that proof again.
            if (!currentInputTarget()) return null
            val fresh = (endpoint.inspect(leasedBinding) as? AgentEndpointResult.Success)?.value ?: return null
            return fresh.takeUnless { it.captureWaitedForFrame }
        }
        if (actionPayload?.optJSONObject("targetBinding")?.sameCoreBinding(lease.optJSONObject("binding")) != true) {
            return finishActionEarly(lease, "verificationFailed")
        }
        if (!currentInputTarget()) return finishActionEarly(lease, "staleBinding")
        // A blank baseline would make any later frame "different":
        // settle one with text first, or send no Escape at all.
        val before = agentSettledBaseline { budget -> withTimeoutOrNull(budget) { inspectInputSurface() } }
            ?: return finishActionEarly(lease, "verificationFailed")
        if (!currentInputTarget()) return finishActionEarly(lease, "staleBinding")
        ensureActionActive()
        preWriteFailure()?.let { return finishActionEarly(lease, it.code) }
        val sent = writes.attempt { endpoint.sendSemanticKey(leasedBinding, AgentSemanticKey.ESCAPE) }
        return if (sent !is AgentEndpointResult.Success) sent
        else if (awaitObservation(endpoint, leasedBinding) { agentInterruptObserved(before, it) } == null
        ) AgentEndpointResult.Failed("verification_failed")
        else AgentEndpointResult.Success(Unit)
    }

    /** An answerPrompt lease: Core's planner steps, each checked before its write. Null once the lease is finished. */
    private suspend fun executePromptAnswerAction(
        lease: JSONObject,
        detail: AgentThreadDetail,
        pending: PendingAction,
        actionPayload: JSONObject?,
        endpoint: AgentSessionEndpoint,
        leasedBinding: AgentEndpointBinding,
        freshBindingToken: String,
        writes: AgentTerminalWriteLatch,
        currentInputTarget: suspend () -> Boolean,
        preWriteFailure: () -> AgentEndpointResult.Failed?,
    ): AgentEndpointResult<Unit>? {
        val planned = actionPayload?.optJSONObject("promptAnswer")
            ?: return finishActionEarly(lease, "verificationFailed")
        val token = pending.actionToken ?: return finishActionEarly(lease, "verificationFailed")
        val optionID = pending.optionID ?: return finishActionEarly(lease, "verificationFailed")
        val signature = pending.promptSignature ?: return finishActionEarly(lease, "verificationFailed")
        if (planned.optJSONObject("actionToken")?.optString("rawValue") != token || planned.optString("optionID") != optionID ||
            planned.optString("expectedSignature") != signature ||
            planned.optString("text").takeIf { planned.has("text") } != pending.promptText ||
            planned.optString("control").takeIf { planned.has("control") } != pending.control ||
            planned.optJSONObject("binding")?.sameCoreBinding(lease.optJSONObject("binding")) != true
        ) return finishActionEarly(lease, "verificationFailed")
        val provider = detail.row.providerID
        val display = detail.prompt?.takeIf { it.actionToken == token }?.options
            ?: return finishActionEarly(lease, "verificationFailed")
        if (!currentInputTarget()) return finishActionEarly(lease, "staleBinding")
        val goal = when {
            pending.control != null -> JSONObject().put("kind", "control").put("control", pending.control)
            pending.promptText != null -> JSONObject().put("kind", "text").put("text", pending.promptText)
            else -> JSONObject().put("kind", "option").put("optionID", optionID)
        }
        // The plan was made for the prompt that waited when Core granted
        // this lease. A transition accepted since (that question closed,
        // the next one asked, the turn over) means the bytes would answer
        // another. Core is asked before each write; its reply carries the
        // question input count it was asked at, or null for a refusal.
        val threadKey = detail.row.key
        suspend fun promptCheck(): Long? {
            val token = lease.getString("token")
            val reply = kotlinx.coroutines.CompletableDeferred<Boolean>()
            promptAnswerChecks[token] = reply
            return try {
                val askedAt = synchronized(questionInputLock) {
                    if (!forward(JSONObject().put("v", 1).put("kind", "promptAnswerCurrent").put("lease", lease)
                            .put("bindingToken", freshBindingToken))) null
                    else questionInputs[threadKey] ?: 0L
                } ?: return null
                askedAt.takeIf { withTimeoutOrNull(2_000) { reply.await() } == true }
            } finally { promptAnswerChecks.remove(token, reply) }
        }
        var anchor: JSONObject? = null
        val history = mutableListOf<String>()
        var outcome: AgentEndpointResult<Unit> = AgentEndpointResult.Failed("verification_failed")
        for (stepIndex in 0..24) {
            val input = JSONObject().put("goal", goal).put("expectedSignature", signature)
                .putOpt("anchor", anchor).put("history", JSONArray(history))
            val read = settledFreshPrompt(endpoint, leasedBinding, detail.row.key, token, provider, display, input)
            if (read == null) {
                // The readiness window already retried unavailable captures.
                // Exhaustion must settle the lease, including after a write;
                // only a parsed planner wait may extend the answer sequence.
                outcome = AgentEndpointResult.Failed("verification_failed")
                break
            }
            val step = read.plan
            if (step == null) {
                outcome = AgentEndpointResult.Failed("verification_failed")
                break
            }
            anchor = step.anchor?.toJson()
            when (step.action) {
                "done" -> { outcome = AgentEndpointResult.Success(Unit); break }
                "refuse" -> { outcome = AgentEndpointResult.Failed(promptPlanRefusalCode(step.refusal)); break }
                "wait" -> history += "wait"
                "send" -> {
                    val bytes = step.bytes
                    val phase = step.phase
                    if (bytes.isNullOrEmpty() || phase == null ||
                        phase !in setOf("select", "confirm", "focus", "navigate", "type", "submit", "control")) {
                        outcome = AgentEndpointResult.Failed("verification_failed")
                        break
                    }
                    // Proven after the capture this step was planned on: an
                    // agent that exited meanwhile leaves its shell in the
                    // pane, which must not get the keys. Core is asked
                    // last, so only its local reply sits between the count
                    // and the write; question input that arrived during it
                    // is behind the check in Core's queue: ask again.
                    var admitted: Boolean? = false
                    for (attempt in 0 until 3) {
                        if (!currentInputTarget()) { admitted = null; break }
                        ensureActionActive()
                        val askedAt = promptCheck() ?: break
                        if (questionInputCount(threadKey) == askedAt) { admitted = true; break }
                    }
                    if (admitted == null) { outcome = AgentEndpointResult.StaleBinding; break }
                    if (admitted == false) { outcome = AgentEndpointResult.Failed("stalePrompt"); break }
                    val refusal = preWriteFailure()
                    if (refusal != null) { outcome = refusal; break }
                    val sent = writes.attempt { sendAgentPromptStep(endpoint, leasedBinding, bytes, step.semanticKey) }
                    if (sent !is AgentEndpointResult.Success) { outcome = sent; break }
                    history += phase
                }
                else -> { outcome = AgentEndpointResult.Failed("verification_failed"); break }
            }
            if (stepIndex == 24) break
            delay(120)
        }
        return outcome
    }

    /** [finishAction] for a lease a per-kind step settles before it has a result. */
    private fun finishActionEarly(lease: JSONObject, code: String): Nothing? {
        finishAction(lease, code)
        return null
    }

    private suspend fun ensureActionActive() {
        requireAgentActionLifetime(enabled, runtime != null)
    }

    private suspend fun awaitObservation(
        endpoint: AgentSessionEndpoint,
        binding: AgentEndpointBinding,
        attempts: Int = 20,
        budgetMillis: Long = AGENT_OBSERVATION_BUDGET_MILLIS,
        beforeInspect: suspend () -> Boolean = { true },
        predicate: (com.bambouville.tessera.agent.platform.AgentTerminalObservation) -> Boolean,
    ): com.bambouville.tessera.agent.platform.AgentTerminalObservation? = agentBoundedPoll(attempts = attempts, budgetMillis = budgetMillis) {
        // Bounded in time as well as count: a read whose tmux ack stalls
        // fails only after 15 s, and the lease is held throughout.
        ensureActionActive()
        if (!beforeInspect()) return@agentBoundedPoll AgentPoll.GiveUp
        var observed = endpoint.inspect(binding)
        if (observed is AgentEndpointResult.Success && observed.value.captureWaitedForFrame) {
            if (!beforeInspect()) return@agentBoundedPoll AgentPoll.GiveUp
            observed = endpoint.inspect(binding)
        }
        agentObservationPoll((observed as? AgentEndpointResult.Success)?.value, predicate)
    }

    private fun finishAction(
        lease: JSONObject,
        code: String,
        bindingToken: String? = agentLeaseThreadKey(lease)?.let { key -> lease.optJSONObject("binding")?.tokenKey(key)?.let(bindingTokens::get) },
        threadKey: String? = agentLeaseThreadKey(lease),
    ) {
        releasePendingAction(lease, threadKey)
        diagnostics?.invoke("agent_action_finished", mapOf("action" to lease.optString("action"), "result" to code))
        agentActionResultNotice(code)?.let { mutableState.value = mutableState.value.copy(notice = it) }
        // Result is itself binding-authorized in ABI v1. If the carrier has
        // already invalidated all authority, fail closed rather than smuggling
        // a stale result over the generic command channel.
        if (bindingToken == null) {
            mutableState.value = mutableState.value.copy(notice = "Terminal action proof is unavailable")
            return
        }
        forward(JSONObject().put("v", 1).put("kind", "result").put("bindingToken", bindingToken).put("lease", lease)
            .putOpt("resultOutcome", agentActionResultOutcome(lease.optString("action"), code)))
    }

    private fun releasePendingAction(lease: JSONObject, threadKey: String?) {
        pendingActions.entries.removeIf { (key, pending) -> agentFinishReleasesPending(key, pending.kind, pending.binding, lease, threadKey, pending.leaseToken) }
        publishSendingThreads()
    }

    /**
     * Finishes a send/queue that provably admitted no input. Core drops the outgoing bubble
     * (`notSent`) rather than showing an ambiguous "check terminal" receipt,
     * and the message returns to the composer once a snapshot shows the bubble
     * withdrawn ([settleNotSent]): a queued result is not an accepted one.
     * When Core cannot take the `notSent` result its bubble survives, so the
     * refusal finishes with the ambiguous [legacyCode] instead and the
     * composer is left alone.
     */
    private fun finishNotSent(
        lease: JSONObject,
        detail: AgentThreadDetail,
        reason: AgentNotSentReason,
        legacyCode: String,
        text: String?,
        draftCleared: Boolean,
        actionRuntime: SharedAgentRuntime?,
        attempts: Int? = null,
        bindingToken: String? = actionBindingTokens[lease.optString("token")] ?: pendingActions[detail.row.key]?.bindingToken,
    ) {
        val action = lease.optString("action")
        val currentRuntime = runtime
        if (!enabled || currentRuntime == null || currentRuntime !== actionRuntime) {
            // Disabled (or replaced) since the send started: the draft and its
            // notice went with it, and the lease belongs to no live runtime.
            releasePendingAction(lease, detail.row.key)
            return
        }
        val providerID = detail.row.providerID.ifEmpty {
            lease.optJSONObject("threadID")?.optJSONObject("providerID")?.optString("rawValue").orEmpty()
        }
        val wait = AgentNotSentWait(AgentPendingNotSent(detail.row.key, lease.optString("token"), action, text, reason,
            agentNoticeProviderName(providerID, detail.row.provider), legacyCode, draftCleared), currentRuntime, lease, bindingToken)
        // Withdrawal uses the original authenticated lease even after rebind.
        val forwarded = agentQueueNotSent(
            register = { notSentLedger.register(wait)?.let { notSentClocks.remove(it)?.cancel() } },
            forward = { bindingToken != null && forward(agentNotSentResultCommand(lease, bindingToken, action, reason)) },
            release = { releasePendingAction(lease, detail.row.key) },
            abandon = { notSentLedger.abandon(wait) },
        )
        val finish = agentNotSentFinish(forwarded, legacyCode)
        diagnostics?.invoke("agent_send_not_sent", agentNotSentDiagnosticFields(action, reason, attempts, finish))
        if (finish == AgentNotSentFinish.Forwarded) {
            if (actionJobs[lease.optString("token")]?.conversationRemoved == true && bindingToken != null) {
                settleRemovedConversation(detail.row.key, bindingToken)
            } else startNotSentClock(wait)
        }
        if (finish is AgentNotSentFinish.Ambiguous) {
            composerRefusals.remove(lease.optString("token"))
            // Teardown already unbound the thread (its bubble is unconfirmed):
            // it was not withdrawn. The legacy result settles a live lease
            // and fails closed without authority, exactly as before notSent.
            finishAction(lease, finish.legacyCode, bindingToken, detail.row.key)
        }
    }

    private fun settleRemovedConversation(threadKey: String, bindingToken: String) {
        // Core removed this conversation and its bubble; its result has no thread snapshot.
        notSentLedger.settleRemovedConversation(threadKey, bindingToken)?.let {
            applyNotSentSettlement(it, AgentNotSentSettlement.RETURN_DRAFT, source = "routeRetired")
        }
    }

    /** Settles this thread's queued `notSent`, and returns a late-watched one, from its own snapshot. */
    private fun settleNotSent(detail: AgentThreadDetail, evidence: AgentNotSentEvidence) {
        notSentLedger.settleLate(detail)?.let { applyNotSentSettlement(it, AgentNotSentSettlement.RETURN_DRAFT, source = "late") }
        val (wait, settlement) = notSentLedger.settle(detail, evidence) ?: return
        applyNotSentSettlement(wait, settlement, source = evidence.name.lowercase())
    }

    /** Runs [body] as [wait]'s only clock, replacing (and cancelling) any earlier one. */
    private fun launchNotSentClock(wait: AgentNotSentWait, body: suspend () -> Unit) {
        val clock = scope.launch(start = CoroutineStart.LAZY) {
            try { body() } finally { coroutineContext[Job]?.let { notSentClocks.remove(wait, it) } }
        }
        notSentClocks.put(wait, clock)?.cancel()
        clock.start()
    }

    /**
     * Bounds a queued `notSent` whose verdict never shows (its snapshot was
     * dropped from the event buffer or too large to deliver, or Core answered
     * only with an unattributed rejection): it asks Core once more, then
     * settles from the thread's latest snapshot.
     */
    private fun startNotSentClock(wait: AgentNotSentWait) {
        if (!notSentLedger.isWaiting(wait)) return
        val tick = notSentLedger.policy.tickMillis
        launchNotSentClock(wait) {
            do { delay(tick) } while (advanceNotSent(wait, tick))
        }
    }

    /** One fallback step for [wait]; false once it no longer waits. */
    private fun advanceNotSent(wait: AgentNotSentWait, advancedMillis: Long): Boolean {
        val step = notSentLedger.advance(wait, advancedMillis,
            probeAllowed = agentNotSentProbeAllowed(wait.threadKey, pendingActions.keys)) ?: return false
        when (step) {
            AgentNotSentFallbackStep.WAIT -> Unit
            AgentNotSentFallbackStep.PROBE -> {
                val bindingToken = wait.bindingToken
                val probed = enabled && runtime === wait.owner && bindingToken != null &&
                    forward(agentNotSentResultCommand(wait.lease, bindingToken, wait.pending.action, wait.pending.reason))
                diagnostics?.invoke("agent_send_not_sent_probe", mapOf("action" to wait.pending.action,
                    "forwarded" to probed.toString(), "afterRejection" to wait.probeRequested.toString()))
            }
            AgentNotSentFallbackStep.SETTLE -> {
                applyNotSentSettlement(wait, notSentLedger.settleByFallback(wait, mutableState.value.projectedDetails[wait.threadKey]),
                    source = "fallback")
                return false
            }
        }
        return true
    }

    /**
     * Withdrawn: the message goes back to the composer. Rejected or kept: the
     * ambiguous legacy notice, composer alone (Core already revoked or keeps
     * the lease, so no second result is sent); a watched one may still come
     * back if a later snapshot shows the bubble gone. Resent: nothing to do.
     */
    private fun applyNotSentSettlement(wait: AgentNotSentWait, settlement: AgentNotSentSettlement, source: String) {
        notSentClocks.remove(wait)?.cancel()
        // Disabled or replaced since: the draft and its notice went with it,
        // and nothing is watched for a runtime that no longer owns it.
        if (!enabled || runtime !== wait.owner) {
            notSentLedger.expireLate(wait)
            return
        }
        if (settlement == AgentNotSentSettlement.AMBIGUOUS_WATCH) {
            // Bounded: past the cap a withdrawal is no longer looked for.
            launchNotSentClock(wait) {
                delay(notSentLedger.policy.lateWatchMillis)
                notSentLedger.expireLate(wait)
                composerRefusals.remove(wait.pending.leaseToken)
            }
        }
        val pending = wait.pending
        diagnostics?.invoke("agent_send_not_sent_settled", mapOf("action" to pending.action,
            "reason" to pending.reason.code, "settlement" to settlement.name.lowercase(), "source" to source))
        diagnostics?.invoke("agent_action_finished", mapOf("action" to pending.action, "result" to when (settlement) {
            AgentNotSentSettlement.RETURN_DRAFT, AgentNotSentSettlement.RESENT -> "notSent"
            else -> pending.legacyCode
        }))
        val draftBeforeReturn = mutableState.value.drafts[pending.threadKey].orEmpty()
        val mergedOnReturn = settlement == AgentNotSentSettlement.RETURN_DRAFT && pending.text?.let {
            agentDraftWithUnsentMessage(draftBeforeReturn, it, pending.draftCleared).second == AgentUnsentDraft.MERGED
        } == true
        mutableState.value = mutableState.value.withSettledNotSent(pending, settlement)
        // An ambiguous result cannot offer a retry. Keep its pre-write facts
        // while the bounded late watch can still prove bubble withdrawal.
        val candidate = if (settlement == AgentNotSentSettlement.AMBIGUOUS_WATCH) composerRefusals[pending.leaseToken]
            else composerRefusals.remove(pending.leaseToken)
        val detail = mutableState.value.projectedDetails[pending.threadKey]
            ?: mutableState.value.detail?.takeIf { it.row.key == pending.threadKey }
        val draftSnapshot = mutableState.value.drafts[pending.threadKey].orEmpty()
        // A prefix can be a user revision that arrived before the first plan.
        // Only the exact original or our own known merge is eligible to retry.
        if (settlement == AgentNotSentSettlement.RETURN_DRAFT && candidate != null && detail != null &&
            (draftSnapshot == pending.text || mergedOnReturn) && sendAnywayTargetIsCurrent(candidate, detail)) {
            val notice = mutableState.value.notice.orEmpty() + " Send anyway skips prompt verification."
            val draftRemainder = if (mergedOnReturn) draftBeforeReturn else ""
            sendAnywayCandidate = candidate.copy(notice = notice, draftSnapshot = draftSnapshot, draftRemainder = draftRemainder)
            mutableState.value = mutableState.value.copy(notice = notice, sendAnywayNotice = notice)
        }
    }

    override fun close() {
        enabled = false
        titleGenerationJob?.cancel()
        titleGenerator?.close()
        deactivate()
    }

    private fun cancelProjectionReads() {
        initialPrefetchJobs.keys.toList().forEach(::cancelInitialPrefetch)
        pendingProjectionRefreshes.clear()
        pendingHistoryRequests.clear()
        pendingFillRequests.clear()
        pendingLatestRequests.clear()
        pendingSeekRequests.clear()
        dropSearchLanding()
        // Retire ownership first: a cancellation finally block must not drain
        // old demand or remove a replacement job installed after foregrounding.
        val retired = projectionJobs.values.toList()
        projectionJobs.clear()
        retired.forEach(Job::cancel)
        mutableState.value = mutableState.value.copy(loadingTranscriptThreads = emptySet())
    }

    private fun deactivate() {
        mutablePaneAgentProviders.value = emptyMap()
        cancelPromptObservations()
        cancelProjectionReads()
        closeIngestionHosts()
        readRetryFailures.clear()
        ingestionScopes.clear()
        attachmentSelection = null
        attachmentJobs.values.toList().forEach(Job::cancel); attachmentJobs.clear()
        actionJobs.values.forEach { it.job.cancel() }; actionJobs.clear()
        notSentLedger.clear()
        invalidateSendAnyway()
        composerRefusals.clear()
        notSentClocks.values.forEach(Job::cancel); notSentClocks.clear()
        outgoingArms.values.forEach { it.cancel() }; outgoingArms.clear()
        promptAnswerChecks.values.forEach { it.cancel() }; promptAnswerChecks.clear()
        readerPlaceChecks.values.forEach { it.cancel() }; readerPlaceChecks.clear()
        readerPlaces.clear(); viewportAnchors.clear()
        synchronized(presentationHoldLock) { presentationHolds.clear(); heldDetails.clear() }
        synchronized(questionInputLock) { questionInputs.clear(); questionScreens.clear() }
        observer?.cancel(); observer = null
        sessionObserver?.cancel(); sessionObserver = null
        integrationEventObserver?.cancel(); integrationEventObserver = null
        viewPreferencesObserver?.cancel(); viewPreferencesObserver = null
        lifecycleProofRetries.clear()
        occupancySweepJobs.values.forEach(Job::cancel); occupancySweepJobs.clear(); occupancySweepLocks.clear()
        occupancyRetirements.values.forEach { it.cancel() }; occupancyRetirements.clear()
        pendingOwners.values.forEach { it.accepted.cancel() }; pendingOwners.clear(); ownerBindingLocks.clear()
        firstProjectionRetryJobs.values.forEach(Job::cancel); firstProjectionRetryJobs.clear(); firstProjectionRetryTokens.clear()
        retiredOwnerThreads.clear()
        retiredObservationTokens.clear()
        endedConversations.clear()
        endpointObservers.values.forEach(Job::cancel); endpointObservers.clear()
        tierACandidateJobs.values.forEach(Job::cancel); tierACandidateJobs.clear()
        tierACandidateBindings.forEach { (key, binding) -> removeTierACandidates(key, binding) }
        tierACandidateBindings.clear(); tierACandidates.clear()
        tierCInventoryJobs.values.forEach(Job::cancel); tierCInventoryJobs.clear(); tierCInventoryBindings.clear(); tierCConformances.clear()
        livePromptWatchJobs.values.forEach(Job::cancel); livePromptWatchJobs.clear()
        latestPromptLifecycleSequence.clear(); latestPromptLifecycleNanos.clear()
        pendingTerminalReads.clear()
        directoryProofs.clear(); acknowledgedRecords.clear(); persistedCompletionKeys.clear(); acknowledgedCompletionEpochs.clear()
        searchJob?.cancel(); searchJob = null; projectionSources.clear()
        presentedSearchNeedle = ""; presentedSearchResults = JSONArray()
        bindingTokens.clear(); threadOwners.clear(); pendingActions.clear(); pendingActionRequests.clear(); actionBindingTokens.clear()
        actionRequestOrderReliable.set(true); lastRuntimeEventGeneration = 0L
        candidateActionsInFlight.clear(); deliveredAttention.clear(); runtime = null
        pendingLaunch = null; pendingLifecycleLaunches.clear()
        attentionNotifier?.withdrawAll()
        SharedAgentMarkdown.clearCache()
        coordinator.resetRuntime()
        mutableState.value = AgentCenterUiState(loading = false, unavailableReason = "Agent Center is disabled")
    }

    private class ActionJob(
        val threadKey: String,
        val bindingToken: String?,
        val writes: AgentTerminalWriteLatch,
        val job: Job,
    ) {
        @Volatile var routeChanged = false
        @Volatile var conversationRemoved = false
    }

    private data class SendAnywayCandidate(
        val threadKey: String,
        val kind: String,
        val text: String,
        val binding: JSONObject,
        val bindingToken: String,
        val generation: Long,
        val runtime: SharedAgentRuntime,
        val leaseToken: String,
        val notice: String? = null,
        val draftSnapshot: String? = null,
        val draftRemainder: String? = null,
    )

    private data class PendingAction(
        val threadKey: String,
        val kind: String,
        val text: String?,
        val binding: JSONObject,
        val bindingToken: String,
        val actionToken: String? = null,
        val optionID: String? = null,
        val promptSignature: String? = null,
        val promptText: String? = null,
        val control: String? = null,
        val requestedAtNanos: Long = System.nanoTime(),
        val bypassComposerVerification: Boolean = false,
        val composerRetryGeneration: Long = 0,
        val retryDraftSnapshot: String? = null,
        val retryDraftRemainder: String? = null,
    ) {
        @Volatile var leaseToken: String? = null
    }

    private data class AttachmentTarget(
        val threadKey: String,
        val coreBinding: JSONObject,
        val binding: AgentEndpointBinding,
        val endpoint: AgentSessionEndpoint,
        val runtime: SharedAgentRuntime,
    )

    private data class PendingPromptObservation(
        val threadKey: String,
        val actionToken: String,
        val displayed: List<AgentPromptOption>,
        val providerID: String,
        val deferred: CompletableDeferred<FreshPromptRead>,
        val requestID: String = java.util.UUID.randomUUID().toString(),
    )

    private data class ProjectionSource(
        val endpointKey: AgentSessionKey,
        val binding: AgentEndpointBinding,
        val threadID: String,
        val provider: String,
        val transcriptRef: String,
        val bindingToken: String,
        val hostObservation: Boolean = false,
    )

    private data class TierCEndpointConformance(
        val binding: AgentEndpointBinding,
        val providers: Set<AgentTierCProvider>,
    )

    internal data class ThreadOwner(
        val endpointKey: AgentSessionKey,
        val threadID: String,
        val coreBindingJSON: String,
        val bindingToken: String,
        /** Its last frame came from a child agent, which runs beside its root. */
        val child: Boolean = false,
        /** The registration that supplied the proof, never a replacement with the same key. */
        val endpoint: AgentSessionEndpoint? = null,
    ) {
        // The lookup key is not JSON: retain the structured snapshot separately
        // so projection/search can recover the proved PID and incarnation.
        val canonicalBinding: String get() = JSONObject(coreBindingJSON).tokenKey()
        val endpointBinding: AgentEndpointBinding? get() = JSONObject().put("threadID", JSONObject(threadID))
            .put("binding", JSONObject(coreBindingJSON)).endpointBindingOrNull()
    }

    private data class PendingLaunch(
        val request: AgentLaunchRequest,
        val threadKey: String,
        val threadID: String,
        val binding: String,
        val intent: String,
        val parentRecordID: String?,
    )

    private data class PendingLifecycleLaunch(
        val providerID: String,
        val parentThreadKey: String?,
        val parentRecordID: String?,
        val requestID: String,
        val windowID: String,
        val paneID: String,
        val worktreeCreated: Boolean,
    )
}

private val AGENT_GROUPINGS = setOf("attention", "host")
private val TIER_C_PROVIDER_IDS = setOf("opencode", "pi", "kimi")
private const val MAX_TIER_C_INVENTORY_PAGES = 32
private const val MAX_PROJECTOR_OUTPUT_BYTES = 262_144
private const val PROJECTOR_STREAM_TIMEOUT_MILLIS = 5_000L
/** Core answers in a turn; its events queue behind any snapshot the app is still mapping. */
private const val READER_PLACE_TIMEOUT_MILLIS = 3_000L

/**
 * The hosts a search reports as not fully searched (unreachable, out of time,
 * or stopped early), including hosts whose matches are therefore partial.
 * Host IDs compare case-insensitively, as Core's UUIDs do. A result host
 * already holds one of [AGENT_SEARCH_HOSTS] slots; any other host needs a
 * free one, so the union stays within Core's snapshot bound.
 */
internal fun agentSearchUnavailableHosts(unavailable: Set<String>, resultHosts: Set<String>): List<String> {
    val withResults = resultHosts.map { it.lowercase(java.util.Locale.ROOT) }.toSet()
    var resultless = 0
    return unavailable.distinctBy { it.lowercase(java.util.Locale.ROOT) }.filter { host ->
        if (host.lowercase(java.util.Locale.ROOT) in withResults) return@filter true
        (withResults.size + resultless < AGENT_SEARCH_HOSTS).also { if (it) resultless++ }
    }
}

/**
 * The matches of the first [AGENT_SEARCH_HOSTS] hosts that have any, in
 * order, as Core's AgentSearchSnapshot constructor keeps them: its decoder
 * refuses a snapshot holding more, which would drop the whole search.
 */
internal fun agentSearchResultsWithinHostCap(results: JSONArray): JSONArray {
    val hosts = hashSetOf<String>()
    val admitted = JSONArray()
    for (index in 0 until results.length()) {
        val result = results.optJSONObject(index) ?: continue
        val host = result.optJSONObject("threadID")?.optString("hostID")?.lowercase(java.util.Locale.ROOT) ?: continue
        if (host !in hosts && hosts.size >= AGENT_SEARCH_HOSTS) continue
        hosts += host
        admitted.put(result)
    }
    return admitted
}

/**
 * The rows shown first, then what a search found, each record once and
 * within Core's per-host and host bounds: a running search only adds rows.
 */
internal fun agentSearchMerged(shown: JSONArray, found: JSONArray): JSONArray {
    val seen = hashMapOf<String, Int>()
    val perHost = mutableMapOf<String, Int>()
    val merged = JSONArray()
    for (list in listOf(shown, found)) for (index in 0 until list.length()) {
        val result = list.optJSONObject(index) ?: continue
        val id = result.optJSONObject("threadID") ?: continue
        // Host IDs compare case-insensitively, as Core's UUIDs do.
        val host = id.optString("hostID").lowercase(java.util.Locale.ROOT)
        val thread = canonicalAgentThreadKey(host,
            id.optJSONObject("providerID")?.optString("rawValue") ?: "", id.optString("providerSessionID"))
        val key = thread + "\u0000" + result.optString("recordID")
        val kept = seen[key]
        if (kept != null) {
            // The first copy keeps its place and excerpt; a later one places
            // a record the first could not, or proves it with a token (see
            // `AgentSearchResult.merging`), never splitting a position.
            val first = merged.getJSONObject(kept)
            if (result.has("sequence") && (!first.has("sequence") || (!first.has("seekToken") && result.has("seekToken")))) {
                merged.put(kept, JSONObject(first.toString()).apply { remove("sourceOffset"); remove("seekToken") }
                    .put("sequence", result.get("sequence")).putOpt("sourceOffset", result.opt("sourceOffset"))
                    .putOpt("seekToken", result.opt("seekToken")))
            }
            continue
        }
        if ((perHost[host] ?: 0) >= AGENT_SEARCH_HOST_RESULTS) continue
        seen[key] = merged.length()
        perHost[host] = (perHost[host] ?: 0) + 1
        merged.put(result)
    }
    return agentSearchResultsWithinHostCap(merged)
}

/** UTF-8 bytes a search needle may hold: the Agent Host refuses more. */
internal const val AGENT_SEARCH_NEEDLE_BYTES = 512
/** Exact matches one thread contributes to a search, host or paged. */
internal const val AGENT_SEARCH_THREAD_RESULTS = 25
/** Matches one host contributes to a search. */
internal const val AGENT_SEARCH_HOST_RESULTS = 100
/** Hosts one search reports, with results or not fully searched
 * (Core's `AgentSearchSnapshot.maximumHosts`). */
internal const val AGENT_SEARCH_HOSTS = 4
/** One connection request waits at most this long (`request`'s bound). */
private const val AGENT_SEARCH_REQUEST_MILLIS = 15_000L

/**
 * The needle a search runs: the trimmed query, cut on a character (grapheme)
 * boundary to at most [AGENT_SEARCH_NEEDLE_BYTES] UTF-8 bytes. The host
 * request, paged search and Core's exact re-match all use this same needle,
 * so a long multibyte query is neither refused by the host nor matched
 * differently on either side.
 */
internal fun agentSearchNeedle(query: String): String {
    val trimmed = query.trim()
    val clusters = java.text.BreakIterator.getCharacterInstance(java.util.Locale.ROOT)
    clusters.setText(trimmed)
    var bytes = 0
    var cut = 0
    var end = clusters.next()
    while (end != java.text.BreakIterator.DONE) {
        val size = trimmed.substring(cut, end).encodeToByteArray().size
        if (bytes + size > AGENT_SEARCH_NEEDLE_BYTES) break
        bytes += size; cut = end
        end = clusters.next()
    }
    return trimmed.substring(0, cut).trim()
}

/**
 * Splits the handles one host holds into searches whose request frame stays
 * well under the 64 KiB frame limit: at most [maxHandles] handles and
 * [maxBytes] of encoded `threads` each, in the given order. (A single 4,096
 * handle request is about 143 KiB, which no frame can carry.)
 */
internal fun agentSearchBatches(handles: List<String>, maxHandles: Int = 1_000, maxBytes: Int = 48 * 1024): List<List<String>> {
    val batches = mutableListOf<List<String>>()
    var batch = mutableListOf<String>()
    var bytes = 2 // The brackets.
    for (handle in handles) {
        val size = JSONObject.quote(handle).encodeToByteArray().size + 1 // And its comma.
        if (batch.isNotEmpty() && (batch.size >= maxHandles || bytes + size > maxBytes)) {
            batches += batch
            batch = mutableListOf()
            bytes = 2
        }
        batch += handle
        bytes += size
    }
    if (batch.isNotEmpty()) batches += batch
    return batches
}

/** One host's `search.v1` pass: matches in host order, the handles to page
 * instead, and whether any thread was left not fully searched. */
internal class AgentHostSearchOutcome(val results: List<JSONObject>, val paged: List<String>, val incomplete: Boolean)

/**
 * Searches [handles] on one Agent Host. Each batch is its own search with its
 * own cursor chain; the pass stops at [room] matches. [match] re-matches one
 * reply exactly (shared Core) for that batch's handles. [handleOf] names the
 * handle a match counts against, and [admit] repeats it only while its source
 * is current; a thread's caps apply first, as on iOS. A thread holding 25 matches is sent back as `satisfied` with every
 * later cursor of its batch, so the host stops reading it.
 *
 * The budget running out, a request timing out or failing, a match [admit]
 * refuses, or matches the host left out as oversized, keeps every match found
 * so far and reports the pass `incomplete`. A host refusal of a batch's
 * first request (invalidRequest, busy, cursorExpired, …) pages that batch
 * instead: the host never read it, so nothing is found twice.
 */
internal suspend fun runAgentHostSearch(
    handles: List<String>,
    needle: String,
    room: Int,
    deadlineNanos: Long,
    request: suspend (fields: JSONObject, timeoutMillis: Long) -> AgentIngestionConnection.Reply,
    match: suspend (reply: AgentIngestionConnection.Reply, batch: List<String>) -> SharedAgentHostSearch.Reply,
    admit: (match: JSONObject) -> String?,
    handleOf: (match: JSONObject) -> String?,
    nanoTime: () -> Long = System::nanoTime,
    progress: suspend (results: List<JSONObject>) -> Unit = {},
): AgentHostSearchOutcome {
    val results = mutableListOf<JSONObject>()
    val paged = mutableListOf<String>()
    val pagedHandles = mutableSetOf<String>()
    val found = mutableMapOf<String, Int>()
    var incomplete = false
    batches@ for (batch in agentSearchBatches(handles)) {
        if (results.size >= room) break
        val members = batch.toSet()
        val satisfied = linkedSetOf<String>()
        var cursor: String? = null
        do {
            currentCoroutineContext().ensureActive()
            val left = (deadlineNanos - nanoTime()) / 1_000_000
            if (left <= 0) { incomplete = true; break@batches }
            // No `limit`: the host reads each thread until the app reports
            // it satisfied or its transcript ends.
            val fields = JSONObject().put("kind", "search")
            if (cursor == null) fields.put("query", needle).put("threads", JSONArray(batch))
            else {
                fields.put("cursor", cursor)
                if (satisfied.isNotEmpty()) fields.put("satisfied", JSONArray(satisfied.toList()))
            }
            val reply = try {
                match(request(fields, left.coerceIn(1L, AGENT_SEARCH_REQUEST_MILLIS)), batch)
            } catch (failure: Exception) {
                // Only this search's own cancellation ends it. A nested
                // timeout or a closed connection is a failed request.
                if (failure is CancellationException) currentCoroutineContext().ensureActive()
                if (cursor == null && (failure is AgentIngestionRemoteError || failure is AgentIngestionReadFailure)) {
                    for (handle in batch) if (pagedHandles.add(handle)) paged += handle
                    continue@batches
                }
                incomplete = true
                break@batches
            }
            val before = results.size
            for (index in 0 until reply.results.length()) {
                if (results.size >= room) break
                val result = reply.results.getJSONObject(index)
                val handle = handleOf(result)?.takeIf { it in members } ?: continue
                val count = found[handle] ?: 0
                if (count >= AGENT_SEARCH_THREAD_RESULTS) continue
                // A thread whose source changed meanwhile shows nothing it
                // found, and the host reads as incomplete, as on iOS.
                if (admit(result) == null) { incomplete = true; continue }
                results += result
                found[handle] = count + 1
                if (count + 1 == AGENT_SEARCH_THREAD_RESULTS) satisfied += handle
            }
            if (results.size > before) progress(results.toList())
            // Matches the host left out as too large to send leave the host
            // incomplete; what it did send stands.
            if (reply.oversizedRecords > 0) incomplete = true
            // A thread the host could not scan itself is paged, unless it
            // already has host matches that paging would repeat.
            for (skipped in reply.skipped) {
                if (skipped.thread !in members) continue
                if (skipped.pagedFallback && skipped.thread !in found) {
                    if (pagedHandles.add(skipped.thread)) paged += skipped.thread
                }
                // Not read to its end (its source changed mid-search, or
                // paging would repeat what it gave): what it gave stands,
                // and the host reads as incomplete.
                else incomplete = true
            }
            cursor = reply.cursor
        } while (cursor != null && results.size < room)
    }
    return AgentHostSearchOutcome(results, paged, incomplete)
}
private const val TIER_A_REFRESH_MILLIS = 2_000L
private const val OCCUPANCY_REFRESH_MILLIS = 5_000L
/** Transcript items a thread snapshot may hold and still map on Main. */
private const val INLINE_DETAIL_ITEMS = 64
/** Shared Core clamps to the same range; this only keeps a bad width local. */
private const val MIN_TITLE_CHARACTERS = 16
private const val MAX_TITLE_CHARACTERS = 200
/** Tiers below `generated`, spelled as shared Core reports them. */
private val TITLE_TIERS_WORTH_GENERATING = setOf("placeholder", "prompt")

/** Matches iOS's stable candidate token: URL-safe unpadded UTF-8 base64, bounded to 128 chars. */
internal fun candidateActionTokenMatches(actionToken: String, signature: String): Boolean =
    actionToken == "candidate-" + Base64.getUrlEncoder().withoutPadding()
        .encodeToString(signature.encodeToByteArray()).take(128)

private fun isUUID(value: String): Boolean = runCatching { java.util.UUID.fromString(value) }.isSuccess

private fun AgentLaunchRequest.coreIntent(detail: AgentThreadDetail, parentRecordID: String?): JSONObject? {
    if (!isUUID(target.liveSessionID) || task.isBlank() || task.encodeToByteArray().size > 16_384) return null
    if (providerID !in setOf("claude", "codex") || (kind == AgentLaunchKind.Fork && providerID != "claude")) return null
    val path = directory.trim()
    if ((!(path.startsWith("/") || path.startsWith("~/"))) || path.encodeToByteArray().size > 2_048 ||
        path.split('/').any { it == ".." } || '\u0000' in path
    ) return null
    val kindJSON = when (kind) {
        AgentLaunchKind.Spawn -> JSONObject().put("spawn", JSONObject().also { value -> name?.let { value.put("name", it) } })
        AgentLaunchKind.Fork -> {
            val sourceRecordID = parentRecordID?.takeIf { it.isNotBlank() } ?: return null
            JSONObject().put("fork", JSONObject()
            .put("source", JSONObject().put("threadID", detail.row.threadIDJson()).put("recordID", sourceRecordID))
            .also { value -> name?.let { value.put("name", it) } })
        }
    }
    val placementJSON = when (placement) {
        AgentLaunchPlacement.NewWindow -> JSONObject().put("newWindow", JSONObject().also { value -> name?.let { value.put("name", it) } })
        AgentLaunchPlacement.SplitRight, AgentLaunchPlacement.SplitDown -> {
            // Swift authority: `TmuxTargetValidation` in TesseraProtocolCore, via
            // SharedTargetValidation. The literal it replaces accepted any Unicode
            // digit, where tmux only ever emits ASCII ones.
            val window = target.windowID
                ?.takeIf { SharedTargetValidation.isValidTmuxTargetId(it, SharedTmuxTargetKind.Window) }
                ?: return null
            val pane = target.paneID
                ?.takeIf { SharedTargetValidation.isValidTmuxTargetId(it, SharedTmuxTargetKind.Pane) }
                ?: return null
            JSONObject().put("split", JSONObject().put("windowID", window).put("paneID", pane)
                .put("axis", if (placement == AgentLaunchPlacement.SplitRight) "right" else "down"))
        }
    }
    val isolationJSON = when (val choice = isolation) {
        AgentLaunchIsolation.CurrentWorktree -> JSONObject().put("currentWorktree", JSONObject())
        is AgentLaunchIsolation.NewWorktree -> {
            // Swift authority: `AgentLaunchValidator.isValidBranch` — the same
            // grammar the shared launch path applies. The literal it replaces
            // accepted Unicode letters and counted its 128 bound in UTF-16 units, so
            // it could admit a branch the launch path then rejected opaquely.
            if (!SharedTargetValidation.isValidBranch(choice.branch)) return null
            JSONObject().put("newWorktree", JSONObject().put("branch", choice.branch))
        }
    }
    return JSONObject().put("kind", kindJSON).put("liveSessionID", target.liveSessionID)
        .put("providerID", JSONObject().put("rawValue", providerID))
        .put("workingDirectory", JSONObject().put("value", path)).put("task", task.trim())
        .put("placement", placementJSON).put("isolation", isolationJSON)
}

/** The target captured by the sheet must be identical to the currently leased route. */
private fun AgentLaunchRequest.matchesDisplayedBinding(detail: AgentThreadDetail): Boolean {
    val binding = detail.binding ?: return false
    return target.hostID.canonicalAgentUUID() == detail.row.hostID.canonicalAgentUUID() &&
        target.liveSessionID.canonicalAgentUUID() == binding.string("liveSessionID")?.canonicalAgentUUID() &&
        target.carrierGeneration == binding.number("carrierGeneration")?.toLongOrNull() &&
        target.transport == binding.string("transport") &&
        target.tmuxSession == binding.string("tmuxSession") &&
        target.windowID == binding.string("windowID") &&
        target.paneID == binding.string("paneID")
}

internal fun AgentLaunchRequest.matchesEndpointBinding(binding: AgentEndpointBinding): Boolean {
    val transport = when (binding.transport) {
        AgentEndpointTransport.SSH -> "ssh"
        AgentEndpointTransport.SSH_TMUX -> "sshTmux"
        AgentEndpointTransport.MOSH -> "mosh"
        AgentEndpointTransport.MOSH_TMUX -> "moshTmux"
    }
    return target.liveSessionID.canonicalAgentUUID() == binding.key.liveSessionID.canonicalAgentUUID() &&
        target.carrierGeneration == binding.key.carrierGeneration &&
        target.hostID.canonicalAgentUUID() == binding.hostID.canonicalAgentUUID() &&
        target.transport == transport &&
        target.tmuxSession == binding.tmuxSession &&
        target.windowID == binding.windowID &&
        target.paneID == binding.paneID
}

private fun String.isSafeTerminalInsert(): Boolean =
    isNotEmpty() && none { (it.code < 32 && it != '\n') || it.code == 127 }

private fun AgentLaunchRequest.helperRequest(requestID: String, sourceThreadID: JSONObject, parentRecordID: String?): JSONObject {
    val value = JSONObject().put("v", 1).put("requestID", requestID.lowercase())
        .put("kind", if (kind == AgentLaunchKind.Fork) "fork" else "spawn")
        .put("provider", providerID).put("task", task.trim()).put("directory", directory.trim())
    if (kind == AgentLaunchKind.Fork) {
        val sourceRecordID = parentRecordID?.takeIf { it.isNotBlank() } ?: return value
        value.put("source", JSONObject().put("providerSessionID", sourceThreadID.getString("providerSessionID")).put("recordID", sourceRecordID))
    }
    value.put("isolation", when (val choice = isolation) {
        AgentLaunchIsolation.CurrentWorktree -> JSONObject().put("kind", "current")
        is AgentLaunchIsolation.NewWorktree -> JSONObject().put("kind", "worktree").put("branch", choice.branch)
    })
    return value
}

private fun JSONObject.matches(request: AgentLaunchRequest, sourceThreadID: JSONObject, parentRecordID: String?): Boolean {
    if (optString("liveSessionID").canonicalAgentUUID() != request.target.liveSessionID.canonicalAgentUUID() ||
        optJSONObject("providerID")?.optString("rawValue") != request.providerID ||
        optJSONObject("workingDirectory")?.optString("value") != request.directory.trim() ||
        optString("task") != request.task.trim()
    ) return false
    val kind = optJSONObject("kind") ?: return false
    if (request.kind == AgentLaunchKind.Spawn && !kind.has("spawn")) return false
    if (request.kind == AgentLaunchKind.Fork) {
        val fork = kind.optJSONObject("fork") ?: return false
        val source = fork.optJSONObject("source")?.optJSONObject("threadID") ?: return false
        if (source.optString("hostID").canonicalAgentUUID() != sourceThreadID.optString("hostID").canonicalAgentUUID() ||
            source.optJSONObject("providerID")?.optString("rawValue") != sourceThreadID.optJSONObject("providerID")?.optString("rawValue") ||
            source.optString("providerSessionID") != sourceThreadID.optString("providerSessionID")
        ) return false
        // The shared runtime requires a concrete turn or projection record for
        // fork provenance. Android only has a projected record identifier.
        if (source.optString("recordID") != parentRecordID) return false
    }
    val placement = optJSONObject("placement") ?: return false
    when (request.placement) {
        AgentLaunchPlacement.NewWindow -> if (!placement.has("newWindow")) return false
        AgentLaunchPlacement.SplitRight, AgentLaunchPlacement.SplitDown -> {
            val split = placement.optJSONObject("split") ?: return false
            if (split.optString("windowID") != request.target.windowID || split.optString("paneID") != request.target.paneID ||
                split.optString("axis") != if (request.placement == AgentLaunchPlacement.SplitRight) "right" else "down"
            ) return false
        }
    }
    val encodedIsolation = optJSONObject("isolation") ?: return false
    return when (val isolation = request.isolation) {
        AgentLaunchIsolation.CurrentWorktree -> encodedIsolation.has("currentWorktree")
        is AgentLaunchIsolation.NewWorktree -> encodedIsolation.optJSONObject("newWorktree")?.optString("branch") == isolation.branch
    }
}

internal fun AgentThreadRow.threadIDJson(): JSONObject = threadID(hostID, providerID, providerSessionID)

/** A host order or source offset: a UInt64, which a Long cannot hold whole. */
private fun String.seekOrder(): java.math.BigInteger? =
    toBigIntegerOrNull()?.takeIf { it.signum() >= 0 && it.bitLength() <= 64 }

private fun String.threadIDJson(): JSONObject? {
    val parts = split(":", limit = 3)
    if (parts.size != 3 || parts.any(String::isBlank)) return null
    return threadID(parts[0], parts[1], parts[2])
}

private fun threadID(hostID: String, provider: String, session: String): JSONObject = JSONObject()
    .put("hostID", hostID).put("providerID", providerID(provider)).put("providerSessionID", session)

private fun providerID(value: String): JSONObject = JSONObject().put("rawValue", value)

/** Converts a Core-issued lease back into the exact registry address it approved. */
internal fun JSONObject.endpointBindingOrNull(): AgentEndpointBinding? {
    val leaseBinding = optJSONObject("binding") ?: return null
    val threadID = optJSONObject("threadID") ?: return null
    val liveSessionID = leaseBinding.optString("liveSessionID").takeIf { it.isNotBlank() } ?: return null
    val generation = leaseBinding.optLong("carrierGeneration", -1).takeIf { it > 0 } ?: return null
    val hostID = threadID.optString("hostID").takeIf { it.isNotBlank() } ?: return null
    val transport = when (leaseBinding.optString("transport")) {
        "ssh" -> AgentEndpointTransport.SSH
        "sshTmux" -> AgentEndpointTransport.SSH_TMUX
        "mosh" -> AgentEndpointTransport.MOSH
        "moshTmux" -> AgentEndpointTransport.MOSH_TMUX
        else -> return null
    }
    return runCatching {
        AgentEndpointBinding(
            key = AgentSessionKey(liveSessionID.canonicalAgentUUID(), generation),
            hostID = hostID.canonicalAgentUUID(),
            transport = transport,
            tmuxSession = leaseBinding.optNullableString("tmuxSession"),
            windowID = leaseBinding.optNullableString("windowID"),
            paneID = leaseBinding.optNullableString("paneID"),
        )
    }.getOrNull()
}

private fun JSONObject.optNullableString(name: String): String? =
    optString(name).takeIf { has(name) && it.isNotBlank() }

/** Stable lookup identity across Swift sorted JSON and Android-created JSON. */
private val AGENT_DETAIL_TABS = setOf("live", "activity", "changes")

/**
 * A split mutates a new pane, while the v1 ABI correlates its launch receipt
 * to the explicitly leased source pane.  Keep that contract separate from the
 * durable local receipt, which always records the created pane.
 */
internal fun AgentTmuxLaunchReceipt.abiReceiptCoordinates(
    placement: AgentLaunchPlacement,
    leasedBinding: AgentEndpointBinding,
): Pair<String?, String?> = when (placement) {
    AgentLaunchPlacement.NewWindow -> windowID to paneID
    AgentLaunchPlacement.SplitRight, AgentLaunchPlacement.SplitDown -> leasedBinding.windowID to leasedBinding.paneID
}

internal fun JSONObject.tokenKey(): String = coreBindingIdentity().joinToString("\u001f")

internal fun JSONObject.tokenKey(threadKey: String): String = "${tokenKey()}\u001f$threadKey"

/**
 * JSONObject's textual form preserves insertion order, while shared Core
 * canonicalizes maps.  Compare the complete binding schema field-by-field so
 * a reordered but equivalent binding is accepted and a substituted pane/PID
 * is not.
 */
internal fun JSONObject.sameCoreBinding(other: JSONObject?): Boolean =
    other != null && coreBindingIdentity() == other.coreBindingIdentity()

private fun JSONObject.coreBindingIdentity(): List<String> = listOf(
    // Swift UUID encoding is uppercase; Android UUID.toString() is lowercase.
    // Normalize only the UUID, retaining every route and authority fence.
    optString("liveSessionID").canonicalAgentUUID(),
    if (has("carrierGeneration")) optLong("carrierGeneration").toString() else "<missing>",
    optJSONObject("incarnation")?.optString("rawValue").orEmpty(),
    optString("transport"),
    optNullableString("tmuxSession").orEmpty(),
    optNullableString("windowID").orEmpty(),
    optNullableString("paneID").orEmpty(),
    if (has("agentPID") && !isNull("agentPID")) optInt("agentPID").toString() else "<none>",
    if (has("capabilities") && !isNull("capabilities")) optInt("capabilities").toString() else "<missing>",
)

internal fun com.bambouville.tessera.core.bridge.SharedAgentValue.ObjectValue.toJson(): JSONObject = JSONObject().also { output ->
    fields.forEach { (key, value) ->
        output.put(key, value.toJsonValue())
    }
}

private fun com.bambouville.tessera.core.bridge.SharedAgentValue.toJsonValue(): Any? = when (this) {
    is com.bambouville.tessera.core.bridge.SharedAgentValue.StringValue -> value
    is com.bambouville.tessera.core.bridge.SharedAgentValue.NumberValue -> java.math.BigDecimal(value)
    is com.bambouville.tessera.core.bridge.SharedAgentValue.BooleanValue -> value
    com.bambouville.tessera.core.bridge.SharedAgentValue.Null -> JSONObject.NULL
    is com.bambouville.tessera.core.bridge.SharedAgentValue.ArrayValue -> org.json.JSONArray(values.map { it.toJsonValue() })
    is com.bambouville.tessera.core.bridge.SharedAgentValue.ObjectValue -> toJson()
}

/** Reports raw wire bounds without logging transcript content or enforcing policy. */
private fun projectionRecordBoundsIssue(frame: JSONObject): String? {
    val id = frame.optString("recordID")
    if (id.isEmpty() || id.toByteArray(StandardCharsets.UTF_8).size > 512) return "recordID-size"
    if (frame.has("sourceHash") && !frame.isNull("sourceHash")) {
        val hash = frame.optString("sourceHash")
        if (hash.length != 64 || hash.any { it !in '0'..'9' && it !in 'a'..'f' }) return "sourceHash-format"
    }
    val pending = ArrayDeque<Pair<Any?, Int>>()
    pending.add(frame.opt("record") to 0)
    var nodes = 0
    while (pending.isNotEmpty()) {
        val (value, depth) = pending.removeLast()
        if (++nodes > 4_096) return "record-nodes=$nodes"
        if (depth > 32) return "record-depth=$depth"
        when (value) {
            is String -> {
                val bytes = value.toByteArray(StandardCharsets.UTF_8).size
                if (bytes > 16_384) return "record-stringBytes=$bytes"
            }
            is JSONObject -> {
                if (value.length() > 4_096) return "record-object-size=${value.length()}"
                for (key in value.keys()) {
                    if (key.isEmpty() || key.toByteArray(StandardCharsets.UTF_8).size > 512) return "record-key-size"
                    pending.add(value.opt(key) to depth + 1)
                }
            }
            is JSONArray -> {
                if (value.length() > 4_096) return "record-array-size=${value.length()}"
                for (index in 0 until value.length()) pending.add(value.opt(index) to depth + 1)
            }
        }
    }
    return null
}

/** Distinguishes route, process-proof, and remote-exec refusals in device logs. */
private fun AgentEndpointResult<*>.describeFailure(): String = when (this) {
    is AgentEndpointResult.Failed -> "failed($code)"
    is AgentEndpointResult.Unavailable -> "unavailable($reason)"
    AgentEndpointResult.StaleBinding -> "stale"
    is AgentEndpointResult.Success -> "success"
}

/** setOpenDetail is owned by the composed detail's DisposableEffect, including compact navigation. */
internal fun isAgentThreadDisplayed(
    key: String,
    state: AgentCenterUiState,
    enabled: Boolean,
    applicationForeground: Boolean,
    openDetailKey: String?,
): Boolean {
    val selected = state.detail ?: state.selectedThreadKey?.let(state.projectedDetails::get)
    return enabled && applicationForeground && openDetailKey == key &&
        state.selectedThreadKey == key && selected?.row?.key == key
}

internal data class AgentLivePromptWatchSnapshot(
    val watch: Boolean,
    val displayed: Boolean,
    val lifecycleNanos: Long?,
    val lifecycleSequence: Long?,
    val deliveryGeneration: Long?,
) {
    fun elapsedMillis(now: Long): Long = lifecycleNanos?.let { (now - it) / 1_000_000 } ?: 3_000
    fun shouldWatch(now: Long): Boolean = watch || elapsedMillis(now) < 1_500 || displayed
}

/** The presenter's polling loop; injectable I/O and clock keep JVM coverage independent of JNI. */
internal suspend fun watchAgentLivePrompt(
    threadID: JSONObject,
    bindingToken: String,
    provider: String,
    current: () -> AgentLivePromptWatchSnapshot?,
    inspect: suspend () -> AgentTerminalObservation?,
    forward: (JSONObject) -> Unit,
    nanoTime: () -> Long = System::nanoTime,
    pause: suspend (Long) -> Unit = { delay(it) },
) {
    while (true) {
        currentCoroutineContext().ensureActive()
        val before = current() ?: return
        val elapsed = before.elapsedMillis(nanoTime())
        if (!before.shouldWatch(nanoTime())) return
        // Fence before inspecting. A route with no forwarded lifecycle frame
        // uses its delivery generation instead; never send both fences.
        val sequence = before.lifecycleSequence
        val generation = if (sequence == null) before.deliveryGeneration else null
        val observed = if (sequence == null && generation == null) null else inspect()
        currentCoroutineContext().ensureActive()
        // A capture can finish after selection, visibility, foreground or
        // route ownership changed. Keep the original fence, but recheck demand.
        val after = current() ?: return
        if (!after.shouldWatch(nanoTime())) return
        if (observed != null && observed.authoritative && !observed.truncated && !observed.captureWaitedForFrame) {
            val visible = promptRows(observed)
            if (visible.isNotBlank()) {
                forward(JSONObject().put("v", 1).put("kind", "livePromptObservation")
                    .put("threadID", threadID).put("bindingToken", bindingToken)
                    .putOpt("observedLifecycleSequence", sequence).putOpt("observedGeneration", generation)
                    .also { if (after.displayed) it.put("onDisplay", true) }
                    .put("promptObservation", JSONObject().put("providerID", providerID(provider))
                        .put("visibleText", visible)
                        .putOpt("currentCursorLine", boundedPromptCursor(observed.currentCursorLine))))
            }
        }
        // Check for a newer frame every fast tick even in the slow phase, so
        // that frame restarts the cadence at once, as on iOS.
        var ticks = if (elapsed < 2_000) 1 else 4
        while (ticks-- > 0) {
            pause(250)
            val now = current() ?: return
            if (now.lifecycleNanos != before.lifecycleNanos || now.lifecycleSequence != before.lifecycleSequence) break
        }
    }
}

/** A redraw is inconclusive, even when consecutive captures wait for frames. */
internal fun agentObservationPoll(
    observation: AgentTerminalObservation?,
    predicate: (AgentTerminalObservation) -> Boolean,
): AgentPoll<AgentTerminalObservation> =
    if (observation != null && !observation.captureWaitedForFrame && predicate(observation))
        AgentPoll.Found(observation) else AgentPoll.Again
