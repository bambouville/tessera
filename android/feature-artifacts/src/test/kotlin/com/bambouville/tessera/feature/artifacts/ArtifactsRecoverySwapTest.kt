package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactRemoteStat
import com.bambouville.tessera.forwarding.BoundForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import com.bambouville.tessera.forwarding.PortForwardingLease
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ArtifactsRecoverySwapTest {
    @get:Rule val temporary = TemporaryFolder()

    private class Rules : PortForwardRuleStore {
        override fun observe(hostId: String) = MutableStateFlow(emptyList<PortForwardRule>())
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) = error("must not save a rule")
        override suspend fun delete(hostId: String) = Unit
    }
    private class Lease : PortForwardingLease {
        override val bound = BoundForwardEndpoint("127.0.0.1", 45_555)
        override val activeConnectionCount = MutableStateFlow(0)
        override val isOpen = MutableStateFlow(true)
        val closes = AtomicInteger()
        override fun close() { closes.incrementAndGet(); isOpen.value = false }
    }
    private class Files : ArtifactLiveFiles {
        var live = true
        override val hasLiveArtifactChannel get() = live
        override val artifactHome: String? = null
        override val artifactDirectory: String? = null
        val documentStarted = CompletableDeferred<Unit>()
        val documentFinished = CompletableDeferred<Unit>()
        var documentGate: CompletableDeferred<Unit>? = null
        val acquisitionStarted = CompletableDeferred<Unit>()
        val acquisitionFinished = CompletableDeferred<Unit>()
        var acquisitionGate: CompletableDeferred<Unit>? = null
        val acquisitions = AtomicInteger()
        val lease = Lease()
        var documentReads = 0
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat {
            check(live)
            documentReads++
            documentStarted.complete(Unit)
            // Models a held SFTP read that cannot promptly be interrupted by cancellation.
            withContext(NonCancellable) { documentGate?.await() }
            output.write("new".encodeToByteArray())
            documentFinished.complete(Unit)
            return ArtifactRemoteStat(path, 3, 20, false)
        }
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat = error("must not stat or connect")
        override suspend fun probeOnLiveChannel(command: String): String = error("must not probe or connect")
        override suspend fun acquireForwardingLeaseOnLiveChannel(rule: PortForwardRule): PortForwardingLease {
            acquisitions.incrementAndGet()
            acquisitionStarted.complete(Unit)
            withContext(NonCancellable) { acquisitionGate?.await() }
            acquisitionFinished.complete(Unit)
            return lease
        }
    }
    private data class Fixture(
        val store: ArtifactsStore,
        val loader: ArtifactContentLoader,
        val pages: ArtifactPageForwarder,
        val manifest: File,
        val writes: MutableList<SharedArtifactsState>,
    )
    private fun document(id: String = "saved", host: String = "a", label: String = "old a") = SharedArtifactTab(
        id, host, label, SharedArtifactsTarget.File("/work/report.txt"), SharedArtifactsKind.Docs, "report.txt", "files", null,
        1, 1, true, SharedArtifactsCacheMetadata(1, 10, 3), false, null,
    )
    private fun TestScope.fixture(saved: SharedArtifactsState, unavailable: () -> Boolean = { false }, files: Files? = null,
        publicationDispatcher: CoroutineDispatcher? = null): Fixture {
        val manifest = temporary.newFile().apply { writeText("saved") }
        val writes = mutableListOf<SharedArtifactsState>()
        val stateFile = ArtifactsStateFile(manifest, split = { snapshot ->
            writes += snapshot
            val tabs = JSONArray()
            snapshot.tabs.forEach { tabs.put(JSONObject().put("id", it.id).put("hostID", it.hostId).put("hostLabel", it.hostLabel)) }
            SharedArtifactsPersistenceFiles(JSONObject().put("tabs", tabs).toString(), emptyMap())
        }, blobDigests = { emptyList() }, join = { _, _ -> saved }, readStateBytes = {
            if (unavailable()) throw IOException("temporarily unreadable")
            it.readBytes()
        })
        val hosts = ArtifactsLiveHosts(findFiles = { files }, findContext = { null }, findForwarding = { emptyList() })
        val dispatcher = StandardTestDispatcher(testScheduler)
        val loader = ArtifactContentLoader(temporary.newFolder(), hosts::files, key = { "a".repeat(64) },
            viewer = { SharedArtifactsViewer.Text }, evictions = { _, _, _ -> emptyList() }, ioDispatcher = dispatcher)
        val planned = PortForwardRule(bind = PortForwardEndpoint("127.0.0.1", 5173), target = PortForwardEndpoint("127.0.0.1", 5173))
        val pages = ArtifactPageForwarder(hosts, Rules(), planForward = { _, _ -> SharedArtifactsForwardPlan.Ephemeral(planned.artifactSharedRule()) },
            webTarget = { SharedForwardedWebTarget("http", it.bind.host, it.bind.port, "http://${it.bind.host}:${it.bind.port}") })
        val storeScope = publicationDispatcher?.let { CoroutineScope(backgroundScope.coroutineContext + it) } ?: backgroundScope
        val store = ArtifactsStore(stateFile, hosts, loader, pages, storeScope, persistenceDispatcher = dispatcher,
            cachePresentation = { tab, live, _ -> SharedArtifactsCachePresentation(
                if (live) SharedArtifactsCacheState.Live else if (tab.cache != null) SharedArtifactsCacheState.Cached else SharedArtifactsCacheState.Offline,
                tab.cache?.fetchedAt, live,
            ) },
            reduceAction = { state, action ->
                val next = when (action) {
                    is SharedArtifactsAction.Open -> {
                        val request = action.request
                        val tab = document(request.id, request.hostId, request.hostLabel).copy(target = request.target,
                            kind = if (request.target is SharedArtifactsTarget.Page) SharedArtifactsKind.Pages else SharedArtifactsKind.Docs,
                            title = request.title, pinned = false, cache = null)
                        state.copy(tabs = state.tabs + tab, selectedId = tab.id)
                    }
                    is SharedArtifactsAction.Fetched -> state.copy(tabs = state.tabs.map {
                        if (it.id == action.tabId) it.copy(cache = action.cache.copy(fetchedAt = action.nowMillis)) else it
                    })
                    is SharedArtifactsAction.SetFilter -> state.copy(filter = action.filter)
                    is SharedArtifactsAction.Select -> state.copy(selectedId = action.tabId)
                    is SharedArtifactsAction.Close -> state.copy(tabs = state.tabs.filter { it.id != action.tabId }, selectedId = null)
                    is SharedArtifactsAction.HostRemoved -> {
                        val tabs = state.tabs.filter { it.hostId != action.hostId }
                        state.copy(tabs = tabs, selectedId = state.selectedId?.takeIf { id -> tabs.any { it.id == id } } ?: tabs.firstOrNull()?.id)
                    }
                    is SharedArtifactsAction.HostRelabelled -> state.copy(tabs = state.tabs.map {
                        if (it.hostId == action.hostId) it.copy(hostLabel = action.label) else it
                    })
                    else -> error("unexpected action: $action")
                }
                SharedArtifactsReduction(next, next.selectedId, emptyList(), null)
            })
        return Fixture(store, loader, pages, manifest, writes)
    }

    @Test fun aBusyRestoredCacheBecomesPresentableOfflineAfterItsObsoleteDownloadReleasesTheLock() = runTest {
        val saved = SharedArtifactsState(tabs = listOf(document()), selectedId = "saved")
        var unavailable = true
        val gate = CompletableDeferred<Unit>()
        val files = Files().apply { documentGate = gate }
        val (store, loader, _, _, writes) = fixture(saved, { unavailable }, files)
        val payload = loader.cacheFile(saved.tabs.single()).apply { parentFile!!.mkdirs(); writeText("old") }
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("a", "old a")))
        store.open(ArtifactOpenRequest.File("a", "/work/report.txt", ArtifactOpenOrigin.Files))
        runCurrent()
        assertEquals(1, files.documentReads)
        assertTrue(files.documentStarted.isCompleted)
        try {
            files.live = false
            unavailable = false
            store.setForeground(true)
            runCurrent()
            assertEquals(saved, store.state.value)
            assertEquals(listOf(saved), writes)
            assertFalse(gate.isCompleted) // The state swap and persistence did not wait for the cache lock.
            val revision = store.revision.value
            gate.complete(Unit)
            runCurrent()
            val content = store.content("saved")
            assertTrue("the restored tab must regain its saved copy", content is ArtifactContent.Document)
            assertEquals(payload, (content as ArtifactContent.Document).file)
            assertEquals("old", content.file.readText())
            assertEquals(SharedArtifactsCacheState.Cached, store.presentation("saved").state)
            assertEquals(1L, store.presentation("saved").fetchedAt)
            assertTrue(store.revision.value > revision)
            assertEquals(1, files.documentReads)
            assertEquals(0, files.acquisitions.get())
        } finally { gate.complete(Unit); runCurrent() }
    }

    private class PausingDispatcher(private val delegate: CoroutineDispatcher) : CoroutineDispatcher() {
        var paused = false
        private val held = ArrayDeque<Pair<CoroutineContext, Runnable>>()
        val pendingCount get() = held.size
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            if (paused) held.addLast(context to block) else delegate.dispatch(context, block)
        }
        fun release() {
            paused = false
            while (held.isNotEmpty()) {
                val (context, block) = held.removeFirst()
                delegate.dispatch(context, block)
            }
        }
    }

    @Test fun aRecoveredCacheReadWaitingToPublishCannotOverwriteANewerLoadResult() = runTest {
        val saved = SharedArtifactsState(tabs = listOf(document()), selectedId = "saved")
        var unavailable = true
        val gate = CompletableDeferred<Unit>()
        val files = Files().apply { documentGate = gate }
        val publications = PausingDispatcher(StandardTestDispatcher(testScheduler))
        val (store, loader) = fixture(saved, { unavailable }, files, publications)
        val payload = loader.cacheFile(saved.tabs.single()).apply { parentFile!!.mkdirs(); writeText("old") }
        val oldImage = File(payload.parentFile, "images/old.png").apply { parentFile!!.mkdirs(); writeText("old image") }
        val manifest = File(payload.parentFile, "images.json").apply { writeText("{\"shot.png\":\"old.png\"}") }
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("a", "old a")))
        store.open(ArtifactOpenRequest.File("a", "/work/report.txt", ArtifactOpenOrigin.Files))
        runCurrent()
        assertEquals(1, files.documentReads)
        try {
            unavailable = false
            store.setForeground(true)
            runCurrent()
            assertEquals(saved, store.state.value)
            publications.paused = true
            gate.complete(Unit)
            runCurrent()
            // Both the cancelled temporary load and the completed cache read are awaiting Main.
            assertEquals(2, publications.pendingCount)
            publications.paused = false
            val newImage = File(payload.parentFile, "images/new.png").apply { writeText("new image") }
            manifest.writeText("{\"shot.png\":\"new.png\"}")
            store.select("saved")
            runCurrent()
            assertEquals(2, files.documentReads)
            assertEquals(mapOf("shot.png" to newImage), (store.content("saved") as ArtifactContent.Document).stagedImages)
            publications.release()
            runCurrent()
            files.live = false
            store.setForeground(true)
            runCurrent()
            val offline = store.content("saved") as ArtifactContent.Document
            assertEquals(mapOf("shot.png" to newImage), offline.stagedImages)
            assertTrue(oldImage.isFile)
            assertEquals(2, files.documentReads)
            assertEquals(0, files.acquisitions.get())
        } finally { gate.complete(Unit); publications.release(); runCurrent() }
    }

    @Test fun closingABusyRestoredTabCancelsItsPendingCacheIndex() = runTest {
        val saved = SharedArtifactsState(tabs = listOf(document()), selectedId = "saved")
        var unavailable = true
        val gate = CompletableDeferred<Unit>()
        val files = Files().apply { documentGate = gate }
        val (store, loader) = fixture(saved, { unavailable }, files)
        loader.cacheFile(saved.tabs.single()).apply { parentFile!!.mkdirs(); writeText("old") }
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("a", "old a")))
        store.open(ArtifactOpenRequest.File("a", "/work/report.txt", ArtifactOpenOrigin.Files))
        runCurrent()
        try {
            files.live = false
            unavailable = false
            store.setForeground(true)
            runCurrent()
            store.close("saved")
            runCurrent()
            gate.complete(Unit)
            runCurrent()
            assertTrue(store.state.value.tabs.isEmpty())
            assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.Missing), store.content("saved"))
            assertEquals(1, files.documentReads)
        } finally { gate.complete(Unit); runCurrent() }
    }

    @Test fun recoveryLiftsTheFenceWhileAnObsoleteDownloadStillHoldsThePersistedKeysLock() = runTest {
        val saved = SharedArtifactsState(tabs = listOf(document()), selectedId = "saved")
        var unavailable = true
        val gate = CompletableDeferred<Unit>()
        val files = Files().apply { documentGate = gate }
        val (store, loader, _, manifest, writes) = fixture(saved, { unavailable }, files)
        loader.cacheFile(saved.tabs.single()).apply { parentFile!!.mkdirs(); writeText("old") }
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("a", "old a")))
        runCurrent()
        try {
            store.open(ArtifactOpenRequest.File("a", "/work/report.txt", ArtifactOpenOrigin.Files))
            runCurrent()
            assertTrue(files.documentStarted.isCompleted)
            assertFalse(files.documentFinished.isCompleted)
            store.flush()
            runCurrent()
            assertTrue(writes.isEmpty())
            unavailable = false
            store.setForeground(true)
            runCurrent()
            assertEquals(saved, store.state.value)
            assertEquals(listOf(saved), writes) // A successful write proves the unavailable-read fence lifted.
            assertEquals("saved", JSONObject(manifest.readText()).getJSONArray("tabs").getJSONObject(0).getString("id"))
            assertFalse(gate.isCompleted)
            assertFalse(files.documentFinished.isCompleted)
            assertEquals("old", loader.cacheFile(saved.tabs.single()).readText())
        } finally { gate.complete(Unit); runCurrent() }
    }

    @Test fun recoveryClosesTheForwardOwnedByADroppedTemporaryPage() = runTest {
        var unavailable = true
        val files = Files()
        val (store, _, pages, _, writes) = fixture(SharedArtifactsState(), { unavailable }, files)
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("a", "a")))
        store.open(ArtifactOpenRequest.Page("a", "http", 5173, "/", ArtifactOpenOrigin.TerminalLink))
        runCurrent()
        val id = checkNotNull(store.state.value.selectedId)
        try {
            await { store.content(id) is ArtifactContent.ForwardedPage }
            assertTrue(files.lease.isOpen.value)
            unavailable = false
            store.setForeground(true)
            await { writes.isNotEmpty() && files.lease.closes.get() == 1 }
            assertTrue(store.state.value.tabs.isEmpty())
            assertEquals(1, files.acquisitions.get())
            assertFalse(files.lease.isOpen.value)
        } finally { pages.close(id) }
    }

    @Test fun anAcquisitionCompletingAfterRecoveryCannotLeaveAnOrphanForward() = runTest {
        var unavailable = true
        val gate = CompletableDeferred<Unit>()
        val files = Files().apply { acquisitionGate = gate }
        val (store, _, pages, _, writes) = fixture(SharedArtifactsState(), { unavailable }, files)
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("a", "a")))
        store.open(ArtifactOpenRequest.Page("a", "http", 5173, "/", ArtifactOpenOrigin.TerminalLink))
        runCurrent()
        val id = checkNotNull(store.state.value.selectedId)
        try {
            await { files.acquisitionStarted.isCompleted }
            unavailable = false
            store.setForeground(true)
            runCurrent()
            assertTrue(store.state.value.tabs.isEmpty())
            assertEquals(1, writes.size)
            assertFalse(files.acquisitionFinished.isCompleted)
            gate.complete(Unit)
            await { files.acquisitionFinished.isCompleted && files.lease.closes.get() == 1 }
            assertFalse(files.lease.isOpen.value)
            assertEquals(1, files.acquisitions.get())
        } finally { gate.complete(Unit); pages.close(id) }
    }

    @Test fun recoveryUsesTheLoadedHostDirectoryBeforePublishingOrWritingTheRestoredSnapshot() = runTest {
        val a = document()
        val b = document("deleted", "b", "old b").copy(target = SharedArtifactsTarget.Change("/secret.kt", "+saved edit", "edit"),
            kind = SharedArtifactsKind.Changes)
        val saved = SharedArtifactsState(tabs = listOf(a, b), selectedId = b.id)
        var unavailable = true
        val (store, _, _, manifest, writes) = fixture(saved, { unavailable })
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("a", "current a")))
        runCurrent()
        unavailable = false
        store.setForeground(true)
        runCurrent()
        val expected = saved.copy(tabs = listOf(a.copy(hostLabel = "current a")), selectedId = a.id)
        assertEquals(expected, store.state.value)
        assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.Missing), store.content(b.id))
        assertEquals(listOf(expected), writes)
        val tabs = JSONObject(manifest.readText()).getJSONArray("tabs")
        assertEquals(1, tabs.length())
        assertEquals("a", tabs.getJSONObject(0).getString("hostID"))
        assertEquals("current a", tabs.getJSONObject(0).getString("hostLabel"))
    }

    @Test fun launchBeforeTheHostDirectoryLoadsRestoresEveryHostAndTheLaterUpdateUsesTheSameReconciliation() = runTest {
        val a = document()
        val b = document("other", "b", "old b")
        val saved = SharedArtifactsState(tabs = listOf(a, b), selectedId = b.id)
        val (store, _, _, _, writes) = fixture(saved)
        runCurrent()
        assertEquals(saved, store.state.value)
        assertTrue(writes.isEmpty())
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("a", "current a")))
        runCurrent()
        assertEquals(saved.copy(tabs = listOf(a.copy(hostLabel = "current a")), selectedId = a.id), store.state.value)
    }

    private fun TestScope.await(condition: () -> Boolean) {
        val deadline = System.nanoTime() + 5_000_000_000L
        do {
            runCurrent()
            if (condition()) return
            Thread.sleep(1)
        } while (System.nanoTime() < deadline)
        assertTrue("asynchronous forwarding did not finish", condition())
    }
}
