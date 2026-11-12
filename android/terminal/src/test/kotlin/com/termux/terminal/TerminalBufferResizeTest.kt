package com.termux.terminal

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Termux's resize, which `TerminalView` keeps a history reader across from the cursor's line. */
class TerminalBufferResizeTest {
    private fun buffer(columns: Int, rows: Int, lines: List<String>, wrapped: Set<Int> = emptySet()) =
        TerminalBuffer(columns, 100, rows).apply {
            lines.forEachIndexed { row, text ->
                text.forEachIndexed { column, char -> setChar(column, row, char.code, TextStyle.NORMAL) }
            }
            wrapped.forEach(::setLineWrap)
        }

    private fun TerminalBuffer.row(row: Int) = getSelectedText(0, row, mColumns - 1, row).trimEnd()

    /** Blank rows the reflow skipped go back above later content, scrolling the cursor's row up with the rest. */
    @Test
    fun skippedBlankRowsScrollTheCursorWithTheScreen() {
        val buffer = buffer(10, 6, listOf("1111111111", "2222", "PROMPT", "", "", "tail"), wrapped = setOf(0))
        val cursor = intArrayOf(6, 2)
        buffer.resize(5, 6, 100, cursor, TextStyle.NORMAL, false)
        assertEquals("T", buffer.row(cursor[1]))
        assertEquals(1, cursor[0])
        assertEquals(cursor[1], buffer.resizedCursorRow)
    }

    /** A blank row a line wraps through holds that line's blanks: a wider grid keeps the line in one piece. */
    @Test
    fun aBlankRowInsideAWrappedLineKeepsTheLineTogether() {
        val buffer = buffer(10, 4, listOf("aaaaaaaaaa", "", "cc"), wrapped = setOf(0, 1))
        val highlighted = TextStyle.encode(TextStyle.COLOR_INDEX_FOREGROUND, 4, 0)
        for (column in 0 until 10) buffer.setChar(column, 1, ' '.code, highlighted)
        val cursor = intArrayOf(0, 3)
        buffer.resize(20, 4, 100, cursor, TextStyle.NORMAL, false)
        assertTrue("the line still wraps into its last row", buffer.getLineWrap(0))
        assertEquals("aaaaaaaaaa", buffer.row(0))
        assertEquals("cc", buffer.row(1))
        assertEquals("the blanks keep their colours", highlighted, buffer.getStyleAt(0, 15))
    }

    /** Blanks a wrapped line goes on through that fill the screen scroll the cursor's row up with the rest. */
    @Test
    fun aWrappedLinesBlanksScrollTheCursorWithTheScreen() {
        val buffer = buffer(10, 4, listOf("$ ", "aaaaaaaaaa", "", "cc"), wrapped = setOf(1, 2))
        val cursor = intArrayOf(2, 0)
        buffer.resize(5, 4, 100, cursor, TextStyle.NORMAL, false)
        assertEquals(-2, buffer.resizedCursorRow)
        assertEquals("$", buffer.row(buffer.resizedCursorRow))
        assertEquals("cc", buffer.row(3))
    }

    /**
     * Blank rows that wrap with no text after them (spaces a program wrapped below the cursor, or a flag that outlived
     * its text) make no line: kept, they would fill the screen and scroll the prompt off it.
     */
    @Test
    fun blankRowsWithStaleWrapFlagsStayBelowTheCursor() {
        val buffer = buffer(10, 6, listOf("$ "), wrapped = setOf(1, 2, 3, 4))
        val cursor = intArrayOf(2, 0)
        buffer.resize(5, 6, 100, cursor, TextStyle.NORMAL, false)
        assertArrayEquals("the prompt stays on the screen's top row", intArrayOf(2, 0), cursor)
        assertEquals("$", buffer.row(0))
        assertEquals(0, buffer.activeTranscriptRows)
    }

    /** A cursor moved back into a line (editing a command) leaves the text after it in the line. */
    @Test
    fun textAfterTheCursorStaysInItsLine() {
        val buffer = buffer(20, 4, listOf("$ hello world"))
        val cursor = intArrayOf(5, 0)
        buffer.resize(8, 4, 100, cursor, TextStyle.NORMAL, false)
        assertEquals("$ hello", buffer.row(0))
        assertEquals("world", buffer.row(1))
        assertArrayEquals(intArrayOf(5, 0), cursor)

        val wrapped = buffer(10, 4, listOf("$ abcdefgh", "ijkl"), wrapped = setOf(0))
        val wrappedCursor = intArrayOf(4, 0)
        wrapped.resize(20, 4, 100, wrappedCursor, TextStyle.NORMAL, false)
        assertEquals("a wrapped line keeps its rows in order", "$ abcdefghijkl", wrapped.row(0))
    }

    /** A shorter grid with no blank rows below the cursor pushes its line into the transcript. */
    @Test
    fun aCursorPushedAboveTheScreenKeepsItsRowForTheReader() {
        val buffer = buffer(10, 6, (0 until 6).map { "r$it" })
        val cursor = intArrayOf(2, 1)
        buffer.resize(10, 3, 100, cursor, TextStyle.NORMAL, false)
        assertArrayEquals("the screen's cursor goes to its top row", intArrayOf(0, 0), cursor)
        assertEquals(-2, buffer.resizedCursorRow)
        assertEquals("r1", buffer.row(buffer.resizedCursorRow))
    }
}
