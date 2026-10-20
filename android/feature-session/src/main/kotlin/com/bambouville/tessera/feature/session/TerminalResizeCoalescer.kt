package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedResizeCoalescerState
import com.bambouville.tessera.core.bridge.SharedResizeDecision
import com.bambouville.tessera.core.bridge.SharedSessionPolicy
import com.bambouville.tessera.core.bridge.SharedTerminalSize
import com.bambouville.tessera.core.bridge.SharedTmuxGridSize

/** What the controller should do with a size the terminal view reported. */
internal enum class TerminalResizeOffer {
    /** Nothing has been delivered yet — the remote cannot start without it. */
    Deliver,

    /** Already known to the remote, or already the size being waited on. */
    Unchanged,

    /** A transient proposal came back to the published geometry. */
    CancelPending,

    /** Hold it for the settle window. */
    Schedule,
}

/**
 * Trailing-edge resize policy, owned by
 * `Packages/TesseraCore/Sources/TesseraSessionCore/TerminalResizeCoalescer.swift`
 * and reached through `SharedSessionPolicy`. The coroutine and timer stay in
 * [SshSessionController]; the rule lives across the bridge.
 *
 * Two drifts close with the move. The first size now DELIVERS rather than
 * being scheduled — this platform used to make a session that cannot start
 * without a geometry wait out a settle window for it. And the window itself
 * comes from [SharedSessionPolicy.resizeSettleMilliseconds] (120 ms, sized to
 * swallow a modal's measured 28 ms shrink-and-restore) rather than the local
 * 80 ms guess.
 */
internal class TerminalResizeCoalescer {
    private var state = SharedResizeCoalescerState()

    fun offer(size: SharedTmuxGridSize): TerminalResizeOffer {
        val previousPending = state.pending
        val outcome = SharedSessionPolicy.resizeNote(state, size.toTerminalSize())
        state = outcome.state
        return when (outcome.decision) {
            SharedResizeDecision.Send -> TerminalResizeOffer.Deliver
            // The shared decision carries no "this is already the size we are
            // waiting on" case, because a repeat costs the core nothing. It
            // costs this side a restarted timer, which would let a stream of
            // identical sizes starve delivery, so the repeat is recognised
            // here from the state that went in.
            SharedResizeDecision.Wait ->
                if (previousPending == size.toTerminalSize()) TerminalResizeOffer.Unchanged
                else TerminalResizeOffer.Schedule
            SharedResizeDecision.Drop ->
                if (previousPending != null) TerminalResizeOffer.CancelPending
                else TerminalResizeOffer.Unchanged
        }
    }

    /**
     * Closes the settle window for [size]. Returns null when the wait was
     * superseded, so a stale timer cannot deliver an old size.
     */
    fun settle(size: SharedTmuxGridSize): SharedTmuxGridSize? {
        val outcome = SharedSessionPolicy.resizeSettle(state, size.toTerminalSize())
        state = outcome.state
        return size.takeIf { outcome.settled }
    }

    /**
     * Forgets both the delivered baseline and any wait. A reconnect starts a
     * fresh remote that has been told nothing, so the size already on screen
     * has to count as new again.
     */
    fun reset() {
        state = SharedResizeCoalescerState()
    }

    private fun SharedTmuxGridSize.toTerminalSize() = SharedTerminalSize(columns, rows)
}
