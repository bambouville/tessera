import Foundation

/// A tmux grid in character cells: a window's size, or the client size this
/// device advertises. Plain integers so both platforms' adapters can fill it
/// from their own layout and viewport types.
public struct TmuxGridSize: Codable, Hashable, Sendable, CustomStringConvertible {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    /// `<columns>x<rows>`, the spelling both platforms' diagnostics use.
    public var description: String { "\(columns)x\(rows)" }
}

/// The local grids this device recently pushed while it owned the window,
/// newest last.
///
/// More than one entry because a mosh side-channel window can freeze at an
/// earlier owned transient (a mid-keyboard height, a pane-grid size) across a
/// side-channel drop, which is still our size. Recording an entry again moves
/// it to the newest slot without growing the history; the oldest fall off
/// beyond `limit`.
public struct TmuxOwnedSizeHistory: Equatable, Sendable {
    public static let limit = 8

    public private(set) var sizes: [TmuxGridSize] = []

    public init(_ sizes: [TmuxGridSize] = []) {
        for size in sizes { record(size) }
    }

    public var newest: TmuxGridSize? { sizes.last }

    public func contains(_ size: TmuxGridSize) -> Bool { sizes.contains(size) }

    public mutating func record(_ size: TmuxGridSize) {
        if sizes.last == size { return }
        sizes.removeAll { $0 == size }
        sizes.append(size)
        if sizes.count > Self.limit {
            sizes.removeFirst(sizes.count - Self.limit)
        }
    }

    /// The control client moved to another tmux session: the grids this
    /// device owned belonged to the old session's windows and are no
    /// evidence about the new one.
    public mutating func removeAll() {
        guard !sizes.isEmpty else { return }
        sizes.removeAll()
    }
}

/// The adapter's facts about the window this device renders, from which the
/// core answers the one question a read naming our own stamp depends on:
/// `TmuxGridAuthorityLifecycleReducer.QueryGeometry`.
///
/// Only the window tmux names active is evidence, and only once the window
/// list is hydrated and that name is authoritative. A reattach's
/// `list-windows` reply lands before its active-window query, and until then
/// a model's "active" window can be a provisional fallback (the first window
/// listed, or a `%window-add`). Judged against that window's grid, an own
/// read replayed every window at the raw viewport (the Android gate's W2
/// shrank 203x30 -> 100x30 after a mosh drop).
public struct TmuxAuthorityGeometryEvidence: Equatable, Sendable {
    public struct ActiveWindow: Equatable, Sendable {
        /// The tmux window number (`@<id>`).
        public var id: Int
        /// The window's grid; nil before its layout is known.
        public var size: TmuxGridSize?
        /// tmux itself named this window active (`%session-window-changed`,
        /// the active-window query reply). False for a model's provisional
        /// pick, which says nothing about what this device renders.
        public var authoritative: Bool

        public init(id: Int, size: TmuxGridSize?, authoritative: Bool) {
            self.id = id
            self.size = size
            self.authoritative = authoritative
        }
    }

    /// A window's effective `window-size` option, as probed for that window.
    public struct WindowSizePolicy: Equatable, Sendable {
        public var windowID: Int
        /// Only `latest` ties the window to a client at all: under
        /// `smallest`, `largest` or `manual` tmux sizes it by its own rule,
        /// so a mismatch is no evidence of another sizer (and there is
        /// nothing this device could replay).
        public var isLatest: Bool

        public init(windowID: Int, isLatest: Bool) {
            self.windowID = windowID
            self.isLatest = isLatest
        }

        /// Parses `show-options -wA -v -t @<id> window-size`: the first
        /// non-empty line, trimmed. An empty reply is tmux's default,
        /// `latest`.
        public init(windowID: Int, rawReply: String) {
            let value = rawReply
                .split(whereSeparator: \.isNewline)
                .lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            self.init(windowID: windowID, isLatest: value.isEmpty || value == "latest")
        }
    }

    public var windowListHydrated: Bool
    public var activeWindow: ActiveWindow?
    /// The client size this device would advertise now; nil before the
    /// viewport is measured.
    public var localSize: TmuxGridSize?
    /// The newest policy probe reply. It counts only for the window it was
    /// probed for.
    public var policy: WindowSizePolicy?
    public var owned: TmuxOwnedSizeHistory

    public init(
        windowListHydrated: Bool = false,
        activeWindow: ActiveWindow? = nil,
        localSize: TmuxGridSize? = nil,
        policy: WindowSizePolicy? = nil,
        owned: TmuxOwnedSizeHistory = .init()
    ) {
        self.windowListHydrated = windowListHydrated
        self.activeWindow = activeWindow
        self.localSize = localSize
        self.policy = policy
        self.owned = owned
    }

    /// The window tmux names active, when it may be judged: hydrated and
    /// authoritative.
    public var judgedWindow: ActiveWindow? {
        guard windowListHydrated, let activeWindow, activeWindow.authoritative else { return nil }
        return activeWindow
    }

    /// The probed policy of `windowID`, or nil when that window was not
    /// probed (a policy probed for another window says nothing about it).
    public func policy(for windowID: Int) -> WindowSizePolicy? {
        guard let policy, policy.windowID == windowID else { return nil }
        return policy
    }

    /// Geometry evidence for an own-stamp read, in this order:
    ///
    /// 1. the judged window at the local size: `atLocalSize`;
    /// 2. at any recently owned size, not only the newest: `atLastOwnedSize`;
    /// 3. a mismatch under a probed `latest`: `foreignSize`;
    /// 4. a mismatch under any other probed policy: `atLocalSize` (tmux
    ///    sized it by its own rule);
    /// 5. otherwise nil: not known yet, hold the reply.
    ///
    /// `final` (the hold's safety bound, or a reply nothing is held for)
    /// answers `unknown` instead of nil: without a judged window, a layout
    /// or a viewport, and for a mismatch whose policy never arrived (M5).
    /// Only a known `latest` makes a mismatch positive evidence of another
    /// sizer, and the reducer keeps an own stamp `.mine` on an unknown read
    /// with no intent.
    public func classify(final: Bool) -> TmuxGridAuthorityLifecycleReducer.QueryGeometry? {
        guard let window = judgedWindow,
              let windowSize = window.size,
              let localSize
        else { return final ? .unknown : nil }
        if windowSize == localSize { return .atLocalSize }
        if owned.contains(windowSize) { return .atLastOwnedSize }
        if let policy = policy(for: window.id) {
            return policy.isLatest ? .foreignSize : .atLocalSize
        }
        return final ? .unknown : nil
    }

    /// Whether the judged window already has the local grid. False when
    /// either is unknown.
    public var judgedWindowMatchesLocalSize: Bool {
        guard let size = judgedWindow?.size, let localSize else { return false }
        return size == localSize
    }
}

extension TmuxAuthorityGeometryEvidence {
    /// What a snapshot says about the window this device renders, in the
    /// shape `windowFacts` reports it: whether the window list is hydrated,
    /// and the active window with its visible grid and whether tmux named it.
    /// Android's adapter and its runtime feed derive it alike (§6.18).
    public struct WindowFacts: Equatable, Sendable {
        public var hydrated: Bool
        public var activeWindow: ActiveWindow?

        public init(hydrated: Bool, activeWindow: ActiveWindow?) {
            self.hydrated = hydrated
            self.activeWindow = activeWindow
        }

        public init(of snapshot: TmuxSnapshot) {
            let window = snapshot.activeWindowID.flatMap { id in snapshot.windows.first { $0.id == id } }
            self.init(
                hydrated: snapshot.isWindowListHydrated,
                activeWindow: window.map { window in
                    ActiveWindow(
                        id: window.id.rawValue,
                        size: (window.visibleLayout ?? window.layout).map {
                            TmuxGridSize(columns: $0.root.rect.width, rows: $0.root.rect.height)
                        },
                        authoritative: snapshot.isActiveWindowAuthoritative
                    )
                }
            )
        }
    }

    /// The window facts last reported.
    public var windowFacts: WindowFacts {
        WindowFacts(hydrated: windowListHydrated, activeWindow: activeWindow)
    }
}
