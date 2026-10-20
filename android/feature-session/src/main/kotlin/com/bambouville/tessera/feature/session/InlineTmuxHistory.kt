package com.bambouville.tessera.feature.session

import android.view.ViewTreeObserver
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.getValue
import com.bambouville.tessera.core.bridge.SharedTmuxInlineHistoryPolicy
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.terminal.TermuxTerminalSurface

/**
 * Inline (SSH+tmux) history deepening, the platform half.
 *
 * The shared render ledger owns every stateful decision: the depth ladder,
 * exhaustion, single-flight admission, the identity reset and the
 * `inlineHistorySettled` signal that closes each gesture. This file holds the
 * two facts a platform is allowed to keep — `canDeepen` from the last settle
 * and a request-in-flight latch — plus the view geometry the ledger cannot
 * see. Mosh keeps its own side-channel ladder (`MoshPaneHistoryOverlay.kt`)
 * and never reaches this code.
 */
internal data class InlineTmuxHistoryRecord(
    /** Owner named by the last settle, or null before the first one. */
    val owner: SharedTmuxRenderOwner? = null,
    /** Credited capture depth the ledger last charged this surface. */
    val depth: Int = 0,
    /** tmux `history_size` behind that capture. */
    val historySize: Int = 0,
    /** Whether another `scrollbackRequested` can still fetch older rows. */
    val canDeepen: Boolean = true,
    /** A `scrollbackRequested` this platform submitted and has not seen settle. */
    val requestInFlight: Boolean = false,
) {
    /**
     * One `inlineHistorySettled`. The ledger promises exactly one per
     * gesture-triggered request — ignored, exhausted and aborted outcomes
     * included — so this is always where the latch is released.
     */
    fun settled(
        owner: SharedTmuxRenderOwner,
        depth: Int,
        historySize: Int,
        canDeepen: Boolean,
    ): InlineTmuxHistoryRecord = InlineTmuxHistoryRecord(
        owner = owner,
        depth = depth,
        historySize = historySize,
        canDeepen = canDeepen,
        requestInFlight = false,
    )

    /** The fact was accepted by the ledger; hold the surface's single flight. */
    fun requestSubmitted(): InlineTmuxHistoryRecord = copy(requestInFlight = true)

    /**
     * A bind moved this surface. An identity move (window/pane/transport)
     * makes the ledger reset its own inline state, so the platform's
     * exhaustion belief has to go with it; the in-flight latch does not,
     * because the request that is still outstanding will settle either way.
     */
    fun ownerRebound(identityChanged: Boolean): InlineTmuxHistoryRecord =
        if (!identityChanged) this else copy(owner = null, depth = 0, historySize = 0, canDeepen = true)

    /**
     * The defensive release. The ledger settles every terminal outcome, but a
     * stuck `mHistoryScrollPending` blocks *all* local scrolling
     * (`TerminalView.scrollLocalPixels`), so a lost settle must not cost the
     * reader their scrollbar.
     */
    fun timedOut(): InlineTmuxHistoryRecord = copy(requestInFlight = false)

    companion object {
        /**
         * Before the first settle the ledger's own state is unknown; assume it
         * can deepen so the first gesture is not silently swallowed.
         */
        val Initial = InlineTmuxHistoryRecord()
    }
}

/**
 * Transcript rows still hidden above the viewport top.
 *
 * `topRow` is zero at the live tail and negative while scrolled back, so the
 * remaining rows are simply the transcript depth plus it. A gesture that ran
 * past the oldest row reports zero rather than a negative count; the shared
 * gate clamps the same way.
 */
internal fun rowsAboveOldest(topRow: Int, availableRows: Int): Int =
    (availableRows + topRow).coerceAtLeast(0)

/** The shared gesture rule, injectable so JVM tests need no native library. */
internal fun interface InlineTmuxHistoryGate {
    fun shouldRequest(
        canDeepen: Boolean,
        requestInFlight: Boolean,
        rowsAboveOldest: Int,
        viewportRows: Int,
        crossedOldestRow: Boolean,
    ): Boolean
}

/** The production gate: `tessera_tmux_inline_history_should_request`. */
internal val SharedInlineTmuxHistoryGate = InlineTmuxHistoryGate(
    SharedTmuxInlineHistoryPolicy::shouldRequestInlineHistory,
)

/**
 * Whether this draw (or crossed-oldest-row signal) should deepen.
 *
 * Pure so the policy is testable without a view, an emulator or the shared
 * library. A surface that has never settled is [InlineTmuxHistoryRecord.Initial]
 * — the ladder is assumed open, exactly as `TmuxInlineHistoryGate` documents
 * for iOS, because the ledger answers an unnecessary request with a settle
 * rather than a capture.
 */
internal fun inlineTmuxHistoryShouldRequest(
    record: InlineTmuxHistoryRecord?,
    topRow: Int,
    availableRows: Int,
    viewportRows: Int,
    crossedOldestRow: Boolean,
    gate: InlineTmuxHistoryGate = SharedInlineTmuxHistoryGate,
): Boolean {
    val current = record ?: InlineTmuxHistoryRecord.Initial
    if (current.requestInFlight) return false
    return gate.shouldRequest(
        canDeepen = current.canDeepen,
        requestInFlight = current.requestInFlight,
        rowsAboveOldest = rowsAboveOldest(topRow, availableRows),
        viewportRows = viewportRows,
        crossedOldestRow = crossedOldestRow,
    )
}

/**
 * The decision both view signals make, with the crossing *derived* from the
 * same geometry rather than asserted by the caller.
 *
 * [derivesCrossing] says only that this signal is allowed to be a crossing —
 * it is the `setHistoryScrollRequest` runnable, which Termux raises from the
 * clamp branch of `scrollLocalPixels`. It is not the crossing itself: the
 * same runnable also fires on every ordinary upward frame, so the position is
 * what settles it. The draw listener passes false and can never report one.
 */
internal fun inlineTmuxHistoryRequestDecision(
    record: InlineTmuxHistoryRecord?,
    topRow: Int,
    availableRows: Int,
    viewportRows: Int,
    derivesCrossing: Boolean,
    gate: InlineTmuxHistoryGate = SharedInlineTmuxHistoryGate,
): Boolean = inlineTmuxHistoryShouldRequest(
    record = record,
    topRow = topRow,
    availableRows = availableRows,
    viewportRows = viewportRows,
    crossedOldestRow = derivesCrossing && rowsAboveOldest(topRow, availableRows) <= 0,
    gate = gate,
)

/**
 * Watches one inline render surface for a reader approaching the oldest row.
 *
 * Two signals feed the same gate. The draw listener sees ordinary upward
 * scrolling and asks while the reader is still inside the transcript, so the
 * replacement capture is usually already fed by the time they reach its end.
 * The `setHistoryScrollRequest` runnable is raised from inside
 * `scrollLocalPixels` before the glide can be clamped; answering it
 * synchronously is what lets the view carry the unclamped remainder into the
 * rebuilt transcript.
 *
 * That runnable is *not* by itself the crossed-the-oldest-row edge. Termux
 * runs it on every upward frame (`delta < 0 && !mHistoryScrollPending`) as
 * well as at the clamp, so reporting `crossedOldestRow = true` from it
 * unconditionally would turn the first scroll-up of any un-exhausted surface
 * into a full-depth capture and make the shared gate's two-viewport prefetch
 * band dead code. Both paths therefore report the view's actual position and
 * let the shared rule decide; the crossing is derived from that position,
 * which the clamp branch guarantees is exactly the oldest row.
 *
 * Neither path ever calls `beginHistoryScroll` itself: the latch is taken
 * inside [onRequest] and only once the ledger has accepted the fact, because a
 * pending history scroll with no request behind it freezes local scrolling
 * until the watchdog fires.
 */
@Composable
internal fun InlineTmuxHistoryController(
    surfaceId: String,
    terminal: TermuxTerminalSurface,
    record: InlineTmuxHistoryRecord?,
    enabled: Boolean,
    onRequest: (String) -> Unit,
    gate: InlineTmuxHistoryGate = SharedInlineTmuxHistoryGate,
) {
    val currentRecord by rememberUpdatedState(record)
    val currentOnRequest by rememberUpdatedState(onRequest)
    val currentGate by rememberUpdatedState(gate)
    val lastObservedTopRow = remember(terminal, surfaceId) { mutableIntStateOf(0) }
    DisposableEffect(terminal, surfaceId, enabled) {
        if (!enabled) return@DisposableEffect onDispose { }
        val view = terminal.view
        fun evaluate(derivesCrossing: Boolean) {
            if (view.isHistoryScrollPending) return
            val availableRows = view.mEmulator?.screen?.activeTranscriptRows ?: 0
            val viewportRows = view.mEmulator?.mRows ?: 0
            if (
                inlineTmuxHistoryRequestDecision(
                    record = currentRecord,
                    topRow = view.topRow,
                    availableRows = availableRows,
                    viewportRows = viewportRows,
                    derivesCrossing = derivesCrossing,
                    gate = currentGate,
                )
            ) currentOnRequest(surfaceId)
        }
        val observer = ViewTreeObserver.OnDrawListener observer@{
            if (view.isHistoryScrollPending) return@observer
            val topRow = view.topRow
            if (topRow == lastObservedTopRow.intValue) return@observer
            lastObservedTopRow.intValue = topRow
            evaluate(derivesCrossing = false)
        }
        view.viewTreeObserver.addOnDrawListener(observer)
        view.setHistoryScrollRequest(Runnable { evaluate(derivesCrossing = true) })
        onDispose {
            view.viewTreeObserver.takeIf { it.isAlive }?.removeOnDrawListener(observer)
            view.setHistoryScrollRequest(null)
        }
    }
}
