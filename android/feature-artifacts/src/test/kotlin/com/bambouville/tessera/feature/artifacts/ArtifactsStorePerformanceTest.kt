package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactRemoteStat
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import com.bambouville.tessera.forwarding.PortForwardingLease
import java.io.FileNotFoundException
import java.io.OutputStream
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Count bridge calls, not elapsed time. Policy and live-channel fakes keep these host/JNI-free. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ArtifactsStorePerformanceTest {
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
        var stats = 0
        var probes = 0
        var forwards = 0
        var bytes = "doc"
        var mtime: Long? = 10
        var statSize: Long? = 3
        var missing = false
        var readUnavailable = false
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat {
            check(live)
            stats += 1
            if (missing) throw FileNotFoundException(path)
            return ArtifactRemoteStat(path, statSize, mtime, false)
        }
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat? {
            check(live)
            reads += 1
            if (readUnavailable) return null
            output.write(bytes.encodeToByteArray())
            return ArtifactRemoteStat(path, bytes.length.toLong(), mtime, false)
        }
        override suspend fun probeOnLiveChannel(command: String): String? { probes += 1; error("must not probe") }
        override suspend fun acquireForwardingLeaseOnLiveChannel(rule: PortForwardRule): PortForwardingLease? {
            forwards += 1
            error("must not acquire a forward")
        }
    }

    private class Calls {
        val reductions = mutableListOf<SharedArtifactsAction>()
        val parses = mutableListOf<Pair<String, SharedArtifactsQuickOpenContext>>()
        val diagnostics = mutableListOf<String>()
        var writes = 0
    }
    private data class Fixture(val store: ArtifactsStore, val calls: Calls)
    private fun fileTab(id: String = "a", host: String = "h", path: String = "/work/a.txt") = SharedArtifactTab(
        id, host, host, SharedArtifactsTarget.File(path), SharedArtifactsKind.Docs,
        "a.txt", "files", null, 1, 1, false, SharedArtifactsCacheMetadata(1, 10, 3), false, null,
    )
    private fun TestScope.fixture(
        initial: SharedArtifactsState,
        files: Files? = null,
        parse: (String, SharedArtifactsQuickOpenContext) -> SharedArtifactsQuickOpenIntent = { _, _ -> error("unexpected parse") },
    ): Fixture {
        val calls = Calls()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val stateFile = ArtifactsStateFile(temporary.newFile().apply { writeText("initial") }, decode = { initial },
            encode = { calls.writes += 1; "saved" })
        val hosts = ArtifactsLiveHosts(findFiles = { id -> files?.takeIf { id == "h" } }, findContext = { null }, findForwarding = { emptyList() })
        val loader = ArtifactContentLoader(temporary.newFolder(), hosts::files,
            key = { it.id.hashCode().toUInt().toString(16).padStart(64, '0') }, viewer = { SharedArtifactsViewer.Text },
            evictions = { _, _, _ -> emptyList() }, ioDispatcher = dispatcher)
        val store = ArtifactsStore(stateFile, hosts, loader, ArtifactPageForwarder(hosts, Rules()), backgroundScope,
            clock = { 1_000 }, recordDiagnostic = { code, _ -> calls.diagnostics += code }, persistenceDispatcher = dispatcher,
            parseQuickOpen = { input, context -> calls.parses += input to context; parse(input, context) },
            reduceAction = { state, action -> calls.reductions += action; reduceFixture(state, action) })
        store.updateHosts(initial.tabs.map { SharedArtifactsQuickOpenHost(it.hostId, it.hostLabel) }.distinct())
        runCurrent()
        assertTrue(calls.reductions.isEmpty())
        return Fixture(store, calls)
    }

    private fun reduceFixture(state: SharedArtifactsState, action: SharedArtifactsAction): SharedArtifactsReduction {
        val next = when (action) {
            is SharedArtifactsAction.AgentEditObserved -> state.copy(tabs = state.tabs.map {
                if (it.hostId == action.hostId && it.target is SharedArtifactsTarget.File && it.target.path == action.path) {
                    it.copy(unseenChange = true, agentEditedAt = action.nowMillis, cache = it.cache?.copy(isStale = true))
                } else it
            })
            is SharedArtifactsAction.RemoteStatObserved -> state.copy(tabs = state.tabs.map {
                val cache = it.cache
                val changed = cache != null && (action.remoteMTime?.let { mtime -> mtime != cache.remoteMTime } == true ||
                    action.size?.let { size -> size >= 0 && size != cache.size } == true)
                if (it.id == action.tabId && changed) it.copy(cache = cache.copy(isStale = true), unseenChange = state.selectedId != it.id || !action.visible) else it
            })
            is SharedArtifactsAction.Fetched -> state.copy(tabs = state.tabs.map {
                if (it.id == action.tabId) it.copy(cache = action.cache.copy(fetchedAt = action.nowMillis, isStale = false), unseenChange = false) else it
            })
            is SharedArtifactsAction.TitleLearned -> state.copy(tabs = state.tabs.map {
                if (it.id == action.tabId && action.title.isNotEmpty()) it.copy(title = action.title) else it
            })
            is SharedArtifactsAction.HostRelabelled -> state.copy(tabs = state.tabs.map { if (it.hostId == action.hostId) it.copy(hostLabel = action.label) else it })
            is SharedArtifactsAction.HostRemoved -> state.copy(tabs = state.tabs.filter { it.hostId != action.hostId })
            else -> error("unexpected action: $action")
        }
        return SharedArtifactsReduction(next, next.selectedId, emptyList(), null)
    }

    private fun TestScope.show(fixture: Fixture) {
        fixture.store.noteVisible("a")
        fixture.store.setForeground(true)
        runCurrent()
    }

    @Test fun thirtyTwoUnrelatedEditsDoNotReduceFourMiBOfHiddenChangeTabs() = runTest {
        val diff = "+".repeat(64 * 1024)
        val initial = SharedArtifactsState(tabs = (0 until 64).map { index ->
            fileTab("change-$index").copy(target = SharedArtifactsTarget.Change("/work/$index.txt", diff, "edit"), kind = SharedArtifactsKind.Changes, cache = null)
        })
        val (store, calls) = fixture(initial)
        repeat(32) { store.agentEditObserved("h", "/work/unrelated-$it.txt", "+new", "edit-$it", null) }
        runCurrent()
        store.agentEditObserved("h", "unrelated.txt", "+new", "relative", "/work")
        runCurrent()
        advanceTimeBy(501); runCurrent()
        assertEquals(0, calls.reductions.size)
        assertEquals(0, calls.parses.size)
        assertEquals(0, calls.writes)
        assertSame(initial, store.state.value)
    }

    @Test fun unrelatedAbsolutePathsAndHostsWithoutFileTabsNeverReachNativeWork() = runTest {
        val page = fileTab("page", "page-host").copy(target = SharedArtifactsTarget.Page("http", 5173, "/work/a.txt"), kind = SharedArtifactsKind.Pages)
        val initial = SharedArtifactsState(tabs = listOf(fileTab(), page))
        val (store, calls) = fixture(initial)
        repeat(32) {
            store.agentEditObserved("h", "/work/unrelated-$it.txt", "+new", "$it", null)
            store.agentEditObserved("unknown", "a.txt", "+new", "$it", "/work")
            store.agentEditObserved("page-host", "a.txt", "+new", "$it", "/work")
        }
        runCurrent()
        assertEquals(0, calls.reductions.size)
        assertEquals(0, calls.parses.size)
        assertSame(initial, store.state.value)
    }

    @Test fun repeatedRelativeEditsAreDeduplicatedBeforeParsingAndOnlyTheMatchingFileIsMarked() = runTest {
        val initial = SharedArtifactsState(tabs = listOf(fileTab(), fileTab("b", "other"), fileTab("c", path = "/work/c.txt"),
            fileTab("change").copy(target = SharedArtifactsTarget.Change("/work/a.txt", "+old", "edit"), kind = SharedArtifactsKind.Changes)))
        val (store, calls) = fixture(initial, parse = { input, context ->
            assertEquals("a.txt", input)
            assertEquals("h", context.currentHostId)
            assertEquals("/work", context.cwd)
            SharedArtifactsQuickOpenIntent.File("h", "/work/a.txt")
        })
        store.agentEditObserved("h", "a.txt", "+new", "record", "/work", 100)
        runCurrent()
        val marked = checkNotNull(store.tab("a"))
        assertTrue(marked.unseenChange)
        assertTrue(checkNotNull(marked.cache).isStale)
        assertEquals(100L, marked.agentEditedAt)
        assertTrue(store.state.value.tabs.filter { it.id != "a" }.none { it.unseenChange })
        assertEquals(listOf(SharedArtifactsAction.AgentEditObserved("h", "/work/a.txt", 100)), calls.reductions)
        assertEquals(1, calls.parses.size)
        calls.reductions.clear()
        repeat(32) { store.agentEditObserved("h", "a.txt", "+new", "record", "/work", 100) }
        runCurrent()
        assertEquals(0, calls.reductions.size)
        assertEquals(1, calls.parses.size)
    }

    @Test fun unrelatedRelativePathsAreResolvedOnceThenSkippedBeforeReduction() = runTest {
        val initial = SharedArtifactsState(tabs = listOf(fileTab()))
        val (store, calls) = fixture(initial, parse = { _, _ -> SharedArtifactsQuickOpenIntent.File("h", "/work/elsewhere.txt") })
        repeat(32) { store.agentEditObserved("h", "elsewhere.txt", "+new", "record", "/work") }
        runCurrent()
        assertEquals(1, calls.parses.size)
        assertEquals(0, calls.reductions.size)
        assertSame(initial, store.state.value)
    }

    @Test fun missingCwdEditsCanRetryOnceDirectoryProofArrives() = runTest {
        val (store, calls) = fixture(SharedArtifactsState(tabs = listOf(fileTab())),
            parse = { _, _ -> SharedArtifactsQuickOpenIntent.File("h", "/work/a.txt") })
        repeat(2) { store.agentEditObserved("h", "a.txt", "+new", "record", null, 100) }
        runCurrent()
        assertEquals(listOf("artifacts_agent_edit_skipped"), calls.diagnostics)
        assertEquals(0, calls.parses.size)
        assertEquals(0, calls.reductions.size)
        store.agentEditObserved("h", "a.txt", "+new", "record", "/work", 100)
        runCurrent()
        assertEquals(1, calls.parses.size)
        assertEquals(1, calls.reductions.size)
        assertTrue(checkNotNull(store.tab("a")).unseenChange)
    }

    @Test fun pathChecksKeepReducerSlashDotAndLiteralParentAndUnicodeSemantics() = runTest {
        val (store, calls) = fixture(SharedArtifactsState(tabs = listOf(fileTab(), fileTab("unicode", path = "/work/\u00e9.txt"))))
        store.agentEditObserved("h", "/work/../work/a.txt", "+new", "parent", null)
        store.agentEditObserved("h", "/work/e\u0301.txt", "+new", "decomposed", null)
        runCurrent()
        assertEquals(0, calls.reductions.size)
        store.agentEditObserved("h", "/work//./a.txt", "+new", "dot", null, 100)
        runCurrent()
        assertEquals(listOf(SharedArtifactsAction.AgentEditObserved("h", "/work//./a.txt", 100)), calls.reductions)
        assertEquals(0, calls.parses.size)
    }

    @Test fun fetchedHistoryAndAlreadyAppliedMarksDoNotReduceButLaterEditsStillWinInArrivalOrder() = runTest {
        val (store, calls) = fixture(SharedArtifactsState(tabs = listOf(fileTab().copy(cache = SharedArtifactsCacheMetadata(50, 10, 3)))))
        store.agentEditObserved("h", "/work/a.txt", "+old", "history", null, 50)
        runCurrent()
        assertEquals(0, calls.reductions.size)
        store.agentEditObserved("h", "/work/a.txt", "+first", "first", null, 200)
        store.agentEditObserved("h", "/work/a.txt", "+last", "last", null, 100)
        runCurrent()
        assertEquals(listOf(200L, 100L), calls.reductions.map { it.nowMillis })
        assertEquals(100L, checkNotNull(store.tab("a")).agentEditedAt)
        calls.reductions.clear()
        store.agentEditObserved("h", "/work/a.txt", "+same mark", "another-record", null, 100)
        runCurrent()
        assertEquals(0, calls.reductions.size)
    }

    @Test fun thirtyTwoUnchangedFollowerStatsDoNotReduceOrDownload() = runTest {
        val files = Files()
        val fixture = fixture(SharedArtifactsState(tabs = listOf(fileTab()), selectedId = "a"), files)
        show(fixture)
        assertTrue(fixture.store.content("a") is ArtifactContent.Document)
        assertEquals(1, files.reads)
        fixture.calls.reductions.clear()
        advanceTimeBy(96_001); runCurrent()
        assertEquals(32, files.stats)
        assertEquals(0, fixture.calls.reductions.size)
        assertEquals(1, files.reads)
        assertEquals(0, files.forwards)
    }

    @Test fun unknownAndNegativeStatFieldsDoNotInventChanges() = runTest {
        val files = Files()
        val fixture = fixture(SharedArtifactsState(tabs = listOf(fileTab()), selectedId = "a"), files)
        show(fixture)
        fixture.calls.reductions.clear()
        files.mtime = null
        files.statSize = null
        advanceTimeBy(3_001); runCurrent()
        files.statSize = -1
        advanceTimeBy(3_000); runCurrent()
        assertEquals(2, files.stats)
        assertEquals(0, fixture.calls.reductions.size)
        assertEquals(1, files.reads)
    }

    @Test fun aChangedStatStillReducesBeforeItsRefetchPublishes() = runTest {
        val files = Files()
        val fixture = fixture(SharedArtifactsState(tabs = listOf(fileTab()), selectedId = "a"), files)
        show(fixture)
        fixture.calls.reductions.clear()
        files.mtime = 11
        files.statSize = 4
        files.bytes = "next"
        advanceTimeBy(3_001); runCurrent()
        assertEquals(listOf("RemoteStatObserved", "Fetched"), fixture.calls.reductions.map { it.javaClass.simpleName })
        assertEquals(2, files.reads)
        val updated = checkNotNull(fixture.store.tab("a"))
        assertEquals(SharedArtifactsCacheMetadata(1_000, 11, 4), updated.cache)
        assertFalse(updated.unseenChange)
    }

    @Test fun anUnchangedStatStillReloadsAfterMissingContentWithoutANoOpReduction() = runTest {
        val files = Files()
        val fixture = fixture(SharedArtifactsState(tabs = listOf(fileTab()), selectedId = "a"), files)
        show(fixture)
        files.missing = true
        advanceTimeBy(3_001); runCurrent()
        assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.Missing), fixture.store.content("a"))
        fixture.calls.reductions.clear()
        files.missing = false
        advanceTimeBy(3_000); runCurrent()
        assertTrue(fixture.store.content("a") is ArtifactContent.Document)
        assertEquals(2, files.reads)
        // The frozen clock makes the second Fetched action identical too.
        assertEquals(0, fixture.calls.reductions.size)
    }

    @Test fun aStatWithoutACacheBaselineRetriesTheLoadWithoutReducing() = runTest {
        val files = Files().apply { readUnavailable = true }
        val fixture = fixture(SharedArtifactsState(tabs = listOf(fileTab().copy(cache = null)), selectedId = "a"), files)
        show(fixture)
        advanceTimeBy(3_001); runCurrent()
        assertEquals(1, files.stats)
        assertEquals(2, files.reads)
        assertEquals(0, fixture.calls.reductions.size)
    }

    @Test fun unknownEmptyAndUnchangedTitlesDoNotReduce() = runTest {
        val (store, calls) = fixture(SharedArtifactsState(tabs = listOf(fileTab())))
        store.titleLearned("unknown", "new")
        store.titleLearned("a", "")
        repeat(32) { store.titleLearned("a", "a.txt") }
        runCurrent()
        assertEquals(0, calls.reductions.size)
        store.titleLearned("a", "learned")
        runCurrent()
        assertEquals("learned", checkNotNull(store.tab("a")).title)
        assertEquals(1, calls.reductions.size)
    }

    @Test fun hostDirectoryAndSessionLivenessUpdatesOnlyReduceAffectedHosts() = runTest {
        val files = Files().apply { live = false }
        val (store, calls) = fixture(SharedArtifactsState(tabs = listOf(fileTab())), files)
        val profilesRemoved = mutableListOf<Set<String>>()
        store.onHostsRemoved = { profilesRemoved += it }
        repeat(4) {
            store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "h"), SharedArtifactsQuickOpenHost("empty", "empty-$it")))
            store.updateDirectories(mapOf("h" to "/work/$it"))
            files.live = it % 2 == 0
            store.setForeground(true)
            runCurrent()
        }
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "h")))
        runCurrent()
        assertEquals(0, calls.reductions.size)
        assertEquals(listOf(setOf("empty")), profilesRemoved)
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "renamed")))
        runCurrent()
        assertEquals(listOf(SharedArtifactsAction.HostRelabelled("h", "renamed", 1_000)), calls.reductions)
        assertEquals("renamed", checkNotNull(store.tab("a")).hostLabel)
        calls.reductions.clear()
        store.updateHosts(emptyList())
        runCurrent()
        assertEquals(listOf(SharedArtifactsAction.HostRemoved("h", 1_000)), calls.reductions)
        assertTrue(store.state.value.tabs.isEmpty())
        assertEquals(0, files.reads)
        assertEquals(0, files.stats)
        assertEquals(0, files.forwards)
    }

    @Test fun offlineBackgroundEventsNeverOpenAChannelOrFetch() = runTest {
        val files = Files().apply { live = false }
        val fixture = fixture(SharedArtifactsState(tabs = listOf(fileTab()), selectedId = "a"), files)
        show(fixture)
        fixture.store.agentEditObserved("h", "/work/unrelated.txt", "+new", "unrelated", null)
        fixture.store.agentEditObserved("h", "/work/a.txt", "+new", "matching", null, 100)
        advanceTimeBy(9_001); runCurrent()
        assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.Offline), fixture.store.content("a"))
        assertTrue(checkNotNull(fixture.store.tab("a")).unseenChange)
        assertEquals(1, fixture.calls.reductions.size)
        assertEquals(0, files.stats)
        assertEquals(0, files.reads)
        assertEquals(0, files.probes)
        assertEquals(0, files.forwards)
    }
}
