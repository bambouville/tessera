package com.bambouville.tessera.terminal

import org.junit.Assert.assertEquals
import org.junit.Test

class TerminalKeyboardViewportPolicyTest {
    private fun clearance(above: Float, below: Float) =
        TerminalCaretClearance(abovePixels = above, belowPixels = below)

    @Test
    fun `cursor at bottom keeps the complete session lift`() {
        assertEquals(0f, hold(previous = null, above = 900f, below = 0f), 0f)
    }

    @Test
    fun `fresh cursor near top cancels the complete terminal lift`() {
        val hold = hold(previous = null, above = 54f, below = 860f)
        assertEquals(860f, hold, 0f)
        assertEquals(336f, TerminalKeyboardViewportPolicy.counterShiftPixels(hold, 336f), 0f)
    }

    @Test
    fun `middle cursor moves only by the keyboard shortfall`() {
        val hold = hold(previous = null, above = 600f, below = 200f)
        assertEquals(200f, hold, 0f)
        assertEquals(136f, 336f - TerminalKeyboardViewportPolicy.counterShiftPixels(hold, 336f), 0f)
    }

    @Test
    fun `cursor motion inside visible band does not jitter`() {
        assertEquals(200f, hold(previous = 200f, above = 500f, below = 300f), 0f)
    }

    @Test
    fun `remote output walking cursor down shrinks hold`() {
        assertEquals(90f, hold(previous = 200f, above = 800f, below = 90f), 0f)
    }

    @Test
    fun `clear returning cursor to top grows hold`() {
        assertEquals(336f, hold(previous = 90f, above = 0f, below = 1_000f), 0f)
    }

    @Test
    fun `opaque keyboard wins when both edges cannot be satisfied`() {
        assertEquals(18f, hold(previous = 300f, above = 0f, below = 18f), 0f)
    }

    @Test
    fun `zero overlap produces no counter shift`() {
        val hold = hold(previous = null, above = 100f, below = 40f, overlap = 0f)
        assertEquals(0f, TerminalKeyboardViewportPolicy.counterShiftPixels(hold, 0f), 0f)
    }

    private fun hold(
        previous: Float?,
        above: Float,
        below: Float,
        overlap: Float = 336f,
    ): Float = TerminalKeyboardViewportPolicy.holdPixels(
        previousHoldPixels = previous,
        clearance = clearance(above, below),
        imeOverlapPixels = overlap,
    )
}
