package com.bambouville.tessera.terminal

import com.bambouville.tessera.core.bridge.SharedScrollRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalSmoothScrollPolicyTest {
    @Test
    fun `defaults mirror iOS smooth scrolling`() {
        assertTrue(TerminalSmoothScrollPolicy.DEFAULT_ENABLED)
        assertEquals(0.5f, TerminalSmoothScrollPolicy.DEFAULT_SPEED, 0f)
    }

    @Test
    fun `only the local scrollback route may glide`() {
        assertTrue(
            TerminalSmoothScrollPolicy.canGlide(enabled = true, route = SharedScrollRoute.LocalScrollback),
        )
        assertFalse(
            TerminalSmoothScrollPolicy.canGlide(enabled = false, route = SharedScrollRoute.LocalScrollback),
        )
        assertFalse(
            TerminalSmoothScrollPolicy.canGlide(enabled = true, route = SharedScrollRoute.MouseWheel),
        )
        assertFalse(
            TerminalSmoothScrollPolicy.canGlide(enabled = true, route = SharedScrollRoute.ArrowKeys),
        )
    }

    @Test
    fun `speed uses the iOS slow to fast range`() {
        assertEquals(0.15f, TerminalSmoothScrollPolicy.normalizedSpeed(-1f), 0f)
        assertEquals(0.5f, TerminalSmoothScrollPolicy.normalizedSpeed(0.5f), 0f)
        assertEquals(1.25f, TerminalSmoothScrollPolicy.normalizedSpeed(8f), 0f)
        assertEquals(0.5f, TerminalSmoothScrollPolicy.normalizedSpeed(Float.NaN), 0f)
    }

    @Test
    fun `release velocity preserves direction and scales the next glide`() {
        assertEquals(
            -1_000f,
            requireNotNull(TerminalSmoothScrollPolicy.scaledReleaseVelocity(-1_000f, 0.5f)),
            0f,
        )
        assertEquals(
            11_250f,
            requireNotNull(TerminalSmoothScrollPolicy.scaledReleaseVelocity(9_000f, 1.25f)),
            0f,
        )
        assertNull(TerminalSmoothScrollPolicy.scaledReleaseVelocity(24f, 0.5f))
        assertNull(TerminalSmoothScrollPolicy.scaledReleaseVelocity(Float.NaN, 0.5f))
    }
}
