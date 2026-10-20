package com.bambouville.tessera.terminal

import com.termux.terminal.TextPresentation
import com.termux.terminal.WcWidth
import org.junit.Assert.assertEquals
import org.junit.Test

class TextPresentationTest {
    @Test
    fun `the table covers exactly the media-control block`() {
        assertEquals(7, TextPresentation.count())
        assertEquals('⏴', TextPresentation.FIRST)
        assertEquals('⏺', TextPresentation.LAST)
        for (index in 0 until TextPresentation.count()) {
            assertEquals(index, TextPresentation.indexOf(TextPresentation.source(index)))
        }
        assertEquals(-1, TextPresentation.indexOf('⏳'))
        assertEquals(-1, TextPresentation.indexOf('⏻'))
        assertEquals(-1, TextPresentation.indexOf('A'))
    }

    @Test
    fun `every twin keeps the column width the emulator reserved for the host's code point`() {
        // The emulator lays the row out from the host's code point; the renderer
        // draws the twin in its place, so the two must agree on the cell count
        // or the drawn row would drift against the emulator's columns.
        for (index in 0 until TextPresentation.count()) {
            val source = TextPresentation.source(index)
            val twin = TextPresentation.substitute(index)
            assertEquals(
                "U+%04X -> U+%04X".format(source.code, twin.code),
                WcWidth.width(source.code),
                WcWidth.width(twin.code),
            )
            assertEquals(1, WcWidth.width(twin.code))
        }
    }
}
