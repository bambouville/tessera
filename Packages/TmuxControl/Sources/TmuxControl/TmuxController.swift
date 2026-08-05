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
    public static let gridAuthorityOption = "@tessera_authority"
    static let gridAuthoritySubscriptionName = "tessera-authority"

    /// Identity this client stamps into `gridAuthorityOption` when it takes
    /// the grid. `id` must be stable per app install; `displayName` is shown
    /// on the peer's takeover overlay ("continued on iPhone").
    public struct GridAuthorityIdentity: Equatable, Sendable {
        public let id: String
        public let displayName: String

        public init(id: String, displayName: String) {
            self.id = TmuxController.sanitizedAuthorityToken(id)
            self.displayName = TmuxController.sanitizedAuthorityToken(displayName)
        }
    }

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

    /// How this control client participates in tmux window sizing.
    ///
    /// App clients use `resizeTmux`: each visible terminal pushes its physical
    /// viewport with `refresh-client -C`, allowing tmux to choose the current
    /// grid from all attached device sizes. `preserveServerGeometry` remains
    /// available for non-rendering observer clients that attach with tmux's
    /// `ignore-size` flag.
    public enum ClientSizePolicy: Sendable {
        case resizeTmux
        case preserveServerGeometry
    }


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
    }

    /// Metadata describing one shared-terminal feed without retaining its
    /// payload. Optional repaint fields make it possible to distinguish a
    /// live-output storm from one large capture-pane repaint in diagnostics.
    public struct TerminalFeedContext: Equatable, Sendable {
        public let source: TerminalFeedSource
        public let paneId: PaneId?
        public let windowId: WindowId?
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
            generation: Int? = nil,
            captureRows: Int? = nil,
            reason: String? = nil,
            originalByteCount: Int? = nil
        ) {
            self.source = source
            self.paneId = paneId
            self.windowId = windowId
            self.generation = generation
            self.captureRows = captureRows
            self.reason = reason
            self.originalByteCount = originalByteCount
        }
    }

    enum RenderStage: Equatable, Sendable {
        case viewport
        /// Refresh the already-rendered window/pane in place. Unlike a real
        /// window swap, this must not clear and rebuild local scrollback.
        case viewportOnly
        case deep
    }

    private enum CaptureBodyPolicy {
        /// A visible or full-grid `capture-pane -p` must describe at least one
        /// terminal row. tmux represents a blank grid as empty row strings.
        case requiredGrid
        /// Supplemental alternate-screen captures are optional: history can
        /// disappear between metadata and capture, and `capture-pane -a -q`
        /// succeeds with no body when there is no saved primary grid.
        case optionalSupplement
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
    /// Guard tuple from the `%begin` that opened `inflightLines`. tmux emits
    /// the same tuple on the closing `%end`/`%error`; retaining it lets us
    /// diagnose corruption and classify the frame without trusting one
    /// potentially malformed closing flags field.
    @ObservationIgnored private var inflightFrameGuard: (
        time: Int,
        commandNumber: Int,
        flags: Int
    )?

    /// Last-known client size (cols × rows). Refreshed by
    /// `updateClientSize(cols:rows:)` from the outer view whenever
    /// SwiftTerm's `sizeChanged` delegate fires. Used both to push
    /// `refresh-client -C` to tmux while in control mode *and* to
    /// send the current size as soon as we enter tmux mode — the
    /// PTY-level SIGWINCH the SSH session sends is ignored by tmux
    /// in `-CC`, so without this the pane stays at whatever size the
    /// PTY happened to be at the moment `tmux -CC` was launched.
    @ObservationIgnored private var lastKnownSize: (cols: Int, rows: Int)?

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
    /// True from a reclaim request until geometry is confirmed and any
    /// required authoritative repaint has been issued/completed (or the
    /// claim timeout folds the spinner back). Drives the overlay's
    /// "taking back control…" phase.
    public private(set) var gridAuthorityReclaimInFlight = false
    /// Set by the owner after construction (like `feedTerminal`). Nil means
    /// this client does not participate in grid-authority stamping — e.g.
    /// harness observers.
    @ObservationIgnored public var gridAuthorityIdentity: GridAuthorityIdentity?
    /// Compact grid presentation mounts only the active pane. Keep authority
    /// repaint completion aligned with the surfaces that actually exist;
    /// regular-width and unzoomed grids repaint every rendered pane.
    @ObservationIgnored public private(set) var gridAuthorityUsesCompactSinglePaneGrid = false
    /// Fired only after a peer-departure auto-reclaim has actually settled,
    /// so the app cannot announce control while the old grid is still live.
    /// The argument is the departed peer label captured before `.mine`
    /// replaces the peer state.
    @ObservationIgnored public var onGridAuthorityAutoReclaimed: ((String?) -> Void)?
    /// Mosh owns visible repainting outside the control channel. Called after
    /// side-channel geometry settles but before the veil lifts. The Bool says
    /// whether the claim changed geometry (and therefore whether the normal
    /// layout observer should suppress its duplicate repaint). The UInt64 is
    /// the claim generation that must be acknowledged after the exact forced
    /// framebuffer has been consumed by the terminal surface.
    @ObservationIgnored public var onGridAuthoritySideChannelRepaintRequired: ((Bool, UInt64) -> Void)?
    @ObservationIgnored private var gridAuthorityGeneration = 0
    @ObservationIgnored private var lastSeenAuthorityRawValue: String?
    @ObservationIgnored private var gridAuthorityPeerCheckInFlight = false
    @ObservationIgnored private var gridAuthorityReclaimTimeoutTask: Task<Void, Never>?
    /// True once this controller has completed a claiming attach. Every later
    /// attach (auto-reconnect, session change) re-derives authority from the
    /// stamp instead of stealing the grid — a takeover can happen during ANY
    /// drop, not just one that began while yielded (T6). Never reset: only a
    /// fresh controller (a user-initiated connect) claims blindly.
    @ObservationIgnored private var gridAuthorityHasAttachedOnce = false
    /// A claim's server-side effects (stamp + size + fence) cannot be
    /// recalled, so this stays armed after the 3s UI timeout folds the
    /// spinner back: a late-settling claim still completes when geometry
    /// finally matches, instead of stranding both devices veiled. Cleared on
    /// completion, contest, or reset.
    @ObservationIgnored private var gridAuthorityClaimPending = false
    /// True only after the server has processed the size replay and the
    /// inline latest-client transfer (when applicable). Geometry can arrive
    /// from an older notification while those commands are still queued, so
    /// it must never settle a claim before this fence lands.
    @ObservationIgnored private var gridAuthorityClaimFenceAcknowledged = false
    /// Diagnostic count of current-window moves observed during this claim.
    /// Every move starts a new fence generation; stale callbacks reject
    /// themselves, while the final settled window always gets a completion
    /// path instead of being stranded behind an arbitrary retry limit.
    @ObservationIgnored private var gridAuthorityRefenceCount = 0
    /// Invalidates an older policy/fence chain when the current tmux window
    /// moves during a claim. Claim generation alone is not enough: every
    /// re-fence belongs to the same claim.
    @ObservationIgnored private var gridAuthorityFenceGeneration: UInt64 = 0
    /// Monotonic identity for the active claim. A timed-out claim's command
    /// replies can arrive after the user retries; those old fences must not
    /// acknowledge the replacement claim.
    @ObservationIgnored private var gridAuthorityClaimGeneration: UInt64 = 0
    /// The effective current-window `window-size` policy must be known before
    /// a fence can settle the claim. It is re-probed for every claim and every
    /// current-window move, rather than cached from attach time.
    @ObservationIgnored private var gridAuthorityClaimPolicyResolved = false
    @ObservationIgnored private var gridAuthorityFenceTarget: WindowId?
    /// Whether this claim began with a different/unknown server grid. Latched
    /// before the size replay so a matching `%layout-change` cannot erase the
    /// fact that the visible terminal needs one resynchronizing repaint.
    @ObservationIgnored private var gridAuthorityClaimChangedGeometry = false
    /// Manual Refresh is a repaint request even when geometry already matches.
    @ObservationIgnored private var gridAuthorityClaimForcesRepaint = false
    /// Inline repaint completion targets. The authority remains `.peer` while
    /// these are armed, keeping the veil above the terminal until captured tmux
    /// truth has actually been fed into every visible surface.
    @ObservationIgnored private var gridAuthorityRepaintWindow: WindowId?
    @ObservationIgnored private var gridAuthorityRepaintPanes: Set<PaneId> = []
    #if DEBUG
    var gridAuthorityRepaintPaneTargetsForTesting: Set<PaneId> {
        gridAuthorityRepaintPanes
    }

    func setGridAuthorityGeometryPolicyForTesting(latest: Bool) {
        gridAuthorityGeometryPolicyKnown = true
        gridAuthorityGeometryPolicyIsLatest = latest
    }

    func expireGridAuthorityReclaimPresentationForTesting() {
        gridAuthorityReclaimInFlight = false
    }
    #endif
    /// Side-channel repaint acknowledgement. Mosh rendering is asynchronous
    /// to `-CC`; the app clears this only after the forced framebuffer output
    /// has actually been consumed by the terminal surface.
    @ObservationIgnored private var gridAuthoritySideChannelRepaintPending = false
    @ObservationIgnored private var gridAuthoritySideChannelRepaintGeneration: UInt64 = 0
    /// Peer label retained across the auto-reclaim because settling changes
    /// `gridAuthority` to `.mine` before the UI toast is delivered.
    @ObservationIgnored private var gridAuthorityAutoReclaimPeerName: String?
    /// Exact stamp written by a reconnect that first re-derived a non-foreign
    /// owner. The subscription registration is already queued by then, so an
    /// intervening foreign value can arrive before this write's echo. Matching
    /// the exact echo lets that rare ordering re-enter the normal fenced claim
    /// path instead of leaving the client veiled after its own later write won.
    @ObservationIgnored private var gridAuthorityReconnectClaimExpectedStamp: String?
    /// Reconnects query the session stamp before replaying any local size.
    /// Ignore geometry-only fallback during that FIFO gap: a stale layout
    /// notification can precede the query response and must not manufacture a
    /// generic peer that then blocks an otherwise valid self re-claim.
    @ObservationIgnored private var gridAuthorityRederiveInFlight = false
    /// False when the current window's effective `window-size` option is not
    /// `latest` —
    /// smallest/largest computes the grid across ALL clients, so our size
    /// can never win: the layout fallback would false-veil and the equality
    /// confirm could never pass.
    @ObservationIgnored private var gridAuthorityGeometryPolicyIsLatest = true
    @ObservationIgnored private var gridAuthorityGeometryPolicyKnown = false
    /// Wall-clock of the last self-initiated size replay; the layout-mismatch
    /// fallback (stamp-less attachers) suppresses itself near our own resizes.
    @ObservationIgnored private var lastClientSizeReplayAt: Date?
    /// Called after tmux acknowledges the authoritative grid cache and before
    /// the visible owner is excluded from sizing. App/session owners persist
    /// this grid beyond the lifetime of the current control connection.
    @ObservationIgnored public var onServerGeometryCeded: ((Int, Int) -> Void)?
    public let clientSizePolicy: ClientSizePolicy

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

    /// Bumped every time a `refresh-client -C` is actually sent. Repaint
    /// flows latch the epoch when their metadata query is sent and compare
    /// at apply time: commands are FIFO-serialized on the control channel,
    /// so a size replay sent mid-refresh resizes and reflows the pane
    /// between the cursor snapshot and the capture reply — the two then
    /// describe different grids and painting the pair misplaces rows and
    /// the restored cursor. Continuity resume hits this every time: the
    /// connect outraces the settling view layout (keyboard, safe area),
    /// so attach-init interleaves with 2–3 size events.
    @ObservationIgnored private var clientSizeEpoch = 0
    /// Consecutive repaints discarded for epoch mismatch. Bounded so a
    /// pathological size churn still paints SOMETHING — a misplaced
    /// cursor beats a terminal that stays empty.
    @ObservationIgnored private var renderSizeResyncAttempts = 0
    @ObservationIgnored private var paneSizeResyncAttempts: [PaneId: Int] = [:]
    private static let maxClientSizeResyncAttempts = 3

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

    /// Source-aware variant of `feedTerminal`. When set, it takes precedence
    /// over the legacy closure so existing package clients remain compatible.
    @ObservationIgnored public var feedTerminalWithContext: ((ArraySlice<UInt8>, TerminalFeedContext) -> Void)?

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
    /// Established repaints prefer an empty command FIFO so metadata and
    /// capture callbacks cannot inherit an older consumer's response body.
    /// The wait is bounded: resize/input traffic can otherwise keep one
    /// command perpetually in flight and starve the authoritative repaint.
    var renderCommandQueueMaxWait: TimeInterval = 0.25

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

    public init(
        controlPath: ControlPath = .inline,
        clientSizePolicy: ClientSizePolicy = .resizeTmux
    ) {
        self.controlPath = controlPath
        self.clientSizePolicy = clientSizePolicy
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

    /// Main-actor-friendly ingestion for an interactive renderer. Control
    /// messages retain their strict synchronous ordering, while live pane
    /// payloads are delivered in bounded slices with cooperative yields. The
    /// legacy synchronous API remains available for package clients and tests
    /// that do not own a UI run loop.
    public func ingestCooperatively(_ chunk: [UInt8]) async {
        switch mode {
        case .passthrough:
            await handlePassthroughCooperatively(chunk)
        case .tmuxControl:
            let parseStart = IngestStageStats.now()
            let messages = parser.feed(chunk)
            ingestStages.parseMs += IngestStageStats.elapsedMs(since: parseStart)
            await processCooperatively(messages: messages)
        }
        ingestStages.noteCall()
        ingestStages.flushIfDue(log: { Self.logDiagnostic($0) })
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
            paneSizeResyncAttempts.removeValue(forKey: paneId)
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
        paneSizeResyncAttempts.removeAll()
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
        foregroundRecovery: Bool,
        queueWaitStartedAt: TimeInterval? = nil
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
                let now = ProcessInfo.processInfo.systemUptime
                let startedAt = queueWaitStartedAt ?? now
                let elapsed = now - startedAt
                if elapsed < max(0, renderCommandQueueMaxWait) {
                    if queueWaitStartedAt == nil {
                        Self.logDiagnostic(
                            "foreground-pane wait-command-queue controller=\(diagnosticID) pane=\(paneId) request=\(requestID) pending=\(pendingCommands.count) maxWaitMs=\(Int(renderCommandQueueMaxWait * 1_000))"
                        )
                    }
                    waitForCommandQueueBeforeForegroundPaneRender(
                        paneId: paneId,
                        requestID: requestID,
                        deep: deep,
                        startedAt: startedAt
                    )
                    return
                }
                Self.logDiagnostic(
                    "foreground-pane command-queue-wait-expired controller=\(diagnosticID) pane=\(paneId) request=\(requestID) pending=\(pendingCommands.count) waitedMs=\(Int(elapsed * 1_000))"
                )
            }
        }
        let target = paneId.description
        let sizeEpoch = clientSizeEpoch
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
            self.capturePane(paneId: paneId, state: state, requestID: requestID, deep: wantsDeep, sizeEpoch: sizeEpoch)
        }
    }

    private func capturePane(
        paneId: PaneId,
        state: RenderedPaneState,
        requestID: Int,
        deep: Bool,
        sizeEpoch: Int
    ) {
        let target = paneId.description
        let depth = deep ? max(0, deepRepaintHistoryDepth) : 0

        if state.paneInAltScreen {
            // history → saved primary → alt-screen viewport (mirrors the shared
            // captureDeepAltScreen chain, pane-targeted).
            let captureAlt: ([String], [String]) -> Void = { [weak self] history, savedPrimary in
                guard let self else { return }
                self.sendPaneSettledCapture(
                    paneId: paneId,
                    requestID: requestID,
                    expectedAltScreen: true,
                    deep: deep
                ) { settledState, altLines in
                    self.finishPaneRefresh(
                        paneId: paneId, state: settledState, requestID: requestID,
                        captureLines: altLines, historyLines: history,
                        savedPrimaryLines: savedPrimary, altScreenLines: altLines, deep: deep,
                        sizeEpoch: sizeEpoch
                    )
                }
            }
            let captureSavedPrimary: ([String]) -> Void = { [weak self] history in
                guard let self else { return }
                self.sendPaneCapture(
                    "capture-pane -p -e -N -a -q -t \(target)",
                    paneId: paneId,
                    requestID: requestID,
                    bodyPolicy: .optionalSupplement
                ) { savedPrimary in
                    captureAlt(history, savedPrimary)
                }
            }
            if deep, (state.historySize ?? 0) > 0 {
                sendPaneCapture(
                    "capture-pane -p -e -N -S -\(depth) -E -1 -t \(target)",
                    paneId: paneId,
                    requestID: requestID,
                    bodyPolicy: .optionalSupplement
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
            guard let self else { return }
            guard deep else {
                self.finishPaneRefresh(
                    paneId: paneId, state: state, requestID: requestID,
                    captureLines: lines, historyLines: [], savedPrimaryLines: [],
                    altScreenLines: nil, deep: false,
                    sizeEpoch: sizeEpoch
                )
                return
            }
            self.sendPaneSettledCapture(
                paneId: paneId,
                requestID: requestID,
                expectedAltScreen: false,
                deep: true
            ) { settledState, scrubLines in
                self.finishPaneRefresh(
                    paneId: paneId, state: settledState, requestID: requestID,
                    captureLines: lines, historyLines: [], savedPrimaryLines: [],
                    altScreenLines: nil, scrubLines: scrubLines, deep: true,
                    sizeEpoch: sizeEpoch
                )
            }
        }
    }

    private func sendPaneSettledCapture(
        paneId: PaneId,
        requestID: Int,
        expectedAltScreen: Bool,
        deep: Bool,
        onSuccess: @escaping (RenderedPaneState, [String]) -> Void
    ) {
        let target = paneId.description
        enqueueControlCommandPair(
            "display-message -p -t \(target) '\(Self.renderedPaneMetadataFormat)'",
            "capture-pane -p -e -N -t \(target)"
        ) { [weak self] metadataResult, captureResult in
            guard let self else { return }
            guard self.paneSinks[paneId] != nil,
                  self.pendingPaneRefreshes[paneId] == requestID
            else {
                self.failPaneRefresh(paneId: paneId, requestID: requestID)
                return
            }
            guard case .success(let metadataLines) = metadataResult,
                  let head = metadataLines.first(where: { !$0.isEmpty }),
                  let settledState = Self.parseRenderedPaneState(head),
                  case .success(let captureLines) = captureResult,
                  !captureLines.isEmpty
            else {
                self.failPaneRefresh(paneId: paneId, requestID: requestID)
                return
            }
            guard settledState.paneId == paneId,
                  settledState.paneInAltScreen == expectedAltScreen
            else {
                let inheritsForegroundRecovery = self.foregroundPaneRefreshTargets[paneId] == requestID
                self.pendingPaneRefreshes.removeValue(forKey: paneId)
                Self.logDiagnostic(
                    "pane-refresh settled-state changed pane=\(paneId) request=\(requestID) newPane=\(settledState.paneId) expectedAlt=\(expectedAltScreen) actualAlt=\(settledState.paneInAltScreen)"
                )
                self.refreshPane(
                    paneId: paneId,
                    deep: deep,
                    foregroundRecovery: inheritsForegroundRecovery
                )
                return
            }
            onSuccess(settledState, captureLines)
        }
    }

    private func sendPaneCapture(
        _ command: String,
        paneId: PaneId,
        requestID: Int,
        bodyPolicy: CaptureBodyPolicy = .requiredGrid,
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
            if case .requiredGrid = bodyPolicy, lines.isEmpty {
                Self.logDiagnostic(
                    "pane-refresh capture rejected-empty pane=\(paneId) request=\(requestID) commandCategory=\(Self.commandCategory(command)) clientRows=\(self.lastKnownSize?.rows ?? -1)"
                )
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
        scrubLines: [String]? = nil,
        deep: Bool,
        sizeEpoch: Int
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
        // Same size-epoch atomicity as finishRenderedWindowRefresh: a client
        // resize processed between this pane's metadata query and its capture
        // reply means cursor and grid describe different geometries — discard
        // and re-run instead of painting a shifted frame.
        if sizeEpoch != clientSizeEpoch,
           paneSizeResyncAttempts[paneId, default: 0] < Self.maxClientSizeResyncAttempts {
            paneSizeResyncAttempts[paneId, default: 0] += 1
            let inheritsForegroundRecovery = foregroundPaneRefreshTargets[paneId] == requestID
            pendingPaneRefreshes.removeValue(forKey: paneId)
            Self.logDiagnostic(
                "pane-refresh size-resync pane=\(paneId) request=\(requestID) attempt=\(paneSizeResyncAttempts[paneId] ?? 0) deep=\(deep)"
            )
            refreshPane(
                paneId: paneId,
                deep: deep,
                foregroundRecovery: inheritsForegroundRecovery
            )
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
        if deep,
           !state.paneInAltScreen,
           let scrubLines {
            let scrubBytes = RepaintAssembly.assemble(
                state: state,
                captureLines: scrubLines,
                historyLines: [],
                savedPrimaryLines: [],
                altScreenLines: nil,
                terminalIsInAltScreen: false,
                clientRows: nil
            )
            sink(ArraySlice(scrubBytes))
            Self.logDiagnostic(
                "repaint-scrub pane=\(paneId) deepRows=\(captureLines.count) scrubRows=\(scrubLines.count) source=fresh-viewport"
            )
        }
        pendingPaneRefreshes.removeValue(forKey: paneId)
        paneSizeResyncAttempts.removeValue(forKey: paneId)
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
        completeGridAuthorityPaneRepaintIfNeeded(paneId: paneId)
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
        deep: Bool,
        startedAt: TimeInterval
    ) {
        foregroundPaneRetryTasks.removeValue(forKey: paneId)?.cancel()
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
                    foregroundRecovery: true,
                    queueWaitStartedAt: startedAt
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
            guard !userMutationsSuppressedWhileYielded else { return }
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

        var firstResult: Result<[String], CommandError>?
        nextCommandSequence &+= 1
        let first = PendingCommand(
            sequence: nextCommandSequence,
            command: firstCommand,
            completion: { result in firstResult = result }
        )
        nextCommandSequence &+= 1
        let second = PendingCommand(
            sequence: nextCommandSequence,
            command: secondCommand,
            completion: { result in
                completion(firstResult ?? .failure(.cancelled), result)
            }
        )
        transmitControlCommandPair(first, second)
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
        let firstLine = first.command.hasSuffix("\n") ? first.command : first.command + "\n"
        let secondLine = second.command.hasSuffix("\n") ? second.command : second.command + "\n"
        sendBytes?(Array((firstLine + secondLine).utf8))
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
            guard !captureLines.isEmpty else {
                Self.logDiagnostic(
                    "scrollback-capture rejected-empty pane=\(paneId) generation=\(generation) clientRows=\(clientRows ?? self.lastKnownSize?.rows ?? -1)"
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
        sendControlCommand("new-window -e COLORTERM=truecolor")
    }

    /// Ask tmux to kill the current window. tmux responds with
    /// `%window-close @N` and, if another window remains, a
    /// `%session-window-changed` naming the successor.
    public func killCurrentWindow() {
        guard !userMutationsSuppressedWhileYielded else { return }
        sendControlCommand("kill-window")
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
        sendControlCommand("kill-window -t \(windowId.description)")
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
        sendControlCommand("previous-window")
    }

    /// Next tmux window in the session (wraps).
    public func nextWindow() {
        guard !userMutationsSuppressedWhileYielded else { return }
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
        guard !userMutationsSuppressedWhileYielded else { return }
        guard mode == .tmuxControl,
              position >= 1,
              position <= windows.count
        else { return }
        let windowId = windows[position - 1].id
        clearBell(forWindowID: windowId.rawValue)
        sendControlCommand("select-window -t \(windowId.description)")
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
        if cols > 0, rows > 0 {
            localViewportSize = (cols, rows)
            if clientSizePolicy == .preserveServerGeometry,
               !reverseAttachPeers.isEmpty,
               reverseAttachBaselineSize == nil {
                reverseAttachBaselineSize = (cols, rows)
                considerReverseAttachCedeFromKnownWindows()
            }
        }
        if clientSizePolicy == .preserveServerGeometry {
            guard compactClientSizeRole == .owner,
                  !hasCededGridOwnership,
                  cols > 0,
                  rows > 0
            else {
                Self.logDiagnostic(
                    "client-size ignored local=\(cols)x\(rows) path=\(controlPath) policy=preserve-server role=\(String(describing: compactClientSizeRole))"
                )
                return
            }
            let previous = lastKnownSize
            lastKnownSize = (cols, rows)
            guard previous?.cols != cols || previous?.rows != rows else { return }
            replayClientSize(reason: "compact-owner-size-change", previous: previous)
            return
        }
        guard clientSizePolicy == .resizeTmux else {
            Self.logDiagnostic(
                "client-size ignored local=\(cols)x\(rows) path=\(controlPath) policy=preserve-server"
            )
            return
        }
        let previous = lastKnownSize
        lastKnownSize = (cols, rows)
        replayClientSize(reason: "size-change", previous: previous)
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

    private func replayClientSize(
        reason: String,
        previous: (cols: Int, rows: Int)? = nil,
        expectsReconnectClaimEcho: Bool = false,
        belongsToGridClaimFence: Bool = false
    ) {
        guard mode == .tmuxControl, let size = lastKnownSize else { return }
        // While yielded, local size churn (keyboard, rotation, split view)
        // must not steal the grid back from the active peer. The size stays
        // latched in `lastKnownSize`; a reclaim replays it explicitly.
        if gridAuthority.isPeer,
           !gridAuthorityReclaimInFlight,
           !gridAuthorityClaimPending {
            Self.logDiagnostic(
                "client-size deferred (yielded) cols=\(size.cols) rows=\(size.rows) reason=\(reason)"
            )
            return
        }
        // Logged so we can catch a transient bogus width (e.g. a half-width cols
        // during a layout/font transition) being pushed to tmux — that would
        // shrink the pane, and on the way back to full width the vacated columns
        // can keep stale background (the half-row gray bleed).
        Self.logDiagnostic(
            "client-size cols=\(size.cols) rows=\(size.rows) prevCols=\(previous?.cols ?? -1) prevRows=\(previous?.rows ?? -1) path=\(controlPath) reason=\(reason)"
        )
        // Stamp before the resize lands so peers can raise their veil ahead
        // of the first foreign-sized frame.
        let authorityStamp = writeGridAuthorityStamp(reason: reason)
        if expectsReconnectClaimEcho {
            gridAuthorityReconnectClaimExpectedStamp = authorityStamp
        }
        lastClientSizeReplayAt = Date()
        clientSizeEpoch &+= 1
        sendControlCommand("refresh-client -C \(size.cols),\(size.rows)")
        forceWindowSizesToClientSize(size)
        if gridAuthorityClaimPending, !belongsToGridClaimFence {
            // Keyboard/rotation churn can update the viewport while a claim's
            // first fence is still queued. Invalidate that fence and append a
            // new policy/fence after this newest replay; otherwise a non-latest
            // policy could acknowledge and expose the terminal before these
            // size commands have reached tmux.
            queueGridClaimFenceSequence(
                connectionGeneration: controlConnectionGeneration,
                claimGeneration: gridAuthorityClaimGeneration,
                reason: "pending-size-\(reason)",
                replaySize: false
            )
        }
    }

    /// `refresh-client -C` only resizes windows indirectly, via tmux's
    /// `window-size latest` recalculation — and that recalculation considers
    /// ONLY the window's latest-active client. Tessera's mosh topology
    /// attaches every visible client with `ignore-size` (so typing on one
    /// device can't yank the shared grid away from another), but the visible
    /// mosh client still claims `latest` every time its PTY resizes over SSP.
    /// From then on the recalculation finds no usable candidate ("no
    /// calculated size", verified against a tmux 3.4 -vv server log) and the
    /// window FREEZES at whatever transient it last applied — on iPhone,
    /// a mid-keyboard-animation height. The frozen window no longer matches
    /// the mosh PTY or the local grid, so the pane renders as a top-left crop
    /// with the content and cursor out of view until input scrolls it.
    ///
    /// So when the mosh side channel is the sizing authority, don't rely on
    /// the recalculation: force each window to the advertised size directly.
    /// `resize-window` stamps the per-window `window-size` option to
    /// `manual`; unset it right after so windows keep inheriting the
    /// session/global sizing behavior — a plain laptop tmux client attaching
    /// later must still resize windows natively.
    ///
    /// Scoped to the side channel: an inline `-CC` client has no separate
    /// visible PTY, so it cannot freeze its own session — only a mosh peer
    /// can freeze it, and that peer's own side channel re-asserts through
    /// this same path.
    ///
    /// Called from every client-size replay AND from window-list hydration:
    /// on a continuity resume the viewport is already settled when control
    /// mode comes up, so the only replay fires during attach-init — before
    /// the `list-windows` reply has populated `windows` — and no later size
    /// change ever replays again. Without the hydration call a frozen window
    /// stays frozen for the whole session (verified against a device
    /// diagnostics log: single 47x20 replay at attach, windows hydrate 80ms
    /// later, no further replay until the app returns to foreground).
    private func forceWindowSizesToClientSize(
        _ size: (cols: Int, rows: Int)
    ) {
        guard controlPath == .sideChannel,
              clientSizePolicy == .resizeTmux
        else { return }
        for window in windows {
            let target = window.id.description
            sendControlCommand(
                "resize-window -x \(size.cols) -y \(size.rows) -t \(target)"
            )
            sendControlCommand("set-option -w -u -t \(target) window-size")
        }
    }

    // MARK: - Continuity grid authority (takeover overlay)

    /// Whether this client stamps and observes grid authority. Observer
    /// clients (`preserveServerGeometry`) never contend for the grid, and a
    /// nil identity opts the whole mechanism out (tests, harnesses).
    private var participatesInGridAuthority: Bool {
        gridAuthorityIdentity != nil && clientSizePolicy == .resizeTmux
    }

    /// Restrict stamp tokens to a shell- and format-safe alphabet; the value
    /// travels inside single quotes on the control channel and back through
    /// a `%subscription-changed` line.
    nonisolated static func sanitizedAuthorityToken(_ raw: String) -> String {
        let allowed = raw.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".":
                return Character(scalar)
            default:
                return "-"
            }
        }
        let token = String(allowed)
        return token.isEmpty ? "-" : token
    }

    /// Device-scoped session option written by the visible mosh client. The
    /// side-channel uses its value to prove which tmux client instance belongs
    /// to this device before an automatic reclaim; client counts or reusable
    /// PTY names cannot distinguish a surviving peer after a partial disconnect.
    public nonisolated static func gridAuthorityVisibleClientOption(
        identityID: String
    ) -> String {
        "@tessera-visible-\(sanitizedAuthorityToken(identityID))"
    }

    /// Write our stamp into the session option. Called from every size
    /// replay, so "we claimed the grid" and "we sized the grid" stay one
    /// atomic batch on the command FIFO.
    @discardableResult
    private func writeGridAuthorityStamp(reason: String) -> String? {
        guard participatesInGridAuthority,
              mode == .tmuxControl,
              let identity = gridAuthorityIdentity
        else { return nil }
        gridAuthorityGeneration += 1
        let value = "v1 \(identity.id) \(gridAuthorityGeneration) \(identity.displayName)"
        // Force the subscription echo of this very write to be processed —
        // it is the reclaim ack (T3).
        lastSeenAuthorityRawValue = nil
        sendControlCommand("set-option \(Self.gridAuthorityOption) '\(value)'")
        Self.logDiagnostic("grid-authority stamp gen=\(gridAuthorityGeneration) reason=\(reason)")
        return value
    }

    /// Parse a stamp value; returns the peer display name when the stamp
    /// belongs to a different device, nil when it is ours / empty / garbled.
    private func foreignAuthorityDisplayName(inRawValue raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let fields = trimmed.split(separator: " ")
        guard fields.count >= 4, fields[0] == "v1" else { return nil }
        guard let identity = gridAuthorityIdentity, String(fields[1]) != identity.id else {
            return nil
        }
        return fields[3...].joined(separator: " ")
    }

    /// Fold a stamp observation (subscription echo or explicit query) into
    /// `gridAuthority`. The value arrives once per subscribed pane, so
    /// dedupe on the raw string.
    private func handleGridAuthoritySubscription(value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed != lastSeenAuthorityRawValue else { return }
        lastSeenAuthorityRawValue = trimmed
        guard participatesInGridAuthority,
              let identity = gridAuthorityIdentity
        else { return }
        // Empty (unstamped session) or unparseable values change nothing —
        // the layout-mismatch fallback covers stamp-less takeovers.
        let fields = trimmed.split(separator: " ")
        guard fields.count >= 4, fields[0] == "v1" else { return }

        if String(fields[1]) == identity.id {
            let resolvesReconnectOrderingRace = trimmed
                == gridAuthorityReconnectClaimExpectedStamp
            if resolvesReconnectOrderingRace {
                gridAuthorityReconnectClaimExpectedStamp = nil
            }
            // Our own stamp echo is advisory only — it can NOT complete a
            // reclaim, because the stamp and tmux's own sizing-client state
            // can disagree; geometry confirmation lives in
            // `confirmGridClaimIfSettled`. It only labels the steady state
            // while nothing is contested.
            if resolvesReconnectOrderingRace,
               gridAuthority.isPeer,
               !gridAuthorityReclaimInFlight {
                Self.logDiagnostic(
                    "grid-authority reconnect echo followed intervening peer stamp: fencing claim"
                )
                gridAuthorityReclaimInFlight = true
                claimActiveViewport(reason: "authority-reconnect-ordering")
                scheduleGridAuthorityReclaimTimeout()
            } else if !gridAuthorityReclaimInFlight, gridAuthority == .unknown {
                gridAuthority = .mine
                Self.logDiagnostic("grid-authority stamp echo (steady state)")
            }
        } else {
            let peerName = fields[3...].joined(separator: " ")
            let wasPeer = gridAuthority.isPeer
            gridAuthority = .peer(displayName: peerName)
            // A foreign stamp while our claim is pending is the contested
            // race (T4): the peer wrote after us, so we fold back to yielded
            // and disarm the claim entirely — its late acks must not
            // complete against the peer's grid.
            if gridAuthorityReclaimInFlight || gridAuthorityClaimPending {
                gridAuthorityReclaimInFlight = false
                gridAuthorityClaimPending = false
                gridAuthorityClaimFenceAcknowledged = false
                gridAuthorityClaimPolicyResolved = false
                gridAuthorityFenceTarget = nil
                clearGridAuthorityRepaintTargets()
                gridAuthorityAutoReclaimPeerName = nil
                gridAuthorityReclaimTimeoutTask?.cancel()
                Self.logDiagnostic("grid-authority reclaim contested by \(peerName)")
            } else if !wasPeer {
                Self.logDiagnostic("grid-authority yielded to \(peerName)")
            }
        }
    }

    /// User- or auto-initiated take-back (T2/T5): claim the active viewport
    /// through the tmux-native path and lift the veil only when the observed
    /// window layout matches our grid. The stamp is advisory copy for peers,
    /// never the success condition — tmux's own `window-size latest` client
    /// state is the geometry source of truth and the two can disagree.
    public func reclaimGridAuthority(reason: String = "user") {
        guard participatesInGridAuthority, mode == .tmuxControl else { return }
        guard gridAuthority.isPeer, !gridAuthorityReclaimInFlight else { return }
        if reason != "peer-departed" {
            gridAuthorityAutoReclaimPeerName = nil
        }
        gridAuthorityReclaimInFlight = true
        claimActiveViewport(reason: "authority-reclaim-\(reason)")
        scheduleGridAuthorityReclaimTimeout()
    }

    public func setGridAuthorityUsesCompactSinglePaneGrid(_ compact: Bool) {
        guard gridAuthorityUsesCompactSinglePaneGrid != compact else { return }
        gridAuthorityUsesCompactSinglePaneGrid = compact
        if let activeWindowId {
            reconcileGridAuthorityRepaintForLayout(windowId: activeWindowId)
        }
    }

    /// Claim the active viewport for this client.
    ///
    /// `refresh-client -C` alone does not reliably transfer tmux's
    /// `window-size latest` ownership — a diagnostics log showed the iPad
    /// advertising 166x54 while captures stayed at the phone's 105x31. On
    /// the inline path the claim therefore follows the size replay with a
    /// no-op `select-window` on the *current* window from this control
    /// client, which does make this client latest (verified against a
    /// disposable tmux 3.4 fixture; no visible switch, no `resize-window`,
    /// no manual window-size option). The side channel keeps its existing
    /// direct `resize-window` force — that topology's visible clients are
    /// `ignore-size` and the recalculation cannot be trusted there.
    ///
    /// Confirmation requires both the command fence and settled geometry:
    /// `confirmGridClaimIfSettled` passes only after the server has processed
    /// the replay/selection and the active window's layout equals our grid.
    public func claimActiveViewport(
        reason: String,
        repaintEvenIfSame: Bool = false
    ) {
        guard mode == .tmuxControl, lastKnownSize != nil else { return }
        // A yielded client claims only through reclaimGridAuthority — the
        // chrome refresh button must not half-claim from under the veil.
        if gridAuthority.isPeer, !gridAuthorityReclaimInFlight { return }
        let connectionGeneration = controlConnectionGeneration
        gridAuthorityClaimGeneration &+= 1
        let claimGeneration = gridAuthorityClaimGeneration
        let localSize = lastKnownSize
        let currentRect = (activeWindowId ?? renderedWindowId)
            .flatMap(indexOfWindow)
            .flatMap { windows[$0].layout?.root.rect }
        gridAuthorityClaimChangedGeometry = currentRect == nil
            || currentRect?.width != localSize?.cols
            || currentRect?.height != localSize?.rows
        gridAuthorityClaimForcesRepaint = repaintEvenIfSame
        clearGridAuthorityRepaintTargets()
        gridAuthorityClaimPending = true
        gridAuthorityClaimFenceAcknowledged = false
        gridAuthorityClaimPolicyResolved = false
        gridAuthorityFenceTarget = nil
        gridAuthorityRefenceCount = 0
        queueGridClaimFenceSequence(
            connectionGeneration: connectionGeneration,
            claimGeneration: claimGeneration,
            reason: reason,
            replaySize: true
        )
    }

    /// Probe the effective policy of the exact window this claim will fence.
    /// The query is queued after any size replay/unset mutations and before the
    /// fence, so FIFO ordering makes the policy authoritative by the time the
    /// fence can acknowledge. A window move starts a new fence generation and
    /// invalidates every callback from the older target.
    private func queueGridClaimFenceSequence(
        connectionGeneration: UInt64,
        claimGeneration: UInt64,
        reason: String,
        replaySize: Bool
    ) {
        guard mode == .tmuxControl,
              controlConnectionGeneration == connectionGeneration,
              gridAuthorityClaimGeneration == claimGeneration,
              gridAuthorityClaimPending,
              let target = activeWindowId ?? renderedWindowId
        else {
            Self.logDiagnostic(
                "grid-authority fence deferred reason=\(reason): active window unavailable"
            )
            return
        }

        gridAuthorityFenceGeneration &+= 1
        let fenceGeneration = gridAuthorityFenceGeneration
        gridAuthorityFenceTarget = target
        gridAuthorityClaimFenceAcknowledged = false
        gridAuthorityClaimPolicyResolved = false
        if replaySize {
            replayClientSize(
                reason: reason,
                belongsToGridClaimFence: true
            )
        }
        // Side-channel replay temporarily makes every known window manual,
        // then unsets that override. Probe only after those FIFO mutations so
        // this claim observes the policy that will actually govern settlement.
        probeGridAuthorityWindowSizePolicy(
            windowId: target,
            connectionGeneration: connectionGeneration,
            claimGeneration: claimGeneration,
            fenceGeneration: fenceGeneration,
            reason: reason
        )
        // Ack-sequence the fence: only after the server has processed the
        // size replay do we read the (then-fresh) current window and send
        // the no-op select — a fence built from a pre-replay snapshot can
        // target a window the peer already left, and select-window on a
        // NON-current window visibly switches every attached client.
        sendControlCommand("display-message -p ''") { [weak self] _ in
            guard let self,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.gridAuthorityClaimGeneration == claimGeneration,
                  self.gridAuthorityFenceGeneration == fenceGeneration,
                  (self.activeWindowId ?? self.renderedWindowId) == target
            else { return }
            self.sendGridClaimFence(
                connectionGeneration: connectionGeneration,
                claimGeneration: claimGeneration,
                fenceGeneration: fenceGeneration,
                target: target
            )
        }
    }

    private func probeGridAuthorityWindowSizePolicy(
        windowId: WindowId,
        connectionGeneration: UInt64,
        claimGeneration: UInt64,
        fenceGeneration: UInt64,
        reason: String
    ) {
        sendControlCommand(
            "show-options -wA -v -t \(windowId.description) window-size"
        ) { [weak self] result in
            guard let self,
                  self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.gridAuthorityClaimGeneration == claimGeneration,
                  self.gridAuthorityFenceGeneration == fenceGeneration,
                  (self.activeWindowId ?? self.renderedWindowId) == windowId
            else { return }
            guard case .success(let lines) = result else {
                Self.logDiagnostic(
                    "grid-authority window-size probe failed window=\(windowId) reason=\(reason): stay yielded"
                )
                return
            }
            let value = (lines.first(where: { !$0.isEmpty }) ?? "latest")
                .trimmingCharacters(in: .whitespaces)
            self.gridAuthorityGeometryPolicyKnown = true
            self.gridAuthorityGeometryPolicyIsLatest = value.isEmpty || value == "latest"
            self.gridAuthorityClaimPolicyResolved = true
            if !self.gridAuthorityGeometryPolicyIsLatest {
                Self.logDiagnostic(
                    "grid-authority window-size=\(value) window=\(windowId): layout fallback disabled, claim confirms on ack"
                )
            }
            self.confirmGridClaimIfSettled(context: "window-size-policy")
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
              !gridAuthorityClaimPending
        else { return }
        let connectionGeneration = controlConnectionGeneration
        let sessionId = ownSessionId
        gridAuthorityGeometryPolicyKnown = false
        sendControlCommand(
            "show-options -wA -v -t \(windowId.description) window-size"
        ) { [weak self] result in
            guard let self,
                  self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.ownSessionId == sessionId,
                  !self.gridAuthorityClaimPending,
                  (self.activeWindowId ?? self.renderedWindowId) == windowId,
                  case .success(let lines) = result
            else { return }
            let value = (lines.first(where: { !$0.isEmpty }) ?? "latest")
                .trimmingCharacters(in: .whitespaces)
            self.gridAuthorityGeometryPolicyKnown = true
            self.gridAuthorityGeometryPolicyIsLatest = value.isEmpty || value == "latest"
            Self.logDiagnostic(
                "grid-authority steady window-size=\(value.isEmpty ? "latest" : value) window=\(windowId) reason=\(reason)"
            )
            // A layout notification can land while this policy probe is in
            // flight. Re-evaluate the model's latest layout now so that brief
            // policy-unknown windows do not permanently miss a bare tmux
            // client's resize.
            self.noteLayoutSizeForAuthorityFallback(
                self.window(windowId)?.layout,
                windowId: windowId
            )
        }
    }

    /// Send (or re-send) the inline latest-client-transfer fence against the
    /// model's *current* window. Re-issued from `%session-window-changed`
    /// when the current window moves while the claim is pending.
    private func sendGridClaimFence(
        connectionGeneration: UInt64,
        claimGeneration: UInt64,
        fenceGeneration: UInt64,
        target: WindowId
    ) {
        guard mode == .tmuxControl,
              controlConnectionGeneration == connectionGeneration,
              gridAuthorityClaimGeneration == claimGeneration,
              gridAuthorityFenceGeneration == fenceGeneration,
              (activeWindowId ?? renderedWindowId) == target,
              gridAuthorityClaimPending
        else { return }
        guard controlPath == .inline else {
            // Side channel (resize-window force already queued) or no
            // hydrated window yet: the ack alone orders the confirmation.
            gridAuthorityClaimFenceAcknowledged = true
            confirmGridClaimIfSettled(context: "claim-fence")
            return
        }
        sendControlCommand("select-window -t \(target.description)") { [weak self] _ in
            guard let self,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.gridAuthorityClaimGeneration == claimGeneration,
                  self.gridAuthorityFenceGeneration == fenceGeneration,
                  (self.activeWindowId ?? self.renderedWindowId) == target
            else { return }
            self.gridAuthorityClaimFenceAcknowledged = true
            self.confirmGridClaimIfSettled(context: "claim-fence")
        }
    }

    /// Re-issue the fence if the session's current window moved while our
    /// claim was pending (the peer switched windows between our snapshot
    /// and the fence landing). Called from `%session-window-changed`.
    private func refenceGridClaimIfCurrentWindowMoved() {
        let repaintWasInFlight = gridAuthorityRepaintWindow != nil
            || !gridAuthorityRepaintPanes.isEmpty
            || gridAuthoritySideChannelRepaintPending
        guard gridAuthorityClaimPending || repaintWasInFlight,
              mode == .tmuxControl
        else { return }
        if repaintWasInFlight {
            // The capture/frame we were waiting for belongs to the previous
            // active window. It can no longer prove that the newly visible
            // surface is authoritative, so return to the geometry/fence phase
            // and keep the veil closed until the new window has been sized and
            // repainted.
            clearGridAuthorityRepaintTargets()
            gridAuthorityClaimPending = true
            gridAuthorityClaimFenceAcknowledged = false
        }
        gridAuthorityRefenceCount += 1
        Self.logDiagnostic(
            "grid-authority re-fence #\(gridAuthorityRefenceCount): current window moved during claim"
        )
        queueGridClaimFenceSequence(
            connectionGeneration: controlConnectionGeneration,
            claimGeneration: gridAuthorityClaimGeneration,
            reason: "current-window-moved",
            // A newly current window may have been unknown during the first
            // side-channel force. Replay there so resize/unset reaches it;
            // inline clients only need a fresh select-window fence.
            replaySize: controlPath == .sideChannel
        )
    }

    /// Complete a pending claim once the server's geometry actually matches
    /// our viewport, then order the one required authoritative repaint before
    /// exposing the terminal. Layout unknown or mismatched → stay pending (a
    /// later `%layout-change` or fence ack re-checks).
    /// `gridAuthorityClaimPending` deliberately survives the 3s UI timeout:
    /// the claim's server-side effects cannot be recalled, so a late success
    /// must still lift the veil instead of stranding both devices behind one.
    /// Under a non-`latest` window-size policy the equality can never hold by
    /// design, so the fence ack completes it.
    private func confirmGridClaimIfSettled(context: String) {
        guard gridAuthorityClaimPending, mode == .tmuxControl else { return }
        guard gridAuthorityClaimPolicyResolved else { return }
        guard gridAuthorityClaimFenceAcknowledged else { return }
        guard let size = lastKnownSize else { return }
        if gridAuthorityGeometryPolicyIsLatest {
            guard let windowId = activeWindowId ?? renderedWindowId,
                  let idx = indexOfWindow(windowId),
                  let rect = windows[idx].layout?.root.rect,
                  rect.width == size.cols, rect.height == size.rows
            else {
                Self.logDiagnostic("grid-authority claim unsettled context=\(context)")
                return
            }
        }
        gridAuthorityClaimPending = false
        Self.logDiagnostic(
            "grid-authority claim settled size=\(size.cols)x\(size.rows) context=\(context)"
        )

        let needsRepaint = gridAuthorityClaimChangedGeometry
            || gridAuthorityClaimForcesRepaint
        guard needsRepaint else {
            finishGridAuthorityClaimPresentation(context: context)
            return
        }

        switch controlPath {
        case .sideChannel:
            // Mosh paints outside this control connection. Keep the veil up
            // until the view reports that the forced framebuffer output was
            // consumed by SwiftTerm; merely enqueueing the driver operation
            // recreates the stale-frame flash this feature is meant to avoid.
            guard let requestRepaint = onGridAuthoritySideChannelRepaintRequired else {
                Self.logDiagnostic(
                    "grid-authority side repaint callback unavailable: keeping yielded presentation"
                )
                if gridAuthority.isPeer {
                    // Production wires the callback before transport start.
                    // Fail closed if an integration does not: a stale frame
                    // is never evidence that this device reclaimed safely.
                    gridAuthorityClaimPending = true
                } else {
                    finishGridAuthorityClaimPresentation(
                        context: "\(context)-side-refresh-unobserved"
                    )
                }
                return
            }
            gridAuthoritySideChannelRepaintGeneration &+= 1
            let repaintGeneration = gridAuthoritySideChannelRepaintGeneration
            if gridAuthority.isPeer {
                gridAuthoritySideChannelRepaintPending = true
                requestRepaint(
                    gridAuthorityClaimChangedGeometry,
                    repaintGeneration
                )
            } else {
                // Manual refresh while already authoritative has no veil to
                // hold. Queue the repaint, then settle the bookkeeping.
                requestRepaint(
                    gridAuthorityClaimChangedGeometry,
                    repaintGeneration
                )
                finishGridAuthorityClaimPresentation(context: "\(context)-side-refresh")
            }

        case .inline:
            guard let windowId = activeWindowId ?? renderedWindowId,
                  let window = window(windowId)
            else {
                // Metadata is briefly unavailable during reattach. Re-arm the
                // geometry phase; the next layout/fence observation retries
                // without revealing an unpainted terminal.
                gridAuthorityClaimPending = true
                Self.logDiagnostic(
                    "grid-authority repaint deferred: active window unavailable"
                )
                return
            }
            if window.rendersAsPaneGrid {
                gridAuthorityRepaintPanes = gridAuthorityVisiblePaneTargets(
                    in: window
                )
                guard !gridAuthorityRepaintPanes.isEmpty else {
                    gridAuthorityClaimPending = true
                    Self.logDiagnostic(
                        "grid-authority repaint deferred: pane grid unavailable"
                    )
                    return
                }
            } else {
                gridAuthorityRepaintWindow = windowId
            }
            refreshActiveWindowOnForeground()
        }
    }

    /// Final authority transition. Inline callers reach this only after the
    /// captured viewport has been fed into the visible terminal surface;
    /// yielded side-channel callers reach it after mosh's forced frame was
    /// consumed by that surface.
    private func finishGridAuthorityClaimPresentation(context: String) {
        let autoReclaimPeer = gridAuthorityAutoReclaimPeerName
        clearGridAuthorityRepaintTargets()
        gridAuthorityClaimFenceAcknowledged = false
        gridAuthorityClaimPolicyResolved = false
        gridAuthorityFenceTarget = nil
        gridAuthorityClaimChangedGeometry = false
        gridAuthorityClaimForcesRepaint = false
        gridAuthorityReclaimInFlight = false
        gridAuthorityReclaimTimeoutTask?.cancel()
        gridAuthorityReclaimTimeoutTask = nil
        gridAuthority = .mine
        gridAuthorityAutoReclaimPeerName = nil
        gridAuthorityReconnectClaimExpectedStamp = nil
        Self.logDiagnostic(
            "grid-authority presentation active context=\(context)"
        )
        if let autoReclaimPeer {
            onGridAuthorityAutoReclaimed?(autoReclaimPeer)
        }
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

    private func clearGridAuthorityRepaintTargets() {
        gridAuthorityRepaintWindow = nil
        gridAuthorityRepaintPanes.removeAll(keepingCapacity: true)
        gridAuthoritySideChannelRepaintPending = false
    }

    /// Complete the side-channel half of a claim after Mosh's forced full
    /// frame has been fed into the visible terminal. Late callbacks from a
    /// reset/contested/replaced claim are harmless no-ops.
    public func completeGridAuthoritySideChannelRepaint(
        generation: UInt64
    ) {
        guard gridAuthoritySideChannelRepaintPending,
              generation == gridAuthoritySideChannelRepaintGeneration,
              gridAuthority.isPeer
        else { return }
        gridAuthoritySideChannelRepaintPending = false
        finishGridAuthorityClaimPresentation(context: "side-channel-repaint-delivered")
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
        gridAuthorityClaimPending = true
        confirmGridClaimIfSettled(context: "repaint-layout-changed")
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

    private func scheduleGridAuthorityReclaimTimeout() {
        gridAuthorityReclaimTimeoutTask?.cancel()
        gridAuthorityReclaimTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.gridAuthorityReclaimInFlight {
                self.gridAuthorityReclaimInFlight = false
                Self.logDiagnostic("grid-authority reclaim ack timeout")
            }
        }
    }

    /// T5: after a client detach (or a reconnect that re-derived a foreign
    /// stamp) while yielded, auto-reclaim only when every attached client can
    /// be positively identified as belonging to this device. A count is not
    /// proof on mosh: if our visible client and a peer's side channel disappear
    /// together, the remaining local side channel + peer visible client still
    /// totals two. The visible mosh launch therefore records a name/PID/created
    /// tuple in a device-scoped session option; this control connection resolves
    /// its own tuple directly. Missing/ambiguous identity fails closed.
    private func scheduleGridAuthorityPeerCheck(reason: String) {
        guard participatesInGridAuthority,
              gridAuthority.isPeer,
              !gridAuthorityReclaimInFlight,
              !gridAuthorityClaimPending,
              !gridAuthorityPeerCheckInFlight,
              mode == .tmuxControl,
              let sessionId = ownSessionId
        else { return }
        let connectionGeneration = controlConnectionGeneration
        gridAuthorityPeerCheckInFlight = true
        sendControlCommand(
            "display-message -p '#{client_name}|#{client_pid}|#{client_created}'"
        ) { [weak self] result in
            guard let self,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.ownSessionId == sessionId
            else { return }
            guard case .success(let lines) = result,
                  let controlClientIdentity = lines.first(where: { !$0.isEmpty })
            else {
                self.gridAuthorityPeerCheckInFlight = false
                Self.logDiagnostic(
                    "grid-authority peer check (\(reason)): own control client unknown — stay yielded"
                )
                return
            }

            if self.controlPath == .sideChannel {
                guard let identity = self.gridAuthorityIdentity else {
                    self.gridAuthorityPeerCheckInFlight = false
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
                          let visibleClientIdentity = visibleLines.first(where: { !$0.isEmpty })
                    else {
                        self.gridAuthorityPeerCheckInFlight = false
                        Self.logDiagnostic(
                            "grid-authority peer check (\(reason)): own visible client unknown — stay yielded"
                        )
                        return
                    }
                    self.finishGridAuthorityPeerCheck(
                        reason: reason,
                        sessionId: sessionId,
                        connectionGeneration: connectionGeneration,
                        controlClientIdentity: controlClientIdentity,
                        ownClientIdentities: Set([
                            controlClientIdentity,
                            visibleClientIdentity,
                        ])
                    )
                }
            } else {
                self.finishGridAuthorityPeerCheck(
                    reason: reason,
                    sessionId: sessionId,
                    connectionGeneration: connectionGeneration,
                    controlClientIdentity: controlClientIdentity,
                    ownClientIdentities: Set([controlClientIdentity])
                )
            }
        }
    }

    private func finishGridAuthorityPeerCheck(
        reason: String,
        sessionId: SessionId,
        connectionGeneration: UInt64,
        controlClientIdentity: String,
        ownClientIdentities: Set<String>
    ) {
        sendControlCommand(
            "list-clients -t \(sessionId.description) -F '#{client_name}|#{client_pid}|#{client_created}'"
        ) { [weak self] result in
            guard let self else { return }
            guard self.controlConnectionGeneration == connectionGeneration,
                  self.ownSessionId == sessionId
            else { return }
            self.gridAuthorityPeerCheckInFlight = false
            guard self.gridAuthority.isPeer,
                  !self.gridAuthorityReclaimInFlight,
                  !self.gridAuthorityClaimPending,
                  case .success(let lines) = result
            else { return }
            let attached = Set(lines.filter { !$0.isEmpty })
            guard attached.contains(controlClientIdentity),
                  !attached.isEmpty,
                  attached.isSubset(of: ownClientIdentities)
            else {
                Self.logDiagnostic(
                    "grid-authority peer check (\(reason)): attached=\(attached.count) provenOwn=\(attached.intersection(ownClientIdentities).count) — stay yielded"
                )
                return
            }
            Self.logDiagnostic(
                "grid-authority truly alone (\(reason)) attached=\(attached.count) → auto-reclaim"
            )
            self.gridAuthorityAutoReclaimPeerName = self.gridAuthority.peerDisplayName
            self.reclaimGridAuthority(reason: "peer-departed")
        }
    }

    /// Fallback for stamp-less attachers (a laptop's bare `tmux attach`): a
    /// window resize we did not initiate, away from our own grid, means some
    /// client took the size. Suppressed near our own replays so rotation /
    /// keyboard churn and the resize's own echo never trigger it.
    ///
    /// Scoped to the window this device actually renders: `window-size
    /// latest` is per-window, so background windows legitimately keep other
    /// clients' (or stale) geometry — a pane exit in a background window
    /// must not veil the device that owns the active grid.
    private func noteLayoutSizeForAuthorityFallback(
        _ layout: WindowLayout?,
        windowId: WindowId
    ) {
        guard participatesInGridAuthority,
              gridAuthorityGeometryPolicyKnown,
              gridAuthorityGeometryPolicyIsLatest,
              !gridAuthorityRederiveInFlight,
              !gridAuthority.isPeer,
              !gridAuthorityReclaimInFlight,
              windowId == (activeWindowId ?? renderedWindowId),
              let rect = layout?.root.rect,
              let local = lastKnownSize,
              rect.width > 0, rect.height > 0,
              rect.width != local.cols || rect.height != local.rows
        else { return }
        if let last = lastClientSizeReplayAt, Date().timeIntervalSince(last) < 2.0 {
            return
        }
        Self.logDiagnostic(
            "grid-authority fallback: foreign layout \(rect.width)x\(rect.height) vs local \(local.cols)x\(local.rows) window=\(windowId)"
        )
        gridAuthority = .peer(displayName: "another device")
    }

    /// Attach-init size replay, T6-aware: only a fresh controller's FIRST
    /// attach (a user-initiated connect) claims the grid blindly. Every
    /// later attach — auto-reconnect, session change — first re-derives
    /// authority from the stamp: a peer can have taken over during ANY
    /// drop, not just one that began while yielded, and an automatic
    /// reconnect must never steal the grid from a device that kept working.
    /// The attach-once flag is never consumed, so a second drop landing
    /// mid-re-derive simply re-derives again on the next attach.
    private func replayAttachInitClientSize() {
        guard participatesInGridAuthority, gridAuthorityHasAttachedOnce else {
            gridAuthorityHasAttachedOnce = true
            replayClientSize(reason: "attach-init")
            return
        }
        let connectionGeneration = controlConnectionGeneration
        let sessionId = ownSessionId
        gridAuthorityRederiveInFlight = true
        sendControlCommand(
            "show-options -qv \(Self.gridAuthorityOption)"
        ) { [weak self] result in
            guard let self,
                  self.mode == .tmuxControl,
                  self.controlConnectionGeneration == connectionGeneration,
                  self.ownSessionId == sessionId
            else { return }
            self.gridAuthorityRederiveInFlight = false
            let value = (try? result.get())?.first(where: { !$0.isEmpty }) ?? ""
            if let peerName = self.foreignAuthorityDisplayName(inRawValue: value) {
                self.lastSeenAuthorityRawValue = value.trimmingCharacters(in: .whitespaces)
                self.gridAuthority = .peer(displayName: peerName)
                Self.logDiagnostic("grid-authority reconnect re-derived: still \(peerName)")
                // Guard against a stale stamp from a crashed peer leaving
                // this device blurred forever: if nobody else is actually
                // attached, the truly-alone check reclaims immediately.
                self.scheduleGridAuthorityPeerCheck(reason: "reconnect-rederive")
            } else if self.gridAuthority.isPeer {
                // A side-channel reset deliberately kept the previous peer
                // veil fail-closed. Once the replacement channel proves the
                // stamp is empty/ours, reclaim through the full policy,
                // geometry, and repaint fence; replayClientSize alone would
                // reject itself while `.peer` and strand the veil forever.
                self.gridAuthorityReclaimInFlight = true
                self.claimActiveViewport(
                    reason: "authority-reconnect-rederived",
                    repaintEvenIfSame: true
                )
                self.scheduleGridAuthorityReclaimTimeout()
            } else {
                self.replayClientSize(
                    reason: "attach-init-rederived",
                    expectsReconnectClaimEcho: true
                )
            }
        }
    }

    private func resetGridAuthorityState(
        preserveYieldedPresentation: Bool = false
    ) {
        let yieldedPeer = preserveYieldedPresentation
            ? gridAuthority.peerDisplayName
            : nil
        gridAuthority = yieldedPeer.map(GridAuthority.peer) ?? .unknown
        gridAuthorityReclaimInFlight = false
        gridAuthorityClaimPending = false
        gridAuthorityClaimFenceAcknowledged = false
        gridAuthorityRefenceCount = 0
        gridAuthorityFenceGeneration &+= 1
        gridAuthorityClaimPolicyResolved = false
        gridAuthorityFenceTarget = nil
        gridAuthorityClaimChangedGeometry = false
        gridAuthorityClaimForcesRepaint = false
        clearGridAuthorityRepaintTargets()
        gridAuthorityAutoReclaimPeerName = nil
        gridAuthorityReconnectClaimExpectedStamp = nil
        gridAuthorityRederiveInFlight = false
        gridAuthorityGeometryPolicyIsLatest = true
        gridAuthorityGeometryPolicyKnown = false
        gridAuthorityReclaimTimeoutTask?.cancel()
        gridAuthorityReclaimTimeoutTask = nil
        gridAuthorityPeerCheckInFlight = false
        lastSeenAuthorityRawValue = nil
        // gridAuthorityHasAttachedOnce deliberately survives: it marks
        // "this controller has claimed before", which is what forces the
        // reconnect re-derive.
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

        clientSizeEpoch &+= 1
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
        windowLayoutQueriesInFlight.removeAll()
        bellingWindows.removeAll()
        pausedPanes.removeAll()
        windowBellFlags.removeAll()
        paneWindowTable.removeAll()
        paneCurrentPaths.removeAll()
        paneSinks.removeAll()
        pendingPaneRefreshes.removeAll()
        paneSizeResyncAttempts.removeAll()
        deepRefreshedPanes.removeAll()
        pendingPaneFocus.removeAll()
        moshPaneBorderWindows.removeAll()
        activeWindowId = nil
        ownSessionId = nil
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

    private func handlePassthroughCooperatively(_ chunk: [UInt8]) async {
        if dcsBuffer.isEmpty {
            if let dcsStart = firstIndex(of: Self.dcsEnterSequence, in: chunk) {
                await enterTmuxModeCooperatively(
                    splittingChunk: chunk,
                    atDcsStart: dcsStart
                )
                return
            }
            let prefixLen = longestDcsPrefixMatchAtTail(of: chunk)
            if prefixLen == 0 {
                await feedPassthroughCooperatively(ArraySlice(chunk))
                return
            }
            let flushCount = chunk.count - prefixLen
            if flushCount > 0 {
                await feedPassthroughCooperatively(ArraySlice(chunk[..<flushCount]))
            }
            dcsBuffer.append(contentsOf: chunk[flushCount...])
            return
        }

        dcsBuffer.append(contentsOf: chunk)
        if let dcsStart = firstIndex(of: Self.dcsEnterSequence, in: dcsBuffer) {
            await enterTmuxModeCooperatively(
                splittingChunk: dcsBuffer,
                atDcsStart: dcsStart
            )
            dcsBuffer.removeAll(keepingCapacity: true)
            return
        }

        let prefixLen = longestDcsPrefixMatchAtTail(of: dcsBuffer)
        if dcsBuffer.count > prefixLen {
            let flushCount = dcsBuffer.count - prefixLen
            await feedPassthroughCooperatively(ArraySlice(dcsBuffer[..<flushCount]))
            dcsBuffer.removeFirst(flushCount)
        }
    }

    private func feedPassthrough(_ bytes: ArraySlice<UInt8>) {
        guard !suppressPassthroughOutputUntilControlMode else { return }
        deliverToSharedTerminal(
            bytes,
            context: TerminalFeedContext(source: .passthrough)
        )
    }

    private func feedPassthroughCooperatively(_ bytes: ArraySlice<UInt8>) async {
        guard !suppressPassthroughOutputUntilControlMode else { return }
        var budget = CooperativeFeedBudget()
        await deliverToSharedTerminalCooperatively(
            bytes,
            context: TerminalFeedContext(
                source: .passthrough,
                originalByteCount: bytes.count
            ),
            budget: &budget
        )
        await budget.yieldAtEndIfSubstantialWork()
        ingestStages.yieldWaitMs += budget.yieldWaitMs
        ingestStages.yields += budget.yieldCount
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
        let messages = activateTmuxMode(
            trailingChunk: chunk,
            dcsStart: dcsStart,
            dcsEnd: dcsEnd
        )
        process(messages: messages)
    }

    private func enterTmuxModeCooperatively(
        splittingChunk chunk: [UInt8],
        atDcsStart dcsStart: Int
    ) async {
        let dcsEnd = dcsStart + Self.dcsEnterSequence.count
        if dcsStart > 0 {
            await feedPassthroughCooperatively(ArraySlice(chunk[..<dcsStart]))
        }
        let messages = activateTmuxMode(
            trailingChunk: chunk,
            dcsStart: dcsStart,
            dcsEnd: dcsEnd
        )
        await processCooperatively(messages: messages)
    }

    private func activateTmuxMode(
        trailingChunk chunk: [UInt8],
        dcsStart: Int,
        dcsEnd: Int
    ) -> [TmuxMessage] {
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
            return parser.feed(Array(chunk[dcsEnd...]))
        }
        return []
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
        inflightFrameGuard = nil
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
            renderSizeResyncAttempts = 0
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
        stage: RenderStage,
        startedAt: TimeInterval
    ) {
        renderCommandQueueWaitTask?.cancel()
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
                    stage: stage,
                    queueWaitStartedAt: startedAt
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

    /// Restore tmux index order after a window's `#{window_index}` is learned
    /// mid-session. Stable: unknown-index windows (details reply still in
    /// flight) sink to the end in arrival order, matching where `ensureWindow`
    /// appended them. Assigns only on an actual order change so observers
    /// (tab strip `onChange`) don't churn on the common already-sorted case.
    private func resortWindowsByTmuxIndex() {
        let sorted = windows.enumerated().sorted { lhs, rhs in
            let lhsIndex = lhs.element.index ?? Int.max
            let rhsIndex = rhs.element.index ?? Int.max
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            return lhs.offset < rhs.offset
        }.map(\.element)
        guard sorted.map(\.id) != windows.map(\.id) else { return }
        windows = sorted
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

        init() {
            turnStartedAt = clock.now
        }

        mutating func noteRenderedWork(byteCount: Int) {
            bytesSinceYield += byteCount
        }

        private(set) var yieldWaitMs: Double = 0
        private(set) var yieldCount = 0

        mutating func yieldIfNeeded(force: Bool = false) async {
            guard bytesSinceYield > 0 else { return }
            guard force || turnStartedAt.duration(to: clock.now) >= turnBudget else {
                return
            }
            let yieldStart = clock.now
            await Task.yield()
            yieldWaitMs += IngestStageStats.elapsedMs(since: yieldStart)
            yieldCount += 1
            turnStartedAt = clock.now
            bytesSinceYield = 0
        }

        /// End-of-ingest yield, charged only once a full renderer slice went
        /// unyielded. The previous trigger — "more than one slice delivered" —
        /// force-yielded after nearly every chunk of a tiny-write storm (a TUI
        /// keystroke redraw arrives as several 10–50 byte `%output` frames per
        /// SSH chunk), paying a main-queue round trip for a few dozen bytes.
        /// Interactive echo latency comes first; large repaints still slice at
        /// `cooperativeFeedChunkBytes` and reliably yield here.
        mutating func yieldAtEndIfSubstantialWork() async {
            guard bytesSinceYield >= TmuxController.cooperativeFeedChunkBytes else {
                return
            }
            await yieldIfNeeded(force: true)
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

    private func processCooperatively(messages: [TmuxMessage]) async {
        var budget = CooperativeFeedBudget()

        for message in messages {
            switch message {
            case .output(let paneId, let data):
                await handlePaneOutputCooperatively(
                    paneId: paneId,
                    data: data,
                    budget: &budget
                )

            case .extendedOutput(let paneId, let ageMs, let data):
                if ageMs > 2_000 {
                    Self.logDiagnostic(
                        "extended-output delayed pane=\(paneId) ageMs=\(ageMs) bytes=\(data.count)"
                    )
                }
                await handlePaneOutputCooperatively(
                    paneId: paneId,
                    data: data,
                    budget: &budget
                )

            default:
                ingestStages.controlMessages += 1
                let controlStart = IngestStageStats.now()
                handle(message: message)
                ingestStages.controlMs += IngestStageStats.elapsedMs(since: controlStart)
            }
        }

        await budget.yieldAtEndIfSubstantialWork()
        ingestStages.yieldWaitMs += budget.yieldWaitMs
        ingestStages.yields += budget.yieldCount
    }

    private func handlePaneOutputCooperatively(
        paneId: PaneId,
        data: [UInt8],
        budget: inout CooperativeFeedBudget
    ) async {
        let target = preparePaneOutput(paneId: paneId, data: data)
        guard !data.isEmpty else { return }
        switch target {
        case .none:
            return

        case .paneSink(let sink):
            var offset = 0
            while offset < data.count {
                let end = min(offset + Self.cooperativeFeedChunkBytes, data.count)
                let deliverStart = IngestStageStats.now()
                sink(data[offset..<end])
                ingestStages.deliverMs += IngestStageStats.elapsedMs(since: deliverStart)
                ingestStages.sliceFeeds += 1
                budget.noteRenderedWork(byteCount: end - offset)
                offset = end
                await budget.yieldIfNeeded()
            }
            return

        case .shared(let context):
            await deliverToSharedTerminalCooperatively(
                data[...],
                context: context,
                budget: &budget
            )
            markInitialRenderReady()
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

    private enum PaneOutputRenderTarget {
        case none
        case paneSink((ArraySlice<UInt8>) -> Void)
        case shared(TerminalFeedContext)
    }

    /// Run content observers and resolve one renderer destination. Cooperative
    /// ingestion changes only delivery pacing after this synchronous routing;
    /// pane latching, refresh gates, and terminal replies keep their ordering.
    private func preparePaneOutput(
        paneId: PaneId,
        data: [UInt8]
    ) -> PaneOutputRenderTarget {
        ingestStages.outputMessages += 1
        let observerStart = IngestStageStats.now()
        paneDidOutput?(paneId)
        paneOutputObserver?(paneId, data[...])
        ingestStages.observerMs += IngestStageStats.elapsedMs(since: observerStart)
        let titleStart = IngestStageStats.now()
        updatePaneTitleFromOutput(paneId: paneId, data: data)
        ingestStages.titleScanMs += IngestStageStats.elapsedMs(since: titleStart)
        let queryStart = IngestStageStats.now()
        sendTerminalResponseForOutputIfNeeded(paneId: paneId, data: data)
        ingestStages.queryScanMs += IngestStageStats.elapsedMs(since: queryStart)

        // Grid path: a registered per-pane sink takes priority over the shared
        // single-pane terminal. This is the explicit fallthrough boundary — if
        // a pane has no sink, control drops to the byte-identical single-pane
        // fast path below. Drop output while this pane's capture-repaint is in
        // flight so stale bytes can't bleed in ahead of the capture.
        if let sink = paneSinks[paneId] {
            guard controlPath == .inline else { return .none }
            if coalesceForegroundOutputIfNeeded(paneId: paneId, data: data) { return .none }
            if pendingPaneRefreshes[paneId] != nil { return .none }
            return .paneSink(sink)
        }

        guard controlPath == .inline else { return .none }
        let isForegroundRecoveryPane = paneId == renderedPaneId
            || paneId == activePaneId
            || (renderedPaneId == nil && activePaneId == nil)
        if isForegroundRecoveryPane,
           coalesceForegroundOutputIfNeeded(paneId: paneId, data: data) {
            return .none
        }
        if pendingRenderRefresh != nil { return .none }

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
            return .shared(
                TerminalFeedContext(
                    source: .paneOutput,
                    paneId: paneId,
                    windowId: renderedWindowId,
                    originalByteCount: data.count
                )
            )
        }
        return .none
    }

    private func handlePaneOutput(paneId: PaneId, data: [UInt8]) {
        switch preparePaneOutput(paneId: paneId, data: data) {
        case .none:
            break
        case .paneSink(let sink):
            sink(ArraySlice(data))
        case .shared(let context):
            deliverToSharedTerminal(ArraySlice(data), context: context)
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
            if let idx = windows.firstIndex(where: { $0.id == windowId }),
               windows[idx].windowName == nil || windows[idx].layout == nil
                || windows[idx].index == nil {
                // While the layout half is unknown the pane count is a
                // guess, so mark the query pending — close paths confirm
                // instead of killing until the reply (or a real
                // `%layout-change`) lands.
                if windows[idx].layout == nil {
                    windowLayoutQueriesInFlight[windowId, default: 0] += 1
                }
                queryWindowDetails(windowId: windowId)
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
            // The session's current window moved while a viewport claim was
            // pending: our queued fence now targets a stale window (a real
            // select-window there would visibly switch the peer). Re-issue
            // against the new current window (bounded).
            if previousActive != windowId {
                refenceGridClaimIfCurrentWindowMoved()
                if !gridAuthorityClaimPending {
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
                reconcileGridAuthorityRepaintForLayout(windowId: windowId)
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
            if name == Self.gridAuthoritySubscriptionName {
                handleGridAuthoritySubscription(value: value)
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

        case .begin(let time, let commandNumber, let flags):
            // Fresh command response — drop any leftover body from a
            // previous response (shouldn't happen in normal flow, but
            // keeps us robust to parser state mishaps).
            if let previous = inflightFrameGuard {
                Self.logDiagnostic(
                    "command-frame-overlap controller=\(diagnosticID) previousTime=\(previous.time) previousNumber=\(previous.commandNumber) previousFlags=\(previous.flags) nextTime=\(time) nextNumber=\(commandNumber) nextFlags=\(flags) discardedLines=\(inflightLines.count)"
                )
            }
            inflightLines.removeAll(keepingCapacity: true)
            inflightFrameGuard = (time, commandNumber, flags)
            Self.logDiagnostic(
                "command-frame-begin controller=\(diagnosticID) time=\(time) number=\(commandNumber) flags=\(flags) wirePending=\(pendingCommands.count) headSequence=\(pendingCommands.first?.sequence ?? -1) headCategory=\(pendingCommands.first.map { Self.commandCategory($0.command) } ?? "none")"
            )

        case .commandOutputLine(let line):
            inflightLines.append(line)

        case .end(let time, let commandNumber, let flags):
            let lines = inflightLines
            inflightLines.removeAll(keepingCapacity: true)
            let begin = inflightFrameGuard
            inflightFrameGuard = nil
            let effectiveFlags = begin?.flags ?? flags
            let guardMatches = begin.map {
                $0.time == time && $0.commandNumber == commandNumber && $0.flags == flags
            } ?? false
            if let begin, !guardMatches {
                Self.logDiagnostic(
                    "command-frame-guard-mismatch controller=\(diagnosticID) status=end beginTime=\(begin.time) beginNumber=\(begin.commandNumber) beginFlags=\(begin.flags) endTime=\(time) endNumber=\(commandNumber) endFlags=\(flags) bodyLines=\(lines.count) recovery=classify-from-begin effectiveFlags=\(effectiveFlags)"
                )
            } else if begin == nil {
                Self.logDiagnostic(
                    "command-frame-missing-begin controller=\(diagnosticID) status=end endTime=\(time) endNumber=\(commandNumber) endFlags=\(flags) bodyLines=\(lines.count) recovery=classify-from-end effectiveFlags=\(effectiveFlags)"
                )
            }
            guard effectiveFlags & 1 == 1 else {
                if !attachInitFlushed {
                    attachInitFlushed = true
                    Self.logDiagnostic("handshake-frame-drained path=\(controlPath)")
                    flushAttachInitQueries()
                } else {
                    Self.logDiagnostic(
                        "server-originated-frame-drained status=end beginTime=\(begin?.time ?? -1) beginNumber=\(begin?.commandNumber ?? -1) beginFlags=\(begin?.flags ?? -1) endTime=\(time) endNumber=\(commandNumber) endFlags=\(flags) guardMatches=\(guardMatches) lines=\(lines.count)"
                    )
                }
                break
            }
            // tmux is serialized, so FIFO dequeue matches the `%end`
            // with the oldest pending command.
            if !pendingCommands.isEmpty {
                let entry = pendingCommands.removeFirst()
                Self.logDiagnostic(
                    "command-response controller=\(diagnosticID) status=end beginTime=\(begin?.time ?? -1) beginNumber=\(begin?.commandNumber ?? -1) beginFlags=\(begin?.flags ?? -1) endTime=\(time) endNumber=\(commandNumber) endFlags=\(flags) guardMatches=\(guardMatches) effectiveFlags=\(effectiveFlags) sequence=\(entry.sequence) commandCategory=\(Self.commandCategory(entry.command)) lines=\(lines.count)"
                )
                entry.completion(.success(lines))
            }

        case .error(let time, let commandNumber, let flags):
            let lines = inflightLines
            inflightLines.removeAll(keepingCapacity: true)
            let begin = inflightFrameGuard
            inflightFrameGuard = nil
            let effectiveFlags = begin?.flags ?? flags
            let guardMatches = begin.map {
                $0.time == time && $0.commandNumber == commandNumber && $0.flags == flags
            } ?? false
            if let begin, !guardMatches {
                Self.logDiagnostic(
                    "command-frame-guard-mismatch controller=\(diagnosticID) status=error beginTime=\(begin.time) beginNumber=\(begin.commandNumber) beginFlags=\(begin.flags) endTime=\(time) endNumber=\(commandNumber) endFlags=\(flags) bodyLines=\(lines.count) recovery=classify-from-begin effectiveFlags=\(effectiveFlags)"
                )
            } else if begin == nil {
                Self.logDiagnostic(
                    "command-frame-missing-begin controller=\(diagnosticID) status=error endTime=\(time) endNumber=\(commandNumber) endFlags=\(flags) bodyLines=\(lines.count) recovery=classify-from-end effectiveFlags=\(effectiveFlags)"
                )
            }
            guard effectiveFlags & 1 == 1 else {
                Self.logDiagnostic(
                    "server-originated-frame-drained status=error beginTime=\(begin?.time ?? -1) beginNumber=\(begin?.commandNumber ?? -1) beginFlags=\(begin?.flags ?? -1) endTime=\(time) endNumber=\(commandNumber) endFlags=\(flags) guardMatches=\(guardMatches) lines=\(lines.count)"
                )
                break
            }
            if !pendingCommands.isEmpty {
                let entry = pendingCommands.removeFirst()
                Self.logDiagnostic(
                    "command-response controller=\(diagnosticID) status=error beginTime=\(begin?.time ?? -1) beginNumber=\(begin?.commandNumber ?? -1) beginFlags=\(begin?.flags ?? -1) endTime=\(time) endNumber=\(commandNumber) endFlags=\(flags) guardMatches=\(guardMatches) effectiveFlags=\(effectiveFlags) sequence=\(entry.sequence) commandCategory=\(Self.commandCategory(entry.command)) lines=\(lines.count)"
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
                controlConnectionGeneration &+= 1
                isWindowListHydrated = false
                // Authority is a session option. Never carry a yielded stamp
                // (or an in-flight claim) into the new session; the hydrate
                // below re-derives that session before any reconnect replay.
                resetGridAuthorityState()
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
            // T5: while yielded, a detach may mean the stamping device left —
            // verify via list-clients and auto-reclaim when only we remain.
            scheduleGridAuthorityPeerCheck(reason: "client-detached")

        case let .layoutChange(windowId, layout, visibleLayout, rawFlags):
            handleLayoutChange(
                windowId: windowId,
                layout: layout,
                visibleLayout: visibleLayout,
                rawFlags: rawFlags
            )

        case .unlinkedWindowAdd, .unlinkedWindowRenamed,
             .sessionRenamed,
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
        // Stamp-less takeover fallback: a resize we did not initiate, away
        // from our grid, means some client (bare `tmux attach`) took the size.
        noteLayoutSizeForAuthorityFallback(parsedLayout, windowId: windowId)
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

        reconcileGridAuthorityRepaintForLayout(windowId: windowId)

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

        // A pending viewport claim settles on geometry only after this
        // notification's complete pane/grid model is installed. Starting the
        // authoritative repaint against the pre-update shape can choose the
        // shared terminal just as the window becomes a grid, after which the
        // transition abandons that repaint and leaves the veil stranded.
        if gridAuthorityClaimPending,
           let rect = parsedLayout?.root.rect,
           let size = lastKnownSize,
           rect.width == size.cols, rect.height == size.rows,
           windowId == (activeWindowId ?? renderedWindowId) {
            confirmGridClaimIfSettled(context: "layout-change")
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
            sendControlCommand("set -t \(windowId.description) pane-border-status off")
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
        // (T6-aware: a reconnect that dropped while yielded re-derives the
        // authority stamp first instead of stealing the grid back.)
        replayAttachInitClientSize()

        sendControlCommand("refresh-client -f pause-after=5")
        sendControlCommand(
            "refresh-client -B '\(Self.bellSubscriptionName):%*:#{window_bell_flag}'"
        )
        if participatesInGridAuthority {
            // Authority stamp push channel. Registered after the attach-init
            // stamp write above, so the initial delivery already reflects our
            // own claim on a fresh takeover.
            sendControlCommand(
                "refresh-client -B '\(Self.gridAuthoritySubscriptionName):%*:#{\(Self.gridAuthorityOption)}'"
            )
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
           !gridAuthority.isPeer || gridAuthorityReclaimInFlight {
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

        if gridAuthorityClaimPending, gridAuthorityFenceTarget == nil {
            queueGridClaimFenceSequence(
                connectionGeneration: controlConnectionGeneration,
                claimGeneration: gridAuthorityClaimGeneration,
                reason: "\(reason)-window-hydrated",
                replaySize: true
            )
        } else if !gridAuthorityClaimPending {
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
    }

    private func sendPaneMetadataSubscription() {
        sendControlCommand(
            "refresh-client -B '\(Self.paneMetadataSubscriptionName):%*:\(Self.paneMetadataSubscriptionFormat)'"
        )
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
        // Same field-order contract as the attach-init `list-windows`:
        // fixed-grammar fields (index, layout, visible_layout, zoomed_flag)
        // first, `#{window_name}` LAST so a tab in the name can't shift them.
        sendControlCommand(
            "display-message -p -t \(windowId.description) '#{window_index}\t#{window_layout}\t#{window_visible_layout}\t#{window_zoomed_flag}\t#{window_name}'"
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
                  let line = lines.first(where: { !$0.isEmpty })
            else { return }
            // The index field is a pure integer while a layout string never
            // is, so probing field 1 tolerates a pre-index 4-field reply.
            let probe = line.split(
                separator: "\t",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let index: Int? = probe.first.flatMap { Int($0) }
            let fixedFieldOffset = index != nil ? 1 : 0
            let fields = line.split(
                separator: "\t",
                maxSplits: 3 + fixedFieldOffset,
                omittingEmptySubsequences: false
            )
            guard fields.count == 4 + fixedFieldOffset else { return }
            guard var idx = self.windows.firstIndex(where: { $0.id == windowId })
            else { return }
            if let index {
                self.windows[idx].index = index
                // The new window may have filled an index gap left by an
                // earlier close (plain `new-window` takes the lowest free
                // index), so its arrival-order slot at the end of the array
                // can be wrong. Re-sort now that the true index is known —
                // otherwise the next reattach hydrates tmux's order and the
                // tabs visibly reshuffle.
                self.resortWindowsByTmuxIndex()
                // The sort may have moved this window (and its neighbors).
                guard let sortedIdx = self.windows.firstIndex(where: { $0.id == windowId })
                else { return }
                idx = sortedIdx
            }
            if self.windows[idx].layout == nil, !fields[fixedFieldOffset].isEmpty {
                // handleLayoutChange owns the downstream consequences
                // (pane merge, pane→window table, mosh pane border),
                // exactly as if tmux had notified us.
                self.handleLayoutChange(
                    windowId: windowId,
                    layout: String(fields[fixedFieldOffset]),
                    visibleLayout: fields[1 + fixedFieldOffset].isEmpty
                        ? nil
                        : String(fields[1 + fixedFieldOffset]),
                    rawFlags: fields[2 + fixedFieldOffset] == "1" ? "Z" : nil
                )
            }
            let name = String(fields[3 + fixedFieldOffset])
            if !name.isEmpty,
               let idx = self.windows.firstIndex(where: { $0.id == windowId }),
               self.windows[idx].windowName == nil {
                self.windows[idx].windowName = name
            }
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
        stage: RenderStage = .viewport,
        queueWaitStartedAt: TimeInterval? = nil
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
        if requiresExclusiveCommandQueue, !pendingCommands.isEmpty {
            let now = ProcessInfo.processInfo.systemUptime
            let startedAt = queueWaitStartedAt ?? now
            let elapsed = now - startedAt
            if elapsed < max(0, renderCommandQueueMaxWait) {
                if queueWaitStartedAt == nil {
                    Self.logDiagnostic(
                        "render-refresh wait-command-queue controller=\(diagnosticID) window=\(windowId) generation=\(generation) stage=\(stage) pending=\(pendingCommands.count) maxWaitMs=\(Int(renderCommandQueueMaxWait * 1_000)) reason=\(reason)"
                    )
                }
                waitForCommandQueueBeforeRender(
                    windowId: windowId,
                    generation: generation,
                    reason: reason,
                    stage: stage,
                    startedAt: startedAt
                )
                return
            }
            Self.logDiagnostic(
                "render-refresh command-queue-wait-expired controller=\(diagnosticID) window=\(windowId) generation=\(generation) stage=\(stage) pending=\(pendingCommands.count) waitedMs=\(Int(elapsed * 1_000)) reason=\(reason)"
            )
        }
        renderCommandQueueWaitTask?.cancel()
        renderCommandQueueWaitTask = nil
        Self.logDiagnostic(
            "render-refresh send-metadata window=\(windowId) generation=\(generation) stage=\(stage) reason=\(reason)"
        )
        let sizeEpoch = clientSizeEpoch
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
                stage: resolvedStage,
                sizeEpoch: sizeEpoch
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
        stage: RenderStage,
        sizeEpoch: Int
    ) {
        switch stage {
        case .viewport, .viewportOnly:
            captureViewport(windowId: windowId, state: state, generation: generation, reason: reason, stage: stage, sizeEpoch: sizeEpoch)
        case .deep where state.paneInAltScreen:
            captureDeepAltScreen(windowId: windowId, state: state, generation: generation, reason: reason, sizeEpoch: sizeEpoch)
        case .deep:
            captureDeepPrimary(windowId: windowId, state: state, generation: generation, reason: reason, sizeEpoch: sizeEpoch)
        }
    }

    private func captureViewport(
        windowId: WindowId,
        state: RenderedPaneState,
        generation: Int,
        reason: String,
        stage: RenderStage,
        sizeEpoch: Int
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
                sizeEpoch: sizeEpoch,
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
        reason: String,
        sizeEpoch: Int
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
            let finish: (RenderedPaneState, [String]?) -> Void = { [weak self] settledState, scrubLines in
                self?.finishRenderedWindowRefresh(
                    windowId: windowId,
                    state: settledState,
                    generation: generation,
                    stage: .deep,
                    reason: reason,
                    sizeEpoch: sizeEpoch,
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
                finish(state, nil)
                return
            }

            // A deep history capture can take tens or hundreds of milliseconds.
            // During continuity attach that is long enough for the remote TUI
            // to finish redrawing for the phone grid and move its cursor, even
            // though no further client-size epoch is emitted. Reusing the
            // metadata sampled before the history capture then paints the fresh
            // scrub with the old bottom-row cursor until input or rotation
            // triggers another refresh. Queue the settled metadata and final
            // viewport capture together so no other control command can land
            // between their snapshots in tmux's FIFO.
            Self.logDiagnostic(
                "render-refresh send-settled-metadata window=\(windowId) generation=\(generation) stage=deep reason=\(reason)"
            )
            self.enqueueControlCommandPair(
                "display-message -p -t \(windowId.description) '\(Self.renderedPaneMetadataFormat)'",
                "capture-pane -p -e -N -t \(windowId.description)"
            ) { [weak self] metadataResult, captureResult in
                guard let self else { return }
                guard self.isCurrentGeneration(generation),
                      self.controlPath == .inline,
                      self.activeWindowId == windowId
                else {
                    self.clearPendingRenderRefresh(windowId: windowId, generation: generation)
                    Self.logDiagnostic(
                        "render-refresh settled-pair stale window=\(windowId) generation=\(generation) metadata='\(Self.describe(metadataResult))' capture='\(Self.describe(captureResult))'"
                    )
                    return
                }
                guard case .success(let lines) = metadataResult,
                      let head = lines.first(where: { !$0.isEmpty }),
                      let settledState = Self.parseRenderedPaneState(head)
                else {
                    self.abortRenderRefreshIfCurrent(
                        windowId: windowId,
                        generation: generation,
                        stage: .deep,
                        reason: "deep-settled-metadata"
                    )
                    Self.logDiagnostic(
                        "render-refresh settled-metadata failed window=\(windowId) generation=\(generation) result='\(Self.describe(metadataResult))' detail=\(Self.describeMetadataResponse(metadataResult))"
                    )
                    return
                }
                guard settledState.paneId == state.paneId,
                      !settledState.paneInAltScreen
                else {
                    Self.logDiagnostic(
                        "render-refresh settled-metadata changed window=\(windowId) generation=\(generation) oldPane=\(state.paneId) newPane=\(settledState.paneId) paneAlt=\(settledState.paneInAltScreen)"
                    )
                    self.refreshRenderedWindow(
                        windowId: windowId,
                        generation: generation,
                        reason: "deep-settled-state-change",
                        stage: .deep
                    )
                    return
                }
                guard case .success(let scrubLines) = captureResult,
                      !scrubLines.isEmpty
                else {
                    self.abortRenderRefreshIfCurrent(
                        windowId: windowId,
                        generation: generation,
                        stage: .deep,
                        reason: "deep-scrub"
                    )
                    Self.logDiagnostic(
                        "render-refresh capture failed window=\(windowId) generation=\(generation) stage=deep result='\(Self.describe(captureResult))' reason=deep-scrub"
                    )
                    return
                }
                if settledState.cursorX != state.cursorX || settledState.cursorY != state.cursorY {
                    Self.logDiagnostic(
                        "render-refresh cursor-resync window=\(windowId) generation=\(generation) old=\(state.cursorX),\(state.cursorY) new=\(settledState.cursorX),\(settledState.cursorY)"
                    )
                }
                finish(settledState, scrubLines)
            }
        }
    }

    private func captureDeepAltScreen(
        windowId: WindowId,
        state: RenderedPaneState,
        generation: Int,
        reason: String,
        sizeEpoch: Int
    ) {
        let sendSavedPrimary: ([String]) -> Void = { [weak self] historyLines in
            guard let self else { return }
            self.sendCaptureCommand(
                "capture-pane -p -e -N -a -q -t \(windowId.description)",
                windowId: windowId,
                generation: generation,
                stage: .deep,
                failureReason: "deep-saved-primary",
                bodyPolicy: .optionalSupplement
            ) { [weak self] savedPrimaryLines in
                guard let self else { return }
                self.enqueueControlCommandPair(
                    "display-message -p -t \(windowId.description) '\(Self.renderedPaneMetadataFormat)'",
                    "capture-pane -p -e -N -t \(windowId.description)"
                ) { [weak self] metadataResult, captureResult in
                    guard let self else { return }
                    guard self.isCurrentGeneration(generation),
                          self.controlPath == .inline,
                          self.activeWindowId == windowId
                    else {
                        self.clearPendingRenderRefresh(windowId: windowId, generation: generation)
                        return
                    }
                    guard case .success(let metadataLines) = metadataResult,
                          let head = metadataLines.first(where: { !$0.isEmpty }),
                          let settledState = Self.parseRenderedPaneState(head)
                    else {
                        self.abortRenderRefreshIfCurrent(
                            windowId: windowId,
                            generation: generation,
                            stage: .deep,
                            reason: "deep-alt-settled-metadata"
                        )
                        return
                    }
                    guard settledState.paneId == state.paneId,
                          settledState.paneInAltScreen
                    else {
                        Self.logDiagnostic(
                            "render-refresh settled-alt-state changed window=\(windowId) generation=\(generation) oldPane=\(state.paneId) newPane=\(settledState.paneId) paneAlt=\(settledState.paneInAltScreen)"
                        )
                        self.refreshRenderedWindow(
                            windowId: windowId,
                            generation: generation,
                            reason: "deep-alt-settled-state-change",
                            stage: .deep
                        )
                        return
                    }
                    guard case .success(let altScreenLines) = captureResult,
                          !altScreenLines.isEmpty
                    else {
                        self.abortRenderRefreshIfCurrent(
                            windowId: windowId,
                            generation: generation,
                            stage: .deep,
                            reason: "deep-alt"
                        )
                        return
                    }
                    if settledState.cursorX != state.cursorX || settledState.cursorY != state.cursorY {
                        Self.logDiagnostic(
                            "render-refresh cursor-resync window=\(windowId) generation=\(generation) old=\(state.cursorX),\(state.cursorY) new=\(settledState.cursorX),\(settledState.cursorY)"
                        )
                    }
                    self.finishRenderedWindowRefresh(
                        windowId: windowId,
                        state: settledState,
                        generation: generation,
                        stage: .deep,
                        reason: reason,
                        sizeEpoch: sizeEpoch,
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
            failureReason: "deep-history",
            bodyPolicy: .optionalSupplement
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
        bodyPolicy: CaptureBodyPolicy = .requiredGrid,
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
            // Visible/full-grid `capture-pane -p` emits one body line per
            // terminal row, including empty strings for a genuinely blank
            // pane. A successful response with zero rows therefore cannot
            // describe that grid. Supplemental alternate-screen history and
            // `capture-pane -a -q` are optional: history may race to empty,
            // and no saved primary grid legitimately has no body.
            // The July 19 device log showed an impossible zero-row viewport
            // being committed as authoritative: RepaintAssembly cleared the
            // shared SwiftTerm canvas and restored only the cursor, while the
            // next repaint waited indefinitely behind a nonempty command FIFO.
            //
            // Treat zero rows like a transient command failure. Established
            // swaps retain their previous pixels behind the existing
            // fail-closed gate; deep-stage failures retain the valid viewport.
            if case .requiredGrid = bodyPolicy, captureLines.isEmpty {
                self.abortRenderRefreshIfCurrent(
                    windowId: windowId,
                    generation: generation,
                    stage: stage,
                    reason: "\(failureReason)-empty"
                )
                Self.logDiagnostic(
                    "render-refresh capture rejected-empty window=\(windowId) generation=\(generation) stage=\(stage) commandCategory=\(Self.commandCategory(command)) clientRows=\(self.lastKnownSize?.rows ?? -1)"
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
        sizeEpoch: Int,
        captureLines: [String],
        historyLines: [String],
        savedPrimaryLines: [String],
        altScreenLines: [String]?,
        scrubLines: [String]? = nil
    ) {
        guard feedTerminalWithContext != nil || feedTerminal != nil,
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
        // A `refresh-client -C` sent after this refresh's metadata query was
        // FIFO-processed by tmux before the capture reply: `state` (cursor
        // row/col) and `captureLines` describe different grids, and painting
        // the pair shifts rows and misplaces the restored cursor. Discard the
        // frame and re-run the whole refresh — the new metadata query queues
        // behind the resize, so the retry snapshot is coherent.
        if sizeEpoch != clientSizeEpoch,
           renderSizeResyncAttempts < Self.maxClientSizeResyncAttempts {
            renderSizeResyncAttempts += 1
            Self.logDiagnostic(
                "render-refresh size-resync window=\(windowId) generation=\(generation) stage=\(stage) attempt=\(renderSizeResyncAttempts) reason=\(reason)"
            )
            refreshRenderedWindow(
                windowId: windowId,
                generation: generation,
                reason: "size-resync",
                stage: stage
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
                deliverToSharedTerminal(
                    ArraySlice(retainedOutput.bytes),
                    context: TerminalFeedContext(
                        source: .foregroundReplay,
                        paneId: state.paneId,
                        windowId: windowId,
                        generation: generation,
                        reason: reason
                    )
                )
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

        let repaintSource: TerminalFeedSource
        switch stage {
        case .viewport:
            repaintSource = .viewportRepaint
        case .viewportOnly:
            repaintSource = .viewportRefresh
        case .deep:
            repaintSource = .deepRepaint
        }
        deliverToSharedTerminal(
            ArraySlice(bytes),
            context: TerminalFeedContext(
                source: repaintSource,
                paneId: state.paneId,
                windowId: windowId,
                generation: generation,
                captureRows: captureLines.count,
                reason: reason
            )
        )

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
            deliverToSharedTerminal(
                ArraySlice(scrubBytes),
                context: TerminalFeedContext(
                    source: .repaintScrub,
                    paneId: state.paneId,
                    windowId: windowId,
                    generation: generation,
                    captureRows: scrubLines.count,
                    reason: reason
                )
            )
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
        renderSizeResyncAttempts = 0
        if !refreshesRenderedPaneInPlace {
            displayDidSwap?(windowId)
        } else {
            displayDidRefresh?(windowId)
        }
        clearPendingRenderRefresh(windowId: windowId, generation: generation)
        if completesForegroundOutputCoalescing {
            endForegroundOutputCoalescing()
        }
        completeGridAuthoritySharedRepaintIfNeeded(windowId: windowId)
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
