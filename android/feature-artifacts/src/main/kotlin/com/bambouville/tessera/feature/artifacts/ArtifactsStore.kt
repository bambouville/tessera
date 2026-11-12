package com.bambouville.tessera.feature.artifacts

import android.content.Context
import androidx.compose.runtime.staticCompositionLocalOf
import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifacts
import com.bambouville.tessera.core.bridge.SharedArtifactsAction
import com.bambouville.tessera.core.bridge.SharedArtifactsCachePresentation
import com.bambouville.tessera.core.bridge.SharedArtifactsCacheState
import com.bambouville.tessera.core.bridge.SharedArtifactsFilter
import com.bambouville.tessera.core.bridge.SharedArtifactsListeningPort
import com.bambouville.tessera.core.bridge.SharedArtifactsOpenRequest
import com.bambouville.tessera.core.bridge.SharedArtifactsOverview
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenContext
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenHost
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenIntent
import com.bambouville.tessera.core.bridge.SharedArtifactsRecent
import com.bambouville.tessera.core.bridge.SharedArtifactsReduction
import com.bambouville.tessera.core.bridge.SharedArtifactsState
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestion
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.design.ArtifactOpenRequest
import com.bambouville.tessera.design.ArtifactOpener
import com.bambouville.tessera.feature.artifacts.viewers.ArtifactSftpInterceptor
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactLiveFilesRegistry
import com.bambouville.tessera.forwarding.AndroidPortForwardRuleStore
import com.bambouville.tessera.forwarding.ArtifactLiveForwardingRegistry
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

sealed interface ArtifactContent {
    data object Loading : ArtifactContent
    data class Document(val file: File, val displayName: String, val reloadToken: Long, val stagedImages: Map<String, File>) : ArtifactContent
    data class ServedPage(val url: String, val interceptor: ArtifactSftpInterceptor) : ArtifactContent
    /** [navigation] changes when the address bar sends the viewer to [url] again, even an unchanged one. */
    data class ForwardedPage(val url: String, val ruleLabel: String, val isEphemeral: Boolean, val navigation: Long = 0) : ArtifactContent
    data class Change(val path: String, val diff: String) : ArtifactContent
    data class Unavailable(val reason: ArtifactUnavailable) : ArtifactContent
}
sealed interface ArtifactUnavailable {
    data object Offline : ArtifactUnavailable
    data object NoForwarding : ArtifactUnavailable
    data class TooLarge(val bytes: Long) : ArtifactUnavailable
    data object Missing : ArtifactUnavailable
    data class Failed(val message: ArtifactMessage) : ArtifactUnavailable {
        constructor(message: String) : this(ArtifactMessage.Verbatim(message))
    }
}
sealed interface ArtifactFilesReconnect {
    data object Available : ArtifactFilesReconnect
    data object Connecting : ArtifactFilesReconnect
    data class Failed(val message: ArtifactMessage) : ArtifactFilesReconnect {
        constructor(message: String) : this(ArtifactMessage.Verbatim(message))
    }
}
sealed interface ArtifactQuickOpenOutcome {
    data class Opened(val tabId: String) : ArtifactQuickOpenOutcome
    data class Directory(val hostId: String, val path: String) : ArtifactQuickOpenOutcome
    data class Failed(val message: ArtifactMessage) : ArtifactQuickOpenOutcome {
        constructor(message: String) : this(ArtifactMessage.Verbatim(message))
    }
}

val LocalArtifactsStore = staticCompositionLocalOf<ArtifactsStore?> { null }

/** Process-owned by the app root. Mutations and content publication run on its Main scope. */
class ArtifactsStore internal constructor(
    private val stateFile: ArtifactsStateFile,
    private val hosts: ArtifactsLiveHosts,
    private val loader: ArtifactContentLoader,
    private val pages: ArtifactPageForwarder,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val recordDiagnostic: (String, Map<String, String>) -> Unit = { _, _ -> },
    private val persistenceDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val parseQuickOpen: (String, SharedArtifactsQuickOpenContext) -> SharedArtifactsQuickOpenIntent = SharedArtifacts::quickOpenParse,
    private val reduceAction: (SharedArtifactsState, SharedArtifactsAction) -> SharedArtifactsReduction = SharedArtifacts::reduce,
    private val cachePresentation: (SharedArtifactTab, Boolean, Long) -> SharedArtifactsCachePresentation = SharedArtifacts::cachePresentation,
) : ArtifactOpener {
    constructor(context: Context, recordDiagnostic: (String, Map<String, String>) -> Unit = { _, _ -> }) : this(
        context.applicationContext, ArtifactsLiveHosts(), recordDiagnostic,
    )
    private constructor(
        context: Context,
        live: ArtifactsLiveHosts,
        diagnostic: (String, Map<String, String>) -> Unit,
        stateFile: ArtifactsStateFile = ArtifactsStateFile(File(context.filesDir, "artifacts/state.json")),
    ) : this(
        stateFile, live,
        ArtifactContentLoader(File(context.noBackupFilesDir, "artifacts/cache"), live::files),
        ArtifactPageForwarder(live, AndroidPortForwardRuleStore(context)),
        CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate), recordDiagnostic = diagnostic,
    )

    private val mutableState = MutableStateFlow(SharedArtifactsState())
    val state: StateFlow<SharedArtifactsState> = mutableState.asStateFlow()
    private val mutableRevision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = mutableRevision.asStateFlow()
    /** Set by the app: removed hosts' WebView profiles (cookies, storage) go with them. */
    var onHostsRemoved: (Set<String>) -> Unit = {}
    /** Runs on Main once, with the complete saved-host directory, before content can load. */
    var onHostsLoaded: (Set<String>) -> Unit = {}
    private val mutableOpened = MutableSharedFlow<Unit>(extraBufferCapacity = 8)
    val opened: SharedFlow<Unit> = mutableOpened.asSharedFlow()
    private val contents = mutableMapOf<String, ArtifactContent>()
    private val cachedDocuments = mutableMapOf<String, ArtifactContent.Document>()
    private val cacheIndexJobs = mutableMapOf<String, Job>()
    private val loads = mutableMapOf<String, Job>()
    private val filesConnecting = mutableSetOf<String>()
    private val filesReconnectFailures = mutableMapOf<String, ArtifactMessage>()
    private data class PendingLoad(val force: Boolean, val staged: File?, val fromFollow: Boolean)
    private val pendingLoads = mutableMapOf<String, PendingLoad>()
    private val documentRefreshIntents = mutableMapOf<String, Long>()
    private val imageRefreshIntents = mutableMapOf<String, Long>()
    private data class ImageRefreshOpportunity(val filesGeneration: Long, val foregroundGeneration: Long)
    private val imageRefreshShortfalls = mutableMapOf<String, ImageRefreshOpportunity>()
    private var imageRefreshGeneration = 0L
    private val followLoads = mutableMapOf<String, Long>()
    private val probeJobs = mutableMapOf<String, Job>()
    private val ports = mutableMapOf<String, List<SharedArtifactsListeningPort>>()
    private val probedAt = mutableMapOf<String, Long>()
    private var sshPorts: Map<String, Int> = emptyMap()
    private var hostDirectoryLoaded = false
    private val liveness = mutableMapOf<String, Pair<Boolean, Boolean>>()
    private val filesChannels = mutableMapOf<String, ArtifactLiveFiles?>()
    private val filesOpenable = mutableMapOf<String, Boolean>()
    private val filesChannelGenerations = mutableMapOf<String, Long>()
    private val filesGenerations = mutableMapOf<String, Long>()
    private var filesGeneration = 0L
    private var foregroundGeneration = 0L
    private val foregroundChanges = MutableStateFlow(false)
    private val foreground: Boolean get() = foregroundChanges.value
    private var visibleId: String? = null
    private val overviewOwners = mutableSetOf<Any>()
    private var overviewSweepJob: Job? = null
    /** Drain a round before refilling, so the tail is polled before any repeat. */
    private val overviewSweepPending = ArrayDeque<String>()
    private val overviewSweepOrder = linkedSetOf<String>()
    private data class OverviewConnection(val files: ArtifactLiveFiles, val generation: Long)
    private val overviewSweepConnections = mutableMapOf<String, OverviewConnection>()
    private var persistJob: Job? = null
    private val stateWriter = ArtifactsStateWriter(stateFile, scope, persistenceDispatcher) {
        recordDiagnostic("artifacts_state_write_failed", emptyMap())
    }
    private var generation = 0L
    private var reloadToken = 0L
    private val seenEdits = LinkedHashSet<String>()
    private val skippedEdits = LinkedHashSet<String>()
    private val recents = LinkedHashMap<String, SharedArtifactsRecent>()
    private val closedTabs = ArtifactClosedTabs()
    private var pageNavigation = 0L
    private val follower = ArtifactFollower(scope, { hosts.files(it) != null }, ::statVisible)
    private val restorationLock = Mutex()
    private var stateRestorePending = false
    private val initialization = scope.async { restoreState() }

    private suspend fun restoreState(retry: Boolean = false) = restorationLock.withLock {
        if (retry && !stateRestorePending) return@withLock
        val loaded = withContext(persistenceDispatcher) {
            val restored = try { stateFile.load() }
            catch (_: IOException) { return@withContext null }
            catch (_: SecurityException) { return@withContext null }
            loader.recover(restored.tabs)
            val caches = restored.tabs.filter { it.target is SharedArtifactsTarget.File }.associate { tab ->
                tab.id to loader.cachedIfIdle(tab, tab.cache?.fetchedAt ?: 0)
            }
            restored to caches
        }
        if (loaded == null) {
            stateRestorePending = true
            return@withLock
        }
        val (diskState, caches) = loaded
        val restored = hostReconciliationActions(diskState).fold(diskState) { snapshot, action -> reduceAction(snapshot, action).state }
        val restoredIDs = restored.tabs.map { it.id }.toSet()
        val removed = state.value.tabs.map { it.id }.toSet() - restoredIDs
        stateRestorePending = false
        persistJob?.cancel()
        loads.values.forEach { it.cancel() }
        loads.clear()
        cacheIndexJobs.values.forEach { it.cancel() }
        cacheIndexJobs.clear()
        followLoads.clear()
        pendingLoads.clear()
        filesConnecting.retainAll(restoredIDs)
        filesReconnectFailures.keys.retainAll(restoredIDs)
        documentRefreshIntents.keys.retainAll(restoredIDs)
        imageRefreshIntents.keys.retainAll(restoredIDs)
        imageRefreshShortfalls.keys.retainAll(restoredIDs)
        contents.clear()
        cachedDocuments.clear()
        caches.forEach { (id, cache) ->
            if (id in restoredIDs && cache is ArtifactCacheLookup.Cached) cachedDocuments[id] = cache.document
        }
        // close shares the forwarder's acquisition mutex, including a cancelled
        // acquisition that only returns after this state swap.
        removed.forEach { id -> scope.launch { pages.close(id) } }
        loader.protect(restored.tabs, restored.selectedId, emptySet())
        mutableState.value = restored
        restored.tabs.filter { caches[it.id] === ArtifactCacheLookup.Busy }.forEach(::indexRecoveredCache)
        if (visibleId != null && restored.tabs.none { it.id == visibleId }) visibleId = null
        if (retry) generation += 1
        val restoredGeneration = generation
        syncFollower()
        bump()
        withContext(persistenceDispatcher) { stateFile.resumeWrites(restoredGeneration) }
        if (retry) stateWriter.enqueue(restored, restoredGeneration)
    }

    private fun indexRecoveredCache(snapshot: SharedArtifactTab) {
        val id = snapshot.id
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val document = loader.cached(snapshot, snapshot.cache?.fetchedAt ?: 0) ?: return@launch
                val current = tab(id) ?: return@launch
                if (current.hostId != snapshot.hostId || current.target != snapshot.target ||
                    cacheIndexJobs[id] !== currentCoroutineContext()[Job]) return@launch
                cachedDocuments[id] = document
                bump()
            } finally {
                if (cacheIndexJobs[id] === currentCoroutineContext()[Job]) cacheIndexJobs.remove(id)
            }
        }
        cacheIndexJobs[id] = job
        job.start()
    }

    init {
        launchReady {
            combine(ArtifactLiveFilesRegistry.revision, ArtifactLiveForwardingRegistry.revision) { files, forwarding -> files to forwarding }.collect {
                updateLiveness()
                val visible = visibleId?.let(::tab)
                val unavailable = visible?.id?.let(contents::get) as? ArtifactContent.Unavailable
                if (foreground && visible != null && visible.target is SharedArtifactsTarget.Page && unavailable?.reason == ArtifactUnavailable.NoForwarding && hosts.isLive(visible.hostId)) {
                    startLoad(visible.id)
                }
                bump()
            }
        }
        launchReady {
            foregroundChanges.collectLatest { active ->
                if (active) while (isActive) {
                    updateLiveness()
                    delay(1_000)
                }
            }
        }
    }

    fun tab(id: String): SharedArtifactTab? = state.value.tabs.firstOrNull { it.id == id }
    fun overview(query: String): SharedArtifactsOverview = SharedArtifacts.overview(state.value, state.value.filter, query)
    fun isLive(hostId: String): Boolean = hosts.isLive(hostId)
    fun content(tabId: String): ArtifactContent {
        if (!initialization.isCompleted || !hostDirectoryLoaded) return ArtifactContent.Loading
        val tab = tab(tabId) ?: return ArtifactContent.Unavailable(ArtifactUnavailable.Missing)
        val target = tab.target
        if (target is SharedArtifactsTarget.Change) return ArtifactContent.Change(target.path, target.diff)
        if (tab.target is SharedArtifactsTarget.File && hosts.files(tab.hostId) == null) {
            val token = (contents[tabId] as? ArtifactContent.Document)?.reloadToken ?: tab.cache?.fetchedAt ?: 0
            return cachedDocuments[tabId]?.copy(reloadToken = token) ?: ArtifactContent.Unavailable(ArtifactUnavailable.Offline)
        }
        return contents[tabId] ?: if (tab.target is SharedArtifactsTarget.File) {
            cachedDocuments[tabId] ?: ArtifactContent.Loading
        } else ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding)
    }
    fun presentation(tabId: String): SharedArtifactsCachePresentation {
        val tab = tab(tabId) ?: return SharedArtifactsCachePresentation(SharedArtifactsCacheState.None, null, false)
        val actual = if (tab.target is SharedArtifactsTarget.File && tabId !in cachedDocuments) tab.copy(cache = null) else tab
        val live = if (tab.target is SharedArtifactsTarget.File) hosts.files(tab.hostId) != null else hosts.isLive(tab.hostId)
        return cachePresentation(actual, live, clock())
    }
    /**
     * Null unless the tab's host is connected in a terminal but not over Files, and the tab is a file,
     * or a page on a mosh host with no SSH connection to forward it.
     */
    fun filesReconnect(tabId: String): ArtifactFilesReconnect? {
        val tab = tab(tabId) ?: return null
        if (hosts.files(tab.hostId) != null || hosts.openableFiles(tab.hostId) == null) return null
        when (tab.target) {
            is SharedArtifactsTarget.File -> Unit
            // A mosh session carries no forward; its Files connection can.
            is SharedArtifactsTarget.Page -> if (hosts.forwarding(tab.hostId).isNotEmpty()) return null
            is SharedArtifactsTarget.Change -> return null
        }
        return when {
            tabId in filesConnecting -> ArtifactFilesReconnect.Connecting
            tabId in filesReconnectFailures -> ArtifactFilesReconnect.Failed(checkNotNull(filesReconnectFailures[tabId]))
            else -> ArtifactFilesReconnect.Available
        }
    }

    /** Automatic opens (Files, terminal selections and links, agent follows) focus a tab already at their target. */
    override fun open(request: ArtifactOpenRequest) { launchReady { openNow(request) } }
    private fun openNow(request: ArtifactOpenRequest, newTab: Boolean = false): String? {
        val target = openTarget(request) ?: return null
        return openTarget(request.hostId, target, openTitle(request), request.origin.name.replaceFirstChar(Char::lowercase),
            request.sessionHint, newTab, (request as? ArtifactOpenRequest.File)?.stagedFile)
    }

    private fun openTarget(request: ArtifactOpenRequest): SharedArtifactsTarget? {
        if (request.hostId.isBlank() || hostDirectoryLoaded && hosts.directory.none { it.id == request.hostId } ||
            request is ArtifactOpenRequest.File && !request.path.startsWith('/') ||
            request is ArtifactOpenRequest.Change && request.path.isBlank() ||
            request is ArtifactOpenRequest.Page && (request.port !in 1..65_535 || request.scheme.lowercase() !in setOf("http", "https"))
        ) return null
        return when (request) {
            is ArtifactOpenRequest.File -> SharedArtifactsTarget.File(request.path)
            is ArtifactOpenRequest.Page -> SharedArtifactsTarget.Page(request.scheme.lowercase(), request.port, request.path)
            is ArtifactOpenRequest.Change -> SharedArtifactsTarget.Change(request.path, request.diff, request.summary)
        }
    }

    private fun openTitle(request: ArtifactOpenRequest): String = when (request) {
        is ArtifactOpenRequest.Page -> "localhost:${request.port}"
        is ArtifactOpenRequest.Change -> request.path.substringAfterLast('/').ifBlank { request.summary }
        is ArtifactOpenRequest.File -> request.path.substringAfterLast('/')
    }

    private fun openTarget(
        hostId: String, target: SharedArtifactsTarget, title: String, origin: String, sessionHint: String?,
        newTab: Boolean, staged: File? = null,
    ): String? {
        val label = hosts.directory.firstOrNull { it.id == hostId }?.label
            ?: state.value.tabs.firstOrNull { it.hostId == hostId }?.hostLabel ?: hostId
        val before = state.value.tabs
        val reduction = applyAction(SharedArtifactsAction.Open(SharedArtifactsOpenRequest(
            UUID.randomUUID().toString(), hostId, label, target, title, origin, sessionHint, newTab,
        ), clock())) ?: return null
        val id = reduction.focusedTabId ?: return null
        loadNavigated(id, before.firstOrNull { it.id == id }, reduction.navigatedPath != null, staged)
        mutableOpened.tryEmit(Unit)
        return id
    }

    /**
     * The address bar's Return on [tabId]. Pages and files retarget in place on
     * their own host; a change snapshot, or another host, opens a new tab.
     */
    private fun navigateNow(tabId: String, request: ArtifactOpenRequest): String? {
        val current = tab(tabId) ?: return null
        if (!artifactNavigatesInPlace(current, request.hostId, request is ArtifactOpenRequest.Change)) return null
        val target = openTarget(request) ?: return null
        val reduction = applyAction(SharedArtifactsAction.Navigate(tabId, target, openTitle(request), clock())) ?: return null
        if (reduction.focusedTabId != tabId || tab(tabId)?.target is SharedArtifactsTarget.Change) return null
        loadNavigated(tabId, current, true, (request as? ArtifactOpenRequest.File)?.stagedFile)
        mutableOpened.tryEmit(Unit)
        return tabId
    }

    /**
     * Another route on the same forwarded port keeps its viewer and history:
     * the page loads the new path. Everything else reloads.
     */
    private fun loadNavigated(id: String, previous: SharedArtifactTab?, navigated: Boolean, staged: File?) {
        val current = tab(id) ?: return
        val page = contents[id] as? ArtifactContent.ForwardedPage
        val before = previous?.target as? SharedArtifactsTarget.Page
        val after = current.target as? SharedArtifactsTarget.Page
        if (navigated && staged == null && page != null && before != null && after != null && previous.hostId == current.hostId &&
            before.scheme == after.scheme && before.port == after.port && loads[id]?.isActive != true
        ) {
            contents[id] = page.copy(url = artifactRebasedPageUrl(page.url, after.path), navigation = ++pageNavigation)
            bump()
            return
        }
        startLoad(id, force = navigated, staged = staged)
    }

    fun select(tabId: String) { launchReady { applyAction(SharedArtifactsAction.Select(tabId, clock())); startLoad(tabId) } }
    fun close(tabId: String) {
        launchReady {
            tab(tabId)?.let(closedTabs::push)
            applyAction(SharedArtifactsAction.Close(tabId, clock()))
        }
    }
    fun closeAll(hostId: String) {
        launchReady {
            state.value.tabs.filter { it.hostId == hostId }.forEach(closedTabs::push)
            applyAction(SharedArtifactsAction.CloseAll(hostId, clock()))
        }
    }
    /** Ctrl+Shift+T: the last tab the user closed comes back as a new tab, pinned if it was. */
    fun reopenClosed() {
        launchReady {
            while (true) {
                val closed = closedTabs.pop() ?: return@launchReady
                if (hostDirectoryLoaded && hosts.directory.none { it.id == closed.hostId }) continue
                val id = openTarget(closed.hostId, closed.target, closed.title, closed.origin, closed.sessionHint, newTab = true)
                    ?: continue
                if (closed.pinned) applyAction(SharedArtifactsAction.Pin(id, true, clock()))
                return@launchReady
            }
        }
    }
    /** What a share control offers for [tabId]: null for no control. */
    internal fun share(tabId: String): ArtifactShare? {
        val tab = tab(tabId) ?: return null
        return artifactShare(tab, content(tabId), cachedDocuments[tabId])
    }
    fun setPinned(tabId: String, pinned: Boolean) { launchReady { applyAction(SharedArtifactsAction.Pin(tabId, pinned, clock())) } }
    fun setFilter(filter: SharedArtifactsFilter) { launchReady { applyAction(SharedArtifactsAction.SetFilter(filter, clock())) } }
    fun refresh(tabId: String) {
        launchReady {
            if (presentation(tabId).canRefresh) {
                if (tab(tabId)?.target is SharedArtifactsTarget.File) {
                    val intent = ++imageRefreshGeneration
                    documentRefreshIntents[tabId] = intent
                    imageRefreshIntents[tabId] = intent
                    imageRefreshShortfalls.remove(tabId)
                }
                startLoad(tabId, force = true)
            }
        }
    }
    fun connectFiles(tabId: String) {
        val reconnect = filesReconnect(tabId)
        if (reconnect != ArtifactFilesReconnect.Available && reconnect !is ArtifactFilesReconnect.Failed) return
        val snapshot = tab(tabId) ?: return
        val files = hosts.openableFiles(snapshot.hostId) ?: return
        filesConnecting += tabId
        filesReconnectFailures.remove(tabId)
        bump()
        scope.launch {
            try {
                files.openArtifactChannel()
                currentCoroutineContext().ensureActive()
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (failure: Exception) {
                val current = tab(tabId)
                if (current?.hostId == snapshot.hostId && current.target == snapshot.target) {
                    filesReconnectFailures[tabId] = artifactFailureMessage(failure, R.string.artifacts_files_connection_failed, limit = 200)
                }
                return@launch
            } finally {
                filesConnecting.remove(tabId)
                bump()
            }
            val current = tab(tabId)
            if (current?.hostId == snapshot.hostId && current.target == snapshot.target) {
                // Observe the channel before its registry notification can cancel the explicit refresh.
                updateLiveness()
                refresh(tabId)
            }
        }
    }
    fun noteVisible(tabId: String?) {
        launchReady {
            if (visibleId != tabId) visibleId?.let(::cancelFollowLoad)
            visibleId = tabId
            syncFollower()
            syncOverviewSweep()
            tabId?.let { startLoad(it) }
        }
    }
    /** Each overview owns a token, so disposing a sheet leaves the desk registered. */
    fun noteOverviewVisible(owner: Any, visible: Boolean) {
        launchReady {
            if (visible) {
                if (!overviewOwners.add(owner)) return@launchReady
                overviewSweepJob?.cancel()
            } else if (!overviewOwners.remove(owner)) return@launchReady
            syncOverviewSweep()
        }
    }
    fun titleLearned(tabId: String, title: String) {
        launchReady {
            val current = tab(tabId) ?: return@launchReady
            if (title.isEmpty() || title == current.title) return@launchReady
            applyAction(SharedArtifactsAction.TitleLearned(tabId, title, clock()))
        }
    }
    fun canKeepAsRule(tabId: String): Boolean = pages.canKeep(tabId)
    fun keepAsRule(tabId: String) {
        launchReady {
            val tab = tab(tabId) ?: return@launchReady
            if (!pages.canKeep(tabId)) return@launchReady
            // Every tab sharing the temporary forward moves to the saved rule.
            try { (pages.keep(tab) + tabId).forEach { id -> if (tab(id) != null) startLoad(id, force = true) } }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) {
                contents[tabId] = ArtifactContent.Unavailable(ArtifactUnavailable.Failed(artifactFailureMessage(failure, R.string.artifacts_save_rule_failed, limit = 200)))
                bump()
            }
        }
    }

    /** The browser's overview-or-tab route, in memory for the process; the tab is the persisted selection. */
    internal val browserRoute = ArtifactsBrowserRoute()

    val quickOpenHosts: List<SharedArtifactsQuickOpenHost> get() = hosts.hosts()
    private fun context(hostId: String?): SharedArtifactsQuickOpenContext = SharedArtifactsQuickOpenContext(
        quickOpenHosts, hostId, hosts.cwd(hostId), hostId?.let(ports::get).orEmpty(), hosts.activeForwards(),
    )
    fun quickOpenSuggestions(input: String, currentHostId: String?): List<SharedArtifactsSuggestion> =
        prepareQuickOpenSuggestions(input, currentHostId).invoke()

    internal fun prepareQuickOpenSuggestions(input: String, currentHostId: String?): () -> List<SharedArtifactsSuggestion> {
        currentHostId?.let(::probePorts)
        val snapshot = state.value.let { it.copy(tabs = it.tabs.toList()) }
        val searchContext = context(currentHostId).let {
            it.copy(hosts = it.hosts.toList(), listeningPorts = it.listeningPorts.toList(), activeForwards = it.activeForwards.toList())
        }
        val recentSnapshot = recents.values.toList()
        return { SharedArtifacts.quickOpenSuggestions(input, snapshot, searchContext, recentSnapshot) }
    }
    /** Typed or picked input. [placement] says whether it opens a new tab or navigates the address bar's tab. */
    suspend fun quickOpen(
        input: String, currentHostId: String?, placement: ArtifactOpenPlacement = ArtifactOpenPlacement.NewTab,
    ): ArtifactQuickOpenOutcome = withContext(scope.coroutineContext.minusKey(Job)) {
        initialization.await()
        when (val intent = parseQuickOpen(input, context(currentHostId))) {
            is SharedArtifactsQuickOpenIntent.Invalid -> ArtifactQuickOpenOutcome.Failed(artifactQuickOpenFailure(intent.reason))
            is SharedArtifactsQuickOpenIntent.Search -> {
                val suggestion = SharedArtifacts.quickOpenSuggestions(input, state.value, context(currentHostId), recents.values.toList()).firstOrNull { it.tabId != null }
                val id = suggestion?.tabId
                if (id == null) ArtifactQuickOpenOutcome.Failed(ArtifactMessage.Resource(R.string.artifacts_no_matching_artifact))
                else { applyAction(SharedArtifactsAction.Select(id, clock())); startLoad(id); mutableOpened.tryEmit(Unit); ArtifactQuickOpenOutcome.Opened(id) }
            }
            is SharedArtifactsQuickOpenIntent.Directory -> {
                if (intent.path == "~" || intent.path.startsWith("~/")) quickOpenFile(intent.hostId, intent.path, placement)
                else ArtifactQuickOpenOutcome.Directory(intent.hostId, intent.path)
            }
            is SharedArtifactsQuickOpenIntent.File -> quickOpenFile(intent.hostId, intent.path, placement)
            is SharedArtifactsQuickOpenIntent.Page -> openOutcome(ArtifactOpenRequest.Page(intent.hostId, intent.scheme, intent.port, intent.path, com.bambouville.tessera.design.ArtifactOpenOrigin.QuickOpen), placement)
        }
    }
    /** Home may only become available after Files connects, so resolve tilde on that channel. */
    private suspend fun quickOpenFile(hostId: String, path: String, placement: ArtifactOpenPlacement): ArtifactQuickOpenOutcome {
        return try {
            val files = hosts.files(hostId) ?: hosts.openableFiles(hostId)?.let { openable ->
                openable.openArtifactChannel()
                currentCoroutineContext().ensureActive()
                hosts.files(hostId)
            }
            val connectionGeneration = files?.artifactConnectionGeneration
            fun connectionCurrent(): Boolean = files == null ||
                hosts.files(hostId) === files && files.artifactConnectionGeneration == connectionGeneration
            val resolved = if (path == "~" || path.startsWith("~/")) {
                val connected = files ?: return ArtifactQuickOpenOutcome.Failed(ArtifactMessage.Resource(R.string.artifacts_home_unavailable))
                val home = connected.artifactHome ?: connected.realPathArtifactOnLiveChannel(".")
                    ?: return ArtifactQuickOpenOutcome.Failed(ArtifactMessage.Resource(R.string.artifacts_home_unavailable))
                currentCoroutineContext().ensureActive()
                if (!connectionCurrent()) return ArtifactQuickOpenOutcome.Failed(ArtifactMessage.Resource(R.string.artifacts_files_connection_unavailable))
                val expanded = home + if (path == "~") "" else path.drop(1)
                connected.realPathArtifactOnLiveChannel(expanded)
                    ?: return ArtifactQuickOpenOutcome.Failed(ArtifactMessage.Resource(R.string.artifacts_files_connection_unavailable))
            } else path
            currentCoroutineContext().ensureActive()
            if (!connectionCurrent()) return ArtifactQuickOpenOutcome.Failed(ArtifactMessage.Resource(R.string.artifacts_files_connection_unavailable))
            val stat = files?.statArtifactOnLiveChannel(resolved)
            currentCoroutineContext().ensureActive()
            if (!connectionCurrent()) return ArtifactQuickOpenOutcome.Failed(ArtifactMessage.Resource(R.string.artifacts_files_connection_unavailable))
            if (stat?.directory == true) ArtifactQuickOpenOutcome.Directory(hostId, stat.path)
            else openOutcome(ArtifactOpenRequest.File(hostId, resolved, com.bambouville.tessera.design.ArtifactOpenOrigin.QuickOpen), placement)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: java.io.FileNotFoundException) { ArtifactQuickOpenOutcome.Failed(ArtifactMessage.Resource(R.string.artifacts_file_not_found)) }
        catch (failure: Exception) { ArtifactQuickOpenOutcome.Failed(artifactFailureMessage(failure, R.string.artifacts_open_file_failed, limit = 200)) }
    }
    private fun openOutcome(request: ArtifactOpenRequest, placement: ArtifactOpenPlacement): ArtifactQuickOpenOutcome {
        val id = when (placement) {
            ArtifactOpenPlacement.NewTab -> openNow(request, newTab = true)
            is ArtifactOpenPlacement.Navigate -> navigateNow(placement.tabId, request) ?: openNow(request, newTab = true)
        }
        return id?.let { ArtifactQuickOpenOutcome.Opened(it) } ?: ArtifactQuickOpenOutcome.Failed(ArtifactMessage.Resource(R.string.artifacts_open_artifact_failed))
    }

    fun updateHosts(directory: List<SharedArtifactsQuickOpenHost>, hostSshPorts: Map<String, Int> = emptyMap()) {
        launchReady {
            if (!hostDirectoryLoaded) onHostsLoaded(directory.map { it.id }.toSet())
            hostDirectoryLoaded = true
            // Includes hosts whose tabs were already closed: their web profile outlives the tabs.
            val removedProfileHosts = (hosts.directory.map { it.id } + state.value.tabs.map { it.hostId }).toSet() -
                directory.map { it.id }.toSet()
            hosts.update(directory)
            sshPorts = hostSshPorts.toMap()
            val labels = directory.associate { it.id to it.label }
            recents.entries.removeAll { (_, recent) ->
                when (val intent = recent.intent) {
                    is SharedArtifactsQuickOpenIntent.File -> intent.hostId !in labels
                    is SharedArtifactsQuickOpenIntent.Page -> intent.hostId !in labels
                    else -> true
                }
            }
            hostReconciliationActions(state.value).forEach { applyAction(it) }
            closedTabs.retainHosts(labels.keys)
            if (removedProfileHosts.isNotEmpty()) onHostsRemoved(removedProfileHosts)
            bump()
            updateLiveness()
            val pending = pendingLoads.toMap()
            pendingLoads.clear()
            pending.forEach { (id, load) -> startLoad(id, load.force, load.staged, load.fromFollow) }
        }
    }
    private fun hostReconciliationActions(snapshot: SharedArtifactsState): List<SharedArtifactsAction> {
        if (!hostDirectoryLoaded) return emptyList()
        val labels = hosts.directory.associate { it.id to it.label }
        return buildList {
            snapshot.tabs.map { it.hostId }.distinct().filter { it !in labels }.forEach {
                add(SharedArtifactsAction.HostRemoved(it, clock()))
            }
            snapshot.tabs.filter { it.hostId in labels && labels[it.hostId] != it.hostLabel }.map { it.hostId }.distinct().forEach {
                add(SharedArtifactsAction.HostRelabelled(it, checkNotNull(labels[it]), clock()))
            }
        }
    }
    fun updateDirectories(directories: Map<String, String>) { launchReady { hosts.updateDirectories(directories); bump() } }

    /** Called by the app's Agent Center observer; relative edits need an explicit proven cwd. */
    fun agentEditObserved(hostId: String, path: String, diff: String, editId: String, cwd: String?, editedAtMillis: Long? = null) {
        launchReady {
            val fingerprint = MessageDigest.getInstance("SHA-256").digest("$hostId\u0000$editId\u0000$path\u0000$diff".encodeToByteArray()).joinToString("") { "%02x".format(it.toInt() and 0xff) }
            if (fingerprint in seenEdits) return@launchReady
            val fileTabs = state.value.tabs.filter { it.hostId == hostId && it.target is SharedArtifactsTarget.File }
            if (fileTabs.isEmpty()) return@launchReady
            if (!path.startsWith('/') && cwd == null) {
                recordSkippedEdit(fingerprint, "missing_cwd")
                return@launchReady
            }
            val absolute = if (path.startsWith('/') && path.none(Char::isISOControl)) path else {
                val parsed = parseQuickOpen(path, SharedArtifactsQuickOpenContext(quickOpenHosts, hostId, cwd, emptyList()))
                (parsed as? SharedArtifactsQuickOpenIntent.File)?.path
            }
            if (absolute == null) {
                recordSkippedEdit(fingerprint, "unresolved_path")
                return@launchReady
            }
            seenEdits.add(fingerprint)
            while (seenEdits.size > 4_096) seenEdits.remove(seenEdits.first())
            // Replayed history predating the fetched bytes is already represented.
            val normalized = normalizedEditPath(absolute)
            val matching = fileTabs.filter { normalizedEditPath(it.target.path) == normalized }
            if (matching.isEmpty()) return@launchReady
            if (editedAtMillis != null && matching.all { (it.cache?.fetchedAt ?: Long.MIN_VALUE) >= editedAtMillis }) return@launchReady
            val now = editedAtMillis ?: clock()
            if (matching.all { it.unseenChange && it.agentEditedAt == now && it.cache?.isStale != false }) return@launchReady
            applyAction(SharedArtifactsAction.AgentEditObserved(hostId, absolute, now))
        }
    }

    // The reducer removes empty and "." components; ".." and Unicode spelling stay literal.
    private fun normalizedEditPath(path: String): String = path.split('/').filter { it.isNotEmpty() && it != "." }
        .joinToString("/", prefix = if (path.startsWith('/')) "/" else "")

    private fun recordSkippedEdit(fingerprint: String, reason: String) {
        if (skippedEdits.add(fingerprint)) recordDiagnostic("artifacts_agent_edit_skipped", mapOf("reason" to reason))
        while (skippedEdits.size > 1_024) skippedEdits.remove(skippedEdits.first())
    }

    fun setForeground(value: Boolean) {
        launchReady {
            val returning = value && !foreground
            if (returning) foregroundGeneration += 1
            foregroundChanges.value = value
            if (value && stateRestorePending) restoreState(retry = true)
            if (!value) followLoads.keys.toList().forEach(::cancelFollowLoad)
            syncFollower()
            syncOverviewSweep()
            if (value) {
                updateLiveness()
                if (returning) visibleId?.let(::tab)?.takeIf {
                    it.id in imageRefreshShortfalls && hosts.files(it.hostId) != null
                }?.let { startLoad(it.id) }
            }
        }
    }
    /** Main captures the latest generation before ON_STOP; the IO consumer writes it later. */
    fun flush() {
        if (!initialization.isCompleted) { launchReady { flush() }; return }
        if (generation == 0L) return
        persistJob?.cancel()
        stateWriter.enqueue(state.value, generation)
    }

    private fun applyAction(action: SharedArtifactsAction): SharedArtifactsReduction? {
        val old = state.value
        val reduction = try { reduceAction(old, action) } catch (failure: Exception) {
            recordDiagnostic("artifacts_action_failed", mapOf("action" to action.javaClass.simpleName))
            return null
        }
        if (old != reduction.state) {
            val protectionChanged = loader.protect(reduction.state.tabs, reduction.state.selectedId, loads.filterValues { it.isActive }.keys)
            mutableState.value = reduction.state
            generation += 1
            persistJob?.cancel()
            val snapshot = reduction.state
            val snapshotGeneration = generation
            persistJob = scope.launch {
                delay(500)
                stateWriter.enqueue(snapshot, snapshotGeneration)
            }
            val removed = old.tabs.map { it.id }.toSet() - reduction.state.tabs.map { it.id }.toSet()
            // A navigated tab keeps its ID; what was loaded for its old target goes.
            val previous = old.tabs.associateBy { it.id }
            reduction.state.tabs.forEach { tab ->
                val before = previous[tab.id] ?: return@forEach
                if (before.target == tab.target && before.hostId == tab.hostId) return@forEach
                loads.remove(tab.id)?.cancel(); cachedDocuments.remove(tab.id); pendingLoads.remove(tab.id)
                cacheIndexJobs.remove(tab.id)?.cancel()
                documentRefreshIntents.remove(tab.id)
                imageRefreshIntents.remove(tab.id)
                imageRefreshShortfalls.remove(tab.id)
                filesConnecting.remove(tab.id)
                filesReconnectFailures.remove(tab.id)
                followLoads.remove(tab.id)
                val from = before.target as? SharedArtifactsTarget.Page
                val to = tab.target as? SharedArtifactsTarget.Page
                if (from == null || to == null || before.hostId != tab.hostId || from.scheme != to.scheme || from.port != to.port) contents.remove(tab.id)
                // A page that became a file no longer uses its forward; a page
                // on another port lets go of it in its next load.
                if (from != null && to == null) scope.launch { pages.close(tab.id) }
            }
            removed.forEach { id ->
                overviewSweepPending.remove(id)
                overviewSweepOrder.remove(id)
                loads.remove(id)?.cancel(); contents.remove(id); cachedDocuments.remove(id); pendingLoads.remove(id)
                cacheIndexJobs.remove(id)?.cancel()
                documentRefreshIntents.remove(id)
                imageRefreshIntents.remove(id)
                imageRefreshShortfalls.remove(id)
                filesConnecting.remove(id)
                filesReconnectFailures.remove(id)
                scope.launch { pages.close(id) }
            }
            val remainingProtectionChanged = loader.protect(reduction.state.tabs, reduction.state.selectedId, loads.filterValues { it.isActive }.keys)
            if (protectionChanged || remainingProtectionChanged || old.selectedId != reduction.state.selectedId ||
                action is SharedArtifactsAction.Pin && !action.pinned || removed.isNotEmpty()
            ) scope.launch { evictCache() }
            if (visibleId in removed) visibleId = null
            syncFollower()
            syncOverviewSweep()
            bump()
        }
        if (action is SharedArtifactsAction.Open || action is SharedArtifactsAction.Select) {
            reduction.focusedTabId?.let(::tab)?.let { tab ->
                val intent = when (val target = tab.target) {
                    is SharedArtifactsTarget.File -> SharedArtifactsQuickOpenIntent.File(tab.hostId, target.path)
                    is SharedArtifactsTarget.Page -> SharedArtifactsQuickOpenIntent.Page(tab.hostId, target.scheme, target.port, target.path)
                    is SharedArtifactsTarget.Change -> null
                }
                if (intent != null) {
                    val key = loader.cacheDirectory(tab).name
                    recents.remove(key)
                    recents[key] = SharedArtifactsRecent(tab.title, "${tab.hostLabel} · ${tab.target.path}", intent, tab.viewedAt)
                    while (recents.size > 64) recents.remove(recents.keys.first())
                }
            }
        }
        return reduction
    }

    private fun imageRefreshOpportunity(hostId: String) = ImageRefreshOpportunity(
        filesGenerations[hostId] ?: 0, foregroundGeneration,
    )

    private fun startLoad(id: String, force: Boolean = false, staged: File? = null, fromFollow: Boolean = false) {
        val snapshot = tab(id) ?: return
        if (!hostDirectoryLoaded) {
            pendingLoads[id] = PendingLoad(force, staged, fromFollow)
            return
        }
        val documentRefreshIntent = documentRefreshIntents[id]
        val imageRefreshIntent = imageRefreshIntents[id]
        val imageOpportunity = imageRefreshOpportunity(snapshot.hostId)
        val retryImages = imageRefreshIntent != null || id in imageRefreshShortfalls
        val imagesCurrent = !retryImages ||
            imageRefreshShortfalls[id] == imageOpportunity && snapshot.cache?.isStale == false && !fromFollow
        if (!force && staged == null && (loads[id]?.isActive == true ||
                documentRefreshIntent == null && imagesCurrent && contents[id]?.let { it !is ArtifactContent.Unavailable && it !== ArtifactContent.Loading } == true)) return
        loads.remove(id)?.cancel()
        // Retry images from accepted bytes; document refreshes and observed changes still fetch.
        val fetchDocument = documentRefreshIntent != null || !retryImages || snapshot.cache?.isStale != false || fromFollow
        val readableDocument = (contents[id] as? ArtifactContent.Document)?.takeIf { !force && staged == null && !fetchDocument }
        // Keep the viewer mounted and spend this opportunity even if staging is cancelled.
        if (readableDocument == null) contents[id] = ArtifactContent.Loading
        else imageRefreshShortfalls[id] = imageOpportunity
        bump()
        val token = ++reloadToken
        if (fromFollow) followLoads[id] = token else followLoads.remove(id)
        loader.protect(state.value.tabs, state.value.selectedId, loads.filterValues { it.isActive }.keys + id)
        loads[id] = scope.launch {
            var imageShortfall = false
            try {
                var documentAccepted = false
                val result = if (snapshot.target is SharedArtifactsTarget.Page) ArtifactLoadResult(pages.load(snapshot)) else loader.load(
                    snapshot, token, staged, forceImages = imageRefreshIntent != null, fetchDocument = fetchDocument,
                    onDocumentAccepted = if (documentRefreshIntent == null) null else { cache ->
                        withContext(scope.coroutineContext.minusKey(Job)) {
                            val current = tab(id)
                            if (current?.hostId == snapshot.hostId && current.target == snapshot.target) {
                                if (documentRefreshIntents[id] == documentRefreshIntent) documentRefreshIntents.remove(id)
                                applyAction(SharedArtifactsAction.Fetched(id, cache, clock()))
                                documentAccepted = true
                            }
                        }
                    },
                )
                val cached = if (snapshot.target is SharedArtifactsTarget.File) loader.cached(snapshot, token) else null
                val current = tab(id)?.takeIf { it.hostId == snapshot.hostId && it.target == snapshot.target } ?: return@launch
                currentCoroutineContext().ensureActive()
                if (snapshot.target is SharedArtifactsTarget.File && imageRefreshIntents[id] == imageRefreshIntent) {
                    if (imageRefreshIntent != null && result.forcedImagesComplete) imageRefreshIntents.remove(id)
                    if (result.imagesFellShort || retryImages && !result.forcedImagesComplete) {
                        // A late failure spends its starting opportunity, never a newer reconnect or foreground.
                        imageRefreshShortfalls[id] = imageOpportunity
                        imageShortfall = true
                    } else imageRefreshShortfalls.remove(id)
                }
                cacheIndexJobs.remove(id)?.cancel()
                if (cached != null) cachedDocuments[id] = cached else if (readableDocument == null) cachedDocuments.remove(id)
                if (readableDocument == null || result.content is ArtifactContent.Document) contents[id] = result.content
                result.cache?.takeUnless { documentAccepted }?.let {
                    val now = clock()
                    if (it.size >= 0 && (current.cache != it.copy(fetchedAt = now, isStale = false) || current.unseenChange)) {
                        applyAction(SharedArtifactsAction.Fetched(id, it, now))
                    }
                }
                bump()
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (failure: Exception) {
                if (tab(id) != null) {
                    cacheIndexJobs.remove(id)?.cancel()
                    if (readableDocument == null) contents[id] = ArtifactContent.Unavailable(ArtifactUnavailable.Failed(artifactFailureMessage(failure, R.string.artifacts_open_artifact_failed, limit = 200)))
                    else imageShortfall = true
                    bump()
                }
            } finally {
                val ownsLoad = loads[id] === currentCoroutineContext()[Job]
                if (ownsLoad) loads.remove(id)
                if (followLoads[id] == token) followLoads.remove(id)
                loader.protect(state.value.tabs, state.value.selectedId, loads.filterValues { it.isActive }.keys)
                scope.launch { evictCache() }
                if (ownsLoad && imageShortfall && currentCoroutineContext().isActive && foreground && visibleId == id) {
                    val nextOpportunity = imageRefreshOpportunity(snapshot.hostId)
                    if (nextOpportunity != imageOpportunity && hosts.files(snapshot.hostId) != null) startLoad(id)
                }
            }
        }
    }

    private suspend fun evictCache() {
        // Until the persisted tabs are restored, their caches look like orphans,
        // and the loader would also mark recovery done against no tabs.
        if (stateRestorePending) return
        val evicted =loader.evict(state.value.tabs, state.value.selectedId, loads.filterValues { it.isActive }.keys)
        if (evicted.isEmpty()) return
        val ids = state.value.tabs.filter { it.target is SharedArtifactsTarget.File && loader.cacheDirectory(it).name in evicted }.map { it.id }
        // A fetch that waited out its entry's deletion has already published a
        // fresh copy, and its page keeps its state. Only documents whose file
        // went with the entry are dropped.
        val published = ids.flatMap { listOfNotNull(contents[it] as? ArtifactContent.Document, cachedDocuments[it]) }
        val gone = loader.missing(published.map { it.file })
        val stale = published.filter { it.file in gone }
        for (id in ids) {
            if (stale.any { it === contents[id] }) contents.remove(id)
            if (stale.any { it === cachedDocuments[id] }) cachedDocuments.remove(id)
        }
        state.value.selectedId?.takeIf { it in ids && it !in contents && loads[it]?.isActive != true }?.let { startLoad(it) }
        bump()
    }

    private fun cancelFollowLoad(id: String) {
        if (followLoads.remove(id) == null) return
        loads.remove(id)?.cancel()
        if (contents[id] === ArtifactContent.Loading) contents.remove(id)
        updateCacheProtection()
        bump()
    }

    private suspend fun statVisible(id: String) {
        val snapshot = tab(id) ?: return
        if (snapshot.target !is SharedArtifactsTarget.File || !foreground || visibleId != id || loads[id]?.isActive == true) return
        val stat = try { hosts.files(snapshot.hostId)?.statArtifactOnLiveChannel(snapshot.target.path) }
        catch (_: java.io.FileNotFoundException) {
            if (foreground && visibleId == id && loads[id]?.isActive != true && tab(id)?.target == snapshot.target) {
                contents[id] = ArtifactContent.Unavailable(ArtifactUnavailable.Missing); bump()
            }
            return
        } ?: return
        val current = tab(id) ?: return
        if (!foreground || visibleId != id || current.hostId != snapshot.hostId || current.target != snapshot.target || loads[id]?.isActive == true) return
        if (stat.directory) {
            contents[id] = ArtifactContent.Unavailable(ArtifactUnavailable.Missing)
            bump()
            return
        }
        val cache = current.cache
        if (cache != null) {
            val changed = stat.modifiedAtMillis?.let { it != cache.remoteMTime } == true || stat.size?.let { it >= 0 && it != cache.size } == true
            if (changed && (!cache.isStale || current.unseenChange != (state.value.selectedId != id))) {
                applyAction(SharedArtifactsAction.RemoteStatObserved(id, stat.modifiedAtMillis, stat.size, true, clock()))
            }
        }
        if (tab(id)?.cache?.isStale == true || tab(id)?.cache == null || contents[id] is ArtifactContent.Unavailable) startLoad(id, force = true, fromFollow = true)
    }
    private fun syncFollower() { follower.update(visibleId?.let(::tab), foreground) }
    private fun canSweepOverviewTab(tab: SharedArtifactTab): Boolean =
        tab.id != visibleId && tab.cache != null && tab.target is SharedArtifactsTarget.File && hosts.files(tab.hostId) != null

    private fun syncOverviewSweep() {
        val dropped = overviewSweepConnections.any { (hostId, connection) ->
            hosts.files(hostId) !== connection.files || connection.files.artifactConnectionGeneration != connection.generation
        }
        if (!foreground || overviewOwners.isEmpty() || state.value.tabs.none(::canSweepOverviewTab) || dropped) {
            overviewSweepJob?.cancel()
            return
        }
        if (overviewSweepJob != null) return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            while (isActive) {
                sweepOverviewFiles()
                delay(15_000)
            }
        }
        overviewSweepJob = job
        job.invokeOnCompletion {
            if (overviewSweepJob === job) {
                overviewSweepJob = null
                overviewSweepConnections.clear()
                if (scope.isActive) syncOverviewSweep()
            }
        }
        job.start()
    }

    private suspend fun sweepOverviewFiles() {
        val eligible = state.value.tabs.filter(::canSweepOverviewTab).sortedByDescending { it.viewedAt }
        val byId = eligible.associateBy { it.id }
        overviewSweepOrder.retainAll(byId.keys)
        overviewSweepPending.retainAll(byId.keys)
        eligible.forEach { if (overviewSweepOrder.add(it.id)) overviewSweepPending.addLast(it.id) }
        if (overviewSweepPending.isEmpty()) overviewSweepPending.addAll(overviewSweepOrder)
        val tabs = overviewSweepPending.take(16).mapNotNull(byId::get)
        overviewSweepConnections.clear()
        tabs.forEach { tab -> hosts.files(tab.hostId)?.let { files ->
            overviewSweepConnections[tab.hostId] = OverviewConnection(files, files.artifactConnectionGeneration)
        } }
        for (snapshot in tabs) {
            currentCoroutineContext().ensureActive()
            if (!foreground || overviewOwners.isEmpty()) return
            val current = tab(snapshot.id) ?: continue
            if (current.hostId != snapshot.hostId || current.target != snapshot.target || !canSweepOverviewTab(current)) continue
            val connection = overviewSweepConnections[snapshot.hostId] ?: continue
            if (hosts.files(snapshot.hostId) !== connection.files || connection.files.artifactConnectionGeneration != connection.generation) return
            overviewSweepPending.remove(snapshot.id)
            overviewSweepOrder.remove(snapshot.id)
            overviewSweepOrder.add(snapshot.id)
            val stat = try { connection.files.statArtifactOnLiveChannel(snapshot.target.path) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { continue } ?: continue
            currentCoroutineContext().ensureActive()
            if (!foreground || overviewOwners.isEmpty() || hosts.files(snapshot.hostId) !== connection.files ||
                connection.files.artifactConnectionGeneration != connection.generation) return
            val latest = tab(snapshot.id) ?: continue
            if (latest.hostId != snapshot.hostId || latest.target != snapshot.target || latest.id == visibleId || latest.cache != current.cache) continue
            applyAction(SharedArtifactsAction.RemoteStatObserved(snapshot.id, stat.modifiedAtMillis, stat.size, false, clock()))
        }
    }

    private suspend fun updateLiveness() {
        var changed = false
        val ids = (hosts.directory.map { it.id } + state.value.tabs.map { it.hostId }).toSet()
        filesChannels.keys.retainAll(ids)
        filesOpenable.keys.retainAll(ids)
        filesChannelGenerations.keys.retainAll(ids)
        filesGenerations.keys.retainAll(ids)
        for (id in ids) {
            val channel = hosts.files(id)
            val filesLive = channel != null
            val openable = !filesLive && hosts.openableFiles(id) != null
            if (filesOpenable.put(id, openable) != openable) changed = true
            val value = filesLive to (filesLive || hosts.forwarding(id).isNotEmpty())
            val previous = liveness.put(id, value)
            val previousChannel = filesChannels.put(id, channel)
            val channelGeneration = channel?.artifactConnectionGeneration ?: 0L
            val previousChannelGeneration = filesChannelGenerations.put(id, channelGeneration)
            val filesFlipped = previous?.first != value.first
            // Another session or held connection is an image opportunity, not a reconnect of the document.
            val filesReplaced = !filesFlipped && filesLive &&
                (previousChannel !== channel || previousChannelGeneration != channelGeneration)
            if (filesFlipped || filesReplaced) filesGenerations[id] = ++filesGeneration
            if (previous == value && !filesReplaced) continue
            changed = true
            state.value.tabs.filter { it.hostId == id }.forEach { tab ->
                if (tab.target is SharedArtifactsTarget.File && filesFlipped || tab.target is SharedArtifactsTarget.Page && previous?.second != value.second) {
                    loads.remove(tab.id)?.cancel()
                    contents.remove(tab.id)
                    if (foreground && tab.id == visibleId) startLoad(tab.id, force = true)
                } else if (filesReplaced && foreground && tab.id == visibleId && tab.id in imageRefreshShortfalls) {
                    startLoad(tab.id)
                }
            }
        }
        for (id in pages.sweep()) {
            contents.remove(id)
            if (foreground && id == visibleId) startLoad(id, force = true)
            changed = true
        }
        syncFollower()
        syncOverviewSweep()
        if (changed) { updateCacheProtection(); bump() }
    }
    private fun probePorts(hostId: String) {
        if (!foreground || probeJobs[hostId]?.isActive == true || clock() - (probedAt[hostId] ?: Long.MIN_VALUE / 2) < 5_000) return
        val live = hosts.files(hostId) ?: return
        probedAt[hostId] = clock()
        probeJobs[hostId] = scope.launch {
            val output = live.probeOnLiveChannel(SharedArtifacts.listeningPortsCommand()) ?: return@launch
            ports[hostId] = SharedArtifacts.listeningPortsParse(output, sshPorts[hostId])
            bump()
        }
    }
    private fun updateCacheProtection() {
        if (loader.protect(state.value.tabs, state.value.selectedId, loads.filterValues { it.isActive }.keys)) {
            scope.launch { evictCache() }
        }
    }
    private fun launchReady(block: suspend CoroutineScope.() -> Unit): Job = scope.launch {
        initialization.await()
        block()
    }
    private fun bump() { mutableRevision.update { it + 1 } }
}
