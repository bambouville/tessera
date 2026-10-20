package com.bambouville.tessera.feature.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.Assert.assertTrue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect

class TmuxWindowReorderUiTest {
    private val order = listOf(10, 20, 30, 40)

    @Test
    fun `scrolled content uses unclipped origin and viewport edges`() {
        val state = TmuxWindowReorderState(TmuxReorderAxis.VERTICAL, 0f)
        state.reportGeometry(Offset(0f, -300f), Rect(0f, 0f, 100f, 200f))
        state.reportItemBounds(20, Rect(0f, 20f, 100f, 70f))
        state.reportItemBounds(30, Rect(0f, 70f, 100f, 120f))
        assertEquals(20, state.idAt(Offset(50f, 340f), listOf(20, 30)))
        assertTrue(state.arm(Offset(50f, 340f), listOf(20, 30)))
        assertTrue(state.beginDrag())
        assertEquals(0f, state.edgeScrollDelta(Offset(50f, 400f), 30f, 10f))
        assertTrue(state.edgeScrollDelta(Offset(50f, 305f), 30f, 10f) < 0f)
        assertTrue(state.edgeScrollDelta(Offset(50f, 495f), 30f, 10f) > 0f)
        state.drag(Offset(50f, 495f))
        val beforeScroll = state.edgeScrollDelta(30f, 10f)
        state.reportGeometry(Offset(0f, -330f), Rect(0f, 0f, 100f, 200f))
        state.refreshDrag()
        assertEquals(beforeScroll, state.edgeScrollDelta(30f, 10f))
    }

    @Test
    fun `menu actions calculate destinations in the resulting order`() {
        assertEquals(1, tmuxWindowMoveDestination(order, 30, TmuxWindowMoveAction.PREVIOUS))
        assertEquals(3, tmuxWindowMoveDestination(order, 30, TmuxWindowMoveAction.NEXT))
        assertEquals(0, tmuxWindowMoveDestination(order, 30, TmuxWindowMoveAction.START))
        assertEquals(3, tmuxWindowMoveDestination(order, 30, TmuxWindowMoveAction.END))
    }

    @Test
    fun `actions which cannot move are unavailable`() {
        assertNull(tmuxWindowMoveDestination(order, 10, TmuxWindowMoveAction.PREVIOUS))
        assertNull(tmuxWindowMoveDestination(order, 10, TmuxWindowMoveAction.START))
        assertNull(tmuxWindowMoveDestination(order, 40, TmuxWindowMoveAction.NEXT))
        assertNull(tmuxWindowMoveDestination(order, 40, TmuxWindowMoveAction.END))
        assertNull(tmuxWindowMoveDestination(order, 99, TmuxWindowMoveAction.START))
        assertNull(tmuxWindowMoveDestination(listOf(10), 10, TmuxWindowMoveAction.END))
    }

    @Test
    fun `drop order preserves every id exactly once`() {
        assertEquals(listOf(30, 10, 20, 40), movedTmuxWindowOrder(order, 30, 0))
        assertEquals(listOf(10, 30, 40, 20), movedTmuxWindowOrder(order, 20, 3))
        assertEquals(order, movedTmuxWindowOrder(order, 30, 2))
    }

    @Test
    fun `invalid drop never produces an order`() {
        assertNull(movedTmuxWindowOrder(order, 99, 0))
        assertNull(movedTmuxWindowOrder(order, 10, -1))
        assertNull(movedTmuxWindowOrder(order, 10, order.size))
    }

    @Test
    fun `post-drop reveal waits for the requested order and cancels stale requests`() {
        val expected = listOf(20, 30, 40, 10)
        val request = TmuxWindowRevealRequest(
            id = 10,
            sourceOrder = order,
            expectedOrder = expected,
            contextKey = "session-a",
        )

        assertEquals(
            TmuxWindowRevealAction.WAIT,
            tmuxWindowRevealAction(request, order, "session-a", contextValid = true),
        )
        assertEquals(
            TmuxWindowRevealAction.REVEAL,
            tmuxWindowRevealAction(request, expected, "session-a", contextValid = true),
        )
        assertEquals(
            TmuxWindowRevealAction.CANCEL,
            tmuxWindowRevealAction(request, listOf(20, 10, 30, 40), "session-a", contextValid = true),
        )
        assertEquals(
            TmuxWindowRevealAction.CANCEL,
            tmuxWindowRevealAction(request, order, "session-b", contextValid = true),
        )
        assertEquals(
            TmuxWindowRevealAction.CANCEL,
            tmuxWindowRevealAction(request, order, "session-a", contextValid = false),
        )
    }

    @Test
    fun `post-drop reveal survives available pending available mutation lifecycle`() {
        val expected = listOf(20, 30, 40, 10)
        val request = TmuxWindowRevealRequest(
            id = 10,
            sourceOrder = order,
            expectedOrder = expected,
            contextKey = "session-a",
        )

        // Available at drop.
        assertEquals(
            TmuxWindowRevealAction.WAIT,
            tmuxWindowRevealAction(request, order, "session-a", contextValid = true),
        )
        // Pending disables controls but remains a valid context for this in-flight mutation.
        assertEquals(
            TmuxWindowRevealAction.WAIT,
            tmuxWindowRevealAction(request, order, "session-a", contextValid = true),
        )
        assertEquals(
            TmuxWindowRevealAction.REVEAL,
            tmuxWindowRevealAction(request, expected, "session-a", contextValid = true),
        )
        // Available reaches the same result if confirmation wins the recomposition race.
        assertEquals(
            TmuxWindowRevealAction.REVEAL,
            tmuxWindowRevealAction(request, expected, "session-a", contextValid = true),
        )
    }
}
