import Foundation

/// Thin observable wrapper around the set of active sessions plus
/// last-touched timestamps. Owned by `ContentView` as `@State`,
/// injected into the environment for the command palette and MRU
/// cycle overlays to read.
///
/// We deliberately do NOT take ownership of the `activeSessions`
/// array itself — `ContentView` still owns it as `@State` and
/// pushes updates here via `syncActiveSessions`. That keeps the
/// existing `connect(to:)` / `dismiss(_:)` paths in `ContentView`
/// untouched while exposing a clean read surface to the new
/// switcher UI.
@MainActor
@Observable
final class SessionRegistry {
    /// Snapshot of the active sessions, mirroring ContentView's
    /// `activeSessions` array. Kept in sync by `syncActiveSessions`.
    private(set) var activeSessions: [LiveSession] = []

    /// Last-touched timestamp per session id. Updated by `markTouched`
    /// when the user switches into a session via any path (sidebar tap,
    /// palette commit, cycle commit, freshly connected).
    private(set) var lastTouched: [UUID: Date] = [:]

    /// Sessions whose launch overlay has dropped (first pane rendered /
    /// plain shell ready). A tmux session reports its transport state as
    /// `.connected` the instant the SSH/mosh handshake lands, but the
    /// user is still watching the "attaching tmux" shield until the first
    /// pane paints. The owning `SessionView` can't be observed from the
    /// sidebar's view tree, so it mirrors that "launch complete" moment
    /// here via `markRenderReady`; the sidebar row reads `isRenderReady`
    /// to hold itself in the connecting state until the shield drops.
    private(set) var renderReadyIDs: Set<UUID> = []

    /// Sessions that have ever been touched, ordered most-recent first.
    /// Used as the MRU walk order for the cycle HUD and as the sort
    /// key for the palette.
    ///
    /// Sessions present in `activeSessions` but never touched are
    /// appended at the end in their existing order — a freshly
    /// connected session that's still showing the spinner shouldn't
    /// jump to the top of the MRU until the user actually focuses it.
    var mruOrder: [UUID] {
        let touched = activeSessions
            .compactMap { live -> (UUID, Date)? in
                guard let date = lastTouched[live.id] else { return nil }
                return (live.id, date)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)

        let untouched = activeSessions
            .filter { lastTouched[$0.id] == nil }
            .map(\.id)

        return touched + untouched
    }

    /// Replace the mirrored active set. Drops any `lastTouched`
    /// entries for sessions that are no longer live, so disconnects
    /// don't leak into MRU order.
    func syncActiveSessions(_ sessions: [LiveSession]) {
        activeSessions = sessions
        let liveIDs = Set(sessions.map(\.id))
        lastTouched = lastTouched.filter { liveIDs.contains($0.key) }
        renderReadyIDs = renderReadyIDs.intersection(liveIDs)
    }

    /// Record that a session's launch overlay has dropped — the first
    /// pane has rendered (tmux) or the shell is ready (plain SSH/custom
    /// command). Called from `SessionView` / `MoshSessionView` when their
    /// local `launchOverlayVisible` flips false. Idempotent.
    func markRenderReady(_ id: UUID) {
        renderReadyIDs.insert(id)
    }

    /// Whether the session has finished launching (overlay dropped).
    /// A transport-`.connected` session that is NOT yet ready is still
    /// showing its "attaching tmux" shield.
    func isRenderReady(_ id: UUID) -> Bool {
        renderReadyIDs.contains(id)
    }

    /// Record that the user just focused this session. No-op if the
    /// id isn't in the active set — guards against stale ids from
    /// dismissed overlays calling back after the session ended.
    func markTouched(_ id: UUID, at date: Date = Date()) {
        guard activeSessions.contains(where: { $0.id == id }) else { return }
        lastTouched[id] = date
    }

    /// Lookup helper used by both the palette and the HUD.
    func session(for id: UUID) -> LiveSession? {
        activeSessions.first(where: { $0.id == id })
    }
}
