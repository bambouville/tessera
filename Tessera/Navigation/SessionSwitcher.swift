import Foundation

/// Direction for the ⌘⇧K / ⌘⇧J session switcher.
enum SessionSwitchDirection {
    /// ⌘⇧K — move back (up the sidebar's session list).
    case previous
    /// ⌘⇧J — move forward (down the sidebar's session list).
    case next
}

/// Pure positional stepping over the active-session list, used by the
/// ⌘⇧K / ⌘⇧J switcher chords.
///
/// We deliberately walk the sidebar's *visible* order (the
/// `activeSessions` array) rather than MRU order: a neighbour-walk implies
/// a stable list, so ⌘⇧J followed by ⌘⇧K should land you back where you
/// started — which a most-recently-used order (reshuffled on every
/// switch) wouldn't guarantee. The ⌘K palette still sorts by MRU; this
/// chord is the predictable neighbour-walk.
///
/// The walk wraps at both ends: ⌘⇧J on the last session lands on the
/// first, ⌘⇧K on the first lands on the last.
///
/// Why a free pure helper instead of the old stateful `MRUCycleController`:
/// the chord went through three dead ends before landing on ⌘⇧K / ⌘⇧J.
/// ⌃Tab is swallowed by iPadOS's focus engine (Tab-family keys are
/// reserved for focus-group navigation, and `wantsPriorityOverSystemBehavior`
/// doesn't reclaim them). ⌘↑/⌘↓ are consumed by SwiftTerm's UITextInput
/// first responder before reaching an ancestor's keyCommands. ⌘⌥[ / ⌘⌥]
/// never matched at all — Option remaps "[" to a different glyph, so the
/// command registered for input "[" was never consulted (confirmed
/// on-device: the selector never fired). Plain ⌘⇧+letter sidesteps all
/// three — Shift leaves the base character intact, so UIKit matches the
/// chord across the full responder chain before delivery, like the ⌘⇧[
/// window chords: a key-down each, no hold-to-cycle, no settle timer, no
/// HUD. Each press is an immediate switch to the neighbour.
enum SessionSwitcher {
    /// Returns the id to switch to, or nil when there's nowhere to go
    /// (empty list, or a single session you're already on).
    ///
    /// - `order`: session ids in sidebar order.
    /// - `current`: the session the user is focused on, or nil on the
    ///   landing page / for a stale id. When `current` isn't in `order`,
    ///   ⌘⇧J lands on the first session and ⌘⇧K on the last.
    static func step(
        order: [UUID],
        from current: UUID?,
        direction: SessionSwitchDirection
    ) -> UUID? {
        guard !order.isEmpty else { return nil }

        guard let current, let index = order.firstIndex(of: current) else {
            return direction == .next ? order.first : order.last
        }

        // Already on the only session — nothing to switch to.
        guard order.count > 1 else { return nil }

        let delta = direction == .next ? 1 : -1
        let next = (index + delta + order.count) % order.count
        return order[next]
    }
}
