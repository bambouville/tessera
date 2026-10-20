import Foundation
import Observation
import TmuxControl

struct CommandPaletteNotice: Equatable {
    /// Already-resolved copy: the notice's source stores it as a
    /// `LocalizedStringResource` and resolves it on the way in.
    let title: String
    let message: String
    let actionLabel: String?
}

enum CommandPaletteCommit: Equatable {
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
    case moveWindow(
        sessionID: UUID,
        windowID: WindowId,
        move: TmuxWindowMove
    )
    case renumberWindows(sessionID: UUID)
}

struct CommandPaletteTmuxPane: Identifiable, Equatable {
    let id: PaneId
    let title: String
    let command: String?
}

struct CommandPaletteTmuxWindow: Identifiable, Equatable {
    let id: WindowId
    let title: String
    /// What the rename field starts from — tmux's own `#{window_name}`, not
    /// `title`. Renaming sets `window_name` and disables `automatic-rename`, so
    /// seeding it with the active pane's OSC title bakes "vim README" in as the
    /// window's name. The label does not change (the pane title still wins), so
    /// the damage only surfaces later, on this client and every other one.
    ///
    /// A window with no name yet — the pre-hydration window — seeds empty rather
    /// than falling back to `title`, which would reintroduce that same bug for
    /// exactly the windows whose name tmux is still choosing. Android's rename
    /// field starts from the same place.
    let renameSeed: String
    /// Zero-based position in the authoritative tmux order. This is the
    /// destination vocabulary accepted by `TmuxController.moveWindow`.
    let position: Int
    /// tmux's `#{window_index}`. It can differ from `position + 1` when the
    /// session uses a non-1 base index or has gaps.
    let tmuxIndex: Int?
    let panes: [CommandPaletteTmuxPane]

    init(
        id: WindowId,
        title: String,
        renameSeed: String? = nil,
        position: Int = 0,
        tmuxIndex: Int? = nil,
        panes: [CommandPaletteTmuxPane]
    ) {
        self.id = id
        self.title = title
        self.renameSeed = renameSeed ?? ""
        self.position = position
        self.tmuxIndex = tmuxIndex
        self.panes = panes
    }
}

struct CommandPaletteTmuxSnapshot: Equatable {
    let windows: [CommandPaletteTmuxWindow]
    let activeWindowID: WindowId?
    let activePaneID: PaneId?
    let allowsMutation: Bool
    let canReorder: Bool
    let canTidy: Bool
    let isPending: Bool
    let error: String?

    @MainActor
    init(
        tmux: TmuxController,
        isDegraded: Bool,
        agentProvider: (PaneId) -> String?
    ) {
        windows = tmux.mode == .tmuxControl || isDegraded
            ? Self.buildWindows(tmux.windows, agentProvider: agentProvider) : []
        activeWindowID = tmux.activeWindowId
        activePaneID = tmux.activePaneId
        allowsMutation = tmux.mode == .tmuxControl
            && !isDegraded
            && !tmux.gridAuthority.isPeer
            && !tmux.isWindowReorderPending
        canReorder = tmux.canReorderWindows
        canTidy = tmux.canTidyWindows
        isPending = tmux.isWindowReorderPending
        error = tmux.windowOrderError
    }

    static func buildWindows(
        _ windows: [TmuxController.WindowInfo],
        agentProvider: (PaneId) -> String?
    ) -> [CommandPaletteTmuxWindow] {
        windows.enumerated().map { position, window in
            let panes = window.panes.map { pane in
                CommandPaletteTmuxPane(
                    id: pane.id,
                    title: nonDefaultTitle(pane.title, isDefault: pane.titleIsDefault)
                        ?? agentProvider(pane.id)
                        ?? pane.currentCommand
                        ?? window.displayName,
                    command: pane.currentCommand
                )
            }
            let activePaneID = window.activePaneId ?? window.panes.first(where: \.isActive)?.id
            let title = nonDefaultTitle(window.activePaneTitle, isDefault: window.activePaneTitleIsDefault)
                ?? activePaneID.flatMap(agentProvider)
                ?? window.displayName
            return CommandPaletteTmuxWindow(
                id: window.id,
                title: title,
                renameSeed: window.windowName,
                position: position,
                tmuxIndex: window.index,
                panes: panes
            )
        }
    }

    private static func nonDefaultTitle(_ title: String?, isDefault: Bool) -> String? {
        guard !isDefault,
              let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }
}

enum CommandPaletteEntry: Identifiable {
    enum ID: Hashable {
        case home
        case pane(WindowId, PaneId)
        case session(UUID)
        case window(WindowId)
    }

    case home
    case pane(window: CommandPaletteTmuxWindow, pane: CommandPaletteTmuxPane)
    case session(LiveSession)
    case window(CommandPaletteTmuxWindow)

    var id: ID {
        switch self {
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
/// The palette filters snapshots of active sessions and tmux targets by a
/// substring query, lists sessions in MRU order, and tracks which unified
/// result is highlighted. Agent Center v2 owns agent search and navigation in
/// its dedicated surface. The caller performs navigation and any explicitly
/// requested tmux mutation.
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

    /// Optional per-session label augmentations (e.g. the active tmux
    /// window name). Keyed by session id. Looked up during filter +
    /// rendering — if absent, only the LiveSession fields are matched.
    private(set) var paneTitles: [UUID: String] = [:]
    private var authoritativeTmuxWindows: [CommandPaletteTmuxWindow] = []
    private var windowPreviewOrder: [WindowId]?
    var tmuxWindows: [CommandPaletteTmuxWindow] {
        guard let windowPreviewOrder else { return authoritativeTmuxWindows }
        let byID = Dictionary(uniqueKeysWithValues: authoritativeTmuxWindows.map { ($0.id, $0) })
        guard Set(windowPreviewOrder) == Set(byID.keys) else { return authoritativeTmuxWindows }
        return windowPreviewOrder.compactMap { byID[$0] }
    }
    private(set) var currentSessionID: UUID?
    private(set) var activeWindowID: WindowId?
    private(set) var activePaneID: PaneId?
    private(set) var includesHome = false
    private(set) var allowsTmuxMutation = true
    private(set) var canReorderTmuxWindows = false
    private(set) var canTidyTmuxWindows = false
    private(set) var isTmuxWindowMutationPending = false
    private(set) var tmuxWindowOrderError: String?
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
    private(set) var keyboardHandoff: TerminalKeyboardHandoff?
    private(set) var tmuxSnapshotGeneration: Int = 0

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
            let windowMatches = needle.isEmpty
                || window.title.lowercased().contains(needle)
                || window.renameSeed.lowercased().contains(needle)
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

    /// Unified keyboard-navigation order for home, tmux targets, and sessions.
    /// Agent Center v2 owns thread search and navigation in its own surface.
    var entries: [CommandPaletteEntry] {
        homeResults
            + tmuxResults
            + results.map(CommandPaletteEntry.session)
    }

    private var lastTouched: [UUID: Date] = [:]

    /// Open the palette. Captures a snapshot of the active set and
    /// pane titles + last-touched timestamps. Re-opens are idempotent
    /// but reset `query` + `selectedIndex` and bump the focus token.
    func open(
        sessions: [LiveSession],
        paneTitles: [UUID: String] = [:],
        lastTouched: [UUID: Date] = [:],
        tmuxWindows: [CommandPaletteTmuxWindow] = [],
        currentSessionID: UUID? = nil,
        activeWindowID: WindowId? = nil,
        activePaneID: PaneId? = nil,
        includesHome: Bool = false,
        allowsTmuxMutation: Bool = true,
        canReorderTmuxWindows: Bool = false,
        canTidyTmuxWindows: Bool = false,
        isTmuxWindowMutationPending: Bool = false,
        tmuxWindowOrderError: String? = nil,
        notice: CommandPaletteNotice? = nil,
        onNoticeAction: (() -> Void)? = nil
    ) {
        self.sessions = sessions
        self.paneTitles = paneTitles
        self.lastTouched = lastTouched
        self.authoritativeTmuxWindows = tmuxWindows
        windowPreviewOrder = nil
        self.currentSessionID = currentSessionID
        self.activeWindowID = activeWindowID
        self.activePaneID = activePaneID
        self.includesHome = includesHome
        self.allowsTmuxMutation = allowsTmuxMutation
        self.canReorderTmuxWindows = canReorderTmuxWindows
        self.canTidyTmuxWindows = canTidyTmuxWindows
        self.isTmuxWindowMutationPending = isTmuxWindowMutationPending
        self.tmuxWindowOrderError = tmuxWindowOrderError.map { NSLocalizedString($0, comment: "tmux window ordering failure") }
        self.notice = notice
        self.noticeAction = onNoticeAction
        self.query = ""
        self.selectedIndex = 0
        self.isOpen = true
        self.focusRequestToken &+= 1
        self.tmuxSnapshotGeneration &+= 1
    }

    func close() {
        if isOpen {
            keyboardHandoff = TerminalKeyboardHandoff()
        }
        isOpen = false
        notice = nil
        noticeAction = nil
    }

    func performNoticeAction() {
        let action = noticeAction
        close()
        action?()
    }

    /// Replace the open palette's notice as the warning appears, changes or
    /// clears. The action stays the opener's, which reads live state on tap.
    func refreshNotice(_ notice: CommandPaletteNotice?) {
        guard isOpen, self.notice != notice else { return }
        self.notice = notice
    }

    /// Refresh the captured snapshot mid-open. Used by the SwiftUI host
    /// view when the underlying registry changes (a new session was
    /// connected, an old one disconnected) while the palette is visible.
    func refreshSnapshot(
        sessions: [LiveSession],
        paneTitles: [UUID: String],
        lastTouched: [UUID: Date],
        tmuxWindows: [CommandPaletteTmuxWindow]? = nil,
        currentSessionID: UUID? = nil,
        activeWindowID: WindowId? = nil,
        activePaneID: PaneId? = nil,
        allowsTmuxMutation: Bool? = nil,
        canReorderTmuxWindows: Bool? = nil,
        canTidyTmuxWindows: Bool? = nil,
        isTmuxWindowMutationPending: Bool? = nil,
        tmuxWindowOrderError: String? = nil
    ) {
        guard isOpen else { return }
        self.sessions = sessions
        self.paneTitles = paneTitles
        self.lastTouched = lastTouched
        let orderError = tmuxWindowOrderError.map { NSLocalizedString($0, comment: "tmux window ordering failure") }
        // Agent rows and the session set refresh too, repeating the same tmux
        // state. Only a real change may end a window drag in progress.
        if let tmuxWindows, tmuxWindows != authoritativeTmuxWindows
            || currentSessionID != self.currentSessionID
            || activeWindowID != self.activeWindowID
            || activePaneID != self.activePaneID
            || allowsTmuxMutation.map({ $0 != self.allowsTmuxMutation }) == true
            || canReorderTmuxWindows.map({ $0 != self.canReorderTmuxWindows }) == true
            || canTidyTmuxWindows.map({ $0 != self.canTidyTmuxWindows }) == true
            || isTmuxWindowMutationPending.map({ $0 != self.isTmuxWindowMutationPending }) == true
            || orderError != self.tmuxWindowOrderError {
            self.authoritativeTmuxWindows = tmuxWindows
            windowPreviewOrder = nil
            self.currentSessionID = currentSessionID
            self.activeWindowID = activeWindowID
            self.activePaneID = activePaneID
            if let allowsTmuxMutation { self.allowsTmuxMutation = allowsTmuxMutation }
            if let canReorderTmuxWindows { self.canReorderTmuxWindows = canReorderTmuxWindows }
            if let canTidyTmuxWindows { self.canTidyTmuxWindows = canTidyTmuxWindows }
            if let isTmuxWindowMutationPending {
                self.isTmuxWindowMutationPending = isTmuxWindowMutationPending
            }
            self.tmuxWindowOrderError = orderError
            self.tmuxSnapshotGeneration &+= 1
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

    /// Reorders only the palette's presentation snapshot. The controller is
    /// mutated once, on drop; until then this gives the drag a live gap while
    /// keeping server truth and its stable window ids untouched.
    func previewMoveWindow(_ id: WindowId, to destination: Int) {
        guard let source = tmuxWindows.firstIndex(where: { $0.id == id }),
              destination >= 0,
              destination < tmuxWindows.count,
              source != destination
        else { return }
        var order = tmuxWindows.map(\.id)
        order.insert(order.remove(at: source), at: destination)
        windowPreviewOrder = order
        clampSelectionToResults()
    }

    func restoreWindowOrder(_ ids: [WindowId]) {
        guard Set(ids) == Set(authoritativeTmuxWindows.map(\.id)) else { return }
        windowPreviewOrder = ids == authoritativeTmuxWindows.map(\.id) ? nil : ids
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

}
