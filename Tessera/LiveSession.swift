import Foundation

/// Wrapper around an active session for the sidebar session list.
/// `Identifiable` so SwiftUI can track it in `ForEach`.
///
/// The `session` field holds a transport-typed `Session` enum rather
/// than a concrete `SSHSession`, so the same `LiveSession` record
/// can represent a mosh session once that transport lands. Call
/// sites that need SwiftUI reactivity branch on the enum and bind a
/// concrete `@StateObject` / `@ObservedObject` per case — see the
/// `TerminalSession` / `Session` docs for why existentials won't
/// work here.
struct LiveSession: Identifiable {
    let id: UUID
    let session: Session
    let hostName: String
    /// Persisted saved-host id for sessions that can be restored on a
    /// fresh app launch. Quick-connect and transient-password sessions
    /// leave this nil.
    let persistedHostID: UUID?
    /// Transport-scoped host identity (`transport:user@address:port`),
    /// used to detect duplicate connections for labeling and singleton
    /// tmux without conflating SSH and mosh sessions.
    let hostKey: String
    let launchMode: HostLaunchMode
    /// Pinned tmux session name when `launchMode == .pinnedTmux`.
    /// Surfaces in the sidebar label so multiple pinned sessions to
    /// the same host are distinguishable at a glance.
    let pinnedSessionName: String?
    let createdAt: Date

    /// Backwards-compat shim — "anything except a custom command" is
    /// treated as auto-tmux by the rest of the app.
    var autoTmux: Bool { launchMode != .customCommand }

    init(
        id: UUID = UUID(),
        session: Session,
        hostName: String,
        persistedHostID: UUID? = nil,
        hostKey: String,
        launchMode: HostLaunchMode,
        pinnedSessionName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.session = session
        self.hostName = hostName
        self.persistedHostID = persistedHostID
        self.hostKey = hostKey
        self.launchMode = launchMode
        self.pinnedSessionName = pinnedSessionName
        self.createdAt = createdAt
    }

    /// Display label for the sidebar, following the rules:
    ///   - auto-tmux: "name (tmux)"
    ///   - pinned tmux: "name (tmux: <session>)"
    ///   - custom command, single to host: "name"
    ///   - custom command, Nth to same host: "name #N"
    func displayLabel(in sessions: [LiveSession]) -> String {
        switch launchMode {
        case .autoTmux:
            return "\(hostName) (tmux)"
        case .pinnedTmux:
            let tag = pinnedSessionName?.isEmpty == false
                ? "tmux: \(pinnedSessionName!)"
                : "tmux"
            return "\(hostName) (\(tag))"
        case .customCommand:
            let siblings = sessions.filter {
                $0.hostKey == hostKey && $0.launchMode == .customCommand
            }
            if siblings.count <= 1 {
                return hostName
            }
            let sorted = siblings.sorted { $0.createdAt < $1.createdAt }
            let index = (sorted.firstIndex(where: { $0.id == id }) ?? 0) + 1
            return "\(hostName) #\(index)"
        }
    }
}
