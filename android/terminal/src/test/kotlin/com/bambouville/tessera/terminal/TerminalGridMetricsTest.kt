package com.bambouville.tessera.terminal

import kotlin.math.ceil
import org.junit.Assert.assertEquals
import org.junit.Test

class TerminalGridMetricsTest {
    @Test
    fun pixelWidthPreservesColumnsWhenFloatProductRoundsDown() {
        val metrics = TerminalGridMetrics(4.0634923f, 19, 3)
        val oldWidth = ceil(63 * metrics.cellWidthPixels).toInt()
        assertEquals(256, oldWidth)
        assertEquals(62, metrics.columnsFor(oldWidth))
        assertEquals(257, metrics.pixelWidth(63))
        assertEquals(63, metrics.columnsFor(metrics.pixelWidth(63)))
    }

    @Test
    fun pixelDimensionsPreserveGridAcrossFractionalCellWidths() {
        for (thousandths in 4000..64000) {
            val metrics = TerminalGridMetrics(thousandths / 1000f, 19, 3)
            for (columns in 20..200) {
                val width = metrics.pixelWidth(columns)
                val actual = metrics.columnsFor(width)
                if (actual != columns) {
                    assertEquals("cell=${metrics.cellWidthPixels} width=$width", columns, actual)
                }
            }
        }
        val metrics = TerminalGridMetrics(4.0634923f, 19, 3)
        for (rows in 10..120) {
            assertEquals(rows, metrics.rowsFor(metrics.pixelHeight(rows)))
        }
    }
}
