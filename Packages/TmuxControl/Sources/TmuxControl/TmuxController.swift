import Foundation
import Observation

public enum TmuxDiagnostics {
    public static var sink: ((String) -> Void)?
}

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

    enum RenderStage: Equatable, Sendable {
        case viewport
        /// Refresh the already-rendered window/pane in place. Unlike a real
        /// window swap, this must not clear and rebuild local scrollback.
        case viewportOnly
        case deep
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

        public var displayName: String {
            (activePaneTitleIsDefault ? nil : Self.nonEmpty(activePaneTitle))
                ?? Self.nonEmpty(windowName)
                ?? id.description
        }

        /// Compatibility for existing UI call sites; prefer
        /// `displayName` in new code.
        public var name: String { displayName }

        /// Number of panes the window holds. Uses the FULL layout so a zoomed
        /// multi-pane window still reports >1.
        public var paneCount: Int { layout?.paneCount ?? max(1, panes.count) }

        /// True when this window must mount the pane grid rather than render
        /// through the shared single-pane terminal. Uses the FULL layout (not
        /// `visibleLayout`) so a zoomed multi-pane window stays in grid mode.
        /// Fail-open: a `nil` layout (pre-hydration) renders single-pane.
        public var rendersAsPaneGrid: Bool { (layout?.paneCount ?? 1) > 1 }

        public init(
            id: WindowId,
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

    public struct ScrollbackCapture: Equatable, Sendable {
        public let paneId: PaneId
        public let requestedDepth: Int
        public let historySize: Int?
        public let capturedLineCount: Int
        public let repaintBytes: [UInt8]

        public init(
            paneId: PaneId,
            requestedDepth: Int,
            historySize: Int?,
            capturedLineCount: Int,
            repaintBytes: [UInt8]
        ) {
            self.paneId = paneId
            self.requestedDepth = requestedDepth
            self.historySize = historySize
            self.capturedLineCount = capturedLineCount
            self.repaintBytes = repaintBytes
        }
    }

    public enum ScrollbackCaptureSkipReason: Equatable, Sendable {
        case notInTmux
        case noActivePane
        case stale
        case metadataUnavailable
        case alternateScreen
        case captureFailed
    }

    public enum ScrollbackCaptureResult: Equatable, Sendable {
        case captured(ScrollbackCapture)
        case skipped(ScrollbackCaptureSkipReason)
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

    /// True only after this control connection has completed an authoritative
    /// `list-windows` response. Side-channel reconnects keep stale tabs visible,
    /// but targeted commands must remain blocked until this flips back to true.
    public private(set) var isWindowListHydrated = false

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
    @ObservationIgnored private var parser = TmuxControlParser()
    @ObservationIgnored private var dcsBuffer: [UInt8] = []
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

    /// Lines accumulated between the most recent `%begin` and the next
    /// `%end` / `%error`. Drained and handed to the head completion
    /// when the terminator arrives.
    @ObservationIgnored private var inflightLines: [String] = []

    /// Last-known client size (cols × rows). Refreshed by
    /// `updateClientSize(cols:rows:)` from the outer view whenever
    /// SwiftTerm's `sizeChanged` delegate fires. Used both to push
    /// `refresh-client -C` to tmux while in control mode *and* to
    /// send the current size as soon as we enter tmux mode — the
    /// PTY-level SIGWINCH the SSH session sends is ignored by tmux
    /// in `-CC`, so without this the pane stays at whatever size the
    /// PTY happened to be at the moment `tmux -CC` was launched.
    @ObservationIgnored private var lastKnownSize: (cols: Int, rows: Int)?

    /// Monotonic state epoch used to ignore stale attach, reconnect,
    /// window-switch, and capture callbacks. Every authoritative
    /// tmux-focus transition advances it before queueing new queries.
    @ObservationIgnored private var stateGeneration: Int = 0

    /// The tmux session id (`$N`) this controller is attached to.
    ///
    /// tmux runs ONE server per user; multiple sessions live inside it.
    /// A `-CC` control client receives some notifications scoped to its
    /// own session (tmux filters those server-side) but a few — notably
    /// `%session-window-changed` and the `%*` pane-metadata subscription
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

    /// Inline render refresh currently waiting on tmux responses.
    /// All stages block direct `%output` presentation until their capture
    /// repaint lands. Foreground repairs retain same-pane output separately and
    /// flush it as one atomic batch immediately before the authoritative
    /// viewport repaint, preserving local scrollback without presenting every
    /// queued redraw frame on the way to the current screen.
    @ObservationIgnored private var pendingRenderRefresh: (
        windowId: WindowId,
        generation: Int,
        stage: RenderStage
    )?

    /// App-background and foreground-capture output barrier. iPadOS can resume
    /// the SSH read path while the app is still inactive, before the foreground
    /// capture is issued. Buffering from the inactive edge closes that gap.
    /// Bytes remain partitioned by pane so a grid can flush each surface into
    /// its own terminal model. Below the safety cap, buffered bytes are fed
    /// synchronously and then the captured viewport is painted in the same
    /// main-actor turn, so SwiftTerm keeps the output in scrollback but Core
    /// Animation can only present the final frame. If the cap is exceeded, the
    /// whole retained stream for that pane is discarded (never a partial escape
    /// sequence) and the authoritative viewport capture supplies visible truth.
    @ObservationIgnored private var isForegroundOutputCoalescing = false
    @ObservationIgnored private var appIsInactive = false
    @ObservationIgnored private var awaitingAppForegroundRefresh = false
    @ObservationIgnored private var foregroundOutputRefreshGeneration: Int?
    @ObservationIgnored private var coalescedForegroundOutput: [PaneId: [UInt8]] = [:]
    @ObservationIgnored private var coalescedForegroundOutputByteCount = 0
    @ObservationIgnored private var foregroundOutputOverflowedPanes: Set<PaneId> = []
    @ObservationIgnored private var foregroundPaneRefreshTargets: [PaneId: Int] = [:]
    @ObservationIgnored private var foregroundPaneRetryTasks: [PaneId: Task<Void, Never>] = [:]
    @ObservationIgnored private var foregroundPaneRetryAttempts: [PaneId: Int] = [:]
    @ObservationIgnored private var pausedPanes: Set<PaneId> = []
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

    /// Panes whose capture-repaint is in flight. Live `%output` for the pane is
    /// dropped until the repaint lands (per-pane analog of `pendingRenderRefresh`
    /// for the shared swap), so stale bytes can't bleed in ahead of the capture.
    @ObservationIgnored private var pendingPaneRefreshes: [PaneId: Int] = [:]
    @ObservationIgnored private var paneRefreshSequence = 0

    /// Panes that have already had a full deep capture since becoming visible.
    /// Drives deep-on-first-focus: siblings render shallow on swap-in and
    /// upgrade to a deep capture the first time they are focused.
    @ObservationIgnored private var deepRefreshedPanes: Set<PaneId> = []

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

    static let paneMetadataSubscriptionName = "tessera-pane-meta"
    private static let bellSubscriptionName = "tessera-bell"
    static let paneMetadataSubscriptionFormat = [
        "#{window_id}",
        "#{pane_id}",
        "#{pane_active}",
        "#{pane_left}",
        "#{pane_top}",
        "#{pane_width}",
        "#{pane_height}",
        "#{pane_current_command}",
        "#{pane_title}",
        "#{window_name}",
        "#{host}",
        "#{pane_current_path}",
        "#{@tessera_agent_state}",
    ].joined(separator: "\t")
    static let renderedPaneMetadataFormat = [
        "#{pane_id}",
        "#{cursor_x}",
        "#{cursor_y}",
        "#{pane_title}",
        "#{window_name}",
        "#{host}",
        "#{alternate_on}",
        "#{history_size}",
        "#{scroll_region_upper}",
        "#{scroll_region_lower}",
        "#{cursor_flag}",
        "#{insert_flag}",
        "#{keypad_cursor_flag}",
        "#{keypad_flag}",
        "#{wrap_flag}",
        "#{mouse_standard_flag}",
        "#{mouse_button_flag}",
        "#{mouse_all_flag}",
        "#{mouse_sgr_flag}",
        "#{origin_flag}",
        "#{alternate_saved_x}",
        "#{alternate_saved_y}",
    ].joined(separator: "\t")

    /// False immediately after DCS entry; the first server-originated
    /// `%end` frame (flags bit0 clear) completes the control-mode
    /// handshake and starts attach hydration.
    @ObservationIgnored private var attachInitFlushed = false
    @ObservationIgnored private var allowUngatedLatchFallback = false
    /// A post-attach window swap whose authoritative capture has not landed.
    /// While true, incremental `%output` must not latch a pane over the stale
    /// full-screen image; only a successful capture-repaint clears the gate.
    @ObservationIgnored private var establishedRenderIsFailClosed = false
    @ObservationIgnored private var initialRenderWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var renderRetryTask: Task<Void, Never>?
    @ObservationIgnored private var renderCommandQueueWaitTask: Task<Void, Never>?
    @ObservationIgnored private var renderRetryAttemptsByGeneration: [Int: Int] = [:]

    private struct PendingCommand {
        let sequence: Int
        let command: String
        let completion: (Result<[String], CommandError>) -> Void
    }

    /// Opaque per-controller tag. Diagnostics exports can contain several live
    /// sessions whose lines otherwise look identical after endpoint redaction.
    private let diagnosticID = String(UUID().uuidString.prefix(8))

    /// Called with bytes destined for the terminal renderer.
    /// Set by the owner after construction; nil by default.
    @ObservationIgnored public var feedTerminal: ((ArraySlice<UInt8>) -> Void)?

    /// Called with bytes destined for the SSH channel upstream.
    /// Set by the owner after construction; nil by default.
    @ObservationIgnored public var sendBytes: (([UInt8]) -> Void)?

    /// Called with decoded `%output` bytes before renderer routing so the
    /// owner can synthesize terminal replies without waiting on the
    /// rendered terminal view's delegate round trip.
    @ObservationIgnored public var terminalResponseForOutput: ((_ paneId: PaneId, _ data: ArraySlice<UInt8>) -> [UInt8]?)?

    /// Fired just before the shared terminal is repainted with a different
    /// window's content. Parameters: the previously rendered window (nil on
    /// the first swap after attach), the window about to be rendered, and
    /// whether tmux reports the incoming pane is in the alternate screen.
    @ObservationIgnored public var displayWillSwap: ((_ from: WindowId?, _ to: WindowId, _ paneInAltScreen: Bool) -> Void)?
    /// Fired after the repaint bytes for `windowId` have been fed and the
    /// rendered ids committed. App layer uses it to re-run find and restore
    /// per-window client-side modes.
    @ObservationIgnored public var displayDidSwap: ((_ windowId: WindowId) -> Void)?
    /// Fired after an already-rendered pane is repaired in place. Unlike
    /// `displayDidSwap`, this must not restore per-window modes; the app uses it
    /// only to refresh derived viewport state such as Find matches.
    @ObservationIgnored public var displayDidRefresh: ((_ windowId: WindowId) -> Void)?
    /// App-layer answer to "is the shared SwiftTerm terminal currently on
    /// the alternate-screen buffer". Consulted when assembling repaints.
    @ObservationIgnored public var terminalIsInAltScreen: (() -> Bool)?
    /// History depth (lines) for the deep repaint stage (wired next).
    public var deepRepaintHistoryDepth: Int = 2000

    public var initialRenderWatchdogInterval: TimeInterval = 4.0
    public var renderRefreshRetryDelay: TimeInterval = 0.5

    /// Hard cap for output retained across inactive→foreground recovery.
    /// Normal Codex redraw bursts stay well below this (the live regression is
    /// ~288 KiB). On overflow we discard that pane's whole retained stream —
    /// never a truncated escape sequence — and trust the viewport capture for
    /// visible truth, avoiding unbounded memory and multi-second parser stalls.
    public var maxForegroundOutputBytes = 512 * 1024

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

    @ObservationIgnored public var onBell: ((_ windowID: Int, _ isActiveWindow: Bool, _ windowName: String?) -> Void)?

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

    /// Retained semantic Agent Center state published by a remote hook as a
    /// pane user option. Format subscriptions replay this value to a fresh
    /// control client after app/session restoration.
    @ObservationIgnored public var paneAgentStateObserver: ((_ paneId: PaneId, _ json: String) -> Void)?

    /// User-originated bytes routed through this controller. Agent Center uses
    /// this only to resolve an already-known blocking prompt immediately; it
    /// never treats arbitrary typing as evidence of agent activity.
    @ObservationIgnored public var inputObserver: ((_ paneId: PaneId?, _ bytes: [UInt8]) -> Void)?

    public init(controlPath: ControlPath = .inline) {
        self.controlPath = controlPath
    }

    // MARK: - Public API

    /// Feed a chunk of bytes received from the SSH output stream.
    /// Routes them to the terminal (passthrough) or into the tmux
    /// parser (tmux mode). Handles DCS boundary detection.
    public func ingest(_ chunk: [UInt8]) {
        switch mode {
        case .passthrough:
            handlePassthrough(chunk)
        case .tmuxControl:
            let messages = parser.feed(chunk)
            process(messages: messages)
        }
    }

    // MARK: - Pane grid rendering (multi-pane windows)

    /// The set of panes currently rendered through their own per-pane sink
    /// (i.e. the mounted grid). Empty when no grid is mounted.
    public var renderingPaneIds: Set<PaneId> { Set(paneSinks.keys) }

    /// Register (or, with `nil`, unregister) the render sink for a pane. The
    /// app calls this when mounting/dismantling a pane surface in the grid.
    /// Registering does NOT auto-repaint — the app follows with `refreshPane`.
    public func setPaneSink(_ paneId: PaneId, _ sink: ((ArraySlice<UInt8>) -> Void)?) {
        if let sink {
            paneSinks[paneId] = sink
        } else {
            paneSinks.removeValue(forKey: paneId)
            pendingPaneRefreshes.removeValue(forKey: paneId)
            deepRefreshedPanes.remove(paneId)
            discardCoalescedForegroundOutput(for: paneId)
            foregroundPaneRefreshTargets.removeValue(forKey: paneId)
            foregroundPaneRetryTasks.removeValue(forKey: paneId)?.cancel()
            foregroundPaneRetryAttempts.removeValue(forKey: paneId)
            if isForegroundOutputCoalescing,
               !awaitingAppForegroundRefresh,
               foregroundOutputRefreshGeneration == nil,
               foregroundPaneRefreshTargets.isEmpty {
                endForegroundOutputCoalescing()
            }
        }
    }

    /// Drop every pane sink — used when the grid unmounts (window collapses to
    /// a single pane, or the session resets) so output falls back to the
    /// shared single-pane path.
    public func clearAllPaneSinks() {
        let removedPaneIds = Set(paneSinks.keys)
        paneSinks.removeAll()
        pendingPaneRefreshes.removeAll()
        deepRefreshedPanes.removeAll()
        for paneId in removedPaneIds {
            discardCoalescedForegroundOutput(for: paneId)
            foregroundPaneRefreshTargets.removeValue(forKey: paneId)
            foregroundPaneRetryTasks.removeValue(forKey: paneId)?.cancel()
            foregroundPaneRetryAttempts.removeValue(forKey: paneId)
        }
        // A grid can collapse while the app is inactive. Keep the lifecycle
        // barrier armed in that case; the foreground shared-surface refresh
        // will take ownership and release it. Once foreground recovery is
        // already running, unmounting the target grid invalidates its buffers.
        if isForegroundOutputCoalescing,
           !awaitingAppForegroundRefresh,
           foregroundOutputRefreshGeneration == nil {
            endForegroundOutputCoalescing()
        }
    }

    /// Capture pane `%P`'s current screen (and scrollback) from tmux and
    /// repaint it into its registered sink. The per-pane analog of
    /// `refreshRenderedWindow`, sharing `RepaintAssembly` for byte-identical
    /// output. `deep` requests the full scrollback capture; a shallow refresh
    /// (viewport only) is used for swap-in siblings and upgraded to deep on
    /// first focus. No-op if the pane has no sink or we're not inline.
    ///
    /// Deep runs AT MOST ONCE per pane mount (`deepRefreshedPanes`): the
    /// repaint stream's `ESC[2J` clears only the visible screen, so a deep
    /// repaint's history lines APPEND to the client's local scrollback.
    /// That's correct exactly once, into a freshly mounted (near-empty)
    /// buffer; after that the sink's live `%output` keeps history current
    /// and every further repaint must be viewport-only or each focus
    /// switch/foreground restore would stack another full copy of history
    /// into local scrollback.
    public func refreshPane(paneId: PaneId, deep: Bool = true) {
        let inheritsForegroundRecovery = isForegroundOutputCoalescing
            && !awaitingAppForegroundRefresh
            && paneWindowTable[paneId] == activeWindowId
            && activeWindowId.flatMap { window($0)?.rendersAsPaneGrid } == true
        refreshPane(
            paneId: paneId,
            deep: deep,
            foregroundRecovery: inheritsForegroundRecovery
        )
    }

    private func refreshPane(
        paneId: PaneId,
        deep: Bool,
        foregroundRecovery: Bool
    ) {
        guard controlPath == .inline, paneSinks[paneId] != nil else { return }
        if awaitingAppForegroundRefresh, !foregroundRecovery { return }
        let wantsDeep = deep && !deepRefreshedPanes.contains(paneId)
        paneRefreshSequence &+= 1
        let requestID = paneRefreshSequence
        pendingPaneRefreshes[paneId] = requestID
        if foregroundRecovery {
            foregroundPaneRetryTasks.removeValue(forKey: paneId)?.cancel()
            foregroundPaneRefreshTargets[paneId] = requestID
            if !pendingCommands.isEmpty {
                waitForCommandQueueBeforeForegroundPaneRender(
                    paneId: paneId,
                    requestID: requestID,
                    deep: deep
                )
                return
            }
        }
        let target = paneId.description
        sendControlCommand(
            "display-message -p -t \(target) '\(Self.renderedPaneMetadataFormat)'"
        ) { [weak self] result in
            guard let self else { return }
            if self.awaitingAppForegroundRefresh {
                if self.pendingPaneRefreshes[paneId] == requestID {
                    self.pendingPaneRefreshes.removeValue(forKey: paneId)
                }
                return
            }
            guard self.paneSinks[paneId] != nil,
                  self.pendingPaneRefreshes[paneId] == requestID,
                  case .success(let lines) = result,
                  let head = lines.first(where: { !$0.isEmpty }),
                  let state = Self.parseRenderedPaneState(head)
            else {
                self.failPaneRefresh(paneId: paneId, requestID: requestID)
                return
            }
            self.capturePane(paneId: paneId, state: state, requestID: requestID, deep: wantsDeep)
        }
    }

    private func capturePane(
        paneId: PaneId,
        state: RenderedPaneState,
        requestID: Int,
        deep: Bool
    ) {
        let target = paneId.description
        let depth = deep ? max(0, deepRepaintHistoryDepth) : 0

        if state.paneInAltScreen {
            // history → saved primary → alt-screen viewport (mirrors the shared
            // captureDeepAltScreen chain, pane-targeted).
            let captureAlt: ([String], [String]) -> Void = { [weak self] history, savedPrimary in
                guard let self else { return }
                self.sendPaneCapture(
                    "capture-pane -p -e -N -t \(target)",
                    paneId: paneId, requestID: requestID
                ) { altLines in
                    self.finishPaneRefresh(
                        paneId: paneId, state: state, requestID: requestID,
                        captureLines: altLines, historyLines: history,
                        savedPrimaryLines: savedPrimary, altScreenLines: altLines, deep: deep
                    )
                }
            }
            let captureSavedPrimary: ([String]) -> Void = { [weak self] history in
                guard let self else { return }
                self.sendPaneCapture(
                    "capture-pane -p -e -N -a -q -t \(target)",
                    paneId: paneId, requestID: requestID
                ) { savedPrimary in
                    captureAlt(history, savedPrimary)
                }
            }
            if deep, (state.historySize ?? 0) > 0 {
                sendPaneCapture(
                    "capture-pane -p -e -N -S -\(depth) -E -1 -t \(target)",
                    paneId: paneId, requestID: requestID
                ) { history in
                    captureSavedPrimary(history)
                }
            } else {
                captureSavedPrimary([])
            }
            return
        }

        let command = deep
            ? "capture-pane -p -e -N -S -\(depth) -t \(target)"
            : "capture-pane -p -e -N -t \(target)"
        sendPaneCapture(command, paneId: paneId, requestID: requestID) { [weak self] lines in
            self?.finishPaneRefresh(
                paneId: paneId, state: state, requestID: requestID,
                captureLines: lines, historyLines: [], savedPrimaryLines: [],
                altScreenLines: nil, deep: deep
            )
        }
    }

    private func sendPaneCapture(
        _ command: String,
        paneId: PaneId,
        requestID: Int,
        onSuccess: @escaping ([String]) -> Void
    ) {
        sendControlCommand(command) { [weak self] result in
            guard let self else { return }
            guard self.paneSinks[paneId] != nil,
                  self.pendingPaneRefreshes[paneId] == requestID,
                  case .success(let lines) = result
            else {
                self.failPaneRefresh(paneId: paneId, requestID: requestID)
                return
            }
            onSuccess(lines)
        }
    }

    private func finishPaneRefresh(
        paneId: PaneId,
        state: RenderedPaneState,
        requestID: Int,
        captureLines: [String],
        historyLines: [String],
        savedPrimaryLines: [String],
        altScreenLines: [String]?,
        deep: Bool
    ) {
        guard let sink = paneSinks[paneId],
              pendingPaneRefreshes[paneId] == requestID
        else {
            failPaneRefresh(paneId: paneId, requestID: requestID)
            return
        }
        if awaitingAppForegroundRefresh {
            pendingPaneRefreshes.removeValue(forKey: paneId)
            return
        }
        let completesForegroundRecovery = foregroundPaneRefreshTargets[paneId] == requestID
        if completesForegroundRecovery {
            let retainedOutput = takeCoalescedForegroundOutput(for: paneId)
            if !retainedOutput.bytes.isEmpty {
                sink(ArraySlice(retainedOutput.bytes))
            }
        }
        // A pane surface starts on the normal buffer at mount, but live
        // %output (a TUI's 1049h) moves it — ask the app for the CURRENT
        // local buffer so the assembler emits ?1049l first when needed
        // (see paneLocalAltScreenProbe). The scroll region is pane-relative,
        // so don't suppress it (clientRows=nil).
        let bytes = RepaintAssembly.assemble(
            state: state,
            captureLines: captureLines,
            historyLines: historyLines,
            savedPrimaryLines: savedPrimaryLines,
            altScreenLines: altScreenLines,
            terminalIsInAltScreen: paneLocalAltScreenProbe?(paneId) ?? false,
            clientRows: nil
        )
        let tailContentLines = state.paneInAltScreen ? (altScreenLines ?? captureLines) : captureLines
        if RepaintAssembly.backgroundLeftOpen(in: tailContentLines) {
            Self.logDiagnostic(
                "repaint-bg-open pane=\(paneId) stage=\(deep ? "deep" : "viewport") paneAlt=\(state.paneInAltScreen) lines=\(tailContentLines.count)"
            )
        }
        let paneCaptureMaxCols = tailContentLines.reduce(0) { max($0, RepaintAssembly.visibleColumns(in: $1)) }
        Self.logDiagnostic(
            "repaint-width pane=\(paneId) clientCols=\(lastKnownSize?.cols ?? -1) clientRows=\(lastKnownSize?.rows ?? -1) captureMaxCols=\(paneCaptureMaxCols) captureRows=\(tailContentLines.count) cursorX=\(state.cursorX) cursorY=\(state.cursorY) stage=\(deep ? "deep" : "viewport")"
        )
        sink(ArraySlice(bytes))
        pendingPaneRefreshes.removeValue(forKey: paneId)
        if deep { deepRefreshedPanes.insert(paneId) }
        if pausedPanes.contains(paneId) {
            resumePausedPane(paneId)
        }
        if paneWindowTable[paneId] == activeWindowId {
            markInitialRenderReady()
        }
        paneDidRefresh?(paneId)
        foregroundPaneRetryTasks.removeValue(forKey: paneId)?.cancel()
        foregroundPaneRetryAttempts.removeValue(forKey: paneId)
        finishForegroundPaneRefresh(paneId, requestID: requestID)
    }

    private func failPaneRefresh(paneId: PaneId, requestID: Int) {
        if pendingPaneRefreshes[paneId] == requestID {
            pendingPaneRefreshes.removeValue(forKey: paneId)
        }
        if foregroundPaneRefreshTargets[paneId] == requestID {
            // Keep the pane fail-closed and retain its output until an
            // authoritative capture succeeds. Reopening live output here
            // recreates the stale-grid/sliver failure seen on shared surfaces.
            scheduleForegroundPaneRefreshRetry(paneId: paneId, requestID: requestID)
            return
        }
        finishForegroundPaneRefresh(paneId, requestID: requestID)
    }

    private func scheduleForegroundPaneRefreshRetry(paneId: PaneId, requestID: Int) {
        let attempt = (foregroundPaneRetryAttempts[paneId] ?? 0) + 1
        foregroundPaneRetryAttempts[paneId] = attempt
        foregroundPaneRetryTasks.removeValue(forKey: paneId)?.cancel()
        let delay = renderRefreshRetryDelay * Double(min(attempt, 6))
        Self.logDiagnostic(
            "foreground-pane retry scheduled pane=\(paneId) request=\(requestID) attempt=\(attempt) delay=\(delay)"
        )
        foregroundPaneRetryTasks[paneId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.isForegroundOutputCoalescing,
                      !self.awaitingAppForegroundRefresh,
                      self.foregroundPaneRefreshTargets[paneId] == requestID,
                      self.paneSinks[paneId] != nil
                else { return }
                self.foregroundPaneRetryTasks.removeValue(forKey: paneId)
                self.refreshPane(
                    paneId: paneId,
                    deep: paneId == self.activePaneId,
                    foregroundRecovery: true
                )
            }
        }
    }

    private func waitForCommandQueueBeforeForegroundPaneRender(
        paneId: PaneId,
        requestID: Int,
        deep: Bool
    ) {
        foregroundPaneRetryTasks.removeValue(forKey: paneId)?.cancel()
        Self.logDiagnostic(
            "foreground-pane wait-command-queue controller=\(diagnosticID) pane=\(paneId) request=\(requestID) pending=\(pendingCommands.count)"
        )
        foregroundPaneRetryTasks[paneId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.foregroundPaneRetryTasks.removeValue(forKey: paneId)
                guard self.isForegroundOutputCoalescing,
                      !self.awaitingAppForegroundRefresh,
                      self.foregroundPaneRefreshTargets[paneId] == requestID,
                      self.paneSinks[paneId] != nil
                else { return }
                self.refreshPane(
                    paneId: paneId,
                    deep: deep,
                    foregroundRecovery: true
                )
            }
        }
    }

    /// Send typed bytes upstream. In passthrough mode, bytes flow
    /// straight to the SSH channel. In tmux mode, they become a
    /// `send-keys -t %<pane> -H <hex>` command targeting the active
    /// pane — hex encoding guarantees safe UTF-8 / control-char transit
    /// through the tmux command parser.
    public func sendInput(_ bytes: [UInt8]) {
        switch mode {
        case .passthrough:
            if !bytes.isEmpty { inputObserver?(nil, bytes) }
            sendBytes?(bytes)
        case .tmuxControl:
            guard let pane = activePaneId else { return }
            guard !bytes.isEmpty else { return }
            inputObserver?(pane, bytes)
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            sendControlCommand("send-keys -t \(pane.description) -H \(hex)")
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
        sendControlCommand(command, completion: completion)
    }

    public var isAuthoritativeRenderRefreshPending: Bool {
        pendingRenderRefresh != nil
            || isForegroundOutputCoalescing
            || establishedRenderIsFailClosed
    }

    private func enqueueControlCommand(
        _ command: String,
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

        nextCommandSequence &+= 1
        let entry = PendingCommand(
            sequence: nextCommandSequence,
            command: command,
            completion: completion
        )
        transmitControlCommand(entry)
    }

    private func transmitControlCommand(_ entry: PendingCommand) {
        pendingCommands.append(entry)
        Self.logDiagnostic(
            "command-transmit controller=\(diagnosticID) sequence=\(entry.sequence) wirePending=\(pendingCommands.count) commandCategory=\(Self.commandCategory(entry.command))"
        )
        let command = entry.command
        let line = command.hasSuffix("\n") ? command : command + "\n"
        sendBytes?(Array(line.utf8))
    }

    /// Capture the active pane's normal-buffer viewport plus a bounded slice of
    /// server-side tmux history and return terminal repaint bytes that seed a
    /// local SwiftTerm scrollback buffer. This is used by the mosh side-channel:
    /// mosh itself synchronizes only the visible screen, so local scrollback has
    /// to be synthesized from tmux on demand.
    public func captureActivePrimaryPaneScrollback(
        depth: Int,
        clientRows: Int? = nil,
        completion: @escaping (ScrollbackCapture?) -> Void
    ) {
        captureActivePrimaryPaneScrollbackResult(
            depth: depth,
            clientRows: clientRows
        ) { result in
            if case .captured(let capture) = result {
                completion(capture)
            } else {
                completion(nil)
            }
        }
    }

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

    public func captureActivePrimaryPaneScrollbackResult(
        depth: Int,
        clientRows: Int? = nil,
        completion: @escaping (ScrollbackCaptureResult) -> Void
    ) {
        guard mode == .tmuxControl else {
            Self.logDiagnostic("scrollback-capture skipped reason=not-in-tmux")
            completion(.skipped(.notInTmux))
            return
        }

        guard let paneId = activePaneId ?? activeWindowId.flatMap({ window($0)?.activePaneId }) else {
            Self.logDiagnostic("scrollback-capture skipped reason=no-active-pane")
            completion(.skipped(.noActivePane))
            return
        }

        let requestedDepth = max(0, depth)
        let generation = stateGeneration
        let target = paneId.description
        Self.logDiagnostic(
            "scrollback-capture metadata send pane=\(paneId) depth=\(requestedDepth) generation=\(generation)"
        )

        sendControlCommand(
            "display-message -p -t \(target) '\(Self.renderedPaneMetadataFormat)'"
        ) { [weak self] result in
            guard let self else { return }
            guard self.isCurrentGeneration(generation),
                  self.activePaneId == paneId || self.activeWindowId.flatMap({ self.window($0)?.activePaneId }) == paneId
            else {
                Self.logDiagnostic(
                    "scrollback-capture metadata stale pane=\(paneId) generation=\(generation) result='\(Self.describe(result))'"
                )
                completion(.skipped(.stale))
                return
            }

            guard case .success(let lines) = result,
                  let head = lines.first(where: { !$0.isEmpty }),
                  let state = Self.parseRenderedPaneState(head)
            else {
                Self.logDiagnostic(
                    "scrollback-capture metadata failed pane=\(paneId) generation=\(generation) result='\(Self.describe(result))'"
                )
                completion(.skipped(.metadataUnavailable))
                return
            }

            self.updatePaneInteractionState(
                paneId: paneId,
                isAlternateScreen: state.paneInAltScreen,
                isMouseReporting: state.isMouseReporting,
                isSgrMouse: state.mouseSgr
            )

            guard !state.paneInAltScreen else {
                Self.logDiagnostic(
                    "scrollback-capture skipped reason=alt-screen pane=\(paneId) generation=\(generation)"
                )
                completion(.skipped(.alternateScreen))
                return
            }

            self.sendScrollbackCaptureCommand(
                paneId: paneId,
                state: state,
                requestedDepth: requestedDepth,
                generation: generation,
                clientRows: clientRows,
                completion: completion
            )
        }
    }

    private func sendScrollbackCaptureCommand(
        paneId: PaneId,
        state: RenderedPaneState,
        requestedDepth: Int,
        generation: Int,
        clientRows: Int?,
        completion: @escaping (ScrollbackCaptureResult) -> Void
    ) {
        let target = paneId.description
        // Preserve tmux's hard-wrapped row geometry. `-J` would join wrapped
        // rows and can drop colored trailing blanks; the local SwiftTerm
        // surface already has the same width we pushed to tmux via
        // `updateClientSize`, so raw rows make the live/history seam line up.
        let command = "capture-pane -p -e -N -S -\(requestedDepth) -t \(target)"
        Self.logDiagnostic(
            "scrollback-capture send pane=\(paneId) depth=\(requestedDepth) generation=\(generation) commandCategory=\(Self.commandCategory(command))"
        )

        sendControlCommand(command) { [weak self] result in
            guard let self else { return }
            guard self.isCurrentGeneration(generation),
                  self.activePaneId == paneId || self.activeWindowId.flatMap({ self.window($0)?.activePaneId }) == paneId
            else {
                Self.logDiagnostic(
                    "scrollback-capture stale pane=\(paneId) generation=\(generation) result='\(Self.describe(result))'"
                )
                completion(.skipped(.stale))
                return
            }

            guard case .success(let captureLines) = result else {
                Self.logDiagnostic(
                    "scrollback-capture failed pane=\(paneId) generation=\(generation) result='\(Self.describe(result))'"
                )
                completion(.skipped(.captureFailed))
                return
            }

            let bytes = RepaintAssembly.assemble(
                state: state,
                captureLines: captureLines,
                historyLines: [],
                savedPrimaryLines: [],
                altScreenLines: nil,
                terminalIsInAltScreen: false,
                clientRows: clientRows ?? lastKnownSize?.rows
            )
            Self.logDiagnostic(
                "scrollback-capture complete pane=\(paneId) depth=\(requestedDepth) lines=\(captureLines.count) bytes=\(bytes.count) historySize=\(String(describing: state.historySize))"
            )
            completion(.captured(ScrollbackCapture(
                paneId: paneId,
                requestedDepth: requestedDepth,
                historySize: state.historySize,
                capturedLineCount: captureLines.count,
                repaintBytes: bytes
            )))
        }
    }

    /// Ask tmux to create a new window. tmux responds with
    /// `%window-add @N` followed by a `%session-window-changed` that
    /// auto-focuses it — the tab strip picks both up through the normal
    /// message flow.
    public func newWindow() {
        replayClientSize(reason: "new-window")
        sendControlCommand("new-window -e COLORTERM=truecolor")
    }

    /// Ask tmux to kill the current window. tmux responds with
    /// `%window-close @N` and, if another window remains, a
    /// `%session-window-changed` naming the successor.
    public func killCurrentWindow() {
        sendControlCommand("kill-window")
    }

    /// Ask tmux to kill a specific tracked window. The explicit `@id` target
    /// lets per-tab close controls remove an inactive window without first
    /// selecting it. Reject unknown ids so a broadcast notification from a
    /// different session can never turn into a command against that session.
    public func killWindow(_ windowId: WindowId) {
        guard mode == .tmuxControl,
              isWindowListHydrated,
              windows.contains(where: { $0.id == windowId })
        else { return }
        sendControlCommand("kill-window -t \(windowId.description)")
    }

    /// Previous tmux window in the session (wraps).
    public func previousWindow() {
        sendControlCommand("previous-window")
    }

    /// Next tmux window in the session (wraps).
    public func nextWindow() {
        sendControlCommand("next-window")
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
        guard mode == .tmuxControl,
              position >= 1,
              position <= windows.count
        else { return }
        let windowId = windows[position - 1].id
        clearBell(forWindowID: windowId.rawValue)
        sendControlCommand("select-window -t \(windowId.description)")
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
        let previous = lastKnownSize
        lastKnownSize = (cols, rows)
        replayClientSize(reason: "size-change", previous: previous)
    }

    private func replayClientSize(
        reason: String,
        previous: (cols: Int, rows: Int)? = nil
    ) {
        guard mode == .tmuxControl, let size = lastKnownSize else { return }
        // Logged so we can catch a transient bogus width (e.g. a half-width cols
        // during a layout/font transition) being pushed to tmux — that would
        // shrink the pane, and on the way back to full width the vacated columns
        // can keep stale background (the half-row gray bleed).
        Self.logDiagnostic(
            "client-size cols=\(size.cols) rows=\(size.rows) prevCols=\(previous?.cols ?? -1) prevRows=\(previous?.rows ?? -1) path=\(controlPath) reason=\(reason)"
        )
        sendControlCommand("refresh-client -C \(size.cols),\(size.rows)")
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
        updateClientSize(cols: cols, rows: rows)
        guard let activeWindowId,
              window(activeWindowId)?.rendersAsPaneGrid == false
        else { return }
        let generation = advanceStateGeneration(reason: "grid-collapse-resync")
        refreshRenderedWindow(
            windowId: activeWindowId,
            generation: generation,
            reason: "grid-collapse-resync"
        )
    }

    /// Close the rendered-output gate as soon as the app leaves the active
    /// phase. The SSH channel can resume before SwiftUI reports `.active` on
    /// the way back from another app, so waiting until the foreground refresh
    /// starts leaves a window where queued TUI redraws can visibly race through
    /// SwiftTerm's existing deep buffer.
    public func prepareForAppInactivity() {
        appIsInactive = true
        guard controlPath == .inline else { return }
        awaitingAppForegroundRefresh = true
        foregroundOutputRefreshGeneration = nil
        guard mode == .tmuxControl else { return }
        beginForegroundOutputCoalescing()
        Self.logDiagnostic(
            "foreground-output coalescing-begin window=\(activeWindowId?.description ?? "nil") renderedPane=\(renderedPaneId?.description ?? "nil")"
        )
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
        appIsInactive = false
        guard controlPath == .inline else { return }
        guard mode == .tmuxControl else {
            // `prepareForAppInactivity()` also latches while passthrough is
            // waiting to enter control mode. Clear that latch if the app became
            // active before tmux attached, or future initial rendering would be
            // deferred forever.
            endForegroundOutputCoalescing()
            return
        }
        guard let activeWindowId else {
            endForegroundOutputCoalescing()
            resumePausedForegroundRecoveryPanes()
            return
        }
        awaitingAppForegroundRefresh = false
        beginForegroundOutputCoalescing()
        Self.logDiagnostic("foreground-refresh window=\(activeWindowId)")
        if window(activeWindowId)?.rendersAsPaneGrid == true {
            // Grid windows are painted per-pane; repaint each visible pane.
            foregroundOutputRefreshGeneration = nil
            relinquishForegroundPaneRefreshOwnership()
            let paneIds = Set(paneSinks.keys)
            guard !paneIds.isEmpty else {
                // SwiftUI may not have mounted the grid surfaces yet. Keep the
                // lifecycle barrier armed across that gap; the app follows
                // each sink registration with refreshPane(), which inherits
                // foreground ownership and releases after authoritative paint.
                return
            }
            for paneId in paneIds {
                refreshPane(
                    paneId: paneId,
                    deep: paneId == activePaneId,
                    foregroundRecovery: true
                )
            }
            return
        }
        relinquishForegroundPaneRefreshOwnership()
        let refreshesRenderedPaneInPlace = renderedWindowId == activeWindowId
            && renderedPaneId != nil
            && renderedPaneId == activePaneId
        let stage: RenderStage = refreshesRenderedPaneInPlace ? .viewportOnly : .viewport
        let generation = advanceStateGeneration(reason: "foreground-refresh")
        foregroundOutputRefreshGeneration = generation
        refreshRenderedWindow(
            windowId: activeWindowId,
            generation: generation,
            reason: "foreground-refresh",
            stage: stage
        )
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
              pendingRenderRefresh == nil
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
        let cancelled = drainPendingCommands()
        controlConnectionGeneration &+= 1
        isWindowListHydrated = false
        advanceStateGeneration(reason: "reset")
        clearProtocolState(keepWindowModel: false)
        resetRenderHardeningState()
        suppressPassthroughOutputUntilControlMode = false
        isInitialRenderReady = false
        mode = .passthrough
        activePaneId = nil
        renderedWindowId = nil
        renderedPaneId = nil
        pendingRenderRefresh = nil
        windows.removeAll()
        bellingWindows.removeAll()
        pausedPanes.removeAll()
        windowBellFlags.removeAll()
        paneWindowTable.removeAll()
        paneCurrentPaths.removeAll()
        paneSinks.removeAll()
        pendingPaneRefreshes.removeAll()
        deepRefreshedPanes.removeAll()
        pendingPaneFocus.removeAll()
        moshPaneBorderWindows.removeAll()
        activeWindowId = nil
        ownSessionId = nil
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

        let cancelled = drainPendingCommands()
        controlConnectionGeneration &+= 1
        isWindowListHydrated = false
        advanceStateGeneration(reason: "sidechannel-disconnected")
        clearProtocolState(keepWindowModel: true)
        resetRenderHardeningState()
        suppressPassthroughOutputUntilControlMode = false
        isInitialRenderReady = false
        mode = .passthrough
        activePaneId = nil
        renderedWindowId = nil
        renderedPaneId = nil
        pendingRenderRefresh = nil
        ownSessionId = nil
        pausedPanes.removeAll()
        windowBellFlags.removeAll()
        pendingPaneFocus.removeAll()
        for entry in cancelled {
            entry.completion(.failure(.cancelled))
        }
    }

    // MARK: - DCS entry detection

    /// The DCS prologue tmux emits on `-CC` attach: ESC P 1 0 0 0 p.
    /// When we spot it in the output stream we flush any bytes before
    /// it to the terminal and switch into tmux mode for the remainder.
    private static let dcsEnterSequence: [UInt8] = [
        0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70
    ]

    private func handlePassthrough(_ chunk: [UInt8]) {
        // Fast path: if there's no pending reserve from a previous
        // chunk AND the incoming chunk can't contain a DCS prefix at
        // its tail (the common case for normal shell output), flush
        // it straight through without touching the rolling buffer.
        // This is the typing-echo hot path — a naive approach that
        // unconditionally reserves the last N-1 bytes creates a
        // visible 6-character input lag that feels dreadful.
        if dcsBuffer.isEmpty {
            // Scan the chunk for an in-place DCS match first.
            if let dcsStart = firstIndex(of: Self.dcsEnterSequence, in: chunk) {
                enterTmuxMode(splittingChunk: chunk, atDcsStart: dcsStart)
                return
            }
            // No DCS. Figure out whether the tail of this chunk could
            // be the start of a DCS that finishes in the next chunk.
            let prefixLen = longestDcsPrefixMatchAtTail(of: chunk)
            if prefixLen == 0 {
                // Not even the first DCS byte at the tail. Flush everything.
                feedPassthrough(ArraySlice(chunk))
                return
            }
            // Flush the non-suspicious prefix and reserve the ambiguous tail.
            let flushCount = chunk.count - prefixLen
            if flushCount > 0 {
                feedPassthrough(ArraySlice(chunk[..<flushCount]))
            }
            dcsBuffer.append(contentsOf: chunk[flushCount...])
            return
        }

        // Slow path: there's a pending reserve from the previous chunk,
        // so we can't short-circuit — the DCS might straddle the seam.
        dcsBuffer.append(contentsOf: chunk)

        if let dcsStart = firstIndex(of: Self.dcsEnterSequence, in: dcsBuffer) {
            enterTmuxMode(splittingChunk: dcsBuffer, atDcsStart: dcsStart)
            dcsBuffer.removeAll(keepingCapacity: true)
            return
        }

        // Still no DCS. Reserve only the bytes that actually match a
        // DCS prefix at the tail — everything else flushes immediately.
        let prefixLen = longestDcsPrefixMatchAtTail(of: dcsBuffer)
        if dcsBuffer.count > prefixLen {
            let flushCount = dcsBuffer.count - prefixLen
            feedPassthrough(ArraySlice(dcsBuffer[..<flushCount]))
            dcsBuffer.removeFirst(flushCount)
        }
    }

    private func feedPassthrough(_ bytes: ArraySlice<UInt8>) {
        guard !suppressPassthroughOutputUntilControlMode else { return }
        feedTerminal?(bytes)
    }

    /// Split a buffer at the DCS match point: pre-DCS bytes go to the
    /// terminal, post-DCS bytes enter tmux parsing, mode flips.
    ///
    /// Note that we DON'T push any commands to tmux yet — the initial
    /// state-discovery queries (`refresh-client -C`, `list-windows`,
    /// `display-message`) are deferred until `flushAttachInitQueries()`
    /// runs after we've absorbed tmux's server-originated handshake
    /// `%begin/%end` frame. tmux marks server-originated frames with
    /// flags bit0 clear; only frames with bit0 set are responses to
    /// commands written by this control client and may pop the FIFO.
    private func enterTmuxMode(splittingChunk chunk: [UInt8], atDcsStart dcsStart: Int) {
        let dcsEnd = dcsStart + Self.dcsEnterSequence.count
        if dcsStart > 0 {
            feedPassthrough(ArraySlice(chunk[..<dcsStart]))
        }
        mode = .tmuxControl
        suppressPassthroughOutputUntilControlMode = false
        isInitialRenderReady = controlPath == .sideChannel
        attachInitFlushed = false
        if controlPath == .inline {
            if appIsInactive {
                awaitingAppForegroundRefresh = true
                beginForegroundOutputCoalescing()
            }
            startInitialRenderWatchdog()
        }
        Self.logDiagnostic(
            "entered-control-mode path=\(controlPath) dcsStart=\(dcsStart) trailingBytes=\(max(0, chunk.count - dcsEnd))"
        )
        if dcsEnd < chunk.count {
            let messages = parser.feed(Array(chunk[dcsEnd...]))
            process(messages: messages)
        }
    }

    /// Length of the longest suffix of `buffer` that matches a prefix
    /// of the DCS enter sequence, up to `dcsEnterSequence.count - 1`.
    /// A full-length match would have been caught by the earlier
    /// `firstIndex(of:)` scan, so we only care about partial prefixes
    /// that could complete on the next chunk. Returns 0 when no tail
    /// byte could begin a DCS — the normal case for shell output,
    /// which enables the immediate-flush fast path.
    private func longestDcsPrefixMatchAtTail(of buffer: [UInt8]) -> Int {
        let dcs = Self.dcsEnterSequence
        let maxCheck = Swift.min(dcs.count - 1, buffer.count)
        var length = maxCheck
        while length > 0 {
            var match = true
            let tailStart = buffer.count - length
            for i in 0..<length where buffer[tailStart + i] != dcs[i] {
                match = false
                break
            }
            if match { return length }
            length -= 1
        }
        return 0
    }

    /// Return the index of the first occurrence of `needle` in
    /// `haystack`, or nil if not found. Straightforward O(n*m) scan —
    /// DCS sequences are short and chunks are small, so Boyer–Moore
    /// would be overkill.
    private func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        outer: for i in 0...(haystack.count - needle.count) {
            for j in 0..<needle.count where haystack[i + j] != needle[j] {
                continue outer
            }
            return i
        }
        return nil
    }

    private func drainPendingCommands() -> [PendingCommand] {
        let cancelled = pendingCommands
        pendingCommands.removeAll(keepingCapacity: true)
        return cancelled
    }

    private func clearProtocolState(keepWindowModel: Bool) {
        inflightLines.removeAll(keepingCapacity: true)
        attachInitFlushed = false
        parser.reset()
        outputTitleScanners.removeAll(keepingCapacity: true)
        preloadedTerminalDefaultColorPanes.removeAll(keepingCapacity: true)
        dcsBuffer.removeAll(keepingCapacity: true)
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

    private func resetRenderHardeningState() {
        cancelInitialRenderWatchdog()
        cancelRenderRetry(resetAttempts: true)
        renderCommandQueueWaitTask?.cancel()
        renderCommandQueueWaitTask = nil
        allowUngatedLatchFallback = false
        establishedRenderIsFailClosed = false
        abortedRenderedWindowId = nil
        endForegroundOutputCoalescing()
    }

    private func beginForegroundOutputCoalescing() {
        guard controlPath == .inline else { return }
        isForegroundOutputCoalescing = true
    }

    @discardableResult
    private func coalesceForegroundOutputIfNeeded(paneId: PaneId, data: [UInt8]) -> Bool {
        guard isForegroundOutputCoalescing else { return false }
        if foregroundOutputOverflowedPanes.contains(paneId) { return true }
        let limit = max(0, maxForegroundOutputBytes)
        guard coalescedForegroundOutputByteCount + data.count <= limit else {
            let discarded = coalescedForegroundOutput.removeValue(forKey: paneId)?.count ?? 0
            coalescedForegroundOutputByteCount -= discarded
            foregroundOutputOverflowedPanes.insert(paneId)
            Self.logDiagnostic(
                "foreground-output overflow pane=\(paneId) limit=\(limit) discarded=\(discarded) incoming=\(data.count)"
            )
            return true
        }
        coalescedForegroundOutput[paneId, default: []].append(contentsOf: data)
        coalescedForegroundOutputByteCount += data.count
        return true
    }

    private func takeCoalescedForegroundOutput(for paneId: PaneId) -> (bytes: [UInt8], overflowed: Bool) {
        let bytes = coalescedForegroundOutput.removeValue(forKey: paneId) ?? []
        coalescedForegroundOutputByteCount -= bytes.count
        let overflowed = foregroundOutputOverflowedPanes.remove(paneId) != nil
        return (bytes, overflowed)
    }

    private func discardCoalescedForegroundOutput(for paneId: PaneId) {
        _ = takeCoalescedForegroundOutput(for: paneId)
    }

    private func finishForegroundPaneRefresh(_ paneId: PaneId, requestID: Int) {
        guard foregroundPaneRefreshTargets[paneId] == requestID else { return }
        foregroundPaneRefreshTargets.removeValue(forKey: paneId)
        if foregroundPaneRefreshTargets.isEmpty {
            endForegroundOutputCoalescing()
        }
    }

    /// Invalidate grid-pane foreground work when the shared terminal becomes
    /// the new recovery owner. Do not end the barrier or discard retained
    /// bytes: the replacement shared capture must stay fail-closed until it
    /// paints authoritative state. Old pane callbacks become harmless stale
    /// completions because both their request ids and retry tasks are removed.
    private func relinquishForegroundPaneRefreshOwnership() {
        let targets = foregroundPaneRefreshTargets
        foregroundPaneRefreshTargets.removeAll(keepingCapacity: true)
        for (paneId, requestID) in targets {
            if pendingPaneRefreshes[paneId] == requestID {
                pendingPaneRefreshes.removeValue(forKey: paneId)
            }
            foregroundPaneRetryTasks.removeValue(forKey: paneId)?.cancel()
            foregroundPaneRetryAttempts.removeValue(forKey: paneId)
        }
    }

    /// Release the foreground barrier. Successful refreshes consume each
    /// relevant pane buffer immediately before repaint. Overflow and surface
    /// invalidation paths drop retained redraw streams atomically so they cannot
    /// reintroduce the high-speed replay this barrier exists to prevent.
    private func endForegroundOutputCoalescing() {
        guard isForegroundOutputCoalescing || !coalescedForegroundOutput.isEmpty else {
            awaitingAppForegroundRefresh = false
            foregroundOutputRefreshGeneration = nil
            coalescedForegroundOutputByteCount = 0
            foregroundOutputOverflowedPanes.removeAll(keepingCapacity: true)
            foregroundPaneRefreshTargets.removeAll(keepingCapacity: true)
            for task in foregroundPaneRetryTasks.values { task.cancel() }
            foregroundPaneRetryTasks.removeAll(keepingCapacity: true)
            foregroundPaneRetryAttempts.removeAll(keepingCapacity: true)
            return
        }
        let bufferedBytes = coalescedForegroundOutputByteCount
        let overflowedPanes = foregroundOutputOverflowedPanes.count
        Self.logDiagnostic(
            "foreground-output coalescing-end bufferedBytes=\(bufferedBytes) overflowedPanes=\(overflowedPanes)"
        )
        isForegroundOutputCoalescing = false
        awaitingAppForegroundRefresh = false
        foregroundOutputRefreshGeneration = nil
        coalescedForegroundOutput.removeAll(keepingCapacity: true)
        coalescedForegroundOutputByteCount = 0
        foregroundOutputOverflowedPanes.removeAll(keepingCapacity: true)
        foregroundPaneRefreshTargets.removeAll(keepingCapacity: true)
        for task in foregroundPaneRetryTasks.values { task.cancel() }
        foregroundPaneRetryTasks.removeAll(keepingCapacity: true)
        foregroundPaneRetryAttempts.removeAll(keepingCapacity: true)
    }

    private func resumePausedForegroundRecoveryPanes() {
        let recoveryPaneIds = Set([activePaneId, renderedPaneId].compactMap { $0 })
        for paneId in recoveryPaneIds where pausedPanes.contains(paneId) {
            resumePausedPane(paneId)
        }
    }

    /// The window whose content was on screen when an aborted swap
    /// cleared the rendered ids. The terminal keeps showing that
    /// window's pixels, so the retried swap must still report it as
    /// the `from` of `displayWillSwap` or the app layer skips the
    /// outgoing kitty/bracketed-paste snapshot.
    @ObservationIgnored private var abortedRenderedWindowId: WindowId?

    private func cancelInitialRenderWatchdog() {
        initialRenderWatchdogTask?.cancel()
        initialRenderWatchdogTask = nil
    }

    private func cancelRenderRetry(resetAttempts: Bool) {
        renderRetryTask?.cancel()
        renderRetryTask = nil
        if resetAttempts {
            renderRetryAttemptsByGeneration.removeAll(keepingCapacity: true)
        }
    }

    /// A shared-terminal repaint can be superseded by a surface transition
    /// that leaves no shared terminal to paint (the active window becomes a
    /// pane grid or the final window closes). Retire every shared owner so a
    /// failed established swap cannot keep observer queries fail-closed after
    /// its retry target has disappeared. In-flight command replies are left in
    /// the FIFO and made stale by the caller's generation advance.
    private func abandonSharedRenderRecovery() {
        pendingRenderRefresh = nil
        cancelRenderRetry(resetAttempts: true)
        renderCommandQueueWaitTask?.cancel()
        renderCommandQueueWaitTask = nil
        establishedRenderIsFailClosed = false
        abortedRenderedWindowId = nil
        foregroundOutputRefreshGeneration = nil
    }

    private func waitForCommandQueueBeforeRender(
        windowId: WindowId,
        generation: Int,
        reason: String,
        stage: RenderStage
    ) {
        renderCommandQueueWaitTask?.cancel()
        Self.logDiagnostic(
            "render-refresh wait-command-queue controller=\(diagnosticID) window=\(windowId) generation=\(generation) stage=\(stage) pending=\(pendingCommands.count) reason=\(reason)"
        )
        renderCommandQueueWaitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.renderCommandQueueWaitTask = nil
                guard self.isCurrentGeneration(generation),
                      self.activeWindowId == windowId,
                      let pending = self.pendingRenderRefresh,
                      pending.windowId == windowId,
                      pending.generation == generation,
                      pending.stage == stage
                else { return }
                self.refreshRenderedWindow(
                    windowId: windowId,
                    generation: generation,
                    reason: reason,
                    stage: stage
                )
            }
        }
    }

    private func startInitialRenderWatchdog() {
        guard controlPath == .inline else { return }
        cancelInitialRenderWatchdog()
        let interval = initialRenderWatchdogInterval
        initialRenderWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.nanoseconds(for: interval))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                // A cancel can land between the post-sleep check and this
                // hop; re-validate on the actor or a cancelled watchdog
                // from a dead attach fires into the next one's state.
                guard !Task.isCancelled,
                      let self,
                      self.mode == .tmuxControl,
                      !self.isInitialRenderReady,
                      self.renderedPaneId == nil
                else { return }
                Self.logDiagnostic(
                    "initial-render watchdog fired activeWindow=\(String(describing: self.activeWindowId)) generation=\(self.stateGeneration)"
                )
                self.allowUngatedLatchFallback = true
                if let activeWindowId = self.activeWindowId {
                    let generation = self.advanceStateGeneration(reason: "watchdog-retry")
                    self.refreshRenderedWindow(
                        windowId: activeWindowId,
                        generation: generation,
                        reason: "watchdog-retry"
                    )
                }
            }
        }
    }

    private func markInitialRenderReady() {
        isInitialRenderReady = true
        // The ungated latch exists only to escape a failed cold attach. Once a
        // complete terminal has rendered, carrying it into later window swaps
        // would allow incremental output to paint over stale full-screen state.
        allowUngatedLatchFallback = false
        cancelInitialRenderWatchdog()
    }

    private func abortRenderRefreshIfCurrent(
        windowId: WindowId,
        generation: Int,
        stage: RenderStage,
        reason: String
    ) {
        clearPendingRenderRefresh(windowId: windowId, generation: generation)
        guard controlPath == .inline,
              isCurrentGeneration(generation),
              activeWindowId == windowId
        else { return }

        // An in-place foreground repair must leave the already-rendered pane
        // and its local scrollback intact while tmux's metadata channel rides
        // out a transient post-background stall. Real swaps keep the existing
        // fail-closed behavior.
        if stage == .viewport || (stage == .deep && !isInitialRenderReady) {
            if stage == .viewport, isInitialRenderReady {
                establishedRenderIsFailClosed = true
            }
            if renderedWindowId != nil {
                abortedRenderedWindowId = renderedWindowId
            }
            renderedWindowId = nil
            renderedPaneId = nil
        }
        scheduleRenderRefreshRetry(
            windowId: windowId,
            generation: generation,
            stage: stage,
            reason: "\(reason)-retry"
        )
    }

    private func scheduleRenderRefreshRetry(
        windowId: WindowId,
        generation: Int,
        stage: RenderStage,
        reason: String
    ) {
        let nextAttempt = (renderRetryAttemptsByGeneration[generation] ?? 0) + 1
        // Fail-open output is safe only during the initial attach, when there
        // is no prior window on screen to corrupt. During a later window swap,
        // latching the new pane after metadata stalls paints only its next few
        // incremental updates over the old full-screen image — a mostly stale
        // viewport with a small sliver from the newly active window. Keep
        // established sessions fail-closed until an authoritative capture lands.
        if nextAttempt > 1, !isInitialRenderReady {
            allowUngatedLatchFallback = true
        }
        // Only the viewport stage (the visible screen) self-heals with extra
        // attempts — that's the repaint whose failure leaves stale cross-window
        // content on screen. The deep stage is scrollback enrichment layered on
        // an already-rendered viewport, so it keeps the single-retry give-up.
        let isForegroundRecovery = foregroundOutputRefreshGeneration == generation
        let isEstablishedSwapRecovery = stage == .viewport && establishedRenderIsFailClosed
        let maxAttempts = stage == .deep ? 1 : maxRenderRefreshAttempts
        guard isForegroundRecovery || isEstablishedSwapRecovery || nextAttempt <= maxAttempts else {
            Self.logDiagnostic(
                "render-refresh retry exhausted window=\(windowId) generation=\(generation) stage=\(stage) attempt=\(nextAttempt) reason=\(reason)"
            )
            return
        }

        // Only the current generation can ever retry; drop stale
        // entries so the map can't grow across a long session.
        renderRetryAttemptsByGeneration = [generation: nextAttempt]
        renderRetryTask?.cancel()
        // Linear backoff (capped) so a multi-second channel stall — the empty
        // render-metadata window right after foreground restore — is ridden out
        // without hammering tmux. The first retry keeps the original delay.
        let delay = renderRefreshRetryDelay * Double(min(nextAttempt, 6))
        Self.logDiagnostic(
            "render-refresh retry scheduled window=\(windowId) generation=\(generation) stage=\(stage) attempt=\(nextAttempt) delay=\(delay) reason=\(reason)"
        )
        renderRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.isCurrentGeneration(generation),
                      self.activeWindowId == windowId
                else { return }
                self.renderRetryTask = nil
                self.refreshRenderedWindow(
                    windowId: windowId,
                    generation: generation,
                    reason: reason,
                    stage: stage
                )
            }
        }
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
        clearTitleWhenMissing: Bool = false
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
            preloadTerminalDefaultColorReportIfNeeded(for: paneId)
        }
        reconcileActivePaneFlags(windowIdx: idx)
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
        }
        reconcileActivePaneFlags(windowIdx: idx)
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
        // Skip no-op writes: the %* pane-metadata subscription fires for
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
        }
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

    private func process(messages: [TmuxMessage]) {
        for message in messages {
            handle(message: message)
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

        guard let widx = paneWindowIdx,
              let pidx = windows[widx].panes.firstIndex(where: { $0.id == paneId })
        else { return }

        windows[widx].panes[pidx].title = Self.nonEmpty(title)
        windows[widx].panes[pidx].titleIsDefault = false
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

    private func handlePaneOutput(paneId: PaneId, data: [UInt8]) {
        paneDidOutput?(paneId)
        paneOutputObserver?(paneId, data[...])
        updatePaneTitleFromOutput(paneId: paneId, data: data)
        sendTerminalResponseForOutputIfNeeded(paneId: paneId, data: data)

        // Grid path: a registered per-pane sink takes priority over the shared
        // single-pane terminal. This is the explicit fallthrough boundary — if
        // a pane has no sink, control drops to the byte-identical single-pane
        // fast path below. Drop output while this pane's capture-repaint is in
        // flight so stale bytes can't bleed in ahead of the capture.
        if let sink = paneSinks[paneId] {
            guard controlPath == .inline else { return }
            if coalesceForegroundOutputIfNeeded(paneId: paneId, data: data) { return }
            if pendingPaneRefreshes[paneId] != nil { return }
            sink(ArraySlice(data))
            return
        }

        guard controlPath == .inline else { return }
        let isForegroundRecoveryPane = paneId == renderedPaneId
            || paneId == activePaneId
            || (renderedPaneId == nil && activePaneId == nil)
        if isForegroundRecoveryPane,
           coalesceForegroundOutputIfNeeded(paneId: paneId, data: data) {
            return
        }
        if pendingRenderRefresh != nil { return }

        // On attach, tmux can flood output before hydration names any active
        // window. The latch opens only once a window is known, except for the
        // watchdog's fail-open path. While a failed swap awaits its retry
        // the gate stays closed too — otherwise a chatty pane latches and
        // paints mid-stream bytes (and drops the launch overlay) during
        // the ~0.5 s retry window on attach.
        let latchGateOpen = controlPath == .inline
            && !establishedRenderIsFailClosed
            && ((activeWindowId != nil && renderRetryTask == nil) || allowUngatedLatchFallback)
        if latchGateOpen,
           renderedPaneId == nil,
           activePaneId == nil,
           (windows.count == 1 || allowUngatedLatchFallback) {
            activePaneId = paneId
            preloadTerminalDefaultColorReportIfNeeded(for: paneId)
            if let activeWindowId {
                updateActivePane(windowId: activeWindowId, paneId: paneId, paneTitle: nil)
            }
        }
        if latchGateOpen, renderedPaneId == nil, paneId == activePaneId {
            renderedPaneId = paneId
            renderedWindowId = activeWindowId
            preloadTerminalDefaultColorReportIfNeeded(for: paneId)
        }
        if paneId == renderedPaneId {
            feedTerminal?(ArraySlice(data))
            markInitialRenderReady()
        }
    }

    private func handle(message: TmuxMessage) {
        switch message {
        case .bell(let paneID):
            guard let window = windowInfo(forPaneId: PaneId(paneID)) else { break }
            let windowID = window.id.rawValue
            let isActive = window.id == activeWindowId
            onBell?(windowID, isActive, window.displayName)
            if !isActive {
                bellingWindows.insert(windowID)
            }

        case .output(let paneId, let data):
            handlePaneOutput(paneId: paneId, data: data)

        case .extendedOutput(let paneId, let ageMs, let data):
            if ageMs > 2_000 {
                Self.logDiagnostic(
                    "extended-output delayed pane=\(paneId) ageMs=\(ageMs) bytes=\(data.count)"
                )
            }
            handlePaneOutput(paneId: paneId, data: data)

        case .windowAdd(let windowId):
            // Create the window if new; ensureWindow also drains any pane focus a
            // broadcast %window-pane-changed stashed for it before it was known,
            // so the active-pane latch below reads the right pane.
            _ = ensureWindow(windowId)
            // Latch the first window we see as the active one if we
            // haven't been told otherwise yet. session-window-changed
            // will overwrite this with tmux's own view in a beat.
            if activeWindowId == nil {
                activeWindowId = windowId
                activePaneId = window(windowId)?.activePaneId
            }
            // Discover the window's actual name if the entry is still
            // on the `@N` placeholder. tmux fires `%window-renamed`
            // shortly after `%window-add` for default `new-window`
            // (the shell-startup automatic-rename), but does NOT for
            // explicitly-named `new-window -n NAME` — verified via
            // pty probe. Without this query the tab label sticks at
            // the `@N` placeholder forever for named windows.
            //
            // For mid-session creates, `%session-window-changed`
            // arrives BEFORE `%window-add` and pre-creates the entry
            // with the placeholder (verified against tmux 3.6), so
            // the gate is "name is still placeholder" rather than
            // "we just appended."
            //
            // The placeholder check also prevents re-querying when
            // the attach-init `list-windows` response already
            // populated the name.
            if let idx = windows.firstIndex(where: { $0.id == windowId }),
               windows[idx].windowName == nil {
                queryWindowName(windowId: windowId)
            }

        case .windowClose(let windowId),
             .unlinkedWindowClose(let windowId):
            // Both variants drop a window from our session's view:
            //   - `%window-close @N` fires when the window was removed
            //     from one winlink but another winlink in the same
            //     session still holds it (rare).
            //   - `%unlinked-window-close @N` fires when the window is
            //     no longer in *any* winlink of the observing client's
            //     session — tmux's own `control_notify_window_unlinked`
            //     picks this variant. It's the one `kill-window`
            //     actually produces in the v1 single-winlink-per-window
            //     case (verified against tmux 3.6 via pty probe), so
            //     we must handle it or the tab strip goes stale after
            //     every ⌘⇧W.
            // Either way the result for our UI is the same: drop the
            // window from the tab list. If tmux hasn't already told us
            // which sibling is active (normally it sends
            // `%session-window-changed` *before* the close), fall back
            // to the first remaining window so we don't leave a
            // dangling activeWindowId.
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
                activeWindowId = windows.first?.id
                activePaneId = activeWindowId.flatMap { window($0)?.activePaneId }
                if let activePaneId {
                    preloadTerminalDefaultColorReportIfNeeded(for: activePaneId)
                }
                if let activeWindowId {
                    switch controlPath {
                    case .inline:
                        refreshRenderedWindow(
                            windowId: activeWindowId,
                            generation: generation,
                            reason: "active-window-closed"
                        )
                    case .sideChannel:
                        refreshActivePaneMetadataIfNeeded(
                            windowId: activeWindowId,
                            generation: generation,
                            reason: "active-window-closed"
                        )
                    }
                } else {
                    // The last active window disappeared. There is no shared
                    // surface left to repaint, so retire both ordinary
                    // established-swap recovery and foreground ownership.
                    abandonSharedRenderRecovery()
                    if isForegroundOutputCoalescing {
                        endForegroundOutputCoalescing()
                    }
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
            if let activePaneId {
                preloadTerminalDefaultColorReportIfNeeded(for: activePaneId)
            }
            Self.logDiagnostic(
                "session-window-changed path=\(controlPath) previous=\(String(describing: previousActive)) activeWindow=\(windowId) activePane=\(String(describing: activePaneId)) rendered=\(String(describing: renderedWindowId))/\(String(describing: renderedPaneId))"
            )
            guard previousActive != windowId || renderedWindowId != windowId else {
                break
            }
            let generation = advanceStateGeneration(reason: "session-window-changed")
            switch controlPath {
            case .inline:
                refreshRenderedWindow(
                    windowId: windowId,
                    generation: generation,
                    reason: "session-window-changed"
                )
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
            if windowId == activeWindowId {
                self.activePaneId = activePaneId
                let generation = advanceStateGeneration(reason: "window-pane-changed")
                switch controlPath {
                case .inline:
                    refreshRenderedWindow(
                        windowId: windowId,
                        generation: generation,
                        reason: "window-pane-changed"
                    )
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
            // The pane-metadata subscription is registered with `%*`
            // (all panes server-wide), so tmux delivers metadata for
            // other sessions' panes too. The bell subscription uses the
            // same wildcard target. Drop foreign-session updates
            // up front (defense-in-depth: the `indexOfWindow` guard in
            // handlePaneMetadataSubscription already rejects them once
            // the %session-window-changed filter keeps foreign windows
            // out of `windows[]`). Fail open while `ownSessionId` is nil.
            if let ownSessionId, sessionId != ownSessionId { break }
            if name == Self.bellSubscriptionName {
                handleBellSubscription(windowId: windowId, value: value)
                break
            }
            guard name == Self.paneMetadataSubscriptionName,
                  let metadata = Self.parsePaneSubscriptionMetadata(
                    value,
                    fallbackWindowId: windowId,
                    fallbackPaneId: paneId
                  )
            else { break }
            handlePaneMetadataSubscription(metadata)

        case .pause(let paneId):
            handlePause(paneId: paneId)

        case .continue(let paneId):
            pausedPanes.remove(paneId)

        case .begin(_, let commandNumber, let flags):
            // Fresh command response — drop any leftover body from a
            // previous response (shouldn't happen in normal flow, but
            // keeps us robust to parser state mishaps).
            inflightLines.removeAll(keepingCapacity: true)
            Self.logDiagnostic(
                "command-frame-begin controller=\(diagnosticID) number=\(commandNumber) flags=\(flags) wirePending=\(pendingCommands.count) headSequence=\(pendingCommands.first?.sequence ?? -1) headCategory=\(pendingCommands.first.map { Self.commandCategory($0.command) } ?? "none")"
            )

        case .commandOutputLine(let line):
            inflightLines.append(line)

        case .end(_, let commandNumber, let flags):
            let lines = inflightLines
            inflightLines.removeAll(keepingCapacity: true)
            guard flags & 1 == 1 else {
                if !attachInitFlushed {
                    attachInitFlushed = true
                    Self.logDiagnostic("handshake-frame-drained path=\(controlPath)")
                    flushAttachInitQueries()
                } else {
                    Self.logDiagnostic(
                        "server-originated-frame-drained status=end lines=\(lines.count)"
                    )
                }
                break
            }
            // tmux is serialized, so FIFO dequeue matches the `%end`
            // with the oldest pending command.
            if !pendingCommands.isEmpty {
                let entry = pendingCommands.removeFirst()
                Self.logDiagnostic(
                    "command-response controller=\(diagnosticID) status=end number=\(commandNumber) sequence=\(entry.sequence) commandCategory=\(Self.commandCategory(entry.command)) lines=\(lines.count)"
                )
                entry.completion(.success(lines))
            }

        case .error(_, let commandNumber, let flags):
            let lines = inflightLines
            inflightLines.removeAll(keepingCapacity: true)
            guard flags & 1 == 1 else {
                Self.logDiagnostic(
                    "server-originated-frame-drained status=error lines=\(lines.count)"
                )
                break
            }
            if !pendingCommands.isEmpty {
                let entry = pendingCommands.removeFirst()
                Self.logDiagnostic(
                    "command-response controller=\(diagnosticID) status=error number=\(commandNumber) sequence=\(entry.sequence) commandCategory=\(Self.commandCategory(entry.command)) lines=\(lines.count)"
                )
                entry.completion(.failure(.tmuxError(lines: lines)))
            }

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

        case .sessionChanged(let sessionId, _):
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
            Self.logDiagnostic("session-changed own session set to \(sessionId)")

            // A later %session-changed can move this same -CC client to a
            // different session without disconnecting. Window ids are global
            // to the tmux server, so stale tabs from the prior session must not
            // remain valid kill targets. Keep them visible but disabled until
            // a new authoritative list-windows response replaces the model.
            if let priorSessionId, priorSessionId != sessionId {
                controlConnectionGeneration &+= 1
                isWindowListHydrated = false
                hydrateTmuxState(reason: "session-changed")
            }

        case let .layoutChange(windowId, layout, visibleLayout, rawFlags):
            handleLayoutChange(
                windowId: windowId,
                layout: layout,
                visibleLayout: visibleLayout,
                rawFlags: rawFlags
            )

        case .unlinkedWindowAdd, .unlinkedWindowRenamed,
             .sessionRenamed,
             .sessionsChanged, .clientSessionChanged, .clientDetached,
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
        rawFlags: String?
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

        if controlPath == .inline,
           windowId == activeWindowId,
           !previouslyRenderedAsGrid,
           windows[idx].rendersAsPaneGrid {
            // SwiftUI will replace the shared terminal with fresh per-pane
            // surfaces after this model update. Invalidate any hidden shared
            // capture/retry, but keep an existing lifecycle output barrier
            // armed across the mount gap. The app's normal first per-pane
            // refresh inherits that ownership and releases it only after every
            // mounted surface has captured authoritative state. If the app is
            // still inactive, foreground activation starts those pane repairs.
            _ = advanceStateGeneration(reason: "shared-to-grid")
            abandonSharedRenderRecovery()
        }

        Self.logDiagnostic(
            "layout-change window=\(windowId) paneCount=\(parsedLayout?.paneCount ?? -1) zoomed=\(zoomed) grid=\(windows[idx].rendersAsPaneGrid) panes=\(parsedLayout?.paneIds.map(\.description) ?? [])"
        )

        updateMoshPaneBorder(windowId: windowId, paneCount: windows[idx].paneCount)
    }

    /// (Mosh/side-channel only) Toggle tmux's native per-pane title row for a
    /// window as it splits/collapses — Option 2: tmux paints the titles into the
    /// UDP stream, Tessera overlays a tappable ✕. No-op on the inline (SSH) path,
    /// where the app draws its own per-pane headers and would double-reserve the
    /// row. Only acts on the 1↔N transition (idempotent across geometry-only
    /// layout changes) and targets the specific window, so single-pane windows
    /// and other sessions are untouched. See `moshPaneBorderWindows`.
    private func updateMoshPaneBorder(windowId: WindowId, paneCount: Int) {
        guard controlPath == .sideChannel else { return }
        let isMulti = paneCount > 1
        let wasMulti = moshPaneBorderWindows.contains(windowId)
        guard isMulti != wasMulti else { return }

        if isMulti {
            moshPaneBorderWindows.insert(windowId)
            sendControlCommand("set -t \(windowId.description) pane-border-status top")
            sendControlCommand("set -t \(windowId.description) pane-border-format \"\(Self.moshPaneBorderFormat)\"")
        } else {
            moshPaneBorderWindows.remove(windowId)
            sendControlCommand("set -t \(windowId.description) pane-border-status off")
        }
    }

    func preemptMoshPaneBorderSplit(forTargeting paneId: PaneId) {
        guard controlPath == .sideChannel,
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

    private func handlePause(paneId: PaneId) {
        pausedPanes.insert(paneId)
        guard controlPath == .inline else { return }
        let pausesRenderedPane = paneId == renderedPaneId
        let pausesActiveUnrenderedPane = renderedPaneId == nil && paneId == activePaneId
        guard pausesRenderedPane || pausesActiveUnrenderedPane,
              let windowId = renderedWindowId ?? activeWindowId,
              // A %pause for the still-rendered pane can land while a
              // window-switch refresh is in flight (pause-after fires
              // under floods — exactly when swaps are slow and users
              // switch away). The rendered ids then point at the OLD
              // window; resyncing it would resume the background
              // flooder, advance the generation (killing the
              // legitimate swap), and issue a refresh whose
              // activeWindowId guard silently aborts with no retry —
              // a sticky display/input split-brain. Leave the pane
              // paused instead: the server discards its output
              // harmlessly, bells survive via the window_bell_flag
              // subscription, and finishRenderedWindowRefresh's
              // swap-in resume continues it if the user returns.
              windowId == activeWindowId
        else { return }

        // Foreground recovery already owns the authoritative viewport capture.
        // Leave the pane paused until that repaint lands; starting the normal
        // deep pause-resync here would replay history and supersede the exact
        // output barrier that protects app activation.
        if isForegroundOutputCoalescing { return }

        resumePausedPane(paneId)
        let generation = advanceStateGeneration(reason: "pause-resync")
        refreshRenderedWindow(
            windowId: windowId,
            generation: generation,
            reason: "pause-resync",
            stage: .deep
        )
    }

    private func resumePausedPane(_ paneId: PaneId) {
        sendControlCommand("refresh-client -A '\(paneId.description):continue'")
        pausedPanes.remove(paneId)
    }

    private func handleBellSubscription(windowId: WindowId, value: String) {
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
              windowId != activeWindowId
        else { return }

        onBell?(windowId.rawValue, false, window(windowId)?.displayName)
        bellingWindows.insert(windowId.rawValue)
    }

    private func sendTerminalResponseForOutputIfNeeded(paneId: PaneId, data: [UInt8]) {
        guard let response = terminalResponseForOutput?(paneId, data[...]),
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

    private func sendTerminalReport(_ bytes: [UInt8], to pane: PaneId) {
        guard let report = String(bytes: bytes, encoding: .utf8) else { return }
        let argument = "\(pane.description):\(report)"
        sendControlCommand("refresh-client -r \(Self.singleQuotedTmuxArgument(argument))")
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

    private func hydrateTmuxState(reason: String) {
        let generation = advanceStateGeneration(reason: reason)
        resetRenderHardeningState()
        if appIsInactive, controlPath == .inline {
            awaitingAppForegroundRefresh = true
            beginForegroundOutputCoalescing()
        }
        if controlPath == .inline {
            startInitialRenderWatchdog()
        }
        pendingRenderRefresh = nil
        Self.logDiagnostic(
            "hydrate begin path=\(controlPath) reason=\(reason) generation=\(generation) size=\(String(describing: lastKnownSize))"
        )

        if controlPath == .inline {
            // tmux bakes history-limit into panes when they are created; this
            // covers post-attach windows while first-session panes keep the
            // server default and deep capture simply clamps to what's there.
            sendControlCommand("set-option -g history-limit 10000")
        }
        // PTY resize is silently ignored in -CC mode, including mosh's
        // side-channel client. Replay the visible terminal size before any
        // queries or user-triggered tmux commands depend on this client.
        replayClientSize(reason: "attach-init")

        sendControlCommand("refresh-client -f pause-after=5")
        sendControlCommand(
            "refresh-client -B '\(Self.bellSubscriptionName):%*:#{window_bell_flag}'"
        )

        // Field order is load-bearing: fixed-grammar fields (id, layout,
        // visible_layout, zoomed_flag) first and `#{window_name}` LAST, because
        // a tab embedded in a window name must not shift the layout columns.
        // Widening this existing command (rather than adding a new one) keeps
        // the attach-init frame numbering stable — no golden renumbering.
        sendControlCommand(
            "list-windows -F '#{window_id}\t#{window_layout}\t#{window_visible_layout}\t#{window_zoomed_flag}\t#{window_name}'"
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

        sendControlCommand("display-message -p '#{window_id}'") { [weak self] result in
            guard let self = self,
                  self.isCurrentGeneration(generation)
            else { return }
            guard case .success(let responseLines) = result,
                  let head = responseLines.first(where: { !$0.isEmpty }),
                  let activeId = Self.parseWindowIdString(head)
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
    }

    private func handleHydratedWindowList(lines: [String]) {
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
        isWindowListHydrated = true
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
        ensureWindow(activeId)
        activeWindowId = activeId
        activePaneId = window(activeId)?.activePaneId

        switch controlPath {
        case .inline:
            refreshRenderedWindow(
                windowId: activeId,
                generation: generation,
                reason: "\(reason)-active",
                stage: .deep
            )
        case .sideChannel:
            refreshActivePaneMetadataIfNeeded(
                windowId: activeId,
                generation: generation,
                reason: "\(reason)-active"
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
    }

    private func sendPaneMetadataSubscription() {
        sendControlCommand(
            "refresh-client -B '\(Self.paneMetadataSubscriptionName):%*:\(Self.paneMetadataSubscriptionFormat)'"
        )
    }

    private static func parseWindowListLine(_ line: String) -> WindowInfo? {
        guard !line.isEmpty else { return nil }
        // Wide shape: id \t layout \t visible_layout \t zoomed_flag \t name.
        // `name` is LAST and may itself contain tabs, so cap at 4 splits to
        // keep the whole remainder as the name (hostile-name safe).
        let parts = line.split(
            separator: "\t",
            maxSplits: 4,
            omittingEmptySubsequences: false
        )
        guard let first = parts.first,
              let id = parseWindowIdString(String(first))
        else {
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

        if parts.count >= 4 {
            let layout = WindowLayout.parse(String(parts[1]))
            let visible = WindowLayout.parse(String(parts[2]))
            let zoomed = String(parts[3]) == "1"
            let name = parts.count >= 5 ? nonEmpty(String(parts[4])) : nil
            var info = WindowInfo(id: id, windowName: name)
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

    private static func parsePaneListLine(_ line: String) -> PaneListEntry? {
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let windowId = parseWindowIdString(String(parts[0])),
              let paneId = parsePaneIdString(String(parts[1]))
        else { return nil }
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

    static func parsePaneSubscriptionMetadata(
        _ value: String,
        fallbackWindowId: WindowId,
        fallbackPaneId: PaneId
    ) -> PaneSubscriptionMetadata? {
        let line = decodeControlEscapes(value)
        let parts = line.split(
            separator: "\t",
            omittingEmptySubsequences: false
        )
        let windowId = parts.first
            .flatMap { parseWindowIdString(String($0)) }
            ?? fallbackWindowId
        let paneId = parts.count >= 2
            ? (parsePaneIdString(String(parts[1])) ?? fallbackPaneId)
            : fallbackPaneId
        let active = parts.count >= 3 ? String(parts[2]) == "1" : false
        let contentRect: CellRect?
        let currentCommandIndex: Int
        if parts.count >= 11,
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
        let windowNameIndex = currentCommandIndex + 2
        let windowName = parts.count > windowNameIndex ? nonEmpty(String(parts[windowNameIndex])) : nil
        let hostIndex = currentCommandIndex + 3
        let host = parts.count > hostIndex ? nonEmpty(String(parts[hostIndex])) : nil
        let currentPathIndex = currentCommandIndex + 4
        let currentPath = parts.count > currentPathIndex ? nonEmpty(String(parts[currentPathIndex])) : nil
        let agentStateIndex = currentCommandIndex + 5
        let agentStateJSON = parts.count > agentStateIndex ? nonEmpty(String(parts[agentStateIndex])) : nil

        return PaneSubscriptionMetadata(
            windowId: windowId,
            paneId: paneId,
            isActive: active,
            contentRect: contentRect,
            currentCommand: currentCommand,
            paneTitle: title,
            paneTitleIsDefault: isDefaultPaneTitle(title, host: host),
            windowName: windowName,
            currentPath: currentPath,
            agentStateJSON: agentStateJSON
        )
    }

    private static func decodeControlEscapes(_ value: String) -> String {
        let input = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var i = 0

        while i < input.count {
            guard input[i] == 0x5C /* \ */ else {
                output.append(input[i])
                i += 1
                continue
            }

            if i + 1 < input.count {
                switch input[i + 1] {
                case 0x74: // t
                    output.append(0x09)
                    i += 2
                    continue
                case 0x72: // r
                    output.append(0x0D)
                    i += 2
                    continue
                case 0x6E: // n
                    output.append(0x0A)
                    i += 2
                    continue
                case 0x5C: // \
                    output.append(0x5C)
                    i += 2
                    continue
                default:
                    break
                }
            }

            if i + 3 < input.count,
               isOctalDigit(input[i + 1]),
               isOctalDigit(input[i + 2]),
               isOctalDigit(input[i + 3])
            {
                let value = Int(input[i + 1] - 0x30) << 6
                    | Int(input[i + 2] - 0x30) << 3
                    | Int(input[i + 3] - 0x30)
                if value < 256 {
                    output.append(UInt8(value))
                    i += 4
                    continue
                }
            }

            output.append(input[i])
            i += 1
        }

        return String(decoding: output, as: UTF8.self)
    }

    private static func isOctalDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x37
    }

    private func handlePaneMetadataSubscription(_ metadata: PaneSubscriptionMetadata) {
        if let agentStateJSON = metadata.agentStateJSON {
            paneAgentStateObserver?(metadata.paneId, agentStateJSON)
        }
        guard indexOfWindow(metadata.windowId) != nil else { return }

        if let windowName = Self.nonEmpty(metadata.windowName) {
            upsertWindowName(windowName, for: metadata.windowId)
        }

        // Track every pane's title/flag, not just the active one — the wire
        // already delivers all of them via the `%*` wildcard subscription.
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

    // MARK: - Window-name discovery (§3.2 commit C part 3)

    /// Query tmux for the actual `#{window_name}` of a window we
    /// only know by its `@N` placeholder, and update
    /// `windows[idx].windowName` from the single-line response.
    ///
    /// Used by the `.windowAdd` handler for windows that arrived
    /// without a follow-up `%window-renamed` — specifically
    /// `new-window -n NAME`, which tmux never auto-renames
    /// (verified via pty probe against tmux 3.6).
    ///
    /// The completion is defensive on three axes:
    ///   - **Window may have been removed** between query and reply
    ///     (e.g. user killed the window). Skip silently.
    ///   - **Name may have been updated** by a real `%window-renamed`
    ///     that arrived between query and reply. Don't overwrite a
    ///     confirmed name with our (potentially stale) response —
    ///     only update when the entry is still on the placeholder.
    /// Pane titles are tracked separately and remain the preferred
    /// display label when present.
    private func queryWindowName(windowId: WindowId) {
        sendControlCommand(
            "display-message -p -t \(windowId.description) '#{window_name}'"
        ) { [weak self] result in
            guard let self,
                  case .success(let lines) = result,
                  let name = lines.first(where: { !$0.isEmpty })
            else { return }
            guard let idx = self.windows.firstIndex(where: { $0.id == windowId }),
                  self.windows[idx].windowName == nil
            else { return }
            self.windows[idx].windowName = name
        }
    }

    // MARK: - Inline rendered-window refresh

    /// Query tmux for the target window's active pane, cursor, pane
    /// title, window name, and terminal modes; then capture and repaint
    /// SwiftTerm if the request is still current.
    ///
    /// The flow is necessarily asynchronous because tmux's responses
    /// come back as separate `%begin`/`%end` frames on the wire. We
    /// chain two callbacks via `sendControlCommand(_:completion:)`:
    ///
    /// 1. `display-message -p -t @N ...` resolves the active pane id,
    ///    cursor position, pane title, and fallback window name in a
    ///    single round trip.
    /// 2. A viewport refresh captures the visible screen first; a deep
    ///    refresh captures scrollback as well, or splits primary/alt
    ///    buffers when tmux reports the pane is in alternate screen.
    ///
    /// On any failure — command error, malformed response, controller
    /// reset mid-refresh, active-window switch — the refresh aborts.
    /// This is a soft-fail rather than a visible error because the
    /// user is mid-interaction and a pop-up would be distracting.
    private func refreshRenderedWindow(
        windowId: WindowId,
        generation: Int,
        reason: String,
        stage: RenderStage = .viewport
    ) {
        guard controlPath == .inline else { return }
        if awaitingAppForegroundRefresh {
            clearPendingRenderRefresh(windowId: windowId, generation: generation)
            Self.logDiagnostic(
                "render-refresh deferred-inactive window=\(windowId) generation=\(generation) stage=\(stage) reason=\(reason)"
            )
            return
        }
        if isForegroundOutputCoalescing {
            // A state change can supersede the original foreground request.
            // Transfer ownership only when this call will actually perform the
            // replacement shared-surface capture; grid/no-window paths release
            // the barrier explicitly instead.
            relinquishForegroundPaneRefreshOwnership()
            foregroundOutputRefreshGeneration = generation
        }
        // Grid windows are painted per-pane by the app (refreshPane), not the
        // shared terminal — skip the shared repaint so the two paths don't
        // fight over renderedPaneId / displayWillSwap. Mark ready so the launch
        // overlay can still drop when switching to a grid window.
        if window(windowId)?.rendersAsPaneGrid == true {
            abandonSharedRenderRecovery()
            if isForegroundOutputCoalescing {
                endForegroundOutputCoalescing()
            }
            markInitialRenderReady()
            return
        }
        pendingRenderRefresh = (windowId: windowId, generation: generation, stage: stage)
        let requiresExclusiveCommandQueue = isInitialRenderReady && stage != .deep
        guard !requiresExclusiveCommandQueue || pendingCommands.isEmpty else {
            waitForCommandQueueBeforeRender(
                windowId: windowId,
                generation: generation,
                reason: reason,
                stage: stage
            )
            return
        }
        renderCommandQueueWaitTask?.cancel()
        renderCommandQueueWaitTask = nil
        Self.logDiagnostic(
            "render-refresh send-metadata window=\(windowId) generation=\(generation) stage=\(stage) reason=\(reason)"
        )
        sendControlCommand(
            "display-message -p -t \(windowId.description) '\(Self.renderedPaneMetadataFormat)'"
        ) { [weak self] result in
            guard let self else { return }
            guard self.isCurrentGeneration(generation),
                  self.controlPath == .inline,
                  self.activeWindowId == windowId
            else {
                self.clearPendingRenderRefresh(windowId: windowId, generation: generation)
                Self.logDiagnostic(
                    "render-refresh metadata stale window=\(windowId) generation=\(generation) result='\(Self.describe(result))'"
                )
                return
            }
            if self.awaitingAppForegroundRefresh {
                self.clearPendingRenderRefresh(windowId: windowId, generation: generation)
                Self.logDiagnostic(
                    "render-refresh metadata-deferred-inactive window=\(windowId) generation=\(generation) stage=\(stage) reason=\(reason)"
                )
                return
            }
            guard case .success(let lines) = result,
                  let head = lines.first(where: { !$0.isEmpty }),
                  let parsed = Self.parseRenderedPaneState(head)
            else {
                self.abortRenderRefreshIfCurrent(
                    windowId: windowId,
                    generation: generation,
                    stage: stage,
                    reason: "metadata"
                )
                Self.logDiagnostic(
                    "render-refresh metadata failed window=\(windowId) generation=\(generation) stage=\(stage) result='\(Self.describe(result))' detail=\(Self.describeMetadataResponse(result))"
                )
                return
            }

            let resolvedStage = self.resolvedRenderStage(
                requestedStage: stage,
                windowId: windowId,
                state: parsed,
                generation: generation
            )
            if resolvedStage != stage {
                self.pendingRenderRefresh = (
                    windowId: windowId,
                    generation: generation,
                    stage: resolvedStage
                )
                Self.logDiagnostic(
                    "render-refresh promoted window=\(windowId) generation=\(generation) from=\(stage) to=\(resolvedStage) pane=\(parsed.paneId) paneAlt=\(parsed.paneInAltScreen)"
                )
            }

            self.captureRenderedWindow(
                windowId: windowId,
                state: parsed,
                generation: generation,
                reason: reason,
                stage: resolvedStage
            )
        }
    }

    private func resolvedRenderStage(
        requestedStage: RenderStage,
        windowId: WindowId,
        state: RenderedPaneState,
        generation: Int
    ) -> RenderStage {
        guard requestedStage == .viewportOnly else { return requestedStage }
        let previousRenderedWindowId = renderedWindowId ?? abortedRenderedWindowId
        let terminalAltScreen = terminalIsInAltScreen?() == true
        let retainedOutputCanAdvanceTerminalState = foregroundOutputRefreshGeneration == generation
            && coalescedForegroundOutput[state.paneId]?.isEmpty == false
        let canRefreshInPlace = previousRenderedWindowId == windowId
            && renderedPaneId == state.paneId
            && (terminalAltScreen == state.paneInAltScreen || retainedOutputCanAdvanceTerminalState)
        return canRefreshInPlace ? .viewportOnly : .viewport
    }

    private func captureRenderedWindow(
        windowId: WindowId,
        state: RenderedPaneState,
        generation: Int,
        reason: String,
        stage: RenderStage
    ) {
        switch stage {
        case .viewport, .viewportOnly:
            captureViewport(windowId: windowId, state: state, generation: generation, reason: reason, stage: stage)
        case .deep where state.paneInAltScreen:
            captureDeepAltScreen(windowId: windowId, state: state, generation: generation, reason: reason)
        case .deep:
            captureDeepPrimary(windowId: windowId, state: state, generation: generation, reason: reason)
        }
    }

    private func captureViewport(
        windowId: WindowId,
        state: RenderedPaneState,
        generation: Int,
        reason: String,
        stage: RenderStage
    ) {
        sendCaptureCommand(
            "capture-pane -p -e -N -t \(windowId.description)",
            windowId: windowId,
            generation: generation,
            stage: stage,
            failureReason: "capture"
        ) { [weak self] captureLines in
            self?.finishRenderedWindowRefresh(
                windowId: windowId,
                state: state,
                generation: generation,
                stage: stage,
                reason: reason,
                captureLines: captureLines,
                historyLines: [],
                savedPrimaryLines: [],
                altScreenLines: state.paneInAltScreen ? captureLines : nil
            )
        }
    }

    private func captureDeepPrimary(
        windowId: WindowId,
        state: RenderedPaneState,
        generation: Int,
        reason: String
    ) {
        let depth = max(0, deepRepaintHistoryDepth)
        sendCaptureCommand(
            "capture-pane -p -e -N -S -\(depth) -t \(windowId.description)",
            windowId: windowId,
            generation: generation,
            stage: .deep,
            failureReason: "deep-capture"
        ) { [weak self] captureLines in
            guard let self else { return }
            let finish: ([String]?) -> Void = { [weak self] scrubLines in
                self?.finishRenderedWindowRefresh(
                    windowId: windowId,
                    state: state,
                    generation: generation,
                    stage: .deep,
                    reason: reason,
                    captureLines: captureLines,
                    historyLines: [],
                    savedPrimaryLines: [],
                    altScreenLines: nil,
                    scrubLines: scrubLines
                )
            }
            // The ghost scrub (finishRenderedWindowRefresh) re-paints the
            // visible screen after the deep feed. It must NOT reuse a suffix
            // slice of this deep capture: capture-pane -e emits SGR
            // cumulatively, so a slice can start mid-run with its bg/fg
            // openers stranded above the boundary — legitimate colors repaint
            // as default (the full-width black band). tmux re-serializes all
            // open SGR state at row 0 of a viewport-only capture, so chain a
            // fresh one whenever the scrub will run (history scrolled).
            guard let visibleRows = self.lastKnownSize?.rows,
                  visibleRows > 0,
                  captureLines.count > visibleRows
            else {
                finish(nil)
                return
            }
            self.sendCaptureCommand(
                "capture-pane -p -e -N -t \(windowId.description)",
                windowId: windowId,
                generation: generation,
                stage: .deep,
                failureReason: "deep-scrub"
            ) { scrubLines in
                finish(scrubLines)
            }
        }
    }

    private func captureDeepAltScreen(
        windowId: WindowId,
        state: RenderedPaneState,
        generation: Int,
        reason: String
    ) {
        let sendSavedPrimary: ([String]) -> Void = { [weak self] historyLines in
            guard let self else { return }
            self.sendCaptureCommand(
                "capture-pane -p -e -N -a -q -t \(windowId.description)",
                windowId: windowId,
                generation: generation,
                stage: .deep,
                failureReason: "deep-saved-primary"
            ) { [weak self] savedPrimaryLines in
                self?.sendCaptureCommand(
                    "capture-pane -p -e -N -t \(windowId.description)",
                    windowId: windowId,
                    generation: generation,
                    stage: .deep,
                    failureReason: "deep-alt"
                ) { [weak self] altScreenLines in
                    self?.finishRenderedWindowRefresh(
                        windowId: windowId,
                        state: state,
                        generation: generation,
                        stage: .deep,
                        reason: reason,
                        captureLines: altScreenLines,
                        historyLines: historyLines,
                        savedPrimaryLines: savedPrimaryLines,
                        altScreenLines: altScreenLines
                    )
                }
            }
        }

        guard (state.historySize ?? 0) > 0 else {
            sendSavedPrimary([])
            return
        }

        let depth = max(0, deepRepaintHistoryDepth)
        sendCaptureCommand(
            "capture-pane -p -e -N -S -\(depth) -E -1 -t \(windowId.description)",
            windowId: windowId,
            generation: generation,
            stage: .deep,
            failureReason: "deep-history"
        ) { historyLines in
            sendSavedPrimary(historyLines)
        }
    }

    private func sendCaptureCommand(
        _ command: String,
        windowId: WindowId,
        generation: Int,
        stage: RenderStage,
        failureReason: String,
        onSuccess: @escaping ([String]) -> Void
    ) {
        sendControlCommand(command) { [weak self] result in
            guard let self else { return }
            guard self.isCurrentGeneration(generation),
                  self.controlPath == .inline,
                  self.activeWindowId == windowId
            else {
                self.clearPendingRenderRefresh(windowId: windowId, generation: generation)
                Self.logDiagnostic(
                    "render-refresh capture stale window=\(windowId) generation=\(generation) stage=\(stage) result='\(Self.describe(result))'"
                )
                return
            }
            guard case .success(let captureLines) = result else {
                self.abortRenderRefreshIfCurrent(
                    windowId: windowId,
                    generation: generation,
                    stage: stage,
                    reason: failureReason
                )
                Self.logDiagnostic(
                    "render-refresh capture failed window=\(windowId) generation=\(generation) stage=\(stage) result='\(Self.describe(result))'"
                )
                return
            }
            onSuccess(captureLines)
        }
    }

    private func clearPendingRenderRefresh(windowId: WindowId, generation: Int) {
        guard let pending = pendingRenderRefresh,
              pending.windowId == windowId,
              pending.generation == generation
        else { return }
        pendingRenderRefresh = nil
    }

    /// Paint captured tmux state into SwiftTerm and restore the terminal
    /// modes tmux reported for the active pane.
    ///
    /// Scrollback is cleared via the host's `changeScrollback` toggle, not
    /// `ESC[3J`. The historical reason (SwiftTerm trimmed `buffer.lines`
    /// without resyncing the UIScrollView geometry → black screen) is fixed
    /// in the fork as of d34c15f, so remote `[3J` is safe; the toggle stays
    /// because it is golden-tested and shipped, and the mosh path needs it
    /// anyway (render-inert side channel — no controller byte stream to
    /// carry a `[3J`).
    private func finishRenderedWindowRefresh(
        windowId: WindowId,
        state: RenderedPaneState,
        generation: Int,
        stage: RenderStage,
        reason: String,
        captureLines: [String],
        historyLines: [String],
        savedPrimaryLines: [String],
        altScreenLines: [String]?,
        scrubLines: [String]? = nil
    ) {
        guard let feed = feedTerminal,
              isCurrentGeneration(generation),
              activeWindowId == windowId
        else {
            abortRenderRefreshIfCurrent(
                windowId: windowId,
                generation: generation,
                stage: stage,
                reason: "finish"
            )
            return
        }
        if awaitingAppForegroundRefresh {
            clearPendingRenderRefresh(windowId: windowId, generation: generation)
            Self.logDiagnostic(
                "render-refresh finish-deferred-inactive window=\(windowId) generation=\(generation) stage=\(stage) reason=\(reason)"
            )
            return
        }

        // Replay retained same-pane output in one synchronous call before the
        // captured viewport. This keeps every byte in SwiftTerm's local history
        // and applies any buffered alternate-screen transition before the
        // assembler inspects the terminal, while presenting no intermediate
        // frame between the batch and the authoritative repaint.
        let completesForegroundOutputCoalescing = foregroundOutputRefreshGeneration == generation
        if completesForegroundOutputCoalescing,
           stage == .viewportOnly,
           renderedPaneId == state.paneId {
            let retainedOutput = takeCoalescedForegroundOutput(for: state.paneId)
            if !retainedOutput.bytes.isEmpty {
                feed(ArraySlice(retainedOutput.bytes))
            }
        }

        let previousRenderedWindowId = renderedWindowId ?? abortedRenderedWindowId
        let terminalWasInAltScreen = terminalIsInAltScreen?() == true
        let refreshesRenderedPaneInPlace = stage == .viewportOnly
            && previousRenderedWindowId == windowId
            && renderedPaneId == state.paneId
            && terminalWasInAltScreen == state.paneInAltScreen
        abortedRenderedWindowId = nil
        if !refreshesRenderedPaneInPlace {
            displayWillSwap?(previousRenderedWindowId, windowId, state.paneInAltScreen)
        }
        let bytes = RepaintAssembly.assemble(
            state: state,
            captureLines: captureLines,
            historyLines: historyLines,
            savedPrimaryLines: savedPrimaryLines,
            altScreenLines: altScreenLines,
            terminalIsInAltScreen: terminalWasInAltScreen,
            clientRows: lastKnownSize?.rows,
            preservePrimaryDuringAltRefresh: refreshesRenderedPaneInPlace && state.paneInAltScreen
        )

        // Cross-window gray-block bleed repro signal: flag when this window's
        // capture ends with a non-default background still open. With one shared
        // terminal across tabs, that pen would bleed into the live %output that
        // resumes after the swap (the assembler appends a trailing reset to
        // prevent it). Switch onto a window whose TUI paints a full-row colored
        // input box (e.g. Codex) to trigger this.
        let tailContentLines = state.paneInAltScreen ? (altScreenLines ?? captureLines) : captureLines
        if RepaintAssembly.backgroundLeftOpen(in: tailContentLines) {
            Self.logDiagnostic(
                "repaint-bg-open window=\(windowId) from=\(previousRenderedWindowId?.description ?? "nil") stage=\(stage) paneAlt=\(state.paneInAltScreen) lines=\(tailContentLines.count) reason=\(reason)"
            )
        }

        // Width-mismatch repro signal for the "half-width gray box" bleed: if the
        // widest captured row is far narrower than the client column count we
        // last pushed to tmux, the capture was taken at a stale/smaller grid and
        // is being painted into a wider terminal, leaving the right margin to
        // show prior-frame content. clientCols == -1 means we never sized.
        let captureMaxCols = tailContentLines.reduce(0) { max($0, RepaintAssembly.visibleColumns(in: $1)) }
        Self.logDiagnostic(
            "repaint-width window=\(windowId) panes=\(window(windowId)?.paneCount ?? -1) grid=\(window(windowId)?.rendersAsPaneGrid == true) clientCols=\(lastKnownSize?.cols ?? -1) clientRows=\(lastKnownSize?.rows ?? -1) captureMaxCols=\(captureMaxCols) captureRows=\(tailContentLines.count) cursorX=\(state.cursorX) cursorY=\(state.cursorY) stage=\(stage)"
        )

        feed(ArraySlice(bytes))

        // Half-width gray-box ghost scrub. The deep/history repaint feeds the
        // full scrollback (thousands of rows) through SwiftTerm in one burst,
        // scrolling ~all of it up into the buffer. That scroll exercises
        // SwiftTerm's iOS scroll path, which can leave a scrolled row's RIGHT
        // half holding the previous frame's background in the cell model — the
        // "half-width gray box" at the screen midpoint (cols >= width/2). So
        // after the deep scroll lands the history, re-paint just the visible
        // screen on top of it to scrub any ghost. ESC[2J inside the repaint
        // clears only the visible screen, so the scrolled-in scrollback is
        // preserved.
        //
        // The scrub paints from `scrubLines` — a fresh viewport capture that
        // captureDeepPrimary chains after the deep one — NEVER from a suffix
        // slice of `captureLines`. capture-pane -e emits SGR cumulatively:
        // an opener appears once and is inherited by every later row, so a
        // mid-stream slice strands bg/fg/attr openers above its boundary and
        // RepaintAssembly's fresh pen paints those rows in default colors
        // (full-width black band over a colored panel — the artifact this
        // used to cause when it sliced the deep capture). A viewport-only
        // capture is self-contained: tmux re-serializes all open SGR state
        // at row 0. When no chained capture landed (scrubLines == nil),
        // skip the scrub outright rather than fall back to a slice.
        // Scoped to the non-alt deep stage where the ghost was observed and
        // only when real history scrolled (more captured rows than fit on
        // screen); tests pass tiny captures / no size, so this stays inert
        // there and leaves the golden deep-stage byte spec unchanged.
        if stage == .deep,
           !state.paneInAltScreen,
           !terminalWasInAltScreen,
           let scrubLines,
           let visibleRows = lastKnownSize?.rows,
           visibleRows > 0,
           captureLines.count > visibleRows {
            let scrubBytes = RepaintAssembly.assemble(
                state: state,
                captureLines: scrubLines,
                historyLines: [],
                savedPrimaryLines: [],
                altScreenLines: nil,
                terminalIsInAltScreen: false,
                clientRows: visibleRows
            )
            feed(ArraySlice(scrubBytes))
            Self.logDiagnostic(
                "repaint-scrub window=\(windowId) visibleRows=\(visibleRows) deepRows=\(captureLines.count) scrubRows=\(scrubLines.count) source=fresh-viewport reason=\(reason)"
            )
        }

        markInitialRenderReady()
        establishedRenderIsFailClosed = false
        renderedWindowId = windowId
        renderedPaneId = state.paneId
        if pausedPanes.contains(state.paneId) {
            resumePausedPane(state.paneId)
        }
        activePaneId = state.paneId
        updateWindowMetadata(
            windowId: windowId,
            windowName: state.windowName,
            activePaneId: state.paneId,
            activePaneTitle: state.paneTitle,
            activePaneTitleIsDefault: state.paneTitleIsDefault,
            clearTitleWhenMissing: true
        )
        renderRetryAttemptsByGeneration[generation] = nil
        if !refreshesRenderedPaneInPlace {
            displayDidSwap?(windowId)
        } else {
            displayDidRefresh?(windowId)
        }
        clearPendingRenderRefresh(windowId: windowId, generation: generation)
        if completesForegroundOutputCoalescing {
            endForegroundOutputCoalescing()
        }
        if (stage == .viewport || (stage == .viewportOnly && !refreshesRenderedPaneInPlace)),
           isCurrentGeneration(generation),
           activeWindowId == windowId {
            refreshRenderedWindow(
                windowId: windowId,
                generation: generation,
                reason: "\(reason)-deep",
                stage: .deep
            )
        }
    }

    struct RenderedPaneState {
        let paneId: PaneId
        let cursorX: Int
        let cursorY: Int
        let paneTitle: String?
        let paneTitleIsDefault: Bool
        let windowName: String?
        let paneInAltScreen: Bool
        let historySize: Int?
        let scrollRegionUpper: Int?
        let scrollRegionLower: Int?
        let cursorVisible: Bool?
        let insertMode: Bool?
        let keypadCursor: Bool?
        let keypadApplication: Bool?
        let wrapMode: Bool?
        let mouseStandard: Bool?
        let mouseButton: Bool?
        let mouseAll: Bool?
        let mouseSgr: Bool?
        let originMode: Bool?
        let altSavedX: Int?
        let altSavedY: Int?

        var isMouseReporting: Bool {
            mouseStandard == true || mouseButton == true || mouseAll == true
        }
    }

    /// Parse the body line of the inline render metadata query.
    /// Expected format:
    /// `renderedPaneMetadataFormat`, with the seven-field legacy prefix
    /// still accepted.
    ///
    /// `alternate_on` must stay at index 6; capping maxSplits would merge
    /// all appended fields into it and make alt-screen detection fail.
    static func parseRenderedPaneState(_ line: String) -> RenderedPaneState? {
        let parts = line.split(
            separator: "\t",
            omittingEmptySubsequences: false
        )
        guard parts.count >= 3,
              let paneId = parsePaneIdString(String(parts[0])),
              let cursorX = Int(parts[1]),
              let cursorY = Int(parts[2])
        else { return nil }
        let title = parts.count >= 4 ? nonEmpty(String(parts[3])) : nil
        let host = parts.count >= 6 ? nonEmpty(String(parts[5])) : nil
        return RenderedPaneState(
            paneId: paneId,
            cursorX: cursorX,
            cursorY: cursorY,
            paneTitle: title,
            paneTitleIsDefault: isDefaultPaneTitle(title, host: host),
            windowName: parts.count >= 5 ? nonEmpty(String(parts[4])) : nil,
            // Known transient: alternate_on is sampled at metadata time;
            // a pane flipping 1049 between this query and the captures
            // can mis-branch one repaint. Self-heals on the pane's next
            // output or swap — same exposure class as the resize race.
            paneInAltScreen: optionalFlag(parts, 6) ?? false,
            historySize: optionalInt(parts, 7),
            scrollRegionUpper: optionalInt(parts, 8),
            scrollRegionLower: optionalInt(parts, 9),
            cursorVisible: optionalFlag(parts, 10),
            insertMode: optionalFlag(parts, 11),
            keypadCursor: optionalFlag(parts, 12),
            keypadApplication: optionalFlag(parts, 13),
            wrapMode: optionalFlag(parts, 14),
            mouseStandard: optionalFlag(parts, 15),
            mouseButton: optionalFlag(parts, 16),
            mouseAll: optionalFlag(parts, 17),
            mouseSgr: optionalFlag(parts, 18),
            originMode: optionalFlag(parts, 19),
            altSavedX: optionalCoordinate(parts, 20),
            altSavedY: optionalCoordinate(parts, 21)
        )
    }

    private static func optionalInt(_ parts: [Substring], _ index: Int) -> Int? {
        guard parts.indices.contains(index) else { return nil }
        let value = String(parts[index])
        guard !value.isEmpty else { return nil }
        return Int(value)
    }

    /// tmux expands `alternate_saved_x/y` as u_int, so "no saved
    /// cursor" arrives as 4294967295 (UINT_MAX), not an empty string.
    /// Anything beyond tmux's SHRT_MAX coordinate range is a sentinel.
    private static func optionalCoordinate(_ parts: [Substring], _ index: Int) -> Int? {
        guard let value = optionalInt(parts, index), value >= 0, value <= 32767 else {
            return nil
        }
        return value
    }

    private static func optionalFlag(_ parts: [Substring], _ index: Int) -> Bool? {
        guard let value = optionalInt(parts, index) else { return nil }
        return value != 0
    }

    /// Parse a tmux `%<id>` pane-id string into a `PaneId`.
    /// Returns nil for malformed input.
    private static func parsePaneIdString(_ s: String) -> PaneId? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("%"), let n = Int(trimmed.dropFirst()) else { return nil }
        return PaneId(n)
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
