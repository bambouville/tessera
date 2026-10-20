package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.core.bridge.SharedTmuxRenderEffect
import com.bambouville.tessera.core.bridge.SharedTmuxRenderHistoryPlacement
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import org.junit.Assert.*
import org.junit.Test

/** Drives the production native observer's request route without Android View stubs. */
class MoshPaneHistoryScrollRuntimeTest {
    private class Reader(val paneId: Int) {
        var topRow = -37
        var pending = false
        var closed = false
    }

    private class Fixture {
        val split = SharedTmuxLayoutNode.Split(
            horizontal = true, width = 10, height = 5,
            children = listOf(
                SharedTmuxLayoutNode.Leaf(paneId = 1, width = 4, height = 5),
                SharedTmuxLayoutNode.Leaf(paneId = 2, width = 5, height = 5, x = 5),
            ),
        )
        var focusedPaneId = 1
        var readerPaneId: Int? = null
        var activePanes = setOf(1, 2)
        val presentation = MoshPaneHistoryOverlayPresentation()
        val deliveries = mutableMapOf<String, MoshPaneHistoryReadyDelivery>()
        val attached = mutableSetOf<Int>()
        val events = mutableListOf<String>()
        val requests = mutableListOf<String>()
        val returned = mutableListOf<String>()
        val store = MoshPaneHistoryRuntimeStore(
            createAndAttach = { paneId: Int ->
                events += "attach:$paneId"
                attached += paneId
                Reader(paneId)
            },
            detachAndClose = { paneId, runtime ->
                attached -= paneId
                runtime.closed = true
                events += "close:$paneId"
            },
        )
        val router = MoshPaneHistoryScrollRouter(
            runtimes = store,
            presentation = presentation,
            deliveries = { deliveries },
            paneExists = { it in activePanes },
            isAlternateScreen = { false },
            readerPaneId = { readerPaneId ?: focusedPaneId },
            onReaderPaneChanged = { readerPaneId = it },
            beginHistoryScroll = { it.pending = true; events += "begin:${it.paneId}" },
            onHistoryRequested = { surfaceId, points, inertial ->
                val paneId = surfaceId.substringAfter(':').toInt()
                assertTrue("first request must already have a destination", paneId in attached)
                // The real screen declares all attached readers, before the request.
                val declarations = tmuxScreenRenderSurfaceDeclarations(
                    TmuxScreenRenderPresentation.Single, 7, focusedPaneId, activePanes,
                    emptySet(), attached,
                )
                assertTrue(declarations.any { it.surfaceId == surfaceId && it.paneId == paneId })
                assertTrue(points < 0)
                assertFalse(inertial)
                assertTrue(store.runtimes.getValue(paneId).pending)
                requests += surfaceId
                events += "request:$paneId"
            },
            onReturnedToLiveTail = ::returnToTail,
            onAltScreenScroll = { _, _ -> error("primary pane must request history") },
        )
        val observer = MoshSplitScrollRequestObserver(
            paneAtLocation = { x, y ->
                moshScrollPaneAtLocation(x, y, 10f, 20, 5, 2f, split, focusedPaneId)
            },
            onScroll = router::scroll,
        )

        fun input() = returnMoshPaneHistoryInputToTail(
            paneId = focusedPaneId,
            hasHistory = { surfaceId ->
                surfaceId in deliveries || store.runtimes[focusedPaneId]?.pending == true
            },
            cancelHistoryScroll = { surfaceId ->
                events += "cancel:$surfaceId"
                store.runtimes[focusedPaneId]?.pending = false
            },
            returnToTail = ::returnToTail,
        )

        fun returnToTail(surfaceId: String) {
            returned += surfaceId
            deliveries.remove(surfaceId)
            val paneId = surfaceId.substringAfter(':').toInt()
            store.runtimes[paneId]?.let { it.topRow = 0; it.pending = false }
        }

        fun ready(paneId: Int) {
            val delivery = MoshPaneHistoryReadyDelivery(
                sequence = requests.size.toLong(),
                effect = SharedTmuxRenderEffect.HistoryReady(
                    surfaceId = moshPaneHistoryOverlaySurfaceId(paneId),
                    owner = SharedTmuxRenderOwner(windowId = 7, paneId = paneId, epoch = 3),
                    depth = 240, historySize = 240,
                    placement = SharedTmuxRenderHistoryPlacement.Bottom,
                ),
            )
            deliveries[delivery.effect.surfaceId] = delivery
            assertTrue(presentation.accept(delivery))
            store.runtimes.getValue(paneId).pending = false
        }
    }

    @Test
    fun firstUnfocusedGestureResolvesAttachesAndRequestsWithoutChangingFocus() {
        val f = Fixture()
        assertTrue(f.store.runtimes.isEmpty())
        f.observer.begin(60f, 43f)
        val runtime = f.observer.scroll(-1, -20.0)
        assertNotNull(runtime)
        assertEquals(listOf("attach:2", "begin:2", "request:2"), f.events)
        assertEquals(setOf(2), f.store.runtimes.keys)
        assertEquals(1, f.focusedPaneId)
        f.ready(2)
        assertTrue(f.presentation.shouldReveal(2, f.deliveries))
        // Subsequent frames keep the exact destination and do not re-request.
        assertSame(runtime, f.observer.scroll(-1, -20.0))
        assertEquals(listOf("overlay:2"), f.requests)
    }

    @Test
    fun inputPreservesUnfocusedReaderPositionAndReturnsFocusedReaderToTail() {
        val f = Fixture()
        f.observer.begin(60f, 43f)
        val reader = requireNotNull(f.observer.scroll(-1, -20.0))
        f.ready(2)
        val delivery = f.deliveries.getValue("overlay:2")
        f.input()
        assertEquals(-37, reader.topRow)
        assertSame(delivery, f.deliveries["overlay:2"])
        assertTrue(f.presentation.shouldReveal(2, f.deliveries))
        assertTrue(f.returned.isEmpty())

        f.focusedPaneId = 2
        f.input()
        assertEquals(0, reader.topRow)
        assertEquals(listOf("overlay:2"), f.returned)
        assertEquals("cancel:overlay:2", f.events.last())
        assertFalse(f.presentation.shouldReveal(2, f.deliveries))
        assertSame(reader, f.store.runtimes[2])
        assertFalse(reader.closed)
    }

    @Test
    fun inputCancelsFocusedPendingGestureBeforeReturningItToTail() {
        val f = Fixture()
        f.observer.begin(60f, 43f)
        val reader = requireNotNull(f.observer.scroll(-1, -20.0))
        assertTrue(reader.pending)
        f.focusedPaneId = 2
        f.input()
        assertFalse(reader.pending)
        assertEquals(0, reader.topRow)
        assertEquals(listOf("overlay:2"), f.returned)
        assertEquals("cancel:overlay:2", f.events.last())
        // With no pending capture/page, subsequent input is a no-op.
        f.input()
        assertEquals(listOf("overlay:2"), f.returned)
    }

    @Test
    fun findOnNeverScrolledPaneAttachesBeforeItsFullDepthRequest() {
        val f = Fixture()
        assertTrue(f.store.runtimes.isEmpty())
        var findSurface: String? = null
        f.router.find(1) { surfaceId ->
            assertEquals(setOf(1), f.attached)
            assertTrue(f.store.runtimes.getValue(1).pending)
            findSurface = surfaceId
        }
        assertEquals("overlay:1", findSurface)
        assertEquals(listOf("attach:1", "begin:1"), f.events)
        assertEquals(1, f.readerPaneId)
        assertTrue(f.requests.isEmpty())
    }

    @Test
    fun runtimeReuseAndRemovalKeepAllExistingReadersDeclared() {
        val f = Fixture()
        f.observer.begin(60f, 43f)
        val second = requireNotNull(f.observer.scroll(-1, -20.0))
        f.ready(2)
        f.observer.begin(20f, 43f)
        val first = requireNotNull(f.observer.scroll(-1, -20.0))
        assertEquals(setOf(1, 2), f.attached)
        assertEquals(listOf("overlay:2"), f.returned)
        f.observer.begin(60f, 43f)
        assertSame(second, f.observer.scroll(-1, -20.0))
        assertEquals(2, f.events.count { it.startsWith("attach:") })
        f.activePanes = setOf(1)
        f.store.retainPanes(f.activePanes)
        assertTrue(second.closed)
        assertFalse(first.closed)
        assertEquals(setOf(1), f.attached)
        // A latched gesture for a removed pane may not resurrect it.
        assertNull(f.observer.scroll(-1, -20.0))
        f.store.close()
        assertTrue(first.closed)
        assertTrue(f.attached.isEmpty())
        assertEquals(2, f.events.count { it.startsWith("close:") })
    }
}
