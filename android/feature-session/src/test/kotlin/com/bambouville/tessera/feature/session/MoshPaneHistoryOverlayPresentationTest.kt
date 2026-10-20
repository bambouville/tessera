package com.bambouville.tessera.feature.session

import android.view.MotionEvent
import com.bambouville.tessera.core.bridge.SharedTmuxCellRect
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.core.bridge.SharedTmuxRenderEffect
import com.bambouville.tessera.core.bridge.SharedTmuxRenderHistoryPlacement
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MoshPaneHistoryOverlayPresentationTest {
    @Test
    fun touchscreenScrollIsAcceptedOnEverySupportedApi() {
        for (sdkInt in listOf(33, 34, 35)) {
            assertTrue(moshSplitScrollAcceptsTouch(false, MotionEvent.CLASSIFICATION_NONE, sdkInt))
        }
    }

    @Test
    fun mouseButtonDragsAndOtherClassificationsStayWithTerminal() {
        for (sdkInt in listOf(33, 34, 35)) {
            for (classification in listOf(MotionEvent.CLASSIFICATION_NONE, MotionEvent.CLASSIFICATION_AMBIGUOUS_GESTURE,
                MotionEvent.CLASSIFICATION_DEEP_PRESS, MotionEvent.CLASSIFICATION_PINCH, Int.MAX_VALUE)) {
                assertFalse(moshSplitScrollAcceptsTouch(true, classification, sdkInt))
            }
        }
    }

    @Test
    fun mouseSourceTwoFingerSwipeIsAcceptedOnlyFromApi34() {
        assertFalse(moshSplitScrollAcceptsTouch(true, MotionEvent.CLASSIFICATION_TWO_FINGER_SWIPE, 33))
        assertTrue(moshSplitScrollAcceptsTouch(true, MotionEvent.CLASSIFICATION_TWO_FINGER_SWIPE, 34))
        assertTrue(moshSplitScrollAcceptsTouch(true, MotionEvent.CLASSIFICATION_TWO_FINGER_SWIPE, 35))
    }

    @Test
    fun touchpadSwipeConsumesDownSubSlopMovesAndRelease() {
        val gesture = MoshSplitScrollTouchGesture()
        gesture.begin(7, 100f, true, MotionEvent.CLASSIFICATION_TWO_FINGER_SWIPE, 34)
        assertTrue(gesture.consumesEvents)
        assertFalse(gesture.scrolling)
        assertNull(gesture.move(7, 104f, 8f))
        assertTrue(gesture.consumesEvents)
        assertFalse(gesture.pointerUp(7))
        assertTrue(gesture.consumesEvents)
        gesture.finish()
        assertFalse(gesture.consumesEvents)
    }

    @Test
    fun touchscreenDownSubSlopMovesAndTapReleaseStillPassThrough() {
        val gesture = MoshSplitScrollTouchGesture()
        gesture.begin(7, 100f, false, MotionEvent.CLASSIFICATION_NONE, 33)
        assertFalse(gesture.consumesEvents)
        assertNull(gesture.move(7, 108f, 8f))
        assertFalse(gesture.consumesEvents)
        assertFalse(gesture.pointerUp(7))
        assertFalse(gesture.consumesEvents)
    }

    @Test
    fun rejectedMouseGestureNeverTakesOverEvenAfterLargeMotion() {
        val gesture = MoshSplitScrollTouchGesture()
        gesture.begin(7, 100f, true, MotionEvent.CLASSIFICATION_NONE, 34)
        assertNull(gesture.trackedPointerId)
        assertNull(gesture.move(7, 200f, 8f))
        assertFalse(gesture.consumesEvents)
    }

    @Test
    fun pointerDownBeforeScrollAbandonsUntilNextDown() {
        val gesture = MoshSplitScrollTouchGesture()
        gesture.begin(7, 100f, false, MotionEvent.CLASSIFICATION_NONE, 34)
        assertNull(gesture.move(7, 104f, 8f))
        gesture.pointerDown()
        assertNull(gesture.trackedPointerId)
        assertNull(gesture.move(7, 200f, 8f))
        assertNull(gesture.move(9, 400f, 8f))
        assertFalse(gesture.pointerUp(9))
        assertNull(gesture.move(7, 220f, 8f))
        assertFalse(gesture.scrolling)
        assertFalse(gesture.consumesEvents)

        gesture.begin(7, 220f, false, MotionEvent.CLASSIFICATION_NONE, 34)
        assertEquals(-20f, gesture.move(7, 240f, 8f))
        assertTrue(gesture.scrolling)
    }

    @Test
    fun scrollDeltaTracksFirstPointerAndIgnoresSecondPointerMotionAndLift() {
        val gesture = MoshSplitScrollTouchGesture()
        gesture.begin(7, 100f, false, MotionEvent.CLASSIFICATION_NONE, 34)
        assertEquals(-20f, gesture.move(7, 120f, 8f))
        assertTrue(gesture.consumesEvents)
        gesture.pointerDown()
        assertEquals(7, gesture.trackedPointerId)
        assertNull(gesture.move(9, 900f, 8f))
        assertEquals(-5f, gesture.move(7, 125f, 8f))
        assertFalse(gesture.pointerUp(9))
        assertTrue(gesture.scrolling)
        assertEquals(-3f, gesture.move(7, 128f, 8f))
    }

    @Test
    fun liftingTrackedPointerEndsScrollOnceAndConsumesRemainderWithoutMoreDeltas() {
        val gesture = MoshSplitScrollTouchGesture()
        gesture.begin(7, 100f, false, MotionEvent.CLASSIFICATION_NONE, 34)
        assertEquals(-20f, gesture.move(7, 120f, 8f))
        gesture.pointerDown()
        assertTrue(gesture.pointerUp(7))
        assertFalse(gesture.pointerUp(7))
        assertFalse(gesture.scrolling)
        assertNull(gesture.trackedPointerId)
        assertNull(gesture.move(9, 900f, 8f))
        gesture.pointerDown()
        assertNull(gesture.move(9, 920f, 8f))
        assertTrue(gesture.consumesEvents)
        gesture.finish()
        assertFalse(gesture.consumesEvents)

        gesture.begin(9, 920f, false, MotionEvent.CLASSIFICATION_NONE, 34)
        assertEquals(-10f, gesture.move(9, 930f, 8f))
    }

    @Test
    fun touchpadAbandonmentStillCannotLeakAnUnmatchedMouseReleaseToPrimary() {
        val gesture = MoshSplitScrollTouchGesture()
        gesture.begin(7, 100f, true, MotionEvent.CLASSIFICATION_TWO_FINGER_SWIPE, 34)
        gesture.pointerDown()
        assertNull(gesture.move(7, 200f, 8f))
        assertFalse(gesture.scrolling)
        assertTrue(gesture.consumesEvents)
    }

    @Test
    fun aGestureThatStartsTowardTheTailCanStillRequestHistoryOnce() {
        val offer = MoshHistoryRequestOffer()
        assertTrue(offer.take(12.0))
        assertFalse(offer.offered)
        assertTrue(offer.take(-4.0))
        assertTrue(offer.offered)
        assertFalse(offer.take(-4.0))
        assertFalse(offer.take(9.0))

        offer.reset()
        assertTrue(offer.take(-1.0))
        assertFalse(offer.take(-1.0))
    }

    private val split = SharedTmuxLayoutNode.Split(
        horizontal = true, width = 10, height = 5,
        children = listOf(
            SharedTmuxLayoutNode.Leaf(paneId = 1, width = 4, height = 5),
            SharedTmuxLayoutNode.Leaf(paneId = 2, width = 5, height = 5, x = 5),
        ),
    )

    @Test
    fun scrollLocationAccountsForBaselineAndFractionalScrollOffset() {
        assertEquals(2, moshScrollPaneAtLocation(
            60f, 43f, 10f, 20, 5, 2f, split, 1,
        ))
        assertEquals(1, moshScrollPaneAtLocation(
            45f, 43f, 10f, 20, 5, 2f, split, 1,
        ))
        assertEquals(1, moshScrollPaneAtLocation(
            60f, 1f, 10f, 20, 5, 0f, split, 1,
        ))
    }

    @Test
    fun emptyContentRectsUseLayoutAndLocationMetricsBeforeFocusedFallback() {
        val stacked = SharedTmuxLayoutNode.Split(
            horizontal = false, width = 10, height = 5,
            children = listOf(
                SharedTmuxLayoutNode.Leaf(paneId = 1, width = 10, height = 2),
                SharedTmuxLayoutNode.Leaf(paneId = 2, width = 10, height = 2, y = 3),
            ),
        )
        assertEquals(2, moshScrollPaneAtLocation(
            20f, 63f, 10f, 20, 5, 2f, stacked, 1, emptyMap(),
        ))
        assertEquals(1, moshScrollPaneAtLocation(
            20f, 62f, 10f, 20, 5, 2f, stacked, 1, emptyMap(),
        ))
        assertEquals(7, moshScrollPaneAtLocation(
            20f, 63f, 10f, 20, 5, 2f, null, 7, emptyMap(),
        ))
    }

    @Test
    fun scrollPaneBordersAndOutsideCellsKeepFocusedRouting() {
        assertEquals(2, moshScrollPaneAtCell(5, 0, split, 1))
        assertEquals(2, moshScrollPaneAtCell(9, 4, split, 1))
        assertEquals(1, moshScrollPaneAtCell(4, 2, split, 1))
        assertEquals(1, moshScrollPaneAtCell(10, 2, split, 1))
        assertEquals(1, moshScrollPaneAtCell(5, 5, split, 1))
        assertEquals(1, moshScrollPaneAtCell(-1, 2, split, 1))
    }

    @Test
    fun paneTitleRowKeepsFocusedRoutingWithContentGeometry() {
        val rects = mapOf(
            1 to SharedTmuxCellRect(columns = 4, rows = 4, x = 0, y = 1),
            2 to SharedTmuxCellRect(columns = 5, rows = 4, x = 5, y = 1),
        )
        assertEquals(1, moshScrollPaneAtLocation(
            60f, 15f, 10f, 20, 5, 0f, split, 1, rects,
        ))
        assertEquals(2, moshScrollPaneAtLocation(
            60f, 25f, 10f, 20, 5, 0f, split, 1, rects,
        ))
    }

    @Test
    fun stackedPaneDividerKeepsFocusedRouting() {
        val stacked = SharedTmuxLayoutNode.Split(
            horizontal = false, width = 10, height = 5,
            children = listOf(
                SharedTmuxLayoutNode.Leaf(paneId = 1, width = 10, height = 2),
                SharedTmuxLayoutNode.Leaf(paneId = 2, width = 10, height = 2, y = 3),
            ),
        )
        assertEquals(2, moshScrollPaneAtCell(2, 3, stacked, 1))
        assertEquals(1, moshScrollPaneAtCell(2, 2, stacked, 1))
    }

    @Test
    fun singleAndZoomedCanvasKeepFocusedRouting() {
        assertEquals(7, moshScrollPaneAtCell(9, 4, null, 7))
        val single = SharedTmuxLayoutNode.Leaf(paneId = 7, width = 10, height = 5)
        assertEquals(7, moshScrollPaneAtCell(9, 4, single, 7))
    }

    @Test
    fun gestureTargetSurvivesCrossingDividerAndReleaseUntilNextGesture() {
        val target = MoshScrollGestureTarget()
        target.begin(moshScrollPaneAtCell(8, 2, split, 1))
        assertEquals(2, target.paneId)
        assertEquals(1, moshScrollPaneAtCell(2, 2, split, 1))
        assertEquals(2, target.paneId) // Continued drag and native release use the retained view.
        target.begin(moshScrollPaneAtCell(2, 2, split, 2))
        assertEquals(1, target.paneId)
        target.begin(null)
        assertNull(target.paneId)
    }

    @Test
    fun wheelStreamRetainsTargetAndIdleRearmsMiceWithZeroDownTime() {
        val target = MoshScrollGestureTarget()
        assertTrue(target.beginsWheelGesture(0, 1000))
        target.begin(2)
        assertFalse(target.beginsWheelGesture(0, 1016))
        assertEquals(2, target.paneId)
        assertFalse(target.beginsWheelGesture(0, 1032))
        assertTrue(target.beginsWheelGesture(0, 1400))
        target.begin(1)
        assertEquals(1, target.paneId)
        assertTrue(target.beginsWheelGesture(1, 1416))
        assertFalse(target.beginsWheelGesture(1, 2000))
    }

    private fun delivery(
        sequence: Long,
        paneId: Int = 42,
        placement: SharedTmuxRenderHistoryPlacement = SharedTmuxRenderHistoryPlacement.Bottom,
    ): MoshPaneHistoryReadyDelivery =
        MoshPaneHistoryReadyDelivery(
            sequence = sequence,
            effect = SharedTmuxRenderEffect.HistoryReady(
                surfaceId = moshPaneHistoryOverlaySurfaceId(paneId),
                owner = SharedTmuxRenderOwner(windowId = 7, paneId = paneId, epoch = 3),
                depth = 240,
                historySize = 240,
                placement = placement,
            ),
        )

    @Test
    fun historyReadyRevealsOnlyItsFocusedPane() {
        val state = MoshPaneHistoryOverlayPresentation()
        val ready = delivery(1)
        val deliveries = mapOf(ready.effect.surfaceId to ready)

        assertTrue(state.accept(ready))
        assertEquals(42, state.visiblePane(42, deliveries))
        assertNull(state.visiblePane(43, deliveries))
    }

    @Test
    fun readerSwitchReturnsPreviousDeliveryToTailExactlyOnce() {
        val state = MoshPaneHistoryOverlayPresentation()
        val first = delivery(1)
        val second = delivery(2, paneId = 43)
        val deliveries = mapOf(first.effect.surfaceId to first, second.effect.surfaceId to second)
        state.accept(first)
        state.accept(second)

        assertFalse(state.returnToLiveTailForReaderSwitch(42, 42, deliveries))
        assertTrue(state.returnToLiveTailForReaderSwitch(42, 43, deliveries))
        assertFalse(state.shouldReveal(42, deliveries))
        assertTrue(state.shouldReveal(43, deliveries))
        assertFalse(state.returnToLiveTailForReaderSwitch(42, 43, deliveries))
        assertFalse(state.observeNativeTopRow(42, -4, deliveries))
        assertFalse(state.observeNativeTopRow(42, 0, deliveries))

        // Returning to that pane requires a fresh capture, never its parked row.
        val replacement = delivery(3)
        state.accept(replacement)
        val replacementDeliveries = deliveries + (replacement.effect.surfaceId to replacement)
        assertTrue(state.shouldReveal(42, replacementDeliveries))
        assertTrue(state.returnToLiveTailForReaderSwitch(42, 43, replacementDeliveries))
    }

    @Test
    fun readerSwitchDoesNotReturnMissingUnacceptedOrAlreadyDismissedDelivery() {
        val state = MoshPaneHistoryOverlayPresentation()
        val ready = delivery(1)
        val deliveries = mapOf(ready.effect.surfaceId to ready)
        assertFalse(state.returnToLiveTailForReaderSwitch(null, 43, deliveries))
        assertFalse(state.returnToLiveTailForReaderSwitch(42, 43, deliveries))
        state.accept(ready)
        assertFalse(state.returnToLiveTailForReaderSwitch(42, 43, emptyMap()))
        state.observeNativeTopRow(42, -4, deliveries)
        assertTrue(state.observeNativeTopRow(42, 0, deliveries))
        assertFalse(state.returnToLiveTailForReaderSwitch(42, 43, deliveries))
    }

    @Test
    fun returningAtInitialFedTailDoesNotDismissUntilNativeHistoryWasVisited() {
        val state = MoshPaneHistoryOverlayPresentation()
        val ready = delivery(1)
        val deliveries = mapOf(ready.effect.surfaceId to ready)
        state.accept(ready)

        assertFalse(state.observeNativeTopRow(42, 0, deliveries))
        assertTrue(state.shouldReveal(42, deliveries))
        assertFalse(state.observeNativeTopRow(42, -8, deliveries))
        assertTrue(state.observeNativeTopRow(42, 0, deliveries))
        assertFalse(state.shouldReveal(42, deliveries))
    }

    @Test
    fun aSameShapeRefillAfterDismissalRevealsAgainWhenItsDeliveryChanges() {
        val state = MoshPaneHistoryOverlayPresentation()
        val first = delivery(1)
        val firstMap = mapOf(first.effect.surfaceId to first)
        state.accept(first)
        state.observeNativeTopRow(42, -2, firstMap)
        assertTrue(state.observeNativeTopRow(42, 0, firstMap))

        val refill = delivery(2)
        val refillMap = mapOf(refill.effect.surfaceId to refill)
        assertTrue(state.accept(refill))
        assertTrue(state.shouldReveal(42, refillMap))
    }

    @Test
    fun staleDeliveryCannotReopenOrReplaceTheParkedPane() {
        val state = MoshPaneHistoryOverlayPresentation()
        val current = delivery(2)
        val map = mapOf(current.effect.surfaceId to current)
        state.accept(current)

        assertFalse(state.accept(delivery(1)))
        assertEquals(42, state.visiblePane(42, map))
    }

    @Test
    fun switchingFocusedPanesSwapsParkedOverlaysWithoutDiscardingEitherCapture() {
        val state = MoshPaneHistoryOverlayPresentation()
        val first = delivery(sequence = 1, paneId = 42)
        val second = delivery(sequence = 2, paneId = 43)
        val deliveries = mapOf(
            first.effect.surfaceId to first,
            second.effect.surfaceId to second,
        )

        assertTrue(state.accept(first))
        assertTrue(state.accept(second))
        assertEquals(42, state.visiblePane(42, deliveries))

        state.dismissForPaneSwitch(42)
        assertEquals(43, state.visiblePane(43, deliveries))
        // The first view remains mounted and becomes visible again without a
        // second capture if the user returns to its pane.
        assertEquals(42, state.visiblePane(42, deliveries))
    }

    @Test
    fun switchingWindowsDiscardsParkedDeliveryUntilANewCaptureArrives() {
        val state = MoshPaneHistoryOverlayPresentation()
        val oldWindow = delivery(sequence = 1, paneId = 42)
        val oldDeliveries = mapOf(oldWindow.effect.surfaceId to oldWindow)
        assertTrue(state.accept(oldWindow))
        assertEquals(42, state.visiblePane(42, oldDeliveries))

        state.retainPanes(setOf(43))
        assertNull(
            "a parked surface from another window must not reveal stale history",
            state.visiblePane(42, oldDeliveries),
        )

        val replacement = delivery(sequence = 2, paneId = 42)
        state.retainPanes(setOf(42))
        assertTrue(state.accept(replacement))
        assertEquals(
            42,
            state.visiblePane(42, mapOf(replacement.effect.surfaceId to replacement)),
        )
    }

    @Test
    fun bottomPlacementEntersOneHistoryRowWhenCaptureHasRows() {
        assertEquals(
            -1,
            moshHistoryTopRowForPlacement(
                placement = SharedTmuxRenderHistoryPlacement.Bottom,
                priorDistanceFromBottom = 0,
                availableHistoryRows = 12,
            ),
        )
        assertEquals(
            0,
            moshHistoryTopRowForPlacement(
                placement = SharedTmuxRenderHistoryPlacement.Bottom,
                priorDistanceFromBottom = 0,
                availableHistoryRows = 0,
            ),
        )
    }

    @Test
    fun preserveDistancePlacementCapsAtReplacementHistorySize() {
        assertEquals(
            -12,
            moshHistoryTopRowForPlacement(
                placement = SharedTmuxRenderHistoryPlacement.PreserveDistanceFromBottom,
                priorDistanceFromBottom = 37,
                availableHistoryRows = 12,
            ),
        )
        assertEquals(
            -7,
            moshHistoryTopRowForPlacement(
                placement = SharedTmuxRenderHistoryPlacement.PreserveDistanceFromBottom,
                priorDistanceFromBottom = 7,
                availableHistoryRows = 12,
            ),
        )
    }

    @Test
    fun underflowRequestsOnlyOnceForEachHistoryReadyDeliveryAndRearmsOnReplacement() {
        val state = MoshPaneHistoryOverlayPresentation()
        val first = delivery(1)
        val firstMap = mapOf(first.effect.surfaceId to first)
        assertTrue(state.accept(first))

        assertTrue(
            state.shouldRequestDeeperHistory(
                paneId = 42,
                topRow = -240,
                availableHistoryRows = 240,
                deliveries = firstMap,
            ),
        )
        assertFalse(
            state.shouldRequestDeeperHistory(
                paneId = 42,
                topRow = -240,
                availableHistoryRows = 240,
                deliveries = firstMap,
            ),
        )

        val replacement = delivery(
            sequence = 2,
            placement = SharedTmuxRenderHistoryPlacement.PreserveDistanceFromBottom,
        )
        val replacementMap = mapOf(replacement.effect.surfaceId to replacement)
        assertTrue(state.accept(replacement))
        assertTrue(
            state.shouldRequestDeeperHistory(
                paneId = 42,
                topRow = -240,
                availableHistoryRows = 240,
                deliveries = replacementMap,
            ),
        )
    }

    @Test
    fun underflowIgnoresTailAndDismissedOverlay() {
        val state = MoshPaneHistoryOverlayPresentation()
        val ready = delivery(1)
        val deliveries = mapOf(ready.effect.surfaceId to ready)
        assertTrue(state.accept(ready))
        assertFalse(state.shouldRequestDeeperHistory(42, 0, 240, deliveries))
        assertFalse(state.shouldRequestDeeperHistory(42, -1, 0, deliveries))

        state.observeNativeTopRow(42, -4, deliveries)
        assertTrue(state.observeNativeTopRow(42, 0, deliveries))
        assertFalse(state.shouldRequestDeeperHistory(42, -240, 240, deliveries))
    }

    @Test
    fun primaryLiveTailReturnsOnlyAfterThisDeliveryVisitedHistoryAndOnlyOnce() {
        val state = MoshPrimaryLiveHistoryPresentation()

        assertTrue(state.accept(7))
        assertFalse(state.observeNativeTopRow(0))
        assertFalse(state.observeNativeTopRow(-3))
        assertTrue(state.observeNativeTopRow(0))
        assertFalse(state.observeNativeTopRow(0))

        // A replacement capture starts a new tail-return lifecycle.
        assertTrue(state.accept(8))
        assertFalse(state.observeNativeTopRow(0))
        assertFalse(state.observeNativeTopRow(-1))
        assertTrue(state.observeNativeTopRow(0))

        // A deeper replacement bind clears the native transcript before it
        // feeds, so its synthetic zero must not cancel that replacement.
        assertTrue(state.accept(9))
        assertFalse(state.observeNativeTopRow(-4))
        assertFalse(state.observeNativeTopRow(0, availableHistoryRows = 0))
        assertTrue(state.observeNativeTopRow(0, availableHistoryRows = 240))
    }

    @Test
    fun primaryLiveDeepensOnlyAtOldestRowOnceUntilItsCaptureIsReplaced() {
        val state = MoshPrimaryLiveHistoryPresentation()
        assertTrue(state.accept(7))
        assertTrue(state.hasActiveHistory())

        // Ordinary local scroll gestures must remain native-only.
        assertFalse(state.shouldRequestDeeperHistory(topRow = -12, availableHistoryRows = 240))
        assertTrue(state.shouldRequestDeeperHistory(topRow = -240, availableHistoryRows = 240))
        assertFalse(state.shouldRequestDeeperHistory(topRow = -240, availableHistoryRows = 240))

        // A replacement HistoryReady re-arms the next actual underflow.
        assertTrue(state.accept(8))
        assertTrue(state.shouldRequestDeeperHistory(topRow = -480, availableHistoryRows = 480))

        state.observeNativeTopRow(-1)
        assertTrue(state.observeNativeTopRow(0))
        assertFalse(state.hasActiveHistory())
        assertFalse(state.shouldRequestDeeperHistory(topRow = -480, availableHistoryRows = 480))
    }

    @Test
    fun splitFindReusesMountedFullDepthDeliveryWhenLedgerWillNotEmitAnotherReady() {
        assertTrue(
            moshFindCanReuseFullDepthDelivery(
                requestedSurfaceId = "overlay:42",
                deliveredSurfaceId = "overlay:42",
                deliveredDepth = 10_000,
                scrollbackLimit = 10_000,
            ),
        )
        assertFalse(
            moshFindCanReuseFullDepthDelivery(
                requestedSurfaceId = "overlay:42",
                deliveredSurfaceId = "overlay:42",
                deliveredDepth = 240,
                scrollbackLimit = 10_000,
            ),
        )
        assertFalse(
            moshFindCanReuseFullDepthDelivery(
                requestedSurfaceId = "overlay:42",
                deliveredSurfaceId = "overlay:43",
                deliveredDepth = 10_000,
                scrollbackLimit = 10_000,
            ),
        )
    }

    @Test
    fun liveFindWaitsForTheFullDepthHistoryReadyToApplyToThePrimarySurface() {
        assertFalse(
            moshFindCanOpenAfterAppliedDelivery(
                requestedSurfaceId = "live",
                deliveredSurfaceId = "live",
                deliveredToken = 8,
                requiredNewerThanToken = 7,
                deliveredDepth = 10_000,
                scrollbackLimit = 10_000,
                appliedDeliveryToken = 7,
                mayReuseExistingDelivery = false,
            ),
        )
        assertTrue(
            moshFindCanOpenAfterAppliedDelivery(
                requestedSurfaceId = "live",
                deliveredSurfaceId = "live",
                deliveredToken = 8,
                requiredNewerThanToken = 7,
                deliveredDepth = 10_000,
                scrollbackLimit = 10_000,
                appliedDeliveryToken = 8,
                mayReuseExistingDelivery = false,
            ),
        )
        assertFalse(
            moshFindCanOpenAfterAppliedDelivery(
                requestedSurfaceId = "live",
                deliveredSurfaceId = "live",
                deliveredToken = 8,
                requiredNewerThanToken = 7,
                deliveredDepth = 240,
                scrollbackLimit = 10_000,
                appliedDeliveryToken = 8,
                mayReuseExistingDelivery = false,
            ),
        )
    }
}
