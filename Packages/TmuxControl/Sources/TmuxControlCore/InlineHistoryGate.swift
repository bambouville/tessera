import Foundation

/// Shared rule for when a platform should ask the render ledger to deepen an
/// inline (SSH+tmux) surface's local scrollback.
///
/// The ledger owns every stateful part of the policy: the credited depth,
/// exhaustion, single-flight and the settling signal
/// (`RenderEffect.inlineHistorySettled`). A platform keeps only two facts
/// from that effect (`canDeepen`, and whether it has a request in flight)
/// and supplies view geometry. Keeping the threshold here means Termux's
/// view and the iOS scroll view decide "is the reader close enough to the
/// oldest local row to fetch more?" identically; see
/// `tessera_tmux_inline_history_should_request` for the C ABI form Android
/// calls.
public enum TmuxInlineHistoryGate {
    /// How many viewports above the oldest local row the prefetch starts.
    /// Two screens hides the capture round trip behind the remaining local
    /// scroll on a phone without fetching on every idle scroll-up.
    public static let prefetchViewports = 2

    /// - Parameters:
    ///   - canDeepen: `canDeepen` from the last `inlineHistorySettled` for
    ///     this surface. A surface that has never settled reports `true`:
    ///     the ledger answers an unnecessary request with a settle rather
    ///     than a capture.
    ///   - requestInFlight: a `scrollbackRequested` fact was submitted and
    ///     no `inlineHistorySettled` has answered it yet.
    ///   - rowsAboveOldest: local transcript rows still hidden above the
    ///     viewport's top row (0 when the oldest row is visible). Negative
    ///     values are treated as 0.
    ///   - viewportRows: visible terminal rows; non-positive disables the
    ///     prefetch band and leaves only `crossedOldestRow`.
    ///   - crossedOldestRow: the gesture tried to scroll past the oldest
    ///     local row this frame.
    public static func shouldRequest(
        canDeepen: Bool,
        requestInFlight: Bool,
        rowsAboveOldest: Int,
        viewportRows: Int,
        crossedOldestRow: Bool
    ) -> Bool {
        guard canDeepen, !requestInFlight else { return false }
        if crossedOldestRow { return true }
        guard viewportRows > 0 else { return false }
        return max(0, rowsAboveOldest) <= viewportRows * prefetchViewports
    }
}
