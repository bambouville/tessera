/// Output routing decision made by the portable runtime before an Apple or
/// Android terminal adapter paints bytes.
public struct TmuxPaneOutput: Equatable, Sendable {
    public let paneID: PaneId
    public let bytes: [UInt8]
    public let ageMilliseconds: Int?

    public init(paneID: PaneId, bytes: [UInt8], ageMilliseconds: Int? = nil) {
        self.paneID = paneID
        self.bytes = bytes
        self.ageMilliseconds = ageMilliseconds
    }
}

public struct TmuxBellEvent: Equatable, Sendable {
    public let windowID: WindowId
    public let isActiveWindow: Bool
    public let windowName: String?

    public init(windowID: WindowId, isActiveWindow: Bool, windowName: String?) {
        self.windowID = windowID
        self.isActiveWindow = isActiveWindow
        self.windowName = windowName
    }
}

public enum TmuxBellSubscription {
    public static let name = "tessera-bell"
}

/// One `@tessera_agent_state` payload observed on the pane-metadata feed.
///
/// The remote lifecycle hook publishes each event twice: as an OSC on the
/// pane's own tty, and as this tmux pane option. Only the option reaches a
/// pane the client is not painting, so this is the sole lifecycle source for
/// an agent running in a window the user is not currently looking at — which
/// is most of them. A client that reads lifecycle exclusively from rendered
/// output sees an empty Agent Center on a session full of working agents.
public struct TmuxPaneAgentState: Equatable, Sendable {
    public let windowID: WindowId
    public let paneID: PaneId
    /// The hook's own JSON, unparsed. Provider state is not this layer's
    /// business; the bound is the transport's.
    public let json: String

    public init(windowID: WindowId, paneID: PaneId, json: String) {
        self.windowID = windowID
        self.paneID = paneID
        self.json = json
    }

    /// Matches the lifecycle-frame ceiling the OSC transport already enforces,
    /// so neither carrier can admit a payload the other would drop.
    public static let maximumJSONBytes = 12 * 1024
}

public struct TmuxRuntimeBatch: Sendable {
    /// Parser and response-framing events in their original wire order. A
    /// platform adapter consumes this stream for side effects, while the
    /// portable runtime remains the only owner of `%begin`/`%end` framing.
    public enum OrderedEvent: Equatable, Sendable {
        case message(TmuxMessage)
        case correlation(TmuxCorrelationEvent)
    }

    /// One parser/correlation event paired with the topology that existed
    /// immediately after that event was applied. A socket read may contain
    /// several identity transitions, so consumers must not reduce every event
    /// against the batch's final snapshot.
    public struct OrderedStep: Equatable, Sendable {
        public let event: OrderedEvent
        public let snapshot: TmuxSnapshot
        public let isActiveWindowAuthoritative: Bool
        /// The raw authority edge this step added to `authorityStamps`, if
        /// any, so a consumer can reduce it at its place in the read.
        public let authorityStamp: String?

        public init(
            event: OrderedEvent,
            snapshot: TmuxSnapshot,
            isActiveWindowAuthoritative: Bool,
            authorityStamp: String? = nil
        ) {
            self.event = event
            self.snapshot = snapshot
            self.isActiveWindowAuthoritative = isActiveWindowAuthoritative
            self.authorityStamp = authorityStamp
        }
    }

    public let messages: [TmuxMessage]
    public let paneOutputs: [TmuxPaneOutput]
    public let bells: [TmuxBellEvent]
    /// Pane lifecycle payloads observed in this read, in wire order.
    public let agentStates: [TmuxPaneAgentState]
    /// Raw authority subscription edges in arrival order, drained once per read.
    public var authorityStamps: [String]
    public let correlationEvents: [TmuxCorrelationEvent]
    public let orderedEvents: [OrderedEvent]
    public let orderedSteps: [OrderedStep]
    public let snapshot: TmuxSnapshot

    public init(
        messages: [TmuxMessage],
        paneOutputs: [TmuxPaneOutput],
        bells: [TmuxBellEvent] = [],
        agentStates: [TmuxPaneAgentState] = [],
        authorityStamps: [String] = [],
        correlationEvents: [TmuxCorrelationEvent],
        orderedEvents: [OrderedEvent]? = nil,
        orderedSteps: [OrderedStep]? = nil,
        snapshot: TmuxSnapshot
    ) {
        self.messages = messages
        self.paneOutputs = paneOutputs
        self.bells = bells
        self.agentStates = agentStates
        self.authorityStamps = authorityStamps
        self.correlationEvents = correlationEvents
        let events = orderedEvents ?? messages.map(OrderedEvent.message)
        self.orderedEvents = events
        self.orderedSteps = orderedSteps ?? events.map {
            OrderedStep(
                event: $0,
                snapshot: snapshot,
                isActiveWindowAuthoritative: false
            )
        }
        self.snapshot = snapshot
    }
}

/// One decoded `windowDetailsCommand` reply.
public struct TmuxWindowDetails: Equatable, Sendable {
    public let window: TmuxWindowSnapshot
    /// The unparsed `#{window_layout}` / `#{window_visible_layout}` text. An
    /// adapter that still owns a layout pipeline of its own needs the raw
    /// string a `%layout-change` would have carried, not only the shared parse.
    public let rawLayout: String?
    public let rawVisibleLayout: String?

    public init(window: TmuxWindowSnapshot, rawLayout: String?, rawVisibleLayout: String?) {
        self.window = window
        self.rawLayout = rawLayout
        self.rawVisibleLayout = rawVisibleLayout
    }
}

/// Tagged, fixed-format queries whose replies are ingested by `TmuxRuntimeEngine`.
/// Platform adapters only transport these strings; topology parsing remains shared.
public enum TmuxRuntimeHydrationQuery {
    private static let windowsTag = "__tessera_windows__"
    private static let panesTag = "__tessera_panes__"
    private static let activeWindowTag = "__tessera_active_window__"
    private static let activePaneTag = "__tessera_active_pane__"
    private static let windowDetailsTag = "__tessera_window_details__"

    /// See `TmuxPaneMetadataSubscription`: a tab inside a value is not escaped
    /// by tmux and would shift every later field, so free text is stripped of
    /// tabs by tmux itself before it reaches the wire.
    private static func tabSafe(_ variable: String) -> String {
        "#{s/\t/ /:\(variable)}"
    }

    /// Session-scoped active-window query used both during hydration and as a
    /// causal fence after a platform adapter selects a window. Keeping the
    /// tag in the portable owner means the correlated reply updates the shared
    /// snapshot before the platform completion is delivered.
    public static let activeWindowCommand =
        "display-message -p '\(activeWindowTag)\t#{window_id}\t#{version}'"

    /// Window-targeted pane query used as the causal fence before a
    /// side-channel adapter moves the separately attached visible Mosh client.
    /// It is deliberately not part of the startup hydration batch; it updates
    /// only a known window/pane pair selected by a user command.
    public static func activePaneCommand(windowID: WindowId) -> String {
        "display-message -p -t \(windowID.description) "
            + "'\(activePaneTag)\t#{window_id}\t#{pane_id}'"
    }

    /// Describe one window tmux announced but never described.
    ///
    /// Creating a window is the single topology transition control mode leaves
    /// half-finished. Captured from a live server, `new-window` emits exactly
    /// `%session-window-changed` followed by `%window-add` — in that order, so
    /// the active id moves before the window exists — and then goes quiet:
    ///
    ///   - `%layout-change` never fires for creation at all. It arrives only on
    ///     a later split or resize, so a window nobody touches keeps a nil
    ///     layout, and therefore no panes, indefinitely.
    ///   - `%window-renamed` does not fire for `new-window -n NAME`, and for a
    ///     default `new-window` only if the shell's automatic-rename happens to
    ///     run.
    ///   - `link-window` / `move-window` can add a window that is already
    ///     split, so "one pane" is not a safe assumption either.
    ///
    /// Verified by pty probe against tmux 3.4 and 3.6. Nothing else in the
    /// notification stream fills these in, so every consumer that resolves "the
    /// active pane of the active window" — the render ledger's surface target
    /// above all — stays blind until this reply lands.
    ///
    /// The row grammar is deliberately the `list-windows` hydration row with a
    /// different tag: same parser, but folded into the one named window instead
    /// of replacing the whole list.
    public static func windowDetailsCommand(windowID: WindowId) -> String {
        "display-message -p -t \(windowID.description) '\(windowDetailsTag)\t\(windowRowFormat)'"
    }

    /// True while tmux has announced this window but not yet described it.
    /// Shared so both platforms ask on the same evidence rather than each
    /// inventing its own idea of "incomplete".
    ///
    /// A window that control mode only announced has all three of these nil at
    /// once. The active pane is deliberately *not* part of the test: an
    /// adapter whose own hydration omits `#{pane_id}` would then re-ask about
    /// every window it just hydrated.
    public static func needsWindowDetails(_ window: TmuxWindowSnapshot) -> Bool {
        window.layout == nil || window.name == nil || window.index == nil
    }

    /// Decode the one tagged row produced by `windowDetailsCommand`.
    ///
    /// Exposed because an adapter may still carry its own window model beside
    /// the shared snapshot; sharing the parser is what stops the two from
    /// disagreeing about a grammar only one of them can see.
    public static func windowDetails(lines: [String]) -> TmuxWindowDetails? {
        for line in lines where hasWindowDetailsTag(line) {
            guard let window = windowRow(line) else { continue }
            let parts = line.split(separator: "\t", maxSplits: 7, omittingEmptySubsequences: false)
            return TmuxWindowDetails(
                window: window,
                rawLayout: parts.count > 4 && !parts[4].isEmpty ? String(parts[4]) : nil,
                rawVisibleLayout: parts.count > 5 && !parts[5].isEmpty ? String(parts[5]) : nil
            )
        }
        return nil
    }

    /// Strict decoder for the correlated full-list reply. Adapters use this
    /// to validate the exact refresh whose completion may confirm optimism;
    /// accepting a partial body here would make a malformed reply authoritative.
    public static func windowList(lines: [String]) -> [TmuxWindowSnapshot]? {
        let rows = lines.filter { !$0.isEmpty }
        guard rows.count <= 512 else { return nil }
        let parsed = rows.compactMap(windowRow)
        guard parsed.count == rows.count,
              TmuxRuntimeEngine.validate(windows: parsed),
              parsed.allSatisfy({ window in
                  window.index.map { (0...1_000_000).contains($0) } ?? false
              })
        else { return nil }
        return parsed
    }

    /// Both adapters use the same acceptance rule for a correlated refresh.
    /// Parsing alone is insufficient if bounds validation rejected ingestion.
    public static func didIngestWindowList(lines: [String], snapshot: TmuxSnapshot) -> Bool {
        guard let parsed = windowList(lines: lines), !parsed.isEmpty,
              snapshot.windows.count == parsed.count else { return false }
        let byID = Dictionary(uniqueKeysWithValues: parsed.map { ($0.id, $0) })
        return snapshot.windows.allSatisfy { byID[$0.id]?.index == $0.index }
    }

    /// The `list-windows` row, in either of its two tagged forms. Field order
    /// is fixed-grammar first and `window_name` LAST, so a tab inside a name
    /// can never shift the columns before it.
    static func windowRow(_ line: String) -> TmuxWindowSnapshot? {
        guard hasWindowsTag(line) || hasWindowDetailsTag(line) else { return nil }
        let parts = line.split(separator: "\t", maxSplits: 7, omittingEmptySubsequences: false)
        guard parts.count >= 7,
              let windowID = WindowId(wireValue: String(parts[1])),
              let index = Int(parts[2])
        else { return nil }
        let activePaneID = PaneId(wireValue: String(parts[3]))
        let layout = WindowLayout.parse(String(parts[4]))
        let visibleLayout = WindowLayout.parse(String(parts[5]))
        // Full layout owns pane membership. A zoomed visible layout contains
        // only the enlarged pane, so using it as membership would delete every
        // hidden pane on an order refresh. Visible geometry overlays matching
        // leaves without changing the full set.
        let membershipLeaves = layout?.leaves ?? visibleLayout?.leaves ?? []
        let membershipIDs = membershipLeaves.map(\.paneId)
        let visibleMembership = visibleLayout?.leaves ?? []
        let visibleIDs = visibleMembership.map(\.paneId)
        guard Set(membershipIDs).count == membershipIDs.count,
              Set(visibleIDs).count == visibleIDs.count
        else { return nil }
        let visibleLeaves = Dictionary(
            uniqueKeysWithValues: visibleMembership.map { ($0.paneId, $0) }
        )
        let panes = membershipLeaves.map { leaf in
            let presentedLeaf = visibleLeaves[leaf.paneId] ?? leaf
            return TmuxPaneSnapshot(
                id: leaf.paneId,
                isActive: leaf.paneId == activePaneID,
                contentRect: presentedLeaf.rect
            )
        }
        let resolvedPanes = panes.isEmpty
            ? activePaneID.map { [TmuxPaneSnapshot(id: $0, isActive: true)] } ?? []
            : panes
        let name = parts.count >= 8 && !parts[7].isEmpty ? String(parts[7]) : nil
        return TmuxWindowSnapshot(
            id: windowID,
            index: index,
            name: name,
            activePaneID: activePaneID,
            panes: resolvedPanes,
            layout: layout,
            visibleLayout: visibleLayout,
            isZoomed: parts[6] == "1"
        )
    }

    private static let windowRowFormat =
        "#{window_id}\t#{window_index}\t#{pane_id}\t#{window_layout}\t"
            + "#{window_visible_layout}\t#{window_zoomed_flag}\t\(tabSafe("window_name"))"

    public static let commands = [
        "list-windows -F '\(windowsTag)\t\(windowRowFormat)'",
        // `#{host}` is what makes `#{pane_title}` legible: tmux's default pane
        // title is the hostname, and a hydration that cannot tell the two apart
        // labels every freshly attached window with the name of the machine.
        "list-panes -s -F '\(panesTag)\t#{window_id}\t#{pane_id}\t#{pane_active}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t\(tabSafe("pane_title"))\t\(tabSafe("pane_current_path"))\t#{host}'",
        activeWindowCommand,
    ]

    /// Accept only the one exact tagged row produced by
    /// `activeWindowCommand`. This is intentionally stricter than the runtime
    /// hydration parser: a platform-side visible-client mutation must not be
    /// authorized by an ambiguous or mixed command body.
    public static func activeWindowMatches(
        _ windowID: WindowId,
        lines: [String]
    ) -> Bool {
        activeWindowID(lines: lines) == windowID
    }

    /// Decode the one canonical row produced by `activeWindowCommand`.
    /// Selection-changing commands such as next/new/close do not know their
    /// resulting target until this causal reply arrives, so the portable core
    /// owns the strict parser as well as the command string.
    public static func activeWindowID(lines: [String]) -> WindowId? {
        activeWindowHydration(lines: lines)?.windowID
    }

    /// Decode the active id and, on current attach queries, the server version.
    /// The two-field legacy row stays accepted for old vectors and callers.
    public static func activeWindowHydration(
        lines: [String]
    ) -> (windowID: WindowId, version: String?)? {
        let rows = lines.filter { !$0.isEmpty }
        guard rows.count == 1 else { return nil }
        let parts = rows[0].split(
            separator: "\t",
            omittingEmptySubsequences: false
        )
        guard (parts.count == 2 || parts.count == 3),
              parts[0] == Substring(activeWindowTag),
              let windowID = WindowId(wireValue: String(parts[1]))
        else { return nil }
        let version = parts.count == 3 && !parts[2].isEmpty ? String(parts[2]) : nil
        return (windowID, version)
    }

    /// Accept only the single exact row emitted by `activePaneCommand`.
    public static func activePaneMatches(
        windowID: WindowId,
        paneID: PaneId,
        lines: [String]
    ) -> Bool {
        lines.filter { !$0.isEmpty } == [
            "\(activePaneTag)\t\(windowID.description)\t\(paneID.description)"
        ]
    }

    fileprivate static func hasWindowsTag(_ line: String) -> Bool {
        line.hasPrefix(windowsTag + "\t")
    }

    fileprivate static func hasWindowDetailsTag(_ line: String) -> Bool {
        line.hasPrefix(windowDetailsTag + "\t")
    }

    fileprivate static func hasPanesTag(_ line: String) -> Bool {
        line.hasPrefix(panesTag + "\t")
    }

    fileprivate static func hasActiveWindowTag(_ line: String) -> Bool {
        line.hasPrefix(activeWindowTag + "\t")
    }

    fileprivate static func hasActivePaneTag(_ line: String) -> Bool {
        line.hasPrefix(activePaneTag + "\t")
    }
}

/// Observation-free production owner for parsing, response framing, topology,
/// pane routing, authority and immutable state publication. Platform adapters
/// perform renderer/network side effects and submit typed, validated results
/// from fixed tmux queries; they never replace the runtime snapshot.
public struct TmuxRuntimeEngine: Sendable {
    private struct PendingOrder: Sendable {
        let token: UInt64
        var order: [WindowId]
        var commandConfirmed = false
    }

    private enum OrderRefreshState: Sendable {
        case idle
        case pending
        case inFlight(dirty: Bool, confirmationToken: UInt64?)
    }

    private struct PaneState: Sendable {
        var id: PaneId
        var title: String?
        var titleIsDefault = false
        var currentCommand: String?
        var currentPath: String?
        var isActive = false
        var isAlternateScreen: Bool?
        var isMouseReporting: Bool?
        var isSgrMouse: Bool?
        var contentRect: CellRect?

        init(_ snapshot: TmuxPaneSnapshot) {
            id = snapshot.id
            title = snapshot.title
            titleIsDefault = snapshot.titleIsDefault
            currentCommand = snapshot.currentCommand
            currentPath = snapshot.currentPath
            isActive = snapshot.isActive
            isAlternateScreen = snapshot.isAlternateScreen
            isMouseReporting = snapshot.isMouseReporting
            isSgrMouse = snapshot.isSgrMouse
            contentRect = snapshot.contentRect
        }

        var snapshot: TmuxPaneSnapshot {
            .init(
                id: id,
                title: title,
                titleIsDefault: titleIsDefault,
                currentCommand: currentCommand,
                currentPath: currentPath,
                isActive: isActive,
                isAlternateScreen: isAlternateScreen,
                isMouseReporting: isMouseReporting,
                isSgrMouse: isSgrMouse,
                contentRect: contentRect
            )
        }
    }

    private struct WindowState: Sendable {
        var id: WindowId
        var index: Int?
        var name: String?
        var activePaneID: PaneId?
        var activePaneTitle: String?
        var activePaneTitleIsDefault = false
        var panes: [PaneId: PaneState] = [:]
        var paneOrder: [PaneId] = []
        var layout: WindowLayout?
        var visibleLayout: WindowLayout?
        var isZoomed = false

        init(id: WindowId) {
            self.id = id
        }

        init(_ snapshot: TmuxWindowSnapshot) {
            id = snapshot.id
            index = snapshot.index
            name = snapshot.name
            activePaneID = snapshot.activePaneID
            activePaneTitle = snapshot.activePaneTitle
            activePaneTitleIsDefault = snapshot.activePaneTitleIsDefault
            layout = snapshot.layout
            visibleLayout = snapshot.visibleLayout
            isZoomed = snapshot.isZoomed
            paneOrder = snapshot.panes.map(\.id)
            panes = Dictionary(
                uniqueKeysWithValues: snapshot.panes.map { ($0.id, PaneState($0)) }
            )
        }

        mutating func ensurePane(_ id: PaneId) {
            guard panes[id] == nil else { return }
            panes[id] = PaneState(.init(id: id, isActive: id == activePaneID))
            paneOrder.append(id)
        }

        mutating func setActivePane(_ id: PaneId?) {
            let changedPane = activePaneID != id
            activePaneID = id
            if let id { ensurePane(id) }
            for paneID in paneOrder {
                panes[paneID]?.isActive = paneID == id
            }
            if changedPane {
                activePaneTitle = id.flatMap { panes[$0]?.title }
                activePaneTitleIsDefault = id.flatMap { panes[$0]?.titleIsDefault } ?? false
            }
        }

        mutating func reconcileLayoutPanes() {
            let ids = layout?.paneIds ?? visibleLayout?.paneIds ?? []
            guard !ids.isEmpty else { return }
            for id in ids { ensurePane(id) }
            paneOrder = ids
            panes = panes.filter { ids.contains($0.key) }
            if let activePaneID, !ids.contains(activePaneID) {
                self.activePaneID = nil
            }
            for paneID in paneOrder {
                panes[paneID]?.isActive = paneID == activePaneID
            }
        }

        var snapshot: TmuxWindowSnapshot {
            .init(
                id: id,
                index: index,
                name: name,
                activePaneID: activePaneID,
                activePaneTitle: activePaneTitle,
                activePaneTitleIsDefault: activePaneTitleIsDefault,
                panes: paneOrder.compactMap { panes[$0]?.snapshot },
                layout: layout,
                visibleLayout: visibleLayout,
                isZoomed: isZoomed
            )
        }
    }

    private var parser = TmuxControlParser()
    private var correlator = TmuxCommandResponseCorrelator()
    private var windows: [WindowId: WindowState] = [:]
    private var windowOrder: [WindowId] = []
    private var capabilities: TmuxWindowCapabilities?
    private var pendingOrder: PendingOrder?
    private var lastAcceptedReorderToken: UInt64 = 0
    private var orderRefreshState: OrderRefreshState = .idle
    private var pendingPaneFocus: [WindowId: PaneId] = [:]
    private var sessionID: SessionId?
    private var sessionName: String?
    private var activeWindowID: WindowId?
    /// Whether `activeWindowID` came from tmux's session-scoped active-window
    /// signal rather than the fail-open first-window fallback. Consumers that
    /// replace a transport-scoped parser must not treat a synthetic fallback
    /// as proof that the replacement connection has rehydrated its topology.
    /// Published as `TmuxSnapshot.isActiveWindowAuthoritative`, so every write
    /// must move the revision like any other published field: a flip that did
    /// not would be served stale by the memo and elided from Android.
    public private(set) var isActiveWindowAuthoritative = false
    /// Session carried by the last `%session-window-changed` that selected the
    /// current window. The notification is broadcast to every control client,
    /// so it is authoritative only after `%session-changed` proves that this
    /// parser belongs to the same session.
    private var activeWindowAuthoritySessionID: SessionId?
    private var provisionalActivePaneID: PaneId?
    /// The shared session's last projection (`projectAuthority`).
    public private(set) var authority: TmuxGridAuthoritySnapshot = .unknown
    /// Raw subscription edges of the read in progress. Authority itself is
    /// only the shared session's projection, never classified here.
    private var pendingAuthorityStamps: [String] = []
    /// The read's last stamp for the current control session. A session
    /// change starts a new one: the new session's first stamp is news even
    /// when it repeats the old session's last.
    private var lastCollapsibleAuthorityStamp: String?
    private var windowBellFlags: [WindowId: Bool] = [:]
    /// Windows tmux has announced but not described, in announcement order.
    /// See `TmuxRuntimeHydrationQuery.windowDetailsCommand(windowID:)`: control
    /// mode says a window exists and then never says what is in it, so the
    /// query has to come from here. The set is drained, not observed, so an
    /// adapter cannot ask twice for the same announcement.
    private var windowsAwaitingDetails: [WindowId] = []
    /// Suppresses the query until the attach-time `list-windows` has answered.
    /// Before that every window is legitimately undescribed and the batch
    /// hydration is already on its way.
    private var hasIngestedWindowList = false
    /// Change token for every field `snapshot` publishes, equal to
    /// `snapshot.revision` without building one. Any mutation of published
    /// state must go through `changed()` (or `reset`), because
    /// `memoizedSnapshot` and the Android ABI's snapshot elision both treat an
    /// unchanged revision as an unchanged snapshot.
    public private(set) var revision: UInt64 = 0
    /// The last snapshot built, reused while `revision` is unchanged.
    /// Building one walks every window and pane, and `feed` needs one per
    /// parsed message so each ordered step carries the topology as of that
    /// step; most messages (`%output` above all) change nothing it publishes.
    /// A plain stored value, so engine copies never share it.
    private var memoizedSnapshot: TmuxSnapshot?
    /// `feed` memoizes per parsed message itself, and one hydration reply can
    /// run a public mutator per window; see `fillSnapshotMemo`.
    private var isFeeding = false
    /// Lifecycle payloads seen since the current `feed` began, drained into
    /// that read's batch. They are carried out of `apply` rather than emitted
    /// from it because a subscription value is applied for its topology first.
    private var pendingPaneAgentStates: [TmuxPaneAgentState] = []
    /// The feeds the adapter wants; kept across `reset`, which a new control
    /// connection triggers, so a reconnect registers them again.
    public var subscriptionRequests = TmuxSubscriptionRequests()
    /// What this control client has asked tmux to register. A new client
    /// starts with nothing, so `reset` clears it.
    private var subscriptionRegistration = TmuxControlSubscriptions.Registration()
    /// Inputs of the last reconciliation, to skip the per-read work when
    /// neither the topology nor the requests moved.
    private var subscriptionsReconciledAt: (revision: UInt64, requests: TmuxSubscriptionRequests)?
    /// Reconciled commands not yet handed out, oldest first. Every drain takes
    /// from here, so commands reach the wire in reconciliation order however
    /// many drains it takes.
    private var queuedSubscriptionCommands: [String] = []

    public init() {}

    public mutating func reset(keepingSnapshot: Bool = false) {
        defer { fillSnapshotMemo() }
        let resetPublishedOrderingState = pendingOrder != nil || capabilities != nil || hasIngestedWindowList
        parser.reset()
        correlator.reset()
        pendingPaneAgentStates.removeAll(keepingCapacity: true)
        subscriptionRegistration = .init()
        subscriptionsReconciledAt = nil
        queuedSubscriptionCommands = []
        pendingAuthorityStamps.removeAll(keepingCapacity: true)
        lastCollapsibleAuthorityStamp = nil
        pendingOrder = nil
        orderRefreshState = .idle
        capabilities = nil
        hasIngestedWindowList = false
        guard !keepingSnapshot else {
            if resetPublishedOrderingState { changed() }
            return
        }
        windows.removeAll(keepingCapacity: true)
        windowOrder.removeAll(keepingCapacity: true)
        pendingPaneFocus.removeAll(keepingCapacity: true)
        windowBellFlags.removeAll(keepingCapacity: true)
        windowsAwaitingDetails.removeAll(keepingCapacity: true)
        hasIngestedWindowList = false
        sessionID = nil
        sessionName = nil
        activeWindowID = nil
        isActiveWindowAuthoritative = false
        activeWindowAuthoritySessionID = nil
        provisionalActivePaneID = nil
        revision &+= 1
    }

    @discardableResult
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> TmuxRuntimeBatch {
        isFeeding = true
        defer { isFeeding = false }
        let messages = parser.feed(bytes)
        pendingPaneAgentStates.removeAll(keepingCapacity: true)
        var outputs: [TmuxPaneOutput] = []
        var bells: [TmuxBellEvent] = []
        var correlationEvents: [TmuxCorrelationEvent] = []
        var orderedEvents: [TmuxRuntimeBatch.OrderedEvent] = []
        var orderedSteps: [TmuxRuntimeBatch.OrderedStep] = []
        for message in messages {
            let stampCount = pendingAuthorityStamps.count
            let orderedEvent: TmuxRuntimeBatch.OrderedEvent
            if let event = correlator.consume(message) {
                if case .frameCompleted(let frame) = event,
                   frame.status == .success,
                   frame.isClientResponse {
                    ingestHydrationFrame(frame.lines)
                }
                correlationEvents.append(event)
                orderedEvent = .correlation(event)
            } else {
                orderedEvent = .message(message)
            }
            switch message {
            case .output(let paneID, let bytes):
                outputs.append(.init(paneID: paneID, bytes: bytes))
            case .extendedOutput(let paneID, let age, let bytes):
                outputs.append(.init(paneID: paneID, bytes: bytes, ageMilliseconds: age))
            case .bell(let rawPaneID):
                bellEvent(for: PaneId(rawPaneID)).map { bells.append($0) }
            case .subscriptionChanged(let name, let eventSessionID, let windowID, _, _, let value)
                where TmuxControlSubscriptions.name(name, isFeed: TmuxBellSubscription.name):
                if sessionID == nil || sessionID == eventSessionID,
                   let bell = ingestBellSubscription(windowID: windowID, value: value) {
                    bells.append(bell)
                }
            default:
                apply(message)
            }
            orderedEvents.append(orderedEvent)
            orderedSteps.append(.init(
                event: orderedEvent,
                snapshot: memoizingSnapshot(),
                isActiveWindowAuthoritative: isActiveWindowAuthoritative,
                authorityStamp: pendingAuthorityStamps.count > stampCount ? pendingAuthorityStamps.last : nil
            ))
        }
        // Move the one-shot list out rather than clear a shared buffer on
        // the next feed. An output-only read never allocates a stamp buffer.
        let authorityStamps = pendingAuthorityStamps
        pendingAuthorityStamps = []
        lastCollapsibleAuthorityStamp = nil
        return .init(
            messages: messages,
            paneOutputs: outputs,
            bells: bells,
            agentStates: pendingPaneAgentStates,
            authorityStamps: authorityStamps,
            correlationEvents: correlationEvents,
            orderedEvents: orderedEvents,
            orderedSteps: orderedSteps,
            snapshot: memoizingSnapshot()
        )
    }

    /// `snapshot`, rebuilt only when the revision moved since the last build.
    private mutating func memoizingSnapshot() -> TmuxSnapshot {
        if let memoizedSnapshot, memoizedSnapshot.revision == revision {
            return memoizedSnapshot
        }
        let built = buildSnapshot()
        memoizedSnapshot = built
        return built
    }

    /// Run as each public mutator returns. `snapshot` cannot fill the memo
    /// (it is a non-mutating getter), so without this every read after a
    /// mutation outside `feed` rebuilt the snapshot until the next `feed`,
    /// and adapters read it several times per mutation. Deferred to the end
    /// of the mutator, never done inside `changed()`: a snapshot built
    /// mid-mutation would carry the final revision with stale fields.
    private mutating func fillSnapshotMemo() {
        guard !isFeeding else { return }
        _ = memoizingSnapshot()
    }

    /// Reapply one topology notification after a legacy adapter callback has
    /// published query results while consuming an already-parsed socket read.
    /// Output, bells, command framing, and subscriptions are never replayed.
    @discardableResult
    public mutating func replayTopologyNotification(_ message: TmuxMessage) -> Bool {
        defer { fillSnapshotMemo() }
        switch message {
        case .windowAdd, .windowClose, .unlinkedWindowClose,
             .windowRenamed, .windowPaneChanged, .layoutChange,
             .sessionChanged, .sessionRenamed, .sessionWindowChanged:
            apply(message)
            return true
        default:
            return false
        }
    }

    private func bellEvent(for paneID: PaneId) -> TmuxBellEvent? {
        guard let windowID = windowOrder.first(where: { windows[$0]?.panes[paneID] != nil }),
              let window = windows[windowID]
        else { return nil }
        return .init(
            windowID: windowID,
            isActiveWindow: windowID == activeWindowID,
            windowName: window.name
        )
    }

    private mutating func ingestBellSubscription(windowID: WindowId, value: String) -> TmuxBellEvent? {
        let isSet = value.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        let previous = windowBellFlags.updateValue(isSet, forKey: windowID)
        guard let previous, !previous, isSet, windowID != activeWindowID else { return nil }
        return .init(
            windowID: windowID,
            isActiveWindow: false,
            windowName: windows[windowID]?.name
        )
    }

    /// Project the shared session's verdict for consumers such as the render
    /// ledger. Equal projections cost no revision or snapshot rebuild.
    @discardableResult
    public mutating func projectAuthority(_ authority: TmuxGridAuthoritySnapshot) -> Bool {
        guard self.authority != authority else { return false }
        self.authority = authority
        changed()
        fillSnapshotMemo()
        return true
    }

    /// Fold one live pane-metadata subscription payload into the window model.
    ///
    /// Carries labels, foreground commands, the live working directory used by
    /// Remote Files, and each pane's alternate-screen and mouse modes. Geometry
    /// and agent state stay with whichever adapter already owns them.
    private mutating func ingestPaneMetadata(_ update: TmuxPaneMetadataUpdate) {
        guard var window = windows[update.windowID] else { return }
        var didChange = false
        if let windowName = update.windowName, window.name != windowName {
            window.name = windowName
            didChange = true
        }
        if var pane = window.panes[update.paneID] {
            if let currentCommand = update.currentCommand, pane.currentCommand != currentCommand {
                pane.currentCommand = currentCommand
                didChange = true
            }
            let titleIsDefault = update.paneTitle != nil && update.paneTitleIsDefault
            if pane.title != update.paneTitle || pane.titleIsDefault != titleIsDefault {
                pane.title = update.paneTitle
                pane.titleIsDefault = titleIsDefault
                didChange = true
            }
            // A shell can cd without changing its title or window name. The
            // initial list-panes path is only a snapshot: publish directory-only
            // updates too, including nil when the server can no longer resolve it.
            if pane.currentPath != update.currentPath {
                pane.currentPath = update.currentPath
                didChange = true
            }
            // The live source of a pane's interaction modes. A payload from a
            // server that predates the fields leaves the probed values alone.
            if let isAlternateScreen = update.isAlternateScreen,
               pane.isAlternateScreen != isAlternateScreen {
                pane.isAlternateScreen = isAlternateScreen
                didChange = true
            }
            if let isMouseReporting = update.isMouseReporting,
               pane.isMouseReporting != isMouseReporting {
                pane.isMouseReporting = isMouseReporting
                didChange = true
            }
            if let isSgrMouse = update.isSgrMouse, pane.isSgrMouse != isSgrMouse {
                pane.isSgrMouse = isSgrMouse
                didChange = true
            }
            window.panes[update.paneID] = pane
        }
        // Only the active pane names the window. tmux fans this subscription
        // out over every pane, so a background pane's title must not relabel
        // the tab the user is looking at.
        if update.isActive || window.activePaneID == update.paneID {
            let titleIsDefault = update.paneTitle != nil && update.paneTitleIsDefault
            if window.activePaneTitle != update.paneTitle
                || window.activePaneTitleIsDefault != titleIsDefault {
                window.activePaneTitle = update.paneTitle
                window.activePaneTitleIsDefault = titleIsDefault
                didChange = true
            }
        }
        guard didChange else { return }
        windows[update.windowID] = window
        changed()
    }

    /// Replace only the topology returned by the authoritative `list-windows`
    /// fixed query. Session identity, active-window selection and authority
    /// remain owned by their independent protocol transitions.
    @discardableResult
    public mutating func ingestWindowListQuery(
        _ queriedWindows: [TmuxWindowSnapshot]
    ) -> Bool {
        defer { fillSnapshotMemo() }
        guard Self.validate(windows: queriedWindows) else { return false }
        let previousWindows = windows
        windows = Dictionary(
            uniqueKeysWithValues: queriedWindows.map { queried in
                let replacement = Self.windowListState(queried, preserving: previousWindows[queried.id])
                return (queried.id, replacement)
            }
        )
        windowOrder = queriedWindows.map(\.id)
        pendingPaneFocus.removeAll(keepingCapacity: true)
        // Everything the list described is described; anything still queued
        // predates this authoritative answer.
        windowsAwaitingDetails.removeAll(keepingCapacity: true)
        hasIngestedWindowList = true
        if let activeWindowID, windows[activeWindowID] == nil {
            self.activeWindowID = nil
            isActiveWindowAuthoritative = false
            activeWindowAuthoritySessionID = nil
        }
        changed()
        return true
    }

    private static func windowListState(_ queried: TmuxWindowSnapshot, preserving previous: WindowState?) -> WindowState {
        var replacement = WindowState(queried)
        if let previous = previous {
            for paneID in replacement.paneOrder {
                guard var pane = replacement.panes[paneID],
                      let retained = previous.panes[paneID]
                else { continue }
                pane.title = retained.title
                pane.titleIsDefault = retained.titleIsDefault
                pane.currentCommand = retained.currentCommand
                pane.currentPath = retained.currentPath
                pane.isAlternateScreen = retained.isAlternateScreen
                pane.isMouseReporting = retained.isMouseReporting
                pane.isSgrMouse = retained.isSgrMouse
                replacement.panes[paneID] = pane
            }
            if replacement.activePaneID == previous.activePaneID {
                replacement.activePaneTitle = previous.activePaneTitle
                replacement.activePaneTitleIsDefault = previous.activePaneTitleIsDefault
            } else if let activePaneID = replacement.activePaneID,
                      let activePane = replacement.panes[activePaneID] {
                replacement.activePaneTitle = activePane.title
                replacement.activePaneTitleIsDefault = activePane.titleIsDefault
            }
        }
        return replacement
    }

    /// Ingest one typed fixed-query or metadata-subscription result. This is
    /// deliberately narrower than snapshot replacement and validates every
    /// identifier, string and geometry bound before mutating production state.
    @discardableResult
    public mutating func ingestWindowMetadata(
        _ queriedWindow: TmuxWindowSnapshot
    ) -> Bool {
        defer { fillSnapshotMemo() }
        guard Self.validate(window: queriedWindow) else { return false }
        if windows[queriedWindow.id] == nil {
            windowOrder.append(queriedWindow.id)
            windows[queriedWindow.id] = WindowState(queriedWindow)
        } else if var state = windows[queriedWindow.id] {
            state.index = queriedWindow.index ?? state.index
            state.name = queriedWindow.name ?? state.name
            if let activePaneID = queriedWindow.activePaneID {
                state.setActivePane(activePaneID)
            }
            state.activePaneTitle = queriedWindow.activePaneTitle
            state.activePaneTitleIsDefault = queriedWindow.activePaneTitleIsDefault
            if !queriedWindow.panes.isEmpty {
                let previous = state.panes
                state.panes = Dictionary(
                    uniqueKeysWithValues: queriedWindow.panes.map { queried in
                        var pane = PaneState(queried)
                        // Hydration queries do not ask for interaction modes;
                        // keep what the metadata subscription already said, as
                        // a quiet full-screen pane may never report again.
                        if let retained = previous[queried.id] {
                            pane.isAlternateScreen = pane.isAlternateScreen ?? retained.isAlternateScreen
                            pane.isMouseReporting = pane.isMouseReporting ?? retained.isMouseReporting
                            pane.isSgrMouse = pane.isSgrMouse ?? retained.isSgrMouse
                        }
                        return (queried.id, pane)
                    }
                )
                state.paneOrder = queriedWindow.panes.map(\.id)
            }
            if let layout = queriedWindow.layout {
                state.layout = layout
            }
            if let visibleLayout = queriedWindow.visibleLayout {
                state.visibleLayout = visibleLayout
            }
            if queriedWindow.layout != nil || queriedWindow.visibleLayout != nil {
                state.isZoomed = queriedWindow.isZoomed
                state.reconcileLayoutPanes()
            }
            windows[queriedWindow.id] = state
        }
        sortWindowOrder()
        changed()
        return true
    }

    @discardableResult
    public mutating func ingestActiveWindowQuery(_ windowID: WindowId) -> Bool {
        defer { fillSnapshotMemo() }
        guard windows[windowID] != nil else { return false }
        activeWindowID = windowID
        isActiveWindowAuthoritative = true
        activeWindowAuthoritySessionID = sessionID
        if windows[windowID]?.activePaneID == nil, let provisionalActivePaneID {
            windows[windowID]?.setActivePane(provisionalActivePaneID)
        }
        provisionalActivePaneID = nil
        changed()
        return true
    }

    /// Merge adapter-owned presentation fields without publishing its possibly
    /// older topology back into the wire owner. A platform consumes ordered
    /// callbacks after `feed` has already reduced the entire socket read.
    /// Titles and renderer flags must not undo a later split, close, or focus.
    @discardableResult
    public mutating func ingestWindowPresentation(_ metadata: TmuxWindowSnapshot) -> Bool {
        defer { fillSnapshotMemo() }
        guard Self.validate(window: metadata), var state = windows[metadata.id] else { return false }
        // Legacy capture/first-output discovery may identify an as-yet unnamed
        // pane. It can fill that gap, but cannot replace notification-owned
        // focus or resurrect a pane excluded by the authoritative layout.
        if state.activePaneID == nil, let paneID = metadata.activePaneID,
           state.layout == nil || state.layout?.paneIds.contains(paneID) == true {
            state.setActivePane(paneID)
        }
        state.index = metadata.index ?? state.index
        state.name = metadata.name ?? state.name
        for pane in metadata.panes {
            guard var existing = state.panes[pane.id] else { continue }
            existing.title = pane.title
            existing.titleIsDefault = pane.titleIsDefault
            existing.currentCommand = pane.currentCommand
            existing.isAlternateScreen = pane.isAlternateScreen
            existing.isMouseReporting = pane.isMouseReporting
            existing.isSgrMouse = pane.isSgrMouse
            existing.contentRect = pane.contentRect ?? existing.contentRect
            state.panes[pane.id] = existing
        }
        if state.activePaneID == metadata.activePaneID {
            state.activePaneTitle = metadata.activePaneTitle
            state.activePaneTitleIsDefault = metadata.activePaneTitleIsDefault
        }
        windows[metadata.id] = state
        changed()
        return true
    }

    @discardableResult
    public mutating func ingestActivePaneQuery(
        windowID: WindowId,
        paneID: PaneId
    ) -> Bool {
        defer { fillSnapshotMemo() }
        guard var window = windows[windowID],
              window.panes[paneID] != nil
                || window.layout?.paneIds.contains(paneID) == true
                || window.visibleLayout?.paneIds.contains(paneID) == true
        else { return false }
        window.setActivePane(paneID)
        windows[windowID] = window
        changed()
        return true
    }

    /// Fail-open routing latch used only before tmux has identified a window.
    /// It keeps early pane output routing core-owned without manufacturing a
    /// phantom topology entry.
    public mutating func ingestProvisionalActivePane(_ paneID: PaneId) {
        defer { fillSnapshotMemo() }
        provisionalActivePaneID = paneID
        changed()
    }

    public var activeRoutingPaneID: PaneId? {
        activeWindowID.flatMap { windows[$0]?.activePaneID }
            ?? provisionalActivePaneID
    }

    public var snapshot: TmuxSnapshot {
        if let memoizedSnapshot, memoizedSnapshot.revision == revision {
            return memoizedSnapshot
        }
        return buildSnapshot()
    }

    /// Whether `snapshot` is served without a rebuild. Internal, for tests.
    var servesSnapshotFromMemo: Bool { memoizedSnapshot?.revision == revision }

    /// The snapshot assembled from live state, bypassing the memo. Internal so
    /// tests can prove the memo never serves a stale value.
    func buildSnapshot() -> TmuxSnapshot {
        let publishedOrder: [WindowId]
        if let pendingOrder {
            let knownPending = pendingOrder.order.filter { windows[$0] != nil }
            let retained = Set(knownPending)
            publishedOrder = knownPending + windowOrder.filter {
                windows[$0] != nil && !retained.contains($0)
            }
        } else {
            publishedOrder = windowOrder
        }
        return .init(
            sessionID: sessionID,
            sessionName: sessionName,
            activeWindowID: activeWindowID,
            isActiveWindowAuthoritative: isActiveWindowAuthoritative,
            windows: publishedOrder.compactMap { windows[$0]?.snapshot },
            authority: authority,
            capabilities: capabilities,
            isReorderPending: pendingOrder != nil,
            authoritativeWindowOrder: windowOrder,
            isWindowListHydrated: hasIngestedWindowList,
            revision: revision
        )
    }

    /// Begin one optimistic reorder. Only one mutation may be outstanding and
    /// the expected order must be a complete permutation of known topology.
    public mutating func beginReorder(expecting order: [WindowId]) -> UInt64? {
        guard lastAcceptedReorderToken < UInt64.max else { return nil }
        let token = lastAcceptedReorderToken + 1
        guard beginReorder(token: token, expecting: order) else { return nil }
        return token
    }

    /// Token-supplied twin used by the existing stateful ABI fact channel.
    @discardableResult
    public mutating func beginReorder(token: UInt64, expecting order: [WindowId]) -> Bool {
        defer { fillSnapshotMemo() }
        guard hasIngestedWindowList, token != 0,
              token > lastAcceptedReorderToken,
              pendingOrder == nil,
              order.count <= 512,
              Set(order).count == order.count,
              Set(order) == Set(windowOrder)
        else { return false }
        lastAcceptedReorderToken = token
        pendingOrder = .init(token: token, order: order)
        changed()
        return true
    }

    /// A successful mutation ACK requests truth but does not confirm order.
    /// tmux may have concurrently reassigned indexes before this reply.
    @discardableResult
    public mutating func confirmReorder(token: UInt64) -> Bool {
        guard pendingOrder?.token == token else { return false }
        pendingOrder?.commandConfirmed = true
        scheduleOrderRefresh()
        return true
    }

    /// Used for a command error, disconnect, or the adapter's five-second
    /// deadline. Unrelated protocol input never advances that deadline.
    @discardableResult
    public mutating func abandonReorder(token: UInt64) -> Bool {
        defer { fillSnapshotMemo() }
        guard pendingOrder?.token == token else { return false }
        pendingOrder = nil
        scheduleOrderRefresh()
        changed()
        return true
    }

    /// Fold one parsed session-scoped subscription value into existing window
    /// objects. Panes, layouts, active selection, and rendering ownership stay
    /// intact; the subscription changes indexes and ordering only.
    @discardableResult
    public mutating func ingestWindowOrderSubscription(
        _ value: String,
        sessionID eventSessionID: SessionId
    ) -> Bool {
        defer { fillSnapshotMemo() }
        guard sessionID == nil || sessionID == eventSessionID else { return false }
        guard let entries = TmuxWindowOrderSubscription.parse(value) else {
            scheduleOrderRefresh()
            return false
        }
        let ids = entries.map(\.id)
        guard Set(ids) == Set(windowOrder) else {
            scheduleOrderRefresh()
            return false
        }
        for entry in entries { windows[entry.id]?.index = entry.index }
        windowOrder = ids
        changed()
        return true
    }

    /// Drain a coalesced authoritative order query. While it is in flight,
    /// further relinks collapse into one dirty follow-up.
    public mutating func takePendingOrderRefreshCommand() -> String? {
        guard case .pending = orderRefreshState else { return nil }
        let confirmationToken = pendingOrder.flatMap {
            $0.commandConfirmed ? $0.token : nil
        }
        orderRefreshState = .inFlight(
            dirty: false,
            confirmationToken: confirmationToken
        )
        return TmuxRuntimeHydrationQuery.commands[0]
    }

    /// Release an in-flight refresh when the adapter observes the completion
    /// correlated to the command returned above. Call this after feeding a
    /// successful reply, so its list rows are already the underlying truth.
    public mutating func completeOrderRefresh(succeeded: Bool) {
        defer { fillSnapshotMemo() }
        guard case .inFlight(let dirty, let confirmationToken) = orderRefreshState else { return }
        if succeeded,
           let confirmationToken,
           pendingOrder?.token == confirmationToken,
           pendingOrder?.commandConfirmed == true {
            pendingOrder = nil
            changed()
        }
        orderRefreshState = dirty ? .pending : .idle
    }

    /// Queue a window whose contents tmux has never described. Deliberately
    /// silent until the attach-time `list-windows` has answered: before that
    /// every window is legitimately blank and the batch hydration already
    /// covers them.
    private mutating func noteWindowAnnounced(_ id: WindowId) {
        guard hasIngestedWindowList,
              let window = windows[id]?.snapshot,
              TmuxRuntimeHydrationQuery.needsWindowDetails(window),
              !windowsAwaitingDetails.contains(id)
        else { return }
        windowsAwaitingDetails.append(id)
    }

    /// Fixed queries the adapter must put on the control channel so the shared
    /// topology can finish describing windows tmux only announced. Draining is
    /// destructive so a window is asked about once per announcement; a window
    /// that has since been described, or closed, yields nothing.
    ///
    /// Replies need no adapter parsing: they carry the shared tag and are
    /// folded back through the same hydration path as every other fixed query.
    public mutating func takePendingWindowDetailQueries() -> [String] {
        guard !windowsAwaitingDetails.isEmpty else { return [] }
        let announced = windowsAwaitingDetails
        windowsAwaitingDetails.removeAll(keepingCapacity: true)
        return announced.compactMap { id in
            guard let window = windows[id]?.snapshot,
                  TmuxRuntimeHydrationQuery.needsWindowDetails(window)
            else { return nil }
            return TmuxRuntimeHydrationQuery.windowDetailsCommand(windowID: id)
        }
    }

    /// `refresh-client -B` commands that register `subscriptionRequests` for
    /// the windows and panes the topology holds and drop what closed ones
    /// left behind.
    /// Draining is destructive: each change is returned once, and a client
    /// that loses the connection starts again from `reset`.
    ///
    /// Nothing is registered until this connection's `list-windows` has
    /// answered: before that the panes are the last connection's, or none.
    ///
    /// `maximumBytes` bounds one drain for an adapter whose envelopes have a
    /// size ceiling; registrations grow with the pane count. The rest stays
    /// queued for the next drain, ahead of anything reconciled later. At
    /// least one command is returned when any is pending.
    public mutating func takePendingSubscriptionCommands(maximumBytes: Int = .max) -> [String] {
        if hasIngestedWindowList, subscriptionsReconciledAt.map({
            $0.revision != revision || $0.requests != subscriptionRequests
        }) ?? true {
            subscriptionsReconciledAt = (revision, subscriptionRequests)
            queuedSubscriptionCommands += TmuxControlSubscriptions.reconcile(
                &subscriptionRegistration,
                requests: subscriptionRequests,
                windows: windowOrder,
                panes: windowOrder.flatMap { windows[$0]?.paneOrder ?? [] },
                supportsSubscriptions: capabilities?.supportsSubscriptions
            )
        }
        var count = 0
        var bytes = 0
        for command in queuedSubscriptionCommands {
            guard count == 0 || bytes + command.utf8.count <= maximumBytes else { break }
            bytes += command.utf8.count
            count += 1
        }
        defer { queuedSubscriptionCommands.removeFirst(count) }
        return Array(queuedSubscriptionCommands.prefix(count))
    }

    private mutating func ensureWindow(_ id: WindowId) {
        if windows[id] == nil {
            windows[id] = .init(id: id)
            windowOrder.append(id)
            pendingOrder?.order.append(id)
        }
        if let pending = pendingPaneFocus.removeValue(forKey: id) {
            windows[id]?.setActivePane(pending)
        }
    }

    private mutating func sortWindowOrder() {
        let positions = Dictionary(uniqueKeysWithValues: windowOrder.enumerated().map { ($1, $0) })
        windowOrder.sort { lhs, rhs in
            let lhsIndex = windows[lhs]?.index ?? Int.max
            let rhsIndex = windows[rhs]?.index ?? Int.max
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            return (positions[lhs] ?? 0) < (positions[rhs] ?? 0)
        }
    }

    private mutating func scheduleOrderRefresh() {
        switch orderRefreshState {
        case .idle:
            orderRefreshState = .pending
        case .pending:
            break
        case .inFlight(_, let confirmationToken):
            orderRefreshState = .inFlight(
                dirty: true,
                confirmationToken: confirmationToken
            )
        }
    }

    static func validate(windows: [TmuxWindowSnapshot]) -> Bool {
        guard windows.count <= 512,
              Set(windows.map(\.id)).count == windows.count
        else { return false }
        return windows.allSatisfy(validate(window:))
    }

    static func validate(window: TmuxWindowSnapshot) -> Bool {
        guard window.index.map({ $0 >= 0 && $0 <= 1_000_000 }) ?? true,
              window.name.map({ $0.utf8.count <= 8_192 }) ?? true,
              window.panes.count <= 512,
              Set(window.panes.map(\.id)).count == window.panes.count
        else { return false }
        for pane in window.panes {
            guard pane.title.map({ $0.utf8.count <= 8_192 }) ?? true,
                  pane.currentCommand.map({ $0.utf8.count <= 8_192 }) ?? true,
                  pane.currentPath.map({ $0.utf8.count <= 8_192 }) ?? true
            else { return false }
            if let rect = pane.contentRect,
               rect.width < 0 || rect.height < 0 || rect.x < 0 || rect.y < 0
                || rect.width > 1_000_000 || rect.height > 1_000_000
                || rect.x > 1_000_000 || rect.y > 1_000_000 {
                return false
            }
        }
        return true
    }

    private mutating func changed() { revision &+= 1 }

    private mutating func ingestHydrationFrame(_ lines: [String]) {
        if lines.contains(where: TmuxRuntimeHydrationQuery.hasWindowsTag) {
            if let queried = TmuxRuntimeHydrationQuery.windowList(lines: lines),
               !queried.isEmpty {
                _ = ingestWindowListQuery(queried)
            } else {
                hasIngestedWindowList = false
                changed()
                // A damaged list is never authoritative membership. Still
                // merge safe metadata for known windows without deleting any.
                for row in lines.prefix(512).compactMap(TmuxRuntimeHydrationQuery.windowRow)
                    where windows[row.id] != nil {
                    guard Self.validate(window: row) else { continue }
                    windows[row.id] = Self.windowListState(row, preserving: windows[row.id])
                    changed()
                }
            }
            return
        }
        // The window-targeted twin describes one window; folding it through the
        // list ingest would delete every window it does not mention.
        if lines.contains(where: TmuxRuntimeHydrationQuery.hasWindowDetailsTag) {
            for queried in lines.compactMap(Self.parseHydratedWindow) {
                windowsAwaitingDetails.removeAll { $0 == queried.id }
                _ = ingestWindowMetadata(queried)
            }
            return
        }
        if lines.contains(where: TmuxRuntimeHydrationQuery.hasPanesTag) {
            let queried = lines.compactMap(Self.parseHydratedPane)
            for (windowID, paneRows) in Dictionary(grouping: queried, by: \.windowID) {
                guard let existing = windows[windowID]?.snapshot else { continue }
                let queriedPanes = paneRows.map(\.pane)
                let activePane = queriedPanes.first(where: \.isActive)?.id ?? existing.activePaneID
                _ = ingestWindowMetadata(TmuxWindowSnapshot(
                    id: existing.id,
                    index: existing.index,
                    name: existing.name,
                    activePaneID: activePane,
                    activePaneTitle: queriedPanes.first(where: \.isActive)?.title,
                    activePaneTitleIsDefault: queriedPanes
                        .first(where: \.isActive)?.titleIsDefault ?? false,
                    panes: queriedPanes,
                    layout: existing.layout,
                    visibleLayout: existing.visibleLayout,
                    isZoomed: existing.isZoomed
                ))
            }
            return
        }
        if let active = TmuxRuntimeHydrationQuery.activeWindowHydration(lines: lines) {
            let queriedCapabilities = TmuxWindowCapabilities.forVersion(active.version ?? "")
            let capabilitiesChanged = capabilities != queriedCapabilities
            capabilities = queriedCapabilities
            // The capabilities are published even when the named window is not
            // known yet, so they need their own revision when nothing else
            // moved it.
            if !ingestActiveWindowQuery(active.windowID), capabilitiesChanged {
                changed()
            }
            return
        }
        guard let line = lines.first(where: TmuxRuntimeHydrationQuery.hasActivePaneTag) else {
            return
        }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let windowID = WindowId(wireValue: String(parts[1])),
              let paneID = PaneId(wireValue: String(parts[2])),
              TmuxRuntimeHydrationQuery.activePaneMatches(
                windowID: windowID,
                paneID: paneID,
                lines: lines
              )
        else { return }
        _ = ingestActivePaneQuery(windowID: windowID, paneID: paneID)
    }

    private static func parseHydratedWindow(_ line: String) -> TmuxWindowSnapshot? {
        TmuxRuntimeHydrationQuery.windowRow(line)
    }

    private struct HydratedPane {
        let windowID: WindowId
        let pane: TmuxPaneSnapshot
    }

    private static func parseHydratedPane(_ line: String) -> HydratedPane? {
        guard TmuxRuntimeHydrationQuery.hasPanesTag(line) else { return nil }
        let parts = line.split(separator: "\t", maxSplits: 10, omittingEmptySubsequences: false)
        guard parts.count >= 8,
              let windowID = WindowId(wireValue: String(parts[1])),
              let paneID = PaneId(wireValue: String(parts[2])),
              let left = Int(parts[4]),
              let top = Int(parts[5]),
              let width = Int(parts[6]),
              let height = Int(parts[7])
        else { return nil }
        let title = parts.count >= 9 && !parts[8].isEmpty ? String(parts[8]) : nil
        let currentPath = parts.count >= 10 && !parts[9].isEmpty ? String(parts[9]) : nil
        let host = parts.count >= 11 && !parts[10].isEmpty ? String(parts[10]) : nil
        return HydratedPane(
            windowID: windowID,
            pane: TmuxPaneSnapshot(
                id: paneID,
                title: title,
                titleIsDefault: title != nil && title == host,
                currentPath: currentPath,
                isActive: parts[3] == "1",
                contentRect: CellRect(width: width, height: height, x: left, y: top)
            )
        )
    }

    private mutating func apply(_ message: TmuxMessage) {
        switch message {
        case .windowAdd(let id):
            ensureWindow(id)
            if activeWindowID == nil {
                activeWindowID = id
                isActiveWindowAuthoritative = false
                activeWindowAuthoritySessionID = nil
                if let provisionalActivePaneID {
                    windows[id]?.setActivePane(provisionalActivePaneID)
                    self.provisionalActivePaneID = nil
                }
            }
            noteWindowAnnounced(id)
            changed()
        case .windowClose:
            // This is control_notify_window_unlinked: the window remains in
            // this session while a move vacates its old winlink. Preserve its
            // topology and last known index until full server truth arrives.
            scheduleOrderRefresh()
        case .unlinkedWindowClose(let id):
            windows.removeValue(forKey: id)
            windowOrder.removeAll { $0 == id }
            pendingOrder?.order.removeAll { $0 == id }
            windowBellFlags.removeValue(forKey: id)
            windowsAwaitingDetails.removeAll { $0 == id }
            if activeWindowID == id {
                activeWindowID = windowOrder.first
                isActiveWindowAuthoritative = false
                activeWindowAuthoritySessionID = nil
            }
            scheduleOrderRefresh()
            changed()
        case .windowRenamed(let id, let name):
            ensureWindow(id); windows[id]?.name = name; changed()
        case .windowPaneChanged(let id, let paneID):
            guard windows[id] != nil else {
                pendingPaneFocus[id] = paneID
                break
            }
            windows[id]?.setActivePane(paneID); changed()
        case .layoutChange(let id, let raw, let visibleRaw, let flags):
            guard windows[id] != nil else { break }
            windows[id]?.layout = WindowLayout.parse(raw)
            windows[id]?.visibleLayout = visibleRaw.flatMap(WindowLayout.parse)
            windows[id]?.isZoomed = flags?.contains("Z") == true
            if windows[id]?.activePaneID == nil {
                let inferredPaneID = windows[id]?.visibleLayout?.paneIds.first
                    ?? windows[id]?.layout?.paneIds.first
                windows[id]?.activePaneID = inferredPaneID
            }
            windows[id]?.reconcileLayoutPanes()
            changed()
        case .sessionChanged(let id, let name):
            if sessionID != id {
                hasIngestedWindowList = false
                lastCollapsibleAuthorityStamp = nil
                pendingOrder = nil
                if sessionID != nil { scheduleOrderRefresh() }
            }
            sessionID = id
            sessionName = name
            isActiveWindowAuthoritative = activeWindowID != nil
                && activeWindowAuthoritySessionID == id
            changed()
        case .sessionRenamed(let id, let name):
            guard sessionID == id else { return }
            sessionName = name; changed()
        case .sessionWindowChanged(let id, let windowID):
            guard sessionID == nil || sessionID == id else { return }
            ensureWindow(windowID)
            activeWindowID = windowID
            activeWindowAuthoritySessionID = id
            isActiveWindowAuthoritative = sessionID == id
            if windows[windowID]?.activePaneID == nil, let provisionalActivePaneID {
                windows[windowID]?.setActivePane(provisionalActivePaneID)
            }
            provisionalActivePaneID = nil
            // tmux sends this *before* `%window-add` for a window it is
            // creating, so this is the first announcement of an undescribed
            // window as often as it is a plain selection change.
            noteWindowAnnounced(windowID)
            changed()
        case .subscriptionChanged(let name, let eventSessionID, _, _, _, let value)
                where name == TmuxGridAuthority.subscriptionName,
            .windowSubscriptionChanged(let name, let eventSessionID, _, _, let value)
                where name == TmuxGridAuthority.subscriptionName:
            guard sessionID == nil || sessionID == eventSessionID else { break }
            // One edge per pane collapses within this read and session.
            // Across reads the session's memo alone decides what is new, so
            // its re-arms (our write, an identity change) reach every
            // platform alike.
            let raw = TmuxGridAuthorityStamp.boundedRawValue(value)
            guard raw != lastCollapsibleAuthorityStamp else { break }
            lastCollapsibleAuthorityStamp = raw
            pendingAuthorityStamps.append(raw)
        case .subscriptionChanged(
            let name, let eventSessionID, let eventWindowID, _, let eventPaneID, let value
        ) where TmuxControlSubscriptions.name(name, isFeed: TmuxPaneMetadataSubscription.name):
            guard sessionID == nil || sessionID == eventSessionID else { break }
            guard let update = TmuxPaneMetadataSubscription.parse(
                value,
                fallbackWindowID: eventWindowID,
                fallbackPaneID: eventPaneID
            ) else { break }
            // Recorded before the topology ingest, which returns early for a
            // window this client has not been told about yet. An agent's pane
            // is exactly the pane most likely to be announced out of order,
            // and its lifecycle must not depend on that race.
            //
            // Every announcement is carried, including one that repeats the
            // value already announced. Suppressing repeats here looked like
            // free savings and was not: tmux announces a pane option's current
            // value once, when a client subscribes, and an idle agent never
            // changes it again. A consumer that did not exist for that one
            // announcement — the endpoint is built moments after the
            // subscribe — would then never learn about the agent at all.
            // Whoever holds a consumer's identity is the layer that may
            // decide a payload is a repeat; this layer only reports what tmux
            // said.
            if let json = update.agentStateJSON,
               json.utf8.count <= TmuxPaneAgentState.maximumJSONBytes {
                pendingPaneAgentStates.append(.init(
                    windowID: update.windowID,
                    paneID: update.paneID,
                    json: json
                ))
            }
            ingestPaneMetadata(update)
        case .subscriptionChanged(let name, let eventSessionID, _, _, _, let value)
                where name == TmuxWindowOrderSubscription.name,
            .windowSubscriptionChanged(let name, let eventSessionID, _, _, let value)
                where name == TmuxWindowOrderSubscription.name:
            _ = ingestWindowOrderSubscription(value, sessionID: eventSessionID)
        case .sessionSubscriptionChanged(let name, let eventSessionID, let value)
            where name == TmuxWindowOrderSubscription.name:
            _ = ingestWindowOrderSubscription(value, sessionID: eventSessionID)
        default:
            break
        }
    }
}
