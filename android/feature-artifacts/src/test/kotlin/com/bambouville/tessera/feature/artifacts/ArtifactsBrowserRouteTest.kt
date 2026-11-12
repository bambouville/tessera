package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.CoreBridge
import com.bambouville.tessera.core.bridge.CoreBridgeState
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenHost
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import java.io.File
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** The app root disposes the browser on every app-tab switch; its route must outlive that. */
@OptIn(ExperimentalCoroutinesApi::class)
class ArtifactsBrowserRouteTest {
    @get:Rule val temporary = TemporaryFolder()
    private class Rules : PortForwardRuleStore {
        override fun observe(hostId: String) = MutableStateFlow(emptyList<PortForwardRule>())
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) = error("must not save a rule")
        override suspend fun delete(hostId: String) = Unit
    }

    /** One composition of ArtifactsBrowser: it shows the route's tab, then its effect records the selection. */
    private fun ArtifactsUiStore.shown(): String? {
        val state = state.value
        val viewedAt = state.tabs.firstOrNull { it.id == state.selectedId }?.viewedAt
        val id = route.displayedId(state.selectedId, viewedAt)
        route.follow(state.selectedId, viewedAt)
        return state.tabs.firstOrNull { it.id == id }?.id
    }

    @Test fun routeRevealsOnlyASelectionItHasNotSeen() {
        val route = ArtifactsBrowserRoute()
        assertEquals("a first screen shows the selection at once", "a", route.displayedId("a", 1))
        route.follow("a", 1)
        route.show(null)
        assertNull(route.displayedId("a", 1))
        route.follow("a", 1)
        assertNull("a rebuilt screen keeps the overview", route.displayedId("a", 1))
        assertEquals("selecting the same tab again reveals it", "a", route.displayedId("a", 2))
        route.follow("a", 2)
        route.show("b")
        assertEquals("a tab picked before the store applies the select shows at once", "b", route.displayedId("a", 2))
        route.follow("b", 3)
        assertEquals("b", route.displayedId("b", 3))
        route.follow(null, null)
        assertNull(route.displayedId(null, null))
    }

    @Test fun browserComesBackToTheOverviewOrTabTheUserLeftAfterTheScreenIsRebuilt() = runTest {
        assumeTrue(CoreBridge.inspect() is CoreBridgeState.Ready)
        val hosts = ArtifactsLiveHosts(findFiles = { null }, findContext = { null }, findForwarding = { emptyList() }, findOpenable = { null })
        val dispatcher = StandardTestDispatcher(testScheduler)
        var now = 100L
        val store = ArtifactsStore(ArtifactsStateFile(File(temporary.root, "state.json")), hosts,
            ArtifactContentLoader(File(temporary.root, "cache"), hosts::files, ioDispatcher = dispatcher),
            ArtifactPageForwarder(hosts, Rules(), ioDispatcher = dispatcher), backgroundScope, { now++ },
            persistenceDispatcher = dispatcher)
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "devbox")))
        val pageRequest = ArtifactOpenRequest.Page("h", "http", 5173, "/", ArtifactOpenOrigin.QuickOpen)
        store.open(ArtifactOpenRequest.File("h", "/notes.md", ArtifactOpenOrigin.QuickOpen)); runCurrent()
        store.open(pageRequest); runCurrent()
        val notes = store.state.value.tabs.single { it.target == SharedArtifactsTarget.File("/notes.md") }.id
        val page = store.state.value.tabs.single { it.target is SharedArtifactsTarget.Page }.id

        // ArtifactsRootScreen makes one adapter per composition of the Artifacts tab.
        var screen: ArtifactsUiStore = LiveArtifactsUiStore(store)
        assertEquals("a first screen shows the selected page", page, screen.shown())
        screen.route.show(null) // back to the overview
        assertNull(screen.shown())
        screen = LiveArtifactsUiStore(store) // a terminal tab, then back
        assertNull("the rebuilt screen shows the overview the user left", screen.shown())
        assertNull(screen.shown())
        assertEquals("the overview keeps the selection", page, store.state.value.selectedId)

        screen.route.show(notes)
        store.select(notes); runCurrent()
        assertEquals(notes, screen.shown())
        screen = LiveArtifactsUiStore(store)
        assertEquals("the rebuilt screen shows the tab the user left", notes, screen.shown())

        screen.route.show(null)
        assertNull(screen.shown())
        store.open(pageRequest.copy(origin = ArtifactOpenOrigin.TerminalLink)); runCurrent()
        screen = LiveArtifactsUiStore(store)
        assertEquals("an open while the screen was gone reveals its tab", page, screen.shown())
    }
}
