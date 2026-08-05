import Foundation
import Observation
import TmuxControl

struct CommandPaletteNotice: Equatable {
    let title: String
    let message: String
    let actionLabel: String?
}

enum CommandPaletteCommit: Equatable {
    case agent(AgentInstanceID)
    case home
    case pane(sessionID: UUID, windowID: WindowId, paneID: PaneId)
    case session(UUID)
    case window(sessionID: UUID, windowID: WindowId)
}

enum CommandPaletteTmuxClose: Equatable {
    case pane(sessionID: UUID, windowID: WindowId, paneID: PaneId)
    case window(sessionID: UUID, windowID: WindowId)
}

enum CommandPaletteTmuxMutation: Equatable {
    case split(
        sessionID: UUID,
        paneID: PaneId,
        axis: PaneSplitAxis
    )
    case rename(
        sessionID: UUID,
        windowID: WindowId,
        name: String
    )
}

struct CommandPaletteTmuxPane: Identifiable, Equatable {
    let id: PaneId
    let title: String
    let command: String?
}

struct CommandPaletteTmuxWindow: Identifiable, Equatable {
    let id: WindowId
    let title: String
    let panes: [CommandPaletteTmuxPane]
}

enum CommandPaletteEntry: Identifiable {
    enum ID: Hashable {
        case agent(AgentInstanceID)
        case home
        case pane(WindowId, PaneId)
        case session(UUID)
        case window(WindowId)
    }

    case agent(AgentInstance)
    case home
    case pane(window: CommandPaletteTmuxWindow, pane: CommandPaletteTmuxPane)
    case session(LiveSession)
    case window(CommandPaletteTmuxWindow)

    var id: ID {
        switch self {
        case .agent(let agent): return .agent(agent.id)
        case .home: return .home
        case .pane(let window, let pane): return .pane(window.id, pane.id)
        case .session(let session): return .session(session.id)
        case .window(let window): return .window(window.id)
        }
    }
}

/// `@Observable` state machine for the ⌘K quick-switch palette.
/// Lives independently of SwiftUI so it's exhaustively testable.
///
/// The palette filters snapshots of active agents and sessions by a substring
/// query, lists MRU sessions before urgency-ranked agents, and tracks which
/// unified result is highlighted. `@` scopes to agents. The caller performs
/// navigation and any explicitly requested tmux mutation.
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
    private(set) var tmuxWindows: [CommandPaletteTmuxWindow] = []
    private(set) var currentSessionID: UUID?
    private(set) var activeWindowID: WindowId?
    private(set) var activePaneID: PaneId?
    private(set) var includesHome = false
    private(set) var allowsTmuxMutation = true
    /// Optional compact-terminal warning rendered above every navigation
    /// result. It is deliberately outside `entries`: switching targets keeps
    /// its established keyboard order, while touch users get the requested
    /// first-line action without a warning row masquerading as navigation.
    private(set) var notice: CommandPaletteNotice?
    @ObservationIgnored private var noticeAction: (() -> Void)?

    var visibleNotice: CommandPaletteNotice? {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? notice : nil
    }

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

    var homeResults: [CommandPaletteEntry] {
        guard includesHome else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.isEmpty || "hosts home".contains(needle) else { return [] }
        return [.home]
    }

    var tmuxResults: [CommandPaletteEntry] {
        guard currentSessionID != nil else { return [] }
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.hasPrefix("@") else { return [] }
        let needle = raw.lowercased()

        return tmuxWindows.flatMap { window -> [CommandPaletteEntry] in
            let windowMatches = needle.isEmpty || window.title.lowercased().contains(needle)
            let matchingPanes = window.panes.filter { pane in
                windowMatches
                    || pane.title.lowercased().contains(needle)
                    || (pane.command?.lowercased().contains(needle) ?? false)
                    || pane.id.description.lowercased().contains(needle)
            }
            guard windowMatches || !matchingPanes.isEmpty else { return [] }

            var entries: [CommandPaletteEntry] = [.window(window)]
            if window.panes.count > 1 {
                entries.append(contentsOf: matchingPanes.map {
                    .pane(window: window, pane: $0)
                })
            }
            return entries
        }
    }

    /// Unified keyboard-navigation order: existing MRU-ordered sessions first,
    /// followed by agents ranked by urgency. The palette remains navigation-only.
    var entries: [CommandPaletteEntry] {
        homeResults
            + tmuxResults
            + results.map(CommandPaletteEntry.session)
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
        lastTouched: [UUID: Date] = [:],
        tmuxWindows: [CommandPaletteTmuxWindow] = [],
        currentSessionID: UUID? = nil,
        activeWindowID: WindowId? = nil,
        activePaneID: PaneId? = nil,
        includesHome: Bool = false,
        allowsTmuxMutation: Bool = true,
        notice: CommandPaletteNotice? = nil,
        onNoticeAction: (() -> Void)? = nil
    ) {
        self.sessions = sessions
        self.agents = agents
        self.paneTitles = paneTitles
        self.lastTouched = lastTouched
        self.tmuxWindows = tmuxWindows
        self.currentSessionID = currentSessionID
        self.activeWindowID = activeWindowID
        self.activePaneID = activePaneID
        self.includesHome = includesHome
        self.allowsTmuxMutation = allowsTmuxMutation
        self.notice = notice
        self.noticeAction = onNoticeAction
        self.query = ""
        self.selectedIndex = 0
        self.isOpen = true
        self.focusRequestToken &+= 1
    }

    func close() {
        isOpen = false
        notice = nil
        noticeAction = nil
    }

    func performNoticeAction() {
        let action = noticeAction
        close()
        action?()
    }

    /// Refresh the captured snapshot mid-open. Used by the SwiftUI host
    /// view when the underlying registry changes (a new session was
    /// connected, an old one disconnected) while the palette is visible.
    func refreshSnapshot(
        sessions: [LiveSession],
        agents: [AgentInstance] = [],
        paneTitles: [UUID: String],
        lastTouched: [UUID: Date],
        tmuxWindows: [CommandPaletteTmuxWindow]? = nil,
        currentSessionID: UUID? = nil,
        activeWindowID: WindowId? = nil,
        activePaneID: PaneId? = nil
    ) {
        guard isOpen else { return }
        self.sessions = sessions
        self.agents = agents
        self.paneTitles = paneTitles
        self.lastTouched = lastTouched
        if let tmuxWindows {
            self.tmuxWindows = tmuxWindows
            self.currentSessionID = currentSessionID
            self.activeWindowID = activeWindowID
            self.activePaneID = activePaneID
        }
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
        case .home: return .home
        case .pane(let window, let pane):
            guard let currentSessionID else { return nil }
            return .pane(
                sessionID: currentSessionID,
                windowID: window.id,
                paneID: pane.id
            )
        case .session(let session): return .session(session.id)
        case .window(let window):
            guard let currentSessionID else { return nil }
            return .window(sessionID: currentSessionID, windowID: window.id)
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
