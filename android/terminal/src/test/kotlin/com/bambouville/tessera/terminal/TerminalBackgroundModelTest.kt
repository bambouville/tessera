package com.bambouville.tessera.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class TerminalBackgroundModelTest {
    private val imageId = "5f72df2a-099c-4546-b49a-0ee0ea7e6019.jpg"

    @Test
    fun `background contract matches iOS defaults and accepted persistence values`() {
        val background = TerminalBackgroundImage(imageId)

        assertEquals(0.5f, background.dim)
        assertEquals(TerminalBackgroundFillMode.Fill, background.fillMode)
        assertEquals(0f, background.blurRadiusDp)
        assertEquals(TerminalBackgroundFillMode.Fill, TerminalBackgroundFillMode.fromPersisted(null))
        assertEquals(TerminalBackgroundFillMode.Fit, TerminalBackgroundFillMode.fromPersisted("fit"))
    }

    @Test
    fun `invalid wallpaper input cannot become a persisted render request`() {
        assertInvalid {
            TerminalBackgroundImage("../../outside.jpg")
        }
        assertInvalid {
            TerminalBackgroundImage(imageId, dim = 0.851f)
        }
        assertInvalid {
            TerminalBackgroundImage(imageId, blurRadiusDp = 24.1f)
        }
    }

    private fun assertInvalid(action: () -> Unit) {
        try {
            action()
            fail("expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }
}
