package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactLiveFilesRegistry
import com.bambouville.tessera.files.ArtifactRemoteStat
import com.bambouville.tessera.files.RemoteMarkdownImages
import com.bambouville.tessera.forwarding.ArtifactLiveForwardingRegistry
import com.bambouville.tessera.forwarding.BoundForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import com.bambouville.tessera.forwarding.PortForwardingLease
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ArtifactsFilesReconnectTest {
    @get:Rule val temporary = TemporaryFolder()

    private class Rules(private val rules: List<PortForwardRule> = emptyList()) : PortForwardRuleStore {
        override fun observe(hostId: String) = MutableStateFlow(rules)
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) = error("must not save a rule")
        override suspend fun delete(hostId: String) = Unit
    }
    private class Lease : PortForwardingLease {
        override val bound = BoundForwardEndpoint("127.0.0.1", 45_555)
        override val activeConnectionCount = MutableStateFlow(0)
        override val isOpen = MutableStateFlow(true)
        override fun close() { isOpen.value = false }
    }
    private class Files : ArtifactLiveFiles {
        var live = false
        var openable = true
        override val hasLiveArtifactChannel get() = live
        override val canOpenArtifactChannel get() = openable && !live
        override val artifactHome: String? = null
        override val artifactDirectory: String? = null
        var opens = 0
        var gate: CompletableDeferred<Unit>? = null
        var failure: Exception? = null
        var document = "new"
        var mtime = 10L
        var reads = 0
        var stats = 0
        override suspend fun openArtifactChannel() {
            opens += 1
            gate?.await()
            failure?.let { throw it }
            live = true
        }
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat? {
            if (!live) return null
            stats += 1
            return ArtifactRemoteStat(path, document.encodeToByteArray().size.toLong(), mtime, false)
        }
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat? {
            if (!live) return null
            reads += 1
            val bytes = document.encodeToByteArray()
            output.write(bytes)
            return ArtifactRemoteStat(path, bytes.size.toLong(), mtime, false)
        }
        override suspend fun probeOnLiveChannel(command: String): String? = null
        var forwards = 0
        val forwardRules = mutableListOf<PortForwardRule>()
        var forwardFailure: Exception? = null
        override suspend fun acquireForwardingLeaseOnLiveChannel(rule: PortForwardRule): PortForwardingLease? {
            forwards += 1
            forwardRules += rule
            forwardFailure?.let { throw it }
            return if (live) Lease() else null
        }
    }
    private fun page(id: String = "b", hostId: String = "h") = tab(id, hostId).copy(
        target = SharedArtifactsTarget.Page("http", 5173, "/"), kind = SharedArtifactsKind.Pages, cache = null,
    )
    private fun tab(id: String = "a", hostId: String = "h") = SharedArtifactTab(
        id, hostId, hostId, SharedArtifactsTarget.File("/work/$id.md"), SharedArtifactsKind.Docs,
        "$id.md", "files", null, 1, 1, false, SharedArtifactsCacheMetadata(1, 10, 5), false, null,
    )
    /** Fetches wait out cache eviction on virtual time; the deadline only bounds a broken store. */
    private fun TestScope.await(condition: () -> Boolean) {
        val deadline = System.nanoTime() + 5_000_000_000L
        do {
            advanceTimeBy(20)
            runCurrent()
            if (condition()) return
            Thread.sleep(1)
        } while (System.nanoTime() < deadline)
        assertTrue("the store did not settle", condition())
    }
    private fun ArtifactsStore.reads(text: String) = (content("a") as? ArtifactContent.Document)?.file?.readText() == text
    private data class Fixture(val store: ArtifactsStore, val forcedStages: MutableList<Boolean>)
    private fun TestScope.fixture(
        files: Files = Files(),
        tabs: List<SharedArtifactTab> = listOf(tab()),
        savedCopy: Boolean = true,
        openableEntry: Boolean = true,
        hosts: ArtifactsLiveHosts? = null,
        rules: List<PortForwardRule> = emptyList(),
    ): Fixture {
        val live = hosts ?: ArtifactsLiveHosts(
            findFiles = { id -> files.takeIf { id == "h" } }, findContext = { null }, findForwarding = { emptyList() },
            findOpenable = { id -> files.takeIf { id == "h" && openableEntry } },
        )
        val dispatcher = StandardTestDispatcher(testScheduler)
        val forcedStages = mutableListOf<Boolean>()
        val loader = ArtifactContentLoader(temporary.newFolder(), live::files, key = { it.id.repeat(64) },
            viewer = { SharedArtifactsViewer.Markdown }, evictions = { _, _, _ -> emptyList() }, ioDispatcher = dispatcher,
            stageCachedImages = { _, _, _, _, _, _, force ->
                forcedStages += force
                RemoteMarkdownImages.StagingResult(emptyMap(), true)
            })
        if (savedCopy) tabs.filter { it.target is SharedArtifactsTarget.File }.forEach {
            loader.cacheFile(it).apply { parentFile!!.mkdirs(); writeText("saved") }
        }
        val initial = SharedArtifactsState(tabs = tabs, selectedId = tabs.firstOrNull()?.id)
        val stateFile = ArtifactsStateFile(temporary.newFile().apply { writeText("initial") }, decode = { initial }, encode = { "saved" })
        val store = ArtifactsStore(stateFile, live, loader, ArtifactPageForwarder(live, Rules(rules), ioDispatcher = dispatcher), backgroundScope,
            persistenceDispatcher = dispatcher, clock = { 1_000 }, cachePresentation = { tab, connected, _ ->
                SharedArtifactsCachePresentation(when {
                    connected -> SharedArtifactsCacheState.Live
                    tab.cache == null -> SharedArtifactsCacheState.Offline
                    tab.cache?.isStale == true -> SharedArtifactsCacheState.Stale
                    else -> SharedArtifactsCacheState.Cached
                }, tab.cache?.fetchedAt, connected)
            }, reduceAction = { state, action ->
                val next = when (action) {
                    is SharedArtifactsAction.Select -> state.copy(selectedId = action.tabId)
                    is SharedArtifactsAction.Close -> state.copy(tabs = state.tabs.filter { it.id != action.tabId })
                    is SharedArtifactsAction.Fetched -> state.copy(tabs = state.tabs.map {
                        if (it.id == action.tabId) it.copy(cache = action.cache.copy(fetchedAt = action.nowMillis)) else it
                    })
                    is SharedArtifactsAction.RemoteStatObserved -> state.copy(tabs = state.tabs.map {
                        if (it.id == action.tabId) it.copy(cache = it.cache?.copy(isStale = true)) else it
                    })
                    else -> error("unexpected action: $action")
                }
                SharedArtifactsReduction(next, next.selectedId, emptyList(), null)
            })
        store.updateHosts(tabs.map { SharedArtifactsQuickOpenHost(it.hostId, it.hostLabel) }.distinct())
        return Fixture(store, forcedStages)
    }

    @Test fun reconnectIsOfferedOnlyForAFileOrUnforwardedPageWithoutALiveChannelAndWithAnOpenableEntry() = runTest {
        val files = Files()
        val change = tab("c").copy(target = SharedArtifactsTarget.Change("/work/c.md", "diff", "summary"), kind = SharedArtifactsKind.Changes)
        val (store) = fixture(files, listOf(tab(), page(), change, tab("d", "offline")))
        runCurrent()
        assertEquals(ArtifactFilesReconnect.Available, store.filesReconnect("a"))
        // A mosh session alone cannot forward the page; its Files connection can.
        assertEquals(ArtifactFilesReconnect.Available, store.filesReconnect("b"))
        for (id in listOf("c", "d", "missing")) {
            assertNull(store.filesReconnect(id))
            store.connectFiles(id)
        }
        files.live = true
        assertNull(store.filesReconnect("a"))
        assertNull(store.filesReconnect("b"))
        store.connectFiles("a")
        files.live = false
        files.openable = false
        assertNull(store.filesReconnect("a"))
        assertNull(store.filesReconnect("b"))
        store.connectFiles("a")
        store.connectFiles("b")
        runCurrent()
        assertEquals(0, files.opens)
    }

    @Test fun aPageThatAnSshSessionCanForwardNeverOffersTheFilesConnection() = runTest {
        val host = UUID.randomUUID().toString()
        val session = "forwarding-$host"
        val files = Files()
        val registration = ArtifactLiveForwardingRegistry.register(host, session, MutableStateFlow(emptyMap()), transportLive = { true })
        val acquirer = ArtifactLiveForwardingRegistry.publishAcquirer(session, live = { true }, acquire = { null })
        try {
            val hosts = ArtifactsLiveHosts(findFiles = { files }, findContext = { null }, findOpenable = { files })
            val (store) = fixture(files, listOf(tab(hostId = host), page(hostId = host)), hosts = hosts)
            runCurrent()
            assertEquals(ArtifactFilesReconnect.Available, store.filesReconnect("a"))
            assertNull(store.filesReconnect("b"))
            store.connectFiles("b")
            runCurrent()
            assertEquals(0, files.opens)
        } finally {
            acquirer.close()
            registration.close()
        }
    }

    @Test fun connectingFilesForAMoshPageForwardsItOverThatConnection() = runTest {
        val files = Files()
        val (store) = fixture(files, listOf(page()), savedCopy = false)
        store.noteVisible("b")
        runCurrent()
        assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding), store.content("b"))
        assertFalse(store.presentation("b").canRefresh)
        assertEquals(0, files.forwards)
        store.connectFiles("b")
        await { store.content("b") is ArtifactContent.ForwardedPage }
        assertEquals(ArtifactContent.ForwardedPage("http://127.0.0.1:45555/", "b.md", true), store.content("b"))
        assertEquals(1, files.opens)
        assertEquals(1, files.forwards)
        assertNull(store.filesReconnect("b"))
        assertTrue(store.presentation("b").canRefresh)
    }

    @Test fun connectingFilesForAMoshPageWithAStoppedSavedRuleUsesAnEphemeralForward() = runTest {
        val files = Files()
        val saved = PortForwardRule(bind = PortForwardEndpoint("127.0.0.1", 5173), target = PortForwardEndpoint("127.0.0.1", 5173))
        val (store) = fixture(files, listOf(page()), savedCopy = false, rules = listOf(saved))
        store.noteVisible("b")
        runCurrent()
        assertEquals(ArtifactFilesReconnect.Available, store.filesReconnect("b"))
        store.connectFiles("b")
        await { store.content("b") is ArtifactContent.ForwardedPage }
        assertEquals(ArtifactContent.ForwardedPage("http://127.0.0.1:45555/", "b.md", true), store.content("b"))
        assertEquals(1, files.opens)
        val acquired = files.forwardRules.single()
        assertTrue(acquired.id != saved.id)
        assertFalse(acquired.autoStart)
        assertEquals(5173, acquired.bind.port)
        assertEquals(5173, acquired.target?.port)
        assertFalse(store.canKeepAsRule("b"))
        assertNull(store.filesReconnect("b"))
    }

    @Test fun aSuccessfulPageRetrySurvivesVisibilityAndForegroundChangesWithoutLoading() = runTest {
        val files = Files().apply { live = true; forwardFailure = IOException("the forward was refused") }
        val (store, stages) = fixture(files, listOf(page()), savedCopy = false)
        store.noteVisible("b")
        await { store.content("b") == ArtifactContent.Unavailable(ArtifactUnavailable.Failed("the forward was refused")) }
        files.forwardFailure = null
        store.refresh("b")
        await { store.content("b") is ArtifactContent.ForwardedPage }
        val recovered = store.content("b")
        assertEquals(ArtifactContent.ForwardedPage("http://127.0.0.1:45555/", "b.md", true), recovered)
        val observed = mutableListOf<ArtifactContent>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            store.revision.collect { observed += store.content("b") }
        }
        store.noteVisible(null)
        store.setForeground(false)
        runCurrent()
        store.setForeground(true)
        store.noteVisible("b")
        runCurrent()
        assertTrue(observed.isNotEmpty())
        assertFalse(observed.any { it === ArtifactContent.Loading })
        assertTrue(observed.all { it === recovered })
        assertSame(recovered, store.content("b"))
        assertEquals(2, files.forwards)
        assertEquals(0, files.reads)
        assertTrue(stages.isEmpty())
    }

    @Test fun aFailedPageLoadsAgainOnRefreshWhileItsHostIsLive() = runTest {
        val files = Files().apply { live = true; forwardFailure = IOException("the forward was refused") }
        val (store) = fixture(files, listOf(page()), savedCopy = false)
        store.noteVisible("b")
        await { store.content("b") == ArtifactContent.Unavailable(ArtifactUnavailable.Failed("the forward was refused")) }
        assertTrue(store.presentation("b").canRefresh)
        assertNull(store.filesReconnect("b"))
        val attempts = files.forwards
        store.refresh("b")
        await { files.forwards > attempts }
        files.live = false
        ArtifactLiveFilesRegistry.changed()
        runCurrent()
        assertFalse(store.presentation("b").canRefresh)
        val offlineAttempts = files.forwards
        store.refresh("b")
        runCurrent()
        assertEquals(offlineAttempts, files.forwards)
        assertEquals(0, files.opens)
    }

    @Test fun aHostWithoutAnOpenableEntryCannotOfferOrAttemptAReconnect() = runTest {
        val files = Files()
        val (store) = fixture(files, openableEntry = false)
        runCurrent()
        assertNull(store.filesReconnect("a"))
        store.connectFiles("a")
        runCurrent()
        assertEquals(0, files.opens)
    }

    @Test fun aLiveChannelFromAnotherSessionTakesPriorityOverAnOpenableOne() = runTest {
        val opener = Files()
        val connected = Files().apply { live = true }
        val hosts = ArtifactsLiveHosts(findFiles = { connected }, findContext = { null }, findForwarding = { emptyList() }, findOpenable = { opener })
        val (store) = fixture(opener, hosts = hosts)
        runCurrent()
        assertTrue(opener.canOpenArtifactChannel)
        assertNull(store.filesReconnect("a"))
        store.connectFiles("a")
        runCurrent()
        assertEquals(0, opener.opens)
        assertEquals(0, connected.opens)
    }

    @Test fun explicitConnectPublishesProgressDeduplicatesTapsAndForcesACachedRefresh() = runTest {
        val gate = CompletableDeferred<Unit>()
        val files = Files().apply { this.gate = gate }
        val (store, stages) = fixture(files)
        store.noteVisible("a")
        runCurrent()
        assertEquals("saved", (store.content("a") as ArtifactContent.Document).file.readText())
        assertEquals(ArtifactFilesReconnect.Available, store.filesReconnect("a"))
        assertFalse(store.presentation("a").canRefresh)
        val revision = store.revision.value
        store.connectFiles("a")
        assertEquals(ArtifactFilesReconnect.Connecting, store.filesReconnect("a"))
        assertTrue(store.revision.value > revision)
        val connectingRevision = store.revision.value
        store.connectFiles("a")
        runCurrent()
        assertEquals(1, files.opens)
        assertEquals(0, files.reads)
        assertEquals(ArtifactFilesReconnect.Connecting, store.filesReconnect("a"))
        gate.complete(Unit)
        await { files.reads == 1 && stages.isNotEmpty() && store.reads("new") }
        assertNull(store.filesReconnect("a"))
        assertTrue(store.presentation("a").canRefresh)
        assertTrue(store.revision.value > connectingRevision)
        assertEquals(1, files.opens)
        assertEquals(1, files.reads)
        assertEquals(listOf(true), stages)
        assertEquals("new", (store.content("a") as ArtifactContent.Document).file.readText())
        assertEquals(1_000L, store.tab("a")?.cache?.fetchedAt)
        store.connectFiles("a")
        runCurrent()
        assertEquals(1, files.opens)
    }

    @Test fun anUncachedFileLoadsOnlyAfterTheExplicitAction() = runTest {
        val files = Files()
        val (store, stages) = fixture(files, listOf(tab().copy(cache = null)), savedCopy = false)
        runCurrent()
        assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.Offline), store.content("a"))
        assertEquals(ArtifactFilesReconnect.Available, store.filesReconnect("a"))
        assertEquals(0, files.opens)
        store.connectFiles("a")
        await { files.reads == 1 && stages.isNotEmpty() && store.reads("new") }
        assertNull(store.filesReconnect("a"))
        assertEquals(1, files.opens)
        assertEquals(1, files.reads)
        assertEquals(listOf(true), stages)
        assertEquals("new", (store.content("a") as ArtifactContent.Document).file.readText())
    }

    @Test fun aFailureIsObservableAndASecondTapRetries() = runTest {
        val files = Files().apply { failure = IOException("channel refused") }
        val (store, stages) = fixture(files, listOf(tab(), tab("b")))
        runCurrent()
        store.connectFiles("a")
        val connectingRevision = store.revision.value
        runCurrent()
        assertTrue(store.revision.value > connectingRevision)
        assertEquals(ArtifactFilesReconnect.Failed("channel refused"), store.filesReconnect("a"))
        assertEquals(ArtifactFilesReconnect.Available, store.filesReconnect("b"))
        assertEquals("saved", (store.content("a") as ArtifactContent.Document).file.readText())
        assertEquals(1, files.opens)
        assertEquals(0, files.reads)
        files.failure = null
        files.gate = CompletableDeferred()
        store.connectFiles("a")
        assertEquals(ArtifactFilesReconnect.Connecting, store.filesReconnect("a"))
        runCurrent()
        assertEquals(2, files.opens)
        checkNotNull(files.gate).complete(Unit)
        await { stages.isNotEmpty() }
        assertNull(store.filesReconnect("a"))
        assertNull(store.filesReconnect("b"))
        assertEquals(2, files.opens)
        assertEquals(listOf(true), stages)
    }

    @Test fun cancellationClearsProgressWithoutRecordingAFailure() = runTest {
        val files = Files().apply { failure = CancellationException("route retired") }
        val (store) = fixture(files)
        runCurrent()
        store.connectFiles("a")
        runCurrent()
        assertEquals(ArtifactFilesReconnect.Available, store.filesReconnect("a"))
        assertEquals(1, files.opens)
        assertEquals(0, files.reads)
        files.failure = null
        store.connectFiles("a")
        runCurrent()
        assertNull(store.filesReconnect("a"))
        assertEquals(2, files.opens)
    }

    @Test fun closingATabDuringAnOpenCannotPublishAFailureOrRefreshTheClosedTab() = runTest {
        val files = Files().apply { gate = CompletableDeferred(); failure = IOException("channel refused") }
        val (store) = fixture(files, listOf(tab(), tab("b")))
        runCurrent()
        store.connectFiles("a")
        runCurrent()
        store.close("a")
        runCurrent()
        checkNotNull(files.gate).complete(Unit)
        runCurrent()
        assertNull(store.filesReconnect("a"))
        assertEquals(ArtifactFilesReconnect.Available, store.filesReconnect("b"))
        assertEquals(1, files.opens)
        assertEquals(0, files.reads)
    }

    @Test fun restorationVisibilityFollowRefreshAndConnectionChangesNeverOpenFiles() = runTest {
        val files = Files()
        val (store) = fixture(files)
        assertEquals(0, files.opens)
        store.noteVisible("a")
        store.setForeground(true)
        runCurrent()
        repeat(3) {
            store.select("a")
            store.noteVisible("a")
            store.refresh("a")
            store.updateDirectories(mapOf("h" to "/work"))
            store.quickOpenHosts
            store.presentation("a")
            store.filesReconnect("a")
            ArtifactLiveFilesRegistry.changed()
            advanceTimeBy(3_001)
            runCurrent()
        }
        assertEquals(0, files.opens)
        assertEquals(0, files.reads)
        files.live = true
        ArtifactLiveFilesRegistry.changed()
        await { files.reads > 0 && store.content("a") is ArtifactContent.Document }
        assertTrue(store.content("a") is ArtifactContent.Document)
        val reads = files.reads
        files.document = "updated"
        files.mtime += 1
        advanceTimeBy(3_001)
        await { files.reads > reads }
        assertTrue(files.stats > 0)
        assertTrue(files.reads > reads)
        files.live = false
        ArtifactLiveFilesRegistry.changed()
        runCurrent()
        assertEquals(ArtifactFilesReconnect.Available, store.filesReconnect("a"))
        store.setForeground(false)
        runCurrent()
        store.setForeground(true)
        advanceTimeBy(3_001)
        runCurrent()
        assertEquals(0, files.opens)
    }

    @Test fun theForegroundSweepPublishesOpenabilityChangesWithoutOpeningOrMutatingTabs() = runTest {
        val files = Files().apply { openable = false }
        val (store) = fixture(files)
        store.setForeground(true)
        await { store.content("a") is ArtifactContent.Document }
        assertNull(store.filesReconnect("a"))
        val state = store.state.value
        // A sweep that finds nothing new publishes nothing, so the next bump is the openability change.
        val revision = store.revision.value
        advanceTimeBy(1_001)
        runCurrent()
        assertEquals(revision, store.revision.value)
        files.openable = true
        advanceTimeBy(1_001)
        runCurrent()
        assertEquals(ArtifactFilesReconnect.Available, store.filesReconnect("a"))
        assertTrue(store.revision.value > revision)
        assertSame(state, store.state.value)
        val availableRevision = store.revision.value
        advanceTimeBy(1_001)
        runCurrent()
        assertEquals(availableRevision, store.revision.value)
        files.openable = false
        advanceTimeBy(1_001)
        runCurrent()
        assertNull(store.filesReconnect("a"))
        assertTrue(store.revision.value > availableRevision)
        assertSame(state, store.state.value)
        assertEquals(0, files.opens)
        assertEquals(0, files.reads)
    }

    @Test fun theDefaultRegistryLookupOpensTheRegisteredChannelAndRefreshesIt() = runTest {
        val host = UUID.randomUUID().toString()
        val files = Files()
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = { true }, channelOpenable = { true })
        try {
            val (store, stages) = fixture(files, listOf(tab(hostId = host)), hosts = ArtifactsLiveHosts(findForwarding = { emptyList() }))
            runCurrent()
            assertEquals(ArtifactFilesReconnect.Available, store.filesReconnect("a"))
            assertEquals(0, files.opens)
            store.connectFiles("a")
            await { files.reads == 1 && stages.isNotEmpty() }
            assertNull(store.filesReconnect("a"))
            assertEquals(1, files.opens)
            assertEquals(1, files.reads)
            assertEquals(listOf(true), stages)
        } finally { registration.close() }
    }
}
