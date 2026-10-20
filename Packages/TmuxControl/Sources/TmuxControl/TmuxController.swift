import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Runtime state machine for a `tmux -CC` session.
///
/// Sits between the raw SSH byte stream and the terminal renderer.
/// The controller has two modes:
///
///   - `.passthrough` — no tmux detected. Bytes go straight to the
///     terminal view and typed input goes straight upstream. We scan
///     the output for the DCS sequence `ESC P 1 0 0 0 p` that tmux
///     emits on `-CC` attach.
///   - `.tmuxControl` — parsing tmux control-mode messages. `%output`
///     pane bytes are fed to the terminal; typed input is wrapped in
///     `send-keys -t %<pane> -H <hex>` commands so UTF-8 and special
///     characters survive intact.
///
/// Owners provide two closures:
///
///   - `feedTerminal` — called with bytes to paint on the SwiftTerm
///     view. In passthrough this is every byte; in tmux mode it's
///     the decoded payload of `%output` messages for the active pane.
///   - `sendBytes` — called with bytes to write upstream on the SSH
///     channel. Passthrough forwards raw; tmux mode wraps in send-keys.
///
/// State changes (mode flip, window list, active pane) are observable
/// via Swift's `Observation` framework — SwiftUI views holding the
/// controller re-render automatically.
///
/// v1 scope: no window tracking, no tab UI, no capture-pane seeding.
/// This is the byte-routing floor so typing inside `tmux -CC attach`
/// round-trips end-to-end. Window lifecycle (§3.2 commit B) and
/// keyboard shortcuts (§3.2 commit C) build on this foundation.
@MainActor
@Observable
public final class TmuxController {
    /// Session user option used by mosh+tmux to identify the visible client
    /// that created a phone-born session. The control side-channel is a
    /// separate, already-ignored tmux client, so it must target this owner when
    /// ceding. The mosh bootstrap sets the option only on the create branch.
    public static let reverseAttachGeometryOwnerOption = "@tessera-size-owner"

    /// Session user option recording which Tessera device most recently took
    /// the shared tmux grid ("continuity takeover"). Written in the same
    /// command batch as the size force, so peers observe an explicit authority
    /// transfer instead of inferring one from geometry. Value grammar:
    /// `v1 <deviceID> <generation> <displayName>`.
    public static let gridAuthorityOption = TmuxGridAuthority.option
    static let gridAuthoritySubscriptionName = TmuxGridAuthority.subscriptionName

    /// Identity this client stamps into `gridAuthorityOption` when it takes
    /// the grid. `id` must be stable per app install; `displayName` is shown
    /// on the peer's takeover overlay ("continued on iPhone").
    public typealias GridAuthorityIdentity = TmuxGridAuthorityIdentity

    /// Who currently owns the shared tmux grid, as observed through the
    /// authority stamp. `.unknown` until the first stamp observation of a
    /// connection; `.peer` drives the continued-elsewhere overlay.
    public enum GridAuthority: Equatable, Sendable {
        case unknown
        case mine
        case peer(displayName: String)

        public var peerDisplayName: String? {
            if case .peer(let name) = self { return name }
            return nil
        }

        public var isPeer: Bool { peerDisplayName != nil }
    }

    /// The one value the terminal surface renders for grid authority. It is
    /// derived from the lifecycle reducer's state, never from `gridAuthority`
    /// alone: while a show intent is pending, buffered stamp lines can
    /// project a peer that the fresh read is about to displace, and showing
    /// the veil for that interval would flash it over a session the user is
    /// resuming. Equatable without a generation, so an unchanged value never
    /// invalidates a SwiftUI body.
    public enum GridAuthorityPresentation: Equatable, Sendable {
        /// Nothing to show; terminal input flows.
        case none
        /// A show (or explicit open) is resolving: the last frame stays on
        /// screen with a small indicator, and input waits for the result.
        /// `awaitingConnection` is true while no control channel can carry
        /// the read, i.e. the session "takes control when reconnected".
        case resuming(awaitingConnection: Bool)
        /// Another device holds the grid and no gesture is pending.
        case veiled(peerName: String)
        /// The user tapped the veil (or a contested claim's own write won):
        /// the veil stays up with its progress state.
        case reclaiming(peerName: String, awaitingConnection: Bool)

        // The input gate is `TmuxController.gridAuthorityAllowsInput`: it
        // also needs the reducer's last-known holder while a show waits for
        // a connection, which this value deliberately does not carry.

        /// True for the states that draw the continued-elsewhere veil.
        public var showsVeil: Bool {
            switch self {
            case .veiled, .reclaiming: return true
            case .none, .resuming: return false
            }
        }

        public var peerName: String? {
            switch self {
            case .veiled(let name), .reclaiming(let name, _): return name
            case .none, .resuming: return nil
            }
        }

        public var isReclaiming: Bool {
            if case .reclaiming = self { return true }
            return false
        }

        public var isResuming: Bool {
            if case .resuming = self { return true }
            return false
        }

        /// A pending gesture is waiting for a control channel.
        public var isAwaitingConnection: Bool {
            switch self {
            case .resuming(let awaiting), .reclaiming(_, let awaiting): return awaiting
            case .none, .veiled: return false
            }
        }
    }

    /// Portable policy shared with non-Observation clients such as the Mac
    /// Bridge. Kept as a source-compatible nested alias for existing callers.
    public typealias ClientSizePolicy = TmuxClientSizePolicy


    public enum Mode: Equatable, Sendable {
        case passthrough
        case tmuxControl
    }

    /// Where tmux control-mode bytes come from.
    ///
    /// `.inline` is the existing SSH `tmux -CC` path: one stream carries
    /// both tmux metadata and pane output, so `%output` renders into the
    /// terminal and resize/display-swap commands travel on the same wire.
    ///
    /// `.sideChannel` is the mosh split-transport path: a second SSH exec
    /// channel carries only the tmux control protocol, while the main mosh
    /// transport renders the active window as ordinary terminal bytes. In
    /// this mode `%output` is ignored and tmux-specific resize/display-swap
    /// commands stay disabled.
    public enum ControlPath: Equatable, Sendable {
        case inline
        case sideChannel
    }

    /// Stable, content-free labels for work delivered to the shared terminal.
    /// The app uses these only for aggregate performance diagnostics; terminal
    /// bytes are never included in the diagnostic payload.
    public enum TerminalFeedSource: String, Equatable, Sendable {
        case passthrough = "ssh-passthrough"
        case paneOutput = "tmux-live"
        case foregroundReplay = "tmux-foreground-replay"
        case viewportRepaint = "tmux-repaint-viewport"
        case viewportRefresh = "tmux-repaint-viewport-only"
        case deepRepaint = "tmux-repaint-deep"
        case repaintScrub = "tmux-repaint-scrub"
        case moshHistory = "mosh-history"
    }

    /// Metadata describing one shared-terminal feed without retaining its
    /// payload. Optional repaint fields make it possible to distinguish a
    /// live-output storm from one large capture-pane repaint in diagnostics.
    public struct TerminalFeedContext: Equatable, Sendable {
        public let source: TerminalFeedSource
        public let paneId: PaneId?
        public let windowId: WindowId?
        /// Surface-ownership epoch. Unlike `generation`, this advances only
        /// when the terminal must be rebound and its scrollback cleared; an
        /// in-place foreground viewport repair intentionally retains it.
        public let renderOwnerEpoch: UInt64?
        public let generation: Int?
        public let captureRows: Int?
        public let reason: String?
        /// Size of the unsliced renderer delivery that produced this chunk.
        /// This is aggregate metadata only; terminal payloads are never logged.
        public let originalByteCount: Int?

        public init(
            source: TerminalFeedSource,
            paneId: PaneId? = nil,
            windowId: WindowId? = nil,
            renderOwnerEpoch: UInt64? = nil,
            generation: Int? = nil,
            captureRows: Int? = nil,
            reason: String? = nil,
            originalByteCount: Int? = nil
        ) {
            self.source = source
            self.paneId = paneId
            self.windowId = windowId
            self.renderOwnerEpoch = renderOwnerEpoch
            self.generation = generation
            self.captureRows = captureRows
            self.reason = reason
            self.originalByteCount = originalByteCount
        }
    }

    /// Failure modes for the command-response API (§3.2 commit C).
    public enum CommandError: Error, Sendable, Equatable {
        /// The controller isn't in `.tmuxControl` mode, so there's no
        /// server to send to. Completions fire synchronously with this
        /// case at call time.
        case notInTmuxMode
        /// tmux replied with `%error`. The payload is the body lines
        /// emitted between the preceding `%begin` and the `%error`.
        case tmuxError(lines: [String])
        /// The controller was reset (session drop, `%exit`, explicit
        /// `reset()`) before tmux replied. The completion fires to
        /// release captured state; no response bytes are available.
        case cancelled
        /// The command's response never arrived within the bounded
        /// response interval and the queue entered recovery. The remote
        /// server MAY still have executed the command — treat delivery
        /// as ambiguous and never retry non-idempotent input for it.
        case timedOut
        /// A background write refused, unsent, while another device holds
        /// the grid or a take-back is running (S5′).
        case refusedByAuthority
    }

    /// Lightweight view model for one tmux window, kept in step with
    /// `%window-add` / `%window-close` / `%window-renamed` notifications
    /// and the shared attach/reconnect hydrator.
    ///
    /// `windowName` is tmux's `#{window_name}` fallback. Non-default
    /// `activePaneTitle` values win when present because OSC titles
    /// update `pane_title` without emitting `%window-renamed`. tmux's
    /// default pane title is just `#{host}`, so it is tracked but not
    /// used as a visible tab label.
    /// One pane within a tmux window.
    ///
    /// Tracked for every pane of every known window (not just the active one)
    /// since `dca6f2a`'s successor: the per-pane title/flag stream already
    /// arrives on the wire, and split rendering needs the full set. `isActive`
    /// mirrors tmux's focus within the window; exactly one pane per window is
    /// active. `titleIsDefault` is true when the pane title still equals
    /// `#{host}` (tmux's default), so it is not used as a visible label.
    public struct PaneInfo: Equatable, Identifiable, Sendable {
        public var id: PaneId
        public var title: String?
        public var titleIsDefault: Bool
        public var isActive: Bool
        public var currentCommand: String?
        public var isAlternateScreen: Bool?
        public var isMouseReporting: Bool?
        public var isSgrMouse: Bool?
        /// Pane content geometry in tmux window cells. Unlike `window_layout`,
        /// this excludes tmux pane chrome such as `pane-border-status top`.
        public var contentRect: CellRect?

        public init(
            id: PaneId,
            title: String? = nil,
            titleIsDefault: Bool = false,
            isActive: Bool = false,
            currentCommand: String? = nil,
            isAlternateScreen: Bool? = nil,
            isMouseReporting: Bool? = nil,
            isSgrMouse: Bool? = nil,
            contentRect: CellRect? = nil
        ) {
            self.id = id
            self.title = title
            self.titleIsDefault = titleIsDefault && title != nil
            self.isActive = isActive
            self.currentCommand = Self.nonEmpty(currentCommand)
            self.isAlternateScreen = isAlternateScreen
            self.isMouseReporting = isMouseReporting
            self.isSgrMouse = isSgrMouse
            self.contentRect = contentRect
        }

        private static func nonEmpty(_ value: String?) -> String? {
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return value
        }
    }

    public struct WindowInfo: Equatable, Identifiable, Sendable {
        public var id: WindowId
        /// tmux `#{window_index}` — the session's display order. `nil` until
        /// hydration or the `%window-add` details query answers. Windows are
        /// kept sorted by this (unknowns keep their arrival position at the
        /// end) so the tab strip matches tmux across attach and live adds:
        /// plain `new-window` fills the lowest free index, not the end, so
        /// arrival order alone diverges from the order a reattach hydrates.
        public var index: Int?
        public var windowName: String?
        public var activePaneId: PaneId?
        public var activePaneTitle: String?
        public var activePaneTitleIsDefault: Bool

        /// All panes of this window, in tmux layout (DFS) order when a layout
        /// is known. Empty until hydration / `%layout-change` populates it.
        public var panes: [PaneInfo]
        /// The full `#{window_layout}` tree (multi-pane even while zoomed).
        /// `nil` before hydration → fail-open to the single-pane fast path.
        public var layout: WindowLayout?
        /// The `#{window_visible_layout}` tree — collapses to the zoomed leaf
        /// while `isZoomed`, otherwise equal to `layout`.
        public var visibleLayout: WindowLayout?
        public var isZoomed: Bool

        /// Delegates to the portable owner of the label policy so the tab
        /// strip, the Android tab strip, and anything reading the snapshot
        /// wire all render the identical string.
        public var displayName: String {
            TmuxWindowSnapshot.displayName(
                windowID: id,
                name: windowName,
                activePaneTitle: activePaneTitle,
                activePaneTitleIsDefault: activePaneTitleIsDefault
            )
        }

        /// Compatibility for existing UI call sites; prefer
        /// `displayName` in new code.
        public var name: String { displayName }

        /// Number of panes the window holds. Uses the FULL layout so a zoomed
        /// multi-pane window still reports >1.
        public var paneCount: Int { layout?.paneCount ?? max(1, panes.count) }

        /// True when this window must mount the pane grid rather than render
        /// through the shared single-pane terminal. A zoomed multi-pane window
        /// is intentionally one surface; its full layout remains available for
        /// unzoom and pane navigation while `visibleLayout` names the leaf.
        /// Fail-open: a `nil` layout (pre-hydration) renders single-pane.
        public var rendersAsPaneGrid: Bool {
            !isZoomed && (layout?.paneCount ?? 1) > 1
        }

        public init(
            id: WindowId,
            index: Int? = nil,
            windowName: String? = nil,
            activePaneId: PaneId? = nil,
            activePaneTitle: String? = nil,
            activePaneTitleIsDefault: Bool = false,
            panes: [PaneInfo] = [],
            layout: WindowLayout? = nil,
            visibleLayout: WindowLayout? = nil,
            isZoomed: Bool = false
        ) {
            self.id = id
            self.index = index
            self.windowName = Self.nonEmpty(windowName)
            self.activePaneId = activePaneId
            self.activePaneTitle = Self.nonEmpty(activePaneTitle)
            self.activePaneTitleIsDefault = activePaneTitleIsDefault && self.activePaneTitle != nil
            self.panes = panes
            self.layout = layout
            self.visibleLayout = visibleLayout
            self.isZoomed = isZoomed
        }

        public init(id: WindowId, name: String) {
            self.init(id: id, windowName: name)
        }

        private static func nonEmpty(_ value: String?) -> String? {
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return value
        }
    }

    public struct PaneInteractionState: Equatable, Sendable {
        public var paneId: PaneId
        public var isAlternateScreen: Bool
        public var isMouseReporting: Bool
        public var isSgrMouse: Bool
    }

    public private(set) var mode: Mode = .passthrough
    public let controlPath: ControlPath

    /// While true, passthrough output is still scanned for tmux's DCS
    /// prologue but is not painted into the terminal. The SSH auto-tmux
    /// launch path uses this to keep shell echo/MOTD/bootstrap text out
    /// of SwiftTerm while waiting for control mode or the no-tmux
    /// sentinel.
    public var suppressPassthroughOutputUntilControlMode = false

    /// True after inline tmux control mode has painted real pane bytes
    /// or completed the attach-time capture repaint. Session UI uses
    /// this as the point where it can drop the launch spinner without
    /// revealing the bootstrap shell.
    public private(set) var isInitialRenderReady = false

    /// The pane id tmux currently considers active for
    /// `activeWindowId`. This is the input target and may differ from
    /// `renderedPaneId` while an inline display refresh is in flight.
    public private(set) var activePaneId: PaneId?
    public private(set) var paneCurrentPaths: [PaneId: String] = [:]

    public var activePaneCurrentPath: String? {
        activePaneId.flatMap { paneCurrentPaths[$0] }
    }

    /// All tmux windows currently known to the session, in tmux order.
    /// Fresh attaches do not replay `%window-add`; hydration rebuilds
    /// the list from `list-windows`, while later creates and closes
    /// arrive as normal notifications.
    public private(set) var windows: [WindowInfo] = []

    /// Immutable production state. The portable runtime remains independent of
    /// Apple Observation, while this revision projection lets Apple adapters
    /// subscribe to every core-owned snapshot change without duplicating its
    /// fields or policy.
    public var snapshot: TmuxSnapshot {
        _ = snapshotObservationRevision
        return runtimeEngine.snapshot
    }

    /// True only after this control connection has completed an authoritative
    /// `list-windows` response. Side-channel reconnects keep stale tabs visible,
    /// but targeted commands must remain blocked until this flips back to true.
    public private(set) var isWindowListHydrated = false

    /// User-facing failure from the most recent reorder or tidy operation.
    /// The session UI observes this and presents it through its existing
    /// transient-error surface.
    public private(set) var windowOrderError: String?

    /// Ordering controls are valid only against live, authoritative topology.
    /// A yielded side-channel client must not mutate the peer-owned session,
    /// and the core admits only one optimistic order at a time.
    public var canTidyWindows: Bool {
        mode == .tmuxControl
            && isWindowListHydrated
            && snapshot.isWindowListHydrated
            && ownSessionId != nil
            && !gridAuthority.isPeer
            && !isWindowReorderPending
            && !windows.isEmpty
    }

    /// Moving needs a distinct source and destination. Tidy remains available
    /// for one surviving window because its tmux index may still have a gap.
    public var canReorderWindows: Bool {
        canTidyWindows && windows.count > 1
    }

    public var isWindowReorderPending: Bool {
        snapshot.isReorderPending || windowOrderOperationPending
    }

    /// Outstanding `%window-add` details queries (`queryWindowDetails`)
    /// per window, counted so a close + re-add of the same id — two
    /// overlapping queries — stays pending until the LAST reply drains.
    /// While a window's layout is unknown AND a query is in flight, its
    /// `paneCount` fallback of 1 is a guess: `link-window`/`move-window`
    /// can add a window that is already split. `isWindowLayoutPending`
    /// exposes this so close paths fail closed (confirm) during the gap.
    private var windowLayoutQueriesInFlight: [WindowId: Int] = [:]

    /// True while `windowId`'s pane count is still a guess: its layout is
    /// unknown and the `%window-add` details query hasn't answered yet. A
    /// real `%layout-change` ends the pending state immediately (the layout
    /// is then authoritative) even while the query reply is in flight.
    public func isWindowLayoutPending(_ windowId: WindowId) -> Bool {
        guard let window = window(windowId), window.layout == nil else { return false }
        return (windowLayoutQueriesInFlight[windowId] ?? 0) > 0
    }

    /// Changes whenever the underlying tmux control connection or attached
    /// session identity is invalidated. UI confirmations capture this value so
    /// an `@id` from an old tmux session/server can never target a different
    /// window after a session switch, reconnect, or id reuse.
    public private(set) var controlConnectionGeneration: UInt64 = 0

    public private(set) var bellingWindows: Set<Int> = []

    /// The window id that tmux considers "current" — driven by
    /// `%session-window-changed` notifications and by falling back to
    /// the first-seen window so we have something highlighted from the
    /// moment the attach completes. Commit B renders this as the
    /// highlighted tab in the top strip but does not yet react to taps
    /// (selection comes in commit C along with `select-window`).
    public private(set) var activeWindowId: WindowId?

    /// The window/pane currently represented by the inline SwiftTerm
    /// renderer. Side-channel mosh does not use these because the UDP
    /// terminal stream renders tmux directly.
    public private(set) var renderedWindowId: WindowId?
    public private(set) var renderedPaneId: PaneId?

    // Non-observed internals (SwiftUI doesn't need to re-render on these).
    @ObservationIgnored private var runtimeEngine = TmuxRuntimeEngine()
    /// A legacy platform hydration reply can arrive before later topology in
    /// one already-parsed socket read. Stage its session-scoped correction so
    /// ordered snapshots can use it, then commit only if nothing later in the
    /// read supersedes it.
    @ObservationIgnored private var activeWindowQueryRebase: (
        windowID: WindowId,
        sessionID: SessionId?,
        connectionGeneration: UInt64
    )?
    @ObservationIgnored private var pendingHydratedActiveWindow: (
        windowID: WindowId,
        generation: Int,
        reason: String
    )?
    /// Generation of a socket read whose legacy list callback mutated the
    /// runtime after that read had already been parsed. Its later topology
    /// notifications must be replayed in wire order.
    @ObservationIgnored private var legacyTopologyReplayConnectionGeneration: UInt64?
    /// Synchronous callbacks (including sendBytes in tests/adapters) may
    /// re-enter ingest while an outer socket read is still being processed.
    /// Only the outermost invocation owns batch-final query commit and replay
    /// cleanup; nested invocations participate in the same ordered turn.
    @ObservationIgnored private var controlProcessingDepth = 0
    /// The single portable owner for render staging and tmux command-response
    /// correlation. Platform code below is deliberately limited to executing
    /// its ordered effects against SwiftTerm and the transport.
    @ObservationIgnored private var renderLedger = TmuxRenderLedger()
    @ObservationIgnored private var renderTimerTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var executingRenderReplyRows: Int?
    @ObservationIgnored private var executingRenderReplyReason: String?
    /// The ordered topology at the command reply currently being delivered.
    /// RuntimeEngine has already parsed the rest of the socket read, so legacy
    /// completion handlers must use this snapshot instead of its batch-final
    /// mutable state.
    @ObservationIgnored private var executingCommandReplySnapshot: TmuxSnapshot?
    private var snapshotObservationRevision: UInt64 = 0
    /// The portable core owns all incremental DCS/prologue state. The Apple
    /// adapter only projects the detector's passthrough/control partitions.
    @ObservationIgnored private var controlModeDetector = TmuxControlModeDetector()
    @ObservationIgnored private var outputTitleScanners: [PaneId: TerminalOutputScanner] = [:]
    @ObservationIgnored private var preloadedTerminalDefaultColorPanes: Set<PaneId> = []

    /// FIFO queue of completions awaiting a `%end` or `%error`. One
    /// entry per command we've sent; popped in the order tmux replies,
    /// which matches the order we queued because tmux processes
    /// control commands serially. Fire-and-forget `sendControlCommand`
    /// pushes a no-op completion so this queue always stays in sync
    /// with the responses on the wire.
    @ObservationIgnored private var pendingCommands: [PendingCommand] = []
    @ObservationIgnored private var nextCommandSequence = 0
    @ObservationIgnored private var pendingWindowReorderToken: UInt64?
    @ObservationIgnored private var windowOrderDeadlineTask: Task<Void, Never>?
    @ObservationIgnored var windowOrderDeadlineInterval: TimeInterval = 5
    @ObservationIgnored private var windowOrderOperationPending = false

    /// Response-liveness watchdog over `pendingCommands`. The FIFO's
    /// correctness depends on tmux answering every client command; a lost,
    /// misclassified, or never-emitted reply otherwise poisons the queue
    /// forever while `%output` keeps flowing (observed on tmux 3.4 — see
    /// docs/refactor/input-stall-after-shared-refactor-findings.md).
    @ObservationIgnored private var commandResponseWatchdogTask: Task<Void, Never>?
    /// Ages are measured from the later of a command's transmit instant and
    /// this baseline. Foregrounding sets it so time spent app-suspended
    /// (during which ContinuousClock keeps advancing) never counts toward
    /// response-poisoning thresholds.
    @ObservationIgnored private var commandResponseWatchdogBaseline: ContinuousClock.Instant?
    /// Most recent instant ANY control-mode wire event was processed
    /// (notifications, `%output`, frames). Once pane output is quiet, this
    /// distinguishes "the server produced later traffic but our client
    /// response is missing" from a fully stalled transport.
    @ObservationIgnored private var lastControlActivityAt: ContinuousClock.Instant?
    /// Most recent pane-output event. A client response is ordered behind all
    /// earlier `%output` on the same control stream, so live pane output is
    /// congestion evidence, not proof that an unanswered command is poisoned.
    @ObservationIgnored private var lastPaneOutputAt: ContinuousClock.Instant?
    /// Cooperative renderer delivery intentionally yields while draining a
    /// large pane-output batch. The watchdog may run during those yields, but
    /// must not recover a command whose response is simply later in that same
    /// ordered batch.
    @ObservationIgnored private var cooperativeOutputIngestDepth = 0
    /// While non-nil, response correlation is unsynchronized: every frame is
    /// discarded until a success frame carrying `nonce` in its body proves the
    /// wire has drained past all pre-recovery commands. Frames after the nonce
    /// map 1:1 onto commands transmitted after the fence, because tmux answers
    /// client commands serially.
    private struct CommandQueueFence {
        let nonce: String
        let armedAt: ContinuousClock.Instant
    }
    @ObservationIgnored private var pendingCommandFence: CommandQueueFence?
    /// Count of poisoned-queue recoveries on this controller, for
    /// diagnostics and tests.
    @ObservationIgnored public private(set) var commandQueueRecoveries = 0
    /// Owner-supplied transport recovery for a poisoned command channel.
    /// Inline SSH reopens its interactive PTY; the mosh path disconnects its
    /// independently reconnecting tmux side channel. When unset (package
    /// tests and compatibility clients), the nonce-fence fallback remains.
    @ObservationIgnored public var onCommandQueueTransportRecoveryRequired: ((Int) -> Void)?
    /// Once transport recovery has been requested, no more commands may enter
    /// the old channel. Their delivery would be ambiguous and, for input,
    /// could replay into the replacement attachment after its fresh hydrate.
    @ObservationIgnored private var commandQueueAwaitingTransportRecovery = false
    /// An actively waiting keystroke or window selection gets a tighter
    /// liveness bound than background metadata after ordered pane output has
    /// drained. It must never outrun renderer/control-stream backpressure.
    @ObservationIgnored public var commandResponseInteractivePoisonThreshold: TimeInterval = 2
    /// Server-active recovery is allowed only after pane output has drained
    /// and stayed quiet for this interval. This keeps a large Codex/compiler
    /// dump from turning renderer backpressure into a destructive reconnect.
    @ObservationIgnored public var commandResponseOutputQuietPeriod: TimeInterval = 1
    /// Oldest-pending-command age that triggers recovery after later server
    /// activity has been observed and ordered pane output is quiet.
    @ObservationIgnored public var commandResponsePoisonThreshold: TimeInterval = 10
    /// Bound after output becomes quiet: recover even without observed server
    /// activity, so a hung tmux server fails pending completions instead of
    /// leaking them forever. Live ordered output defers this bound because the
    /// response may still be behind that output on the same stream.
    @ObservationIgnored public var commandResponseHardTimeout: TimeInterval = 30

    /// Portable frame assembler/classifier; completion closures remain in the
    /// Apple Observation wrapper and are dequeued only after this seam has
    /// classified a response as client-originated.

    /// Last-known client size (cols × rows). Refreshed by
    /// `updateClientSize(cols:rows:)` from the outer view whenever
    /// SwiftTerm's `sizeChanged` delegate fires. Used both to push
    /// `refresh-client -C` to tmux while in control mode *and* to
    /// send the current size as soon as we enter tmux mode — the
    /// PTY-level SIGWINCH the SSH session sends is ignored by tmux
    /// in `-CC`, so without this the pane stays at whatever size the
    /// PTY happened to be at the moment `tmux -CC` was launched.
    @ObservationIgnored private var lastKnownSize: (cols: Int, rows: Int)?

    /// Geometry whose refresh-client bytes entered the ordered transport queue.
    /// Requested geometry stays in lastKnownSize while authority or app
    /// visibility withholds it; compact reprojection must judge publications.
    public private(set) var lastPublishedClientSize: TmuxClientGeometry?

    /// The physical viewport reported by the local terminal view. This stays
    /// separate from `lastKnownSize`: an `ignore-size` phone deliberately
    /// adopts the server grid there, but still needs its own viewport here to
    /// recognize when a larger client has taken over the session.
    @ObservationIgnored private var localViewportSize: (cols: Int, rows: Int)?

    /// Peers in this control client's own session. Session-change events keep
    /// this current when tmux emits them; a list-clients fallback discovers new
    /// attachments because live tmux versions do not announce every attach.
    @ObservationIgnored private var reverseAttachPeers: Set<String> = []
    /// Frozen phone geometry from the moment the first same-session peer was
    /// announced, plus dimensions queried from those exact tmux clients. A
    /// layout can trigger ceding only when its width equals a tracked peer's
    /// reported width (and its height too when tmux exposes one), so a local
    /// rotation cannot be mistaken for peer ownership.
    @ObservationIgnored private var reverseAttachBaselineSize: (cols: Int, rows: Int)?
    /// The first authoritative server grid observed before a reverse-attach
    /// peer arrives. A newly attached peer can initially inherit this exact
    /// size, so matching its queried client size is not by itself evidence
    /// that the peer expanded the session.
    @ObservationIgnored private var reverseAttachOwnerGridBaseline: (cols: Int, rows: Int)?
    @ObservationIgnored private var reverseAttachPeerSizes: [String: (cols: Int, rows: Int?)] = [:]
    @ObservationIgnored private var reverseAttachPeerQueries: Set<String> = []
    @ObservationIgnored private var reverseAttachOwnClientName: String?
    @ObservationIgnored private var reverseAttachPeerDiscoveryInFlight = false

    /// Side-channel cede resolves the tagged visible mosh client through a
    /// command response. Retain the newest larger grid while that lookup is in
    /// flight; geometry-only notifications can arrive faster than responses.
    @ObservationIgnored private var reverseAttachCedeLookupInFlight = false
    /// Cede first caches the peer grid on this control client, then excludes
    /// the owning client from sizing. The authoritative hold is promoted after
    /// the cache acknowledgement and before the owner mutation is transmitted,
    /// so a second-command error or disconnect cannot strand an ignored owner
    /// without matching local/session state.
    @ObservationIgnored private var reverseAttachCedeMutationInFlight = false
    @ObservationIgnored private var pendingReverseAttachCedeSize: (cols: Int, rows: Int)?
    /// Monotonic user-selection intent for the side-channel's visible-client
    /// mirror. Window and pane selections share the fence because either can
    /// supersede the other while identity queries are in flight; only the
    /// newest is allowed to move the painter client.
    @ObservationIgnored private var visibleClientSelectionGeneration: UInt64 = 0

    private enum CompactClientSizeRole {
        case unresolved
        case owner
        case observer
    }

    /// Whether this inline compact client created the tmux session and still
    /// owns its size. While true, phone viewport changes (most importantly the
    /// software keyboard appearing/disappearing) may resize the remote grid so
    /// the terminal keeps its configured font size instead of scaling the old
    /// full-height grid down. Existing-session attaches report `ignore-size`
    /// and remain false; reverse attach flips this back to false before the
    /// larger iPad grid becomes the preserved rendering authority.
    public private(set) var compactClientOwnsSize = false
    public private(set) var compactClientSizeRoleResolved = false
    @ObservationIgnored private var compactClientSizeRole: CompactClientSizeRole = .unresolved
    @ObservationIgnored private var compactClientSizeRoleResolutionInFlight = false
    @ObservationIgnored private var compactClientSizeRoleResolutionAttempts = 0
    @ObservationIgnored private var compactClientSizeRoleRetryTask: Task<Void, Never>?

    /// One-way for the lifetime of the logical session. Once a preserving
    /// client establishes the cede grid hold, a peer detach or side-channel
    /// reconnect must never make it replay its smaller local viewport.
    @ObservationIgnored private(set) var hasCededGridOwnership = false

    /// Continuity-takeover authority state (observable — drives the
    /// continued-elsewhere overlay). Distinct from the reverse-attach cede
    /// machinery above: that one-way path serves `preserveServerGeometry`
    /// observers, while grid authority is the reversible, stamp-based
    /// ownership contract between `resizeTmux` devices.
    public private(set) var gridAuthority: GridAuthority = .unknown
    /// Cross-platform authority policy. The surrounding controller is only
    /// the tmux-command and renderer adapter; claim admission, reconnect,
    /// contest, timeout and settlement decisions live here and in the
    /// identical reducer Android reaches through TesseraCoreABI. Control
    /// moves only on a show edge or a veil gesture (the show rule, review
    /// §6.9); attach, reconnect, foreground and a peer's departure only read.
    @ObservationIgnored private var gridAuthoritySession = TmuxGridAuthoritySession(initialGeneration: TmuxGridAuthorityStamp.generationBase(
        unixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
    ))
    private var gridAuthorityLifecycle: TmuxGridAuthorityLifecycleReducer { gridAuthoritySession.reducer }
    /// Milliseconds from one sleep-inclusive origin. Tests inject the same clock
    /// used for events and deadlines; the wake task never supplies its own time.
    private static let gridAuthorityClockOrigin = ContinuousClock.now
    private static func continuousAuthorityMillis() -> Int64 {
        let elapsed = gridAuthorityClockOrigin.duration(to: ContinuousClock.now).components
        return elapsed.seconds * 1_000 + Int64(elapsed.attoseconds / 1_000_000_000_000_000)
    }
    @ObservationIgnored private var gridAuthorityNow: () -> Int64 = TmuxController.continuousAuthorityMillis
    @ObservationIgnored private var gridAuthorityWakeTask: Task<Void, Never>?
    @ObservationIgnored private var gridAuthorityWakeDeadline: Int64?
    @ObservationIgnored private var gridAuthorityReductionRevision: UInt64 = 0
    #if canImport(UIKit)
    @ObservationIgnored private var gridAuthorityBackgroundObserver: NSObjectProtocol?
    @ObservationIgnored private var gridAuthorityForegroundObserver: NSObjectProtocol?
    @ObservationIgnored private var gridAuthorityActiveObserver: NSObjectProtocol?
    #endif
    /// The single observed value the terminal surface renders. Recomputed
    /// after every reduction and written only when it changes.
    public private(set) var gridAuthorityPresentation: GridAuthorityPresentation = .none
    /// One synchronous O(1) read for every input path (keys, paste, path
    /// injection). False while veiled or reclaiming, and while resuming over
    /// a live channel (the fresh read is moments away). While a show waits
    /// for a channel that is down (`awaitingConnection`, e.g. a mosh+tmux
    /// side channel reconnecting), typing still reaches the shell through
    /// the transport, so it flows unless the last-known holder is a peer.
    public private(set) var gridAuthorityAllowsInput = true
    /// Agent Center launches (D7): refused while veiled or reclaiming, and
    /// while resuming only when a peer holds the grid.
    public var gridAuthorityRefusesAgentSend: Bool {
        participatesInGridAuthority && gridAuthorityMutationRefusal != nil
    }
    /// Whether the control channel could carry a read right now; the
    /// show coordinator pauses only connecting sessions for connect prompts.
    public var gridAuthorityChannelIsLive: Bool {
        gridAuthoritySession.channelIsLive
    }
    /// True while a claim's progress presentation is visible (from the
    /// gesture until settlement, contest, or the 3 s presentation timeout).
    /// Derived from the reducer; observe `gridAuthorityPresentation` instead.
    public var gridAuthorityReclaimInFlight: Bool {
        gridAuthorityLifecycle.claim?.presentationVisible == true
    }
    /// A show, explicit open or tap is waiting for its fresh authority read.
    public var gridAuthorityHasPendingIntent: Bool {
        gridAuthorityLifecycle.pendingIntent != nil
    }
    public var gridAuthorityPendingIntentSource: TmuxGridAuthorityLifecycleReducer.IntentSource? {
        gridAuthorityLifecycle.pendingIntent?.source
            ?? gridAuthoritySession.carriedShow(now: gridAuthorityNow()).map { $0.source == .show ? .show : .explicitOpen }
    }
    public private(set) var gridAuthorityMutationRefusal: TmuxGridAuthorityPresentation.MutationRefusal?
    public private(set) var gridAuthorityGeometryHold: TmuxGridAuthoritySession.GeometryHold = .withheld
    public private(set) var gridAuthorityNextDeadline: Int64?
    public var gridAuthorityIntentTimeout: TimeInterval {
        Double(gridAuthoritySession.configuration.intentWindowMillis) / 1_000
    }
    public var gridAuthorityGeometryEvidenceTimeout: TimeInterval {
        Double(gridAuthoritySession.configuration.replyHoldMillis) / 1_000
    }
    /// Set by the owner after construction (like `feedTerminal`). Nil means
    /// this client does not participate in grid-authority stamping — e.g.
    /// harness observers.
    @ObservationIgnored public var gridAuthorityIdentity: GridAuthorityIdentity? {
        didSet {
            gridAuthoritySession.localDeviceID = gridAuthorityIdentity?.id
            if let old = oldValue?.id, old != gridAuthorityIdentity?.id {
                applyGridAuthorityLifecycleEffects(reduceGridAuthority(.identityChanged))
            } else {
                // Participation can change without a reducer transition (nil
                // identity). Re-project it through the same ledger path.
                applyGridAuthorityLifecycleEffects([])
            }
            if let local = lastKnownSize {
                applyGridAuthorityLifecycleEffects(reduceGridAuthority(.localSize(TmuxGridSize(columns: local.cols, rows: local.rows))))
            }
            noteGridAuthorityWindowFacts()
            noteGridAuthorityPaintable()
            updateGridAuthorityPresentation()
        }
    }
    /// Compact grid presentation mounts only the active pane. Keep authority
    /// repaint completion aligned with the surfaces that actually exist;
    /// regular-width and unzoomed grids repaint every rendered pane.
    @ObservationIgnored public private(set) var gridAuthorityUsesCompactSinglePaneGrid = false
    /// Mosh owns visible repainting outside the control channel. Called after
    /// side-channel geometry settles but before the veil lifts. The Bool says
    /// whether the claim changed geometry (and therefore whether the normal
    /// layout observer should suppress its duplicate repaint). The UInt64 is
    /// the claim generation that must be acknowledged after the exact forced
    /// framebuffer has been consumed by the terminal surface.
    @ObservationIgnored public var onGridAuthoritySideChannelRepaintRequired: ((Bool, UInt64) -> Void)? {
        didSet { noteGridAuthorityPaintable() }
    }
    /// Retire a held history view before reserving a non-preserving claim's
    /// live frame. Foreground repairs can keep that reservation held until tail.
    @ObservationIgnored public var onGridAuthoritySideChannelRepaintPreparing: (() -> Void)?
    /// A same-owner foreground repair keeps a revealed history page in place.
    /// Geometry changes still invalidate it through the render ledger.
    public var gridAuthorityRepaintPreservesHistory: Bool {
        gridClaimIsForegroundRecovery
            && !gridAuthorityClaimChangedGeometry
            && gridAuthorityForegroundRecoveryOwner != nil
            && gridAuthorityForegroundRecoveryOwner == renderLedger.owner(for: .live)
    }
    public var gridAuthorityRepaintRequiresFreshRemoteState: Bool {
        gridAuthorityClaimChangedGeometry || gridClaimIsForegroundRecovery
    }
    private var gridClaimIsForegroundRecovery: Bool {
        gridAuthorityForegroundRecoveryGeneration.map { $0 == liveGridClaimGeneration } ?? false
    }
    @ObservationIgnored private var gridAuthorityForegroundRecoveryGeneration: UInt64?
    @ObservationIgnored private var gridAuthorityForegroundRecoveryOwner: RenderOwner?
    private var gridAuthorityGeometryHeld: Bool { gridAuthoritySession.geometryHold == .withheld }
    private var gridAuthorityGeometryWithheld: Bool { gridAuthorityGeometryHeld }
    private var gridAuthorityOrdinaryGeometryIsUnstamped: Bool {
        participatesInGridAuthority && gridAuthoritySession.geometryHold == .advertiseOnly
    }
    @ObservationIgnored private var gridAuthorityDeliveryRetryTask: Task<Void, Never>?
    @ObservationIgnored private var gridAuthorityDeliveryRetryAttempts = 0
    @ObservationIgnored private var gridAuthorityDeliveryRetryWindow: WindowId?
    @ObservationIgnored private var gridAuthorityDeliveryRetryPanes: Set<PaneId> = []
    /// The live claim's generation; nil outside a claim. The session's claim
    /// is the only one: its fence (`claimFence`) says what the wire proved.
    private var liveGridClaimGeneration: UInt64? { gridAuthorityLifecycle.claim?.generation }
    /// The live claim's geometry phase is open on the wire: it advertised
    /// its target and has not confirmed, or a loss, a stall or a re-target
    /// sent it back. It stays open after the presentation deadline: a
    /// claim's server-side effects cannot be recalled, so a late claim
    /// still confirms when its geometry lands (§6.10 rule 1). A claim that
    /// never advertised (no measured viewport yet) has sent nothing.
    private var gridClaimAwaitsFence: Bool {
        guard let claim = gridAuthorityLifecycle.claim else { return false }
        return claim.phase == .awaitingFence && claim.targetGrid != nil
    }
    /// Whether this claim began with a different/unknown server grid. Latched
    /// before the size replay so a matching `%layout-change` cannot erase the
    /// fact that the visible terminal needs one resynchronizing repaint.
    @ObservationIgnored private var gridAuthorityClaimChangedGeometry = false
    /// Inline repaint completion targets. The authority remains `.peer` while
    /// these are armed, keeping the veil above the terminal until captured tmux
    /// truth has actually been fed into every visible surface.
    @ObservationIgnored private var gridAuthorityRepaintWindow: WindowId?
    @ObservationIgnored private var gridAuthorityRepaintPanes: Set<PaneId> = []
    /// P8: the claim's visible repaint, sent in the fence's own burst when
    /// the claim cannot change geometry. tmux runs it after the fence, so
    /// its capture is the frame the confirmation would otherwise have asked
    /// for one round trip later. `relied` marks that confirmation adopted
    /// it instead of requesting its own; a failure then falls back.
    private struct GridAuthorityClaimRepaintInFlight {
        let claimGeneration: UInt64
        let fenceID: UInt64
        let window: WindowId?
        let panes: Set<PaneId>
        var relied = false
    }
    @ObservationIgnored private var gridAuthorityClaimRepaintInFlight: GridAuthorityClaimRepaintInFlight?
    #if DEBUG
    var gridAuthorityRepaintPaneTargetsForTesting: Set<PaneId> {
        gridAuthorityRepaintPanes
    }

    var gridAuthorityRepaintWindowTargetForTesting: WindowId? {
        gridAuthorityRepaintWindow
    }

    var gridAuthorityDeliveryRetryAttemptsForTesting: Int {
        gridAuthorityDeliveryRetryAttempts
    }

    var gridAuthorityClaimFenceAcknowledgedForTesting: Bool {
        gridAuthoritySession.claimFence?.acknowledged ?? false
    }

    var stamplessPeerRejudgePendingForTesting: Bool {
        gridAuthoritySession.stamplessJudge.deferred != nil
    }

    /// Advances the session's injected clock without a tick. Its recorded
    /// advertisement stays unchanged; the next event sees the elapsed time.
    func backdateLastClientSizeReplayForTesting(by seconds: TimeInterval) {
        advanceGridAuthorityClockForTesting(by: Int64(seconds * 1_000), tick: false)
    }

    func advanceGridAuthorityClockForTesting(by milliseconds: Int64, tick: Bool = true) {
        let clock = gridAuthorityNow
        gridAuthorityNow = { clock() + milliseconds }
        if tick { applyGridAuthorityLifecycleEffects(reduceGridAuthority(.tick)) }
    }

    var gridAuthoritySessionForTesting: TmuxGridAuthoritySession { gridAuthoritySession }

    /// Advances to the shared judge's deadline and ticks the same session.
    func finishStamplessPeerEchoForTesting() {
        guard let deadline = gridAuthoritySession.stamplessJudge.nextDeadline else { return }
        advanceGridAuthorityClockForTesting(by: max(0, deadline - gridAuthorityNow()))
    }

    /// Models a real connection boundary, including the shared reset.
    func advanceControlConnectionGenerationForTesting() {
        controlConnectionGeneration &+= 1
        resetGridAuthorityState(preserveYieldedPresentation: true)
    }

    /// Isolates a stale projection from the reset/claim effects around it.
    func deferGridAuthorityWireTargetForTesting() {
        activeWindowId = nil
        renderedWindowId = nil
    }

    /// A foreground read without the app's independent repaint, so a test
    /// can see exactly what the authority verdict releases.
    func rereadGridAuthorityForTesting() {
        applyGridAuthorityLifecycleEffects(
            reduceGridAuthority(.foregrounded)
        )
    }

    var gridAuthorityDeliveryRetryPaneTargetsForTesting: Set<PaneId> {
        gridAuthorityDeliveryRetryPanes
    }

    func armGridAuthorityDeliveryRetryForTesting(panes: Set<PaneId>) {
        gridAuthorityRepaintPanes = panes
    }

    func scheduleGridAuthorityDeliveryRetryForTesting(panes: Set<PaneId>) {
        scheduleGridAuthorityDeliveryRetry(
            rejectedWindows: [],
            rejectedPanes: panes
        )
    }

    func setGridAuthorityGeometryPolicyForTesting(latest: Bool) {
        guard let window = activeWindowId else { return }
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.windowSizePolicyReplied(
            windowID: window.rawValue, raw: latest ? "latest" : "smallest"
        )))
    }

    func expireGridAuthorityReclaimPresentationForTesting() {
        guard gridAuthorityLifecycle.claim?.presentationVisible == true else { return }
        advanceGridAuthorityClockForTesting(by: gridAuthoritySession.configuration.claimPresentationMillis)
    }

    var gridAuthorityLifecycleForTesting: TmuxGridAuthorityLifecycleReducer {
        gridAuthorityLifecycle
    }

    var gridAuthorityGeometryHeldForTesting: Bool { gridAuthorityGeometryHeld }

    var gridAuthorityQueriesInFlightForTesting: Int { gridAuthoritySession.query.current == nil ? 0 : 1 }

    var gridAuthorityHasHeldReplyForTesting: Bool { gridAuthoritySession.query.held != nil }

    func expireGridAuthorityIntentForTesting() {
        guard let deadline = gridAuthoritySession.intentClock.deadline else { return }
        advanceGridAuthorityClockForTesting(by: max(0, deadline - gridAuthorityNow()))
    }
    #endif
    /// Side-channel repaint acknowledgement. Mosh rendering is asynchronous
    /// to `-CC`; the app clears this only after the forced framebuffer output
    /// has actually been consumed by the terminal surface.
    @ObservationIgnored private var gridAuthoritySideChannelRepaintPending = false
    /// Per-*issue* token handed to the platform and echoed back on its ack.
    /// The ledger owns the reservation; this only answers "which issue of it
    /// is this ack for", so a frame forced before a re-issue cannot discharge
    /// the one forced after it.
    @ObservationIgnored private var gridAuthoritySideChannelRepaintGeneration: UInt64 = 0
    @ObservationIgnored private var gridAuthorityTransportFrameCorrelation: UInt64?
    @ObservationIgnored private var gridAuthorityTransportFrameOwner: RenderOwner?
    /// Set when a geometry settle is observed mid-step, drained at the end
    /// of that step, once the ledger has reduced it
    /// (`finishDeferredGridClaimConfirmation`). See `handleLayoutChange`.
    /// `depth` is the `controlProcessingDepth` of the step that left it: a
    /// nested step (a synchronous reply ingested from inside the outer
    /// step) ends before the outer ledger reduce and must not drain it.
    @ObservationIgnored private var deferredGridClaimConfirmation: (context: String, depth: Int)?
    /// Bumped whenever the claim's geometry changes (an advertisement, a
    /// re-fence): a settle probe written for older geometry, or a fence
    /// acknowledged after newer geometry went out, proves nothing about the
    /// geometry now in flight (§6.10 rule 5).
    @ObservationIgnored private var gridClaimGeometryEpoch: UInt64 = 0
    /// The claim's own commands still awaiting their replies (policy probe,
    /// fence, re-fence, settle probe, side-channel window force), counted
    /// for `gridClaimCommandsGeneration` only. A late claim with none left
    /// and no repaint in flight cannot progress (§6.10 rule 6).
    @ObservationIgnored private var gridClaimCommandsInFlight = 0
    @ObservationIgnored private var gridClaimCommandsGeneration: UInt64 = 0
    /// Set when the side-channel confirmation asked the ledger for the
    /// claim's transport frame; the frame may be requested a turn later.
    @ObservationIgnored private var gridClaimSideChannelRepaintRequested = false
    private var gridAuthorityRederiveInFlight: Bool {
        let query = gridAuthoritySession.query
        return query.current != nil || query.held != nil || query.retryAt != nil || query.wanted
    }
    /// Wire confirmation uses only the policy probed for its current window.
    private var gridAuthorityGeometryPolicyKnown: Bool { currentGridAuthorityPolicy != nil }
    private var gridAuthorityGeometryPolicyIsLatest: Bool { currentGridAuthorityPolicy?.isLatest ?? true }
    private var currentGridAuthorityPolicy: TmuxAuthorityGeometryEvidence.WindowSizePolicy? {
        (activeWindowId ?? renderedWindowId).flatMap { gridAuthoritySession.evidence.policy(for: $0.rawValue) }
    }
    private struct WindowSizeReplayAttempt: Equatable {
        let token: UInt64
        let connectionGeneration: UInt64
        let requested: TmuxClientGeometry
    }
    @ObservationIgnored private var windowSizeReplayAttempts: [WindowId: WindowSizeReplayAttempt] = [:]
    @ObservationIgnored private var nextWindowSizeReplayToken: UInt64 = 0
    @ObservationIgnored private var reconcilingPresentedWindowSize = false
    @ObservationIgnored private var presentedWindowRecoveryReserved = false
    private struct PassiveWindowSizeProbe: Equatable {
        let token: UInt64
        let connectionGeneration: UInt64
        let windowID: WindowId
        let requested: TmuxClientGeometry
        let observed: TmuxClientGeometry?
        let authorityGeneration: UInt64
    }
    @ObservationIgnored private var passiveWindowSizeProbe: PassiveWindowSizeProbe? {
        didSet {
            guard oldValue != nil, oldValue != passiveWindowSizeProbe,
                  gridAuthoritySession.ordinaryRecoveryActive, !presentedWindowRecoveryReserved else { return }
            applyGridAuthorityLifecycleEffects(reduceGridAuthority(.ordinaryRecovery(active: false, proven: false)))
        }
    }
    /// Called after tmux acknowledges the authoritative grid cache and before
    /// the visible owner is excluded from sizing. App/session owners persist
    /// this grid beyond the lifetime of the current control connection.
    @ObservationIgnored public var onServerGeometryCeded: ((Int, Int) -> Void)?
    public let clientSizePolicy: ClientSizePolicy

    /// Monotonic state epoch used to ignore stale attach, reconnect,
    /// window-switch, and capture callbacks. Every authoritative
    /// tmux-focus transition advances it before queueing new queries.
    @ObservationIgnored private var stateGeneration: Int = 0

    /// Identity of the terminal surface's currently authoritative tmux
    /// rendering continuity. This deliberately does not track
    /// `stateGeneration`: foreground viewport repairs advance the latter to
    /// invalidate asynchronous callbacks, while retaining the already-bound
    /// SwiftTerm buffer and therefore this owner epoch.
    @ObservationIgnored private var renderOwnerEpoch: UInt64 = 0

    /// The tmux session id (`$N`) this controller is attached to.
    ///
    /// tmux runs ONE server per user; multiple sessions live inside it.
    /// A `-CC` control client receives some notifications scoped to its
    /// own session (tmux filters those server-side) but a few — notably
    /// `%session-window-changed` and the per-pane metadata subscriptions
    /// — are BROADCAST to every control client in the server, each
    /// tagged with the session id they refer to. It is the client's job
    /// to ignore the ones for other sessions. Without this, two Tessera
    /// clients attached to different sessions of the same server (e.g.
    /// an iPad and the simulator both hitting one Mac) would drag each
    /// other's active window around.
    ///
    /// Latched from `%session-changed` / `%client-session-changed`, which
    /// tmux emits right after the DCS prologue on `-CC` attach — before
    /// any `%session-window-changed` could arrive. Stays `nil` until then;
    /// the cross-session filters FAIL OPEN while it is `nil` so the
    /// single-client path can never regress.
    @ObservationIgnored private(set) var ownSessionId: SessionId?
    @ObservationIgnored private var ownSessionName: String?

    /// Lifecycle is a platform fact; foreground byte retention and release are
    /// owned entirely by `renderLedger`.
    @ObservationIgnored private var appIsInactive = false
    /// An owner replay the session released while the app was still
    /// inactive (a foreground read answered before activation). The session
    /// already counted that edge as replayed and will not release it again,
    /// so activation sends it.
    @ObservationIgnored private var gridAuthorityOwnerReplayDeferred = false
    @ObservationIgnored private var windowBellFlags: [WindowId: Bool] = [:]

    /// Maps every known pane to its owning window, rebuilt from window
    /// layouts. This makes `windowInfo(forPaneId:)` exact for *non-active*
    /// panes — which fixes the dropped-bell bug for background panes, and is
    /// the routing index split rendering needs. A pane absent from any layout
    /// (pre-hydration) falls back to the active-pane heuristics.
    @ObservationIgnored private var paneWindowTable: [PaneId: WindowId] = [:]

    /// Per-pane render sinks for the multi-pane grid path. When a window
    /// mounts the pane grid, the app registers one sink per visible pane; that
    /// pane's `%output` (and capture-repaint) then routes to its own terminal
    /// surface instead of the shared single-pane terminal. Empty = no grid =
    /// today's single-pane fast path (byte-identical, golden-pinned).
    @ObservationIgnored private var paneSinks: [PaneId: (ArraySlice<UInt8>) -> Void] = [:]
    private struct PaneRenderSurfaceAdapter {
        let bind: (TmuxControlCore.RenderOwner, Int) -> Void
        let feed: (TmuxControlCore.RenderOwner, ArraySlice<UInt8>) -> Void
        let state: () -> (
            altScreen: Bool,
            mouseMode: RenderMouseMode,
            columns: Int,
            rows: Int
        )?
    }
    @ObservationIgnored private var paneRenderSurfaces: [PaneId: PaneRenderSurfaceAdapter] = [:]

    /// Pending pane-focus latch (iTerm2's `_paneToActivateWhenCreated`).
    /// `%window-pane-changed @w %p` is BROADCAST to every control client with NO
    /// session filter (control-notify.c), so it can name a window we don't track
    /// — a foreign session's window, or a same-session window whose
    /// `%window-add`/hydration hasn't landed yet. We refuse to `ensureWindow`-
    /// create from that notification (it would leak a foreign window as a
    /// phantom tab); instead we stash the focus here keyed by window id and
    /// apply it via `drainPendingPaneFocus` if/when the window legitimately
    /// appears (`%window-add`, `%session-window-changed` — both session-scoped).
    /// A foreign window never appears through those paths, so its stash is never
    /// applied; the whole table is dropped at hydration (the authoritative
    /// active-pane snapshot) and on reset.
    @ObservationIgnored private var pendingPaneFocus: [WindowId: PaneId] = [:]

    /// (Mosh/side-channel only) Windows we've toggled tmux's native per-pane
    /// title row on. On the side channel the remote tmux client paints panes
    /// natively, so per-pane titles come from tmux's `pane-border-status top`
    /// (Tessera overlays a ✕ on top). It's a *window* option that also adds a
    /// title row to single-pane windows, so we toggle it per-window only across
    /// the 1↔N pane transition (probed: session/global targets either miss new
    /// windows or shrink single-pane windows). Membership = "currently set to
    /// top", so a geometry-only `%layout-change` doesn't resend it.
    @ObservationIgnored private var moshPaneBorderWindows: Set<WindowId> = []

    /// `pane-border-format` mirroring the SSH pane-header title policy: show the
    /// app-set pane title, falling back to the foreground command when the title
    /// is still tmux's default (the hostname). Left-aligned with padding; the
    /// Tessera ✕ overlay sits over the right end.
    static let moshPaneBorderFormat =
        " #[align=left]#{?#{||:#{==:#{pane_title},#{host}},#{==:#{pane_title},#{host_short}}},#{pane_current_command},#{pane_title}} "

    /// Owned by `TmuxPaneMetadataSubscription` so the subscribed field order
    /// and the parser can never drift, on this platform or any other.
    static let paneMetadataSubscriptionName = TmuxPaneMetadataSubscription.name
    static let paneMetadataSubscriptionFormat = TmuxPaneMetadataSubscription.format
    static let renderedPaneMetadataFormat = RenderCommands.renderedPaneMetadataFormat

    /// False immediately after DCS entry; the first server-originated
    /// `%end` frame (flags bit0 clear) completes the control-mode
    /// handshake and starts attach hydration.
    @ObservationIgnored private var attachInitFlushed = false
    /// One probe per controller lifetime: the answer is a property of the
    /// host's tmux build, not of any single attach.
    /// Whether hydration may append the one-shot separator diagnostics
    /// probe to the command FIFO. Only the production session wiring opts
    /// in; scripted positional-reply consumers (tests, debug harnesses)
    /// keep the golden frame count.
    @ObservationIgnored private let separatorProbeEnabled: Bool
    @ObservationIgnored private var sentSeparatorProbe = false
    private struct PendingCommand {
        /// Tag allocated by the shared command FIFO. Sequence remains a
        /// human-friendly monotonic diagnostic counter only.
        let tag: UInt64
        let sequence: Int
        let command: String
        /// Transmit instant, for oldest-pending-age poisoning detection.
        let transmittedAt: ContinuousClock.Instant
        /// Caller-supplied correlation tag (e.g. the shared session
        /// adapter's input receipt) carried into transmit/response logs so
        /// one device log can follow a keystroke across layers.
        let correlation: String?
        let completion: (Result<[String], CommandError>) -> Void
    }

    /// Opaque per-controller tag. Diagnostics exports can contain several live
    /// sessions whose lines otherwise look identical after endpoint redaction.
    private let diagnosticID = String(UUID().uuidString.prefix(8))

    /// Called with bytes destined for the terminal renderer.
    /// Set by the owner after construction; nil by default.
    @ObservationIgnored public var feedTerminal: ((ArraySlice<UInt8>) -> Void)? {
        didSet { noteGridAuthorityPaintable() }
    }

    /// Source-aware variant of `feedTerminal`. When set, it takes precedence
    /// over the legacy closure so existing package clients remain compatible.
    @ObservationIgnored public var feedTerminalWithContext: ((ArraySlice<UInt8>, TerminalFeedContext) -> Void)? {
        didSet { noteGridAuthorityPaintable() }
    }

    /// Called with bytes destined for the SSH channel upstream.
    /// Set by the owner after construction; nil by default.
    @ObservationIgnored public var sendBytes: (([UInt8]) -> Void)?
    /// Synchronous admission into the ordered writer for the current PTY or
    /// control channel. When set, takes precedence over sendBytes for control
    /// commands; false means the transport withheld or dropped the bytes.
    /// Record sizing before any reply can be ingested, rather than waiting
    /// for a write-completion callback that can arrive after tmux's layout.
    @ObservationIgnored public var sendBytesAdmitting: (([UInt8]) -> Bool)?
    /// Metadata-only bridge for correlating an input receipt with the actual
    /// transport write. Called synchronously immediately before admission.
    @ObservationIgnored public var commandWriteDiagnostic: ((Int, String?) -> Void)?

    /// Called with decoded `%output` bytes before renderer routing so the
    /// owner can synthesize terminal replies without waiting on the
    /// rendered terminal view's delegate round trip.
    @ObservationIgnored public var terminalResponseForOutput: ((_ paneId: PaneId, _ data: ArraySlice<UInt8>) -> [UInt8]?)?

    /// Fired just before the shared terminal is repainted with a different
    /// window's content. Parameters: the previously rendered window (nil on
    /// the first swap after attach), the window about to be rendered, and
    /// whether tmux reports the incoming pane is in the alternate screen.
    @ObservationIgnored public var displayWillSwap: ((_ from: WindowId?, _ to: WindowId, _ paneInAltScreen: Bool) -> Void)?
    /// Owner-aware form of `displayWillSwap`. The platform adapter uses the
    /// context to bind its render surface immediately before the authoritative
    /// repaint feed. Keeping the context-free hook preserves source
    /// compatibility for package clients that do not expose a render surface.
    @ObservationIgnored public var displayWillSwapWithContext: ((
        _ from: WindowId?,
        _ context: TerminalFeedContext,
        _ paneInAltScreen: Bool
    ) -> Void)?
    /// Fired after the repaint bytes for `windowId` have been fed and the
    /// rendered ids committed. App layer uses it to re-run find and restore
    /// per-window client-side modes.
    @ObservationIgnored public var displayDidSwap: ((_ windowId: WindowId) -> Void)?
    /// App-layer diagnostics hook. The controller fires this immediately
    /// before lifecycle boundaries can replace render owners or dismantle
    /// surfaces, allowing the platform seam to publish one aggregate
    /// `dropped_foreign` count without moving diagnostics policy into the
    /// portable reducer.
    @ObservationIgnored public var renderDropSummaryBoundary: ((_ boundary: String) -> Void)?
    /// Fired after an already-rendered pane is repaired in place. Unlike
    /// `displayDidSwap`, this must not restore per-window modes; the app uses it
    /// only to refresh derived viewport state such as Find matches.
    @ObservationIgnored public var displayDidRefresh: ((_ windowId: WindowId) -> Void)?
    /// App-layer answer to "is the shared SwiftTerm terminal currently on
    /// the alternate-screen buffer". Consulted when assembling repaints.
    @ObservationIgnored public var terminalIsInAltScreen: (() -> Bool)?

    // MARK: Shared render-ledger platform seam

    /// Platform surface hooks used by the portable ledger. Apps with only one
    /// shared surface may leave these nil; the controller bridges `.live`
    /// through the context-aware compatibility callbacks above.
    @ObservationIgnored public var renderBindSurface: ((SurfaceId, TmuxControlCore.RenderOwner) -> Void)?
    /// Returns true only when the exact owner-qualified bytes were accepted by
    /// a mounted surface. Authority stays fail-closed if the surface vanished
    /// or rejected a stale owner between capture and delivery.
    @ObservationIgnored public var renderFeedSurface: ((SurfaceId, TmuxControlCore.RenderOwner, ArraySlice<UInt8>, RenderFeedSource) -> Bool)? {
        didSet { noteGridAuthorityPaintable() }
    }

    struct AuthorityDeliveryTally {
        private(set) var acceptedWindows: Set<WindowId> = []
        private(set) var rejectedWindows: Set<WindowId> = []
        private(set) var acceptedPanes: Set<PaneId> = []
        private(set) var rejectedPanes: Set<PaneId> = []

        mutating func record(
            accepted: Bool,
            surfaceID: SurfaceId,
            owner: TmuxControlCore.RenderOwner,
            source: RenderFeedSource
        ) {
            switch source {
            case .viewportRepaint, .viewportRefresh, .deepRepaint, .repaintScrub:
                if surfaceID == .live, let windowID = owner.windowID {
                    if accepted {
                        acceptedWindows.insert(windowID)
                    } else {
                        rejectedWindows.insert(windowID)
                    }
                } else if let paneID = owner.paneID {
                    if accepted {
                        acceptedPanes.insert(paneID)
                    } else {
                        rejectedPanes.insert(paneID)
                    }
                }
            case .paneOutput, .foregroundReplay, .moshHistory:
                break
            }
        }

        var completedWindows: Set<WindowId> {
            acceptedWindows.subtracting(rejectedWindows)
        }

        var completedPanes: Set<PaneId> {
            acceptedPanes.subtracting(rejectedPanes)
        }
    }

    @ObservationIgnored public var renderSurfaceState: ((SurfaceId) -> (
        altScreen: Bool,
        mouseMode: RenderMouseMode,
        columns: Int,
        rows: Int
    )?)?
    @ObservationIgnored public var renderSaveWindowModes: ((SurfaceId, WindowId) -> Void)?
    @ObservationIgnored public var renderRestoreWindowModes: ((SurfaceId, WindowId, Bool) -> Void)?
    @ObservationIgnored public var renderHistoryReady: ((
        SurfaceId,
        TmuxControlCore.RenderOwner,
        Int,
        Int,
        RenderHistoryPlacement
    ) -> Void)?
    /// Inline (SSH+tmux) history settle hook: surface, owner, credited
    /// depth, tmux `history_size`, and whether a later `scrollbackRequested`
    /// can still deepen. Follows the `.deep` feed it describes.
    @ObservationIgnored public var renderInlineHistorySettled: ((
        SurfaceId,
        TmuxControlCore.RenderOwner,
        Int,
        Int,
        Bool
    ) -> Void)?
    @ObservationIgnored public var requestTransportFullFrame: (() -> Void)?
    /// History depth (lines) for the first inline deep repaint stage. The
    /// ledger deepens to the scrollback limit on demand.
    public var deepRepaintHistoryDepth: Int = 2000

    public var initialRenderWatchdogInterval: TimeInterval = 4.0
    public var renderRefreshRetryDelay: TimeInterval = 0.5
    /// Established repaints prefer an empty command FIFO so metadata and
    /// capture callbacks cannot inherit an older consumer's response body.
    /// The wait is bounded: resize/input traffic can otherwise keep one
    /// command perpetually in flight and starve the authoritative repaint.
    var renderCommandQueueMaxWait: TimeInterval = 0.25

    /// Hard cap for output retained across inactive→foreground recovery.
    /// Ordinary textual output stays below this. Full-screen redraw storms can
    /// exceed it quickly (the live regression is ~460 KiB split across two
    /// retained phases); replaying those batches blocked SwiftTerm on the old
    /// frame for several seconds. On overflow we discard that pane's whole
    /// retained stream — never a truncated escape sequence — and trust the
    /// viewport capture for visible truth.
    public var maxForegroundOutputBytes = 64 * 1024

    /// Max capture-repaint attempts per generation before we stop re-trying and
    /// rely on the live-output fallback alone. Must be > 1: tmux returns empty
    /// render metadata for several seconds right after the app resumes from the
    /// background (foreground restore), so a single retry gives up while the
    /// control channel is still recovering and the active window never repaints
    /// — leaving the pre-background screen (another tmux window's content) to
    /// bleed through. Retrying with backoff lets the repaint land the moment the
    /// channel recovers, which clears the stale content.
    public var maxRenderRefreshAttempts: Int = 8

    private static let defaultColorProbeQueryBytes = Array("\u{1B}]10;?\u{1B}\\\u{1B}]11;?\u{1B}\\".utf8)

    /// tmux server version learned from the attach-time separator probe
    /// (`#{version}`, e.g. "3.4" or "3.6a"). Nil until that reply lands.
    @ObservationIgnored private(set) var serverVersion: String?

    /// `refresh-client -r` (a control client's colour report for a pane)
    /// exists from tmux 3.5. Nil while the version is unknown; the report
    /// path then assumes support, which is also the pre-existing behavior.
    var serverSupportsClientReports: Bool? {
        serverVersion.map(Self.versionSupportsClientReports)
    }

    @ObservationIgnored public var onBell: ((_ windowID: Int, _ isActiveWindow: Bool, _ windowName: String?) -> Void)?

    /// A tmux paste buffer changed and its text was fetched. This is how
    /// `/copy` in Codex (and any `tmux load-buffer -w` / copy-mode yank)
    /// reaches the device clipboard: tmux forwards OSC 52 only to real
    /// ttys, so a control-mode client must mirror the buffer itself.
    @ObservationIgnored public var onPasteBufferChanged: ((_ name: String, _ text: String) -> Void)?

    /// Called when a tmux control command issued by a pane operation
    /// (split / kill / zoom / select) fails with `%error`. The payload is the
    /// joined error body, e.g. "create pane failed: pane too small" — the app
    /// surfaces it as a transient toast. Min-pane-size and dead-pane errors are
    /// server-enforced, so this is the only place they can be reported; never
    /// pre-validate. nil by default.
    @ObservationIgnored public var onCommandError: ((_ message: String) -> Void)?

    /// Queried right before a per-pane capture-repaint is assembled: is the
    /// pane's LOCAL terminal currently on the alternate screen? A pane
    /// surface starts on the normal buffer at mount, but live `%output`
    /// (vim/htop sending 1049h) moves it — and a repaint assembled for the
    /// wrong buffer corrupts it: without a leading `?1049l`, the saved-
    /// primary rows print INTO the live alt screen and the `?1049h` that
    /// follows is a no-op on a terminal already in alt (no clear, no
    /// switch), leaving stale primary fragments behind the TUI's rows.
    /// nil / unset falls back to the mount-time assumption (normal buffer).
    @ObservationIgnored public var paneLocalAltScreenProbe: ((_ paneId: PaneId) -> Bool)?

    /// Fired after a per-pane capture-repaint has been fed to a pane's sink.
    /// The app uses it to restore per-pane client-side modes (kitty), re-run
    /// find against the focused pane, and drive multi-pane launch readiness.
    @ObservationIgnored public var paneDidRefresh: ((_ paneId: PaneId) -> Void)?

    /// Fired when tmux emits `%output` / `%extended-output` for a pane. Side-
    /// channel mosh mode does not render these bytes, but the app can use the
    /// pane id as a best-effort invalidation signal for derived UI such as
    /// pane-local scrollback overlays.
    @ObservationIgnored public var paneDidOutput: ((_ paneId: PaneId) -> Void)?

    /// Raw per-pane output tap for consumers that need the bytes before render
    /// routing (Agent Center prompt/echo observation). Kept separate from
    /// `paneDidOutput` so existing mosh scrollback invalidation remains a
    /// single-owner callback. The observer must stay cheap; expensive capture
    /// work is expected to coalesce off this pulse.
    @ObservationIgnored public var paneOutputObserver: ((_ paneId: PaneId, _ data: ArraySlice<UInt8>) -> Void)?

    // MARK: Program status (OSC 7501)

    /// Status records that programs report about themselves, per pane and for
    /// the raw terminal. Published only when a record changes.
    public private(set) var programStatus: ProgramStatusSnapshot = .empty
    /// Off for package clients; the app sets it from its preference. Turning
    /// it off discards every record and stops the raw-SSH query reply.
    public var programStatusEnabled = false {
        didSet {
            guard programStatusEnabled != oldValue else { return }
            programStatusMonitor.isEnabled = programStatusEnabled
            executeRenderEffects(renderLedger.reduce(
                .programStatusPaneOutput(enabled: programStatusEnabled),
                snapshot: runtimeEngine.snapshot
            ))
            Self.logDiagnostic("program-status enabled=\(programStatusEnabled)")
            publishProgramStatus()
        }
    }
    @ObservationIgnored private var programStatusMonitor: ProgramStatusMonitor = {
        var monitor = ProgramStatusMonitor(answersQueries: true)
        monitor.isEnabled = false
        return monitor
    }()
    @ObservationIgnored private var programStatusAttentionCount = 0

    /// Marks one terminal's results up to `token` checked: the user has been
    /// shown that pane. Blocked records are never acknowledged.
    public func acknowledgeProgramStatus(terminal: ProgramStatusTerminalKey, through token: UInt64) {
        guard programStatusMonitor.acknowledge(terminal: terminal, through: token) else { return }
        publishProgramStatus()
    }

    private func observeProgramStatus(_ batch: TmuxRuntimeBatch) {
        guard programStatusEnabled else { return }
        programStatusMonitor.observe(batch: batch)
        publishProgramStatus()
    }

    /// Raw-terminal output. Tessera is the terminal here, so a detection
    /// query is answered before the bytes reach the emulator: the reply
    /// precedes its DA1 answer to a `CSI c` that follows the query. Only the
    /// inline path's passthrough is the user's terminal; a side channel's is
    /// an SSH exec stream.
    private func observeRawProgramStatus(_ bytes: ArraySlice<UInt8>) {
        guard programStatusEnabled, controlPath == .inline else { return }
        let reply = programStatusMonitor.feed(bytes, terminal: .raw)
        if !reply.isEmpty {
            Self.logDiagnostic("program-status query-reply bytes=\(reply.count)")
            sendBytes?(reply)
        }
        publishProgramStatus()
    }

    private func publishProgramStatus() {
        guard programStatusMonitor.revision != programStatus.revision else { return }
        let snapshot = programStatusMonitor.snapshot()
        programStatus = snapshot
        let attention = snapshot.terminals.count { $0.attention != nil }
        if attention != programStatusAttentionCount {
            programStatusAttentionCount = attention
            Self.logDiagnostic("program-status terminals=\(snapshot.terminals.count) attention=\(attention)")
        }
    }

    /// Retained semantic Agent Center state published by a remote hook as a
    /// pane user option. Format subscriptions replay this value to a fresh
    /// control client after app/session restoration.
    @ObservationIgnored public var paneAgentStateObserver: ((_ paneId: PaneId, _ json: String) -> Void)?

    /// User-originated bytes routed through this controller. Agent Center uses
    /// this only to resolve an already-known blocking prompt immediately; it
    /// never treats arbitrary typing as evidence of agent activity.
    @ObservationIgnored public var inputObserver: ((_ paneId: PaneId?, _ bytes: [UInt8]) -> Void)?

    public init(
        authorityInitialGeneration: UInt64? = nil,
        controlPath: ControlPath = .inline,
        clientSizePolicy: ClientSizePolicy = .resizeTmux,
        separatorProbeEnabled: Bool = false,
        authorityConfiguration: TmuxGridAuthoritySession.Configuration = .init(),
        authorityNow: (() -> Int64)? = nil
    ) {
        self.controlPath = controlPath
        self.clientSizePolicy = clientSizePolicy
        self.separatorProbeEnabled = separatorProbeEnabled
        gridAuthoritySession = TmuxGridAuthoritySession(configuration: authorityConfiguration, initialGeneration: authorityInitialGeneration ?? TmuxGridAuthorityStamp.generationBase(
            unixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
        ))
        if let authorityNow { gridAuthorityNow = authorityNow }
        #if canImport(UIKit)
        if UIApplication.shared.applicationState == .background {
            _ = gridAuthoritySession.reduce(.backgrounded, now: gridAuthorityNow())
        }
        gridAuthorityBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.gridAuthorityBackgrounded() }
        }
        gridAuthorityForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Let the slot coordinator deliver any hide owed during sleep first.
            Task { @MainActor [weak self] in self?.gridAuthorityForegrounded() }
        }
        // A restored session builds its controller while a cold launch still
        // reads `applicationState` as background, and that launch posts no
        // willEnterForeground: becoming active ends the background, or its
        // show would wait for a foreground read that never comes. Resigning
        // proves nothing (inactive is transparent), so it is not observed.
        gridAuthorityActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.gridAuthoritySession.inBackground else { return }
                Self.logDiagnostic("grid-authority foregrounded reason=became-active")
                self.gridAuthorityForegrounded()
            }
        }
        #endif
        // Policy is fixed at construction. This also projects the initial
        // background reduction before any transport or identity is supplied.
        runtimeEngine.projectAuthority(
            participatesInGridAuthority ? gridAuthorityLifecycle.authority : .unknown
        )
    }

    deinit {
        gridAuthorityWakeTask?.cancel()
        #if canImport(UIKit)
        if let gridAuthorityBackgroundObserver { NotificationCenter.default.removeObserver(gridAuthorityBackgroundObserver) }
        if let gridAuthorityForegroundObserver { NotificationCenter.default.removeObserver(gridAuthorityForegroundObserver) }
        if let gridAuthorityActiveObserver { NotificationCenter.default.removeObserver(gridAuthorityActiveObserver) }
        #endif
    }

    /// Convert the Apple rendering projection into the typed metadata shape
    /// accepted by the portable owner. Callers use this only at validated
    /// fixed-query/subscription boundaries, never to replace a whole runtime
    /// snapshot.
    private func coreWindowMetadata(_ window: WindowInfo) -> TmuxWindowSnapshot {
        TmuxWindowSnapshot(
            id: window.id,
            index: window.index,
            name: window.windowName,
            activePaneID: window.activePaneId,
            activePaneTitle: window.activePaneTitle,
            activePaneTitleIsDefault: window.activePaneTitleIsDefault,
            panes: window.panes.map { pane in
                TmuxPaneSnapshot(
                    id: pane.id,
                    title: pane.title,
                    titleIsDefault: pane.titleIsDefault,
                    currentCommand: pane.currentCommand,
                    isActive: pane.isActive,
                    isAlternateScreen: pane.isAlternateScreen,
                    isMouseReporting: pane.isMouseReporting,
                    isSgrMouse: pane.isSgrMouse,
                    contentRect: pane.contentRect
                )
            },
            layout: window.layout,
            visibleLayout: window.visibleLayout,
            isZoomed: window.isZoomed
        )
    }

    private func publishWindowMetadataToCore(_ windowID: WindowId) {
        guard let window = window(windowID),
              runtimeEngine.ingestWindowPresentation(coreWindowMetadata(window))
        else { return }
    }

    private func publishWindowListQueryToCore() {
        let query = windows.map(coreWindowMetadata)
        _ = runtimeEngine.ingestWindowListQuery(query)
    }

    /// Refresh the Apple Observation projection from the portable owner. The
    /// projection deliberately carries no independent policy state.
    private func projectCoreSnapshot(_ supplied: TmuxSnapshot? = nil) {
        let core = supplied ?? runtimeEngine.snapshot
        let projectedWindows = core.windows.map { window in
            let panes = window.panes.map { pane in
                PaneInfo(
                    id: pane.id,
                    title: pane.title,
                    titleIsDefault: pane.titleIsDefault,
                    isActive: pane.isActive,
                    currentCommand: pane.currentCommand,
                    isAlternateScreen: pane.isAlternateScreen,
                    isMouseReporting: pane.isMouseReporting,
                    isSgrMouse: pane.isSgrMouse,
                    contentRect: pane.contentRect
                )
            }
            return WindowInfo(
                id: window.id,
                index: window.index,
                windowName: window.name,
                activePaneId: window.activePaneID,
                activePaneTitle: window.activePaneTitle,
                activePaneTitleIsDefault: window.activePaneTitleIsDefault,
                panes: panes,
                layout: window.layout,
                visibleLayout: window.visibleLayout,
                isZoomed: window.isZoomed
            )
        }
        if windows != projectedWindows { windows = projectedWindows }
        ownSessionId = core.sessionID
        ownSessionName = core.sessionName
        activeWindowId = core.activeWindowID
        let projectedActiveWindow = core.activeWindowID.flatMap { activeID in
            projectedWindows.first { $0.id == activeID }
        }
        activePaneId = projectedActiveWindow?.activePaneId
            ?? runtimeEngine.activeRoutingPaneID
        rebuildPaneWindowTable()
        // `gridAuthority` has exactly one source: the lifecycle reducer. The
        // runtime's own classification (subscription stamps, the stamp-less
        // fallback) reaches it only through `observedAuthority`, so a stale
        // runtime value can never re-project over a fresher reducer verdict.
        projectGridAuthority(gridAuthorityLifecycle.authority)
        snapshotObservationRevision = core.revision
        noteGridAuthorityWindowFacts(core)
        noteGridAuthorityPaintable()
    }

    private func projectGridAuthority(_ authority: TmuxGridAuthoritySnapshot) {
        switch authority {
        case .unknown:
            gridAuthority = .unknown
        case .mine:
            gridAuthority = .mine
        case .peer(_, let displayName, _):
            gridAuthority = .peer(displayName: displayName)
        }
    }

    // MARK: - Public API

    /// Declare the emulator surfaces currently mounted by the app. Inline
    /// single-pane mode normally declares `.live`; pane grids and mosh history
    /// overlays use stable pane-specific ids. The reducer immediately
    /// reconciles the declarations against the latest authoritative snapshot.
    public func declareRenderSurfaces(_ declarations: [SurfaceDeclaration]) {
        declareRenderSurfaces(declarations, snapshot: runtimeEngine.snapshot)
    }

    private func declareRenderSurfaces(
        _ declarations: [SurfaceDeclaration],
        snapshot: TmuxSnapshot
    ) {
        currentRenderDeclarations = declarations
        submitRenderFact(.surfacesDeclared(declarations), snapshot: snapshot)
        noteGridAuthorityPaintable()
    }

    /// Includes both the capture and its still-unacknowledged presentation.
    public func isHistoryPresentationPending(for surfaceID: SurfaceId) -> Bool {
        renderLedger.isHistoryPresentationPending(for: surfaceID)
    }

    /// Submit a platform observation to the portable render ledger and execute
    /// its effects synchronously, in order, on the main actor.
    public func submitRenderFact(_ fact: RenderFact) {
        submitRenderFact(fact, snapshot: runtimeEngine.snapshot)
    }

    private func submitRenderFact(_ fact: RenderFact, snapshot: TmuxSnapshot) {
        if case .scrollbackLimit(let lines) = fact {
            renderScrollbackLimit = max(0, lines)
        }
        updateRenderLedgerConfiguration()
        executeRenderEffects(
            renderLedger.reduce(fact, snapshot: snapshot),
            snapshot: snapshot
        )
    }

    private var defaultRenderSurfaceDeclaration: SurfaceDeclaration {
        SurfaceDeclaration(surfaceID: .live, presentation: .single)
    }

    @ObservationIgnored private var renderScrollbackLimit = 10_000
    @ObservationIgnored private var currentRenderDeclarations: [SurfaceDeclaration] = []

    private func updateRenderLedgerConfiguration(advertiseOnly: Bool = false) {
        renderLedger.updateConfiguration(.init(
            deepHistoryDepth: deepRepaintHistoryDepth,
            // A normal iPad flick plus release travels beyond 240 rows.
            // Keep enough initial history to avoid a second capture mid-glide.
            moshPageDepth: 512,
            scrollbackLimit: renderScrollbackLimit,
            commandQueueWaitMilliseconds: Int(max(0, renderCommandQueueMaxWait) * 1_000),
            renderRetryMilliseconds: Int(max(0, renderRefreshRetryDelay) * 1_000),
            initialRenderWatchdogMilliseconds: Int(max(0, initialRenderWatchdogInterval) * 1_000),
            maximumViewportRetryAttempts: maxRenderRefreshAttempts,
            maximumForegroundOutputBytes: maxForegroundOutputBytes,
            // An unstamped session's ordinary replay is a bare
            // `refresh-client -C`: no `select-window` latest fence (M3).
            inlineClientSizeReplayBelongsToClaim: advertiseOnly || gridClaimAwaitsFence
                || gridAuthorityOrdinaryGeometryIsUnstamped,
            // P6: every `-C` this controller sends goes through the ledger's
            // `.clientSize` replay, except the reverse-attach cede, which
            // reports its acknowledged size through `noteAppliedClientSize`;
            // that one is not trusted as advertised, so the next claim
            // re-sends its `-C`.
            suppressesUnchangedClientSizeReplay: true,
            // P8: visible captures ride with their metadata query, and the
            // claim's correlated repaint queues behind its own fence.
            pipelinesVisibleCapture: true
        ))
    }

    private func executeRenderEffects(
        _ effects: [RenderEffect],
        snapshot suppliedSnapshot: TmuxSnapshot? = nil
    ) {
        let effectSnapshot = suppliedSnapshot ?? runtimeEngine.snapshot
        var authorityDelivery = AuthorityDeliveryTally()
        var effectIndex = effects.startIndex
        while effectIndex < effects.endIndex {
            if case .sendCommand = effects[effectIndex] {
                var commandIndex = effectIndex
                var wireBytes: [UInt8] = []
                var publishedSize: TmuxClientGeometry?
                while commandIndex < effects.endIndex,
                      case .sendCommand(let command) = effects[commandIndex] {
                    let line = command.hasSuffix("\n") ? command : command + "\n"
                    Self.logDiagnostic(
                        "render-command-transmit controller=\(diagnosticID) pending=\(renderLedger.pendingCommandCount) commandCategory=\(Self.commandCategory(command))"
                    )
                    wireBytes.append(contentsOf: line.utf8)
                    publishedSize = Self.publishedClientSize(in: command) ?? publishedSize
                    commandIndex += 1
                }
                // Every purpose in this run was already appended to the core
                // FIFO by the reducer.  One transport call prevents a
                // synchronous write callback from inserting a platform query
                // between an authoritative metadata/capture pair.
                transmitControlBytes(wireBytes, publishedSize: publishedSize)
                effectIndex = commandIndex
                continue
            }

            let effect = effects[effectIndex]
            defer { effectIndex += 1 }
            switch effect {
            case .sendCommand:
                preconditionFailure("contiguous render commands are handled above")

            case .commandReply(let tag, let success, let lines, _):
                completePlatformCommand(tag: tag, success: success, lines: lines)

            case .bindSurface(let surfaceID, let owner):
                let previous = ledgerRenderedOwners[surfaceID]
                ledgerRenderedOwners[surfaceID] = owner
                if surfaceID == .live {
                    renderOwnerEpoch = owner.epoch
                }
                renderBindSurface?(surfaceID, owner)
                if renderBindSurface == nil,
                   surfaceID != .live,
                   let paneID = owner.paneID {
                    paneRenderSurfaces[paneID]?.bind(owner, renderScrollbackLimit)
                }
                if renderBindSurface == nil, surfaceID == .live,
                   let windowID = owner.windowID {
                    let feedSource = effects[effects.index(after: effectIndex)...]
                        .lazy
                        .compactMap { candidate -> RenderFeedSource? in
                            guard case .feed(
                                let candidateSurface,
                                let candidateOwner,
                                _,
                                let source
                            ) = candidate,
                                  candidateSurface == surfaceID,
                                  candidateOwner == owner,
                                  source != .foregroundReplay
                            else { return nil }
                            return source
                        }
                        .first
                    let context = terminalFeedContext(
                        owner: owner,
                        source: feedSource.map(terminalFeedSource) ?? .viewportRepaint,
                        originalByteCount: nil
                    )
                    let incomingAlt = owner.paneID.flatMap { paneID in
                        effectSnapshot.windows
                            .flatMap(\.panes)
                            .first(where: { $0.id == paneID })?
                            .isAlternateScreen
                    } ?? false
                    if let displayWillSwapWithContext {
                        displayWillSwapWithContext(previous?.windowID, context, incomingAlt)
                    } else {
                        displayWillSwap?(previous?.windowID, windowID, incomingAlt)
                    }
                }

            case .feed(let surfaceID, let owner, let reference, let source):
                guard let bytes = renderLedger.takeRenderBytes(reference) else {
                    Self.logDiagnostic(
                        "render-ledger missing-bytes-ref controller=\(diagnosticID) id=\(reference.rawValue)"
                    )
                    continue
                }
                let feedAccepted: Bool
                if let renderFeedSurface {
                    feedAccepted = renderFeedSurface(
                        surfaceID,
                        owner,
                        bytes[...],
                        source
                    )
                } else if surfaceID == .live {
                    feedAccepted = feedTerminalWithContext != nil || feedTerminal != nil
                    deliverToSharedTerminal(
                        bytes[...],
                        context: terminalFeedContext(
                            owner: owner,
                            source: terminalFeedSource(source),
                            originalByteCount: bytes.count
                        )
                    )
                } else if let paneID = owner.paneID,
                          let surface = paneRenderSurfaces[paneID] {
                    surface.feed(owner, bytes[...])
                    feedAccepted = true
                } else if let paneID = owner.paneID,
                          let legacySink = paneSinks[paneID] {
                    legacySink(bytes[...])
                    feedAccepted = true
                } else {
                    feedAccepted = false
                }
                // The shared render ledger replaced the legacy refresh
                // executors, so authority repaint completion belongs at this
                // common delivery boundary. Retained live output and mosh
                // history are not authoritative captures; only a completed
                // inline repaint can commit the pending lifecycle stamp and
                // lift the takeover veil.
                authorityDelivery.record(
                    accepted: feedAccepted,
                    surfaceID: surfaceID,
                    owner: owner,
                    source: source
                )
                if surfaceID == .live, source == .paneOutput {
                    if owner.windowID == nil, let paneID = owner.paneID {
                        runtimeEngine.ingestProvisionalActivePane(paneID)
                    }
                    renderedWindowId = owner.windowID
                    renderedPaneId = owner.paneID
                    activePaneId = owner.paneID
                    markInitialRenderReady()
                }

            case .saveWindowModes(let surfaceID, let windowID):
                renderSaveWindowModes?(surfaceID, windowID)

            case .restoreWindowModes(let surfaceID, let windowID, let paneInAltScreen):
                renderRestoreWindowModes?(surfaceID, windowID, paneInAltScreen)
                guard let owner = ledgerRenderedOwners[surfaceID] else { continue }
                if surfaceID == .live {
                    let changed = renderedWindowId != owner.windowID || renderedPaneId != owner.paneID
                    renderedWindowId = owner.windowID
                    renderedPaneId = owner.paneID
                    activePaneId = owner.paneID
                    if changed {
                        displayDidSwap?(windowID)
                    } else {
                        displayDidRefresh?(windowID)
                    }
                } else if let paneID = owner.paneID {
                    paneDidRefresh?(paneID)
                }

            case .resolveSurfaceState(let surfaceID, let request):
                let supplied = renderSurfaceState?(surfaceID)
                let paneID = ledgerRenderedOwners[surfaceID]?.paneID
                    ?? Self.paneIDEncoded(in: surfaceID)
                let paneSupplied = paneID.flatMap { paneRenderSurfaces[$0]?.state() }
                let altScreen = supplied?.altScreen
                    ?? paneSupplied?.altScreen
                    ?? (surfaceID == .live
                        ? terminalIsInAltScreen?() == true
                        : paneID.flatMap { paneLocalAltScreenProbe?($0) } == true)
                let columns = supplied?.columns ?? paneSupplied?.columns ?? lastKnownSize?.cols ?? 0
                let rows = supplied?.rows ?? paneSupplied?.rows ?? lastKnownSize?.rows ?? 0
                submitRenderFact(
                    .surfaceState(
                        surfaceID,
                        request: request,
                        altScreen: altScreen,
                        mouseMode: supplied?.mouseMode ?? paneSupplied?.mouseMode ?? .off,
                        columns: columns,
                        rows: rows
                    ),
                    snapshot: effectSnapshot
                )

            case .armTimer(let token, let milliseconds):
                renderTimerTasks.removeValue(forKey: token)?.cancel()
                renderTimerTasks[token] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(max(0, milliseconds)))
                    guard !Task.isCancelled, let self else { return }
                    self.renderTimerTasks.removeValue(forKey: token)
                    self.submitRenderFact(.timerFired(token: token))
                }

            case .cancelTimer(let token):
                renderTimerTasks.removeValue(forKey: token)?.cancel()

            case .initialRenderReady:
                markInitialRenderReady()

            case .requestTransportFullFrame:
                requestTransportFullFrame?()

            case .historyReady(let surfaceID, let owner, let depth, let historySize, let placement):
                renderHistoryReady?(surfaceID, owner, depth, historySize, placement)

            case .inlineHistorySettled(let surfaceID, let owner, let depth, let historySize, let canDeepen):
                renderInlineHistorySettled?(surfaceID, owner, depth, historySize, canDeepen)

            case .refreshCompleted:
                // Completion is proven by the feed tally below, which also
                // covers uncorrelated repaints.
                break

            case .refreshFailed(_, let correlation, let reason):
                // Only the claim repaint sent behind its fence is correlated
                // on Apple; a failure must not strand the veil it would lift.
                gridClaimRepaintBehindFenceFailed(correlation: correlation, reason: reason)

            case .requestCorrelatedTransportFullFrame(_, let owner, let correlation, let reason):
                // The ledger owns the reservation and re-issues it across its
                // own rebinds, so this arm fires once per (re-)issue and the
                // platform simply forces a frame for the owner it names.
                requestCorrelatedTransportFullFrame(
                    owner: owner,
                    correlation: correlation,
                    reason: reason
                )

            case .transportFullFrameCompleted(_, _, let correlation):
                guard gridAuthorityLifecycle.claim?.generation == correlation,
                      gridAuthorityLifecycle.claim?.phase == .awaitingRepaint
                else { break }
                finishGridAuthorityClaimPresentation(
                    context: "side-channel-repaint-delivered"
                )

            case .transportFullFrameFailed(_, let correlation, let reason):
                Self.logDiagnostic(
                    "grid-authority transport frame failed correlation=\(correlation) reason=\(reason)"
                )
                // `owner-changed` means the surface moved to another window or
                // pane. That kills the *frame*, not the claim: the veil must
                // stay closed while the claim re-enters its geometry/fence
                // phase for the window now on screen (D38 -- never complete,
                // never abort). `refenceGridClaimIfCurrentWindowMoved` owns
                // that transition and has already run for this move.
                //
                // `superseded` is the same shape: the reservation was replaced
                // under this very correlation and its replacement request is
                // already in this batch.
                guard reason != "owner-changed", reason != "superseded" else { break }
                guard gridAuthorityLifecycle.claim?.generation == correlation,
                      gridAuthorityLifecycle.claim?.phase == .awaitingRepaint
                else { break }
                applyGridAuthorityLifecycleEffects(
                    reduceGridAuthority(.abortClaim(
                        generation: correlation, reason: .adapterFailure))
                )

            case .diagnostic(let message):
                Self.logDiagnostic(message)
            }
        }
        // A repaint sent behind a claim's fence that lands before the claim
        // confirmed (the window was still resizing) cannot be counted; the
        // confirmation then asks for its own.
        if gridAuthorityClaimRepaintInFlight?.relied == false,
           !authorityDelivery.completedWindows.isEmpty || !authorityDelivery.completedPanes.isEmpty {
            gridAuthorityClaimRepaintInFlight = nil
        }
        // Multiple feeds (deep repaint + viewport scrub) form one effect
        // transaction. Acknowledge only after the whole transaction has been
        // delivered so the veil cannot lift between its constituent frames.
        for windowID in authorityDelivery.completedWindows {
            if gridAuthorityDeliveryRetryWindow == windowID {
                gridAuthorityDeliveryRetryWindow = nil
            }
            completeGridAuthoritySharedRepaintIfNeeded(windowId: windowID)
        }
        for paneID in authorityDelivery.completedPanes {
            gridAuthorityDeliveryRetryPanes.remove(paneID)
            completeGridAuthorityPaneRepaintIfNeeded(paneId: paneID)
        }
        scheduleGridAuthorityDeliveryRetry(
            rejectedWindows: authorityDelivery.rejectedWindows,
            rejectedPanes: authorityDelivery.rejectedPanes
        )
        // Ordinary foreground/first-fill and delivery-retry captures can
        // consume claim targets too. Their terminal failures are uncorrelated:
        // inspect the ledger after the whole delivery transaction, including
        // any replacement a correlated failure just started.
        let targetCaptureFailed = (gridAuthorityRepaintWindow != nil && renderLedger.hasFailedRefresh(for: .live))
            || gridAuthorityRepaintPanes.contains {
                renderLedger.hasFailedRefresh(for: Self.inlinePaneSurfaceID($0))
            }
        if controlPath == .inline, !appIsInactive,
           targetCaptureFailed, gridAuthorityDeliveryRetryTask == nil {
            stallGridClaim(context: "repaint-exhausted", canProgress: true, fenceAgain: false)
        }
    }

    @ObservationIgnored private var ledgerRenderedOwners: [SurfaceId: TmuxControlCore.RenderOwner] = [:]

    private func completePlatformCommand(tag: UInt64, success: Bool, lines: [String]) {
        guard let index = pendingCommands.firstIndex(where: { $0.tag == tag }) else {
            Self.logDiagnostic(
                "command-response missing-platform-tag controller=\(diagnosticID) tag=\(tag)"
            )
            return
        }
        let entry = pendingCommands.remove(at: index)
        if success {
            entry.completion(.success(lines))
        } else {
            entry.completion(.failure(.tmuxError(lines: lines)))
        }
    }

    private func terminalFeedSource(_ source: RenderFeedSource) -> TerminalFeedSource {
        switch source {
        case .paneOutput: return .paneOutput
        case .viewportRepaint: return .viewportRepaint
        case .viewportRefresh: return .viewportRefresh
        case .deepRepaint: return .deepRepaint
        case .repaintScrub: return .repaintScrub
        case .foregroundReplay: return .foregroundReplay
        case .moshHistory: return .moshHistory
        }
    }

    private func terminalFeedContext(
        owner: TmuxControlCore.RenderOwner,
        source: TerminalFeedSource,
        originalByteCount: Int?
    ) -> TerminalFeedContext {
        let isCapture = source != .paneOutput && source != .foregroundReplay
        return TerminalFeedContext(
            source: source,
            paneId: owner.paneID,
            windowId: owner.windowID,
            renderOwnerEpoch: owner.epoch,
            generation: stateGeneration,
            captureRows: isCapture ? executingRenderReplyRows : nil,
            reason: isCapture ? executingRenderReplyReason : nil,
            originalByteCount: originalByteCount
        )
    }

    /// Feed a chunk of bytes received from the SSH output stream.
    /// Routes them to the terminal (passthrough) or into the tmux
    /// parser (tmux mode). Handles DCS boundary detection.
    public func ingest(_ chunk: [UInt8]) {
        switch mode {
        case .passthrough:
            handlePassthrough(chunk)
        case .tmuxControl:
            let batch = runtimeEngine.feed(chunk)
            process(steps: batch.orderedSteps)
            deliverAgentStates(batch.agentStates)
            observeProgramStatus(batch)
        }
    }

    /// Publish the lifecycle payloads the shared runtime read off this batch's
    /// pane-metadata events.
    ///
    /// Delivered per batch rather than per message because a pane option is a
    /// state, not an event: the value that matters is the one that survives
    /// the read. It arrives for every pane of the session, including panes
    /// this client never paints, which is the point — an agent working in an
    /// unwatched window has no other way to reach Agent Center.
    private func deliverAgentStates(_ states: [TmuxPaneAgentState]) {
        guard let observer = paneAgentStateObserver, !states.isEmpty else { return }
        for state in states { observer(state.paneID, state.json) }
    }

    @ObservationIgnored private var cooperativeYieldGeneration: UInt64 = 0

    /// Main-actor-friendly ingestion for an interactive renderer. Control
    /// messages retain their strict synchronous ordering, while live pane
    /// payloads are delivered in bounded slices with cooperative yields. The
    /// legacy synchronous API remains available for package clients and tests
    /// that do not own a UI run loop.
    /// Returns whether rendering yielded, so a surrounding stream consumer
    /// can reset its fairness budget without counting our scheduling wait.
    @discardableResult
    public func ingestCooperatively(_ chunk: [UInt8]) async -> Bool {
        let previousYield = cooperativeYieldGeneration
        switch mode {
        case .passthrough:
            await handlePassthroughCooperatively(chunk)
        case .tmuxControl:
            let parseStart = IngestStageStats.now()
            let batch = runtimeEngine.feed(chunk)
            let steps = batch.orderedSteps
            ingestStages.parseMs += IngestStageStats.elapsedMs(since: parseStart)
            cooperativeOutputIngestDepth += 1
            defer { cooperativeOutputIngestDepth -= 1 }
            await processCooperatively(steps: steps)
            deliverAgentStates(batch.agentStates)
            observeProgramStatus(batch)
        }
        ingestStages.noteCall()
        ingestStages.flushIfDue(log: { Self.logDiagnostic("controller=\(diagnosticID) " + $0) })
        return cooperativeYieldGeneration != previousYield
    }

    // MARK: - Pane grid rendering (multi-pane windows)

    /// The set of panes currently rendered through their own per-pane sink
    /// (i.e. the mounted grid). Empty when no grid is mounted.
    public var renderingPaneIds: Set<PaneId> { Set(paneSinks.keys) }

    /// Register (or, with `nil`, unregister) the render sink for a pane. The
    /// app calls this when mounting/dismantling a pane surface in the grid.
    /// Registering does NOT auto-repaint — the app follows with `refreshPane`.
    public func setPaneSink(_ paneId: PaneId, _ sink: ((ArraySlice<UInt8>) -> Void)?) {
        let wasRenderingGrid = !paneSinks.isEmpty
        if let sink {
            paneSinks[paneId] = sink
        } else {
            paneSinks.removeValue(forKey: paneId)
            paneRenderSurfaces.removeValue(forKey: paneId)
        }
        redeclareInlineRenderSurfaces()
        if wasRenderingGrid,
           paneSinks.isEmpty,
           mode == .tmuxControl,
           controlPath == .inline {
            submitRenderFact(.refreshRequested(
                .live,
                stage: .viewport,
                reason: "grid-collapse-resync"
            ))
        }
    }

    /// Register the owner-aware seam for a mounted grid terminal. The legacy
    /// sink remains present only for source-compatible tests and dead repaint
    /// helpers while the ledger executor always chooses this adapter first.
    public func setPaneRenderSurface(
        _ paneId: PaneId,
        legacyFeed: @escaping (ArraySlice<UInt8>) -> Void,
        bind: @escaping (TmuxControlCore.RenderOwner, Int) -> Void,
        feed: @escaping (TmuxControlCore.RenderOwner, ArraySlice<UInt8>) -> Void,
        state: @escaping () -> (
            altScreen: Bool,
            mouseMode: RenderMouseMode,
            columns: Int,
            rows: Int
        )?
    ) {
        paneRenderSurfaces[paneId] = .init(bind: bind, feed: feed, state: state)
        noteGridAuthorityPaintable()
        setPaneSink(paneId, legacyFeed)
    }

    /// Drop every pane sink — used when the grid unmounts (window collapses to
    /// a single pane, or the session resets) so output falls back to the
    /// shared single-pane path.
    public func clearAllPaneSinks() {
        let wasRenderingGrid = !paneSinks.isEmpty
        paneSinks.removeAll()
        paneRenderSurfaces.removeAll()
        redeclareInlineRenderSurfaces()
        if wasRenderingGrid,
           mode == .tmuxControl,
           controlPath == .inline {
            submitRenderFact(.refreshRequested(
                .live,
                stage: .viewport,
                reason: "grid-collapse-resync"
            ))
        }
    }

    /// The render-surface id of one grid pane, `pane:<pane number>`. Shared
    /// with the app so the platform ladders and the ledger agree on the
    /// spelling of a surface.
    nonisolated public static func inlinePaneSurfaceID(_ paneID: PaneId) -> SurfaceId {
        SurfaceId("pane:\(paneID.rawValue)")
    }

    /// Inverse of `inlinePaneSurfaceID`; nil for `.live` and anything else.
    nonisolated public static func paneIDEncoded(in surfaceID: SurfaceId) -> PaneId? {
        let prefix = "pane:"
        guard surfaceID.rawValue.hasPrefix(prefix),
              let value = Int(surfaceID.rawValue.dropFirst(prefix.count))
        else { return nil }
        return PaneId(value)
    }

    /// PaneGridView remains responsible for mounting SwiftTerm views; this is
    /// the only place their topology becomes reducer input. Active-first order
    /// keeps launch readiness tied to the pane a user can actually interact
    /// with while sibling surfaces hydrate behind it.
    private func redeclareInlineRenderSurfaces(
        snapshot suppliedSnapshot: TmuxSnapshot? = nil
    ) {
        guard controlPath == .inline else { return }
        let snapshot = suppliedSnapshot ?? runtimeEngine.snapshot
        guard !paneSinks.isEmpty else {
            guard snapshot.activeWindowID != nil else {
                if !currentRenderDeclarations.isEmpty {
                    declareRenderSurfaces([], snapshot: snapshot)
                }
                return
            }
            let activeWindowUsesGrid = snapshot.activeWindowID
                .flatMap { activeID in
                    snapshot.windows.first { $0.id == activeID }
                }
                .map { window in
                    !window.isZoomed && (window.layout?.paneCount ?? 1) > 1
                }
                ?? false
            // Between the topology notification and SwiftUI mounting its
            // per-pane emulators there is intentionally no render surface.
            // Keeping `.live` declared during that turn would let the ledger
            // enqueue a shared-window repaint that can never paint this grid
            // and would occupy the command FIFO ahead of the pane captures.
            let declarations = activeWindowUsesGrid
                ? []
                : [defaultRenderSurfaceDeclaration]
            if declarations != currentRenderDeclarations {
                declareRenderSurfaces(declarations, snapshot: snapshot)
            }
            return
        }
        let orderedPaneIDs = paneSinks.keys.sorted { lhs, rhs in
            if lhs == activePaneId { return true }
            if rhs == activePaneId { return false }
            return lhs.rawValue < rhs.rawValue
        }
        let declarations = orderedPaneIDs.map { paneID in
            SurfaceDeclaration(
                surfaceID: Self.inlinePaneSurfaceID(paneID),
                presentation: .grid,
                windowID: paneWindowTable[paneID] ?? activeWindowId,
                paneID: paneID
            )
        }
        if declarations != currentRenderDeclarations {
            declareRenderSurfaces(declarations, snapshot: snapshot)
        }
    }

    /// The compact pane's geometry changed (a `%layout-change` resized the
    /// focused pane): rebuild it deep once the new bounds reach its
    /// terminal. P7: not while a peer holds the grid. The ledger already
    /// owes that relayout, and the claim's repaint (or the peer's departure)
    /// pays it. Capturing here would cost a 2,000-row capture on every
    /// keyboard toggle of the peer's, and during a take-back would supersede
    /// the claim's own repaint.
    public func refreshPaneAfterCompactGeometryChange(paneId: PaneId) {
        guard !participatesInGridAuthority || !gridAuthorityLifecycle.authority.isPeer else {
            Self.logDiagnostic("compact-pane refresh owed while yielded pane=\(paneId)")
            return
        }
        refreshPane(paneId: paneId, deep: true)
    }

    /// Ask the shared ledger to rebuild one mounted pane surface. The ledger
    /// owns the capture stages, epochs, retries, and clear-before-feed rule.
    public func refreshPane(paneId: PaneId, deep: Bool = true) {
        guard controlPath == .inline, paneSinks[paneId] != nil else { return }
        submitRenderFact(.refreshRequested(
            Self.inlinePaneSurfaceID(paneId),
            stage: deep ? .deep : .viewport,
            reason: deep ? "pane-focus" : "pane-mount"
        ))
    }

    /// through the tmux command parser.
    public func sendInput(_ bytes: [UInt8]) {
        sendInput(bytes, correlation: nil)
    }

    /// `sendInput` variant carrying an opaque correlation tag into the
    /// command-transmit/response diagnostics, so a caller-side admission log
    /// line (e.g. the shared session adapter's) can be tied to the exact
    /// tmux command and its acknowledgement in one device log.
    public func sendInput(_ bytes: [UInt8], correlation: String?) {
        sendInput(bytes, correlation: correlation) { _ in }
    }

    /// `sendInput` that reports what tmux made of it: true once tmux ran the
    /// `send-keys` (or passthrough handed the bytes to the transport), false
    /// when nothing was sent or tmux failed it. The command is queued before
    /// this returns, in order with other input; the report follows tmux's
    /// reply.
    public func sendInput(
        _ bytes: [UInt8],
        correlation: String?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        switch mode {
        case .passthrough:
            if !bytes.isEmpty { inputObserver?(nil, bytes) }
            sendBytes?(bytes)
            completion(!bytes.isEmpty && sendBytes != nil)
        case .tmuxControl:
            guard !userMutationsSuppressedWhileYielded,
                  let pane = activePaneId,
                  !bytes.isEmpty
            else {
                completion(false)
                return
            }
            inputObserver?(pane, bytes)
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            enqueueControlCommand(
                "send-keys -t \(pane.description) -H \(hex)",
                correlation: correlation
            ) { result in
                if case .success = result { completion(true) } else { completion(false) }
            }
        }
    }

    // MARK: - Control commands (§3.2 commit C)

    /// Send a raw tmux control-mode command line upstream. The trailing
    /// newline is added if missing. Bypasses the `send-keys` wrapping
    /// that `sendInput` applies — control commands like `new-window`
    /// target tmux itself, not the shell running inside a pane.
    ///
    /// Fire-and-forget convenience wrapper: queues a no-op completion
    /// so the response is drained from `pendingCommands` on `%end` and
    /// the queue stays in FIFO sync with the wire. Use the variant
    /// with a `completion` closure if you need the response body.
    ///
    /// No-ops in passthrough mode: control commands only make sense once
    /// we've negotiated the `-CC` session. A user pressing ⌘T before
    /// tmux has started has nothing to target.
    public func sendControlCommand(_ command: String) {
        enqueueControlCommand(command) { _ in }
    }

    /// Send a raw tmux control-mode command line upstream and invoke
    /// `completion` with the response body when tmux replies with
    /// `%end` or `%error`. Trailing newline is added if missing.
    ///
    /// Responses arrive in the order commands are queued because tmux
    /// serializes control-mode commands — the nth `%end` we see
    /// corresponds to the nth command we sent, so a FIFO is sufficient
    /// for correlation (no per-command id tracking needed).
    ///
    /// - On `%end`: completion fires with `.success([body lines])`.
    /// - On `%error`: completion fires with `.failure(.tmuxError(...))`.
    /// - On `reset()` / `%exit`: completion fires with `.failure(.cancelled)`.
    /// - If we're in passthrough mode: completion fires synchronously
    ///   with `.failure(.notInTmuxMode)` and no bytes are sent upstream.
    ///
    /// The body lines are the plain text emitted between `%begin` and
    /// `%end` — one entry per line, CRLF stripped. For a successful
    /// query like `display-message -p …` there's typically a single
    /// line; for `capture-pane -p …` there's one entry per captured
    /// viewport row (with ANSI escape sequences preserved when `-e`
    /// is passed).
    public func sendControlCommand(
        _ command: String,
        completion: @escaping (Result<[String], CommandError>) -> Void
    ) {
        enqueueControlCommand(command, completion: completion)
    }

    /// Low-priority query surface for observers such as Swipe Pad and Agent
    /// Center. An authoritative shared-terminal repaint must run alone after
    /// all older replies drain: the device corruption log showed cursor/process
    /// and capture bodies reaching render-metadata callbacks when those
    /// consumers were pipelined together. Observers may retry on their normal
    /// poll/output cadence; rendering cannot safely accept a foreign-shaped
    /// body or paint incrementally over a stale window.
    public func sendBackgroundControlQuery(
        _ command: String,
        completion: @escaping (Result<[String], CommandError>) -> Void
    ) {
        guard !isAuthoritativeRenderRefreshPending else {
            Self.logDiagnostic(
                "background-query skipped controller=\(diagnosticID) reason=authoritative-render commandCategory=\(Self.commandCategory(command))"
            )
            completion(.failure(.cancelled))
            return
        }
        // S5′ (D13): a launch write here (Agent Center's launch buffer,
        // `new-window -d`, `split-window -d`) would change the grid another
        // device is using. Decided in the same turn as the enqueue.
        guard !gridAuthorityRefusesAgentSend || TmuxAgentCommandAccess.isAuthorityNeutral(command) else {
            Self.logDiagnostic(
                "background-query refused controller=\(diagnosticID) reason=controlled-elsewhere commandCategory=\(Self.commandCategory(command))"
            )
            completion(.failure(.refusedByAuthority))
            return
        }
        sendControlCommand(command, completion: completion)
    }

    public var isAuthoritativeRenderRefreshPending: Bool {
        renderLedger.hasPendingRender
    }

    private func enqueueControlCommand(
        _ command: String,
        correlation: String? = nil,
        completion: @escaping (Result<[String], CommandError>) -> Void
    ) {
        let category = Self.commandCategory(command)
        Self.logDiagnostic(
            "sendControlCommand controller=\(diagnosticID) path=\(controlPath) mode=\(mode) pending=\(pendingCommands.count) activeWindowPresent=\(activeWindowId != nil) activePanePresent=\(activePaneId != nil) commandCategory=\(category)"
        )
        guard mode == .tmuxControl else {
            Self.logDiagnostic("sendControlCommand rejected controller=\(diagnosticID) reason=not-in-tmux commandCategory=\(category)")
            completion(.failure(.notInTmuxMode))
            return
        }
        guard !commandQueueAwaitingTransportRecovery else {
            Self.logDiagnostic(
                "sendControlCommand rejected controller=\(diagnosticID) reason=transport-recovery-pending commandCategory=\(category)"
            )
            completion(.failure(.timedOut))
            return
        }

        let submission = renderLedger.enqueuePlatformCommand(command)
        nextCommandSequence &+= 1
        let entry = PendingCommand(
            tag: submission.tag,
            sequence: nextCommandSequence,
            command: command,
            transmittedAt: ContinuousClock.now,
            correlation: correlation,
            completion: completion
        )
        transmitControlCommand(entry)
    }

    /// Enqueue two commands back-to-back before returning to the actor. tmux
    /// still emits one response frame per command, but no observer query,
    /// input command, or layout reaction can be transmitted between this
    /// authoritative metadata/capture pair.
    private func enqueueControlCommandPair(
        _ firstCommand: String,
        _ secondCommand: String,
        completion: @escaping (
            Result<[String], CommandError>,
            Result<[String], CommandError>
        ) -> Void
    ) {
        Self.logDiagnostic(
            "sendControlCommand pair controller=\(diagnosticID) path=\(controlPath) mode=\(mode) pending=\(pendingCommands.count) firstCategory=\(Self.commandCategory(firstCommand)) secondCategory=\(Self.commandCategory(secondCommand))"
        )
        guard mode == .tmuxControl else {
            let failure: Result<[String], CommandError> = .failure(.notInTmuxMode)
            completion(failure, failure)
            return
        }
        guard !commandQueueAwaitingTransportRecovery else {
            Self.logDiagnostic(
                "sendControlCommand pair rejected controller=\(diagnosticID) reason=transport-recovery-pending firstCategory=\(Self.commandCategory(firstCommand)) secondCategory=\(Self.commandCategory(secondCommand))"
            )
            let failure: Result<[String], CommandError> = .failure(.timedOut)
            completion(failure, failure)
            return
        }

        let submissions = renderLedger.enqueuePlatformCommands([firstCommand, secondCommand])
        guard submissions.count == 2 else {
            let failure: Result<[String], CommandError> = .failure(.cancelled)
            completion(failure, failure)
            return
        }
        var firstResult: Result<[String], CommandError>?
        nextCommandSequence &+= 1
        let first = PendingCommand(
            tag: submissions[0].tag,
            sequence: nextCommandSequence,
            command: firstCommand,
            transmittedAt: ContinuousClock.now,
            correlation: nil,
            completion: { result in firstResult = result }
        )
        nextCommandSequence &+= 1
        let second = PendingCommand(
            tag: submissions[1].tag,
            sequence: nextCommandSequence,
            command: secondCommand,
            transmittedAt: ContinuousClock.now,
            correlation: nil,
            completion: { result in
                completion(firstResult ?? .failure(.cancelled), result)
            }
        )
        transmitControlCommandPair(first, second)
    }

    /// Queue one logical mutation as an uninterrupted command batch. Reorder
    /// plans can contain several swaps and selection restores (including active-window
    /// restoration); tidy can contain one renumber per session-group member.
    /// Every response is still correlated independently, and the aggregate
    /// completion runs only after the final response so partial failures can
    /// be reported without abandoning later correlation slots.
    private func enqueueControlCommands(
        _ commands: [String],
        completion: @escaping ([Result<[String], CommandError>]) -> Void
    ) {
        guard !commands.isEmpty else {
            completion([])
            return
        }
        guard mode == .tmuxControl else {
            completion(Array(repeating: .failure(.notInTmuxMode), count: commands.count))
            return
        }
        guard !commandQueueAwaitingTransportRecovery else {
            completion(Array(repeating: .failure(.timedOut), count: commands.count))
            return
        }

        let submissions = renderLedger.enqueuePlatformCommands(commands)
        guard submissions.count == commands.count else {
            completion(Array(repeating: .failure(.cancelled), count: commands.count))
            return
        }

        var results = Array<Result<[String], CommandError>?>(
            repeating: nil,
            count: commands.count
        )
        var entries: [PendingCommand] = []
        entries.reserveCapacity(commands.count)
        for (index, command) in commands.enumerated() {
            nextCommandSequence &+= 1
            entries.append(PendingCommand(
                tag: submissions[index].tag,
                sequence: nextCommandSequence,
                command: command,
                transmittedAt: ContinuousClock.now,
                correlation: nil,
                completion: { result in
                    results[index] = result
                    guard results.allSatisfy({ $0 != nil }) else { return }
                    completion(results.compactMap { $0 })
                }
            ))
        }

        // Establish the complete FIFO before invoking the transport callback;
        // test transports and app adapters may synchronously re-enter ingest.
        pendingCommands.append(contentsOf: entries)
        for entry in entries {
            Self.logDiagnostic(
                "command-transmit controller=\(diagnosticID) sequence=\(entry.sequence) wirePending=\(pendingCommands.count) commandCategory=\(Self.commandCategory(entry.command))"
            )
        }
        armCommandResponseWatchdog()
        let wire = entries.map { entry in
            entry.command.hasSuffix("\n") ? entry.command : entry.command + "\n"
        }.joined()
        transmitControlBytes(Array(wire.utf8), publishedSize: entries.compactMap {
            Self.publishedClientSize(in: $0.command)
        }.last)
    }

    private func transmitControlCommandPair(_ first: PendingCommand, _ second: PendingCommand) {
        // Append both correlations before invoking the transport callback, then
        // emit one byte batch. `sendBytes` is app-owned and may synchronously
        // re-enter this controller; pre-queuing both entries prevents that
        // reentrancy from splitting the authoritative pair or sending the
        // second command after a reset triggered by the first callback.
        pendingCommands.append(first)
        pendingCommands.append(second)
        for entry in [first, second] {
            Self.logDiagnostic(
                "command-transmit controller=\(diagnosticID) sequence=\(entry.sequence) wirePending=\(pendingCommands.count) commandCategory=\(Self.commandCategory(entry.command))"
            )
        }
        armCommandResponseWatchdog()
        let firstLine = first.command.hasSuffix("\n") ? first.command : first.command + "\n"
        let secondLine = second.command.hasSuffix("\n") ? second.command : second.command + "\n"
        transmitControlBytes(Array((firstLine + secondLine).utf8), publishedSize:
            Self.publishedClientSize(in: second.command) ?? Self.publishedClientSize(in: first.command))
    }

    private func transmitControlCommand(_ entry: PendingCommand) {
        pendingCommands.append(entry)
        Self.logDiagnostic(
            "command-transmit controller=\(diagnosticID) sequence=\(entry.sequence) wirePending=\(pendingCommands.count) commandCategory=\(Self.commandCategory(entry.command))\(entry.correlation.map { " corr=\($0)" } ?? "")"
        )
        armCommandResponseWatchdog()
        let command = entry.command
        let line = command.hasSuffix("\n") ? command : command + "\n"
        commandWriteDiagnostic?(entry.sequence, entry.correlation)
        transmitControlBytes(Array(line.utf8), publishedSize: Self.publishedClientSize(in: command))
    }

    private static func publishedClientSize(in command: String) -> TmuxClientGeometry? {
        let prefix = "refresh-client -C "
        guard command.hasPrefix(prefix) else { return nil }
        let dimensions = command.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",")
        guard dimensions.count == 2,
              let columns = Int(dimensions[0]), let rows = Int(dimensions[1])
        else { return nil }
        return try? TmuxClientGeometry(columns: columns, rows: rows)
    }

    private func transmitControlBytes(_ bytes: [UInt8], publishedSize: TmuxClientGeometry?) {
        let generation = controlConnectionGeneration
        let admitted: Bool
        if let sendBytesAdmitting {
            admitted = sendBytesAdmitting(bytes)
        } else if let sendBytes {
            sendBytes(bytes)
            admitted = true
        } else {
            admitted = false
        }
        // Compatibility senders may synchronously reset the connection.
        guard admitted, let publishedSize, mode == .tmuxControl,
              controlConnectionGeneration == generation else { return }
        lastPublishedClientSize = publishedSize
        if participatesInGridAuthority, gridAuthorityLifecycle.claim == nil {
            applyGridAuthorityLifecycleEffects(reduceGridAuthority(.sizeAdvertised(
                TmuxGridSize(columns: publishedSize.columns, rows: publishedSize.rows)
            )))
        }
    }

    // MARK: - Command-queue poisoning detection and recovery

    /// One task per non-empty FIFO episode. It sleeps until the oldest
    /// pending command's response deadline, then either re-arms (the head
    /// changed because responses are draining normally) or declares the
    /// queue poisoned and recovers. Detection is gated on observed server
    /// activity below the hard timeout so a fully stalled link stays the
    /// transport layer's problem.
    private func armCommandResponseWatchdog() {
        guard commandResponseWatchdogTask == nil, !pendingCommands.isEmpty else { return }
        let generation = controlConnectionGeneration
        commandResponseWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.controlConnectionGeneration == generation,
                      self.mode == .tmuxControl,
                      let oldest = self.pendingCommands.first
                else { break }
                let poison = Duration.seconds(self.commandResponsePoisonThreshold)
                let interactivePoison = Duration.seconds(
                    self.commandResponseInteractivePoisonThreshold
                )
                let hard = Duration.seconds(self.commandResponseHardTimeout)
                var ageStart = oldest.transmittedAt
                if let baseline = self.commandResponseWatchdogBaseline,
                   baseline > ageStart {
                    ageStart = baseline
                }
                let now = ContinuousClock.now
                let age = ageStart.duration(to: now)
                let interactiveEntry = self.pendingCommands
                    .first(where: { Self.isInteractiveCommand($0.command) })
                let interactiveAge: Duration? = interactiveEntry.map { entry in
                        var start = entry.transmittedAt
                        if let baseline = self.commandResponseWatchdogBaseline,
                           baseline > start {
                            start = baseline
                        }
                        return start.duration(to: now)
                    }
                let interactiveExpired = interactiveAge.map { $0 >= interactivePoison } ?? false
                let outputQuiet = Duration.seconds(self.commandResponseOutputQuietPeriod)
                let outputCongested = self.cooperativeOutputIngestDepth > 0
                    || (self.lastPaneOutputAt.map {
                        $0 >= ageStart && $0.duration(to: now) < outputQuiet
                    } ?? false)
                let interactiveServerActive = (interactiveEntry.map { entry in
                    var evidenceStart = entry.transmittedAt
                    if let baseline = self.commandResponseWatchdogBaseline,
                       baseline > evidenceStart {
                        evidenceStart = baseline
                    }
                    return self.lastControlActivityAt.map {
                        $0 >= evidenceStart
                    } ?? false
                } ?? false) && !outputCongested
                if age < poison && !interactiveExpired {
                    let headWait = poison - age
                    let interactiveWait = interactiveAge.map {
                        max(.zero, interactivePoison - $0)
                    } ?? headWait
                    try? await Task.sleep(for: min(headWait, interactiveWait))
                    continue
                }
                let serverActive = self.lastControlActivityAt
                    .map { $0 >= ageStart } ?? false
                if (serverActive && age >= poison && !outputCongested)
                    || (interactiveExpired && interactiveServerActive)
                    || (age >= hard && !outputCongested) {
                    self.commandResponseWatchdogTask = nil
                    let trigger: String
                    if age >= hard {
                        trigger = "hard-timeout"
                    } else if interactiveExpired && interactiveServerActive {
                        trigger = "interactive-server-active"
                    } else {
                        trigger = "server-active"
                    }
                    self.recoverPoisonedCommandQueue(
                        oldestAge: age,
                        trigger: trigger
                    )
                    return
                }
                let remainingToHard = max(.zero, hard - age)
                let retryDelay = remainingToHard > .zero
                    ? min(.milliseconds(250), remainingToHard)
                    : .milliseconds(250)
                try? await Task.sleep(for: retryDelay)
            }
            self?.commandResponseWatchdogTask = nil
        }
    }

    private func cancelCommandResponseWatchdog() {
        commandResponseWatchdogTask?.cancel()
        commandResponseWatchdogTask = nil
        pendingCommandFence = nil
        commandQueueAwaitingTransportRecovery = false
    }

    /// Fail every stuck completion and resynchronize response correlation
    /// with a fence command. At-most-once is preserved: nothing is
    /// retransmitted — `send-keys` may or may not have executed remotely, and
    /// replaying it could duplicate user input. Completions observe
    /// `.timedOut` (not `.cancelled`) so callers can distinguish ambiguous
    /// delivery from a torn-down channel.
    private func recoverPoisonedCommandQueue(oldestAge: Duration, trigger: String) {
        guard mode == .tmuxControl else { return }
        let stuck = drainPendingCommands()
        guard !stuck.isEmpty else { return }
        commandQueueRecoveries += 1
        let oldestAgeMs = oldestAge.components.seconds * 1_000
            + Int64(oldestAge.components.attoseconds / 1_000_000_000_000_000)
        Self.logDiagnostic(
            "command-queue-poisoned controller=\(diagnosticID) trigger=\(trigger) stuck=\(stuck.count) oldestAgeMs=\(oldestAgeMs) recoveries=\(commandQueueRecoveries) headCategory=\(stuck.first.map { Self.commandCategory($0.command) } ?? "none") headCorr=\(stuck.first?.correlation ?? "none")"
        )
        if let requestTransportRecovery = onCommandQueueTransportRecoveryRequired {
            commandQueueAwaitingTransportRecovery = true
            applyGridAuthorityLifecycleEffects(reduceGridAuthority(.channelLiveness(false)))
            pendingCommandFence = nil
            for entry in stuck {
                entry.completion(.failure(.timedOut))
            }
            Self.logDiagnostic(
                "command-queue-transport-recovery-requested controller=\(diagnosticID) path=\(controlPath) recoveries=\(commandQueueRecoveries)"
            )
            requestTransportRecovery(commandQueueRecoveries)
            return
        }

        let nonce = "tessera-cq-fence-\(commandQueueRecoveries)-\(String(UUID().uuidString.prefix(8)))"
        pendingCommandFence = CommandQueueFence(nonce: nonce, armedAt: ContinuousClock.now)
        // The fence is armed before completions fire so a completion that
        // synchronously enqueues a follow-up command lands after the fence
        // on the wire and correlates exactly once the nonce drains.
        sendBytes?(Array("display-message -p \(nonce)\n".utf8))
        for entry in stuck {
            entry.completion(.failure(.timedOut))
        }
    }

    private static func isInteractiveCommand(_ command: String) -> Bool {
        switch commandCategory(command) {
        case "send-keys", "select": true
        default: false
        }
    }

    /// Fence matched: correlation is exact again. Stale render work owned by
    /// the failed commands is invalidated by re-claiming the active viewport
    /// through the normal authority path, which rehydrates metadata and
    /// repaints from authoritative server state.
    private func completeCommandQueueRecovery() {
        Self.logDiagnostic(
            "command-queue-recovered controller=\(diagnosticID) recoveries=\(commandQueueRecoveries) pendingAfterFence=\(pendingCommands.count)"
        )
        // Commands that waited out the fence measure their response age from
        // the resync, not from transmit — their replies are typically already
        // in flight right behind the nonce.
        commandResponseWatchdogBaseline = ContinuousClock.now
        armCommandResponseWatchdog()
        if controlPath == .inline {
            claimActiveViewport(reason: "command-queue-recovery", repaintEvenIfSame: true)
        }
    }

    #if DEBUG
    /// Test seam: the active recovery fence nonce, if any.
    public var _debugPendingCommandFenceNonce: String? { pendingCommandFence?.nonce }
    /// Test seam: pending command-FIFO depth.
    public var _debugPendingCommandCount: Int { pendingCommands.count }
    /// Test seam: exact FIFO order, used to keep causal-selection tests from
    /// guessing how many render/window hydration commands an event inserted.
    public var _debugPendingCommands: [String] { pendingCommands.map(\.command) }
    #endif


    public func queryActivePaneInteractionState(
        completion: @escaping (PaneInteractionState?) -> Void
    ) {
        guard mode == .tmuxControl else {
            Self.logDiagnostic("pane-interaction query skipped reason=not-in-tmux")
            completion(nil)
            return
        }

        guard let paneId = activePaneId ?? activeWindowId.flatMap({ window($0)?.activePaneId }) else {
            Self.logDiagnostic("pane-interaction query skipped reason=no-active-pane")
            completion(nil)
            return
        }

        let generation = stateGeneration
        let target = paneId.description
        Self.logDiagnostic(
            "pane-interaction query send pane=\(paneId) generation=\(generation)"
        )

        sendControlCommand(
            "display-message -p -t \(target) '\(Self.renderedPaneMetadataFormat)'"
        ) { [weak self] result in
            guard let self else { return }
            guard self.isCurrentGeneration(generation),
                  self.activePaneId == paneId || self.activeWindowId.flatMap({ self.window($0)?.activePaneId }) == paneId
            else {
                Self.logDiagnostic(
                    "pane-interaction query stale pane=\(paneId) generation=\(generation) result='\(Self.describe(result))'"
                )
                completion(nil)
                return
            }

            guard case .success(let lines) = result,
                  let head = lines.first(where: { !$0.isEmpty }),
                  let state = Self.parseRenderedPaneState(head)
            else {
                Self.logDiagnostic(
                    "pane-interaction query failed pane=\(paneId) generation=\(generation) result='\(Self.describe(result))'"
                )
                completion(nil)
                return
            }

            self.updatePaneInteractionState(
                paneId: paneId,
                isAlternateScreen: state.paneInAltScreen,
                isMouseReporting: state.isMouseReporting,
                isSgrMouse: state.mouseSgr
            )
            completion(PaneInteractionState(
                paneId: paneId,
                isAlternateScreen: state.paneInAltScreen,
                isMouseReporting: state.isMouseReporting,
                isSgrMouse: state.mouseSgr == true
            ))
        }
    }


    /// While another device holds the grid, window commands from this
    /// client must not run: `select-window`/`new-window` from a control
    /// client is exactly the latest-client transfer the claim protocol is
    /// built on, so a tab tap on a veiled device would steal the grid (and
    /// yank the peer's current window) outside the reclaim path, and a kill
    /// would destroy a window the peer may be using. The take-back veil is
    /// the only exit from yielded.
    var userMutationsSuppressedWhileYielded: Bool {
        guard gridAuthority.isPeer else { return false }
        Self.logDiagnostic("user mutation suppressed while yielded")
        return true
    }

    /// Ask tmux to create a new window. tmux responds with
    /// `%window-add @N` followed by a `%session-window-changed` that
    /// auto-focuses it — the tab strip picks both up through the normal
    /// message flow.
    public func newWindow() {
        guard !userMutationsSuppressedWhileYielded else { return }
        replayClientSize(reason: "new-window")
        performWindowSelection(
            TmuxWindowCommands.newWindowAtEnd(target: ownSessionId?.description),
            expectedWindowID: nil
        )
    }

    /// Move a tracked window to a zero-based position. The portable planner is
    /// the sole owner of tmux command spelling and the expected order. The
    /// optimistic snapshot remains published through command ACK and is
    /// reconciled only by a subsequent authoritative full-list reply.
    public func moveWindow(_ windowId: WindowId, to destination: Int) {
        guard canReorderWindows,
              let sessionID = ownSessionId
        else { return }
        windowOrderError = nil
        let connectionGeneration = controlConnectionGeneration
        let order = windows.map(\.id)
        let capabilities = snapshot.capabilities
            ?? TmuxWindowCapabilities.forVersion(serverVersion ?? "")
        guard let plan = TmuxWindowReorderPlanner.plan(
            order: order,
            moving: windowId,
            to: destination,
            capabilities: capabilities,
            sessionID: sessionID,
            activeWindowID: nil,
            highestIndex: windows.compactMap(\.index).max()
        ) else {
            windowOrderError = "The window order changed. Try again."
            return
        }
        guard !plan.commands.isEmpty else { return }
        guard let token = beginWindowOrderOptimism(
            expectedOrder: plan.expectedOrder,
            connectionGeneration: connectionGeneration
        ) else { return }
        sendControlCommand(TmuxSessionGroupQuery.command) { [weak self] result in
            guard let self,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.mode == .tmuxControl,
                  self.pendingWindowReorderToken == token
            else { return }
            guard case .success(let lines) = result else {
                self.abandonWindowOrderMutation(
                    token: token,
                    error: Self.windowOrderErrorMessage(
                        result,
                        fallback: "Could not verify the tmux session group."
                    ) ?? "Could not verify the tmux session group."
                )
                return
            }
            guard let states = TmuxSessionGroupQuery.parse(
                lines: lines,
                containing: sessionID
            ) else {
                self.abandonWindowOrderMutation(
                    token: token,
                    error: "Could not verify the tmux session group."
                )
                Self.logDiagnostic(
                    "window-order group parse failed own=\(sessionID) lines=\(lines.count)"
                )
                return
            }
            guard self.runtimeEngine.snapshot.authoritativeWindowOrder == order else {
                self.abandonWindowOrderMutation(token: token, error: "The window order changed. Try again.")
                return
            }
            guard let grouped = TmuxSessionGroupQuery.renumberPlan(for: states, preservingAttached: sessionID) else { return }
            self.beginWindowOrderMutation(
                plan: TmuxWindowMutationPlan(mutationCommands: plan.commands, selectionRestoreCommands: grouped.selectionRestoreCommands),
                expectedOrder: plan.expectedOrder,
                connectionGeneration: connectionGeneration,
                existingToken: token
            )
        }
    }

    /// Compact window indexes for every member of the attached session group.
    /// Group membership is discovered from tmux on each invocation because a
    /// user may add members beyond Tessera's normal owner/view pair.
    public func renumberWindows() {
        guard canTidyWindows,
              let ownSessionId
        else { return }
        windowOrderError = nil
        let connectionGeneration = controlConnectionGeneration
        guard let token = beginWindowOrderOptimism(expectedOrder: windows.map(\.id), connectionGeneration: connectionGeneration) else { return }
        sendControlCommand(TmuxSessionGroupQuery.command) { [weak self] result in
            guard let self,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.mode == .tmuxControl,
                  self.pendingWindowReorderToken == token
            else { return }
            guard case .success(let lines) = result,
                  let states = TmuxSessionGroupQuery.parse(
                      lines: lines,
                      containing: ownSessionId
                  ),
                  !states.isEmpty
            else {
                self.abandonWindowOrderMutation(token: token, error: Self.windowOrderErrorMessage(result, fallback: "Could not discover the tmux session group.") ?? "Could not discover the tmux session group.")
                return
            }
            guard let plan = TmuxSessionGroupQuery.renumberPlan(
                for: states,
                preservingAttached: ownSessionId
            ) else {
                self.abandonWindowOrderMutation(token: token, error: "Could not build a safe tmux tidy operation.")
                return
            }
            self.beginWindowOrderMutation(
                plan: plan,
                expectedOrder: self.windows.map(\.id),
                connectionGeneration: connectionGeneration,
                existingToken: token
            )
        }
    }

    private func beginWindowOrderMutation(
        plan: TmuxWindowMutationPlan,
        expectedOrder: [WindowId],
        connectionGeneration: UInt64,
        existingToken: UInt64? = nil
    ) {
        guard self.controlConnectionGeneration == connectionGeneration,
              mode == .tmuxControl,
              isWindowListHydrated,
              !gridAuthority.isPeer
        else {
            if let existingToken,
               pendingWindowReorderToken == existingToken {
                abandonWindowOrderMutation(
                    token: existingToken,
                    error: "The tmux session changed before the window could move."
                )
            } else {
                windowOrderOperationPending = false
            }
            return
        }
        let token: UInt64
        if let existingToken {
            guard pendingWindowReorderToken == existingToken,
                  runtimeEngine.snapshot.isReorderPending
            else { return }
            token = existingToken
        } else {
            guard let started = beginWindowOrderOptimism(
                expectedOrder: expectedOrder,
                connectionGeneration: connectionGeneration
            ) else { return }
            token = started
        }

        armWindowOrderDeadline(token: token, connectionGeneration: connectionGeneration)
        enqueueControlCommands(plan.commands) { [weak self] results in
            guard let self,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.pendingWindowReorderToken == token
            else { return }
            self.windowOrderOperationPending = false
            for (command, result) in zip(plan.selectionRestoreCommands, results.dropFirst(plan.mutationCommands.count)) {
                if case .failure = result { Self.logDiagnostic("window-order selection restore failed command=\(command)") }
            }
            if results.prefix(plan.mutationCommands.count).allSatisfy({ result in
                if case .success = result { return true }
                return false
            }) {
                _ = self.runtimeEngine.confirmReorder(token: token)
                self.armWindowOrderDeadline(token: token, connectionGeneration: connectionGeneration)
            } else {
                _ = self.runtimeEngine.abandonReorder(token: token)
                self.pendingWindowReorderToken = nil
                self.windowOrderDeadlineTask?.cancel()
                self.windowOrderDeadlineTask = nil
                self.windowOrderError = results.lazy.compactMap { result in
                    Self.windowOrderErrorMessage(result, fallback: nil)
                }.first ?? "Could not update the tmux window order."
            }
            self.projectCoreSnapshot()
            self.sendPendingWindowOrderRefreshIfNeeded()
        }
    }

    private func beginWindowOrderOptimism(
        expectedOrder: [WindowId],
        connectionGeneration: UInt64
    ) -> UInt64? {
        guard self.controlConnectionGeneration == connectionGeneration,
              let token = runtimeEngine.beginReorder(expecting: expectedOrder)
        else { return nil }
        pendingWindowReorderToken = token
        windowOrderOperationPending = true
        projectCoreSnapshot()
        armWindowOrderDeadline(token: token, connectionGeneration: connectionGeneration)
        return token
    }

    private func abandonWindowOrderMutation(token: UInt64, error: String) {
        guard pendingWindowReorderToken == token else { return }
        _ = runtimeEngine.abandonReorder(token: token)
        pendingWindowReorderToken = nil
        windowOrderOperationPending = false
        windowOrderDeadlineTask?.cancel()
        windowOrderDeadlineTask = nil
        windowOrderError = error
        projectCoreSnapshot()
        sendPendingWindowOrderRefreshIfNeeded()
    }

    private func armWindowOrderDeadline(
        token: UInt64,
        connectionGeneration: UInt64
    ) {
        windowOrderDeadlineTask?.cancel()
        let interval = windowOrderDeadlineInterval
        windowOrderDeadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled,
                  let self,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.pendingWindowReorderToken == token
            else { return }
            _ = self.runtimeEngine.abandonReorder(token: token)
            self.pendingWindowReorderToken = nil
            self.windowOrderOperationPending = false
            self.windowOrderDeadlineTask = nil
            self.windowOrderError = "The tmux window order did not update in time."
            self.projectCoreSnapshot()
            self.sendPendingWindowOrderRefreshIfNeeded()
        }
    }

    private func finishConfirmedWindowOrderMutationIfNeeded() {
        guard pendingWindowReorderToken != nil,
              !runtimeEngine.snapshot.isReorderPending
        else { return }
        pendingWindowReorderToken = nil
        windowOrderOperationPending = false
        windowOrderDeadlineTask?.cancel()
        windowOrderDeadlineTask = nil
    }

    private static func windowOrderErrorMessage(
        _ result: Result<[String], CommandError>,
        fallback: String?
    ) -> String? {
        switch result {
        case .success:
            return fallback
        case .failure(.tmuxError(let lines)):
            let message = lines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? (fallback ?? "tmux rejected the window order change.") : message
        case .failure(.timedOut):
            return "The tmux window order command timed out."
        case .failure(.cancelled):
            return fallback ?? "The tmux window order change was cancelled."
        case .failure(.notInTmuxMode):
            return fallback ?? "The tmux control connection is unavailable."
        case .failure(.refusedByAuthority):
            return fallback ?? "This session is being controlled from another device."
        }
    }

    /// Ask tmux to kill the current window. tmux responds with
    /// `%window-close @N` and, if another window remains, a
    /// `%session-window-changed` naming the successor.
    public func killCurrentWindow() {
        guard !userMutationsSuppressedWhileYielded else { return }
        performWindowSelection("kill-window", expectedWindowID: nil)
    }

    /// Ask tmux to kill a specific tracked window. The explicit `@id` target
    /// lets per-tab close controls remove an inactive window without first
    /// selecting it. Reject unknown ids so a broadcast notification from a
    /// different session can never turn into a command against that session.
    public func killWindow(_ windowId: WindowId) {
        guard !userMutationsSuppressedWhileYielded else { return }
        guard mode == .tmuxControl,
              isWindowListHydrated,
              windows.contains(where: { $0.id == windowId })
        else { return }
        let command = "kill-window -t \(windowId.description)"
        guard controlPath == .sideChannel,
              let sessionID = ownSessionId,
              let identity = gridAuthorityIdentity
        else {
            sendControlCommand(command)
            return
        }

        // An inactive tab close must not move the separately attached Mosh
        // painter. Prove whether this target is current before deciding if the
        // close needs the same post-mutation visible-client reconciliation as
        // `killCurrentWindow`.
        let selectionGeneration = visibleClientSelectionGeneration
        let connectionGeneration = controlConnectionGeneration
        sendControlCommand(TmuxRuntimeHydrationQuery.activeWindowCommand) { [weak self] result in
            guard let self else { return }
            guard self.isCurrentVisibleClientSelectionContext(
                sessionID: sessionID,
                identityID: identity.id,
                selectionGeneration: selectionGeneration,
                connectionGeneration: connectionGeneration
            ) else {
                Self.logDiagnostic(
                    "targeted window close skipped window=\(windowId) stage=stale-preflight"
                )
                return
            }
            let closesActiveWindow = (try? result.get()).flatMap({
                TmuxRuntimeHydrationQuery.activeWindowID(lines: $0)
            }) == windowId

            if closesActiveWindow {
                self.performWindowSelection(command, expectedWindowID: nil)
            } else {
                self.sendControlCommand(command)
            }
        }
    }

    /// Rename a tracked window from compact touch UI. Strip control scalars so
    /// pasted text cannot become a second control-mode command, then quote the
    /// remaining user text for tmux's command parser.
    public func renameWindow(_ windowId: WindowId, to name: String) {
        guard !userMutationsSuppressedWhileYielded else { return }
        guard mode == .tmuxControl,
              isWindowListHydrated,
              windows.contains(where: { $0.id == windowId })
        else { return }
        let safeName = String(
            name.unicodeScalars
                .filter { $0.value >= 0x20 && $0.value != 0x7F }
                .prefix(100)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty else { return }
        sendControlCommand(
            "rename-window -t \(windowId.description) \(Self.singleQuotedTmuxArgument(safeName))"
        )
    }

    /// Previous tmux window in the session (wraps).
    public func previousWindow() {
        guard !userMutationsSuppressedWhileYielded else { return }
        performWindowSelection("previous-window", expectedWindowID: nil)
    }

    /// Next tmux window in the session (wraps).
    public func nextWindow() {
        guard !userMutationsSuppressedWhileYielded else { return }
        performWindowSelection("next-window", expectedWindowID: nil)
    }

    /// Select the tmux window at a given 1-based tab position in our
    /// `windows` list. Targets the window by its `@id` rather than by
    /// tmux's positional `:N` syntax, so the result is immune to the
    /// server's `base-index` option (which can make `:0` either valid
    /// or an error depending on config).
    ///
    /// Out-of-range or non-tmux-mode calls are silent no-ops — matches
    /// iTerm2's "⌘5 with three tabs does nothing" feel. Positions are
    /// 1-based because that's what the keyboard shortcut labels show
    /// (⌘1 → first tab).
    public func selectWindow(atPosition position: Int) {
        guard !userMutationsSuppressedWhileYielded else { return }
        guard mode == .tmuxControl,
              position >= 1,
              position <= windows.count
        else { return }
        let windowId = windows[position - 1].id
        selectKnownWindow(windowId)
    }

    /// Select a known window by its stable tmux `@id`.
    ///
    /// Compact switchers carry ids rather than positional shortcuts, so this
    /// mirrors `selectWindow(atPosition:)` without re-deriving an index after
    /// the palette snapshot was taken.
    public func selectWindow(_ windowId: WindowId) {
        guard !userMutationsSuppressedWhileYielded else { return }
        guard mode == .tmuxControl,
              isWindowListHydrated,
              windows.contains(where: { $0.id == windowId })
        else { return }
        selectKnownWindow(windowId)
    }

    private func selectKnownWindow(_ windowId: WindowId) {
        clearBell(forWindowID: windowId.rawValue)
        // W2: name our own session. A bare `@W` resolves to the most recently
        // active session holding W, which in a group is often a sibling (the
        // mosh view session, a user's `tmux new -t`), so the switch would land
        // on someone else's screen. Fail open to the bare spelling only in
        // the brief window before `%session-changed` names our session.
        performWindowSelection(
            ownSessionId.map {
                TmuxWindowCommands.selectWindow(windowId, inOwnSession: $0)
            } ?? TmuxWindowCommands.selectWindow(windowId),
            expectedWindowID: windowId
        )
    }

    /// Run a command which changes this control client's selected window and,
    /// for Mosh side-channel sessions, causally mirror the command's resulting
    /// target to the separately attached pixel-producing client. Dynamic
    /// commands (`new`, `next`, `previous`, active close) discover that target
    /// through the shared strict active-window query after their reply.
    private func performWindowSelection(
        _ command: String,
        expectedWindowID: WindowId?
    ) {
        visibleClientSelectionGeneration &+= 1
        let selectionGeneration = visibleClientSelectionGeneration

        guard controlPath == .sideChannel,
              let sessionID = ownSessionId,
              let identity = gridAuthorityIdentity
        else {
            sendControlCommand(command)
            return
        }

        let connectionGeneration = controlConnectionGeneration
        sendControlCommand(command) { [weak self] result in
            guard let self,
                  case .success = result,
                  self.isCurrentVisibleClientSelectionContext(
                      sessionID: sessionID,
                      identityID: identity.id,
                      selectionGeneration: selectionGeneration,
                      connectionGeneration: connectionGeneration
                  )
            else {
                Self.logDiagnostic(
                    "visible-client selection skipped window=\(String(describing: expectedWindowID)) stage=select-control-client"
                )
                return
            }
            self.proveActiveWindowBeforeVisibleMoshSelection(
                expectedWindowID: expectedWindowID,
                sessionID: sessionID,
                identity: identity,
                selectionGeneration: selectionGeneration,
                connectionGeneration: connectionGeneration
            )
        }
    }

    /// A side-channel Mosh session has a metadata/control client and a separate
    /// tmux client whose PTY supplies visible pixels. Keep pane selection on the
    /// same verified, newest-intent path as window selection so the render
    /// ledger cannot bind P2 while the UDP painter remains on P1.
    func selectPaneAcrossTmuxClients(
        _ paneId: PaneId,
        preservingWindowZoom: Bool
    ) {
        let command = "select-pane "
            + (preservingWindowZoom ? "-Z " : "")
            + "-t \(paneId.description)"
        visibleClientSelectionGeneration &+= 1
        let selectionGeneration = visibleClientSelectionGeneration

        guard controlPath == .sideChannel,
              let sessionID = ownSessionId,
              let identity = gridAuthorityIdentity,
              let windowID = windows.first(where: { window in
                  window.panes.contains(where: { $0.id == paneId })
                      || window.layout?.paneIds.contains(paneId) == true
              })?.id
        else {
            sendControlCommand(command) { [weak self] result in
                self?.reportPaneSelectionError(result)
            }
            return
        }

        let connectionGeneration = controlConnectionGeneration
        sendControlCommand(command) { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                self.reportPaneSelectionError(result)
                return
            }
            guard self.isCurrentVisibleClientSelection(
                windowId: windowID,
                paneId: paneId,
                sessionID: sessionID,
                identityID: identity.id,
                selectionGeneration: selectionGeneration,
                connectionGeneration: connectionGeneration,
                requireActiveTarget: false
            ) else {
                Self.logDiagnostic(
                    "visible-client selection skipped window=\(windowID) pane=\(paneId) stage=select-control-client"
                )
                return
            }
            self.proveActivePaneBeforeVisibleMoshSelection(
                windowID: windowID,
                paneID: paneId,
                preservingWindowZoom: preservingWindowZoom,
                sessionID: sessionID,
                identity: identity,
                selectionGeneration: selectionGeneration,
                connectionGeneration: connectionGeneration
            )
        }
    }

    private func reportPaneSelectionError(
        _ result: Result<[String], CommandError>
    ) {
        guard case .failure(.tmuxError(let lines)) = result else { return }
        let message = lines
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        onCommandError?(message)
    }

    private func proveActivePaneBeforeVisibleMoshSelection(
        windowID: WindowId,
        paneID: PaneId,
        preservingWindowZoom: Bool,
        sessionID: SessionId,
        identity: GridAuthorityIdentity,
        selectionGeneration: UInt64,
        connectionGeneration: UInt64
    ) {
        sendControlCommand(
            TmuxRuntimeHydrationQuery.activePaneCommand(windowID: windowID)
        ) { [weak self] result in
            guard let self,
                  self.isCurrentVisibleClientSelection(
                      windowId: windowID,
                      paneId: paneID,
                      sessionID: sessionID,
                      identityID: identity.id,
                      selectionGeneration: selectionGeneration,
                      connectionGeneration: connectionGeneration,
                      requireActiveTarget: false
                  ),
                  case .success(let lines) = result,
                  TmuxRuntimeHydrationQuery.activePaneMatches(
                      windowID: windowID,
                      paneID: paneID,
                      lines: lines
                  )
            else {
                Self.logDiagnostic(
                    "visible-client selection skipped window=\(windowID) pane=\(paneID) stage=prove-active-pane"
                )
                return
            }
            self.mirrorSelectionToVisibleMoshClient(
                windowID: windowID,
                paneID: paneID,
                preservingWindowZoom: preservingWindowZoom,
                sessionID: sessionID,
                identity: identity,
                selectionGeneration: selectionGeneration,
                connectionGeneration: connectionGeneration
            )
        }
    }

    /// A mosh+tmux session has two tmux clients: this `-CC` side channel owns
    /// metadata and the main mosh PTY owns visible pixels. Selecting a window
    /// on only the control client advances the render ledger while leaving the
    /// painter on the previous window, so no causally-new SSP frame can ever
    /// complete the owner handoff. Resolve the device-stamped visible client,
    /// prove that exact name/PID/creation tuple is still attached to our
    /// session, then mirror only the newest selection intent.
    private func proveActiveWindowBeforeVisibleMoshSelection(
        expectedWindowID: WindowId?,
        sessionID: SessionId,
        identity: GridAuthorityIdentity,
        selectionGeneration: UInt64,
        connectionGeneration: UInt64
    ) {
        sendControlCommand(TmuxRuntimeHydrationQuery.activeWindowCommand) { [weak self] result in
            guard let self,
                  self.isCurrentVisibleClientSelectionContext(
                      sessionID: sessionID,
                      identityID: identity.id,
                      selectionGeneration: selectionGeneration,
                      connectionGeneration: connectionGeneration
                  ),
                  case .success(let lines) = result,
                  let windowID = TmuxRuntimeHydrationQuery.activeWindowID(lines: lines),
                  expectedWindowID.map({ $0 == windowID }) ?? true,
                  self.isCurrentVisibleClientSelection(
                      windowId: windowID,
                      sessionID: sessionID,
                      identityID: identity.id,
                      selectionGeneration: selectionGeneration,
                      connectionGeneration: connectionGeneration
                  )
            else {
                Self.logDiagnostic(
                    "visible-client selection skipped window=\(String(describing: expectedWindowID)) stage=prove-active-window"
                )
                return
            }
            self.mirrorSelectionToVisibleMoshClient(
                windowID: windowID,
                paneID: nil,
                preservingWindowZoom: false,
                sessionID: sessionID,
                identity: identity,
                selectionGeneration: selectionGeneration,
                connectionGeneration: connectionGeneration
            )
        }
    }

    private func mirrorSelectionToVisibleMoshClient(
        windowID: WindowId,
        paneID: PaneId?,
        preservingWindowZoom: Bool,
        sessionID: SessionId,
        identity: GridAuthorityIdentity,
        selectionGeneration: UInt64,
        connectionGeneration: UInt64
    ) {
        let visibleOption = Self.gridAuthorityVisibleClientOption(identityID: identity.id)
        sendControlCommand(
            "show-options -qv -t \(sessionID.description) \(visibleOption)"
        ) { [weak self] result in
            guard let self,
                  self.isCurrentVisibleClientSelection(
                      windowId: windowID,
                      paneId: paneID,
                      sessionID: sessionID,
                      identityID: identity.id,
                      selectionGeneration: selectionGeneration,
                      connectionGeneration: connectionGeneration
                  ),
                  case .success(let optionLines) = result,
                  optionLines.filter({ !$0.isEmpty }).count == 1,
                  let stampedIdentity = optionLines.first(where: { !$0.isEmpty }),
                  let visibleClient = Self.visibleClientName(from: stampedIdentity)
            else {
                Self.logDiagnostic(
                    "visible-client selection skipped window=\(windowID) pane=\(String(describing: paneID)) stage=resolve-option"
                )
                return
            }

            self.sendControlCommand(
                "list-clients -t \(sessionID.description) -F '#{client_name}|#{client_pid}|#{client_created}'"
            ) { [weak self] attachedResult in
                guard let self,
                      self.isCurrentVisibleClientSelection(
                          windowId: windowID,
                          paneId: paneID,
                          sessionID: sessionID,
                          identityID: identity.id,
                          selectionGeneration: selectionGeneration,
                          connectionGeneration: connectionGeneration
                      ),
                      case .success(let attachedLines) = attachedResult,
                      attachedLines.filter({ $0 == stampedIdentity }).count == 1
                else {
                    Self.logDiagnostic(
                        "visible-client selection skipped window=\(windowID) pane=\(String(describing: paneID)) stage=verify-attached"
                    )
                    return
                }
                // Windows/panes are shared by grouped sessions. A bare @id
                // or %id lets tmux choose the owner session, silently moving
                // the visible mosh client out of the control client's view.
                let target = TmuxWindowCommands.sessionQualifiedTarget(
                    windowID,
                    sessionID: sessionID,
                    paneID: paneID
                )
                let zoomFlag = preservingWindowZoom && paneID != nil ? "-Z " : ""
                self.sendControlCommand(
                    "switch-client \(zoomFlag)-c \(Self.singleQuotedTmuxArgument(visibleClient)) -t \(target)"
                ) { result in
                    switch result {
                    case .success:
                        Self.logDiagnostic(
                            "visible-client selection completed window=\(windowID) pane=\(String(describing: paneID))"
                        )
                    case .failure:
                        Self.logDiagnostic(
                            "visible-client selection failed window=\(windowID) pane=\(String(describing: paneID))"
                        )
                    }
                }
            }
        }
    }

    private func isCurrentVisibleClientSelection(
        windowId: WindowId,
        paneId: PaneId? = nil,
        sessionID: SessionId,
        identityID: String,
        selectionGeneration: UInt64,
        connectionGeneration: UInt64,
        requireActiveTarget: Bool = true
    ) -> Bool {
        isCurrentVisibleClientSelectionContext(
            sessionID: sessionID,
            identityID: identityID,
            selectionGeneration: selectionGeneration,
            connectionGeneration: connectionGeneration
        )
            && (!requireActiveTarget || (
                runtimeEngine.snapshot.activeWindowID == windowId
                    && (paneId == nil || runtimeEngine.snapshot.windows.first(where: {
                        $0.id == windowId
                    })?.activePaneID == paneId)
            ))
            && windows.contains(where: { window in
                window.id == windowId
                    && (paneId.map { targetPaneID in
                        window.panes.contains(where: { $0.id == targetPaneID })
                            || window.layout?.paneIds.contains(targetPaneID) == true
                    } ?? true)
            })
    }

    private func isCurrentVisibleClientSelectionContext(
        sessionID: SessionId,
        identityID: String,
        selectionGeneration: UInt64,
        connectionGeneration: UInt64
    ) -> Bool {
        mode == .tmuxControl
            && controlPath == .sideChannel
            && controlConnectionGeneration == connectionGeneration
            && visibleClientSelectionGeneration == selectionGeneration
            && ownSessionId == sessionID
            && gridAuthorityIdentity?.id == identityID
            && !userMutationsSuppressedWhileYielded
    }

    /// Parse only the exact tuple written by `moshVisibleClientCommand`.
    /// `client_name` is later shell-quoted, but malformed/ambiguous option
    /// values still fail closed before any client-targeted mutation is queued.
    nonisolated static func visibleClientName(from stampedIdentity: String) -> String? {
        let fields = stampedIdentity.split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard fields.count == 3,
              !fields[0].isEmpty,
              fields[0].utf8.count <= 100,
              !fields[0].unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              fields[1].unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              fields[2].unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let pid = UInt64(fields[1]), pid > 0,
              let created = UInt64(fields[2]), created > 0
        else { return nil }
        return String(fields[0])
    }

    public func clearBell(forWindowID windowID: Int) {
        if bellingWindows.contains(windowID) {
            bellingWindows.remove(windowID)
        }
    }

    /// Tell the controller the current client size (cols × rows). Cached so we
    /// can push `refresh-client -C` to tmux on the next mode flip; also sent
    /// immediately when we're already in tmux mode. Outer views should call
    /// this alongside the transport-level resize any time the terminal view's
    /// dimensions change.
    ///
    /// Why this exists: tmux `-CC` ignores PTY `SIGWINCH` entirely.
    /// It reads the initial size from the controlling PTY's winsize
    /// when `tmux -CC` is launched, then locks the pane grid at that
    /// size until a `refresh-client -C <cols>,<rows>` command tells
    /// it otherwise. Verified against tmux 3.6 via a pty probe —
    /// SIGWINCH flipped the PTY winsize to 120×40, pane stayed at
    /// 80×24; `refresh-client -C 120,40` finally resized the pane.
    /// Without this method, tmux's pane drifts out of sync with
    /// SwiftTerm's view as soon as the simulator rotates or Stage Manager
    /// resizes the window, and `capture-pane` returns a smaller grid than the
    /// SwiftTerm viewport — content shows up in the top-left corner with large
    /// blank margins. The mosh side-channel needs the same replay: its PTY resize
    /// is also ignored by `tmux -CC`, and commands issued by that client (notably
    /// `new-window`) otherwise create panes at the side-channel's stale geometry
    /// until user input through the visible mosh client forces a repaint.
    public func updateClientSize(cols: Int, rows: Int) {
        guard let geometry = try? TmuxClientGeometry(columns: cols, rows: rows) else {
            Self.logDiagnostic("client-size rejected local=\(cols)x\(rows)")
            return
        }
        let cols = geometry.columns
        let rows = geometry.rows
        localViewportSize = (cols, rows)
        if clientSizePolicy == .preserveServerGeometry,
           !reverseAttachPeers.isEmpty,
           reverseAttachBaselineSize == nil {
            reverseAttachBaselineSize = (cols, rows)
            considerReverseAttachCedeFromKnownWindows()
        }
        let ownsPreservedGeometry = compactClientSizeRole == .owner
            && !hasCededGridOwnership
        guard TmuxGeometryCapability.canPublishLocalGeometry(
            policy: clientSizePolicy,
            ownsPreservedGeometry: ownsPreservedGeometry
        ) else {
            if clientSizePolicy == .preserveServerGeometry,
               compactClientSizeRole != .owner {
                Self.logDiagnostic(
                    "client-size ignored local=\(cols)x\(rows) path=\(controlPath) policy=preserve-server role=\(String(describing: compactClientSizeRole))"
                )
            }
            return
        }
        if clientSizePolicy == .preserveServerGeometry {
            let previous = lastKnownSize
            lastKnownSize = (cols, rows)
            guard previous?.cols != cols || previous?.rows != rows else { return }
            replayClientSize(reason: "compact-owner-size-change", previous: previous)
            return
        }
        let previous = lastKnownSize
        lastKnownSize = (cols, rows)
        let priorClaimGeneration = gridAuthorityLifecycle.claim?.generation
        // A late claim waits for its own force's confirmation (§6.10 rule
        // 3); its churn is replayed only after it settles.
        let lateClaim = gridAuthorityLifecycle.claim != nil
            && !gridAuthoritySession.claimMayAdvertiseGeometry
        if previous?.cols != cols || previous?.rows != rows, !lateClaim {
            windowSizeReplayAttempts.removeAll()
            passiveWindowSizeProbe = nil
        }
        if participatesInGridAuthority, previous?.cols != cols || previous?.rows != rows {
            applyGridAuthorityLifecycleEffects(reduceGridAuthority(.localSize(TmuxGridSize(columns: cols, rows: rows))))
        }
        if let claim = gridAuthorityLifecycle.claim, claim.generation != priorClaimGeneration,
           claim.hasAdvertisedGrid(.init(columns: cols, rows: rows)) { return }
        if resumeDeferredGridAuthorityClaim(reason: "measured-viewport") { return }
        let sizeChanged = previous?.cols != cols || previous?.rows != rows
        if sizeChanged || !participatesInGridAuthority {
            // A participating device re-asserting an unchanged size is not a
            // geometry change: on the inline path it would also fence
            // `latest` (and stamp), i.e. seize the grid outside a claim.
            replayClientSize(reason: "size-change", previous: previous)
        }
    }

    /// Resolve whether an inline compact control client owns the tmux grid or
    /// attached to an existing session as an `ignore-size` observer.
    ///
    /// Call after attach hydration has drained so this query joins an aligned
    /// command FIFO. The distinction is deliberately read from tmux rather
    /// than inferred from grid dimensions: a phone-created session may already
    /// have changed height when the software keyboard appears, while an
    /// inherited session may coincidentally have phone-sized geometry.
    public func resolveCompactClientSizeRole() {
        guard clientSizePolicy == .preserveServerGeometry,
              controlPath == .inline,
              mode == .tmuxControl,
              compactClientSizeRole == .unresolved,
              !compactClientSizeRoleResolutionInFlight
        else { return }

        compactClientSizeRoleResolutionInFlight = true
        compactClientSizeRoleRetryTask?.cancel()
        compactClientSizeRoleRetryTask = nil
        compactClientSizeRoleResolutionAttempts += 1
        let connectionGeneration = controlConnectionGeneration
        sendControlCommand("display-message -p '#{client_flags}'") { [weak self] result in
            guard let self,
                  self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration
            else { return }
            self.compactClientSizeRoleResolutionInFlight = false

            guard case .success(let lines) = result,
                  let flags = lines.first(where: { !$0.isEmpty })
            else {
                Self.logDiagnostic(
                    "client-size compact-role unresolved attempt=\(self.compactClientSizeRoleResolutionAttempts) result=\(Self.describe(result))"
                )
                self.scheduleCompactClientSizeRoleRetry(
                    connectionGeneration: connectionGeneration
                )
                return
            }

            let ignoresSize = flags
                .split { $0 == "," || $0 == " " || $0 == "\t" }
                .contains("ignore-size")
            self.compactClientSizeRole = ignoresSize ? .observer : .owner
            self.compactClientSizeRoleResolved = true
            self.compactClientOwnsSize = !ignoresSize
            Self.logDiagnostic(
                "client-size compact-role role=\(ignoresSize ? "observer" : "owner") flags=\(flags)"
            )

            if !ignoresSize, let viewport = self.localViewportSize {
                let previous = self.lastKnownSize
                self.lastKnownSize = viewport
                self.replayClientSize(
                    reason: "compact-owner-role-resolved",
                    previous: previous
                )
            }
        }
    }

    private func scheduleCompactClientSizeRoleRetry(
        connectionGeneration: UInt64
    ) {
        let maxAttempts = 3
        guard compactClientSizeRole == .unresolved,
              compactClientSizeRoleResolutionAttempts < maxAttempts
        else {
            Self.logDiagnostic(
                "client-size compact-role retry exhausted attempts=\(compactClientSizeRoleResolutionAttempts)"
            )
            return
        }

        let delay = 0.15 * Double(compactClientSizeRoleResolutionAttempts)
        compactClientSizeRoleRetryTask?.cancel()
        compactClientSizeRoleRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
            guard !Task.isCancelled,
                  let self,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.mode == .tmuxControl,
                  self.compactClientSizeRole == .unresolved
            else { return }
            self.compactClientSizeRoleRetryTask = nil
            self.resolveCompactClientSizeRole()
        }
    }

    /// Match an `ignore-size` phone client to the server's existing logical
    /// grid without allowing the phone viewport to resize that grid.
    ///
    /// The caller supplies dimensions parsed from the active window layout.
    /// Sending the same dimensions back to this ignored client ensures tmux
    /// emits the complete window rather than a phone-sized crop; because the
    /// client is `ignore-size`, it remains excluded from server window sizing.
    public func adoptPreservedServerSize(cols: Int, rows: Int) {
        guard clientSizePolicy == .preserveServerGeometry,
              cols > 0,
              rows > 0
        else { return }
        if reverseAttachPeers.isEmpty,
           !hasCededGridOwnership,
           reverseAttachOwnerGridBaseline == nil {
            reverseAttachOwnerGridBaseline = (cols, rows)
        }
        let previous = lastKnownSize
        lastKnownSize = (cols, rows)
        replayClientSize(reason: "adopt-server-geometry", previous: previous)
    }

    /// Why a replay sent nothing. P11: a keyboard animation replays on
    /// every frame, so a gated replay is logged once when its gate begins
    /// and the repeats are counted into one line when it ends, instead of a
    /// line per frame saturating the diagnostics budget.
    private enum ClientSizeGate: String {
        case inactive = "deferred (inactive)"
        case withheld = "withheld (authority unresolved)"
        case yielded = "deferred (yielded)"
        case lateClaim = "deferred (late claim)"
    }
    @ObservationIgnored private var clientSizeGateLogged: ClientSizeGate?
    @ObservationIgnored private var clientSizeGateRepeats = 0

    private func noteClientSizeGated(
        _ gate: ClientSizeGate,
        size: (cols: Int, rows: Int),
        reason: String
    ) {
        guard clientSizeGateLogged != gate else {
            clientSizeGateRepeats += 1
            return
        }
        endClientSizeGate()
        clientSizeGateLogged = gate
        Self.logDiagnostic("client-size \(gate.rawValue) cols=\(size.cols) rows=\(size.rows) reason=\(reason)")
    }

    private func endClientSizeGate() {
        guard let gate = clientSizeGateLogged else { return }
        if clientSizeGateRepeats > 0 {
            Self.logDiagnostic("client-size \(gate.rawValue) repeated=\(clientSizeGateRepeats)")
        }
        clientSizeGateLogged = nil
        clientSizeGateRepeats = 0
    }

    private func replayClientSize(
        reason: String,
        previous: (cols: Int, rows: Int)? = nil,
        belongsToGridClaimFence: Bool = false
    ) {
        guard mode == .tmuxControl, let size = lastKnownSize else { return }
        if participatesInGridAuthority, !belongsToGridClaimFence {
            // Both control paths: an inactive app sizes nothing. The
            // foreground read (or the pending intent's own read) decides
            // what the size it returns to may do; an inline replay here
            // would stamp and fence `latest` before that read lands.
            if appIsInactive {
                noteClientSizeGated(.inactive, size: size, reason: reason)
                return
            }
            // D3, both control paths: nothing sizes the window until the
            // authority read resolves. Attach, reconnect and foreground all
            // land here first; the reply releases or keeps the hold.
            if gridAuthorityGeometryWithheld {
                let gate: ClientSizeGate = gridAuthority.isPeer && gridAuthorityLifecycle.claim == nil ? .yielded : .withheld
                noteClientSizeGated(gate, size: size, reason: reason)
                return
            }
        }
        // §6.10 rule 2: a late claim advertises nothing, its own fence
        // included. It finishes on the geometry it already sent; the churn
        // stays latched in `lastKnownSize` and the settlement replays it as
        // an ordinary owner resize.
        if gridAuthorityLifecycle.claim != nil,
           !gridAuthoritySession.claimMayAdvertiseGeometry {
            noteClientSizeGated(.lateClaim, size: size, reason: reason)
            return
        }
        // While yielded, local size churn (keyboard, rotation, split view)
        // must not steal the grid back from the active peer. The size stays
        // latched in `lastKnownSize`; a claim replays it explicitly.
        if gridAuthority.isPeer, gridAuthorityLifecycle.claim == nil {
            noteClientSizeGated(.yielded, size: size, reason: reason)
            return
        }
        endClientSizeGate()
        // Logged so we can catch a transient bogus width (e.g. a half-width cols
        // during a layout/font transition) being pushed to tmux — that would
        // shrink the pane, and on the way back to full width the vacated columns
        // can keep stale background (the half-row gray bleed).
        Self.logDiagnostic(
            "client-size cols=\(size.cols) rows=\(size.rows) prevCols=\(previous?.cols ?? -1) prevRows=\(previous?.rows ?? -1) path=\(controlPath) reason=\(reason)"
        )
        // P5: a replay never writes the stamp. Only a claim does, once, after
        // its fence and authoritative repaint (Core's fence -> repaint ->
        // stamp chain, `commitGridAuthorityLifecycleStamp`). An ordinary
        // replay runs only on the owner (a yielded device defers above, and a
        // device whose read found no stamp sizes with a bare refresh and
        // never stamps), so every peer already holds our stamp from the claim
        // that made us owner and is already veiled; "stamp before size" gave
        // them nothing new. It did cost: each fresh generation redrew every
        // tty client on the server, fanned a subscription burst out to every
        // peer and re-rendered their session view, on every keyboard frame
        // and rotation. Worse, a changed stamp is a new foreign write to a
        // peer's in-flight claim, which aborts it as contested: an owner's
        // keyboard toggle could cancel the take-back the user just tapped on
        // another device.
        //
        // Before the fact: a confirmed claim that re-targets is pending again
        // by the time the ledger decides whether this replay brings its own
        // `latest` fence (the claim's fence sequence follows below instead).
        noteGridClaimAdvertised(size, reason: reason)
        if participatesInGridAuthority, gridAuthoritySession.geometryHold == .withheld { return }
        // The shared replay sequence (`TmuxClientSizeReplay`): on the inline
        // path the refresh is fenced with a targetless no-op `select-window`
        // so this client becomes tmux's `latest`. Without it any client that
        // attached or typed since the last replay — an `ignore-size` phone, a
        // laptop `tmux attach` — holds `latest`, tmux answers the refresh with
        // "no size change", and the window freezes at its old grid while this
        // device renders the new one. A claim acks its replay and sends its
        // own fence (`queueGridClaimFenceSequence`), so it adds none here.
        submitRenderFact(.clientSize(columns: size.cols, rows: size.rows))
        forceWindowSizesToClientSize(
            size, belongsToGridClaimFence: belongsToGridClaimFence,
            evenIfLayoutMatches: belongsToGridClaimFence
        )
        if gridClaimAwaitsFence, !belongsToGridClaimFence, let claim = gridAuthorityLifecycle.claim {
            // Keyboard/rotation churn can update the viewport while a claim's
            // first fence is still queued. Invalidate that fence and append a
            // new policy/fence after this newest replay; otherwise a non-latest
            // policy could acknowledge and expose the terminal before these
            // size commands have reached tmux.
            queueGridClaimFenceSequence(
                connectionGeneration: controlConnectionGeneration,
                claimGeneration: claim.generation,
                reason: "pending-size-\(reason)",
                replaySize: false
            )
        }
    }

    /// §6.10 rule 3: record a grid the live claim advertises, so its echo is
    /// never a loss. A confirmed claim re-targets: it returns to its
    /// geometry phase and drops the repaint in flight, which shows the old
    /// grid; the replay's own fence sequence follows (`replayClientSize`).
    private func noteGridClaimAdvertised(_ size: (cols: Int, rows: Int), reason: String) {
        guard let claim = gridAuthorityLifecycle.claim,
              gridAuthoritySession.claimMayAdvertiseGeometry
        else { return }
        let effects = reduceGridAuthority(.claimAdvertisedGeometry(
            generation: claim.generation,
            size: TmuxGridSize(columns: size.cols, rows: size.rows)
        ))
        gridClaimGeometryEpoch &+= 1
        if claim.phase == .awaitingRepaint,
           gridAuthorityLifecycle.claim?.phase == .awaitingFence {
            Self.logDiagnostic(
                "grid-authority claim re-targeted gen=\(claim.generation) grid=\(size.cols)x\(size.rows) reason=\(reason): repaint dropped"
            )
            clearGridAuthorityRepaintTargets()
            gridAuthorityClaimChangedGeometry = true
        }
        if !effects.isEmpty { applyGridAuthorityLifecycleEffects(effects) }
    }

    /// A Mosh visible client takes tmux's `latest` on every keystroke or
    /// PTY resize even though it is `ignore-size`; the recalculation then
    /// finds no usable candidate ("no calculated size", tmux 3.4 -vv) and the
    /// window freezes at its last transient, on iPhone a mid-keyboard height,
    /// rendered as a top-left crop. A plain laptop can hold `latest` too, so
    /// `refresh-client -C` alone cannot restore our grid. Advertise the side
    /// channel's size first, then use the shared replay: resize, targetless
    /// `select-window`, unset. The fence makes this control client latest in
    /// its own session before the unset recalculates sizing, so the window
    /// does not snap back to the plain client (D2); the unset keeps windows
    /// inheriting session/global sizing so a laptop attaching later still
    /// resizes them natively. Keep the manual resize/unset until the next
    /// protocol step's live lane proves they can be removed; confirmation
    /// follows all mutation replies in a separate write so it sees the final,
    /// policy-governed geometry.
    ///
    /// Scoped to the side channel: an inline `-CC` client has no separate
    /// visible PTY, so it cannot freeze its own session.
    ///
    /// Hydration also uses this path: on a continuity resume the only replay
    /// fires during attach-init, before `list-windows` populates `windows`,
    /// and no later size change replays again (seen in a device diagnostics
    /// log), so without it a frozen window stays frozen for the session.
    private func forceWindowSizesToClientSize(
        _ size: (cols: Int, rows: Int),
        belongsToGridClaimFence: Bool = false,
        onlyWindowID: WindowId? = nil,
        evenIfLayoutMatches: Bool = false,
        recoveryCompletion: ((Bool) -> Void)? = nil
    ) {
        var submitted = false
        defer { if !submitted { recoveryCompletion?(false) } }
        guard mode == .tmuxControl,
              controlPath == .sideChannel,
              clientSizePolicy == .resizeTmux,
              !commandQueueAwaitingTransportRecovery,
              let requested = try? TmuxClientGeometry(columns: size.cols, rows: size.rows)
        else { return }
        // The yield gate, and §6.10 rule 2: a late claim forces nothing.
        if gridAuthorityLifecycle.claim != nil,
           !gridAuthoritySession.claimMayAdvertiseGeometry {
            return
        }
        if gridAuthority.isPeer, gridAuthorityLifecycle.claim == nil {
            return
        }
        if participatesInGridAuthority,
           appIsInactive || gridAuthorityGeometryWithheld
            || gridAuthorityOrdinaryGeometryIsUnstamped,
           !belongsToGridClaimFence {
            return
        }
        if appIsInactive, !belongsToGridClaimFence { return }
        let validWindows = Set(windows.map(\.id))
        windowSizeReplayAttempts = windowSizeReplayAttempts.filter { validWindows.contains($0.key) }
        // The window a claim settles on (`confirmGridClaimIfSettled`). Only it
        // is forced at a matching layout, and only its failure can abort the
        // claim: a background window that already fits keeps its own
        // window-size policy, and one that vanished mid-force says nothing
        // about the take-back.
        let claimWindowID = gridAuthorityLifecycle.claim != nil ? (activeWindowId ?? renderedWindowId) : nil
        if gridAuthorityLifecycle.claim != nil, claimWindowID == nil { return }
        for window in windows {
            if let claimWindowID, window.id != claimWindowID { continue }
            if let onlyWindowID, window.id != onlyWindowID { continue }
            let observed = window.layout.flatMap { layout in
                try? TmuxClientGeometry(columns: layout.root.rect.width, rows: layout.root.rect.height)
            }
            guard (evenIfLayoutMatches && window.id == claimWindowID) || TmuxWindowSizeReplay.decision(
                requested: requested,
                observed: observed,
                lastAttempt: windowSizeReplayAttempts[window.id]?.requested
            ) == .replay else {
                continue
            }
            let commands = TmuxWindowSizeReplay.commands(windowID: window.id, requested: requested)
            guard commands.count == 4 else { continue }
            nextWindowSizeReplayToken &+= 1
            let attempt = WindowSizeReplayAttempt(
                token: nextWindowSizeReplayToken,
                connectionGeneration: controlConnectionGeneration,
                requested: requested
            )
            let windowID = window.id
            // Register before transmission: sendBytes may synchronously deliver
            // replies. Matching layout notifications do not retire this attempt.
            windowSizeReplayAttempts[windowID] = attempt
            reportGridClaimFenceForce()

            let counted = noteGridClaimCommandSent()
            submitted = true
            enqueueControlCommands(Array(commands.dropLast())) { [weak self] results in
                guard let self else { return }
                self.noteGridClaimReplyReceived(counted)
                defer { self.endGridClaimIfStalledLate(context: "window-size-force") }
                guard self.controlConnectionGeneration == attempt.connectionGeneration,
                      self.windowSizeReplayAttempts[windowID] == attempt
                else { recoveryCompletion?(false); return }
                guard results.count == commands.count - 1,
                      results.allSatisfy({ if case .success = $0 { return true }; return false })
                else {
                    if recoveryCompletion != nil {
                        self.windowSizeReplayAttempts.removeValue(forKey: windowID)
                    }
                    recoveryCompletion?(false)
                    Self.logDiagnostic("window-size force failed window=\(windowID): attempt \(recoveryCompletion == nil ? "retained" : "retired")")
                    if let counted, windowID == claimWindowID,
                       self.gridAuthorityLifecycle.claim?.generation == counted {
                        self.applyGridAuthorityLifecycleEffects(
                            self.reduceGridAuthority(.abortClaim(generation: counted, reason: .adapterFailure))
                        )
                    }
                    return
                }
                // Unsetting window-size schedules tmux's recalculation. A query
                // in the mutation batch can see the temporary manual size, so
                // send it only after all three acknowledgements return to the client.
                let confirmCounted = counted.flatMap { _ in self.noteGridClaimCommandSent() }
                self.sendControlCommand(commands[3]) { [weak self] result in
                    guard let self else { return }
                    self.noteGridClaimReplyReceived(confirmCounted)
                    defer { self.endGridClaimIfStalledLate(context: "window-size-confirmation") }
                    guard self.controlConnectionGeneration == attempt.connectionGeneration,
                          self.windowSizeReplayAttempts[windowID] == attempt
                    else { recoveryCompletion?(false); return }
                    guard case .success(let lines) = result,
                          TmuxWindowSizeReplay.confirms(
                            windowID: windowID,
                            requested: requested,
                            reply: lines.joined(separator: "\n")
                          )
                    else {
                        if recoveryCompletion != nil {
                            self.windowSizeReplayAttempts.removeValue(forKey: windowID)
                        }
                        recoveryCompletion?(false)
                        Self.logDiagnostic("window-size confirmation mismatch window=\(windowID): attempt \(recoveryCompletion == nil ? "retained" : "retired")")
                        return
                    }
                    self.windowSizeReplayAttempts.removeValue(forKey: windowID)
                    recoveryCompletion?(true)
                    self.reportGridClaimFenceForce()
                }
            }
        }
    }

    /// Selection and hydration can install a known layout without a
    /// `%layout-change`. Reconcile after the complete read (including policy
    /// and authority replies), using the same passive proof as layout drift.
    /// Discovery alone never sizes a background window.
    private func reconcilePresentedWindowSizeIfNeeded() {
        guard mode == .tmuxControl, presentedWindowRecoveryReserved, !reconcilingPresentedWindowSize,
              let windowID = activeWindowId ?? renderedWindowId else { return }
        if window(windowID)?.layout == nil || (windowLayoutQueriesInFlight[windowID] ?? 0) > 0 || (gridAuthorityRederiveInFlight && gridAuthoritySession.channelIsLive),
           !appIsInactive, !gridAuthoritySession.hidden,
           !gridAuthoritySession.inBackground, gridAuthority == .mine, gridAuthorityLifecycle.claim == nil { return }
        reconcilingPresentedWindowSize = true
        defer { reconcilingPresentedWindowSize = false }
        reconcilePresentedWindowSize(windowId: windowID)
        if presentedWindowRecoveryReserved {
            presentedWindowRecoveryReserved = false
            if passiveWindowSizeProbe == nil {
                applyGridAuthorityLifecycleEffects(reduceGridAuthority(.ordinaryRecovery(active: false, proven: false)))
            }
        }
    }

    /// Let positive client proof judge a newly presented foreign grid before
    /// the stamp-less layout heuristic can yield away our cached own stamp.
    /// This reserves no geometry permission and sends no mutation.
    private func reservePresentedWindowRecovery(_ facts: TmuxAuthorityGeometryEvidence.WindowFacts) {
        if let probe = passiveWindowSizeProbe,
           probe.windowID.rawValue != facts.activeWindow?.id {
            // Carry recovery across the switch; only the new facts may judge it.
            if gridAuthoritySession.ordinaryRecoveryActive { presentedWindowRecoveryReserved = true }
            passiveWindowSizeProbe = nil
        }
        guard !presentedWindowRecoveryReserved, passiveWindowSizeProbe == nil,
              mode == .tmuxControl, controlPath == .sideChannel,
              clientSizePolicy == .resizeTmux, gridAuthority == .mine,
              !appIsInactive, !gridAuthorityGeometryHeld,
              gridAuthorityLifecycle.claim == nil,
              facts.hydrated, let window = facts.activeWindow, window.authoritative,
              gridAuthoritySession.evidence.policy(for: window.id)?.isLatest != false,
              let size = lastKnownSize,
              window.size?.columns != size.cols || window.size?.rows != size.rows else { return }
        presentedWindowRecoveryReserved = true
        // A public authority update can synchronously run the end-of-turn
        // hook; do not release this reservation before installing its facts.
        let wasReconciling = reconcilingPresentedWindowSize
        reconcilingPresentedWindowSize = true
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.ordinaryRecovery(active: true, proven: false)))
        reconcilingPresentedWindowSize = wasReconciling
    }

    // MARK: - Continuity grid authority (takeover overlay)

    /// Whether this client stamps and observes grid authority. Observer
    /// clients (`preserveServerGeometry`) never contend for the grid, and a
    /// nil identity opts the whole mechanism out (tests, harnesses).
    private var participatesInGridAuthority: Bool {
        gridAuthorityIdentity != nil && clientSizePolicy == .resizeTmux
    }

    /// Whether a veil gesture would be admitted now. A gesture while no
    /// control channel is live is still admitted: it records a tap intent
    /// that the next attach resolves (`requestTakeBack(channelLive:)`).
    public var canReclaimGridAuthority: Bool {
        participatesInGridAuthority
            && gridAuthorityLifecycle.authority.isPeer
            && gridAuthorityLifecycle.claim?.presentationVisible != true
    }

    /// Whether the control channel can carry a claim right now. A side
    /// channel that dropped (or a command queue awaiting transport recovery)
    /// cannot, even before the reducer has seen the reset.
    private var gridAuthorityChannelLive: Bool {
        mode == .tmuxControl && !commandQueueAwaitingTransportRecovery
    }

    /// Restrict stamp tokens to a shell- and format-safe alphabet; the value
    /// travels inside single quotes on the control channel and back through
    /// a `%subscription-changed` line.
    nonisolated static func sanitizedAuthorityToken(_ raw: String) -> String {
        TmuxGridAuthorityStamp.sanitizeToken(raw)
    }

    /// Device-scoped session option written by the visible mosh client. The
    /// side-channel uses its value to prove which tmux client instance belongs
    /// to this device before an automatic reclaim; client counts or reusable
    /// PTY names cannot distinguish a surviving peer after a partial disconnect.
    public nonisolated static func gridAuthorityVisibleClientOption(
        identityID: String
    ) -> String {
        TmuxGridAuthority.visibleClientOption(identityID: identityID)
    }

    /// Runs one reducer event and logs the core's own description of the
    /// transition, so an iOS diagnostics report reads exactly like an Android
    /// one (`TmuxGridAuthorityLifecycleReducer.describeTransition`). A no-op
    /// reduction (no effects, equal state) skips the trace entirely: the
    /// same stamp is re-observed once per pane on every subscription echo.
    @discardableResult
    private func reduceGridAuthority(_ event: TmuxGridAuthoritySession.Event) -> [TmuxGridAuthoritySession.Effect] {
        let before = gridAuthoritySession
        let effects = gridAuthoritySession.reduce(event, now: gridAuthorityNow())
        if before != gridAuthoritySession || !effects.isEmpty { gridAuthorityReductionRevision &+= 1 }
        projectGridAuthority(gridAuthorityLifecycle.authority)
        let measurementOnly: Bool
        switch event {
        case .localSize, .sizeAdvertised, .windowFacts: measurementOnly = true
        default: measurementOnly = false
        }
        if (!measurementOnly || before.reducer != gridAuthoritySession.reducer
            || before.query != gridAuthoritySession.query || !effects.isEmpty),
           let trace = TmuxGridAuthoritySession.describeTransition(
            event: event, before: before, after: gridAuthoritySession, effects: effects
        ) {
            Self.logDiagnostic("grid-authority session \(trace)")
        }
        updateGridAuthorityPresentation()
        scheduleGridAuthorityWake()
        return effects
    }

    private func scheduleGridAuthorityWake() {
        let deadline = gridAuthoritySession.nextDeadline
        guard deadline != gridAuthorityWakeDeadline || (deadline != nil && gridAuthorityWakeTask == nil) else { return }
        gridAuthorityWakeTask?.cancel()
        gridAuthorityWakeTask = nil
        gridAuthorityWakeDeadline = deadline
        guard let deadline else { return }
        let delay = max(0, deadline - gridAuthorityNow())
        gridAuthorityWakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.gridAuthorityWakeTask = nil
            self.gridAuthorityWakeDeadline = nil
            self.applyGridAuthorityLifecycleEffects(self.reduceGridAuthority(.tick))
        }
    }

    /// Execute the session's instructions with the existing command FIFO and
    /// render ledger. Authority policy and deadlines stay inside the session.
    private func applyGridAuthorityLifecycleEffects(_ effects: [TmuxGridAuthoritySession.Effect]) {
        let revision = gridAuthorityReductionRevision
        for effect in effects {
            // A single reduction can replace a due retry with a newer show
            // read. Only the session's current query should reach the FIFO.
            if case .queryAuthority(let id) = effect,
               gridAuthoritySession.query.current?.id != id { continue }
            if revision != gridAuthorityReductionRevision {
                // A synchronous wire callback may have advanced the session.
                // Keep only instructions it still owns; an unrelated query
                // bookkeeping change must not strand a current read/claim.
                let stillOwned: Bool
                switch effect {
                case .queryAuthority(let id):
                    stillOwned = gridAuthoritySession.query.current?.id == id
                case .beginClaim(let claim):
                    stillOwned = gridAuthorityLifecycle.claim?.generation == claim.generation
                case .commitAuthorityStamp(let generation):
                    stillOwned = gridAuthorityLifecycle.claim?.generation == generation
                        && gridAuthorityLifecycle.claim?.phase == .awaitingStampCommit
                case .refenceClaim(let generation), .requestRepaint(let generation):
                    stillOwned = gridAuthorityLifecycle.claim?.generation == generation
                default:
                    stillOwned = false
                }
                guard stillOwned else { continue }
            }
            switch effect {
            case .authorityChanged(let authority):
                projectGridAuthority(authority)
            case .hideReclaimPresentation:
                break
            case .claimAborted(let reason):
                Self.logDiagnostic("grid-authority claim aborted reason=\(reason.wireName)")
                clearGridAuthorityClaimBookkeeping()
            case .claimSettled:
                windowSizeReplayAttempts.removeAll()
                passiveWindowSizeProbe = nil
                clearGridAuthorityClaimBookkeeping()
            case .commitAuthorityStamp(let generation):
                commitGridAuthorityLifecycleStamp(generation: generation)
            case .beginClaim(let claim):
                startGridAuthorityClaim(claim)
            case .queryAuthority(let id):
                issueGridAuthorityQuery(id: id)
            case .releaseGeometry(let release):
                switch release {
                case .none: break
                case .advertise: advertiseGridAuthorityClientSize()
                case .ownerReplay:
                    if appIsInactive, participatesInGridAuthority {
                        gridAuthorityOwnerReplayDeferred = true
                        Self.logDiagnostic("grid-authority owner replay deferred reason=inactive")
                    } else {
                        replayClientSize(reason: "authority-owned-geometry")
                    }
                }
            case .raiseStamplessPeer:
                break // The shared verdict is projected after the effects loop.
            case .controlChannelUnresponsive:
                Self.logDiagnostic("grid-authority control channel unresponsive path=\(controlPath)")
                if controlPath == .sideChannel, !commandQueueAwaitingTransportRecovery,
                   let reconnect = onCommandQueueTransportRecoveryRequired {
                    commandQueueAwaitingTransportRecovery = true
                    applyGridAuthorityLifecycleEffects(reduceGridAuthority(.channelLiveness(false)))
                    commandQueueRecoveries += 1
                    reconnect(commandQueueRecoveries)
                }
            case .refenceClaim(let generation):
                refenceGridClaimAfterGeometryLoss(generation: generation)
            case .requestRepaint(let generation):
                guard gridAuthorityLifecycle.claim?.generation == generation,
                      gridAuthorityLifecycle.claim?.phase == .awaitingRepaint else { continue }
                // Fence confirmation is drained after the ledger's layout
                // step, so these targets bind to the surface that will paint.
                performGridAuthorityClaimRepaint(context: "authority-session")
            }
        }
        projectGridAuthority(gridAuthorityLifecycle.authority)
        updateGridAuthorityPresentation()
        let authorityChanged = runtimeEngine.projectAuthority(
            participatesInGridAuthority ? gridAuthorityLifecycle.authority : .unknown
        )
        if revision == gridAuthorityReductionRevision,
           authorityChanged || effects.contains(where: { effect in
            switch effect {
            case .authorityChanged, .claimSettled, .raiseStamplessPeer: return true
            default: return false
            }
        }) {
            let base = executingCommandReplySnapshot ?? runtimeEngine.snapshot
            let snapshot = TmuxSnapshot(
                sessionID: base.sessionID, sessionName: base.sessionName,
                activeWindowID: base.activeWindowID,
                isActiveWindowAuthoritative: base.isActiveWindowAuthoritative,
                windows: base.windows, authority: runtimeEngine.snapshot.authority,
                capabilities: base.capabilities, isReorderPending: base.isReorderPending,
                authoritativeWindowOrder: base.authoritativeWindowOrder, isWindowListHydrated: base.isWindowListHydrated,
                revision: base.revision
            )
            executeRenderEffects(renderLedger.noteAuthority(snapshot: snapshot), snapshot: snapshot)
        }
        if effects.contains(.hideReclaimPresentation) {
            endGridClaimIfStalledLate(context: "presentation-hidden")
        }
        if controlProcessingDepth == 0 { reconcilePresentedWindowSizeIfNeeded() }
    }

    /// P6 is enforced by the ledger. A read's advertise release is always a
    /// bare -C, even over an own stamp; it never transfers latest or forces a window.
    private func advertiseGridAuthorityClientSize() {
        guard mode == .tmuxControl, !gridAuthorityGeometryWithheld,
              let size = lastKnownSize else { return }
        updateRenderLedgerConfiguration(advertiseOnly: true)
        executeRenderEffects(renderLedger.reduce(
            .clientSize(columns: size.cols, rows: size.rows), snapshot: runtimeEngine.snapshot
        ))
        updateRenderLedgerConfiguration()
    }

    /// Starts the wire side of the session's claim: geometry replay, policy
    /// probe and fence (`beginGridClaimWire`). The session owns its deadline.
    private func startGridAuthorityClaim(_ claim: TmuxGridAuthorityLifecycleReducer.Claim) {
        if (claim.reason == .show || claim.reason == .explicitOpen), claim.contestedPeer == nil {
            gridAuthorityForegroundRecoveryGeneration = claim.generation
            gridAuthorityForegroundRecoveryOwner = renderLedger.owner(for: .live)
        } else {
            gridAuthorityForegroundRecoveryGeneration = nil
            gridAuthorityForegroundRecoveryOwner = nil
        }
        beginGridClaimWire(generation: claim.generation, reason: "authority-\(claim.reason.rawValue)")
    }

    /// Derives the one observed presentation from reducer state (never from
    /// `authority` alone) and writes it only when it changed.
    private func updateGridAuthorityPresentation() {
        let enabled = participatesInGridAuthority && (mode == .tmuxControl
            || (controlPath == .sideChannel && gridAuthorityLifecycle.hasAttached))
        let next: GridAuthorityPresentation
        if !enabled { next = .none }
        else {
            switch gridAuthoritySession.presentation {
            case .none: next = .none
            case .resuming(let waiting): next = .resuming(awaitingConnection: waiting)
            case .veiled(let name): next = .veiled(peerName: name)
            case .reclaiming(let name, let waiting): next = .reclaiming(peerName: name, awaitingConnection: waiting)
            }
        }
        if next != gridAuthorityPresentation { gridAuthorityPresentation = next }
        let allowsInput = !enabled || !gridAuthoritySession.gatesTyping
        if allowsInput != gridAuthorityAllowsInput { gridAuthorityAllowsInput = allowsInput }
        let refusal = enabled ? gridAuthoritySession.mutationRefusal : nil
        if gridAuthorityMutationRefusal != refusal { gridAuthorityMutationRefusal = refusal }
        if gridAuthorityGeometryHold != gridAuthoritySession.geometryHold {
            gridAuthorityGeometryHold = gridAuthoritySession.geometryHold
        }
        if gridAuthorityNextDeadline != gridAuthoritySession.nextDeadline {
            gridAuthorityNextDeadline = gridAuthoritySession.nextDeadline
        }
    }

    private func commitGridAuthorityLifecycleStamp(generation: UInt64) {
        guard participatesInGridAuthority,
              mode == .tmuxControl,
              gridAuthorityIdentity != nil,
              let claim = gridAuthorityLifecycle.claim,
              claim.generation == generation,
              claim.phase == .awaitingStampCommit
        else { return }

        guard sideChannelClaimGeometryIsCurrent else {
            applyGridAuthorityLifecycleEffects(
                reduceGridAuthority(.abortClaim(generation: generation, reason: .adapterFailure))
            )
            return
        }

        if controlPath == .sideChannel, gridAuthorityGeometryPolicyIsLatest {
            // The claim's target, not the local grid: churn while the stamp
            // waits is either advertised (visible) or held back (late), and
            // must never strand the claim here (§6.10 rules 3 and 6).
            guard let windowID = activeWindowId ?? renderedWindowId,
                  let size = gridClaimTargetSize,
                  let requested = try? TmuxClientGeometry(columns: size.cols, rows: size.rows)
            else {
                applyGridAuthorityLifecycleEffects(
                    reduceGridAuthority(.abortClaim(generation: generation, reason: .adapterFailure))
                )
                return
            }
            let connectionGeneration = controlConnectionGeneration
            let command = TmuxWindowSizeReplay.sizeQuery(windowID: windowID)
            // Native delivery proves the local canvas. This final query proves
            // the remote window still fits before committing its ownership.
            sendControlCommand(command) { [weak self] result in
                guard let self,
                      self.controlConnectionGeneration == connectionGeneration,
                      self.gridAuthorityLifecycle.claim?.generation == generation,
                      self.gridAuthorityLifecycle.claim?.phase == .awaitingStampCommit
                else { return }
                guard case .success(let lines) = result,
                      (self.activeWindowId ?? self.renderedWindowId) == windowID,
                      self.sideChannelClaimGeometryIsCurrent,
                      TmuxWindowSizeReplay.confirms(
                        windowID: windowID,
                        requested: requested,
                        reply: lines.joined(separator: "\n")
                      )
                else {
                    self.applyGridAuthorityLifecycleEffects(
                        self.reduceGridAuthority(.abortClaim(generation: generation, reason: .adapterFailure))
                    )
                    return
                }
                self.writeGridAuthorityLifecycleStamp(generation: generation)
            }
            return
        }
        writeGridAuthorityLifecycleStamp(generation: generation)
    }

    private func writeGridAuthorityLifecycleStamp(generation: UInt64) {
        guard let identity = gridAuthorityIdentity,
              gridAuthorityLifecycle.claim?.generation == generation,
              gridAuthorityLifecycle.claim?.phase == .awaitingStampCommit
        else { return }

        let connectionGeneration = controlConnectionGeneration
        let stamp = TmuxGridAuthorityStamp(
            identity: identity,
            generation: generation
        )
        let scope = gridAuthorityScope
        let commands = TmuxGridAuthority.writeCommands(stamp, scope: scope)
        sendControlCommand(commands[0]) { [weak self] result in
            if case .failure(.tmuxError) = result {
                self?.abandonGridAuthorityOwnerScope(scope, connection: connectionGeneration, reason: "owner-write-failed")
            }
            guard let self,
                  self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration,
                  let liveClaim = self.gridAuthorityLifecycle.claim,
                  liveClaim.generation == generation,
                  liveClaim.phase == .awaitingStampCommit
            else { return }

            guard case .success = result else {
                Self.logDiagnostic(
                    "grid-authority lifecycle stamp failed gen=\(generation): stay yielded"
                )
                self.applyGridAuthorityLifecycleEffects(
                    reduceGridAuthority(.abortClaim(generation: generation, reason: .adapterFailure))
                )
                return
            }

            self.applyGridAuthorityLifecycleEffects(
                reduceGridAuthority(.stampCommitSucceeded(
                    generation: generation
                ))
            )
            guard self.gridAuthorityLifecycle.claim?.phase == .awaitingSettlement else {
                return
            }
            self.applyGridAuthorityLifecycleEffects(
                reduceGridAuthority(.settleClaim(generation: generation))
            )
            Self.logDiagnostic(
                "grid-authority lifecycle stamp committed gen=\(generation); presentation active"
            )
        }
        for command in commands.dropFirst() { sendControlCommand(command) }
    }

    private func clearGridAuthorityClaimBookkeeping() {
        gridAuthorityForegroundRecoveryGeneration = nil
        gridAuthorityForegroundRecoveryOwner = nil
        clearGridAuthorityRepaintTargets()
        gridAuthorityClaimChangedGeometry = false
    }

    /// Fold a live subscription edge through the shared session. Its raw memo
    /// owns pane fan-out dedupe; local parsing only explains diagnostics and
    /// retires adapter bookkeeping after a foreign write.
    private func handleGridAuthoritySubscription(value: String) {
        guard participatesInGridAuthority, let identity = gridAuthorityIdentity else { return }
        let previousAuthority = gridAuthority
        let previousSession = gridAuthoritySession
        let lifecycleEffects = reduceGridAuthority(.stampObserved(raw: value))
        applyGridAuthorityLifecycleEffects(lifecycleEffects)
        // The session already rejected a pane fan-out replay before parsing.
        // Diagnostics must not parse that same replay again locally.
        guard previousSession != gridAuthoritySession || !lifecycleEffects.isEmpty else { return }
        guard let stamp = TmuxGridAuthorityStamp.parse(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        if stamp.deviceID == TmuxGridAuthorityStamp.sanitizeToken(identity.id) {
            if !lifecycleEffects.contains(where: { if case .beginClaim = $0 { return true }; return false }),
               gridAuthorityLifecycle.claim == nil,
               previousAuthority == .unknown,
               !gridAuthority.isPeer {
                Self.logDiagnostic("grid-authority stamp echo (steady state)")
            }
        } else {
            if lifecycleEffects.contains(where: { if case .claimAborted = $0 { return true }; return false }) {
                Self.logDiagnostic("grid-authority reclaim contested by \(stamp.displayName)")
            } else if !previousAuthority.isPeer, gridAuthority.isPeer {
                Self.logDiagnostic("grid-authority yielded to \(stamp.displayName)")
            }
        }
    }

    /// The veil gesture (R4): a pointer tap, Return or a printable key on
    /// the continued-elsewhere veil. Claims at once over a live channel;
    /// otherwise records a tap intent bound to the peer the veil names, which
    /// the next attach resolves. Returns true when the reducer admitted it.
    @discardableResult
    public func reclaimGridAuthority(reason: String = "user") -> Bool {
        guard participatesInGridAuthority else {
            Self.logDiagnostic(
                "grid-authority take-back rejected reason=\(reason) participates=false"
            )
            return false
        }
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.channelLiveness(gridAuthorityChannelLive)))
        let before = gridAuthorityLifecycle
        let effects = reduceGridAuthority(.requestTakeBack)
        applyGridAuthorityLifecycleEffects(effects)
        let admitted = gridAuthorityLifecycle != before
        if !admitted {
            Self.logDiagnostic(
                "grid-authority take-back ignored reason=\(reason) authority=\(gridAuthority) claim=\(gridAuthorityLifecycle.claim.traceLabel)"
            )
        }
        return admitted
    }

    /// The session became displayed on this device (R1), or an explicit
    /// open targeted it even though it already was. Records an intent and
    /// always sends a fresh `show-options` read when the channel is live, so
    /// the reply postdates everything tmux queued before the show.
    ///
    /// - Parameter intentElapsed: time the user's step has already spent
    ///   before reaching this controller (a show carried from a replaced
    ///   session object). The R3 window runs from the step, not from here;
    ///   a step that already outlived it is dropped.
    public func gridAuthorityShown(
        source: TmuxGridAuthorityLifecycleReducer.ShowSource = .show,
        intentElapsed: TimeInterval = 0
    ) {
        guard participatesInGridAuthority else { return }
        let stepAt = gridAuthorityNow() - Int64(max(0, intentElapsed) * 1_000)
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.shown(source: source, stepAt: stepAt)))
    }

    /// A replacement of an already shown slot adopts visibility without a gesture.
    public func gridAuthorityAdoptShown() {
        guard participatesInGridAuthority else { return }
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.adoptShown))
    }

    /// Real background boundaries are distinct from transparent render inactivity.
    public func gridAuthorityBackgrounded() {
        // Capture app state even before the owner installs its identity.
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.backgrounded))
        noteGridAuthorityPaintable()
    }

    public func gridAuthorityForegrounded() {
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.foregrounded))
        noteGridAuthorityPaintable()
    }

    /// A hide edge: drops an intent and, while the session stays hidden,
    /// keeps a peer's veil from being drawn on a surface the user cannot
    /// see (it shows as `.resuming` until the next show decides). A claim
    /// whose wire work has started finishes on its own (S4′); one that is
    /// still waiting for a measured viewport never sent anything, so it is
    /// abandoned rather than carried out from a hidden session (L2).
    public func gridAuthorityHidden() {
        guard participatesInGridAuthority else { return }
        abandonUnsentGridAuthorityClaim(context: "hidden")
        applyGridAuthorityLifecycleEffects(
            reduceGridAuthority(.hidden)
        )
        updateGridAuthorityPresentation()
    }

    /// A claim still waiting for a measured viewport has sent nothing (it
    /// never advertised a target); a hide or a cancel abandons it rather
    /// than letting it run later.
    private func abandonUnsentGridAuthorityClaim(context: String) {
        guard let claim = gridAuthorityLifecycle.claim,
              claim.phase == .awaitingFence,
              claim.targetGrid == nil
        else { return }
        Self.logDiagnostic(
            "grid-authority \(context): abandoning unsent claim gen=\(claim.generation)"
        )
        applyGridAuthorityLifecycleEffects(
            reduceGridAuthority(.abortClaim(
                generation: claim.generation,
                reason: .superseded
            ))
        )
    }

    /// Time the pending intent's user step has used of its R3 window; nil
    /// without one. Zero while a prompt pauses the clock (answering it
    /// restarts the full window).
    public var gridAuthorityIntentElapsed: TimeInterval? {
        gridAuthoritySession.intentClock.elapsed(now: gridAuthorityNow()).map { Double($0) / 1_000 }
            ?? gridAuthoritySession.carriedShow(now: gridAuthorityNow()).map { Double(max(0, gridAuthorityNow() - $0.stepAt)) / 1_000 }
    }

    /// The pending-state "cancel" (the X on "takes control when
    /// reconnected" and on the show pill): ends the waiting intent now,
    /// exactly as its R3 expiry would, and abandons a claim that never sent
    /// its commands. It is not a hide: the session is still on screen, so
    /// the show-rule hidden flag is left alone and a peer that holds the
    /// grid is drawn as the tappable veil once the channel reads it.
    public func cancelGridAuthorityIntent() {
        guard participatesInGridAuthority else { return }
        abandonUnsentGridAuthorityClaim(context: "cancel")
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.cancelIntent))
    }

    /// R3 pause while a host-key, password, OTP or Face ID prompt is on
    /// screen. Answering it is the user's next step, so resuming restarts the
    /// full window rather than continuing the old one.
    public func setGridAuthorityIntentClockPaused(_ paused: Bool) {
        // The slot coordinator already combines session prompts with connect
        // prompts for this target; its effective pause is a session prompt here.
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.prompt(scope: .session, active: paused)))
    }

    public func setGridAuthorityPromptState(session: Bool, connect: Bool) {
        // Raise a new scope before lowering an old one so switching prompts
        // does not briefly resume/expire R3 between the two facts.
        if session { applyGridAuthorityLifecycleEffects(reduceGridAuthority(.prompt(scope: .session, active: true))) }
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.prompt(scope: .connect, active: connect)))
        if !session { applyGridAuthorityLifecycleEffects(reduceGridAuthority(.prompt(scope: .session, active: false))) }
    }

    /// A user step that keeps a pending intent alive (a prompt answered, an
    /// in-place retry): restart its R3 window.
    public func noteGridAuthorityUserStep() {
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.userStep))
    }

    /// R3: the pending intent expires `gridAuthorityIntentTimeout` after the
    /// user's step whether or not a channel has attached yet; only a prompt
    /// on screen pauses it. A first connection that outlives the window
    /// (without a prompt) resolves as a plain attach: read, never claim.

    public func setGridAuthorityUsesCompactSinglePaneGrid(_ compact: Bool) {
        guard gridAuthorityUsesCompactSinglePaneGrid != compact else { return }
        gridAuthorityUsesCompactSinglePaneGrid = compact
        noteGridAuthorityPaintable()
        if let activeWindowId {
            reconcileGridAuthorityRepaintForLayout(windowId: activeWindowId)
        }
    }

    /// The refresh command (⌘R, `requestFullRepaint`): a repaint and nothing
    /// else (D9). Control moves only on a show edge or a veil gesture, so no
    /// stamp, no `latest` fence and no claim that a contest could strand.
    /// `repaintEvenIfSame` is the shared command's; every refresh repaints.
    public func claimActiveViewport(reason: String, repaintEvenIfSame: Bool = false) {
        guard mode == .tmuxControl else { return }
        repaintActiveViewportWithoutClaim(reason: reason)
    }

    /// The wire side of the session's claim `generation`.
    ///
    /// `refresh-client -C` alone does not reliably transfer tmux's
    /// `window-size latest` ownership — a diagnostics log showed the iPad
    /// advertising 166x54 while captures stayed at the phone's 105x31. On
    /// the inline path the claim therefore follows the size replay with a
    /// no-op `select-window` on the *current* window from this control
    /// client, which does make this client latest (verified against a
    /// disposable tmux 3.4 fixture; no visible switch, no `resize-window`,
    /// no manual window-size option). The side channel uses the same targetless
    /// fence inside its shared resize/fence/unset sequence, so the unset
    /// recalculates from this control client's already advertised grid.
    ///
    /// The session confirms the claim's fence (`ClaimFence`) once the server
    /// has processed the replay and the selection and, under `latest`, the
    /// active window's layout equals the claim's target.
    private func beginGridClaimWire(generation: UInt64, reason: String) {
        guard mode == .tmuxControl,
              let claim = gridAuthorityLifecycle.claim, claim.generation == generation
        else { return }
        // Core admits the intent before UIKit has necessarily measured a
        // viewport (`resumeDeferredGridAuthorityClaim`).
        guard lastKnownSize != nil else {
            Self.logDiagnostic("grid-authority claim deferred: viewport unavailable gen=\(generation) reason=\(reason)")
            return
        }
        guard gridAuthoritySession.claimMayAdvertiseGeometry else {
            // §6.10 rule 2: a claim that may not advertise the viewport has
            // nothing to fence, and nothing else to finish.
            stallGridClaim(context: "viewport-measured-late", canProgress: false, fenceAgain: false)
            return
        }
        windowSizeReplayAttempts.removeAll()
        passiveWindowSizeProbe = nil
        if gridAuthorityForegroundRecoveryGeneration != generation {
            gridAuthorityForegroundRecoveryGeneration = nil
            gridAuthorityForegroundRecoveryOwner = nil
        }
        let localSize = lastKnownSize
        let currentRect = (activeWindowId ?? renderedWindowId)
            .flatMap(indexOfWindow)
            .flatMap { windows[$0].layout?.root.rect }
        gridAuthorityClaimChangedGeometry = currentRect == nil
            || currentRect?.width != localSize?.cols
            || currentRect?.height != localSize?.rows
        clearGridAuthorityRepaintTargets()
        queueGridClaimFenceSequence(
            connectionGeneration: controlConnectionGeneration,
            claimGeneration: generation,
            reason: reason,
            replaySize: true
        )
    }

    /// D9 manual refresh: repaint the visible surfaces when this device may
    /// render authoritatively. A participating controller repaints nothing
    /// while a peer holds the grid, a claim is in flight or the authority
    /// read has not resolved (the read's own outcome repaints).
    private func repaintActiveViewportWithoutClaim(reason: String) {
        let authority = gridAuthorityLifecycle.authority
        if participatesInGridAuthority {
            guard !authority.isPeer,
                  gridAuthorityLifecycle.claim == nil,
                  !gridAuthorityGeometryWithheld
            else {
                Self.logDiagnostic(
                    "grid-authority manual refresh skipped reason=\(reason) authority=\(authority.traceLabel) claim=\(gridAuthorityLifecycle.claim.traceLabel) held=\(gridAuthorityGeometryHeld)"
                )
                return
            }
        }
        Self.logDiagnostic("grid-authority manual refresh repaint reason=\(reason) path=\(controlPath)")
        switch controlPath {
        case .sideChannel:
            // Mosh paints outside this control connection. The request is
            // untracked: nothing waits for its acknowledgement.
            guard let requestRepaint = onGridAuthoritySideChannelRepaintRequired else { return }
            onGridAuthoritySideChannelRepaintPreparing?()
            gridAuthoritySideChannelRepaintGeneration &+= 1
            requestRepaint(false, gridAuthoritySideChannelRepaintGeneration)
        case .inline:
            guard !appIsInactive else { return }
            _ = advanceStateGeneration(reason: "manual-refresh")
            let surfaces = currentRenderDeclarations.isEmpty
                ? [defaultRenderSurfaceDeclaration]
                : currentRenderDeclarations
            for declaration in surfaces {
                submitRenderFact(.refreshRequested(
                    declaration.surfaceID,
                    stage: .viewport,
                    reason: reason
                ))
            }
        }
    }

    /// Resume only the admitted claim whose wire work has not started.
    /// A changed foreign stamp aborts it in Core, so a later measurement cannot
    /// silently take the grid back after that cancellation.
    @discardableResult
    private func resumeDeferredGridAuthorityClaim(reason: String) -> Bool {
        guard mode == .tmuxControl,
              lastKnownSize != nil,
              let claim = gridAuthorityLifecycle.claim,
              claim.phase == .awaitingFence,
              claim.targetGrid == nil
        else { return false }
        beginGridClaimWire(generation: claim.generation, reason: reason)
        return true
    }

    /// Probe the effective policy of the exact window this claim will fence.
    /// The query is queued after any size replay/unset mutations and before the
    /// fence, so FIFO ordering makes the policy authoritative by the time the
    /// fence can acknowledge. Each sequence is a new fence in the session
    /// (`claimFenceSent`), which retires every reply to an older one.
    private func queueGridClaimFenceSequence(
        connectionGeneration: UInt64,
        claimGeneration: UInt64,
        reason: String,
        replaySize: Bool
    ) {
        guard mode == .tmuxControl,
              controlConnectionGeneration == connectionGeneration,
              let claim = gridAuthorityLifecycle.claim,
              claim.generation == claimGeneration,
              claim.phase == .awaitingFence
        else {
            return
        }
        if replaySize {
            replayClientSize(
                reason: reason,
                belongsToGridClaimFence: true
            )
        }
        // Only geometry the claim advertised can be fenced.
        guard gridClaimAwaitsFence, liveGridClaimGeneration == claimGeneration else { return }
        // A claim that may no longer advertise fences nothing either (rule 2,
        // as Android's `sendTmuxGridAuthorityFence`): a late one ends once
        // nothing of its own is left on the wire.
        guard gridAuthoritySession.claimMayAdvertiseGeometry else {
            endGridClaimIfStalledLate(context: "fence-withheld")
            return
        }
        guard let target = activeWindowId ?? renderedWindowId else {
            Self.logDiagnostic(
                "grid-authority fence deferred reason=\(reason): active window unavailable"
            )
            // A `-C` this claim sent may still be on the wire, and no claim
            // aborts over its own geometry (I3): a counted no-op behind it
            // keeps a late claim from stalling before tmux has processed it.
            // Every deferral sends one, so none precedes a newer `-C`.
            let counted = noteGridClaimCommandSent()
            sendControlCommand("display-message -p ''") { [weak self] _ in
                guard let self else { return }
                self.noteGridClaimReplyReceived(counted)
                self.endGridClaimIfStalledLate(context: "fence-deferred")
            }
            return
        }
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.claimFenceSent(
            generation: claimGeneration, windowID: target.rawValue
        )))
        guard let fence = gridAuthoritySession.claimFence, fence.generation == claimGeneration else { return }
        // The replay's window force went out before this fence existed.
        reportGridClaimFenceForce()
        // Side-channel replay temporarily makes every known window manual,
        // then unsets that override. Probe only after those FIFO mutations so
        // this claim observes the policy that will actually govern settlement.
        probeGridAuthorityWindowSizePolicy(
            windowId: target,
            connectionGeneration: connectionGeneration,
            claimGeneration: claimGeneration,
            fenceID: fence.id,
            reason: reason
        )
        // The fence goes out in the same FIFO burst as the replay and the
        // probe. It used to wait one extra round trip (a `display-message`
        // hop) so that a `select-window -t @W` built from a pre-replay
        // snapshot could not name a window the peer had already left. The
        // inline fence now names no window (W2), so tmux resolves it to our
        // session's current window when it runs, and the hop has nothing left
        // to protect.
        sendGridClaimFence(
            connectionGeneration: connectionGeneration,
            claimGeneration: claimGeneration,
            fenceID: fence.id,
            target: target
        )
        sendGridClaimRepaintBehindFence(
            claimGeneration: claimGeneration,
            fenceID: fence.id,
            target: target
        )
    }

    /// P8: when the claim cannot change geometry (our grid already equals
    /// the window's, so the fence's `select-window` recalculates to the same
    /// size and tmux resizes nothing), the repaint the confirmation would
    /// request after the fence's reply goes out now, behind the fence in the
    /// same burst, and the take-back costs two round trips (this burst, then
    /// the stamp commit) instead of three. Even a first-on-connection
    /// `refresh-client -C` at an equal size only echoes an identical layout,
    /// which the ledger ignores. A claim that resizes the window keeps the
    /// confirmation-time repaint: a capture queued here would run before
    /// tmux applies the deferred resize.
    private func sendGridClaimRepaintBehindFence(
        claimGeneration: UInt64,
        fenceID: UInt64,
        target: WindowId
    ) {
        gridAuthorityClaimRepaintInFlight = nil
        guard controlPath == .inline,
              mode == .tmuxControl,
              !appIsInactive,
              gridClaimAwaitsFence,
              gridAuthoritySession.claimFence?.id == fenceID,
              gridAuthorityLifecycle.claim?.generation == claimGeneration,
              !gridAuthorityClaimChangedGeometry,
              let size = gridClaimTargetSize,
              let window = window(target),
              let rect = window.layout?.root.rect,
              rect.width == size.cols, rect.height == size.rows
        else { return }
        submitCorrelatedGridClaimRepaint(
            claimGeneration: claimGeneration,
            fenceID: fenceID,
            target: target,
            window: window,
            relied: false,
            context: "behind fence"
        )
    }

    /// Sends a claim's visible repaint as correlated refreshes, which queue
    /// behind the commands already on the wire (P8) rather than waiting for
    /// the FIFO to drain, and records it as the claim's repaint in flight.
    /// Returns false, sending nothing, when a target surface is not mounted
    /// and painted yet: that one needs the foreground path's first fill.
    @discardableResult
    private func submitCorrelatedGridClaimRepaint(
        claimGeneration: UInt64,
        fenceID: UInt64,
        target: WindowId,
        window: WindowInfo,
        relied: Bool,
        context: String
    ) -> Bool {
        let surfaces: [SurfaceId]
        let panes: Set<PaneId>
        if window.rendersAsPaneGrid {
            panes = gridAuthorityVisiblePaneTargets(in: window)
            surfaces = panes
                .sorted { $0.rawValue < $1.rawValue }
                .map(Self.inlinePaneSurfaceID)
            let declared = Set(currentRenderDeclarations.map(\.surfaceID))
            // Pane surfaces mount a turn after the shape changes. Repaint
            // only surfaces that are mounted and painted; an unpainted one
            // needs the foreground path's deep first fill.
            guard !surfaces.isEmpty,
                  surfaces.allSatisfy({ declared.contains($0) && renderLedger.owner(for: $0) != nil })
            else { return false }
        } else {
            panes = []
            surfaces = [.live]
            guard currentRenderDeclarations.isEmpty
                    || currentRenderDeclarations.contains(where: { $0.surfaceID == .live }),
                  renderLedger.owner(for: .live) != nil
            else { return false }
        }
        gridAuthorityClaimRepaintInFlight = GridAuthorityClaimRepaintInFlight(
            claimGeneration: claimGeneration,
            fenceID: fenceID,
            window: window.rendersAsPaneGrid ? nil : target,
            panes: panes,
            relied: relied
        )
        Self.logDiagnostic(
            "grid-authority claim repaint \(context) gen=\(claimGeneration) fence=\(fenceID) surfaces=\(surfaces.count)"
        )
        // No state-generation advance here, unlike the foreground repaint:
        // the correlation already scopes these refreshes, and an advance
        // would retire unrelated callbacks still in flight (hydration
        // replies queued behind a reconnect's authority read, a pane
        // interaction query) that this repaint does not replace.
        for surfaceID in surfaces {
            // In place when the surface already shows this pane; the ledger
            // rebinds (and deepens after settlement) when it does not.
            submitRenderFact(.correlatedRefreshRequested(
                surfaceID,
                stage: .viewportOnly,
                reason: "authority-claim",
                correlation: claimGeneration
            ))
        }
        return true
    }

    /// Whether the repaint sent behind this claim's fence covers exactly the
    /// targets confirmation just armed; if so it is adopted, not repeated.
    private func adoptGridClaimRepaintBehindFence() -> Bool {
        guard var inFlight = gridAuthorityClaimRepaintInFlight,
              inFlight.claimGeneration == liveGridClaimGeneration,
              inFlight.fenceID == gridAuthoritySession.claimFence?.id,
              inFlight.window == gridAuthorityRepaintWindow,
              inFlight.panes == gridAuthorityRepaintPanes
        else {
            gridAuthorityClaimRepaintInFlight = nil
            return false
        }
        inFlight.relied = true
        gridAuthorityClaimRepaintInFlight = inFlight
        return true
    }

    /// A correlated claim repaint ended without a frame (superseded by
    /// another refresh, aborted, transport boundary). Before confirmation
    /// nothing relied on it; after, request the ordinary repaint.
    private func gridClaimRepaintBehindFenceFailed(correlation: UInt64, reason: String) {
        guard let inFlight = gridAuthorityClaimRepaintInFlight,
              inFlight.claimGeneration == correlation
        else { return }
        gridAuthorityClaimRepaintInFlight = nil
        guard inFlight.relied,
              gridAuthorityLifecycle.claim?.generation == correlation,
              gridAuthorityRepaintWindow != nil || !gridAuthorityRepaintPanes.isEmpty,
              !appIsInactive
        else { return }
        Self.logDiagnostic(
            "grid-authority claim repaint behind fence failed gen=\(correlation) reason=\(reason): repainting"
        )
        refreshActiveWindowOnForeground()
    }

    private func probeGridAuthorityWindowSizePolicy(
        windowId: WindowId,
        connectionGeneration: UInt64,
        claimGeneration: UInt64,
        fenceID: UInt64,
        reason: String
    ) {
        let counted = noteGridClaimCommandSent()
        sendControlCommand(
            "show-options -wA -v -t \(windowId.description) window-size"
        ) { [weak self] result in
            guard let self else { return }
            self.noteGridClaimReplyReceived(counted)
            defer { self.endGridClaimIfStalledLate(context: "window-size-policy") }
            guard self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.gridAuthorityLifecycle.claim?.generation == claimGeneration
            else { return }
            guard case .success(let lines) = result else {
                Self.logDiagnostic(
                    "grid-authority window-size probe failed window=\(windowId) reason=\(reason): stay yielded"
                )
                return
            }
            let value = (lines.first(where: { !$0.isEmpty }) ?? "latest")
                .trimmingCharacters(in: .whitespaces)
            // Speaks for the fence only while it is the claim's latest; the
            // session confirms the fence once it has settled.
            self.applyGridAuthorityLifecycleEffects(self.reduceGridAuthority(.windowSizePolicyReplied(
                windowID: windowId.rawValue, raw: lines.joined(separator: "\n"), fenceID: fenceID
            )))
            if self.gridAuthoritySession.claimFence?.id == fenceID,
               self.gridAuthoritySession.claimFence?.policyIsLatest == false {
                Self.logDiagnostic(
                    "grid-authority window-size=\(value) window=\(windowId): layout fallback disabled, claim confirms on ack"
                )
            }
        }
    }

    /// Keep the stamp-less layout fallback aligned with the current window's
    /// effective policy outside a claim. Unknown policy disables the fallback
    /// (safe) until this targeted query answers.
    private func probeSteadyGridAuthorityWindowSizePolicy(
        windowId: WindowId,
        reason: String
    ) {
        guard participatesInGridAuthority,
              mode == .tmuxControl,
              !gridClaimAwaitsFence
        else { return }
        let connectionGeneration = controlConnectionGeneration
        let sessionId = ownSessionId
        sendControlCommand(
            "show-options -wA -v -t \(windowId.description) window-size"
        ) { [weak self] result in
            guard let self,
                  self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.ownSessionId == sessionId,
                  !self.gridClaimAwaitsFence,
                  (self.activeWindowId ?? self.renderedWindowId) == windowId,
                  case .success(let lines) = result
            else { return }
            let value = (lines.first(where: { !$0.isEmpty }) ?? "latest")
                .trimmingCharacters(in: .whitespaces)
            self.reservePresentedWindowRecovery(self.gridAuthorityWindowFacts())
            self.applyGridAuthorityLifecycleEffects(self.reduceGridAuthority(.windowSizePolicyReplied(
                windowID: windowId.rawValue, raw: lines.joined(separator: "\n")
            )))
            Self.logDiagnostic(
                "grid-authority steady window-size=\(value.isEmpty ? "latest" : value) window=\(windowId) reason=\(reason)"
            )
            // A layout notification can land while this policy probe is in
            // flight. Re-evaluate the model's latest layout now so that brief
            // policy-unknown windows do not permanently miss a bare tmux
            // client's resize.
            self.noteGridAuthorityWindowFacts()
            self.reconcilePresentedWindowSize(windowId: windowId)
        }
    }

    /// Send (or re-send) the claim fence `fenceID`. `target` is the window
    /// the model expected to be current, and a reply that finds another one
    /// current is dropped (the window-moved re-fence owns that case).
    ///
    /// Inline, the fence is the targetless latest-client transfer
    /// (`TmuxClientSizeReplay.latestFenceCommand`): with no `-t`, tmux
    /// resolves `select-window` to this control client's own session and its
    /// current window, so it can neither switch a window nor reach a grouped
    /// sibling (W2). On the side channel the shared resize/fence/unset is already
    /// queued, and a no-op `display-message` reply alone orders the
    /// confirmation after it.
    private func sendGridClaimFence(
        connectionGeneration: UInt64,
        claimGeneration: UInt64,
        fenceID: UInt64,
        target: WindowId
    ) {
        guard mode == .tmuxControl,
              controlConnectionGeneration == connectionGeneration,
              gridAuthorityLifecycle.claim?.generation == claimGeneration,
              gridAuthoritySession.claimFence?.id == fenceID,
              (activeWindowId ?? renderedWindowId) == target,
              gridClaimAwaitsFence
        else { return }
        let fence = controlPath == .inline
            ? TmuxClientSizeReplay.latestFenceCommand
            : "display-message -p ''"
        let epoch = gridClaimGeometryEpoch
        let counted = noteGridClaimCommandSent()
        sendControlCommand(fence) { [weak self] _ in
            guard let self else { return }
            // Counted until this reply's work is done: `sendBytes` may answer
            // the probe below synchronously, and that answer's stall check
            // must not find the claim idle before its repaint is requested.
            defer {
                self.noteGridClaimReplyReceived(counted)
                self.endGridClaimIfStalledLate(context: "claim-fence")
            }
            // A reply that outlived its claim (an abort, a contest) or its
            // fence acknowledges nothing for the next one.
            guard self.controlConnectionGeneration == connectionGeneration,
                  self.gridAuthorityLifecycle.claim?.generation == claimGeneration,
                  self.gridAuthoritySession.claimFence?.id == fenceID,
                  (self.activeWindowId ?? self.renderedWindowId) == target
            else { return }
            // Acknowledged before the probe goes out, so even a synchronous
            // answer finds the fence acknowledged; the repaint a confirmation
            // requests goes out after the probe, queued behind it.
            let acknowledged = self.reduceGridAuthority(.claimFenceAcknowledged(fenceID: fenceID))
            if self.gridClaimGeometryEpoch == epoch {
                self.sendGridClaimSettleProbe(
                    connectionGeneration: connectionGeneration,
                    claimGeneration: claimGeneration,
                    fenceID: fenceID,
                    epoch: epoch,
                    target: target
                )
            }
            self.applyGridAuthorityLifecycleEffects(acknowledged)
        }
    }

    /// §6.10 rule 5: one size read, written once the claim's fence was
    /// acknowledged and therefore in a write of its own. tmux delivers the
    /// fence's `%layout-change` before this reply (verified on 3.4 and
    /// 3.6a), so the answer shows where the claim's geometry landed: from
    /// then on a size the claim never advertised is a loss, not a stale
    /// layout. Confirmation never waits for it. A newer advertisement or
    /// re-fence (`gridClaimGeometryEpoch`) or fence makes the answer moot.
    private func sendGridClaimSettleProbe(
        connectionGeneration: UInt64,
        claimGeneration: UInt64,
        fenceID: UInt64,
        epoch: UInt64,
        target: WindowId
    ) {
        guard participatesInGridAuthority,
              gridAuthorityLifecycle.claim?.generation == claimGeneration,
              gridAuthoritySession.claimFence?.policyIsLatest != false
        else { return }
        let counted = noteGridClaimCommandSent()
        sendControlCommand(TmuxWindowSizeReplay.sizeQuery(windowID: target)) { [weak self] result in
            guard let self else { return }
            self.noteGridClaimReplyReceived(counted)
            defer { self.endGridClaimIfStalledLate(context: "settle-probe") }
            guard self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.gridAuthorityLifecycle.claim?.generation == claimGeneration,
                  self.gridAuthoritySession.claimFence?.id == fenceID,
                  self.gridClaimGeometryEpoch == epoch,
                  (self.activeWindowId ?? self.renderedWindowId) == target
            else { return }
            guard case .success(let lines) = result,
                  let reported = TmuxWindowSizeReplay.reportedGeometry(
                      windowID: target,
                      reply: lines.joined(separator: "\n")
                  )
            else {
                Self.logDiagnostic(
                    "grid-authority settle probe unreadable gen=\(claimGeneration) window=\(target)"
                )
                return
            }
            Self.logDiagnostic(
                "grid-authority settle probe gen=\(claimGeneration) window=\(target) size=\(reported.columns)x\(reported.rows)"
            )
            // The session judges the probe first: a force proven below can
            // confirm the fence only on a window the probe found at target.
            self.observeGridClaimWindow(
                columns: reported.columns,
                rows: reported.rows,
                settleProbe: true,
                context: "settle-probe",
                checkForStall: false
            )
            // Side channel: a read after the unset's recalculation that finds
            // the window at a force's size confirms that force, even one
            // whose own read caught another size first.
            if self.windowSizeReplayAttempts[target]?.requested == reported {
                self.windowSizeReplayAttempts.removeValue(forKey: target)
                self.reportGridClaimFenceForce()
            }
        }
    }

    /// Re-issue the fence if the session's current window moved while our
    /// claim was in its geometry or repaint phase (the peer switched windows
    /// between our snapshot and the fence landing). Called from
    /// `%session-window-changed`.
    private func refenceGridClaimIfCurrentWindowMoved() {
        let repaintWasInFlight = gridAuthorityRepaintWindow != nil
            || !gridAuthorityRepaintPanes.isEmpty
            || gridAuthoritySideChannelRepaintPending
        guard mode == .tmuxControl,
              let claim = gridAuthorityLifecycle.claim,
              claim.targetGrid != nil,
              claim.phase == .awaitingFence || (claim.phase == .awaitingRepaint && repaintWasInFlight)
        else { return }
        guard gridAuthoritySession.claimMayAdvertiseGeometry else {
            if claim.phase == .awaitingFence, gridAuthoritySession.claimFence == nil {
                // Its fence waited for a window: tmux named one, nothing
                // moved (Android's `window-known`). It fences none now, and
                // ends once its own commands are answered (I3).
                endGridClaimIfStalledLate(context: "window-known")
                return
            }
            // §6.10 rules 2 and 6: a late claim fences no other window.
            // It cannot finish on the one it fenced, so it ends.
            stallGridClaim(context: "current-window-moved", canProgress: false, fenceAgain: false)
            return
        }
        // The new window has not seen this claim's geometry land.
        if let target = claim.targetGrid {
            reduceGridAuthority(.claimAdvertisedGeometry(
                generation: claim.generation,
                size: TmuxGridSize(columns: target.columns, rows: target.rows)
            ))
            gridClaimGeometryEpoch &+= 1
        }
        if repaintWasInFlight {
            // The capture/frame we were waiting for belongs to the previous
            // active window. It can no longer prove that the newly visible
            // surface is authoritative: the claim is back in its geometry
            // phase, and the veil stays closed until the new window has been
            // sized and repainted.
            clearGridAuthorityRepaintTargets()
        }
        Self.logDiagnostic(
            "grid-authority re-fence: current window moved during claim gen=\(claim.generation)"
        )
        queueGridClaimFenceSequence(
            connectionGeneration: controlConnectionGeneration,
            claimGeneration: claim.generation,
            reason: "current-window-moved",
            // A newly current window may have been unknown during the first
            // side-channel force. Replay there so resize/unset reaches it;
            // inline clients only need a fresh select-window fence.
            replaySize: controlPath == .sideChannel
        )
    }

    /// Confirms the live claim's fence, or re-arms the repaint of a
    /// confirmed one whose layout changed shape. The session decides
    /// whether the fence has settled (`ClaimFence`): the server processed
    /// the replay and the fence, the fence read the window's policy, and
    /// under `latest` the fenced window stands at the claim's target with no
    /// settle probe or window force saying otherwise. Under any other
    /// policy the window never follows a client, so the acknowledgement
    /// confirms. The claim stays in its geometry phase past the
    /// presentation deadline: its server-side effects cannot be recalled,
    /// so a late success must still lift the veil instead of stranding both
    /// devices behind one (§6.10 rule 1).
    private func confirmGridClaimIfSettled(context: String) {
        guard mode == .tmuxControl, let claim = gridAuthorityLifecycle.claim else { return }
        switch claim.phase {
        case .awaitingFence:
            guard claim.targetGrid != nil else { return }
            let effects = reduceGridAuthority(.confirmClaimFence)
            if gridAuthorityLifecycle.claim?.phase == .awaitingFence {
                Self.logDiagnostic(
                    "grid-authority claim unsettled context=\(context) fence=\(gridAuthoritySession.claimFence.traceLabel)"
                )
            }
            // `requestRepaint` runs the repaint.
            applyGridAuthorityLifecycleEffects(effects)
        case .awaitingRepaint:
            guard !gridClaimRepaintArmed, gridAuthoritySession.claimFenceSettled else { return }
            performGridAuthorityClaimRepaint(context: context)
        case .awaitingStampCommit, .awaitingSettlement:
            return
        }
    }

    /// The confirmed claim's repaint has targets or a frame on its way.
    private var gridClaimRepaintArmed: Bool {
        gridAuthorityRepaintWindow != nil
            || !gridAuthorityRepaintPanes.isEmpty
            || gridClaimSideChannelRepaintRequested
            || gridAuthoritySideChannelRepaintPending
    }

    /// The session's repaint effect uses the platform's existing reservation,
    /// inline target selection and P8 capture adoption. Re-arming a
    /// confirmed claim's repaint after its layout changed shape also enters
    /// here.
    private func performGridAuthorityClaimRepaint(context: String) {
        guard let generation = liveGridClaimGeneration, let size = gridClaimTargetSize else { return }
        Self.logDiagnostic(
            "grid-authority claim settled size=\(size.cols)x\(size.rows) context=\(context)"
        )

        switch controlPath {
        case .sideChannel:
            if !gridAuthorityRepaintPreservesHistory {
                onGridAuthoritySideChannelRepaintPreparing?()
            }
            // Mosh paints outside this control connection. Keep the veil up
            // until the view reports that the forced framebuffer output was
            // consumed by SwiftTerm; merely enqueueing the driver operation
            // recreates the stale-frame flash this feature is meant to avoid.
            //
            // The reservation is held by the render ledger, not here: the
            // ledger is what rebinds surfaces and advances owner epochs, so it
            // is what must decide whether a frame reserved against the old
            // owner is re-issued or failed. Before this, each platform
            // re-derived that rule privately and iOS got it wrong — a reclaim's
            // own geometry force rebound the surface and retired the frame the
            // claim was waiting on, aborting every mosh take-back.
            gridClaimSideChannelRepaintRequested = true
            submitRenderFact(.correlatedTransportFullFrameRequested(
                .live,
                reason: "authority-reclaim",
                correlation: generation
            ))

        case .inline:
            guard let windowId = activeWindowId ?? renderedWindowId,
                  let window = window(windowId)
            else {
                // Metadata is briefly unavailable during reattach. Re-arm the
                // geometry phase; the next layout/fence observation retries
                // without revealing an unpainted terminal.
                deferGridClaimConfirmation(context: "active-window-unavailable")
                return
            }
            if window.rendersAsPaneGrid {
                gridAuthorityRepaintPanes = gridAuthorityVisiblePaneTargets(
                    in: window
                )
                guard !gridAuthorityRepaintPanes.isEmpty else {
                    deferGridClaimConfirmation(context: "pane-grid-unavailable")
                    return
                }
            } else {
                gridAuthorityRepaintWindow = windowId
            }
            guard !appIsInactive else {
                // A read can resolve into a claim while the app is inactive.
                // Its repaint is the app's own foreground refresh; forcing it
                // here would mark the app foreground behind the user's back.
                Self.logDiagnostic(
                    "grid-authority inline repaint awaits app foreground"
                )
                return
            }
            if adoptGridClaimRepaintBehindFence() {
                Self.logDiagnostic(
                    "grid-authority claim repaint already behind the fence gen=\(generation)"
                )
                return
            }
            // A claim confirming again after losing its geometry has its
            // re-fence (and possibly the lost repaint) still on the wire.
            // Its repaint queues behind them rather than waiting for the
            // FIFO to drain: a stale foreign layout then costs one round
            // trip, the repaint the lost one could not stand in for. So does
            // one confirming while its settle probe is out (a resized
            // window's layout arrives right after the fence's reply), which
            // keeps the probe off the take-back's critical path (§6.10
            // rule 5).
            let refenced = gridAuthorityLifecycle.claim?.geometryRefenced == true
            if refenced || gridClaimHasOwnCommandsInFlight,
               let fence = gridAuthoritySession.claimFence,
               submitCorrelatedGridClaimRepaint(
                   claimGeneration: generation,
                   fenceID: fence.id,
                   target: windowId,
                   window: window,
                   relied: true,
                   context: refenced ? "after geometry loss" : "behind the settle probe"
               ) {
                return
            }
            refreshActiveWindowOnForeground()
        }
    }

    /// Force one transport-painted frame for a reservation the ledger issued.
    ///
    /// Called once per issue *and* once per re-issue: the ledger re-emits the
    /// request under the same correlation whenever it rebinds the surface to
    /// the same window and pane, which is what a reclaim's own geometry force
    /// provokes. The platform therefore never has to notice a rebind or decide
    /// whether the claim survives it — it just paints for the owner named here.
    private func requestCorrelatedTransportFullFrame(
        owner: RenderOwner?,
        correlation: UInt64,
        reason: String
    ) {
        guard let requestRepaint = onGridAuthoritySideChannelRepaintRequired else {
            // Production wires this before transport start. Fail closed: a
            // stale frame is never evidence that this device reclaimed safely.
            Self.logDiagnostic(
                "grid-authority transport frame request unserviceable correlation=\(correlation)"
            )
            failGridAuthoritySideChannelRepaint(generation: correlation)
            return
        }
        Self.logDiagnostic(
            "grid-authority transport frame requested correlation=\(correlation) "
                + "reason=\(reason) owner=\(owner.map(String.init(describing:)) ?? "unbound")"
        )
        gridAuthoritySideChannelRepaintPending = true
        gridAuthoritySideChannelRepaintGeneration &+= 1
        gridAuthorityTransportFrameCorrelation = correlation
        gridAuthorityTransportFrameOwner = owner
        requestRepaint(
            gridAuthorityClaimChangedGeometry,
            gridAuthoritySideChannelRepaintGeneration
        )
    }

    /// Consume the authoritative repaint. The claim enqueues the stamp only
    /// now and remains veiled until tmux acknowledges that write.
    private func finishGridAuthorityClaimPresentation(context: String) {
        // The stamp follows this repaint in the same turn, so this is the
        // last point at which a window off the claim's target can stop it:
        // core tells our own geometry and a stale layout from a loss.
        if let rect = (activeWindowId ?? renderedWindowId).flatMap(window)?.layout?.root.rect,
           gridClaimWindowIsOffTarget(rect) {
            observeGridClaimWindow(
                columns: rect.width,
                rows: rect.height,
                settleProbe: false,
                context: "repaint-\(context)"
            )
            return
        }
        clearGridAuthorityRepaintTargets()
        guard let generation = liveGridClaimGeneration else { return }
        applyGridAuthorityLifecycleEffects(
            reduceGridAuthority(.repaintSucceeded(generation: generation))
        )
        Self.logDiagnostic(
            "grid-authority repaint consumed context=\(context)"
        )
    }

    private func completeGridAuthoritySharedRepaintIfNeeded(
        windowId: WindowId
    ) {
        guard gridAuthorityRepaintWindow == windowId else { return }
        gridAuthorityRepaintWindow = nil
        finishGridAuthorityClaimPresentation(context: "inline-window-repaint")
    }

    private func completeGridAuthorityPaneRepaintIfNeeded(paneId: PaneId) {
        guard gridAuthorityRepaintPanes.remove(paneId) != nil,
              gridAuthorityRepaintPanes.isEmpty
        else { return }
        finishGridAuthorityClaimPresentation(context: "inline-pane-repaint")
    }

    private func scheduleGridAuthorityDeliveryRetry(
        rejectedWindows: Set<WindowId>,
        rejectedPanes: Set<PaneId>
    ) {
        let retryWindow = gridAuthorityRepaintWindow.flatMap { target in
            rejectedWindows.contains(target) ? target : nil
        }
        let retryPanes = gridAuthorityRepaintPanes.intersection(rejectedPanes)
        guard retryWindow != nil || !retryPanes.isEmpty else { return }
        if let retryWindow {
            gridAuthorityDeliveryRetryWindow = retryWindow
        }
        gridAuthorityDeliveryRetryPanes.formUnion(retryPanes)
        guard gridAuthorityDeliveryRetryTask == nil else { return }
        gridAuthorityDeliveryRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(max(0, self.renderRefreshRetryDelay)))
            guard !Task.isCancelled else { return }
            self.gridAuthorityDeliveryRetryTask = nil
            let retryWindow = self.gridAuthorityDeliveryRetryWindow.flatMap { target in
                self.gridAuthorityRepaintWindow == target ? target : nil
            }
            let retryPanes = self.gridAuthorityRepaintPanes.intersection(
                self.gridAuthorityDeliveryRetryPanes
            )
            self.gridAuthorityDeliveryRetryWindow = nil
            self.gridAuthorityDeliveryRetryPanes.removeAll(keepingCapacity: true)
            guard retryWindow != nil || !retryPanes.isEmpty else { return }
            guard self.gridAuthorityDeliveryRetryAttempts < self.maxRenderRefreshAttempts else {
                Self.logDiagnostic(
                    "grid-authority delivery retry exhausted windows=\(retryWindow == nil ? 0 : 1) panes=\(retryPanes.count)"
                )
                // §6.10 rule 6: never wait on a repaint nothing retries.
                self.stallGridClaim(context: "delivery-exhausted", canProgress: true, fenceAgain: true)
                return
            }
            self.gridAuthorityDeliveryRetryAttempts += 1
            let attempt = self.gridAuthorityDeliveryRetryAttempts
            Self.logDiagnostic(
                "grid-authority delivery retry attempt=\(attempt) windows=\(retryWindow == nil ? 0 : 1) panes=\(retryPanes.count)"
            )
            if let retryWindow,
               self.gridAuthorityRepaintWindow == retryWindow {
                self.submitRenderFact(.refreshRequested(
                    .live,
                    stage: .viewport,
                    reason: "grid-authority-delivery-retry"
                ))
            }
            for paneID in retryPanes.sorted(by: { $0.rawValue < $1.rawValue })
            where self.gridAuthorityRepaintPanes.contains(paneID) {
                self.submitRenderFact(.refreshRequested(
                    Self.inlinePaneSurfaceID(paneID),
                    stage: .viewport,
                    reason: "grid-authority-delivery-retry"
                ))
            }
        }
    }

    private func clearGridAuthorityRepaintTargets() {
        gridAuthorityRepaintWindow = nil
        gridAuthorityRepaintPanes.removeAll(keepingCapacity: true)
        gridClaimSideChannelRepaintRequested = false
        // Whoever re-arms targets after this re-decides how to repaint.
        gridAuthorityClaimRepaintInFlight = nil
        gridAuthoritySideChannelRepaintPending = false
        gridAuthorityDeliveryRetryTask?.cancel()
        gridAuthorityDeliveryRetryTask = nil
        gridAuthorityDeliveryRetryAttempts = 0
        gridAuthorityDeliveryRetryWindow = nil
        gridAuthorityDeliveryRetryPanes.removeAll(keepingCapacity: true)
    }

    /// Complete the side-channel half of a claim after Mosh's forced full
    /// frame has been fed into the visible terminal. Late callbacks from a
    /// reset/contested/replaced claim are harmless no-ops.
    public func completeGridAuthoritySideChannelRepaint(
        generation: UInt64
    ) {
        reportGridAuthorityTransportFrame(issueToken: generation, failure: nil)
    }

    /// Hand the platform's acknowledgement to the ledger, which holds the
    /// reservation and is therefore the only thing that can say whether this
    /// frame still authorises anything. The controller checks only that the
    /// ack belongs to the issue currently outstanding; the owner match, the
    /// correlation match and the single-terminal-outcome guarantee are the
    /// ledger's.
    private func reportGridAuthorityTransportFrame(
        issueToken: UInt64,
        failure: String?
    ) {
        guard gridAuthoritySideChannelRepaintPending,
              issueToken == gridAuthoritySideChannelRepaintGeneration,
              let correlation = gridAuthorityTransportFrameCorrelation
        else { return }
        let owner = gridAuthorityTransportFrameOwner
        gridAuthoritySideChannelRepaintPending = false
        let failure = failure ?? (sideChannelClaimGeometryIsCurrent ? nil : "remote-geometry-changed")
        if let failure {
            submitRenderFact(.transportFullFramePresentationFailed(
                .live,
                owner: owner,
                correlation: correlation,
                reason: failure
            ))
        } else {
            submitRenderFact(.transportFullFramePresented(
                .live,
                owner: owner,
                correlation: correlation
            ))
        }
    }

    /// The window is at the claim's target, and the force for that target
    /// is confirmed. A force still in flight for another grid is our own
    /// later churn, not a reason to doubt the target.
    private var sideChannelClaimGeometryIsCurrent: Bool {
        guard controlPath == .sideChannel, gridAuthorityGeometryPolicyIsLatest else { return true }
        guard let windowID = activeWindowId ?? renderedWindowId,
              let size = gridClaimTargetSize,
              let rect = window(windowID)?.layout?.root.rect
        else { return false }
        let targetForceInFlight = windowSizeReplayAttempts[windowID].map {
            $0.requested.columns == size.cols && $0.requested.rows == size.rows
        } ?? false
        return rect.width == size.cols && rect.height == size.rows && !targetForceInFlight
    }

    /// Abort only the claim whose side-channel repaint was retired before it
    /// produced an admissible full frame. A stale failure from a replaced
    /// request must not disturb the current claim.
    public func failGridAuthoritySideChannelRepaint(
        generation: UInt64
    ) {
        reportGridAuthorityTransportFrame(
            issueToken: generation,
            failure: "platform-repaint-failed"
        )
    }

    /// A split/collapse can land after claim geometry settled but before the
    /// corresponding capture reached its render sink. A capture targeted at
    /// the old surface shape cannot authorize the new one; re-enter the
    /// geometry phase and arm a repaint for the fully updated layout.
    private func reconcileGridAuthorityRepaintForLayout(
        windowId: WindowId
    ) {
        guard controlPath == .inline,
              windowId == (activeWindowId ?? renderedWindowId),
              gridAuthorityRepaintWindow != nil
                || !gridAuthorityRepaintPanes.isEmpty,
              let window = window(windowId)
        else { return }

        let expectedPanes = window.rendersAsPaneGrid
            ? gridAuthorityVisiblePaneTargets(in: window)
            : []
        let targetStillMatches = window.rendersAsPaneGrid
            ? gridAuthorityRepaintWindow == nil
                && gridAuthorityRepaintPanes == expectedPanes
            : gridAuthorityRepaintWindow == windowId
                && gridAuthorityRepaintPanes.isEmpty
        guard !targetStillMatches else { return }

        Self.logDiagnostic(
            "grid-authority repaint retargeted after layout shape change window=\(windowId) panes=\(expectedPanes.map(\.description))"
        )
        clearGridAuthorityRepaintTargets()
        // Like the layout's own confirmation: the ledger reduces this
        // layout after `handleLayoutChange` returns.
        confirmGridClaimAtStepEnd(context: "repaint-layout-changed")
    }

    /// Whether a lifecycle claim waiting on its repaint sees the window off
    /// its target, under a `latest` policy this claim read.
    private func gridClaimWindowIsOffTarget(_ rect: CellRect) -> Bool {
        guard mode == .tmuxControl,
              gridAuthoritySession.claimFence?.policyIsLatest == true,
              let claim = gridAuthorityLifecycle.claim,
              claim.phase == .awaitingRepaint,
              let target = claim.targetGrid
        else { return false }
        return rect.width != target.columns || rect.height != target.rows
    }

    /// §6.10 rules 3–4: report the claimed window's size to core, which
    /// tells our own geometry and a stale layout from a loss. Only under a
    /// `latest` policy this claim read: under any other the size proves
    /// nothing. A claim sent back to its geometry phase (unsettled, or lost
    /// and fencing again) stops counting the repaint in flight, which shows
    /// a grid other than its target.
    private func observeGridClaimWindow(
        columns: Int,
        rows: Int,
        settleProbe: Bool,
        context: String,
        checkForStall: Bool = true
    ) {
        guard mode == .tmuxControl,
              gridAuthoritySession.claimFence?.policyIsLatest == true,
              let claim = gridAuthorityLifecycle.claim,
              claim.phase == .awaitingFence || claim.phase == .awaitingRepaint
        else { return }
        let effects = reduceGridAuthority(.claimObservedGeometry(
            generation: claim.generation,
            size: TmuxGridSize(columns: columns, rows: rows),
            settleProbe: settleProbe
        ))
        let after = gridAuthorityLifecycle.claim
        let lost = effects.contains { effect in
            switch effect {
            case .refenceClaim, .claimAborted: return true
            default: return false
            }
        }
        if lost || (claim.phase == .awaitingRepaint && after?.phase == .awaitingFence) {
            let target = claim.targetGrid.map { "\($0.columns)x\($0.rows)" } ?? "-"
            Self.logDiagnostic(
                "grid-authority claim geometry \(lost ? "lost" : "unsettled") gen=\(claim.generation) layout=\(columns)x\(rows) target=\(target) context=\(context)"
            )
        }
        if let after, after.generation == claim.generation,
           claim.phase == .awaitingRepaint, after.phase == .awaitingFence {
            clearGridAuthorityRepaintTargets()
        }
        if !effects.isEmpty { applyGridAuthorityLifecycleEffects(effects) }
        // Own replies that observe and confirm judge stalling in their
        // outer defer, after confirmation had a chance to arm the repaint.
        // Notifications with no confirmation still judge it here.
        if checkForStall { endGridClaimIfStalledLate(context: context) }
    }

    /// Core's one re-fence for a claim whose landed geometry another client
    /// took (§6.10 rule 4): only the fence goes out again, inline a bare
    /// `select-window`, on the side channel the shared resize/fence/unset
    /// sequence at the target. It answers under the same `ClaimFence`: the
    /// window's policy is already read for it and its acknowledgement
    /// stands, so confirmation needs only the window back at the target;
    /// this fence's own settle probe lands it again. A repaint that
    /// confirmation sends queues behind this fence, so it captures the
    /// window after tmux made us `latest` again.
    private func refenceGridClaimAfterGeometryLoss(generation: UInt64) {
        guard mode == .tmuxControl,
              let claim = gridAuthorityLifecycle.claim,
              claim.generation == generation,
              let fence = gridAuthoritySession.claimFence,
              let target = activeWindowId ?? renderedWindowId,
              target.rawValue == fence.windowID
        else { return }
        Self.logDiagnostic(
            "grid-authority re-fence after geometry loss gen=\(generation) window=\(target)"
        )
        gridClaimGeometryEpoch &+= 1
        if controlPath == .sideChannel, let grid = claim.targetGrid {
            // The cached layout may still show the target (a settle probe
            // found the loss before its notification), so it cannot veto
            // the force.
            windowSizeReplayAttempts.removeValue(forKey: target)
            forceWindowSizesToClientSize(
                (grid.columns, grid.rows),
                belongsToGridClaimFence: true,
                onlyWindowID: target,
                evenIfLayoutMatches: true
            )
        }
        sendGridClaimFence(
            connectionGeneration: controlConnectionGeneration,
            claimGeneration: generation,
            fenceID: fence.id,
            target: target
        )
    }

    private func gridAuthorityVisiblePaneTargets(
        in window: WindowInfo
    ) -> Set<PaneId> {
        if gridAuthorityUsesCompactSinglePaneGrid {
            return window.activePaneId.map { Set([$0]) } ?? []
        }
        let renderLayout = window.isZoomed
            ? (window.visibleLayout ?? window.layout)
            : window.layout
        return Set(renderLayout?.paneIds ?? [])
    }

    /// The grid the live claim confirms at (§6.10 rule 3), which a late
    /// claim's local churn no longer moves.
    private var gridClaimTargetSize: (cols: Int, rows: Int)? {
        gridAuthorityLifecycle.claim?.targetGrid.map { ($0.columns, $0.rows) }
    }

    /// Tells the session whether a side-channel force at the claim's target
    /// on its fenced window still awaits proof (`ClaimFence`). Under
    /// `latest` the window can show the target before the force's unset has
    /// recalculated it, so that layout alone confirms nothing.
    private func reportGridClaimFenceForce() {
        guard let fence = gridAuthoritySession.claimFence,
              let target = gridAuthorityLifecycle.claim?.targetGrid
        else { return }
        let outstanding = windowSizeReplayAttempts[WindowId(fence.windowID)].map {
            $0.requested.columns == target.columns && $0.requested.rows == target.rows
        } ?? false
        guard outstanding != fence.forceOutstanding else { return }
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.claimFenceForce(
            fenceID: fence.id, outstanding: outstanding
        )))
    }

    /// Counts one of the live claim's own commands onto the wire; its reply
    /// hands the returned generation to `noteGridClaimReplyReceived`. Nil
    /// outside a claim.
    private func noteGridClaimCommandSent() -> UInt64? {
        guard let generation = liveGridClaimGeneration else { return nil }
        if gridClaimCommandsGeneration != generation {
            gridClaimCommandsGeneration = generation
            gridClaimCommandsInFlight = 0
        }
        gridClaimCommandsInFlight += 1
        return generation
    }

    private var gridClaimHasOwnCommandsInFlight: Bool {
        gridClaimCommandsGeneration == liveGridClaimGeneration && gridClaimCommandsInFlight > 0
    }

    private func noteGridClaimReplyReceived(_ generation: UInt64?) {
        guard let generation,
              gridClaimCommandsGeneration == generation,
              gridClaimCommandsInFlight > 0
        else { return }
        gridClaimCommandsInFlight -= 1
    }

    /// Work that can still consume the claim's repaint targets. Armed
    /// targets alone are no proof: the ledger may retain an exhausted
    /// ownership cut solely to keep live output off the stale surface.
    private var gridClaimRepaintInFlight: Bool {
        (gridAuthorityRepaintWindow != nil && renderLedger.isRefreshInFlight(for: .live))
            || gridAuthorityRepaintPanes.contains {
                renderLedger.isRefreshInFlight(for: Self.inlinePaneSurfaceID($0))
            }
            || gridAuthorityDeliveryRetryTask != nil
            || gridAuthoritySideChannelRepaintPending
            || gridClaimSideChannelRepaintRequested
    }

    /// §6.10 rule 6 for a late claim: with no command of its own awaiting a
    /// reply and no repaint in flight, nothing can confirm or repaint it any
    /// more, so it ends now rather than waiting under the veil. Checked at
    /// the deadline and after each of its own replies, which bounds a late
    /// claim to the round trips already on the wire.
    private func endGridClaimIfStalledLate(context: String) {
        guard let claim = gridAuthorityLifecycle.claim,
              !claim.presentationVisible,
              claim.phase == .awaitingFence || claim.phase == .awaitingRepaint,
              !gridClaimHasOwnCommandsInFlight,
              !gridClaimRepaintInFlight
        else { return }
        stallGridClaim(context: "late-\(context)", canProgress: false, fenceAgain: false)
    }

    /// §6.10 rule 6: the claim cannot progress as it stands. Core sends a
    /// visible claim that can still move (`canProgress`) back to its
    /// geometry phase, where it fences again (`fenceAgain`) or waits for
    /// its next observation; anything else ends as an adapter failure.
    private func stallGridClaim(context: String, canProgress: Bool, fenceAgain: Bool) {
        guard let claim = gridAuthorityLifecycle.claim else { return }
        let effects = reduceGridAuthority(.claimStalled(
            generation: claim.generation,
            canProgress: canProgress
        ))
        if let live = gridAuthorityLifecycle.claim, live.generation == claim.generation {
            guard live.phase == .awaitingFence else { return }
            Self.logDiagnostic(
                "grid-authority claim stalled gen=\(claim.generation) context=\(context): geometry phase again"
            )
            clearGridAuthorityRepaintTargets()
            if fenceAgain {
                queueGridClaimFenceSequence(
                    connectionGeneration: controlConnectionGeneration,
                    claimGeneration: claim.generation,
                    reason: "stalled-\(context)",
                    replaySize: false
                )
            }
        } else {
            Self.logDiagnostic(
                "grid-authority claim stalled gen=\(claim.generation) context=\(context): gave up"
            )
        }
        if !effects.isEmpty { applyGridAuthorityLifecycleEffects(effects) }
    }

    /// Confirmation found the window's metadata incomplete. A visible claim
    /// re-enters its geometry phase and confirms on the next layout or fence
    /// observation; a late one waits only while its own replies are still
    /// coming (§6.10 rule 6).
    private func deferGridClaimConfirmation(context: String) {
        Self.logDiagnostic("grid-authority repaint deferred: \(context)")
        if gridAuthoritySession.claimMayAdvertiseGeometry {
            stallGridClaim(context: context, canProgress: true, fenceAgain: false)
        } else {
            endGridClaimIfStalledLate(context: context)
        }
    }

    /// Resolves this device's own tmux client identities (control client,
    /// plus the visible mosh client on the side channel) for the passive
    /// window-size probe's exclusive-ownership proof.
    private func queryOwnGridAuthorityClientIdentities(
        sessionId: SessionId,
        connectionGeneration: UInt64,
        completion: @escaping (Set<String>?) -> Void
    ) {
        sendControlCommand(
            "display-message -p '#{client_name}|#{client_pid}|#{client_created}'"
        ) { [weak self] result in
            guard let self,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.ownSessionId == sessionId
            else { return }
            guard case .success(let lines) = result,
                  lines.count == 1,
                  let controlClientIdentity = lines.first, !controlClientIdentity.isEmpty
            else {
                completion(nil)
                return
            }

            if self.controlPath == .sideChannel {
                guard let identity = self.gridAuthorityIdentity else {
                    completion(nil)
                    return
                }
                let visibleOption = Self.gridAuthorityVisibleClientOption(
                    identityID: identity.id
                )
                self.sendControlCommand(
                    "show-options -qv -t \(sessionId.description) \(visibleOption)"
                ) { [weak self] visibleResult in
                    guard let self,
                          self.controlConnectionGeneration == connectionGeneration,
                          self.ownSessionId == sessionId
                    else { return }
                    guard case .success(let visibleLines) = visibleResult,
                          visibleLines.count == 1,
                          let visibleClientIdentity = visibleLines.first, !visibleClientIdentity.isEmpty
                    else {
                        completion(nil)
                        return
                    }
                    completion(Set([controlClientIdentity, visibleClientIdentity]))
                }
            } else {
                completion(Set([controlClientIdentity]))
            }
        }
    }

    /// Facts come from the ordered snapshot, only when they change. The
    /// shared session judges only its hydrated, authoritative active window.
    private func gridAuthorityWindowFacts(_ snapshot: TmuxSnapshot? = nil) -> TmuxAuthorityGeometryEvidence.WindowFacts {
        var facts = TmuxAuthorityGeometryEvidence.WindowFacts(of: snapshot ?? executingCommandReplySnapshot ?? runtimeEngine.snapshot)
        facts.hydrated = isWindowListHydrated && facts.hydrated
        return facts
    }

    private func noteGridAuthorityWindowFacts(_ snapshot: TmuxSnapshot? = nil) {
        guard participatesInGridAuthority else { return }
        let snapshot = snapshot ?? executingCommandReplySnapshot ?? runtimeEngine.snapshot
        let priorSnapshot = executingCommandReplySnapshot
        executingCommandReplySnapshot = snapshot
        defer { executingCommandReplySnapshot = priorSnapshot }
        let facts = gridAuthorityWindowFacts(snapshot)
        let previous = gridAuthoritySession.evidence.windowFacts
        guard previous != facts else { return }
        if previous.hydrated, previous.activeWindow?.id != facts.activeWindow?.id || previous.activeWindow?.size == nil {
            reservePresentedWindowRecovery(facts)
        }
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.windowFacts(
            hydrated: facts.hydrated,
            activeWindow: facts.activeWindow
        )))
    }

    private func noteGridAuthorityPaintable() {
        guard participatesInGridAuthority else { return }
        let mounted: Bool
        if controlPath == .sideChannel {
            mounted = !currentRenderDeclarations.isEmpty && onGridAuthoritySideChannelRepaintRequired != nil
        } else if let window = activeWindowId.flatMap(window), window.rendersAsPaneGrid {
            let targets = gridAuthorityVisiblePaneTargets(in: window)
            mounted = !targets.isEmpty && targets.allSatisfy { paneRenderSurfaces[$0] != nil || paneSinks[$0] != nil || renderFeedSurface != nil }
        } else {
            mounted = !currentRenderDeclarations.isEmpty && (feedTerminal != nil || feedTerminalWithContext != nil || renderFeedSurface != nil)
        }
        let paintable = mode == .tmuxControl && !appIsInactive && !gridAuthoritySession.inBackground && mounted
        guard paintable != gridAuthoritySession.paintable else { return }
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.paintable(paintable)))
    }

    /// Attach-init: a control channel attached (first connect, reconnect,
    /// session change or restore alike). Attaching never claims and never
    /// sizes the window before authority is known (R5, D3): it withholds
    /// geometry and reads the stamp. The reply releases the hold (own window
    /// at our size, or one ordinary owned replay), keeps it (yielded,
    /// unknown), or resolves a pending show/tap intent into a claim.
    private func replayAttachInitClientSize() {
        guard participatesInGridAuthority else {
            replayClientSize(reason: "attach-init")
            return
        }

        applyGridAuthorityLifecycleEffects(
            reduceGridAuthority(.attached)
        )
    }

    /// Set before attaching a mosh side channel; inline never resolves a group owner.
    @ObservationIgnored public var gridAuthorityOwnerSessionName: String?
    @ObservationIgnored private var gridAuthorityScope: TmuxGridAuthorityScope = .ownSession
    @ObservationIgnored private var gridAuthorityScopeGeneration: UInt64?
    @ObservationIgnored private var gridAuthorityScopeResolving = false
    @ObservationIgnored private var heldGridAuthorityQueryID: UInt64?
    @ObservationIgnored private var heldGridAuthorityPassiveRead: (() -> Void)?
    @ObservationIgnored private var gridAuthoritySubscriptionRequested = false
    @ObservationIgnored private var subscriptionFlushScheduled = false

    private func beginGridAuthorityScopeResolution() {
        guard controlPath == .sideChannel,
              gridAuthorityScopeGeneration != controlConnectionGeneration else { return }
        gridAuthorityScopeGeneration = controlConnectionGeneration
        gridAuthorityScope = .ownSession
        guard let name = gridAuthorityOwnerSessionName else {
            Self.logDiagnostic("authority scope=own reason=missing-owner-name")
            return
        }
        gridAuthorityScopeResolving = true
        let connection = controlConnectionGeneration
        var ownerReply: [String]?
        var ownReply: [String]?
        var replies = 0
        let commands = TmuxGridAuthority.ownerResolutionCommands(ownerSessionName: name)
        for (index, command) in commands.enumerated() {
            sendControlCommand(command) { [weak self] result in
                guard let self, self.controlConnectionGeneration == connection,
                      self.gridAuthorityScopeResolving else { return }
                if case .success(let lines) = result {
                    if index == 0 { ownerReply = lines } else { ownReply = lines }
                }
                replies += 1
                guard replies == 2 else { return }
                let owner = TmuxGridAuthority.resolveOwner(ownerReply: ownerReply, ownReply: ownReply)
                self.gridAuthorityScope = owner.map { .owner($0) } ?? .ownSession
                self.gridAuthorityScopeResolving = false
                Self.logDiagnostic("authority scope=\(owner == nil ? "own" : "owner") reason=\(owner == nil ? "unresolved-group" : "group-owner")")
                if self.gridAuthoritySubscriptionRequested {
                    self.sendGridAuthoritySubscription()
                }
                let held = self.heldGridAuthorityQueryID
                self.heldGridAuthorityQueryID = nil
                if let held, self.gridAuthoritySession.query.current?.id == held {
                    self.issueGridAuthorityQuery(id: held)
                }
                let passive = self.heldGridAuthorityPassiveRead
                self.heldGridAuthorityPassiveRead = nil
                passive?()
            }
        }
    }

    /// A grouped view outlives a killed owner: owner reads then find no
    /// owner and owner writes fail. Fall back to our own session (the
    /// behaviour before owner resolution) rather than reading a dead owner
    /// as unstamped; the caller's retry uses the new scope. Reconnecting
    /// resolves the owner afresh.
    private func abandonGridAuthorityOwnerScope(_ scope: TmuxGridAuthorityScope, connection: UInt64, reason: String) {
        guard case .owner = scope, gridAuthorityScope == scope,
              controlConnectionGeneration == connection else { return }
        gridAuthorityScope = .ownSession
        Self.logDiagnostic("authority scope=own reason=\(reason)")
        if gridAuthoritySubscriptionRequested {
            sendGridAuthoritySubscription()
        }
    }

    private func sendGridAuthoritySubscription() {
        gridAuthoritySubscriptionRequested = true
        guard !gridAuthorityScopeResolving else { return }
        runtimeEngine.subscriptionRequests.authority = gridAuthorityScope
        sendPendingSubscriptionCommands()
    }

    private func sendGridAuthorityPassiveRead(ifCurrent: @escaping () -> Bool, completion: @escaping (Result<[String], CommandError>) -> Void) {
        if gridAuthorityScopeResolving {
            heldGridAuthorityPassiveRead = { [weak self] in self?.sendGridAuthorityPassiveRead(ifCurrent: ifCurrent, completion: completion) }
            return
        }
        guard ifCurrent() else { return }
        let scope = gridAuthorityScope
        let connection = controlConnectionGeneration
        sendControlCommand(TmuxGridAuthority.queryCommand(scope)) { [weak self] result in
            guard case .success(let reply) = result else { completion(result); return }
            guard let lines = TmuxGridAuthority.queryReplyLines(reply, scope: scope) else {
                self?.abandonGridAuthorityOwnerScope(scope, connection: connection, reason: "owner-missing")
                completion(.failure(.tmuxError(lines: reply)))
                return
            }
            completion(.success(lines))
        }
    }

    /// Sends one explicit authority read. Reads coalesce only with one
    /// already in flight for the same pending intent (or the same absence of
    /// one) on this connection: a show edge records a new intent and so
    /// always gets its own read, ordered after everything tmux queued before
    /// the show.
    private func issueGridAuthorityQuery(id: UInt64) {
        guard participatesInGridAuthority, mode == .tmuxControl else { return }
        if gridAuthorityScopeResolving {
            heldGridAuthorityQueryID = id
            return
        }
        let connectionGeneration = controlConnectionGeneration
        let scope = gridAuthorityScope
        sendControlCommand(TmuxGridAuthority.queryCommand(scope)) { [weak self] result in
            guard let self, self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration else { return }
            switch result {
            case .success(let reply):
                guard let lines = TmuxGridAuthority.queryReplyLines(reply, scope: scope) else {
                    self.abandonGridAuthorityOwnerScope(scope, connection: connectionGeneration, reason: "owner-missing")
                    self.applyGridAuthorityLifecycleEffects(self.reduceGridAuthority(.queryFailed(id: id)))
                    return
                }
                let raw = lines.joined(separator: "\n")
                self.applyGridAuthorityLifecycleEffects(self.reduceGridAuthority(.queryReplied(id: id, raw: raw)))
            case .failure:
                self.applyGridAuthorityLifecycleEffects(self.reduceGridAuthority(.queryFailed(id: id)))
            }
        }
    }

    /// `resettingSession` false: the session already reset itself, as a
    /// known `controlSessionChanged` does.
    private func resetGridAuthorityState(preserveYieldedPresentation: Bool = false, resettingSession: Bool = true) {
        gridAuthorityScope = .ownSession
        gridAuthorityScopeGeneration = nil
        gridAuthorityScopeResolving = false
        heldGridAuthorityQueryID = nil
        heldGridAuthorityPassiveRead = nil
        gridAuthoritySubscriptionRequested = false
        // The old connection's release does not speak for the next one.
        gridAuthorityOwnerReplayDeferred = false
        if resettingSession {
            applyGridAuthorityLifecycleEffects(reduceGridAuthority(.resetTransport(preservingPeer: preserveYieldedPresentation)))
        }
        clearGridAuthorityClaimBookkeeping()
        noteGridAuthorityPaintable()
    }

    /// A preserving client starts as the size owner only when it created the
    /// tmux session. When another control client enters the same session and
    /// expands its grid beyond this device's viewport, make that transition
    /// permanent for this connection:
    ///
    /// 1. cache the larger grid on this control client with `-C`;
    /// 2. promote that acknowledged grid to the app/session owner;
    /// 3. set `ignore-size` on the phone's owning client, so the larger peer
    ///    owns sizing.
    ///
    /// Existing-session phone attaches already carry `-f ignore-size`; the
    /// peer-presence guard makes their initial hydration a no-op here. iPad
    /// controllers use `.resizeTmux` and never enter this path.
    private func considerReverseAttachCede(
        serverCols: Int,
        serverRows: Int,
        allowPeerQuery: Bool = true
    ) {
        guard mode == .tmuxControl,
              clientSizePolicy == .preserveServerGeometry,
              !hasCededGridOwnership,
              serverCols > 0,
              serverRows > 0
        else { return }
        guard !reverseAttachCedeMutationInFlight else { return }

        guard let baseline = reverseAttachBaselineSize ?? localViewportSize else {
            if allowPeerQuery, !reverseAttachPeers.isEmpty {
                requestReverseAttachPeerSizes()
            }
            return
        }
        if reverseAttachBaselineSize == nil {
            reverseAttachBaselineSize = baseline
        }

        let serverSize = (cols: serverCols, rows: serverRows)
        let isLargerThanViewportBaseline = Self.isGrid(
            serverSize,
            largerThan: baseline
        )
        let isLargerThanOwnerGrid: Bool
        if let ownerGrid = reverseAttachOwnerGridBaseline {
            isLargerThanOwnerGrid = Self.isGrid(
                serverSize,
                largerThan: ownerGrid
            )
        } else {
            isLargerThanOwnerGrid = true
        }
        Self.logDiagnostic(
            "client-size cede evaluate server=\(serverCols)x\(serverRows) baseline=\(baseline.cols)x\(baseline.rows) owner=\(reverseAttachOwnerGridBaseline?.cols ?? -1)x\(reverseAttachOwnerGridBaseline?.rows ?? -1) largerViewport=\(isLargerThanViewportBaseline) largerOwner=\(isLargerThanOwnerGrid) peers=\(reverseAttachPeers.count) path=\(controlPath)"
        )
        let attributedToPeer = reverseAttachPeers.contains { client in
            guard let size = reverseAttachPeerSizes[client] else { return false }
            return size.cols == serverCols && (size.rows == nil || size.rows == serverRows)
        }
        guard isLargerThanViewportBaseline,
              isLargerThanOwnerGrid
        else {
            if reverseAttachCedeLookupInFlight,
               !reverseAttachCedeMutationInFlight {
                pendingReverseAttachCedeSize = nil
            }
            if allowPeerQuery, !reverseAttachPeers.isEmpty {
                requestReverseAttachPeerSizes()
            }
            return
        }
        guard !reverseAttachPeers.isEmpty else {
            if allowPeerQuery {
                requestReverseAttachPeerDiscovery()
            }
            return
        }
        guard attributedToPeer else {
            if reverseAttachCedeLookupInFlight,
               !reverseAttachCedeMutationInFlight {
                pendingReverseAttachCedeSize = nil
            }
            if allowPeerQuery {
                requestReverseAttachPeerSizes()
            }
            return
        }

        // Keep the newest authoritative peer grid while a side-channel owner
        // lookup is pending. Once mutation starts its exact size is frozen so
        // the two acknowledged commands describe one coherent transaction.
        if reverseAttachCedeLookupInFlight,
           !reverseAttachCedeMutationInFlight {
            pendingReverseAttachCedeSize = (serverCols, serverRows)
            return
        }
        guard !reverseAttachCedeMutationInFlight else { return }

        switch controlPath {
        case .inline:
            requestReverseAttachCedeMutation(
                serverCols: serverCols,
                serverRows: serverRows,
                targetClient: nil
            )
        case .sideChannel:
            requestSideChannelReverseAttachCede(
                serverCols: serverCols,
                serverRows: serverRows
            )
        }
    }

    private func requestReverseAttachPeerSizes() {
        for client in reverseAttachPeers where !reverseAttachPeerQueries.contains(client) {
            reverseAttachPeerQueries.insert(client)
            let connectionGeneration = controlConnectionGeneration
            let target = Self.singleQuotedTmuxArgument(client)
            sendControlCommand(
                "display-message -p -c \(target) '#{client_width},#{client_height}'"
            ) { [weak self] result in
                guard let self,
                      self.mode == .tmuxControl,
                      self.controlConnectionGeneration == connectionGeneration
                else { return }
                self.reverseAttachPeerQueries.remove(client)
                Self.logDiagnostic(
                    "client-size peer-query client=\(client) result=\(Self.describe(result)) path=\(self.controlPath)"
                )
                guard self.reverseAttachPeers.contains(client),
                      case .success(let lines) = result,
                      let value = lines.first(where: { !$0.isEmpty }),
                      let size = Self.parseClientSize(value)
                else {
                    self.reverseAttachPeerSizes.removeValue(forKey: client)
                    self.requestReverseAttachPeerDiscovery()
                    return
                }
                self.reverseAttachPeerSizes[client] = size
                Self.logDiagnostic(
                    "client-size peer-query parsed client=\(client) size=\(size.cols)x\(size.rows.map(String.init) ?? "unavailable") path=\(self.controlPath)"
                )
                self.considerReverseAttachCedeFromKnownWindows(allowPeerQuery: false)
                if self.reverseAttachWindowNeedsPeerDiscovery() {
                    self.requestReverseAttachPeerDiscovery()
                }
            }
        }
    }

    private static func isGrid(
        _ candidate: (cols: Int, rows: Int),
        largerThan baseline: (cols: Int, rows: Int)
    ) -> Bool {
        let candidateArea = candidate.cols.multipliedReportingOverflow(by: candidate.rows)
        let baselineArea = baseline.cols.multipliedReportingOverflow(by: baseline.rows)
        if candidateArea.overflow || baselineArea.overflow {
            return candidate.cols > baseline.cols || candidate.rows > baseline.rows
        }
        return candidateArea.partialValue > baselineArea.partialValue
    }

    /// A targeted query only covers clients already announced to this control
    /// connection. If a larger known window still has no matching peer size,
    /// refresh the complete same-session client set to discover a peer whose
    /// announcement raced the layout broadcast.
    private func reverseAttachWindowNeedsPeerDiscovery() -> Bool {
        guard let baseline = reverseAttachBaselineSize ?? localViewportSize else {
            return false
        }
        return windows.compactMap(\.layout?.root.rect).contains { rect in
            let serverSize = (cols: rect.width, rows: rect.height)
            guard Self.isGrid(serverSize, largerThan: baseline) else { return false }
            if let ownerGrid = reverseAttachOwnerGridBaseline,
               !Self.isGrid(serverSize, largerThan: ownerGrid) {
                return false
            }
            return !reverseAttachPeers.contains { client in
                guard let size = reverseAttachPeerSizes[client] else { return false }
                return size.cols == serverSize.cols
                    && (size.rows == nil || size.rows == serverSize.rows)
            }
        }
    }

    /// Discover same-session clients when tmux publishes a larger layout
    /// without first emitting `%client-session-changed`. The current control
    /// client is resolved independently and excluded; ceding still requires a
    /// remaining client's reported width (and height, when available) to match
    /// the server grid.
    private func requestReverseAttachPeerDiscovery() {
        guard !reverseAttachPeerDiscoveryInFlight,
              let ownSessionId
        else { return }

        reverseAttachPeerDiscoveryInFlight = true
        let connectionGeneration = controlConnectionGeneration
        if let reverseAttachOwnClientName {
            queryReverseAttachPeers(
                ownClient: reverseAttachOwnClientName,
                sessionId: ownSessionId,
                connectionGeneration: connectionGeneration
            )
            return
        }

        sendControlCommand("display-message -p '#{client_name}'") { [weak self] result in
            guard let self,
                  self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration,
                  case .success(let lines) = result,
                  let ownClient = lines.first(where: { !$0.isEmpty })
            else {
                self?.reverseAttachPeerDiscoveryInFlight = false
                return
            }
            self.reverseAttachOwnClientName = ownClient
            Self.logDiagnostic(
                "client-size own-client name=\(ownClient) path=\(self.controlPath)"
            )
            self.queryReverseAttachPeers(
                ownClient: ownClient,
                sessionId: ownSessionId,
                connectionGeneration: connectionGeneration
            )
        }
    }

    private func queryReverseAttachPeers(
        ownClient: String,
        sessionId: SessionId,
        connectionGeneration: UInt64
    ) {
        sendControlCommand(
            "list-clients -t \(sessionId.description) -F '#{client_name}\t#{client_width},#{client_height}'"
        ) { [weak self] result in
            guard let self,
                  self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration
            else { return }
            self.reverseAttachPeerDiscoveryInFlight = false
            guard case .success(let lines) = result else { return }

            var peers: Set<String> = []
            var sizes: [String: (cols: Int, rows: Int?)] = [:]
            for line in lines {
                let fields = line.split(
                    separator: "\t",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard fields.count == 2 else { continue }
                let client = String(fields[0])
                guard client != ownClient,
                      let size = Self.parseClientSize(String(fields[1]))
                else { continue }
                peers.insert(client)
                sizes[client] = size
            }
            self.reverseAttachPeers = peers
            self.reverseAttachPeerSizes = sizes
            Self.logDiagnostic(
                "client-size peer-discovery session=\(sessionId) peers=\(peers.count) path=\(self.controlPath)"
            )
            self.considerReverseAttachCedeFromKnownWindows(allowPeerQuery: false)
        }
    }

    /// tmux 3.4 intentionally leaves `client_height` empty for control clients
    /// because their drawing TTY is not started, even after `refresh-client -C`
    /// sets both dimensions. `client_width` is still authoritative. Accept that
    /// documented control-mode shape while rejecting a malformed nonempty row.
    private static func parseClientSize(_ value: String) -> (cols: Int, rows: Int?)? {
        let fields = value.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let cols = Int(fields[0]), cols > 0 else { return nil }
        guard !fields[1].isEmpty else { return (cols, nil) }
        guard let rows = Int(fields[1]), rows > 0 else { return nil }
        return (cols, rows)
    }

    private func requestSideChannelReverseAttachCede(serverCols: Int, serverRows: Int) {
        // Always retain the newest authoritative layout. Using the largest
        // observed area could replay stale geometry if the iPad resized while
        // the owner lookup was in flight.
        pendingReverseAttachCedeSize = (serverCols, serverRows)

        guard !reverseAttachCedeLookupInFlight,
              let ownSessionId
        else { return }

        reverseAttachCedeLookupInFlight = true
        let connectionGeneration = controlConnectionGeneration
        sendControlCommand(
            "show-options -qv -t \(ownSessionId.description) \(Self.reverseAttachGeometryOwnerOption)"
        ) { [weak self] result in
            guard let self,
                  self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration
            else { return }
            self.reverseAttachCedeLookupInFlight = false
            guard case .success(let lines) = result,
                  let owner = lines.first(where: { !$0.isEmpty }),
                  let size = self.pendingReverseAttachCedeSize
            else {
                self.pendingReverseAttachCedeSize = nil
                Self.logDiagnostic("client-size cede skipped path=sideChannel reason=missing-owner")
                return
            }
            let stillAttributedToPeer = self.reverseAttachPeers.contains { client in
                guard let peerSize = self.reverseAttachPeerSizes[client] else {
                    return false
                }
                return peerSize.cols == size.cols
                    && (peerSize.rows == nil || peerSize.rows == size.rows)
            }
            let isStillCurrentWindowGeometry = self.windows
                .compactMap(\.layout?.root.rect)
                .contains { rect in
                    rect.width == size.cols && rect.height == size.rows
                }
            guard stillAttributedToPeer, isStillCurrentWindowGeometry else {
                self.pendingReverseAttachCedeSize = nil
                Self.logDiagnostic(
                    "client-size cede skipped path=sideChannel reason=stale-peer-grid"
                )
                self.considerReverseAttachCedeFromKnownWindows()
                return
            }
            self.pendingReverseAttachCedeSize = nil
            self.requestReverseAttachCedeMutation(
                serverCols: size.cols,
                serverRows: size.rows,
                targetClient: owner
            )
        }
    }

    private func requestReverseAttachCedeMutation(
        serverCols: Int,
        serverRows: Int,
        targetClient: String?
    ) {
        guard !hasCededGridOwnership,
              !reverseAttachCedeMutationInFlight
        else { return }

        // A side channel cannot safely exclude the separate visible mosh
        // client unless its owner can first promote the acknowledged grid to
        // the visible PTY and every replacement channel.
        guard controlPath != .sideChannel || onServerGeometryCeded != nil else {
            Self.logDiagnostic(
                "client-size cede skipped path=sideChannel reason=missing-promotion-handler"
            )
            return
        }

        reverseAttachCedeMutationInFlight = true
        let connectionGeneration = controlConnectionGeneration
        let target = targetClient.map(Self.singleQuotedTmuxArgument)
        let ignoreCommand = target.map { "refresh-client -t \($0) -f ignore-size" }
            ?? "refresh-client -f ignore-size"
        // `-C` is a control-client virtual-size operation. On the mosh path
        // `target` is the normal visible mosh client, so the authoritative
        // grid is cached on this already-ignored `-CC` side channel. Cache and
        // promote it before transmitting the owner mutation: if the later
        // ignore command fails or its acknowledgement is lost, the visible
        // owner remains authoritative at this same promoted size.
        let sizeCommand = "refresh-client -C \(serverCols),\(serverRows)"

        sendControlCommand(sizeCommand) { [weak self] firstResult in
            guard let self,
                  self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.reverseAttachCedeMutationInFlight
            else { return }
            guard case .success = firstResult else {
                self.failReverseAttachCedeMutation(stage: "cache-grid")
                return
            }

            // The size command itself was enqueued through the ledger-owned
            // platform FIFO. Record its acknowledged geometry without sending
            // a duplicate replay, so any younger capture observes the new
            // size epoch and resynchronises before it can paint.
            self.executeRenderEffects(self.renderLedger.noteAppliedClientSize(
                columns: serverCols,
                rows: serverRows
            ))
            let previous = self.lastKnownSize
            self.lastKnownSize = (serverCols, serverRows)
            self.hasCededGridOwnership = true
            self.compactClientSizeRole = .observer
            self.compactClientSizeRoleResolved = true
            self.compactClientOwnsSize = false
            self.onServerGeometryCeded?(serverCols, serverRows)

            self.sendControlCommand(ignoreCommand) { [weak self] secondResult in
                guard let self,
                      self.mode == .tmuxControl,
                      self.controlConnectionGeneration == connectionGeneration,
                      self.reverseAttachCedeMutationInFlight
                else { return }
                self.reverseAttachCedeMutationInFlight = false
                switch secondResult {
                case .success:
                    Self.logDiagnostic(
                        "client-size cede result=acknowledged local=\(self.localViewportSize?.cols ?? -1)x\(self.localViewportSize?.rows ?? -1) server=\(serverCols)x\(serverRows) peers=\(self.reverseAttachPeers.count) path=\(self.controlPath) previous=\(previous?.cols ?? -1)x\(previous?.rows ?? -1)"
                    )
                case .failure:
                    // The owner was not confirmed ignored, but this is still a
                    // coherent held state: cache acknowledgement preceded the
                    // synchronous session promotion, so the owner and control
                    // client both retain the authoritative grid.
                    Self.logDiagnostic(
                        "client-size cede result=owner-ignore-unacknowledged gridHeld=true local=\(self.localViewportSize?.cols ?? -1)x\(self.localViewportSize?.rows ?? -1) server=\(serverCols)x\(serverRows) path=\(self.controlPath)"
                    )
                }
            }
        }
    }

    private func failReverseAttachCedeMutation(stage: String) {
        reverseAttachCedeMutationInFlight = false
        Self.logDiagnostic(
            "client-size cede result=failed stage=\(stage) path=\(controlPath)"
        )
    }

    private func considerReverseAttachCedeFromKnownWindows(
        allowPeerQuery: Bool = true
    ) {
        let rects = windows.compactMap(\.layout?.root.rect)
        guard !rects.isEmpty else { return }
        for rect in rects {
            considerReverseAttachCede(
                serverCols: rect.width,
                serverRows: rect.height,
                allowPeerQuery: false
            )
            if hasCededGridOwnership || reverseAttachCedeMutationInFlight { return }
        }
        if allowPeerQuery {
            requestReverseAttachPeerSizes()
        }
    }

    /// Re-assert the client size AND repaint the active single-pane window from
    /// a fresh capture, as one atomic, latest-generation operation.
    ///
    /// Used when a multi-pane grid collapses to a single pane (or when the
    /// foreground switches from a grid window to a single-pane window). The grid
    /// is the size authority while mounted and pushes a header-RESERVED (shorter)
    /// row count; the shared terminal's frame never changes, so on collapse its
    /// `sizeChanged` won't fire to restore the full size. Naively pushing the
    /// size from the view layer races the `%window-pane-changed` repaint: the
    /// in-flight capture is taken at the reserved size while `lastKnownSize`
    /// (→ `clientRows`, which gates the scroll-region restore in
    /// `RepaintAssembly`) flips to the full size — a mismatch that mis-sets
    /// DECSTBM and scrolls the screen out of view (intermittent blank) or leaves
    /// the cursor a row off.
    ///
    /// Doing it here keeps the resize and the capture consistent (both at the
    /// full size) and advances the generation so any racing reserved-size
    /// refresh is dropped and THIS repaint wins.
    public func resyncRenderedWindowAfterGridCollapse(cols: Int, rows: Int) {
        guard mode == .tmuxControl, controlPath == .inline else { return }
        guard !gridAuthority.isPeer else {
            Self.logDiagnostic(
                "grid-collapse resync deferred while yielded cols=\(cols) rows=\(rows)"
            )
            return
        }
        updateClientSize(cols: cols, rows: rows)
        guard let activeWindowId,
              window(activeWindowId)?.rendersAsPaneGrid == false
        else { return }
        _ = advanceStateGeneration(reason: "grid-collapse-resync")
        submitRenderFact(.refreshRequested(
            .live,
            stage: .viewport,
            reason: "grid-collapse-resync"
        ))
    }

    /// Close the rendered-output gate as soon as the app leaves the active
    /// phase. The SSH channel can resume before SwiftUI reports `.active` on
    /// the way back from another app, so waiting until the foreground refresh
    /// starts leaves a window where queued TUI redraws can visibly race through
    /// SwiftTerm's existing deep buffer.
    public func prepareForAppInactivity() {
        appIsInactive = true
        if participatesInGridAuthority {
            noteGridAuthorityPaintable()
        }
        // Suspend response-liveness detection: ContinuousClock keeps running
        // while the process is frozen, so post-resume ages would spuriously
        // exceed the hard timeout. The fence (if armed) survives — correlation
        // stays unsynchronized across a suspension.
        commandResponseWatchdogTask?.cancel()
        commandResponseWatchdogTask = nil
        guard mode == .tmuxControl else { return }
        renderDropSummaryBoundary?("app-background")
        submitRenderFact(.appBackground)
        Self.logDiagnostic("render-ledger app-background path=\(controlPath)")
    }

    /// Force a fresh visible repaint of the active window. Call on foreground
    /// restore: when the app resumes, nothing else re-renders the visible
    /// window — the size replay only sends `refresh-client -C` — so any stale
    /// content left on the shared terminal (cross-window bleed from a pane that
    /// painted while we were rendering a different window, or a repaint that
    /// failed/aborted before backgrounding) persists until the user interacts.
    /// A fresh capture-repaint clears the viewport (`ED 2`) and repaints it from
    /// tmux's authoritative grid; if the control channel is still recovering and
    /// the metadata comes back empty, the viewport retry/backoff rides it out.
    /// When the same window/pane is already rendered, the repaint stays
    /// viewport-only: replaying up to 2,000 history rows makes SwiftTerm visibly
    /// race from old output to the bottom and briefly stalls the UI. A real
    /// window/pane mismatch still takes the normal viewport+deep path so its
    /// scrollback is rebuilt from tmux truth.
    public func refreshActiveWindowOnForeground() {
        let resumedFromBackground = appIsInactive
        appIsInactive = false
        if resumedFromBackground, participatesInGridAuthority {
            noteGridAuthorityPaintable()
        }
        // The replay a foreground read released while inactive goes now,
        // before the re-derive below holds geometry for its own read. Its
        // usual gates still apply: a peer or a hold since then drops it.
        if gridAuthorityOwnerReplayDeferred {
            gridAuthorityOwnerReplayDeferred = false
            replayClientSize(reason: "authority-owned-geometry-deferred")
        }
        // A transparent inactive period still re-derives without hiding a claim.
        if resumedFromBackground, participatesInGridAuthority {
            applyGridAuthorityLifecycleEffects(reduceGridAuthority(.foregrounded))
        }
        // Re-baseline response ages: time spent suspended must not count
        // toward poisoning. Genuine post-resume poisoning re-triggers 10s
        // after this instant.
        commandResponseWatchdogBaseline = ContinuousClock.now
        armCommandResponseWatchdog()
        guard mode == .tmuxControl else { return }
        renderDropSummaryBoundary?("app-foreground")
        _ = advanceStateGeneration(reason: "app-foreground")
        submitRenderFact(.appForeground)
        Self.logDiagnostic("render-ledger app-foreground path=\(controlPath)")
    }

    /// Update the rendered active pane's display title from an OSC title
    /// sequence captured by the terminal view. In tmux `-CC` mode,
    /// `%output` bytes routed to SwiftTerm include any OSC 0/1/2
    /// escape sequences the pane's running process emits. tmux
    /// itself treats these as `pane_title` (a per-pane attribute)
    /// and does NOT fire `%window-renamed`, so the only way for
    /// the tab strip to reflect OSC titles is to capture them from
    /// the terminal renderer side.
    ///
    /// No-ops in passthrough mode (no tab strip), when a guarded
    /// inline refresh is in flight, or when no rendered/active window
    /// has been identified yet.
    public func updateActiveWindowName(_ title: String) {
        guard mode == .tmuxControl,
              !renderLedger.hasPendingRender
        else { return }
        let targetWindowId = renderedWindowId ?? activeWindowId
        guard let targetWindowId,
              targetWindowId == activeWindowId,
              let idx = windows.firstIndex(where: { $0.id == targetWindowId })
        else { return }
        if let title = Self.nonEmpty(title) {
            let remainsDefaultTitle = windows[idx].activePaneTitleIsDefault
                && windows[idx].activePaneTitle == title
            windows[idx].activePaneTitle = title
            windows[idx].activePaneTitleIsDefault = remainsDefaultTitle
        } else {
            windows[idx].activePaneTitle = nil
            windows[idx].activePaneTitleIsDefault = false
        }
        if let paneID = windows[idx].activePaneId,
           let paneIndex = windows[idx].panes.firstIndex(where: { $0.id == paneID }) {
            windows[idx].panes[paneIndex].title = Self.nonEmpty(title)
            windows[idx].panes[paneIndex].titleIsDefault = false
        } else if let paneID = windows[idx].activePaneId {
            windows[idx].panes.append(PaneInfo(
                id: paneID,
                title: Self.nonEmpty(title),
                titleIsDefault: false,
                isActive: true
            ))
        }
        publishWindowMetadataToCore(targetWindowId)
        projectCoreSnapshot()
    }

    /// Reset all state. Use on session disconnect or reattach.
    ///
    /// Also cancels any in-flight command completions with
    /// `.failure(.cancelled)` so callbacks waiting for a reply don't
    /// leak their captured closures. Completions fire *after* the
    /// controller state is fully reset, so a handler that recursively
    /// calls `sendControlCommand` sees an already-passthrough mode
    /// and silently no-ops instead of re-queueing work on a half-
    /// -reset controller.
    public func reset() {
        renderDropSummaryBoundary?("transport-lost")
        // P11: a gate episode ends with its connection; the next one logs
        // its own first line.
        endClientSizeGate()
        let cancelled = drainPendingCommands()
        executeRenderEffects(renderLedger.reduce(.transportLost, snapshot: runtimeEngine.snapshot))
        executeRenderEffects(renderLedger.reduce(.surfacesDeclared([]), snapshot: runtimeEngine.snapshot))
        ledgerRenderedOwners.removeAll(keepingCapacity: true)
        for task in renderTimerTasks.values { task.cancel() }
        renderTimerTasks.removeAll(keepingCapacity: true)
        cancelCommandResponseWatchdog()
        controlConnectionGeneration &+= 1
        isWindowListHydrated = false
        advanceStateGeneration(reason: "reset")
        clearProtocolState(keepWindowModel: false)
        suppressPassthroughOutputUntilControlMode = false
        isInitialRenderReady = false
        mode = .passthrough
        activePaneId = nil
        renderedWindowId = nil
        renderedPaneId = nil
        windows.removeAll()
        windowLayoutQueriesInFlight.removeAll()
        bellingWindows.removeAll()
        windowBellFlags.removeAll()
        paneWindowTable.removeAll()
        paneCurrentPaths.removeAll()
        paneSinks.removeAll()
        paneRenderSurfaces.removeAll()
        pendingPaneFocus.removeAll()
        moshPaneBorderWindows.removeAll()
        activeWindowId = nil
        activeWindowQueryRebase = nil
        pendingHydratedActiveWindow = nil
        legacyTopologyReplayConnectionGeneration = nil
        executingCommandReplySnapshot = nil
        currentRenderDeclarations.removeAll(keepingCapacity: true)
        ownSessionId = nil
        ownSessionName = nil
        reverseAttachPeers.removeAll()
        reverseAttachBaselineSize = nil
        reverseAttachOwnerGridBaseline = nil
        reverseAttachPeerSizes.removeAll()
        reverseAttachPeerQueries.removeAll()
        reverseAttachOwnClientName = nil
        reverseAttachPeerDiscoveryInFlight = false
        reverseAttachCedeLookupInFlight = false
        reverseAttachCedeMutationInFlight = false
        pendingReverseAttachCedeSize = nil
        compactClientSizeRole = .unresolved
        compactClientSizeRoleResolutionInFlight = false
        compactClientSizeRoleResolutionAttempts = 0
        compactClientSizeRoleRetryTask?.cancel()
        compactClientSizeRoleRetryTask = nil
        compactClientSizeRoleResolved = false
        compactClientOwnsSize = false
        hasCededGridOwnership = false
        resetGridAuthorityState(
            preserveYieldedPresentation: controlPath == .sideChannel
        )
        for entry in cancelled {
            entry.completion(.failure(.cancelled))
        }
    }

    /// Side-channel-only disconnect handling for mosh transport.
    ///
    /// Unlike `reset()`, this preserves the current tmux window model
    /// so the outer UI can keep showing stale tabs while the main mosh
    /// terminal stays alive. Protocol parser state and in-flight
    /// commands are cleared because the control channel is gone and any
    /// partial frames or pending replies are no longer valid.
    public func sideChannelDisconnected() {
        guard controlPath == .sideChannel else {
            reset()
            return
        }

        renderDropSummaryBoundary?("side-channel-disconnected")
        endClientSizeGate()
        let cancelled = drainPendingCommands()
        executeRenderEffects(renderLedger.reduce(.transportLost, snapshot: runtimeEngine.snapshot))
        for task in renderTimerTasks.values { task.cancel() }
        renderTimerTasks.removeAll(keepingCapacity: true)
        cancelCommandResponseWatchdog()
        controlConnectionGeneration &+= 1
        isWindowListHydrated = false
        advanceStateGeneration(reason: "sidechannel-disconnected")
        clearProtocolState(keepWindowModel: true)
        suppressPassthroughOutputUntilControlMode = false
        isInitialRenderReady = false
        mode = .passthrough
        activePaneId = nil
        renderedWindowId = nil
        renderedPaneId = nil
        activeWindowQueryRebase = nil
        pendingHydratedActiveWindow = nil
        legacyTopologyReplayConnectionGeneration = nil
        executingCommandReplySnapshot = nil
        ownSessionId = nil
        ownSessionName = nil
        reverseAttachPeers.removeAll()
        reverseAttachBaselineSize = nil
        reverseAttachOwnerGridBaseline = nil
        reverseAttachPeerSizes.removeAll()
        reverseAttachPeerQueries.removeAll()
        reverseAttachOwnClientName = nil
        reverseAttachPeerDiscoveryInFlight = false
        reverseAttachCedeLookupInFlight = false
        reverseAttachCedeMutationInFlight = false
        pendingReverseAttachCedeSize = nil
        compactClientSizeRole = .unresolved
        compactClientSizeRoleResolutionInFlight = false
        compactClientSizeRoleResolutionAttempts = 0
        compactClientSizeRoleRetryTask?.cancel()
        compactClientSizeRoleRetryTask = nil
        compactClientSizeRoleResolved = false
        compactClientOwnsSize = false
        // Keep the acknowledged cede latch across a side-channel reconnect.
        // Its session-level promotion outlives this connection and seeds the
        // replacement channel at the held remote grid.
        // Preserve a yielded presentation across the control-only gap. The
        // primary mosh transport remains interactive, so changing `.peer` to
        // `.unknown` here would remove every input/overlay guard before the
        // replacement side channel has re-derived the session stamp.
        resetGridAuthorityState(preserveYieldedPresentation: true)
        windowBellFlags.removeAll()
        pendingPaneFocus.removeAll()
        for entry in cancelled {
            entry.completion(.failure(.cancelled))
        }
    }

    // MARK: - DCS entry detection

    private func handlePassthrough(_ chunk: [UInt8]) {
        let detection = controlModeDetector.feed(chunk)
        if !detection.passthroughBytes.isEmpty {
            feedPassthrough(ArraySlice(detection.passthroughBytes))
        }
        guard detection.enteredControlMode else { return }
        enterTmuxMode(
            controlBytes: detection.controlBytes,
            passthroughByteCount: detection.passthroughBytes.count
        )
    }

    private func handlePassthroughCooperatively(_ chunk: [UInt8]) async {
        let detection = controlModeDetector.feed(chunk)
        if !detection.passthroughBytes.isEmpty {
            await feedPassthroughCooperatively(ArraySlice(detection.passthroughBytes))
        }
        guard detection.enteredControlMode else { return }
        await enterTmuxModeCooperatively(
            controlBytes: detection.controlBytes,
            passthroughByteCount: detection.passthroughBytes.count
        )
    }

    private func feedPassthrough(_ bytes: ArraySlice<UInt8>) {
        guard !suppressPassthroughOutputUntilControlMode else { return }
        observeRawProgramStatus(bytes)
        deliverToSharedTerminal(
            bytes,
            context: TerminalFeedContext(source: .passthrough)
        )
    }

    private func feedPassthroughCooperatively(_ bytes: ArraySlice<UInt8>) async {
        guard !suppressPassthroughOutputUntilControlMode else { return }
        observeRawProgramStatus(bytes)
        var budget = CooperativeFeedBudget(previousWork: cooperativeFeedWork)
        await deliverToSharedTerminalCooperatively(
            bytes,
            context: TerminalFeedContext(
                source: .passthrough,
                originalByteCount: bytes.count
            ),
            budget: &budget
        )
        await budget.yieldIfNeeded()
        cooperativeFeedWork = budget.unyieldedWork
        ingestStages.yieldWaitMs += budget.yieldWaitMs
        ingestStages.yields += budget.yieldCount
        cooperativeYieldGeneration &+= UInt64(budget.yieldCount)
    }

    private func deliverToSharedTerminal(
        _ bytes: ArraySlice<UInt8>,
        context: TerminalFeedContext
    ) {
        if let feedTerminalWithContext {
            feedTerminalWithContext(bytes, context)
        } else {
            feedTerminal?(bytes)
        }
    }

    /// Note that we DON'T push any commands to tmux yet — the initial
    /// state-discovery queries (`refresh-client -C`, `list-windows`,
    /// `display-message`) are deferred until `flushAttachInitQueries()`
    /// runs after we've absorbed tmux's server-originated handshake
    /// `%begin/%end` frame. tmux marks server-originated frames with
    /// flags bit0 clear; only frames with bit0 set are responses to
    /// commands written by this control client and may pop the FIFO.
    private func enterTmuxMode(
        controlBytes: [UInt8],
        passthroughByteCount: Int
    ) {
        let events = activateTmuxMode(
            controlBytes: controlBytes,
            passthroughByteCount: passthroughByteCount
        )
        process(steps: events)
    }

    private func enterTmuxModeCooperatively(
        controlBytes: [UInt8],
        passthroughByteCount: Int
    ) async {
        let events = activateTmuxMode(
            controlBytes: controlBytes,
            passthroughByteCount: passthroughByteCount
        )
        await processCooperatively(steps: events)
    }

    private func activateTmuxMode(
        controlBytes: [UInt8],
        passthroughByteCount: Int
    ) -> [TmuxRuntimeBatch.OrderedStep] {
        mode = .tmuxControl
        suppressPassthroughOutputUntilControlMode = false
        isInitialRenderReady = controlPath == .sideChannel
        attachInitFlushed = false
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.channelLiveness(gridAuthorityChannelLive)))
        updateGridAuthorityPresentation()
        if currentRenderDeclarations.isEmpty {
            currentRenderDeclarations = [defaultRenderSurfaceDeclaration]
        }
        renderDropSummaryBoundary?("transport-attached")
        updateRenderLedgerConfiguration()
        executeRenderEffects(renderLedger.reduce(
            .surfacesDeclared(currentRenderDeclarations),
            snapshot: runtimeEngine.snapshot
        ))
        executeRenderEffects(renderLedger.reduce(
            .transportAttached(controlPath == .inline ? .inline : .sideChannel),
            snapshot: runtimeEngine.snapshot
        ))
        if appIsInactive {
            executeRenderEffects(renderLedger.reduce(
                .appBackground,
                snapshot: runtimeEngine.snapshot
            ))
        }
        noteGridAuthorityPaintable()
        Self.logDiagnostic(
            "entered-control-mode path=\(controlPath) dcsStart=\(passthroughByteCount) trailingBytes=\(controlBytes.count)"
        )
        // The raw terminal's foreground program is now tmux itself.
        programStatusMonitor.noteTerminalClosed(.raw)
        publishProgramStatus()
        guard !controlBytes.isEmpty else { return [] }
        let batch = runtimeEngine.feed(controlBytes)
        observeProgramStatus(batch)
        return batch.orderedSteps
    }

    private func drainPendingCommands() -> [PendingCommand] {
        let cancelled = pendingCommands
        pendingCommands.removeAll(keepingCapacity: true)
        renderLedger.resetCommandQueue()
        return cancelled
    }

    private func clearProtocolState(keepWindowModel: Bool) {
        lastPublishedClientSize = nil
        windowSizeReplayAttempts.removeAll()
        passiveWindowSizeProbe = nil
        presentedWindowRecoveryReserved = false
        windowOrderDeadlineTask?.cancel()
        windowOrderDeadlineTask = nil
        pendingWindowReorderToken = nil
        windowOrderOperationPending = false
        // The next connection asks again from its own hydrate.
        runtimeEngine.subscriptionRequests = .init()
        windowOrderError = nil
        attachInitFlushed = false
        runtimeEngine.reset(keepingSnapshot: keepWindowModel)
        applyGridAuthorityLifecycleEffects([])
        outputTitleScanners.removeAll(keepingCapacity: true)
        preloadedTerminalDefaultColorPanes.removeAll(keepingCapacity: true)
        controlModeDetector.reset()
        // Reports emitted while the channel was gone are lost; what was known
        // is history until fresh reports arrive.
        programStatusMonitor.noteTransportLost()
        publishProgramStatus()
    }

    @discardableResult
    private func advanceStateGeneration(reason: String) -> Int {
        stateGeneration &+= 1
        Self.logDiagnostic("state-generation advanced value=\(stateGeneration) reason=\(reason)")
        return stateGeneration
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        mode == .tmuxControl && stateGeneration == generation
    }

    /// path is the same.
    private func sendSeparatorProbeIfNeeded() {
        // The probe adds a command slot to the reply FIFO, so only the
        // production session wiring opts in: golden-FIFO tests and the
        // in-app debug harnesses reply positionally and must never see
        // an extra in-flight command.
        guard separatorProbeEnabled else { return }
        guard !sentSeparatorProbe else { return }
        sentSeparatorProbe = true
        sendControlCommand("display-message -p 'tessera-sep\t#{version}'") { [weak self] result in
            Self.logDiagnostic("separator-probe \(Self.classifySeparatorProbe(result))")
            self?.noteServerVersion(Self.parseServerVersion(result))
        }
    }

    /// Pure classification of the probe reply, split out for tests. Never
    /// echoes the raw line — the log line carries only derived facts.
    static func classifySeparatorProbe(
        _ result: Result<[String], CommandError>
    ) -> String {
        switch result {
        case .failure(.tmuxError(let lines)):
            // A usage error here is itself a mechanism signature: the host
            // split our quoted single argument on the embedded tab and
            // display-message rejected the extra argument.
            return "result=command-rejected lines=\(lines.count)"
        case .failure(.notInTmuxMode):
            return "result=failed reason=not-in-tmux"
        case .failure(.cancelled):
            return "result=failed reason=cancelled"
        case .failure(.timedOut):
            return "result=failed reason=timed-out"
        case .failure(.refusedByAuthority):
            return "result=failed reason=controlled-elsewhere"
        case .success(let lines):
            guard let line = lines.first(where: { !$0.isEmpty }) else {
                return "result=empty"
            }
            guard let range = line.range(of: "tessera-sep") else {
                return "result=unrecognized len=\(line.count)"
            }
            let rest = line[range.upperBound...]
            guard let separator = rest.first else {
                return "result=truncated"
            }
            let version = rest.dropFirst()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if separator == "\t" {
                return "result=intact version=\(version)"
            }
            let sepHex = String(
                format: "%02x",
                separator.unicodeScalars.first?.value ?? 0
            )
            return "result=mangled sepHex=\(sepHex) version=\(version)"
        }
    }

    /// App-level nudge for a stalled attach hydration (the launch overlay's
    /// hydration watchdog): re-run the authoritative refresh with a fresh
    /// generation and the ledger's retry budget. No-op once the initial
    /// render is ready or outside inline control mode.
    public func forceInitialRenderRecovery(reason: String) {
        guard controlPath == .inline, mode == .tmuxControl, !isInitialRenderReady else { return }
        Self.logDiagnostic(
            "initial-render force-recovery reason=\(reason) activeWindowPresent=\(activeWindowId != nil) generation=\(stateGeneration)"
        )
        guard activeWindowId != nil else { return }
        _ = advanceStateGeneration(reason: reason)
        submitRenderFact(.refreshRequested(.live, stage: .deep, reason: reason))
    }

    private func markInitialRenderReady() {
        isInitialRenderReady = true
    }

    private nonisolated static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 0 }
        let nanoseconds = interval * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else { return UInt64.max }
        return UInt64(nanoseconds)
    }

    private func indexOfWindow(_ windowId: WindowId) -> Int? {
        windows.firstIndex(where: { $0.id == windowId })
    }

    @discardableResult
    private func ensureWindow(_ windowId: WindowId) -> Int {
        if let idx = indexOfWindow(windowId) {
            return idx
        }
        windows.append(.init(id: windowId))
        let idx = windows.count - 1
        // The window just appeared — apply any pane focus a broadcast
        // %window-pane-changed stashed for it before it was tracked. Draining at
        // this single creation chokepoint covers EVERY session-scoped path that
        // first materializes a window (%window-renamed → upsertWindowName, the
        // pane-metadata subscription → upsertPaneInfo, %session-window-changed),
        // not just %window-add — so a rename arriving before the add can no
        // longer strand the stash until hydration clears it. Re-entrancy-safe:
        // drain removes the entry before applying it, and its updateActivePane →
        // ensureWindow call finds the now-existing window and returns early.
        drainPendingPaneFocus(windowId)
        return idx
    }

    private func upsertWindowName(_ name: String?, for windowId: WindowId) {
        let idx = ensureWindow(windowId)
        windows[idx].windowName = Self.nonEmpty(name)
    }

    /// Apply (and clear) a pending pane-focus stash for a window that has just
    /// legitimately appeared. Called from `ensureWindow` at the moment of
    /// creation, so it fires for every session-scoped path that materializes a
    /// window. Updates ONLY the per-window model (`windows[idx].activePaneId`);
    /// it deliberately does not touch `self.activePaneId` or trigger a repaint:
    ///   - For a background window (e.g. `%window-add` while another window is
    ///     active) that is correct — the window is not on screen.
    ///   - When `%session-window-changed` makes the window active, it sets
    ///     `activeWindowId` first, then calls `ensureWindow` (→ this), then reads
    ///     `windows[idx].activePaneId` into `self.activePaneId` and refreshes —
    ///     so the seeded value still reaches the controller's active pane.
    /// No-op when nothing is stashed for the window (the common case).
    private func drainPendingPaneFocus(_ windowId: WindowId) {
        guard let paneId = pendingPaneFocus.removeValue(forKey: windowId) else { return }
        Self.logDiagnostic(
            "window-pane-changed drained window=\(windowId) pane=\(paneId)"
        )
        updateActivePane(windowId: windowId, paneId: paneId, paneTitle: nil)
    }

    private func updateActivePane(
        windowId: WindowId,
        paneId: PaneId?,
        paneTitle: String?,
        activePaneTitleIsDefault: Bool = false,
        clearTitleWhenMissing: Bool = false,
        preloadTerminalReport: Bool = true
    ) {
        let idx = ensureWindow(windowId)
        let previousPaneId = windows[idx].activePaneId
        windows[idx].activePaneId = paneId
        if let paneTitle = Self.nonEmpty(paneTitle) {
            windows[idx].activePaneTitle = paneTitle
            windows[idx].activePaneTitleIsDefault = activePaneTitleIsDefault
        } else if clearTitleWhenMissing || previousPaneId != paneId {
            windows[idx].activePaneTitle = nil
            windows[idx].activePaneTitleIsDefault = false
        }
        if let paneId {
            paneWindowTable[paneId] = windowId
            if preloadTerminalReport {
                preloadTerminalDefaultColorReportIfNeeded(for: paneId)
            }
            if let paneIndex = windows[idx].panes.firstIndex(where: { $0.id == paneId }) {
                if let paneTitle = Self.nonEmpty(paneTitle) {
                    windows[idx].panes[paneIndex].title = paneTitle
                    windows[idx].panes[paneIndex].titleIsDefault = activePaneTitleIsDefault
                } else if clearTitleWhenMissing || previousPaneId != paneId {
                    windows[idx].panes[paneIndex].title = nil
                    windows[idx].panes[paneIndex].titleIsDefault = false
                }
            } else {
                windows[idx].panes.append(PaneInfo(
                    id: paneId,
                    title: Self.nonEmpty(paneTitle),
                    titleIsDefault: activePaneTitleIsDefault,
                    isActive: true
                ))
            }
        }
        reconcileActivePaneFlags(windowIdx: idx)
        publishWindowMetadataToCore(windowId)
    }

    private func updateWindowMetadata(
        windowId: WindowId,
        windowName: String?,
        activePaneId: PaneId?,
        activePaneTitle: String?,
        activePaneTitleIsDefault: Bool = false,
        clearTitleWhenMissing: Bool = false
    ) {
        let idx = ensureWindow(windowId)
        if let windowName = Self.nonEmpty(windowName) {
            windows[idx].windowName = windowName
        }
        let previousPaneId = windows[idx].activePaneId
        if let activePaneId {
            windows[idx].activePaneId = activePaneId
        }
        if let activePaneTitle = Self.nonEmpty(activePaneTitle) {
            windows[idx].activePaneTitle = activePaneTitle
            windows[idx].activePaneTitleIsDefault = activePaneTitleIsDefault
        } else if clearTitleWhenMissing || (activePaneId != nil && previousPaneId != activePaneId) {
            windows[idx].activePaneTitle = nil
            windows[idx].activePaneTitleIsDefault = false
        }
        if let activePaneId {
            paneWindowTable[activePaneId] = windowId
            preloadTerminalDefaultColorReportIfNeeded(for: activePaneId)
            if let paneIndex = windows[idx].panes.firstIndex(where: { $0.id == activePaneId }) {
                if let activePaneTitle = Self.nonEmpty(activePaneTitle) {
                    windows[idx].panes[paneIndex].title = activePaneTitle
                    windows[idx].panes[paneIndex].titleIsDefault = activePaneTitleIsDefault
                } else if clearTitleWhenMissing || previousPaneId != activePaneId {
                    windows[idx].panes[paneIndex].title = nil
                    windows[idx].panes[paneIndex].titleIsDefault = false
                }
            } else {
                windows[idx].panes.append(PaneInfo(
                    id: activePaneId,
                    title: Self.nonEmpty(activePaneTitle),
                    titleIsDefault: activePaneTitleIsDefault,
                    isActive: true
                ))
            }
        }
        reconcileActivePaneFlags(windowIdx: idx)
        publishWindowMetadataToCore(windowId)
    }

    private func window(_ windowId: WindowId) -> WindowInfo? {
        windows.first(where: { $0.id == windowId })
    }

    /// Rebuild `paneWindowTable` from the current window models. Cheap
    /// (windows × panes is tiny) and rebuilt wholesale so a pane removed from
    /// a layout drops its stale mapping. Layout pane ids are authoritative;
    /// the tracked `panes[]` and `activePaneId` cover the pre-layout window.
    ///
    /// This wholesale rebuild is the authoritative reconciliation point for a
    /// pane that moves between windows (move/break/join-pane). The incremental
    /// `paneWindowTable[pane] = window` writes in updateActivePane/
    /// updateWindowMetadata/the subscription only ever add or overwrite a
    /// single mapping; they never prune a pane that LEFT a window. tmux emits
    /// `%layout-change` for both source and destination of a move, and each
    /// fires this rebuild, so a stale mapping cannot outlive the move. A future
    /// change that stopped rebuilding here on a move would reintroduce a
    /// cross-window misroute — keep this call on the `%layout-change` path.
    private func rebuildPaneWindowTable() {
        var table: [PaneId: WindowId] = [:]
        for window in windows {
            if let layout = window.layout {
                for paneId in layout.paneIds { table[paneId] = window.id }
            }
            for pane in window.panes { table[pane.id] = window.id }
            if let active = window.activePaneId { table[active] = window.id }
        }
        paneWindowTable = table
        prunePaneCurrentPathsToKnownPanes()
    }

    private func prunePaneCurrentPathsToKnownPanes() {
        let knownPaneIds = Set(paneWindowTable.keys)
        paneCurrentPaths = paneCurrentPaths.filter { knownPaneIds.contains($0.key) }
    }

    private func updatePaneCurrentPath(_ currentPath: String?, for paneId: PaneId) {
        // Skip no-op writes: the per-pane metadata subscriptions fire for
        // every pane on every change (command, title, …), and @Observable
        // publishes on every set — an unconditional reassign would
        // re-render every observer of `paneCurrentPaths` per message.
        guard paneCurrentPaths[paneId] != currentPath else { return }
        var paths = paneCurrentPaths
        if let currentPath {
            paths[paneId] = currentPath
        } else {
            paths.removeValue(forKey: paneId)
        }
        paneCurrentPaths = paths
    }

    /// Merge a fresh set of layout pane ids into a window's `panes`, preserving
    /// known titles for panes that persist, dropping panes no longer present,
    /// and stamping `isActive`. Layout order (DFS) is preserved.
    private func mergePaneInfos(
        existing: [PaneInfo],
        layoutPaneIds: [PaneId],
        activePaneId: PaneId?
    ) -> [PaneInfo] {
        let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return layoutPaneIds.map { paneId in
            var info = byId[paneId] ?? PaneInfo(id: paneId)
            info.isActive = (paneId == activePaneId)
            return info
        }
    }

    /// Keep `panes[].isActive` consistent with the window's `activePaneId`.
    ///
    /// Notification ordering makes this load-bearing: on a non-last kill-pane,
    /// `%layout-change` (which rebuilds `panes` via `mergePaneInfos`, stamping
    /// isActive against the still-dead active pane) arrives BEFORE the
    /// `%window-pane-changed` that re-elects the survivor. Without this
    /// reconciliation the window would end with `activePaneId` set yet no pane
    /// flagged active — an inconsistency the M3 grid (which reads
    /// `panes.first(where: \.isActive)`) would trip over.
    private func reconcileActivePaneFlags(windowIdx: Int) {
        let activePaneId = windows[windowIdx].activePaneId
        for index in windows[windowIdx].panes.indices {
            windows[windowIdx].panes[index].isActive =
                (windows[windowIdx].panes[index].id == activePaneId)
        }
    }

    private func updatePaneInteractionState(
        paneId: PaneId,
        isAlternateScreen: Bool,
        isMouseReporting: Bool,
        isSgrMouse: Bool?
    ) {
        guard let windowId = paneWindowTable[paneId] ?? activeWindowId,
              let widx = windows.firstIndex(where: { $0.id == windowId })
        else { return }

        if let pidx = windows[widx].panes.firstIndex(where: { $0.id == paneId }) {
            windows[widx].panes[pidx].isAlternateScreen = isAlternateScreen
            windows[widx].panes[pidx].isMouseReporting = isMouseReporting
            windows[widx].panes[pidx].isSgrMouse = isSgrMouse
            publishWindowMetadataToCore(windowId)
        }
    }

    /// The subscription fans out on every pane title change (agent spinners
    /// redraw constantly), so only a real mode change republishes the window.
    /// Each mode applies on its own; a nil one leaves the known value alone.
    private func updatePaneInteractionStateIfChanged(
        paneId: PaneId,
        isAlternateScreen: Bool?,
        isMouseReporting: Bool?,
        isSgrMouse: Bool?
    ) {
        guard let windowId = paneWindowTable[paneId] ?? activeWindowId,
              let widx = windows.firstIndex(where: { $0.id == windowId }),
              let pidx = windows[widx].panes.firstIndex(where: { $0.id == paneId })
        else { return }
        var pane = windows[widx].panes[pidx]
        pane.isAlternateScreen = isAlternateScreen ?? pane.isAlternateScreen
        pane.isMouseReporting = isMouseReporting ?? pane.isMouseReporting
        pane.isSgrMouse = isSgrMouse ?? pane.isSgrMouse
        guard pane != windows[widx].panes[pidx] else { return }
        windows[widx].panes[pidx] = pane
        publishWindowMetadataToCore(windowId)
    }

    /// Insert or update a single pane's per-pane info on its window, without
    /// touching the window-level `activePaneTitle` (the tab label). Used by the
    /// unfiltered pane-metadata subscription so every pane's title/flag is
    /// tracked, not just the active one.
    private func upsertPaneInfo(
        windowId: WindowId,
        paneId: PaneId,
        title: String?,
        titleIsDefault: Bool,
        currentCommand: String?,
        isActive: Bool,
        contentRect: CellRect?
    ) {
        let widx = ensureWindow(windowId)
        let cleanTitle = Self.nonEmpty(title)
        let cleanCommand = Self.nonEmpty(currentCommand)
        if let pidx = windows[widx].panes.firstIndex(where: { $0.id == paneId }) {
            let priorCommand = windows[widx].panes[pidx].currentCommand
            windows[widx].panes[pidx].title = cleanTitle
            windows[widx].panes[pidx].titleIsDefault = titleIsDefault && cleanTitle != nil
            windows[widx].panes[pidx].isActive = isActive
            windows[widx].panes[pidx].currentCommand = cleanCommand
            if priorCommand != cleanCommand {
                windows[widx].panes[pidx].isAlternateScreen = nil
                windows[widx].panes[pidx].isMouseReporting = nil
                windows[widx].panes[pidx].isSgrMouse = nil
            }
            if let contentRect {
                windows[widx].panes[pidx].contentRect = contentRect
            }
        } else {
            windows[widx].panes.append(
                PaneInfo(
                    id: paneId,
                    title: cleanTitle,
                    titleIsDefault: titleIsDefault,
                    isActive: isActive,
                    currentCommand: currentCommand,
                    contentRect: contentRect
                )
            )
        }
        if isActive {
            for index in windows[widx].panes.indices
            where windows[widx].panes[index].id != paneId {
                windows[widx].panes[index].isActive = false
            }
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    private static func isDefaultPaneTitle(_ paneTitle: String?, host: String?) -> Bool {
        guard let paneTitle = nonEmpty(paneTitle),
              let host = nonEmpty(host)
        else { return false }
        return paneTitle == host
    }

    // MARK: - Control-mode message processing

    /// The end of one ordered step, in both ingest loops: confirm a grid
    /// claim that `handleLayoutChange` found settled mid-step, now that the
    /// ledger has reduced the same step. It runs after every step, a command
    /// correlation included: a `%window-add` details reply applies its layout
    /// through `handleLayoutChange` too, and a deferral it leaves must not
    /// wait for some later notification. Production inline SSH ingests
    /// through `processCooperatively`, so a drain in `process(steps:)` alone
    /// left a take-back that resized the window unconfirmed.
    private func finishDeferredGridClaimConfirmation() {
        guard let deferral = deferredGridClaimConfirmation,
              deferral.depth >= controlProcessingDepth
        else { return }
        defer { endGridClaimIfStalledLate(context: "step-confirmation") }
        deferredGridClaimConfirmation = nil
        confirmGridClaimIfSettled(context: deferral.context)
    }

    /// Confirms the claim now, or, inside an ingest step, at the end of that
    /// step once the ledger has reduced it (`finishDeferredGridClaimConfirmation`).
    /// A nested step that asks again keeps the outer step's depth: the
    /// confirmation waits for every step that asked for it.
    private func confirmGridClaimAtStepEnd(context: String) {
        guard controlProcessingDepth > 0 else {
            confirmGridClaimIfSettled(context: context)
            endGridClaimIfStalledLate(context: context)
            return
        }
        let depth = min(
            deferredGridClaimConfirmation?.depth ?? controlProcessingDepth,
            controlProcessingDepth
        )
        deferredGridClaimConfirmation = (context: context, depth: depth)
    }

    /// Every step drains its own deferral, so a loop starts with none at its
    /// depth; an outer step's may still be pending.
    private func assertNoGridClaimDeferralAtThisDepth() {
        assert(
            deferredGridClaimConfirmation.map { $0.depth < controlProcessingDepth } ?? true,
            "a grid claim confirmation deferral outlived its step"
        )
    }

    private func process(steps: [TmuxRuntimeBatch.OrderedStep]) {
        controlProcessingDepth += 1
        defer { controlProcessingDepth -= 1 }
        assertNoGridClaimDeferralAtThisDepth()
        if !steps.isEmpty { lastControlActivityAt = ContinuousClock.now }
        for step in steps {
            let event = step.event
            let orderedSnapshot = snapshotRebasedAfterActiveWindowQuery(step)
            switch event {
            case .message(let message):
                switch message {
                case .output(let paneID, let data),
                     .extendedOutput(let paneID, _, let data):
                    let provisionalSnapshot = observePaneOutput(
                        paneId: paneID,
                        data: data,
                        answerTerminalQueries: false,
                        orderedSnapshot: orderedSnapshot
                    )
                    let renderSnapshot = provisionalSnapshot ?? orderedSnapshot
                    updateRenderLedgerConfiguration()
                    let effects = renderLedger.reduce(
                        event,
                        snapshot: renderSnapshot
                    )
                    // Queue terminal replies after the reducer has taken its
                    // FIFO cut, but transmit them before touching the emulator.
                    // This keeps first-output fail-open from mistaking its own
                    // OSC response for older attach work.
                    if effects.contains(where: { effect in
                        guard case .bindSurface(_, let owner) = effect else { return false }
                        return owner.paneID == paneID
                    }) {
                        preloadTerminalDefaultColorReportIfNeeded(for: paneID)
                    }
                    sendTerminalResponseForOutputIfNeeded(paneId: paneID, data: data)
                    executeRenderEffects(effects, snapshot: renderSnapshot)
                default:
                    handle(message: message, snapshot: orderedSnapshot)
                    let topologySnapshot = snapshotAfterLegacyTopologyMutation(
                        step,
                        fallback: orderedSnapshot
                    )
                    noteGridAuthorityWindowFacts(topologySnapshot)
                    let reducerSnapshot = snapshotWithCurrentGridAuthority(topologySnapshot)
                    reconcileRenderSurfacesAfterTopology(
                        message,
                        snapshot: reducerSnapshot
                    )
                    updateRenderLedgerConfiguration()
                    executeRenderEffects(
                        renderLedger.reduce(event, snapshot: reducerSnapshot),
                        snapshot: reducerSnapshot
                    )
                }
            case .correlation(let event):
                handleCommandCorrelation(event, snapshot: orderedSnapshot)
            }
            finishDeferredGridClaimConfirmation()
        }
        if controlProcessingDepth == 1 {
            commitActiveWindowQueryRebaseIfNeeded()
            legacyTopologyReplayConnectionGeneration = nil
        }
        projectCoreSnapshot()
        if controlProcessingDepth == 1 { reconcilePresentedWindowSizeIfNeeded() }
        sendPendingSubscriptionCommands()
        finishConfirmedWindowOrderMutationIfNeeded()
        sendPendingWindowOrderRefreshIfNeeded()
    }

    /// Ordered topology is captured before the adapter reduces stamps and
    /// replies. Overlay only the current shared verdict, or a later step in
    /// the same read would restore the pre-reduction authority in the ledger.
    /// Equal authority returns the stored value without constructing anything.
    private func snapshotWithCurrentGridAuthority(_ base: TmuxSnapshot) -> TmuxSnapshot {
        let authority = participatesInGridAuthority ? gridAuthorityLifecycle.authority : .unknown
        guard base.authority != authority else { return base }
        return TmuxSnapshot(
            sessionID: base.sessionID, sessionName: base.sessionName,
            activeWindowID: base.activeWindowID,
            isActiveWindowAuthoritative: base.isActiveWindowAuthoritative,
            windows: base.windows, authority: authority,
            capabilities: base.capabilities, isReorderPending: base.isReorderPending,
            authoritativeWindowOrder: base.authoritativeWindowOrder,
            isWindowListHydrated: base.isWindowListHydrated, revision: base.revision
        )
    }

    private func snapshotRebasedAfterActiveWindowQuery(
        _ step: TmuxRuntimeBatch.OrderedStep
    ) -> TmuxSnapshot {
        snapshotWithCurrentGridAuthority(snapshotRebasedTopologyAfterActiveWindowQuery(step))
    }

    private func snapshotRebasedTopologyAfterActiveWindowQuery(
        _ step: TmuxRuntimeBatch.OrderedStep
    ) -> TmuxSnapshot {
        guard let rebase = activeWindowQueryRebase else { return step.snapshot }
        guard step.snapshot.sessionID == rebase.sessionID,
              !activeWindowQueryIsSuperseded(by: step.event, rebase: rebase)
        else {
            activeWindowQueryRebase = nil
            return step.snapshot
        }
        let dynamicSnapshot = runtimeEngine.snapshot
        let rebasedWindows: [TmuxWindowSnapshot]
        if step.snapshot.windows.contains(where: { $0.id == rebase.windowID }) {
            rebasedWindows = step.snapshot.windows
        } else if dynamicSnapshot.sessionID == rebase.sessionID,
                  dynamicSnapshot.windows.contains(where: { $0.id == rebase.windowID }) {
            // Earlier legacy list replies from this same read have now been
            // published into RuntimeEngine, while this precomputed ordered
            // step still predates those callbacks. Borrow topology only when
            // its session matches; session boundaries remain fail closed.
            rebasedWindows = dynamicSnapshot.windows
        } else {
            activeWindowQueryRebase = nil
            return step.snapshot
        }
        return TmuxSnapshot(
            sessionID: step.snapshot.sessionID,
            sessionName: step.snapshot.sessionName,
            activeWindowID: rebase.windowID,
            // The rebase is the correlated active-window reply for this
            // session, so tmux named this window.
            isActiveWindowAuthoritative: true,
            windows: rebasedWindows,
            authority: step.snapshot.authority,
            isWindowListHydrated: step.snapshot.isWindowListHydrated,
            revision: step.snapshot.revision
        )
    }

    private func activeWindowQueryIsSuperseded(
        by event: TmuxRuntimeBatch.OrderedEvent,
        rebase: (
            windowID: WindowId,
            sessionID: SessionId?,
            connectionGeneration: UInt64
        )
    ) -> Bool {
        switch event {
        case .message(.sessionWindowChanged(let sessionID, _)):
            return rebase.sessionID == nil || sessionID == rebase.sessionID
        case .message(.windowClose(let windowID)),
             .message(.unlinkedWindowClose(let windowID)):
            return windowID == rebase.windowID
        case .correlation(.frameCompleted(let frame)):
            return frame.status == .success
                && TmuxRuntimeHydrationQuery.activeWindowID(lines: frame.lines) != nil
        default:
            return false
        }
    }

    private func snapshotAfterLegacyTopologyMutation(
        _ step: TmuxRuntimeBatch.OrderedStep,
        fallback: TmuxSnapshot
    ) -> TmuxSnapshot {
        guard legacyTopologyReplayConnectionGeneration == controlConnectionGeneration,
              case .message(let message) = step.event,
              runtimeEngine.replayTopologyNotification(message)
        else { return fallback }
        let replayedStep = TmuxRuntimeBatch.OrderedStep(
            event: step.event,
            snapshot: runtimeEngine.snapshot,
            isActiveWindowAuthoritative: runtimeEngine.isActiveWindowAuthoritative
        )
        guard activeWindowQueryRebase != nil else { return replayedStep.snapshot }
        return snapshotRebasedAfterActiveWindowQuery(replayedStep)
    }

    /// Commit the staged legacy query only after every later event from the
    /// already-parsed read has had a chance to supersede it. This preserves a
    /// later authoritative window/session transition in RuntimeEngine while
    /// still correcting non-authoritative layout snapshots from the same read.
    private func commitActiveWindowQueryRebaseIfNeeded() {
        guard let rebase = activeWindowQueryRebase else {
            pendingHydratedActiveWindow = nil
            return
        }
        defer {
            activeWindowQueryRebase = nil
            pendingHydratedActiveWindow = nil
        }
        let finalSnapshot = runtimeEngine.snapshot
        guard controlConnectionGeneration == rebase.connectionGeneration,
              mode == .tmuxControl,
              finalSnapshot.sessionID == rebase.sessionID,
              finalSnapshot.windows.contains(where: { $0.id == rebase.windowID })
        else { return }
        _ = runtimeEngine.ingestActiveWindowQuery(rebase.windowID)
        let committedSnapshot = runtimeEngine.snapshot
        projectCoreSnapshot(committedSnapshot)
        if let pending = pendingHydratedActiveWindow,
           pending.windowID == rebase.windowID {
            finalizeHydratedActiveWindow(
                pending.windowID,
                generation: pending.generation,
                reason: pending.reason,
                snapshot: committedSnapshot
            )
        }
    }

    private static let cooperativeFeedChunkBytes = 1024

    /// Wall-time attribution for cooperative ingest, summarized through the
    /// diagnostics sink every few seconds while output flows. Exists to answer
    /// "where does ingest wall time go?" with data instead of theory: the
    /// app-side terminal-output-burst line reports whole-call ingressMs, and
    /// this splits the non-feed remainder into parse / observer / title-scan /
    /// query-scan / control / deliver / yield-wait stages so a single laggy
    /// repro names the culprit stage. Storage must stay @ObservationIgnored —
    /// it mutates on every chunk and would otherwise churn observation.
    struct IngestStageStats {
        static let clock = ContinuousClock()
        static let flushInterval: Duration = .seconds(5)

        var windowStart: ContinuousClock.Instant?
        var calls = 0
        var outputMessages = 0
        var controlMessages = 0
        var sliceFeeds = 0
        var parseMs: Double = 0
        var observerMs: Double = 0
        var titleScanMs: Double = 0
        var queryScanMs: Double = 0
        var controlMs: Double = 0
        var deliverMs: Double = 0
        var yieldWaitMs: Double = 0
        var yields = 0

        static func now() -> ContinuousClock.Instant { clock.now }

        static func elapsedMs(since start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: clock.now)
            return Double(duration.components.seconds) * 1_000
                + Double(duration.components.attoseconds) / 1e15
        }

        mutating func noteCall() {
            calls += 1
            if windowStart == nil { windowStart = Self.clock.now }
        }

        mutating func flushIfDue(log: (String) -> Void) {
            guard let windowStart else { return }
            let elapsed = windowStart.duration(to: Self.clock.now)
            guard elapsed >= Self.flushInterval else { return }
            let windowMs = Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15
            let f = { (value: Double) in String(format: "%.1f", value) }
            log(
                "ingest-stages windowMs=\(f(windowMs)) calls=\(calls) outputMsgs=\(outputMessages) controlMsgs=\(controlMessages) sliceFeeds=\(sliceFeeds) parseMs=\(f(parseMs)) observerMs=\(f(observerMs)) titleMs=\(f(titleScanMs)) queryMs=\(f(queryScanMs)) controlMs=\(f(controlMs)) deliverMs=\(f(deliverMs)) yieldWaitMs=\(f(yieldWaitMs)) yields=\(yields)"
            )
            self = IngestStageStats()
        }
    }

    @ObservationIgnored var ingestStages = IngestStageStats()
    @ObservationIgnored private var cooperativeFeedWork: Duration = .zero

    /// MainActor-isolated deliberately: this package builds in Swift 5 mode,
    /// where a nonisolated async method hops to the global executor on every
    /// call (SE-0338) and each return re-enqueues behind pending main-queue
    /// work. On the ingest hot path that charged milliseconds of pure
    /// scheduling per SSH chunk even when no yield fired — a TUI redraw storm
    /// (hundreds of tiny `%output` chunks per second) then drains far below
    /// its arrival rate and keystroke echo queues seconds behind. Isolation
    /// makes the no-yield fast path a plain same-actor call.
    @MainActor
    private struct CooperativeFeedBudget {
        private let clock = ContinuousClock()
        private let turnBudget: Duration = .milliseconds(4)
        private var turnStartedAt: ContinuousClock.Instant
        private var bytesSinceYield = 0
        private var previousWork: Duration

        init(previousWork: Duration) {
            turnStartedAt = clock.now
            self.previousWork = previousWork
        }

        // Carry work, not elapsed idle/network time, between ingress calls.
        // A run of cheap 1 KB packets shares the same 4 ms UI work budget.
        var unyieldedWork: Duration {
            previousWork + (bytesSinceYield > 0 ? turnStartedAt.duration(to: clock.now) : .zero)
        }

        mutating func noteRenderedWork(byteCount: Int) {
            bytesSinceYield += byteCount
        }

        private(set) var yieldWaitMs: Double = 0
        private(set) var yieldCount = 0

        mutating func yieldIfNeeded() async {
            guard bytesSinceYield > 0 else { return }
            guard unyieldedWork >= turnBudget else {
                return
            }
            let yieldStart = clock.now
            await Task.yield()
            yieldWaitMs += IngestStageStats.elapsedMs(since: yieldStart)
            yieldCount += 1
            turnStartedAt = clock.now
            bytesSinceYield = 0
            previousWork = .zero
        }
    }

    private func deliverToSharedTerminalCooperatively(
        _ bytes: ArraySlice<UInt8>,
        context: TerminalFeedContext,
        budget: inout CooperativeFeedBudget
    ) async {
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = bytes.index(
                offset,
                offsetBy: min(
                    Self.cooperativeFeedChunkBytes,
                    bytes.distance(from: offset, to: bytes.endIndex)
                )
            )
            let slice = bytes[offset..<end]
            let deliverStart = IngestStageStats.now()
            deliverToSharedTerminal(slice, context: context)
            ingestStages.deliverMs += IngestStageStats.elapsedMs(since: deliverStart)
            ingestStages.sliceFeeds += 1
            offset = end
            budget.noteRenderedWork(byteCount: slice.count)
            await budget.yieldIfNeeded()
        }
    }

    private func processCooperatively(steps: [TmuxRuntimeBatch.OrderedStep]) async {
        controlProcessingDepth += 1
        defer { controlProcessingDepth -= 1 }
        assertNoGridClaimDeferralAtThisDepth()
        if !steps.isEmpty { lastControlActivityAt = ContinuousClock.now }
        var budget = CooperativeFeedBudget(previousWork: cooperativeFeedWork)

        for step in steps {
            // Every step ends here, whichever branch it takes; see
            // `finishDeferredGridClaimConfirmation`. The confirmation is
            // control work, so it counts toward the control stage.
            defer {
                if deferredGridClaimConfirmation != nil {
                    let drainStart = IngestStageStats.now()
                    finishDeferredGridClaimConfirmation()
                    ingestStages.controlMs += IngestStageStats.elapsedMs(since: drainStart)
                }
            }
            let event = step.event
            let orderedSnapshot = snapshotRebasedAfterActiveWindowQuery(step)
            if case .correlation(let correlation) = event {
                ingestStages.controlMessages += 1
                let controlStart = IngestStageStats.now()
                handleCommandCorrelation(correlation, snapshot: orderedSnapshot)
                ingestStages.controlMs += IngestStageStats.elapsedMs(since: controlStart)
                continue
            }
            guard case .message(let message) = event else { continue }
            switch message {
            case .output(let paneId, let data):
                let provisionalSnapshot = observePaneOutput(
                    paneId: paneId,
                    data: data,
                    answerTerminalQueries: false,
                    orderedSnapshot: orderedSnapshot
                )
                let renderSnapshot = provisionalSnapshot ?? orderedSnapshot
                updateRenderLedgerConfiguration()
                let effects = renderLedger.reduce(
                    event,
                    snapshot: renderSnapshot
                )
                if effects.contains(where: { effect in
                    guard case .bindSurface(_, let owner) = effect else { return false }
                    return owner.paneID == paneId
                }) {
                    preloadTerminalDefaultColorReportIfNeeded(for: paneId)
                }
                sendTerminalResponseForOutputIfNeeded(paneId: paneId, data: data)
                await executeRenderEffectsCooperatively(
                    effects,
                    snapshot: renderSnapshot,
                    budget: &budget
                )

            case .extendedOutput(let paneId, let ageMs, let data):
                if ageMs > 2_000 {
                    Self.logDiagnostic(
                        "extended-output delayed pane=\(paneId) ageMs=\(ageMs) bytes=\(data.count)"
                    )
                }
                let provisionalSnapshot = observePaneOutput(
                    paneId: paneId,
                    data: data,
                    answerTerminalQueries: false,
                    orderedSnapshot: orderedSnapshot
                )
                let renderSnapshot = provisionalSnapshot ?? orderedSnapshot
                updateRenderLedgerConfiguration()
                let effects = renderLedger.reduce(
                    event,
                    snapshot: renderSnapshot
                )
                if effects.contains(where: { effect in
                    guard case .bindSurface(_, let owner) = effect else { return false }
                    return owner.paneID == paneId
                }) {
                    preloadTerminalDefaultColorReportIfNeeded(for: paneId)
                }
                sendTerminalResponseForOutputIfNeeded(paneId: paneId, data: data)
                await executeRenderEffectsCooperatively(
                    effects,
                    snapshot: renderSnapshot,
                    budget: &budget
                )

            default:
                ingestStages.controlMessages += 1
                let controlStart = IngestStageStats.now()
                handle(message: message, snapshot: orderedSnapshot)
                let topologySnapshot = snapshotAfterLegacyTopologyMutation(
                    step,
                    fallback: orderedSnapshot
                )
                noteGridAuthorityWindowFacts(topologySnapshot)
                let reducerSnapshot = snapshotWithCurrentGridAuthority(topologySnapshot)
                reconcileRenderSurfacesAfterTopology(
                    message,
                    snapshot: reducerSnapshot
                )
                updateRenderLedgerConfiguration()
                executeRenderEffects(
                    renderLedger.reduce(event, snapshot: reducerSnapshot),
                    snapshot: reducerSnapshot
                )
                ingestStages.controlMs += IngestStageStats.elapsedMs(since: controlStart)
            }
        }

        if controlProcessingDepth == 1 {
            commitActiveWindowQueryRebaseIfNeeded()
            legacyTopologyReplayConnectionGeneration = nil
        }
        projectCoreSnapshot()
        if controlProcessingDepth == 1 { reconcilePresentedWindowSizeIfNeeded() }
        sendPendingSubscriptionCommands()
        finishConfirmedWindowOrderMutationIfNeeded()
        sendPendingWindowOrderRefreshIfNeeded()

        await budget.yieldIfNeeded()
        cooperativeFeedWork = budget.unyieldedWork
        ingestStages.yieldWaitMs += budget.yieldWaitMs
        ingestStages.yields += budget.yieldCount
        cooperativeYieldGeneration &+= UInt64(budget.yieldCount)
    }

    /// Preserve the renderer's bounded-yield hot path while keeping all
    /// reducer effects in their declared order. Only live `%output` is sliced;
    /// authoritative capture feeds remain atomic in `executeRenderEffects`.
    private func executeRenderEffectsCooperatively(
        _ effects: [RenderEffect],
        snapshot: TmuxSnapshot,
        budget: inout CooperativeFeedBudget
    ) async {
        var effectIndex = effects.startIndex
        while effectIndex < effects.endIndex {
            guard case .feed(let surfaceID, let owner, let reference, let source) = effects[effectIndex],
                  source == .paneOutput else {
                // Preserve each maximal non-live-feed run as one executor
                // transaction. In particular, adjacent ledger commands must
                // reach `sendBytes` atomically even on cooperative ingestion;
                // one-effect dispatch would re-open the synchronous callback
                // window that can invert wire order against the shared FIFO.
                var end = effects.index(after: effectIndex)
                while end < effects.endIndex {
                    if case .feed(_, _, _, let candidateSource) = effects[end],
                       candidateSource == .paneOutput {
                        break
                    }
                    end = effects.index(after: end)
                }
                executeRenderEffects(
                    Array(effects[effectIndex..<end]),
                    snapshot: snapshot
                )
                effectIndex = end
                continue
            }
            effectIndex = effects.index(after: effectIndex)
            guard let bytes = renderLedger.takeRenderBytes(reference) else {
                Self.logDiagnostic(
                    "render-ledger missing-bytes-ref controller=\(diagnosticID) id=\(reference.rawValue)"
                )
                continue
            }
            let context = terminalFeedContext(
                owner: owner,
                source: .paneOutput,
                originalByteCount: bytes.count
            )
            var offset = bytes.startIndex
            while offset < bytes.endIndex {
                let end = TmuxLiveOutputFramer.chunkEnd(
                    in: bytes[...], from: offset,
                    maximumCount: Self.cooperativeFeedChunkBytes
                )
                let slice = bytes[offset..<end]
                let deliverStart = IngestStageStats.now()
                if let renderFeedSurface {
                    _ = renderFeedSurface(surfaceID, owner, slice, source)
                } else if surfaceID == .live {
                    deliverToSharedTerminal(slice, context: context)
                } else if let paneID = owner.paneID,
                          let surface = paneRenderSurfaces[paneID] {
                    surface.feed(owner, slice)
                } else if let paneID = owner.paneID,
                          let legacySink = paneSinks[paneID] {
                    legacySink(slice)
                }
                ingestStages.deliverMs += IngestStageStats.elapsedMs(since: deliverStart)
                ingestStages.sliceFeeds += 1
                budget.noteRenderedWork(byteCount: slice.count)
                await budget.yieldIfNeeded()
                offset = end
            }
            if surfaceID == .live {
                if owner.windowID == nil, let paneID = owner.paneID {
                    runtimeEngine.ingestProvisionalActivePane(paneID)
                }
                renderedWindowId = owner.windowID
                renderedPaneId = owner.paneID
                activePaneId = owner.paneID
                markInitialRenderReady()
            }
        }
    }

    /// Topology is authoritative before the SwiftUI view tree reacts to the
    /// published snapshot. Reconcile in this same ordered wire turn so a
    /// single shared surface cannot begin a capture for a window that has
    /// already become a pane grid.
    private func reconcileRenderSurfacesAfterTopology(
        _ message: TmuxMessage,
        snapshot: TmuxSnapshot
    ) {
        switch message {
        case .layoutChange, .sessionWindowChanged, .windowPaneChanged,
             .windowAdd, .unlinkedWindowAdd, .windowClose, .unlinkedWindowClose:
            redeclareInlineRenderSurfaces(snapshot: snapshot)
        default:
            break
        }
    }


    private func windowInfo(forPaneId paneId: PaneId) -> WindowInfo? {
        // Exact mapping from the rebuilt layout table — covers non-active
        // panes (fixes the dropped background-pane bell).
        if let windowId = paneWindowTable[paneId], let window = window(windowId) {
            return window
        }
        if let window = windows.first(where: { $0.activePaneId == paneId }) {
            return window
        }
        if paneId == activePaneId,
           let activeWindowId,
           let window = windows.first(where: { $0.id == activeWindowId }) {
            return window
        }
        return nil
    }

    private func updatePaneTitleFromOutput(paneId: PaneId, data: [UInt8]) {
        guard mode == .tmuxControl else { return }
        var scanner = outputTitleScanners[paneId] ?? TerminalOutputScanner()
        let events = scanner.feed(data)
        outputTitleScanners[paneId] = scanner
        for event in events.titleEvents {
            applyPaneTitleFromOutput(event.title, paneId: paneId)
        }
    }

    private func applyPaneTitleFromOutput(_ title: String, paneId: PaneId) {
        let activePaneWindowIdx = indexOfWindowForPaneTitleUpdate(paneId: paneId)
        if let idx = activePaneWindowIdx {
            if let title = Self.nonEmpty(title) {
                windows[idx].activePaneTitle = title
                windows[idx].activePaneTitleIsDefault = false
            } else {
                windows[idx].activePaneTitle = nil
                windows[idx].activePaneTitleIsDefault = false
            }
        }

        let paneWindowIdx: Int?
        if let windowId = paneWindowTable[paneId] {
            paneWindowIdx = windows.firstIndex(where: { $0.id == windowId })
        } else {
            paneWindowIdx = activePaneWindowIdx
        }

        guard let widx = paneWindowIdx else { return }
        if let pidx = windows[widx].panes.firstIndex(where: { $0.id == paneId }) {
            windows[widx].panes[pidx].title = Self.nonEmpty(title)
            windows[widx].panes[pidx].titleIsDefault = false
        } else {
            windows[widx].panes.append(PaneInfo(
                id: paneId,
                title: Self.nonEmpty(title),
                titleIsDefault: false,
                isActive: windows[widx].activePaneId == paneId
            ))
        }
        publishWindowMetadataToCore(windows[widx].id)
    }

    private func indexOfWindowForPaneTitleUpdate(paneId: PaneId) -> Int? {
        // DELIBERATELY active-pane-only (unlike windowInfo(forPaneId:), which
        // uses paneWindowTable for bell routing). This resolves the window
        // whose *tab label* (`activePaneTitle`) an OSC title from %output may
        // update. Routing a NON-active background pane here would let its OSC
        // title clobber the active pane's tab label — a multi-pane window's
        // background pane printing `ESC]2;…` would rewrite the visible label.
        // Per-pane titles are updated separately by pane id.
        if let idx = windows.firstIndex(where: { $0.activePaneId == paneId }) {
            return idx
        }
        if paneId == activePaneId,
           let activeWindowId,
           let idx = windows.firstIndex(where: { $0.id == activeWindowId }) {
            return idx
        }
        return nil
    }

    @discardableResult
    private func observePaneOutput(
        paneId: PaneId,
        data: [UInt8],
        answerTerminalQueries: Bool = true,
        orderedSnapshot: TmuxSnapshot? = nil
    ) -> TmuxSnapshot? {
        guard !renderLedger.isProgramStatusPaneOutput else { return nil }
        lastPaneOutputAt = ContinuousClock.now
        ingestStages.outputMessages += 1
        let observerStart = IngestStageStats.now()
        paneDidOutput?(paneId)
        paneOutputObserver?(paneId, data[...])
        ingestStages.observerMs += IngestStageStats.elapsedMs(since: observerStart)
        let titleStart = IngestStageStats.now()
        updatePaneTitleFromOutput(paneId: paneId, data: data)
        ingestStages.titleScanMs += IngestStageStats.elapsedMs(since: titleStart)
        let queryStart = IngestStageStats.now()
        if answerTerminalQueries {
            sendTerminalResponseForOutputIfNeeded(paneId: paneId, data: data)
        }
        ingestStages.queryScanMs += IngestStageStats.elapsedMs(since: queryStart)

        // A newly created single-pane window can emit `%output` before tmux
        // publishes `%window-pane-changed` or hydration names its pane.  This
        // is topology discovery, not a rendering decision: seed the portable
        // snapshot so the ledger can bind the first authenticated output to
        // the only known active window in this same ordered turn.
        let routingSnapshot = orderedSnapshot ?? runtimeEngine.snapshot
        if controlPath == .inline,
           let activeWindowID = routingSnapshot.activeWindowID,
           routingSnapshot.windows.count == 1,
           routingSnapshot.windows
                .first(where: { $0.id == activeWindowID })?
                .activePaneID == nil {
            updateActivePane(
                windowId: activeWindowID,
                paneId: paneId,
                paneTitle: nil,
                preloadTerminalReport: answerTerminalQueries
            )
            projectCoreSnapshot()
            return Self.snapshot(
                routingSnapshot,
                seedingActivePane: paneId,
                in: activeWindowID
            )
        }
        return nil
    }

    /// Controller-level first-output discovery happens after the portable
    /// runtime has produced this wire step. Enrich only that exact step rather
    /// than falling back to the batch-final runtime snapshot, which may already
    /// include later window switches from the same read.
    private static func snapshot(
        _ snapshot: TmuxSnapshot,
        seedingActivePane paneID: PaneId,
        in windowID: WindowId
    ) -> TmuxSnapshot {
        let windows = snapshot.windows.map { window -> TmuxWindowSnapshot in
            guard window.id == windowID else { return window }
            var panes = window.panes.map { pane in
                TmuxPaneSnapshot(
                    id: pane.id,
                    title: pane.title,
                    titleIsDefault: pane.titleIsDefault,
                    currentCommand: pane.currentCommand,
                    currentPath: pane.currentPath,
                    isActive: pane.id == paneID,
                    isAlternateScreen: pane.isAlternateScreen,
                    isMouseReporting: pane.isMouseReporting,
                    isSgrMouse: pane.isSgrMouse,
                    contentRect: pane.contentRect
                )
            }
            if !panes.contains(where: { $0.id == paneID }) {
                panes.append(TmuxPaneSnapshot(id: paneID, isActive: true))
            }
            return TmuxWindowSnapshot(
                id: window.id,
                index: window.index,
                name: window.name,
                activePaneID: paneID,
                activePaneTitle: window.activePaneTitle,
                activePaneTitleIsDefault: window.activePaneTitleIsDefault,
                panes: panes,
                layout: window.layout,
                visibleLayout: window.visibleLayout,
                isZoomed: window.isZoomed
            )
        }
        return TmuxSnapshot(
            sessionID: snapshot.sessionID,
            sessionName: snapshot.sessionName,
            activeWindowID: snapshot.activeWindowID,
            isActiveWindowAuthoritative: snapshot.isActiveWindowAuthoritative,
            windows: windows,
            authority: snapshot.authority,
            isWindowListHydrated: snapshot.isWindowListHydrated,
            revision: snapshot.revision &+ 1
        )
    }


    private func handleCommandCorrelation(
        _ event: TmuxCorrelationEvent,
        snapshot: TmuxSnapshot
    ) {
        let priorSnapshot = executingCommandReplySnapshot
        executingCommandReplySnapshot = snapshot
        defer { executingCommandReplySnapshot = priorSnapshot }
        noteGridAuthorityWindowFacts(snapshot)
        switch event {
        case .frameStarted(let current, let discarded, let discardedLineCount):
            if let discarded {
                Self.logDiagnostic(
                    "command-frame-overlap controller=\(diagnosticID) previousTime=\(discarded.time) previousNumber=\(discarded.commandNumber) previousFlags=\(discarded.flags) nextTime=\(current.time) nextNumber=\(current.commandNumber) nextFlags=\(current.flags) discardedLines=\(discardedLineCount)"
                )
            }
            Self.logDiagnostic(
                "command-frame-begin controller=\(diagnosticID) time=\(current.time) number=\(current.commandNumber) flags=\(current.flags) wirePending=\(pendingCommands.count) headSequence=\(pendingCommands.first?.sequence ?? -1) headCategory=\(pendingCommands.first.map { Self.commandCategory($0.command) } ?? "none")"
            )

        case .frameCompleted(let frame):
            let status = frame.status == .success ? "end" : "error"
            let begin = frame.begin
            let end = frame.end
            if let fence = pendingCommandFence {
                // Recovery mode: correlation is unsynchronized, so no frame
                // may pop the FIFO until the fence nonce proves the wire has
                // drained past every pre-recovery command. Classification is
                // deliberately ignored here — a misclassifying server (client
                // responses tagged flags=0) still resynchronizes on the body.
                if frame.status == .success,
                   frame.lines.contains(fence.nonce) {
                    pendingCommandFence = nil
                    Self.logDiagnostic(
                        "command-queue-fence-matched controller=\(diagnosticID) nonce=\(fence.nonce) waitedMs=\(Int(IngestStageStats.elapsedMs(since: fence.armedAt)))"
                    )
                    completeCommandQueueRecovery()
                } else {
                    Self.logDiagnostic(
                        "command-queue-fence-discard controller=\(diagnosticID) status=\(status) effectiveFlags=\(frame.effectiveFlags) lines=\(frame.lines.count)"
                    )
                }
                return
            }
            if let begin, !frame.guardMatches {
                let recovery = begin.flags >= 0 ? "classify-from-begin"
                    : frame.effectiveFlags >= 0 ? "classify-from-matching-end" : "unclassified"
                Self.logDiagnostic(
                    "command-frame-guard-mismatch controller=\(diagnosticID) status=\(status) beginTime=\(begin.time) beginNumber=\(begin.commandNumber) beginFlags=\(begin.flags) endTime=\(end.time) endNumber=\(end.commandNumber) endFlags=\(end.flags) bodyLines=\(frame.lines.count) recovery=\(recovery) effectiveFlags=\(frame.effectiveFlags)"
                )
            } else if begin == nil {
                Self.logDiagnostic(
                    "command-frame-missing-begin controller=\(diagnosticID) status=\(status) endTime=\(end.time) endNumber=\(end.commandNumber) endFlags=\(end.flags) bodyLines=\(frame.lines.count) recovery=classify-from-end effectiveFlags=\(frame.effectiveFlags)"
                )
            }

            guard frame.isClientResponse else {
                if frame.status == .success, !attachInitFlushed {
                    attachInitFlushed = true
                    Self.logDiagnostic("handshake-frame-drained path=\(controlPath)")
                    flushAttachInitQueries()
                } else {
                    Self.logDiagnostic(
                        "server-originated-frame-drained status=\(status) beginTime=\(begin?.time ?? -1) beginNumber=\(begin?.commandNumber ?? -1) beginFlags=\(begin?.flags ?? -1) endTime=\(end.time) endNumber=\(end.commandNumber) endFlags=\(end.flags) guardMatches=\(frame.guardMatches) lines=\(frame.lines.count)"
                    )
                }
                return
            }

            let metadataSurfaceID = renderLedger.nextAuthoritativeMetadataSurfaceID
            executingRenderReplyRows = frame.lines.count
            executingRenderReplyReason = renderLedger.pendingReason(for: .live)
            defer {
                executingRenderReplyRows = nil
                executingRenderReplyReason = nil
            }
            let effects = renderLedger.reduce(
                .correlation(event),
                snapshot: snapshotWithCurrentGridAuthority(snapshot)
            )
            if frame.status == .success, let metadataSurfaceID {
                observeRenderedPaneMetadataReply(
                    frame.lines,
                    surfaceID: metadataSurfaceID
                )
            }
            var executableEffects: [RenderEffect] = []
            for effect in effects {
                if case .commandReply(let tag, let success, let lines, _) = effect {
                    if !executableEffects.isEmpty {
                        executeRenderEffects(
                            executableEffects,
                            snapshot: snapshot
                        )
                        executableEffects.removeAll(keepingCapacity: true)
                    }
                    if let index = pendingCommands.firstIndex(where: { $0.tag == tag }) {
                    let entry = pendingCommands.remove(at: index)
                    Self.logDiagnostic(
                        "command-response controller=\(diagnosticID) status=\(status) beginTime=\(begin?.time ?? -1) beginNumber=\(begin?.commandNumber ?? -1) beginFlags=\(begin?.flags ?? -1) endTime=\(end.time) endNumber=\(end.commandNumber) endFlags=\(end.flags) guardMatches=\(frame.guardMatches) effectiveFlags=\(frame.effectiveFlags) sequence=\(entry.sequence) commandCategory=\(Self.commandCategory(entry.command)) lines=\(lines.count) waitedMs=\(Int(IngestStageStats.elapsedMs(since: entry.transmittedAt)))\(entry.correlation.map { " corr=\($0)" } ?? "")"
                    )
                    let previousReplySnapshot = executingCommandReplySnapshot
                    executingCommandReplySnapshot = snapshot
                    if success {
                        entry.completion(.success(lines))
                    } else {
                        entry.completion(.failure(.tmuxError(lines: lines)))
                    }
                    executingCommandReplySnapshot = previousReplySnapshot
                    } else {
                        completePlatformCommand(tag: tag, success: success, lines: lines)
                    }
                } else {
                    executableEffects.append(effect)
                }
            }
            if !executableEffects.isEmpty {
                executeRenderEffects(
                    executableEffects,
                    snapshot: snapshot
                )
            }
        }
    }

    /// Render metadata replies are consumed by the ledger's private command
    /// purpose, but the platform snapshot still owns titles and interaction
    /// flags used by SwiftUI. The 22-field shape is unique and strictly
    /// validated, so observing it here cannot turn arbitrary command output
    /// into topology.
    private func observeRenderedPaneMetadataReply(
        _ lines: [String],
        surfaceID: SurfaceId
    ) {
        guard let line = lines.first(where: { !$0.isEmpty }),
              let state = Self.parseRenderedPaneState(line),
              let windowID = paneWindowTable[state.paneId] ?? activeWindowId
        else { return }
        let isFixedSurfaceReply = currentRenderDeclarations.contains { declaration in
            declaration.surfaceID == surfaceID
                && declaration.presentation != .single
                && declaration.paneID == state.paneId
        }
        if isFixedSurfaceReply {
            // A grid/overlay metadata query targets one declared pane, not the
            // window's active pane. Treating its `pane_id` as focus silently
            // retargets topology and can promote a superseding foreground
            // viewport repair into an unnecessary deep rebuild. Update only
            // the queried pane while preserving the notification-owned focus.
            let windowIndex = ensureWindow(windowID)
            if let windowName = Self.nonEmpty(state.windowName) {
                windows[windowIndex].windowName = windowName
            }
            let isActive = windows[windowIndex].activePaneId == state.paneId
            let existing = windows[windowIndex].panes.first { $0.id == state.paneId }
            upsertPaneInfo(
                windowId: windowID,
                paneId: state.paneId,
                title: state.paneTitle,
                titleIsDefault: state.paneTitleIsDefault,
                currentCommand: existing?.currentCommand,
                isActive: isActive,
                contentRect: existing?.contentRect
            )
            paneWindowTable[state.paneId] = windowID
            preloadTerminalDefaultColorReportIfNeeded(for: state.paneId)
            if isActive {
                windows[windowIndex].activePaneTitle = Self.nonEmpty(state.paneTitle)
                windows[windowIndex].activePaneTitleIsDefault =
                    state.paneTitleIsDefault && Self.nonEmpty(state.paneTitle) != nil
            }
            reconcileActivePaneFlags(windowIdx: windowIndex)
            publishWindowMetadataToCore(windowID)
        } else {
            if renderedWindowId != nil,
               (renderedWindowId != windowID || renderedPaneId != state.paneId) {
                // The shared surface is now in a real swap. Keep its physical
                // old owner until bind+feed can land atomically, but retire the
                // legacy projection so no controller-side consumer mistakes
                // the stale pane for paintable current state if capture fails.
                renderedWindowId = nil
                renderedPaneId = nil
            }
            updateWindowMetadata(
                windowId: windowID,
                windowName: state.windowName,
                activePaneId: state.paneId,
                activePaneTitle: state.paneTitle,
                activePaneTitleIsDefault: state.paneTitleIsDefault,
                clearTitleWhenMissing: true
            )
        }
        updatePaneInteractionState(
            paneId: state.paneId,
            isAlternateScreen: state.paneInAltScreen,
            isMouseReporting: state.isMouseReporting,
            isSgrMouse: state.mouseSgr
        )
        if !isFixedSurfaceReply, activeWindowId == windowID {
            activePaneId = state.paneId
        }
    }

    private func handle(message: TmuxMessage, snapshot: TmuxSnapshot) {
        let priorSnapshot = executingCommandReplySnapshot
        executingCommandReplySnapshot = snapshot
        defer { executingCommandReplySnapshot = priorSnapshot }
        switch message {
        case .bell(let paneID):
            guard !renderLedger.isProgramStatusPaneOutput else { break }
            guard let window = windowInfo(forPaneId: PaneId(paneID)) else { break }
            let windowID = window.id.rawValue
            let isActive = window.id == snapshot.activeWindowID
            onBell?(windowID, isActive, window.displayName)
            if !isActive {
                bellingWindows.insert(windowID)
            }

        case .output(let paneId, let data):
            observePaneOutput(paneId: paneId, data: data)

        case .extendedOutput(let paneId, let ageMs, let data):
            if ageMs > 2_000 {
                Self.logDiagnostic(
                    "extended-output delayed pane=\(paneId) ageMs=\(ageMs) bytes=\(data.count)"
                )
            }
            observePaneOutput(paneId: paneId, data: data)

        case .windowAdd(let windowId):
            // Create the window if new; ensureWindow also drains any pane focus a
            // broadcast %window-pane-changed stashed for it before it was known,
            // so the active-pane latch below reads the right pane.
            _ = ensureWindow(windowId)
            // Latch the first window we see as the active one if we
            // haven't been told otherwise yet. session-window-changed
            // will overwrite this with tmux's own view in a beat.
            if activeWindowId == nil {
                activeWindowId = snapshot.activeWindowID ?? windowId
                activePaneId = activeWindowId.flatMap { window($0)?.activePaneId }
            }
            // Discover the window's actual name if the entry is still
            // on the `@N` placeholder. tmux fires `%window-renamed`
            // shortly after `%window-add` for default `new-window`
            // (the shell-startup automatic-rename), but does NOT for
            // explicitly-named `new-window -n NAME` — verified via
            // pty probe. Without this query the tab label sticks at
            // the `@N` placeholder forever for named windows.
            //
            // Discover the layout too: tmux does NOT follow
            // `%window-add` with a `%layout-change` — layout only
            // arrives on later splits/resizes — so a mid-session
            // window keeps `layout == nil` indefinitely. Pane-count
            // consumers (close confirmation, contextual ⌘⇧W, the mosh
            // pane border) need it, and `link-window`/`move-window`
            // can even add a window that is already split.
            //
            // For mid-session creates, `%session-window-changed`
            // arrives BEFORE `%window-add` and pre-creates the entry
            // with the placeholder (verified against tmux 3.6), so
            // the gate is "name or layout still unknown" rather than
            // "we just appended."
            //
            // The check also prevents re-querying when the attach-init
            // `list-windows` response already populated both.
            //
            // `index` is part of the gate for the same reason as layout: a
            // mid-session add lands at the END of `windows` (arrival order),
            // but plain `new-window` fills the lowest free tmux index — the
            // reply is what lets resortWindowsByTmuxIndex slot it where the
            // next reattach's hydration would.
            // The "still undescribed" predicate is shared with Android so both
            // clients ask on the same evidence.
            if attachInitFlushed,
               let idx = windows.firstIndex(where: { $0.id == windowId }),
               TmuxRuntimeHydrationQuery.needsWindowDetails(
                   coreWindowMetadata(windows[idx])
               ) {
                // While the layout half is unknown the pane count is a
                // guess, so mark the query pending — close paths confirm
                // instead of killing until the reply (or a real
                // `%layout-change`) lands.
                if windows[idx].layout == nil {
                    windowLayoutQueriesInFlight[windowId, default: 0] += 1
                }
                queryWindowDetails(windowId: windowId)
            }

        case .windowClose:
            // This is a winlink relink notification, including the vacated
            // slot emitted by `move-window`. The window still belongs to this
            // session, so preserve all pane topology, render ownership, bell
            // state, and the last known index until the core's full-order
            // refresh supplies authoritative truth.
            break

        case .unlinkedWindowClose(let windowId):
            // The window is no longer present in this session. Remove only
            // this true topology close; the core separately schedules a full
            // order refresh because `renumber-windows on` may have restacked
            // every survivor without another notification.
            windows.removeAll { $0.id == windowId }
            bellingWindows.remove(windowId.rawValue)
            windowBellFlags.removeValue(forKey: windowId)
            // The window is gone — drop its title-row membership (no `off` to
            // send; the option died with the window).
            moshPaneBorderWindows.remove(windowId)
            paneWindowTable = paneWindowTable.filter { $0.value != windowId }
            prunePaneCurrentPathsToKnownPanes()
            if activeWindowId == windowId {
                let generation = advanceStateGeneration(reason: "active-window-closed")
                activeWindowId = snapshot.activeWindowID ?? windows.first?.id
                activePaneId = activeWindowId.flatMap { window($0)?.activePaneId }
                if let activePaneId {
                    preloadTerminalDefaultColorReportIfNeeded(for: activePaneId)
                }
                if let activeWindowId {
                    switch controlPath {
                    case .inline:
                        // The ordered close event below is the single render
                        // trigger; the ledger resolves and rebuilds the new
                        // active surface from its authoritative snapshot.
                        _ = generation
                    case .sideChannel:
                        refreshActivePaneMetadataIfNeeded(
                            windowId: activeWindowId,
                            generation: generation,
                            reason: "active-window-closed"
                        )
                    }
                } else {
                    // The topology reconciliation below declares an empty
                    // surface set; the ledger then releases any foreground
                    // barrier when it consumes this ordered close event.
                }
            }
            if renderedWindowId == windowId {
                renderedWindowId = nil
                renderedPaneId = nil
            }

        case .windowRenamed(let windowId, let name):
            // Rename arriving before add — eager-create the entry so
            // the tab shows up with the right fallback label on first
            // sight. Do not clear a pane title; it still wins display.
            upsertWindowName(name, for: windowId)
        case .sessionWindowChanged(let sessionId, let windowId):
            // tmux BROADCASTS this to every control client in the server,
            // tagged with the session it refers to. Drop changes for any
            // session other than our own — otherwise another client
            // switching windows in its session would drag our active
            // window (and a `capture-pane` repaint) along with it, since
            // window ids are server-global and the capture would succeed.
            // Fail open while `ownSessionId` is unknown (see its docs).
            if let ownSessionId, sessionId != ownSessionId {
                Self.logDiagnostic(
                    "session-window-changed dropped foreign session=\(sessionId) own=\(ownSessionId) window=\(windowId)"
                )
                break
            }
            let previousActive = activeWindowId
            activeWindowId = windowId
            // ensureWindow drains any pane focus stashed for this window before
            // we tracked it, so the read below picks up the right active pane.
            ensureWindow(windowId)
            activePaneId = window(windowId)?.activePaneId
            // The session's current window moved while a viewport claim was
            // pending: the policy probe and the geometry check were for the
            // old window, and the fence may have made us latest on it only.
            // Re-issue against the new current window (bounded).
            noteGridAuthorityWindowFacts(snapshot)
            if previousActive != windowId {
                refenceGridClaimIfCurrentWindowMoved()
                if !gridClaimAwaitsFence {
                    probeSteadyGridAuthorityWindowSizePolicy(
                        windowId: windowId,
                        reason: "session-window-changed"
                    )
                }
            }
            if let activePaneId {
                preloadTerminalDefaultColorReportIfNeeded(for: activePaneId)
            }
            Self.logDiagnostic(
                "session-window-changed path=\(controlPath) previous=\(String(describing: previousActive)) activeWindow=\(windowId) activePane=\(String(describing: activePaneId)) rendered=\(String(describing: renderedWindowId))/\(String(describing: renderedPaneId))"
            )
            guard previousActive != windowId || renderedWindowId != windowId else {
                break
            }
            if controlPath == .inline,
               renderedWindowId != windowId,
               renderLedger.pendingStage(for: .live) != .deep {
                // The ledger retains the old physical owner fail-closed until
                // an authoritative bind+feed succeeds. This legacy projection
                // represents current paintability, so a real window switch
                // retires it immediately and cannot admit incremental slivers.
                renderedWindowId = nil
                renderedPaneId = nil
            }
            let generation = advanceStateGeneration(reason: "session-window-changed")
            switch controlPath {
            case .inline:
                // Rendering is reduced from this ordered notification after
                // the platform projection above has been updated.
                _ = generation
            case .sideChannel:
                refreshActivePaneMetadataIfNeeded(
                    windowId: windowId,
                    generation: generation,
                    reason: "session-window-changed"
                )
            }

        case .windowPaneChanged(let windowId, let activePaneId):
            // Client-side window-id filter. %window-pane-changed is BROADCAST to
            // every control client with NO session filter (control-notify.c), so
            // it can name a window we don't track. Acting on it unconditionally
            // (the old behavior) `ensureWindow`-created the named window — leaking
            // a foreign session's window as a phantom tab. Instead: act only on a
            // KNOWN window; for an unknown one, stash the focus and apply it when
            // the window legitimately appears (drainPendingPaneFocus, called from
            // the session-scoped %window-add / %session-window-changed paths).
            // This preserves the side-channel pre-cache for a same-session window
            // whose hydration/layout hasn't landed yet, while never applying a
            // foreign broadcast (its window never appears through those paths).
            guard indexOfWindow(windowId) != nil else {
                pendingPaneFocus[windowId] = activePaneId
                Self.logDiagnostic(
                    "window-pane-changed stashed (unknown window) window=\(windowId) pane=\(activePaneId) activeWindow=\(String(describing: self.activeWindowId))"
                )
                break
            }
            updateActivePane(windowId: windowId, paneId: activePaneId, paneTitle: nil)
            Self.logDiagnostic(
                "window-pane-changed path=\(controlPath) window=\(windowId) pane=\(activePaneId) activeWindow=\(String(describing: self.activeWindowId))"
            )
            if windowId == snapshot.activeWindowID {
                self.activePaneId = activePaneId
                if controlPath == .inline,
                   renderedWindowId == windowId,
                   renderedPaneId != activePaneId,
                   renderLedger.pendingStage(for: .live) != .deep {
                    renderedWindowId = nil
                    renderedPaneId = nil
                }
                reconcileGridAuthorityRepaintForLayout(windowId: windowId)
                let generation = advanceStateGeneration(reason: "window-pane-changed")
                switch controlPath {
                case .inline:
                    _ = generation
                case .sideChannel:
                    refreshActivePaneMetadataIfNeeded(
                        windowId: windowId,
                        generation: generation,
                        reason: "window-pane-changed"
                    )
                    Self.logDiagnostic(
                        "sidechannel active-pane source=notification window=\(windowId) pane=\(activePaneId)"
                    )
                }
            }

        case .subscriptionChanged(let name, let sessionId, let windowId, _, let paneId, let value):
            // Per-pane registrations outlive a session switch until the
            // core reconciles them, and tmux names the session each update
            // was read in. Drop foreign-session updates up front
            // (defense-in-depth: the `indexOfWindow` guard in
            // handlePaneMetadataSubscription already rejects them once
            // the %session-window-changed filter keeps foreign windows
            // out of `windows[]`). Fail open while `ownSessionId` is nil.
            if let ownSessionId, sessionId != ownSessionId { break }
            if TmuxControlSubscriptions.name(name, isFeed: TmuxBellSubscription.name) {
                handleBellSubscription(
                    windowId: windowId,
                    value: value,
                    activeWindowID: snapshot.activeWindowID
                )
                break
            }
            if name == Self.gridAuthoritySubscriptionName {
                handleGridAuthoritySubscription(value: value)
                break
            }
            guard TmuxControlSubscriptions.name(name, isFeed: Self.paneMetadataSubscriptionName),
                  let metadata = Self.parsePaneSubscriptionMetadata(
                    value,
                    fallbackWindowId: windowId,
                    fallbackPaneId: paneId
                  )
            else { break }
            handlePaneMetadataSubscription(metadata)

        case .windowSubscriptionChanged(let name, let sessionId, _, _, let value):
            // The session-level feeds ride one anchor window. Window order is
            // folded into the shared runtime snapshot before this projection.
            if let ownSessionId, sessionId != ownSessionId { break }
            if name == Self.gridAuthoritySubscriptionName {
                handleGridAuthoritySubscription(value: value)
            }

        case .sessionSubscriptionChanged:
            // Session-scoped order subscriptions are folded into the shared
            // runtime snapshot before this legacy adapter projection runs.
            break

        case .pause, .continue:
            // Flow control and the guarded repaint are ledger-owned.
            break

        case .pasteBufferChanged(let name):
            handlePasteBufferChanged(name)

        case .pasteBufferDeleted:
            break

        case .begin, .commandOutputLine, .end, .error:
            // Framed and correlated by TmuxControlCore before this adapter
            // sees the batch. These cases remain exhaustive for clients that
            // call the legacy message handler from package tests.
            break
        case .exit:
            // tmux control mode is ending. Drop back to passthrough so
            // the parent shell's next output lands in the terminal
            // directly. Any trailing ST bytes (ESC \) the parser didn't
            // consume are discarded with the buffer reset — a couple
            // of lost bytes that SwiftTerm wouldn't have rendered anyway.
            //
            // `reset()` also fires `.cancelled` on any pending
            // completions so callbacks waiting for a reply don't
            // leak their captured state.
            reset()

        case .sessionChanged(let sessionId, let name):
            // tmux sends %session-changed ONLY to the control client whose
            // own attached session changed (per-client, not broadcast).
            // So this authoritatively tells us which `$N` is "ours" — latch
            // it for the cross-session broadcast filters below. Emitted
            // right after the DCS prologue on `-CC` attach, and again if we
            // navigate to another session (e.g. within a session group).
            //
            // We deliberately do NOT latch from %client-session-changed:
            // tmux sends THAT to every *other* control client to announce
            // some peer's session change (it leads with that peer's client
            // name). Treating it as our own corrupts ownSessionId to a
            // peer's session, which then makes the foreign-session filter
            // *accept* that peer's broadcasts — observed live as the
            // simulator latching $0 here, then a peer's
            // %client-session-changed $5 flipping it to $5 and re-opening
            // the very leak this filter closes.
            let priorSessionId = ownSessionId
            ownSessionId = sessionId
            ownSessionName = name
            if priorSessionId != sessionId, participatesInGridAuthority {
                applyGridAuthorityLifecycleEffects(reduceGridAuthority(.controlSessionChanged(replacedKnownSession: priorSessionId != nil)))
            }
            Self.logDiagnostic("session-changed own session set to \(sessionId)")

            // A later %session-changed can move this same -CC client to a
            // different session without disconnecting. Window ids are global
            // to the tmux server, so stale tabs from the prior session must not
            // remain valid kill targets. Keep them visible but disabled until
            // a new authoritative list-windows response replaces the model.
            if let priorSessionId, priorSessionId != sessionId {
                // The size this device last owned belonged to the old
                // session's windows; it is no evidence about the new one.
                reverseAttachPeers.removeAll()
                reverseAttachBaselineSize = nil
                reverseAttachOwnerGridBaseline = nil
                reverseAttachPeerSizes.removeAll()
                reverseAttachPeerQueries.removeAll()
                reverseAttachOwnClientName = nil
                reverseAttachPeerDiscoveryInFlight = false
                reverseAttachCedeLookupInFlight = false
                reverseAttachCedeMutationInFlight = false
                pendingReverseAttachCedeSize = nil
                // A new connection generation starts a new gate episode,
                // as a disconnect does: count the old one's repeats now.
                endClientSizeGate()
                controlConnectionGeneration &+= 1
                isWindowListHydrated = false
                // Authority is a session option. Never carry a yielded stamp
                // (or an in-flight claim) into the new session; the hydrate
                // below re-derives that session before any reconnect replay.
                // A participating session reset itself with the switch.
                resetGridAuthorityState(resettingSession: !participatesInGridAuthority)
                hydrateTmuxState(reason: "session-changed")
            }

        case .clientSessionChanged(let client, let sessionId, _):
            // Existing control clients receive this when a peer attaches and
            // whenever that peer changes sessions. Track only peers in our own
            // session; the larger grid itself arrives authoritatively through
            // `%layout-change` after the peer publishes its `-C` size.
            guard clientSizePolicy == .preserveServerGeometry else { break }
            if sessionId == ownSessionId {
                if reverseAttachPeers.isEmpty {
                    reverseAttachBaselineSize = localViewportSize
                }
                reverseAttachPeers.insert(client)
                considerReverseAttachCedeFromKnownWindows()
            } else {
                reverseAttachPeers.remove(client)
                reverseAttachPeerSizes.removeValue(forKey: client)
                reverseAttachPeerQueries.remove(client)
                if reverseAttachPeers.isEmpty, !hasCededGridOwnership {
                    reverseAttachBaselineSize = nil
                }
            }

        case .clientDetached(let client):
            // Ceding is deliberately one-way. Removing the peer only prevents
            // a not-yet-ceded client from reacting to a later unrelated resize.
            reverseAttachPeers.remove(client)
            reverseAttachPeerSizes.removeValue(forKey: client)
            reverseAttachPeerQueries.remove(client)
            if reverseAttachPeers.isEmpty, !hasCededGridOwnership {
                pendingReverseAttachCedeSize = nil
                reverseAttachBaselineSize = nil
            }
            // A peer's departure is not an authority event (R5): the stamp
            // stays where it is until a show or a veil gesture moves it.

        case let .layoutChange(windowId, layout, visibleLayout, rawFlags):
            handleLayoutChange(
                windowId: windowId,
                layout: layout,
                visibleLayout: visibleLayout,
                rawFlags: rawFlags,
                snapshot: snapshot
            )

        case .sessionRenamed(let sessionId, let name):
            if ownSessionId == nil || ownSessionId == sessionId {
                ownSessionName = name
            }

        case .unlinkedWindowAdd, .unlinkedWindowRenamed,
             .sessionsChanged,
             .paneModeChanged, .unknown:
            // Parsed and ignored.
            //
            // `.unlinkedWindowAdd` / `.unlinkedWindowRenamed` refer to
            // windows in OTHER sessions the tmux server is tracking —
            // we don't render those, so we drop them. The close variant
            // gets handled together with `.windowClose` above because
            // it's what `kill-window` produces in our session.
            break
        }
    }

    /// Decode a `%layout-change` and fold it into the window model.
    ///
    /// M1 scope: parse the layout/visible/zoom state, refresh the window's
    /// `panes`, and reindex `paneWindowTable`. The output-routing consequences
    /// of a pane-set change (mounting/tearing down per-pane sinks and the grid)
    /// land in M2/M3 — here the notification only updates the model, so the
    /// active window keeps rendering through today's single-pane path.
    private func handleLayoutChange(
        windowId: WindowId,
        layout: String,
        visibleLayout: String?,
        rawFlags: String?,
        snapshot: TmuxSnapshot? = nil
    ) {
        // %layout-change is session-filtered server-side, but only act on
        // windows we track (defense-in-depth against any cross-session leak).
        guard let idx = indexOfWindow(windowId) else {
            Self.logDiagnostic("layout-change dropped unknown window=\(windowId)")
            return
        }

        let previouslyRenderedAsGrid = windows[idx].rendersAsPaneGrid
        let parsedLayout = WindowLayout.parse(layout)
        let parsedVisible = visibleLayout.flatMap { WindowLayout.parse($0) }
        let zoomed = rawFlags?.contains("Z") ?? false
        // Stamp-less takeover fallback: a resize we did not initiate, away
        // from our grid, means some client (bare `tmux attach`) took the size.
        windows[idx].layout = parsedLayout
        windows[idx].visibleLayout = parsedVisible ?? parsedLayout
        windows[idx].isZoomed = zoomed
        if let parsedLayout {
            windows[idx].panes = mergePaneInfos(
                existing: windows[idx].panes,
                layoutPaneIds: parsedLayout.paneIds,
                activePaneId: windows[idx].activePaneId
            )
        }
        rebuildPaneWindowTable()

        noteGridAuthorityWindowFacts(snapshot)
        // §6.10: core judges the claimed window first, so a layout that
        // sends the claim back to its geometry phase also retires the
        // repaint the shape check below would otherwise retarget.
        if windowId == (activeWindowId ?? renderedWindowId),
           let rect = parsedLayout?.root.rect {
            let atTarget = gridClaimTargetSize.map {
                rect.width == $0.cols && rect.height == $0.rows
            } ?? false
            observeGridClaimWindow(
                columns: rect.width,
                rows: rect.height,
                settleProbe: false,
                context: "layout-change",
                checkForStall: !atTarget
            )
        }
        reconcileGridAuthorityRepaintForLayout(windowId: windowId)

        if controlPath == .inline,
           windowId == activeWindowId,
           !previouslyRenderedAsGrid,
           windows[idx].rendersAsPaneGrid {
            // SwiftUI replaces the shared terminal with pane surfaces after
            // this model turn. The ledger keeps foreground ownership across
            // that intentional declaration/mount gap.
            _ = advanceStateGeneration(reason: "shared-to-grid")
        }

        // A pending viewport claim settles on geometry only after this
        // notification's complete pane/grid model is installed. Starting the
        // authoritative repaint against the pre-update shape can choose the
        // shared terminal just as the window becomes a grid, after which the
        // transition abandons that repaint and leaves the veil stranded.
        if gridClaimAwaitsFence,
           let rect = parsedLayout?.root.rect,
           let size = gridClaimTargetSize,
           rect.width == size.cols, rect.height == size.rows,
           windowId == (activeWindowId ?? renderedWindowId) {
            // The render ledger has not seen this same `%layout-change` yet --
            // the controller model is updated first, the ledger reduces after.
            // Reserving now would take the reservation against the owner the
            // ledger is about to replace, and the rebind would immediately
            // re-issue it: two forced frames for one claim. Defer to the end of
            // this step so the reservation names the owner that will actually
            // paint.
            //
            // Inline, a take-back's confirmation hands the ledger the engine's
            // snapshot through its foreground refresh, and that snapshot
            // already holds this layout. The ledger would then reduce the
            // notification as an echo of its own geometry and repaint the
            // reflowed window in place, over history wrapped for the old
            // grid. Reduced first, the relayout is either owed (P7, a peer
            // still holds the grid) or a deep rebuild already asked for (no
            // peer: a show after a rotation, say). Either way the claim's
            // repaint inherits it, rebuilding the visible rows, and the
            // history follows: at settlement under P8, at once without a
            // peer.
            confirmGridClaimAtStepEnd(context: "layout-change")
        }

        Self.logDiagnostic(
            "layout-change window=\(windowId) paneCount=\(parsedLayout?.paneCount ?? -1) zoomed=\(zoomed) grid=\(windows[idx].rendersAsPaneGrid) panes=\(parsedLayout?.paneIds.map(\.description) ?? [])"
        )

        if let serverRect = parsedLayout?.root.rect {
            if clientSizePolicy == .preserveServerGeometry,
               reverseAttachPeers.isEmpty,
               !hasCededGridOwnership,
               reverseAttachOwnerGridBaseline == nil {
                reverseAttachOwnerGridBaseline = (
                    serverRect.width,
                    serverRect.height
                )
            }
            considerReverseAttachCede(
                serverCols: serverRect.width,
                serverRows: serverRect.height
            )
        }

        updateMoshPaneBorder(windowId: windowId, paneCount: windows[idx].paneCount)
        reconcilePresentedWindowSize(windowId: windowId)
    }

    private func reconcilePresentedWindowSize(windowId: WindowId) {
        guard controlPath == .sideChannel,
              clientSizePolicy == .resizeTmux,
              windowId == (activeWindowId ?? renderedWindowId),
              gridAuthority == .mine,
              currentGridAuthorityPolicy?.isLatest == true,
              !appIsInactive,
              !gridAuthorityRederiveInFlight,
              !gridAuthorityGeometryHeld,
              gridAuthorityLifecycle.claim == nil,
              (windowLayoutQueriesInFlight[windowId] ?? 0) == 0,
              window(windowId)?.layout != nil,
              let sessionId = ownSessionId,
              let size = lastKnownSize,
              let requested = try? TmuxClientGeometry(columns: size.cols, rows: size.rows)
        else { return }
        guard case .mine(let authorityGeneration) = gridAuthorityLifecycle.authority else { return }
        let observed = window(windowId)?.layout.flatMap {
            try? TmuxClientGeometry(columns: $0.root.rect.width, rows: $0.root.rect.height)
        }
        if passiveWindowSizeProbe?.windowID != windowId || passiveWindowSizeProbe?.observed != observed {
            passiveWindowSizeProbe = nil
        }
        guard TmuxWindowSizeReplay.decision(
            requested: requested,
            observed: observed,
            lastAttempt: windowSizeReplayAttempts[windowId]?.requested
        ) == .replay, passiveWindowSizeProbe == nil else { return }
        nextWindowSizeReplayToken &+= 1
        let probe = PassiveWindowSizeProbe(
            token: nextWindowSizeReplayToken,
            connectionGeneration: controlConnectionGeneration,
            windowID: windowId,
            requested: requested,
            observed: observed,
            authorityGeneration: authorityGeneration
        )
        // A competing claim publishes geometry before its committed stamp.
        // Passive maintenance therefore needs positive own-client proof,
        // rather than turning that ambiguous layout into another claim.
        passiveWindowSizeProbe = probe
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.ordinaryRecovery(active: true, proven: false)))
        sendGridAuthorityPassiveRead(ifCurrent: { [weak self] in self?.passiveWindowSizeProbeIsCurrent(probe) == true }) { [weak self] result in
            guard let self else { return }
            guard self.passiveWindowSizeProbeIsCurrent(probe),
                  case .success(let lines) = result,
                  lines.count == 1
            else { self.finishOrdinaryGridRecovery(probe, proven: false); return }
            // The read sees the stamp as a subscription edge would, and the
            // session reduces it as one: a peer's stamp is that peer's
            // verdict now, not a layout for the stamp-less rule to judge.
            let observed = self.gridAuthoritySession.classify(raw: lines[0])
            self.applyGridAuthorityLifecycleEffects(self.reduceGridAuthority(.stampObserved(raw: lines[0])))
            guard observed == .mine(generation: probe.authorityGeneration),
                  self.passiveWindowSizeProbeIsCurrent(probe)
            else {
                // Only a missing stamp leaves the layout to that rule.
                self.finishOrdinaryGridRecovery(probe, proven: observed != .unknown)
                return
            }
            self.queryOwnGridAuthorityClientIdentities(
                sessionId: sessionId,
                connectionGeneration: probe.connectionGeneration
            ) { [weak self] identities in
                guard let self else { return }
                guard self.passiveWindowSizeProbeIsCurrent(probe),
                      let identities, identities.count == 2
                else { self.finishOrdinaryGridRecovery(probe, proven: false); return }
                let own = identities.sorted()
                self.sendControlCommand(
                    "list-clients -F '#{window_id}\t#{client_name}\t#{client_pid}\t#{client_created}'"
                ) { [weak self] result in
                    guard let self else { return }
                    guard self.passiveWindowSizeProbeIsCurrent(probe),
                          case .success(let lines) = result,
                          TmuxWindowSizeReplay.provesExclusiveOwnership(
                            windowID: windowId,
                            controlIdentity: own[0],
                            visibleIdentity: own[1],
                            inventory: lines.joined(separator: "\n")
                          )
                    else { self.finishOrdinaryGridRecovery(probe, proven: false); return }
                    self.forceWindowSizesToClientSize(size, onlyWindowID: windowId) { [weak self] proven in
                        self?.finishOrdinaryGridRecovery(probe, proven: proven)
                    }
                }
            }
        }
    }

    private func finishOrdinaryGridRecovery(_ probe: PassiveWindowSizeProbe, proven: Bool) {
        guard passiveWindowSizeProbe == probe,
              probe.connectionGeneration == controlConnectionGeneration,
              gridAuthoritySession.ordinaryRecoveryActive else { return }
        applyGridAuthorityLifecycleEffects(reduceGridAuthority(.ordinaryRecovery(active: false, proven: proven)))
    }

    private func passiveWindowSizeProbeIsCurrent(_ probe: PassiveWindowSizeProbe) -> Bool {
        guard passiveWindowSizeProbe == probe,
              controlConnectionGeneration == probe.connectionGeneration,
              mode == .tmuxControl,
              !commandQueueAwaitingTransportRecovery,
              !appIsInactive,
              !gridAuthorityRederiveInFlight,
              !gridAuthorityGeometryHeld,
              gridAuthorityLifecycle.claim == nil,
              gridAuthority == .mine,
              gridAuthorityLifecycle.authority == .mine(generation: probe.authorityGeneration),
              currentGridAuthorityPolicy?.isLatest == true,
              (activeWindowId ?? renderedWindowId) == probe.windowID,
              let size = lastKnownSize,
              size.cols == probe.requested.columns, size.rows == probe.requested.rows
        else { return false }
        let observed = window(probe.windowID)?.layout.flatMap {
            try? TmuxClientGeometry(columns: $0.root.rect.width, rows: $0.root.rect.height)
        }
        return observed == probe.observed
    }

    /// (Mosh/side-channel only) Toggle tmux's native per-pane title row for a
    /// window as it splits/collapses — Option 2: tmux paints the titles into the
    /// UDP stream, Tessera overlays a tappable ✕. No-op on the inline (SSH) path,
    /// where the app draws its own per-pane headers and would double-reserve the
    /// row. Only acts on the 1↔N transition (idempotent across geometry-only
    /// layout changes) and targets the specific window, so single-pane windows
    /// and other sessions are untouched. See `moshPaneBorderWindows`.
    private func updateMoshPaneBorder(windowId: WindowId, paneCount: Int) {
        guard controlPath == .sideChannel,
              clientSizePolicy == .resizeTmux
        else { return }
        let isMulti = paneCount > 1
        let wasMulti = moshPaneBorderWindows.contains(windowId)
        guard isMulti != wasMulti else { return }

        if isMulti {
            moshPaneBorderWindows.insert(windowId)
            sendControlCommand("set -t \(windowId.description) pane-border-status top")
            sendControlCommand("set -t \(windowId.description) pane-border-format \"\(Self.moshPaneBorderFormat)\"")
        } else {
            moshPaneBorderWindows.remove(windowId)
            // `-u`, not `off`: the window keeps whatever the user configured
            // for pane borders. Forcing `off` here wrote our preference into
            // their window and left it there for every client of that session.
            sendControlCommand("set -u -t \(windowId.description) pane-border-status")
            sendControlCommand("set -u -t \(windowId.description) pane-border-format")
        }
    }

    func preemptMoshPaneBorderSplit(forTargeting paneId: PaneId) {
        guard controlPath == .sideChannel,
              clientSizePolicy == .resizeTmux,
              let windowId = paneWindowTable[paneId] ?? activeWindowId,
              let window = windows.first(where: { $0.id == windowId }),
              window.paneCount <= 1,
              !moshPaneBorderWindows.contains(windowId)
        else { return }

        let paneIsInWindow = window.layout?.paneIds.contains(paneId) == true
            || window.panes.contains { $0.id == paneId }
            || window.activePaneId == paneId
        guard paneIsInWindow else { return }

        moshPaneBorderWindows.insert(windowId)
        sendControlCommand("set -t \(windowId.description) pane-border-status top")
        sendControlCommand("set -t \(windowId.description) pane-border-format \"\(Self.moshPaneBorderFormat)\"")
    }


    private func handleBellSubscription(
        windowId: WindowId,
        value: String,
        activeWindowID: WindowId?
    ) {
        let isBellSet = value.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        // tmux delivers each -B subscription's current value right after
        // registration, so the first observation per window is a seed,
        // not an edge — without this, a window whose bell flag was
        // already 1 re-rings on every reattach.
        let previousObservation = windowBellFlags[windowId]
        windowBellFlags[windowId] = isBellSet
        guard let wasBellSet = previousObservation,
              isBellSet,
              !wasBellSet,
              windowId != activeWindowID
        else { return }

        onBell?(windowId.rawValue, false, window(windowId)?.displayName)
        bellingWindows.insert(windowId.rawValue)
    }

    private func sendTerminalResponseForOutputIfNeeded(paneId: PaneId, data: [UInt8]) {
        guard !renderLedger.isProgramStatusPaneOutput,
              let response = terminalResponseForOutput?(paneId, data[...]),
              !response.isEmpty
        else { return }
        sendTerminalReport(response, to: paneId)
    }

    private func preloadTerminalDefaultColorReportIfNeeded(for pane: PaneId) {
        guard mode == .tmuxControl,
              !preloadedTerminalDefaultColorPanes.contains(pane),
              let response = terminalResponseForOutput?(
                pane,
                Self.defaultColorProbeQueryBytes[...]
              ),
              !response.isEmpty
        else { return }

        preloadedTerminalDefaultColorPanes.insert(pane)
        sendTerminalReport(response, to: pane)
    }

    /// Hand a terminal reply (OSC 10/11 colour reports) to tmux for `pane`.
    ///
    /// tmux ≥ 3.5 stores one colour per `refresh-client -r` — its parser
    /// (`tty_keys_colours`) reads exactly one OSC sequence and ignores the
    /// rest — so a combined fg+bg reply is split into one command per
    /// sequence; sending both in one report silently dropped the background.
    ///
    /// tmux < 3.5 has no `-r` at all and answers a pane's OSC 10/11 query
    /// itself from the first attached client's terminal colours. A control
    /// client never initialises those (they stay at the zeroed `tty.fg/bg`),
    /// so every query got black/black — Codex's status shimmer, which
    /// blends default fg into bg, rendered invisible. There the pane's own
    /// `window-style` is the only lever that changes that answer: an
    /// explicit pane style is reported verbatim (`input_osc_10` checks
    /// `COLOUR_DEFAULT` before consulting clients), and for control clients
    /// it has no rendering side effect because their output is raw.
    private func sendTerminalReport(_ bytes: [UInt8], to pane: PaneId) {
        let sequences = Self.splitOSCSequences(bytes)
        let reports = sequences.isEmpty ? [bytes] : sequences
        if serverSupportsClientReports == false {
            sendPaneStyleColorFallback(reports, to: pane)
            return
        }
        for report in reports {
            guard let text = String(bytes: report, encoding: .utf8) else { continue }
            let argument = "\(pane.description):\(text)"
            sendControlCommand("refresh-client -r \(Self.singleQuotedTmuxArgument(argument))")
        }
    }

    private func sendPaneStyleColorFallback(_ reports: [[UInt8]], to pane: PaneId) {
        var styleParts: [String] = []
        for report in reports {
            guard let (code, rgb) = Self.parseOSCColorReport(report) else { continue }
            switch code {
            case 10: styleParts.append("fg=\(rgb)")
            case 11: styleParts.append("bg=\(rgb)")
            default: break
            }
        }
        guard !styleParts.isEmpty else { return }
        let style = styleParts.joined(separator: ",")
        Self.logDiagnostic(
            "color-report fallback=pane-style pane=\(pane.description) version=\(serverVersion ?? "nil") style=\(style)"
        )
        let argument = Self.singleQuotedTmuxArgument(style)
        // `select-pane -t %N -P` also makes %N the active pane, so attaching
        // to a split moved the user's typing to whichever pane was styled
        // last. Since tmux 3.0 the same pane options can be set directly.
        // Two commands, not one `;` list: each sent line must get exactly
        // one reply.
        if serverVersion.map(Self.versionSupportsPaneOptions) ?? true {
            for option in ["window-style", "window-active-style"] {
                sendControlCommand("set-option -p -t \(pane.description) \(option) \(argument)")
            }
            return
        }
        // Older servers only have `select-pane -P`: style the pane the user
        // is already in, and leave the others' colours unanswered rather
        // than move their focus.
        guard pane == activePaneId else {
            Self.logDiagnostic("color-report fallback=skipped pane=\(pane.description) reason=inactive-pane")
            return
        }
        sendControlCommand("select-pane -t \(pane.description) -P \(argument)")
    }

    /// Records the server version from the separator probe. When the server
    /// turns out to lack `refresh-client -r`, the colour preloads already
    /// sent as reports were rejected (`unknown flag -r`), so they are redone
    /// through the pane-style fallback for the panes currently in play.
    func noteServerVersion(_ version: String?) {
        guard let version, !version.isEmpty else { return }
        serverVersion = version
        guard Self.versionSupportsClientReports(version) == false else { return }
        Self.logDiagnostic("server-version value=\(version) clientReports=unsupported")
        preloadedTerminalDefaultColorPanes.removeAll(keepingCapacity: true)
        for pane in [renderedPaneId, activePaneId].compactMap({ $0 }) {
            preloadTerminalDefaultColorReportIfNeeded(for: pane)
        }
    }

    /// Pulls the version token out of the separator probe reply
    /// (`tessera-sep<sep>3.6a`), tolerant of a mangled separator.
    static func parseServerVersion(_ result: Result<[String], CommandError>) -> String? {
        guard case .success(let lines) = result,
              let line = lines.first(where: { !$0.isEmpty }),
              let range = line.range(of: "tessera-sep")
        else { return nil }
        let version = line[range.upperBound...]
            .dropFirst()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// `refresh-client -r` landed in tmux 3.5. Unparseable versions (e.g.
    /// "next-3.7", "master") fall back to assuming support.
    static func versionSupportsClientReports(_ version: String) -> Bool {
        guard let (major, minor) = versionComponents(version) else { return true }
        return major > 3 || (major == 3 && minor >= 5)
    }

    /// Pane options (`set-option -p`) landed in tmux 3.0. Unparseable
    /// versions count as current here too.
    static func versionSupportsPaneOptions(_ version: String) -> Bool {
        guard let (major, _) = versionComponents(version) else { return true }
        return major >= 3
    }

    /// "3.4" → (3, 4), "3.6a" → (3, 6), "next-3.7" → (3, 7); nil without a
    /// major.minor pair.
    private static func versionComponents(_ version: String) -> (major: Int, minor: Int)? {
        var digits = version[...]
        if let firstDigit = digits.firstIndex(where: { $0.isNumber }) {
            digits = digits[firstDigit...]
        }
        let components = digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              let major = Int(components[0].prefix(while: { $0.isNumber })),
              let minor = Int(components[1].prefix(while: { $0.isNumber }))
        else { return nil }
        return (major, minor)
    }

    /// Splits `bytes` into its complete OSC sequences (`ESC ] … BEL` or
    /// `ESC ] … ESC \`). Bytes outside any sequence are dropped; an empty
    /// result means the payload was not OSC-shaped at all.
    static func splitOSCSequences(_ bytes: [UInt8]) -> [[UInt8]] {
        var sequences: [[UInt8]] = []
        var index = 0
        while index + 1 < bytes.count {
            guard bytes[index] == 0x1B, bytes[index + 1] == 0x5D else {
                index += 1
                continue
            }
            var end = index + 2
            var terminatorLength = 0
            while end < bytes.count {
                if bytes[end] == 0x07 {
                    terminatorLength = 1
                    break
                }
                if bytes[end] == 0x1B, end + 1 < bytes.count, bytes[end + 1] == 0x5C {
                    terminatorLength = 2
                    break
                }
                end += 1
            }
            guard terminatorLength > 0 else { break }
            sequences.append(Array(bytes[index..<(end + terminatorLength)]))
            index = end + terminatorLength
        }
        return sequences
    }

    /// Parses one `ESC ] 10;rgb:RRRR/GGGG/BBBB ST` (or 11) report into the
    /// OSC code and a tmux style colour `#rrggbb`.
    static func parseOSCColorReport(_ sequence: [UInt8]) -> (code: Int, rgb: String)? {
        guard sequence.count > 2,
              sequence[0] == 0x1B, sequence[1] == 0x5D,
              let text = String(bytes: sequence.dropFirst(2), encoding: .utf8)
        else { return nil }
        let payload = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{07}\u{1B}\\"))
        let fields = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2,
              let code = Int(fields[0]),
              fields[1].hasPrefix("rgb:")
        else { return nil }
        let channels = fields[1].dropFirst(4).split(separator: "/")
        guard channels.count == 3 else { return nil }
        var hex = "#"
        for channel in channels {
            // X11 rgb: components carry 1–4 hex digits; the leading two are
            // the 8-bit value (rgb:d4d4/… → d4).
            guard !channel.isEmpty, channel.allSatisfy({ $0.isHexDigit }) else { return nil }
            let value = channel.count >= 2 ? String(channel.prefix(2)) : String(channel) + String(channel)
            hex += value.lowercased()
        }
        return (code, hex)
    }

    /// `%paste-buffer-changed`: fetch the buffer text and hand it to the
    /// owner. `show-buffer` prints the buffer as command-output lines, so a
    /// trailing newline is indistinguishable from none — acceptable for
    /// clipboard mirroring. Deferred while an authoritative repaint owns the
    /// reply FIFO, the same rule background observer queries follow.
    private func handlePasteBufferChanged(_ name: String, attempt: Int = 0) {
        guard mode == .tmuxControl, onPasteBufferChanged != nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isAuthoritativeRenderRefreshPending, attempt < 5 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.handlePasteBufferChanged(trimmed, attempt: attempt + 1)
            }
            return
        }
        sendControlCommand(
            "show-buffer -b \(Self.singleQuotedTmuxArgument(trimmed))"
        ) { [weak self] result in
            guard let self, case .success(let lines) = result else { return }
            let text = lines.joined(separator: "\n")
            guard !text.isEmpty else { return }
            Self.logDiagnostic("paste-buffer-changed name=\(trimmed) bytes=\(text.utf8.count)")
            self.onPasteBufferChanged?(trimmed, text)
        }
    }

    private static func singleQuotedTmuxArgument(_ value: String) -> String {
        var quoted = "'"
        for scalar in value.unicodeScalars {
            if scalar == "'" {
                quoted += "'\\''"
            } else {
                quoted += String(scalar)
            }
        }
        quoted += "'"
        return quoted
    }

    // MARK: - Attach/hydration

    /// Push the shared state-discovery queries we need after `-CC`
    /// mode is established. Both inline SSH tmux and mosh side-channel
    /// use the same tmux truth for window names, active panes, pane
    /// titles, and active-window id; only the render step differs.
    private func flushAttachInitQueries() {
        hydrateTmuxState(reason: "attach-init")
    }

    /// The pane history Tessera's deep capture wants, in lines.
    static let desiredHistoryLimit = 10_000

    /// Ask for more scrollback on new panes without ever asking for less, and
    /// without leaving the session the user asked for.
    ///
    /// This used to be `set-option -g history-limit 10000`: a *global* write,
    /// so a user whose `.tmux.conf` set a deeper limit had every future pane on
    /// that server silently truncated to ours, permanently, from a terminal
    /// they had merely connected once. An untargeted `set-option` in control
    /// mode scopes to this client's own session, and reading the effective
    /// value first means a user who already keeps more than we want keeps it.
    private func raiseHistoryLimitForThisSession() {
        let desired = Self.desiredHistoryLimit
        sendControlCommand("display-message -p '#{history-limit}'") { [weak self] result in
            guard let self,
                  case .success(let lines) = result,
                  let current = lines
                      .lazy
                      .map({ $0.trimmingCharacters(in: .whitespaces) })
                      .first(where: { !$0.isEmpty })
                      .flatMap(Int.init)
            else { return }
            guard current < desired else {
                Self.logDiagnostic("history-limit kept user value=\(current)")
                return
            }
            self.sendControlCommand("set-option history-limit \(desired)")
        }
    }

    private func hydrateTmuxState(reason: String) {
        let generation = advanceStateGeneration(reason: reason)
        if appIsInactive, controlPath == .inline {
            submitRenderFact(.appBackground)
        }
        Self.logDiagnostic(
            "hydrate begin path=\(controlPath) reason=\(reason) generation=\(generation) size=\(String(describing: lastKnownSize))"
        )

        if controlPath == .inline {
            // tmux bakes history-limit into panes when they are created; this
            // covers post-attach windows while first-session panes keep the
            // server default and deep capture simply clamps to what's there.
            raiseHistoryLimitForThisSession()
        }
        // PTY resize is silently ignored in -CC mode, including mosh's
        // side-channel client. Replay the visible terminal size before any
        // queries or user-triggered tmux commands depend on this client.
        // (T6-aware: a reconnect that dropped while yielded re-derives the
        // authority stamp first instead of stealing the grid back.)
        if participatesInGridAuthority { beginGridAuthorityScopeResolution() }
        replayAttachInitClientSize()

        sendControlCommand(RenderCommands.pauseAfter())
        // Registered per pane once the window list below has answered; see
        // `sendPendingSubscriptionCommands`.
        runtimeEngine.subscriptionRequests.bell = true
        runtimeEngine.subscriptionRequests.windowOrder = true
        if participatesInGridAuthority {
            sendGridAuthoritySubscription()
        }

        // Field order is load-bearing: fixed-grammar fields (id, index, layout,
        // visible_layout, zoomed_flag) first and `#{window_name}` LAST, because
        // a tab embedded in a window name must not shift the layout columns.
        // Widening this existing command (rather than adding a new one) keeps
        // the attach-init frame numbering stable — no golden renumbering.
        sendControlCommand(
            "list-windows -F '#{window_id}\t#{window_index}\t#{window_layout}\t#{window_visible_layout}\t#{window_zoomed_flag}\t#{window_name}'"
        ) { [weak self] result in
            guard let self = self,
                  self.isCurrentGeneration(generation)
            else { return }
            guard case .success(let lines) = result else {
                Self.logDiagnostic("hydrate windows failed result='\(Self.describe(result))'")
                return
            }
            self.handleHydratedWindowList(lines: lines)
        }

        sendControlCommand(
            "list-panes -s -F '#{window_id}\t#{pane_id}\t#{pane_active}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{pane_current_command}\t#{pane_title}\t#{host}'"
        ) { [weak self] result in
            guard let self = self,
                  self.isCurrentGeneration(generation)
            else { return }
            guard case .success(let lines) = result else {
                Self.logDiagnostic("hydrate panes failed result='\(Self.describe(result))'")
                return
            }
            self.handleHydratedPaneList(lines: lines)
        }

        sendControlCommand(TmuxRuntimeHydrationQuery.activeWindowCommand) { [weak self] result in
            guard let self = self,
                  self.isCurrentGeneration(generation)
            else { return }
            guard case .success(let responseLines) = result,
                  let activeId = TmuxRuntimeHydrationQuery.activeWindowID(lines: responseLines)
                    ?? responseLines.first(where: { !$0.isEmpty })
                        .flatMap(Self.parseWindowIdString)
            else {
                Self.logDiagnostic(
                    "hydrate active-window parse-failed result='\(Self.describe(result))'"
                )
                return
            }
            self.handleHydratedActiveWindow(
                activeId,
                generation: generation,
                reason: reason,
                responseLines: responseLines
            )
        }

        sendPaneMetadataSubscription()

        // Last on purpose: the attach-init frame numbering above is golden
        // (tests reply positionally), and the probe's answer is diagnostic,
        // not load-bearing.
        sendSeparatorProbeIfNeeded()
    }

    private func handleHydratedWindowList(lines: [String]) {
        if executingCommandReplySnapshot != nil {
            legacyTopologyReplayConnectionGeneration = controlConnectionGeneration
        }
        var discoveredWindows: [WindowInfo] = []

        for line in lines {
            guard var discovered = Self.parseWindowListLine(line) else { continue }
            if let existing = window(discovered.id) {
                discovered.activePaneId = existing.activePaneId
                discovered.activePaneTitle = existing.activePaneTitle
                discovered.activePaneTitleIsDefault = existing.activePaneTitleIsDefault
                // Carry forward per-pane titles for panes that persist; the
                // list-panes step that follows refreshes them, but this keeps
                // labels stable across the brief window between the two replies.
                if !existing.panes.isEmpty {
                    let titles = Dictionary(
                        existing.panes.map { ($0.id, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    discovered.panes = discovered.panes.map { pane in
                        guard let prior = titles[pane.id] else { return pane }
                        var merged = pane
                        merged.title = prior.title
                        merged.titleIsDefault = prior.titleIsDefault
                        merged.currentCommand = prior.currentCommand
                        merged.isAlternateScreen = prior.isAlternateScreen
                        merged.isMouseReporting = prior.isMouseReporting
                        merged.isSgrMouse = prior.isSgrMouse
                        merged.contentRect = prior.contentRect
                        return merged
                    }
                }
            }
            discoveredWindows.append(discovered)
        }

        windows = discoveredWindows
        publishWindowListQueryToCore()
        isWindowListHydrated = true
        if clientSizePolicy == .preserveServerGeometry,
           reverseAttachPeers.isEmpty,
           !hasCededGridOwnership,
           reverseAttachOwnerGridBaseline == nil,
           let ownerRect = discoveredWindows.compactMap({ $0.layout?.root.rect }).max(
               by: { lhs, rhs in
                   lhs.width * lhs.height < rhs.width * rhs.height
               }
           ) {
            // `list-windows` is the first authoritative geometry snapshot on
            // a real attach. Latch it before a peer's layout notification can
            // arrive ahead of that peer's `%client-session-changed` event and
            // masquerade as the original owner grid.
            reverseAttachOwnerGridBaseline = (ownerRect.width, ownerRect.height)
            Self.logDiagnostic(
                "client-size owner-baseline source=hydrate size=\(ownerRect.width)x\(ownerRect.height) path=\(controlPath)"
            )
        }
        // Hydration is the authoritative active-pane snapshot (list-panes sets
        // each window's active pane below). Any pane focus stashed for a
        // not-yet-known window is now superseded — applied windows get their
        // active pane from hydration, foreign windows are simply gone — so drop
        // the whole latch rather than risk applying a pre-hydration value.
        pendingPaneFocus.removeAll()
        let validWindowIds = Set(discoveredWindows.map(\.id))
        bellingWindows = bellingWindows.intersection(Set(validWindowIds.map(\.rawValue)))
        windowBellFlags = windowBellFlags.filter { validWindowIds.contains($0.key) }
        if let activeWindowId, !validWindowIds.contains(activeWindowId) {
            self.activeWindowId = nil
            activePaneId = nil
        }
        if let renderedWindowId, !validWindowIds.contains(renderedWindowId) {
            self.renderedWindowId = nil
            renderedPaneId = nil
        }
        rebuildPaneWindowTable()

        // (Mosh) Apply tmux's native title row to any window that hydrates
        // already-split (attach-to-pre-split), and drop set-membership for
        // windows that vanished while disconnected. No-op on the inline path.
        moshPaneBorderWindows = moshPaneBorderWindows.intersection(validWindowIds)
        for window in windows {
            updateMoshPaneBorder(windowId: window.id, paneCount: window.paneCount)
        }

        Self.logDiagnostic(
            "hydrate windows discovered=\(discoveredWindows.map { "\($0.id):\($0.windowName ?? "nil")" })"
        )

        // The attach-init client-size replay ran before this reply, so its
        // window-size force had nothing to iterate. Stamp the windows now
        // that they are known, or a window frozen by an ignore-size latest
        // client stays frozen when no later size change ever replays again
        // (the settled-viewport continuity-resume shape).
        // Skipped while yielded: forcing here would steal the grid back
        // from the peer that owns the authority stamp (T8).
        if let size = lastKnownSize,
           !gridAuthority.isPeer || gridAuthorityLifecycle.claim != nil {
            forceWindowSizesToClientSize(size)
        }
    }

    private func handleHydratedPaneList(lines: [String]) {
        // `list-panes -s` returns EVERY pane in the session. Track them all —
        // background panes' titles/flags are on the wire and split rendering
        // needs the full set — not just the active pane as before.
        var panesByWindow: [WindowId: [PaneInfo]] = [:]
        var activeEntries: [PaneListEntry] = []
        for line in lines {
            guard let pane = Self.parsePaneListLine(line) else { continue }
            panesByWindow[pane.windowId, default: []].append(
                PaneInfo(
                    id: pane.paneId,
                    title: pane.paneTitle,
                    titleIsDefault: pane.paneTitleIsDefault,
                    isActive: pane.isActive,
                    currentCommand: pane.currentCommand,
                    contentRect: pane.contentRect
                )
            )
            if pane.isActive { activeEntries.append(pane) }
        }

        for (windowId, discoveredPanes) in panesByWindow {
            guard let idx = indexOfWindow(windowId) else { continue }
            windows[idx].panes = Self.orderPanes(discoveredPanes, byLayout: windows[idx].layout)
        }

        for pane in activeEntries {
            updateActivePane(
                windowId: pane.windowId,
                paneId: pane.paneId,
                paneTitle: pane.paneTitle,
                activePaneTitleIsDefault: pane.paneTitleIsDefault,
                clearTitleWhenMissing: true
            )
        }

        if let activeWindowId {
            activePaneId = window(activeWindowId)?.activePaneId
        }
        rebuildPaneWindowTable()
        publishWindowListQueryToCore()

        Self.logDiagnostic(
            "hydrate panes active=\(windows.map { "\($0.id):\(String(describing: $0.activePaneId)):\($0.activePaneTitle ?? "nil")" }) paneCounts=\(windows.map { "\($0.id):\($0.panes.count)" })"
        )
    }

    /// Order a window's discovered panes by its layout's DFS order when known,
    /// appending any pane absent from the layout so a real pane is never lost.
    private static func orderPanes(_ panes: [PaneInfo], byLayout layout: WindowLayout?) -> [PaneInfo] {
        guard let layout else { return panes }
        let byId = Dictionary(panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [PaneInfo] = []
        for paneId in layout.paneIds {
            if let info = byId[paneId] { ordered.append(info) }
        }
        for pane in panes where !ordered.contains(where: { $0.id == pane.id }) {
            ordered.append(pane)
        }
        return ordered
    }

    private func handleHydratedActiveWindow(
        _ activeId: WindowId,
        generation: Int,
        reason: String,
        responseLines: [String]
    ) {
        Self.logDiagnostic(
            "hydrate active-window result=\(activeId) generation=\(generation) lines=\(responseLines.count)"
        )
        let querySnapshot = executingCommandReplySnapshot ?? runtimeEngine.snapshot
        guard window(activeId) != nil else {
            Self.logDiagnostic(
                "hydrate active-window ignored missing-window=\(activeId) generation=\(generation)"
            )
            return
        }
        activeWindowQueryRebase = (
            windowID: activeId,
            sessionID: querySnapshot.sessionID,
            connectionGeneration: controlConnectionGeneration
        )
        pendingHydratedActiveWindow = (
            windowID: activeId,
            generation: generation,
            reason: reason
        )
    }

    private func finalizeHydratedActiveWindow(
        _ activeId: WindowId,
        generation: Int,
        reason: String,
        snapshot: TmuxSnapshot
    ) {

        switch controlPath {
        case .inline:
            // Hydration has now supplied the authoritative layout. A split
            // window must retire `.live` before the ledger can enqueue a
            // shared repaint; PaneGridView declares pane surfaces as their
            // emulators mount.
            redeclareInlineRenderSurfaces()
            updateRenderLedgerConfiguration()
            executeRenderEffects(
                renderLedger.synchronize(snapshot: snapshot),
                snapshot: snapshot
            )
        case .sideChannel:
            refreshActivePaneMetadataIfNeeded(
                windowId: activeId,
                generation: generation,
                reason: "\(reason)-active"
            )
        }

        if gridClaimAwaitsFence, gridAuthoritySession.claimFence == nil,
           let claim = gridAuthorityLifecycle.claim {
            // The claim's fence waited for an active window.
            queueGridClaimFenceSequence(
                connectionGeneration: controlConnectionGeneration,
                claimGeneration: claim.generation,
                reason: "\(reason)-window-hydrated",
                replaySize: true
            )
        } else if !gridClaimAwaitsFence {
            probeSteadyGridAuthorityWindowSizePolicy(
                windowId: activeId,
                reason: reason
            )
        }
    }

    private struct PaneListEntry {
        let windowId: WindowId
        let paneId: PaneId
        let isActive: Bool
        let contentRect: CellRect?
        let currentCommand: String?
        let paneTitle: String?
        let paneTitleIsDefault: Bool
    }

    private struct PaneMetadata {
        let paneId: PaneId
        let contentRect: CellRect?
        let currentCommand: String?
        let paneTitle: String?
        let paneTitleIsDefault: Bool
        let windowName: String?
    }

    struct PaneSubscriptionMetadata {
        let windowId: WindowId
        let paneId: PaneId
        let isActive: Bool
        let contentRect: CellRect?
        let currentCommand: String?
        let paneTitle: String?
        let paneTitleIsDefault: Bool
        let windowName: String?
        let currentPath: String?
        let agentStateJSON: String?
        var isAlternateScreen: Bool? = nil
        var isMouseReporting: Bool? = nil
        var isSgrMouse: Bool? = nil
    }

    private func sendPaneMetadataSubscription() {
        runtimeEngine.subscriptionRequests.paneMetadata = true
        sendPendingSubscriptionCommands()
    }

    /// Put the core's `refresh-client -B` changes on the wire: the requested
    /// feeds for panes that appeared, removals for panes that closed. The
    /// core registers nothing until this connection's window list has
    /// answered, so this is asked after every read.
    ///
    /// Sent on the next main-actor turn, not inline: a hydration or a burst
    /// of layout changes spans several reads, and one reconciliation after
    /// them registers each pane once instead of interleaving registrations
    /// with the render queries those same reads start. The engine, not this
    /// turn, decides what is pending, so a flush that runs after a reconnect
    /// registers the new connection's panes or nothing.
    private func sendPendingSubscriptionCommands() {
        guard mode == .tmuxControl, !subscriptionFlushScheduled else { return }
        subscriptionFlushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.subscriptionFlushScheduled = false
            guard self.mode == .tmuxControl else { return }
            for command in self.runtimeEngine.takePendingSubscriptionCommands() {
                self.sendControlCommand(command)
            }
        }
    }

    /// Drain the core's coalesced order-refresh request through the same
    /// correlated list query used by attach hydration. One dirty follow-up is
    /// retained by the core while this command is in flight.
    private func sendPendingWindowOrderRefreshIfNeeded() {
        guard mode == .tmuxControl,
              let command = runtimeEngine.takePendingOrderRefreshCommand()
        else { return }
        let connectionGeneration = controlConnectionGeneration
        sendControlCommand(command) { [weak self] result in
            guard let self,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.mode == .tmuxControl
            else { return }
            switch result {
            case .success(let lines):
                // This is the core's tagged hydration row, already ingested
                // before the correlated platform completion is delivered.
                // Validate with the same strict shared parser; the legacy
                // adapter parser expects an untagged @id first column.
                let valid = TmuxRuntimeHydrationQuery.didIngestWindowList(lines: lines, snapshot: self.runtimeEngine.snapshot)
                self.runtimeEngine.completeOrderRefresh(succeeded: valid)
            case .failure:
                self.runtimeEngine.completeOrderRefresh(succeeded: false)
            }
            self.projectCoreSnapshot()
            self.finishConfirmedWindowOrderMutationIfNeeded()
            self.sendPendingWindowOrderRefreshIfNeeded()
        }
    }

    private static func parseWindowListLine(_ line: String) -> WindowInfo? {
        guard !line.isEmpty else { return nil }
        // Wide shape: id \t index \t layout \t visible_layout \t zoomed_flag
        // \t name. `name` is LAST and may itself contain tabs, so cap the
        // splits to keep the whole remainder as the name (hostile-name safe).
        // The index field is a pure integer while a layout string never is
        // ("b25d,80x24,…"), so probing field 2 disambiguates the pre-index
        // wide shape (id \t layout \t …) without guessing from field count —
        // a tab-bearing name must not skew the detection.
        let probe = line.split(
            separator: "\t",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        let index: Int? = probe.count >= 2 ? Int(probe[1]) : nil
        let fixedFieldOffset = index != nil ? 1 : 0
        let parts = line.split(
            separator: "\t",
            maxSplits: 4 + fixedFieldOffset,
            omittingEmptySubsequences: false
        )
        guard let first = parts.first,
              let id = parseWindowIdString(String(first))
        else {
            // A separator-sanitizing host (tabs arrive as another single
            // character) still yields the full wide shape — recover it
            // before settling for the legacy 2-field guess.
            if let mangled = parseSeparatorMangledWindowListLine(line) {
                return mangled
            }
            // Legacy 2-field shape fallback (id name, possibly space-joined).
            let spaceParts = line.split(
                separator: " ",
                maxSplits: 1,
                omittingEmptySubsequences: true
            )
            guard let head = spaceParts.first,
                  let legacyId = parseWindowIdString(String(head))
            else { return nil }
            let legacyName = spaceParts.count >= 2 ? nonEmpty(String(spaceParts[1])) : nil
            return .init(id: legacyId, windowName: legacyName)
        }

        if parts.count >= 4 + fixedFieldOffset {
            let layout = WindowLayout.parse(String(parts[1 + fixedFieldOffset]))
            let visible = WindowLayout.parse(String(parts[2 + fixedFieldOffset]))
            let zoomed = String(parts[3 + fixedFieldOffset]) == "1"
            let name = parts.count >= 5 + fixedFieldOffset
                ? nonEmpty(String(parts[4 + fixedFieldOffset]))
                : nil
            var info = WindowInfo(id: id, index: index, windowName: name)
            info.layout = layout
            info.visibleLayout = visible ?? layout
            info.isZoomed = zoomed
            if let layout {
                info.panes = layout.paneIds.map { PaneInfo(id: $0) }
            }
            return info
        }

        // Narrow shape (id \t name) — tolerate older servers / formats.
        let name = parts.count >= 2 ? nonEmpty(String(parts[1])) : nil
        return .init(id: id, windowName: name)
    }

    /// `list-windows` wide shape on a separator-sanitizing host. The five
    /// fixed-grammar fields never contain the separator (window id, integer
    /// index, layout strings, zoom flag), and `window_name` is LAST by
    /// design, so bounded splits keep a name containing the separator
    /// intact — the same hostile-name guarantee the tab shape has.
    private static func parseSeparatorMangledWindowListLine(_ line: String) -> WindowInfo? {
        guard line.hasPrefix("@") else { return nil }
        let afterAnchor = line.dropFirst().drop(while: { ("0"..."9").contains($0) })
        guard let separator = afterAnchor.first,
              separator != "\t",
              afterAnchor.startIndex != line.index(after: line.startIndex)
        else { return nil }
        let parts = line.split(
            separator: separator,
            maxSplits: 5,
            omittingEmptySubsequences: false
        )
        guard parts.count >= 5,
              let id = parseWindowIdString(String(parts[0])),
              let index = Int(parts[1]),
              let layout = WindowLayout.parse(String(parts[2])),
              parts[4] == "0" || parts[4] == "1"
        else { return nil }
        let visible = WindowLayout.parse(String(parts[3]))
        let name = parts.count >= 6 ? nonEmpty(String(parts[5])) : nil
        var info = WindowInfo(id: id, index: index, windowName: name)
        info.layout = layout
        info.visibleLayout = visible ?? layout
        info.isZoomed = parts[4] == "1"
        info.panes = layout.paneIds.map { PaneInfo(id: $0) }
        Self.logDiagnostic(
            "window-list fallback engaged sepHex=\(String(format: "%02x", separator.unicodeScalars.first?.value ?? 0))"
        )
        return info
    }

    private static func parsePaneListLine(_ line: String) -> PaneListEntry? {
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let windowId = parseWindowIdString(String(parts[0])),
              let paneId = parsePaneIdString(String(parts[1]))
        else { return parseSeparatorMangledPaneListLine(line) }
        let contentRect: CellRect?
        let currentCommandIndex: Int
        if parts.count >= 10,
           let left = Int(parts[3]),
           let top = Int(parts[4]),
           let width = Int(parts[5]),
           let height = Int(parts[6]) {
            contentRect = CellRect(width: width, height: height, x: left, y: top)
            currentCommandIndex = 7
        } else {
            contentRect = nil
            currentCommandIndex = 3
        }
        let currentCommand = parts.count > currentCommandIndex ? nonEmpty(String(parts[currentCommandIndex])) : nil
        let titleIndex = currentCommandIndex + 1
        let title = parts.count > titleIndex ? nonEmpty(String(parts[titleIndex])) : nil
        let hostIndex = currentCommandIndex + 2
        let host = parts.count > hostIndex ? nonEmpty(String(parts[hostIndex])) : nil
        return PaneListEntry(
            windowId: windowId,
            paneId: paneId,
            isActive: String(parts[2]) == "1",
            contentRect: contentRect,
            currentCommand: currentCommand,
            paneTitle: title,
            paneTitleIsDefault: isDefaultPaneTitle(title, host: host)
        )
    }

    /// `list-panes` reply on a separator-sanitizing host. The seven leading
    /// fixed-grammar fields (ids, active flag, geometry) never contain the
    /// separator; the trailing three (command, title, host) may. Exactly ten
    /// tokens maps unambiguously; more means a string field contained the
    /// separator, and all three are dropped rather than misassigned — split
    /// rendering needs the geometry, not the labels.
    private static func parseSeparatorMangledPaneListLine(_ line: String) -> PaneListEntry? {
        guard line.hasPrefix("@") else { return nil }
        let afterAnchor = line.dropFirst().drop(while: { ("0"..."9").contains($0) })
        guard let separator = afterAnchor.first,
              separator != "\t",
              afterAnchor.startIndex != line.index(after: line.startIndex)
        else { return nil }
        let parts = line.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count >= 10,
              let windowId = parseWindowIdString(String(parts[0])),
              let paneId = parsePaneIdString(String(parts[1])),
              parts[2] == "0" || parts[2] == "1",
              let left = Int(parts[3]),
              let top = Int(parts[4]),
              let width = Int(parts[5]),
              let height = Int(parts[6])
        else { return nil }
        let exact = parts.count == 10
        let command = exact ? nonEmpty(String(parts[7])) : nil
        let title = exact ? nonEmpty(String(parts[8])) : nil
        let host = exact ? nonEmpty(String(parts[9])) : nil
        return PaneListEntry(
            windowId: windowId,
            paneId: paneId,
            isActive: parts[2] == "1",
            contentRect: CellRect(width: width, height: height, x: left, y: top),
            currentCommand: command,
            paneTitle: title,
            paneTitleIsDefault: isDefaultPaneTitle(title, host: host)
        )
    }

    private static func parsePaneMetadata(_ line: String) -> PaneMetadata? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard let first = parts.first,
              let paneId = parsePaneIdString(String(first))
        else { return nil }
        let contentRect: CellRect?
        let currentCommand: String?
        let titleIndex: Int
        let windowNameIndex: Int
        let hostIndex: Int
        if parts.count >= 9,
           let left = Int(parts[1]),
           let top = Int(parts[2]),
           let width = Int(parts[3]),
           let height = Int(parts[4]) {
            contentRect = CellRect(width: width, height: height, x: left, y: top)
            currentCommand = parts.count > 5 ? nonEmpty(String(parts[5])) : nil
            titleIndex = 6
            windowNameIndex = 7
            hostIndex = 8
        } else {
            contentRect = nil
            currentCommand = nil
            titleIndex = 1
            windowNameIndex = 2
            hostIndex = 3
        }
        let title = parts.count > titleIndex ? nonEmpty(String(parts[titleIndex])) : nil
        let windowName = parts.count > windowNameIndex ? nonEmpty(String(parts[windowNameIndex])) : nil
        let host = parts.count > hostIndex ? nonEmpty(String(parts[hostIndex])) : nil
        return PaneMetadata(
            paneId: paneId,
            contentRect: contentRect,
            currentCommand: currentCommand,
            paneTitle: title,
            paneTitleIsDefault: isDefaultPaneTitle(title, host: host),
            windowName: windowName
        )
    }

    /// Projects the portable parser into the Apple view model. The field
    /// layout, escape decoding and default-title rule are all owned by
    /// `TmuxPaneMetadataSubscription`.
    static func parsePaneSubscriptionMetadata(
        _ value: String,
        fallbackWindowId: WindowId,
        fallbackPaneId: PaneId
    ) -> PaneSubscriptionMetadata? {
        guard let update = TmuxPaneMetadataSubscription.parse(
            value,
            fallbackWindowID: fallbackWindowId,
            fallbackPaneID: fallbackPaneId
        ) else { return nil }
        return PaneSubscriptionMetadata(
            windowId: update.windowID,
            paneId: update.paneID,
            isActive: update.isActive,
            contentRect: update.contentRect,
            currentCommand: update.currentCommand,
            paneTitle: update.paneTitle,
            paneTitleIsDefault: update.paneTitleIsDefault,
            windowName: update.windowName,
            currentPath: update.currentPath,
            agentStateJSON: update.agentStateJSON,
            isAlternateScreen: update.isAlternateScreen,
            isMouseReporting: update.isMouseReporting,
            isSgrMouse: update.isSgrMouse
        )
    }


    private func handlePaneMetadataSubscription(_ metadata: PaneSubscriptionMetadata) {
        // The pane's `@tessera_agent_state` is not read here: the shared
        // runtime collects it for the whole batch, so both platforms observe
        // one lifecycle feed instead of one each. See `deliverAgentStates`.
        guard indexOfWindow(metadata.windowId) != nil else { return }

        if let windowName = Self.nonEmpty(metadata.windowName) {
            upsertWindowName(windowName, for: metadata.windowId)
        }

        // Track every pane's title/flag, not just the active one — the wire
        // already delivers all of them, one subscription per pane.
        // This only updates the per-pane `panes[]` model; the window-level
        // `activePaneTitle` (tab label) stays gated to the active pane below.
        upsertPaneInfo(
            windowId: metadata.windowId,
            paneId: metadata.paneId,
            title: metadata.paneTitle,
            titleIsDefault: metadata.paneTitleIsDefault,
            currentCommand: metadata.currentCommand,
            isActive: metadata.isActive,
            contentRect: metadata.contentRect
        )
        paneWindowTable[metadata.paneId] = metadata.windowId
        updatePaneCurrentPath(metadata.currentPath, for: metadata.paneId)
        // After the upsert, which forgets a pane's modes when its command
        // changes: this payload read them from the server at the same moment.
        updatePaneInteractionStateIfChanged(
            paneId: metadata.paneId,
            isAlternateScreen: metadata.isAlternateScreen,
            isMouseReporting: metadata.isMouseReporting,
            isSgrMouse: metadata.isSgrMouse
        )

        let trackedActivePane = window(metadata.windowId)?.activePaneId
        guard metadata.isActive
                || trackedActivePane == metadata.paneId
                || (metadata.windowId == activeWindowId && activePaneId == metadata.paneId)
        else { return }

        updateWindowMetadata(
            windowId: metadata.windowId,
            windowName: metadata.windowName,
            activePaneId: metadata.paneId,
            activePaneTitle: metadata.paneTitle,
            activePaneTitleIsDefault: metadata.paneTitleIsDefault,
            clearTitleWhenMissing: true
        )

        if metadata.windowId == activeWindowId {
            activePaneId = metadata.paneId
        }
    }

    private func refreshActivePaneMetadataIfNeeded(
        windowId: WindowId,
        generation: Int,
        reason: String
    ) {
        let info = window(windowId)
        activePaneId = info?.activePaneId
        if let activePaneId {
            preloadTerminalDefaultColorReportIfNeeded(for: activePaneId)
        }
        if info?.activePaneId != nil, info?.activePaneTitle != nil {
            Self.logDiagnostic(
                "sidechannel metadata source=cache window=\(windowId) pane=\(String(describing: info?.activePaneId)) title='\(info?.activePaneTitle ?? "")'"
            )
            return
        }
        refreshActivePaneMetadata(
            windowId: windowId,
            generation: generation,
            reason: reason
        )
    }

    private func refreshActivePaneMetadata(
        windowId: WindowId,
        generation: Int,
        reason: String
    ) {
        guard controlPath == .sideChannel else { return }
        Self.logDiagnostic(
            "sidechannel metadata-query send window=\(windowId) generation=\(generation) reason=\(reason)"
        )
        sendControlCommand(
            "display-message -p -t \(windowId.description) '#{pane_id}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{pane_current_command}\t#{pane_title}\t#{window_name}\t#{host}'"
        ) { [weak self] result in
            guard let self,
                  self.isCurrentGeneration(generation),
                  self.activeWindowId == windowId,
                  case .success(let lines) = result,
                  let head = lines.first(where: { !$0.isEmpty }),
                  let metadata = Self.parsePaneMetadata(head)
            else {
                Self.logDiagnostic(
                    "sidechannel metadata-query stale-or-failed window=\(windowId) generation=\(generation) result='\(Self.describe(result))'"
                )
                return
            }
            self.upsertPaneInfo(
                windowId: windowId,
                paneId: metadata.paneId,
                title: metadata.paneTitle,
                titleIsDefault: metadata.paneTitleIsDefault,
                currentCommand: metadata.currentCommand,
                isActive: true,
                contentRect: metadata.contentRect
            )
            self.updateWindowMetadata(
                windowId: windowId,
                windowName: metadata.windowName,
                activePaneId: metadata.paneId,
                activePaneTitle: metadata.paneTitle,
                activePaneTitleIsDefault: metadata.paneTitleIsDefault,
                clearTitleWhenMissing: true
            )
            self.activePaneId = metadata.paneId
            Self.logDiagnostic(
                "sidechannel metadata source=query window=\(windowId) pane=\(metadata.paneId) title='\(metadata.paneTitle ?? "")'"
            )
        }
    }

    /// Parse a tmux `@<id>` window-id string into a `WindowId`.
    /// Returns nil for malformed input.
    private static func parseWindowIdString(_ s: String) -> WindowId? {
        guard s.hasPrefix("@"), let n = Int(s.dropFirst()) else { return nil }
        return WindowId(n)
    }

    // MARK: - Window-name/layout discovery (§3.2 commit C part 3)

    /// Query tmux for the actual `#{window_name}` and layout of a
    /// window we only know from a bare `%window-add`, and fold the
    /// single-line response into the window model.
    ///
    /// Used by the `.windowAdd` handler for windows that arrived
    /// without the follow-ups that would otherwise fill these in:
    /// `%window-renamed` never fires for `new-window -n NAME`, and
    /// `%layout-change` never fires for window creation at all
    /// (verified via pty probe against tmux 3.6) — layout only
    /// arrives on later splits/resizes.
    ///
    /// Field order matches the attach-init `list-windows` format:
    /// fixed-grammar fields first, `#{window_name}` LAST, because a
    /// tab embedded in a window name must not shift the layout columns.
    ///
    /// The completion is defensive on three axes:
    ///   - **Window may have been removed** between query and reply
    ///     (e.g. user killed the window). Skip silently.
    ///   - **Name may have been updated** by a real `%window-renamed`
    ///     that arrived between query and reply. Don't overwrite a
    ///     confirmed name with our (potentially stale) response —
    ///     only update when the entry is still on the placeholder.
    ///   - **Layout may have been updated** by a real `%layout-change`
    ///     (e.g. an immediate split). That notification is fresher —
    ///     only apply the response when the layout is still unknown.
    /// Pane titles are tracked separately and remain the preferred
    /// display label when present.
    private func queryWindowDetails(windowId: WindowId) {
        // Command grammar and reply parser both live in the shared core, so
        // Android asks the same question and reads the same answer. The core's
        // own runtime folds this tagged reply into the shared snapshot on its
        // way past; the completion below only mirrors it into this
        // controller's legacy window model.
        sendControlCommand(
            TmuxRuntimeHydrationQuery.windowDetailsCommand(windowID: windowId)
        ) { [weak self] result in
            guard let self else { return }
            // The query answered (or failed/cancelled) — the pane count is
            // no longer provisionally pending on this reply. Decrement, not
            // remove: a close + re-add of the same id can overlap a second
            // query whose reply is still owed.
            if let inFlight = self.windowLayoutQueriesInFlight[windowId] {
                if inFlight <= 1 {
                    self.windowLayoutQueriesInFlight.removeValue(forKey: windowId)
                } else {
                    self.windowLayoutQueriesInFlight[windowId] = inFlight - 1
                }
            }
            guard case .success(let lines) = result,
                  let details = TmuxRuntimeHydrationQuery.windowDetails(lines: lines),
                  case let queried = details.window,
                  queried.id == windowId,
                  let idx = self.windows.firstIndex(where: { $0.id == windowId })
            else { return }
            if let index = queried.index {
                self.windows[idx].index = index
            }
            // A real `%layout-change` that arrived while this query was in
            // flight is fresher; only apply the reply when layout is still
            // unknown.
            if self.windows[idx].layout == nil, let layout = details.rawLayout {
                // handleLayoutChange owns the downstream consequences
                // (pane merge, pane→window table, mosh pane border),
                // exactly as if tmux had notified us.
                self.handleLayoutChange(
                    windowId: windowId,
                    layout: layout,
                    visibleLayout: details.rawVisibleLayout,
                    rawFlags: queried.isZoomed ? "Z" : nil
                )
            }
            // Don't overwrite a confirmed name from a real `%window-renamed`
            // that landed between query and reply.
            if let name = queried.name,
               let idx = self.windows.firstIndex(where: { $0.id == windowId }),
               self.windows[idx].windowName == nil {
                self.windows[idx].windowName = name
            }
            self.publishWindowMetadataToCore(windowId)
            self.projectCoreSnapshot()
        }
    }


    typealias RenderedPaneState = TmuxRenderedPaneState

    /// Parse the body line of the inline render metadata query.
    /// Expected format:
    /// `renderedPaneMetadataFormat`, with the seven-field legacy prefix
    /// still accepted.
    ///
    /// `alternate_on` must stay at index 6; capping maxSplits would merge
    /// all appended fields into it and make alt-screen detection fail.
    static func parseRenderedPaneState(_ line: String) -> RenderedPaneState? {
        TmuxRenderedPaneStateParser.parse(line)
    }

    /// Parse a tmux `%<id>` pane-id string into a `PaneId`.
    /// Returns nil for malformed input.
    private static func parsePaneIdString(_ string: String) -> PaneId? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("%"), let raw = Int(trimmed.dropFirst()) else { return nil }
        return PaneId(raw)
    }

    private static func logDiagnostic(_ message: @autoclosure () -> String) {
        TmuxDiagnostics.sink?(message())
    }

    private static func describe(_ result: Result<[String], CommandError>) -> String {
        switch result {
        case .success(let lines):
            return "success lines=\(lines.count)"
        case .failure(let error):
            return "failure \(error)"
        }
    }

    /// Verbose shape of a command response for failure diagnostics: per-line tab
    /// field count, length, and an escaped, length-bounded preview. Distinguishes
    /// "tmux returned an empty payload" (the post-foreground-restore symptom)
    /// from "a valid-but-unparseable line" or "a desynced response that belongs
    /// to a different command".
    private static func describeMetadataResponse(_ result: Result<[String], CommandError>) -> String {
        switch result {
        case .failure(let error):
            return "failure(\(error))"
        case .success(let lines):
            guard !lines.isEmpty else { return "empty(0 lines)" }
            return lines.prefix(2).enumerated().map { idx, line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).count
                var preview = ""
                for scalar in line.unicodeScalars.prefix(140) {
                    switch scalar {
                    case "\u{1B}": preview += "\\e"
                    case "\t": preview += "\\t"
                    case "\r": preview += "\\r"
                    case "\n": preview += "\\n"
                    default: preview.unicodeScalars.append(scalar)
                    }
                }
                return "[\(idx)]fields=\(fields) len=\(line.count) raw='\(preview)'"
            }.joined(separator: " ")
        }
    }

    private static func commandCategory(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let head = trimmed.split(separator: " ").first else {
            return "empty"
        }
        switch head {
        case "capture-pane":
            return "capture-pane"
        case "display-message":
            return "display-message"
        case "list-windows":
            return "list-windows"
        case "list-panes":
            return "list-panes"
        case "refresh-client":
            return "refresh-client"
        case "send-keys":
            return "send-keys"
        case "select-window", "select-pane":
            return "select"
        case "new-window", "neww":
            return "new-window"
        case "kill-window", "kill-pane":
            return "kill"
        case "split-window", "splitw":
            return "split"
        case "resize-pane", "resize-window":
            return "resize"
        default:
            return "other"
        }
    }
}

private extension TmuxGridAuthoritySnapshot {
    var isMine: Bool {
        if case .mine = self { return true }
        return false
    }
}
