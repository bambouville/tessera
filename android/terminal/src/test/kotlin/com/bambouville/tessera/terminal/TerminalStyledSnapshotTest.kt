package com.bambouville.tessera.terminal

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

    @Test fun captureWorkDependsOnlyOnPhysicalGrid() {
        var visits = 0
        val rows = snapshotTerminalCells(List(24) { "live" }, 80) { _, _ -> visits++; 0 }!!
        assertEquals(1920, visits)
        assertEquals(1920, rows.sumOf { it.size })
    }
}
