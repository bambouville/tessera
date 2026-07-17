import Foundation

enum CommandPaletteCommit: Equatable {
    case agent(AgentInstanceID)
    case session(UUID)
}

enum CommandPaletteEntry: Identifiable {
    enum ID: Hashable {
        case agent(AgentInstanceID)
        case session(UUID)
    }

    case agent(AgentInstance)
    case session(LiveSession)

    var id: ID {
        switch self {
        case .agent(let agent): return .agent(agent.id)
        case .session(let session): return .session(session.id)
        }
    }
}

/// `@Observable` state machine for the ⌘K quick-switch palette.
/// Lives independently of SwiftUI so it's exhaustively testable.
///
/// The palette filters snapshots of active agents and sessions by a substring
/// query, lists MRU sessions before urgency-ranked agents, and tracks which
/// unified result is highlighted. `@` scopes to agents. It remains a pure
/// navigation surface: the caller performs the pane/session jump.
@MainActor
@Observable
final class CommandPalette {
    var isOpen: Bool = false
    var query: String = ""
    /// Selected row, in unified `entries` index space. Clamps via
    /// `clampSelectionToResults` after any filter/result change.
    var selectedIndex: Int = 0

    /// Snapshot of the active session set provided by the host view.
    /// Re-set on every open and whenever the underlying registry
    /// changes while the palette is visible.
    private(set) var sessions: [LiveSession] = []

    /// Agent snapshot supplied by Agent Center. Entries are ranked by urgency
    /// after sessions; an `@` query scopes the palette to this set.
    private(set) var agents: [AgentInstance] = []

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
        let rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuery.hasPrefix("@") else { return [] }
        let filtered = sessions.filter { live in
            guard !rawQuery.isEmpty else { return true }
            let needle = rawQuery.lowercased()
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

    var agentResults: [AgentInstance] {
        let rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = rawQuery.hasPrefix("@")
        let needle = (scoped ? String(rawQuery.dropFirst()) : rawQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return agents.filter { agent in
            guard !needle.isEmpty else { return true }
            return agent.name.lowercased().contains(needle)
                || agent.location.hostName.lowercased().contains(needle)
                || agent.location.addressText.lowercased().contains(needle)
                || agent.location.transportLabel.lowercased().contains(needle)
                || (agent.location.windowName?.lowercased().contains(needle) ?? false)
                || Self.statusSearchText(agent.status).contains(needle)
                || (agent.prompt?.summary.lowercased().contains(needle) ?? false)
                || (agent.outputTail?.lowercased().contains(needle) ?? false)
        }.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status < rhs.status }
            if lhs.statusChangedAt != rhs.statusChangedAt {
                return lhs.statusChangedAt < rhs.statusChangedAt
            }
            return lhs.location.addressText < rhs.location.addressText
        }
    }

    /// Unified keyboard-navigation order: existing MRU-ordered sessions first,
    /// followed by agents ranked by urgency. The palette remains navigation-only.
    var entries: [CommandPaletteEntry] {
        results.map(CommandPaletteEntry.session)
            + agentResults.map(CommandPaletteEntry.agent)
    }

    private var lastTouched: [UUID: Date] = [:]

    /// Open the palette. Captures a snapshot of the active set and
    /// pane titles + last-touched timestamps. Re-opens are idempotent
    /// but reset `query` + `selectedIndex` and bump the focus token.
    func open(
        sessions: [LiveSession],
        agents: [AgentInstance] = [],
        paneTitles: [UUID: String] = [:],
        lastTouched: [UUID: Date] = [:]
    ) {
        self.sessions = sessions
        self.agents = agents
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
        agents: [AgentInstance] = [],
        paneTitles: [UUID: String],
        lastTouched: [UUID: Date]
    ) {
        guard isOpen else { return }
        self.sessions = sessions
        self.agents = agents
        self.paneTitles = paneTitles
        self.lastTouched = lastTouched
        clampSelectionToResults()
    }

    func selectNext() {
        let count = entries.count
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = (selectedIndex + 1) % count
    }

    func selectPrevious() {
        let count = entries.count
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = (selectedIndex - 1 + count) % count
    }

    /// Return the highlighted session id, or nil if the result set is
    /// empty. Does NOT close the palette — the caller decides whether
    /// to dismiss after acting on the id.
    func commit() -> UUID? {
        guard case .session(let id)? = commitResult() else { return nil }
        return id
    }

    func commitResult() -> CommandPaletteCommit? {
        let current = entries
        guard !current.isEmpty,
              selectedIndex >= 0,
              selectedIndex < current.count else { return nil }
        switch current[selectedIndex] {
        case .agent(let agent): return .agent(agent.id)
        case .session(let session): return .session(session.id)
        }
    }

    /// Called from a SwiftUI `.onChange(of: query)` so the view layer
    /// doesn't have to know about the clamping rules.
    func didChangeQuery() {
        clampSelectionToResults()
    }

    private func clampSelectionToResults() {
        let count = entries.count
        if count == 0 {
            selectedIndex = 0
        } else if selectedIndex >= count {
            selectedIndex = count - 1
        } else if selectedIndex < 0 {
            selectedIndex = 0
        }
    }

    private static func statusSearchText(_ status: AgentStatus) -> String {
        switch status {
        case .waitingForInput: return "needs input waiting blocked"
        case .justFinished: return "just finished completed done feedback"
        case .working: return "working running"
        case .idle: return "idle prompt"
        case .unavailable: return "status unavailable"
        }
    }
}
