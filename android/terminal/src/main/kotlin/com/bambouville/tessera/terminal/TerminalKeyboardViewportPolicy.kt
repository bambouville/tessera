package com.bambouville.tessera.terminal

import kotlin.math.max
import kotlin.math.min

/** Clear space around the live cursor row in the terminal viewport's coordinates. */
data class TerminalCaretClearance(
    val abovePixels: Float,
    val belowPixels: Float,
)

/**
 * Minimum-movement policy shared by every Android terminal transport.
 *
 * The session still lifts by the complete IME overlap so the accessory row remains attached to
 * the keyboard. This policy returns how much of that lift the terminal canvas may cancel because
 * the cursor already has blank space below it. It mirrors iOS' v0.3.6
 * `TerminalKeyboardCaretPolicy` exactly.
 */
object TerminalKeyboardViewportPolicy {
    fun holdPixels(
        previousHoldPixels: Float?,
        clearance: TerminalCaretClearance,
        imeOverlapPixels: Float,
    ): Float {
        val ceiling = max(0f, clearance.belowPixels)
        val floor = min(
            ceiling,
            max(0f, imeOverlapPixels - max(0f, clearance.abovePixels)),
        )
        return previousHoldPixels?.coerceIn(floor, ceiling) ?: ceiling
    }

    fun counterShiftPixels(holdPixels: Float, imeOverlapPixels: Float): Float =
        min(max(0f, holdPixels), max(0f, imeOverlapPixels))
}
