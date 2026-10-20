import Foundation

/// The live `refresh-client -B` feeds a control client wants the runtime to
/// keep registered. See `TmuxControlSubscriptions` for how each is targeted.
public struct TmuxSubscriptionRequests: Equatable, Sendable {
    /// `#{window_bell_flag}`, one registration per pane.
    public var bell: Bool
    /// `TmuxPaneMetadataSubscription.format`, one registration per pane.
    public var paneMetadata: Bool
    /// `TmuxWindowOrderSubscription.format`, registered once the server is
    /// known to be tmux 3.2 or later.
    public var windowOrder: Bool
    /// The grid-authority stamp read in this scope; nil asks for none.
    public var authority: TmuxGridAuthorityScope?

    public init(
        bell: Bool = false,
        paneMetadata: Bool = false,
        windowOrder: Bool = false,
        authority: TmuxGridAuthorityScope? = nil
    ) {
        self.bell = bell
        self.paneMetadata = paneMetadata
        self.windowOrder = windowOrder
        self.authority = authority
    }
}

/// Builds and reconciles a control client's `refresh-client -B` feeds.
///
/// Every feed is registered against a single pane (`%N`) or window (`@N`),
/// never against every pane (`%*`), every window (`@*`) or the session (an
/// empty target). tmux 3.2 through 3.6a crash the whole server, and so every
/// session on it, when a control client holding one of those outlives its
/// session.
/// Destroying a session clears its clients' session pointer, but a control
/// client stays until its unread output drains, and its one-second
/// subscription timer keeps firing meanwhile. The all-panes, all-windows and
/// session checks in `control_check_subs_timer` then read the NULL session
/// (`segfault at f0` in the kernel log); the single-pane and single-window
/// checks only compare against it. A phone that stops reading (backgrounded, a stalled or
/// half-open link) holds its client in exactly that state. On a private
/// tmux 3.4 server whose control client never read its output, killing the
/// client's session crashed the server 3 times out of 3 with the old `%*`
/// and session feeds, and 0 out of 3 with these per-pane feeds.
///
/// Pane-level feeds (bell, metadata) are registered once per pane, named
/// `<feed>.<pane number>`. Session-level feeds (authority, window order)
/// read the same in every window of the session, so each is registered
/// once, under its plain name, against an anchor window that moves on when
/// that window closes. The anchor is a window, not a pane: tmux skips a
/// dead pane's subscriptions (`remain-on-exit`), but evaluates a window's
/// in its active pane whatever that pane's state, and reports them with a
/// `-` pane field. Registering a name tmux already holds replaces it.
public enum TmuxControlSubscriptions {
    /// What this client has asked tmux for: each name's `target:format`, and
    /// the window carrying the session-level feeds.
    public struct Registration: Equatable, Sendable {
        public fileprivate(set) var specs: [String: String] = [:]
        public fileprivate(set) var anchor: WindowId?

        public init() {}
    }

    public static let bellFormat = "#{window_bell_flag}"

    public static func paneName(_ feed: String, pane: PaneId) -> String {
        "\(feed).\(pane.rawValue)"
    }

    /// Whether a `%subscription-changed` name belongs to `feed`: its plain
    /// name or one of its per-pane names.
    public static func name(_ name: String, isFeed feed: String) -> Bool {
        guard name.hasPrefix(feed) else { return false }
        let rest = name.utf8.dropFirst(feed.utf8.count)
        guard let separator = rest.first else { return true }
        let digits = rest.dropFirst()
        return separator == UInt8(ascii: ".")
            && !digits.isEmpty
            && digits.allSatisfy { (0x30...0x39).contains($0) }
    }

    /// The commands that bring `registration` to what `requests` asks for
    /// over `windows` and their `panes`, updating `registration` as if tmux
    /// accepted them.
    ///
    /// `supportsSubscriptions` is the server's capability: true once its
    /// version is known to be 3.2 or later, which window order waits for.
    /// Every other feed is registered whatever the version says, as it was
    /// before these feeds were per pane: OpenBSD's tmux names its OS
    /// release, which reads as unknown, and a server without
    /// `refresh-client -B` only answers each command with an error.
    public static func reconcile(
        _ registration: inout Registration,
        requests: TmuxSubscriptionRequests,
        windows: [WindowId],
        panes: [PaneId],
        supportsSubscriptions: Bool?
    ) -> [String] {
        var seenPanes = Set<PaneId>()
        let panes = panes.filter { seenPanes.insert($0).inserted }
        let anchor = registration.anchor.flatMap { windows.contains($0) ? $0 : nil }
            ?? windows.min { $0.rawValue < $1.rawValue }

        // Desired registrations grouped by target, anchor first and then
        // panes in order, so a target's feeds travel in one command.
        var desired: [String: String] = [:]
        var byTarget: [(target: String, names: [String])] = []
        func want(_ name: String, _ target: String, _ format: String) {
            desired[name] = "\(target):\(format)"
            if let index = byTarget.firstIndex(where: { $0.target == target }) {
                byTarget[index].names.append(name)
            } else {
                byTarget.append((target, [name]))
            }
        }
        if let anchor {
            if let scope = requests.authority {
                want(TmuxGridAuthority.subscriptionName, anchor.description, TmuxGridAuthority.subscriptionFormat(scope))
            }
            if requests.windowOrder, supportsSubscriptions == true {
                want(TmuxWindowOrderSubscription.name, anchor.description, TmuxWindowOrderSubscription.format)
            }
        }
        for pane in panes {
            if requests.paneMetadata {
                want(paneName(TmuxPaneMetadataSubscription.name, pane: pane), pane.description, TmuxPaneMetadataSubscription.format)
            }
            if requests.bell {
                want(paneName(TmuxBellSubscription.name, pane: pane), pane.description, bellFormat)
            }
        }

        var commands: [String] = []
        let removed = registration.specs.keys.filter { desired[$0] == nil }.sorted()
        for start in stride(from: 0, to: removed.count, by: 32) {
            let names = removed[start..<min(start + 32, removed.count)]
            commands.append("refresh-client" + names.map { " -B '\($0)'" }.joined())
        }
        for (_, names) in byTarget {
            let changed = names.filter { registration.specs[$0] != desired[$0] }
            guard !changed.isEmpty else { continue }
            commands.append("refresh-client" + changed.map { " -B '\($0):\(desired[$0]!)'" }.joined())
        }
        registration.specs = desired
        registration.anchor = desired.isEmpty ? nil : anchor
        return commands
    }
}
