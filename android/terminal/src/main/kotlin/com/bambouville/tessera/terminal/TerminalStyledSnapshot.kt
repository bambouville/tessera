package com.bambouville.tessera.terminal

import com.bambouville.tessera.core.bridge.SharedTerminalScreenEvidence.Cell
import com.termux.terminal.TextStyle
import com.termux.terminal.WcWidth

/** Copy live physical cells using the terminal engine's own width rules. All
 * byte/cell bounds apply before publication; partial evidence is never usable. */
internal fun snapshotTerminalCells(
    rows: List<String>, columns: Int, maximumBytes: Int = 65_536,
    styleAt: (row: Int, column: Int) -> Long,
): List<List<Cell>>? {
    if (rows.isEmpty() || columns <= 0 || columns > 65_536 / rows.size || maximumBytes < rows.size - 1) return null
    var remaining = maximumBytes - (rows.size - 1)
    val result = ArrayList<List<Cell>>(rows.size)
    for ((rowIndex, text) in rows.withIndex()) {
        val cells = ArrayList<Cell>(columns)
        var offset = 0
        var baseColumn = -1
        while (offset < text.length) {
            val codePoint = text.codePointAt(offset)
            if (codePoint < 32 || codePoint in 127..159) return null
            val width = WcWidth.width(codePoint)
            if (width < 0 || width > 2 || cells.size + width > columns) return null
            remaining -= when {
                codePoint < 0x80 -> 1
                codePoint < 0x800 -> 2
                codePoint < 0x10000 -> 3
                else -> 4
            }
            if (remaining < 0) return null
            val glyph = String(Character.toChars(codePoint))
            if (width == 0) {
                if (baseColumn < 0) return null
                cells[baseColumn] = cells[baseColumn].copy(text = cells[baseColumn].text + glyph)
            } else {
                baseColumn = cells.size
                val style = screenStyle(styleAt(rowIndex, baseColumn))
                cells.add(Cell(glyph, width, style))
                if (width == 2) cells.add(Cell("", 0, screenStyle(styleAt(rowIndex, baseColumn + 1))))
            }
            offset += Character.charCount(codePoint)
        }
        while (cells.size < columns) {
            if (--remaining < 0) return null
            cells.add(Cell(" ", 1, screenStyle(styleAt(rowIndex, cells.size))))
        }
        result.add(cells)
    }
    return result
}

private fun screenStyle(value: Long): Int {
    val effect = TextStyle.decodeEffect(value)
    var result = 0
    if (effect and TextStyle.CHARACTER_ATTRIBUTE_BOLD != 0) result = result or 1
    if (effect and TextStyle.CHARACTER_ATTRIBUTE_UNDERLINE != 0) result = result or 2
    if (effect and TextStyle.CHARACTER_ATTRIBUTE_BLINK != 0) result = result or 4
    if (effect and TextStyle.CHARACTER_ATTRIBUTE_INVERSE != 0) result = result or 8
    if (effect and TextStyle.CHARACTER_ATTRIBUTE_INVISIBLE != 0) result = result or 16
    if (effect and TextStyle.CHARACTER_ATTRIBUTE_DIM != 0) result = result or 32
    if (effect and TextStyle.CHARACTER_ATTRIBUTE_ITALIC != 0) result = result or 64
    if (effect and TextStyle.CHARACTER_ATTRIBUTE_STRIKETHROUGH != 0) result = result or 128
    return result
}
