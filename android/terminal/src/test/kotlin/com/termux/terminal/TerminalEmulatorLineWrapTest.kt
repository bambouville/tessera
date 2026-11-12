package com.termux.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A row's wrap flag says its line goes on in the next row: a reflow joins the two, and a blank row it marks belongs
 * to the line. Erasing a row to its end, and the rows a ring buffer reuses, end that line, as in xterm.
 */
class TerminalEmulatorLineWrapTest {
    private fun emulator(columns: Int = 10, rows: Int = 4) =
        TerminalEmulator(NullOutput(), columns, rows, 10, 20, 100, null)

    private fun TerminalEmulator.feed(text: String) {
        val bytes = text.toByteArray()
        append(bytes, bytes.size)
    }

    @Test
    fun erasingTheDisplayEndsItsLines() {
        val emulator = emulator()
        emulator.feed("a".repeat(25))
        assertTrue("the text wraps", emulator.screen.getLineWrap(0) && emulator.screen.getLineWrap(1))
        emulator.feed("\u001b[H\u001b[2J")
        assertFalse(emulator.screen.getLineWrap(0))
        assertFalse(emulator.screen.getLineWrap(1))
    }

    @Test
    fun erasingARowToItsEndEndsItsLine() {
        val emulator = emulator()
        emulator.feed("a".repeat(15) + "\u001b[1;5H\u001b[K")
        assertFalse(emulator.screen.getLineWrap(0))

        val display = emulator()
        display.feed("a".repeat(15) + "\u001b[1;5H\u001b[J")
        assertFalse("erasing the display from the cursor ends the cursor's line", display.screen.getLineWrap(0))

        val start = emulator()
        start.feed("a".repeat(15) + "\u001b[1;5H\u001b[1K")
        assertTrue("erasing up to the cursor leaves the line going on", start.screen.getLineWrap(0))
    }

    @Test
    fun aRowTheRingBufferReusesContinuesNothing() {
        val emulator = emulator()
        // Fill the 100-row ring with wrapped lines, then write short ones over its reused rows.
        repeat(80) { emulator.feed("w".repeat(15) + "\r\n") }
        repeat(110) { emulator.feed("x$it\r\n") }
        for (row in -emulator.screen.activeTranscriptRows until emulator.mRows) {
            assertFalse("row $row", emulator.screen.getLineWrap(row))
        }
    }

    @Test
    fun deletedAndInsertedLinesMoveTheirWrapFlags() {
        val emulator = emulator()
        emulator.feed("a".repeat(15) + "\r\nb")
        emulator.feed("\u001b[1;1H\u001b[M")
        assertFalse("the continuation row moved up continues nothing", emulator.screen.getLineWrap(0))

        val inserted = emulator()
        inserted.feed("a".repeat(15) + "\u001b[1;1H\u001b[L")
        assertFalse("the inserted row continues nothing", inserted.screen.getLineWrap(0))
        assertTrue("the wrapped row moved down still goes on", inserted.screen.getLineWrap(1))
    }

    @Test
    fun aCursorOnAWideCharactersSecondCellKeepsItsRowThroughAReflow() {
        val emulator = emulator()
        emulator.feed("ab界cd\u001b[1;4H")
        assertEquals(3, emulator.cursorCol)
        emulator.resize(5, 4, 10, 20)
        assertEquals("the cursor goes to the wide character's first cell", 2, emulator.cursorCol)
        assertEquals(0, emulator.cursorRow)
    }

    private class NullOutput : TerminalOutput() {
        override fun write(data: ByteArray, offset: Int, count: Int) = Unit
        override fun titleChanged(oldTitle: String?, newTitle: String?) = Unit
        override fun hostDirectoryChanged(uri: String?) = Unit
        override fun onCopyTextToClipboard(text: String?) = Unit
        override fun onPasteTextFromClipboard() = Unit
        override fun onBell() = Unit
        override fun onColorsChanged() = Unit
    }
}
