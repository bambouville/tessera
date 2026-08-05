import Foundation
import TmuxControl

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
    struct TmuxFocusRequest: Equatable {
        let token: UInt64
        let sessionID: UUID
        let windowID: WindowId
        let paneID: PaneId?
    }

    struct TmuxCloseRequest: Equatable {
        let token: UInt64
        let action: CommandPaletteTmuxClose
    }

    struct TmuxMutationRequest: Equatable {
        let token: UInt64
        let action: CommandPaletteTmuxMutation
    }

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
    /// Per-session continuation presentation mirrored from the view-owned tmux
    /// controller. The sidebar lives outside those controller subtrees, so it
    /// reads this map to show which live sessions yielded to another device.
    private(set) var gridAuthorityPeerNames: [UUID: String] = [:]
    private(set) var tmuxFocusRequest: TmuxFocusRequest?
    private(set) var tmuxCloseRequest: TmuxCloseRequest?
    private(set) var tmuxMutationRequest: TmuxMutationRequest?
    private var nextTmuxFocusToken: UInt64 = 0
    private var nextTmuxCloseToken: UInt64 = 0
    private var nextTmuxMutationToken: UInt64 = 0

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
        gridAuthorityPeerNames = gridAuthorityPeerNames.filter {
            liveIDs.contains($0.key)
        }
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

    /// Mirror (or clear) a live session's yielded presentation. Unknown ids
    /// are ignored so a disappearing SessionView cannot resurrect stale
    /// sidebar state after its LiveSession was removed.
    func setGridAuthorityPeerName(_ name: String?, for id: UUID) {
        guard activeSessions.contains(where: { $0.id == id }) else { return }
        if let name, !name.isEmpty {
            gridAuthorityPeerNames[id] = name
        } else {
            gridAuthorityPeerNames.removeValue(forKey: id)
        }
    }

    func gridAuthorityPeerName(for id: UUID) -> String? {
        gridAuthorityPeerNames[id]
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

    /// Route a compact switcher destination back into the owning session view.
    /// The request is an observable one-shot token; only the matching live
    /// session consumes it, so controllers stay view-owned.
    func requestTmuxFocus(
        sessionID: UUID,
        windowID: WindowId,
        paneID: PaneId? = nil
    ) {
        guard activeSessions.contains(where: { $0.id == sessionID }) else { return }
        nextTmuxFocusToken &+= 1
        tmuxFocusRequest = TmuxFocusRequest(
            token: nextTmuxFocusToken,
            sessionID: sessionID,
            windowID: windowID,
            paneID: paneID
        )
    }

    /// Route a compact switcher's destructive action to the matching
    /// session-owned tmux controller. Stable tmux ids cross the navigation
    /// boundary; transport state and stale-target validation stay in the
    /// owning session view.
    func requestTmuxClose(_ action: CommandPaletteTmuxClose) {
        let sessionID: UUID
        switch action {
        case .pane(let id, _, _), .window(let id, _):
            sessionID = id
        }
        guard activeSessions.contains(where: { $0.id == sessionID }) else { return }
        nextTmuxCloseToken &+= 1
        tmuxCloseRequest = TmuxCloseRequest(
            token: nextTmuxCloseToken,
            action: action
        )
    }

    /// Route non-destructive compact tmux actions to the matching view-owned
    /// controller. The controller revalidates stable ids against its current
    /// hydrated snapshot before emitting anything on the wire.
    func requestTmuxMutation(_ action: CommandPaletteTmuxMutation) {
        let sessionID: UUID
        switch action {
        case .split(let id, _, _), .rename(let id, _, _):
            sessionID = id
        }
        guard activeSessions.contains(where: { $0.id == sessionID }) else { return }
        nextTmuxMutationToken &+= 1
        tmuxMutationRequest = TmuxMutationRequest(
            token: nextTmuxMutationToken,
            action: action
        )
    }
}
