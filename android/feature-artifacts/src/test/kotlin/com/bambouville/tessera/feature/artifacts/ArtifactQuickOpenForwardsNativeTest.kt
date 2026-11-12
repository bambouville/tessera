package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.CoreBridge
import com.bambouville.tessera.core.bridge.CoreBridgeState
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenHost
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenIntent
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestion
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestionKind
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.forwarding.ArtifactLiveForwardingRegistry
import com.bambouville.tessera.forwarding.BoundForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import com.bambouville.tessera.forwarding.PortForwardingFailure
import com.bambouville.tessera.forwarding.PortForwardingState
import com.bambouville.tessera.forwarding.PortForwardingStatus
import java.io.File
import java.util.UUID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Quick Open's running forwards come from published session state; listing them never connects. */
@OptIn(ExperimentalCoroutinesApi::class)
class ArtifactQuickOpenForwardsNativeTest {
    @get:Rule val temporary = TemporaryFolder()
    @Before fun requireNativeCore() { assumeTrue(CoreBridge.inspect() is CoreBridgeState.Ready) }
    private class Rules(initial: List<PortForwardRule>) : PortForwardRuleStore {
        val value = MutableStateFlow(initial)
        override fun observe(hostId: String) = value
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) = error("must not save a rule")
        override suspend fun delete(hostId: String) = Unit
    }

    private val vite = PortForwardRule(bind = PortForwardEndpoint("127.0.0.1", 15173), target = PortForwardEndpoint("localhost", 5173), label = "vite")
    private val stopped = PortForwardRule(bind = PortForwardEndpoint("127.0.0.1", 13000), target = PortForwardEndpoint("localhost", 3000))
    private fun listening(rule: PortForwardRule) = PortForwardingState(rule, PortForwardingStatus.Listening(BoundForwardEndpoint("127.0.0.1", rule.bind.port)))

    private fun TestScope.store(host: String): ArtifactsStore {
        val hosts = ArtifactsLiveHosts(findFiles = { null }, findContext = { null }, findOpenable = { null })
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = ArtifactsStore(ArtifactsStateFile(File(temporary.root, "state.json")), hosts,
            ArtifactContentLoader(File(temporary.root, "cache"), hosts::files, ioDispatcher = dispatcher),
            ArtifactPageForwarder(hosts, Rules(listOf(vite, stopped)), ioDispatcher = dispatcher), backgroundScope,
            { 100L }, persistenceDispatcher = dispatcher)
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost(host, "devbox")))
        runCurrent()
        return store
    }

    private fun ArtifactsStore.forwards(vararg inputs: String) = inputs.flatMap { quickOpenSuggestions(it, null) }
        .filter { it.kind == SharedArtifactsSuggestionKind.ActiveForward }

    @Test fun emptyQuickOpenOffersRunningForwardsAndOpensTheirPageThroughThePageTabPath() = runTest {
        val host = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        val states = MutableStateFlow(mapOf(vite.id to listening(vite), stopped.id to PortForwardingState(stopped, PortForwardingStatus.Idle)))
        var acquired = 0
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { true }, { acquired += 1; null })
        val registration = ArtifactLiveForwardingRegistry.register(host, session, states) { true }
        try {
            val store = store(host)
            val forwards = store.forwards("")
            val page = SharedArtifactsQuickOpenIntent.Page(host, "http", 5173, "/")
            assertEquals(listOf(SharedArtifactsSuggestion(SharedArtifactsSuggestionKind.ActiveForward, "localhost:5173", "devbox · vite", page, null)), forwards)
            assertEquals(1, store.forwards("vite").size)
            assertTrue(store.forwards("plan").isEmpty())
            val outcome = store.quickOpen(artifactQuickOpenInput(page.path, page.scheme, page.port), page.hostId)
            val id = (outcome as ArtifactQuickOpenOutcome.Opened).tabId
            runCurrent()
            assertEquals(SharedArtifactsTarget.Page("http", 5173, "/"), store.tab(id)?.target)
            assertEquals(ArtifactContent.ForwardedPage("http://127.0.0.1:15173/", "vite", false), store.content(id))
            assertTrue("its open tab now stands for the forward", store.forwards("").isEmpty())
            assertEquals("the page borrowed the running forward", 0, acquired)
        } finally { registration.close(); provider.close() }
    }

    @Test fun quickOpenOffersNoForwardWhenNoneIsListeningInALiveSession() = runTest {
        val host = UUID.randomUUID().toString()
        val session = UUID.randomUUID().toString()
        val elsewhere = UUID.randomUUID().toString()
        val states = MutableStateFlow(mapOf(vite.id to PortForwardingState(vite, PortForwardingStatus.Idle)))
        var live = true
        var acquired = 0
        val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { live }, { acquired += 1; null })
        val registration = ArtifactLiveForwardingRegistry.register(host, session, states) { live }
        // A host outside the saved-host directory is never offered.
        val stranger = ArtifactLiveForwardingRegistry.register(elsewhere, UUID.randomUUID().toString(), MutableStateFlow(mapOf(vite.id to listening(vite)))) { true }
        try {
            val store = store(host)
            assertEquals(emptyList<SharedArtifactsSuggestion>(), store.forwards("", ":5173", "devbox"))
            states.value = mapOf(vite.id to PortForwardingState(vite, PortForwardingStatus.Failed(PortForwardingFailure.Transport("bind failed"))))
            assertEquals(emptyList<SharedArtifactsSuggestion>(), store.forwards("", ":5173", "devbox"))
            states.value = mapOf(vite.id to listening(vite))
            assertEquals("the fixture must offer a live forward", 3, store.forwards("", ":5173", "devbox").size)
            live = false
            assertEquals("an ended session's listener is not active", emptyList<SharedArtifactsSuggestion>(), store.forwards("", ":5173", "devbox"))
            live = true
            registration.close()
            assertEquals(emptyList<SharedArtifactsSuggestion>(), store.forwards("", ":5173", "devbox"))
            assertEquals(0, acquired)
        } finally { registration.close(); stranger.close(); provider.close() }
    }
}
