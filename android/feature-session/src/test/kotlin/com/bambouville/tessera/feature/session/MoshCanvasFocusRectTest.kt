package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxCellRect
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MoshCanvasFocusRectTest {
    // The tablet split this was found on: vim at the left, vitest at the right.
    private val canvas = SharedTmuxCellRect(columns = 160, rows = 29)
    private val vim = SharedTmuxCellRect(columns = 81, rows = 29)
    private val split = SharedTmuxLayoutNode.Split(
        horizontal = true,
        width = 160,
        height = 29,
        children = listOf(
            SharedTmuxLayoutNode.Leaf(paneId = 9, width = 81, height = 29),
            SharedTmuxLayoutNode.Leaf(paneId = 14, width = 78, height = 29, x = 82),
        ),
    )

    @Test
    fun compactScreenFramesTheFocusedPane() {
        assertEquals(vim, moshCanvasFocusRect(canvas, split, vim, panToFocusedPane = true))
    }

    @Test
    fun wideScreenFramesTheWholeCanvas() {
        assertEquals(canvas, moshCanvasFocusRect(canvas, split, vim, panToFocusedPane = false))
    }

    @Test
    fun aLayoutThatIsNotThisCanvasIsNeverPanned() {
        // A peer's `latest` client sized the window; this PTY shows a crop of it.
        val peerSized = split.copy(width = 200, height = 50)
        assertEquals(canvas, moshCanvasFocusRect(canvas, peerSized, vim, panToFocusedPane = true))
        assertEquals(canvas, moshCanvasFocusRect(canvas, null, vim, panToFocusedPane = true))
    }

    @Test
    fun noFocusedPaneFallsBackToTheCanvas() {
        assertEquals(canvas, moshCanvasFocusRect(canvas, split, null, panToFocusedPane = true))
        assertNull(moshCanvasFocusRect(null, split, vim, panToFocusedPane = true))
    }
}
