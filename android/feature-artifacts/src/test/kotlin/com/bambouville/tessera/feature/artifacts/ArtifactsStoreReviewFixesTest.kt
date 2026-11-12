package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactRemoteStat
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import com.bambouville.tessera.forwarding.BoundForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardingLease
import java.io.File
import java.io.FileNotFoundException
import java.io.OutputStream
import java.io.RandomAccessFile
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.coroutines.Continuation
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** These exercise platform wiring with policy fakes, without JNI or a host. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ArtifactsStoreReviewFixesTest {
    @get:Rule val temporary = TemporaryFolder()
    private class Rules : PortForwardRuleStore {
        override fun observe(hostId: String) = MutableStateFlow(emptyList<PortForwardRule>())
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) = error("must not save a rule")
        override suspend fun delete(hostId: String) = Unit
    }
    private class Files : ArtifactLiveFiles {
        var live = true
        override val hasLiveArtifactChannel get() = live
        override val artifactHome: String? = null
        override val artifactDirectory: String? = null
        var reads = 0
        var beforeRead: () -> Unit = {}
        var connectionAttempts = 0
        var pageLease: PortForwardingLease? = null
        var forwardingRequests = 0
        var beforeForwarding: () -> Unit = {}
        fun connect(): Nothing { connectionAttempts += 1; error("artifacts must never connect") }
        var stat: suspend (String) -> ArtifactRemoteStat? = { ArtifactRemoteStat(it, 3, 10, false) }
        override suspend fun statArtifactOnLiveChannel(path: String) = stat(path)
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat {
            beforeRead()
            reads += 1
            output.write("doc".encodeToByteArray())
            return ArtifactRemoteStat(path, 3, 10, false)
        }
        override suspend fun probeOnLiveChannel(command: String): String? = null
        override suspend fun acquireForwardingLeaseOnLiveChannel(rule: PortForwardRule): PortForwardingLease? {
            beforeForwarding()
            forwardingRequests += 1
            return pageLease
        }
    }
    private fun tab(id: String, host: String = "other", pinned: Boolean = false) = SharedArtifactTab(
        id, host, host, SharedArtifactsTarget.File("/work/$id.txt"), SharedArtifactsKind.Docs,
        "$id.txt", "files", null, 1, 1, pinned, SharedArtifactsCacheMetadata(1, 10, 3), false, null,
    )
    private fun key(tab: SharedArtifactTab) = tab.id.repeat(64)
    private data class Fixture(val store: ArtifactsStore, val loader: ArtifactContentLoader, val file: File)
    private fun fixture(
        scope: CoroutineScope,
        dispatcher: CoroutineDispatcher,
        initial: SharedArtifactsState = SharedArtifactsState(),
        files: Files? = null,
        pages: ArtifactPageForwarder? = null,
        reduced: (SharedArtifactsState, SharedArtifactsAction) -> SharedArtifactsReduction = ::reduceFixture,
        loadHosts: Boolean = true,
        onStateRead: () -> Unit = {},
        deleteDirectory: (File) -> Boolean = { it.deleteRecursively() },
    ): Fixture {
        val file = temporary.newFile().apply { writeText("initial") }
        val stateFile = ArtifactsStateFile(file, decode = { onStateRead(); initial }, encode = { it.filter.wireValue })
        val hosts = ArtifactsLiveHosts(findFiles = { id -> files?.takeIf { id == "h" } }, findContext = { files }, findForwarding = { emptyList() })
        val loader = ArtifactContentLoader(temporary.newFolder(), hosts::files, key = ::key,
            viewer = { SharedArtifactsViewer.Text }, evictions = { entries, budget, protected ->
                assertEquals(ArtifactContentLoader.CACHE_BUDGET, budget)
                if (entries.sumOf { it.size } <= budget) emptyList()
                else entries.filter { !it.pinned && it.key !in protected }.map { it.key }
            }, ioDispatcher = dispatcher, deleteDirectory = deleteDirectory)
        val store = ArtifactsStore(stateFile, hosts, loader, pages ?: ArtifactPageForwarder(hosts, Rules()), scope,
            persistenceDispatcher = dispatcher, parseQuickOpen = { _, _ -> SharedArtifactsQuickOpenIntent.File("h", "/work/a.txt") },
            reduceAction = reduced)
        if (loadHosts) store.updateHosts(initial.tabs.map { SharedArtifactsQuickOpenHost(it.hostId, it.hostLabel) }.distinct())
        return Fixture(store, loader, file)
    }
    private fun reduceFixture(state: SharedArtifactsState, action: SharedArtifactsAction): SharedArtifactsReduction {
        val next = when (action) {
            is SharedArtifactsAction.Select -> state.copy(selectedId = action.tabId,
                tabs = state.tabs.map { if (it.id == action.tabId) it.copy(viewedAt = action.nowMillis) else it })
            is SharedArtifactsAction.Pin -> state.copy(tabs = state.tabs.map { if (it.id == action.tabId) it.copy(pinned = action.pinned) else it })
            is SharedArtifactsAction.Close -> state.copy(tabs = state.tabs.filter { it.id != action.tabId })
            is SharedArtifactsAction.CloseAll -> state.copy(tabs = state.tabs.filter { it.hostId != action.hostId })
            is SharedArtifactsAction.HostRemoved -> state.copy(tabs = state.tabs.filter { it.hostId != action.hostId })
            is SharedArtifactsAction.SetFilter -> state.copy(filter = action.filter)
            is SharedArtifactsAction.Fetched -> state.copy(tabs = state.tabs.map { if (it.id == action.tabId) it.copy(cache = action.cache) else it })
            is SharedArtifactsAction.RemoteStatObserved -> state
            else -> error("unexpected fixture action: $action")
        }
        return SharedArtifactsReduction(next, (action as? SharedArtifactsAction.Select)?.tabId, emptyList(), null)
    }

    private class QueuedIoDispatcher(private val delegate: CoroutineDispatcher) : CoroutineDispatcher() {
        private val pending = ArrayDeque<Pair<CoroutineContext, Runnable>>()
        private var held = true
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            if (held) pending.addLast(context to block) else delegate.dispatch(context, block)
        }
        fun release() {
            held = false
            while (pending.isNotEmpty()) {
                val (context, block) = pending.removeFirst()
                delegate.dispatch(context, block)
            }
        }
    }

    @Test fun constructionAndQueuedActionsDoNotReadStateOrCacheUntilIoRecoveryFinishes() = runTest {
        val io = QueuedIoDispatcher(StandardTestDispatcher(testScheduler))
        val initial = tab("a", "h")
        var stateReads = 0
        val fixture = fixture(backgroundScope, io, SharedArtifactsState(tabs = listOf(initial), selectedId = "a"),
            onStateRead = { stateReads += 1 })
        val payload = fixture.loader.cacheFile(initial).apply { parentFile!!.mkdirs(); writeText("saved") }
        val stale = File(payload.parentFile, "images/.staging/artifact-interrupted.tmp").apply { parentFile!!.mkdirs(); writeText("partial") }
        fixture.store.setPinned("a", true)
        fixture.store.noteVisible("a")
        fixture.store.flush()
        assertEquals(0, stateReads)
        runCurrent()
        assertEquals(0, stateReads)
        assertTrue(stale.exists())
        assertTrue(fixture.store.state.value.tabs.isEmpty())
        assertEquals(ArtifactContent.Loading, fixture.store.content("a"))
        io.release()
        runCurrent()
        assertEquals(1, stateReads)
        assertFalse(stale.exists())
        assertTrue(checkNotNull(fixture.store.tab("a")).pinned)
        val document = fixture.store.content("a") as ArtifactContent.Document
        assertEquals("saved", document.file.readText())
        assertEquals("a.txt", File(payload.parentFile, "images/.artifact-content").readText())
        assertEquals("all", fixture.file.readText())
    }

    @Test fun selectingAnAlreadyLoadedTabEvictsThePreviouslySelectedUnpinned64MiBFile() = runTest {
        val tabs = ('a'..'e').map { tab(it.toString(), "h", pinned = true) }
        val files = Files().apply { live = false }
        val fixture = fixture(backgroundScope, StandardTestDispatcher(testScheduler),
            SharedArtifactsState(tabs = tabs, selectedId = "a"), files)
        val payloads = tabs.associate { tab -> tab.id to fixture.loader.cacheFile(tab).apply {
            parentFile!!.mkdirs()
            RandomAccessFile(this, "rw").use { it.setLength(ArtifactContentLoader.MAX_BYTES) }
        } }
        fixture.store.noteVisible("b")
        @Suppress("UNCHECKED_CAST")
        val loaded = fixture.store.javaClass.getDeclaredField("contents").apply { isAccessible = true }.get(fixture.store) as Map<String, ArtifactContent>
        await { loaded["b"] is ArtifactContent.Document }
        fixture.store.setPinned("a", false)
        runCurrent()
        assertTrue(payloads.values.all(File::exists))
        val loadedB = loaded["b"]
        fixture.store.select("b")
        await { !payloads.getValue("a").exists() }
        assertEquals("b", fixture.store.state.value.selectedId)
        assertEquals(loadedB, loaded["b"])
        assertTrue(payloads.filterKeys { it != "a" }.values.all(File::isFile))
        assertEquals(0, files.reads)
        assertEquals(0, files.connectionAttempts)
        assertEquals(0, files.forwardingRequests)
    }

    @Test fun aTabSelectedWhileItsEntryIsDeletedKeepsTheFreshCopyItFetchedOnceTheSweepEnds() = runTest {
        val tabs = ('a'..'f').map { tab(it.toString(), "h", pinned = it != 'b') }
        val files = Files()
        val deleting = LinkedBlockingQueue<String>()
        val releases = listOf(CountDownLatch(1), CountDownLatch(1))
        val fixture = fixture(backgroundScope, Dispatchers.IO, SharedArtifactsState(tabs = tabs, selectedId = "f"), files,
            deleteDirectory = { tombstone ->
                val index = deleting.size
                deleting.add(tombstone.name.removePrefix(".evicting-").take(1))
                check(releases[index].await(5, TimeUnit.SECONDS))
                tombstone.deleteRecursively()
            })
        tabs.forEach { tab -> fixture.loader.cacheFile(tab).apply {
            parentFile!!.mkdirs()
            RandomAccessFile(this, "rw").use { it.setLength(ArtifactContentLoader.MAX_BYTES) }
        } }
        try {
            fixture.store.setPinned("a", false)
            await { deleting.isNotEmpty() }
            val first = checkNotNull(deleting.peek())
            val second = if (first == "a") "b" else "a"
            fixture.store.select(first)
            await { fixture.store.state.value.selectedId == first && fixture.store.content(first) === ArtifactContent.Loading }
            Thread.sleep(100)
            assertEquals(0, files.reads)
            releases[0].countDown()
            // The selected tab refetches while the other unpinned entry is still being deleted.
            await { deleting.size == 2 && fixture.store.content(first) is ArtifactContent.Document }
            val fresh = fixture.store.content(first) as ArtifactContent.Document
            assertEquals(1, files.reads)
            val revision = fixture.store.revision.value
            releases[1].countDown()
            await { !fixture.loader.cacheFile(checkNotNull(fixture.store.tab(second))).exists() && fixture.store.revision.value > revision }
            Thread.sleep(100)
            testScheduler.runCurrent()
            assertTrue(fresh === fixture.store.content(first))
            assertEquals("doc", fresh.file.readText())
            assertEquals(1, files.reads)
            assertEquals(0, files.connectionAttempts)
        } finally { releases.forEach(CountDownLatch::countDown) }
    }

    @Test fun anEvictedTabsDocumentWhoseFileWentWithTheEntryIsDropped() = runTest {
        val tabs = ('a'..'f').map { tab(it.toString(), "h", pinned = true) }
        val files = Files().apply { live = false }
        val fixture = fixture(backgroundScope, StandardTestDispatcher(testScheduler),
            SharedArtifactsState(tabs = tabs, selectedId = "f"), files)
        val payloads = tabs.associate { tab -> tab.id to fixture.loader.cacheFile(tab).apply {
            parentFile!!.mkdirs()
            RandomAccessFile(this, "rw").use { it.setLength(ArtifactContentLoader.MAX_BYTES) }
        } }
        @Suppress("UNCHECKED_CAST")
        val loaded = fixture.store.javaClass.getDeclaredField("contents").apply { isAccessible = true }.get(fixture.store) as Map<String, ArtifactContent>
        fixture.store.noteVisible("b")
        await { loaded["b"] is ArtifactContent.Document }
        fixture.store.noteVisible("f")
        fixture.store.setPinned("b", false)
        await { !payloads.getValue("b").exists() && "b" !in loaded }
        assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.Offline), fixture.store.content("b"))
        assertTrue(payloads.filterKeys { it != "b" }.values.all(File::isFile))
        assertEquals(0, files.reads)
        assertEquals(0, files.connectionAttempts)
    }

    @Test fun cancellingAFollowLoadReenforcesTheBudgetAsSoonAsItsProtectionIsReleased() = runTest {
        val tabs = ('a'..'e').map { tab(it.toString(), "h", pinned = true) }
        val fixture = fixture(backgroundScope, StandardTestDispatcher(testScheduler), SharedArtifactsState(tabs = tabs, selectedId = "a"))
        val payloads = tabs.associate { tab -> tab.id to fixture.loader.cacheFile(tab).apply {
            parentFile!!.mkdirs()
            RandomAccessFile(this, "rw").use { it.setLength(ArtifactContentLoader.MAX_BYTES) }
        } }
        fixture.store.noteVisible("e")
        runCurrent()
        @Suppress("UNCHECKED_CAST")
        val loads = fixture.store.javaClass.getDeclaredField("loads").apply { isAccessible = true }.get(fixture.store) as MutableMap<String, Job>
        @Suppress("UNCHECKED_CAST")
        val follows = fixture.store.javaClass.getDeclaredField("followLoads").apply { isAccessible = true }.get(fixture.store) as MutableMap<String, Long>
        val loading = Job()
        loads["e"] = loading
        follows["e"] = 1L
        try {
            fixture.store.setPinned("e", false)
            runCurrent()
            assertTrue(payloads.values.all(File::exists))
            fixture.store.noteVisible(null)
            runCurrent()
            assertTrue(loading.isCancelled)
            assertFalse(payloads.getValue("e").exists())
            assertTrue(payloads.filterKeys { it != "e" }.values.all(File::isFile))
        } finally { loading.cancel() }
    }

    @Test fun firstSavedHostDirectoryReconcilesAllProfilesOnTheUiScopeBeforeAnyPageLoad() = runTest {
        val caller = Thread.currentThread()
        val files = Files()
        val reconciled = mutableListOf<Set<String>>()
        val removed = mutableListOf<Set<String>>()
        val savedIds = setOf("h", "saved-with-no-session", "saved-with-no-tabs")
        files.beforeForwarding = { assertEquals(listOf(savedIds), reconciled) }
        val lease = object : PortForwardingLease {
            override val bound = BoundForwardEndpoint("127.0.0.1", 45555)
            override val activeConnectionCount = MutableStateFlow(0)
            override val isOpen = MutableStateFlow(true)
            override fun close() { isOpen.value = false }
        }
        files.pageLease = lease
        val hosts = ArtifactsLiveHosts(findFiles = { id -> files.takeIf { id == "h" } }, findContext = { files }, findForwarding = { emptyList() })
        val rule = PortForwardRule(bind = PortForwardEndpoint("127.0.0.1", 5173), target = PortForwardEndpoint("127.0.0.1", 5173))
        val pages = ArtifactPageForwarder(hosts, Rules(), planForward = { _, _ -> SharedArtifactsForwardPlan.Ephemeral(rule.artifactSharedRule()) },
            webTarget = { SharedForwardedWebTarget("http", it.bind.host, it.bind.port, "http://${it.bind.host}:${it.bind.port}") })
        val page = tab("a", "h").copy(target = SharedArtifactsTarget.Page("http", 5173, "/"), kind = SharedArtifactsKind.Pages)
        val fixture = fixture(backgroundScope, StandardTestDispatcher(testScheduler),
            SharedArtifactsState(tabs = listOf(page), selectedId = "a"), files, pages, loadHosts = false)
        fixture.store.onHostsLoaded = { ids -> assertEquals(caller, Thread.currentThread()); reconciled += ids }
        fixture.store.onHostsRemoved = { removed += it }
        fixture.store.noteVisible("a")
        runCurrent()
        assertTrue(reconciled.isEmpty())
        assertEquals(0, files.forwardingRequests)
        assertEquals(ArtifactContent.Loading, fixture.store.content("a"))
        fixture.store.updateHosts(savedIds.map { SharedArtifactsQuickOpenHost(it, it) })
        try {
            await { fixture.store.content("a") is ArtifactContent.ForwardedPage }
            assertEquals(listOf(savedIds), reconciled)
            assertEquals(1, files.forwardingRequests)
            fixture.store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "h")))
            await { removed.isNotEmpty() }
            assertEquals(listOf(savedIds), reconciled)
            assertEquals(listOf(savedIds - "h"), removed)
            assertEquals(0, files.connectionAttempts)
        } finally { pages.close(page.id) }
    }

    @Test fun anEmptyFirstSavedHostDirectoryStillReconcilesProfilesOnce() = runTest {
        val reconciled = mutableListOf<Set<String>>()
        val fixture = fixture(backgroundScope, StandardTestDispatcher(testScheduler), loadHosts = false)
        fixture.store.onHostsLoaded = { reconciled += it }
        fixture.store.updateHosts(emptyList())
        runCurrent()
        assertEquals(listOf(emptySet<String>()), reconciled)
        fixture.store.updateHosts(listOf(SharedArtifactsQuickOpenHost("saved", "saved")))
        runCurrent()
        assertEquals(listOf(emptySet<String>()), reconciled)
    }

    @Test fun htmlFileLoadsWaitForTheFirstProfileReconciliationToo() = runTest {
        var reconciliations = 0
        val reconciliationsAtRead = mutableListOf<Int>()
        val files = Files().apply { beforeRead = { reconciliationsAtRead += reconciliations } }
        val html = tab("a", "h").copy(target = SharedArtifactsTarget.File("/work/index.html"), kind = SharedArtifactsKind.Pages)
        val fixture = fixture(backgroundScope, StandardTestDispatcher(testScheduler),
            SharedArtifactsState(tabs = listOf(html), selectedId = "a"), files, loadHosts = false)
        fixture.store.onHostsLoaded = { assertEquals(setOf("h", "offline-saved-host"), it); reconciliations += 1 }
        fixture.store.noteVisible("a")
        runCurrent()
        assertEquals(0, files.reads)
        assertEquals(ArtifactContent.Loading, fixture.store.content("a"))
        fixture.store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "h"), SharedArtifactsQuickOpenHost("offline-saved-host", "offline")))
        // The viewer policy fake keeps WebViewClient construction out of this JVM wiring test.
        await { fixture.store.content("a") is ArtifactContent.Document }
        assertEquals(1, reconciliations)
        assertEquals(listOf(1), reconciliationsAtRead)
        assertEquals(1, files.reads)
        assertEquals(0, files.connectionAttempts)
    }

    @Test fun aPageDeferredUntilProfilesAreReconciledStillCannotReconnectAnOfflineHost() = runTest {
        val files = Files().apply { live = false }
        val page = tab("a", "h").copy(target = SharedArtifactsTarget.Page("http", 5173, "/"), kind = SharedArtifactsKind.Pages)
        val fixture = fixture(backgroundScope, StandardTestDispatcher(testScheduler),
            SharedArtifactsState(tabs = listOf(page), selectedId = "a"), files, loadHosts = false)
        fixture.store.noteVisible("a")
        runCurrent()
        assertEquals(ArtifactContent.Loading, fixture.store.content("a"))
        fixture.store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "h")))
        await { fixture.store.content("a") == ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding) }
        assertEquals(0, files.forwardingRequests)
        assertEquals(0, files.reads)
        assertEquals(0, files.connectionAttempts)
    }

    @Test fun flushCapturesTheLatestStateAndReturnsBeforeAnyStorageWork() = runTest {
        val fixture = fixture(backgroundScope, StandardTestDispatcher(testScheduler))
        fixture.store.setFilter(SharedArtifactsFilter.Docs)
        runCurrent()
        fixture.store.flush()
        assertEquals("initial", fixture.file.readText())
        fixture.store.setFilter(SharedArtifactsFilter.Pages)
        runCurrent()
        fixture.store.flush()
        assertEquals("docs", fixture.file.readText())
        runCurrent()
        assertEquals("pages", fixture.file.readText())
    }

    @Test fun aFilesBorrowedPageNeverOffersOrExecutesKeepAsRuleThroughTheStore() = runTest {
        val files = Files()
        val lease = object : PortForwardingLease {
            override val bound = BoundForwardEndpoint("127.0.0.1", 45555)
            override val activeConnectionCount = MutableStateFlow(0)
            override val isOpen = MutableStateFlow(true)
            override fun close() { isOpen.value = false }
        }
        files.pageLease = lease
        val hosts = ArtifactsLiveHosts(findFiles = { files }, findContext = { files }, findForwarding = { emptyList() })
        val rule = PortForwardRule(bind = PortForwardEndpoint("127.0.0.1", 5173), target = PortForwardEndpoint("127.0.0.1", 5173))
        val pages = ArtifactPageForwarder(hosts, Rules(), planForward = { _, _ -> SharedArtifactsForwardPlan.Ephemeral(rule.artifactSharedRule()) },
            webTarget = { SharedForwardedWebTarget("http", it.bind.host, it.bind.port, "http://${it.bind.host}:${it.bind.port}") })
        val page = tab("a", "h").copy(target = SharedArtifactsTarget.Page("http", 5173, "/"), kind = SharedArtifactsKind.Pages)
        val fixture = fixture(backgroundScope, StandardTestDispatcher(testScheduler),
            SharedArtifactsState(tabs = listOf(page), selectedId = page.id), files, pages)
        runCurrent()
        try {
            val content = pages.load(page)
            @Suppress("UNCHECKED_CAST")
            val contents = fixture.store.javaClass.getDeclaredField("contents").apply { isAccessible = true }.get(fixture.store) as MutableMap<String, ArtifactContent>
            contents[page.id] = content
            assertTrue((content as ArtifactContent.ForwardedPage).isEphemeral)
            assertFalse(fixture.store.canKeepAsRule(page.id))
            fixture.store.keepAsRule(page.id)
            runCurrent()
            assertEquals(content, fixture.store.content(page.id))
            assertTrue(lease.isOpen.value)
            assertEquals(0, files.connectionAttempts)
        } finally { pages.close(page.id) }
    }

    @Test fun aCancelledQuickOpenCannotOpenATabAfterANonCancellableStatReturns() = runTest {
        val files = Files()
        var continuation: Continuation<ArtifactRemoteStat?>? = null
        files.stat = { suspendCoroutine { continuation = it } }
        var mutations = 0
        val fixture = fixture(backgroundScope, StandardTestDispatcher(testScheduler), files = files, reduced = { state, _ ->
            mutations += 1
            SharedArtifactsReduction(state, null, emptyList(), null)
        })
        val opening = backgroundScope.async { fixture.store.quickOpen("/work/a.txt", "h") }
        runCurrent()
        assertTrue(continuation != null)
        opening.cancel()
        checkNotNull(continuation).resume(ArtifactRemoteStat("/work/a.txt", 3, 10, false))
        runCurrent()
        try { opening.await(); error("cancelled Quick Open returned") } catch (_: CancellationException) { }
        assertEquals(0, mutations)
        assertTrue(fixture.store.state.value.tabs.isEmpty())
        assertEquals(0, files.connectionAttempts)
    }

    @Test fun unpinReenforcesTheBudgetAndProtectsSelectedAndInFlightFiles() = evictionAfter { it.setPinned("a", false) }
    @Test fun closingATabReenforcesTheBudgetAndProtectsSelectedAndInFlightFiles() = evictionAfter { it.close("a") }
    @Test fun closingAHostReenforcesTheBudgetAndProtectsSelectedAndInFlightFiles() = evictionAfter { it.closeAll("h") }
    @Test fun removingAHostReenforcesTheBudgetAndProtectsSelectedAndInFlightFiles() = evictionAfter {
        it.updateHosts(listOf(SharedArtifactsQuickOpenHost("other", "other")))
    }

    private fun evictionAfter(mutate: (ArtifactsStore) -> Unit) = runTest {
        val tabs = listOf(tab("a", "h", pinned = true), tab("b"), tab("c"))
        val fixture = fixture(backgroundScope, StandardTestDispatcher(testScheduler), SharedArtifactsState(tabs = tabs, selectedId = "b"))
        val directories = tabs.associate { it.id to fixture.loader.cacheDirectory(it).apply {
            mkdirs()
            RandomAccessFile(File(this, "bytes"), "rw").use { file -> file.setLength(ArtifactContentLoader.CACHE_BUDGET + 1) }
        } }
        val loading = Job()
        runCurrent()
        @Suppress("UNCHECKED_CAST")
        val loads = fixture.store.javaClass.getDeclaredField("loads").apply { isAccessible = true }.get(fixture.store) as MutableMap<String, Job>
        loads["c"] = loading
        try {
            runCurrent()
            assertTrue(directories.values.all(File::exists))
            mutate(fixture.store)
            await { !directories.getValue("a").exists() }
            assertTrue(directories.getValue("b").isDirectory)
            assertTrue(directories.getValue("c").isDirectory)
        } finally { loading.cancel(); runCurrent() }
    }

    @Test fun aSuccessfulUnchangedFollowStatRecoversFromATransientMissingFile() = runTest {
        val files = Files()
        val initial = tab("a", "h")
        val fixture = fixture(backgroundScope, StandardTestDispatcher(testScheduler), SharedArtifactsState(tabs = listOf(initial), selectedId = "a"), files)
        fixture.store.noteVisible("a")
        fixture.store.setForeground(true)
        await { fixture.store.content("a") is ArtifactContent.Document }
        val reads = files.reads
        files.stat = { throw FileNotFoundException(it) }
        advanceTimeBy(3_001); runCurrent()
        assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.Missing), fixture.store.content("a"))
        files.stat = { ArtifactRemoteStat(it, 3, 10, false) }
        advanceTimeBy(3_001); runCurrent()
        await { fixture.store.content("a") is ArtifactContent.Document }
        assertTrue(files.reads > reads)
        assertEquals(0, files.connectionAttempts)
    }

    private fun TestScope.await(condition: () -> Boolean) {
        val deadline = System.nanoTime() + 5_000_000_000L
        do {
            runCurrent()
            if (condition()) return
            Thread.sleep(1)
        } while (System.nanoTime() < deadline)
        assertTrue("asynchronous store work did not finish", condition())
    }
}
