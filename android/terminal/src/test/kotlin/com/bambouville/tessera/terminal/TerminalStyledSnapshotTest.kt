package com.bambouville.tessera.terminal

import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalOutput
import com.termux.terminal.TextStyle
import org.junit.Assert.*
import org.junit.Test

class TerminalStyledSnapshotTest {
    private val dim = TextStyle.CHARACTER_ATTRIBUTE_DIM.toLong()

    @Test fun typedSnapshotPreservesPhysicalWidthsAndStylesWithoutANSI() {
        val rows = snapshotTerminalCells(listOf("界e\u0301😀x"), 8) { _, col -> if (col >= 5) dim else 0 }!!
        assertEquals(listOf(2, 0, 1, 2, 0, 1, 1, 1), rows.single().map { it.width })
        assertEquals("e\u0301", rows[0][2].text)
        assertEquals(32, rows[0][5].style)
        assertEquals("界e\u0301😀x  ", rows.single().joinToString("") { it.text })
    }

    @Test fun limitsApplyBeforeReturningAnyPartialSnapshot() {
        assertNull(snapshotTerminalCells(listOf("界x"), 2) { _, _ -> 0 })
        assertNull(snapshotTerminalCells(listOf("x"), 2, maximumBytes = 1) { _, _ -> 0 })
        assertNull(snapshotTerminalCells(listOf("x"), 65_537) { _, _ -> 0 })
        assertNull(snapshotTerminalCells(listOf("\u001b"), 2) { _, _ -> 0 })
    }

    @Test fun promptTextKeepsEachCellsBackgroundAsItWasWritten() {
        val emulator = TerminalEmulator(SilentOutput(), 20, 2, 10, 20, 100, null)
        val input = "\u001b[41ma\u001b[101mb\u001b[48;2;1;2;3mc\u001b[7md\u001b[0me\r\n\u001b[48;5;200m界x".toByteArray()
        emulator.append(input, input.size)
        val rows = (0 until 2).map { emulator.screen.getSelectedText(0, it, 19, it) }
        val cells = snapshotTerminalCells(rows, 20) { row, col -> emulator.screen.getStyleAt(row, col) }!!
        assertEquals("\u001b[0;41ma\u001b[0;101mb\u001b[0;48;2;1;2;3mc\u001b[0;7;48;2;1;2;3md\u001b[0me" + " ".repeat(15) +
            "\n\u001b[0;48;5;200m界x\u001b[0m" + " ".repeat(17),
            snapshotPromptText(cells) { row, col -> emulator.screen.getStyleAt(row, col) })
    }

    /** The surface's snapshot carries the backgrounds an inspection forwards for a local grid. */
    @Test fun theSurfacesSnapshotCarriesItsGridsPromptText() {
        val emulator = TerminalEmulator(SilentOutput(), 20, 2, 10, 20, 100, null)
        val input = "\u001b[41ma\u001b[0mb\r\n\u001b[7mc".toByteArray()
        emulator.append(input, input.size)
        val snapshot = snapshotEmulatorText(emulator)!!
        assertEquals("ab" + " ".repeat(18) + "\nc" + " ".repeat(19), snapshot.visibleText)
        assertEquals("\u001b[0;41ma\u001b[0mb" + " ".repeat(18) + "\n\u001b[0;7mc\u001b[0m" + " ".repeat(19), snapshot.promptText)
        val pending = "\u001b[?2026hd".toByteArray()
        emulator.append(pending, pending.size)
        assertEquals(true, snapshotEmulatorText(emulator)?.framePending)
        assertNull(snapshotEmulatorText(emulator)?.promptText)
    }

    private class SilentOutput : TerminalOutput() {
        override fun write(data: ByteArray, offset: Int, count: Int) = Unit
        override fun titleChanged(oldTitle: String?, newTitle: String?) = Unit
        override fun hostDirectoryChanged(uri: String?) = Unit
        override fun onCopyTextToClipboard(text: String?) = Unit
        override fun onPasteTextFromClipboard() = Unit
        override fun onBell() = Unit
        override fun onColorsChanged() = Unit
    }

    @Test fun captureWorkDependsOnlyOnPhysicalGrid() {
        var visits = 0
        val rows = snapshotTerminalCells(List(24) { "live" }, 80) { _, _ -> visits++; 0 }!!
        assertEquals(1920, visits)
        assertEquals(1920, rows.sumOf { it.size })
    }
}
