package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactRemoteStat
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import java.io.IOException
import java.io.OutputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ArtifactsQuickOpenFilesTest {
    @get:Rule val temporary = TemporaryFolder()

    private class Rules : PortForwardRuleStore {
        override fun observe(hostId: String) = MutableStateFlow(emptyList<PortForwardRule>())
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) = error("must not save a rule")
        override suspend fun delete(hostId: String) = Unit
    }

    private class Files : ArtifactLiveFiles {
        var live = false
        override val hasLiveArtifactChannel get() = live
        override val canOpenArtifactChannel get() = !live
        var home: String? = null
        var publishesHome = true
        override val artifactHome get() = home.takeIf { live && publishesHome }
        var generation = 1L
        override val artifactConnectionGeneration get() = generation
        val realPaths = mutableListOf<String>()
        var canonicalize: (String) -> String = { it }
        override val artifactDirectory: String? = null
        var opens = 0
        var stats = 0
        val statPaths = mutableListOf<String>()
        var failure: Exception? = null
        var gate: CompletableDeferred<Unit>? = null
        var directory = false
        override suspend fun openArtifactChannel() {
            opens += 1
            gate?.await()
            failure?.let { throw it }
            live = true
        }
        override suspend fun realPathArtifactOnLiveChannel(path: String): String? {
            check(live)
            realPaths += path
            return if (path == ".") home else canonicalize(path)
        }
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat {
            check(live)
            stats += 1
            statPaths += path
            return ArtifactRemoteStat(path, 4, 1, directory)
        }
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat {
            check(live)
            output.write("plan".encodeToByteArray())
            return ArtifactRemoteStat(path, 4, 1, false)
        }
        override suspend fun probeOnLiveChannel(command: String): String? = null
    }

    private fun TestScope.store(files: Files, sessionLive: Boolean = true): ArtifactsStore {
        val hosts = ArtifactsLiveHosts(
            findFiles = { files.takeIf { sessionLive && it.hasLiveArtifactChannel } },
            findContext = { null }, findForwarding = { emptyList() },
            findOpenable = { files.takeIf { sessionLive } },
        )
        val dispatcher = StandardTestDispatcher(testScheduler)
        val loader = ArtifactContentLoader(temporary.newFolder(), hosts::files, key = { "a".repeat(64) },
            viewer = { SharedArtifactsViewer.Text }, evictions = { _, _, _ -> emptyList() }, ioDispatcher = dispatcher)
        val stateFile = ArtifactsStateFile(temporary.newFile().apply { writeText("initial") },
            decode = { SharedArtifactsState() }, encode = { "saved" })
        val store = ArtifactsStore(stateFile, hosts, loader, ArtifactPageForwarder(hosts, Rules(), ioDispatcher = dispatcher),
            backgroundScope, persistenceDispatcher = dispatcher,
            parseQuickOpen = { input, _ ->
                if (input == "~" || input.endsWith('/')) SharedArtifactsQuickOpenIntent.Directory("h", input)
                else SharedArtifactsQuickOpenIntent.File("h", input)
            },
            reduceAction = { state, action ->
                val next = when (action) {
                    is SharedArtifactsAction.Open -> {
                        val request = action.request
                        val tab = SharedArtifactTab(request.id, request.hostId, request.hostLabel, request.target,
                            SharedArtifactsKind.Docs, request.title, request.origin, null, 1, 1, false, null, false, null)
                        state.copy(tabs = state.tabs + tab, selectedId = tab.id)
                    }
                    is SharedArtifactsAction.Fetched -> state.copy(tabs = state.tabs.map {
                        if (it.id == action.tabId) it.copy(cache = action.cache) else it
                    })
                    else -> error("unexpected action: $action")
                }
                SharedArtifactsReduction(next, next.selectedId, emptyList(), null)
            })
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "host")))
        runCurrent()
        return store
    }

    @Test fun quickOpenConnectsFilesBeforeOpeningAFile() = runTest {
        val files = Files()
        val store = store(files)
        val outcome = store.quickOpen("/tmp/x/plan.md", "h")
        assertTrue(outcome is ArtifactQuickOpenOutcome.Opened)
        assertEquals(1, files.opens)
        assertEquals(1, files.stats)
        assertEquals(SharedArtifactsTarget.File("/tmp/x/plan.md"), store.state.value.tabs.single().target)
    }

    @Test fun quickOpenReportsTheFilesConnectionFailure() = runTest {
        val files = Files().apply { failure = IOException("channel refused") }
        val store = store(files)
        assertEquals(ArtifactQuickOpenOutcome.Failed("channel refused"), store.quickOpen("/tmp/x/plan.md", "h"))
        assertEquals(1, files.opens)
        assertEquals(0, files.stats)
        assertTrue(store.state.value.tabs.isEmpty())
    }

    @Test fun quickOpenExpandsHomeAfterConnectingFiles() = runTest {
        val files = Files().apply { home = "/home/u"; publishesHome = false }
        val store = store(files)
        assertEquals(null, files.artifactHome)
        assertTrue(store.quickOpen("~/notes/plan.md", "h") is ArtifactQuickOpenOutcome.Opened)
        assertEquals(1, files.opens)
        assertEquals(listOf(".", "/home/u/notes/plan.md"), files.realPaths)
        assertEquals(listOf("/home/u/notes/plan.md"), files.statPaths)
        assertEquals(SharedArtifactsTarget.File("/home/u/notes/plan.md"), store.state.value.tabs.single().target)
    }

    @Test fun quickOpenResolvesHomeAloneToADirectoryAfterConnectingFiles() = runTest {
        val files = Files().apply { home = "/home/u"; publishesHome = false; directory = true }
        val store = store(files)
        assertEquals(ArtifactQuickOpenOutcome.Directory("h", "/home/u"), store.quickOpen("~", "h"))
        assertEquals(1, files.opens)
        assertEquals(listOf(".", "/home/u"), files.realPaths)
        assertEquals(listOf("/home/u"), files.statPaths)
        assertTrue(store.state.value.tabs.isEmpty())
    }

    @Test fun quickOpenUsesTheCanonicalExpandedPathForTheTab() = runTest {
        val files = Files().apply { home = "/home/u"; canonicalize = { "/srv/notes/plan.md" } }
        val store = store(files)
        assertTrue(store.quickOpen("~/notes/plan.md", "h") is ArtifactQuickOpenOutcome.Opened)
        assertEquals(listOf("/home/u/notes/plan.md"), files.realPaths)
        assertEquals(listOf("/srv/notes/plan.md"), files.statPaths)
        assertEquals(SharedArtifactsTarget.File("/srv/notes/plan.md"), store.state.value.tabs.single().target)
    }

    @Test fun quickOpenReportsAnUnavailableHomeWithoutStattingOrOpeningATab() = runTest {
        val files = Files()
        val store = store(files)
        assertEquals(ArtifactQuickOpenOutcome.Failed(ArtifactMessage.Resource(R.string.artifacts_home_unavailable)), store.quickOpen("~", "h"))
        assertEquals(1, files.opens)
        assertEquals(listOf("."), files.realPaths)
        assertEquals(0, files.stats)
        assertTrue(store.state.value.tabs.isEmpty())
    }

    @Test fun quickOpenRejectsAConnectionReplacedWhileCanonicalizing() = runTest {
        val files = Files().apply { home = "/home/u"; canonicalize = { generation += 1; it } }
        val store = store(files)
        assertEquals(ArtifactQuickOpenOutcome.Failed(ArtifactMessage.Resource(R.string.artifacts_files_connection_unavailable)), store.quickOpen("~/notes/plan.md", "h"))
        assertEquals(1, files.opens)
        assertEquals(0, files.stats)
        assertTrue(store.state.value.tabs.isEmpty())
    }

    @Test fun quickOpenWithoutASessionKeepsTheOfflineTabAndNeverConnects() = runTest {
        val files = Files()
        val store = store(files, sessionLive = false)
        assertTrue(store.quickOpen("/tmp/x/plan.md", "h") is ArtifactQuickOpenOutcome.Opened)
        assertEquals(0, files.opens)
        assertEquals(0, files.stats)
        assertEquals(SharedArtifactsTarget.File("/tmp/x/plan.md"), store.state.value.tabs.single().target)
    }

    @Test fun quickOpenUsesAnAlreadyConnectedFilesChannel() = runTest {
        val files = Files().apply { live = true }
        val store = store(files)
        assertTrue(store.quickOpen("/tmp/x/plan.md", "h") is ArtifactQuickOpenOutcome.Opened)
        assertEquals(0, files.opens)
        assertEquals(1, files.stats)
    }

    @Test fun quickOpenRecognizesADirectoryAfterConnectingFiles() = runTest {
        val files = Files().apply { directory = true }
        val store = store(files)
        assertEquals(ArtifactQuickOpenOutcome.Directory("h", "/tmp/x"), store.quickOpen("/tmp/x", "h"))
        assertEquals(1, files.opens)
        assertEquals(1, files.stats)
        assertTrue(store.state.value.tabs.isEmpty())
    }

    @Test fun cancellingQuickOpenDuringTheFilesConnectionDoesNotOpenATab() = runTest {
        val files = Files().apply { gate = CompletableDeferred() }
        val store = store(files)
        val opening = backgroundScope.async { store.quickOpen("/tmp/x/plan.md", "h") }
        runCurrent()
        assertEquals(1, files.opens)
        opening.cancel()
        runCurrent()
        try { opening.await(); error("cancelled Quick Open returned") }
        catch (_: CancellationException) { }
        assertEquals(0, files.stats)
        assertTrue(store.state.value.tabs.isEmpty())
    }
}
