import Foundation

/// tmux capabilities whose command spelling changed across supported versions.
public struct TmuxWindowCapabilities: Equatable, Sendable, Codable {
    public let supportsMoveBefore: Bool
    public let supportsSubscriptions: Bool

    public init(supportsMoveBefore: Bool, supportsSubscriptions: Bool) {
        self.supportsMoveBefore = supportsMoveBefore
        self.supportsSubscriptions = supportsSubscriptions
    }

    /// Parse the value of tmux's `#{version}` format. Unknown versions use the
    /// conservative pre-3.2 command set.
    public static func forVersion(_ version: String) -> Self {
        // `next-` uses tmux's version scheme. OpenBSD's number is the OS
        // release, not a tmux version: keep the safe swap-only capability set.
        let normalized = version.hasPrefix("next-") ? String(version.dropFirst(5)) : version
        let bytes = Array(normalized.utf8)
        guard let dot = bytes.firstIndex(of: 0x2E), dot > bytes.startIndex else {
            return Self(supportsMoveBefore: false, supportsSubscriptions: false)
        }
        let majorBytes = bytes[..<dot]
        let minorTail = bytes[bytes.index(after: dot)...]
        let minorBytes = minorTail.prefix { (0x30...0x39).contains($0) }
        guard !minorBytes.isEmpty,
              majorBytes.allSatisfy({ (0x30...0x39).contains($0) }),
              let major = Int(String(decoding: majorBytes, as: UTF8.self)),
              let minor = Int(String(decoding: minorBytes, as: UTF8.self))
        else {
            return Self(supportsMoveBefore: false, supportsSubscriptions: false)
        }
        let modern = major > 3 || (major == 3 && minor >= 2)
        return Self(supportsMoveBefore: modern, supportsSubscriptions: modern)
    }
}

/// Shared builders for every command that mutates tmux windows.
public enum TmuxWindowCommands {
    public static func splitPane(_ id: PaneId, horizontal: Bool, before: Bool = false) -> String {
        "split-window \(horizontal ? "-h" : "-v")\(before ? " -b" : "") -t \(id) -e COLORTERM=truecolor"
    }

    /// The default spelling is the interactive new-window command. Agent
    /// Center passes its detached/name/print/helper options here as well so no
    /// platform has to splice arguments into the shared command string.
    public static func newWindowAtEnd(
        target: String? = nil,
        detached: Bool = false,
        name: String? = nil,
        printFormat: String? = nil,
        command: String? = nil
    ) -> String {
        let target = target.map { "\(safeArgument($0, maximumScalars: 256)):{end}" } ?? "{end}"
        var result = "new-window -a -t \(AutoTmuxCommands.singleQuoted(target)) -e COLORTERM=truecolor"
        if detached { result += " -d" }
        if let name {
            result += " -n \(AutoTmuxCommands.singleQuoted(safeArgument(name, maximumScalars: 100)))"
        }
        if let printFormat {
            let safeFormat = safeArgument(
                printFormat,
                maximumScalars: 1_024,
                allowsTab: true
            )
            result += " -P -F \(AutoTmuxCommands.singleQuoted(safeFormat))"
        }
        if let command {
            result += " \(AutoTmuxCommands.singleQuoted(safeArgument(command, maximumScalars: 4_096)))"
        }
        return result
    }

    public static func newWindowAfterCurrent() -> String {
        "new-window -a -e COLORTERM=truecolor"
    }

    public static func selectWindow(_ id: WindowId, sessionID: SessionId? = nil) -> String {
        "select-window -t \(target(id, sessionID: sessionID))"
    }

    /// A tab switch: make `id` current in the issuing client's own session.
    ///
    /// Never send a bare `select-window -t @W` for this. Window ids are
    /// server-global, and a target with no session resolves through
    /// `cmd_find_best_session_with_window` to the most recently *active*
    /// session holding W (cmd-find.c), where activity moves only on tty
    /// keys and attach. In a session group that is routinely a sibling: the
    /// mosh `<owner>-tessera-view` session, or a user's `tmux new -t`. The
    /// command then switches that session's window instead of ours, which
    /// is a visible switch on someone else's screen. The session-qualified
    /// target resolves only within `sessionID`
    /// (`cmd_find_best_winlink_with_window`), and fails instead of
    /// wandering when W is no longer linked there.
    public static func selectWindow(_ id: WindowId, inOwnSession sessionID: SessionId) -> String {
        "select-window -t \(sessionQualifiedTarget(id, sessionID: sessionID))"
    }

    /// The one spelling of a session-qualified window (and optionally pane)
    /// target: `'$S:@W'` or `'$S:@W.%P'`, single-quoted.
    ///
    /// tmux's command lexer expands `$NAME` and `${NAME}` from the global
    /// environment in unquoted and double-quoted words alike
    /// (`yylex_token_variable` in cmd-parse.y; identical in 3.2, 3.3a, 3.4
    /// and 3.6a). A bare `$4:@7` survives only because `yylex_is_var` refuses
    /// a digit as a name's first character, so the `$` stays literal. Single
    /// quotes switch every expansion off (`$`, `~` and `\` are all skipped in
    /// `SINGLE_QUOTES`), so this spelling does not depend on that detail and
    /// cannot be widened by a later edit into an environment lookup. The ids
    /// are all digits, so nothing inside the quotes needs escaping.
    ///
    /// The window-order plans still spell their targets bare (they are pinned
    /// by the shared protocol vectors); that spelling is equally literal.
    public static func sessionQualifiedTarget(
        _ id: WindowId,
        sessionID: SessionId,
        paneID: PaneId? = nil
    ) -> String {
        let pane = paneID.map { ".\($0.description)" } ?? ""
        return "'\(sessionID.description):\(id.description)\(pane)'"
    }

    public static func killWindow(_ id: WindowId, sessionID: SessionId? = nil) -> String {
        "kill-window -t \(target(id, sessionID: sessionID))"
    }

    public static func renameWindow(
        _ id: WindowId,
        to name: String,
        sessionID: SessionId? = nil
    ) -> String {
        let name = safeArgument(name, maximumScalars: 100)
        return "rename-window -t \(target(id, sessionID: sessionID)) \(AutoTmuxCommands.singleQuoted(name))"
    }

    public static func moveWindow(
        _ id: WindowId,
        after other: WindowId,
        sessionID: SessionId? = nil
    ) -> String {
        "move-window -d -a -s \(target(id, sessionID: sessionID)) -t \(target(other, sessionID: sessionID))"
    }

    public static func moveWindow(
        _ id: WindowId,
        before other: WindowId,
        sessionID: SessionId? = nil
    ) -> String {
        "move-window -d -b -s \(target(id, sessionID: sessionID)) -t \(target(other, sessionID: sessionID))"
    }

    public static func swapWindows(
        _ first: WindowId,
        _ second: WindowId,
        sessionID: SessionId? = nil
    ) -> String {
        "swap-window -d -s \(target(first, sessionID: sessionID)) -t \(target(second, sessionID: sessionID))"
    }

    public static func renumber(target: String) -> String {
        let target = safeArgument(target, maximumScalars: 256)
        return "move-window -r -t \(AutoTmuxCommands.singleQuoted(target))"
    }

    private static func target(_ id: WindowId, sessionID: SessionId?) -> String {
        guard let sessionID else { return id.description }
        return "\(sessionID.description):\(id.description)"
    }

    /// Control mode splits commands at CR/LF before parsing quotes. Strip all
    /// C0 controls and DEL before quoting so no exported builder can produce a
    /// second command even when called directly through the ABI. A format may
    /// retain tab because tmux does not treat it as a command delimiter.
    private static func safeArgument(
        _ value: String,
        maximumScalars: Int,
        allowsTab: Bool = false
    ) -> String {
        let scalars = value.unicodeScalars.lazy.filter {
            ($0.value >= 0x20 && $0.value != 0x7F)
                || (allowsTab && $0.value == 0x09)
        }.prefix(maximumScalars)
        return String(String.UnicodeScalarView(Array(scalars)))
    }
}

/// One session-group member and the selection that tidy must preserve.
public struct TmuxSessionGroupMember: Equatable, Sendable, Codable {
    public let sessionID: SessionId
    public let activeWindowID: WindowId

    public init(sessionID: SessionId, activeWindowID: WindowId) {
        self.sessionID = sessionID
        self.activeWindowID = activeWindowID
    }
}

/// Discovers the complete attached session group for a safe multi-session tidy.
public enum TmuxSessionGroupQuery {
    public static let command =
        "list-sessions -F '#{session_id}\t#{session_group}\t#{window_id}'"

    public static func parse(
        lines: [String],
        containing ownSessionID: SessionId
    ) -> [TmuxSessionGroupMember]? {
        guard !lines.isEmpty, lines.count <= 512 else { return nil }
        var rows: [(member: TmuxSessionGroupMember, group: String)] = []
        var seen = Set<SessionId>()
        rows.reserveCapacity(lines.count)
        for line in lines {
            guard line.utf8.count <= 1_024 else { return nil }
            let fields = line.split(
                separator: "\t",
                maxSplits: 2,
                omittingEmptySubsequences: false
            )
            guard fields.count == 3,
                  let sessionID = SessionId(wireValue: String(fields[0])),
                  let activeWindowID = WindowId(wireValue: String(fields[2])),
                  seen.insert(sessionID).inserted
            else { return nil }
            rows.append((
                TmuxSessionGroupMember(
                    sessionID: sessionID,
                    activeWindowID: activeWindowID
                ),
                String(fields[1])
            ))
        }
        guard let own = rows.first(where: { $0.member.sessionID == ownSessionID }) else {
            return nil
        }
        let members = own.group.isEmpty
            ? [own.member]
            : rows.filter { $0.group == own.group }.map(\.member)
        return members.sorted { $0.sessionID.rawValue < $1.sessionID.rawValue }
    }

    /// Renumber every member before restoring any selection: a later group
    /// renumber may otherwise disturb a selection restored too early. Restore
    /// the attached session last so the control client's visible selection is
    /// the final state transition in the batch.
    public static func renumberPlan(
        for members: [TmuxSessionGroupMember],
        preservingAttached ownSessionID: SessionId
    ) -> TmuxWindowMutationPlan? {
        guard !members.isEmpty,
              members.count <= 512,
              Set(members.map(\.sessionID)).count == members.count,
              members.contains(where: { $0.sessionID == ownSessionID })
        else { return nil }
        let renumbers = members.map {
            TmuxWindowCommands.renumber(target: $0.sessionID.description)
        }
        let restoreOrder = members.filter { $0.sessionID != ownSessionID }
            + members.filter { $0.sessionID == ownSessionID }
        let restores = restoreOrder.map { member in
            TmuxWindowCommands.selectWindow(
                member.activeWindowID,
                sessionID: member.sessionID
            )
        }
        return TmuxWindowMutationPlan(mutationCommands: renumbers, selectionRestoreCommands: restores)
    }

    public static func renumberCommands(for members: [TmuxSessionGroupMember], preservingAttached ownSessionID: SessionId) -> [String]? {
        renumberPlan(for: members, preservingAttached: ownSessionID)?.commands
    }
}

/// The transport submits one batch but distinguishes mutation ACKs from
/// best-effort restores of independently disappearing peer sessions.
public struct TmuxWindowMutationPlan: Equatable, Codable, Sendable {
    public let mutationCommands: [String]
    public let selectionRestoreCommands: [String]
    public var commands: [String] { mutationCommands + selectionRestoreCommands }

    public init(mutationCommands: [String], selectionRestoreCommands: [String]) {
        self.mutationCommands = mutationCommands
        self.selectionRestoreCommands = selectionRestoreCommands
    }
}
