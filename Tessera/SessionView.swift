import SwiftUI
import SwiftTerm
import ScrollDispatcher
import TmuxControl
import PortForwarding
import UIKit
import GameController

private var integrationScrollHarnessSuppressesFirstResponder: Bool {
#if DEBUG
    ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_HARNESS"] == "1"
        && UIDevice.current.userInterfaceIdiom != .phone
#else
    false
#endif
}

private enum TesseraTerminalFont {
    static func mono(size: CGFloat) -> UIFont {
        let base = UIFont(name: "JetBrainsMono-Regular", size: size)
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let cascade = ["STIXTwoMath-Regular", "Menlo-Regular"].compactMap {
            UIFont(name: $0, size: size)?.fontDescriptor
        }
        guard !cascade.isEmpty else { return base }

        // Prefer text glyph fallback for text-default emoji-capable symbols;
        // explicit emoji presentation with VS16 still falls through to color emoji.
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: cascade
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// Reference box for diagnostics counters. Deliberately NOT observable:
/// these bump on every scroll event when diagnostics are enabled, and as
/// `@State var` they invalidated the entire session view body per event —
/// a CA commit per pointer event, which on an idle-refresh (24Hz) panel
/// blocks the main thread to the panel rate and starves event delivery,
/// display links, and MainActor ingest for the whole gesture.
private final class ScrollDiagnosticCounters {
    var sequence = 0
    var gateLogCount = 0
    /// Alt-screen proxy deltas arrive per display frame (~120Hz); a log
    /// per event would wipe the ~900-line diagnostics ring in seconds.
    var altProxyEventCount = 0
}

/// Hosts a `TerminalSurface` bound to an `SSHSession`. The terminal view
/// is created once and retained; session output bytes are pumped into
/// it via the session's `outputStream`.
///
/// v1 layout (§3.5 R3.5.2): a `SessionTopBar` occupies the top
/// corner-inset area and is always visible — space the terminal
/// content can't use anyway because of the iPad's rounded display
/// corners. Below it, the terminal content area fills to the bottom edge
/// while keeping the horizontal inset needed for the rounded corners. When
/// tmux -CC lands (§3.2), the same top bar morphs into an iTerm2-style tab
/// strip without changing the outer layout.
struct SessionView: View {
    @StateObject var session: SSHSession
    /// Identifier of the owning `LiveSession` so the MRU cycle can
    /// exclude "the session we're already in" when seeding its walk
    /// snapshot. Bound from the `ForEach` in `ContentView`.
    var liveSessionID: UUID
    /// Whether this session is the foreground (visible) session.
    /// Hidden sessions suppress resize propagation to avoid sending
    /// SIGWINCH to background TUIs when the sidebar toggles or the
    /// device rotates.
    var isActive: Bool
    /// Toggles the sidebar visibility from within the session.
    var onToggleSidebar: () -> Void
    /// Whether the sidebar is currently shown — drives the top-bar
    /// toggle's accent tint so the button reflects its on/off state.
    var sidebarVisible: Bool
    /// Called when the user taps "back" — hides the session without
    /// disconnecting so it stays alive for switching back to.
    var onBack: () -> Void
    /// Called from the connection-failed overlay's "edit host" button.
    /// The parent removes this session and opens the host editor.
    var onEditHost: () -> Void
    /// Called from the connection-failed overlay's "retry" button. The
    /// parent removes this session and reconnects with the same host.
    var onRetry: () -> Void
    /// Called when the SSH session terminates (clean exit or error).
    /// The parent should remove this session from its active list.
    var onSessionEnded: () -> Void
    /// Called when the ⌃Tab MRU cycle commits to a session OR when the
    /// command palette commits. The parent translates the id into a
    /// `selectedItem = .session(id)` update.
    var onSelectSession: (UUID) -> Void
    /// Called when ⌘, fires inside the session. The parent opens the
    /// Settings page (`selectedItem = .settings`).
    var onOpenSettings: () -> Void
    /// Called when ⌘⇧A fires inside SwiftTerm.
    var onOpenAgentCenter: (() -> Void)?
    /// Reports auto-tmux degrading to the already-connected plain shell.
    var onEffectiveLaunchModeChanged: (HostLaunchMode) -> Void = { _ in }

    /// Terminal view reference captured via `onMade` so we can feed it
    /// from the session's output stream.
    @State private var terminalBox = TerminalBox(traceLabel: "ssh")
    @State private var tmuxTerminalQueryResponder = TerminalOSCColorQueryResponder()
    @State private var kittyWindowModes = KittyWindowModeStore()
    /// Per-pane kitty/2004 modes for the multi-pane grid (analog of
    /// `kittyWindowModes` for the single-pane path). Held here so pane modes
    /// survive window switches and grid mount/unmount.
    @State private var kittyPaneModes = KittyPaneModeStore()
    @State private var modifierState = ModifierState()

    /// §3.2 tmux -CC router. In passthrough mode it's a transparent
    /// pipe between the SSH session and SwiftTerm; as soon as tmux's
    /// `ESC P 1 0 0 0 p` prologue appears in the output stream the
    /// controller swaps modes, parses control-mode messages, and
    /// wraps typed keystrokes in `send-keys` commands.
    @State private var tmux = TmuxController(clientSizePolicy: .resizeTmux)
    @State private var shellIntegration = SwipePadShellIntegrationTracker()
    @State private var swipePadOutputActivityToken = 0
    @State private var swipePadOutputActivityTask: Task<Void, Never>?
    @State private var swipePadSessionIsActive = false
    @State private var agentSourceRegistrationID: UUID?

    /// Set to `true` once we've sent the auto-tmux shell snippet for
    /// this connect, so we don't re-send it on every state churn.
    /// Reset would only matter if the same `SessionView` instance
    /// reconnected, which it doesn't in the multi-session model.
    @State private var sentAutoTmuxCommand = false

    /// Banner state for "tmux not available on this host". Set when
    /// the auto-tmux script's failure path's sentinel byte sequence
    /// shows up in the SSH output stream. Dismissable.
    @State private var noTmuxBannerVisible = false
    @State private var noTmuxScanner = AutoTmuxSentinelScanner()
    @State private var dismissedWSLTailscaleMTUWarning = false

    /// Full terminal-area loading shield shown from connect-start until
    /// the session is ready: `.connected` for `.customCommand`; first
    /// tmux pane render for `.autoTmux` / `.pinnedTmux`. Replaces the
    /// v1 tmux-only overlay (commit 6a01abc) with a unified visual.
    /// Defaults to `true` so the overlay is up immediately when the
    /// view appears; dismissed by the mode-specific signal handlers
    /// below (see `.onChange(of: session.state)` and
    /// `.onChange(of: tmux.isInitialRenderReady)`).
    @State private var launchOverlayVisible = true

    /// T5 auto-reclaim toast ("iPhone left — control returned here").
    @State private var authorityReturnedToastVisible = false
    @State private var authorityReturnedToastLabel: String?
    @State private var authorityToastDismissTask: Task<Void, Never>?
    /// Last terminal size reported by the TerminalView. Cached so
    /// we can replay it when foregrounded after being hidden.
    @State private var lastTerminalSize: (cols: Int, rows: Int)?
    /// Physical phone viewport, separate from the authoritative tmux canvas.
    /// Hidden compact sessions keep this current without resizing their remote
    /// TUI; the selected session replays it when it becomes active.
    @State private var lastCompactViewportSize: (cols: Int, rows: Int)?
    /// Expanded tmux client canvas last sent for that physical viewport. A
    /// split window may be wider/taller so its focused pane receives the full
    /// phone cell grid while the saved tmux layout remains unchanged.
    @State private var lastCompactClientSize: (cols: Int, rows: Int)?

    /// Cached tmux session name we resolved for this host on first
    /// access. Computed lazily and held as state so the view body
    /// doesn't recompute the SHA-256 derivation on every render.
    @State private var resolvedTmuxSessionName: String?
    @State private var currentTerminalTitle: String? = nil

    /// Transient toast for a failed pane operation (e.g. "pane too small").
    @State private var paneCommandToast: String? = nil
    @State private var paneCommandToastTask: Task<Void, Never>? = nil
    @State private var agentScrollNotice = AgentScrollPreventionNoticeController()

    /// §R4.6 find-in-scrollback. The bar is hidden until the user
    /// taps the `⌕` button in the top bar or hits ⌘F. Owns search
    /// query / options state and the dispatch closures into the
    /// SwiftTerm view (installed below in `.task`).
    @State private var findController = FindController()

    /// Remote Files panel. Per-session, mirrors the find controller's
    /// scoping; the FileBridge attaches lazily on first open via the
    /// app-wide FileBridgeRegistry (never-auto-connect: nothing dials
    /// until the user opens the panel).
    @State private var filesPanel = FilesPanelController()
    /// True once OSC 7 has delivered outside tmux this session — the
    /// only state that proves the signal is live in passthrough. The
    /// terminal's `hostCurrentDirectory` alone can't prove it: that
    /// property never clears, and pane bytes riding the tmux control
    /// channel can latch a value the plain shell will never refresh.
    @State private var osc7DeliveredInPassthrough = false
    @AppStorage(DiagnosticLogStore.scrollDiagnosticsDefaultsKey)
    private var scrollDiagnosticsEnabled = false
    @State private var scrollDiagnostics = ScrollDiagnosticCounters()

    /// Live AppearancePreferences read so chrome bg + top-bar tokens follow
    /// the user's terminal theme choice — see `themeChromeTokens` below.
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(AppLockController.self) private var appLockController
    @Environment(BellController.self) private var bellController
    @Environment(TunnelsRegistry.self) private var tunnelsRegistry
    @Environment(SwipePadProfileStore.self) private var swipePadStore
    @Environment(SpeechDictationController.self) private var dictationController
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(AgentCenter.self) private var agentCenter
    @Environment(AppPhase.self) private var appPhase
    @Environment(FileBridgeRegistry.self) private var fileBridges
    @Environment(HostTerminalBackgroundStore.self) private var hostBackgrounds
    @Environment(\.designTokens) private var appDesignTokens
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var activeTheme: TerminalTheme {
        TerminalTheme.find(id: appearance.terminalThemeID)
    }

    private var isPhone: Bool {
        CompactLayout.isPhone(horizontalSizeClass)
    }

    private var themeChromeTokens: DesignTokens {
        activeTheme.chromeTokens(applying: appearance)
    }

    /// The iPad inspector visually belongs to the terminal, but the compact
    /// presentation is a system sheet above the app shell. Matching that
    /// sheet to the app appearance keeps light mode from pairing a light
    /// presentation surface with terminal-theme white text.
    private var filesPanelTokens: DesignTokens {
        isPhone ? appDesignTokens : themeChromeTokens
    }

    /// Background picture for this session's canvas (host override → global),
    /// nil for the classic solid theme color.
    private var resolvedTerminalBackground: ResolvedTerminalBackground? {
        ResolvedTerminalBackground.resolve(
            hostID: session.host.id,
            appearance: appearance,
            hostStore: hostBackgrounds
        )
    }

    /// The tmux window tmux currently considers active, if known.
    private var activeWindow: TmuxController.WindowInfo? {
        guard let id = tmux.activeWindowId else { return nil }
        return tmux.windows.first(where: { $0.id == id })
    }

    /// The active window iff it must render as a multi-pane grid. `nil` keeps
    /// the shared single-pane terminal (today's fast path).
    private var activeGridWindow: TmuxController.WindowInfo? {
        guard let window = activeWindow, window.rendersAsPaneGrid else { return nil }
        return window
    }

    private var compactTmuxLayout: WindowLayout? {
        guard let window = activeWindow else { return nil }
        return window.isZoomed
            ? (window.visibleLayout ?? window.layout)
            : window.layout
    }

    private var compactTmuxWindowRect: CellRect? {
        guard isPhone, tmux.mode == .tmuxControl else { return nil }
        return compactTmuxLayout?.root.rect
            ?? activeWindow?.panes.first?.contentRect
    }

    private var compactTmuxFocusRect: CellRect? {
        guard let window = activeWindow,
              let paneID = window.activePaneId ?? tmux.activePaneId
        else { return compactTmuxWindowRect }
        return compactTmuxLayout?.leaves.first(where: { $0.paneId == paneID })?.rect
            ?? window.panes.first(where: { $0.id == paneID })?.contentRect
            ?? compactTmuxWindowRect
    }

    private var compactTmuxSizingKey: String {
        func token(_ rect: CellRect?) -> String {
            guard let rect else { return "nil" }
            return "\(rect.width)x\(rect.height)+\(rect.x)+\(rect.y)"
        }
        return [
            String(describing: tmux.mode),
            tmux.activeWindowId?.description ?? "nil",
            tmux.activePaneId?.description ?? "nil",
            token(compactTmuxWindowRect),
            token(compactTmuxFocusRect),
        ].joined(separator: ":")
    }

    /// A single-pane tmux window still keeps its remote grid on phone. Split
    /// windows use `PaneGridView.compactSinglePane` instead.
    private var compactSingleWindowRect: CellRect? {
        guard isPhone,
              tmux.mode == .tmuxControl,
              activeGridWindow == nil
        else { return nil }
        return compactTmuxWindowRect
    }

    /// Character-cell size for the live terminal font, used to lay out pane
    /// frames as exact cell multiples (matches SwiftTerm's own grid snapping).
    private var terminalCellSize: CGSize {
        let size = CGFloat(appearance.fontSize)
        let font = TesseraTerminalFont.mono(size: size)
        return TerminalCellMetrics.cellSize(font: font, scale: UIScreen.main.scale)
    }

    private func updateCompactInlineViewport(_ size: CGSize) {
        guard isPhone,
              let viewport = CompactTmuxClientSizing.viewportCells(
                for: size,
                cellSize: terminalCellSize
              )
        else { return }
        lastCompactViewportSize = viewport
        guard isActive, appPhase.isActive else { return }
        pushCompactInlineViewport(viewport)
    }

    private func pushCompactInlineViewport(
        _ viewport: (cols: Int, rows: Int),
        force: Bool = false
    ) {
        let client = CompactTmuxClientSizing.clientSize(
            for: viewport,
            windowRect: compactTmuxWindowRect,
            focusRect: compactTmuxFocusRect
        )
        if !force,
           let lastCompactClientSize,
           lastCompactClientSize.cols == client.cols,
           lastCompactClientSize.rows == client.rows {
            return
        }
        lastCompactClientSize = client
        session.resize(cols: client.cols, rows: client.rows)
        tmux.updateClientSize(cols: client.cols, rows: client.rows)
    }

    /// Repaint the visible SSH terminal and ask inline tmux for a fresh
    /// authoritative capture when -CC is active. Replaying the current size
    /// also gives plain SSH/TUI sessions the same redraw signal without
    /// tearing down the live connection.
    private func forceRefreshTerminal() {
        guard isActive, appPhase.isActive, session.state == .connected else { return }
        appLockController.notifyUserActivity()
        terminalBox.forceRedraw()

        if isPhone, let viewport = lastCompactViewportSize {
            pushCompactInlineViewport(viewport, force: true)
        } else if activeGridWindow == nil, let size = lastTerminalSize {
            // A mounted pane grid owns a smaller, header-reserved tmux size.
            // Replaying the hidden shared terminal's full height here would
            // overwrite that authority without a grid-layout change to heal it.
            session.resize(cols: size.cols, rows: size.rows)
            tmux.updateClientSize(cols: size.cols, rows: size.rows)
        }
        // Recovery path doubles as the viewport claim. The controller orders
        // the no-op latest-client fence, geometry confirmation, and exactly
        // one authoritative capture before completing the claim; starting a
        // second capture here can race that sequence and repaint stale cells.
        tmux.claimActiveViewport(
            reason: "force-refresh",
            repaintEvenIfSame: true
        )
    }

    /// Take back the shared tmux grid from the device that continued this
    /// session. The controller restamps authority and replays our size; the
    /// veil lifts only after geometry confirmation and any required repaint.
    private func takeBackContinuedSession() {
        appLockController.notifyUserActivity()
        tmux.reclaimGridAuthority()
    }

    /// The peer detached and the controller auto-reclaimed — confirm with a
    /// transient toast instead of requiring a tap.
    private func presentAuthorityReturnedToast(departedPeerName: String?) {
        let selfName = GridAuthorityDeviceIdentity.selfDisplayName
        authorityReturnedToastLabel = departedPeerName.map {
            $0 == selfName ? "another \($0)" : $0
        }
        authorityToastDismissTask?.cancel()
        authorityReturnedToastVisible = true
        authorityToastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            authorityReturnedToastVisible = false
        }
    }

    /// `.unknown` is a transport gap, not evidence that this session stopped
    /// being controlled elsewhere. Preserve the sidebar's last-known glyph
    /// across reconnect/background teardown; `.mine` or session removal is
    /// the authoritative clear.
    private func mirrorGridAuthorityInRegistry(
        _ authority: TmuxController.GridAuthority
    ) {
        switch authority {
        case .peer(let displayName):
            sessionRegistry.setGridAuthorityPeerName(displayName, for: liveSessionID)
        case .mine:
            sessionRegistry.setGridAuthorityPeerName(nil, for: liveSessionID)
        case .unknown:
            break
        }
    }

    private func handleCompactTmuxFocusRequest() {
        guard let request = sessionRegistry.tmuxFocusRequest,
              request.sessionID == liveSessionID
        else { return }
        tmux.selectWindow(request.windowID)
        if let paneID = request.paneID {
            tmux.selectPanePreservingWindowZoom(paneID)
        }
    }

    private var showsLaunchOverlay: Bool { launchOverlayVisible }

    /// Caption shown by the launch overlay. Phases map 1:1 to
    /// observable transitions in `session.state` + `tmux.mode` +
    /// `tmux.isInitialRenderReady`; no aspirational steps. Plain SSH
    /// (`.customCommand`) only ever sees `.connecting` because the
    /// overlay dismisses on first `.connected`.
    private var launchPhase: SessionLaunchPhase {
        if session.state != .connected { return .connecting }
        if tmux.mode != .tmuxControl   { return .startingTmux }
        return .attachingPane
    }

    /// Sub-line shown below the phase caption. The tmux session name
    /// for tmux modes; nil (collapses to whitespace) for plain shell.
    private var launchSubtitle: String? {
        switch session.host.launchMode {
        case .autoTmux, .pinnedTmux: return resolvedTmuxSessionName
        case .customCommand:         return nil
        }
    }

    /// Non-nil when the connect attempt failed; flips the launch overlay
    /// into its error state (the overlay no longer dismisses on `.failed`).
    private var launchFailureReason: String? {
        if case .failed(let reason) = session.state { return reason }
        return nil
    }

    /// ⌘⇧E / top-bar toggle. First open attaches the shared per-host
    /// bridge (same auth flags the terminal connected with, so trust
    /// and biometric gating behave identically) and seeds the cwd from
    /// whichever source is live.
    private func toggleFilesPanel() {
        terminalBox.dismissTransientInteractions()
        if filesPanel.isOpen {
            withAnimation(.easeInOut(duration: 0.2)) { filesPanel.close() }
            return
        }
        configureFilesPanelIfNeeded()
        if tmux.mode == .tmuxControl {
            filesPanel.terminalReportedDirectory(tmux.activePaneCurrentPath)
        } else if let dir = terminalBox.view?.getTerminal().hostCurrentDirectory {
            filesPanel.terminalReportedDirectory(dir)
        }
        withAnimation(.easeInOut(duration: 0.2)) { filesPanel.open() }
    }

    private var compactFilesBinding: Binding<Bool> {
        Binding(
            get: { isPhone && filesPanel.isOpen },
            set: { if !$0 { filesPanel.close() } }
        )
    }

    /// Bridge/handler wiring shared by the panel toggle and the §3
    /// selection actions (which may run with the panel closed).
    private func configureFilesPanelIfNeeded() {
        if filesPanel.bridge == nil {
            let bridge = fileBridges.bridge(
                for: session.host,
                requireBiometric: session.requireBiometric,
                isSecureEnclave: session.isSecureEnclave
            )
            filesPanel.attach(bridge: bridge)
            filesPanel.configureFileActions(
                transfers: fileBridges.transferQueue(for: bridge),
                hostFolderName: session.host.name
            )
        }
        if filesPanel.onInstallShellIntegration == nil {
            let host = session.host
            let requireBiometric = session.requireBiometric
            let isSecureEnclave = session.isSecureEnclave
            filesPanel.onInstallShellIntegration = { [filesPanel] in
                filesPanel.infoMessage = "Installing shell integration…"
                Task { @MainActor in
                    do {
                        let report = try await RemoteShellIntegrationInstaller.install(
                            on: host,
                            requireBiometric: requireBiometric,
                            isSecureEnclave: isSecureEnclave
                        )
                        filesPanel.infoMessage = "Installed (\(report.rcFilesUpdated.joined(separator: ", "))). Takes effect on the next shell login — run exec $SHELL or reconnect."
                    } catch {
                        filesPanel.infoMessage = nil
                        filesPanel.lastError = error.localizedDescription
                    }
                }
            }
        }
        if filesPanel.onSendPathToTerminal == nil {
            // Same routing as consumePendingPathInjection: quoted
            // absolute path, no trailing Enter; tmux.sendInput covers
            // both stdin (passthrough) and send-keys (-CC). Overlay
            // guard per the accessory-bar convention — during tmux
            // startup the stdin belongs to the -CC bootstrap.
            filesPanel.onSendPathToTerminal = { [weak session, weak tmux] path in
                guard let session, let tmux,
                      session.state == .connected, !showsLaunchOverlay else { return }
                tmux.sendInput(Array(FilesPanelController.shellQuoted(path).utf8))
            }
        }
    }

    /// §3 selection menu: resolve the selected text over the file
    /// bridge — file → Quick Look (works with the panel closed),
    /// directory → the panel opens there. Misses land on the same
    /// toast the terminal drop target uses.
    private func handleSelectionPathAction(
        _ action: TesseraTerminalSelectionPathAction, text: String
    ) {
        guard session.state == .connected, !showsLaunchOverlay else { return }
        appLockController.notifyUserActivity()
        configureFilesPanelIfNeeded()
        let cwd: String? = tmux.mode == .tmuxControl
            ? tmux.activePaneCurrentPath
            : terminalBox.view?.getTerminal().hostCurrentDirectory
        filesPanel.openTerminalPath(
            text,
            cwd: cwd,
            intent: action == .quickLook ? .quickLook : .reveal
        ) { message in
            terminalDropFailure = message
        }
    }

    /// Failed terminal drops surface here (the drop modifier's toast) —
    /// the panel and its error banner may be CLOSED during a drop.
    @State private var terminalDropFailure: String?

    /// Drop-on-terminal: upload to temp over the host's bridge, then
    /// type the quoted resolved path. Trailing space per the desktop
    /// drag-into-terminal convention — it also keeps multi-file drops
    /// from concatenating into one shell word.
    private func handleTerminalDrop(_ providers: [NSItemProvider]) -> Bool {
        guard session.state == .connected,
              !showsLaunchOverlay,
              !tmux.gridAuthority.isPeer
        else { return false }
        let bridge = fileBridges.bridge(
            for: session.host,
            requireBiometric: session.requireBiometric,
            isSecureEnclave: session.isSecureEnclave
        )
        let queue = fileBridges.transferQueue(for: bridge)
        return FilesPanelController.handleTerminalDrop(
            providers,
            queue: queue,
            inject: { [weak session, weak tmux] path in
                guard let session, let tmux,
                      session.state == .connected,
                      !showsLaunchOverlay,
                      !tmux.gridAuthority.isPeer
                else { return }
                tmux.sendInput(Array((FilesPanelController.shellQuoted(path) + " ").utf8))
            },
            reportFailure: { message in
                terminalDropFailure = message
                DiagnosticLogStore.appendApp("terminal-drop failed: \(message)")
            }
        )
    }

    /// Identity for the cwd-poll task; see RemoteCwdPoller.taskKey.
    private var sshCwdPollKey: String {
        RemoteCwdPoller.taskKey(
            panelOpen: filesPanel.isOpen,
            sessionActive: isActive,
            tmuxAttached: tmux.mode == .tmuxControl
        )
    }

    /// Upload sheet's "paste path": type the quoted absolute path into
    /// this session's terminal (no trailing Enter). tmux.sendInput
    /// routes per transport — stdin in passthrough, send-keys to the
    /// active pane under -CC.
    private func consumePendingPathInjection(_ path: String?) {
        guard let path else { return }
        session.pendingPathInjection = nil
        guard session.state == .connected else { return }
        tmux.sendInput(Array(FilesPanelController.shellQuoted(path).utf8))
    }

    /// Plain-SSH follow fallback: OSC 7 stays primary (instant,
    /// per-shell exact — the loop stands down while the terminal has a
    /// live value), the poller covers hosts without shell integration
    /// by following the user's newest tty-attached shell. The install
    /// CTA still exists but now only surfaces when BOTH signals fail
    /// (followState == .unavailable).
    private func runSSHCwdPoll() async {
        guard filesPanel.isOpen, isActive, tmux.mode != .tmuxControl else { return }
        await RemoteCwdPoller.run(
            panel: filesPanel,
            discovery: .newestLoginShell,
            oscSignal: {
                // Gate on a passthrough delivery: see
                // osc7DeliveredInPassthrough for why presence of
                // hostCurrentDirectory alone can't prove liveness.
                osc7DeliveredInPassthrough
                    ? terminalBox.view?.getTerminal().hostCurrentDirectory
                    : nil
            }
        )
    }

    private var sessionDecoratedChrome: some View {
        ZStack(alignment: .top) {
            // §3.5 R3.5.4: background extends edge-to-edge under the
            // rounded corners and home-indicator area. Pinned to the
            // active TerminalTheme's bg so the page-edge gutters blend
            // seamlessly with the SwiftTerm canvas.
            activeTheme.bg.ignoresSafeArea()

            if let background = resolvedTerminalBackground, !showsLaunchOverlay {
                TerminalBackdrop(background: background, baseColor: activeTheme.bg)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                SessionTopBar(
                    state: session.state,
                    host: session.host,
                    sessionID: liveSessionID,
                    sessionIsActive: isActive,
                    tmux: tmux,
                    tmuxIsDegraded: false,
                    connectionStatus: .ssh(state: session.state),
                    onToggleSidebar: onToggleSidebar,
                    sidebarVisible: sidebarVisible,
                    onBack: {
                        terminalBox.dismissTransientInteractions()
                        onBack()
                    },
                    onDisconnect: {
                        terminalBox.dismissTransientInteractions()
                        session.disconnect()
                    },
                    findController: findController,
                    filesPanelOpen: filesPanel.isOpen,
                    onToggleFiles: toggleFilesPanel,
                    bellController: bellController,
                    forwarderManager: session.portForwarderManager,
                    T: themeChromeTokens
                )
                .frame(height: SessionTopBar.reservedHeight(
                    pillHeight: appearance.topBarHeight,
                    compact: isPhone
                ))
                .zIndex(2)

                if findController.isOpen {
                    FindBar(
                        controller: findController,
                        horizontalInset: isPhone ? 10 : Self.cornerInset,
                        T: themeChromeTokens
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Terminal content. Horizontal inset clears the bottom
                // rounded corners (iPadOS's safeAreaInsets has no
                // horizontal component on iPad, so we have to inset
                // manually). The top is already pushed down by the
                // VStack placement below the top bar; the bottom should
                // run edge-to-edge so the terminal uses all rows.
                ZStack {
                    TerminalSurfaceBound(
                        initialData: [],
                        onMade: { view in terminalBox.attach(view) },
                        onReady: { terminalBox.markRenderReady() },
                        onSend: { bytes in
                            guard !showsLaunchOverlay, !tmux.gridAuthority.isPeer else { return }
                            tmux.sendInput(Array(bytes))
                        },
                        onResize: { cols, rows in
                            lastTerminalSize = (cols, rows)
                            // Only propagate resize to the remote when this
                            // session is the foreground tab. Background
                            // sessions must not send SIGWINCH — it would
                            // reflow vim/less/htop while the user isn't
                            // looking, and the "new" size might reflect the
                            // sidebar being open, not the actual terminal
                            // viewport the user will see when they switch.
                            guard isActive else { return }
                            // While a multi-pane grid is mounted IT is the size
                            // authority (it pushes a header-reserved row count via
                            // refresh-client -C). The shared terminal's frame is
                            // unchanged behind the grid, so its sizeChanged would
                            // push the FULL row count and fight the grid's reserved
                            // size — leaving tmux at the wrong height. Suppress the
                            // push here; the grid owns it, and collapse re-pushes
                            // the full size below.
                            guard activeGridWindow == nil else { return }
                            // The compact canvas is framed at the authoritative
                            // server grid, so this inner callback reports server
                            // cells rather than the phone's physical viewport.
                            // Its outer GeometryReader is the sole compact size
                            // authority; feeding this value back can erase the
                            // smaller-phone baseline before an iPad cede.
                            guard !(isPhone && tmux.mode == .tmuxControl) else { return }
                            session.resize(cols: cols, rows: rows)
                            tmux.updateClientSize(cols: cols, rows: rows)
                        },
                        onTitle: { title in
                            // §3.2 C3: OSC 0/1/2 title sequences from the
                            // active pane update the tab label. tmux treats
                            // these as pane_title (no %window-renamed), so
                            // the terminal renderer is the only source.
                            tmux.updateActiveWindowName(title)
                            currentTerminalTitle = title
                        },
                        onUserActivity: {
                            appLockController.notifyUserActivity()
                        },
                        onBell: {
                            bellController.ring(
                                source: .session(session.host.id),
                                isOriginOnScreen: true,
                                hostDisplayName: session.host.name,
                                paneTitle: currentTerminalTitle
                            )
                        },
                        agentScrollBlockingActive:
                            agentScrollPrevention(paneID: activeAgentScrollPaneID) != nil,
                        onAgentScrollBlocked: {
                            presentAgentScrollPrevention(paneID: activeAgentScrollPaneID)
                        },
                        mouseReportingImpliesAltScreen: false,
                        suppressDirectColorQueryResponses: true,
                        softwareModifierState: modifierState,
                        tmuxShortcutsEnabled: true,
                        onTmuxShortcut: handleTmuxShortcut,
                        onFindShortcut: { shortcut in
                            appLockController.notifyUserActivity()
                            switch shortcut {
                            case .open:     findController.open()
                            case .next:     findController.next()
                            case .previous: findController.previous()
                            }
                        },
                        onSwitcherShortcut: { shortcut in
                            appLockController.notifyUserActivity()
                            handleSwitcherShortcut(shortcut)
                        },
                        onOpenSettings: {
                            appLockController.notifyUserActivity()
                            onOpenSettings()
                        },
                        onOpenAgentCenter: onOpenAgentCenter.map { action in
                            {
                                appLockController.notifyUserActivity()
                                action()
                            }
                        },
                        // The shared terminal yields first responder to the
                        // grid's focused pane while a multi-pane window is up.
                        // `!isActive` is load-bearing: background (non-selected,
                        // opacity-0) sessions stay MOUNTED, and without this gate
                        // their terminal reclaims first responder on any
                        // re-render — stealing focus from whatever IS on screen
                        // (e.g. a TextField in the host editor). Only the
                        // foreground session may hold the keyboard.
                        suppressFirstResponderReclaim: integrationScrollHarnessSuppressesFirstResponder
                            || !isActive
                            || findController.isOpen
                            || commandPalette.isOpen
                            || filesPanel.textEntryActive
                            || (isPhone && modifierState.suppressesSoftwareKeyboardReclaim)
                            || tmux.gridAuthority.isPeer
                            || activeGridWindow != nil,
                        forceResignFirstResponder: tmux.gridAuthority.isPeer,
                        onHardwareKey: nil,
                        scrollRetentionID: [
                            "ssh",
                            tmux.activeWindowId?.description ?? "nil",
                            tmux.activePaneId?.description ?? "nil",
                            activeGridWindow?.id.description ?? "nil",
                        ].joined(separator: ":"),
                        onScrollDiagnostic: { message in
                            recordScrollDiagnostic(message)
                        },
                        onHostDirectory: { dir in
                            // OSC 7 owns the cwd only while no tmux is
                            // attached; under tmux the pane-metadata
                            // subscription is the per-pane source of truth.
                            guard tmux.mode == .passthrough else { return }
                            if dir != nil { osc7DeliveredInPassthrough = true }
                            filesPanel.terminalReportedDirectory(dir)
                        },
                        onFilesShortcut: {
                            appLockController.notifyUserActivity()
                            toggleFilesPanel()
                        },
                        onSelectionPathAction: { action, text in
                            handleSelectionPathAction(action, text: text)
                        },
                        terminalBackground: resolvedTerminalBackground
                    )
                    .modifier(GeometryNeutralTmuxCanvasModifier(
                        windowRect: compactSingleWindowRect,
                        focusRect: compactSingleWindowRect,
                        cellSize: terminalCellSize,
                        onViewportSize: updateCompactInlineViewport
                    ))
                    .allowsHitTesting(!showsLaunchOverlay && activeGridWindow == nil)
                    // With a background picture the grid canvas is transparent
                    // (it no longer paints an opaque fill over this inert
                    // surface), so hide the shared surface outright while a
                    // grid is mounted or its stale text bleeds through.
                    .opacity(
                        showsLaunchOverlay
                            || (activeGridWindow != nil && resolvedTerminalBackground != nil)
                            ? 0 : 1
                    )
                    .animation(
                        // Sequential dissolve: snap the terminal to
                        // invisible while the overlay reappears; on
                        // dismiss, wait for the overlay's own removal
                        // transition (0.25 s) to finish before fading
                        // the terminal back in over 0.3 s. The user
                        // sees overlay-out → terminal-in, not a
                        // crossfade.
                        showsLaunchOverlay
                            ? .linear(duration: 0)
                            : .easeInOut(duration: 0.30).delay(0.25),
                        value: showsLaunchOverlay
                    )

                    // Multi-pane grid overlays the shared terminal (which goes
                    // inert — its panes' %output routes to per-pane sinks).
                    if let gridWindow = activeGridWindow, !showsLaunchOverlay {
                        PaneGridView(
                            window: gridWindow,
                            tmux: tmux,
                            cellSize: terminalCellSize,
                            chrome: themeChromeTokens,
                            backgroundColor: activeTheme.bg,
                            terminalBackground: resolvedTerminalBackground,
                            tmuxShortcutsEnabled: true,
                            onTmuxShortcut: handleTmuxShortcut,
                            onFindShortcut: { shortcut in
                                appLockController.notifyUserActivity()
                                switch shortcut {
                                case .open:     findController.open()
                                case .next:     findController.next()
                                case .previous: findController.previous()
                                }
                            },
                            onSwitcherShortcut: { shortcut in
                                appLockController.notifyUserActivity()
                                handleSwitcherShortcut(shortcut)
                            },
                            onOpenSettings: {
                                appLockController.notifyUserActivity()
                                onOpenSettings()
                            },
                            onOpenAgentCenter: onOpenAgentCenter.map { action in
                                {
                                    appLockController.notifyUserActivity()
                                    action()
                                }
                            },
                            onSelectionPathAction: { action, text in
                                handleSelectionPathAction(action, text: text)
                            },
                            onUserActivity: { appLockController.notifyUserActivity() },
                            agentScrollPreventionForPane: { paneID in
                                agentScrollPrevention(paneID: paneID.rawValue)
                            },
                            onAgentScrollBlocked: { paneID in
                                presentAgentScrollPrevention(paneID: paneID.rawValue)
                            },
                            // `!isActive` so a backgrounded grid's focused pane
                            // doesn't reclaim first responder from the foreground
                            // (e.g. the host editor) — same rule as the shared
                            // surface above.
                            suppressFindReclaim: integrationScrollHarnessSuppressesFirstResponder
                                || !isActive
                                || findController.isOpen
                                || commandPalette.isOpen
                                || filesPanel.textEntryActive
                                || (isPhone && modifierState.suppressesSoftwareKeyboardReclaim)
                                || tmux.gridAuthority.isPeer,
                            inputSuppressed: tmux.gridAuthority.isPeer,
                            compactSinglePane: isPhone,
                            modifierState: modifierState,
                            kittyPaneModes: kittyPaneModes,
                            onFocusedBoxChanged: { box in
                                // Find is scoped to the focused pane: rebind
                                // its search handlers and re-run any open query.
                                findController.handlers = TerminalSearchAdapter.handlers(for: box)
                                if findController.isOpen { findController.updateSearch() }
                            },
                            onFocusedPaneRefreshed: {
                                if findController.isOpen { findController.updateSearch() }
                            },
                            onPaneBell: { paneTitle in
                                bellController.ring(
                                    source: .session(session.host.id),
                                    isOriginOnScreen: true,
                                    hostDisplayName: session.host.name,
                                    paneTitle: paneTitle
                                )
                            },
                            onScrollDiagnostic: { paneId, message in
                                recordScrollDiagnostic("surface=pane:\(paneId.description) \(message)")
                            }
                        )
                        .id(gridWindow.id)
                    }

                    if showsLaunchOverlay {
                        SessionLaunchOverlay(
                            T: themeChromeTokens,
                            phase: launchPhase,
                            subtitle: launchSubtitle,
                            wslTailscaleMTUWarning: session.wslTailscaleMTUWarning,
                            failureReason: launchFailureReason,
                            onEditHost: onEditHost,
                            onRetry: onRetry,
                            onBack: onSessionEnded
                        )
                        .transition(.opacity)
                        .zIndex(1)
                    }

                    // Continuity takeover veil: another device holds the grid.
                    // Connection loss and session end outrank it — both are
                    // covered because the veil requires `.connected` and the
                    // launch overlay's failure state wins via the gate above.
                    if let peerName = tmux.gridAuthority.peerDisplayName,
                       !showsLaunchOverlay,
                       session.state == .connected {
                        ContinuedElsewhereOverlay(
                            T: themeChromeTokens,
                            peerDisplayName: peerName,
                            isReclaiming: tmux.gridAuthorityReclaimInFlight,
                            onTakeBack: takeBackContinuedSession
                        )
                        .transition(.opacity)
                        .zIndex(2)
                    }

                    if authorityReturnedToastVisible {
                        GridAuthorityReturnedToast(
                            T: themeChromeTokens,
                            departedPeerLabel: authorityReturnedToastLabel
                        )
                        .transition(.opacity)
                        .zIndex(3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(
                    .easeInOut(duration: 0.35),
                    value: tmux.gridAuthority.isPeer
                )
                .animation(
                    .easeInOut(duration: 0.2),
                    value: authorityReturnedToastVisible
                )
                // Drop a file onto the terminal → upload to the host's
                // temp dir, then type the quoted path (mockup §4). The
                // open panel's own drop zone sits on top and wins over
                // its strip.
                .modifier(TerminalFileDropTarget(
                    T: themeChromeTokens,
                    failureMessage: $terminalDropFailure,
                    handle: handleTerminalDrop
                ))
                // §3 terminal Quick Look with the panel closed: the
                // panel hosts presentedPreview's sheet only while open,
                // so this fallback presents it otherwise. The binding
                // nils itself while the panel is open — exactly one
                // host at a time by construction.
                .sheet(item: Binding(
                    get: { filesPanel.isOpen ? nil : filesPanel.presentedPreview },
                    set: { filesPanel.presentedPreview = $0 }
                )) { request in
                    QuickLookPresenter(fileURL: request.localURL, displayTitle: request.title)
                        .ignoresSafeArea()
                }
                .sheet(isPresented: compactFilesBinding) {
                    FilesPanelView(
                        controller: filesPanel,
                        T: filesPanelTokens,
                        sessionIsActive: isActive,
                        // The compact card sits over its own app-themed sheet,
                        // not directly over the terminal canvas.
                        terminalBackground: nil
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(filesPanelTokens.presentationBg)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                }
                // Remote Files panel floats as an overlay over the
                // terminal — no trailing padding, so the terminal keeps
                // its full width and toggling the panel never resizes it
                // (no sizeChanged → no SIGWINCH / refresh-client reflow).
                // A transparent tap-catcher behind the card dismisses the
                // panel when the user taps the terminal, like the sidebar.
                .overlay(alignment: .trailing) {
                    if filesPanel.isOpen, !isPhone {
                        ZStack(alignment: .trailing) {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) { filesPanel.close() }
                                }
                            FilesPanelView(
                                controller: filesPanel,
                                T: themeChromeTokens,
                                sessionIsActive: isActive,
                                terminalBackground: resolvedTerminalBackground
                            )
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, isPhone ? 4 : Self.cornerInset)

                if appearance.showAccessoryBar {
                    SessionAccessoryBar(
                        accent: appearance.tokens(systemColorScheme: .dark).accent,
                        modifierState: modifierState,
                        onSend: { bytes in
                            guard !showsLaunchOverlay, !tmux.gridAuthority.isPeer else { return }
                            appLockController.notifyUserActivity()
                            tmux.sendInput(bytes)
                        },
                        applicationCursor: { [terminalBox] in
                            terminalBox.view?.getTerminal().applicationCursor ?? false
                        },
                        onPageScrollAttempt: { _ in
                            guard agentScrollPrevention(
                                paneID: activeAgentScrollPaneID
                            ) != nil else { return false }
                            presentAgentScrollPrevention(
                                paneID: activeAgentScrollPaneID
                            )
                            return true
                        }
                    )
                    .allowsHitTesting(!tmux.gridAuthority.isPeer)
                    .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
                }
            }

            // Non-blocking host warnings sit below the top bar. The MTU card
            // lives inside the launch overlay while it is visible, then moves
            // here if the connection recovers.
            if noTmuxBannerVisible
                || (!showsLaunchOverlay
                    && !dismissedWSLTailscaleMTUWarning
                    && session.wslTailscaleMTUWarning != nil)
            {
                VStack(spacing: 8) {
                    if noTmuxBannerVisible {
                        NoTmuxBanner(onDismiss: { noTmuxBannerVisible = false })
                    }
                    if !showsLaunchOverlay,
                       !dismissedWSLTailscaleMTUWarning,
                       let warning = session.wslTailscaleMTUWarning {
                        WSLTailscaleMTUWarningView(
                            warning: warning,
                            T: themeChromeTokens,
                            onDismiss: { dismissedWSLTailscaleMTUWarning = true }
                        )
                    }
                }
                    .padding(.top, SessionTopBar.reservedHeight(
                        pillHeight: appearance.topBarHeight,
                        compact: isPhone
                    ))
                    .padding(.horizontal, Self.cornerInset + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
            }

            if let prevention = agentScrollNotice.prevention {
                AgentScrollPreventionNotice(
                    agentName: prevention.agentName,
                    T: themeChromeTokens
                )
                .padding(.top,
                    SessionTopBar.reservedHeight(
                        pillHeight: appearance.topBarHeight,
                        compact: isPhone
                    )
                    + (findController.isOpen ? 44 : 8)
                    + (noTmuxBannerVisible ? 58 : 0)
                )
                .padding(.horizontal, isPhone ? 12 : Self.cornerInset + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(7)
            }

            SwipePadOverlay(
                onSend: { bytes in
                    guard !showsLaunchOverlay, !tmux.gridAuthority.isPeer else { return }
                    appLockController.notifyUserActivity()
                    tmux.sendInput(bytes)
                },
                tmux: tmux,
                outputActivityToken: swipePadOutputActivityToken,
                processNameProvider: {
                    if let name = agentCenter.activeLifecycleProcessName(
                        sessionID: liveSessionID,
                        paneID: nil
                    ) {
                        SwipePadDiagnostics.log(
                            "provider ssh source=agent-lifecycle candidateCount=1"
                        )
                        return [name]
                    }

                    let names = shellIntegration.processNames
                    if !names.isEmpty {
                        SwipePadDiagnostics.log(
                            "provider ssh source=shell-integration candidateCount=\(names.count)"
                        )
                        return names
                    }

                    SwipePadDiagnostics.log(
                        "provider ssh source=plain-ssh reason=shell-integration-empty"
                    )
                    let probeNames = await session.detectForegroundProcessNames()
                    SwipePadDiagnostics.log("provider ssh source=plain-ssh candidateCount=\(probeNames.count)")
                    return probeNames
                },
                paneProcessNameProvider: { paneID, panePID in
                    if let name = agentCenter.activeLifecycleProcessName(
                        sessionID: liveSessionID,
                        paneID: paneID?.rawValue
                    ) {
                        SwipePadDiagnostics.log(
                            "provider ssh source=agent-lifecycle panePID=\(panePID) candidateCount=1"
                        )
                        return [name]
                    }

                    let names = await session.detectForegroundProcessNames(rootPID: panePID)
                    SwipePadDiagnostics.log(
                        "provider ssh source=tmux-pane-ps panePID=\(panePID) candidateCount=\(names.count)"
                    )
                    return names
                },
                agentContext: agentCenter.swipePadContext(sessionID: liveSessionID),
                sessionIsActive: swipePadSessionIsActive,
                onShowMore: onOpenAgentCenter,
                profileStore: swipePadStore,
                dictationController: dictationController
            )
            .padding(.top, SessionTopBar.reservedHeight(
                pillHeight: appearance.topBarHeight,
                compact: isPhone
            ))
            .padding(.horizontal, isPhone ? 10 : Self.cornerInset)
            .padding(.bottom, appearance.showAccessoryBar ? 52 : max(Self.cornerInset - 8, 4))
            // The puck is terminal input chrome. Move the entire sibling
            // below the terminal layer while yielded so the takeover veil
            // visually owns the full canvas, and disable hit testing as a
            // second line behind the controller's input gate.
            .allowsHitTesting(!tmux.gridAuthority.isPeer)
            .zIndex(tmux.gridAuthority.isPeer ? -1 : 5)

            if let toast = paneCommandToast {
                PaneCommandToast(message: toast, T: themeChromeTokens)
                    .padding(.bottom, appearance.showAccessoryBar ? 64 : 24)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: noTmuxBannerVisible)
        .animation(.easeInOut(duration: 0.25), value: showsLaunchOverlay)
        .animation(.easeInOut(duration: 0.2), value: paneCommandToast)
        .animation(.easeInOut(duration: 0.18), value: agentScrollNotice.prevention)
        .ignoresSafeArea(.container, edges: .bottom)
        .onChange(of: activeGridWindow?.id) { oldValue, newValue in
            reconcileAgentScrollNotice()
            if oldValue == nil, newValue != nil {
                // 1→N boundary: the shared terminal is being torn off the hot
                // path OUTSIDE displayWillSwap (no window swap occurs). Without
                // this synthetic snapshot, splitting while a kitty-flags TUI
                // (e.g. Codex) holds the shared terminal would lose its CSI-u
                // keyboard mode. Snapshot under the pane it was rendering so
                // that pane's grid surface restores it on its capture-repaint.
                if let paneId = tmux.renderedPaneId ?? tmux.activePaneId,
                   let terminal = terminalBox.view?.getTerminal() {
                    kittyPaneModes.snapshot(paneId, from: terminal)
                }
            } else if oldValue != nil, newValue == nil {
                // N→1: the grid collapsed back to the shared terminal. The grid
                // had pushed a header-reserved (shorter) row count; the shared
                // terminal's frame is unchanged so its sizeChanged won't fire to
                // correct it. Re-assert the full size AND repaint atomically in
                // the controller (one consistent capture + clientRows, newest
                // generation) so the survivor isn't left cursor-offset or blank
                // by a racing reserved-size refresh. (Also covers switching from
                // a grid window to a single-pane window.)
                if isActive, !isPhone, let size = lastTerminalSize {
                    session.resize(cols: size.cols, rows: size.rows)
                    tmux.resyncRenderedWindowAfterGridCollapse(cols: size.cols, rows: size.rows)
                }
                // Rebind find to the shared terminal (it was scoped to a now-gone
                // pane surface).
                findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)
                if findController.isOpen { findController.updateSearch() }
            }
        }
        .onChange(of: tmux.activePaneCurrentPath) { _, path in
            // tmux modes: the pane-metadata subscription pushes the active
            // pane's cwd (updates on cd AND on pane/window focus change).
            guard tmux.mode == .tmuxControl else { return }
            filesPanel.terminalReportedDirectory(path)
        }
        .onChange(of: tmux.mode) { _, newMode in
            agentCenter.requestRefresh(sessionID: liveSessionID)
            updateSwipePadAgentFocus()
            // tmux detached/exited (reset() flips mode before the pane
            // paths clear, so the watcher above never delivers nil).
            // Fall back to OSC 7 when the shell reports it; nil flips
            // the panel to its no-signal state instead of leaving the
            // last tmux pane path stuck as "following".
            guard newMode == .passthrough else { return }
            filesPanel.terminalReportedDirectory(
                terminalBox.view?.getTerminal().hostCurrentDirectory
            )
        }
        .onChange(of: sessionRegistry.tmuxFocusRequest?.token) { _, _ in
            handleCompactTmuxFocusRequest()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(isPhone ? .automatic : .hidden)
        .onAppear {
            swipePadSessionIsActive = isActive
            updateSwipePadAgentFocus()
            tunnelsRegistry.register(host: session.host.id, manager: session.portForwarderManager)
            #if DEBUG
            if integrationScrollHarnessSuppressesFirstResponder {
                LiveScrollForegroundProbe.registerSendAction {
                    tmux.sendInput(Array((LiveScrollForegroundProbe.marker + "\r").utf8))
                }
            }
            #endif
        }
        .onDisappear {
            terminalBox.dismissTransientInteractions()
            #if DEBUG
            if integrationScrollHarnessSuppressesFirstResponder {
                LiveScrollForegroundProbe.unregisterSendAction()
            }
            #endif
            tunnelsRegistry.unregister(host: session.host.id, manager: session.portForwarderManager)
            if let agentSourceRegistrationID {
                agentCenter.unregister(
                    sessionID: liveSessionID,
                    registrationID: agentSourceRegistrationID
                )
                self.agentSourceRegistrationID = nil
            }
            swipePadOutputActivityTask?.cancel()
            swipePadOutputActivityTask = nil
        }
    }

    private var sessionDecoratedConnection: some View {
        sessionDecoratedChrome
        .task {
            #if DEBUG
            session.noteCompactNavigationHarnessSessionTaskStart()
            #endif
            // Mirror every cwd report onto the session object so
            // transport-agnostic consumers (Upload sheet) can read it.
            filesPanel.onTerminalDirectoryChanged = { [weak session] dir in
                // Change-guarded: the poller re-reports the same path
                // every tick and the mirror is @Published now.
                if session?.remoteWorkingDirectory != dir {
                    session?.remoteWorkingDirectory = dir
                }
            }
            // Connect the tmux controller's upstream/downstream hooks
            // before connecting the session. `feedTerminal` paints the
            // SwiftTerm view; `sendBytes` pushes to the SSH channel.
            tmux.feedTerminalWithContext = { [terminalBox, shellIntegration] slice, feedContext in
                #if DEBUG
                if integrationScrollHarnessSuppressesFirstResponder {
                    LiveScrollForegroundProbe.observeRenderedFeed(slice)
                }
                #endif
                let before = terminalScrollPosition(for: terminalBox.view)
                let performanceContext = TerminalPerformanceFeedContext(feedContext)
                terminalBox.feedTerminalOutput(
                    slice,
                    context: performanceContext,
                    shellIntegration: shellIntegration
                )
                if shouldRecordScrollDiagnostics,
                   let view = terminalBox.view,
                   shouldLogTerminalFeedScroll(before: before, after: terminalScrollPosition(for: view)) {
                    recordScrollDiagnostic(
                        "terminal-feed bytes=\(slice.count) before=\(describeScrollPosition(before)) after=\(describeScrollPosition(for: view))"
                    )
                }
                scheduleSwipePadOutputActivityRefresh(reason: "terminal-output")
            }
            tmux.sendBytes = { [session] bytes in
                session.send(bytes)
            }
            tmux.terminalResponseForOutput = { [tmuxTerminalQueryResponder, appearance] paneId, slice in
                let theme = TerminalTheme.find(id: appearance.terminalThemeID)
                let responses = tmuxTerminalQueryResponder.responses(
                    for: slice,
                    streamID: paneId.description,
                    defaultForegroundRGB: theme.fgRGB,
                    defaultBackgroundRGB: theme.bgRGB
                )
                return responses.isEmpty ? nil : responses
            }
            tmux.displayWillSwap = { [terminalBox, kittyWindowModes, appearance] from, to, paneInAltScreen in
                recordScrollDiagnostic(
                    "tmux-display-will-swap from=\(from?.description ?? "nil") to=\(to.description) paneAlt=\(paneInAltScreen) before=\(describeScrollPosition(for: terminalBox.view))"
                )
                if let terminal = terminalBox.view?.getTerminal() {
                    kittyWindowModes.displayWillSwap(
                        from: from,
                        to: to,
                        paneInAltScreen: paneInAltScreen,
                        terminal: terminal
                    )
                    // Width-mismatch repro: SwiftTerm's actual grid size at swap.
                    // Compare against `repaint-width clientCols`/`captureMaxCols`
                    // in the tmux log — a half-width gray box means one of these
                    // three disagrees.
                    DiagnosticLogStore.appendTmux(
                        "swap-terminal-size to=\(to.description) swiftTermCols=\(terminal.cols) swiftTermRows=\(terminal.rows)"
                    )
                }
                terminalBox.clearScrollback(restoringLimit: appearance.scrollbackLines)
                recordScrollDiagnostic(
                    "tmux-display-will-swap-clear to=\(to.description) after=\(describeScrollPosition(for: terminalBox.view))"
                )
            }
            tmux.terminalIsInAltScreen = { [terminalBox] in
                terminalBox.view?.getTerminal().isCurrentBufferAlternate ?? false
            }
            tmux.displayDidSwap = { [terminalBox, kittyWindowModes, findController] windowId in
                kittyWindowModes.displayDidSwap(to: windowId, terminalBox: terminalBox)
                recordScrollDiagnostic(
                    "tmux-display-did-swap window=\(windowId.description) after=\(describeScrollPosition(for: terminalBox.view))"
                )
                if findController.isOpen {
                    findController.updateSearch()
                }
            }
            tmux.displayDidRefresh = { [findController] _ in
                if findController.isOpen {
                    findController.updateSearch()
                }
            }
            tmux.onBell = { windowID, isActiveWindow, windowName in
                guard !isActiveWindow else { return }
                let bc = bellController
                let sid = session.host.id
                let hname = session.host.name
                Task { @MainActor in
                    bc.ring(
                        source: .tmuxWindow(sessionID: sid, windowID: windowID),
                        isOriginOnScreen: false,
                        hostDisplayName: hname,
                        paneTitle: windowName
                    )
                }
            }
            tmux.onCommandError = { message in
                showPaneCommandError(message)
            }
            tmux.gridAuthorityIdentity = GridAuthorityDeviceIdentity.current()
            tmux.setGridAuthorityUsesCompactSinglePaneGrid(isPhone)
            mirrorGridAuthorityInRegistry(tmux.gridAuthority)
            tmux.onGridAuthorityAutoReclaimed = { peerName in
                presentAuthorityReturnedToast(departedPeerName: peerName)
            }

            findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)

            // Resolve the per-host tmux session name once and stash
            // it in @State so the body and the onChange callbacks
            // share a consistent value (the helper does a SHA-256
            // hash on the fallback path, cheap but worth caching).
            //
            // R6.7: `.pinnedTmux` mode uses the user-supplied name when
            // it passes the shell-safety check; otherwise we fall back
            // to the SHA default rather than corrupting the shell
            // one-liner, since `AutoTmuxScript.command` does not escape.
            // `.customCommand` skips the whole resolution — no tmux
            // command is going to be sent.
            if resolvedTmuxSessionName == nil {
                resolvedTmuxSessionName = MoshBootstrap.resolvedTmuxSessionName(
                    for: session.host
                )
            }

            agentCenter.syncProfiles(swipePadStore.profiles)
            let agentSource = AgentSessionSourceFactory.make(
                sessionID: liveSessionID,
                hostName: session.host.name.isEmpty ? session.host.address : session.host.name,
                baseTransportLabel: "ssh",
                tmux: tmux,
                terminalBox: terminalBox,
                tmuxSessionName: { resolvedTmuxSessionName },
                profiles: { swipePadStore.profiles },
                rawProcessProvider: {
                    return await session.detectForegroundProcessSnapshotIfAvailable()
                },
                paneProcessProvider: { panePID in
                    await session.detectForegroundProcessSnapshotIfAvailable(rootPID: panePID)
                },
                bracketedPasteProvider: { location in
                    if let paneID = location.paneID,
                       let enabled = kittyPaneModes.bracketedPasteEnabled(for: PaneId(paneID)) {
                        return enabled
                    }
                    if let windowID = location.windowID {
                        return kittyWindowModes.bracketedPasteEnabled(for: WindowId(windowID))
                    }
                    return nil
                },
                lifecycleIntegrationCacheKey: session.host.sshConnectionRouteIdentity,
                probeLifecycleIntegration: {
                    try await RemoteAgentLifecycleIntegrationInstaller.probe(
                        execute: {
                            try await session.executeConnectedCommand($0)
                        },
                        diagnostic: { detail in
                            DiagnosticLogStore.appendAgentCenter(
                                "host-diagnostic sid=\(liveSessionID.uuidString.prefix(8)) transport=ssh \(detail)"
                            )
                        }
                    )
                },
                installLifecycleIntegration: {
                    try await RemoteAgentLifecycleIntegrationInstaller.install {
                        try await session.executeConnectedCommand($0)
                    }
                },
                probeShellIntegration: { processIDs, allowInheritedEnvironment in
                    do {
                        let output = try await session.executeConnectedCommand(
                            RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                                processIDs: processIDs,
                                allowInheritedEnvironment: allowInheritedEnvironment
                            )
                        )
                        let parsed = RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(
                            output
                        )
                        let shellDiagnostic = RemoteAgentLifecycleIntegrationInstaller
                            .parseShellDiagnostic(output)?
                            .replacingOccurrences(of: " ", with: ",") ?? "missing"
                        DiagnosticLogStore.appendAgentCenter(
                            "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=ssh processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=\(parsed.map(String.init) ?? "invalid-output") diagnostic=\(shellDiagnostic)"
                        )
                        return parsed
                    } catch {
                        DiagnosticLogStore.appendAgentCenter(
                            "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=ssh processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=transport-failed failureType=\(String(describing: type(of: error)))"
                        )
                        return nil
                    }
                },
                rawSend: { bytes in session.send(bytes) }
            )
            agentSourceRegistrationID = agentSource.registrationID
            agentCenter.register(agentSource)
            let sourceRegistrationID = agentSource.registrationID
            tmux.paneOutputObserver = { paneID, data in
                agentCenter.noteOutput(
                    sessionID: liveSessionID,
                    paneID: paneID.rawValue,
                    registrationID: sourceRegistrationID,
                    data: data
                )
            }
            tmux.paneAgentStateObserver = { paneID, json in
                agentCenter.noteLifecyclePayload(
                    sessionID: liveSessionID,
                    paneID: paneID.rawValue,
                    registrationID: sourceRegistrationID,
                    json: json
                )
            }
            tmux.inputObserver = { paneID, bytes in
                agentCenter.noteInput(
                    sessionID: liveSessionID,
                    paneID: paneID?.rawValue,
                    registrationID: sourceRegistrationID,
                    bytes: bytes
                )
            }

            session.connect()
            for await chunk in session.outputStream {
                // Process the chunk FIRST so any DCS in it has already
                // flipped tmux.mode → .tmuxControl by the time we check.
                // This stops the auto-tmux failure scanner from racing
                // with a successful tmux launch when both the sentinel
                // *and* the DCS land in the same SSH chunk.
                if let startedAt = terminalBox.performanceDiagnostics.beginIngress(
                    byteCount: chunk.count
                ) {
                    await tmux.ingestCooperatively(chunk)
                    terminalBox.performanceDiagnostics.endIngress(startedAt: startedAt)
                } else {
                    await tmux.ingestCooperatively(chunk)
                }
                if tmux.mode == .passthrough, !chunk.isEmpty {
                    agentCenter.noteOutput(
                        sessionID: liveSessionID,
                        paneID: nil,
                        registrationID: sourceRegistrationID,
                        data: chunk[...]
                    )
                }

                // Auto-tmux failure detection: the shell snippet we
                // sent over stdin prints AutoTmuxScript's sentinel
                // bytes when `tmux` isn't on the remote host's PATH.
                // Gated on:
                //   - banner not already shown (idempotent)
                //   - the host opted into auto-tmux
                //   - we're STILL in passthrough mode (tmux didn't
                //     just take over via DCS in this same chunk)
                // The last gate is what makes the happy path quiet:
                // a successful auto-tmux command both echoes the
                // command (octal-escaped sentinel that doesn't match
                // the needle anyway) and flips us to tmuxControl, so
                // by the time we check, the scanner is disabled.
                // R6.8: only scan for the sentinel when we actually
                // sent an auto-tmux command. `.customCommand` mode
                // replaces the one-liner entirely, so the sentinel
                // can't legitimately appear.
                if !noTmuxBannerVisible
                    && sentAutoTmuxCommand
                    && session.host.launchMode != .customCommand
                    && tmux.mode == .passthrough
                    && noTmuxScanner.feed(chunk)
                {
                    launchOverlayVisible = false
                    tmux.suppressPassthroughOutputUntilControlMode = false
                    noTmuxScanner.reset()
                    noTmuxBannerVisible = true
                    HostRuntimeStateStore.recordTmuxUnavailable(for: session.host)
                    onEffectiveLaunchModeChanged(.customCommand)
                }
            }
        }
        .onChange(of: session.state) { _, newState in
            // Clean disconnect (e.g. Ctrl+D) returns to the host list
            // without an error banner. .failed stays put so the user
            // can read the reason before tapping back.
            if newState == .disconnected {
                launchOverlayVisible = false
                tmux.suppressPassthroughOutputUntilControlMode = false
                noTmuxScanner.reset()
                onSessionEnded()
            }
            if case .failed = newState {
                // Keep the launch overlay UP to host the error state +
                // recovery actions (edit host / retry / back), rather than
                // dismissing to a dead shell with a red top-bar string.
                tmux.suppressPassthroughOutputUntilControlMode = false
                noTmuxScanner.reset()
            }

            // First time we hit `.connected`, dispatch on launchMode:
            //   - `.autoTmux` / `.pinnedTmux`: build and send the
            //     auto-tmux shell snippet with the resolved session name.
            //   - `.customCommand`: send the user's command verbatim
            //     (adding a trailing newline if missing) and skip the
            //     tmux path.
            // Plain SSH (`.customCommand`) is ready as soon as the
            // handshake completes — drop the overlay here so the
            // terminal can fade in. Tmux modes wait on `tmux.isInitialRenderReady`
            // (handled further down in `.onChange(of: tmux.isInitialRenderReady)`).
            if case .connected = newState, session.host.launchMode == .customCommand {
                launchOverlayVisible = false
            }

            if case .connected = newState, !sentAutoTmuxCommand {
                let prologue = HostLaunchPrologue.multilineStdin(
                    envVars: session.host.envVars,
                    startupSnippet: session.host.startupSnippet
                ) ?? ""
                switch session.host.launchMode {
                case .autoTmux, .pinnedTmux:
                    sentAutoTmuxCommand = true
                    // launchOverlayVisible already true (defaults to true on
                    // view appearance and stays up through .connecting). The
                    // existing handler for `tmux.isInitialRenderReady` drops it.
                    tmux.suppressPassthroughOutputUntilControlMode = true
                    noTmuxScanner.reset()
                    let name = resolvedTmuxSessionName
                        ?? HostRuntimeStateStore.sessionName(for: session.host)
                    resolvedTmuxSessionName = name
                    let cmd = prologue + AutoTmuxScript.command(
                        sessionName: name
                    )
                    session.send(Array(cmd.utf8))
                case .customCommand:
                    let raw = session.host.launchCommand ?? ""
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        sentAutoTmuxCommand = true
                        var cmd = prologue + raw
                        if !cmd.hasSuffix("\n") { cmd += "\n" }
                        session.send(Array(cmd.utf8))
                    } else if !prologue.isEmpty {
                        // No launch command, but the user asked for env
                        // exports / a startup snippet — still send the
                        // prologue so it lands on the interactive shell.
                        sentAutoTmuxCommand = true
                        session.send(Array(prologue.utf8))
                    }
                }
            }
        }
    }

    private var sessionDecoratedLifecycle: some View {
        sessionDecoratedConnection
        .onChange(of: tmux.gridAuthority) { _, authority in
            mirrorGridAuthorityInRegistry(authority)
        }
        .onChange(of: isPhone) { _, compact in
            tmux.setGridAuthorityUsesCompactSinglePaneGrid(compact)
        }
        .onChange(of: isActive) { _, nowActive in
            swipePadSessionIsActive = nowActive
            if nowActive { updateSwipePadAgentFocus() }
            if !nowActive {
                agentScrollNotice.dismiss()
                terminalBox.dismissTransientInteractions()
                filesPanel.close()
            } else {
                reconcileAgentScrollNotice()
            }
            // When this session becomes the selected tab, replay the last known
            // terminal size so the remote gets an accurate SIGWINCH. The size
            // may have changed while we were hidden (sidebar toggle, rotation).
            if nowActive {
                if isPhone, let viewport = lastCompactViewportSize {
                    pushCompactInlineViewport(viewport, force: true)
                } else if let size = lastTerminalSize {
                    session.resize(cols: size.cols, rows: size.rows)
                    tmux.updateClientSize(cols: size.cols, rows: size.rows)
                }
            }
            if nowActive {
                if appPhase.isActive {
                    tmux.refreshActiveWindowOnForeground()
                } else {
                    tmux.prepareForAppInactivity()
                }
            }
            // Returning to a session whose open panel lost its bridge
            // (idle teardown or drop while backgrounded): reconnect and
            // refresh the listing — the panel being open is standing
            // user intent, not a new connection decision.
            if nowActive, filesPanel.isOpen,
               let bridge = filesPanel.bridge,
               bridge.state != .connected, bridge.state != .connecting {
                filesPanel.open()
            }
        }
        .task(id: sshCwdPollKey) {
            await runSSHCwdPoll()
        }
        .onChange(of: session.pendingPathInjection) { _, path in
            consumePendingPathInjection(path)
        }
        .onChange(of: appPhase.isActive) { _, nowForeground in
            // App background→foreground is a SEPARATE signal from `isActive`
            // (which is just "selected tab"). SwiftUI's `\.scenePhase` doesn't
            // reliably reach this nested view, but `AppPhase.isActive` — set
            // from the app-root scenePhase observer — does. On resume nothing
            // else re-renders the visible window, so stale content left on the
            // shared terminal (the cross-window gray-box bleed) persists until
            // the user interacts. Replay the size, then force a fresh
            // capture-repaint that clears (ED 2) and repaints from tmux's grid;
            // the viewport retry/backoff rides out the empty-metadata window
            // while the control channel recovers. Close the output gate at the
            // inactive edge too: SSH can resume and deliver queued TUI redraws
            // during the inactive→active transition, before this capture starts.
            guard isActive else { return }
            guard nowForeground else {
                terminalBox.dismissTransientInteractions()
                tmux.prepareForAppInactivity()
                return
            }
            if isPhone, let viewport = lastCompactViewportSize {
                pushCompactInlineViewport(viewport, force: true)
            } else if let size = lastTerminalSize {
                session.resize(cols: size.cols, rows: size.rows)
                tmux.updateClientSize(cols: size.cols, rows: size.rows)
            }
            tmux.refreshActiveWindowOnForeground()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tesseraForceRefreshTerminal)) { _ in
            forceRefreshTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            terminalBox.dismissTransientInteractionsIfInterfaceOrientationChanged()
        }
        .onChange(of: tmux.mode) { _, newMode in
            recordScrollDiagnostic(
                "tmux-mode-changed mode=\(newMode) position=\(describeScrollPosition(for: terminalBox.view))"
            )
            // Control mode can finish attaching after the app has already
            // become inactive. Re-arm the controller here as well as on the
            // app-phase edge so its first `%output` cannot race the foreground
            // viewport repair.
            if case .tmuxControl = newMode, !appPhase.isActive {
                tmux.prepareForAppInactivity()
            }
            if case .tmuxControl = newMode,
               isPhone,
               isActive,
               appPhase.isActive,
               let viewport = lastCompactViewportSize {
                pushCompactInlineViewport(viewport, force: true)
            }
            // Successful control mode supersedes a prior "tmux unavailable"
            // discovery. Auto mode also remembers the resolved rendezvous name.
            if case .tmuxControl = newMode {
                if session.host.launchMode == .autoTmux,
                   let name = resolvedTmuxSessionName {
                    HostRuntimeStateStore.recordSessionUsed(name, for: session.host)
                } else {
                    HostRuntimeStateStore.recordTmuxAvailable(for: session.host)
                }
            }
        }
        .onChange(of: tmux.isInitialRenderReady) { _, isReady in
            recordScrollDiagnostic(
                "tmux-initial-render-ready ready=\(isReady) position=\(describeScrollPosition(for: terminalBox.view))"
            )
            if isReady {
                launchOverlayVisible = false
                noTmuxScanner.reset()
            }
        }
        .onChange(of: scrollDiagnosticsEnabled) { _, enabled in
            if enabled {
                recordScrollDiagnostic(
                    "scroll-diagnostics-enabled position=\(describeScrollPosition(for: terminalBox.view))"
                )
            }
        }
        .onChange(of: launchOverlayVisible) { _, visible in
            // The sidebar row can't observe this view's local overlay
            // state, so mirror "launch complete" into the shared registry
            // the moment the shield drops. Until then the row holds itself
            // in the connecting state (amber, pulsing) even though the
            // transport already reports `.connected`. Stays false for the
            // session's lifetime (the overlay never re-shows in place).
            if !visible {
                sessionRegistry.markRenderReady(liveSessionID)
            }
        }
        .onChange(of: compactTmuxSizingKey) { _, _ in
            guard isPhone,
                  isActive,
                  appPhase.isActive,
                  let viewport = lastCompactViewportSize,
                  CompactTmuxClientSizing.shouldReprojectLayout(
                    viewport: viewport,
                    lastClientSize: lastCompactClientSize,
                    windowRect: compactTmuxWindowRect,
                    focusRect: compactTmuxFocusRect
                  )
            else { return }
            pushCompactInlineViewport(viewport)
        }
        .onChange(of: tmux.activePaneId) { _, newPaneId in
            updateSwipePadAgentFocus()
            reconcileAgentScrollNotice()
            // Magic-puck pane-awareness. The SwipePad resolver scopes its
            // `pane_current_command`/`pane_pid` query to `tmux.activePaneId`,
            // but it only re-runs on terminal output or the 1–5 s background
            // poll. A pane focus change (⌘[/⌘], tap-to-focus, or a `select-pane`
            // echo) can carry no new output, so without this the puck keeps
            // showing the previously-focused pane's process-adaptive shortcuts.
            // Bump the activity token directly (not the debounced output
            // refresh) so the re-poll fires immediately even during the output
            // cooldown window. `activePaneId` is already the new pane when this
            // fires, so the next resolver query is correctly scoped.
            //
            // Only re-poll when focus lands on a REAL pane. `activePaneId` also
            // transitions to nil on teardown / reset / a window invalidated
            // mid-hydration; bumping there fires a wasted client-scoped query
            // (or a send against a torn-down channel) and can burst during the
            // nil↔value reconnect dance — there is no pane to scope to, so skip.
            guard swipePadSessionIsActive, newPaneId != nil else { return }
            swipePadOutputActivityToken &+= 1
            SwipePadDiagnostics.log(
                "output-activity session=ssh reason='pane-focus' token=\(swipePadOutputActivityToken)"
            )
        }
        .onChange(of: agentCenter.activityRevision) { _, _ in
            reconcileAgentScrollNotice()
        }
    }

    var body: some View {
        sessionDecoratedLifecycle
    }

    /// Dispatch a tmux keyboard shortcut to a control command. Shared by the
    /// single-pane terminal and every pane surface in the grid (so chords work
    /// whichever pane is focused). Silent no-op in passthrough mode (the
    /// controller gates internally).
    private func handleTmuxShortcut(_ shortcut: TesseraTmuxShortcut) {
        appLockController.notifyUserActivity()
        switch shortcut {
        case .newWindow:
            tmux.newWindow()
        case .killCurrentWindow:
            // Contextual: kill the focused PANE when the window is split,
            // else kill the whole window (the shipped ⌘⇧W behavior).
            if (activeWindow?.paneCount ?? 1) > 1 {
                tmux.killActivePane()
            } else {
                tmux.killCurrentWindow()
            }
        case .previousWindow:
            tmux.previousWindow()
        case .nextWindow:
            tmux.nextWindow()
        case .selectWindow(let position):
            tmux.selectWindow(atPosition: position)
        case .splitPaneHorizontal:
            tmux.splitActivePane(.horizontal)
        case .splitPaneVertical:
            tmux.splitActivePane(.vertical)
        case .cyclePaneNext:
            tmux.cyclePane(forward: true)
        case .cyclePanePrevious:
            tmux.cyclePane(forward: false)
        case .zoomPane:
            tmux.togglePaneZoom()
        }
    }

    /// Show a transient toast for a failed pane operation (tmux `%error`,
    /// e.g. "create pane failed: pane too small"). Auto-dismisses after 2.5 s.
    private func showPaneCommandError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paneCommandToastTask?.cancel()
        paneCommandToast = trimmed
        paneCommandToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            paneCommandToast = nil
            paneCommandToastTask = nil
        }
    }

    /// Translate the SwiftTerm container's switcher-shortcut events into
    /// palette and MRU-cycle controller calls. The actual selection
    /// change goes back to `ContentView` via `onSelectSession`.
    private func handleSwitcherShortcut(_ shortcut: TesseraSwitcherShortcut) {
        switch shortcut {
        case .openPalette:
            commandPalette.open(
                sessions: sessionRegistry.activeSessions,
                lastTouched: sessionRegistry.lastTouched
            )
        case .cyclePrevious, .cycleNext:
            // Immediate switch to the neighbouring session in sidebar
            // order, wrapping at both ends. No HUD or settle timer — the
            // terminal content changing is the feedback, and this reuses
            // the same `onSelectSession` path the palette commits through.
            let direction: SessionSwitchDirection =
                shortcut == .cyclePrevious ? .previous : .next
            if let target = SessionSwitcher.step(
                order: sessionRegistry.activeSessions.map(\.id),
                from: liveSessionID,
                direction: direction
            ) {
                onSelectSession(target)
            }
        }
    }

    private var activeAgentScrollPaneID: Int? {
        tmux.mode == .tmuxControl ? tmux.activePaneId?.rawValue : nil
    }

    private func agentScrollPrevention(paneID: Int?) -> AgentScrollPrevention? {
        agentCenter.scrollPrevention(sessionID: liveSessionID, paneID: paneID)
    }

    private func presentAgentScrollPrevention(paneID: Int?) {
        guard isActive, let prevention = agentScrollPrevention(paneID: paneID) else {
            return
        }
        appLockController.notifyUserActivity()
        agentScrollNotice.show(prevention)
        let paneLabel = paneID.map(String.init) ?? "raw"
        let provider = prevention.agentName == "Codex" ? "codex" : "claude"
        DiagnosticLogStore.appendAgentCenter(
            "scroll-blocked sid=\(String(liveSessionID.uuidString.prefix(8))) pane=\(paneLabel) provider=\(provider)"
        )
    }

    private func reconcileAgentScrollNotice() {
        guard let shown = agentScrollNotice.prevention else { return }
        let current = agentScrollPrevention(paneID: shown.agentID.paneID)
        if current != shown || !isActive || !agentScrollSurfaceIsVisible(shown.agentID) {
            agentScrollNotice.dismiss()
        }
    }

    private func agentScrollSurfaceIsVisible(_ id: AgentInstanceID) -> Bool {
        guard id.sessionID == liveSessionID else { return false }
        guard tmux.mode == .tmuxControl else { return id.paneID == nil }
        if let window = activeGridWindow {
            return window.panes.contains { $0.id.rawValue == id.paneID }
        }
        return id.paneID == tmux.activePaneId?.rawValue
    }

    /// Report the terminal surface the user is looking at to Agent Center's
    /// SwipePad projection: the focused tmux pane, or a nil pane for a raw
    /// screen. Equality-gated on the other side, so calling on every focus
    /// signal is free.
    private func updateSwipePadAgentFocus() {
        if tmux.mode == .tmuxControl {
            if let paneID = tmux.activePaneId {
                agentCenter.setSwipePadFocus(sessionID: liveSessionID, paneID: paneID.rawValue)
            } else {
                // No active pane (window teardown / mid-hydration): clear
                // rather than keep the departed pane's focus — a stale
                // fireable snapshot could route a macro into whatever pane
                // tmux has foreground, and mosh sends have no pane guard.
                agentCenter.clearSwipePadFocus(sessionID: liveSessionID)
            }
        } else {
            agentCenter.setSwipePadFocus(sessionID: liveSessionID, paneID: nil)
        }
    }

    private func scheduleSwipePadOutputActivityRefresh(reason: String) {
        guard swipePadSessionIsActive else { return }
        guard swipePadOutputActivityTask == nil else { return }

        swipePadOutputActivityTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            swipePadOutputActivityToken &+= 1
            SwipePadDiagnostics.log(
                "output-activity session=ssh reason='\(reason)' token=\(swipePadOutputActivityToken)"
            )

            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            swipePadOutputActivityTask = nil
        }
    }

    private var shouldRecordScrollDiagnostics: Bool {
        scrollDiagnosticsEnabled || DiagnosticLogStore.isScrollDiagnosticsEnabled
    }

    private func recordScrollDiagnostic(_ message: String) {
        guard shouldRecordScrollDiagnostics else { return }
        scrollDiagnostics.sequence += 1
        let context = [
            "ssh",
            "seq=\(scrollDiagnostics.sequence)",
            "mode=\(tmux.mode)",
            "window=\(tmux.activeWindowId?.description ?? "nil")",
            "pane=\(tmux.activePaneId?.description ?? "nil")",
            "grid=\(activeGridWindow?.id.description ?? "nil")",
        ].joined(separator: " ")
        let line = "\(context) \(message)"
        DiagnosticLogStore.appendScroll(line)
    }

    private func terminalScrollPosition(for view: TerminalView?) -> TerminalScrollPosition? {
        guard let view else { return nil }
        let terminal = view.getTerminal()
        return TerminalScrollPosition(
            offsetY: view.contentOffset.y,
            maxOffsetY: max(0, view.contentSize.height - view.bounds.height),
            contentHeight: view.contentSize.height,
            boundsHeight: view.bounds.height,
            isAltScreen: terminal.isCurrentBufferAlternate,
            mouseMode: String(describing: terminal.mouseMode)
        )
    }

    private func describeScrollPosition(for view: TerminalView?) -> String {
        describeScrollPosition(terminalScrollPosition(for: view))
    }

    private func describeScrollPosition(_ position: TerminalScrollPosition?) -> String {
        guard let position else { return "nil" }
        return "off=\(Self.format(position.offsetY))/\(Self.format(position.maxOffsetY)) content=\(Self.format(position.contentHeight)) bounds=\(Self.format(position.boundsHeight)) bottom=\(position.isAtBottom) alt=\(position.isAltScreen) mouse=\(position.mouseMode)"
    }

    private func shouldLogTerminalFeedScroll(
        before: TerminalScrollPosition?,
        after: TerminalScrollPosition?
    ) -> Bool {
        guard let after else { return false }
        guard let before else { return !after.isAtBottom }
        return !before.isAtBottom
            || !after.isAtBottom
            || abs(before.offsetY - after.offsetY) > 0.5
            || abs(before.maxOffsetY - after.maxOffsetY) > 0.5
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    /// Inset needed to keep terminal glyphs clear of the physical
    /// display corner radius. Uses the private `_displayCornerRadius`
    /// KVC key when available (stable across iOS versions); falls back
    /// to 24pt which covers current iPad Pro / iPad Air / iPad mini
    /// corner sizes.
    static let cornerInset: CGFloat = {
        if let value = UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat,
           value > 0 {
            return value
        }
        return 24
    }()

}

private struct TerminalScrollPosition {
    let offsetY: CGFloat
    let maxOffsetY: CGFloat
    let contentHeight: CGFloat
    let boundsHeight: CGFloat
    let isAltScreen: Bool
    let mouseMode: String

    var isAtBottom: Bool {
        maxOffsetY - offsetY <= 1.0
    }
}

/// Renders the current tmux cell grid inside a compact local viewport while a
/// resize is in flight. `focusRect` may be one pane within the full window; the
/// pane is cropped and fitted to the phone until tmux reports the new grid.
private struct GeometryNeutralTmuxCanvasModifier: ViewModifier {
    let windowRect: CellRect?
    let focusRect: CellRect?
    let cellSize: CGSize
    var onViewportSize: ((CGSize) -> Void)? = nil

    @ViewBuilder
    func body(content: Content) -> some View {
        if let windowRect,
           let focusRect,
           windowRect.width > 0,
           windowRect.height > 0,
           focusRect.width > 0,
           focusRect.height > 0,
           cellSize.width > 0,
           cellSize.height > 0 {
            GeometryReader { geo in
                let fullSize = CGSize(
                    width: CGFloat(windowRect.width) * cellSize.width,
                    height: CGFloat(windowRect.height) * cellSize.height
                )
                let focusSize = CGSize(
                    width: CGFloat(focusRect.width) * cellSize.width,
                    height: CGFloat(focusRect.height) * cellSize.height
                )
                let scale = min(
                    geo.size.width / focusSize.width,
                    geo.size.height / focusSize.height
                )
                let focusOrigin = CGPoint(
                    x: CGFloat(focusRect.x - windowRect.x) * cellSize.width,
                    y: CGFloat(focusRect.y - windowRect.y) * cellSize.height
                )
                let offset = CGSize(
                    width: (geo.size.width - focusSize.width * scale) / 2
                        - focusOrigin.x * scale,
                    height: (geo.size.height - focusSize.height * scale) / 2
                        - focusOrigin.y * scale
                )

                ZStack(alignment: .topLeading) {
                    content
                        .frame(width: fullSize.width, height: fullSize.height)
                        .scaleEffect(scale, anchor: .topLeading)
                        .offset(offset)
                }
                .frame(
                    width: geo.size.width,
                    height: geo.size.height,
                    alignment: .topLeading
                )
                .clipped()
                .onAppear {
                    onViewportSize?(geo.size)
                }
                .onChange(of: geo.size) { _, newSize in
                    onViewportSize?(newSize)
                }
            }
        } else if let onViewportSize {
            GeometryReader { geo in
                content
                    .frame(
                        width: geo.size.width,
                        height: geo.size.height,
                        alignment: .topLeading
                    )
                    .onAppear {
                        onViewportSize(geo.size)
                    }
                    .onChange(of: geo.size) { _, newSize in
                        onViewportSize(newSize)
                    }
            }
        } else {
            content
        }
    }
}

/// Mosh transport variant of `SessionView`.
///
/// The main mosh UDP session owns terminal rendering end-to-end.
/// tmux metadata and control commands travel on a separate SSH exec
/// channel running `tmux -CC attach -t <session>`, which feeds only the
/// `TmuxController`.
struct MoshSessionView: View {
    @StateObject var session: MoshSession
    var liveSessionID: UUID
    var isActive: Bool
    var onToggleSidebar: () -> Void
    var sidebarVisible: Bool
    var onBack: () -> Void
    /// Connection-failed overlay → open the host editor.
    var onEditHost: () -> Void
    /// Connection-failed overlay → reconnect with the same host.
    var onRetry: () -> Void
    var onSessionEnded: () -> Void
    var onSelectSession: (UUID) -> Void
    /// Called when ⌘, fires inside the session. The parent opens the
    /// Settings page (`selectedItem = .settings`).
    var onOpenSettings: () -> Void
    /// Called when ⌘⇧A fires inside SwiftTerm.
    var onOpenAgentCenter: (() -> Void)?

    @State private var terminalBox = TerminalBox(traceLabel: "mosh")
    /// Remote Files panel — same per-session scoping as the SSH view.
    /// The bridge is a plain SSH connection independent of the mosh
    /// transport, shared per-host via FileBridgeRegistry.
    @State private var filesPanel = FilesPanelController()
    @State private var tmux = TmuxController(
        controlPath: .sideChannel,
        clientSizePolicy: .resizeTmux
    )
    @State private var tmuxTerminalQueryResponder = TerminalOSCColorQueryResponder()
    @State private var modifierState = ModifierState()
    @State private var shellIntegration = SwipePadShellIntegrationTracker()
    @State private var swipePadSidecarProbeGate = SwipePadSidecarProbeGate()
    @State private var swipePadOutputActivityToken = 0
    @State private var swipePadOutputActivityTask: Task<Void, Never>?
    @State private var swipePadSessionIsActive = false
    @State private var agentSourceRegistrationID: UUID?
    @State private var tmuxControlBox = TmuxControlChannelBox()
    @State private var tmuxControlTask: Task<Void, Never>?
    @State private var tmuxControlGeneration = 0
    @State private var tmuxSideChannelState: MoshSideChannelState = .idle
    @State private var tmuxShortcutToastVisible = false
    @State private var tmuxShortcutToastTask: Task<Void, Never>?
    @State private var agentScrollNotice = AgentScrollPreventionNoticeController()
    @State private var lastTerminalSize: (cols: Int, rows: Int)?
    @State private var lastCompactViewportSize: (cols: Int, rows: Int)?
    @State private var lastCompactClientSize: (cols: Int, rows: Int)?
    @State private var resolvedTmuxSessionName: String?
    @State private var currentTerminalTitle: String? = nil
    @State private var lastScrollbackWindowId: WindowId?
    @State private var lastMoshPaneChromeSnapshot: MoshPaneChromeSnapshot?
    @State private var moshPaneChromeTopMaskActive = false
    @State private var moshPaneChromeTopMaskGeneration = 0
    @State private var moshPaneChromeCollapseMaskedPaneIds: Set<PaneId> = []
    @State private var moshPaneScrollbackOverlay: MoshPaneScrollbackOverlayRuntime?
    /// Most recently dismissed overlay runtime, kept MOUNTED (opacity 0,
    /// routing-inactive — every guard reads `moshPaneScrollbackOverlay`
    /// only). Creating the overlay's SwiftTerm view costs ~140ms of
    /// main-thread block (Metal pipeline + mount) — measured as the
    /// "first scroll is laggy" hitch, re-paid on every scroll-up after a
    /// return-to-bottom or keystroke dismissal. Parking the runtime here
    /// keeps the view alive so `ensureMoshPaneScrollbackOverlay` can
    /// promote it back for the same pane at zero mount cost.
    @State private var moshDormantScrollbackOverlay: MoshPaneScrollbackOverlayRuntime?
    /// The overlay instance whose first capture has been fed — only then is
    /// the overlay surface mounted. Before that the overlay would render as
    /// an opaque theme-background rectangle over the live pane (a black
    /// flash for the whole capture-pane round trip). `TerminalBox` buffers
    /// the feed until the surface attaches, and the pending-placement hook
    /// (`onReady`) anchors the offset post-mount, so mounting late is safe.
    @State private var moshOverlayContentReadyId: UUID?
    @State private var moshScrollbackDepthByPane: [PaneId: Int] = [:]
    @State private var moshScrollbackInFlight: (paneId: PaneId, depth: Int)?
    /// Monotonic token so a fetch's watchdog only clears the latch it
    /// armed — a stale timer from an already-completed fetch must not
    /// kill a newer same-pane/same-depth fetch early.
    @State private var moshScrollbackFetchToken = 0
    @State private var pendingMoshAltScreenScrollPointsByPane: [PaneId: Double] = [:]
    @State private var moshPaneInteractionProbeInFlight: Set<PaneId> = []
    @State private var pendingMoshInteractionProbeScrollPointsByPane: [PaneId: Double] = [:]
    @State private var moshSplitAltScreenScrollDispatcher =
        Self.makeMoshSplitAltScreenScrollDispatcher()
    @State private var moshScrollbackLoading = false
    /// Debounce for the hot-buffer prefetch: re-arming cancels the wait,
    /// so the fill runs once, ~400ms after the trigger burst quiesces.
    @State private var moshOverlayPrefetchTask: Task<Void, Never>?
    /// Silent in-flight latch for the prefetch capture — deliberately
    /// separate from `moshScrollbackInFlight`/`moshScrollbackLoading` so
    /// the spinner stays off and the gesture path's fetch gating never
    /// sees a background fill as a user-visible fetch.
    @State private var moshOverlayPrefetchInFlight = false
    /// Monotonic token pairing each prefetch with its timeout watchdog,
    /// same pattern as `moshScrollbackFetchToken`.
    @State private var moshOverlayPrefetchToken = 0
    /// Bumped on every content invalidation (typing, pane output). A
    /// prefetch latches the epoch when it sends and drops its reply if
    /// the epoch moved mid-flight — otherwise a capture requested before
    /// the invalidation would mark pre-invalidation bytes as fresh.
    @State private var moshOverlayContentEpoch = 0
    /// Lost-wakeup guard: a trigger that lands while a prefetch is in
    /// flight is deferred here instead of dropped, and re-armed when the
    /// latch releases — otherwise a pane switch during a slow capture
    /// leaves the new pane cold with nothing left to refill it.
    @State private var moshOverlayPrefetchDeferred = false
    /// Written by the shared surface's Coordinator at gesture/glide
    /// boundaries. Plain class on purpose: flipping it must not invalidate
    /// this view — it exists precisely to keep work OFF the gesture.
    @State private var scrollGestureActivity = ScrollGestureActivityBox()
    /// §R4.6 find-in-scrollback. See SessionView for details — same
    /// shape, just bound to the mosh transport's terminal box.
    @State private var findController = FindController()
    @AppStorage(DiagnosticLogStore.scrollDiagnosticsDefaultsKey)
    private var scrollDiagnosticsEnabled = false
    @State private var scrollDiagnostics = ScrollDiagnosticCounters()

    /// Unified launch-loading shield (same visual as SSH side). Defaults
    /// to `true` so the overlay covers `.connecting` (mosh bootstrap +
    /// UDP handshake). Dismissed by `.onChange(of: session.state)` for
    /// `.customCommand` and by the combined tmux-mode / first-output
    /// signal below for `.autoTmux` / `.pinnedTmux`.
    @State private var launchOverlayVisible = true
    @State private var dismissedWSLTailscaleMTUWarning = false

    /// T5 auto-reclaim toast ("iPhone left — control returned here").
    @State private var authorityReturnedToastVisible = false
    @State private var authorityReturnedToastLabel: String?
    @State private var authorityToastDismissTask: Task<Void, Never>?
    /// A side-channel authority claim explicitly requests the full mosh frame
    /// before lifting its veil. Retain the exact layout whose ordinary observer
    /// repaint may be suppressed; a fence that lands after that observer ran
    /// must not make a later, unrelated split/collapse consume a stale Bool.
    @State private var authorityMoshRepaintLayoutToSuppress: WindowLayout?
    /// The forced mosh frame is delivered through the ordinary output stream.
    /// Hold the veil until that exact stream element has finished feeding the
    /// terminal; the controller generation rejects late output from a timed-
    /// out/retried claim.
    @State private var authorityMoshRepaintTarget: (
        outputCount: Int,
        claimGeneration: UInt64
    )?
    @State private var moshConsumedOutputCount = 0
    /// Flipped true on the first non-empty chunk arriving via
    /// `session.outputStream`. Combined with `tmux.mode == .tmuxControl`
    /// to guarantee the terminal we fade in has content (side-channel
    /// control mode sets `isInitialRenderReady` immediately on DCS, so
    /// we can't rely on that alone here).
    @State private var hasReceivedFirstOutput = false

    @Environment(AppearancePreferences.self) private var appearance
    @Environment(AppLockController.self) private var appLockController
    @Environment(BellController.self) private var bellController
    @Environment(TunnelsRegistry.self) private var tunnelsRegistry
    @Environment(SwipePadProfileStore.self) private var swipePadStore
    @Environment(SpeechDictationController.self) private var dictationController
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(AgentCenter.self) private var agentCenter
    @Environment(AppPhase.self) private var appPhase
    @Environment(FileBridgeRegistry.self) private var fileBridges
    @Environment(HostTerminalBackgroundStore.self) private var hostBackgrounds
    @Environment(\.designTokens) private var appDesignTokens
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var activeTheme: TerminalTheme {
        TerminalTheme.find(id: appearance.terminalThemeID)
    }

    private var isPhone: Bool {
        CompactLayout.isPhone(horizontalSizeClass)
    }

    private var filesPanelTokens: DesignTokens {
        isPhone
            ? appDesignTokens
            : activeTheme.chromeTokens(applying: appearance)
    }

    /// Background picture for this session's canvas (host override → global),
    /// nil for the classic solid theme color.
    private var resolvedTerminalBackground: ResolvedTerminalBackground? {
        ResolvedTerminalBackground.resolve(
            hostID: session.host.id,
            appearance: appearance,
            hostStore: hostBackgrounds
        )
    }

    private static let moshScrollbackPageLines = 240
    private static let moshScrollbackTopThreshold: CGFloat = 24
    private static let moshPaneChromeTopMaskDuration: TimeInterval = 0.35
    /// Watchdog for capture-pane fetches. Observed RTT is ~0.9s; a reply
    /// that hasn't arrived in 4s is treated as lost so the in-flight
    /// latch can't permanently block refetches (observed when a side-
    /// channel stream died between fetch send and reply).
    private static let moshScrollbackFetchTimeout: TimeInterval = 4

    private var showsLaunchOverlay: Bool { launchOverlayVisible }

    /// Phase for the launch overlay caption. Mosh paths:
    ///   - `.connecting` while bootstrap SSH / UDP handshake runs.
    ///   - `.attachingTmuxChannel` once UDP is up but the side-channel
    ///     SSH hasn't yet flipped tmux into `.tmuxControl`.
    ///   - `.attachingPane` once tmux is in control mode but mosh
    ///     hasn't streamed pane bytes yet.
    /// `.customCommand` only ever sees `.connecting` (dismisses on
    /// first `.connected`).
    private var launchPhase: SessionLaunchPhase {
        if session.state != .connected { return .connecting }
        switch session.host.launchMode {
        case .customCommand:
            return .connecting
        case .autoTmux, .pinnedTmux:
            if tmux.mode == .tmuxControl { return .attachingPane }
            return .attachingTmuxChannel
        }
    }

    private var launchSubtitle: String? {
        switch session.host.launchMode {
        case .autoTmux, .pinnedTmux: return resolvedTmuxSessionName
        case .customCommand:         return nil
        }
    }

    /// Non-nil when the connect attempt failed; flips the launch overlay
    /// into its error state (the overlay no longer dismisses on `.failed`).
    private var launchFailureReason: String? {
        if case .failed(let reason) = session.state { return reason }
        return nil
    }

    /// ⌘⇧E / top-bar toggle — mosh variant. The bridge is plain SSH to
    /// the same endpoint (mosh's UDP transport can't carry SFTP), with
    /// the same auth flags this session connected with.
    private func toggleFilesPanel() {
        terminalBox.dismissTransientInteractions()
        if filesPanel.isOpen {
            withAnimation(.easeInOut(duration: 0.2)) { filesPanel.close() }
            return
        }
        configureFilesPanelIfNeeded()
        if tmux.mode == .tmuxControl {
            filesPanel.terminalReportedDirectory(tmux.activePaneCurrentPath)
        } else if let dir = terminalBox.view?.getTerminal().hostCurrentDirectory {
            filesPanel.terminalReportedDirectory(dir)
        }
        withAnimation(.easeInOut(duration: 0.2)) { filesPanel.open() }
    }

    private var compactMoshFilesBinding: Binding<Bool> {
        Binding(
            get: { isPhone && filesPanel.isOpen },
            set: { if !$0 { filesPanel.close() } }
        )
    }

    /// Bridge/handler wiring shared by the panel toggle and the §3
    /// selection actions (which may run with the panel closed).
    private func configureFilesPanelIfNeeded() {
        if filesPanel.bridge == nil {
            let bridge = fileBridges.bridge(
                for: session.host,
                requireBiometric: session.requireBiometric,
                isSecureEnclave: session.isSecureEnclave
            )
            filesPanel.attach(bridge: bridge)
            filesPanel.configureFileActions(
                transfers: fileBridges.transferQueue(for: bridge),
                hostFolderName: session.host.name
            )
        }
        // Plain-mosh cwd comes from the bridge poller (below), not from
        // OSC 7 — a stock mosh-server drops OSC 7 server-side before it
        // ever reaches the state sync, so the shell-integration CTA
        // would be a dead end. Offer it only when polling is impossible
        // (no server PID captured from the bootstrap banner).
        if filesPanel.onInstallShellIntegration == nil, session.remoteServerPID == nil {
            let host = session.host
            let requireBiometric = session.requireBiometric
            let isSecureEnclave = session.isSecureEnclave
            filesPanel.onInstallShellIntegration = { [filesPanel] in
                filesPanel.infoMessage = "Installing shell integration…"
                Task { @MainActor in
                    do {
                        let report = try await RemoteShellIntegrationInstaller.install(
                            on: host,
                            requireBiometric: requireBiometric,
                            isSecureEnclave: isSecureEnclave
                        )
                        filesPanel.infoMessage = "Installed (\(report.rcFilesUpdated.joined(separator: ", "))). Takes effect on the next shell login — run exec $SHELL or reconnect."
                    } catch {
                        filesPanel.infoMessage = nil
                        filesPanel.lastError = error.localizedDescription
                    }
                }
            }
        }
        if filesPanel.onSendPathToTerminal == nil {
            // Same routing as this view's consumePendingPathInjection:
            // tmux.sendInput only under -CC (its sendBytes rides the
            // side-channel SSH, nil on plain mosh and backgrounded
            // mosh+tmux); otherwise type via the mosh transport.
            // Overlay guard per the accessory-bar convention — during
            // tmux startup the transport belongs to the -CC bootstrap.
            filesPanel.onSendPathToTerminal = { [weak session, weak tmux] path in
                guard let session, let tmux,
                      session.state == .connected, !showsLaunchOverlay else { return }
                let bytes = Array(FilesPanelController.shellQuoted(path).utf8)
                if tmux.mode == .tmuxControl {
                    tmux.sendInput(bytes)
                } else {
                    session.send(bytes)
                }
            }
        }
    }

    /// §3 selection menu, mosh variant: identical routing — the bridge
    /// is transport-independent, and cwd falls back to the panel's
    /// poller-fed signal inside openTerminalPath.
    private func handleSelectionPathAction(
        _ action: TesseraTerminalSelectionPathAction, text: String
    ) {
        guard session.state == .connected, !showsLaunchOverlay else { return }
        appLockController.notifyUserActivity()
        configureFilesPanelIfNeeded()
        let cwd: String? = tmux.mode == .tmuxControl
            ? tmux.activePaneCurrentPath
            : terminalBox.view?.getTerminal().hostCurrentDirectory
        filesPanel.openTerminalPath(
            text,
            cwd: cwd,
            intent: action == .quickLook ? .quickLook : .reveal
        ) { message in
            terminalDropFailure = message
        }
    }

    /// Failed terminal drops surface here (the drop modifier's toast) —
    /// the panel and its error banner may be CLOSED during a drop.
    @State private var terminalDropFailure: String?

    /// Drop-on-terminal, mosh variant: same temp-upload + quoted-path
    /// injection, routed like consumePendingPathInjection (sendInput
    /// only under -CC; otherwise the mosh transport itself).
    private func handleTerminalDrop(_ providers: [NSItemProvider]) -> Bool {
        guard session.state == .connected,
              !showsLaunchOverlay,
              !tmux.gridAuthority.isPeer
        else { return false }
        let bridge = fileBridges.bridge(
            for: session.host,
            requireBiometric: session.requireBiometric,
            isSecureEnclave: session.isSecureEnclave
        )
        let queue = fileBridges.transferQueue(for: bridge)
        return FilesPanelController.handleTerminalDrop(
            providers,
            queue: queue,
            inject: { [weak session, weak tmux] path in
                guard let session, let tmux,
                      session.state == .connected,
                      !showsLaunchOverlay,
                      !tmux.gridAuthority.isPeer
                else { return }
                let bytes = Array((FilesPanelController.shellQuoted(path) + " ").utf8)
                if tmux.mode == .tmuxControl {
                    tmux.sendInput(bytes)
                } else {
                    session.send(bytes)
                }
            },
            reportFailure: { message in
                terminalDropFailure = message
                DiagnosticLogStore.appendApp("terminal-drop failed: \(message)")
            }
        )
    }

    /// Identity for the cwd-poll task; see RemoteCwdPoller.taskKey.
    private var moshCwdPollKey: String {
        RemoteCwdPoller.taskKey(
            panelOpen: filesPanel.isOpen,
            sessionActive: isActive,
            tmuxAttached: tmux.mode == .tmuxControl,
            serverPID: session.remoteServerPID
        )
    }

    /// Plain-mosh follow: poll the shell's cwd over the bridge — it's
    /// the mosh-server's child and the bootstrap banner gave us the
    /// server PID. No oscSignal probe here: a stock remote mosh-server
    /// drops OSC 7, and `hostCurrentDirectory` can hold a stale value
    /// that rode the tmux control channel, so non-nil wouldn't mean
    /// live. Under tmux the pane subscription owns cwd and this task
    /// idles out via its id.
    private func runMoshCwdPoll() async {
        guard filesPanel.isOpen, isActive, tmux.mode != .tmuxControl,
              let serverPID = session.remoteServerPID else { return }
        await RemoteCwdPoller.run(
            panel: filesPanel,
            discovery: .moshServerChild(serverPID: serverPID)
        )
    }

    /// The bootstrap banner can deliver the PID after the panel was
    /// first opened; the poller takes over then, so drop the install
    /// CTA latched during the no-PID window — it's a dead end against
    /// a stock mosh-server (drops OSC 7).
    private func handleRemoteServerPIDChange(_ pid: Int?) {
        if pid != nil { filesPanel.onInstallShellIntegration = nil }
    }

    /// Upload sheet's "paste path" — mosh variant. Unlike the SSH view,
    /// passthrough must NOT go through tmux.sendInput: this view wires
    /// `sendBytes` to the tmux side-channel SSH, which is nil on plain
    /// mosh (always) and on backgrounded mosh+tmux — the bytes would
    /// silently vanish. Outside control mode, type via the mosh
    /// transport itself (the PTY's tmux forwards to the active pane in
    /// the attached modes).
    private func consumePendingPathInjection(_ path: String?) {
        guard let path else { return }
        session.pendingPathInjection = nil
        guard session.state == .connected else { return }
        let bytes = Array(FilesPanelController.shellQuoted(path).utf8)
        if tmux.mode == .tmuxControl {
            tmux.sendInput(bytes)
        } else {
            session.send(bytes)
        }
    }

    // Body is split in two: the stack + the bulk of its modifiers here,
    // the trailing lifecycle modifiers in `body` — one expression blew
    // past the type-checker's budget (same wall FilesPanelView hit).
    private var moshSessionTopBar: some View {
        AnyView(SessionTopBar(
            state: session.state,
            host: session.host,
            sessionID: liveSessionID,
            sessionIsActive: isActive,
            tmux: tmux,
            tmuxIsDegraded: isTmuxDegraded,
            connectionStatus: .mosh(
                sessionState: session.state,
                transportState: session.transportState,
                tcpControl: moshTcpControlStatus
            ),
            onToggleSidebar: onToggleSidebar,
            sidebarVisible: sidebarVisible,
            onBack: {
                terminalBox.dismissTransientInteractions()
                stopTmuxControlChannel()
                onBack()
            },
            onDisconnect: {
                terminalBox.dismissTransientInteractions()
                session.disconnect()
            },
            findController: findController,
            filesPanelOpen: filesPanel.isOpen,
            onToggleFiles: toggleFilesPanel,
            bellController: bellController,
            forwarderManager: session.portForwarderManager,
            T: activeTheme.chromeTokens(applying: appearance)
        )
        .frame(height: SessionTopBar.reservedHeight(
            pillHeight: appearance.topBarHeight,
            compact: isPhone
        ))
        .zIndex(2))
    }

    private var moshDecoratedLayerStack: some View {
        ZStack(alignment: .top) {
            activeTheme.bg.ignoresSafeArea()

            if let background = resolvedTerminalBackground, !showsLaunchOverlay {
                TerminalBackdrop(background: background, baseColor: activeTheme.bg)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                moshSessionTopBar

                if findController.isOpen {
                    FindBar(
                        controller: findController,
                        horizontalInset: isPhone ? 10 : SessionView.cornerInset,
                        T: activeTheme.chromeTokens(applying: appearance)
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                ZStack {
                    moshTerminalSurface
                    .modifier(GeometryNeutralTmuxCanvasModifier(
                        windowRect: compactMoshWindowRect,
                        focusRect: compactMoshFocusRect,
                        cellSize: compactMoshCellSize,
                        onViewportSize: updateCompactMoshViewport
                    ))
                    .allowsHitTesting(!showsLaunchOverlay)
                    .opacity(showsLaunchOverlay ? 0 : 1)
                    .animation(
                        // Sequential dissolve — overlay fades out first
                        // (0.25 s), then terminal fades in (0.3 s).
                        showsLaunchOverlay
                            ? .linear(duration: 0)
                            : .easeInOut(duration: 0.30).delay(0.25),
                        value: showsLaunchOverlay
                    )

                    if !showsLaunchOverlay,
                       let overlay = moshPaneScrollbackOverlay ?? moshDormantScrollbackOverlay,
                       let frame = moshPaneScrollbackFrame(for: overlay.paneId) {
                        MoshPaneScrollbackOverlay(
                            runtime: overlay,
                            paneFrame: frame.surfaceFrame,
                            terminalBackground: resolvedTerminalBackground,
                            backdropBaseColor: activeTheme.bg,
                            backdropBleed: moshOverlayBackdropBleed,
                            onReady: applyPendingMoshPaneScrollbackOverlayOffset,
                            onTerminalScrolled: handleMoshPaneScrollbackOverlayScrolled,
                            onScrollDiagnostic: { message in
                                recordMoshScrollDiagnostic(message)
                            },
                            agentScrollBlockingActive:
                                agentScrollPrevention(paneID: overlay.paneId.rawValue) != nil,
                            onAgentScrollBlocked: {
                                presentAgentScrollPrevention(paneID: overlay.paneId.rawValue)
                            }
                        )
                        .id(overlay.id)
                        // Invisible until its first capture has been fed: the
                        // surface must MOUNT immediately (feeding a not-yet-
                        // laid-out terminal wraps the capture at the interim
                        // tiny column count, and SwiftTerm doesn't reflow on
                        // resize), but painting it black over the live pane
                        // for the whole capture round trip reads as a black
                        // flash — so it mounts hidden and appears with content.
                        .opacity(overlay.id == moshOverlayContentReadyId ? 1 : 0)
                        // Only a REVEALED overlay may take (scroll-only) hits —
                        // a hidden/parked one must never intercept anything.
                        // Once visible, trackpad pans land on the overlay's own
                        // scroll view and scroll natively; clicks fall through
                        // via the container's scroll-only hitTest.
                        .allowsHitTesting(overlay.id == moshOverlayContentReadyId)
                        .modifier(GeometryNeutralTmuxCanvasModifier(
                            windowRect: compactMoshWindowRect,
                            focusRect: compactMoshFocusRect,
                            cellSize: compactMoshCellSize
                        ))
                    }

                    // Alt-screen pans get a local scroll surface to move from
                    // event 1 (htop scroll feel — see the proxy view's doc).
                    // Mutually exclusive with a revealed scrollback overlay:
                    // an alt-screen pane never reveals one (capture skips
                    // alt-screen), and the proxy unmounts the moment the
                    // cached pane state says primary.
                    if !showsLaunchOverlay,
                       agentScrollPrevention(paneID: activeAgentScrollPaneID) == nil,
                       let proxyTarget = moshAltScreenScrollProxyTarget {
                        MoshAltScreenScrollProxy(onScrollDelta: { delta in
                            handleMoshAltScreenProxyScroll(
                                paneId: proxyTarget.paneId,
                                pointsY: delta
                            )
                        })
                        .frame(
                            width: proxyTarget.frame.width,
                            height: proxyTarget.frame.height
                        )
                        .offset(x: proxyTarget.frame.minX, y: proxyTarget.frame.minY)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .modifier(GeometryNeutralTmuxCanvasModifier(
                            windowRect: compactMoshWindowRect,
                            focusRect: compactMoshFocusRect,
                            cellSize: compactMoshCellSize
                        ))
                    }

                    // Mosh paints split pane contents natively in the shared
                    // terminal, but Tessera owns the pane chrome so SSH and
                    // mosh splits look and tap the same.
                    if !isPhone,
                       !showsLaunchOverlay,
                       let snapshot = moshPaneChromeSnapshot(),
                       let cellSize = moshCellSize {
                        let frames = moshPaneChromeFrames(
                            for: snapshot,
                            cellSize: cellSize
                        )
                        MoshPaneChromeOverlay(
                            root: snapshot.layout.root,
                            frames: frames,
                            titles: moshPaneChromeTitles(
                                for: frames,
                                snapshot: snapshot
                            ),
                            cellSize: cellSize,
                            activePaneId: snapshot.activePaneId,
                            chrome: activeTheme.chromeTokens(applying: appearance),
                            backgroundColor: activeTheme.bg,
                            terminalBackground: resolvedTerminalBackground,
                            backdropBleed: moshOverlayBackdropBleed
                        )
                    }

                    if !isPhone,
                       !showsLaunchOverlay,
                       let cellSize = moshCellSize,
                       shouldShowMoshPaneChromeTopMask
                        || !moshPaneChromeCollapseMaskFrames(cellSize: cellSize).isEmpty {
                        let collapseFrames = moshPaneChromeCollapseMaskFrames(cellSize: cellSize)
                        GeometryReader { geo in
                            let topMaskRects: [CGRect] = shouldShowMoshPaneChromeTopMask
                                ? [CGRect(
                                    x: 0,
                                    y: 0,
                                    width: geo.size.width,
                                    height: ceil(cellSize.height) + 1
                                )]
                                : []
                            moshChromeTransitionMask(rects: topMaskRects + collapseFrames)
                        }
                        .allowsHitTesting(false)
                    }

                    if !showsLaunchOverlay, moshScrollbackLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(activeTheme.chromeTokens(applying: appearance).fgMuted)
                            .padding(8)
                            .background(.black.opacity(0.35), in: Circle())
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }

                    if showsLaunchOverlay {
                        SessionLaunchOverlay(
                            T: activeTheme.chromeTokens(applying: appearance),
                            phase: launchPhase,
                            subtitle: launchSubtitle,
                            wslTailscaleMTUWarning: session.wslTailscaleMTUWarning,
                            failureReason: launchFailureReason,
                            onEditHost: onEditHost,
                            onRetry: onRetry,
                            onBack: onSessionEnded
                        )
                        .transition(.opacity)
                        .zIndex(1)
                    }

                    // Continuity takeover veil: another device holds the grid.
                    // Requires `.connected`, so mosh transport loss falls back
                    // to the existing reconnect presentation.
                    if let peerName = tmux.gridAuthority.peerDisplayName,
                       !showsLaunchOverlay,
                       session.state == .connected {
                        ContinuedElsewhereOverlay(
                            T: activeTheme.chromeTokens(applying: appearance),
                            peerDisplayName: peerName,
                            isReclaiming: tmux.gridAuthorityReclaimInFlight,
                            onTakeBack: takeBackContinuedSession
                        )
                        .transition(.opacity)
                        .zIndex(2)
                    }

                    if authorityReturnedToastVisible {
                        GridAuthorityReturnedToast(
                            T: activeTheme.chromeTokens(applying: appearance),
                            departedPeerLabel: authorityReturnedToastLabel
                        )
                        .transition(.opacity)
                        .zIndex(3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(
                    .easeInOut(duration: 0.35),
                    value: tmux.gridAuthority.isPeer
                )
                .animation(
                    .easeInOut(duration: 0.2),
                    value: authorityReturnedToastVisible
                )
                // Drop a file onto the terminal → upload to the host's
                // temp dir, then type the quoted path (mockup §4).
                .modifier(TerminalFileDropTarget(
                    T: activeTheme.chromeTokens(applying: appearance),
                    failureMessage: $terminalDropFailure,
                    handle: handleTerminalDrop
                ))
                // §3 terminal Quick Look with the panel closed: the
                // panel hosts presentedPreview's sheet only while open,
                // so this fallback presents it otherwise. The binding
                // nils itself while the panel is open — exactly one
                // host at a time by construction.
                .sheet(item: Binding(
                    get: { filesPanel.isOpen ? nil : filesPanel.presentedPreview },
                    set: { filesPanel.presentedPreview = $0 }
                )) { request in
                    QuickLookPresenter(fileURL: request.localURL, displayTitle: request.title)
                        .ignoresSafeArea()
                }
                .sheet(isPresented: compactMoshFilesBinding) {
                    FilesPanelView(
                        controller: filesPanel,
                        T: filesPanelTokens,
                        sessionIsActive: isActive,
                        terminalBackground: nil
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(filesPanelTokens.presentationBg)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                }
                // Remote Files panel floats as an overlay over the
                // terminal — same as the SSH view. No trailing padding,
                // so the terminal keeps full width and toggling never
                // triggers a mosh SSP / tmux refresh-client resize. A
                // transparent tap-catcher behind the card dismisses the
                // panel when the user taps the terminal, like the sidebar.
                .overlay(alignment: .trailing) {
                    if filesPanel.isOpen, !isPhone {
                        ZStack(alignment: .trailing) {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) { filesPanel.close() }
                                }
                            FilesPanelView(
                                controller: filesPanel,
                                T: activeTheme.chromeTokens(applying: appearance),
                                sessionIsActive: isActive,
                                terminalBackground: resolvedTerminalBackground
                            )
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, isPhone ? 4 : SessionView.cornerInset)

                if appearance.showAccessoryBar {
                    SessionAccessoryBar(
                        accent: appearance.tokens(systemColorScheme: .dark).accent,
                        modifierState: modifierState,
                        onSend: { bytes in
                            guard !showsLaunchOverlay, !tmux.gridAuthority.isPeer else { return }
                            appLockController.notifyUserActivity()
                            invalidateMoshScrollbackForTerminalInput(reason: "accessory-input")
                            noteMoshAgentInput(bytes)
                            session.send(bytes)
                        },
                        applicationCursor: { [terminalBox] in
                            terminalBox.view?.getTerminal().applicationCursor ?? false
                        },
                        onPageScrollAttempt: { _ in
                            guard agentScrollPrevention(
                                paneID: activeAgentScrollPaneID
                            ) != nil else { return false }
                            presentAgentScrollPrevention(
                                paneID: activeAgentScrollPaneID
                            )
                            return true
                        }
                    )
                    .allowsHitTesting(!tmux.gridAuthority.isPeer)
                    .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
                }
            }

            if !showsLaunchOverlay,
               !dismissedWSLTailscaleMTUWarning,
               let warning = session.wslTailscaleMTUWarning {
                WSLTailscaleMTUWarningView(
                    warning: warning,
                    T: activeTheme.chromeTokens(applying: appearance),
                    onDismiss: { dismissedWSLTailscaleMTUWarning = true }
                )
                .padding(.top, SessionTopBar.reservedHeight(
                    pillHeight: appearance.topBarHeight,
                    compact: isPhone
                ))
                .padding(.horizontal, SessionView.cornerInset + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(3)
            }

            if tmuxShortcutToastVisible {
                MoshTmuxShortcutBlockedToast()
                    .padding(.top, appearance.topBarHeight + 44)
                    .padding(.leading, SessionView.cornerInset + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                    .zIndex(4)
            }

            if let prevention = agentScrollNotice.prevention {
                AgentScrollPreventionNotice(
                    agentName: prevention.agentName,
                    T: activeTheme.chromeTokens(applying: appearance)
                )
                .padding(.top,
                    SessionTopBar.reservedHeight(
                        pillHeight: appearance.topBarHeight,
                        compact: isPhone
                    ) + (findController.isOpen ? 44 : 8)
                )
                .padding(.horizontal, isPhone ? 12 : SessionView.cornerInset + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(7)
            }

            SwipePadOverlay(
                onSend: { bytes in
                    guard !showsLaunchOverlay, !tmux.gridAuthority.isPeer else { return }
                    appLockController.notifyUserActivity()
                    invalidateMoshScrollbackForTerminalInput(reason: "swipepad-input")
                    noteMoshAgentInput(bytes)
                    session.send(bytes)
                },
                tmux: tmux,
                outputActivityToken: swipePadOutputActivityToken,
                processNameProvider: {
                    if let name = agentCenter.activeLifecycleProcessName(
                        sessionID: liveSessionID,
                        paneID: nil
                    ) {
                        swipePadSidecarProbeGate.reset()
                        SwipePadDiagnostics.log(
                            "provider mosh source=agent-lifecycle candidateCount=1"
                        )
                        return [name]
                    }

                    let names = shellIntegration.processNames
                    if !names.isEmpty {
                        swipePadSidecarProbeGate.reset()
                        SwipePadDiagnostics.log(
                            "provider mosh source=shell-integration candidateCount=\(names.count)"
                        )
                        return names
                    }

                    // Plain mosh's terminal channel can carry neither the
                    // lifecycle OSC nor shell-integration OSC — the mosh
                    // server's emulator consumes unknown OSC sequences
                    // before they reach the client (the fork forwards only
                    // clipboard/cwd/title). Without this side-channel probe
                    // the pad can never match an agent on plain mosh (live
                    // E2E: both providers stuck on the generic puck). Same
                    // FileBridge probe Agent Center's discovery uses,
                    // scoped to the mosh server's process tree.
                    guard let serverPID = session.remoteServerPID else {
                        SwipePadDiagnostics.log(
                            "provider mosh source=ssh-sidecar skipped reason=no-server-pid"
                        )
                        return []
                    }
                    let identity = "\(session.host.id.uuidString):\(serverPID)"
                    return await swipePadSidecarProbeGate.probe(
                        identity: identity
                    ) {
                        let bridge = fileBridges.bridge(
                            for: session.host,
                            requireBiometric: session.requireBiometric,
                            isSecureEnclave: session.isSecureEnclave
                        )
                        do {
                            try await bridge.connect()
                            let output = try await bridge.exec(
                                SwipePadPlainSSHProcessProbe.makeCommand(rootPID: serverPID),
                                inShell: false
                            )
                            let probeNames = SwipePadPlainSSHProcessProbe.processNames(from: output)
                            SwipePadDiagnostics.log(
                                "provider mosh source=ssh-sidecar candidateCount=\(probeNames.count)"
                            )
                            return .success(probeNames)
                        } catch {
                            return .failure(type: String(describing: type(of: error)))
                        }
                    }
                },
                paneProcessNameProvider: { paneID, panePID in
                    if let name = agentCenter.activeLifecycleProcessName(
                        sessionID: liveSessionID,
                        paneID: paneID?.rawValue
                    ) {
                        SwipePadDiagnostics.log(
                            "provider mosh source=agent-lifecycle panePID=\(panePID) candidateCount=1"
                        )
                        return [name]
                    }

                    guard let channel = tmuxControlBox.channel else {
                        SwipePadDiagnostics.log(
                            "provider mosh source=tmux-pane-ps skipped reason=no-channel panePID=\(panePID)"
                        )
                        return []
                    }
                    let names = await channel.detectForegroundProcessNames(rootPID: panePID)
                    SwipePadDiagnostics.log(
                        "provider mosh source=tmux-pane-ps panePID=\(panePID) candidateCount=\(names.count)"
                    )
                    return names
                },
                agentContext: agentCenter.swipePadContext(sessionID: liveSessionID),
                sessionIsActive: swipePadSessionIsActive,
                onShowMore: onOpenAgentCenter,
                profileStore: swipePadStore,
                dictationController: dictationController
            )
            .padding(.top, SessionTopBar.reservedHeight(
                pillHeight: appearance.topBarHeight,
                compact: isPhone
            ))
            .padding(.horizontal, isPhone ? 10 : SessionView.cornerInset)
            .padding(.bottom, appearance.showAccessoryBar ? 52 : max(SessionView.cornerInset - 8, 4))
            .allowsHitTesting(!tmux.gridAuthority.isPeer)
            .zIndex(tmux.gridAuthority.isPeer ? -1 : 5)
        }
    }

    private var moshDecoratedChrome: some View {
        moshDecoratedLayerStack
        .animation(.easeInOut(duration: 0.2), value: tmuxSideChannelState)
        .animation(.easeInOut(duration: 0.15), value: tmuxShortcutToastVisible)
        .animation(.easeInOut(duration: 0.18), value: agentScrollNotice.prevention)
        .animation(.easeInOut(duration: 0.25), value: showsLaunchOverlay)
        .onChange(of: tmux.activePaneCurrentPath) { _, path in
            // tmux modes: the pane-metadata subscription pushes the active
            // pane's cwd (updates on cd AND on pane/window focus change).
            guard tmux.mode == .tmuxControl else { return }
            filesPanel.terminalReportedDirectory(path)
        }
        .onChange(of: tmux.mode) { _, newMode in
            agentCenter.requestRefresh(sessionID: liveSessionID)
            updateSwipePadAgentFocus()
            // tmux detached/exited (reset() flips mode before the pane
            // paths clear, so the watcher above never delivers nil).
            // Fall back to OSC 7 when the shell reports it; nil flips
            // the panel to its no-signal state instead of leaving the
            // last tmux pane path stuck as "following".
            guard newMode == .passthrough else { return }
            // Backgrounding also lands here (the side channel is torn
            // down for non-selected tabs) — that's a channel-lifecycle
            // artifact, not a cwd-signal change; reporting nil would
            // wipe session.remoteWorkingDirectory and the Upload sheet
            // would claim "no session cwd" for a live background host.
            guard isActive else { return }
            filesPanel.terminalReportedDirectory(
                terminalBox.view?.getTerminal().hostCurrentDirectory
            )
        }
        .onChange(of: sessionRegistry.tmuxFocusRequest?.token) { _, _ in
            handleCompactTmuxFocusRequest()
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .statusBarHidden(true)
        .persistentSystemOverlays(isPhone ? .automatic : .hidden)
        .onAppear {
            swipePadSessionIsActive = isActive
            updateSwipePadAgentFocus()
            tunnelsRegistry.register(host: session.host.id, manager: session.portForwarderManager)
        }
        .onDisappear {
            terminalBox.dismissTransientInteractions()
            tunnelsRegistry.unregister(host: session.host.id, manager: session.portForwarderManager)
            if let agentSourceRegistrationID {
                agentCenter.unregister(
                    sessionID: liveSessionID,
                    registrationID: agentSourceRegistrationID
                )
                self.agentSourceRegistrationID = nil
            }
            swipePadOutputActivityTask?.cancel()
            swipePadOutputActivityTask = nil
        }
    }

    private var moshDecoratedConnectionTask: some View {
        moshDecoratedChrome
        .task {
            MoshDiagnostics.log(
                "mosh view task start transport=\(session.host.transport.rawValue) launchMode=\(session.host.launchMode.rawValue) port=\(session.host.port)"
            )
            // Mirror every cwd report onto the session object so
            // transport-agnostic consumers (Upload sheet) can read it.
            filesPanel.onTerminalDirectoryChanged = { [weak session] dir in
                // Change-guarded: the poller re-reports the same path
                // every tick and the mirror is @Published now.
                if session?.remoteWorkingDirectory != dir {
                    session?.remoteWorkingDirectory = dir
                }
            }
            tmux.sendBytes = { [tmuxControlBox] bytes in
                tmuxControlBox.channel?.send(bytes)
            }
            tmux.onServerGeometryCeded = { [weak session] cols, rows in
                session?.preserveRemoteTmuxSizeAfterCede(cols: cols, rows: rows)
            }
            tmux.gridAuthorityIdentity = GridAuthorityDeviceIdentity.current()
            tmux.setGridAuthorityUsesCompactSinglePaneGrid(isPhone)
            mirrorGridAuthorityInRegistry(tmux.gridAuthority)
            tmux.onGridAuthorityAutoReclaimed = { peerName in
                presentAuthorityReturnedToast(departedPeerName: peerName)
            }
            tmux.onGridAuthoritySideChannelRepaintRequired = {
                geometryChanged,
                claimGeneration in
                authorityMoshRepaintLayoutToSuppress = geometryChanged
                    ? moshRenderLayout
                    : nil
                let acknowledgesYieldedClaim = tmux.gridAuthority.isPeer
                session.forceFullRepaint { outputCount in
                    guard acknowledgesYieldedClaim,
                          let outputCount
                    else { return }
                    authorityMoshRepaintTarget = (
                        outputCount,
                        claimGeneration
                    )
                    completeAuthorityMoshRepaintIfReady()
                }
            }
            tmux.terminalResponseForOutput = { [tmuxTerminalQueryResponder, appearance] paneId, slice in
                let theme = TerminalTheme.find(id: appearance.terminalThemeID)
                let responses = tmuxTerminalQueryResponder.responses(
                    for: slice,
                    streamID: paneId.description,
                    defaultForegroundRGB: theme.fgRGB,
                    defaultBackgroundRGB: theme.bgRGB
                )
                return responses.isEmpty ? nil : responses
            }
            tmux.onBell = { windowID, isActiveWindow, windowName in
                guard !isActiveWindow else { return }
                let bc = bellController
                let sid = session.host.id
                let hname = session.host.name
                Task { @MainActor in
                    bc.ring(
                        source: .tmuxWindow(sessionID: sid, windowID: windowID),
                        isOriginOnScreen: false,
                        hostDisplayName: hname,
                        paneTitle: windowName
                    )
                }
            }
            tmux.paneDidOutput = { paneId in
                if paneId == tmux.activePaneId {
                    // Revealed scrollback stays (frozen); otherwise this
                    // marks the parked runtime stale and re-arms the
                    // debounced prefetch, so the hot buffer refills
                    // ~400ms after the output quiesces.
                    invalidateMoshScrollbackForActivePaneOutput()
                } else if let dormant = moshDormantScrollbackOverlay,
                          dormant.paneId == paneId {
                    // Background output into the parked pane: its capture
                    // no longer matches. No prefetch re-arm — prefetch
                    // targets the ACTIVE pane; if focus returns here, the
                    // pane-change trigger refills.
                    moshOverlayContentEpoch += 1
                    dormant.isFresh = false
                }
            }
            findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)

            if resolvedTmuxSessionName == nil {
                resolvedTmuxSessionName = MoshBootstrap.resolvedTmuxSessionName(
                    for: session.host
                )
            }

            agentCenter.syncProfiles(swipePadStore.profiles)
            let agentSource = AgentSessionSourceFactory.make(
                sessionID: liveSessionID,
                hostName: session.host.name.isEmpty ? session.host.address : session.host.name,
                baseTransportLabel: "mosh",
                tmux: tmux,
                terminalBox: terminalBox,
                tmuxSessionName: { resolvedTmuxSessionName },
                profiles: { swipePadStore.profiles },
                rawProcessProvider: {
                    guard let serverPID = session.remoteServerPID else { return nil }
                    let bridge = fileBridges.bridge(
                        for: session.host,
                        requireBiometric: session.requireBiometric,
                        isSecureEnclave: session.isSecureEnclave
                    )
                    do {
                        try await bridge.connect()
                        let output = try await bridge.exec(
                            SwipePadPlainSSHProcessProbe.makeCommand(rootPID: serverPID),
                            inShell: false
                        )
                        return SwipePadPlainSSHProcessProbe.snapshot(from: output)
                    } catch {
                        return nil
                    }
                },
                paneProcessProvider: { panePID in
                    guard let channel = tmuxControlBox.channel else { return nil }
                    return await channel.detectForegroundProcessSnapshotIfAvailable(rootPID: panePID)
                },
                lifecycleIntegrationCacheKey: session.host.sshConnectionRouteIdentity,
                automaticallyProbeLifecycleIntegration: false,
                probeLifecycleIntegration: {
                    if let channel = tmuxControlBox.channel {
                        return try await RemoteAgentLifecycleIntegrationInstaller.probe(
                            execute: {
                                try await channel.executeConnectedCommand($0)
                            },
                            diagnostic: { detail in
                                DiagnosticLogStore.appendAgentCenter(
                                    "host-diagnostic sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh-tmux \(detail)"
                                )
                            }
                        )
                    }
                    let bridge = fileBridges.bridge(
                        for: session.host,
                        requireBiometric: session.requireBiometric,
                        isSecureEnclave: session.isSecureEnclave
                    )
                    return try await RemoteAgentLifecycleIntegrationInstaller.probe(
                        using: bridge,
                        diagnostic: { detail in
                            DiagnosticLogStore.appendAgentCenter(
                                "host-diagnostic sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh \(detail)"
                            )
                        }
                    )
                },
                installLifecycleIntegration: {
                    if let channel = tmuxControlBox.channel {
                        return try await RemoteAgentLifecycleIntegrationInstaller.install {
                            try await channel.executeConnectedCommand($0)
                        }
                    }
                    let bridge = fileBridges.bridge(
                        for: session.host,
                        requireBiometric: session.requireBiometric,
                        isSecureEnclave: session.isSecureEnclave
                    )
                    try await RemoteAgentLifecycleIntegrationInstaller.install(using: bridge)
                },
                automaticallyInspectCurrentIntegration: {
                    tmux.mode == .tmuxControl && tmuxControlBox.channel != nil
                },
                probeShellIntegration: { processIDs, allowInheritedEnvironment in
                    let command = RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                        processIDs: processIDs,
                        allowInheritedEnvironment: allowInheritedEnvironment
                    )
                    if tmux.mode == .tmuxControl {
                        guard let channel = tmuxControlBox.channel else {
                            DiagnosticLogStore.appendAgentCenter(
                                "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh-tmux processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=side-channel-missing"
                            )
                            return nil
                        }
                        do {
                            let output = try await channel.executeConnectedCommand(command)
                            let parsed = RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(
                                output
                            )
                            let shellDiagnostic = RemoteAgentLifecycleIntegrationInstaller
                                .parseShellDiagnostic(output)?
                                .replacingOccurrences(of: " ", with: ",") ?? "missing"
                            DiagnosticLogStore.appendAgentCenter(
                                "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh-tmux processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=\(parsed.map(String.init) ?? "invalid-output") diagnostic=\(shellDiagnostic)"
                            )
                            return parsed
                        } catch {
                            DiagnosticLogStore.appendAgentCenter(
                                "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh-tmux processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=transport-failed failureType=\(String(describing: type(of: error)))"
                            )
                            return nil
                        }
                    }
                    let bridge = fileBridges.bridge(
                        for: session.host,
                        requireBiometric: session.requireBiometric,
                        isSecureEnclave: session.isSecureEnclave
                    )
                    do {
                        try await bridge.connect()
                        let output = try await bridge.exec(command, inShell: true)
                        let parsed = RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(output)
                        let shellDiagnostic = RemoteAgentLifecycleIntegrationInstaller
                            .parseShellDiagnostic(output)?
                            .replacingOccurrences(of: " ", with: ",") ?? "missing"
                        DiagnosticLogStore.appendAgentCenter(
                            "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh-ssh-sidecar processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=\(parsed.map(String.init) ?? "invalid-output") diagnostic=\(shellDiagnostic)"
                        )
                        return parsed
                    } catch {
                        DiagnosticLogStore.appendAgentCenter(
                            "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh-ssh-sidecar processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=transport-failed failureType=\(String(describing: type(of: error)))"
                        )
                        return nil
                    }
                },
                rawSend: { bytes in session.send(bytes) }
            )
            agentSourceRegistrationID = agentSource.registrationID
            agentCenter.register(agentSource)
            let sourceRegistrationID = agentSource.registrationID
            tmux.paneOutputObserver = { paneID, data in
                agentCenter.noteOutput(
                    sessionID: liveSessionID,
                    paneID: paneID.rawValue,
                    registrationID: sourceRegistrationID,
                    data: data
                )
            }
            tmux.paneAgentStateObserver = { paneID, json in
                agentCenter.noteLifecyclePayload(
                    sessionID: liveSessionID,
                    paneID: paneID.rawValue,
                    registrationID: sourceRegistrationID,
                    json: json
                )
            }
            tmux.inputObserver = { paneID, bytes in
                agentCenter.noteInput(
                    sessionID: liveSessionID,
                    paneID: paneID?.rawValue,
                    registrationID: sourceRegistrationID,
                    bytes: bytes
                )
            }

            var outputChunkCount = 0
            session.connect()
            for await chunk in session.outputStream {
                outputChunkCount += 1
                if outputChunkCount <= 12 || outputChunkCount == 25 || outputChunkCount == 50 {
                    MoshDiagnostics.log(
                        "mosh view output chunk#\(outputChunkCount) bytes=\(chunk.count)"
                    )
                }
                let before = terminalScrollPosition(for: terminalBox.view)
                let ingressStartedAt = terminalBox.performanceDiagnostics.beginIngress(
                    byteCount: chunk.count
                )
                await terminalBox.feedTerminalOutputCooperatively(
                    chunk[...],
                    context: .moshLive(originalByteCount: chunk.count),
                    shellIntegration: shellIntegration
                )
                moshConsumedOutputCount += 1
                completeAuthorityMoshRepaintIfReady()
                if tmux.mode == .passthrough, !chunk.isEmpty {
                    agentCenter.noteOutput(
                        sessionID: liveSessionID,
                        paneID: nil,
                        registrationID: sourceRegistrationID,
                        data: chunk[...]
                    )
                }
                if shouldRecordScrollDiagnostics,
                   let view = terminalBox.view,
                   shouldLogTerminalFeedScroll(before: before, after: terminalScrollPosition(for: view)) {
                    recordMoshScrollDiagnostic(
                        "surface=shared terminal-feed bytes=\(chunk.count) before=\(describeScrollPosition(before)) after=\(describeScrollPosition(for: view))"
                    )
                }
                scheduleSwipePadOutputActivityRefresh(reason: "mosh-output")
                if let ingressStartedAt {
                    terminalBox.performanceDiagnostics.endIngress(startedAt: ingressStartedAt)
                }

                // First non-empty chunk → the terminal has content to
                // show. Combined with `tmux.mode == .tmuxControl` (in
                // the tmux dismissal branch below) this guarantees the
                // surface we fade in is non-blank.
                if !chunk.isEmpty && !hasReceivedFirstOutput {
                    hasReceivedFirstOutput = true
                    maybeDismissLaunchOverlay(reason: "first-output")
                }
            }
            MoshDiagnostics.log("mosh view output stream ended")
        }
        .onChange(of: session.state) { _, newState in
            MoshDiagnostics.log(
                "mosh view state=\(MoshDiagnostics.stateDescription(newState))"
            )
            if newState == .disconnected {
                launchOverlayVisible = false
                stopTmuxControlChannel()
                onSessionEnded()
            }

            if case .failed = newState {
                // Keep the overlay up to host the error state + recovery
                // actions (edit host / retry / back).
                stopTmuxControlChannel()
            }

            if case .connected = newState,
               shouldMaintainTmuxControlChannel,
               let sessionName = resolvedTmuxSessionName {
                startTmuxControlChannel(sessionName: sessionName)
            }

            // Plain mosh (`.customCommand`) has no further handshake
            // past `.connected`; dismiss as soon as we've got bytes.
            // Tmux modes wait for both `.connected + first output +
            // tmux control mode` (see `.onChange(of: tmux.mode)` below
            // and `maybeDismissLaunchOverlay`).
            maybeDismissLaunchOverlay(reason: "state=\(MoshDiagnostics.stateDescription(newState))")
        }
    }

    private var moshDecoratedTransport: some View {
        moshDecoratedConnectionTask
        .onChange(of: launchOverlayVisible) { _, visible in
            // Mirror "launch complete" into the shared registry so the
            // sidebar row can drop its connecting appearance — it can't
            // observe this view's local overlay state directly. See the
            // matching handler in the SSH `SessionView`.
            if !visible {
                sessionRegistry.markRenderReady(liveSessionID)
                if !isActive,
                   !agentCenter.shouldMaintainObservation(sessionID: liveSessionID) {
                    stopTmuxControlChannel()
                }
            }
        }
        .onChange(of: session.transportState) { _, newState in
            recordMoshScrollDiagnostic(
                "transport-state-changed state=\(newState.logDescription) position=\(describeScrollPosition(for: terminalBox.view))"
            )
            MoshDiagnostics.log(
                "mosh view transport state=\(newState.logDescription)"
            )
            if newState != .connected {
                resetMoshScrollbackCapture(clearLocal: false, reason: "transport-\(newState.logDescription)")
            }
        }
        .onChange(of: tmux.activeWindowId) { _, newValue in
            reconcileAgentScrollNotice()
            recordMoshScrollDiagnostic(
                "tmux-window-changed window=\(newValue?.description ?? "nil") position=\(describeScrollPosition(for: terminalBox.view))"
            )
            // Mosh paints the terminal directly; the side-channel -CC client is
            // render-inert, so the only per-window hygiene possible is clearing
            // the shared scrollback when the active window genuinely changes.
            // tmux.reset() nils activeWindowId on every side-channel reattach —
            // latch the last-known window so reattach-to-the-same-window never
            // fires a gratuitous clear, and roams never clear at all.
            guard let newValue else { return }
            if let last = lastScrollbackWindowId, last != newValue {
                resetMoshScrollbackCapture(clearLocal: false, reason: "window-change")
                recordMoshScrollDiagnostic(
                    "surface=shared clear-scrollback reason=window-change from=\(last.description) to=\(newValue.description) before=\(describeScrollPosition(for: terminalBox.view))"
                )
                terminalBox.clearScrollback(restoringLimit: appearance.scrollbackLines)
                recordMoshScrollDiagnostic(
                    "surface=shared clear-scrollback reason=window-change after=\(describeScrollPosition(for: terminalBox.view))"
                )
                if findController.isOpen {
                    seedMoshFindScrollbackIfNeeded(reason: "window-change")
                }
            }
            lastScrollbackWindowId = newValue
            scheduleMoshOverlayPrefetch(reason: "window-change")
        }
        .onChange(of: tmux.activePaneId) { oldPaneId, newPaneId in
            updateSwipePadAgentFocus()
            reconcileAgentScrollNotice()
            recordMoshScrollDiagnostic(
                "tmux-pane-changed old=\(oldPaneId?.description ?? "nil") new=\(newPaneId?.description ?? "nil") position=\(describeScrollPosition(for: terminalBox.view))"
            )
            rememberCurrentMoshPaneChromeSnapshot()
            if oldPaneId != newPaneId {
                if oldPaneId != nil {
                    let hadOverlay = moshPaneScrollbackOverlay != nil
                    resetMoshScrollbackCapture(clearLocal: !hadOverlay, reason: "pane-change")
                }
                if newPaneId != nil, findController.isOpen {
                    seedMoshFindScrollbackIfNeeded(reason: "pane-change")
                }
                if newPaneId != nil {
                    // Warm the alt-screen/mouse cache for the incoming pane
                    // so its first scroll routes semantically right away
                    // instead of parking points behind an interaction-probe
                    // round trip (felt as "first htop scroll does nothing").
                    tmux.queryActivePaneInteractionState { _ in }
                    scheduleMoshOverlayPrefetch(reason: "pane-change")
                }
            }
            if newPaneId != nil,
               isPhone,
               isActive,
               appPhase.isActive,
               let viewport = lastCompactViewportSize,
               CompactTmuxClientSizing.shouldReprojectLayout(
                viewport: viewport,
                lastClientSize: lastCompactClientSize,
                windowRect: compactMoshWindowRect,
                focusRect: compactMoshFocusRect
               ) {
                pushCompactMoshViewport(viewport)
            }
            // Magic-puck pane-awareness on the mosh path. The side-channel -CC
            // client tracks `activePaneId` from `%window-pane-changed`, and the
            // SwipePad resolver scopes its `pane_current_command`/`pane_pid`
            // query to it. A pane focus change (prefix keys / ⌘[] dispatched via
            // the side channel) carries no terminal output here — mosh paints
            // the split natively — so re-poll immediately so the puck follows
            // the focused pane. Bump directly to bypass the output cooldown.
            // Skip nil transitions (teardown / reset / reconnect): no pane to
            // scope to, and the side channel may already be torn down.
            guard swipePadSessionIsActive, newPaneId != nil else { return }
            swipePadOutputActivityToken &+= 1
            SwipePadDiagnostics.log(
                "output-activity session=mosh reason='pane-focus' token=\(swipePadOutputActivityToken)"
            )
        }
    }

    private var moshDecoratedCore: some View {
        moshDecoratedTransport
        .onChange(of: tmux.gridAuthority) { _, authority in
            mirrorGridAuthorityInRegistry(authority)
        }
        .onChange(of: isPhone) { _, compact in
            tmux.setGridAuthorityUsesCompactSinglePaneGrid(compact)
        }
        .onChange(of: moshRenderLayout) { oldLayout, newLayout in
            guard oldLayout != newLayout else { return }
            if (newLayout?.paneCount ?? 1) > 1 {
                moshPaneChromeTopMaskActive = false
                moshPaneChromeCollapseMaskedPaneIds.removeAll()
                rememberCurrentMoshPaneChromeSnapshot()
            } else if (oldLayout?.paneCount ?? 1) > 1,
                      (newLayout?.paneCount ?? 1) <= 1 {
                showMoshPaneChromeCollapseMaskIfNeeded()
            }
            resetMoshScrollbackCapture(clearLocal: false, reason: "layout-change")
            // A tmux-side geometry change redraws the window into the
            // mosh-server PTY as a diff against tmux's own client model —
            // cells the local terminal shows differently (buffered attach
            // replay, restored continuity snapshot) but that tmux and mosh
            // both believe are current never get repainted, leaving stale
            // fragments on screen. One full frame from the mosh client's
            // framebuffer model resynchronizes the terminal; SSP diffs stay
            // consistent from there. (Same-size resumes never trigger the
            // resize path that would otherwise heal this as a side effect.)
            let suppressAuthorityDuplicate = authorityMoshRepaintLayoutToSuppress
                .map { $0 == newLayout } ?? false
            authorityMoshRepaintLayoutToSuppress = nil
            if !suppressAuthorityDuplicate {
                session.forceFullRepaint()
            }
            if findController.isOpen {
                seedMoshFindScrollbackIfNeeded(reason: "layout-change")
            }
            scheduleMoshOverlayPrefetch(reason: "layout-change")
            if isPhone,
               isActive,
               appPhase.isActive,
               let viewport = lastCompactViewportSize,
               CompactTmuxClientSizing.shouldReprojectLayout(
                viewport: viewport,
                lastClientSize: lastCompactClientSize,
                windowRect: compactMoshWindowRect,
                focusRect: compactMoshFocusRect
               ) {
                pushCompactMoshViewport(viewport)
            }
        }
        .onChange(of: findController.focusRequestToken) { _, _ in
            seedMoshFindScrollbackIfNeeded(reason: "find-open")
        }
        .onChange(of: findController.query) { _, newQuery in
            guard !newQuery.isEmpty else { return }
            seedMoshFindScrollbackIfNeeded(reason: "find-query")
        }
        .onChange(of: findController.isOpen) { _, isOpen in
            if !isOpen {
                moshPaneScrollbackOverlay?.box.view?.clearSearch()
            }
        }
        .onChange(of: isActive) { _, nowActive in
            recordMoshScrollDiagnostic(
                "active-changed active=\(nowActive) position=\(describeScrollPosition(for: terminalBox.view))"
            )
            swipePadSessionIsActive = nowActive
            if nowActive { updateSwipePadAgentFocus() }
            if !nowActive {
                agentScrollNotice.dismiss()
                terminalBox.dismissTransientInteractions()
                filesPanel.close()
            } else {
                reconcileAgentScrollNotice()
            }
            if nowActive {
                if isPhone,
                   tmux.mode == .tmuxControl,
                   let viewport = lastCompactViewportSize {
                    pushCompactMoshViewport(viewport, force: true)
                } else if let size = lastTerminalSize {
                    session.resize(cols: size.cols, rows: size.rows)
                    tmux.updateClientSize(cols: size.cols, rows: size.rows)
                    tmuxControlBox.channel?.resize(cols: size.cols, rows: size.rows)
                }
            }
            if shouldMaintainTmuxControlChannel {
                if let sessionName = resolvedTmuxSessionName {
                    startTmuxControlChannel(sessionName: sessionName)
                }
            } else {
                stopTmuxControlChannel()
            }
            // Same recovery as the SSH view: an open panel whose bridge
            // idled out or dropped while this session was backgrounded
            // reconnects on return.
            if nowActive, filesPanel.isOpen,
               let bridge = filesPanel.bridge,
               bridge.state != .connected, bridge.state != .connecting {
                filesPanel.open()
            }
        }
        .onChange(of: appPhase.isActive) { _, nowForeground in
            if !nowForeground, isActive {
                terminalBox.dismissTransientInteractions()
            }
            if nowForeground,
               isActive,
               isPhone,
               tmux.mode == .tmuxControl,
               let viewport = lastCompactViewportSize {
                pushCompactMoshViewport(viewport, force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tesseraForceRefreshTerminal)) { _ in
            forceRefreshTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            terminalBox.dismissTransientInteractionsIfInterfaceOrientationChanged()
        }
        .onChange(of: agentCenter.shouldMaintainObservation(sessionID: liveSessionID)) { _, needed in
            if needed,
               session.state == .connected,
               let sessionName = resolvedTmuxSessionName {
                startTmuxControlChannel(sessionName: sessionName)
                if case .tmuxControl = tmux.mode {
                    agentCenter.observationCarrierBecameReady(sessionID: liveSessionID)
                }
            } else if !needed, !isActive, !launchOverlayVisible {
                stopTmuxControlChannel()
            }
        }
        .onChange(of: agentCenter.activityRevision) { _, _ in
            reconcileAgentScrollNotice()
        }
    }

    var body: some View {
        moshDecoratedCore
        .task(id: moshCwdPollKey) {
            await runMoshCwdPoll()
        }
        .onChange(of: session.remoteServerPID) { _, pid in
            handleRemoteServerPIDChange(pid)
        }
        .onChange(of: session.pendingPathInjection) { _, path in
            consumePendingPathInjection(path)
        }
        .onChange(of: scrollDiagnosticsEnabled) { _, enabled in
            if enabled {
                recordMoshScrollDiagnostic(
                    "scroll-diagnostics-enabled position=\(describeScrollPosition(for: terminalBox.view))"
                )
            }
        }
        .onChange(of: tmux.mode) { _, newMode in
            recordMoshScrollDiagnostic(
                "tmux-mode-changed mode=\(newMode) position=\(describeScrollPosition(for: terminalBox.view))"
            )
            if case .tmuxControl = newMode {
                if session.host.launchMode == .autoTmux,
                   let name = resolvedTmuxSessionName {
                    HostRuntimeStateStore.recordSessionUsed(name, for: session.host)
                } else {
                    HostRuntimeStateStore.recordTmuxAvailable(for: session.host)
                }
            }
            // Tmux side-channel just engaged — the other half of the
            // tmux-mode dismissal pair (first-output is checked in the
            // bytes-receive loop above).
            maybeDismissLaunchOverlay(reason: "tmux.mode")
            if case .tmuxControl = newMode {
                if isPhone,
                   isActive,
                   appPhase.isActive,
                   let viewport = lastCompactViewportSize {
                    pushCompactMoshViewport(viewport, force: true)
                }
                seedMoshFindScrollbackIfNeeded(reason: "tmux-mode")
                // Every entry into control mode is an attach boundary:
                // output during a side-channel outage arrives via mosh SSP
                // with no %output to mark the parked capture stale, so it
                // must never be trusted across the gap — force the refill
                // instead of letting the fresh guard skip it.
                moshOverlayContentEpoch += 1
                moshDormantScrollbackOverlay?.isFresh = false
                scheduleMoshOverlayPrefetch(reason: "tmux-mode")
            }
        }
        .onDisappear {
            stopTmuxControlChannel()
            moshOverlayPrefetchTask?.cancel()
            swipePadOutputActivityTask?.cancel()
            swipePadOutputActivityTask = nil
        }
    }

    /// Combined-signal dismissal for the launch overlay. Caller fires
    /// from every input that could have advanced the readiness state
    /// (session.state change, tmux.mode change, first output chunk);
    /// this method decides per launchMode whether we're now ready.
    ///
    ///   - `.customCommand`: ready when `.connected && hasReceivedFirstOutput`.
    ///   - tmux modes: ready when `.connected && hasReceivedFirstOutput
    ///     && tmux.mode == .tmuxControl`. We don't use
    ///     `tmux.isInitialRenderReady` because for side-channel control
    ///     it's set immediately on DCS — but the main mosh stream may
    ///     not have streamed any bytes yet, so we'd dismiss to an
    ///     empty terminal.
    private func maybeDismissLaunchOverlay(reason: String) {
        guard launchOverlayVisible else { return }
        guard session.state == .connected else { return }
        let ready: Bool
        switch session.host.launchMode {
        case .customCommand:
            ready = hasReceivedFirstOutput
        case .autoTmux, .pinnedTmux:
            ready = hasReceivedFirstOutput && tmux.mode == .tmuxControl
        }
        if ready {
            MoshDiagnostics.log("mosh launch overlay dismissed reason=\(reason)")
            launchOverlayVisible = false
        }
    }

    private var shouldMaintainTmuxControlChannel: Bool {
        switch session.host.launchMode {
        case .customCommand:
            return false
        case .autoTmux, .pinnedTmux:
            return session.state == .connected
                && (isActive
                    || launchOverlayVisible
                    || agentCenter.shouldMaintainObservation(sessionID: liveSessionID))
        }
    }

    private var isTmuxDegraded: Bool {
        session.state == .connected && tmuxSideChannelState.isControlUnavailable
    }

    private var moshTcpControlStatus: MoshTcpControlStatus? {
        session.host.launchMode == .customCommand
            ? nil
            : tmuxSideChannelState.tcpControlStatus
    }

    /// Mirror of `SessionView.handleSwitcherShortcut` — see the SSH path
    /// for the same code shape. Kept in the mosh struct because the
    /// closure body needs access to this view's `liveSessionID` /
    /// environment objects.
    private func handleSwitcherShortcut(_ shortcut: TesseraSwitcherShortcut) {
        switch shortcut {
        case .openPalette:
            commandPalette.open(
                sessions: sessionRegistry.activeSessions,
                lastTouched: sessionRegistry.lastTouched
            )
        case .cyclePrevious, .cycleNext:
            // Immediate switch to the neighbouring session in sidebar
            // order, wrapping at both ends. No HUD or settle timer — the
            // terminal content changing is the feedback, and this reuses
            // the same `onSelectSession` path the palette commits through.
            let direction: SessionSwitchDirection =
                shortcut == .cyclePrevious ? .previous : .next
            if let target = SessionSwitcher.step(
                order: sessionRegistry.activeSessions.map(\.id),
                from: liveSessionID,
                direction: direction
            ) {
                onSelectSession(target)
            }
        }
    }

    private var activeAgentScrollPaneID: Int? {
        tmux.mode == .tmuxControl ? tmux.activePaneId?.rawValue : nil
    }

    private func agentScrollPrevention(paneID: Int?) -> AgentScrollPrevention? {
        agentCenter.scrollPrevention(sessionID: liveSessionID, paneID: paneID)
    }

    private func presentAgentScrollPrevention(paneID: Int?) {
        guard isActive, let prevention = agentScrollPrevention(paneID: paneID) else {
            return
        }
        appLockController.notifyUserActivity()
        agentScrollNotice.show(prevention)
        let paneLabel = paneID.map(String.init) ?? "raw"
        let provider = prevention.agentName == "Codex" ? "codex" : "claude"
        DiagnosticLogStore.appendAgentCenter(
            "scroll-blocked sid=\(String(liveSessionID.uuidString.prefix(8))) pane=\(paneLabel) provider=\(provider)"
        )
    }

    private func reconcileAgentScrollNotice() {
        guard let shown = agentScrollNotice.prevention else { return }
        let current = agentScrollPrevention(paneID: shown.agentID.paneID)
        if current != shown || !isActive || !agentScrollSurfaceIsVisible(shown.agentID) {
            agentScrollNotice.dismiss()
        }
    }

    private func agentScrollSurfaceIsVisible(_ id: AgentInstanceID) -> Bool {
        guard id.sessionID == liveSessionID else { return false }
        guard tmux.mode == .tmuxControl else { return id.paneID == nil }
        return id.paneID == tmux.activePaneId?.rawValue
    }

    /// Report the terminal surface the user is looking at to Agent Center's
    /// SwipePad projection: the focused tmux pane, or a nil pane for a raw
    /// screen. Equality-gated on the other side, so calling on every focus
    /// signal is free.
    private func updateSwipePadAgentFocus() {
        if tmux.mode == .tmuxControl {
            if let paneID = tmux.activePaneId {
                agentCenter.setSwipePadFocus(sessionID: liveSessionID, paneID: paneID.rawValue)
            } else {
                // No active pane (window teardown / mid-hydration): clear
                // rather than keep the departed pane's focus — a stale
                // fireable snapshot could route a macro into whatever pane
                // tmux has foreground, and mosh sends have no pane guard.
                agentCenter.clearSwipePadFocus(sessionID: liveSessionID)
            }
        } else {
            agentCenter.setSwipePadFocus(sessionID: liveSessionID, paneID: nil)
        }
    }

    private func scheduleSwipePadOutputActivityRefresh(reason: String) {
        guard swipePadSessionIsActive else { return }
        guard swipePadOutputActivityTask == nil else { return }

        swipePadOutputActivityTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            swipePadOutputActivityToken &+= 1
            SwipePadDiagnostics.log(
                "output-activity session=mosh reason='\(reason)' token=\(swipePadOutputActivityToken)"
            )

            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            swipePadOutputActivityTask = nil
        }
    }

    private var shouldRecordScrollDiagnostics: Bool {
        scrollDiagnosticsEnabled || DiagnosticLogStore.isScrollDiagnosticsEnabled
    }

    private func recordMoshScrollDiagnostic(_ message: String) {
        guard shouldRecordScrollDiagnostics else { return }
        scrollDiagnostics.sequence += 1
        let context = [
            "mosh",
            "seq=\(scrollDiagnostics.sequence)",
            "state=\(MoshDiagnostics.stateDescription(session.state))",
            "transport=\(session.transportState.logDescription)",
            "mode=\(tmux.mode)",
            "window=\(tmux.activeWindowId?.description ?? "nil")",
            "pane=\(tmux.activePaneId?.description ?? "nil")",
        ].joined(separator: " ")
        DiagnosticLogStore.appendScroll("\(context) \(message)")
    }

    private func terminalScrollPosition(for view: TerminalView?) -> TerminalScrollPosition? {
        guard let view else { return nil }
        let terminal = view.getTerminal()
        return TerminalScrollPosition(
            offsetY: view.contentOffset.y,
            maxOffsetY: max(0, view.contentSize.height - view.bounds.height),
            contentHeight: view.contentSize.height,
            boundsHeight: view.bounds.height,
            isAltScreen: terminal.isCurrentBufferAlternate,
            mouseMode: String(describing: terminal.mouseMode)
        )
    }

    private func describeScrollPosition(for view: TerminalView?) -> String {
        describeScrollPosition(terminalScrollPosition(for: view))
    }

    private func describeScrollPosition(_ position: TerminalScrollPosition?) -> String {
        guard let position else { return "nil" }
        return "off=\(Self.format(position.offsetY))/\(Self.format(position.maxOffsetY)) content=\(Self.format(position.contentHeight)) bounds=\(Self.format(position.boundsHeight)) bottom=\(position.isAtBottom) alt=\(position.isAltScreen) mouse=\(position.mouseMode)"
    }

    private func shouldLogTerminalFeedScroll(
        before: TerminalScrollPosition?,
        after: TerminalScrollPosition?
    ) -> Bool {
        guard let after else { return false }
        guard let before else { return !after.isAtBottom }
        return !before.isAtBottom
            || !after.isAtBottom
            || abs(before.offsetY - after.offsetY) > 0.5
            || abs(before.maxOffsetY - after.maxOffsetY) > 0.5
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private func startTmuxControlChannel(sessionName: String) {
        guard tmuxControlTask == nil else { return }
        rememberMoshPaneChromeSnapshot()
        tmuxControlGeneration += 1
        let generation = tmuxControlGeneration
        MoshDiagnostics.log(
            "mosh tmux sidechannel reconnect loop start generation=\(generation) session=\(sessionName) state=\(MoshDiagnostics.stateDescription(session.state))"
        )
        resetMoshScrollbackCapture(clearLocal: false, reason: "sidechannel-start")
        tmux.reset()
        tmuxSideChannelState = .connecting(attempt: 1)

        tmuxControlTask?.cancel()
        tmuxControlTask = Task { @MainActor in
            await runTmuxControlReconnectLoop(
                sessionName: sessionName,
                generation: generation
            )
        }
    }

    private func runTmuxControlReconnectLoop(
        sessionName: String,
        generation: Int
    ) async {
        var reconnectAttempt = 0
        var lastReason: String?

        while !Task.isCancelled && tmuxControlGeneration == generation {
            guard shouldMaintainTmuxControlChannel else {
                MoshDiagnostics.log(
                    "mosh tmux sidechannel reconnect loop stop generation=\(generation) session=\(sessionName) active=\(isActive) overlay=\(launchOverlayVisible) state=\(MoshDiagnostics.stateDescription(session.state))"
                )
                break
            }

            if reconnectAttempt > 0 || lastReason != nil {
                tmuxSideChannelState = .reconnecting(
                    lastError: lastReason,
                    retryAttempt: max(reconnectAttempt, 1),
                    nextRetryDelay: nil
                )
            } else {
                tmuxSideChannelState = .connecting(attempt: 1)
            }

            let channel = TmuxControlChannel(
                host: session.host,
                requireBiometric: session.requireBiometric,
                isSecureEnclave: session.isSecureEnclave,
                sessionName: sessionName,
                initialSize: lastTerminalSize,
                preserveTmuxGeometry: session.preserveTmuxGeometry,
                preservedServerSize: session.preservedRemoteTmuxSize,
                portForwarderManager: session.portForwarderManager,
                portForwardRules: session.host.portForwardRules
            )
            tmuxControlBox.channel = channel
            MoshDiagnostics.log(
                "mosh tmux sidechannel reconnect attempt start generation=\(generation) sessionNameLength=\(sessionName.count) attempt=\(max(reconnectAttempt, 1)) state=\(tmuxSideChannelState.logDescription)"
            )
            channel.connect()
            var sawOutput = false
            var sawControlMode = false
            var chunkCount = 0
            for await chunk in channel.outputStream {
                chunkCount += 1
                if chunkCount <= 4 {
                    MoshDiagnostics.log(
                        "mosh tmux sidechannel view chunk#\(chunkCount) bytes=\(chunk.count)"
                    )
                }
                if !sawOutput {
                    sawOutput = true
                }
                let previousMode = tmux.mode
                let previousWindow = tmux.activeWindowId
                let previousPane = tmux.activePaneId
                tmux.ingest(chunk)
                if previousMode != tmux.mode
                    || previousWindow != tmux.activeWindowId
                    || previousPane != tmux.activePaneId {
                    SwipePadDiagnostics.log(
                        "mosh-sidechannel tmux-state mode \(previousMode)->\(tmux.mode) window \(String(describing: previousWindow))->\(String(describing: tmux.activeWindowId)) pane \(String(describing: previousPane))->\(String(describing: tmux.activePaneId))"
                    )
                }
                if !sawControlMode, case .tmuxControl = tmux.mode {
                    sawControlMode = true
                    reconnectAttempt = 0
                    lastReason = nil
                    if tmuxControlBox.channel === channel {
                        tmuxSideChannelState = .connected
                    }
                    MoshDiagnostics.log(
                        "mosh tmux sidechannel reconnect control-mode-entered generation=\(generation) session=\(sessionName)"
                    )
                    MoshDiagnostics.log(
                        "mosh tmux sidechannel reconnect state=connected generation=\(generation) session=\(sessionName)"
                    )
                    agentCenter.observationCarrierBecameReady(sessionID: liveSessionID)
                }
            }
            MoshDiagnostics.log(
                "mosh tmux sidechannel reconnect stream ended generation=\(generation) session=\(sessionName) sawOutput=\(sawOutput) sawControlMode=\(sawControlMode) chunks=\(chunkCount) sessionState=\(MoshDiagnostics.stateDescription(session.state)) reason=\(channel.terminationReason?.logDescription ?? "unknown")"
            )

            if tmuxControlBox.channel === channel {
                tmuxControlBox.channel = nil
                // Drain BEFORE the exit guards below: pending command
                // completions die with this stream. Breaking out on
                // cancel / generation-swap / degraded without draining
                // left them queued forever — a scrollback fetch stayed
                // "in-flight" and blocked every refetch on that pane,
                // and a later stream's replies dequeued against the
                // wrong commands (FIFO misalignment).
                tmux.sideChannelDisconnected()
            }

            guard !Task.isCancelled && tmuxControlGeneration == generation else { break }
            guard shouldMaintainTmuxControlChannel else { break }

            reconnectAttempt += 1
            let delay = Self.tmuxReconnectDelay(for: reconnectAttempt)
            lastReason = channel.terminationReason?.userFacingDescription
                ?? "control connection closed"
            tmuxSideChannelState = .reconnecting(
                lastError: lastReason,
                retryAttempt: reconnectAttempt,
                nextRetryDelay: delay
            )
            MoshDiagnostics.log(
                "mosh tmux sidechannel reconnect scheduled generation=\(generation) session=\(sessionName) attempt=\(reconnectAttempt) backoff=\(Self.formatDelay(delay)) reason=\(lastReason ?? "unknown") sawOutput=\(sawOutput) sawControlMode=\(sawControlMode)"
            )

            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(forDelay: delay))
            } catch {
                break
            }
        }

        if tmuxControlGeneration == generation {
            tmuxControlTask = nil
            tmuxControlBox.channel = nil
            if Task.isCancelled {
                MoshDiagnostics.log(
                    "mosh tmux sidechannel reconnect loop cancelled generation=\(generation) session=\(sessionName)"
                )
            } else if session.state == .connected && isActive {
                tmuxSideChannelState = .degraded(lastError: lastReason)
                MoshDiagnostics.log(
                    "mosh tmux sidechannel reconnect loop ended degraded generation=\(generation) session=\(sessionName) reason=\(lastReason ?? "unknown")"
                )
            } else {
                tmuxSideChannelState = .idle
                tmux.reset()
                MoshDiagnostics.log(
                    "mosh tmux sidechannel reconnect loop ended idle generation=\(generation) session=\(sessionName)"
                )
            }
        }
    }

    private func stopTmuxControlChannel() {
        rememberMoshPaneChromeSnapshot()
        if tmuxControlBox.channel != nil || tmuxControlTask != nil {
            MoshDiagnostics.log(
                "mosh tmux sidechannel view stop state=\(MoshDiagnostics.stateDescription(session.state))"
            )
        }
        tmuxControlGeneration += 1
        tmuxControlTask?.cancel()
        tmuxControlTask = nil
        tmuxControlBox.channel?.disconnect()
        tmuxControlBox.channel = nil
        tmuxShortcutToastTask?.cancel()
        tmuxShortcutToastTask = nil
        tmuxShortcutToastVisible = false
        tmuxSideChannelState = .idle
        resetMoshScrollbackCapture(clearLocal: false, reason: "sidechannel-stop")
        tmux.reset()
    }

    private func handleTmuxShortcut(_ shortcut: TesseraTmuxShortcut) {
        if shouldBlockTmuxShortcut {
            showTmuxShortcutBlockedToast(shortcut: shortcut)
            return
        }

        invalidateMoshScrollbackForTerminalInput(reason: "tmux-shortcut")
        switch shortcut {
        case .newWindow:
            tmux.newWindow()
        case .killCurrentWindow:
            // Contextual kill: pane when split, else window. Mosh dispatches
            // pane commands over the side channel like the others.
            if (moshActiveWindow?.paneCount ?? 1) > 1 {
                tmux.killActivePane()
            } else {
                tmux.killCurrentWindow()
            }
        case .previousWindow:
            tmux.previousWindow()
        case .nextWindow:
            tmux.nextWindow()
        case .selectWindow(let position):
            tmux.selectWindow(atPosition: position)
        case .splitPaneHorizontal:
            showMoshPaneChromeTopMask()
            tmux.splitActivePane(.horizontal)
        case .splitPaneVertical:
            showMoshPaneChromeTopMask()
            tmux.splitActivePane(.vertical)
        case .cyclePaneNext:
            tmux.cyclePane(forward: true)
        case .cyclePanePrevious:
            tmux.cyclePane(forward: false)
        case .zoomPane:
            tmux.togglePaneZoom()
        }
    }

    private var moshActiveWindow: TmuxController.WindowInfo? {
        guard let id = tmux.activeWindowId else { return nil }
        return tmux.windows.first(where: { $0.id == id })
    }

    private var compactMoshLayout: WindowLayout? {
        guard let window = moshActiveWindow else { return nil }
        return window.isZoomed
            ? (window.visibleLayout ?? window.layout)
            : window.layout
    }

    private var compactMoshWindowRect: CellRect? {
        guard isPhone, tmux.mode == .tmuxControl else { return nil }
        return compactMoshLayout?.root.rect
            ?? moshActiveWindow?.panes.first?.contentRect
    }

    private var compactMoshFocusRect: CellRect? {
        guard let window = moshActiveWindow,
              let paneID = window.activePaneId ?? tmux.activePaneId
        else { return compactMoshWindowRect }
        return compactMoshLayout?.leaves.first(where: { $0.paneId == paneID })?.rect
            ?? window.panes.first(where: { $0.id == paneID })?.contentRect
            ?? compactMoshWindowRect
    }

    private var compactMoshCellSize: CGSize {
        if let moshCellSize { return moshCellSize }
        let font = TesseraTerminalFont.mono(size: CGFloat(appearance.fontSize))
        return TerminalCellMetrics.cellSize(font: font, scale: UIScreen.main.scale)
    }

    private func updateCompactMoshViewport(_ size: CGSize) {
        guard isPhone,
              let viewport = CompactTmuxClientSizing.viewportCells(
                for: size,
                cellSize: compactMoshCellSize
              )
        else { return }
        lastCompactViewportSize = viewport
        guard isActive, appPhase.isActive else { return }
        pushCompactMoshViewport(viewport)
    }

    private func pushCompactMoshViewport(
        _ viewport: (cols: Int, rows: Int),
        force: Bool = false
    ) {
        let client = CompactTmuxClientSizing.clientSize(
            for: viewport,
            windowRect: compactMoshWindowRect,
            focusRect: compactMoshFocusRect
        )
        if !force,
           let lastCompactClientSize,
           lastCompactClientSize.cols == client.cols,
           lastCompactClientSize.rows == client.rows {
            return
        }
        if let previous = lastTerminalSize,
           previous.cols != client.cols || previous.rows != client.rows {
            resetMoshScrollbackCapture(clearLocal: true, reason: "compact-viewport-resize")
        }
        lastCompactClientSize = client
        lastTerminalSize = client
        session.resize(cols: client.cols, rows: client.rows)
        tmux.updateClientSize(cols: client.cols, rows: client.rows)
        tmuxControlBox.channel?.resize(cols: client.cols, rows: client.rows)
    }

    /// Repaint the visible mosh terminal from its framebuffer model. Mosh's
    /// full-frame emission is the authoritative refresh for both plain mosh
    /// and mosh+tmux; replaying the current size first also preserves the
    /// compact viewport geometry used by the side channel.
    private func forceRefreshTerminal() {
        guard isActive, appPhase.isActive, session.state == .connected else { return }
        appLockController.notifyUserActivity()
        terminalBox.forceRedraw()

        if isPhone, let viewport = lastCompactViewportSize {
            pushCompactMoshViewport(viewport, force: true)
        } else if let size = lastTerminalSize {
            session.resize(cols: size.cols, rows: size.rows)
            tmux.updateClientSize(cols: size.cols, rows: size.rows)
            tmuxControlBox.channel?.resize(cols: size.cols, rows: size.rows)
        }
        if tmux.mode == .tmuxControl {
            // Side-channel claim: replays the size with the existing direct
            // window force; the fence orders geometry and the exact mosh
            // framebuffer acknowledgement behind it.
            tmux.claimActiveViewport(
                reason: "force-refresh",
                repaintEvenIfSame: true
            )
        } else {
            // Plain mosh has no tmux claim callback to request the frame.
            session.forceFullRepaint()
        }
    }

    private func completeAuthorityMoshRepaintIfReady() {
        guard let target = authorityMoshRepaintTarget,
              moshConsumedOutputCount >= target.outputCount
        else { return }
        authorityMoshRepaintTarget = nil
        tmux.completeGridAuthoritySideChannelRepaint(
            generation: target.claimGeneration
        )
    }

    /// Take back the shared tmux grid from the device that continued this
    /// session. The controller restamps authority and replays our size over
    /// the side channel; the resulting `%layout-change` already drives the
    /// mosh full-repaint resync, and a same-grid reclaim needs neither.
    private func takeBackContinuedSession() {
        appLockController.notifyUserActivity()
        tmux.reclaimGridAuthority()
    }

    /// The peer detached and the controller auto-reclaimed — confirm with a
    /// transient toast instead of requiring a tap.
    private func presentAuthorityReturnedToast(departedPeerName: String?) {
        let selfName = GridAuthorityDeviceIdentity.selfDisplayName
        authorityReturnedToastLabel = departedPeerName.map {
            $0 == selfName ? "another \($0)" : $0
        }
        authorityToastDismissTask?.cancel()
        authorityReturnedToastVisible = true
        authorityToastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            authorityReturnedToastVisible = false
        }
    }

    /// Keep the sidebar's last-known continuation marker through a mosh
    /// side-channel reconnect. `.unknown` only means the observer is between
    /// control connections; `.mine` or removal of the live session clears it.
    private func mirrorGridAuthorityInRegistry(
        _ authority: TmuxController.GridAuthority
    ) {
        switch authority {
        case .peer(let displayName):
            sessionRegistry.setGridAuthorityPeerName(displayName, for: liveSessionID)
        case .mine:
            sessionRegistry.setGridAuthorityPeerName(nil, for: liveSessionID)
        case .unknown:
            break
        }
    }

    private func handleCompactTmuxFocusRequest() {
        guard let request = sessionRegistry.tmuxFocusRequest,
              request.sessionID == liveSessionID
        else { return }
        tmux.selectWindow(request.windowID)
        if let paneID = request.paneID {
            tmux.selectPanePreservingWindowZoom(paneID)
        }
    }

    /// Whether the mosh active window has a real multi-pane layout — gates the
    /// bare ⌘[/⌘] pane-cycle and ⌘⇧Return zoom chords on the mosh shared
    /// surface (the chord-only focus story; mosh paints splits natively).
    /// Extracted from the `TerminalSurfaceBound` call site so the SwiftUI body
    /// type-checks (an inline optional-chain there blows the complexity budget).
    private var moshPaneCycleEnabled: Bool {
        moshActiveWindow?.rendersAsPaneGrid ?? false
    }

    private func moshPaneChromeSnapshot() -> MoshPaneChromeSnapshot? {
        if let current = currentMoshPaneChromeSnapshot() {
            return current
        }
        if case .tmuxControl = tmux.mode,
           moshActiveWindow != nil {
            return nil
        }
        return lastMoshPaneChromeSnapshot
    }

    private var shouldShowMoshPaneChromeTopMask: Bool {
        moshPaneChromeTopMaskActive
            && currentMoshPaneChromeSnapshot() == nil
            && moshActiveWindow != nil
    }

    private func moshPaneChromeCollapseMaskFrames(cellSize: CGSize) -> [CGRect] {
        guard moshPaneChromeTopMaskActive,
              !moshPaneChromeCollapseMaskedPaneIds.isEmpty,
              let snapshot = lastMoshPaneChromeSnapshot,
              snapshot.windowId == moshActiveWindow?.id
        else { return [] }

        return moshPaneChromeFrames(for: snapshot, cellSize: cellSize)
            .filter { moshPaneChromeCollapseMaskedPaneIds.contains($0.paneId) }
            .map(\.paneBox)
    }

    private func currentMoshPaneChromeSnapshot() -> MoshPaneChromeSnapshot? {
        guard let window = moshActiveWindow,
              window.rendersAsPaneGrid,
              let layout = moshRenderLayout,
              layout.paneCount > 1
        else { return nil }

        return MoshPaneChromeSnapshot(
            windowId: window.id,
            layout: layout,
            activePaneId: window.activePaneId,
            panes: window.panes,
            windowName: window.windowName
        )
    }

    private func rememberCurrentMoshPaneChromeSnapshot() {
        if let snapshot = currentMoshPaneChromeSnapshot() {
            lastMoshPaneChromeSnapshot = snapshot
        }
    }

    private func rememberMoshPaneChromeSnapshot() {
        if let snapshot = currentMoshPaneChromeSnapshot() {
            lastMoshPaneChromeSnapshot = snapshot
            return
        }
        if case .tmuxControl = tmux.mode,
           moshActiveWindow != nil {
            lastMoshPaneChromeSnapshot = nil
        }
    }

    private func showMoshPaneChromeCollapseMaskIfNeeded() {
        guard let snapshot = lastMoshPaneChromeSnapshot,
              let window = moshActiveWindow,
              snapshot.windowId == window.id,
              !window.isZoomed,
              window.paneCount <= 1
        else { return }

        let oldPaneIds = Set(snapshot.layout.paneIds)
        let newPaneIds = Set(window.layout?.paneIds ?? [])
        moshPaneChromeCollapseMaskedPaneIds = oldPaneIds.subtracting(newPaneIds)
        showMoshPaneChromeTopMask()
    }

    private func showMoshPaneChromeTopMask() {
        moshPaneChromeTopMaskGeneration += 1
        let generation = moshPaneChromeTopMaskGeneration
        moshPaneChromeTopMaskActive = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.moshPaneChromeTopMaskDuration
        ) {
            guard moshPaneChromeTopMaskGeneration == generation else { return }
            moshPaneChromeTopMaskActive = false
            moshPaneChromeCollapseMaskedPaneIds.removeAll()
            if currentMoshPaneChromeSnapshot() == nil,
               case .tmuxControl = tmux.mode,
               moshActiveWindow != nil {
                lastMoshPaneChromeSnapshot = nil
            }
        }
    }

    private func moshPaneChromeFrames(
        for snapshot: MoshPaneChromeSnapshot,
        cellSize: CGSize
    ) -> [PaneFrame] {
        snapshot.layout.leaves.compactMap { leaf in
            let contentRect = moshPaneChromeContentRect(
                paneId: leaf.paneId,
                leafRect: leaf.rect,
                panes: snapshot.panes
            )
            guard contentRect.width > 0, contentRect.height > 0 else { return nil }

            let headerRect = CellRect(
                width: contentRect.width,
                height: 1,
                x: contentRect.x,
                y: max(0, contentRect.y - 1)
            )
            return PaneFrame(
                paneId: leaf.paneId,
                headerFrame: moshPixelFrame(for: headerRect, cellSize: cellSize),
                surfaceFrame: moshPixelFrame(for: contentRect, cellSize: cellSize)
            )
        }
    }

    private func moshPaneChromeContentRect(
        paneId: PaneId,
        leafRect: CellRect,
        panes: [TmuxController.PaneInfo]
    ) -> CellRect {
        panes.first(where: { $0.id == paneId })?.contentRect ?? leafRect
    }

    private func moshPixelFrame(for rect: CellRect, cellSize: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(rect.x) * cellSize.width,
            y: CGFloat(rect.y) * cellSize.height,
            width: CGFloat(rect.width) * cellSize.width,
            height: CGFloat(rect.height) * cellSize.height
        )
    }

    private func moshPaneChromeTitles(
        for frames: [PaneFrame],
        snapshot: MoshPaneChromeSnapshot
    ) -> [PaneId: String] {
        Dictionary(
            uniqueKeysWithValues: frames.map {
                ($0.paneId, moshPaneTitle($0.paneId, snapshot: snapshot))
            }
        )
    }

    private func moshPaneTitle(
        _ paneId: PaneId,
        snapshot: MoshPaneChromeSnapshot
    ) -> String {
        let pane = snapshot.panes.first(where: { $0.id == paneId })
        if let pane,
           !pane.titleIsDefault,
           let title = moshNonEmpty(pane.title) {
            return title
        }
        if let command = moshNonEmpty(pane?.currentCommand) {
            return command
        }
        if let name = moshNonEmpty(snapshot.windowName) {
            return name
        }
        return paneId.description
    }

    private func moshNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func moshPaneScrollbackFrame(for paneId: PaneId) -> PaneFrame? {
        guard let cellSize = moshCellSize
        else { return nil }

        if let rect = moshPaneScrollbackContentRect(for: paneId) {
            let surface = moshPixelFrame(for: rect, cellSize: cellSize)
            return PaneFrame(
                paneId: paneId,
                headerFrame: CGRect(x: surface.minX, y: surface.minY, width: surface.width, height: 0),
                surfaceFrame: surface
            )
        }

        guard let root = moshRenderLayout?.root else { return nil }
        return PaneLayoutMath.frames(root: root, cellSize: cellSize, headerHeight: 0)
            .first(where: { $0.paneId == paneId })
    }

    private func moshPaneScrollbackContentRect(for paneId: PaneId) -> CellRect? {
        let leafRect = moshRenderLayout?.leaves.first(where: { $0.paneId == paneId })?.rect
        if let window = moshActiveWindow,
           let rect = window.panes.first(where: { $0.id == paneId })?.contentRect {
            if window.rendersAsPaneGrid,
               let leafRect,
               rect == leafRect {
                return moshPaneContentRectByExcludingTitleRow(from: rect)
            }
            return rect
        }

        guard let window = moshActiveWindow,
              window.rendersAsPaneGrid,
              let leafRect
        else { return nil }

        // Fallback for the brief gap before pane metadata hydration catches up:
        // with `pane-border-status top`, `window_layout` still includes the
        // title row, while `pane_top`/`pane_height` exclude it.
        return moshPaneContentRectByExcludingTitleRow(from: leafRect)
    }

    private func moshPaneContentRectByExcludingTitleRow(from rect: CellRect) -> CellRect {
        guard rect.height > 1 else { return rect }
        return CellRect(
            width: rect.width,
            height: rect.height - 1,
            x: rect.x,
            y: rect.y + 1
        )
    }

    private func moshPaneScrollbackRows(for paneId: PaneId) -> Int? {
        guard let frame = moshPaneScrollbackFrame(for: paneId),
              let cellSize = moshCellSize,
              cellSize.height > 0
        else { return nil }
        return max(1, Int((frame.surfaceFrame.height / cellSize.height).rounded()))
    }

    private func ensureMoshPaneScrollbackOverlay(
        paneId: PaneId,
        windowId: WindowId
    ) -> MoshPaneScrollbackOverlayRuntime {
        if let overlay = moshPaneScrollbackOverlay,
           overlay.paneId == paneId,
           overlay.windowId == windowId {
            // NO find-handler rebind here: this early path runs on EVERY
            // scroll event while the overlay is up, and `handlers` lives on
            // an @Observable — a per-event observable write from the scroll
            // hot path is invalidation/observation churn for zero benefit
            // (the handlers were bound at creation and haven't changed).
            return overlay
        }

        dismissMoshPaneScrollbackOverlay(clearDepth: true, reason: "replace")

        if let dormant = moshDormantScrollbackOverlay,
           dormant.paneId == paneId,
           dormant.windowId == windowId {
            // Same pane re-entering scrollback: promote the parked runtime
            // — its SwiftTerm view is still mounted (or remounts itself if
            // its frame vanished meanwhile; TerminalBox buffers feeds until
            // attach), so this skips the ~140ms view-creation block.
            moshDormantScrollbackOverlay = nil
            dormant.pendingScrollPlacement = nil
            dormant.pendingDeferredCapture = nil
            dormant.sawNativeScroll = false
            dormant.contentFrozen = false
            dormant.clearDesiredScrollOffset()
            dormant.stopNativeScrollMotion()
            moshPaneScrollbackOverlay = dormant
            findController.handlers = TerminalSearchAdapter.handlers(for: dormant.box)
            if dormant.hasRevealableFreshContent {
                // Hot-buffer reveal: the prefetched capture still matches
                // the live tail, so show it right now — no fetch, nothing
                // cold left inside the gesture. Content sits at the bottom
                // (post-feed snap), so the caller's scroll on this same
                // event moves up from the live tail seamlessly. Restoring
                // the depth keeps the caller's at-top check honest and
                // top-reach fetches continuing from the right page.
                moshScrollbackDepthByPane[dormant.paneId] = max(
                    moshScrollbackDepthByPane[dormant.paneId] ?? 0,
                    dormant.capturedDepth
                )
                moshOverlayContentReadyId = dormant.id
                MoshDiagnostics.log(
                    "mosh scrollback overlay promote-fresh pane=\(paneId.description) window=\(windowId.description) depth=\(dormant.capturedDepth)"
                )
                recordMoshScrollDiagnostic(
                    "surface=overlay window=\(windowId.description) pane=\(paneId.description) promote-fresh depth=\(dormant.capturedDepth)"
                )
                scheduleEagerMoshOverlayDeepen(for: dormant)
            } else {
                MoshDiagnostics.log(
                    "mosh scrollback overlay promote pane=\(paneId.description) window=\(windowId.description) fresh=\(dormant.isFresh) viewAttached=\(dormant.box.view != nil)"
                )
            }
            return dormant
        }

        let overlay = MoshPaneScrollbackOverlayRuntime(paneId: paneId, windowId: windowId)
        moshPaneScrollbackOverlay = overlay
        findController.handlers = TerminalSearchAdapter.handlers(for: overlay.box)
        MoshDiagnostics.log(
            "mosh scrollback overlay create pane=\(paneId.description) window=\(windowId.description)"
        )
        return overlay
    }

    private func dismissMoshPaneScrollbackOverlay(clearDepth: Bool, reason: String) {
        guard let overlay = moshPaneScrollbackOverlay else { return }
        overlay.box.view?.clearSearch()
        if clearDepth {
            moshScrollbackDepthByPane.removeValue(forKey: overlay.paneId)
        }
        if moshScrollbackInFlight?.paneId == overlay.paneId {
            moshScrollbackInFlight = nil
            moshScrollbackLoading = false
        }
        moshPaneScrollbackOverlay = nil
        // Park rather than drop: the runtime's mounted SwiftTerm view is
        // the expensive part (~140ms). Stale content is safe — the
        // opacity gate keys on moshOverlayContentReadyId, so a promoted
        // overlay stays invisible until its next capture (or prefetch)
        // is fed. Freshness never survives a park: the dismissal reasons
        // (output, typing, pane/layout churn, bottom return) all mean the
        // content can no longer be trusted to match the live tail — the
        // debounced prefetch re-establishes it.
        overlay.isFresh = false
        overlay.pendingDeferredCapture = nil
        overlay.sawNativeScroll = false
        // A frozen snapshot never survives a park: the next reveal goes
        // through prefetch/fetch, which re-establishes live-tail content.
        overlay.contentFrozen = false
        // A dismissal can land mid-fling; the parked view stays mounted,
        // so without this its deceleration keeps running invisibly —
        // moving the parked offset, deferring prefetch feeds, and making
        // a promoted-but-hidden overlay look "natively active" to the
        // fetch-reply deferral (which would strand the capture).
        overlay.stopNativeScrollMotion()
        moshDormantScrollbackOverlay = overlay
        moshOverlayContentReadyId = nil
        findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)
        if findController.isOpen {
            findController.updateSearch()
        }
        MoshDiagnostics.log(
            "mosh scrollback overlay dismiss reason=\(reason) pane=\(overlay.paneId.description) clearDepth=\(clearDepth)"
        )
    }

    private func applyPendingMoshPaneScrollbackOverlayOffset() {
        guard let overlay = moshPaneScrollbackOverlay,
              overlay.pendingScrollPlacement != nil
        else { return }
        applyPendingMoshPaneScrollbackOverlayOffset(
            revision: overlay.pendingScrollPlacementRevision,
            attemptsRemaining: 5
        )
    }

    private func applyPendingMoshPaneScrollbackOverlayOffset(
        revision: Int,
        attemptsRemaining: Int
    ) {
        DispatchQueue.main.async {
            guard let overlay = moshPaneScrollbackOverlay,
                  overlay.pendingScrollPlacementRevision == revision,
                  let view = overlay.box.view
            else { return }
            if let placement = overlay.pendingScrollPlacement {
                let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
                if placement.requiresScrollableContent,
                   maxOffsetY <= Self.moshScrollbackTopThreshold {
                    if attemptsRemaining > 1 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) {
                            guard let currentOverlay = moshPaneScrollbackOverlay,
                                  currentOverlay === overlay,
                                  currentOverlay.pendingScrollPlacementRevision == revision
                            else { return }
                            applyPendingMoshPaneScrollbackOverlayOffset(
                                revision: revision,
                                attemptsRemaining: attemptsRemaining - 1
                            )
                        }
                    } else {
                        MoshDiagnostics.log(
                            "mosh scrollback overlay offset waiting pane=\(overlay.paneId.description) placement=\(placement.logDescription) contentHeight=\(String(format: "%.1f", view.contentSize.height)) boundsHeight=\(String(format: "%.1f", view.bounds.height))"
                        )
                    }
                    return
                }

                let targetY: CGFloat
                switch placement {
                case .top:
                    targetY = 0
                case .bottomMinus(let points):
                    targetY = max(0, maxOffsetY - points)
                case .absolute(let y):
                    targetY = y
                }
                let offsetY = overlay.applyDesiredScrollOffset(targetY, in: view)
                MoshDiagnostics.log(
                    "mosh scrollback overlay offset applied pane=\(overlay.paneId.description) placement=\(placement.logDescription) targetY=\(String(format: "%.1f", targetY)) offsetY=\(String(format: "%.1f", offsetY)) maxOffset=\(String(format: "%.1f", maxOffsetY)) contentHeight=\(String(format: "%.1f", view.contentSize.height)) boundsHeight=\(String(format: "%.1f", view.bounds.height))"
                )
                recordMoshScrollDiagnostic(
                    "surface=overlay window=\(overlay.windowId.description) pane=\(overlay.paneId.description) offset-applied placement=\(placement.logDescription) targetY=\(Self.format(targetY)) offsetY=\(Self.format(offsetY)) max=\(Self.format(maxOffsetY)) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height))"
                )
                if attemptsRemaining > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) {
                        guard let currentOverlay = moshPaneScrollbackOverlay,
                              currentOverlay === overlay,
                              currentOverlay.pendingScrollPlacementRevision == revision
                        else { return }
                        applyPendingMoshPaneScrollbackOverlayOffset(
                            revision: revision,
                            attemptsRemaining: attemptsRemaining - 1
                        )
                    }
                } else {
                    overlay.pendingScrollPlacement = nil
                }
            }
            if findController.isOpen {
                findController.handlers = TerminalSearchAdapter.handlers(for: overlay.box)
                findController.updateSearch()
            }
        }
    }

    private func handleMoshPaneScrollbackOverlayScrolled(_ view: TerminalView) {
        guard let overlay = moshPaneScrollbackOverlay,
              overlay.box.view === view
        else { return }
        if view.isTracking || view.isDragging || view.isDecelerating {
            // A native pan/deceleration owns contentOffset. The desired-
            // offset anchor exists to counter feed-induced snaps — fighting
            // a live finger with it would stutter, so it FOLLOWS the native
            // offset instead. Boundary work (bottom dismissal, deferred
            // deep-history feed) waits for the settle poll: UIScrollView
            // exposes no end-of-scroll hook here (SwiftTerm owns the
            // delegate), and the last didScroll of a gesture still reports
            // an active state.
            if view.isTracking || view.isDragging,
               overlay.pendingDeferredCapture == nil,
               moshScrollbackInFlight == nil,
               overlay.pendingScrollPlacement != nil {
                // A real pan takes over from a just-applied capture anchor:
                // bump the revision so the 35ms re-anchor retry chain dies
                // instead of fighting the finger (same rule the bridge path
                // applies in scrollMoshPaneScrollbackOverlay). Never while a
                // capture is in flight or parked — that placement is the
                // capture's anchor, and killing it would make the eventual
                // apply snap to the fed tail instead of rebasing to .top.
                overlay.pendingScrollPlacement = nil
                overlay.pendingScrollPlacementRevision += 1
            }
            overlay.sawNativeScroll = true
            overlay.desiredScrollOffsetY = view.contentOffset.y
            maybeDeepenMoshOverlayScrollback(
                overlay: overlay,
                view: view,
                reason: "native-deepen-pan"
            )
            armMoshOverlayNativeSettleCheck(for: overlay)
            return
        }
        overlay.restoreDesiredScrollOffset(in: view) { detail in
            recordMoshScrollDiagnostic(
                "surface=overlay window=\(overlay.windowId.description) \(detail)"
            )
        }
        resolveMoshOverlayNativeBoundary(overlay: overlay, view: view)
    }

    /// 10Hz poll bridging the gap between the last active didScroll and
    /// actual settle (pan end with no momentum, or deceleration running
    /// out) — both end without a settled scroll callback.
    private func armMoshOverlayNativeSettleCheck(for overlay: MoshPaneScrollbackOverlayRuntime) {
        guard !overlay.nativeSettleCheckArmed else { return }
        overlay.nativeSettleCheckArmed = true
        scheduleMoshOverlayNativeSettleCheck(overlay, attempt: 0)
    }

    private func scheduleMoshOverlayNativeSettleCheck(
        _ overlay: MoshPaneScrollbackOverlayRuntime,
        attempt: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard moshPaneScrollbackOverlay === overlay,
                  let view = overlay.box.view
            else {
                overlay.nativeSettleCheckArmed = false
                return
            }
            if view.isTracking || view.isDragging || view.isDecelerating {
                // 60s cap: a wedged UIScrollView state must not poll forever.
                guard attempt < 600 else {
                    overlay.nativeSettleCheckArmed = false
                    return
                }
                scheduleMoshOverlayNativeSettleCheck(overlay, attempt: attempt + 1)
                return
            }
            overlay.nativeSettleCheckArmed = false
            overlay.desiredScrollOffsetY = view.contentOffset.y
            resolveMoshOverlayNativeBoundary(overlay: overlay, view: view)
        }
    }

    /// Settled-state boundary decisions for the native scroll path.
    private func resolveMoshOverlayNativeBoundary(
        overlay: MoshPaneScrollbackOverlayRuntime,
        view: TerminalView
    ) {
        guard moshOverlayContentReadyId == overlay.id else { return }

        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        let settledOffsetY = overlay.desiredScrollOffsetY ?? view.contentOffset.y
        let atLiveTail = maxOffsetY > 0
            && settledOffsetY >= max(0, maxOffsetY - Self.moshScrollbackTopThreshold)

        if let capture = overlay.pendingDeferredCapture {
            overlay.pendingDeferredCapture = nil
            if !atLiveTail {
                // The apply anchors by distance-from-bottom, so it is
                // position-preserving wherever the gesture settled. Only a
                // settle AT the live tail drops it: the reader is leaving
                // scrollback, and feeding thousands of lines just to
                // dismiss would be waste. FALL THROUGH there — with
                // bounces off there is no further didScroll to re-run the
                // bottom dismissal.
                applyMoshOverlayFetchCapture(capture, to: overlay, context: "deferred-settle")
                return
            }
            overlay.pendingScrollPlacement = nil
            overlay.pendingScrollPlacementRevision += 1
            MoshDiagnostics.log(
                "mosh scrollback overlay deferred capture dropped reason=at-live-tail pane=\(overlay.paneId.description)"
            )
        }

        // A fetch's post-landing anchor hasn't applied yet — the offset is
        // transiently at the fed tail, not where the user is.
        guard overlay.pendingScrollPlacement == nil else { return }

        if atLiveTail {
            // Bottom dismissal only after genuine native motion: bridge
            // writes also arrive settled, and a gentle reveal-scroll still
            // inside the bottom threshold must not dismiss its own overlay
            // (the bridge path has its own direction-aware bottom check).
            guard overlay.sawNativeScroll else { return }
            recordMoshScrollDiagnostic(
                "surface=overlay window=\(overlay.windowId.description) pane=\(overlay.paneId.description) native-bottom-dismiss offset=\(Self.format(view.contentOffset.y)) max=\(Self.format(maxOffsetY))"
            )
            dismissMoshPaneScrollbackOverlay(clearDepth: true, reason: "native-bottom")
            scheduleMoshOverlayPrefetch(reason: "bottom-dismiss")
            return
        }

        // Settled inside scrollback with the history still shallow: deepen
        // NOW — this settle is exactly where the old page ladder sat
        // waiting for another gesture.
        maybeDeepenMoshOverlayScrollback(
            overlay: overlay,
            view: view,
            reason: "native-deepen-settle"
        )
    }

    /// Deepen the overlay's history to full parity depth
    /// (`appearance.scrollbackLines` — what a plain tmux pane holds
    /// locally) in one capture. Fires from the active-pan branch and from
    /// settle; the guards make it converge after a single successful
    /// fetch. A reply that lands mid-pan defers application until settle
    /// (see `fetchMoshPaneScrollbackOverlay`); the apply anchors by
    /// distance-from-bottom, so the reader never moves.
    private func maybeDeepenMoshOverlayScrollback(
        overlay: MoshPaneScrollbackOverlayRuntime,
        view: TerminalView,
        reason: String
    ) {
        guard moshOverlayContentReadyId == overlay.id,
              !overlay.contentFrozen,
              overlay.pendingDeferredCapture == nil,
              overlay.pendingScrollPlacement == nil,
              moshScrollbackInFlight == nil
        else { return }
        let currentDepth = moshScrollbackDepthByPane[overlay.paneId] ?? 0
        let maxDepth = max(Self.moshScrollbackPageLines, appearance.scrollbackLines)
        guard currentDepth > 0, currentDepth < maxDepth else { return }
        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        fetchMoshPaneScrollbackOverlay(
            overlay: overlay,
            paneId: overlay.paneId,
            pointsY: 0,
            currentDepth: currentDepth,
            currentMaxOffsetY: maxOffsetY,
            reason: reason
        )
    }

    /// Kick the full-depth deepen the instant scrollback reveals, instead
    /// of waiting for the reader to scroll up into the top of the initial
    /// 240-line page. The initial page exists only for instant first
    /// paint; loading the rest immediately means the complete history is
    /// present BEFORE the reader's first committed fling, so native
    /// inertia carries straight through (with bounces=false a fling into a
    /// not-yet-loaded top edge dead-stops at ~300 lines and needs a second
    /// swipe — the device-reported symptom). Still on-demand: this fires
    /// only because the reader entered scrollback, never eagerly on output.
    ///
    /// Reveal usually carries a brief post-fill `.bottomMinus` placement
    /// that gates the deepen, so retry across it (bounded). Each attempt
    /// re-checks every guard, so a dismissed/maxed/frozen overlay simply
    /// stops the chain. The deepen apply is position-preserving and the
    /// overlay sits at the live tail on reveal, so growing history above
    /// never moves the viewport.
    private func scheduleEagerMoshOverlayDeepen(
        for overlay: MoshPaneScrollbackOverlayRuntime,
        attempt: Int = 0
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.06)) {
            guard moshPaneScrollbackOverlay === overlay,
                  moshOverlayContentReadyId == overlay.id,
                  !overlay.contentFrozen,
                  let view = overlay.box.view
            else { return }
            let currentDepth = moshScrollbackDepthByPane[overlay.paneId] ?? 0
            let maxDepth = max(Self.moshScrollbackPageLines, appearance.scrollbackLines)
            // Already deep enough, or a fetch (this one or a top-reach) is
            // running — nothing left to schedule.
            guard currentDepth > 0, currentDepth < maxDepth,
                  moshScrollbackInFlight == nil
            else { return }
            if overlay.pendingScrollPlacement != nil
                || overlay.pendingDeferredCapture != nil {
                guard attempt < 6 else { return }
                scheduleEagerMoshOverlayDeepen(for: overlay, attempt: attempt + 1)
                return
            }
            maybeDeepenMoshOverlayScrollback(
                overlay: overlay,
                view: view,
                reason: "eager-reveal"
            )
        }
    }

    private func resetMoshScrollbackCapture(clearLocal: Bool, reason: String) {
        // Every caller is a boundary the parked capture can't be trusted
        // across — pane/window/layout topology, terminal resize, transport
        // or side-channel lifecycle. Un-fresh the parked runtime so the
        // follow-up prefetch actually refills it (instead of skipping on
        // the fresh guard), and bump the epoch so a prefetch reply that
        // was in flight across the boundary is dropped: geometry changes
        // bake the old wrap width into the capture, and outages swallow
        // the %output notifications that would otherwise mark it stale.
        moshOverlayContentEpoch += 1
        moshDormantScrollbackOverlay?.isFresh = false
        if moshPaneScrollbackOverlay != nil {
            dismissMoshPaneScrollbackOverlay(clearDepth: false, reason: reason)
        }
        moshScrollbackDepthByPane.removeAll(keepingCapacity: true)
        moshScrollbackInFlight = nil
        pendingMoshAltScreenScrollPointsByPane.removeAll(keepingCapacity: true)
        moshPaneInteractionProbeInFlight.removeAll(keepingCapacity: true)
        pendingMoshInteractionProbeScrollPointsByPane.removeAll(keepingCapacity: true)
        moshSplitAltScreenScrollDispatcher = Self.makeMoshSplitAltScreenScrollDispatcher()
        moshScrollbackLoading = false
        scrollDiagnostics.gateLogCount = 0
        findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)
        if clearLocal {
            terminalBox.clearScrollback(restoringLimit: appearance.scrollbackLines)
        }
        MoshDiagnostics.log("mosh scrollback reset reason=\(reason) clearLocal=\(clearLocal)")
    }

    /// Active-pane output with the reader INSIDE revealed scrollback:
    /// stay, don't dismiss (iTerm2 keeps the reader in place; getting
    /// yanked to the live tail mid-read was the complaint this replaces).
    /// The overlay freezes instead: content stays exactly as displayed,
    /// all further capture machinery is blocked, and the normal bottom
    /// return dismisses to the (updated) live pane and re-arms the hot
    /// buffer. Every other case falls back to the input invalidation.
    private func invalidateMoshScrollbackForActivePaneOutput() {
        if let overlay = moshPaneScrollbackOverlay,
           moshOverlayContentReadyId == overlay.id {
            moshOverlayContentEpoch += 1
            moshDormantScrollbackOverlay?.isFresh = false
            overlay.isFresh = false
            let alreadyFrozen = overlay.contentFrozen
            overlay.contentFrozen = true
            // Drop capture flight state: replies from here on include the
            // new output and must never clear+feed over the snapshot.
            overlay.pendingDeferredCapture = nil
            if moshScrollbackInFlight?.paneId == overlay.paneId {
                moshScrollbackInFlight = nil
                moshScrollbackLoading = false
            }
            if !alreadyFrozen {
                MoshDiagnostics.log(
                    "mosh scrollback overlay frozen reason=active-pane-output pane=\(overlay.paneId.description)"
                )
                recordMoshScrollDiagnostic(
                    "surface=overlay window=\(overlay.windowId.description) pane=\(overlay.paneId.description) content-frozen reason=active-pane-output"
                )
            }
            return
        }
        invalidateMoshScrollbackForTerminalInput(reason: "active-pane-output")
    }

    private func invalidateMoshScrollbackForTerminalInput(reason: String) {
        // Terminal input is about to change the pane's tail: whatever the
        // parked runtime holds no longer matches, and once the output
        // settles the debounced prefetch refills it.
        moshOverlayContentEpoch += 1
        moshDormantScrollbackOverlay?.isFresh = false
        scheduleMoshOverlayPrefetch(reason: reason)
        let hadOverlay = moshPaneScrollbackOverlay != nil
        let hasLocalCapture = hadOverlay
            || !moshScrollbackDepthByPane.isEmpty
            || moshScrollbackInFlight != nil
        guard hasLocalCapture else { return }
        resetMoshScrollbackCapture(clearLocal: !hadOverlay, reason: reason)
    }

    // MARK: - Hot-buffer prefetch
    //
    // The structural fix for the cold-gesture throttle (round 7): during an
    // active trackpad pan iPadOS suppresses the whole update cycle unless
    // something has recently presented, so any work still pending at
    // gesture start (view mount, capture-pane round trip) runs at the
    // throttled cadence and the pan stays frozen. The only winning move is
    // to have nothing left to do: fill the parked overlay with content
    // BEFORE the gesture, so the first scroll-up event just reveals and
    // scrolls an already-warm surface, like an SSH pane.

    private static let moshOverlayPrefetchDebounce: TimeInterval = 0.4

    /// Debounced, coalescing entry point — every trigger site (pane
    /// switch, layout change, output/input quiescing, bottom dismiss,
    /// side-channel reattach) funnels through here. Trailing-edge: a
    /// continuously-streaming pane keeps cancelling the wait and simply
    /// never goes fresh — its first scroll falls back to fetch-then-reveal.
    private func scheduleMoshOverlayPrefetch(reason: String) {
        moshOverlayPrefetchTask?.cancel()
        moshOverlayPrefetchTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.moshOverlayPrefetchDebounce * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            performMoshOverlayPrefetch(reason: reason)
        }
    }

    private func performMoshOverlayPrefetch(reason: String) {
        // Never mount or feed the hidden runtime while a pan/glide is
        // running — that's main-thread work landing inside the exact
        // window this machinery is meant to keep clear. Re-debounce past
        // the gesture instead.
        if scrollGestureActivity.isActive {
            scheduleMoshOverlayPrefetch(reason: "gesture-deferred")
            return
        }
        guard !moshOverlayPrefetchInFlight else {
            // A trigger during an in-flight capture means state moved
            // (pane switch, invalidation). Defer, don't drop: the reply
            // may resolve .skipped for the OLD pane and nothing else
            // would ever refill the new one.
            moshOverlayPrefetchDeferred = true
            return
        }
        guard session.host.launchMode != .customCommand,
              session.state == .connected,
              tmux.mode == .tmuxControl,
              let window = moshActiveWindow,
              window.rendersAsPaneGrid,
              let paneId = window.activePaneId ?? tmux.activePaneId,
              moshPaneScrollbackFrame(for: paneId) != nil,
              let paneRows = moshPaneScrollbackRows(for: paneId)
        else { return }
        // User-visible scrollback active or fetching: the gesture path owns
        // the runtime's content — a background clear+feed would teleport it.
        guard moshPaneScrollbackOverlay == nil, moshScrollbackInFlight == nil else { return }
        if let pane = window.panes.first(where: { $0.id == paneId }),
           pane.isAlternateScreen == true {
            return
        }

        let runtime: MoshPaneScrollbackOverlayRuntime
        if let dormant = moshDormantScrollbackOverlay,
           dormant.paneId == paneId,
           dormant.windowId == window.id {
            // Revealable-content check, not bare isFresh: if SwiftUI
            // replaced the mounted view since the fill, the bytes died
            // with the old view and the buffer needs refilling even
            // though nothing invalidated the content itself.
            guard !dormant.hasRevealableFreshContent else { return }
            runtime = dormant
        } else {
            // Parking the runtime mounts its SwiftTerm view hidden right
            // away (the ~140ms creation block lands here, off-gesture; the
            // opacity gate stays down — `moshOverlayContentReadyId` nil).
            runtime = MoshPaneScrollbackOverlayRuntime(paneId: paneId, windowId: window.id)
            moshDormantScrollbackOverlay = runtime
        }

        moshOverlayPrefetchInFlight = true
        moshOverlayPrefetchToken += 1
        let token = moshOverlayPrefetchToken
        let epoch = moshOverlayContentEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.moshScrollbackFetchTimeout) {
            guard moshOverlayPrefetchToken == token, moshOverlayPrefetchInFlight else { return }
            moshOverlayPrefetchInFlight = false
            MoshDiagnostics.log(
                "mosh scrollback prefetch timeout pane=\(paneId.description)"
            )
            if moshOverlayPrefetchDeferred {
                moshOverlayPrefetchDeferred = false
                scheduleMoshOverlayPrefetch(reason: "deferred-retrigger")
            }
        }
        MoshDiagnostics.log(
            "mosh scrollback prefetch begin reason=\(reason) pane=\(paneId.description) rows=\(paneRows)"
        )

        tmux.captureActivePrimaryPaneScrollbackResult(
            depth: Self.moshScrollbackPageLines,
            clientRows: paneRows
        ) { result in
            // The in-flight check drops replies that outlived the watchdog
            // (the latch is already released — a newer fill may be armed).
            guard moshOverlayPrefetchToken == token, moshOverlayPrefetchInFlight else { return }
            moshOverlayPrefetchInFlight = false
            // Re-arm a trigger that was swallowed while this capture was
            // in flight — on EVERY outcome; the rescheduled pass re-runs
            // all its own guards, so a no-longer-needed refill no-ops.
            if moshOverlayPrefetchDeferred {
                moshOverlayPrefetchDeferred = false
                scheduleMoshOverlayPrefetch(reason: "deferred-retrigger")
            }
            // Promoted mid-flight (a gesture beat the reply): the visible
            // overlay's content is the gesture path's to manage now.
            guard let dormant = moshDormantScrollbackOverlay,
                  dormant === runtime
            else {
                MoshDiagnostics.log(
                    "mosh scrollback prefetch dropped reason=runtime-moved pane=\(paneId.description)"
                )
                return
            }
            guard moshOverlayContentEpoch == epoch else {
                // Typing/output invalidated the pane while the capture was
                // in flight — these bytes predate it. Refill from now.
                MoshDiagnostics.log(
                    "mosh scrollback prefetch dropped reason=stale-epoch pane=\(paneId.description)"
                )
                scheduleMoshOverlayPrefetch(reason: "prefetch-stale-epoch")
                return
            }
            guard case .captured(let capture) = result,
                  capture.paneId == paneId,
                  !capture.repaintBytes.isEmpty
            else {
                MoshDiagnostics.log(
                    "mosh scrollback prefetch skipped pane=\(paneId.description) result=\(String(describing: result))"
                )
                return
            }

            if scrollGestureActivity.isActive {
                // Feeding ~240 captured lines into the hidden terminal is
                // a visible hitch inside a 120Hz pan. Drop this capture
                // and refill once the gesture settles.
                MoshDiagnostics.log(
                    "mosh scrollback prefetch deferred reason=gesture-active pane=\(paneId.description)"
                )
                scheduleMoshOverlayPrefetch(reason: "gesture-deferred")
                return
            }

            runtime.pendingScrollPlacement = nil
            runtime.clearDesiredScrollOffset()
            runtime.stopNativeScrollMotion()
            runtime.box.clearScrollback(restoringLimit: appearance.scrollbackLines)
            runtime.box.feed(capture.repaintBytes[...])
            runtime.freshContentViewID = runtime.box.view.map(ObjectIdentifier.init)
            runtime.capturedDepth = moshCaptureDepthCredit(capture)
            runtime.isFresh = true
            MoshDiagnostics.log(
                "mosh scrollback prefetch applied pane=\(paneId.description) depth=\(capture.requestedDepth) lines=\(capture.capturedLineCount) bytes=\(capture.repaintBytes.count)"
            )
            recordMoshScrollDiagnostic(
                "surface=overlay window=\(runtime.windowId.description) pane=\(paneId.description) prefetch-applied reason=\(reason) depth=\(capture.requestedDepth) lines=\(capture.capturedLineCount) bytes=\(capture.repaintBytes.count)"
            )
        }
    }

    private func isAutomaticTerminalColorResponse(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard !bytes.isEmpty else { return false }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.hasPrefix("\u{1B}]10;rgb:")
            || text.hasPrefix("\u{1B}]11;rgb:")
            || text.hasPrefix("\u{9D}10;rgb:")
            || text.hasPrefix("\u{9D}11;rgb:")
    }

    private func logMoshScrollbackGate(_ message: @autoclosure () -> String) {
        guard scrollDiagnostics.gateLogCount < 24 else { return }
        scrollDiagnostics.gateLogCount += 1
        MoshDiagnostics.log("mosh scrollback gate \(message())")
    }

    private func handleMoshPrimaryScrollbackDelta(
        view: TerminalView,
        pointsY: Double,
        proposedOffsetY: CGFloat,
        maxOffsetY: CGFloat,
        isInertial: Bool
    ) -> TerminalPrimaryScrollConsumption {
        guard moshActiveWindow?.rendersAsPaneGrid == true else { return .notConsumed }
        guard pointsY != 0 else { return .consumedCancelInertia }
        guard session.host.launchMode != .customCommand,
              session.state == .connected,
              tmux.mode == .tmuxControl
        else {
            return .consumedCancelInertia
        }
        guard terminalBox.view === view else { return .consumedCancelInertia }

        let terminal = view.getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return .notConsumed }

        guard let window = moshActiveWindow,
              let paneId = window.activePaneId ?? tmux.activePaneId,
              moshPaneScrollbackFrame(for: paneId) != nil
        else {
            logMoshScrollbackGate("overlay-skip reason=no-pane-frame")
            return .consumedCancelInertia
        }

        if let pane = window.panes.first(where: { $0.id == paneId }),
           pane.isAlternateScreen == true {
            // Semantic forward — never from a synthetic glide frame: the
            // remote TUI would keep receiving motion after the fingers
            // left the trackpad.
            guard !isInertial else { return .consumedCancelInertia }
            forwardMoshPaneAltScreenScroll(
                view: view,
                paneId: paneId,
                pointsY: pointsY,
                mouseReporting: pane.isMouseReporting == true,
                useSgrMouse: pane.isSgrMouse == true,
                reason: "cached-alt-screen"
            )
            return .consumedCancelInertia
        }

        guard pointsY > 0 else {
            if let overlay = moshPaneScrollbackOverlay,
               overlay.paneId == paneId,
               overlay.windowId == window.id {
                // Same passivity rule as scroll-up: a glide never scrolls
                // through a capture's in-flight/anchor window (a parked
                // deferred capture counts — its settle apply is imminent).
                if isInertial,
                   overlay.pendingScrollPlacement != nil
                    || overlay.pendingDeferredCapture != nil
                    || moshScrollbackInFlight != nil {
                    return .consumedCancelInertia
                }
                scrollMoshPaneScrollbackOverlay(
                    overlay,
                    pointsY: pointsY,
                    isInertial: isInertial
                )
                // If this reached the live bottom the overlay was just
                // dismissed — the next glide frame finds no overlay and
                // stops there. Local motion either way.
                return .consumedLocalScroll
            }
            // No overlay: at the live screen already. The interaction
            // probe can end in a semantic alt-screen forward, so glide
            // frames must not fire it (or scroll further down).
            guard !isInertial else { return .consumedCancelInertia }
            logMoshScrollbackGate(
                "overlay-skip reason=no-overlay-scroll-down-probe pane=\(paneId.description) pointsY=\(String(format: "%.2f", pointsY))"
            )
            probeMoshPaneInteractionForAltScreenScroll(
                view: view,
                paneId: paneId,
                pointsY: pointsY,
                reason: "no-overlay-scroll-down"
            )
            return .consumedCancelInertia
        }

        // Scroll-up. A glide is strictly PASSIVE on the overlay: it may
        // scroll content that is already loaded and laid out, but it never
        // creates an overlay, never fetches, and yields the moment a
        // capture is in flight or its post-landing anchor hasn't applied
        // yet. Glide frames run at display rate straight through a
        // capture's clear+feed+layout window — letting them fetch or
        // scroll during that window chained clear/feed cycles (a black
        // pane for the whole glide) and pinned the rebase target to the
        // top. The gesture already prefetched; when the glide exhausts
        // loaded content it stops and the next flick goes deeper.
        if isInertial {
            guard let overlay = moshPaneScrollbackOverlay,
                  overlay.paneId == paneId,
                  overlay.windowId == window.id,
                  overlay.pendingScrollPlacement == nil,
                  overlay.pendingDeferredCapture == nil,
                  moshScrollbackInFlight == nil
            else { return .consumedCancelInertia }
            let beforeY = overlay.desiredScrollOffsetY
                ?? overlay.box.view?.contentOffset.y
                ?? 0
            let scrollState = scrollMoshPaneScrollbackOverlay(
                overlay,
                pointsY: pointsY,
                isInertial: true
            )
            let moved = scrollState.map { abs($0.offsetY - beforeY) > 0.1 } ?? false
            return moved ? .consumedLocalScroll : .consumedCancelInertia
        }

        let overlay = ensureMoshPaneScrollbackOverlay(paneId: paneId, windowId: window.id)
        let scrollState = scrollMoshPaneScrollbackOverlay(overlay, pointsY: pointsY)
        let currentDepth = moshScrollbackDepthByPane[paneId] ?? 0
        let overlayOffsetY = scrollState?.offsetY
            ?? overlay.desiredScrollOffsetY
            ?? overlay.box.view?.contentOffset.y
            ?? 0
        let overlayMaxOffsetY = scrollState?.maxOffsetY
            ?? overlay.box.view.map { max(0, $0.contentSize.height - $0.bounds.height) }
            ?? maxOffsetY
        let isAtTop = currentDepth == 0
            || overlayOffsetY <= Self.moshScrollbackTopThreshold
            || overlayMaxOffsetY <= Self.moshScrollbackTopThreshold
        guard currentDepth == 0 || isAtTop else {
            return .consumedLocalScroll
        }

        fetchMoshPaneScrollbackOverlay(
            overlay: overlay,
            paneId: paneId,
            pointsY: pointsY,
            currentDepth: currentDepth,
            currentMaxOffsetY: overlayMaxOffsetY,
            reason: "scroll"
        )
        return .consumedLocalScroll
    }

    private func probeMoshPaneInteractionForAltScreenScroll(
        view: TerminalView,
        paneId: PaneId,
        pointsY: Double,
        reason: String
    ) {
        guard pointsY != 0 else { return }
        guard !moshPaneInteractionProbeInFlight.contains(paneId) else {
            pendingMoshInteractionProbeScrollPointsByPane[paneId, default: 0] += pointsY
            logMoshScrollbackGate(
                "overlay-skip reason=interaction-probe-in-flight pane=\(paneId.description) pointsY=\(String(format: "%.2f", pointsY))"
            )
            return
        }

        moshPaneInteractionProbeInFlight.insert(paneId)
        MoshDiagnostics.log(
            "mosh scrollback interaction probe begin reason=\(reason) pane=\(paneId.description) pointsY=\(String(format: "%.2f", pointsY))"
        )
        tmux.queryActivePaneInteractionState { state in
            moshPaneInteractionProbeInFlight.remove(paneId)
            let pendingPoints =
                pendingMoshInteractionProbeScrollPointsByPane.removeValue(forKey: paneId) ?? 0
            let totalPoints = pointsY + pendingPoints
            guard let state, state.paneId == paneId else {
                MoshDiagnostics.log(
                    "mosh scrollback interaction probe skipped pane=\(paneId.description) reason=no-state pointsY=\(String(format: "%.2f", totalPoints))"
                )
                return
            }

            guard state.isAlternateScreen else {
                MoshDiagnostics.log(
                    "mosh scrollback interaction probe primary pane=\(paneId.description) pointsY=\(String(format: "%.2f", totalPoints))"
                )
                return
            }

            forwardMoshPaneAltScreenScroll(
                view: view,
                paneId: paneId,
                pointsY: totalPoints,
                mouseReporting: state.isMouseReporting,
                useSgrMouse: state.isSgrMouse,
                reason: "interaction-probe"
            )
        }
    }

    /// Shared config for the split-grid alt-screen dispatcher (initial
    /// @State value + capture-state reset must stay identical). The
    /// thresholds are tuned for the scroll PROXY's smooth 120Hz delta
    /// stream — the old 1pt/3pt values compensated for throttled 24-40ms
    /// bridge events and would flood the pty (up to ~960 arrow keys/s)
    /// now that deltas arrive per display frame.
    private static func makeMoshSplitAltScreenScrollDispatcher() -> ScrollDispatcher {
        ScrollDispatcher(config: .init(
            pointsPerArrowKey: 8,
            mouseWheelThresholdPoints: 6,
            maxEventsPerFlush: 8
        ))
    }

    /// Where (and whether) the alt-screen scroll proxy mounts: over the
    /// active pane of a mosh+tmux grid whose cached interaction state says
    /// alt-screen. The proxy gives a trackpad pan a local UIScrollView to
    /// move from event 1 — without it iPadOS throttles the whole update
    /// cycle during the pan (round-7 finding) and semantic forwards run at
    /// ~1 wheel notch per 350ms. Cache-miss panes (state not yet probed)
    /// keep riding the bridge path, whose interaction probe warms the
    /// cache and mounts the proxy for the next gesture.
    private var moshAltScreenScrollProxyTarget: (paneId: PaneId, frame: CGRect)? {
        guard session.host.launchMode != .customCommand,
              session.state == .connected,
              tmux.mode == .tmuxControl,
              // Never mount over REVEALED scrollback: a pane can flip to
              // alt-screen while the reader sits in a frozen snapshot
              // (output opened less/vim mid-read). The proxy on top would
              // swallow every scroll, starve the overlay's bottom
              // dismissal, and silently drive the hidden TUI — the reader
              // scrolls out of the snapshot first, then the proxy mounts.
              moshOverlayContentReadyId == nil,
              let window = moshActiveWindow,
              window.rendersAsPaneGrid,
              let paneId = window.activePaneId ?? tmux.activePaneId,
              let pane = window.panes.first(where: { $0.id == paneId }),
              pane.isAlternateScreen == true,
              let frame = moshPaneScrollbackFrame(for: paneId)
        else { return nil }
        return (paneId, frame.surfaceFrame)
    }

    /// Tracked motion from the alt-screen scroll proxy → semantic forward.
    /// Same encoder as the bridge path (wheel or arrows via the split
    /// dispatcher); the proxy only forwards while fingers are on the pad,
    /// so the no-motion-after-release policy holds without an isInertial
    /// check here.
    private func handleMoshAltScreenProxyScroll(paneId: PaneId, pointsY: Double) {
        // The proxy normally unmounts as soon as the lifecycle gate turns on.
        // Revalidate here as well so a delta already queued by UIKit at that
        // transition cannot leak a wheel/arrow event into the remote TUI.
        if agentScrollPrevention(paneID: paneId.rawValue) != nil {
            presentAgentScrollPrevention(paneID: paneId.rawValue)
            return
        }
        guard session.host.launchMode != .customCommand,
              session.state == .connected,
              tmux.mode == .tmuxControl,
              let window = moshActiveWindow,
              let pane = window.panes.first(where: { $0.id == paneId }),
              pane.isAlternateScreen == true,
              let view = terminalBox.view
        else { return }
        forwardMoshPaneAltScreenScroll(
            view: view,
            paneId: paneId,
            pointsY: pointsY,
            mouseReporting: pane.isMouseReporting == true,
            useSgrMouse: pane.isSgrMouse == true,
            reason: "alt-proxy"
        )
    }

    private func forwardMoshPaneAltScreenScroll(
        view: TerminalView,
        paneId: PaneId,
        pointsY: Double,
        mouseReporting: Bool,
        useSgrMouse: Bool,
        reason: String
    ) {
        guard pointsY != 0 else { return }
        let target = moshPaneAltScreenScrollTarget(paneId: paneId, in: view)
        let state = ScrollDispatcher.TerminalState(
            isAltScreen: true,
            mouseReporting: mouseReporting ? .vt200OrLater : .off
        )
        var dispatcher = moshSplitAltScreenScrollDispatcher
        let actions = dispatcher.handle(
            event: .init(
                deltaY: pointsY,
                cursorColumn: target.column,
                cursorRow: target.row,
                phase: .changed
            ),
            terminal: state
        )
        moshSplitAltScreenScrollDispatcher = dispatcher
        var forwardedCount = 0
        let terminal = view.getTerminal()
        for action in actions {
            switch action {
            case .scrollbackDelta:
                break
            case .mouseWheel(let buttonFlags, let cursorColumn, let cursorRow, let repeatCount):
                forwardedCount += repeatCount
                for _ in 0..<repeatCount {
                    if useSgrMouse {
                        sendMoshSgrMouseEvent(
                            buttonFlags: buttonFlags,
                            column: cursorColumn,
                            row: cursorRow
                        )
                    } else {
                        terminal.sendEvent(
                            buttonFlags: buttonFlags,
                            x: max(0, cursorColumn - 1),
                            y: max(0, cursorRow - 1)
                        )
                    }
                }
            case .writeBytes(let bytes):
                forwardedCount += bytes.count / 3
                session.send(bytes)
            }
        }
        let shouldLog: Bool
        if reason == "alt-proxy" {
            // Proxy deltas arrive per display frame — sample the log so a
            // scroll session doesn't wipe the diagnostics ring buffer.
            scrollDiagnostics.altProxyEventCount += 1
            shouldLog = forwardedCount > 0
                && scrollDiagnostics.altProxyEventCount % 30 == 1
        } else {
            shouldLog = true
        }
        if shouldLog {
            MoshDiagnostics.log(
                "mosh scrollback forward alt-screen scroll reason=\(reason) pane=\(paneId.description) pointsY=\(String(format: "%.2f", pointsY)) mouse=\(mouseReporting) sgr=\(useSgrMouse) forwarded=\(forwardedCount) column=\(target.column) row=\(target.row)"
            )
        }
    }

    private func moshPaneAltScreenScrollTarget(
        paneId: PaneId,
        in view: TerminalView
    ) -> (column: Int, row: Int) {
        let terminal = view.getTerminal()
        guard let rect = moshPaneScrollbackContentRect(for: paneId) else {
            return (
                column: max(1, (terminal.cols + 1) / 2),
                row: max(1, (terminal.rows + 1) / 2)
            )
        }
        let column = rect.x + max(0, rect.width / 2) + 1
        let row = rect.y + max(0, rect.height / 2) + 1
        return (
            column: max(1, min(terminal.cols, column)),
            row: max(1, min(terminal.rows, row))
        )
    }

    private func sendMoshSgrMouseEvent(buttonFlags: Int, column: Int, row: Int) {
        let sequence = "\u{1B}[<\(buttonFlags);\(column);\(row)M"
        session.send(Array(sequence.utf8))
    }

    @discardableResult
    private func scrollMoshPaneScrollbackOverlay(
        _ overlay: MoshPaneScrollbackOverlayRuntime,
        pointsY: Double,
        isInertial: Bool = false
    ) -> (offsetY: CGFloat, maxOffsetY: CGFloat)? {
        guard let view = overlay.box.view else { return nil }
        if view.isTracking || view.isDragging || view.isDecelerating {
            // A native pan/deceleration owns this view's contentOffset —
            // bridge and glide writers yield rather than fight it (an
            // inertial caller reads the nil as "didn't move" and cancels).
            return nil
        }
        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        // Only a REAL gesture may override a pending post-capture placement.
        // A glide synthesizes frames straight through the capture landing —
        // if those cleared the placement, the offset rebase would silently
        // skip and the view would teleport to the fed tail instead of the
        // .top/.bottomMinus anchor.
        if maxOffsetY > 0, overlay.pendingScrollPlacement != nil, !isInertial {
            overlay.pendingScrollPlacement = nil
            overlay.pendingScrollPlacementRevision += 1
        }
        let currentY = overlay.desiredScrollOffsetY ?? view.contentOffset.y
        let newY = currentY - CGFloat(pointsY) * 3
        let offsetY = overlay.applyDesiredScrollOffset(newY, in: view)
        recordMoshScrollDiagnostic(
            "surface=overlay window=\(overlay.windowId.description) pane=\(overlay.paneId.description) primary-write points=\(String(format: "%.1f", pointsY)) before=\(Self.format(currentY)) proposed=\(Self.format(newY)) after=\(Self.format(offsetY)) max=\(Self.format(maxOffsetY)) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height))"
        )

        if pointsY < 0,
           offsetY >= max(0, maxOffsetY - Self.moshScrollbackTopThreshold) {
            dismissMoshPaneScrollbackOverlay(clearDepth: true, reason: "bottom")
            // Back at the live tail — refill the parked runtime so the
            // next scroll-up reveals instantly again.
            scheduleMoshOverlayPrefetch(reason: "bottom-dismiss")
        }

        return (offsetY, maxOffsetY)
    }

    /// Latch the in-flight marker for a capture-pane fetch and arm its
    /// watchdog. Every site that sets `moshScrollbackInFlight` for a
    /// remote capture goes through here: if the reply never comes back
    /// (side-channel stream died mid-flight), the latch is released so
    /// the next gesture can refetch instead of scrolling a dead pane.
    private func armMoshScrollbackFetch(
        paneId: PaneId,
        depth: Int,
        context: String,
        showsLoading: Bool = true
    ) {
        moshScrollbackInFlight = (paneId: paneId, depth: depth)
        // Background deepens (content already on screen, position-preserving
        // apply) skip the spinner — plain tmux shows nothing there either.
        if showsLoading { moshScrollbackLoading = true }
        moshScrollbackFetchToken += 1
        let token = moshScrollbackFetchToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.moshScrollbackFetchTimeout) {
            guard moshScrollbackFetchToken == token,
                  moshScrollbackInFlight?.paneId == paneId,
                  moshScrollbackInFlight?.depth == depth
            else { return }
            moshScrollbackInFlight = nil
            moshScrollbackLoading = false
            if let overlay = moshPaneScrollbackOverlay, overlay.paneId == paneId {
                overlay.pendingScrollPlacement = nil
            }
            MoshDiagnostics.log(
                "mosh scrollback fetch timeout context=\(context) pane=\(paneId.description) depth=\(depth)"
            )
            recordMoshScrollDiagnostic(
                "surface=overlay pane=\(paneId.description) fetch-timeout context=\(context) depth=\(depth)"
            )
        }
    }

    private func fetchMoshPaneScrollbackOverlay(
        overlay: MoshPaneScrollbackOverlayRuntime,
        paneId: PaneId,
        pointsY: Double,
        currentDepth: Int,
        currentMaxOffsetY: CGFloat,
        reason: String
    ) {
        guard !overlay.contentFrozen else {
            logMoshScrollbackGate(
                "overlay-skip reason=content-frozen pane=\(paneId.description) fetchReason=\(reason)"
            )
            return
        }
        let maxDepth = max(Self.moshScrollbackPageLines, appearance.scrollbackLines)
        guard currentDepth < maxDepth else {
            logMoshScrollbackGate(
                "overlay-skip reason=max-depth pane=\(paneId.description) depth=\(currentDepth) maxDepth=\(maxDepth)"
            )
            return
        }

        // Initial fill stays one small page — it's the fetch-then-reveal
        // cold path and the reader is waiting on it. Any deepen goes
        // straight to full parity depth (`scrollbackLines`, what a plain
        // tmux pane holds locally) in ONE capture: the find-seed path
        // already does full-depth captures, and a 240-line page ladder
        // needs a gesture+spinner per page to walk 10k lines of history.
        let targetDepth = currentDepth > 0
            ? maxDepth
            : min(maxDepth, Self.moshScrollbackPageLines)
        if let inFlight = moshScrollbackInFlight,
           inFlight.paneId == paneId,
           inFlight.depth >= targetDepth {
            pendingMoshAltScreenScrollPointsByPane[paneId, default: 0] += pointsY
            logMoshScrollbackGate(
                "overlay-skip reason=in-flight pane=\(paneId.description) targetDepth=\(targetDepth) inFlightDepth=\(inFlight.depth)"
            )
            return
        }
        guard let paneRows = moshPaneScrollbackRows(for: paneId) else {
            logMoshScrollbackGate("overlay-skip reason=no-pane-rows pane=\(paneId.description)")
            return
        }

        if currentDepth == 0 {
            // First fill: content lands at the tail and the triggering
            // scroll carries it up from there.
            overlay.setPendingScrollPlacement(.bottomMinus(CGFloat(pointsY) * 3))
        }
        // Deepen fetches set NO placement here: the apply computes a
        // distance-from-bottom anchor at apply time (fetch time can't know
        // where the reader will be when the capture lands), and a nil
        // placement leaves the settle-time bottom dismissal free to run if
        // the reader bails to the live tail mid-flight.
        armMoshScrollbackFetch(
            paneId: paneId,
            depth: targetDepth,
            context: "overlay-scroll",
            showsLoading: currentDepth == 0
        )
        MoshDiagnostics.log(
            "mosh scrollback overlay fetch begin reason=\(reason) pane=\(paneId.description) depth=\(targetDepth) rows=\(paneRows) currentDepth=\(currentDepth) maxOffset=\(String(format: "%.1f", currentMaxOffsetY))"
        )
        recordMoshScrollDiagnostic(
            "surface=overlay window=\(overlay.windowId.description) pane=\(paneId.description) fetch-begin reason=\(reason) depth=\(targetDepth) rows=\(paneRows) currentDepth=\(currentDepth) max=\(Self.format(currentMaxOffsetY))"
        )

        tmux.captureActivePrimaryPaneScrollbackResult(
            depth: targetDepth,
            clientRows: paneRows
        ) { result in
            guard let currentOverlay = moshPaneScrollbackOverlay,
                  currentOverlay === overlay,
                  moshScrollbackInFlight?.paneId == paneId,
                  moshScrollbackInFlight?.depth == targetDepth
            else {
                recordMoshScrollDiagnostic(
                    "surface=overlay pane=\(paneId.description) fetch-reply-dropped context=overlay-scroll depth=\(targetDepth) overlayMatch=\(moshPaneScrollbackOverlay === overlay) inFlight=\(moshScrollbackInFlight.map { "\($0.paneId.description)/\($0.depth)" } ?? "nil")"
                )
                return
            }

            moshScrollbackInFlight = nil
            moshScrollbackLoading = false
            let pendingAltScreenPoints =
                pendingMoshAltScreenScrollPointsByPane.removeValue(forKey: paneId) ?? 0

            guard case .captured(let capture) = result else {
                recordMoshScrollDiagnostic(
                    "surface=overlay pane=\(paneId.description) fetch-skipped context=overlay-scroll depth=\(targetDepth) result=\(String(describing: result))"
                )
                if case .skipped(.alternateScreen) = result {
                    MoshDiagnostics.log(
                        "mosh scrollback overlay fetch skipped alt-screen pane=\(paneId.description)"
                    )
                    dismissMoshPaneScrollbackOverlay(clearDepth: true, reason: "alt-screen")
                    if let view = terminalBox.view {
                        let pane = moshActiveWindow?.panes.first { $0.id == paneId }
                        forwardMoshPaneAltScreenScroll(
                            view: view,
                            paneId: paneId,
                            pointsY: pointsY + pendingAltScreenPoints,
                            mouseReporting: pane?.isMouseReporting == true,
                            useSgrMouse: pane?.isSgrMouse == true,
                            reason: "capture-alt-screen"
                        )
                    }
                } else {
                    MoshDiagnostics.log(
                        "mosh scrollback overlay fetch skipped pane=\(paneId.description) result=\(String(describing: result))"
                    )
                    dismissMoshPaneScrollbackOverlay(clearDepth: true, reason: "capture-skipped")
                }
                return
            }

            guard capture.paneId == paneId, !capture.repaintBytes.isEmpty else {
                MoshDiagnostics.log(
                    "mosh scrollback overlay fetch empty pane=\(paneId.description) depth=\(targetDepth)"
                )
                recordMoshScrollDiagnostic(
                    "surface=overlay pane=\(paneId.description) fetch-skipped context=overlay-scroll depth=\(targetDepth) result=empty-capture capturedPane=\(capture.paneId.description)"
                )
                dismissMoshPaneScrollbackOverlay(clearDepth: true, reason: "empty-capture")
                return
            }

            if moshOverlayContentReadyId == overlay.id,
               let view = overlay.box.view,
               view.isTracking || view.isDragging || view.isDecelerating {
                // A native pan/deceleration is mid-flight on the REVEALED
                // overlay — clear+feed now would teleport the finger. Park
                // the capture; the settle poll applies (or drops) it once
                // the scroll stops. A hidden overlay never defers: the
                // settle poll's resolve can't touch it (contentReadyId
                // gate), so a parked capture there would strand — and its
                // ghost motion was already halted at park/promote anyway.
                overlay.pendingDeferredCapture = capture
                MoshDiagnostics.log(
                    "mosh scrollback overlay fetch deferred reason=native-scroll pane=\(paneId.description) depth=\(capture.requestedDepth)"
                )
                armMoshOverlayNativeSettleCheck(for: overlay)
                return
            }
            applyMoshOverlayFetchCapture(capture, to: overlay, context: "fetch-reply")
        }
    }

    /// Depth to credit a landed capture with. When the pane's entire
    /// history already fit inside the request, credit full parity depth so
    /// the deepen machinery doesn't burn a round trip (re)discovering that
    /// nothing deeper exists. Safe to latch for the scrollback session:
    /// history only grows with output, and output invalidates the capture.
    private func moshCaptureDepthCredit(_ capture: TmuxController.ScrollbackCapture) -> Int {
        let maxDepth = max(Self.moshScrollbackPageLines, appearance.scrollbackLines)
        if let historySize = capture.historySize, historySize <= capture.requestedDepth {
            return maxDepth
        }
        return capture.requestedDepth
    }

    /// Feed a landed capture into the overlay and anchor it — shared by
    /// the immediate fetch-reply path and the deferred settle path.
    private func applyMoshOverlayFetchCapture(
        _ capture: TmuxController.ScrollbackCapture,
        to overlay: MoshPaneScrollbackOverlayRuntime,
        context: String
    ) {
        let paneId = overlay.paneId
        // A deepen apply must not move the reader: anchor by distance-from-
        // bottom measured NOW — the fetch can't know where the user will be
        // when the capture lands. Content below the anchor is identical
        // bytes (output invalidates in-flight captures), so the same rows
        // stay on screen while history extends above.
        if moshOverlayContentReadyId == overlay.id, let view = overlay.box.view {
            let oldMaxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            if oldMaxOffsetY > 0 {
                let offsetY = min(
                    max(0, overlay.desiredScrollOffsetY ?? view.contentOffset.y),
                    oldMaxOffsetY
                )
                overlay.setPendingScrollPlacement(.bottomMinus(oldMaxOffsetY - offsetY))
            }
        }
        // A parked capture must never survive a fresh apply: it predates
        // this content, and a later settle would re-feed it over the top.
        overlay.pendingDeferredCapture = nil
        overlay.stopNativeScrollMotion()
        overlay.clearDesiredScrollOffset()
        overlay.box.clearScrollback(restoringLimit: appearance.scrollbackLines)
        overlay.box.feed(capture.repaintBytes[...])
        moshScrollbackDepthByPane[paneId] = max(
            moshScrollbackDepthByPane[paneId] ?? 0,
            moshCaptureDepthCredit(capture)
        )
        // First content for this overlay instance — mount its surface
        // (until now the live pane stayed visible underneath).
        moshOverlayContentReadyId = overlay.id
        applyPendingMoshPaneScrollbackOverlayOffset()
        if findController.isOpen {
            findController.handlers = TerminalSearchAdapter.handlers(for: overlay.box)
            findController.updateSearch()
        }
        MoshDiagnostics.log(
            "mosh scrollback overlay fetch applied context=\(context) pane=\(paneId.description) depth=\(capture.requestedDepth) lines=\(capture.capturedLineCount) bytes=\(capture.repaintBytes.count)"
        )
        recordMoshScrollDiagnostic(
            "surface=overlay window=\(overlay.windowId.description) pane=\(paneId.description) fetch-applied context=\(context) depth=\(capture.requestedDepth) lines=\(capture.capturedLineCount) bytes=\(capture.repaintBytes.count) position=\(describeScrollPosition(for: overlay.box.view))"
        )
        // Cold fetch-then-reveal lands only the initial 240-line page;
        // chain the eager full-depth deepen so it's loaded before the
        // first committed fling (a no-op on a deepen apply — depth is
        // already maxed, and the guard inside stops there).
        scheduleEagerMoshOverlayDeepen(for: overlay)
    }

    private func handleMoshPrimaryScrollbackUnderflow(
        view: TerminalView,
        pointsY: Double,
        proposedOffsetY: CGFloat,
        maxOffsetY: CGFloat
    ) {
        guard pointsY > 0 else { return }
        guard session.host.launchMode != .customCommand else {
            logMoshScrollbackGate("skip reason=custom-command")
            return
        }
        guard session.state == .connected else {
            logMoshScrollbackGate("skip reason=session-not-connected state=\(MoshDiagnostics.stateDescription(session.state))")
            return
        }
        guard tmux.mode == .tmuxControl else {
            logMoshScrollbackGate("skip reason=tmux-not-ready mode=\(tmux.mode)")
            return
        }
        guard let paneId = tmux.activePaneId else {
            logMoshScrollbackGate("skip reason=no-active-pane")
            return
        }
        guard moshActiveWindow?.rendersAsPaneGrid != true else {
            logMoshScrollbackGate("skip reason=pane-grid pane=\(paneId.description)")
            return
        }
        guard terminalBox.view === view else {
            logMoshScrollbackGate("skip reason=view-mismatch")
            return
        }

        let terminal = view.getTerminal()
        guard !terminal.isCurrentBufferAlternate else {
            logMoshScrollbackGate("skip reason=alt-screen pane=\(paneId.description)")
            return
        }
        guard terminal.mouseMode == .off else {
            logMoshScrollbackGate("skip reason=mouse-mode pane=\(paneId.description) mode=\(terminal.mouseMode)")
            return
        }

        let currentDepth = moshScrollbackDepthByPane[paneId] ?? 0
        let isAtTop = view.contentOffset.y <= Self.moshScrollbackTopThreshold
            || proposedOffsetY <= Self.moshScrollbackTopThreshold
            || maxOffsetY <= Self.moshScrollbackTopThreshold
        guard currentDepth == 0 || isAtTop else {
            logMoshScrollbackGate(
                "skip reason=not-at-top pane=\(paneId.description) depth=\(currentDepth) offset=\(String(format: "%.1f", view.contentOffset.y)) proposed=\(String(format: "%.1f", proposedOffsetY)) max=\(String(format: "%.1f", maxOffsetY))"
            )
            return
        }

        let maxDepth = max(Self.moshScrollbackPageLines, appearance.scrollbackLines)
        guard currentDepth < maxDepth else {
            logMoshScrollbackGate(
                "skip reason=max-depth pane=\(paneId.description) depth=\(currentDepth) maxDepth=\(maxDepth)"
            )
            return
        }

        // Same one-shot deepen as the overlay path: first fill is one fast
        // page, any deepen jumps straight to full parity depth so the
        // reader never walks a page ladder (deltas keep flowing while they
        // scroll against the top, so the single deepen fires without a new
        // gesture).
        let isDeepen = currentDepth > 0
        let targetDepth = isDeepen
            ? maxDepth
            : min(maxDepth, Self.moshScrollbackPageLines)
        if let inFlight = moshScrollbackInFlight,
           inFlight.paneId == paneId,
           inFlight.depth >= targetDepth {
            logMoshScrollbackGate(
                "skip reason=in-flight pane=\(paneId.description) targetDepth=\(targetDepth) inFlightDepth=\(inFlight.depth)"
            )
            return
        }

        let pendingScrollPoints = CGFloat(pointsY) * 3
        armMoshScrollbackFetch(
            paneId: paneId,
            depth: targetDepth,
            context: "primary-underflow",
            showsLoading: !isDeepen
        )
        MoshDiagnostics.log(
            "mosh scrollback fetch begin pane=\(paneId.description) depth=\(targetDepth) currentDepth=\(currentDepth) maxOffset=\(String(format: "%.1f", maxOffsetY)) proposed=\(String(format: "%.1f", proposedOffsetY))"
        )

        tmux.captureActivePrimaryPaneScrollback(depth: targetDepth) { capture in
            guard terminalBox.view === view,
                  moshScrollbackInFlight?.paneId == paneId,
                  moshScrollbackInFlight?.depth == targetDepth
            else {
                recordMoshScrollDiagnostic(
                    "surface=shared pane=\(paneId.description) fetch-reply-dropped context=primary-underflow depth=\(targetDepth) viewMatch=\(terminalBox.view === view) inFlight=\(moshScrollbackInFlight.map { "\($0.paneId.description)/\($0.depth)" } ?? "nil")"
                )
                return
            }

            moshScrollbackInFlight = nil
            moshScrollbackLoading = false

            guard let capture, capture.paneId == paneId, !capture.repaintBytes.isEmpty else {
                MoshDiagnostics.log(
                    "mosh scrollback fetch empty pane=\(paneId.description) depth=\(targetDepth)"
                )
                return
            }

            // Measured BEFORE the clear+feed: the deepen apply anchors by
            // distance-from-bottom so the same rows stay on screen while
            // history extends above (content below the anchor is identical
            // bytes — output invalidates in-flight captures).
            let oldMaxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            let oldOffsetY = min(max(0, view.contentOffset.y), oldMaxOffsetY)
            terminalBox.clearScrollback(restoringLimit: appearance.scrollbackLines)
            terminalBox.feed(capture.repaintBytes[...])
            moshScrollbackDepthByPane[paneId] = max(
                moshScrollbackDepthByPane[paneId] ?? 0,
                moshCaptureDepthCredit(capture)
            )

            let immediateMaxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            DispatchQueue.main.async {
                guard terminalBox.view === view else { return }
                let newMaxOffsetY = max(0, view.contentSize.height - view.bounds.height)
                let targetY: CGFloat
                if isDeepen {
                    // Position-preserving, minus the triggering delta so
                    // the scroll keeps moving instead of pinning again.
                    targetY = max(
                        0,
                        newMaxOffsetY - (oldMaxOffsetY - oldOffsetY) - pendingScrollPoints
                    )
                } else {
                    targetY = max(0, newMaxOffsetY - pendingScrollPoints)
                }
                view.contentOffset = CGPoint(
                    x: view.contentOffset.x,
                    y: min(max(0, targetY), newMaxOffsetY)
                )
                MoshDiagnostics.log(
                    "mosh scrollback fetch applied pane=\(paneId.description) depth=\(capture.requestedDepth) lines=\(capture.capturedLineCount) bytes=\(capture.repaintBytes.count) immediateMaxOffset=\(String(format: "%.1f", immediateMaxOffsetY)) newMaxOffset=\(String(format: "%.1f", newMaxOffsetY)) targetY=\(String(format: "%.1f", targetY)) contentHeight=\(String(format: "%.1f", view.contentSize.height)) boundsHeight=\(String(format: "%.1f", view.bounds.height))"
                )
            }
            if findController.isOpen {
                findController.updateSearch()
            }
        }
    }

    private func seedMoshFindScrollbackIfNeeded(reason: String, retryAttempt: Int = 0) {
        guard findController.isOpen,
              session.host.launchMode != .customCommand,
              session.state == .connected,
              tmux.mode == .tmuxControl,
              let paneId = tmux.activePaneId,
              let view = terminalBox.view
        else { return }

        let terminal = view.getTerminal()
        guard !terminal.isCurrentBufferAlternate,
              terminal.mouseMode == .off
        else {
            logMoshScrollbackGate(
                "find-skip reason=terminal-mode pane=\(paneId.description) alt=\(terminal.isCurrentBufferAlternate) mouseMode=\(terminal.mouseMode)"
            )
            return
        }

        let targetDepth = max(Self.moshScrollbackPageLines, appearance.scrollbackLines)

        if let window = moshActiveWindow, window.rendersAsPaneGrid {
            guard moshPaneScrollbackFrame(for: paneId) != nil else {
                logMoshScrollbackGate("find-skip reason=no-pane-frame pane=\(paneId.description)")
                return
            }
            let overlay = ensureMoshPaneScrollbackOverlay(paneId: paneId, windowId: window.id)
            findController.handlers = TerminalSearchAdapter.handlers(for: overlay.box)
            guard !overlay.contentFrozen else {
                // Output froze this snapshot mid-read: a full-depth seed
                // would clear+feed post-output content and teleport the
                // reader. Find searches what's loaded; a bottom return
                // re-syncs and the next open seeds fully.
                MoshDiagnostics.log(
                    "mosh scrollback overlay find seed skipped reason=content-frozen pane=\(paneId.description)"
                )
                findController.updateSearch()
                return
            }
            let currentDepth = moshScrollbackDepthByPane[paneId] ?? 0
            guard currentDepth < targetDepth else {
                MoshDiagnostics.log(
                    "mosh scrollback overlay find seed skipped reason=already-seeded pane=\(paneId.description) depth=\(currentDepth) targetDepth=\(targetDepth)"
                )
                findController.updateSearch()
                return
            }
            if overlay.pendingDeferredCapture != nil
                || overlay.box.view.map({ $0.isTracking || $0.isDragging || $0.isDecelerating }) == true {
                // A native scroll (or its parked top-reach capture) owns
                // the overlay right now — the seed's full-depth clear+feed
                // would teleport the finger. Retry once it settles; the
                // entry guards (find open, connected, control mode) stop
                // the retry chain if the user moves on. Bounded like the
                // native settle poll: a wedged scroll-view state must not
                // re-arm forever (~6s is ample to wait out a live gesture).
                guard retryAttempt < 40 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    seedMoshFindScrollbackIfNeeded(reason: reason, retryAttempt: retryAttempt + 1)
                }
                return
            }
            if let inFlight = moshScrollbackInFlight,
               inFlight.paneId == paneId,
               inFlight.depth >= targetDepth {
                logMoshScrollbackGate(
                    "find-skip reason=overlay-in-flight pane=\(paneId.description) targetDepth=\(targetDepth) inFlightDepth=\(inFlight.depth)"
                )
                return
            }
            guard let paneRows = moshPaneScrollbackRows(for: paneId) else {
                logMoshScrollbackGate("find-skip reason=no-pane-rows pane=\(paneId.description)")
                return
            }

            armMoshScrollbackFetch(paneId: paneId, depth: targetDepth, context: "overlay-find-seed")
            MoshDiagnostics.log(
                "mosh scrollback overlay find seed begin reason=\(reason) pane=\(paneId.description) depth=\(targetDepth) rows=\(paneRows) currentDepth=\(currentDepth)"
            )

            tmux.captureActivePrimaryPaneScrollback(
                depth: targetDepth,
                clientRows: paneRows
            ) { capture in
                guard let currentOverlay = moshPaneScrollbackOverlay,
                      currentOverlay === overlay,
                      moshScrollbackInFlight?.paneId == paneId,
                      moshScrollbackInFlight?.depth == targetDepth
                else { return }

                moshScrollbackInFlight = nil
                moshScrollbackLoading = false

                guard let capture, capture.paneId == paneId, !capture.repaintBytes.isEmpty else {
                    MoshDiagnostics.log(
                        "mosh scrollback overlay find seed empty pane=\(paneId.description) depth=\(targetDepth)"
                    )
                    dismissMoshPaneScrollbackOverlay(clearDepth: true, reason: "find-empty-capture")
                    findController.updateSearch()
                    return
                }

                if moshOverlayContentReadyId == overlay.id,
                   let view = overlay.box.view,
                   view.isTracking || view.isDragging || view.isDecelerating {
                    // A native pan started during the seed's round trip —
                    // clear+feed now would teleport the finger (the pre-arm
                    // gate only covers the send side). Park it; the settle
                    // poll applies it position-preserved and rebinds find.
                    overlay.pendingDeferredCapture = capture
                    MoshDiagnostics.log(
                        "mosh scrollback overlay find seed deferred reason=native-scroll pane=\(paneId.description) depth=\(capture.requestedDepth)"
                    )
                    armMoshOverlayNativeSettleCheck(for: overlay)
                    return
                }

                overlay.box.clearScrollback(restoringLimit: appearance.scrollbackLines)
                overlay.box.feed(capture.repaintBytes[...])
                moshScrollbackDepthByPane[paneId] = max(
                    moshScrollbackDepthByPane[paneId] ?? 0,
                    capture.requestedDepth
                )
                moshOverlayContentReadyId = overlay.id

                DispatchQueue.main.async {
                    guard let currentOverlay = moshPaneScrollbackOverlay,
                          currentOverlay === overlay
                    else { return }
                    MoshDiagnostics.log(
                        "mosh scrollback overlay find seed applied pane=\(paneId.description) depth=\(capture.requestedDepth) lines=\(capture.capturedLineCount) bytes=\(capture.repaintBytes.count)"
                    )
                    if findController.isOpen {
                        findController.handlers = TerminalSearchAdapter.handlers(for: overlay.box)
                        findController.updateSearch()
                    }
                }
            }
            return
        }

        findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)
        let currentDepth = moshScrollbackDepthByPane[paneId] ?? 0
        guard currentDepth < targetDepth else {
            MoshDiagnostics.log(
                "mosh scrollback find seed skipped reason=already-seeded pane=\(paneId.description) depth=\(currentDepth) targetDepth=\(targetDepth)"
            )
            findController.updateSearch()
            return
        }

        if let inFlight = moshScrollbackInFlight,
           inFlight.paneId == paneId,
           inFlight.depth >= targetDepth {
            logMoshScrollbackGate(
                "find-skip reason=in-flight pane=\(paneId.description) targetDepth=\(targetDepth) inFlightDepth=\(inFlight.depth)"
            )
            return
        }

        armMoshScrollbackFetch(paneId: paneId, depth: targetDepth, context: "find-seed")
        MoshDiagnostics.log(
            "mosh scrollback find seed begin reason=\(reason) pane=\(paneId.description) depth=\(targetDepth) currentDepth=\(currentDepth)"
        )

        tmux.captureActivePrimaryPaneScrollback(depth: targetDepth) { capture in
            guard terminalBox.view === view,
                  moshScrollbackInFlight?.paneId == paneId,
                  moshScrollbackInFlight?.depth == targetDepth
            else { return }

            moshScrollbackInFlight = nil
            moshScrollbackLoading = false

            guard let capture, capture.paneId == paneId, !capture.repaintBytes.isEmpty else {
                MoshDiagnostics.log(
                    "mosh scrollback find seed empty pane=\(paneId.description) depth=\(targetDepth)"
                )
                findController.updateSearch()
                return
            }

            terminalBox.clearScrollback(restoringLimit: appearance.scrollbackLines)
            terminalBox.feed(capture.repaintBytes[...])
            moshScrollbackDepthByPane[paneId] = max(
                moshScrollbackDepthByPane[paneId] ?? 0,
                capture.requestedDepth
            )

            DispatchQueue.main.async {
                guard terminalBox.view === view else { return }
                MoshDiagnostics.log(
                    "mosh scrollback find seed applied pane=\(paneId.description) depth=\(capture.requestedDepth) lines=\(capture.capturedLineCount) bytes=\(capture.repaintBytes.count)"
                )
                if findController.isOpen {
                    findController.updateSearch()
                }
            }
        }
    }

    private func noteMoshAgentInput(_ bytes: [UInt8]) {
        guard let registrationID = agentSourceRegistrationID else { return }
        let paneID = tmux.mode == .tmuxControl ? tmux.activePaneId?.rawValue : nil
        agentCenter.noteInput(
            sessionID: liveSessionID,
            paneID: paneID,
            registrationID: registrationID,
            bytes: bytes
        )
    }

    /// The mosh shared terminal surface. Extracted from `body` as a concrete
    /// `TerminalSurfaceBound` (not `some View`) so the SwiftUI body stays under
    /// the type-checker's complexity budget — the full inline call plus its many
    /// closures tips "unable to type-check this expression in reasonable time".
    private var moshTerminalSurface: TerminalSurfaceBound {
        TerminalSurfaceBound(
            initialData: [],
            onMade: { view in terminalBox.attach(view) },
            onReady: { terminalBox.markRenderReady() },
            onSend: { bytes in
                guard !showsLaunchOverlay, !tmux.gridAuthority.isPeer else { return }
                if !isAutomaticTerminalColorResponse(bytes) {
                    invalidateMoshScrollbackForTerminalInput(reason: "terminal-input")
                }
                let input = Array(bytes)
                noteMoshAgentInput(input)
                session.send(input)
            },
            onResize: { cols, rows in
                // Once the compact tmux canvas is active this inner SwiftTerm
                // surface is intentionally framed at the full server grid.
                // Only the outer viewport callback represents phone geometry.
                guard !(isPhone && tmux.mode == .tmuxControl) else { return }
                if let previous = lastTerminalSize,
                   previous.cols != cols || previous.rows != rows {
                    resetMoshScrollbackCapture(clearLocal: true, reason: "resize")
                }
                lastTerminalSize = (cols, rows)
                guard isActive else { return }
                session.resize(cols: cols, rows: rows)
                tmux.updateClientSize(cols: cols, rows: rows)
                tmuxControlBox.channel?.resize(cols: cols, rows: rows)
            },
            onTitle: { title in
                tmux.updateActiveWindowName(title)
                currentTerminalTitle = title
            },
            onUserActivity: {
                appLockController.notifyUserActivity()
            },
            onBell: {
                bellController.ring(
                    source: .session(session.host.id),
                    isOriginOnScreen: true,
                    hostDisplayName: session.host.name,
                    paneTitle: currentTerminalTitle
                )
            },
            onPrimaryScrollbackDelta: handleMoshPrimaryScrollbackDelta,
            onPrimaryScrollbackUnderflow: handleMoshPrimaryScrollbackUnderflow,
            onScrollGestureActivity: { [scrollGestureActivity] active in
                scrollGestureActivity.isActive = active
            },
            agentScrollBlockingActive:
                !tmux.gridAuthority.isPeer
                    && agentScrollPrevention(paneID: activeAgentScrollPaneID) != nil,
            onAgentScrollBlocked: {
                presentAgentScrollPrevention(paneID: activeAgentScrollPaneID)
            },
            mouseReportingImpliesAltScreen: !moshPaneCycleEnabled,
            suppressDirectColorQueryResponses: false,
            softwareModifierState: modifierState,
            tmuxShortcutsEnabled: true,
            onTmuxShortcut: { shortcut in
                appLockController.notifyUserActivity()
                handleTmuxShortcut(shortcut)
            },
            onFindShortcut: { shortcut in
                appLockController.notifyUserActivity()
                switch shortcut {
                case .open:     findController.open()
                case .next:     findController.next()
                case .previous: findController.previous()
                }
            },
            onSwitcherShortcut: { shortcut in
                appLockController.notifyUserActivity()
                handleSwitcherShortcut(shortcut)
            },
            onOpenSettings: {
                appLockController.notifyUserActivity()
                onOpenSettings()
            },
            onOpenAgentCenter: onOpenAgentCenter.map { action in
                {
                    appLockController.notifyUserActivity()
                    action()
                }
            },
            // `!isActive`: a backgrounded (mounted, opacity-0) mosh session must
            // not reclaim first responder from the foreground (e.g. host editor).
            suppressFirstResponderReclaim: integrationScrollHarnessSuppressesFirstResponder
                || !isActive
                || findController.isOpen
                || commandPalette.isOpen
                || filesPanel.textEntryActive
                || (isPhone && modifierState.suppressesSoftwareKeyboardReclaim)
                || tmux.gridAuthority.isPeer,
            forceResignFirstResponder: tmux.gridAuthority.isPeer,
            onHardwareKey: { key in
                // While yielded, a page key is a reclaim gesture, never
                // bytes into the PTY the peer is using (the GCKeyboard
                // passthrough can fire before the veil's focus grab lands).
                if tmux.gridAuthority.isPeer {
                    takeBackContinuedSession()
                    return
                }
                let bytes = key.escapeSequence
                MoshDiagnostics.log(
                    "mosh hardware key type=\(String(describing: key)) bytes=\(bytes.count)"
                )
                invalidateMoshScrollbackForTerminalInput(reason: "hardware-key")
                session.send(bytes)
            },
            scrollRetentionID: [
                "mosh",
                "shared",
                tmux.activeWindowId?.description ?? "nil",
                tmux.activePaneId?.description ?? "nil",
            ].joined(separator: ":"),
            onScrollDiagnostic: { message in
                recordMoshScrollDiagnostic("surface=shared \(message)")
            },
            onHostDirectory: { dir in
                // Plain mosh: OSC 7 arrives via the fork's framebuffer
                // cwd sync (mirrors OSC 52). Under tmux the pane
                // subscription owns cwd instead.
                guard tmux.mode == .passthrough else { return }
                filesPanel.terminalReportedDirectory(dir)
            },
            onFilesShortcut: {
                appLockController.notifyUserActivity()
                toggleFilesPanel()
            },
            onSelectionPathAction: { action, text in
                handleSelectionPathAction(action, text: text)
            },
            // Mosh paints the split natively in the single shared surface (no
            // grid mounts), so there is no per-pane surface to carry this flag —
            // wire it here off the side-channel active window's pane count. With
            // >1 pane the bare ⌘[/⌘] pane-cycle and ⌘⇧Return zoom chords go live
            // (dispatched over the side channel via handleTmuxShortcut, behind
            // the degraded gate); with a single pane they no-op and the session
            // switcher keeps ⌘[/⌘]. ⌘D split stays available either way (gated on
            // tmuxShortcutsEnabled, not this flag).
            paneCycleEnabled: moshPaneCycleEnabled,
            // Tap-to-focus: when the active window is split, a tap on the shared
            // surface selects the pane under the finger over the side channel
            // (the remote tmux paints the panes; we only move focus). Gated on
            // the same multi-pane predicate so single-pane mosh keeps SwiftTerm's
            // tap/selection behaviour untouched.
            onPaneFocusTap: handleMoshPaneFocusTap,
            paneFocusTapEnabled: moshPaneCycleEnabled,
            terminalBackground: resolvedTerminalBackground
        )
    }

    private var shouldBlockTmuxShortcut: Bool {
        session.host.launchMode != .customCommand
            && session.state == .connected
            && tmuxSideChannelState.blocksTmuxCommands
    }

    private func showTmuxShortcutBlockedToast(shortcut: TesseraTmuxShortcut) {
        presentTmuxBlockedToast(logReason: "shortcut=\(shortcut.logDescription)")
    }

    /// Shared "side channel is reconnecting / degraded" toast, used by both the
    /// blocked chords and tap-to-focus when `shouldBlockTmuxShortcut` is true.
    private func presentTmuxBlockedToast(logReason: String) {
        MoshDiagnostics.log(
            "mosh tmux command blocked \(logReason) state=\(tmuxSideChannelState.logDescription)"
        )
        tmuxShortcutToastTask?.cancel()
        tmuxShortcutToastVisible = true
        tmuxShortcutToastTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            tmuxShortcutToastVisible = false
            tmuxShortcutToastTask = nil
        }
    }

    /// Maps a tap on the mosh shared surface to a pane and selects it over the
    /// side channel — iTerm2 behaviour: focus only, never a click into the
    /// in-pane TUI. The remote tmux client paints the split into the UDP
    /// terminal, so there is no per-pane surface to route through; the layout
    /// tracked on the render-inert side channel drives the hit test. Returns
    /// `true` when the tap is consumed (hit a non-focused pane, or showed the
    /// degraded toast); a tap on the focused pane, a divider gutter, or a
    /// single-pane window returns `false` and the caller does nothing.
    ///
    /// A `select-pane` only moves `activePaneId`, never `activeWindowId`, so it
    /// cannot trip the mosh window-change scrollback clear (pinned controller
    /// test). Our own echo is suppressed in the controller like the SSH path.
    private func handleMoshPaneFocusTap(at point: CGPoint, cellSize: CGSize) -> Bool {
        guard let snapshot = moshPaneChromeSnapshot() else { return false }

        let frames = moshPaneChromeFrames(for: snapshot, cellSize: cellSize)
        guard let hit = frames.first(where: { $0.paneBox.contains(point) }) else { return false }

        // Header close affordance — only when actually split (frames.count > 1,
        // so a zoomed single-leaf render shows none). Checked BEFORE focus so
        // tapping a pane's x closes it without also dispatching select-pane to a
        // pane that's about to die.
        if frames.count > 1,
           PaneLayoutMath.headerCloseButtonRect(for: hit, cellSize: cellSize).contains(point) {
            if shouldBlockTmuxShortcut {
                presentTmuxBlockedToast(logReason: "paneClose pane=\(hit.paneId.description)")
                return true
            }
            appLockController.notifyUserActivity()
            tmux.killPane(hit.paneId)
            return true
        }

        // Tapping the already-focused pane is a no-op: no redundant select-pane,
        // and crucially no click forwarded into a mouse-aware app in that pane.
        guard hit.paneId != snapshot.activePaneId else { return false }

        if shouldBlockTmuxShortcut {
            presentTmuxBlockedToast(logReason: "paneFocusTap pane=\(hit.paneId.description)")
            return true
        }

        appLockController.notifyUserActivity()
        tmux.selectPane(hit.paneId)
        return true
    }

    /// The layout tmux is actually painting on the shared surface: the single
    /// zoomed leaf while zoomed, else the full split layout. Drives both the ✕
    /// overlay and the tap hit-test so chrome and touch targets match the pixels.
    /// Mirrors `PaneGridView.renderLayout`.
    private var moshRenderLayout: WindowLayout? {
        guard let window = moshActiveWindow else { return nil }
        return window.isZoomed ? (window.visibleLayout ?? window.layout) : window.layout
    }

    /// Cell size of the mosh shared terminal — used to position the ✕ overlay and
    /// hit-test taps. Reads the live terminal font via the same `TerminalCellMetrics`
    /// helper the SSH grid uses, so the overlay and the UIKit tap recognizer's
    /// `cellDimensions(for:)` agree to the pixel.
    private var moshCellSize: CGSize? {
        terminalBox.view.map { TerminalCellMetrics.cellSize(for: $0) }
    }

    /// Transient cover for tmux's native pane-title rows during split /
    /// collapse transitions (the chrome overlay unmounts before tmux repaints
    /// the reclaimed rows). With a background picture it paints the aligned
    /// backdrop crop so the mask is invisible against the session backdrop;
    /// otherwise the plain theme color, as before.
    @ViewBuilder
    private func moshChromeTransitionMask(rects: [CGRect]) -> some View {
        if let background = resolvedTerminalBackground {
            TerminalBackdrop(
                background: background,
                baseColor: activeTheme.bg,
                bleed: moshOverlayBackdropBleed
            )
            .clipShape(FixedRectsShape(rects: rects))
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(rects, id: \.self) { rect in
                    Rectangle()
                        .fill(activeTheme.bg)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The scrollback overlay is mounted in the inset terminal coordinate
    /// space, while the session backdrop now spans the whole screen. Expanding
    /// its duplicate by the surrounding chrome reconstructs the same image
    /// dimensions and origin before the pane clip is applied.
    private var moshOverlayBackdropBleed: EdgeInsets {
        let topBar = SessionTopBar.reservedHeight(
            pillHeight: appearance.topBarHeight,
            compact: isPhone
        )
        let findBar = findController.isOpen ? CGFloat(appearance.topBarHeight + 4) : 0
        return EdgeInsets(
            top: topBar + findBar,
            leading: SessionView.cornerInset,
            bottom: appearance.showAccessoryBar ? 52 : 0,
            trailing: SessionView.cornerInset
        )
    }

    private static func tmuxReconnectDelay(for attempt: Int) -> TimeInterval {
        let shift = min(max(attempt - 1, 0), 4)
        let uncapped = 1 << shift
        return TimeInterval(min(uncapped, 15))
    }

    private static func nanoseconds(forDelay delay: TimeInterval) -> UInt64 {
        UInt64((delay * 1_000_000_000).rounded())
    }

    private static func formatDelay(_ delay: TimeInterval) -> String {
        if delay.rounded() == delay {
            return "\(Int(delay))s"
        }
        return String(format: "%.1fs", delay)
    }
}

/// Invisible UIScrollView mounted over an alt-screen pane in a mosh+tmux
/// grid. Same principle as the scrollback overlay's native path (M1/M2):
/// during a trackpad pan iPadOS throttles the whole UIKit update cycle
/// unless something is presenting, so a pan that only produces semantic
/// forwards runs at coalesced 24-40ms events. Giving the pan its own
/// scroll view to move from event 1 keeps the cycle hot; the offset
/// motion is forwarded semantically (wheel/arrow encoding upstream) and
/// the offset itself is recentered so the surface never hits an edge
/// (Apple StreetScroller pattern — safe mid-pan because pan tracking is
/// delta-based).
///
/// Policy mirrors the bridge path: only TRACKED motion forwards — the
/// remote TUI must never keep receiving motion after the fingers left
/// the trackpad, so deceleration is killed at release. Non-scroll hits
/// pass through to the live pane beneath (clicks/taps keep working).
final class MoshAltScreenScrollProxyView: UIScrollView, UIScrollViewDelegate {
    var onScrollDelta: ((Double) -> Void)?

    private var lastOffsetY: CGFloat = 0
    private var isAdjustingOffset = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        scrollsToTop = false
        // Recentering keeps both edges unreachable, so bounce physics
        // never engage; disabling them is belt-and-braces against an
        // edge-pin swallowing didScroll (the M2 lesson).
        bounces = false
        alwaysBounceVertical = false
        panGestureRecognizer.allowedScrollTypesMask = .all
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Scroll-only delivery, same rule as the scrollback overlay's
    /// container: clicks, taps, and finger touches fall through to the
    /// live shared surface (htop clicks must keep landing). `nil` events
    /// pass through — conservative direction.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type != .scroll { return nil }
        return super.hitTest(point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let targetHeight = max(bounds.height * 8, 4000)
        if abs(contentSize.height - targetHeight) > 0.5
            || abs(contentSize.width - bounds.width) > 0.5 {
            contentSize = CGSize(width: bounds.width, height: targetHeight)
            recenter()
        } else {
            recenterIfNeeded()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjustingOffset else { return }
        let delta = Double(lastOffsetY - contentOffset.y)
        lastOffsetY = contentOffset.y
        // Deltas only while fingers are on the pad: deceleration (or any
        // programmatic motion) must not turn into semantic forwards.
        guard isTracking || isDragging, delta != 0 else { return }
        onScrollDelta?(delta)
    }

    func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        if decelerate {
            // Kill momentum at release — a same-offset set ends it — so
            // the proxy never sits in a ghost isDecelerating state.
            setContentOffset(contentOffset, animated: false)
        }
        recenterIfNeeded(force: true)
    }

    private func recenterIfNeeded(force: Bool = false) {
        let centerY = max(0, (contentSize.height - bounds.height) / 2)
        let distance = abs(contentOffset.y - centerY)
        guard force ? distance > 0.5 : distance > bounds.height * 2 else { return }
        recenter()
    }

    private func recenter() {
        let centerY = max(0, (contentSize.height - bounds.height) / 2)
        isAdjustingOffset = true
        contentOffset = CGPoint(x: contentOffset.x, y: centerY)
        lastOffsetY = centerY
        isAdjustingOffset = false
    }
}

private struct MoshAltScreenScrollProxy: UIViewRepresentable {
    let onScrollDelta: (Double) -> Void

    func makeUIView(context: Context) -> MoshAltScreenScrollProxyView {
        let view = MoshAltScreenScrollProxyView(frame: .zero)
        view.onScrollDelta = onScrollDelta
        return view
    }

    func updateUIView(_ uiView: MoshAltScreenScrollProxyView, context: Context) {
        uiView.onScrollDelta = onScrollDelta
    }
}

private struct MoshPaneScrollbackOverlay: View {
    let runtime: MoshPaneScrollbackOverlayRuntime
    let paneFrame: CGRect
    /// Background picture treatment, mirrored from the shared surface. The
    /// overlay stacks OVER live content, so it can't simply be transparent —
    /// it mounts its own opaque copy of the backdrop, clipped to the exact
    /// crop of the canvas-spanning one its pane covers (no shift on reveal),
    /// and its terminal goes transparent over that.
    let terminalBackground: ResolvedTerminalBackground?
    let backdropBaseColor: SwiftUI.Color
    let backdropBleed: EdgeInsets
    let onReady: () -> Void
    let onTerminalScrolled: (TerminalView) -> Void
    let onScrollDiagnostic: (String) -> Void
    let agentScrollBlockingActive: Bool
    let onAgentScrollBlocked: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let terminalBackground {
                TerminalBackdrop(
                    background: terminalBackground,
                    baseColor: backdropBaseColor,
                    bleed: backdropBleed
                )
                .clipShape(FixedRectShape(rect: paneFrame))
            }

            TerminalSurfaceBound(
                initialData: [],
                onMade: { view in runtime.box.attach(view) },
                onReady: {
                    runtime.box.markRenderReady()
                    onReady()
                },
                onSend: { _ in },
                onResize: { _, _ in },
                onTitle: { _ in },
                onUserActivity: nil,
                onBell: nil,
                agentScrollBlockingActive: agentScrollBlockingActive,
                onAgentScrollBlocked: onAgentScrollBlocked,
                mouseReportingImpliesAltScreen: false,
                suppressDirectColorQueryResponses: true,
                tmuxShortcutsEnabled: false,
                onTmuxShortcut: { _ in },
                onFindShortcut: nil,
                onSwitcherShortcut: nil,
                onOpenSettings: nil,
                suppressFirstResponderReclaim: true,
                onHardwareKey: nil,
                onTerminalScrolled: onTerminalScrolled,
                scrollRetentionID: [
                    "mosh-overlay",
                    runtime.windowId.description,
                    runtime.paneId.description,
                ].joined(separator: ":"),
                onScrollDiagnostic: { message in
                    onScrollDiagnostic(
                        "surface=overlay window=\(runtime.windowId.description) pane=\(runtime.paneId.description) \(message)"
                    )
                },
                nativeScrollSurface: true,
                terminalBackground: terminalBackground
            )
            .frame(width: paneFrame.width, height: paneFrame.height)
            .clipped()
            .offset(x: paneFrame.minX, y: paneFrame.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Hit-testability is decided at the mount site (revealed overlays
        // take scroll hits natively; hidden/parked ones take none) — the
        // container's scroll-only hitTest handles click pass-through.
    }
}

/// Reference box so we can capture the UIKit `TerminalView` out of
/// SwiftUI's value-type world and feed bytes into it from async code.
private struct TerminalPerformanceFeedContext {
    let source: String
    let pane: String?
    let window: String?
    let generation: Int?
    let captureRows: Int?
    let reason: String?
    let originalByteCount: Int?

    init(_ context: TmuxController.TerminalFeedContext) {
        source = context.source.rawValue
        pane = context.paneId?.description
        window = context.windowId?.description
        generation = context.generation
        captureRows = context.captureRows
        reason = context.reason
        originalByteCount = context.originalByteCount
    }

    static func moshLive(originalByteCount: Int) -> TerminalPerformanceFeedContext {
        TerminalPerformanceFeedContext(
            source: "mosh-live",
            originalByteCount: originalByteCount
        )
    }

    private init(source: String, originalByteCount: Int) {
        self.source = source
        pane = nil
        window = nil
        generation = nil
        captureRows = nil
        reason = nil
        self.originalByteCount = originalByteCount
    }
}

private struct TerminalPerformanceFeedToken {
    let startedAt: CFTimeInterval
    let source: String
    let byteCount: Int
}

/// Verbose-only, burst-aggregated terminal timing. There is no payload
/// capture and no permanent sampler: one display link exists only while an
/// output burst is active, then one bounded summary is written after idle.
@MainActor
private final class TerminalPerformanceDiagnostics: NSObject {
    private struct SourceStats {
        var chunks = 0
        var bytes = 0
        var maxFeedMs: Double = 0
        var slowestFeedBytes = 0
        var maxOriginalBytes = 0
        var maxCaptureRows: Int?
    }

    private struct ActiveIngress {
        let byteCount: Int
        var burstGeneration: Int?
    }

    private struct Burst {
        let generation: Int
        let startedAt: CFTimeInterval
        var lastActivityAt: CFTimeInterval
        var lastFrameAt: CFTimeInterval
        var ingressChunks = 0
        var ingressBytes = 0
        var ingressMs: Double = 0
        var maxIngressMs: Double = 0
        var feedChunks = 0
        var feedBytes = 0
        var shellMs: Double = 0
        var rendererMs: Double = 0
        var feedMs: Double = 0
        var maxFeedMs: Double = 0
        var slowestFeedBytes = 0
        var maxOriginalBytes = 0
        var frameTicks = 0
        var maxFrameGapMs: Double = 0
        var frameGapsOver50ms = 0
        var maxMainQueueDelayMs: Double = 0
        var sources: [String: SourceStats] = [:]
        var lastPane: String?
        var lastWindow: String?
        var lastGeneration: Int?
        var maxCaptureRows: Int?
        var lastReason: String?
    }

    private static let idleFlushSeconds: CFTimeInterval = 0.5
    private static let maximumBurstSeconds: CFTimeInterval = 10
    private static let slowIngressOnlyMs: Double = 50
    private static let slowIngressLogInterval: CFTimeInterval = 60

    private let surface: String
    private var cachedEnabled = false
    private var nextDefaultsCheckAt: CFTimeInterval = 0
    private var nextGeneration = 0
    private var burst: Burst?
    private var flushTask: Task<Void, Never>?
    private var expectedFlushAt: CFTimeInterval?
    private var displayLink: CADisplayLink?
    private var activeIngress: ActiveIngress?
    private var nextSlowIngressLogAt: CFTimeInterval = 0

    init(surface: String) {
        self.surface = surface
        super.init()
    }

    func beginIngress(byteCount: Int) -> CFTimeInterval? {
        let now = CACurrentMediaTime()
        guard diagnosticsEnabled(at: now) else { return nil }
        activeIngress = ActiveIngress(
            byteCount: byteCount,
            burstGeneration: nil
        )
        return now
    }

    func endIngress(startedAt: CFTimeInterval) {
        let now = CACurrentMediaTime()
        let elapsedMs = max(0, now - startedAt) * 1_000
        let ingress = activeIngress
        activeIngress = nil

        if let generation = ingress?.burstGeneration,
           var burst,
           burst.generation == generation {
            burst.ingressMs += elapsedMs
            burst.maxIngressMs = max(burst.maxIngressMs, elapsedMs)
            burst.lastActivityAt = now
            self.burst = burst
            return
        }

        // Control-only ingress is normally sub-millisecond and carries no
        // renderer signal. Keep it out of burst/frame diagnostics entirely;
        // emit one content-free line only when parsing itself is visibly slow.
        if elapsedMs >= Self.slowIngressOnlyMs,
           now >= nextSlowIngressLogAt,
           DiagnosticLogStore.isVerboseEnabled {
            nextSlowIngressLogAt = now + Self.slowIngressLogInterval
            DiagnosticLogStore.appendTerminalPerformance(
                "terminal-ingress-slow surface=\(surface) bytes=\(ingress?.byteCount ?? 0) elapsedMs=\(format(elapsedMs))"
            )
        }
    }

    func beginFeed(
        context: TerminalPerformanceFeedContext,
        byteCount: Int
    ) -> TerminalPerformanceFeedToken? {
        let now = CACurrentMediaTime()
        guard diagnosticsEnabled(at: now) else { return nil }
        ensureBurst(at: now)
        guard var burst else { return nil }

        if var ingress = activeIngress,
           ingress.burstGeneration == nil {
            ingress.burstGeneration = burst.generation
            activeIngress = ingress
            burst.ingressChunks += 1
            burst.ingressBytes += ingress.byteCount
        }

        burst.feedChunks += 1
        burst.feedBytes += byteCount
        burst.maxOriginalBytes = max(
            burst.maxOriginalBytes,
            context.originalByteCount ?? byteCount
        )
        burst.lastActivityAt = now
        var source = burst.sources[context.source] ?? SourceStats()
        source.chunks += 1
        source.bytes += byteCount
        source.maxOriginalBytes = max(
            source.maxOriginalBytes,
            context.originalByteCount ?? byteCount
        )
        if let rows = context.captureRows {
            source.maxCaptureRows = max(source.maxCaptureRows ?? 0, rows)
            burst.maxCaptureRows = max(burst.maxCaptureRows ?? 0, rows)
        }
        burst.sources[context.source] = source
        burst.lastPane = context.pane ?? burst.lastPane
        burst.lastWindow = context.window ?? burst.lastWindow
        burst.lastGeneration = context.generation ?? burst.lastGeneration
        burst.lastReason = context.reason ?? burst.lastReason
        self.burst = burst

        return TerminalPerformanceFeedToken(
            startedAt: now,
            source: context.source,
            byteCount: byteCount
        )
    }

    func endFeed(
        _ token: TerminalPerformanceFeedToken,
        shellMs: Double,
        rendererMs: Double
    ) {
        guard var burst else { return }
        let now = CACurrentMediaTime()
        let feedMs = max(0, now - token.startedAt) * 1_000
        burst.shellMs += max(0, shellMs)
        burst.rendererMs += max(0, rendererMs)
        burst.feedMs += feedMs
        if feedMs > burst.maxFeedMs {
            burst.maxFeedMs = feedMs
            burst.slowestFeedBytes = token.byteCount
        }
        burst.lastActivityAt = now
        if var source = burst.sources[token.source] {
            if feedMs > source.maxFeedMs {
                source.maxFeedMs = feedMs
                source.slowestFeedBytes = token.byteCount
            }
            burst.sources[token.source] = source
        }
        self.burst = burst
    }

    private func diagnosticsEnabled(at now: CFTimeInterval) -> Bool {
        if now >= nextDefaultsCheckAt {
            cachedEnabled = DiagnosticLogStore.isVerboseEnabled
            nextDefaultsCheckAt = now + 1
            if !cachedEnabled {
                discardBurst()
            }
        }
        return cachedEnabled
    }

    private func ensureBurst(at now: CFTimeInterval) {
        guard burst == nil else { return }
        nextGeneration &+= 1
        let generation = nextGeneration
        burst = Burst(
            generation: generation,
            startedAt: now,
            lastActivityAt: now,
            lastFrameAt: now
        )
        startDisplayLink()
        scheduleFlush(generation: generation, after: Self.idleFlushSeconds)

        // One sentinel per burst captures a fully synchronous first feed (or a
        // backlog of already-ready MainActor work) without a recurring timer.
        Task { @MainActor [weak self] in
            guard let self, var current = self.burst,
                  current.generation == generation else { return }
            current.maxMainQueueDelayMs = max(
                current.maxMainQueueDelayMs,
                max(0, CACurrentMediaTime() - now) * 1_000
            )
            self.burst = current
        }
    }

    private func scheduleFlush(generation: Int, after delay: CFTimeInterval) {
        flushTask?.cancel()
        let boundedDelay = max(0.01, delay)
        expectedFlushAt = CACurrentMediaTime() + boundedDelay
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(boundedDelay))
            guard !Task.isCancelled else { return }
            self?.flushIfReady(generation: generation)
        }
    }

    private func flushIfReady(generation: Int) {
        flushTask = nil
        guard var current = burst, current.generation == generation else { return }
        let now = CACurrentMediaTime()

        // Cooperative renderer delivery can span several main-run-loop turns.
        // Keep its one aggregate open until the owning ingress completes.
        if activeIngress?.burstGeneration == generation {
            scheduleFlush(generation: generation, after: Self.idleFlushSeconds)
            return
        }

        if let expectedFlushAt {
            current.maxMainQueueDelayMs = max(
                current.maxMainQueueDelayMs,
                max(0, now - expectedFlushAt) * 1_000
            )
            burst = current
        }

        let idleSeconds = now - current.lastActivityAt
        let wallSeconds = now - current.startedAt
        guard idleSeconds >= Self.idleFlushSeconds
                || wallSeconds >= Self.maximumBurstSeconds else {
            let untilIdle = Self.idleFlushSeconds - idleSeconds
            let untilMaximum = Self.maximumBurstSeconds - wallSeconds
            scheduleFlush(
                generation: generation,
                after: min(untilIdle, untilMaximum)
            )
            return
        }

        displayLink?.invalidate()
        displayLink = nil
        burst = nil
        expectedFlushAt = nil

        guard DiagnosticLogStore.isVerboseEnabled else { return }
        let outsideFeedMs = max(0, current.ingressMs - current.feedMs)
        let sourceSummary = current.sources.keys.sorted().compactMap { key -> String? in
            guard let source = current.sources[key] else { return nil }
            let rows = source.maxCaptureRows.map { ",rows=\($0)" } ?? ""
            return "\(key){chunks=\(source.chunks),bytes=\(source.bytes),maxOriginalBytes=\(source.maxOriginalBytes),maxFeedMs=\(format(source.maxFeedMs)),slowestFeedBytes=\(source.slowestFeedBytes)\(rows)}"
        }.joined(separator: ";")

        DiagnosticLogStore.appendTerminalPerformance(
            "terminal-output-burst surface=\(surface) wallMs=\(format(wallSeconds * 1_000)) ingressChunks=\(current.ingressChunks) ingressBytes=\(current.ingressBytes) ingressMs=\(format(current.ingressMs)) maxIngressMs=\(format(current.maxIngressMs)) outsideFeedMs=\(format(outsideFeedMs)) feedChunks=\(current.feedChunks) feedBytes=\(current.feedBytes) maxOriginalBytes=\(current.maxOriginalBytes) shellMs=\(format(current.shellMs)) rendererMs=\(format(current.rendererMs)) maxFeedMs=\(format(current.maxFeedMs)) slowestFeedBytes=\(current.slowestFeedBytes) frameTicks=\(current.frameTicks) maxFrameGapMs=\(format(current.maxFrameGapMs)) frameGapsOver50ms=\(current.frameGapsOver50ms) mainQueueDelayMs=\(format(current.maxMainQueueDelayMs)) sources='\(sourceSummary)' pane=\(current.lastPane ?? "nil") window=\(current.lastWindow ?? "nil") generation=\(current.lastGeneration.map(String.init) ?? "nil") maxCaptureRows=\(current.maxCaptureRows.map(String.init) ?? "nil") reason=\(current.lastReason ?? "none")"
        )
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        guard var burst else { return }
        let gapMs = max(0, link.timestamp - burst.lastFrameAt) * 1_000
        burst.frameTicks += 1
        burst.maxFrameGapMs = max(burst.maxFrameGapMs, gapMs)
        if gapMs >= 50 {
            burst.frameGapsOver50ms += 1
        }
        burst.lastFrameAt = link.timestamp
        self.burst = burst
    }

    private func discardBurst() {
        flushTask?.cancel()
        flushTask = nil
        displayLink?.invalidate()
        displayLink = nil
        expectedFlushAt = nil
        burst = nil
        activeIngress = nil
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

@MainActor
final class TerminalBox {
    private let traceLabel: String
    fileprivate let performanceDiagnostics: TerminalPerformanceDiagnostics
    weak var view: TerminalView?
    private var pendingBytes: [UInt8] = []
    private var isRenderReady = false
    private var bufferedChunkCount = 0
    private var directChunkCount = 0
    private var contrastFilter = TerminalOutputContrastFilter()
    private var lastInterfaceOrientation: UIInterfaceOrientation?

    init(traceLabel: String) {
        self.traceLabel = traceLabel
        performanceDiagnostics = TerminalPerformanceDiagnostics(surface: traceLabel)
    }

    func dismissTransientInteractions() {
        view?.selectNone()
        view?.resignFirstResponder()
        view?.window?.endEditing(true)
        UIMenuController.shared.hideMenu()
    }

    /// `UIDevice.orientationDidChangeNotification` also reports physical
    /// posture changes such as portrait -> face-up -> portrait even when the
    /// window remains portrait. Dismissing the terminal for those notifications
    /// makes the phone keyboard hide, then `TerminalSurfaceBound` immediately
    /// reclaims first responder on the next SwiftUI update. Only a real
    /// interface-orientation transition should invalidate transient UI.
    func dismissTransientInteractionsIfInterfaceOrientationChanged() {
        guard let current = view?.window?.windowScene?.interfaceOrientation else {
            return
        }
        defer { lastInterfaceOrientation = current }
        guard let previous = lastInterfaceOrientation,
              previous != current
        else { return }
        dismissTransientInteractions()
    }

    func attach(_ view: TerminalView) {
        if self.view !== view {
            isRenderReady = false
            lastInterfaceOrientation = nil
        }
        self.view = view
        MoshDiagnostics.log(
            "\(traceLabel) terminal attach ready=\(isRenderReady) pendingBytes=\(pendingBytes.count)"
        )
        flushPendingBytesIfPossible()
    }

    func markRenderReady() {
        isRenderReady = true
        MoshDiagnostics.log(
            "\(traceLabel) terminal render ready pendingBytes=\(pendingBytes.count)"
        )
        flushPendingBytesIfPossible()
    }

    private func flushPendingBytesIfPossible() {
        guard isRenderReady, let view, !pendingBytes.isEmpty else { return }
        MoshDiagnostics.log(
            "\(traceLabel) terminal flush pending bytes=\(pendingBytes.count)"
        )
        let filtered = filteredBytes(pendingBytes[...], for: view)
        if !filtered.isEmpty {
            view.feed(byteArray: filtered[...])
        }
        pendingBytes.removeAll(keepingCapacity: true)
    }

    /// Shared shell-observer + renderer feed path. Keeping the timing wrapper
    /// here ensures every transport reports identical per-slice metrics.
    fileprivate func feedTerminalOutput(
        _ bytes: ArraySlice<UInt8>,
        context: TerminalPerformanceFeedContext,
        shellIntegration: SwipePadShellIntegrationTracker
    ) {
        if let token = performanceDiagnostics.beginFeed(
            context: context,
            byteCount: bytes.count
        ) {
            let shellStartedAt = CACurrentMediaTime()
            shellIntegration.feed(bytes)
            let rendererStartedAt = CACurrentMediaTime()
            feed(bytes)
            let finishedAt = CACurrentMediaTime()
            performanceDiagnostics.endFeed(
                token,
                shellMs: (rendererStartedAt - shellStartedAt) * 1_000,
                rendererMs: (finishedAt - rendererStartedAt) * 1_000
            )
        } else {
            shellIntegration.feed(bytes)
            feed(bytes)
        }
    }

    /// Plain mosh output bypasses TmuxController, so apply the same cooperative
    /// renderer budget at this shared terminal boundary. SwiftTerm and the
    /// shell/contrast parsers are streaming parsers and preserve state across
    /// arbitrary byte boundaries.
    fileprivate func feedTerminalOutputCooperatively(
        _ bytes: ArraySlice<UInt8>,
        context: TerminalPerformanceFeedContext,
        shellIntegration: SwipePadShellIntegrationTracker
    ) async {
        guard !bytes.isEmpty else { return }
        let maximumChunkBytes = 1024
        let turnBudget: Duration = .milliseconds(4)
        let clock = ContinuousClock()
        var turnStartedAt = clock.now
        var offset = bytes.startIndex
        var renderedMultipleSlices = false

        while offset < bytes.endIndex {
            let end = bytes.index(
                offset,
                offsetBy: min(maximumChunkBytes, bytes.distance(from: offset, to: bytes.endIndex))
            )
            feedTerminalOutput(
                bytes[offset..<end],
                context: context,
                shellIntegration: shellIntegration
            )
            renderedMultipleSlices = renderedMultipleSlices || end < bytes.endIndex
            offset = end
            if turnStartedAt.duration(to: clock.now) >= turnBudget {
                await Task.yield()
                turnStartedAt = clock.now
                renderedMultipleSlices = false
            }
        }

        if renderedMultipleSlices {
            await Task.yield()
        }
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        if isRenderReady, let view {
            directChunkCount += 1
            if directChunkCount <= 12 || directChunkCount == 25 || directChunkCount == 50 {
                MoshDiagnostics.log(
                    "\(traceLabel) terminal direct feed chunk#\(directChunkCount) bytes=\(bytes.count)"
                )
            }
            let filtered = filteredBytes(bytes, for: view)
            if !filtered.isEmpty {
                view.feed(byteArray: filtered[...])
            }
        } else {
            bufferedChunkCount += 1
            if bufferedChunkCount <= 12 {
                MoshDiagnostics.log(
                    "\(traceLabel) terminal buffer chunk#\(bufferedChunkCount) bytes=\(bytes.count)"
                )
            }
            pendingBytes.append(contentsOf: bytes)
        }
    }

    /// Contentoffset-correct scrollback wipe via the changeScrollback
    /// 0 → limit toggle, which keeps the visible viewport rows intact.
    /// The toggle is kept for swap + mosh symmetry; `[3J` is fixed in the
    /// fork as of d34c15f (it now resyncs the scroll view), so remote
    /// clears are safe too.
    /// Main-actor only: all feeds are main-actor; if that ever changes this
    /// becomes a data race on SwiftTerm's CircularList.
    func clearScrollback(restoringLimit limit: Int) {
        guard let view else { return }
        view.changeScrollback(0)
        view.changeScrollback(max(limit, 0))
    }

    /// Repaint the current SwiftTerm viewport from its existing terminal
    /// model. This is the local half of the user-facing force refresh; the
    /// session owner separately asks tmux or mosh for authoritative output.
    func forceRedraw() {
        guard let view else { return }
        let terminal = view.getTerminal()
        guard terminal.rows > 0 else { return }
        terminal.refresh(startRow: 0, endRow: terminal.rows - 1)
        // `Terminal.refresh` only records SwiftTerm's dirty-row range. A
        // layout pass can resubmit cached Metal buffers without consuming that
        // range, and does not redraw the CoreGraphics fallback at unchanged
        // bounds. An empty feed drives SwiftTerm's normal display scheduler,
        // which maps the dirty rows into `metalDirtyRange` (or invalidates the
        // CoreGraphics canvas) without changing the terminal model.
        view.feed(text: "")
        MoshDiagnostics.log(
            "\(traceLabel) terminal force redraw rows=\(terminal.rows) offset=\(String(format: "%.1f", view.contentOffset.y))"
        )
    }

    private func filteredBytes(_ bytes: ArraySlice<UInt8>, for view: TerminalView) -> [UInt8] {
        let container = view.superview as? TesseraTerminalContainer
        return contrastFilter.process(
            bytes,
            defaultBackgroundRGB: container?.terminalDefaultBackgroundRGB ?? 0x000000,
            defaultForegroundRGB: container?.terminalDefaultForegroundRGB ?? 0xD4D4D4,
            minimumContrast: container?.terminalMinimumContrast ?? 0.30
        )
    }
}

/// Per-tmux-window kitty keyboard mode bookkeeping for the inline `-CC`
/// path, where every tmux window shares one SwiftTerm `Terminal`.
///
/// A kitty-aware TUI (Codex, newer vims) pushes keyboard-enhancement
/// flags that live on the shared terminal, so without this store the
/// flags leak into every other window: SwiftTerm keeps encoding keys as
/// `CSI … u` and the next window's shell echoes the escape tail as
/// garbage (shift+= became `1:43;2u`). On each display swap the
/// outgoing window's keyboard mode is snapshotted and the incoming
/// window's is restored (or cleared when it has none saved).
///
/// `paneInAltScreen` is tmux's `#{alternate_on}` for the incoming pane
/// and guards against stale restores: `%output` from non-active windows
/// is dropped, so a kitty pop emitted while the window was off-screen
/// is never seen by SwiftTerm. Apps push kitty flags from the alternate
/// screen in practice, so "pane no longer in the alt screen" means the
/// saved alt-screen flags are dead and must not be restored. An app
/// that pushes flags in the *normal* buffer and pops while off-screen
/// would still restore stale — accepted; that shape does not occur in
/// real TUIs and the failure degrades to today's behavior.
///
/// Window ids are not reused within a tmux server epoch, so entries for
/// closed windows are harmless and are not pruned.
@MainActor
final class KittyWindowModeStore {
    private var snapshots: [WindowId: KittyKeyboardModeSnapshot] = [:]
    private var bracketedPaste: [WindowId: Bool] = [:]

    func displayWillSwap(
        from: WindowId?,
        to: WindowId,
        paneInAltScreen: Bool,
        terminal: Terminal
    ) {
        if let from {
            let snapshot = terminal.keyboardModeSnapshot()
            if snapshot.isEmpty {
                snapshots.removeValue(forKey: from)
            } else {
                snapshots[from] = snapshot
            }
            bracketedPaste[from] = terminal.bracketedPasteMode
        }
        guard let saved = snapshots[to] else {
            terminal.resetKeyboardMode()
            return
        }
        let restored = paneInAltScreen ? saved : saved.clearingAlternateScreenState()
        snapshots[to] = restored
        terminal.restoreKeyboardMode(restored)
    }

    /// Called after the repaint because the repaint epilogue never touches
    /// 2004. tmux's `bracket_paste_flag` is not available until post-3.6a,
    /// so Tessera keeps 2004 client-side while older tmux servers are
    /// supported. Remove this once the tmux floor can report the flag.
    func displayDidSwap(to windowId: WindowId, terminalBox: TerminalBox) {
        let wanted = bracketedPaste[windowId] ?? false
        let bytes = Array((wanted ? "\u{1B}[?2004h" : "\u{1B}[?2004l").utf8)
        terminalBox.feed(bytes[...])
    }

    func bracketedPasteEnabled(for windowId: WindowId) -> Bool? {
        bracketedPaste[windowId]
    }
}

@MainActor
private final class TmuxControlChannelBox {
    var channel: TmuxControlChannel?
}

/// Reference latch for "a scroll gesture or glide is running right now",
/// written by the terminal Coordinator and read by the prefetch scheduler.
/// A class (not @State-observed data) so writes at gesture boundaries never
/// trigger a SwiftUI invalidation.
@MainActor
private final class ScrollGestureActivityBox {
    var isActive = false
}

@MainActor
private final class MoshPaneScrollbackOverlayRuntime {
    let id = UUID()
    let paneId: PaneId
    let windowId: WindowId
    let box: TerminalBox
    var pendingScrollPlacement: MoshPaneScrollbackPlacement?
    var pendingScrollPlacementRevision = 0
    var desiredScrollOffsetY: CGFloat?
    /// Hot-buffer freshness: true while the parked capture still matches
    /// the pane's live tail — set by a completed prefetch, cleared on any
    /// pane output / terminal input / dismiss-to-park / capture-state
    /// reset. Only a fresh parked runtime may reveal without a fetch
    /// (stale content must never show).
    var isFresh = false
    /// Depth of the parked capture. `moshScrollbackDepthByPane` is cleared
    /// when the overlay dismisses, so a fresh promote restores its depth
    /// from here — top-reach fetches then continue from the right page.
    var capturedDepth = 0
    /// Identity of the TerminalView the fresh capture was actually fed
    /// into. SwiftUI can unmount the hidden overlay (pane frame goes nil
    /// during rehydration, tab switch) and remount a NEW view later — the
    /// bytes died with the old view, so `isFresh` alone would reveal a
    /// blank surface. Reveal and skip-refill decisions both go through
    /// `hasRevealableFreshContent`, which requires the current view to be
    /// the fed one.
    var freshContentViewID: ObjectIdentifier?
    /// Deep-history capture whose reply landed while a native pan or
    /// deceleration was in progress — a clear+feed then would teleport
    /// the finger. Held until the scroll settles; the settle apply is
    /// position-preserving, so it is only dropped if the gesture ended
    /// at the live tail (the reader is leaving scrollback).
    var pendingDeferredCapture: TmuxController.ScrollbackCapture?
    /// True once a native pan/deceleration has moved this overlay since
    /// its reveal. Gates the settle-time bottom dismissal: bridge writes
    /// also arrive "settled" (they come from a gesture on the SHARED
    /// surface), and without this gate a gentle reveal-scroll that stays
    /// within the bottom threshold would dismiss its own overlay.
    var sawNativeScroll = false
    /// Latched when active-pane output arrives while this overlay is
    /// REVEALED: the reader stays in scrollback (iTerm2 behavior) instead
    /// of being kicked to the live tail, but the content is now a frozen
    /// snapshot — any capture fetched from here on includes the new
    /// output, so applying one would shift the distance-from-bottom
    /// anchor and teleport the reader. Blocks every fetch/deepen/seed
    /// until the overlay dismisses (bottom return re-syncs to live).
    var contentFrozen = false
    /// One-shot latch for the native settle poll (see
    /// `armMoshOverlayNativeSettleCheck`).
    var nativeSettleCheckArmed = false

    var hasRevealableFreshContent: Bool {
        guard isFresh, let view = box.view else { return false }
        return freshContentViewID == ObjectIdentifier(view)
    }
    private var restoredScrollOffsetLogCount = 0

    init(paneId: PaneId, windowId: WindowId) {
        self.paneId = paneId
        self.windowId = windowId
        self.box = TerminalBox(traceLabel: "mosh-overlay-\(paneId.rawValue)")
    }

    func setPendingScrollPlacement(_ placement: MoshPaneScrollbackPlacement) {
        pendingScrollPlacement = placement
        pendingScrollPlacementRevision += 1
    }

    @discardableResult
    func applyDesiredScrollOffset(_ targetY: CGFloat, in view: TerminalView) -> CGFloat {
        let offsetY = clampedScrollOffsetY(targetY, in: view)
        desiredScrollOffsetY = offsetY
        if abs(view.contentOffset.y - offsetY) > 0.5 {
            view.contentOffset = CGPoint(x: view.contentOffset.x, y: offsetY)
        }
        return offsetY
    }

    func restoreDesiredScrollOffset(
        in view: TerminalView,
        onScrollDiagnostic: ((String) -> Void)? = nil
    ) {
        guard let desiredScrollOffsetY else { return }
        let offsetY = clampedScrollOffsetY(desiredScrollOffsetY, in: view)
        self.desiredScrollOffsetY = offsetY
        guard abs(view.contentOffset.y - offsetY) > 0.5 else { return }
        if restoredScrollOffsetLogCount < 12 {
            restoredScrollOffsetLogCount += 1
            let detail = "scroll-offset-restore pane=\(paneId.description) from=\(String(format: "%.1f", view.contentOffset.y)) to=\(String(format: "%.1f", offsetY)) contentHeight=\(String(format: "%.1f", view.contentSize.height)) boundsHeight=\(String(format: "%.1f", view.bounds.height))"
            MoshDiagnostics.log("mosh scrollback overlay \(detail)")
            onScrollDiagnostic?(detail)
        }
        view.contentOffset = CGPoint(x: view.contentOffset.x, y: offsetY)
    }

    func clearDesiredScrollOffset() {
        desiredScrollOffsetY = nil
    }

    /// Halt any in-flight native deceleration on the runtime's view (a
    /// same-offset setContentOffset ends UIScrollView momentum). A hidden
    /// view must never remain "natively active": its ghost motion would
    /// keep moving the parked offset and trip every isDecelerating check.
    func stopNativeScrollMotion() {
        guard let view = box.view,
              view.isDragging || view.isDecelerating
        else { return }
        view.setContentOffset(view.contentOffset, animated: false)
    }

    private func clampedScrollOffsetY(_ y: CGFloat, in view: TerminalView) -> CGFloat {
        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        return min(max(0, y), maxOffsetY)
    }
}

private enum MoshPaneScrollbackPlacement {
    case top
    case bottomMinus(CGFloat)
    case absolute(CGFloat)

    var requiresScrollableContent: Bool {
        switch self {
        case .top:
            return false
        case .bottomMinus:
            return true
        case .absolute(let y):
            return y > 0
        }
    }

    var logDescription: String {
        switch self {
        case .top:
            return "top"
        case .bottomMinus(let points):
            return "bottom-minus-\(String(format: "%.1f", points))"
        case .absolute(let y):
            return "absolute-\(String(format: "%.1f", y))"
        }
    }
}

private struct MoshPaneChromeSnapshot {
    let windowId: WindowId
    let layout: WindowLayout
    let activePaneId: PaneId?
    let panes: [TmuxController.PaneInfo]
    let windowName: String?
}

private enum MoshSideChannelState: Equatable {
    case idle
    case connecting(attempt: Int)
    case connected
    case reconnecting(lastError: String?, retryAttempt: Int, nextRetryDelay: TimeInterval?)
    case degraded(lastError: String?)
    case failed(lastError: String?)

    var isControlUnavailable: Bool {
        switch self {
        case .reconnecting, .degraded, .failed:
            return true
        case .idle, .connecting, .connected:
            return false
        }
    }

    var showsPersistentWarning: Bool {
        switch self {
        case .reconnecting, .degraded, .failed:
            return true
        case .idle, .connecting, .connected:
            return false
        }
    }

    var tcpControlStatus: MoshTcpControlStatus {
        switch self {
        case .connected:
            return .connected
        case .connecting, .reconnecting:
            return .retrying
        case .idle, .degraded, .failed:
            return .disconnected
        }
    }

    var blocksTmuxCommands: Bool {
        switch self {
        case .reconnecting, .degraded, .failed:
            return true
        case .idle, .connecting, .connected:
            return false
        }
    }

    var compactLabel: String {
        switch self {
        case .reconnecting:
            return "tmux reconnecting"
        case .failed:
            return "tmux failed"
        case .degraded:
            return "tmux offline"
        case .idle:
            return "tmux idle"
        case .connecting:
            return "tmux connecting"
        case .connected:
            return "tmux connected"
        }
    }

    var controlStateText: String {
        switch self {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reconnecting:
            return "reconnecting"
        case .degraded:
            return "degraded"
        case .failed:
            return "failed"
        }
    }

    var lastErrorText: String? {
        switch self {
        case .reconnecting(let lastError, _, _),
             .degraded(let lastError),
             .failed(let lastError):
            return lastError
        case .idle, .connecting, .connected:
            return nil
        }
    }

    var retryText: String? {
        switch self {
        case .connecting(let attempt):
            return "attempt \(attempt)"
        case .reconnecting(_, let retryAttempt, let nextRetryDelay):
            if let nextRetryDelay {
                return "attempt \(retryAttempt), next in \(Self.formatDelay(nextRetryDelay))"
            }
            return "attempt \(retryAttempt)"
        case .idle, .connected, .degraded, .failed:
            return nil
        }
    }

    var logDescription: String {
        switch self {
        case .idle:
            return "idle"
        case .connecting(let attempt):
            return "connecting(attempt=\(attempt))"
        case .connected:
            return "connected"
        case .reconnecting(let lastError, let retryAttempt, let nextRetryDelay):
            return "reconnecting(attempt=\(retryAttempt),backoff=\(nextRetryDelay.map(Self.formatDelay) ?? "active"),error=\(lastError ?? "nil"))"
        case .degraded(let lastError):
            return "degraded(error=\(lastError ?? "nil"))"
        case .failed(let lastError):
            return "failed(error=\(lastError ?? "nil"))"
        }
    }

    private static func formatDelay(_ delay: TimeInterval) -> String {
        if delay.rounded() == delay {
            return "\(Int(delay))s"
        }
        return String(format: "%.1fs", delay)
    }
}

private enum MoshTcpControlStatus: Equatable {
    case connected
    case retrying
    case disconnected

    var text: String {
        switch self {
        case .connected:
            return "connected"
        case .retrying:
            return "retrying"
        case .disconnected:
            return "disconnected"
        }
    }
}

private enum SessionConnectionStatus: Equatable {
    case ssh(state: SessionState)
    case mosh(
        sessionState: SessionState,
        transportState: MoshTransportState,
        tcpControl: MoshTcpControlStatus?
    )

    var dotColor: SwiftUI.Color {
        switch self {
        case .ssh(let state):
            return Self.dotColor(for: state)
        case .mosh(let sessionState, let transportState, let tcpControl):
            switch sessionState {
            case .connected:
                switch transportState {
                case .connected:
                    break
                case .connecting, .idle:
                    return SwiftUI.Color.yellow.opacity(0.9)
                case .disconnected:
                    return SwiftUI.Color.red
                }
                guard let tcpControl else {
                    return SwiftUI.Color.green
                }
                return tcpControl == .connected
                    ? SwiftUI.Color.green
                    : SwiftUI.Color.yellow.opacity(0.9)
            case .connecting:
                return SwiftUI.Color.yellow.opacity(0.9)
            case .idle:
                return SwiftUI.Color.gray
            case .disconnected, .failed:
                return SwiftUI.Color.red
            }
        }
    }

    var lines: [String] {
        switch self {
        case .ssh(let state):
            return ["ssh: \(Self.binaryTransportText(for: state))"]
        case .mosh(let sessionState, let transportState, let tcpControl):
            var lines = [
                "mosh: \(Self.binaryMoshText(for: transportState, sessionState: sessionState))",
            ]
            if let tcpControl {
                let controlText = Self.binaryTransportText(for: sessionState) == "connected"
                    ? tcpControl.text
                    : "disconnected"
                lines.append("tcp control: \(controlText)")
            }
            return lines
        }
    }

    private static func dotColor(for state: SessionState) -> SwiftUI.Color {
        switch state {
        case .idle:
            return .gray
        case .connecting:
            return .yellow
        case .connected:
            return .green
        case .disconnected, .failed:
            return .red
        }
    }

    private static func binaryTransportText(for state: SessionState) -> String {
        if case .connected = state {
            return "connected"
        }
        return "disconnected"
    }

    private static func binaryMoshText(
        for transportState: MoshTransportState,
        sessionState: SessionState
    ) -> String {
        guard case .connected = sessionState else { return "disconnected" }
        return transportState == .connected ? "connected" : "disconnected"
    }
}

/// 600 ms accent stroke fade — attached to a tmux tab pill the moment its
/// window emits BEL. Self-animates from `0.85 → 0` opacity once on appear;
/// re-mounted via `.id(bellController.lastBellAt)` so back-to-back bells
/// retrigger cleanly.
private struct BellGlowOverlay: View {
    let color: SwiftUI.Color
    @State private var opacity: Double = 0.85

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(color, lineWidth: 2)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.6)) { opacity = 0 }
            }
    }
}

private extension TesseraTmuxShortcut {
    var logDescription: String {
        switch self {
        case .newWindow:
            return "newWindow"
        case .killCurrentWindow:
            return "killCurrentWindow"
        case .previousWindow:
            return "previousWindow"
        case .nextWindow:
            return "nextWindow"
        case .selectWindow(let position):
            return "selectWindow(\(position))"
        case .splitPaneHorizontal:
            return "splitPaneHorizontal"
        case .splitPaneVertical:
            return "splitPaneVertical"
        case .cyclePaneNext:
            return "cyclePaneNext"
        case .cyclePanePrevious:
            return "cyclePanePrevious"
        case .zoomPane:
            return "zoomPane"
        }
    }
}

/// Always-visible top chrome bar that lives in the corner-inset area
/// above the terminal content (§3.5 R3.5.2).
///
/// The bar has two layouts driven by the tmux controller's mode:
///
/// **Passthrough (no tmux)** — single-row status line:
///
///     ● user@127.0.0.1:22  connecting…                   back
///
/// **tmux control mode** — iTerm2-style tab strip:
///
///     ● tmux  [editor]  logs  zsh                          back
///
/// The active tab is highlighted; inactive tabs are dimmed. Tab
/// labels default to the `@N` window id until tmux sends a
/// `%window-renamed` notification with a real name. Commit B makes
/// the tabs visual-only; commit C (§3.2) will make taps trigger
/// `select-window -t :N` and bind ⌘1-9.
///
/// Text is inset horizontally by `horizontalInset` (the display
/// corner radius) so characters clear the rounded corners. The
/// background extends edge-to-edge because it's solid black and
/// matches the safe-area fill behind the terminal — no visual seam
/// at the corners.
private struct PendingTmuxWindowClose {
    let window: TmuxController.WindowInfo
    let controlConnectionGeneration: UInt64
}

/// Browser-style close affordance for a tmux tab. The circle stays visible at
/// rest so the X reads as a button, brightens under the iPad pointer, and
/// compresses into a stronger fill while touch or pointer input is held down.
private struct TmuxTabCloseButton: View {
    let name: String
    let windowID: Int
    let isActive: Bool
    let isAvailable: Bool
    let accessibilityHint: String
    let scale: CGFloat
    let T: DesignTokens
    /// Accessibility-identifier namespace. The overflow window list renders a
    /// second close affordance for every window while it's open; namespacing
    /// keeps those from colliding with the strip's identifiers in UI queries.
    var idNamespace: String = "tmux-window"
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: max(7.5, 8.5 * scale), weight: .semibold))
                .frame(
                    width: max(15, 16 * scale),
                    height: max(15, 16 * scale)
                )
        }
        .buttonStyle(
            TmuxTabCloseButtonStyle(
                isActive: isActive,
                isAvailable: isAvailable,
                isHovered: isHovered,
                scale: scale,
                T: T
            )
        )
        .disabled(!isAvailable)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Close \(name) tmux window")
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("\(idNamespace)-\(windowID)-close")
    }
}

private struct TmuxTabCloseButtonStyle: ButtonStyle {
    let isActive: Bool
    let isAvailable: Bool
    let isHovered: Bool
    let scale: CGFloat
    let T: DesignTokens

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground(isPressed: configuration.isPressed))
            .background {
                Circle()
                    .fill(background(isPressed: configuration.isPressed))
            }
            .overlay {
                Circle()
                    .strokeBorder(
                        border(isPressed: configuration.isPressed),
                        lineWidth: max(0.8, scale)
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .frame(width: max(28, 28 * scale), height: 24 * scale)
            // Largest hit frame the tab allows without overlapping the
            // window-select button: absorb the label's old 7pt-scaled
            // trailing gap and stand up to the bar's full 32pt-scaled
            // height (iPadOS 26 expands sub-44pt targets itself and
            // mis-assigns taps between adjacent small controls — this
            // close is destructive, so mis-taps matter).
            .padding(.leading, 7 * scale)
            .frame(height: 32 * scale)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.1), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func foreground(isPressed: Bool) -> SwiftUI.Color {
        guard isAvailable else { return T.fgFaint.opacity(0.45) }
        if isPressed || isHovered { return T.fg }
        return isActive ? T.fgMuted : T.fgDim
    }

    private func background(isPressed: Bool) -> SwiftUI.Color {
        guard isAvailable else { return SwiftUI.Color.clear }
        if isPressed { return T.fg.opacity(T.isLight ? 0.16 : 0.24) }
        if isHovered { return T.fg.opacity(T.isLight ? 0.09 : 0.14) }
        return T.fg.opacity(T.isLight ? 0.04 : 0.06)
    }

    private func border(isPressed: Bool) -> SwiftUI.Color {
        guard isAvailable else { return T.fgFaint.opacity(0.4) }
        if isPressed { return T.fg }
        if isHovered { return T.fgMuted }
        return isActive ? T.fgDim : T.fgFaint
    }
}

private struct SessionTopBar: View {
    let state: SessionState
    let host: Host
    let sessionID: UUID
    let sessionIsActive: Bool
    let tmux: TmuxController
    let tmuxIsDegraded: Bool
    let connectionStatus: SessionConnectionStatus
    let onToggleSidebar: () -> Void
    let sidebarVisible: Bool
    let onBack: () -> Void
    let onDisconnect: () -> Void
    /// Find-in-scrollback controller. Backs the trailing `⌕` button:
    /// tap toggles `findController.isOpen`, which makes the parent
    /// session view render the `FindBar` strip just below this top
    /// bar. The button lights up `accentSoft` while the bar is open
    /// to mirror the active-tab highlight.
    let findController: FindController
    /// Remote Files panel toggle — the trailing `folder` glyph between
    /// find and the forwarding chip. Accent-tinted while the panel is
    /// open, mirroring the find button's toggled treatment.
    let filesPanelOpen: Bool
    let onToggleFiles: () -> Void
    /// Drives the per-tab bell glow + badge dot. `bellingWindows` set
    /// on `tmux` accumulates inactive-window bells; `BellController`
    /// publishes `lastBellAt` for transient glow animations.
    let bellController: BellController
    /// Live PortForwarderManager for this session. SSH sessions pass it
    /// in so the `⇄ N` chip can render between the find button and the
    /// home button. Mosh sessions pass nil — forwarding is SSH-only.
    /// The chip auto-hides when the manager has zero forwarders, so a
    /// session with no rules looks identical to before.
    let forwarderManager: PortForwarderManager?
    /// Chrome tokens derived from the active TerminalTheme so the top bar
    /// matches the canvas color the user picked. Built once per render by
    /// the parent SessionView (see `themeChromeTokens` there); semantic
    /// state colors (green/amber/red) stay fixed across themes.
    let T: DesignTokens
    @State private var statusBreakdownVisible = false
    @State private var integrationPopoverVisible = false
    @State private var attentionPopoverVisible = false
    @State private var integrationHelpVisible = false
    @State private var integrationConfirmationVisible = false
    @State private var pendingIntegrationAction: AgentIntegrationFixAction?
    @State private var pendingWindowClose: PendingTmuxWindowClose?
    @State private var compactUtilitiesVisible = false
    /// Close confirmation staged by the window-list popover, held until the
    /// popover's content reports `onDisappear` (dismissal actually complete)
    /// before it becomes `pendingWindowClose`.
    @State private var stagedWindowListClose: PendingTmuxWindowClose?
    /// Overflow window-list popover, anchored on the `chevron.down` button
    /// that appears when the tab strip overflows. Touch-scrolling the strip
    /// fights the iPadOS window-drag region at the top screen edge, so the
    /// list gives touch users a direct pick; trackpad scrolling is untouched.
    @State private var windowListVisible = false
    /// Tab-strip content frame in the scroll view's coordinate space.
    /// Width feeds the overflow check; minX/maxX drive the edge-fade
    /// hints while the strip is scrolled away from either end.
    @State private var tabStripContentFrame = CGRect.zero
    /// Visible width of the tab strip's scroll viewport.
    @State private var tabStripVisibleWidth: CGFloat = 0
    /// Whether the strip currently overflows (chevron visible). Held as
    /// state, not derived, because the check needs hysteresis — see
    /// `updateTabStripOverflow()`.
    @State private var tabStripOverflows = false

    /// Live appearance prefs — read for `topBarHeight`, which drives the
    /// `scale` multiplier applied to every icon, pill, dot, and font
    /// inside the bar. Flows down from SessionView/MoshSessionView's
    /// environment automatically; SessionTopBar isn't constructed
    /// outside those views.
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(AgentCenter.self) private var agentCenter
    @Environment(AppPhase.self) private var appPhase
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isPhone: Bool {
        CompactLayout.isPhone(horizontalSizeClass)
    }

    /// Multiplier applied to every numeric literal inside the bar.
    /// 32pt is the v2 design baseline — at that height every element
    /// renders at its intrinsic size; smaller picks make icons/text
    /// shrink proportionally, larger picks grow them. Capped at 0.6
    /// to keep ⌘N hints legible at the slider's 26pt floor.
    private var scale: CGFloat {
        max(0.6, CGFloat(appearance.topBarHeight) / CGFloat(AppearancePreferences.defaultTopBarHeight))
    }

    /// Horizontal inset of the floating pill from the screen edges. Small
    /// enough to clear the iPad's display corner radius (a point this far in
    /// from the corner is inside the visible rounded screen) while still
    /// reading as a floating element with bg gutter on either side.
    static let floatSideInset: CGFloat = 10
    /// Gap above the pill, between the top safe area and the pill.
    static let floatTopInset: CGFloat = 8
    /// Gap below the pill before the find bar / terminal begins.
    static let floatBottomInset: CGFloat = 8

    /// Total vertical space the floating bar reserves in the session VStack:
    /// the pill itself plus its top and bottom gaps. The session views key
    /// their `.frame(height:)` and the banner / swipe-pad top offsets off
    /// this so everything tracks the user's `topBarHeight` slider together.
    static func reservedHeight(pillHeight: Double, compact: Bool) -> CGFloat {
        let height: CGFloat = compact ? 44 : CGFloat(pillHeight)
        return height + floatTopInset + floatBottomInset
    }

    /// The pill outline. Corner radius scales with the bar so the rounding
    /// stays proportional across the 26–44pt height range (≈13pt at the 32pt
    /// baseline, mirroring the mockup's 13/34 ratio). Always < half the pill
    /// height, so it's a rounded rect, never an unintended capsule.
    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isPhone ? 16 : 13 * scale, style: .continuous)
    }

    /// "on iPhone" chip shown while another device holds the shared grid —
    /// keeps the takeover visible in the chrome even though the veil owns
    /// the terminal area. iPad-width bar only; the compact phone bar has no
    /// room and the veil itself is the signal there.
    private func continuedElsewhereChip(peerName: String) -> some View {
        let selfName = GridAuthorityDeviceIdentity.selfDisplayName
        let label = peerName == selfName ? "on another \(peerName)" : "on \(peerName)"
        return HStack(spacing: 5 * scale) {
            Image(systemName: peerName == "iPhone" ? "iphone" : "ipad.landscape")
                .font(.system(size: 10 * scale, weight: .medium))
            Text(label)
                .font(Typography.tesseraMonoFixed(size: 10.5 * scale, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(T.fgMuted)
        .padding(.horizontal, 9 * scale)
        .frame(height: 22 * scale)
        .overlay {
            Capsule().stroke(T.borderStrong, lineWidth: 0.5)
        }
        .padding(.horizontal, 4 * scale)
    }

    var body: some View {
        Group {
            if isPhone {
                compactBarCore
            } else {
                // Spacing 0 — every child owns half of each 8pt-scaled gap
                // (chrome buttons via their full-pitch hit frames, pills via
                // 4pt-scaled padding) so glyph centers stay put while the
                // hit frames meet edge-to-edge.
                HStack(spacing: 0) {
            // Sidebar toggle — replaces the system NavigationSplitView
            // toggle that would otherwise float above us and waste the
            // entire top strip. A three-bar `line.3.horizontal` "menu"
            // glyph (the widely-recognized show-sidebar affordance); the
            // accent tint (via isToggled) reinforces the open state. The
            // sidebar floats over the terminal, so toggling never resizes
            // the grid — collapse it again from here or the in-panel ‹.
            chromeIconButton(
                systemName: "line.3.horizontal",
                isToggled: sidebarVisible,
                action: onToggleSidebar
            )

            // Leading region swaps between "connection status" (no
            // tmux) and "tmux tab strip" (tmux active). The home
            // button sits on the trailing edge of both layouts so the
            // bar reads symmetrically.
            if (tmux.mode == .tmuxControl || tmuxIsDegraded) && !tmux.windows.isEmpty {
                tabStrip
            } else {
                passthroughStatus
                Spacer(minLength: 8)
            }

            if let peerName = tmux.gridAuthority.peerDisplayName {
                continuedElsewhereChip(peerName: peerName)
            }

            // Find-in-scrollback toggle. Slot between the (tmux-only)
            // window controls and the trailing `house` so the home button
            // stays anchored at the far edge regardless of which
            // layout the bar is in.
            chromeIconButton(
                systemName: "magnifyingglass",
                isToggled: findController.isOpen,
                action: {
                    if findController.isOpen {
                        findController.close()
                    } else {
                        findController.open()
                    }
                }
            )
            .disabled(tmux.gridAuthority.isPeer)
            .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)

            // Remote Files panel toggle (⌘⇧E). Sits with the other
            // trailing utilities so the home button stays anchored.
            chromeIconButton(
                systemName: "folder",
                isToggled: filesPanelOpen,
                action: onToggleFiles
            )

            // Port forwarding indicator. Hides when the session has no
            // forwarders defined; otherwise shows `⇄ N` with the running
            // listener count, opens a popover sheet on tap.
            if let forwarderManager {
                ForwardingStatusChip(
                    manager: forwarderManager,
                    scale: scale,
                    T: T
                )
            }

            if appearance.agentCenterEnabled,
               sessionIsActive,
               appPhase.isActive,
               !agentCenter.sortedUnreadAttentions.isEmpty {
                agentAttentionButton
            }

            chromeIconButton(
                systemName: "arrow.clockwise",
                action: requestTerminalForceRefresh
            )
            .disabled(state != .connected || !sessionIsActive || tmux.gridAuthority.isPeer)
            .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
            .accessibilityLabel("Refresh terminal")

            // Home — returns to the host landing. Mirrors the leading
            // sidebar toggle's icon-button style for visual symmetry,
            // replacing the v1 `back` text label which carried no
            // affordance hint.
            chromeIconButton(systemName: "house", action: onBack)

                    if appearance.agentCenterEnabled,
                       state == .connected,
                       currentIntegrationState.showsWarning {
                        agentIntegrationWarningButton
                    }
                }
            }
        }
        // Inner content inset (mockup uses 8px); the floating pill's own
        // side margin handles clearing the display corners, so this stays
        // small instead of the full corner-radius inset the edge-to-edge
        // bar needed. Halved because the edge buttons' full-pitch hit
        // frames carry the other half — the visual inset is unchanged.
        .padding(.horizontal, isPhone ? 5 : 4 * scale)
        .frame(maxWidth: .infinity)
        .frame(height: isPhone ? 44 : appearance.topBarHeight)
        // The bar is fixed-height chrome, so its text caps Dynamic Type
        // growth per label via chromeBarTextCap() rather than a cap on this
        // container — several bar buttons present sheets/popovers, and
        // presented content inherits the attachment view's environment, so a
        // container-level cap would wrongly limit full modal content too.
        // Same floating material + tint + solid fill as the sidebar, so all
        // chrome reads as one Liquid Glass layer and tracks `chromeMaterial`
        // together. Clipped to a fully-rounded pill (all four corners) rather
        // than an edge-to-edge rectangle — the bar floats over the canvas with
        // a bg gutter around it, matching the sidebar-rework mockup.
        .floatingGlass(
            appearance.chromeMaterial,
            tint: T.sidebarBg,
            solidFill: T.isLight ? SwiftUI.Color(rgbInt: 0xF2F2F7) : SwiftUI.Color(rgbInt: 0x1C1C1E),
            in: pillShape
        )
        // Full hairline ring around the pill (was a bottom-only divider on the
        // square bar). `strokeBorder` insets the stroke so it isn't clipped by
        // the pill's own corner-clip.
        .overlay(pillShape.strokeBorder(T.border, lineWidth: 0.5))
        .padding(.top, Self.floatTopInset)
        .padding(.bottom, Self.floatBottomInset)
        .padding(.horizontal, Self.floatSideInset)
        .task(id: integrationRefreshKey) {
            guard appearance.agentCenterEnabled,
                  sessionIsActive,
                  appPhase.isActive,
                  state == .connected
            else {
                agentCenter.cancelCurrentIntegrationRequest(sessionID: sessionID)
                return
            }
            agentCenter.requestCurrentIntegrationRefresh(
                sessionID: sessionID,
                supersedeCurrent: true,
                reason: "surface-change"
            )
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                agentCenter.requestCurrentIntegrationRefresh(
                    sessionID: sessionID,
                    reason: "periodic"
                )
            }
        }
        .task(id: attentionVisibilityKey) {
            agentCenter.setVisibleTarget(
                sessionID: sessionID,
                windowID: visibleAgentWindowID,
                paneID: visibleAgentPaneID,
                isVisible: agentSurfaceIsSelected
            )
        }
        .onChange(of: tmux.gridAuthority.isPeer) { _, yielded in
            guard yielded else { return }
            findController.close()
            windowListVisible = false
            stagedWindowListClose = nil
            pendingWindowClose = nil
        }
        .onDisappear {
            agentCenter.cancelCurrentIntegrationRequest(sessionID: sessionID)
            agentCenter.setVisibleTarget(
                sessionID: sessionID,
                windowID: visibleAgentWindowID,
                paneID: visibleAgentPaneID,
                isVisible: false
            )
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TESSERA_AGENT_INTEGRATION_WARNING_HARNESS"] == "1",
               ProcessInfo.processInfo.environment["TESSERA_AGENT_INTEGRATION_WARNING_AUTO_OPEN"] != "0" {
                integrationPopoverVisible = true
            }
            if ProcessInfo.processInfo.environment["TESSERA_TMUX_WINDOW_CLOSE_HARNESS"] == "1",
               ProcessInfo.processInfo.environment["TESSERA_TMUX_WINDOW_CLOSE_AUTO_CONFIRM"] == "1",
               let window = tmux.windows.first(where: { $0.paneCount > 1 }) {
                pendingWindowClose = PendingTmuxWindowClose(
                    window: window,
                    controlConnectionGeneration: tmux.controlConnectionGeneration
                )
            }
            if ProcessInfo.processInfo.environment["TESSERA_AGENT_ATTENTION_HARNESS"] == "1",
               ProcessInfo.processInfo.environment["TESSERA_AGENT_ATTENTION_AUTO_OPEN"] == "1" {
                attentionPopoverVisible = true
            }
            #endif
        }
        .sheet(isPresented: $integrationHelpVisible) {
            AgentLifecycleIntegrationHelpView()
        }
        .alert(integrationConfirmationTitle, isPresented: $integrationConfirmationVisible) {
            Button("Cancel", role: .cancel) {
                pendingIntegrationAction = nil
            }
            Button("Help") {
                pendingIntegrationAction = nil
                Task { @MainActor in
                    await Task.yield()
                    integrationHelpVisible = true
                }
            }
            Button(integrationConfirmationLabel) {
                let requestedAction = pendingIntegrationAction
                pendingIntegrationAction = nil
                guard currentIntegrationState.supports(requestedAction) else { return }
                agentCenter.fixCurrentIntegration(
                    sessionID: sessionID,
                    action: requestedAction
                )
                integrationPopoverVisible = true
            }
        } message: {
            Text(integrationConfirmationMessage)
        }
        .alert(
            "Close tmux window?",
            isPresented: Binding(
                get: { pendingWindowClose != nil },
                set: { if !$0 { pendingWindowClose = nil } }
            ),
            presenting: pendingWindowClose
        ) { request in
            Button(closeConfirmationActionLabel(for: request.window), role: .destructive) {
                pendingWindowClose = nil
                guard request.controlConnectionGeneration == tmux.controlConnectionGeneration,
                      tmux.isWindowListHydrated,
                      tmux.windows.contains(where: { $0.id == request.window.id })
                else { return }
                tmux.killWindow(request.window.id)
            }
            Button("Cancel", role: .cancel) {
                pendingWindowClose = nil
            }
        } message: { request in
            Text(closeConfirmationMessage(for: request.window))
        }
        .onChange(of: tmux.controlConnectionGeneration) {
            pendingWindowClose = nil
        }
        // The popover auto-dismisses when its chevron anchor leaves the
        // hierarchy (enough windows closed that the strip fits again);
        // keep the state in sync so the chevron isn't born re-toggled.
        .onChange(of: tabStripOverflows) { _, overflows in
            if !overflows { windowListVisible = false }
        }
        .onChange(of: sessionRegistry.tmuxCloseRequest?.token) { _, _ in
            handleCompactTmuxCloseRequest()
        }
        .onChange(of: sessionRegistry.tmuxMutationRequest?.token) { _, _ in
            handleCompactTmuxMutationRequest()
        }
        .onChange(of: tmux.windows.map(\.id)) { _, windowIDs in
            guard let pendingWindowClose,
                  !windowIDs.contains(pendingWindowClose.window.id)
            else { return }
            self.pendingWindowClose = nil
        }
    }

    private func handleCompactTmuxCloseRequest() {
        guard let request = sessionRegistry.tmuxCloseRequest,
              tmux.mode == .tmuxControl,
              !tmuxIsDegraded,
              tmux.isWindowListHydrated
        else { return }

        switch request.action {
        case .pane(let requestedSessionID, let windowID, let paneID):
            guard requestedSessionID == sessionID,
                  let window = tmux.windows.first(where: { $0.id == windowID }),
                  window.paneCount > 1,
                  window.panes.contains(where: { $0.id == paneID })
            else { return }
            tmux.killPane(paneID)

        case .window(let requestedSessionID, let windowID):
            guard requestedSessionID == sessionID,
                  let window = tmux.windows.first(where: { $0.id == windowID })
            else { return }
            if window.paneCount > 1 || tmux.isWindowLayoutPending(windowID) {
                pendingWindowClose = PendingTmuxWindowClose(
                    window: window,
                    controlConnectionGeneration: tmux.controlConnectionGeneration
                )
            } else {
                tmux.killWindow(windowID)
            }
        }
    }

    private func handleCompactTmuxMutationRequest() {
        guard let request = sessionRegistry.tmuxMutationRequest,
              tmux.mode == .tmuxControl,
              !tmuxIsDegraded
        else { return }
        switch request.action {
        case .split(let requestedSessionID, let paneID, let axis):
            guard requestedSessionID == sessionID else { return }
            tmux.splitPane(paneID, axis: axis)
        case .rename(let requestedSessionID, let windowID, let name):
            guard requestedSessionID == sessionID else { return }
            tmux.renameWindow(windowID, to: name)
        }
    }

    private var compactBarCore: some View {
        // Keep Files + Refresh inline whenever the host switcher still has a
        // usable floor. Display Zoom can reduce a supported iPhone to a
        // 320pt-wide layout; with tmux + forwarding active, seven fixed 40pt
        // controls leave only 10pt for the switcher. The fallback collapses
        // those two utilities behind one popover without shrinking touch
        // targets or dropping either action.
        ViewThatFits(in: .horizontal) {
            compactBarContent(collapsesUtilities: false)
            compactBarContent(collapsesUtilities: true)
        }
    }

    private func compactBarContent(collapsesUtilities: Bool) -> some View {
        // Spacing 0 — each icon button's 40pt full-pitch hit frame carries
        // 1pt of the old 2pt gap on each side, so glyph centers stay put
        // while the hit frames meet edge-to-edge.
        HStack(spacing: 0) {
            compactIconButton(
                systemName: "chevron.left",
                label: "Back — session keeps running",
                action: onBack
            )

            Button(action: openCompactSwitcher) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 7, height: 7)
                    Text(host.name.isEmpty ? host.address : host.name)
                        .font(Typography.tesseraMono(size: 12, weight: .medium))
                        .foregroundStyle(T.fg)
                        .lineLimit(1)
                    if compactIntegrationNotice != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(T.amber)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(T.fgMuted)
                }
                .chromeBarTextCap()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .frame(minWidth: 44, maxWidth: .infinity)
            .buttonStyle(.plain)
            .accessibilityLabel(compactSwitcherAccessibilityLabel)
            .accessibilityIdentifier("compact-session-switcher")

            if (tmux.mode == .tmuxControl || tmuxIsDegraded),
               !tmux.windows.isEmpty {
                compactIconButton(
                    systemName: "plus",
                    label: "New tmux window",
                    action: { tmux.newWindow() }
                )
                .disabled(tmuxIsDegraded || tmux.gridAuthority.isPeer)
                .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
                .accessibilityIdentifier("tmux-new-window")
            }

            compactIconButton(
                systemName: "magnifyingglass",
                label: "Find in terminal",
                isToggled: findController.isOpen
            ) {
                findController.isOpen ? findController.close() : findController.open()
            }
            .disabled(tmux.gridAuthority.isPeer)
            .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
            if collapsesUtilities {
                compactIconButton(
                    systemName: "ellipsis",
                    label: "More terminal actions",
                    isToggled: filesPanelOpen,
                    action: { compactUtilitiesVisible = true }
                )
                .popover(isPresented: $compactUtilitiesVisible, arrowEdge: .top) {
                    compactUtilityActions
                        .presentationCompactAdaptation(.popover)
                }
            } else {
                compactIconButton(
                    systemName: "folder",
                    label: "Files",
                    isToggled: filesPanelOpen,
                    action: onToggleFiles
                )
            }
            CompactForwardingStatusButton(manager: forwarderManager, T: T)
            if !collapsesUtilities {
                compactIconButton(
                    systemName: "arrow.clockwise",
                    label: "Refresh terminal",
                    action: requestTerminalForceRefresh
                )
                .disabled(state != .connected || !sessionIsActive || tmux.gridAuthority.isPeer)
                .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
            }
            compactIconButton(
                systemName: "xmark",
                label: "Disconnect",
                tint: T.red,
                action: onDisconnect
            )
        }
    }

    private var compactUtilityActions: some View {
        VStack(spacing: 0) {
            compactUtilityAction(
                systemName: "folder",
                title: filesPanelOpen ? "Close Files" : "Files"
            ) {
                compactUtilitiesVisible = false
                onToggleFiles()
            }
            compactUtilityAction(
                systemName: "arrow.clockwise",
                title: "Refresh terminal"
            ) {
                compactUtilitiesVisible = false
                requestTerminalForceRefresh()
            }
            .disabled(state != .connected || !sessionIsActive || tmux.gridAuthority.isPeer)
            .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
        }
        .padding(6)
        .frame(width: 210)
        .background(T.presentationBg)
    }

    private func compactUtilityAction(
        systemName: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(Typography.tesseraMono(size: 12, weight: .medium))
                .foregroundStyle(T.fg)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func requestTerminalForceRefresh() {
        NotificationCenter.default.post(name: .tesseraForceRefreshTerminal, object: nil)
    }

    private func compactIconButton(
        systemName: String,
        label: String,
        isToggled: Bool = false,
        tint: SwiftUI.Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint ?? (isToggled ? T.accent : T.fgMuted))
                .frame(width: 38, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isToggled ? T.accentSoft : SwiftUI.Color.clear)
                )
                // 38pt visual box inside the bar's full 40pt button pitch
                // (bar spacing is 0; six 44pt frames don't fit compact
                // widths — iPadOS 26 expands sub-44pt targets itself and
                // mis-assigns taps between adjacent small controls).
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func openCompactSwitcher() {
        let windows = tmux.windows.map { window in
            CommandPaletteTmuxWindow(
                id: window.id,
                title: window.displayName,
                panes: window.panes.map { pane in
                    CommandPaletteTmuxPane(
                        id: pane.id,
                        title: compactPaneTitle(pane, window: window),
                        command: pane.currentCommand
                    )
                }
            )
        }
        let activeTitle = tmux.activeWindowId.flatMap { activeID in
            tmux.windows.first(where: { $0.id == activeID })?.displayName
        }
        commandPalette.open(
            sessions: sessionRegistry.activeSessions,
            agents: appearance.agentCenterEnabled ? agentCenter.sortedAgents : [],
            paneTitles: activeTitle.map { [sessionID: $0] } ?? [:],
            lastTouched: sessionRegistry.lastTouched,
            tmuxWindows: windows,
            currentSessionID: sessionID,
            activeWindowID: tmux.activeWindowId,
            activePaneID: tmux.activePaneId,
            includesHome: true,
            allowsTmuxMutation: tmux.mode == .tmuxControl
                && !tmuxIsDegraded
                && !tmux.gridAuthority.isPeer,
            notice: compactIntegrationNotice,
            onNoticeAction: handleCompactIntegrationNotice
        )
    }

    private var compactIntegrationNotice: CommandPaletteNotice? {
        guard appearance.agentCenterEnabled,
              state == .connected,
              currentIntegrationState.showsWarning else { return nil }
        return CommandPaletteNotice(
            title: currentIntegrationState.title,
            message: currentIntegrationState.message,
            actionLabel: currentIntegrationState.actionLabel
        )
    }

    private var compactSwitcherAccessibilityLabel: String {
        guard let notice = compactIntegrationNotice else {
            return "Switch session, window, or pane"
        }
        return "Switch session, window, or pane. \(notice.title)"
    }

    private func handleCompactIntegrationNotice() {
        if let action = currentIntegrationState.action {
            pendingIntegrationAction = action
            integrationConfirmationVisible = true
        } else {
            integrationPopoverVisible = true
        }
    }

    private func compactPaneTitle(
        _ pane: TmuxController.PaneInfo,
        window: TmuxController.WindowInfo
    ) -> String {
        if !pane.titleIsDefault,
           let title = pane.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let command = pane.currentCommand, !command.isEmpty { return command }
        return window.displayName
    }

    private func closeConfirmationActionLabel(
        for window: TmuxController.WindowInfo
    ) -> String {
        window.paneCount > 1 ? "Close all \(window.paneCount) panes" : "Close window"
    }

    private func closeConfirmationMessage(
        for window: TmuxController.WindowInfo
    ) -> String {
        guard window.paneCount > 1 else {
            // Reachable only while the window's details query is in flight:
            // the pane count is still a guess (link-window/move-window can
            // add an already-split window), so the close fails closed with
            // a generic confirmation instead of a promptless kill.
            return "“\(window.name)” is still syncing its pane layout. "
                + "Closing this window will close every pane it contains."
        }
        return "“\(window.name)” contains \(window.paneCount) panes. Closing this window will close every pane in it."
    }

    private var currentIntegrationState: AgentIntegrationWarningState {
        agentCenter.currentIntegrationState(sessionID: sessionID)
    }

    private var integrationRefreshKey: String {
        [
            appearance.agentCenterEnabled ? "enabled" : "disabled",
            sessionIsActive ? "active" : "background",
            appPhase.isActive ? "foreground" : "app-background",
            String(describing: state),
            String(describing: tmux.mode),
            tmux.activeWindowId?.description ?? "raw",
            tmux.activePaneId?.description ?? "raw",
        ].joined(separator: ":")
    }

    /// Keep the selected route while iOS is backgrounded. AgentCenter combines
    /// it with scene activity, which lets foregrounding acknowledge the route
    /// immediately without a one-render window for a stale banner or chip.
    private var agentSurfaceIsSelected: Bool {
        appearance.agentCenterEnabled
            && sessionIsActive
            && state == .connected
    }

    private var visibleAgentWindowID: Int? {
        guard tmux.mode == .tmuxControl || tmuxIsDegraded else { return nil }
        return tmux.activeWindowId?.rawValue
    }

    private var visibleAgentPaneID: Int? {
        guard tmux.mode == .tmuxControl || tmuxIsDegraded else { return nil }
        return tmux.activePaneId?.rawValue
    }

    private var attentionVisibilityKey: String {
        [
            agentSurfaceIsSelected ? "selected" : "hidden",
            visibleAgentWindowID.map(String.init) ?? "raw",
            visibleAgentPaneID.map(String.init) ?? "raw",
        ].joined(separator: ":")
    }

    private var agentAttentionButton: some View {
        let tint = agentCenter.sortedUnreadAttentions.contains {
            $0.kind == .needsInput
        } ? T.amber : T.green

        return Button {
            attentionPopoverVisible = true
        } label: {
            HStack(spacing: 5 * scale) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10 * scale, weight: .semibold))
                Text(agentAttentionSummary)
                    .font(Typography.tesseraMono(size: 10 * scale, weight: .medium))
                    .lineLimit(1)
            }
            .chromeBarTextCap()
            .foregroundStyle(tint)
            .padding(.horizontal, 8 * scale)
            .frame(height: 24 * scale)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.36), lineWidth: 1))
            // Bar spacing is 0 — own half of each 8pt-scaled gap inside
            // the hit frame so the capsule keeps its position.
            .padding(.horizontal, 4 * scale)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agentAttentionSummary)
        .accessibilityHint("Shows agents that need attention")
        .accessibilityIdentifier("agent-attention-summary")
        .popover(isPresented: $attentionPopoverVisible, arrowEdge: .top) {
            AgentAttentionPopover(center: agentCenter) {
                attentionPopoverVisible = false
                agentCenter.jump(agentID: $0)
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    private var agentAttentionSummary: String {
        let attentions = agentCenter.sortedUnreadAttentions
        let needsInput = attentions.count { $0.kind == .needsInput }
        let finished = attentions.count { $0.kind == .justFinished }
        var parts: [String] = []
        if needsInput > 0 {
            parts.append(needsInput == 1 ? "1 agent needs input" : "\(needsInput) agents need input")
        }
        if finished > 0 {
            parts.append(finished == 1 ? "1 agent finished" : "\(finished) agents finished")
        }
        return parts.joined(separator: " · ")
    }

    private var agentIntegrationWarningButton: some View {
        Button {
            integrationPopoverVisible = true
        } label: {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(T.amber)
                .frame(width: 28 * scale, height: 24 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                        .fill(T.amber.opacity(0.12))
                )
                .frame(width: 44, height: 44)
                // Bar spacing is 0 — own half of each 8pt-scaled gap inside
                // the hit frame so the glyph keeps its position.
                .padding(.horizontal, 4 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(currentIntegrationState.title)
        .accessibilityHint("Shows the safe action for this terminal")
        .accessibilityIdentifier("agent-integration-warning")
        .popover(isPresented: $integrationPopoverVisible, arrowEdge: .top) {
            AgentIntegrationWarningPopover(
                state: currentIntegrationState,
                T: T,
                onFix: {
                    pendingIntegrationAction = currentIntegrationState.action
                    integrationPopoverVisible = false
                    integrationConfirmationVisible = true
                },
                onSecondaryFix: {
                    pendingIntegrationAction = currentIntegrationState.secondaryAction
                    integrationPopoverVisible = false
                    integrationConfirmationVisible = true
                },
                onHelp: {
                    integrationPopoverVisible = false
                    integrationHelpVisible = true
                }
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private var integrationConfirmationTitle: String {
        switch pendingIntegrationAction {
        case .installAndApply: "Install and enable integration?"
        case .installOnly: "Install agent integration?"
        case .apply: "Enable integration here?"
        case .persistAndApply: "Enable integration automatically?"
        case .check: "Check agent integration?"
        case .retry: "Retry integration check?"
        case nil: "Agent integration"
        }
    }

    private var integrationConfirmationMessage: String {
        switch pendingIntegrationAction {
        case .installAndApply:
            "Writes Tessera hook files, edits bash/zsh startup files, then types one source command so agents launched here report precise status. Continue only at an empty bash/zsh prompt."
        case .installOnly:
            "Writes Tessera hook files and edits bash/zsh startup files. If this exact terminal reaches an empty bash/zsh prompt before the action runs, Tessera also types one source command to enable it immediately. It never types into a running agent or other program."
        case .apply:
            "Types one source command so agents launched here report precise status. Continue only at an empty bash/zsh prompt."
        case .persistAndApply:
            "Adds one guarded activation line to this exact bash/zsh shell's startup file, then loads it here. Future windows of this shell activate automatically. Continue only at an empty bash/zsh prompt."
        case .check:
            "Uses secondary SSH to verify this terminal's integration. Your key may ask to unlock."
        case .retry:
            "Runs a read-only host check to verify the integration state."
        case nil:
            ""
        }
    }

    private var integrationConfirmationLabel: String {
        switch pendingIntegrationAction {
        case .installAndApply: "Install and enable"
        case .installOnly: "Install"
        case .apply: "Run source command"
        case .persistAndApply: "Enable automatically"
        case .check: "Check"
        case .retry: "Retry"
        case nil: "Continue"
        }
    }

    /// Shared icon-button style for the bar's leading sidebar toggle
    /// and trailing home / find buttons. 28×24pt visual box at the
    /// 32pt baseline; both the symbol and frame scale with `scale`
    /// so the icons stay proportional when the bar grows or shrinks.
    /// `isToggled: true` lights up `accentSoft` so on-state buttons
    /// (e.g. the find toggle while the bar is open) read like the
    /// active tmux tab.
    private func chromeIconButton(
        systemName: String,
        isToggled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14 * scale, weight: .medium))
                .foregroundStyle(isToggled ? T.accent : T.fgMuted)
                .frame(width: 28 * scale, height: 24 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                        .fill(isToggled ? T.accentSoft : SwiftUI.Color.clear)
                )
                // 28×24 visual box inside a full-pitch hit frame: the
                // scaled bar can't fit 44pt frames without moving glyphs
                // (iPadOS 26 expands sub-44pt targets itself and
                // mis-assigns taps between adjacent small controls), so
                // absorb the bar's 8pt-scaled gaps (4 each side, bar
                // spacing is 0) and fill the bar height — capped at the
                // bar, not the terminal below.
                .frame(width: 36 * scale)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chrome-\(systemName)")
    }

    // MARK: - Passthrough layout

    @ViewBuilder
    private var passthroughStatus: some View {
        hostStatusButton {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7 * scale, height: 7 * scale)

                // Text(verbatim:) — interpolating the Int directly localizes
                // it (port 2222 renders as "2,222").
                Text(verbatim: "\(host.user)@\(host.address):\(host.port)")
                    .font(Typography.tesseraMono(size: 13 * scale, weight: .medium))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !detailText.isEmpty {
                    Text(detailText)
                        .font(Typography.tesseraMono(size: 12 * scale))
                        .foregroundStyle(detailColor)
                        .lineLimit(1)
                }
            }
            .chromeBarTextCap()
            // Bar spacing is 0 — own half of each 8pt-scaled gap inside
            // the hit frame so the text keeps its position.
            .padding(.horizontal, 4 * scale)
            .contentShape(Rectangle())
        }
    }

    // MARK: - tmux tab strip layout

    @ViewBuilder
    private var tabStrip: some View {
        // Compact host pill on the leading edge — status dot, host
        // identity, then a small-caps "tmux" tag separated by a thin
        // dot. The tag carries the same "you're in tmux mode" signal
        // the old "name · tmux" string did, but visually distinct
        // typography keeps the host name readable on its own.
        hostStatusButton {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7 * scale, height: 7 * scale)
                Text(host.name.isEmpty ? host.address : host.name)
                    .font(Typography.tesseraMono(size: 12 * scale, weight: .medium))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                Text("·")
                    .font(Typography.tesseraMono(size: 11 * scale))
                    .foregroundStyle(T.fgDim)
                Text("tmux")
                    .font(Typography.tesseraSans(size: 10 * scale, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(tmuxIsDegraded ? T.amber : T.fgMuted)
                if tmuxIsDegraded {
                    Text("sync offline")
                        .font(Typography.tesseraMono(size: 11 * scale, weight: .semibold))
                        .foregroundStyle(T.amber)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(
                            Capsule()
                                .fill(T.amber.opacity(0.10))
                        )
                }
            }
            .chromeBarTextCap()
            // Bar spacing is 0 — own half of each 8pt-scaled gap inside
            // the hit frame so the pill keeps its position.
            .padding(.horizontal, 4 * scale)
            .contentShape(Rectangle())
        }

        // Horizontal scroll so a dozen tmux windows can coexist with a
        // narrow viewport; the typical case (1-4 windows) fits
        // comfortably without any scroll indicators appearing. The reader
        // keeps the active tab revealed on every switch (tap, ⌘1-9,
        // palette, or the overflow list) — a selection alone never used
        // to scroll the strip, leaving the active tab clipped offscreen.
        ScrollViewReader { tabStripProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6 * scale) {
                    ForEach(Array(tmux.windows.enumerated()), id: \.element.id) { index, window in
                        tabButton(
                            number: index + 1,
                            window: window,
                            isActive: window.id == tmux.activeWindowId,
                            isDegraded: tmuxIsDegraded
                        )
                    }
                }
                .onGeometryChange(for: CGRect.self) { geo in
                    geo.frame(in: .scrollView)
                } action: { frame in
                    tabStripContentFrame = frame
                    updateTabStripOverflow()
                }
            }
            // Alpha-fade the clipped edge(s) instead of a hard cut. The
            // mask is fully opaque when the strip fits (or is at an end),
            // so the common 1-4 window case renders pixel-identical.
            .mask(tabStripFadeMask)
            .onChange(of: tmux.activeWindowId) { _, windowID in
                guard let windowID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    tabStripProxy.scrollTo(windowID, anchor: nil)
                }
            }
            .onAppear {
                // Defer a turn — at onAppear the strip hasn't laid out yet,
                // so an immediate scrollTo is a no-op.
                guard let windowID = tmux.activeWindowId else { return }
                Task { @MainActor in
                    await Task.yield()
                    tabStripProxy.scrollTo(windowID, anchor: nil)
                }
            }
        }
        .allowsHitTesting(!tmux.gridAuthority.isPeer)
        .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
        .onGeometryChange(for: CGFloat.self) { geo in
            geo.size.width
        } action: { width in
            tabStripVisibleWidth = width
            updateTabStripOverflow()
        }
        // Bar spacing is 0 — keep the strip's 8pt-scaled gaps to the host
        // pill and the `+` button (which carry 4 inside their hit frames).
        .padding(.horizontal, 4 * scale)

        // Overflow chevron — only when the strip genuinely overflows, so
        // the bar is unchanged until tabs no longer fit. Opens a window
        // list touch users can pick from directly instead of wrestling
        // the strip's horizontal scroll against the system drag region.
        if tabStripOverflows {
            chromeIconButton(
                systemName: "chevron.down",
                isToggled: windowListVisible,
                action: { windowListVisible.toggle() }
            )
            .disabled(tmux.gridAuthority.isPeer)
            .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
            .accessibilityLabel("Show all windows")
            .accessibilityIdentifier("tmux-tab-overflow")
            .popover(
                isPresented: $windowListVisible,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                TmuxWindowListPopover(
                    tmux: tmux,
                    sessionID: sessionID,
                    isDegraded: tmuxIsDegraded,
                    T: T,
                    onSelect: { position in
                        windowListVisible = false
                        tmux.selectWindow(atPosition: position)
                    },
                    onClose: { window in
                        requestWindowClose(window, fromWindowList: true)
                    },
                    onNewWindow: {
                        windowListVisible = false
                        tmux.newWindow()
                    }
                )
                .presentationCompactAdaptation(.popover)
                // Fires when the popover has fully left the screen — the
                // reliable point to present a close confirmation staged by
                // the list without racing the dismiss transition.
                .onDisappear { presentStagedWindowListClose() }
            }
        }

        // New-window button. Lives inside the tabStrip branch on
        // purpose so it only appears when tmux -CC is actively
        // managing windows — there's no equivalent action in
        // passthrough mode (a raw shell has no concept of "another
        // window"). Same effect as ⌘T. Shares the rounded-square
        // chrome-icon style with the toggle / find / home buttons so
        // the bar reads as one consistent set (matching the mockup,
        // where new-window is a plain `+` icon, not a ringed circle).
        chromeIconButton(systemName: "plus", action: { tmux.newWindow() })
            .disabled(tmux.gridAuthority.isPeer)
            .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
            .accessibilityLabel("New tmux window")
            .accessibilityIdentifier("tmux-new-window")
    }

    /// A single tmux-window tab. Tapping its label switches through the same
    /// path ⌘1-9 takes (`selectWindow(atPosition:)`); its X targets the window
    /// id directly, so closing an inactive tab never selects it first.
    private func tabButton(
        number: Int,
        window: TmuxController.WindowInfo,
        isActive: Bool,
        isDegraded: Bool
    ) -> some View {
        let name = window.name
        let windowID = window.id.rawValue
        let hasPendingBell = appearance.bellVisualEnabled
            && !isActive
            && tmux.bellingWindows.contains(windowID)
        let glowing = appearance.bellVisualEnabled
            && bellController.shouldGlow(forWindowID: windowID, sessionID: host.id)
        let windowAgents = agentCenter.agents.filter {
            $0.id.sessionID == sessionID && $0.location.windowID == windowID
        }
        let hasAgent = !windowAgents.isEmpty
        let agentNeedsInput = windowAgents.contains { $0.status == .waitingForInput }
        let agentHasUnreadFinished = !isActive
            && !agentNeedsInput
            && agentCenter.hasUnreadJustFinished(
                sessionID: sessionID,
                windowID: windowID
            )
        let closeIsAvailable = !isDegraded
            && tmux.mode == .tmuxControl
            && tmux.isWindowListHydrated
            && !tmux.gridAuthority.isPeer
        // Confirmation contract: closing a window prompts when it would take
        // 2+ panes with it — and, transiently, while the `%window-add`
        // details query is still in flight, because until that reply lands
        // the pane count is a guess (`link-window`/`move-window` can add a
        // window that is already split). Once the query answers, an unknown
        // layout means genuinely single-pane and the close is immediate —
        // never a permanent "still loading" prompt.
        let closeNeedsConfirmation = window.paneCount > 1
            || tmux.isWindowLayoutPending(window.id)

        return HStack(spacing: 0) {
            Button(action: { tmux.selectWindow(atPosition: number) }) {
                HStack(spacing: 6) {
                    if hasAgent {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9 * scale, weight: .semibold))
                            .foregroundStyle(
                                agentNeedsInput ? T.amber
                                    : (agentHasUnreadFinished ? T.green : T.fgMuted)
                            )
                            .shadow(
                                color: agentNeedsInput ? T.amber.opacity(0.55)
                                    : (agentHasUnreadFinished ? T.green.opacity(0.5) : .clear),
                                radius: 3 * scale
                            )
                            .accessibilityLabel(
                                agentNeedsInput ? "agent needs input"
                                    : (agentHasUnreadFinished ? "agent just finished" : "agent active")
                            )
                    }
                    Text(name)
                        .font(Typography.tesseraMono(size: 12 * scale, weight: isActive ? .medium : .regular))
                        .foregroundStyle(
                            agentHasUnreadFinished && !isDegraded
                                ? T.green
                                : (isActive
                                ? (isDegraded ? T.amber : T.fg)
                                : (isDegraded ? T.fgDim : T.fgMuted))
                        )
                        .lineLimit(1)
                    // Only windows 1-9 have a ⌘N keyboard shortcut, so
                    // suppress the hint past 9 rather than mislead with a
                    // shortcut that doesn't fire.
                    if number <= 9 {
                        Text("⌘\(number)")
                            .font(Typography.tesseraMono(size: 10.5 * scale))
                            .foregroundStyle(
                                isActive
                                    ? (isDegraded ? T.amber : T.accent)
                                    : T.fgFaint
                            )
                    }
                }
                .chromeBarTextCap()
                .padding(.leading, 11 * scale)
                // No trailing padding: the 7pt-scaled gap before the X
                // belongs to the close button's hit frame, so the
                // destructive X never sits flush against this target.
                .frame(height: 24 * scale)
                .frame(height: 32 * scale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tmux.gridAuthority.isPeer)
            .accessibilityIdentifier("tmux-window-\(windowID)-tab")

            TmuxTabCloseButton(
                name: name,
                windowID: windowID,
                isActive: isActive,
                isAvailable: closeIsAvailable,
                accessibilityHint: closeIsAvailable
                    ? (closeNeedsConfirmation
                        ? "Asks before closing every pane in this window"
                        : "Closes this window")
                    : (isDegraded
                        ? "Unavailable while tmux sync is offline"
                        : "Unavailable while tmux window details are syncing"),
                scale: scale,
                T: T
            ) {
                requestWindowClose(window)
            }
        }
        .frame(height: 24 * scale)
        .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
        .background(
            // Capsule-rounded tab (radius = half the height), matching the
            // mockup's fully-rounded pills, rather than the prior 6pt nubs.
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .fill(
                    tabBackground(
                        isActive: isActive,
                        isDegraded: isDegraded,
                        agentHasUnreadFinished: agentHasUnreadFinished
                    )
                )
        )
        .overlay {
            if glowing {
                BellGlowOverlay(color: T.accent)
                    .id(bellController.lastBellAt)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if agentNeedsInput || agentHasUnreadFinished {
                Rectangle()
                    .fill(agentNeedsInput ? T.amber : T.green)
                    .frame(height: max(1, 1.2 * scale))
                    .shadow(
                        color: (agentNeedsInput ? T.amber : T.green).opacity(0.7),
                        radius: 3 * scale
                    )
                    .padding(.horizontal, 5 * scale)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hasPendingBell {
                Circle()
                    .fill(T.accent)
                    .frame(width: 5 * scale, height: 5 * scale)
                    .padding(EdgeInsets(top: 2 * scale, leading: 0, bottom: 0, trailing: 3 * scale))
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        // Stand the row up to the bar's full 32pt-scaled height so the
        // buttons' tall hit frames stay inside the scroll view's
        // hit-test bounds; the pill visual above stays 24pt-scaled.
        .frame(height: 32 * scale)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: hasPendingBell)
    }

    // MARK: - Tab-strip overflow

    /// True while the strip is scrolled away from its leading edge — the
    /// leading fade hint is showing.
    private var canScrollTabStripLeft: Bool {
        tabStripContentFrame.minX < -2
    }

    /// True while more tabs remain past the trailing edge.
    private var canScrollTabStripRight: Bool {
        tabStripContentFrame.maxX > tabStripVisibleWidth + 2
    }

    /// Re-derives `tabStripOverflows` from the latest measurements, with
    /// hysteresis: the chevron's appearance costs the strip its own 36pt
    /// pitch, so a plain `content > visible` check would flap right at the
    /// boundary (chevron appears → strip shrinks → still overflows; user
    /// closes one tab → fits → chevron hides → strip regrows → overflows
    /// again). Once visible, the chevron hides only when the content would
    /// fit with that pitch reclaimed.
    private func updateTabStripOverflow() {
        let epsilon: CGFloat = 2
        let chevronPitch = 36 * scale
        let content = tabStripContentFrame.width
        if tabStripOverflows {
            if content <= tabStripVisibleWidth + chevronPitch - epsilon {
                tabStripOverflows = false
            }
        } else if content > tabStripVisibleWidth + epsilon {
            tabStripOverflows = true
        }
    }

    /// Mask for the strip's scroll view: solid everywhere except a short
    /// alpha ramp at an edge that has clipped tabs behind it. Replaces the
    /// hard clip as the "there's more" hint without adding any chrome.
    private var tabStripFadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [canScrollTabStripLeft ? .clear : .black, .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 14 * scale)
            SwiftUI.Color.black
            LinearGradient(
                colors: [.black, canScrollTabStripRight ? .clear : .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 14 * scale)
        }
        .animation(.easeOut(duration: 0.15), value: canScrollTabStripLeft)
        .animation(.easeOut(duration: 0.15), value: canScrollTabStripRight)
    }

    /// Close availability mirrors `TmuxTabCloseButton`'s enabled state: no
    /// destructive sends while sync is degraded or the window list hasn't
    /// hydrated (a kill against a stale list could target the wrong window).
    private var windowCloseIsAvailable: Bool {
        !tmuxIsDegraded && tmux.mode == .tmuxControl && tmux.isWindowListHydrated
    }

    /// Shared close entry for the strip's X and the overflow list's X.
    /// Decides on live controller state re-read at tap time (the passed-in
    /// `window` is a render-captured snapshot that can be a frame stale).
    /// Confirmation goes through the `pendingWindowClose` alert for
    /// multi-pane windows AND for windows whose pane count is still a guess
    /// because the `%window-add` details query hasn't answered — an
    /// already-split `link-window`/`move-window` window must not be killed
    /// promptless during that round trip. When the request comes from the
    /// window-list popover, the alert is staged and presented only after
    /// the popover has actually left the screen (its content's
    /// `onDisappear`): a fixed one-turn yield doesn't outlast the dismiss
    /// transition, during which UIKit can drop the presentation.
    private func requestWindowClose(
        _ window: TmuxController.WindowInfo,
        fromWindowList: Bool = false
    ) {
        guard windowCloseIsAvailable else { return }
        let live = tmux.windows.first(where: { $0.id == window.id }) ?? window
        guard live.paneCount > 1 || tmux.isWindowLayoutPending(live.id) else {
            tmux.killWindow(live.id)
            return
        }
        let pending = PendingTmuxWindowClose(
            window: live,
            controlConnectionGeneration: tmux.controlConnectionGeneration
        )
        if fromWindowList {
            stagedWindowListClose = pending
            windowListVisible = false
        } else {
            pendingWindowClose = pending
        }
    }

    /// Presents a close confirmation staged by the window-list popover once
    /// the popover has fully dismissed. Re-validates against live controller
    /// state at presentation time so a window that vanished mid-dismiss
    /// (remote close, reconnect) doesn't resurrect as a ghost alert.
    private func presentStagedWindowListClose() {
        guard let staged = stagedWindowListClose else { return }
        stagedWindowListClose = nil
        guard staged.controlConnectionGeneration == tmux.controlConnectionGeneration,
              tmux.isWindowListHydrated,
              tmux.windows.contains(where: { $0.id == staged.window.id })
        else { return }
        pendingWindowClose = staged
    }

    /// Active-tab fill: theme accent (via `accentSoft`) in normal
    /// operation, semantic amber when tmux sync is degraded so the
    /// warning state remains unambiguous regardless of which theme
    /// the user picked. Inactive tabs are transparent.
    private func tabBackground(
        isActive: Bool,
        isDegraded: Bool,
        agentHasUnreadFinished: Bool
    ) -> SwiftUI.Color {
        if agentHasUnreadFinished && !isDegraded { return T.green.opacity(0.14) }
        guard isActive else { return SwiftUI.Color.clear }
        return isDegraded ? T.amber.opacity(0.16) : T.accentSoft
    }

    private func hostStatusButton<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: { statusBreakdownVisible = true }) {
            content()
                // Stand the hit frame up to the bar height like the other bar
                // controls — a natural-height pill is a sub-44 pt target next
                // to full-pitch neighbors (iPadOS 26 mis-assigns such taps).
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: $statusBreakdownVisible,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            ConnectionStatusBreakdownView(status: connectionStatus)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("Connection status")
    }

    private var statusDotColor: SwiftUI.Color {
        switch connectionStatus {
        case .ssh(let state):
            return dotColor(for: state)
        case .mosh(let sessionState, let transportState, let tcpControl):
            switch sessionState {
            case .connected:
                switch transportState {
                case .connected:
                    break
                case .connecting, .idle:
                    return T.amber.opacity(0.9)
                case .disconnected:
                    return T.red
                }
                guard let tcpControl else {
                    return T.green
                }
                return tcpControl == .connected
                    ? T.green
                    : T.amber.opacity(0.9)
            case .connecting:
                return T.amber.opacity(0.9)
            case .idle:
                return T.fgDim
            case .disconnected, .failed:
                return T.red
            }
        }
    }

    private func dotColor(for state: SessionState) -> SwiftUI.Color {
        switch state {
        case .idle: return T.fgDim
        case .connecting: return T.amber
        case .connected: return T.green
        case .disconnected, .failed: return T.red
        }
    }

    /// Extra text after the host label describing the session state.
    /// Empty when connected — the green dot alone conveys that and
    /// the space is more valuable than the redundant word "connected".
    private var detailText: String {
        if tmuxIsDegraded, state == .connected {
            return "tmux sync offline"
        }
        switch state {
        case .idle:               return "idle"
        case .connecting:         return "connecting…"
        case .connected:          return ""
        case .disconnected:       return "disconnected"
        // The full reason + recovery actions live in the launch overlay's
        // error state now; the top bar just keeps a short red marker.
        case .failed:             return "failed"
        }
    }

    private var detailColor: SwiftUI.Color {
        if tmuxIsDegraded, state == .connected {
            return T.amber
        }
        switch state {
        case .failed: return T.red
        default:      return T.fgMuted
        }
    }
}

/// The tab-overflow window list. Presented from the strip's `chevron.down`
/// button so touch users can switch (or close) windows directly when the
/// strip has scrolled past the viewport — finger-scrolling the strip fights
/// the iPadOS window-drag region along the top screen edge. Rows mirror the
/// strip's tabs (position number, agent sparkles, name, ⌘N hint, close X)
/// with 40pt pitch for comfortable touch targets. Unscaled: popover content
/// floats outside the bar, so the `topBarHeight` slider doesn't apply.
private struct TmuxWindowListPopover: View {
    let tmux: TmuxController
    let sessionID: UUID
    let isDegraded: Bool
    let T: DesignTokens
    /// Selection by strip position (1-based) — the same
    /// `selectWindow(atPosition:)` path tab taps and ⌘1-9 use.
    let onSelect: (Int) -> Void
    let onClose: (TmuxController.WindowInfo) -> Void
    let onNewWindow: () -> Void

    @Environment(AgentCenter.self) private var agentCenter

    private static let rowHeight: CGFloat = 40
    private static let footerHeight: CGFloat = 36
    /// Cap so a pathological window count scrolls instead of growing a
    /// popover taller than a landscape iPad's usable height.
    private static let maxHeight: CGFloat = 420

    var body: some View {
        let windows = tmux.windows
        // Popovers collapse greedy ScrollViews to zero, so size the panel
        // explicitly: rows + divider block + footer + vertical padding.
        let idealHeight = 5 + CGFloat(windows.count) * Self.rowHeight + 9
            + Self.footerHeight + 5
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                            row(number: index + 1, window: window)
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.top, 5)
                }
                .onAppear {
                    // Long lists should open with the active window on
                    // screen, not the top of the list. Deferred a turn so
                    // layout exists for scrollTo to target.
                    guard let windowID = tmux.activeWindowId else { return }
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(windowID, anchor: .center)
                    }
                }
            }

            Rectangle()
                .fill(T.border)
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            Button(action: onNewWindow) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                    Text("New window")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(T.fgMuted)
                .padding(.horizontal, 15)
                .frame(height: Self.footerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New tmux window")
            .accessibilityIdentifier("tmux-window-list-new")
            .padding(.bottom, 5)
        }
        .frame(width: 288, height: min(idealHeight, Self.maxHeight))
        .presentationBackground(T.bg.opacity(0.94))
        .presentationCornerRadius(13)
    }

    private func row(number: Int, window: TmuxController.WindowInfo) -> some View {
        let windowID = window.id.rawValue
        let isActive = window.id == tmux.activeWindowId
        let windowAgents = agentCenter.agents.filter {
            $0.id.sessionID == sessionID && $0.location.windowID == windowID
        }
        let hasAgent = !windowAgents.isEmpty
        let agentNeedsInput = windowAgents.contains { $0.status == .waitingForInput }
        let agentHasUnreadFinished = !isActive
            && !agentNeedsInput
            && agentCenter.hasUnreadJustFinished(
                sessionID: sessionID,
                windowID: windowID
            )
        let closeIsAvailable = !isDegraded
            && tmux.mode == .tmuxControl
            && tmux.isWindowListHydrated

        return HStack(spacing: 0) {
            Button(action: { onSelect(number) }) {
                HStack(spacing: 8) {
                    Text("\(number)")
                        .font(Typography.tesseraMono(size: 10.5))
                        .foregroundStyle(T.fgFaint)
                        .frame(width: 16, alignment: .trailing)
                    if hasAgent {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                agentNeedsInput ? T.amber
                                    : (agentHasUnreadFinished ? T.green : T.fgMuted)
                            )
                            .accessibilityLabel(
                                agentNeedsInput ? "agent needs input"
                                    : (agentHasUnreadFinished ? "agent just finished" : "agent active")
                            )
                    }
                    Text(window.name)
                        .font(Typography.tesseraMono(size: 12.5, weight: isActive ? .medium : .regular))
                        .foregroundStyle(
                            agentHasUnreadFinished && !isDegraded
                                ? T.green
                                : (isActive
                                ? (isDegraded ? T.amber : T.fg)
                                : (isDegraded ? T.fgDim : T.fgMuted))
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    // Same 1-9 cutoff as the strip: no hint for windows
                    // without a live ⌘N shortcut.
                    if number <= 9 {
                        Text("⌘\(number)")
                            .font(Typography.tesseraMono(size: 10.5))
                            .foregroundStyle(
                                isActive
                                    ? (isDegraded ? T.amber : T.accent)
                                    : T.fgFaint
                            )
                    }
                }
                .padding(.leading, 10)
                .frame(height: Self.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Explicit label replaces child aggregation, so fold the agent
            // sparkle's state back in — a VoiceOver user scanning the list
            // for the window whose agent needs attention has no other signal.
            .accessibilityLabel(
                "\(window.name), window \(number)"
                    + (hasAgent
                        ? (agentNeedsInput ? ", agent needs input"
                            : (agentHasUnreadFinished
                                ? ", agent just finished"
                                : ", agent active"))
                        : "")
            )
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityIdentifier("tmux-window-list-\(windowID)-row")

            TmuxTabCloseButton(
                name: window.name,
                windowID: windowID,
                isActive: isActive,
                isAvailable: closeIsAvailable,
                accessibilityHint: closeIsAvailable
                    ? (window.paneCount > 1 || tmux.isWindowLayoutPending(window.id)
                        ? "Asks before closing every pane in this window"
                        : "Closes this window")
                    : (isDegraded
                        ? "Unavailable while tmux sync is offline"
                        : "Unavailable while tmux window details are syncing"),
                scale: 1,
                T: T,
                idNamespace: "tmux-window-list"
            ) {
                onClose(window)
            }
            .padding(.trailing, 2)
        }
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    agentHasUnreadFinished && !isDegraded
                        ? T.green.opacity(0.14)
                        : (isActive
                        ? (isDegraded ? T.amber.opacity(0.16) : T.accentSoft)
                        : SwiftUI.Color.clear)
                )
        )
    }
}

private struct AgentIntegrationWarningPopover: View {
    let state: AgentIntegrationWarningState
    let T: DesignTokens
    let onFix: () -> Void
    let onSecondaryFix: () -> Void
    let onHelp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(T.amber)
                Text(state.title)
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                    .foregroundStyle(T.fg)
                    .accessibilityAddTraits(.isHeader)
            }

            Text(state.message)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            if state.isRepairing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("working…")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Fixing agent integration")
            } else if let label = state.actionLabel {
                if state.action == nil {
                    Text(label)
                        .font(Typography.tesseraMono(size: 11, weight: .medium))
                        .foregroundStyle(T.fgDim)
                        .accessibilityIdentifier("agent-integration-guidance")
                } else {
                    HStack(spacing: 8) {
                        actionButton("Help", primary: false, action: onHelp)
                            .accessibilityIdentifier("agent-integration-help")
                        actionButton(label, primary: true, action: onFix)
                            .accessibilityIdentifier("agent-integration-fix")
                    }
                    .buttonStyle(.plain)
                    if let secondaryLabel = state.secondaryActionLabel,
                       state.secondaryAction != nil {
                        actionButton(
                            secondaryLabel,
                            primary: false,
                            action: onSecondaryFix
                        )
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent-integration-persist")
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(T.panelBg)
    }

    private func actionButton(
        _ title: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.tesseraMono(size: 11, weight: .medium))
                .foregroundStyle(primary ? T.accent : T.fgMuted)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(T.inputBgSoft)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(primary ? T.accentSoft : T.border, lineWidth: 1)
                )
        }
    }
}

#if DEBUG
/// Host-free phone fixture for the production SwiftTerm responder path.
/// It keeps the real accessory bar mounted, claims first responder at launch,
/// and exposes keyboard show/hide notifications through accessibility so an
/// iPhone simulator can verify dismissal without opening a user connection.
struct IPhoneKeyboardHarnessView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @State private var terminalBox = TerminalBox(traceLabel: "iphone-keyboard-harness")
    @State private var modifierState = ModifierState()
    @State private var oracle = IPhoneKeyboardHarnessOracle()
    @State private var ownerGrid = CellRect(width: 50, height: 48, x: 0, y: 0)
    @State private var viewportRows = 0
    @State private var viewportLayoutGeneration = -1
    @State private var lastHarnessViewportSize = CGSize.zero

    var body: some View {
        VStack(spacing: 0) {
            TerminalSurfaceBound(
                initialData: Self.fixtureBytes,
                onMade: { view in
                    terminalBox.attach(view)
                    view.isAccessibilityElement = true
                    view.accessibilityIdentifier = "iphone-keyboard-terminal"
                    view.accessibilityLabel = "iPhone terminal"
                },
                onReady: { terminalBox.markRenderReady() },
                onSend: { _ in },
                onResize: { _, _ in },
                onTitle: { _ in },
                onUserActivity: nil,
                onBell: nil,
                mouseReportingImpliesAltScreen: false,
                suppressDirectColorQueryResponses: true,
                softwareModifierState: modifierState,
                tmuxShortcutsEnabled: false,
                onTmuxShortcut: { _ in },
                onFindShortcut: nil,
                onSwitcherShortcut: nil,
                onOpenSettings: nil,
                suppressFirstResponderReclaim: modifierState.suppressesSoftwareKeyboardReclaim,
                onHardwareKey: nil
            )
            .modifier(GeometryNeutralTmuxCanvasModifier(
                windowRect: ownerGrid,
                focusRect: ownerGrid,
                cellSize: harnessCellSize,
                onViewportSize: updateOwnerGrid
            ))

            SessionAccessoryBar(
                accent: DesignTokens.make(mode: .dark, accent: .blue).accent,
                modifierState: modifierState,
                onSend: { _ in },
                applicationCursor: { false }
            )
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .overlay(alignment: .topLeading) {
            Text("keyboard \(oracle.isVisible ? "visible" : "hidden")")
                .font(Typography.tesseraMono(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.01))
                .accessibilityIdentifier("iphone-keyboard-state")
                .accessibilityValue(oracle.isVisible ? "visible" : "hidden")
        }
        .overlay(alignment: .topTrailing) {
            let measuredRows = viewportLayoutGeneration == oracle.frameGeneration
                ? String(viewportRows)
                : "pending"
            Text("viewport rows \(measuredRows)")
                .foregroundStyle(Color.white.opacity(0.01))
                .accessibilityIdentifier("iphone-terminal-viewport-rows")
                .accessibilityValue(measuredRows)
        }
        .overlay(alignment: .top) {
            Button {
                // Two notifications make the regression independent of the
                // orientation tracker's initial seed. Neither represents an
                // interface rotation in this portrait harness.
                NotificationCenter.default.post(
                    name: UIDevice.orientationDidChangeNotification,
                    object: UIDevice.current
                )
                NotificationCenter.default.post(
                    name: UIDevice.orientationDidChangeNotification,
                    object: UIDevice.current
                )
            } label: {
                Color.clear.frame(width: 44, height: 44)
            }
            .accessibilityLabel("Simulate device orientation noise")
            .accessibilityIdentifier("iphone-keyboard-orientation-noise")
        }
        .overlay(alignment: .topLeading) {
            Text("keyboard hides \(oracle.hideCount)")
                .foregroundStyle(Color.white.opacity(0.01))
                .accessibilityIdentifier("iphone-keyboard-hide-count")
                .accessibilityValue(String(oracle.hideCount))
                .offset(y: 24)
        }
        .onAppear {
            appearance.mode = .dark
            appearance.fontSize = 13
            appearance.cursorBlink = false
            appearance.showAccessoryBar = true
            appearance.accessoryBarKeys = AccessoryChip.defaultBarOrder.map(\.rawValue)
            oracle.start()
        }
        .onDisappear {
            oracle.stop()
        }
        .onChange(of: oracle.settledGeneration) { _, _ in
            guard lastHarnessViewportSize != .zero else { return }
            updateOwnerGrid(lastHarnessViewportSize)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            terminalBox.dismissTransientInteractionsIfInterfaceOrientationChanged()
        }
    }

    private static let fixtureBytes = Array(
        (
            "\u{001B}[2J\u{001B}[H"
                + "Tessera iPhone terminal - 13 pt\r\n"
                + "Readable phone-owned tmux viewport\r\n"
                + "$ tmux list-windows\r\n"
                + "0: shell*  1: htop  2: vim\r\n"
                + "$ _"
        ).utf8
    )

    private var harnessCellSize: CGSize {
        let font = TesseraTerminalFont.mono(size: CGFloat(appearance.fontSize))
        return TerminalCellMetrics.cellSize(font: font, scale: UIScreen.main.scale)
    }

    private func updateOwnerGrid(_ size: CGSize) {
        lastHarnessViewportSize = size
        let cellSize = harnessCellSize
        guard cellSize.width > 0, cellSize.height > 0 else { return }
        let cols = max(1, Int(size.width / cellSize.width))
        let rows = max(1, Int(size.height / cellSize.height))
        let next = CellRect(width: cols, height: rows, x: 0, y: 0)
        ownerGrid = next
        viewportRows = rows
        viewportLayoutGeneration = oracle.frameGeneration
    }
}

@Observable
private final class IPhoneKeyboardHarnessOracle {
    private(set) var isVisible = false
    private(set) var hideCount = 0
    private(set) var frameGeneration = 0
    private(set) var settledGeneration = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.frameGeneration += 1
            },
            center.addObserver(
                forName: UIResponder.keyboardDidShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isVisible = true
                self?.settledGeneration += 1
            },
            center.addObserver(
                forName: UIResponder.keyboardDidHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isVisible = false
                self?.hideCount += 1
                self?.settledGeneration += 1
            },
        ]
    }

    func stop() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }
}

/// Host-free compact-session fixture. It mounts the production phone chrome,
/// two-level tmux switcher, modifier bar, and SwipePad without opening any
/// transport. `TESSERA_IPHONE_SESSION_HARNESS_MODE=palette` opens the switcher
/// at launch for deterministic screenshots.
struct IPhoneCompanionHarnessView: View {
    private let sessionID = UUID(
        uuidString: "11111111-2222-3333-4444-555555555555"
    )!

    @State private var appearance: AppearancePreferences
    @State private var center = AgentCenter()
    @State private var registry = SessionRegistry()
    @State private var palette = CommandPalette()
    @State private var tmux: TmuxController
    @State private var findController = FindController()
    @State private var modifierState = ModifierState()
    @Environment(BellController.self) private var bellController
    @Environment(SwipePadProfileStore.self) private var swipePadStore
    @Environment(SpeechDictationController.self) private var dictationController

    init() {
        let appearance = AppearancePreferences()
        appearance.mode = .dark
        appearance.showAccessoryBar = true
        appearance.swipePadEnabled = true
        appearance.swipePadCorner = "bottomRight"
        appearance.swipePadSize = "standard"
        appearance.modifierBehavior = "oneShot"
        appearance.accessoryBarKeys = AccessoryChip.defaultBarOrder.map(\.rawValue)
        _appearance = State(initialValue: appearance)

        let controller = TmuxController(
            controlPath: .sideChannel,
            clientSizePolicy: .preserveServerGeometry
        )
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array((
            "%begin 0 4 1\r\n"
                + "@1\t8205,160x48,0,0{80x48,0,0,20,79x48,81,0,21}\t8205,160x48,0,0{80x48,0,0,20,79x48,81,0,21}\t0\tdev\r\n"
                + "@2\tb25d,160x48,0,0,30\tb25d,160x48,0,0,30\t0\thtop\r\n"
                + "%end 0 4 1\r\n"
        ).utf8))
        controller.ingest(Array((
            "%begin 0 5 1\r\n"
                + "@1\t%20\t0\t\tnvim\thost\r\n"
                + "@1\t%21\t1\t\tzsh\thost\r\n"
                + "@2\t%30\t1\t\thtop\thost\r\n"
                + "%end 0 5 1\r\n"
        ).utf8))
        controller.ingest(Array("%begin 0 6 1\r\n@1\r\n%end 0 6 1\r\n".utf8))
        controller.ingest(Array("%begin 0 7 1\r\n%end 0 7 1\r\n".utf8))
        _tmux = State(initialValue: controller)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                SessionTopBar(
                    state: .connected,
                    host: Host(
                        name: "zeus",
                        address: "zeus.local",
                        transport: .mosh,
                        autoTmux: true,
                        launchMode: .autoTmux
                    ),
                    sessionID: sessionID,
                    sessionIsActive: false,
                    tmux: tmux,
                    tmuxIsDegraded: false,
                    connectionStatus: .mosh(
                        sessionState: .connected,
                        transportState: .connected,
                        tcpControl: .connected
                    ),
                    onToggleSidebar: {},
                    sidebarVisible: false,
                    onBack: {},
                    onDisconnect: {},
                    findController: findController,
                    filesPanelOpen: false,
                    onToggleFiles: {},
                    bellController: bellController,
                    forwarderManager: nil,
                    T: chrome
                )
                .frame(
                    height: SessionTopBar.reservedHeight(
                        pillHeight: appearance.topBarHeight,
                        compact: true
                    )
                )

                fakeTerminal

                SessionAccessoryBar(
                    accent: chrome.accent,
                    modifierState: modifierState,
                    onSend: { _ in },
                    applicationCursor: { false }
                )
            }

            SwipePadOverlay(
                onSend: { _ in },
                tmux: tmux,
                profileStore: swipePadStore,
                dictationController: dictationController
            )
            .padding(.top, SessionTopBar.reservedHeight(
                pillHeight: appearance.topBarHeight,
                compact: true
            ))
            .padding(.horizontal, 10)
            .padding(.bottom, 52)
            .zIndex(5)

            if palette.isOpen {
                CommandPaletteView(
                    palette: palette,
                    onTmuxClose: registry.requestTmuxClose,
                    onTmuxMutation: registry.requestTmuxMutation
                ) { _ in }
                    .zIndex(20)
            }
        }
        .environment(appearance)
        .environment(center)
        .environment(registry)
        .environment(palette)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            let mode = ProcessInfo.processInfo.environment[
                "TESSERA_IPHONE_SESSION_HARNESS_MODE"
            ]
            if mode == "palette" {
                openPalette()
            } else if mode == "ctrl" {
                modifierState.tap(.ctrl)
            } else if mode == "find" {
                findController.open()
            }
        }
    }

    private var chrome: DesignTokens {
        TerminalTheme.find(id: appearance.terminalThemeID)
            .chromeTokens(applying: appearance)
    }

    private var fakeTerminal: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 4) {
                Text("pane %21 · zsh · full-screen local view")
                    .foregroundStyle(chrome.accent)
                Text("$ git status --short")
                Text(" M Tessera/SessionView.swift")
                Text("$ swift test")
                Text("Building for debugging…")
                Text("Test Suite 'TmuxControlTests' passed")
                    .foregroundStyle(chrome.green)
                Spacer()
                Text("zeus ~/projects/tessera $ _")
            }
            .font(Typography.tesseraMono(size: 12))
            .foregroundStyle(Color.white.opacity(0.84))
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
        }
        .background(Color.black)
        .accessibilityIdentifier("iphone-session-harness")
    }

    private func openPalette() {
        let windows = tmux.windows.map { window in
            CommandPaletteTmuxWindow(
                id: window.id,
                title: window.displayName,
                panes: window.panes.map {
                    CommandPaletteTmuxPane(
                        id: $0.id,
                        title: $0.currentCommand ?? window.displayName,
                        command: $0.currentCommand
                    )
                }
            )
        }
        palette.open(
            sessions: [],
            agents: [],
            tmuxWindows: windows,
            currentSessionID: sessionID,
            activeWindowID: tmux.activeWindowId,
            activePaneID: tmux.activePaneId,
            includesHome: true
        )
    }
}

struct AgentIntegrationWarningHarnessView: View {
    private let sessionID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    @State private var appearance: AppearancePreferences
    @State private var center: AgentCenter
    @State private var registry = SessionRegistry()
    @State private var palette = CommandPalette()
    @State private var tmux = TmuxController()
    @State private var findController = FindController()
    @Environment(BellController.self) private var bellController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init() {
        let appearance = AppearancePreferences()
        appearance.agentCenterEnabled = true
        let center = AgentCenter()
        let sessionID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let missingInsideAgent = ProcessInfo.processInfo.environment[
            "TESSERA_AGENT_INTEGRATION_WARNING_STATE"
        ] == "missing-agent"
        let target = AgentCurrentIntegrationTarget(
            location: AgentLocation(
                sessionID: sessionID,
                hostName: "devbox",
                transportLabel: "ssh",
                tmuxSessionName: nil,
                windowID: nil,
                windowName: nil,
                paneID: nil
            ),
            foreground: missingInsideAgent ? .agent : .shell,
            processIDs: missingInsideAgent ? [200] : [],
            shellIntegrationActive: false,
            agentIntegrationActive: false
        )
        center.installHarnessCurrentIntegrationState(
            .resolved(
                installation: missingInsideAgent ? .missing : .current,
                target: target
            ),
            for: sessionID
        )
        _appearance = State(initialValue: appearance)
        _center = State(initialValue: center)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                SessionTopBar(
                    state: .connected,
                    host: Host(name: "devbox", address: "devbox.local", autoTmux: false, launchMode: .customCommand),
                    sessionID: sessionID,
                    sessionIsActive: false,
                    tmux: tmux,
                    tmuxIsDegraded: false,
                    connectionStatus: .ssh(state: .connected),
                    onToggleSidebar: {},
                    sidebarVisible: false,
                    onBack: {},
                    onDisconnect: {},
                    findController: findController,
                    filesPanelOpen: false,
                    onToggleFiles: {},
                    bellController: bellController,
                    forwarderManager: nil,
                    T: DesignTokens.make(mode: .dark, accent: .blue)
                )
                .frame(height: SessionTopBar.reservedHeight(
                    pillHeight: appearance.topBarHeight,
                    compact: CompactLayout.isPhone(horizontalSizeClass)
                ))
                Spacer()
            }

            if palette.isOpen {
                CommandPaletteView(
                    palette: palette,
                    onTmuxClose: registry.requestTmuxClose,
                    onTmuxMutation: registry.requestTmuxMutation
                ) { _ in }
                .zIndex(20)
            }
        }
        .environment(appearance)
        .environment(center)
        .environment(registry)
        .environment(palette)
        .environment(
            \.horizontalSizeClass,
            ProcessInfo.processInfo.environment[
                "TESSERA_AGENT_INTEGRATION_WARNING_COMPACT"
            ] == "1" ? .compact : horizontalSizeClass
        )
        .onAppear {
            guard ProcessInfo.processInfo.environment[
                "TESSERA_AGENT_INTEGRATION_WARNING_SWITCHER_AUTO_OPEN"
            ] == "1" else { return }
            let state = center.currentIntegrationState(sessionID: sessionID)
            palette.open(
                sessions: [],
                includesHome: true,
                notice: CommandPaletteNotice(
                    title: state.title,
                    message: state.message,
                    actionLabel: state.actionLabel
                )
            )
        }
    }
}

/// Host-free notification fixture: one finished agent is on the visible pane
/// (green active tab, no unread alert), while an inactive window needs input
/// and another inactive window just finished (aggregate chip + popover).
struct AgentAttentionHarnessView: View {
    private let sessionID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    @State private var appearance: AppearancePreferences
    @State private var center: AgentCenter
    @State private var registry = SessionRegistry()
    @State private var palette = CommandPalette()
    @State private var tmux: TmuxController
    @State private var findController = FindController()
    @Environment(BellController.self) private var bellController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init() {
        let appearance = AppearancePreferences()
        appearance.agentCenterEnabled = true
        _appearance = State(initialValue: appearance)

        let controller = TmuxController(controlPath: .sideChannel)
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array((
            "%begin 0 4 1\r\n"
                + "@1\tb25d,80x24,0,0,10\tb25d,80x24,0,0,10\t0\tplan\r\n"
                + "@2\tb25d,80x24,0,0,20\tb25d,80x24,0,0,20\t0\tactive\r\n"
                + "@3\tb25d,80x24,0,0,30\tb25d,80x24,0,0,30\t0\treview\r\n"
                + "%end 0 4 1\r\n"
        ).utf8))
        controller.ingest(Array((
            "%begin 0 5 1\r\n"
                + "@1\t%10\t1\t\tplan\thost\r\n"
                + "@2\t%20\t1\t\tactive\thost\r\n"
                + "@3\t%30\t1\t\treview\thost\r\n"
                + "%end 0 5 1\r\n"
        ).utf8))
        controller.ingest(Array("%begin 0 6 1\r\n@2\r\n%end 0 6 1\r\n".utf8))
        controller.ingest(Array("%begin 0 7 1\r\n%end 0 7 1\r\n".utf8))
        _tmux = State(initialValue: controller)

        let center = AgentCenter(completionAttentionDelayNanoseconds: 0)
        let now = Date.now
        let waiting = AgentCenterHarnessFixtures.make(
            sessionID: sessionID,
            paneID: 10,
            profileID: SwipePadProfile.builtInCodexCLIID,
            name: "Codex",
            host: "tmux-lab",
            transport: "ssh+tmux",
            tmuxSession: "work",
            windowID: 1,
            windowName: "plan",
            status: .waitingForInput,
            tail: "Approve the implementation plan",
            prompt: nil,
            detectedAt: now.addingTimeInterval(-180),
            statusChangedAt: now.addingTimeInterval(-18),
            lastOutputAt: now.addingTimeInterval(-18)
        )
        let visibleFinished = AgentCenterHarnessFixtures.make(
            sessionID: sessionID,
            paneID: 20,
            profileID: SwipePadProfile.builtInClaudeCodeID,
            name: "Claude Code",
            host: "tmux-lab",
            transport: "ssh+tmux",
            tmuxSession: "work",
            windowID: 2,
            windowName: "active",
            status: .justFinished,
            tail: "Completed the active task",
            prompt: nil,
            detectedAt: now.addingTimeInterval(-240),
            statusChangedAt: now.addingTimeInterval(-12),
            lastOutputAt: now.addingTimeInterval(-12)
        )
        let hiddenFinished = AgentCenterHarnessFixtures.make(
            sessionID: sessionID,
            paneID: 30,
            profileID: SwipePadProfile.builtInCodexCLIID,
            name: "Codex",
            host: "tmux-lab",
            transport: "ssh+tmux",
            tmuxSession: "work",
            windowID: 3,
            windowName: "review",
            status: .justFinished,
            tail: "Completed the review",
            prompt: nil,
            detectedAt: now.addingTimeInterval(-300),
            statusChangedAt: now.addingTimeInterval(-8),
            lastOutputAt: now.addingTimeInterval(-8)
        )
        center.installHarnessAgents([waiting, visibleFinished, hiddenFinished])
        center.installHarnessAttention(.needsInput, for: waiting.id)
        center.installHarnessAttention(.justFinished, for: visibleFinished.id)
        center.installHarnessAttention(.justFinished, for: hiddenFinished.id)
        _center = State(initialValue: center)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                SessionTopBar(
                    state: .connected,
                    host: Host(
                        name: "tmux-lab",
                        address: "tmux-lab.local",
                        autoTmux: true,
                        launchMode: .autoTmux
                    ),
                    sessionID: sessionID,
                    sessionIsActive: true,
                    tmux: tmux,
                    tmuxIsDegraded: false,
                    connectionStatus: .ssh(state: .connected),
                    onToggleSidebar: {},
                    sidebarVisible: false,
                    onBack: {},
                    onDisconnect: {},
                    findController: findController,
                    filesPanelOpen: false,
                    onToggleFiles: {},
                    bellController: bellController,
                    forwarderManager: nil,
                    T: DesignTokens.make(mode: .dark, accent: .blue)
                )
                .frame(height: SessionTopBar.reservedHeight(
                    pillHeight: appearance.topBarHeight,
                    compact: CompactLayout.isPhone(horizontalSizeClass)
                ))

                Text("Visible finished · hidden input · hidden finished")
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.top, 28)
                    .accessibilityIdentifier("agent-attention-harness")
                Spacer()
            }
        }
        .environment(appearance)
        .environment(center)
        .environment(registry)
        .environment(palette)
        .onAppear { center.setApplicationActive(true) }
    }
}

/// Host-free system-notification fixture. It starts a synthetic foreground
/// turn, lets XCUITest background the app, then finishes the turn while the
/// finite Agent Center background assertion is active. The visible result is
/// read back from UNUserNotificationCenter after delivery, so this exercises
/// the real iPadOS scheduling path rather than only the policy model.
struct AgentNotificationDeliveryHarnessView: View {
    private let sessionID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
    private let agent: AgentInstance

    @Environment(AppearancePreferences.self) private var appearance
    @Environment(AppPhase.self) private var appPhase
    @Environment(BellController.self) private var bellController
    @Environment(\.designTokens) private var T
    @State private var authorization = "checking"
    @State private var isAuthorized = false
    @State private var syntheticTurnIsWorking = false

    init() {
        let now = Date.now
        agent = AgentCenterHarnessFixtures.make(
            sessionID: sessionID,
            paneID: 42,
            profileID: SwipePadProfile.builtInClaudeCodeID,
            name: "Claude Code",
            host: "notification-lab",
            transport: "ssh+tmux",
            tmuxSession: "work",
            windowID: 4,
            windowName: "background",
            status: .working,
            tail: "Working on notification delivery",
            prompt: nil,
            detectedAt: now,
            statusChangedAt: now,
            lastOutputAt: now
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("agent notification delivery")
                .font(Typography.tesseraMono(size: 20, weight: .semibold))
                .foregroundStyle(T.fg)

            Text("authorization=\(authorization)")
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(T.fgMuted)
                .accessibilityIdentifier("agent-notification-authorization")

            Button("arm background completion") {
                armBackgroundCompletion()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isAuthorized)
            .accessibilityIdentifier("agent-notification-arm")

            Text(bellController.agentNotificationVerification)
                .font(Typography.tesseraMono(size: 13, weight: .medium))
                .foregroundStyle(T.green)
                .accessibilityIdentifier("agent-notification-verification")

            Text("The synthetic Stop is emitted two seconds after arming. Background Tessera immediately.")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(T.bg)
        .task {
            appearance.agentCenterEnabled = true
            appearance.agentCenterNotificationsEnabled = true
            let status = await bellController.requestPermissionIfNeeded()
            authorization = String(status.rawValue)
            isAuthorized = status == .authorized
                || status == .provisional
                || status == .ephemeral
        }
        .onChange(of: appPhase.state) { _, _ in
            updateBackgroundAssertion(reason: "notification-harness-phase")
        }
    }

    private func armBackgroundCompletion() {
        bellController.resetAgentNotificationVerification()
        syntheticTurnIsWorking = true
        updateBackgroundAssertion(reason: "notification-harness-arm")
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            syntheticTurnIsWorking = false
            updateBackgroundAssertion(reason: "notification-harness-stop")
            bellController.agentAttention(
                AgentAttention(
                    agentID: agent.id,
                    kind: .justFinished,
                    occurredAt: .now,
                    sequence: 1
                ),
                agent: agent
            )
        }
    }

    private func updateBackgroundAssertion(reason: String) {
        AgentAttentionBackgroundKeepAlive.shared.update(
            enabled: true,
            workingCount: syntheticTurnIsWorking ? 1 : 0,
            appPhase: appPhase,
            reason: reason
        )
    }
}

/// Host-free tmux-tab fixture used by the integration suite to exercise every
/// close branch without initiating a connection. It includes a single-pane
/// window, a split window, and a zoomed split window (whose visible layout is
/// one pane while its full layout still contains two).
struct TmuxWindowCloseHarnessView: View {
    private let sessionID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    @State private var appearance: AppearancePreferences
    @State private var center = AgentCenter()
    @State private var registry = SessionRegistry()
    @State private var palette = CommandPalette()
    @State private var tmux: TmuxController
    @State private var findController = FindController()
    @Environment(BellController.self) private var bellController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init() {
        let appearance = AppearancePreferences()
        appearance.agentCenterEnabled = false
        _appearance = State(initialValue: appearance)

        let controller = TmuxController(controlPath: .sideChannel)
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array((
            "%begin 0 4 1\r\n"
                + "@1\tb25d,80x24,0,0,10\tb25d,80x24,0,0,10\t0\teditor\r\n"
                + "@2\t8205,80x24,0,0{40x24,0,0,20,39x24,41,0,21}\t8205,80x24,0,0{40x24,0,0,20,39x24,41,0,21}\t0\tdashboard\r\n"
                + "@3\t9205,80x24,0,0{40x24,0,0,30,39x24,41,0,31}\tb25d,80x24,0,0,30\t1\tlogs\r\n"
                + "%end 0 4 1\r\n"
        ).utf8))
        controller.ingest(Array((
            "%begin 0 5 1\r\n"
                + "@1\t%10\t1\t\teditor\thost\r\n"
                + "@2\t%20\t1\t\tdashboard-left\thost\r\n"
                + "@2\t%21\t0\t\tdashboard-right\thost\r\n"
                + "@3\t%30\t1\t\tlogs-top\thost\r\n"
                + "@3\t%31\t0\t\tlogs-bottom\thost\r\n"
                + "%end 0 5 1\r\n"
        ).utf8))
        controller.ingest(Array("%begin 0 6 1\r\n@2\r\n%end 0 6 1\r\n".utf8))
        controller.ingest(Array("%begin 0 7 1\r\n%end 0 7 1\r\n".utf8))
        // A freshly-created window arriving after hydration: bare
        // %window-add, no layout. The details query it fires is answered
        // with an empty body so the command FIFO stays aligned while the
        // layout stays unhydrated — the regression case where closing a
        // brand-new single-pane tab must NOT prompt.
        controller.ingest(Array(
            "%window-add @4\r\n%window-renamed @4 scratch\r\n".utf8
        ))
        // Hydrating the two split side-channel windows queued four pane-border
        // commands behind the pane subscription. Drain those first; the
        // fresh-window details query is the fifth FIFO entry.
        controller.ingest(Array("%begin 0 8 1\r\n%end 0 8 1\r\n".utf8))
        controller.ingest(Array("%begin 0 9 1\r\n%end 0 9 1\r\n".utf8))
        controller.ingest(Array("%begin 0 10 1\r\n%end 0 10 1\r\n".utf8))
        controller.ingest(Array("%begin 0 11 1\r\n%end 0 11 1\r\n".utf8))
        controller.ingest(Array("%begin 0 12 1\r\n%end 0 12 1\r\n".utf8))

        controller.sendBytes = { [weak controller] bytes in
            let command = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard command.hasPrefix("kill-window -t @"),
                  let rawID = command.split(separator: "@").last,
                  let windowID = Int(rawID)
            else { return }
            controller?.ingest(Array((
                "%begin 0 \(900 + windowID) 1\r\n"
                    + "%end 0 \(900 + windowID) 1\r\n"
                    + "%unlinked-window-close @\(windowID)\r\n"
            ).utf8))
        }
        _tmux = State(initialValue: controller)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                SessionTopBar(
                    state: .connected,
                    host: Host(
                        name: "tmux-lab",
                        address: "tmux-lab.local",
                        autoTmux: true,
                        launchMode: .autoTmux
                    ),
                    sessionID: sessionID,
                    sessionIsActive: false,
                    tmux: tmux,
                    tmuxIsDegraded: false,
                    connectionStatus: .ssh(state: .connected),
                    onToggleSidebar: {},
                    sidebarVisible: false,
                    onBack: {},
                    onDisconnect: {},
                    findController: findController,
                    filesPanelOpen: false,
                    onToggleFiles: {},
                    bellController: bellController,
                    forwarderManager: nil,
                    T: DesignTokens.make(mode: .dark, accent: .blue)
                )
                .frame(height: SessionTopBar.reservedHeight(
                    pillHeight: appearance.topBarHeight,
                    compact: CompactLayout.isPhone(horizontalSizeClass)
                ))

                Text("Single pane · split panes · zoomed split")
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.top, 28)
                    .accessibilityIdentifier("tmux-window-close-harness")
                Spacer()
            }
        }
        .environment(appearance)
        .environment(center)
        .environment(registry)
        .environment(palette)
    }
}

/// UITest harness for the tab-overflow window list: enough hydrated
/// windows that the strip genuinely overflows (so the chevron and its
/// popover exist), one already-split window near the active one, and a
/// freshly-added window whose `%window-add` details query is never
/// answered — its pane count stays a guess, pinning the fail-closed
/// close confirmation for the layout-pending gap. `kill-window` sends
/// are answered ONLY with the `%unlinked-window-close` notification (no
/// `%begin`/`%end` reply), which keeps that details query owed for the
/// whole test.
struct TmuxWindowListHarnessView: View {
    private let sessionID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    @State private var appearance: AppearancePreferences
    @State private var center = AgentCenter()
    @State private var registry = SessionRegistry()
    @State private var palette = CommandPalette()
    @State private var tmux: TmuxController
    @State private var findController = FindController()
    @Environment(BellController.self) private var bellController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init() {
        let appearance = AppearancePreferences()
        appearance.agentCenterEnabled = false
        _appearance = State(initialValue: appearance)

        let controller = TmuxController(controlPath: .sideChannel)
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        // list-windows: 15 hydrated windows; @14 is a 2-pane split.
        var listWindows = "%begin 0 4 1\r\n"
        for n in 1...15 {
            if n == 14 {
                listWindows += "@14\t8205,80x24,0,0{40x24,0,0,140,39x24,41,0,141}\t8205,80x24,0,0{40x24,0,0,140,39x24,41,0,141}\t0\tdashboard\r\n"
            } else {
                listWindows += "@\(n)\tb25d,80x24,0,0,\(n)0\tb25d,80x24,0,0,\(n)0\t0\tw\(n)\r\n"
            }
        }
        listWindows += "%end 0 4 1\r\n"
        controller.ingest(Array(listWindows.utf8))
        var listPanes = "%begin 0 5 1\r\n"
        for n in 1...15 where n != 14 {
            listPanes += "@\(n)\t%\(n)0\t1\t\tw\(n)\thost\r\n"
        }
        listPanes += "@14\t%140\t1\t\tdash-left\thost\r\n"
        listPanes += "@14\t%141\t0\t\tdash-right\thost\r\n"
        listPanes += "%end 0 5 1\r\n"
        controller.ingest(Array(listPanes.utf8))
        // Active window @15 — the popover auto-centers it, keeping the
        // rows the tests tap (@13/@14/@16) on screen in the 420pt panel.
        controller.ingest(Array("%begin 0 6 1\r\n@15\r\n%end 0 6 1\r\n".utf8))
        controller.ingest(Array("%begin 0 7 1\r\n%end 0 7 1\r\n".utf8))
        // Fresh window added after hydration. Its details query is
        // deliberately never answered, so its layout stays pending.
        controller.ingest(Array(
            "%window-add @16\r\n%window-renamed @16 fresh\r\n".utf8
        ))

        controller.sendBytes = { [weak controller] bytes in
            let command = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard command.hasPrefix("kill-window -t @"),
                  let rawID = command.split(separator: "@").last,
                  let windowID = Int(rawID)
            else { return }
            controller?.ingest(Array(
                "%unlinked-window-close @\(windowID)\r\n".utf8
            ))
        }
        _tmux = State(initialValue: controller)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                SessionTopBar(
                    state: .connected,
                    host: Host(
                        name: "tmux-lab",
                        address: "tmux-lab.local",
                        autoTmux: true,
                        launchMode: .autoTmux
                    ),
                    sessionID: sessionID,
                    sessionIsActive: false,
                    tmux: tmux,
                    tmuxIsDegraded: false,
                    connectionStatus: .ssh(state: .connected),
                    onToggleSidebar: {},
                    sidebarVisible: false,
                    onBack: {},
                    onDisconnect: {},
                    findController: findController,
                    filesPanelOpen: false,
                    onToggleFiles: {},
                    bellController: bellController,
                    forwarderManager: nil,
                    T: DesignTokens.make(mode: .dark, accent: .blue)
                )
                .frame(height: SessionTopBar.reservedHeight(
                    pillHeight: appearance.topBarHeight,
                    compact: CompactLayout.isPhone(horizontalSizeClass)
                ))

                Text("Overflowing strip · window list popover")
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.top, 28)
                    .accessibilityIdentifier("tmux-window-list-harness")
                Spacer()
            }
        }
        .environment(appearance)
        .environment(center)
        .environment(registry)
        .environment(palette)
    }
}
#endif

/// Variant of `TerminalSurface` that exposes a `onMade` hook so the
/// parent can grab the `TerminalView` after construction, and an
/// `onSend` callback so keystrokes flow out to the session.
///
/// The view returned is a `TesseraTerminalContainer`: a UIView that
/// hosts a SwiftTerm `TerminalView` as its only subview and claims
/// tmux shortcuts via `UIKeyCommand` through its position in the
/// responder chain. See `TesseraTerminalView.swift` for the ⌘T / ⌘⇧W
/// / ⌘1-9 / ⌘⇧[ / ⌘⇧] bindings and why ⌘⇧W (not ⌘W).
/// What an `onPrimaryScrollbackDelta` host did with a primary-screen scroll
/// delta. The distinction between "local visual scroll" and "semantic /
/// dropped" is what gates the coordinator's inertia glide — a fling must
/// never keep emitting wheel/arrow events into a remote app after the
/// fingers leave the trackpad.
enum TerminalPrimaryScrollConsumption {
    /// Not handled — the coordinator falls through to the direct
    /// `contentOffset` write on its own view.
    case notConsumed
    /// Consumed as local visual scrolling (or a scrollback fetch is in
    /// flight that will extend it); inertia may start or continue.
    case consumedLocalScroll
    /// Consumed semantically (forwarded to the remote app) or dropped;
    /// inertia must not start, and an active glide stops here.
    case consumedCancelInertia
}

struct TerminalSurfaceBound: UIViewRepresentable {
    let initialData: [UInt8]
    let onMade: (TerminalView) -> Void
    let onReady: () -> Void
    let onSend: (ArraySlice<UInt8>) -> Void
    let onResize: (Int, Int) -> Void
    let onTitle: (String) -> Void
    let onUserActivity: (() -> Void)?
    let onBell: (() -> Void)?
    /// Primary-screen scroll delta hook (mosh shared surface). Params:
    /// view, raw pointsY, proposed offsetY (after multiplier), max offsetY,
    /// isInertial (true when the delta is a synthetic post-release glide
    /// frame rather than a live gesture event).
    var onPrimaryScrollbackDelta: ((TerminalView, Double, CGFloat, CGFloat, Bool) -> TerminalPrimaryScrollConsumption)? = nil
    var onPrimaryScrollbackUnderflow: ((TerminalView, Double, CGFloat, CGFloat) -> Void)? = nil
    /// Fires with `true` when a trackpad pan begins (or a glide keeps the
    /// surface moving after release) and `false` once both have ended.
    /// The mosh host uses it to keep heavyweight off-gesture work (hidden
    /// overlay mounts, prefetch feeds) from landing mid-scroll.
    var onScrollGestureActivity: ((Bool) -> Void)? = nil
    /// True only for an exact hook-proven `.working` agent on this surface.
    /// The coordinator consumes touch, trackpad, and wheel pans before either
    /// local scrollback or remote TUI semantics can move; the container covers
    /// hardware Page Up / Page Down through the responder chain.
    var agentScrollBlockingActive: Bool = false
    var onAgentScrollBlocked: (() -> Void)? = nil
    let mouseReportingImpliesAltScreen: Bool
    let suppressDirectColorQueryResponses: Bool
    var softwareModifierState: ModifierState? = nil
    let tmuxShortcutsEnabled: Bool
    let onTmuxShortcut: (TesseraTmuxShortcut) -> Void
    let onFindShortcut: ((TesseraFindShortcut) -> Void)?
    let onSwitcherShortcut: ((TesseraSwitcherShortcut) -> Void)?
    let onOpenSettings: (() -> Void)?
    /// ⌘⇧A — toggle Agent Center while SwiftTerm owns first responder.
    var onOpenAgentCenter: (() -> Void)? = nil
    /// When true, `updateUIView` skips its "reclaim first responder"
    /// pass so the find bar's `TextField` can hold focus. Without
    /// this gate the terminal yanks first responder back on every
    /// SwiftUI re-render and the user sees the input cursor blink
    /// briefly in the bar then jump back to the terminal.
    let suppressFirstResponderReclaim: Bool
    /// Actively resign an already-held first responder (and with it the
    /// software keyboard). The reclaim-suppression flag above only prevents
    /// GRABBING focus — a continued-elsewhere veil must also strip focus the
    /// terminal already holds, or software-keyboard keystrokes keep flowing
    /// into the shared PTY underneath the blur.
    var forceResignFirstResponder: Bool = false
    let onHardwareKey: ((TesseraTerminalHardwareKey) -> Void)?
    var onTerminalScrolled: ((TerminalView) -> Void)? = nil
    var scrollRetentionID: String? = nil
    var onScrollDiagnostic: ((String) -> Void)? = nil
    /// OSC 7 cwd reports (SwiftTerm's `hostCurrentDirectoryUpdate`).
    /// Wired only on the shared single-pane surfaces — under tmux the
    /// pane-metadata subscription is the cwd source, not OSC 7.
    var onHostDirectory: ((String?) -> Void)? = nil
    /// ⌘⇧E — toggle the Remote Files panel. Registered on the container
    /// alongside the find/switcher chords.
    var onFilesShortcut: (() -> Void)? = nil
    /// §3 selection-menu path actions ("Quick Look" / "Reveal in
    /// Files") — raw selected text in, resolution happens in the owner.
    var onSelectionPathAction: ((TesseraTerminalSelectionPathAction, String) -> Void)? = nil

    /// True when this surface is a pane in a mounted multi-pane grid. Enables
    /// the bare ⌘[/⌘] pane-cycle and ⌘⇧Return zoom chords (the shared
    /// single-pane terminal leaves this false, so those chords no-op there and
    /// the session switcher rides ⌘⇧K/⌘⇧J instead). Defaulted so existing
    /// single-pane call sites are unchanged.
    var paneCycleEnabled: Bool = false

    /// Mosh tap-to-focus. On the mosh path the remote tmux client paints all
    /// panes into the single shared terminal natively (no Tessera grid mounts),
    /// so a tap can't be routed by a per-pane SwiftUI overlay the way the SSH
    /// grid does it. Instead, when the active window is split, a tap on this
    /// shared surface maps to the pane under the finger and selects it over the
    /// side channel. The closure receives the tap point (in the terminal view's
    /// coordinate space) and the measured cell size, and returns `true` when it
    /// consumed the tap (hit a non-focused pane); `false` falls through to
    /// nothing (single-pane / gutter / already-focused). Defaulted `nil` so the
    /// SSH single-pane and grid surfaces are unaffected.
    var onPaneFocusTap: ((CGPoint, CGSize) -> Bool)? = nil

    /// True while the mosh shared surface paints a multi-pane layout — enables
    /// the dedicated focus-tap recognizer (separate from the SGR mouse-tap) so a
    /// tap selects a pane even with terminal mouse reporting off (the common
    /// all-shells case). Paired with `onPaneFocusTap`; both default off for
    /// other surfaces (SSH single-pane, SSH grid panes).
    var paneFocusTapEnabled: Bool = false

    /// Native-scroll surface (the mosh pane-scrollback overlay only): leave
    /// UIScrollView's built-in pan in charge of trackpad/wheel scrolls
    /// instead of installing the custom scroll recognizer. The pan moving
    /// this view's own contentOffset from the first event is the structural
    /// condition that keeps iPadOS from throttling the gesture — the same
    /// reason SSH panes never lag. Also flips the container into
    /// scroll-only hit-testing so clicks/taps fall through to the live
    /// surface underneath. Default false: SSH surfaces and the shared mosh
    /// surface keep the custom recognizer path unchanged.
    var nativeScrollSurface: Bool = false

    /// Non-nil while a background picture backs this surface's canvas: the
    /// terminal renders its *default* background transparent (view +
    /// container go clear) so the TerminalBackdrop mounted behind it shows
    /// through; cells with explicit ANSI backgrounds still paint opaque.
    /// nil (the default) keeps today's opaque theme-color canvas. Only the
    /// on/off state matters here — dim/fill live on the backdrop itself.
    var terminalBackground: ResolvedTerminalBackground? = nil

    /// Live AppearancePreferences read so updateUIView can re-apply terminal
    /// settings (font size, cursor, scrollback) when the user changes them.
    @Environment(AppearancePreferences.self) private var appearance

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onReady: onReady,
            onSend: onSend,
            onResize: onResize,
            onTitle: onTitle,
            onUserActivity: onUserActivity,
            onBell: onBell,
            onPrimaryScrollbackDelta: onPrimaryScrollbackDelta,
            onPrimaryScrollbackUnderflow: onPrimaryScrollbackUnderflow,
            agentScrollBlockingActive: agentScrollBlockingActive,
            onAgentScrollBlocked: onAgentScrollBlocked,
            mouseReportingImpliesAltScreen: mouseReportingImpliesAltScreen,
            suppressDirectColorQueryResponses: suppressDirectColorQueryResponses,
            softwareModifierState: softwareModifierState,
            onHardwareKey: onHardwareKey,
            onTerminalScrolled: onTerminalScrolled,
            scrollRetentionID: scrollRetentionID,
            onScrollDiagnostic: onScrollDiagnostic
        )
    }

    func makeUIView(context: Context) -> TesseraTerminalContainer {
        let container = TesseraTerminalContainer(frame: .zero)
        container.onTmuxShortcut = onTmuxShortcut
        container.tmuxShortcutsEnabled = tmuxShortcutsEnabled
        container.multiPaneActive = paneCycleEnabled
        container.onFindShortcut = onFindShortcut
        container.onSwitcherShortcut = onSwitcherShortcut
        container.onOpenSettings = onOpenSettings
        container.onOpenAgentCenter = onOpenAgentCenter
        container.agentScrollBlockingActive = agentScrollBlockingActive
        container.onAgentScrollBlocked = onAgentScrollBlocked
        container.onFilesShortcut = onFilesShortcut
        container.onSelectionPathAction = onSelectionPathAction
        context.coordinator.naturalTextEditingEnabled = appearance.naturalTextEditingEnabled
        context.coordinator.smoothScrollingEnabled = appearance.smoothScrollingEnabled
        context.coordinator.smoothScrollingSpeed = appearance.smoothScrollingSpeed
        context.coordinator.noteFocusSuppression(suppressFirstResponderReclaim)
        context.coordinator.onHostDirectory = onHostDirectory

        let view = container.terminalView
        view.agentScrollBlockingActive = agentScrollBlockingActive
        view.onAgentScrollBlocked = onAgentScrollBlocked
        view.terminalDelegate = context.coordinator
        view.onBecameFirstResponder = { [weak view] in
            softwareModifierState?.noteSoftwareKeyboardRequested(
                resign: { [weak view] in
                    guard let view, view.isFirstResponder else { return false }
                    return view.resignFirstResponder()
                },
                become: { [weak view] in
                    guard let view else { return false }
                    return view.becomeFirstResponder()
                }
            )
        }
        // SwiftTerm ships a default inputAccessoryView with esc/ctrl/arrows.
        // Tessera now renders its own bar as a SwiftUI sibling at the bottom
        // of the session (§14.8 — visible regardless of hardware-keyboard
        // state), so suppress SwiftTerm's bar to avoid a duplicate strip.
        view.inputAccessoryView = nil

        // SwiftTerm's TerminalView is a UIScrollView; iOS scrolls the topmost
        // scrollsToTop-enabled scroll view to the top when the status-bar frame
        // region is tapped. We run fullscreen with the status bar hidden, but
        // the tap region persists — so a tap just below the floating top bar
        // would yank the whole scrollback to row 0. Disable it.
        view.scrollsToTop = false

        applyAppearance(to: view, container: container)
        if !initialData.isEmpty { view.feed(byteArray: initialData[...]) }
        context.coordinator.terminalView = view
        context.coordinator.container = container
        context.coordinator.installHardwareKeyPassthroughIfNeeded()
        context.coordinator.observeHardwareKeyboard()
        onMade(view)

        // This recognizer is dormant in every ordinary terminal state. When an
        // exact hook-proven agent starts working it becomes the prerequisite
        // for both Tessera's semantic pan and UIScrollView's native pan, so it
        // consumes the gesture before either local history or a remote TUI can
        // move. It stays on the terminal view (rather than a SwiftUI overlay)
        // so selection, links, clicks, and all non-scroll input remain intact.
        let agentScrollBlockGesture = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleAgentBlockedScroll(_:))
        )
        agentScrollBlockGesture.allowedScrollTypesMask = .all
        agentScrollBlockGesture.delegate = context.coordinator
        agentScrollBlockGesture.isEnabled = agentScrollBlockingActive
        view.addGestureRecognizer(agentScrollBlockGesture)
        view.agentScrollBlockGesture = agentScrollBlockGesture
        context.coordinator.agentScrollBlockGesture = agentScrollBlockGesture
        view.panGestureRecognizer.require(toFail: agentScrollBlockGesture)

        var scrollGesture: UIPanGestureRecognizer?
        if nativeScrollSurface {
            // Native path: no custom recognizer, no cleared scroll mask —
            // UIScrollView's own pan scrolls the view with native physics
            // and deceleration. bounces=false so bottom-reach parks exactly
            // at the live tail (the host's scrolled handler dismisses
            // there) instead of rubber-banding past it.
            view.bounces = false
            container.passthroughNonScrollHits = true
            // With bounces off, a pan that pins contentOffset at an edge
            // stops producing didScroll callbacks — and the host's
            // history-deepening trigger only evaluates from those. The
            // built-in pan keeps tracking while pinned, so pump the
            // scrolled handler from it: rubbing upward at the top still
            // kicks off the one-shot deepen to full history depth.
            view.panGestureRecognizer.addTarget(
                context.coordinator,
                action: #selector(Coordinator.handleNativeScrollSurfacePan(_:))
            )
        } else {
            // §3.1: One semantic scroll gesture covers trackpad (continuous),
            // mouse wheel (discrete), and vertical finger pans while an
            // alternate-screen TUI owns scrolling. Primary-screen touches are
            // rejected by the delegate and stay on UIScrollView's native
            // scrollback path.
            let gesture = UIPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleSemanticScroll(_:))
            )
            gesture.allowedScrollTypesMask = .all
            gesture.delegate = context.coordinator
            gesture.require(toFail: agentScrollBlockGesture)
            view.addGestureRecognizer(gesture)
            context.coordinator.semanticScrollGesture = gesture
            view.semanticScrollGesture = gesture
            scrollGesture = gesture

            // UIScrollView (SwiftTerm's TerminalView superclass) has its own
            // built-in panGestureRecognizer that also responds to scroll-type
            // events. When both fire simultaneously, UIScrollView applies its
            // momentum/deceleration model to contentOffset while our handler
            // sets contentOffset directly — the two compete and produce visible
            // stuttering on fast scrolling. Clearing the built-in pan's scroll
            // mask makes it ignore trackpad/wheel events entirely, leaving
            // scroll handling exclusively to our gesture.
            view.panGestureRecognizer.allowedScrollTypesMask = []

            // With the scroll mask cleared, the built-in pan fires for finger
            // drags only. Piggyback on it so a touch landing mid-glide cancels
            // our inertia instead of fighting UIScrollView's native physics.
            view.panGestureRecognizer.addTarget(
                context.coordinator,
                action: #selector(Coordinator.handleNativeTouchPan(_:))
            )
        }

        // Mouse click gesture for TUI apps (htop, vim, etc.) that
        // enable terminal mouse reporting. SwiftTerm's built-in
        // singleTap has a require(toFail: doubleTap) delay and
        // conflicts with UIScrollView touch handling, making it
        // unreliable on iPadOS. Our gesture fires immediately and
        // uses exact font-metric cell dimensions (matching
        // SwiftTerm's internal computeFontDimensions) to map tap
        // coordinates to the correct grid position.
        let mouseTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMouseTap(_:))
        )
        mouseTap.delegate = context.coordinator
        context.coordinator.mouseTapGesture = mouseTap
        context.coordinator.onPaneFocusTap = onPaneFocusTap
        context.coordinator.paneFocusTapEnabled = paneFocusTapEnabled
        // Prevent phantom clicks at the end of scroll gestures: the tap
        // must not fire if a scroll gesture is in progress or just ended.
        // (Native-scroll surfaces have no custom scroll gesture — and no
        // touch hit-testing either, so their tap recognizers are inert.)
        if let scrollGesture {
            mouseTap.require(toFail: scrollGesture)
        }
        view.addGestureRecognizer(mouseTap)
        // Make SwiftTerm's own singleTap require ours to fail first,
        // so only one fires per tap.
        for existing in view.gestureRecognizers ?? [] {
            if let tap = existing as? UITapGestureRecognizer,
               tap.numberOfTapsRequired == 1,
               tap !== mouseTap {
                tap.require(toFail: mouseTap)
            }
        }

        // Mosh tap-to-focus: a dedicated single-tap recognizer that selects the
        // pane under the finger when the active mosh window is split and mouse
        // reporting is off (`shouldReceive` gates on `paneFocusTapEnabled`).
        // Kept SEPARATE from `mouseTap` on purpose: it carries no
        // `require(toFail:)` against SwiftTerm's singleTap/doubleTap, so it never
        // suppresses link-open / selection-clear / context-menu in split panes
        // and never delays the SGR-click path. It only requires the scroll
        // gesture to fail (no phantom focus change at the end of a scroll).
        let paneFocusTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePaneFocusTap(_:))
        )
        paneFocusTap.delegate = context.coordinator
        if let scrollGesture {
            paneFocusTap.require(toFail: scrollGesture)
        }
        context.coordinator.paneFocusTapGesture = paneFocusTap
        view.addGestureRecognizer(paneFocusTap)

        // Deferred to the next runloop tick because becomeFirstResponder
        // only works once the view is attached to a window. SwiftUI
        // finishes hosting after makeUIView returns, so dispatch-async
        // is the simplest reliable hook. The terminal view is the
        // first responder; the container participates in the responder
        // chain automatically as its superview.
        //
        // Gated on the suppress flag: in a pane grid every pane surface mounts,
        // but only the focused pane (suppress == false) may claim first
        // responder — otherwise the last-mounted pane wins and keystrokes
        // misroute (the structural single-claimant invariant).
        if !suppressFirstResponderReclaim {
            DispatchQueue.main.async {
                guard context.coordinator.permitsFirstResponderReclaim else { return }
                view.becomeFirstResponder()
            }
        }
        return container
    }

    func updateUIView(_ container: TesseraTerminalContainer, context: Context) {
        // Re-assign in case SwiftUI recreates the closure on state
        // change — the container outlives individual updateUIView calls
        // but the captured closure might point at stale state.
        container.onTmuxShortcut = onTmuxShortcut
        container.tmuxShortcutsEnabled = tmuxShortcutsEnabled
        container.multiPaneActive = paneCycleEnabled
        container.onFindShortcut = onFindShortcut
        container.onSwitcherShortcut = onSwitcherShortcut
        container.onOpenSettings = onOpenSettings
        container.onOpenAgentCenter = onOpenAgentCenter
        container.agentScrollBlockingActive = agentScrollBlockingActive
        container.onAgentScrollBlocked = onAgentScrollBlocked
        container.terminalView.agentScrollBlockingActive = agentScrollBlockingActive
        container.terminalView.onAgentScrollBlocked = onAgentScrollBlocked
        container.onFilesShortcut = onFilesShortcut
        container.onSelectionPathAction = onSelectionPathAction
        context.coordinator.onHostDirectory = onHostDirectory
        context.coordinator.onUserActivity = onUserActivity
        context.coordinator.onPrimaryScrollbackDelta = onPrimaryScrollbackDelta
        context.coordinator.onPrimaryScrollbackUnderflow = onPrimaryScrollbackUnderflow
        context.coordinator.onScrollGestureActivity = onScrollGestureActivity
        context.coordinator.onAgentScrollBlocked = onAgentScrollBlocked
        context.coordinator.setAgentScrollBlockingActive(agentScrollBlockingActive)
        context.coordinator.onTerminalScrolled = onTerminalScrolled
        context.coordinator.setScrollRetentionID(scrollRetentionID)
        context.coordinator.onScrollDiagnostic = onScrollDiagnostic
        context.coordinator.mouseReportingImpliesAltScreen = mouseReportingImpliesAltScreen
        context.coordinator.suppressDirectColorQueryResponses = suppressDirectColorQueryResponses
        context.coordinator.softwareModifierState = softwareModifierState
        context.coordinator.naturalTextEditingEnabled = appearance.naturalTextEditingEnabled
        context.coordinator.smoothScrollingEnabled = appearance.smoothScrollingEnabled
        context.coordinator.smoothScrollingSpeed = appearance.smoothScrollingSpeed
        context.coordinator.noteFocusSuppression(suppressFirstResponderReclaim)
        // Re-bind the mosh tap-to-focus closure + gate every update so the hit
        // test reads the current active window's layout, not a stale capture.
        context.coordinator.onPaneFocusTap = onPaneFocusTap
        context.coordinator.paneFocusTapEnabled = paneFocusTapEnabled
        let terminalView = container.terminalView
        terminalView.onBecameFirstResponder = { [weak terminalView] in
            softwareModifierState?.noteSoftwareKeyboardRequested(
                resign: { [weak terminalView] in
                    guard let terminalView, terminalView.isFirstResponder else { return false }
                    return terminalView.resignFirstResponder()
                },
                become: { [weak terminalView] in
                    guard let terminalView else { return false }
                    return terminalView.becomeFirstResponder()
                }
            )
        }

        applyAppearance(to: container.terminalView, container: container)

        // If focus drifted away (e.g., a modal briefly took first
        // responder), reclaim it on the next SwiftUI update pass —
        // unless the find bar is open and intentionally holding focus
        // for its own input. Without this gate the terminal grabs
        // first responder back from the find input on every SwiftUI
        // re-render, so typing into the find bar loses focus mid-key.
        let view = container.terminalView
        if forceResignFirstResponder, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
        if !view.isFirstResponder {
            if !suppressFirstResponderReclaim {
                DispatchQueue.main.async {
                    guard context.coordinator.permitsFirstResponderReclaim else { return }
                    view.becomeFirstResponder()
                    context.coordinator.installHardwareKeyPassthroughIfNeeded()
                }
            }
        } else {
            context.coordinator.installHardwareKeyPassthroughIfNeeded()
        }
    }

    /// Apply the user's font size, cursor style+blink, scrollback, and
    /// terminal theme to the SwiftTerm view. Idempotent — safe to call from
    /// both makeUIView and updateUIView. Setting `view.font` triggers a font-
    /// set rebuild + reflow, so we only touch it when the size actually
    /// changed; theme installation is also gated on a cache stored on the
    /// container, since `installColors` schedules a full canvas repaint.
    private func applyAppearance(
        to view: TerminalView,
        container: TesseraTerminalContainer
    ) {
        let desiredSize = CGFloat(appearance.fontSize)
        if abs(view.font.pointSize - desiredSize) > 0.5 {
            view.font = TesseraTerminalFont.mono(size: desiredSize)
        }

        view.getTerminal().setCursorStyle(swiftTermCursorStyle(
            style: appearance.cursorStyle,
            blink: appearance.cursorBlink
        ))

        // §R4.5 scrollback. SwiftTerm's iOS `changeScrollback` refreshes and
        // runs `updateScroller()`, which snaps the UIScrollView to bottom even
        // when the value is unchanged. Cache the applied value here so ordinary
        // SwiftUI updates from busy sessions do not break local scrollback.
        if container.appliedScrollbackLines != appearance.scrollbackLines {
            view.changeScrollback(appearance.scrollbackLines)
            container.appliedScrollbackLines = appearance.scrollbackLines
        }

        let theme = TerminalTheme.find(id: appearance.terminalThemeID)
        container.terminalDefaultBackgroundRGB = theme.bgRGB
        container.terminalDefaultForegroundRGB = theme.fgRGB
        container.terminalMinimumContrast = 0.30
        // Transparent-canvas mode while a background picture is mounted
        // behind this surface. `nativeBackgroundColor` keeps the theme's RGB
        // (OSC 10/11 reports and contrast math read the RGB components) but
        // drops alpha to 0, which makes both the full-canvas fill and every
        // default-background cell run transparent; explicit ANSI backgrounds
        // are unaffected. Dim/fill changes stay on the SwiftUI backdrop, so
        // they don't force a canvas repaint here.
        let wantsTransparentCanvas = terminalBackground != nil
        if container.appliedThemeID != theme.id
            || container.appliedTransparentCanvas != wantsTransparentCanvas {
            view.installColors(theme.ansi.map(swiftTermColor(rgb:)))
            let bg = uiColor(rgb: theme.bgRGB)
            let fg = uiColor(rgb: theme.fgRGB)
            view.nativeForegroundColor = fg
            if wantsTransparentCanvas {
                view.nativeBackgroundColor = bg.withAlphaComponent(0)
                view.isOpaque = false
                view.backgroundColor = .clear
                container.isOpaque = false
                container.backgroundColor = .clear
            } else {
                view.nativeBackgroundColor = bg
                view.isOpaque = true
                view.backgroundColor = bg
                container.isOpaque = true
                container.backgroundColor = bg
            }
            container.appliedThemeID = theme.id
            container.appliedTransparentCanvas = wantsTransparentCanvas
        }
    }


    private func swiftTermCursorStyle(
        style: CursorStyleOption,
        blink: Bool
    ) -> CursorStyle {
        switch (style, blink) {
        case (.block,     true):  return .blinkBlock
        case (.block,     false): return .steadyBlock
        case (.bar,       true):  return .blinkBar
        case (.bar,       false): return .steadyBar
        case (.underline, true):  return .blinkUnderline
        case (.underline, false): return .steadyUnderline
        }
    }

    /// SwiftTerm.Color uses 16-bit channels (0..65535). 257 = 65535/255 maps
    /// 8-bit values directly without rounding loss.
    private func swiftTermColor(rgb: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red:   UInt16((rgb >> 16) & 0xFF) * 257,
            green: UInt16((rgb >>  8) & 0xFF) * 257,
            blue:  UInt16( rgb        & 0xFF) * 257
        )
    }

    private func uiColor(rgb: Int) -> UIColor {
        UIColor(
            red:   CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >>  8) & 0xFF) / 255,
            blue:  CGFloat( rgb        & 0xFF) / 255,
            alpha: 1
        )
    }

    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        let onReady: () -> Void
        let onSend: (ArraySlice<UInt8>) -> Void
        let onResize: (Int, Int) -> Void
        let onTitle: (String) -> Void
        var onUserActivity: (() -> Void)?
        let onBell: (() -> Void)?
        var onPrimaryScrollbackDelta: ((TerminalView, Double, CGFloat, CGFloat, Bool) -> TerminalPrimaryScrollConsumption)?
        var onPrimaryScrollbackUnderflow: ((TerminalView, Double, CGFloat, CGFloat) -> Void)?
        var onScrollGestureActivity: ((Bool) -> Void)?
        var agentScrollBlockingActive: Bool
        var onAgentScrollBlocked: (() -> Void)?
        var mouseReportingImpliesAltScreen: Bool
        var suppressDirectColorQueryResponses: Bool
        var softwareModifierState: ModifierState?
        let onHardwareKey: ((TesseraTerminalHardwareKey) -> Void)?
        var onTerminalScrolled: ((TerminalView) -> Void)?
        private var scrollRetentionID: String?
        var onScrollDiagnostic: ((String) -> Void)?
        /// OSC 7 forwarding — assigned by `makeUIView`/`updateUIView`
        /// (a `var` like `onPaneFocusTap`, so the memberwise-ish
        /// Coordinator init stays untouched).
        var onHostDirectory: ((String?) -> Void)?
        private var didReportReady = false
        private var scrollDiagnosticEventCount = 0
        private var desiredScrollOffsetY: CGFloat?
        private var scrollRestoreLogCount = 0

        /// §3.1 scroll dispatcher — three-state machine that decides
        /// whether a trackpad scroll turns into a scrollback adjustment,
        /// a terminal mouse wheel event, or a velocity-integrated arrow-key
        /// press. All the policy is in the dispatcher; this coordinator
        /// just feeds it events and routes its outputs.
        ///
        /// Thresholds tuned to match iTerm2 / Terminal.app default feel
        /// on macOS. A Magic Mouse wheel delivers ~3pt per notch via
        /// `UIPanGestureRecognizer` with `allowedScrollTypesMask = .all`,
        /// and the system-default scroll velocity is 3 lines per notch.
        /// So 1pt = 1 line = 1 arrow key:
        ///
        ///   - `pointsPerArrowKey = 1`          → 3pt notch → 3 arrow keys
        ///   - `mouseWheelThresholdPoints = 3`  → 3pt notch → 1 wheel
        ///     tick (vim interprets each tick as 3 lines by default, so
        ///     the visible result is still 3 lines per notch)
        ///
        /// The arrow-key and mouse-wheel modes therefore scroll at the
        /// same visible rate even though the encoding is different. The
        /// per-flush cap keeps a fast continuous fling from flooding the
        /// pty when deltas stack (a 30pt trackpad fling emits up to 8
        /// arrow keys per event, not 30).
        var scrollDispatcher = ScrollDispatcher(config: .init(
            pointsPerArrowKey: 1,
            mouseWheelThresholdPoints: 3,
            maxEventsPerFlush: 8
        ))

        // MARK: Scroll inertia (§3.1 smooth scrolling)
        //
        // Post-release glide for primary-screen scrollback only. Velocity
        // is tracked from live gesture deltas (raw points, pre-multiplier);
        // on release a CADisplayLink synthesizes per-frame deltas that flow
        // through the SAME `applyPrimaryScrollbackDelta` routing as gesture
        // events — so mosh overlay scrolling, history prefetch, and offset
        // retention behave identically during a glide. Alt-screen and
        // mouse-forwarding modes never glide: wheel ticks and arrow keys
        // stay discrete-semantic (the fingers-off stream would desync the
        // remote app's view).

        /// Toggled from AppearancePreferences.smoothScrollingEnabled via
        /// make/updateUIView. Turning it off mid-glide stops the glide.
        var smoothScrollingEnabled = true {
            didSet {
                if !smoothScrollingEnabled {
                    cancelScrollInertia(reason: "setting-off")
                }
            }
        }
        /// Glide-strength multiplier applied to the tracked release
        /// velocity (AppearancePreferences.smoothScrollingSpeed). Takes
        /// effect on the next fling; an active glide keeps its velocity.
        var smoothScrollingSpeed: Double = 0.5

        /// Mirror of `suppressFirstResponderReclaim`, tracked so focus
        /// transitions cancel a running glide. In a pane grid the user's
        /// focus tap lands on a SwiftUI overlay of the *other* pane — no
        /// gesture ever reaches this coordinator — but the flag flips for
        /// both panes on the next update pass. Without this, a glide keeps
        /// running (and keeps advancing the remembered scroll offset that
        /// deep-refresh restore re-asserts) on a pane the user has visibly
        /// left, which reads as the pane scrolling by itself.
        private var lastFocusSuppression: Bool?
        var permitsFirstResponderReclaim: Bool {
            lastFocusSuppression == false
        }

        func noteFocusSuppression(_ suppressed: Bool) {
            guard lastFocusSuppression != suppressed else { return }
            let isTransition = lastFocusSuppression != nil
            lastFocusSuppression = suppressed
            if isTransition {
                cancelScrollInertia(reason: "focus-change")
            }
        }
        private var scrollVelocityTracker = ScrollVelocityTracker()
        private var scrollInertia: ScrollInertiaDecay?
        private var inertiaDisplayLink: CADisplayLink?
        private var inertiaLastTargetTimestamp: CFTimeInterval = 0
        private var inertiaTickCount = 0
        /// True while the most recent nonzero primary-screen delta produced
        /// local visual scrolling (vs. semantic forwarding / bound clamp).
        /// Gates whether release may start a glide.
        private var lastPrimaryScrollWasLocal = false

        // Per-gesture cost probe (diagnostics only): UIKit coalesces scroll
        // events when the main thread can't drain them — visible as large
        // inter-event gaps with proportionally large deltas. Handler time
        // vs. gap time tells whether the stall is inside this handler or
        // elsewhere (SwiftUI invalidation, rendering, transport work).
        private var gestureCostEvents = 0
        private var gestureCostTotalMs: Double = 0
        private var gestureCostMaxMs: Double = 0
        private var gestureGapMaxMs: Double = 0
        private var gestureLastEventAt: CFTimeInterval = 0

        // Scroll-activity latch feeding `onScrollGestureActivity`: active
        // while a trackpad pan is tracking OR a synthetic glide is still
        // running. Kept out of any observable store — it flips at gesture
        // boundaries only and must not trigger SwiftUI invalidation.
        private var panGestureActive = false
        private var scrollActivityLatched = false

        private func updateScrollActivity() {
            let active = panGestureActive || inertiaDisplayLink != nil
            guard active != scrollActivityLatched else { return }
            scrollActivityLatched = active
            onScrollGestureActivity?(active)
        }

        // Display link held for the duration of an active pan gesture.
        // It is the drain driver for the commit-free event path: gesture
        // events only queue points, and this link applies them once per
        // frame (`drainPendingGestureScroll`). The tick counters feed the
        // gesture-cost diagnostic — frames≈events with ~8ms gaps is the
        // warm regime, frames≈0 means the OS throttled the update cycle
        // for the whole gesture (the cold regime the hot-buffer prefetch
        // exists to avoid).
        private var gestureFrameLink: CADisplayLink?
        private var gestureFrameTicks = 0
        private var gestureFrameLastTimestamp: CFTimeInterval = 0
        private var gestureFrameGapMaxMs: Double = 0
        private var gestureFrameDurationMs: Double = 0

        /// Local scrollback points accumulated from gesture events and
        /// applied on gesture display-link ticks (or gesture end),
        /// never per event. Round-3 device logs showed the regime this
        /// avoids: on a cold (idle-refresh) screen, per-event work that
        /// commits blocks the main thread to the panel's 24Hz — event
        /// delivery, MainActor ingest, and display links all starve
        /// until the fingers lift. With events commit-free, the thread
        /// stays available, ingest keeps rendering mid-gesture, and the
        /// pipeline self-ramps to 120Hz (observed in the same logs once
        /// anything was presenting). Semantic actions (wheel forwards,
        /// arrow-key bytes) stay per-event — they don't commit locally.
        private var pendingGestureScrollPoints: Double = 0
        private var lastGestureDrainAt: CFTimeInterval = 0

        /// Weak ref so the scroll handler can read terminal state
        /// (`isCurrentBufferAlternate`, `mouseMode`) and call scroll
        /// methods (`scrollUp`/`scrollDown`) without creating a retain
        /// cycle with the coordinator.
        weak var terminalView: TerminalView?

        /// Mouse-click tap gesture, stored so the delegate can
        /// distinguish it from other recognizers.
        weak var mouseTapGesture: UITapGestureRecognizer?

        /// Our trackpad scroll pan, stored so the inertia tick's
        /// concurrent-pan poll can exclude it.
        weak var semanticScrollGesture: UIPanGestureRecognizer?

        /// Dormant unless an exact hook-proven agent is `.working`. Stored so
        /// SwiftUI updates can enable/disable it without rebuilding the surface.
        weak var agentScrollBlockGesture: UIPanGestureRecognizer?
        private var agentScrollBlockNotified = false

        /// Mosh tap-to-focus gesture (split windows only) — a separate
        /// recognizer from `mouseTapGesture`, stored so the delegate can gate it.
        weak var paneFocusTapGesture: UITapGestureRecognizer?

        /// Mosh tap-to-focus: maps a tap → pane and selects it over the side
        /// channel. Set by `TerminalSurfaceBound.update`; nil on every other
        /// surface. `paneFocusTapEnabled` mirrors "the active mosh window is
        /// split" so the focus-tap recognizer fires even with mouse reporting off.
        var onPaneFocusTap: ((CGPoint, CGSize) -> Bool)?
        var paneFocusTapEnabled: Bool = false


        /// Container weak ref kept for the hardware-key-passthrough wiring
        /// to find a stable reference point.
        weak var container: TesseraTerminalContainer?

        private var keyboardConnectObserver: NSObjectProtocol?
        private var resignActiveObserver: NSObjectProtocol?
        private weak var hardwareKeyboard: GCKeyboard?
        var naturalTextEditingEnabled = true
        private var pendingInputBytes: [UInt8] = []

        init(
            onReady: @escaping () -> Void,
            onSend: @escaping (ArraySlice<UInt8>) -> Void,
            onResize: @escaping (Int, Int) -> Void,
            onTitle: @escaping (String) -> Void,
            onUserActivity: (() -> Void)?,
            onBell: (() -> Void)?,
            onPrimaryScrollbackDelta: ((TerminalView, Double, CGFloat, CGFloat, Bool) -> TerminalPrimaryScrollConsumption)?,
            onPrimaryScrollbackUnderflow: ((TerminalView, Double, CGFloat, CGFloat) -> Void)?,
            agentScrollBlockingActive: Bool,
            onAgentScrollBlocked: (() -> Void)?,
            mouseReportingImpliesAltScreen: Bool,
            suppressDirectColorQueryResponses: Bool,
            softwareModifierState: ModifierState?,
            onHardwareKey: ((TesseraTerminalHardwareKey) -> Void)?,
            onTerminalScrolled: ((TerminalView) -> Void)?,
            scrollRetentionID: String?,
            onScrollDiagnostic: ((String) -> Void)?
        ) {
            self.onReady = onReady
            self.onSend = onSend
            self.onResize = onResize
            self.onTitle = onTitle
            self.onUserActivity = onUserActivity
            self.onBell = onBell
            self.onPrimaryScrollbackDelta = onPrimaryScrollbackDelta
            self.onPrimaryScrollbackUnderflow = onPrimaryScrollbackUnderflow
            self.agentScrollBlockingActive = agentScrollBlockingActive
            self.onAgentScrollBlocked = onAgentScrollBlocked
            self.mouseReportingImpliesAltScreen = mouseReportingImpliesAltScreen
            self.suppressDirectColorQueryResponses = suppressDirectColorQueryResponses
            self.softwareModifierState = softwareModifierState
            self.onHardwareKey = onHardwareKey
            self.onTerminalScrolled = onTerminalScrolled
            self.scrollRetentionID = scrollRetentionID
            self.onScrollDiagnostic = onScrollDiagnostic
            super.init()

            // A glide must not survive suspension: CADisplayLink freezes
            // while suspended but stays valid, so without this an hours-old
            // fling would visibly resume on foreground — and the link's
            // target retention would keep a dismantled surface's
            // coordinator alive until its first foreground tick.
            resignActiveObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.cancelScrollInertia(reason: "app-inactive")
            }
        }

        deinit {
            if let obs = keyboardConnectObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            if let obs = resignActiveObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func setScrollRetentionID(_ id: String?) {
            guard scrollRetentionID != id else { return }
            scrollRetentionID = id
            // Pane/window switch on the shared mosh surface — a glide from
            // the previous pane must not carry into the new one.
            cancelScrollInertia(reason: "identity-change")
            clearDesiredScrollOffset(reason: "identity-change", view: terminalView)
        }

        func setAgentScrollBlockingActive(_ active: Bool) {
            guard agentScrollBlockingActive != active else { return }
            agentScrollBlockingActive = active
            agentScrollBlockGesture?.isEnabled = active
            guard active else {
                agentScrollBlockNotified = false
                return
            }

            // Stop every continuation of an already-started scroll at the
            // lifecycle transition. Future physical gestures are consumed by
            // the blocker recognizer; these resets cover native deceleration,
            // semantic-frame backlog, and Tessera's synthetic inertia.
            cancelScrollInertia(reason: "agent-working")
            pendingGestureScrollPoints = 0
            scrollVelocityTracker.reset()
            lastPrimaryScrollWasLocal = false
            if let gesture = semanticScrollGesture, gesture.state != .possible {
                gesture.isEnabled = false
                gesture.isEnabled = true
            }
            if let view = terminalView {
                if view.panGestureRecognizer.state != .possible {
                    view.panGestureRecognizer.isEnabled = false
                    view.panGestureRecognizer.isEnabled = true
                }
                view.setContentOffset(view.contentOffset, animated: false)
            }
        }

        // MARK: - Hardware keyboard / accessory bar (§3.5 R3.5.3)

        /// Subscribe to GCKeyboard connect/disconnect so the hardware-key
        /// passthrough re-binds when a Magic Keyboard is plugged in mid-
        /// session. The accessory bar itself is now a SwiftUI sibling and
        /// no longer cares about hardware keyboard presence.
        func observeHardwareKeyboard() {
            keyboardConnectObserver = NotificationCenter.default.addObserver(
                forName: .GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.installHardwareKeyPassthroughIfNeeded()
            }
            installHardwareKeyPassthroughIfNeeded()
        }

        /// SwiftTerm's PageUp/PageDown handling can consume hardware keys as
        /// local scrollback when its local terminal state says "normal buffer".
        /// In mosh, that state can lag the remote TUI, so use GCKeyboard to
        /// catch raw PageUp/PageDown events and send VT sequences ourselves
        /// only when SwiftTerm would not already send them.
        func installHardwareKeyPassthroughIfNeeded() {
            guard onHardwareKey != nil,
                  let keyboard = GCKeyboard.coalesced,
                  let input = keyboard.keyboardInput
            else { return }

            if hardwareKeyboard === keyboard {
                return
            }

            hardwareKeyboard = keyboard
            input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
                DispatchQueue.main.async {
                    self?.handleHardwareKeyCode(keyCode, pressed: pressed)
                }
            }
        }

        private func handleHardwareKeyCode(_ keyCode: GCKeyCode, pressed: Bool) {
            guard pressed,
                  let key = terminalHardwareKey(for: keyCode),
                  let view = terminalView,
                  view.isFirstResponder,
                  let onHardwareKey
            else { return }

            if agentScrollBlockingActive {
                onUserActivity?()
                onAgentScrollBlocked?()
                emitScrollDiagnostic(
                    "agent-scroll-blocked input=hardware-\(String(describing: key))"
                )
                return
            }

            let terminal = view.getTerminal()
            if terminal.applicationCursor || terminal.isCurrentBufferAlternate {
                MoshDiagnostics.log(
                    "mosh hardware key \(String(describing: key)) left to SwiftTerm appCursor=\(terminal.applicationCursor) alt=\(terminal.isCurrentBufferAlternate)"
                )
                return
            }

            MoshDiagnostics.log(
                "mosh hardware key \(String(describing: key)) via GCKeyboard appCursor=\(terminal.applicationCursor) alt=\(terminal.isCurrentBufferAlternate)"
            )
            onUserActivity?()
            onHardwareKey(key)
        }

        private func terminalHardwareKey(for keyCode: GCKeyCode) -> TesseraTerminalHardwareKey? {
            switch keyCode {
            case .pageUp:
                return .pageUp
            case .pageDown:
                return .pageDown
            default:
                return nil
            }
        }

        private var hardwareCommandKeyActive: Bool {
            guard let input = hardwareKeyboard?.keyboardInput ?? GCKeyboard.coalesced?.keyboardInput else {
                return false
            }
            return input.button(forKeyCode: .leftGUI)?.isPressed == true
                || input.button(forKeyCode: .rightGUI)?.isPressed == true
        }

        // MARK: - TerminalViewDelegate

        func scrolled(source: TerminalView, position: Double) {
            restoreDesiredScrollOffsetIfNeeded(in: source, position: position)
            onTerminalScrolled?(source)
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            onTitle(title)
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Reflow rebases every offset; a glide across it would land
            // somewhere meaningless.
            cancelScrollInertia(reason: "resize")
            emitScrollDiagnostic(
                "size-changed cols=\(newCols) rows=\(newRows) bounds=\(Self.format(source.bounds.height)) content=\(Self.format(source.contentSize.height))"
            )
            if !didReportReady, newCols > 0, newRows > 0 {
                didReportReady = true
                onReady()
            }
            onResize(newCols, newRows)
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            onHostDirectory?(directory)
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onUserActivity?()
            let colorResponse = TerminalOSCColorResponseRewriter.rewriteColorQueryResponse(
                data,
                defaultForegroundRGB: container?.terminalDefaultForegroundRGB ?? 0xD4D4D4,
                defaultBackgroundRGB: container?.terminalDefaultBackgroundRGB ?? 0x000000
            )
            if colorResponse.isColorQueryResponse {
                if !pendingInputBytes.isEmpty {
                    onSend(pendingInputBytes[...])
                    pendingInputBytes.removeAll(keepingCapacity: true)
                }
                if suppressDirectColorQueryResponses {
                    return
                }
                onSend(colorResponse.bytes[...])
                return
            }

            // Real user input (keys, forwarded mouse) while gliding: stop
            // the glide — terminals snap attention back to the live cursor
            // on input, and mosh invalidates its capture overlay. Color
            // query responses returned above; other terminal auto-replies
            // (CPR, DA, DSR, window reports, DCS) carry no user intent and
            // must not kill a glide just because remote output queried us.
            if !Self.isTerminalAutoReply(data) {
                cancelScrollInertia(reason: "user-input")
                // Typing also snaps the viewport to the live prompt (the
                // iTerm2/Terminal convention) and drops the retained scroll
                // offset — otherwise the offset-restore machinery pins the
                // view off-bottom while the command's output streams and
                // the prompt ends up hidden below the fold. Forwarded SGR
                // mouse reports are pointer events, not typing — a click
                // must not yank the viewport.
                if !Self.isMouseReport(data) {
                    snapToBottomForUserInput()
                }
            }

            let normalized = TerminalInputNormalizer.normalizeInput(
                data,
                pending: &pendingInputBytes,
                naturalTextEditingEnabled: naturalTextEditingEnabled,
                commandKeyActive: hardwareCommandKeyActive
            )
            if !normalized.isEmpty {
                let outgoing: [UInt8]
                if !Self.isTerminalAutoReply(data),
                   !Self.isMouseReport(data),
                   let softwareModifierState,
                   softwareModifierState.armed.isAny {
                    outgoing = softwareModifierState
                        .encodeSoftwareKeyboardPayload(normalized)
                } else {
                    outgoing = normalized
                }
                onSend(outgoing[...])
            }
        }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { UIApplication.shared.open(url) }
        }
        func bell(source: TerminalView) { onBell?() }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        // MARK: - Trackpad scroll handling (§3.1)

        private func emitScrollDiagnostic(_ message: String) {
            onScrollDiagnostic?(message)
        }

        private func rememberDesiredScrollOffset(_ offsetY: CGFloat, maxOffsetY: CGFloat) {
            if maxOffsetY - offsetY <= 1.0 {
                clearDesiredScrollOffset(reason: "bottom", view: terminalView)
                return
            }
            desiredScrollOffsetY = min(max(0, offsetY), maxOffsetY)
        }

        private func clearDesiredScrollOffset(reason: String, view: TerminalView?) {
            guard desiredScrollOffsetY != nil else { return }
            let position = view.map { scrollOffsetDescription(for: $0) } ?? "nil"
            emitScrollDiagnostic("scroll-retention-clear reason=\(reason) position=\(position)")
            desiredScrollOffsetY = nil
        }

        private func restoreDesiredScrollOffsetIfNeeded(in view: TerminalView, position: Double) {
            guard let desiredScrollOffsetY else { return }
            let terminal = view.getTerminal()
            if terminal.isCurrentBufferAlternate {
                clearDesiredScrollOffset(reason: "alt-screen", view: view)
                return
            }

            let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            let offsetY = min(max(0, desiredScrollOffsetY), maxOffsetY)
            if maxOffsetY - offsetY <= 1.0 {
                clearDesiredScrollOffset(reason: "bottom", view: view)
                return
            }
            self.desiredScrollOffsetY = offsetY
            guard abs(view.contentOffset.y - offsetY) > 0.5 else { return }

            if scrollRestoreLogCount < 40 {
                scrollRestoreLogCount += 1
                emitScrollDiagnostic(
                    "scroll-offset-restore from=\(Self.format(view.contentOffset.y)) to=\(Self.format(offsetY)) max=\(Self.format(maxOffsetY)) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height)) position=\(String(format: "%.3f", position))"
                )
            }
            view.contentOffset = CGPoint(x: view.contentOffset.x, y: offsetY)
        }

        private func scrollOffsetDescription(for view: TerminalView) -> String {
            "off=\(Self.format(view.contentOffset.y))/\(Self.format(max(0, view.contentSize.height - view.bounds.height))) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height))"
        }

        private static func format(_ value: CGFloat) -> String {
            String(format: "%.1f", Double(value))
        }

        private static func actionDescription(_ actions: [ScrollDispatcher.Action]) -> String {
            guard !actions.isEmpty else { return "none" }
            return actions.map { action in
                switch action {
                case .scrollbackDelta(let pointsY):
                    return "scrollback(\(String(format: "%.1f", pointsY)))"
                case .mouseWheel(let buttonFlags, _, _, let repeatCount):
                    return "wheel(button=\(buttonFlags),count=\(repeatCount))"
                case .writeBytes(let bytes):
                    return "writeBytes(\(bytes.count))"
                }
            }.joined(separator: "+")
        }

        @objc func handleSemanticScroll(_ recognizer: UIPanGestureRecognizer) {
            guard let view = terminalView else { return }
            let handlerStart = CACurrentMediaTime()
            if recognizer.state == .began {
                gestureCostEvents = 0
                gestureCostTotalMs = 0
                gestureCostMaxMs = 0
                gestureGapMaxMs = 0
                panGestureActive = true
                updateScrollActivity()
                startGestureFrameDrainLink()
            } else if gestureLastEventAt > 0 {
                gestureGapMaxMs = max(
                    gestureGapMaxMs, (handlerStart - gestureLastEventAt) * 1000
                )
            }
            gestureLastEventAt = handlerStart
            defer {
                let elapsedMs = (CACurrentMediaTime() - handlerStart) * 1000
                gestureCostEvents += 1
                gestureCostTotalMs += elapsedMs
                gestureCostMaxMs = max(gestureCostMaxMs, elapsedMs)
                if recognizer.state == .ended || recognizer.state == .cancelled {
                    if gestureCostEvents > 1 {
                        emitScrollDiagnostic(
                            "gesture-cost events=\(gestureCostEvents) handlerAvgMs=\(String(format: "%.2f", gestureCostTotalMs / Double(gestureCostEvents))) handlerMaxMs=\(String(format: "%.2f", gestureCostMaxMs)) gapMaxMs=\(String(format: "%.1f", gestureGapMaxMs)) frames=\(gestureFrameTicks) frameGapMaxMs=\(String(format: "%.1f", gestureFrameGapMaxMs)) frameMs=\(String(format: "%.1f", gestureFrameDurationMs))"
                        )
                        gestureLastEventAt = 0
                    }
                    stopGestureFrameDrainLink()
                    // Runs after the body, so a glide launched at .ended
                    // keeps the activity latch up until the glide stops.
                    panGestureActive = false
                    updateScrollActivity()
                }
            }
            onUserActivity?()
            scrollDiagnosticEventCount += 1
            let diagnosticEvent = scrollDiagnosticEventCount

            let translation = recognizer.translation(in: view)
            // Reset to zero so the next callback delivers an incremental
            // delta rather than cumulative-from-gesture-start.
            recognizer.setTranslation(.zero, in: view)

            let terminal = view.getTerminal()
            let mouseMode = terminal.mouseMode
            let isAltScreen = terminal.isCurrentBufferAlternate
                || (mouseReportingImpliesAltScreen && mouseMode != .off)
            let mouseReporting: ScrollDispatcher.MouseReporting =
                (mouseMode != .off) ? .vt200OrLater : .off
            let state = ScrollDispatcher.TerminalState(
                isAltScreen: isAltScreen,
                mouseReporting: mouseReporting
            )

            let phase: ScrollDispatcher.ScrollEvent.Phase
            switch recognizer.state {
            case .began: phase = .began
            case .changed: phase = .changed
            case .ended: phase = .ended
            case .cancelled, .failed: phase = .cancelled
            default: phase = .changed
            }

            // A fresh physical gesture always takes over from a glide.
            switch phase {
            case .began:
                cancelScrollInertia(reason: "new-gesture")
                scrollVelocityTracker.reset()
                lastPrimaryScrollWasLocal = false
                pendingGestureScrollPoints = 0
                lastGestureDrainAt = handlerStart
            case .changed:
                if inertiaDisplayLink != nil {
                    cancelScrollInertia(reason: "new-gesture")
                }
                scrollVelocityTracker.record(
                    deltaY: Double(translation.y),
                    timestamp: CACurrentMediaTime()
                )
            case .cancelled:
                scrollVelocityTracker.reset()
                lastPrimaryScrollWasLocal = false
                // Another recognizer took the touches — applying the
                // queued remainder would fight it over contentOffset.
                pendingGestureScrollPoints = 0
            case .ended:
                break
            }

            // For wheel events, use center of terminal. Unlike clicks,
            // wheel scroll position rarely matters to apps, and keeping
            // the synthetic event near the middle avoids edge-triggered
            // UI behavior in TUIs.
            let cols = terminal.cols
            let rows = terminal.rows
            let col = max(1, (cols + 1) / 2)
            let row = max(1, (rows + 1) / 2)

            let event = ScrollDispatcher.ScrollEvent(
                deltaY: Double(translation.y),
                cursorColumn: col,
                cursorRow: row,
                phase: phase
            )

            let actions = scrollDispatcher.handle(event: event, terminal: state)
            if actions.isEmpty {
                emitScrollDiagnostic(
                    "event=\(diagnosticEvent) phase=\(phase) delta=\(Self.format(translation.y)) termAlt=\(terminal.isCurrentBufferAlternate) stateAlt=\(isAltScreen) mouse=\(mouseMode) actions=none before=\(scrollOffsetDescription(for: view))"
                )
            }

            for action in actions {
                switch action {
                case .scrollbackDelta(let pointsY):
                    pendingGestureScrollPoints += pointsY
                    emitScrollDiagnostic(
                        "event=\(diagnosticEvent) phase=\(phase) delta=\(Self.format(translation.y)) termAlt=\(terminal.isCurrentBufferAlternate) stateAlt=\(isAltScreen) mouse=\(mouseMode) actions=\(Self.actionDescription(actions)) queued pending=\(String(format: "%.1f", pendingGestureScrollPoints))"
                    )
                    // Safety valve: if display-link ticks aren't coming
                    // (the starved regime this coalescing is meant to
                    // break out of), don't hold scroll output hostage —
                    // apply inline at ≥20Hz so the worst case matches
                    // the old per-event behavior, not a frozen screen.
                    if handlerStart - lastGestureDrainAt > 0.05 {
                        drainPendingGestureScroll(reason: "stall-fallback")
                    }
                case .mouseWheel(let buttonFlags, let cursorColumn, let cursorRow, let repeatCount):
                    lastPrimaryScrollWasLocal = false
                    clearDesiredScrollOffset(reason: "mouse-wheel", view: view)
                    let x = max(0, cursorColumn - 1)
                    let y = max(0, cursorRow - 1)
                    for _ in 0..<repeatCount {
                        terminal.sendEvent(buttonFlags: buttonFlags, x: x, y: y)
                    }
                    emitScrollDiagnostic(
                        "event=\(diagnosticEvent) phase=\(phase) delta=\(Self.format(translation.y)) termAlt=\(terminal.isCurrentBufferAlternate) stateAlt=\(isAltScreen) mouse=\(mouseMode) actions=\(Self.actionDescription(actions)) mouse-wheel button=\(buttonFlags) count=\(repeatCount) at=\(cursorColumn),\(cursorRow) position=\(scrollOffsetDescription(for: view))"
                    )
                case .writeBytes(let bytes):
                    lastPrimaryScrollWasLocal = false
                    clearDesiredScrollOffset(reason: "write-bytes", view: view)
                    onSend(ArraySlice(bytes))
                    emitScrollDiagnostic(
                        "event=\(diagnosticEvent) phase=\(phase) delta=\(Self.format(translation.y)) termAlt=\(terminal.isCurrentBufferAlternate) stateAlt=\(isAltScreen) mouse=\(mouseMode) actions=\(Self.actionDescription(actions)) write-bytes count=\(bytes.count) position=\(scrollOffsetDescription(for: view))"
                    )
                }
            }

            if phase == .ended {
                drainPendingGestureScroll(reason: "gesture-end")
                maybeStartScrollInertia(view: view, isAltScreen: isAltScreen)
                scrollVelocityTracker.reset()
            }
        }

        /// Apply the scrollback points queued since the last display
        /// frame. Runs on gesture display-link ticks and at gesture end
        /// — the only two places local scroll output is committed.
        private func drainPendingGestureScroll(reason: String) {
            lastGestureDrainAt = CACurrentMediaTime()
            let points = pendingGestureScrollPoints
            guard points != 0, let view = terminalView else { return }
            pendingGestureScrollPoints = 0
            let localScroll = applyPrimaryScrollbackDelta(
                view: view,
                pointsY: points,
                isInertial: false,
                diagnosticPrefix: "gesture-frame-drain reason=\(reason)"
            )
            if abs(points) > 0.01 {
                lastPrimaryScrollWasLocal = localScroll
            }
        }

        // MARK: - Primary scrollback application (shared gesture + inertia)

        /// Apply one primary-screen scrollback delta — from a live gesture
        /// event or a synthetic inertia frame. Returns true when the delta
        /// produced (or a pending fetch will produce) local visual
        /// scrolling, i.e. inertia may start or continue; false on semantic
        /// consumption or a hard bound.
        @discardableResult
        private func applyPrimaryScrollbackDelta(
            view: TerminalView,
            pointsY: Double,
            isInertial: Bool,
            diagnosticPrefix: String
        ) -> Bool {
            // SwiftTerm's `TerminalView` is a UIScrollView subclass on iOS
            // and the Metal renderer reads `contentOffset.y` (not `yDisp`)
            // to decide which rows to draw. Its public `scrollUp(lines:)`
            // API ends by calling `updateScroller`, which snaps
            // contentOffset back to the bottom — so that API is broken for
            // scrollback. Instead we write `contentOffset.y` directly.
            //
            // Note SwiftTerm on iOS scrolls in continuous pixel units, not
            // line-snapped like iTerm2 on macOS — you can briefly see half
            // a row at the top of the view mid-scroll. Line-snap would
            // require intercepting Metal's `firstRow` computation and is
            // out of scope.
            //
            // 3× multiplier: a raw 1:1 pass-through ended up too slow on
            // iPad (Safari-style natural scroll feels brisker than a mouse
            // wheel on a desktop by reflex). Each 3pt wheel notch now moves
            // 9pt of content, five events per click ≈ 45pt ≈ 3 lines —
            // matching iTerm2 default feel.
            let beforeY = view.contentOffset.y
            let newY = beforeY - CGFloat(pointsY) * 3
            let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            let consumption = onPrimaryScrollbackDelta?(view, pointsY, newY, maxOffsetY, isInertial)
                ?? .notConsumed
            switch consumption {
            case .consumedLocalScroll, .consumedCancelInertia:
                clearDesiredScrollOffset(reason: "primary-consumed", view: view)
                if !diagnosticPrefix.isEmpty {
                    emitScrollDiagnostic(
                        "\(diagnosticPrefix) primary-consumed local=\(consumption == .consumedLocalScroll) points=\(String(format: "%.1f", pointsY)) before=\(Self.format(beforeY)) proposed=\(Self.format(newY)) after=\(Self.format(view.contentOffset.y)) max=\(Self.format(maxOffsetY)) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height))"
                    )
                }
                return consumption == .consumedLocalScroll
            case .notConsumed:
                break
            }
            let targetY = min(max(0, newY), maxOffsetY)
            view.contentOffset = CGPoint(
                x: view.contentOffset.x,
                y: targetY
            )
            rememberDesiredScrollOffset(targetY, maxOffsetY: maxOffsetY)
            if !diagnosticPrefix.isEmpty {
                emitScrollDiagnostic(
                    "\(diagnosticPrefix) primary-write points=\(String(format: "%.1f", pointsY)) before=\(Self.format(beforeY)) proposed=\(Self.format(newY)) after=\(Self.format(view.contentOffset.y)) max=\(Self.format(maxOffsetY)) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height))"
                )
            }
            if pointsY > 0 {
                onPrimaryScrollbackUnderflow?(
                    view,
                    pointsY,
                    newY,
                    maxOffsetY
                )
            }
            // Clamped proposal = the delta hit an edge of the scrollable
            // range: no glide from here. (For mosh single-pane, the
            // underflow prefetch above has already fired — content arrives
            // and re-anchors the view; the user can fling again.)
            return abs(targetY - newY) < 0.5
        }

        // MARK: - Scroll inertia driver

        private func maybeStartScrollInertia(view: TerminalView, isAltScreen: Bool) {
            guard smoothScrollingEnabled,
                  !isAltScreen,
                  lastPrimaryScrollWasLocal,
                  let velocity = scrollVelocityTracker.releaseVelocity(at: CACurrentMediaTime())
            else { return }
            // Scale by the user's glide-speed preference. At the slow end
            // a soft flick can land under the decay's stop threshold —
            // nothing worth animating, skip the launch entirely.
            let inertia = ScrollInertiaDecay(velocity: velocity * smoothScrollingSpeed)
            guard !inertia.isFinished else { return }
            scrollInertia = inertia
            inertiaTickCount = 0
            inertiaLastTargetTimestamp = 0
            if inertiaDisplayLink == nil {
                let link = CADisplayLink(
                    target: self,
                    selector: #selector(handleInertiaTick(_:))
                )
                // Glide at the panel's native cadence on ProMotion iPads.
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 60, maximum: 120, preferred: 120
                )
                link.add(to: .main, forMode: .common)
                inertiaDisplayLink = link
            }
            updateScrollActivity()
            emitScrollDiagnostic(
                "inertia-start velocity=\(String(format: "%.1f", velocity))"
            )
        }

        @objc private func handleInertiaTick(_ link: CADisplayLink) {
            guard var inertia = scrollInertia,
                  let view = terminalView,
                  view.window != nil
            else {
                cancelScrollInertia(reason: "view-detached")
                return
            }

            // A TUI can take the terminal to the alt screen mid-glide
            // (delayed `less` startup, mosh repaint) — re-check the same
            // predicate the dispatcher used and stop before emitting any
            // motion the remote app would see as stale.
            let terminal = view.getTerminal()
            let isAltScreen = terminal.isCurrentBufferAlternate
                || (mouseReportingImpliesAltScreen && terminal.mouseMode != .off)
            guard !isAltScreen else {
                cancelScrollInertia(reason: "alt-screen")
                return
            }

            // A different pan actively tracking touches — SwiftTerm's
            // selection pan claims finger drags while a selection is
            // active, so the built-in-pan target-action never fires for
            // them. Poll here so the glide yields before the two writers
            // fight over contentOffset (selection autoscroll vs our tick).
            if view.gestureRecognizers?.contains(where: { recognizer in
                recognizer is UIPanGestureRecognizer
                    && recognizer !== semanticScrollGesture
                    && (recognizer.state == .began || recognizer.state == .changed)
            }) == true {
                cancelScrollInertia(reason: "concurrent-pan")
                return
            }

            // Frame delta from the previous tick's target. Clamped so a
            // main-thread hitch doesn't turn into a teleport.
            let dt: CFTimeInterval
            if inertiaLastTargetTimestamp == 0 {
                dt = link.targetTimestamp - link.timestamp
            } else {
                dt = min(link.targetTimestamp - inertiaLastTargetTimestamp, 0.1)
            }
            inertiaLastTargetTimestamp = link.targetTimestamp

            let delta = inertia.step(dt: dt)
            scrollInertia = inertia
            inertiaTickCount += 1
            guard delta != 0 else {
                cancelScrollInertia(reason: "decayed")
                return
            }

            let tick = inertiaTickCount
            let localScroll = applyPrimaryScrollbackDelta(
                view: view,
                pointsY: delta,
                isInertial: true,
                // Sampled: a 2s glide at 120Hz would otherwise flood the
                // diagnostics ring buffer.
                diagnosticPrefix: tick % 15 == 0
                    ? "inertia tick=\(tick) v=\(String(format: "%.1f", inertia.velocity))"
                    : ""
            )
            if !localScroll {
                cancelScrollInertia(reason: "bound-or-consumed")
            } else if inertia.isFinished {
                cancelScrollInertia(reason: "decayed")
            }
        }

        func cancelScrollInertia(reason: String) {
            guard scrollInertia != nil || inertiaDisplayLink != nil else { return }
            inertiaDisplayLink?.invalidate()
            inertiaDisplayLink = nil
            scrollInertia = nil
            updateScrollActivity()
            emitScrollDiagnostic(
                "inertia-stop reason=\(reason) ticks=\(inertiaTickCount)"
            )
        }

        // MARK: - Gesture frame-drain display link

        private func startGestureFrameDrainLink() {
            stopGestureFrameDrainLink()
            gestureFrameTicks = 0
            gestureFrameLastTimestamp = 0
            gestureFrameGapMaxMs = 0
            gestureFrameDurationMs = 0
            let link = CADisplayLink(
                target: self,
                selector: #selector(handleGestureFrameTick(_:))
            )
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60, maximum: 120, preferred: 120
            )
            link.add(to: .main, forMode: .common)
            gestureFrameLink = link
        }

        @objc private func handleGestureFrameTick(_ link: CADisplayLink) {
            guard let view = terminalView, view.window != nil else {
                // Recognizer died with its view mid-gesture — no .ended
                // will come to stop us, and the link retains self. Release
                // the activity latch too: nothing else will, and a stuck
                // latch would defer the overlay prefetch indefinitely.
                stopGestureFrameDrainLink()
                panGestureActive = false
                updateScrollActivity()
                return
            }
            gestureFrameTicks += 1
            gestureFrameDurationMs = (link.targetTimestamp - link.timestamp) * 1000
            if gestureFrameLastTimestamp > 0 {
                gestureFrameGapMaxMs = max(
                    gestureFrameGapMaxMs,
                    (link.timestamp - gestureFrameLastTimestamp) * 1000
                )
            }
            gestureFrameLastTimestamp = link.timestamp
            drainPendingGestureScroll(reason: "frame")
        }

        private func stopGestureFrameDrainLink() {
            gestureFrameLink?.invalidate()
            gestureFrameLink = nil
        }

        /// SGR mouse reports (`ESC [ < … M/m`) — pointer events forwarded to
        /// the remote app, distinct from typed input for scroll purposes.
        static func isMouseReport(_ data: ArraySlice<UInt8>) -> Bool {
            let bytes = Array(data.prefix(3))
            return bytes.count == 3
                && bytes[0] == 0x1B
                && bytes[1] == UInt8(ascii: "[")
                && bytes[2] == UInt8(ascii: "<")
        }

        /// Snap the viewport to the live prompt on typed input, clearing the
        /// retained scroll offset so the restore machinery doesn't pull the
        /// view back up. Alt screen has no local scroll position to snap.
        private func snapToBottomForUserInput() {
            guard let view = terminalView else { return }
            guard !view.getTerminal().isCurrentBufferAlternate else { return }
            clearDesiredScrollOffset(reason: "user-input", view: view)
            let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            if view.contentOffset.y < maxOffsetY - 0.5 {
                view.contentOffset = CGPoint(x: view.contentOffset.x, y: maxOffsetY)
            }
        }

        /// Terminal-originated auto-replies (cursor-position reports,
        /// device attributes, DSR, DECRQM, window reports, DCS replies for
        /// DECRQSS/XTGETTCAP) route through the same `send` delegate as
        /// keystrokes but carry no user intent. Conservative shape match —
        /// anything unrecognized counts as user input. Known ambiguity:
        /// modified F3 encodes as `CSI 1;2R`, colliding with CPR by design
        /// of the protocol; treating it as a reply merely skips one glide
        /// cancel.
        static func isTerminalAutoReply(_ data: ArraySlice<UInt8>) -> Bool {
            let bytes = Array(data)
            guard bytes.count >= 3, bytes[0] == 0x1B else { return false }
            // DCS replies (ESC P … ST) — user keys never produce DCS.
            if bytes[1] == UInt8(ascii: "P") { return true }
            // CSI replies: ESC [ (optional ? or >) digits/; (optional $)
            // ending in a report-only final byte. Keystrokes either have
            // no parameter digits (arrows: ESC[A) or end in ~ (nav keys).
            guard bytes[1] == UInt8(ascii: "[") else { return false }
            var i = 2
            if bytes[i] == UInt8(ascii: "?") || bytes[i] == UInt8(ascii: ">") {
                i += 1
            }
            var digitCount = 0
            while i < bytes.count,
                  (0x30...0x39).contains(bytes[i])
                    || bytes[i] == UInt8(ascii: ";")
                    || bytes[i] == UInt8(ascii: "$") {
                if (0x30...0x39).contains(bytes[i]) { digitCount += 1 }
                i += 1
            }
            guard digitCount > 0, i == bytes.count - 1 else { return false }
            switch bytes[i] {
            case UInt8(ascii: "R"),  // CPR (cursor position report)
                 UInt8(ascii: "c"),  // DA1/DA2
                 UInt8(ascii: "n"),  // DSR
                 UInt8(ascii: "t"),  // window size/state reports
                 UInt8(ascii: "y"):  // DECRQM ($y)
                return true
            default:
                return false
            }
        }

        /// Consumes one physical scroll gesture while a hook-proven agent is
        /// working. Notify once at gesture start (with a changed-state fallback
        /// for discrete wheels that skip `.began`) so a fast trackpad stream
        /// never invalidates SwiftUI on every event.
        @objc func handleAgentBlockedScroll(_ recognizer: UIPanGestureRecognizer) {
            guard agentScrollBlockingActive else { return }
            switch recognizer.state {
            case .began:
                agentScrollBlockNotified = true
                onUserActivity?()
                onAgentScrollBlocked?()
                emitScrollDiagnostic("agent-scroll-blocked input=gesture")
            case .changed:
                // Some discrete pointer devices enter at `.changed`; the
                // fallback still emits exactly one notice for that gesture.
                if !agentScrollBlockNotified {
                    agentScrollBlockNotified = true
                    onUserActivity?()
                    onAgentScrollBlocked?()
                    emitScrollDiagnostic("agent-scroll-blocked input=gesture")
                }
                let translation = recognizer.translation(in: terminalView)
                if abs(translation.y) > 0.01 {
                    recognizer.setTranslation(.zero, in: terminalView)
                }
            case .ended, .cancelled, .failed:
                agentScrollBlockNotified = false
            default:
                break
            }
        }

        /// Target added to SwiftTerm's built-in touch pan (its scroll-type
        /// mask is cleared, so this fires for finger drags only). A finger
        /// landing mid-glide must hand control to the native scroll view
        /// physics instead of fighting the display link.
        /// Native-scroll surfaces only. Mirrors pan activity into the
        /// host's scrolled handler so edge-pinned pans (no didScroll when
        /// bounces=false clamps the offset) still drive top-reach fetches
        /// and bottom dismissal, and gesture end resolves boundaries
        /// faster than the 100ms settle poll alone.
        @objc func handleNativeScrollSurfacePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = terminalView else { return }
            switch recognizer.state {
            case .changed:
                onTerminalScrolled?(view)
            case .ended, .cancelled:
                // After the current runloop turn, so isTracking/isDragging
                // have cleared and any deceleration has been committed.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let view = self.terminalView else { return }
                    self.onTerminalScrolled?(view)
                }
            default:
                break
            }
        }

        @objc func handleNativeTouchPan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began {
                cancelScrollInertia(reason: "touch-pan")
            }
        }

        // MARK: - Mouse click for TUI apps (§3.2 C3)

        /// Compute cell dimensions using the same formula as
        /// SwiftTerm's internal `computeFontDimensions`. This
        /// gives pixel-exact coordinates matching the Metal
        /// renderer's glyph grid.
        private func cellDimensions(
            for view: TerminalView
        ) -> (w: CGFloat, h: CGFloat) {
            let font = view.font
            let ctFont = font as CTFont
            let ascent = CTFontGetAscent(ctFont)
            let descent = CTFontGetDescent(ctFont)
            let leading = CTFontGetLeading(ctFont)
            let cellH = ceil(ascent + descent + leading)
            let cellW = "W".size(
                withAttributes: [.font: font]
            ).width
            // Snap to pixel grid (same as SwiftTerm).
            let scale = view.contentScaleFactor
            let w = ceil(cellW * scale) / scale
            let h = ceil(cellH * scale) / scale
            return (max(1, w), max(1, h))
        }

        @objc func handleMouseTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = terminalView else { return }
            onUserActivity?()

            if handlePaneFocusTapIfNeeded(in: view, at: recognizer.location(in: view)) {
                return
            }

            let terminal = view.getTerminal()
            guard terminal.mouseMode != .off else { return }

            let pt = recognizer.location(in: view)
            let (cellW, cellH) = cellDimensions(for: view)

            // 0-indexed grid position, clamped.
            let col = max(0, min(terminal.cols - 1, Int(pt.x / cellW)))
            let row = max(0, min(terminal.rows - 1, Int(pt.y / cellH)))

            // Use SwiftTerm's own sendEvent which handles protocol
            // encoding (SGR/X10/etc.) and sends through the delegate
            // chain → our send callback → tmux sendInput.
            // buttonFlags: 0 = left press, 3 = left release.
            terminal.sendEvent(buttonFlags: 0, x: col, y: row)
            terminal.sendEvent(buttonFlags: 3, x: col, y: row)
        }

        private func handlePaneFocusTapIfNeeded(
            in view: TerminalView,
            at point: CGPoint
        ) -> Bool {
            guard paneFocusTapEnabled,
                  let onPaneFocusTap
            else { return false }

            var pt = point
            pt.x -= view.contentOffset.x
            pt.y -= view.contentOffset.y
            let (cellW, cellH) = cellDimensions(for: view)
            return onPaneFocusTap(pt, CGSize(width: cellW, height: cellH))
        }

        /// Mosh tap-to-focus (split windows only). This recognizer covers the
        /// mouse-reporting-off case. When mouse reporting is on, `handleMouseTap`
        /// performs the same non-active-pane focus check before forwarding the
        /// click into the active TUI.
        @objc func handlePaneFocusTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = terminalView else { return }
            onUserActivity?()
            _ = handlePaneFocusTapIfNeeded(in: view, at: recognizer.location(in: view))
        }

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === agentScrollBlockGesture {
                guard agentScrollBlockingActive,
                      let pan = gestureRecognizer as? UIPanGestureRecognizer,
                      let view = terminalView
                else { return false }
                let velocity = pan.velocity(in: view)
                if pan.numberOfTouches == 0 {
                    // Scroll-type events may be diagonal. Block every event
                    // with a vertical component; otherwise its Y delta can
                    // still move history even when X is dominant.
                    return abs(velocity.y) > 0.01
                }
                return abs(velocity.y) >= abs(velocity.x)
            }

            guard gestureRecognizer === semanticScrollGesture,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  pan.numberOfTouches > 0,
                  let view = terminalView
            else { return true }

            // Direct-touch scrolling is deliberately vertical-only. If the
            // TUI uses a horizontal drag affordance, fail here so SwiftTerm's
            // mouse-reporting pan can receive it instead.
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) >= abs(velocity.x)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive event: UIEvent
        ) -> Bool {
            if gestureRecognizer === agentScrollBlockGesture {
                guard agentScrollBlockingActive else { return false }
                if event.type == .scroll { return true }
                guard event.type == .touches,
                      let touches = event.allTouches,
                      !touches.isEmpty,
                      touches.allSatisfy({ $0.type == .direct })
                else { return false }
                return true
            }
            if gestureRecognizer === mouseTapGesture {
                // Only recognize when mouse mode is active (SGR click forward).
                guard let tv = terminalView else { return false }
                return tv.getTerminal().mouseMode != .off
            }
            if gestureRecognizer === paneFocusTapGesture {
                // Mosh tap-to-focus without terminal mouse reporting. With
                // mouse reporting on, `handleMouseTap` first selects a
                // non-active pane, then only forwards clicks that land in the
                // already-active pane.
                guard let tv = terminalView else { return false }
                return paneFocusTapEnabled && tv.getTerminal().mouseMode == .off
            }
            guard gestureRecognizer === semanticScrollGesture else {
                return true
            }

            // Indirect trackpad/wheel scrolling always uses Tessera's shared
            // dispatcher. Direct finger pans join that path only when a TUI
            // owns semantic scrolling; primary-screen history remains native.
            if event.type == .scroll { return true }
            guard event.type == .touches,
                  let touches = event.allTouches,
                  !touches.isEmpty,
                  touches.allSatisfy({ $0.type == .direct }),
                  let view = terminalView,
                  !view.selectionActive
            else { return false }

            let terminal = view.getTerminal()
            return terminal.isCurrentBufferAlternate
                || (mouseReportingImpliesAltScreen && terminal.mouseMode != .off)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Coexist peacefully with SwiftTerm's internal recognizers.
            // Primary-screen touches never enter our pan. Alternate-screen
            // vertical pans win explicitly over SwiftTerm's mouse-drag pan,
            // while the native UIScrollView may recognize simultaneously
            // without moving (alternate screens have no local scroll range).
            true
        }
    }
}

/// Debounced presentation state shared by SSH, mosh, and the host-free scroll
/// harness. Repeated gestures extend the same default two-second notice instead of
/// stacking banners; the blocker identity allows callers to dismiss stale UI
/// immediately when that exact agent stops working.
@MainActor
@Observable
final class AgentScrollPreventionNoticeController {
    private(set) var prevention: AgentScrollPrevention?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private let dismissDelay: Duration

    init(dismissDelay: Duration = .seconds(2)) {
        self.dismissDelay = dismissDelay
    }

    func show(_ prevention: AgentScrollPrevention) {
        dismissTask?.cancel()
        self.prevention = prevention
        dismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.dismissDelay)
            } catch {
                return
            }
            guard self.prevention == prevention else { return }
            self.prevention = nil
            self.dismissTask = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        prevention = nil
    }
}

/// Top-of-terminal in-app notice shown only after a blocked physical scroll
/// attempt. The provider name makes the source of the behavior explicit so a
/// user does not interpret the terminal staying at the live tail as a Tessera
/// scrolling failure.
struct AgentScrollPreventionNotice: View {
    let agentName: String
    let T: DesignTokens

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(T.amber)

            Text("\(agentName) is working — scrolling is temporarily disabled")
                .font(Typography.tesseraMono(size: 12, weight: .medium))
                .foregroundStyle(T.fg)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(T.panelBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(T.amber.opacity(0.55), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-scroll-prevention-notice")
        .accessibilityLabel("\(agentName) is working. Scrolling is temporarily disabled.")
    }
}

/// Slim banner shown when the auto-tmux script's "tmux not available"
/// sentinel is detected on the SSH output stream. Sits below the
/// session top bar; dismissable via the trailing X.
private struct NoTmuxBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.yellow.opacity(0.85))

            Text("tmux not available on remote host — multi-window features disabled")
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss banner")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 540)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(SwiftUI.Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(SwiftUI.Color.yellow.opacity(0.25), lineWidth: 0.5)
                )
        )
    }
}

private struct MoshTmuxShortcutBlockedToast: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow.opacity(0.95))

            Text("tmux control reconnecting - shortcut not sent")
                .font(Typography.tesseraMono(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(SwiftUI.Color.black.opacity(0.90))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(SwiftUI.Color.yellow.opacity(0.35), lineWidth: 0.5)
                )
        )
    }
}

private struct ConnectionStatusBreakdownView: View {
    let status: SessionConnectionStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(status.lines, id: \.self) { line in
                Text(line)
                    .font(Typography.tesseraMono(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 210, alignment: .leading)
        .background(SwiftUI.Color.black.opacity(0.94))
        .presentationBackground(SwiftUI.Color.black.opacity(0.94))
        .presentationCornerRadius(8)
    }
}
