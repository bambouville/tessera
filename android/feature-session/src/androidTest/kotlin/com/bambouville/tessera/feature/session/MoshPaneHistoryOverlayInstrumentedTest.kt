package com.bambouville.tessera.feature.session

import android.graphics.Typeface
import android.view.View
import android.view.InputDevice
import android.view.MotionEvent
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.core.bridge.SharedScrollRoute
import com.bambouville.tessera.core.bridge.SharedTmuxCellRect
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.core.bridge.SharedTmuxPane
import com.bambouville.tessera.core.bridge.SharedTmuxRenderEffect
import com.bambouville.tessera.core.bridge.SharedTmuxRenderHistoryPlacement
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import com.bambouville.tessera.terminal.RenderOwner
import com.bambouville.tessera.terminal.TerminalCursorStyle
import com.bambouville.tessera.terminal.TerminalTheme
import com.bambouville.tessera.terminal.TermuxTerminalSurface
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Exercises the Phase 4 view with a real Termux transcript, not a fake
 * scroll model. A ledger batch binds and feeds the detached surface before it
 * reports history ready; returning from native scrollback then parks the
 * exact same view at the live tail.
 */
@RunWith(AndroidJUnit4::class)
class MoshPaneHistoryOverlayInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun fedCaptureRevealsDetachedOverlayThenParksItAtLiveTail() {
        val paneId = 42
        val owner = SharedTmuxRenderOwner(windowId = 7, paneId = paneId, epoch = 3)
        val physicalOwner = RenderOwner(
            windowId = requireNotNull(owner.windowId),
            paneId = requireNotNull(owner.paneId),
            epoch = owner.epoch,
            transportGeneration = 11,
        )
        val delivery = MoshPaneHistoryReadyDelivery(
            sequence = 1,
            effect = SharedTmuxRenderEffect.HistoryReady(
                surfaceId = moshPaneHistoryOverlaySurfaceId(paneId),
                owner = owner,
                depth = 240,
                historySize = 240,
                placement = SharedTmuxRenderHistoryPlacement.Bottom,
            ),
        )
        val deliveries = mapOf(delivery.effect.surfaceId to delivery)
        val presentation = MoshPaneHistoryOverlayPresentation()
        val visible = mutableStateOf(false)
        val mounted = mutableStateOf(true)
        var dismisses = 0
        val appliedDeliveries = mutableListOf<Pair<String, Long>>()
        val presentationAcknowledgements = MoshHistoryPresentationAcknowledgements<TermuxTerminalSurface>()
        val acceptedPresentationOwners = mutableListOf<SharedTmuxRenderOwner>()
        lateinit var runtime: MoshPaneHistoryOverlayRuntime

        compose.runOnIdle {
            runtime = MoshPaneHistoryOverlayRuntime(
                paneId = paneId,
                surface = TermuxTerminalSurface(compose.activity),
            )
        }
        compose.setContent {
            if (mounted.value) {
                MoshPaneHistoryOverlaySurface(
                    runtime = runtime,
                    paneRect = SharedTmuxCellRect(columns = 60, rows = 24),
                    visible = visible.value,
                    terminalTextSizeSp = 13,
                    terminalTypeface = Typeface.MONOSPACE,
                    terminalTheme = TerminalTheme.Void,
                    cursorStyle = TerminalCursorStyle.Block,
                    cursorBlink = false,
                    eligibleDeliveryToken = delivery.sequence,
                    onNativeTopRowChanged = { deliveredPaneId, topRow, _ ->
                        if (presentation.observeNativeTopRow(deliveredPaneId, topRow, deliveries)) {
                            dismisses += 1
                            visible.value = false
                        }
                    },
                    onHistoryPlacementApplied = { _, _ ->
                        visible.value = presentation.shouldReveal(paneId, deliveries)
                    },
                    onHistoryDeliveryApplied = { surfaceId, deliveryToken ->
                        appliedDeliveries += surfaceId to deliveryToken
                        when (val acknowledgement = presentationAcknowledgements.acknowledge(
                            surfaceId = surfaceId,
                            deliveryToken = deliveryToken,
                            currentGeneration = physicalOwner.transportGeneration,
                            currentSurface = runtime.surface,
                            currentOwner = runtime.surface.boundOwner,
                        )) {
                            is MoshHistoryPresentationAcknowledgements.Acknowledgement.Accepted ->
                                acceptedPresentationOwners += acknowledgement.delivery.owner
                            else -> throw AssertionError(
                                "actual post-placement overlay callback did not carry the exact physical owner: " +
                                    acknowledgement::class.simpleName,
                            )
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }

        compose.waitUntil(timeoutMillis = 5_000) { runtime.surface.view.mEmulator != null }
        fun overlayVisibility(): Int? = (runtime.surface.view.parent as? View)?.visibility
        compose.runOnIdle {
            val surface = runtime.surface
            surface.bind(physicalOwner)
            // This mirrors a mosh-history feed: a server capture is in the
            // detached transcript before the ordered historyReady handoff.
            repeat(80) { row ->
                surface.feed(physicalOwner, "PANE-42-HISTORY-$row\r\n".encodeToByteArray())
            }
            assertTrue(surface.view.mEmulator.screen.activeTranscriptRows > 0)
            // The captured pane can have tmux mouse mode enabled, but a
            // primary-screen history overlay must still use native local
            // scrollback rather than send wheel reports to the live pane.
            surface.feed(physicalOwner, "\u001b[?1000h".encodeToByteArray())
            assertTrue(surface.snapshotNonSecretState().mouseTracking)
            assertEquals(SharedScrollRoute.LocalScrollback, surface.view.scrollRoute())
            assertTrue(presentation.accept(delivery))
            presentationAcknowledgements.publish(
                MoshHistoryPresentationAcknowledgements.Delivery(
                    deliveryToken = delivery.sequence,
                    surfaceId = delivery.effect.surfaceId,
                    owner = owner,
                    physicalOwner = physicalOwner,
                    surface = surface,
                ),
            )
            runtime.queueHistoryPlacement(delivery)
        }
        compose.waitUntil(timeoutMillis = 5_000) {
            // The surface reads its text on the main thread only.
            compose.runOnUiThread {
                visible.value && overlayVisibility() == View.VISIBLE &&
                    runtime.surface.snapshotText()?.visibleText.orEmpty().contains("PANE-42-HISTORY")
            }
        }
        compose.runOnIdle {
            assertEquals(listOf(moshPaneHistoryOverlaySurfaceId(paneId) to 1L), appliedDeliveries)
            assertEquals(listOf(owner), acceptedPresentationOwners)
        }

        compose.runOnIdle {
            // Native Termux uses a negative top row while the reader is in
            // local history. The overlay's draw listener samples this exact
            // state rather than installing a competing gesture recognizer.
            runtime.surface.view.topRow = -4
            runtime.surface.view.invalidate()
        }
        compose.waitUntil(timeoutMillis = 5_000) { runtime.lastNativeTopRow < 0 }
        compose.runOnIdle {
            runtime.surface.view.topRow = 0
            runtime.surface.view.invalidate()
        }
        compose.waitUntil(timeoutMillis = 5_000) {
            !visible.value && overlayVisibility() == View.INVISIBLE
        }
        compose.runOnIdle {
            assertEquals(1, dismisses)
            assertFalse(presentation.shouldReveal(paneId, deliveries))
        }

        // AndroidView's release runs before the real external terminal is
        // closed, matching the production parked-overlay disposal order.
        compose.runOnIdle { mounted.value = false }
        compose.waitForIdle()
        compose.runOnIdle { runtime.surface.close() }
    }

    @Test
    fun productionHostMountsHistoryPrunesOldWindowAndReturnsWithFreshSurface() {
        val firstPaneId = 42
        val secondPaneId = 84
        val firstWindow = testWindow(id = 7, paneId = firstPaneId)
        val secondWindow = testWindow(id = 8, paneId = secondPaneId)
        val activeWindow = mutableStateOf(firstWindow)
        val focusedPane = mutableStateOf(firstPaneId)
        val findPane = mutableStateOf<Int?>(null)
        val deliveries = mutableStateOf<Map<String, MoshPaneHistoryReadyDelivery>>(emptyMap())
        val returnedSurface = mutableStateOf<String?>(null)
        val mounted = mutableStateOf(true)
        val attached = mutableMapOf<Int, TermuxTerminalSurface>()
        val detached = mutableListOf<Pair<Int, TermuxTerminalSurface>>()
        var visibleOverlay: TermuxTerminalSurface? = null
        lateinit var primary: TermuxTerminalSurface

        compose.runOnIdle {
            primary = TermuxTerminalSurface(compose.activity)
        }
        compose.setContent {
            if (mounted.value) {
                MoshPaneHistoryOverlayHost(
                    context = compose.activity,
                    activeWindow = activeWindow.value,
                    focusedPaneId = focusedPane.value,
                    findPaneId = findPane.value,
                    primaryTerminal = primary,
                    deliveries = deliveries.value,
                    scrollbackLines = 2_000,
                    terminalTextSizeSp = 13,
                    terminalTypeface = Typeface.MONOSPACE,
                    terminalTheme = TerminalTheme.Void,
                    cursorStyle = TerminalCursorStyle.Block,
                    cursorBlink = false,
                    onSurfaceAttached = { paneId, surface ->
                        assertTrue("first native event needs an initialized emulator", surface.view.mEmulator != null)
                        attached[paneId] = surface
                    },
                    onSurfaceDetached = { paneId, surface ->
                        if (attached[paneId] === surface) attached.remove(paneId)
                        detached += paneId to surface
                    },
                    onHistoryRequested = { _, _, _ -> },
                    onFindRequested = { surfaceId ->
                        assertTrue(attached.containsKey(surfaceId.substringAfter(':').toInt()))
                    },
                    onReturnedToLiveTail = { surfaceId ->
                        returnedSurface.value = surfaceId
                        deliveries.value = deliveries.value - surfaceId
                    },
                    onHistoryDeliveryApplied = { _, _ -> },
                    onVisibleOverlaySurfaceChanged = { visibleOverlay = it },
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }

        compose.runOnIdle {
            assertTrue("unrequested readers stay unallocated", attached.isEmpty())
            // Drive the real split observer before the lazy AndroidView has
            // mounted. Its first wheel delta must survive until capture feed.
            val properties = MotionEvent.PointerProperties().apply { id = 0 }
            val coords = MotionEvent.PointerCoords().apply {
                x = 10f
                y = 30f
                setAxisValue(MotionEvent.AXIS_VSCROLL, 1f)
            }
            val event = MotionEvent.obtain(
                10L, 20L, MotionEvent.ACTION_SCROLL, 1, arrayOf(properties), arrayOf(coords),
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0,
            )
            try {
                assertTrue(primary.view.dispatchGenericMotionEvent(event))
            } finally {
                event.recycle()
            }
        }
        compose.waitUntil(timeoutMillis = 5_000) {
            attached[firstPaneId]?.view?.mEmulator != null
        }
        lateinit var firstSurface: TermuxTerminalSurface
        val firstSurfaceId = moshPaneHistoryOverlaySurfaceId(firstPaneId)
        compose.runOnIdle {
            firstSurface = requireNotNull(attached[firstPaneId])
            val owner = RenderOwner(windowId = firstWindow.id, paneId = firstPaneId, epoch = 1)
            firstSurface.bind(owner)
            repeat(80) { row ->
                firstSurface.feed(owner, "HOST-PANE-42-HISTORY-$row\r\n".encodeToByteArray())
            }
            deliveries.value = mapOf(
                firstSurfaceId to MoshPaneHistoryReadyDelivery(
                    sequence = 1,
                    effect = SharedTmuxRenderEffect.HistoryReady(
                        surfaceId = firstSurfaceId,
                        owner = SharedTmuxRenderOwner(firstWindow.id, firstPaneId, 1),
                        depth = 240,
                        historySize = 240,
                        placement = SharedTmuxRenderHistoryPlacement.Bottom,
                    ),
                ),
            )
        }
        compose.waitUntil(timeoutMillis = 5_000) {
            compose.runOnUiThread {
                visibleOverlay === firstSurface &&
                    (firstSurface.view.parent as? View)?.visibility == View.VISIBLE &&
                    firstSurface.snapshotText()?.visibleText.orEmpty().contains("HOST-PANE-42-HISTORY")
            }
        }

        compose.runOnIdle {
            assertTrue("the initiating wheel delta must enter history", firstSurface.view.topRow < 0)
            firstSurface.view.topRow = -4
            firstSurface.view.invalidate()
        }
        compose.runOnIdle {
            assertTrue(firstSurface.snapshotNonSecretState().topRow < 0)
        }
        compose.runOnIdle {
            firstSurface.view.topRow = 0
            firstSurface.view.invalidate()
        }
        compose.waitUntil(timeoutMillis = 5_000) {
            returnedSurface.value == firstSurfaceId && visibleOverlay == null
        }

        compose.runOnIdle {
            activeWindow.value = secondWindow
            focusedPane.value = secondPaneId
            findPane.value = secondPaneId
        }
        compose.waitUntil(timeoutMillis = 5_000) {
            detached.any { (paneId, surface) -> paneId == firstPaneId && surface === firstSurface } &&
                attached[secondPaneId]?.view?.mEmulator != null
        }
        compose.runOnIdle {
            // Even if a stale map update races the window transition, the
            // host must not recreate or reveal a pane outside this window.
            deliveries.value = mapOf(
                firstSurfaceId to MoshPaneHistoryReadyDelivery(
                    sequence = 2,
                    effect = SharedTmuxRenderEffect.HistoryReady(
                        surfaceId = firstSurfaceId,
                        owner = SharedTmuxRenderOwner(firstWindow.id, firstPaneId, 2),
                        depth = 240,
                        historySize = 240,
                        placement = SharedTmuxRenderHistoryPlacement.Bottom,
                    ),
                ),
            )
        }
        compose.waitForIdle()
        compose.runOnIdle {
            assertFalse(attached.containsKey(firstPaneId))
            assertEquals(null, visibleOverlay)
            deliveries.value = emptyMap()
            activeWindow.value = firstWindow
            focusedPane.value = firstPaneId
            findPane.value = firstPaneId
        }
        compose.waitUntil(timeoutMillis = 5_000) {
            attached[firstPaneId]?.let { it !== firstSurface && it.view.mEmulator != null } == true
        }
        compose.runOnIdle {
            val replacement = requireNotNull(attached[firstPaneId])
            assertNotSame(firstSurface, replacement)
            assertFalse(replacement.snapshotText()?.visibleText.orEmpty().contains("HOST-PANE-42-HISTORY"))
            assertEquals(null, visibleOverlay)
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_MOSH_OVERLAY_HOST_OK mounted=1 history=1 tail=1 windowPrune=1 freshSurface=1",
            )
        }

        compose.runOnIdle { mounted.value = false }
        compose.waitForIdle()
        compose.runOnIdle { primary.close() }
    }

    private fun testWindow(id: Int, paneId: Int) = SharedTmuxWindow(
        id = id,
        index = id,
        name = "window-$id",
        activePaneId = paneId,
        panes = listOf(
            SharedTmuxPane(
                id = paneId,
                title = "pane-$paneId",
                currentCommand = "bash",
                active = true,
            ),
        ),
        zoomed = false,
        layout = SharedTmuxLayoutNode.Leaf(
            paneId = paneId,
            width = 60,
            height = 24,
        ),
    )
}
