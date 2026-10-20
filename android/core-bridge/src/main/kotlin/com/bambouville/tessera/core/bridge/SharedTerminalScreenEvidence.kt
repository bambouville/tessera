package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject

/** Detached native live-grid values; Core owns validation and provider rules. */
data class SharedTerminalScreenEvidence(
    val columns: Int,
    val cells: List<List<Cell>>,
    /** Current row continues its predecessor, including a predecessor in history. */
    val wrappedRows: List<Boolean>,
    val cursorRow: Int,
    val cursorColumn: Int,
    val cursorVisible: Boolean,
    val isAlternate: Boolean,
    val complete: Boolean = true,
) {
    data class Cell(val text: String, val width: Int, val style: Int)
    val physicalRows: List<String> get() = cells.map { row -> row.joinToString("") { it.text } }
    fun toJSON(): JSONObject = JSONObject().put("columns", columns)
        .put("cells", JSONArray().also { rows -> cells.forEach { row ->
            rows.put(JSONArray().also { values -> row.forEach { cell ->
                values.put(JSONArray().put(cell.text).put(cell.width).put(cell.style))
            } })
        } })
        .put("wrappedRows", JSONArray(wrappedRows)).put("cursorRow", cursorRow)
        .put("cursorColumn", cursorColumn).put("cursorVisible", cursorVisible)
        .put("isAlternate", isAlternate).put("complete", complete)
}
