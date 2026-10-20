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
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.async
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
    private val ingestionVisibleCards = ConcurrentHashMap.newKeySet<String>()
    @Volatile private var ingestionOpenDetail: String? = null
    private var ingestionInterestJob: Job? = null
    private var ingestionInterestRevision = 0L
    private val ingestionCommits = ConcurrentHashMap<String, CompletableDeferred<NativeCommit>>()
    private var searchJob: Job? = null
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
        if (runtime != null || observer != null) return
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
                endpointObservers.keys.filterNot(live::contains).forEach { key ->
                    occupancySweepJobs.remove(key)?.cancel()
                    occupancySweepLocks.remove(key)
                    ingestionInventories.remove(key)?.cancel()
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
                for (binding in bindings) {
                    val endpoint = coordinator.directory.resolve(binding.key) ?: continue
                    startNativeInventory(endpoint)
                    if (endpointObservers[binding.key] == null) {
                        scheduleOccupancySweeps(endpoint)
                        endpointObservers[binding.key] = launch {
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
        readRetryJobs.keys.filter { it != threadKey && it !in ingestionVisibleCards }.forEach { readRetryJobs.remove(it)?.cancel() }
        val current = mutableState.value
        // Do not render an old selected thread while Core resolves the new
        // one. A same-thread projection can be shown immediately, but a row
        // summary never substitutes for a detail/binding lease.
        mutableState.value = current.copy(
            selectedThreadKey = threadKey,
            detail = threadKey?.let(current.projectedDetails::get)?.let(::withKnownDirectoryProof),
        )
        publishSendingThreads()
        // A thread key is a display identity. The native ABI remains authoritative
        // for resolving provider IDs; an unresolvable key is a harmless rejection.
        forward(JSONObject().put("v", 1).put("kind", "select").putOpt("threadID", threadKey?.threadIDJson()))
        // Search can select a historical inventory thread that Core deliberately
        // omits from its live-only list. Reuse only its current registered
        // projection source and owner; this does not mint a binding or send to
        // the terminal.
        threadKey?.let(::scheduleExistingProjection)
        startDisplayedLivePromptWatch()
    }

    fun search(query: String) {
        mutableState.value = mutableState.value.copy(searchQuery = query)
        searchJob?.cancel()
        val bounded = query.trim().take(512)
        if (!enabled || !applicationForeground) { searchJob = null; return }
        searchJob = scope.launch { runRemoteSearch(bounded) }
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
        val thread = threadKey.threadIDJson() ?: return
        forward(JSONObject().put("v", 1).put("kind", "viewportAnchor").put("threadID", thread).putOpt("recordID", recordID))
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
            is SharedAgentRuntimeEvent.Notice -> Unit
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
                    mutableState.value = mutableState.value.withThreadSnapshot(detail)
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
                mutableState.value = previous.copy(
                    detail = if (previous.selectedThreadKey == detail.row.key) detail else previous.detail,
                    projectedDetails = previous.projectedDetails + (detail.row.key to detail),
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
            val visible = bottomPromptRows(observed.visibleTail.decodeToString())
            if (visible.isBlank()) return@withLock null
            val cursor = boundedPromptCursor(observed.currentCursorLine)
            val deferred = CompletableDeferred<FreshPromptRead>()
            val pending = PendingPromptObservation(threadKey, actionToken, displayed, providerID, deferred)
            pendingPromptObservation = pending
            try {
                if (!forward(JSONObject().put("v", 1).put("kind", "promptObservation").put("promptObservation", JSONObject()
                        .put("providerID", providerID(providerID)).put("visibleText", visible).putOpt("currentCursorLine", cursor))
                        .putOpt("promptAnswerPlan", planInput).put("promptRequestID", pending.requestID))) {
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

    private fun teardownEndpointOwners(endpointKey: AgentSessionKey) {
        threadOwners.entries.filter { it.value.endpointKey == endpointKey }.forEach { entry ->
            // Core's retirement event names the token that actually left.
            forward(JSONObject().put("v", 1).put("kind", "unbind").put("threadID", JSONObject(entry.value.threadID))
                .put("bindingToken", entry.value.bindingToken))
        }
    }

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
    private fun retireRevokedOwner(threadKey: String) {
        val previous = mutableState.value
        val rows = previous.threads.filterNot { it.key == threadKey }
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
        if (!forward(
                JSONObject().put("v", 1).put("kind", "lifecycle").put("threadID", id)
                    .put("bindingToken", bindingToken).put("lifecycle", lifecycle),
            )
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
        if (transcriptRef != null) {
            val source = ProjectionSource(endpoint.key, frame.binding, id.toString(), provider, transcriptRef, bindingToken)
            val previousSource = projectionSources[key]
            if (previousSource != null && previousSource.transcriptRef != transcriptRef) {
                cancelFirstProjectionRetry(key)
                clearNativeReadStatus(key)
            }
            projectionSources[key] = source
            scheduleProjection(endpoint, frame.binding, id, provider, transcriptRef, key, bindingToken)
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
            projectionJobs.remove(threadKey)?.cancel()
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
                    forward = { forward(it) },
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
        if (sendAnywayCandidate?.threadKey == threadKey) invalidateSendAnyway()
        retiredOwnerThreads.add(threadKey)
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
        projectionJobs.remove(threadKey)?.cancel()
        projectionSources.remove(threadKey)
        val followed = mutableState.value.selectedThreadKey == threadKey
        mutableState.value = mutableState.value.copy(loadingTranscriptThreads = mutableState.value.loadingTranscriptThreads - threadKey)
        retireRevokedOwner(threadKey)
        if (followed && successor != null) select(successor)
        return true
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
    ) {
        if (!enabled || !applicationForeground) return
        if (cursor == null && nativeDirection != "bootstrap" &&
            (mutableState.value.ingestionReadStatuses[threadKey]?.recovery == "manual" || readRetryJobs.containsKey(threadKey))) return
        val owner = threadOwners[threadKey]
        if (owner?.endpointKey != endpoint.key || owner.bindingToken != bindingToken) return
        AgentTierCProvider.fromWire(provider)?.let { tierC ->
            if (!tierCConforms(endpoint.key, binding, tierC)) return
        }
        if (coalesceProjectionIfRunning(threadKey, cursor, nativeDirection)) return
        lateinit var job: Job
        job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                project(endpoint, binding, threadID, provider, transcriptRef, threadKey, cursor = cursor,
                    bindingToken = bindingToken, nativeDirection = nativeDirection,
                    initialPagesRemaining = if (cursor == null && mutableState.value.projectedDetails[threadKey]?.cursor == null
                        && mutableState.value.projectedDetails[threadKey]?.live.isNullOrEmpty()) SharedAgentInitialLoadPolicy.initialPageCount - 1 else 0)
            } finally {
                if (projectionJobs.remove(threadKey, job)) {
                    mutableState.value = mutableState.value.copy(loadingTranscriptThreads = mutableState.value.loadingTranscriptThreads - threadKey)
                    if (pendingLatestRequests.remove(threadKey)) {
                        pendingHistoryRequests.remove(threadKey)
                        pendingProjectionRefreshes.remove(threadKey)
                        loadNewer(threadKey, latest = true)
                    } else if (pendingHistoryRequests.remove(threadKey)) loadMore(threadKey)
                    else if (pendingProjectionRefreshes.remove(threadKey)) scheduleExistingProjection(threadKey)
                    else if (pendingFillRequests.remove(threadKey)) fillHistory(threadKey)
                }
            }
        }
        projectionJobs[threadKey] = job
        if (nativeDirection == "bootstrap" || cursor != null || mutableState.value.projectedDetails[threadKey]?.live.isNullOrEmpty()) {
            mutableState.value = mutableState.value.copy(loadingTranscriptThreads = mutableState.value.loadingTranscriptThreads + threadKey)
        }
        job.start()
    }

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
        if (!enabled || !applicationForeground || ingestionInventories[endpoint.key]?.isActive == true) return
        ingestionInventories[endpoint.key] = scope.launch {
            while (enabled && applicationForeground && coordinator.directory.resolve(endpoint.key) === endpoint) {
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
                        require(claims.map { it.first }.distinct().size == claims.size)
                        host.reserveHandles(claims)
                        for (row in reply.inventory) {
                            val provider = row.getString("provider")
                            require(connection.supportsProvider(provider))
                            val session = row.getString("sessionID")
                            val key = canonicalAgentThreadKey(connection.binding.hostID, provider, session)
                            val handle = row.getString("thread")
                            claimNativeThread(key, host)
                            host.threads.putIfAbsent(key, NativeThread(handle))
                            val old = projectionSources[key]
                            // Canonical thread ownership spans host sessions.
                            // Keep any current owner, not just this endpoint's
                            // owner, so sibling inventories cannot churn its
                            // token or downgrade a proved live pane.
                            val oldEndpoint = old?.let { coordinator.directory.resolve(it.endpointKey) }
                            if (old != null && oldEndpoint != null && isProjectionSourceCurrent(oldEndpoint, old)) continue
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
                            if (projectionSources[key] !== old) continue
                            val issued = (issuance as? AgentEndpointResult.Success)?.value
                                ?: error("inventory observation unavailable")
                            require(!issued.actionable)
                            bindingTokens[issued.coreBinding.tokenKey(key)] = issued.bindingToken
                            val owner = ThreadOwner(endpoint.key, id.toString(), issued.coreBinding.toString(), issued.bindingToken, endpoint = endpoint)
                            val previousOwner = threadOwners.put(key, owner)
                            refreshPaneAgentProviders()
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
                        // One shared list projection per page, no transcript
                        // bootstrap and no selection side effect per row.
                        forward(JSONObject().put("v", 1).put("kind", "filter").put("grouping", mutableState.value.grouping))
                        scheduleNativeInterests()
                        if (!reply.end.getBoolean("hasMore")) break
                        val next = reply.end.getString("cursor")
                        check(seen.add(next) && pageIndex < 163)
                        cursor = next
                    }
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    // Transport Deferred cancellation is a reconnectable failure;
                    // only cancellation of this inventory job ends discovery.
                    currentCoroutineContext().ensureActive()
                }
                catch (failure: Throwable) { diagnostics?.invoke("agent_native_inventory", mapOf("reason" to "inventory-failed", "errorType" to failure.javaClass.simpleName)) }
                delay(10_000)
            }
        }
    }

    private fun closeIngestionHosts() {
        initialPrefetchJobs.keys.toList().forEach(::cancelInitialPrefetch)
        readRetryJobs.values.forEach(Job::cancel); readRetryJobs.clear()
        readRetryRequests.clear()
        ingestionInterestJob?.cancel(); ingestionInterestJob = null
        ingestionInventories.values.forEach { it.cancel() }; ingestionInventories.clear()
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
                                     threadID: JSONObject, token: String): NativeCommit {
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
            val committed = if (!forwardEncoded(command)) NativeCommit(false, code = "commitNotForwarded")
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
            detail.binding?.toJson()?.sameCoreBinding(JSONObject(owner.coreBindingJSON)) != true ||
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
                                      prefetchConnection: AgentIngestionConnection? = null) {
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
            if (prefetchConnection == null && (direction == "bootstrap" || cursor != null)) {
                mutableState.value = mutableState.value.copy(ingestionCapacityThreads = mutableState.value.ingestionCapacityThreads - key)
            }
            if (selected.window != null && cursor == null && direction != "bootstrap") {
                scheduleInitialPrefetch(host, connection, selected, key)
                updateNativeInterests(host, connection)
                return@withLock
            }
            selected.paused = true
            try {
                stage = "unsubscribe"
                host.interests.withLock {
                    connection.request(JSONObject().put("kind", "unsubscribe").put("thread", selected.handle)); selected.fast = null
                }
                suspend fun read(operation: String, anchor: String? = null) {
                    var limit = 100
                    while (true) {
                        stage = "pageRead"
                        val previousWindow = selected.window
                        val reply = connection.request(JSONObject().put("kind", "window.read").put("operation", operation)
                            .put("thread", selected.handle).putOpt("cursor", anchor).put("limit", limit)
                            .put("windowVersion", if (operation == "bootstrap") 0 else checkNotNull(selected.window).getLong("version")))
                        val source = checkNotNull(projectionSources[key])
                        try {
                            stage = "pageAuthority"
                            check(enabled && applicationForeground) { "projectionInactive" }
                            check(isNativeHostCurrent(host)) { "staleEpoch" }
                            // Core leases contain terminal addresses, not host
                            // display names. Compare every route field without
                            // rejecting the same address's presentation label.
                            check(source.binding.sameRouteAs(binding)) { "projectionRouteChanged" }
                            check(source.bindingToken == token) { "projectionOwnerChanged" }
                            check(isProjectionSourceCurrent(endpoint, source)) { "staleBinding" }
                            if (prefetchConnection != null) check(selected.window === previousWindow) { "resyncRequired" }
                            currentCoroutineContext().ensureActive()
                            // Once Core accepts a page its remote lease must be
                            // ACKed even if optional prefetch is cancelled in
                            // that local commit interval. This never waits for
                            // another history response or blocks Send's frontier.
                            val commit = kotlinx.coroutines.withContext(if (prefetchConnection != null)
                                kotlinx.coroutines.NonCancellable else currentCoroutineContext()) {
                                stage = "pageCommit"
                                val committed = commitNative(host, connection, selected.handle, reply, threadID, token)
                                if (committed.accepted) {
                                    val checkpoint = checkNotNull(committed.window)
                                    stage = "pageAck"
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
                                return
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
                    scheduleInitialPrefetch(host, connection, selected, key)
                    // Optional title metadata cannot keep the first-page
                    // spinner or the older-page prefetch waiting on its RTT.
                    if (provider == "codex" && selected.metadataJob?.isActive != true) {
                        val metadata = scope.launch(start = CoroutineStart.LAZY) {
                            try {
                                val summary = connection.request(JSONObject().put("kind", "summary").put("thread", selected.handle))
                                commitNative(host, connection, selected.handle, summary, threadID, token)
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
            } finally {
                selected.paused = false
                // Subscription maintenance is independently coalesced; page
                // loading never waits for every visible card's control ACK.
                scheduleNativeInterests()
            }
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
                readRetryRequests[key] = cursor to direction
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
                    cursor, direction = nativeDirection)
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
                    val sent = forward(JSONObject().put("v", 1).put("kind", "projection").put("threadID", threadID).put("bindingToken", bindingToken).put("projection", page))
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

    private suspend fun searchNativeProvider(endpoint: AgentSessionEndpoint, key: String, source: ProjectionSource, query: String): JSONArray = withTimeout(30_000) {
        val context = threadOwners[key]?.coreBindingJSON?.let(::JSONObject)
        val rawPID = context?.opt("agentPID")
        require(rawPID == null || rawPID == JSONObject.NULL || rawPID is Int || rawPID is Long)
        val contextPID = (rawPID as? Number)?.toLong()?.also { require(it in 2..Int.MAX_VALUE) }?.toInt()
        val (host, connection) = nativeConnection(endpoint, contextPID, context?.optJSONObject("incarnation")?.optString("rawValue") ?: "")
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
        if (query.isEmpty()) {
            forward(JSONObject().put("v", 1).put("kind", "search")
                .put("searchSnapshot", JSONObject().put("results", JSONArray()).put("unavailableHostIDs", JSONArray())))
            return
        }
        val results = JSONArray()
        val unavailableHosts = linkedSetOf<String>()
        val resultCounts = mutableMapOf<String, Int>()
        val deadline = System.nanoTime() + 30_000_000_000L
        for ((sourceKey, source) in projectionSources.entries.sortedBy { it.value.threadID }) {
            currentCoroutineContext().ensureActive()
            if (!enabled || !applicationForeground) return
            val hostID = JSONObject(source.threadID).getString("hostID")
            if ((resultCounts[hostID] ?: 0) >= 100) continue
            val remaining = (deadline - System.nanoTime()) / 1_000_000
            if (remaining <= 0) { unavailableHosts.add(hostID); continue }
            val owner = threadOwners[sourceKey]
            if (owner?.endpointKey != source.endpointKey || owner.bindingToken != source.bindingToken) continue
            val tierCProvider = AgentTierCProvider.fromWire(source.provider)
            if (tierCProvider != null && !tierCConforms(source.endpointKey, source.binding, tierCProvider)) continue
            val endpoint = coordinator.directory.resolve(source.endpointKey)
            if (endpoint == null) {
                JSONObject(source.threadID).optString("hostID").takeIf(::isUUID)?.let(unavailableHosts::add)
                continue
            }
            try {
                val matches = withTimeout(remaining) { searchNativeProvider(endpoint, sourceKey, source, query) }
                currentCoroutineContext().ensureActive()
                if (isProjectionSourceCurrent(endpoint, source) && projectionSources[sourceKey] === source &&
                    threadOwners[sourceKey]?.bindingToken == source.bindingToken) {
                    for (index in 0 until matches.length()) if ((resultCounts[hostID] ?: 0) < 100) {
                        results.put(matches.getJSONObject(index))
                        resultCounts[hostID] = (resultCounts[hostID] ?: 0) + 1
                    }
                }
            } catch (_: TimeoutCancellationException) { unavailableHosts.add(hostID) }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) { unavailableHosts.add(hostID) }
        }
        currentCoroutineContext().ensureActive()
        if (!enabled || !applicationForeground) return
        // A failed source does not make its whole host unavailable when another
        // source on that host returned matches. Match AgentSearchSnapshot's
        // canonical constructor: result hosts and unavailable hosts are disjoint.
        val resultHosts = (0 until results.length()).mapNotNull { index ->
            results.optJSONObject(index)?.optJSONObject("threadID")?.optString("hostID")
        }.toSet()
        val fullyUnavailableHosts = agentSearchUnavailableHosts(unavailableHosts, resultHosts)
        forward(JSONObject().put("v", 1).put("kind", "search").put("searchSnapshot", JSONObject()
            .put("results", results).put("unavailableHostIDs", JSONArray(fullyUnavailableHosts))))
        diagnostics?.invoke("agent_search_completed", mapOf("count" to results.length().toString(), "unavailableHosts" to fullyUnavailableHosts.size.toString()))
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
            is AgentEndpointResult.Failed -> failLaunch(result.code.replace('_', ' '))
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
        suspend fun inspectInputSurface(): com.bambouville.tessera.agent.platform.AgentTerminalObservation? {
            val first = (endpoint.inspect(leasedBinding) as? AgentEndpointResult.Success)?.value ?: return null
            if (!first.captureWaitedForFrame) return first
            // Frame readiness can outlive a process. Refresh authority, then
            // accept only an immediate capture; do not age that proof again.
            if (!currentInputTarget()) return null
            val fresh = (endpoint.inspect(leasedBinding) as? AgentEndpointResult.Success)?.value ?: return null
            return fresh.takeUnless { it.captureWaitedForFrame }
        }
        val capability = endpoint.capabilities.value
        if (!capability.verifiedInput || !capability.semanticKeys) {
            refuse("unavailable", AgentNotSentReason.INPUT_UNAVAILABLE)
            return
        }
        val result = when (pending.kind) {
            "send", "queue" -> {
                val planned = actionPayload?.optJSONObject("text")
                val text = planned?.optString("text")?.takeIf { it == pending.text }
                    ?: return refuse("verificationFailed", AgentNotSentReason.PLAN_MISMATCH)
                if (planned.optBoolean("queueWhenWorking") != (pending.kind == "queue") ||
                    planned.optString("composerVerification", "required") !=
                        (if (pending.bypassComposerVerification) "userOverride" else "required")) {
                    return refuse("verificationFailed", AgentNotSentReason.PLAN_MISMATCH)
                }
                // Known provider editors accept bracketed-paste events. Raw
                // newlines must never be sent as separate terminal commands.
                if (!text.isSafeTerminalInsert() || ('\n' in text && leaseProvider !in setOf("codex", "claude"))) {
                    return refuse("unsupported_multiline_input", AgentNotSentReason.UNSUPPORTED_INPUT)
                }
                val source = projectionSources[detail.row.key]
                if (source != null && (source.endpointKey != endpoint.key || !source.binding.sameRouteAs(leasedBinding) || source.provider != leaseProvider)) {
                    return refuse("staleBinding", AgentNotSentReason.ROUTE_CHANGED)
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
                if (!armed) return refuse("receipt_baseline_unavailable", AgentNotSentReason.RECEIPT_UNAVAILABLE)
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
                when (delivery) {
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
                        }, delivery.reason, delivery.attempts, composerRefusal = delivery.canSkipComposerVerification(leaseProvider))
                    }
                    is AgentTextDeliveryResult.Attempted -> {
                        if (delivery.attempts > 1) {
                            diagnostics?.invoke("agent_send_input_settled", mapOf("attempts" to delivery.attempts.toString()))
                        }
                        delivery.result
                    }
                }
            }
            "interrupt" -> {
                if (actionPayload?.optJSONObject("targetBinding")?.sameCoreBinding(lease.optJSONObject("binding")) != true) {
                    return finishAction(lease, "verificationFailed")
                }
                if (!currentInputTarget()) return finishAction(lease, "staleBinding")
                // A blank baseline would make any later frame "different":
                // settle one with text first, or send no Escape at all.
                val before = agentSettledBaseline { budget -> withTimeoutOrNull(budget) { inspectInputSurface() } }
                    ?: return finishAction(lease, "verificationFailed")
                if (!currentInputTarget()) return finishAction(lease, "staleBinding")
                ensureActionActive()
                preWriteFailure()?.let { return finishAction(lease, it.code) }
                val sent = writes.attempt { endpoint.sendSemanticKey(leasedBinding, AgentSemanticKey.ESCAPE) }
                if (sent !is AgentEndpointResult.Success) sent
                else if (awaitObservation(endpoint, leasedBinding) { agentInterruptObserved(before, it) } == null
                ) AgentEndpointResult.Failed("verification_failed")
                else AgentEndpointResult.Success(Unit)
            }
            "answerPrompt" -> {
                val planned = actionPayload?.optJSONObject("promptAnswer")
                    ?: return finishAction(lease, "verificationFailed")
                val token = pending.actionToken ?: return finishAction(lease, "verificationFailed")
                val optionID = pending.optionID ?: return finishAction(lease, "verificationFailed")
                val signature = pending.promptSignature ?: return finishAction(lease, "verificationFailed")
                if (planned.optJSONObject("actionToken")?.optString("rawValue") != token || planned.optString("optionID") != optionID ||
                    planned.optString("expectedSignature") != signature ||
                    planned.optString("text").takeIf { planned.has("text") } != pending.promptText ||
                    planned.optString("control").takeIf { planned.has("control") } != pending.control ||
                    planned.optJSONObject("binding")?.sameCoreBinding(lease.optJSONObject("binding")) != true
                ) return finishAction(lease, "verificationFailed")
                val provider = detail.row.providerID
                val display = detail.prompt?.takeIf { it.actionToken == token }?.options
                    ?: return finishAction(lease, "verificationFailed")
                if (!currentInputTarget()) return finishAction(lease, "staleBinding")
                val goal = when {
                    pending.control != null -> JSONObject().put("kind", "control").put("control", pending.control)
                    pending.promptText != null -> JSONObject().put("kind", "text").put("text", pending.promptText)
                    else -> JSONObject().put("kind", "option").put("optionID", optionID)
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
                            // Proven after the capture this step was planned on and
                            // Core's reply: an agent that exited meanwhile leaves
                            // its shell in the pane, which must not get the keys.
                            if (!currentInputTarget()) { outcome = AgentEndpointResult.StaleBinding; break }
                            ensureActionActive()
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
                outcome
            }
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

internal fun agentSearchUnavailableHosts(unavailable: Set<String>, resultHosts: Set<String>): List<String> {
    val successful = resultHosts.map { it.lowercase(java.util.Locale.ROOT) }.toSet()
    return unavailable.distinctBy { it.lowercase(java.util.Locale.ROOT) }
        .filterNot { it.lowercase(java.util.Locale.ROOT) in successful }
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
            val visible = bottomPromptRows(observed.visibleTail.decodeToString())
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
        pause(if (elapsed < 2_000) 250 else 1_000)
    }
}

/** A redraw is inconclusive, even when consecutive captures wait for frames. */
internal fun agentObservationPoll(
    observation: AgentTerminalObservation?,
    predicate: (AgentTerminalObservation) -> Boolean,
): AgentPoll<AgentTerminalObservation> =
    if (observation != null && !observation.captureWaitedForFrame && predicate(observation))
        AgentPoll.Found(observation) else AgentPoll.Again
