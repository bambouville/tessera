package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import java.io.File
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class ArtifactsStoreNativeTest {
    @get:Rule val temporary = TemporaryFolder()
    @Before fun requireNativeCore() { assumeTrue(CoreBridge.inspect() is CoreBridgeState.Ready) }
    private class Rules : PortForwardRuleStore {
        private val value = MutableStateFlow(emptyList<PortForwardRule>())
        override fun observe(hostId: String) = value
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) { value.value = rules }
        override suspend fun delete(hostId: String) { value.value = emptyList() }
    }

    @Test fun storeActionsMatchSharedReductionsAndPersistTheCanonicalState() = runTest {
        val hosts = ArtifactsLiveHosts(findFiles = { null }, findContext = { null }, findForwarding = { emptyList() })
        val dispatcher = StandardTestDispatcher(testScheduler)
        val loader = ArtifactContentLoader(File(temporary.root, "cache"), hosts::files, ioDispatcher = dispatcher)
        val stateFile = ArtifactsStateFile(File(temporary.root, "artifacts/state.json"))
        var now = 100L
        val store = ArtifactsStore(stateFile, hosts, loader, ArtifactPageForwarder(hosts, Rules()), backgroundScope, { now },
            persistenceDispatcher = dispatcher)
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "dev")))
        store.open(ArtifactOpenRequest.File("h", "/work/./a.md", ArtifactOpenOrigin.Files))
        runCurrent()
        val tab = store.state.value.tabs.single()
        var expected = SharedArtifacts.reduce(SharedArtifactsState(), SharedArtifactsAction.Open(
            SharedArtifactsOpenRequest(tab.id, "h", "dev", SharedArtifactsTarget.File("/work/./a.md"), "a.md", "files"), now,
        )).state
        assertEquals(expected, store.state.value)
        store.setPinned(tab.id, true); runCurrent()
        expected = SharedArtifacts.reduce(expected, SharedArtifactsAction.Pin(tab.id, true, now)).state
        store.setFilter(SharedArtifactsFilter.Docs); runCurrent()
        expected = SharedArtifacts.reduce(expected, SharedArtifactsAction.SetFilter(SharedArtifactsFilter.Docs, now)).state
        now = 200
        store.open(ArtifactOpenRequest.File("h", "/work/a.md", ArtifactOpenOrigin.TerminalSelection)); runCurrent()
        expected = SharedArtifacts.reduce(expected, SharedArtifactsAction.Open(
            SharedArtifactsOpenRequest("ignored-id", "h", "dev", SharedArtifactsTarget.File("/work/a.md"), "a.md", "terminalSelection"), now,
        )).state
        assertEquals(expected, store.state.value)
        assertEquals(1, store.state.value.tabs.size)
        store.flush()
        runCurrent()
        assertEquals(expected, stateFile.load())
        assertEquals(SharedArtifacts.encodeState(expected), File(temporary.root, "artifacts/state.json").readText())
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "renamed"))); runCurrent()
        expected = SharedArtifacts.reduce(expected, SharedArtifactsAction.HostRelabelled("h", "renamed", now)).state
        assertEquals(expected, store.state.value)
        store.updateHosts(emptyList()); runCurrent()
        assertTrue(store.state.value.tabs.isEmpty())
        assertTrue(store.revision.value > 0)
    }

    @Test fun agentEditsUseTheSharedActionAndSkipUnprovenRelativePaths() = runTest {
        val hosts = ArtifactsLiveHosts(findFiles = { null }, findContext = { null }, findForwarding = { emptyList() })
        val diagnostics = mutableListOf<String>()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = ArtifactsStore(ArtifactsStateFile(File(temporary.root, "state.json")), hosts,
            ArtifactContentLoader(File(temporary.root, "cache"), hosts::files, ioDispatcher = dispatcher), ArtifactPageForwarder(hosts, Rules()), backgroundScope,
            { 100L }, { code, _ -> diagnostics += code }, persistenceDispatcher = dispatcher)
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "dev")))
        store.open(ArtifactOpenRequest.File("h", "/work/a.md", ArtifactOpenOrigin.Files)); runCurrent()
        store.agentEditObserved("h", "a.md", "+new", "record1", null); runCurrent()
        assertTrue(diagnostics.contains("artifacts_agent_edit_skipped"))
        assertEquals(false, store.state.value.tabs.single().unseenChange)
        store.agentEditObserved("h", "a.md", "+new", "record2", "/work"); runCurrent()
        assertTrue(store.state.value.tabs.single().unseenChange)
        val expected = SharedArtifacts.reduce(store.state.value, SharedArtifactsAction.AgentEditObserved("h", "/work/a.md", 100)).state
        assertEquals(expected, store.state.value)
    }
}
