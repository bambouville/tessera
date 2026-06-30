import Foundation

/// `@Observable` state machine for the ⌘K quick-switch palette.
/// Lives independently of SwiftUI so it's exhaustively testable.
///
/// The palette filters a snapshot of active sessions by a substring
/// query (case-insensitive across host name, address, user, and
/// the active tmux window name when supplied) and tracks which
/// result is highlighted. `commit()` returns the highlighted id to
/// the caller, who is responsible for actually switching to it.
///
/// V1 scope: active sessions only, no positional jump (⌘1-9), no
/// in-palette disconnect (⌘⌫). The hooks for those features are
/// deliberately absent — they're additive and can land later.
@MainActor
@Observable
final class CommandPalette {
    var isOpen: Bool = false
    var query: String = ""
    /// Selected row, in `results` index space. Clamps via
    /// `clampSelectionToResults` after any filter/result change.
    var selectedIndex: Int = 0

    /// Snapshot of the active session set provided by the host view.
    /// Re-set on every open and whenever the underlying registry
    /// changes while the palette is visible.
    private(set) var sessions: [LiveSession] = []

    /// Optional per-session label augmentations (e.g. the active tmux
    /// window name). Keyed by session id. Looked up during filter +
    /// rendering — if absent, only the LiveSession fields are matched.
    private(set) var paneTitles: [UUID: String] = [:]

    /// Bumped each time `open()` is called so the SwiftUI view layer
    /// can `.onChange(of:)` the token and re-focus the input even when
    /// `isOpen` was already true (mirrors `FindController.focusRequestToken`).
    private(set) var focusRequestToken: Int = 0

    /// Sessions matching the current query, ordered by last-touched
    /// (most recent first) using the supplied `lastTouched` map.
    /// Untouched sessions tail the list in their existing order so a
    /// fresh connection doesn't bury everything else.
    var results: [LiveSession] {
        let filtered = sessions.filter { live in
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return true }
            let needle = q.lowercased()
            if live.hostName.lowercased().contains(needle) { return true }
            if live.hostKey.lowercased().contains(needle) { return true }
            if let pane = paneTitles[live.id]?.lowercased(),
               pane.contains(needle) { return true }
            return false
        }

        return filtered.sorted { lhs, rhs in
            let l = lastTouched[lhs.id]
            let r = lastTouched[rhs.id]
            switch (l, r) {
            case let (lv?, rv?): return lv > rv
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none):
                let li = sessions.firstIndex { $0.id == lhs.id } ?? 0
                let ri = sessions.firstIndex { $0.id == rhs.id } ?? 0
                return li < ri
            }
        }
    }

    private var lastTouched: [UUID: Date] = [:]

    /// Open the palette. Captures a snapshot of the active set and
    /// pane titles + last-touched timestamps. Re-opens are idempotent
    /// but reset `query` + `selectedIndex` and bump the focus token.
    func open(
        sessions: [LiveSession],
        paneTitles: [UUID: String] = [:],
        lastTouched: [UUID: Date] = [:]
    ) {
        self.sessions = sessions
        self.paneTitles = paneTitles
        self.lastTouched = lastTouched
        self.query = ""
        self.selectedIndex = 0
        self.isOpen = true
        self.focusRequestToken &+= 1
    }

    func close() {
        isOpen = false
    }

    /// Refresh the captured snapshot mid-open. Used by the SwiftUI host
    /// view when the underlying registry changes (a new session was
    /// connected, an old one disconnected) while the palette is visible.
    func refreshSnapshot(
        sessions: [LiveSession],
        paneTitles: [UUID: String],
        lastTouched: [UUID: Date]
    ) {
        guard isOpen else { return }
        self.sessions = sessions
        self.paneTitles = paneTitles
        self.lastTouched = lastTouched
        clampSelectionToResults()
    }

    func selectNext() {
        let count = results.count
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = (selectedIndex + 1) % count
    }

    func selectPrevious() {
        let count = results.count
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = (selectedIndex - 1 + count) % count
    }

    /// Return the highlighted session id, or nil if the result set is
    /// empty. Does NOT close the palette — the caller decides whether
    /// to dismiss after acting on the id.
    func commit() -> UUID? {
        let r = results
        guard !r.isEmpty, selectedIndex >= 0, selectedIndex < r.count else {
            return nil
        }
        return r[selectedIndex].id
    }

    /// Called from a SwiftUI `.onChange(of: query)` so the view layer
    /// doesn't have to know about the clamping rules.
    func didChangeQuery() {
        clampSelectionToResults()
    }

    private func clampSelectionToResults() {
        let count = results.count
        if count == 0 {
            selectedIndex = 0
        } else if selectedIndex >= count {
            selectedIndex = count - 1
        } else if selectedIndex < 0 {
            selectedIndex = 0
        }
    }
}
