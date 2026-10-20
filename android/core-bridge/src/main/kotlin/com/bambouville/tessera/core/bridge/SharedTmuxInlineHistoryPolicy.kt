package com.bambouville.tessera.core.bridge

/**
 * The one gesture rule the platforms evaluate for inline (SSH+tmux) history.
 *
 * Swift authority: `TmuxControlCore.TmuxInlineHistoryGate.shouldRequest`,
 * exported as `tessera_tmux_inline_history_should_request` and declared in
 * `Packages/TesseraCore/Sources/TesseraCoreCABIHeaders/include/TesseraCoreABI.h`.
 * iOS calls the Swift rule directly; this is the same rule, not a copy of it.
 *
 * Everything stateful — the depth ladder, exhaustion, single-flight, identity
 * reset and the settling signal — lives in the shared render ledger. A
 * platform keeps exactly two facts per surface (`canDeepen` from the last
 * `inlineHistorySettled` and its own request-in-flight latch) and supplies the
 * view geometry the ledger cannot see.
 */
object SharedTmuxInlineHistoryPolicy {
    /**
     * Whether this surface should submit `scrollbackRequested` now.
     *
     * [rowsAboveOldest] is how many transcript rows remain hidden above the
     * viewport top, [viewportRows] the visible row count, and
     * [crossedOldestRow] true when the gesture ran past the oldest row the
     * local transcript holds.
     */
    @JvmStatic
    fun shouldRequestInlineHistory(
        canDeepen: Boolean,
        requestInFlight: Boolean,
        rowsAboveOldest: Int,
        viewportRows: Int,
        crossedOldestRow: Boolean,
    ): Boolean {
        NativeLibraries.ensureLoaded()
        return when (
            val answer = NativeCoreBindings.tmuxInlineHistoryShouldRequest(
                canDeepen,
                requestInFlight,
                rowsAboveOldest,
                viewportRows,
                crossedOldestRow,
            )
        ) {
            1 -> true
            0 -> false
            else -> throw IllegalStateException(
                "shared core rejected inline history gate inputs: $answer",
            )
        }
    }
}
