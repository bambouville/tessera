package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactLiveFilesRegistry
import com.bambouville.tessera.files.ArtifactRemoteStat
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import java.io.FileNotFoundException
import java.io.OutputStream
import java.util.UUID
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.CompletableDeferred
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

/** Exercises store wiring with the module's policy-fake pattern, without JNI or a host. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ArtifactsOverviewSweepTest {
    @get:Rule val temporary = TemporaryFolder()

    private class Rules : PortForwardRuleStore {
        override fun observe(hostId: String) = MutableStateFlow(emptyList<PortForwardRule>())
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) = error("must not save a rule")
        override suspend fun delete(hostId: String) = Unit
    }

    private class Files : ArtifactLiveFiles {
        var live = true
        var generation = 1L
        var modified = 2L
        var opens = 0
        var reads = 0
        val stats = mutableListOf<String>()
        var beforeStatReply: suspend (String) -> Unit = {}
        override val hasLiveArtifactChannel get() = live
        override val canOpenArtifactChannel get() = !live
        override val artifactConnectionGeneration get() = generation
        override val artifactHome: String? = null
        override val artifactDirectory: String? = null
        override suspend fun openArtifactChannel() { opens += 1; error("must not open Files") }
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat? {
            if (!live) return null
            stats += path
            val reply = ArtifactRemoteStat(path, 5, modified, false)
            beforeStatReply(path)
            return reply
        }
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat? {
            if (!live) return null
            reads += 1
            output.write("saved".encodeToByteArray())
            return ArtifactRemoteStat(path, 5, modified, false)
        }
        override suspend fun probeOnLiveChannel(command: String): String? = null
    }

    private fun tab(id: String = "a", hostId: String = "h", viewedAt: Long = 1) = SharedArtifactTab(
        id, hostId, hostId, SharedArtifactsTarget.File("/work/$id.txt"), SharedArtifactsKind.Docs,
        "$id.txt", "files", null, 1, viewedAt, false, SharedArtifactsCacheMetadata(1, 1, 5), false, null,
    )

    private data class Fixture(val store: ArtifactsStore, val observations: MutableList<SharedArtifactsAction.RemoteStatObserved>)

    private fun TestScope.fixture(
        files: Files,
        tabs: List<SharedArtifactTab> = listOf(tab()),
        hosts: ArtifactsLiveHosts = ArtifactsLiveHosts(
            findFiles = { files }, findContext = { null }, findForwarding = { emptyList() }, findOpenable = { files },
        ),
    ): Fixture {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val loader = ArtifactContentLoader(temporary.newFolder(), hosts::files, key = { it.id.padStart(64, '0') },
            viewer = { SharedArtifactsViewer.Text }, evictions = { _, _, _ -> emptyList() }, ioDispatcher = dispatcher)
        tabs.filter { it.cache != null && it.target is SharedArtifactsTarget.File }.forEach {
            loader.cacheFile(it).apply { parentFile!!.mkdirs(); writeText("saved") }
        }
        val initial = SharedArtifactsState(tabs = tabs, selectedId = tabs.lastOrNull()?.id)
        val file = ArtifactsStateFile(temporary.newFile().apply { writeText("initial") }, decode = { initial }, encode = { "saved" })
        val observations = mutableListOf<SharedArtifactsAction.RemoteStatObserved>()
        val store = ArtifactsStore(file, hosts, loader, ArtifactPageForwarder(hosts, Rules(), ioDispatcher = dispatcher), backgroundScope,
            clock = { 1_000 }, persistenceDispatcher = dispatcher, reduceAction = { state, action ->
                val next = when (action) {
                    is SharedArtifactsAction.Close -> state.copy(tabs = state.tabs.filter { it.id != action.tabId })
                    is SharedArtifactsAction.Select -> state.copy(selectedId = action.tabId, tabs = state.tabs.map {
                        if (it.id == action.tabId) it.copy(unseenChange = false) else it
                    })
                    is SharedArtifactsAction.Fetched -> state.copy(tabs = state.tabs.map {
                        if (it.id == action.tabId) it.copy(cache = action.cache.copy(fetchedAt = action.nowMillis), unseenChange = false) else it
                    })
                    is SharedArtifactsAction.RemoteStatObserved -> {
                        observations += action
                        state.copy(tabs = state.tabs.map { tab ->
                            val cache = tab.cache
                            val changed = cache != null && (action.remoteMTime?.let { it != cache.remoteMTime } == true ||
                                action.size?.let { it >= 0 && it != cache.size } == true)
                            if (tab.id == action.tabId && changed) tab.copy(cache = cache.copy(isStale = true),
                                unseenChange = !(state.selectedId == tab.id && action.visible)) else tab
                        })
                    }
                    else -> error("unexpected action: $action")
                }
                SharedArtifactsReduction(next, next.selectedId, emptyList(), null)
            })
        store.updateHosts(tabs.map { SharedArtifactsQuickOpenHost(it.hostId, it.hostLabel) }.distinct())
        store.setForeground(true)
        runCurrent()
        return Fixture(store, observations)
    }

    @Test fun overviewSweepMarksHiddenCachedFileWithoutStattingVisibleTab() = runTest {
        val files = Files()
        val (store, observations) = fixture(files, listOf(tab("a"), tab("b")))
        store.noteVisible("b")
        runCurrent()
        val reads = files.reads
        store.noteOverviewVisible(Any(), true)
        runCurrent()
        assertEquals(listOf("/work/a.txt"), files.stats)
        assertEquals(listOf("a"), observations.map { it.tabId })
        assertTrue(observations.all { !it.visible })
        assertTrue(store.tab("a")!!.unseenChange)
        assertTrue(store.tab("a")!!.cache!!.isStale)
        assertFalse(store.tab("b")!!.unseenChange)
        assertEquals(reads, files.reads)
        assertEquals(0, files.opens)
        store.select("a")
        store.noteVisible("a")
        runCurrent()
        assertFalse(store.tab("a")!!.unseenChange)
    }

    @Test fun overviewSweepDoesNotStatWithoutAVisibleOverview() = runTest {
        val files = Files()
        val (store, observations) = fixture(files)
        advanceTimeBy(60_001)
        runCurrent()
        assertTrue(files.stats.isEmpty())
        assertTrue(observations.isEmpty())
        assertFalse(store.tab("a")!!.unseenChange)
        assertEquals(0, files.opens)
    }

    @Test fun overviewSweepRequiresALiveSessionAndConnectedBridge() = runTest {
        for (sessionLive in listOf(false, true)) {
            val hostId = UUID.randomUUID().toString()
            val files = Files().apply { live = !sessionLive }
            val registration = ArtifactLiveFilesRegistry.register(hostId, "session", files,
                sessionLive = { sessionLive }, channelOpenable = { true })
            try {
                val hosts = ArtifactsLiveHosts(findContext = { null }, findForwarding = { emptyList() })
                val (store, observations) = fixture(files, listOf(tab(hostId = hostId)), hosts)
                val owner = Any()
                store.noteOverviewVisible(owner, true)
                advanceTimeBy(60_001)
                runCurrent()
                assertTrue(files.stats.isEmpty())
                assertTrue(observations.isEmpty())
                assertEquals(0, files.opens)
                store.noteOverviewVisible(owner, false)
                runCurrent()
            } finally { registration.close() }
        }
    }

    @Test fun hidingOverviewStopsItsPeriodicSweep() = runTest {
        val files = Files()
        val (store) = fixture(files)
        val owner = Any()
        store.noteOverviewVisible(owner, true)
        store.noteOverviewVisible(owner, true)
        runCurrent()
        assertEquals(1, files.stats.size)
        advanceTimeBy(14_999)
        runCurrent()
        assertEquals(1, files.stats.size)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(2, files.stats.size)
        store.noteOverviewVisible(owner, false)
        runCurrent()
        advanceTimeBy(60_001)
        runCurrent()
        assertEquals(2, files.stats.size)
        assertEquals(0, files.opens)
    }

    @Test fun overviewSweepKeepsRunningUntilBothOverviewsDisappear() = runTest {
        val files = Files()
        val (store) = fixture(files)
        val desk = Any()
        val sheet = Any()
        store.noteOverviewVisible(desk, true)
        store.noteOverviewVisible(sheet, true)
        runCurrent()
        assertEquals(1, files.stats.size)
        store.noteOverviewVisible(sheet, false)
        runCurrent()
        advanceTimeBy(15_000)
        runCurrent()
        assertEquals(2, files.stats.size)
        store.noteOverviewVisible(desk, false)
        runCurrent()
        advanceTimeBy(60_001)
        runCurrent()
        assertEquals(2, files.stats.size)
    }

    @Test fun lockingOverviewStopsSweepsAcrossForegroundAndUnlockingResumesThem() = runTest {
        val files = Files()
        val (store) = fixture(files)
        val owner = Any()
        store.noteOverviewVisible(owner, true)
        runCurrent()
        assertEquals(1, files.stats.size)

        store.noteOverviewVisible(owner, false)
        runCurrent()
        advanceTimeBy(60_001)
        store.setForeground(false)
        runCurrent()
        store.setForeground(true)
        runCurrent()
        advanceTimeBy(60_001)
        runCurrent()
        assertEquals(1, files.stats.size)

        store.noteOverviewVisible(owner, true)
        runCurrent()
        assertEquals(2, files.stats.size)
        advanceTimeBy(15_000)
        runCurrent()
        assertEquals(3, files.stats.size)
        assertEquals(0, files.opens)
    }

    @Test fun overviewSweepLimitsStatsToSixteenRecentCachedFiles() = runTest {
        val files = Files()
        val tabs = (0..<18).map { tab(it.toString(16).padStart(2, '0'), viewedAt = it.toLong()) }
        val uncached = tab("ee", viewedAt = 100).copy(cache = null)
        val change = tab("ff", viewedAt = 101).copy(target = SharedArtifactsTarget.Change("/change.txt", "+saved", "edit"),
            kind = SharedArtifactsKind.Changes, cache = null)
        val (store) = fixture(files, tabs + uncached + change)
        store.noteOverviewVisible(Any(), true)
        runCurrent()
        assertEquals(tabs.takeLast(16).reversed().map { it.target.path }, files.stats)
        assertEquals(0, files.reads)
    }

    @Test fun threeOverviewSweepsVisitAllFortyTabsBeforeRepeating() = runTest {
        val files = Files()
        val tabs = (0..<40).map { tab(it.toString(16).padStart(2, '0'), viewedAt = it.toLong()) }
        val (store) = fixture(files, tabs)
        store.noteOverviewVisible(Any(), true)
        runCurrent()
        assertEquals(16, files.stats.size)
        advanceTimeBy(15_000)
        runCurrent()
        assertEquals(32, files.stats.size)
        advanceTimeBy(15_000)
        runCurrent()
        assertEquals(tabs.reversed().map { it.target.path }, files.stats)
        assertEquals(40, files.stats.toSet().size)
        advanceTimeBy(15_000)
        runCurrent()
        assertEquals(tabs.takeLast(16).reversed().map { it.target.path }, files.stats.drop(40))
        assertEquals(0, files.reads)
        assertEquals(0, files.opens)
    }

    @Test fun overviewSweepDropsClosedTabsFromItsPendingRound() = runTest {
        val files = Files()
        val tabs = (0..<18).map { tab(it.toString(16).padStart(2, '0'), viewedAt = it.toLong()) }
        val (store) = fixture(files, tabs)
        store.noteOverviewVisible(Any(), true)
        runCurrent()
        assertEquals(16, files.stats.size)
        store.close("00")
        runCurrent()
        advanceTimeBy(15_000)
        runCurrent()
        assertEquals(tabs.drop(1).reversed().map { it.target.path }, files.stats)
    }

    @Test fun failedOverviewStatsStillAdvanceToTheRemainingTabs() = runTest {
        val files = Files().apply { beforeStatReply = { throw FileNotFoundException(it) } }
        val tabs = (0..<18).map { tab(it.toString(16).padStart(2, '0'), viewedAt = it.toLong()) }
        val (store, observations) = fixture(files, tabs)
        store.noteOverviewVisible(Any(), true)
        runCurrent()
        assertEquals(16, files.stats.size)
        advanceTimeBy(15_000)
        runCurrent()
        assertEquals(tabs.reversed().map { it.target.path }, files.stats)
        assertTrue(observations.isEmpty())
    }

    @Test fun overviewSweepCancelsInFlightStatsAndRestartsAfterBackgroundOrBridgeDrop() = runTest {
        val files = Files()
        val (store, observations) = fixture(files)
        val owner = Any()
        var reply: Continuation<Unit>? = null
        files.beforeStatReply = { suspendCoroutine { reply = it } }
        store.noteOverviewVisible(owner, true)
        runCurrent()
        assertEquals(1, files.stats.size)
        store.noteOverviewVisible(owner, false)
        store.noteOverviewVisible(owner, true)
        runCurrent()
        assertEquals(1, files.stats.size)
        files.beforeStatReply = {}
        checkNotNull(reply).resume(Unit)
        runCurrent()
        assertEquals(2, files.stats.size)
        assertEquals(1, observations.size)

        store.setForeground(false)
        runCurrent()
        advanceTimeBy(60_001)
        runCurrent()
        assertEquals(2, files.stats.size)
        store.setForeground(true)
        runCurrent()
        assertEquals(3, files.stats.size)
        files.live = false
        ArtifactLiveFilesRegistry.changed()
        runCurrent()
        advanceTimeBy(60_001)
        runCurrent()
        assertEquals(3, files.stats.size)
        files.live = true
        ArtifactLiveFilesRegistry.changed()
        runCurrent()
        assertEquals(4, files.stats.size)
        assertEquals(0, files.opens)
    }

    @Test fun overviewSweepDiscardsStatsFromAReplacedConnectionOrCache() = runTest {
        for (replaceCache in listOf(false, true)) {
            val files = Files()
            val (store, observations) = fixture(files)
            val gate = CompletableDeferred<Unit>()
            files.beforeStatReply = { gate.await() }
            val owner = Any()
            store.noteOverviewVisible(owner, true)
            runCurrent()
            assertEquals(1, files.stats.size)
            if (replaceCache) {
                files.modified = 3
                store.refresh("a")
                runCurrent()
                assertEquals(3L, store.tab("a")?.cache?.remoteMTime)
            } else files.generation += 1
            gate.complete(Unit)
            runCurrent()
            assertTrue(observations.isEmpty())
            assertFalse(store.tab("a")!!.unseenChange)
            store.noteOverviewVisible(owner, false)
            runCurrent()
        }
    }
}
