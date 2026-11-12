package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.CoreBridge
import com.bambouville.tessera.core.bridge.CoreBridgeState
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenHost
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import com.bambouville.tessera.forwarding.ArtifactLiveForwardingRegistry
import com.bambouville.tessera.forwarding.BoundForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import com.bambouville.tessera.forwarding.PortForwardingLease
import java.io.File
import java.util.UUID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The browser's open, navigate and reopen paths through the real shared
 * reducer, with a fake forwarding session: nothing here connects.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ArtifactsBrowserStoreNativeTest {
    @get:Rule val temporary = TemporaryFolder()
    @Before fun requireNativeCore() { assumeTrue(CoreBridge.inspect() is CoreBridgeState.Ready) }

    private class Rules : PortForwardRuleStore {
        val value = MutableStateFlow(emptyList<PortForwardRule>())
        override fun observe(hostId: String) = value
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) { value.value = rules }
        override suspend fun delete(hostId: String) { value.value = emptyList() }
    }
    private class Lease : PortForwardingLease {
        override val bound = BoundForwardEndpoint("127.0.0.1", 45_555)
        override val activeConnectionCount = MutableStateFlow(0)
        override val isOpen = MutableStateFlow(true)
        override fun close() { isOpen.value = false }
    }

    private val host = UUID.randomUUID().toString()
    private val session = UUID.randomUUID().toString()
    private val leases = mutableListOf<Lease>()
    private val provider = ArtifactLiveForwardingRegistry.publishAcquirer(session, { true }, { Lease().also { leases += it } })
    private val registration = ArtifactLiveForwardingRegistry.register(host, session, MutableStateFlow(emptyMap())) { true }

    @After fun closeRegistry() { registration.close(); provider.close() }

    private fun TestScope.store(): ArtifactsStore {
        val hosts = ArtifactsLiveHosts(findFiles = { null }, findContext = { null }, findOpenable = { null })
        val dispatcher = StandardTestDispatcher(testScheduler)
        val store = ArtifactsStore(ArtifactsStateFile(File(temporary.root, "state.json")), hosts,
            ArtifactContentLoader(File(temporary.root, "cache"), hosts::files, ioDispatcher = dispatcher),
            ArtifactPageForwarder(hosts, Rules(), ioDispatcher = dispatcher), backgroundScope,
            { 100L }, persistenceDispatcher = dispatcher)
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost(host, "devbox")))
        runCurrent()
        return store
    }

    private suspend fun ArtifactsStore.typed(input: String, placement: ArtifactOpenPlacement = ArtifactOpenPlacement.NewTab): String =
        (quickOpen(input, host, placement) as ArtifactQuickOpenOutcome.Opened).tabId

    private fun ArtifactsStore.page(id: String) = content(id) as ArtifactContent.ForwardedPage

    @Test fun typedOpensOnOnePortAreNewTabsThatShareOneForward() = runTest {
        val store = store()
        val root = store.typed("localhost:8001")
        val laptop = store.typed("localhost:8001/laptop.html")
        val again = store.typed("localhost:8001/laptop.html")
        runCurrent()
        assertEquals("the identical address opens a third tab", 3, setOf(root, laptop, again).size)
        assertEquals(3, store.state.value.tabs.size)
        assertEquals(SharedArtifactsTarget.Page("http", 8001, "/"), store.tab(root)?.target)
        assertEquals(SharedArtifactsTarget.Page("http", 8001, "/laptop.html"), store.tab(laptop)?.target)
        assertEquals(SharedArtifactsTarget.Page("http", 8001, "/laptop.html"), store.tab(again)?.target)
        assertEquals("http://127.0.0.1:45555/", store.page(root).url)
        assertEquals("http://127.0.0.1:45555/laptop.html", store.page(laptop).url)
        assertTrue(store.page(again).isEphemeral)
        assertEquals("one forward serves every tab on the port", 1, leases.size)
        store.close(root); runCurrent()
        assertTrue("closing one tab keeps the forward its siblings use", leases.single().isOpen.value)
        store.close(laptop); runCurrent()
        assertTrue(leases.single().isOpen.value)
        store.close(again); runCurrent()
        assertFalse("the last tab closes the forward", leases.single().isOpen.value)
    }

    @Test fun automaticOpensFocusTheExactTabAndTheAddressBarNavigatesItsOwnTab() = runTest {
        val store = store()
        val root = store.typed("localhost:8001")
        val laptop = store.typed("localhost:8001/laptop.html")
        runCurrent()
        store.select(root); runCurrent()
        // Terminal selections, agent follows and Open in Artifacts still dedupe.
        store.open(ArtifactOpenRequest.Page(host, "http", 8001, "/laptop.html", ArtifactOpenOrigin.TerminalSelection)); runCurrent()
        assertEquals(2, store.state.value.tabs.size)
        assertEquals(laptop, store.state.value.selectedId)

        val before = store.page(root)
        assertEquals(root, store.typed("localhost:8001/docs/?q=1", ArtifactOpenPlacement.Navigate(root)))
        runCurrent()
        assertEquals(2, store.state.value.tabs.size)
        assertEquals(root, store.state.value.selectedId)
        assertEquals(SharedArtifactsTarget.Page("http", 8001, "/docs/?q=1"), store.tab(root)?.target)
        val after = store.page(root)
        assertEquals("the viewer keeps its origin and history", "http://127.0.0.1:45555/docs/?q=1", after.url)
        assertTrue(after.navigation > before.navigation)
        // Return on the unchanged address loads it again, as a browser does.
        store.typed("localhost:8001/docs/?q=1", ArtifactOpenPlacement.Navigate(root)); runCurrent()
        assertTrue(store.page(root).navigation > after.navigation)
        assertEquals(1, leases.size)
        assertEquals("the other tab is untouched", "http://127.0.0.1:45555/laptop.html", store.page(laptop).url)
    }

    @Test fun anotherPortNavigatesInPlaceAndMovesTheTabToItsOwnForward() = runTest {
        val store = store()
        val root = store.typed("localhost:8001")
        val sibling = store.typed("localhost:8001/laptop.html")
        runCurrent()
        assertEquals(root, store.typed("localhost:9000/", ArtifactOpenPlacement.Navigate(root)))
        runCurrent()
        assertEquals(SharedArtifactsTarget.Page("http", 9000, "/"), store.tab(root)?.target)
        assertEquals(2, leases.size)
        assertTrue("the sibling still holds port 8001", leases[0].isOpen.value)
        store.close(sibling); runCurrent()
        assertFalse(leases[0].isOpen.value)
        assertTrue(leases[1].isOpen.value)
    }

    @Test fun navigatingAPageTabToAFileReleasesItsForward() = runTest {
        val store = store()
        val root = store.typed("localhost:8001")
        runCurrent()
        assertTrue(leases.single().isOpen.value)
        assertEquals(root, store.typed("/work/notes.md", ArtifactOpenPlacement.Navigate(root)))
        runCurrent()
        assertEquals(SharedArtifactsTarget.File("/work/notes.md"), store.tab(root)?.target)
        assertEquals("notes.md", store.tab(root)?.title)
        assertFalse(leases.single().isOpen.value)
        assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.Offline), store.content(root))
        assertEquals(1, store.state.value.tabs.size)
    }

    @Test fun reopenClosedBringsBackTheLastClosedTabAsANewTabAndForgetsRemovedHosts() = runTest {
        val store = store()
        store.open(ArtifactOpenRequest.File(host, "/work/a.md", ArtifactOpenOrigin.Files)); runCurrent()
        store.open(ArtifactOpenRequest.File(host, "/work/b.md", ArtifactOpenOrigin.Files)); runCurrent()
        val b = store.state.value.tabs.single { it.target == SharedArtifactsTarget.File("/work/b.md") }
        store.setPinned(b.id, true); runCurrent()
        store.close(b.id); runCurrent()
        assertEquals(1, store.state.value.tabs.size)
        store.reopenClosed(); runCurrent()
        val reopened = store.state.value.tabs.single { it.target == SharedArtifactsTarget.File("/work/b.md") }
        assertNotEquals(b.id, reopened.id)
        assertTrue(reopened.pinned)
        assertEquals(reopened.id, store.state.value.selectedId)
        assertEquals("files", reopened.origin)
        store.reopenClosed(); runCurrent()
        assertEquals("nothing else was closed", 2, store.state.value.tabs.size)
        store.closeAll(host); runCurrent()
        store.updateHosts(emptyList()); runCurrent()
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost(host, "devbox"))); runCurrent()
        store.reopenClosed(); runCurrent()
        assertTrue("a removed host's closed tabs cannot come back", store.state.value.tabs.isEmpty())
    }

    @Test fun shareOffersFilesOnlyAndNeverAnUndownloadedOne() = runTest {
        val store = store()
        store.open(ArtifactOpenRequest.File(host, "/work/a.md", ArtifactOpenOrigin.Files)); runCurrent()
        val file = store.state.value.tabs.single().id
        assertEquals(ArtifactShare.Unavailable(ARTIFACT_SHARE_NOT_DOWNLOADED), store.share(file))
        val page = store.typed("localhost:8001"); runCurrent()
        assertNull("a forwarded page has no share control", store.share(page))
    }
}
