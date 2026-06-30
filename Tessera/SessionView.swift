import SwiftUI
import SwiftTerm
import ScrollDispatcher
import TmuxControl
import PortForwarding
import UIKit
import GameController

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

    /// Terminal view reference captured via `onMade` so we can feed it
    /// from the session's output stream.
    @State private var terminalBox = TerminalBox(traceLabel: "ssh")
    @State private var tmuxTerminalQueryResponder = TerminalOSCColorQueryResponder()
    @State private var kittyWindowModes = KittyWindowModeStore()
    /// Per-pane kitty/2004 modes for the multi-pane grid (analog of
    /// `kittyWindowModes` for the single-pane path). Held here so pane modes
    /// survive window switches and grid mount/unmount.
    @State private var kittyPaneModes = KittyPaneModeStore()

    /// §3.2 tmux -CC router. In passthrough mode it's a transparent
    /// pipe between the SSH session and SwiftTerm; as soon as tmux's
    /// `ESC P 1 0 0 0 p` prologue appears in the output stream the
    /// controller swaps modes, parses control-mode messages, and
    /// wraps typed keystrokes in `send-keys` commands.
    @State private var tmux = TmuxController()
    @State private var shellIntegration = SwipePadShellIntegrationTracker()
    @State private var swipePadOutputActivityToken = 0
    @State private var swipePadOutputActivityTask: Task<Void, Never>?
    @State private var swipePadSessionIsActive = false

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

    /// Full terminal-area loading shield shown from connect-start until
    /// the session is ready: `.connected` for `.customCommand`; first
    /// tmux pane render for `.autoTmux` / `.pinnedTmux`. Replaces the
    /// v1 tmux-only overlay (commit 6a01abc) with a unified visual.
    /// Defaults to `true` so the overlay is up immediately when the
    /// view appears; dismissed by the mode-specific signal handlers
    /// below (see `.onChange(of: session.state)` and
    /// `.onChange(of: tmux.isInitialRenderReady)`).
    @State private var launchOverlayVisible = true

    /// Last terminal size reported by the TerminalView. Cached so
    /// we can replay it when foregrounded after being hidden.
    @State private var lastTerminalSize: (cols: Int, rows: Int)?

    /// Cached tmux session name we resolved for this host on first
    /// access. Computed lazily and held as state so the view body
    /// doesn't recompute the SHA-256 derivation on every render.
    @State private var resolvedTmuxSessionName: String?
    @State private var currentTerminalTitle: String? = nil

    /// Transient toast for a failed pane operation (e.g. "pane too small").
    @State private var paneCommandToast: String? = nil
    @State private var paneCommandToastTask: Task<Void, Never>? = nil

    /// §R4.6 find-in-scrollback. The bar is hidden until the user
    /// taps the `⌕` button in the top bar or hits ⌘F. Owns search
    /// query / options state and the dispatch closures into the
    /// SwiftTerm view (installed below in `.task`).
    @State private var findController = FindController()
    @AppStorage(DiagnosticLogStore.scrollDiagnosticsDefaultsKey)
    private var scrollDiagnosticsEnabled = false
    @State private var scrollDiagnosticSequence = 0

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
    @Environment(AppPhase.self) private var appPhase

    private var activeTheme: TerminalTheme {
        TerminalTheme.find(id: appearance.terminalThemeID)
    }

    private var themeChromeTokens: DesignTokens {
        activeTheme.chromeTokens(applying: appearance)
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

    /// Character-cell size for the live terminal font, used to lay out pane
    /// frames as exact cell multiples (matches SwiftTerm's own grid snapping).
    private var terminalCellSize: CGSize {
        let size = CGFloat(appearance.fontSize)
        let font = TesseraTerminalFont.mono(size: size)
        return TerminalCellMetrics.cellSize(font: font, scale: UIScreen.main.scale)
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

    var body: some View {
        ZStack(alignment: .top) {
            // §3.5 R3.5.4: background extends edge-to-edge under the
            // rounded corners and home-indicator area. Pinned to the
            // active TerminalTheme's bg so the page-edge gutters blend
            // seamlessly with the SwiftTerm canvas.
            activeTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                SessionTopBar(
                    state: session.state,
                    host: session.host,
                    tmux: tmux,
                    tmuxIsDegraded: false,
                    connectionStatus: .ssh(state: session.state),
                    onToggleSidebar: onToggleSidebar,
                    sidebarVisible: sidebarVisible,
                    onBack: onBack,
                    findController: findController,
                    bellController: bellController,
                    forwarderManager: session.portForwarderManager,
                    T: themeChromeTokens
                )
                .frame(height: SessionTopBar.reservedHeight(pillHeight: appearance.topBarHeight))
                .zIndex(2)

                if findController.isOpen {
                    FindBar(
                        controller: findController,
                        horizontalInset: Self.cornerInset,
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
                            guard !showsLaunchOverlay else { return }
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
                        mouseReportingImpliesAltScreen: false,
                        suppressDirectColorQueryResponses: true,
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
                        // The shared terminal yields first responder to the
                        // grid's focused pane while a multi-pane window is up.
                        // `!isActive` is load-bearing: background (non-selected,
                        // opacity-0) sessions stay MOUNTED, and without this gate
                        // their terminal reclaims first responder on any
                        // re-render — stealing focus from whatever IS on screen
                        // (e.g. a TextField in the host editor). Only the
                        // foreground session may hold the keyboard.
                        suppressFirstResponderReclaim: !isActive
                            || findController.isOpen
                            || commandPalette.isOpen
                            || activeGridWindow != nil,
                        onHardwareKey: nil,
                        scrollRetentionID: [
                            "ssh",
                            tmux.activeWindowId?.description ?? "nil",
                            tmux.activePaneId?.description ?? "nil",
                            activeGridWindow?.id.description ?? "nil",
                        ].joined(separator: ":"),
                        onScrollDiagnostic: { message in
                            recordScrollDiagnostic(message)
                        }
                    )
                    .allowsHitTesting(!showsLaunchOverlay && activeGridWindow == nil)
                    .opacity(showsLaunchOverlay ? 0 : 1)
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
                            onUserActivity: { appLockController.notifyUserActivity() },
                            // `!isActive` so a backgrounded grid's focused pane
                            // doesn't reclaim first responder from the foreground
                            // (e.g. the host editor) — same rule as the shared
                            // surface above.
                            suppressFindReclaim: !isActive || findController.isOpen || commandPalette.isOpen,
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
                            }
                        )
                        .id(gridWindow.id)
                    }

                    if showsLaunchOverlay {
                        SessionLaunchOverlay(
                            T: themeChromeTokens,
                            phase: launchPhase,
                            subtitle: launchSubtitle,
                            failureReason: launchFailureReason,
                            onEditHost: onEditHost,
                            onRetry: onRetry,
                            onBack: onSessionEnded
                        )
                        .transition(.opacity)
                        .zIndex(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, Self.cornerInset)

                if appearance.showAccessoryBar {
                    SessionAccessoryBar(
                        accent: appearance.tokens(systemColorScheme: .dark).accent,
                        onSend: { bytes in
                            guard !showsLaunchOverlay else { return }
                            appLockController.notifyUserActivity()
                            tmux.sendInput(bytes)
                        },
                        applicationCursor: { [terminalBox] in
                            terminalBox.view?.getTerminal().applicationCursor ?? false
                        }
                    )
                }
            }

            // "tmux not available" banner. Sits below the top bar
            // when set; dismissable. Triggered by detection of the
            // AutoTmuxScript sentinel in the SSH output stream — see
            // the .task block below.
            if noTmuxBannerVisible {
                NoTmuxBanner(onDismiss: { noTmuxBannerVisible = false })
                    .padding(.top, SessionTopBar.reservedHeight(pillHeight: appearance.topBarHeight))
                    .padding(.horizontal, Self.cornerInset + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
            }

            SwipePadOverlay(
                onSend: { bytes in
                    guard !showsLaunchOverlay else { return }
                    appLockController.notifyUserActivity()
                    tmux.sendInput(bytes)
                },
                tmux: tmux,
                outputActivityToken: swipePadOutputActivityToken,
                processNameProvider: {
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
                paneProcessNameProvider: { panePID in
                    let names = await session.detectForegroundProcessNames(rootPID: panePID)
                    SwipePadDiagnostics.log(
                        "provider ssh source=tmux-pane-ps panePID=\(panePID) candidateCount=\(names.count)"
                    )
                    return names
                },
                profileStore: swipePadStore,
                dictationController: dictationController
            )
            .padding(.top, SessionTopBar.reservedHeight(pillHeight: appearance.topBarHeight))
            .padding(.horizontal, Self.cornerInset)
            .padding(.bottom, appearance.showAccessoryBar ? 52 : max(Self.cornerInset - 8, 4))
            .zIndex(5)

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
        .ignoresSafeArea(.container, edges: .bottom)
        .onChange(of: activeGridWindow?.id) { oldValue, newValue in
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
                if isActive, let size = lastTerminalSize {
                    session.resize(cols: size.cols, rows: size.rows)
                    tmux.resyncRenderedWindowAfterGridCollapse(cols: size.cols, rows: size.rows)
                }
                // Rebind find to the shared terminal (it was scoped to a now-gone
                // pane surface).
                findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)
                if findController.isOpen { findController.updateSearch() }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            swipePadSessionIsActive = isActive
            tunnelsRegistry.register(host: session.host.id, manager: session.portForwarderManager)
        }
        .onDisappear {
            tunnelsRegistry.unregister(host: session.host.id)
            swipePadOutputActivityTask?.cancel()
            swipePadOutputActivityTask = nil
        }
        .task {
            // Connect the tmux controller's upstream/downstream hooks
            // before connecting the session. `feedTerminal` paints the
            // SwiftTerm view; `sendBytes` pushes to the SSH channel.
            tmux.feedTerminal = { [terminalBox, shellIntegration] slice in
                let before = terminalScrollPosition(for: terminalBox.view)
                shellIntegration.feed(slice)
                terminalBox.feed(slice)
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

            session.connect()
            for await chunk in session.outputStream {
                // Process the chunk FIRST so any DCS in it has already
                // flipped tmux.mode → .tmuxControl by the time we check.
                // This stops the auto-tmux failure scanner from racing
                // with a successful tmux launch when both the sentinel
                // *and* the DCS land in the same SSH chunk.
                tmux.ingest(chunk)

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
                    let cmd = prologue + AutoTmuxScript.command(sessionName: name)
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
        .onChange(of: isActive) { _, nowActive in
            swipePadSessionIsActive = nowActive
            // When this session becomes the selected tab, replay the last known
            // terminal size so the remote gets an accurate SIGWINCH. The size
            // may have changed while we were hidden (sidebar toggle, rotation).
            if nowActive, let size = lastTerminalSize {
                session.resize(cols: size.cols, rows: size.rows)
                tmux.updateClientSize(cols: size.cols, rows: size.rows)
            }
            if nowActive {
                tmux.refreshActiveWindowOnForeground()
            }
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
            // while the control channel recovers.
            guard nowForeground, isActive else { return }
            if let size = lastTerminalSize {
                session.resize(cols: size.cols, rows: size.rows)
                tmux.updateClientSize(cols: size.cols, rows: size.rows)
            }
            tmux.refreshActiveWindowOnForeground()
        }
        .onChange(of: tmux.mode) { _, newMode in
            recordScrollDiagnostic(
                "tmux-mode-changed mode=\(newMode) position=\(describeScrollPosition(for: terminalBox.view))"
            )
            // First successful entry into tmux control mode for this
            // host: persist the session name so the next connect
            // attempts to attach to the same one. Idempotent — the
            // store skips the write if the value is already current.
            //
            // Only the `.autoTmux` fallback path feeds this store —
            // `.pinnedTmux` has its own explicit name on the host
            // record and would just pollute the "last-used default"
            // memory, and `.customCommand` doesn't touch tmux.
            if case .tmuxControl = newMode,
               session.host.launchMode == .autoTmux,
               let name = resolvedTmuxSessionName
            {
                HostRuntimeStateStore.recordSessionUsed(name, for: session.host)
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
        .onChange(of: tmux.activePaneId) { _, newPaneId in
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
        scrollDiagnosticSequence += 1
        let context = [
            "ssh",
            "seq=\(scrollDiagnosticSequence)",
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

    @State private var terminalBox = TerminalBox(traceLabel: "mosh")
    @State private var tmux = TmuxController(controlPath: .sideChannel)
    @State private var tmuxTerminalQueryResponder = TerminalOSCColorQueryResponder()
    @State private var shellIntegration = SwipePadShellIntegrationTracker()
    @State private var swipePadOutputActivityToken = 0
    @State private var swipePadOutputActivityTask: Task<Void, Never>?
    @State private var swipePadSessionIsActive = false
    @State private var tmuxControlBox = TmuxControlChannelBox()
    @State private var tmuxControlTask: Task<Void, Never>?
    @State private var tmuxControlGeneration = 0
    @State private var tmuxSideChannelState: MoshSideChannelState = .idle
    @State private var tmuxShortcutToastVisible = false
    @State private var tmuxShortcutToastTask: Task<Void, Never>?
    @State private var lastTerminalSize: (cols: Int, rows: Int)?
    @State private var resolvedTmuxSessionName: String?
    @State private var currentTerminalTitle: String? = nil
    @State private var lastScrollbackWindowId: WindowId?
    @State private var lastMoshPaneChromeSnapshot: MoshPaneChromeSnapshot?
    @State private var moshPaneChromeTopMaskActive = false
    @State private var moshPaneChromeTopMaskGeneration = 0
    @State private var moshPaneChromeCollapseMaskedPaneIds: Set<PaneId> = []
    @State private var moshPaneScrollbackOverlay: MoshPaneScrollbackOverlayRuntime?
    @State private var moshScrollbackDepthByPane: [PaneId: Int] = [:]
    @State private var moshScrollbackInFlight: (paneId: PaneId, depth: Int)?
    @State private var pendingMoshAltScreenScrollPointsByPane: [PaneId: Double] = [:]
    @State private var moshPaneInteractionProbeInFlight: Set<PaneId> = []
    @State private var pendingMoshInteractionProbeScrollPointsByPane: [PaneId: Double] = [:]
    @State private var moshSplitAltScreenScrollDispatcher = ScrollDispatcher(config: .init(
        pointsPerArrowKey: 1,
        mouseWheelThresholdPoints: 3,
        maxEventsPerFlush: 8
    ))
    @State private var moshScrollbackLoading = false
    @State private var moshScrollbackGateLogCount = 0
    /// §R4.6 find-in-scrollback. See SessionView for details — same
    /// shape, just bound to the mosh transport's terminal box.
    @State private var findController = FindController()
    @AppStorage(DiagnosticLogStore.scrollDiagnosticsDefaultsKey)
    private var scrollDiagnosticsEnabled = false
    @State private var scrollDiagnosticSequence = 0

    /// Unified launch-loading shield (same visual as SSH side). Defaults
    /// to `true` so the overlay covers `.connecting` (mosh bootstrap +
    /// UDP handshake). Dismissed by `.onChange(of: session.state)` for
    /// `.customCommand` and by the combined tmux-mode / first-output
    /// signal below for `.autoTmux` / `.pinnedTmux`.
    @State private var launchOverlayVisible = true
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

    private var activeTheme: TerminalTheme {
        TerminalTheme.find(id: appearance.terminalThemeID)
    }

    private static let moshScrollbackPageLines = 240
    private static let moshScrollbackTopThreshold: CGFloat = 24
    private static let moshPaneChromeTopMaskDuration: TimeInterval = 0.35

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

    var body: some View {
        ZStack(alignment: .top) {
            activeTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                SessionTopBar(
                    state: session.state,
                    host: session.host,
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
                        stopTmuxControlChannel()
                        onBack()
                    },
                    findController: findController,
                    bellController: bellController,
                    forwarderManager: session.portForwarderManager,
                    T: activeTheme.chromeTokens(applying: appearance)
                )
                .frame(height: SessionTopBar.reservedHeight(pillHeight: appearance.topBarHeight))
                .zIndex(2)

                if findController.isOpen {
                    FindBar(
                        controller: findController,
                        horizontalInset: SessionView.cornerInset,
                        T: activeTheme.chromeTokens(applying: appearance)
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                ZStack {
                    moshTerminalSurface
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
                       let overlay = moshPaneScrollbackOverlay,
                       let frame = moshPaneScrollbackFrame(for: overlay.paneId) {
                        MoshPaneScrollbackOverlay(
                            runtime: overlay,
                            paneFrame: frame.surfaceFrame,
                            onReady: applyPendingMoshPaneScrollbackOverlayOffset,
                            onTerminalScrolled: handleMoshPaneScrollbackOverlayScrolled,
                            onScrollDiagnostic: { message in
                                recordMoshScrollDiagnostic(message)
                            }
                        )
                        .id(overlay.id)
                    }

                    // Mosh paints split pane contents natively in the shared
                    // terminal, but Tessera owns the pane chrome so SSH and
                    // mosh splits look and tap the same.
                    if !showsLaunchOverlay,
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
                            backgroundColor: activeTheme.bg
                        )
                    }

                    if !showsLaunchOverlay,
                       let cellSize = moshCellSize,
                       shouldShowMoshPaneChromeTopMask
                        || !moshPaneChromeCollapseMaskFrames(cellSize: cellSize).isEmpty {
                        let collapseFrames = moshPaneChromeCollapseMaskFrames(cellSize: cellSize)
                        ZStack(alignment: .topLeading) {
                            if shouldShowMoshPaneChromeTopMask {
                                Rectangle()
                                    .fill(activeTheme.bg)
                                    .frame(height: ceil(cellSize.height) + 1)
                                    .frame(
                                        maxWidth: .infinity,
                                        maxHeight: .infinity,
                                        alignment: .top
                                    )
                            }

                            ForEach(collapseFrames, id: \.self) { frame in
                                Rectangle()
                                    .fill(activeTheme.bg)
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: frame.minX, y: frame.minY)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                            failureReason: launchFailureReason,
                            onEditHost: onEditHost,
                            onRetry: onRetry,
                            onBack: onSessionEnded
                        )
                        .transition(.opacity)
                        .zIndex(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, SessionView.cornerInset)

                if appearance.showAccessoryBar {
                    SessionAccessoryBar(
                        accent: appearance.tokens(systemColorScheme: .dark).accent,
                        onSend: { bytes in
                            guard !showsLaunchOverlay else { return }
                            appLockController.notifyUserActivity()
                            invalidateMoshScrollbackForTerminalInput(reason: "accessory-input")
                            session.send(bytes)
                        },
                        applicationCursor: { [terminalBox] in
                            terminalBox.view?.getTerminal().applicationCursor ?? false
                        }
                    )
                }
            }

            if tmuxShortcutToastVisible {
                MoshTmuxShortcutBlockedToast()
                    .padding(.top, appearance.topBarHeight + 44)
                    .padding(.leading, SessionView.cornerInset + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                    .zIndex(4)
            }

            SwipePadOverlay(
                onSend: { bytes in
                    guard !showsLaunchOverlay else { return }
                    appLockController.notifyUserActivity()
                    invalidateMoshScrollbackForTerminalInput(reason: "swipepad-input")
                    session.send(bytes)
                },
                tmux: tmux,
                outputActivityToken: swipePadOutputActivityToken,
                processNameProvider: {
                    let names = shellIntegration.processNames
                    SwipePadDiagnostics.log(
                        "provider mosh source=shell-integration-only candidateCount=\(names.count)"
                    )
                    return names
                },
                paneProcessNameProvider: { panePID in
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
                profileStore: swipePadStore,
                dictationController: dictationController
            )
            .padding(.top, SessionTopBar.reservedHeight(pillHeight: appearance.topBarHeight))
            .padding(.horizontal, SessionView.cornerInset)
            .padding(.bottom, appearance.showAccessoryBar ? 52 : max(SessionView.cornerInset - 8, 4))
            .zIndex(5)
        }
        .animation(.easeInOut(duration: 0.2), value: tmuxSideChannelState)
        .animation(.easeInOut(duration: 0.15), value: tmuxShortcutToastVisible)
        .animation(.easeInOut(duration: 0.25), value: showsLaunchOverlay)
        .ignoresSafeArea(.container, edges: .bottom)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            swipePadSessionIsActive = isActive
            tunnelsRegistry.register(host: session.host.id, manager: session.portForwarderManager)
        }
        .onDisappear {
            tunnelsRegistry.unregister(host: session.host.id)
            swipePadOutputActivityTask?.cancel()
            swipePadOutputActivityTask = nil
        }
        .task {
            MoshDiagnostics.log(
                "mosh view task start transport=\(session.host.transport.rawValue) launchMode=\(session.host.launchMode.rawValue) port=\(session.host.port)"
            )
            tmux.sendBytes = { [tmuxControlBox] bytes in
                tmuxControlBox.channel?.send(bytes)
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
                guard paneId == tmux.activePaneId else { return }
                invalidateMoshScrollbackForTerminalInput(reason: "active-pane-output")
            }

            findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)

            if resolvedTmuxSessionName == nil {
                resolvedTmuxSessionName = MoshBootstrap.resolvedTmuxSessionName(
                    for: session.host
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
                shellIntegration.feed(chunk[...])
                terminalBox.feed(chunk[...])
                if shouldRecordScrollDiagnostics,
                   let view = terminalBox.view,
                   shouldLogTerminalFeedScroll(before: before, after: terminalScrollPosition(for: view)) {
                    recordMoshScrollDiagnostic(
                        "surface=shared terminal-feed bytes=\(chunk.count) before=\(describeScrollPosition(before)) after=\(describeScrollPosition(for: view))"
                    )
                }
                scheduleSwipePadOutputActivityRefresh(reason: "mosh-output")

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
               isActive,
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
        .onChange(of: launchOverlayVisible) { _, visible in
            // Mirror "launch complete" into the shared registry so the
            // sidebar row can drop its connecting appearance — it can't
            // observe this view's local overlay state directly. See the
            // matching handler in the SSH `SessionView`.
            if !visible {
                sessionRegistry.markRenderReady(liveSessionID)
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
        }
        .onChange(of: tmux.activePaneId) { oldPaneId, newPaneId in
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
            if findController.isOpen {
                seedMoshFindScrollbackIfNeeded(reason: "layout-change")
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
            if nowActive, let size = lastTerminalSize {
                session.resize(cols: size.cols, rows: size.rows)
                tmux.updateClientSize(cols: size.cols, rows: size.rows)
                tmuxControlBox.channel?.resize(cols: size.cols, rows: size.rows)
            }
            if nowActive {
                if case .connected = session.state,
                   let sessionName = resolvedTmuxSessionName {
                    startTmuxControlChannel(sessionName: sessionName)
                }
            } else {
                stopTmuxControlChannel()
            }
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
            if case .tmuxControl = newMode,
               session.host.launchMode == .autoTmux,
               let name = resolvedTmuxSessionName {
                HostRuntimeStateStore.recordSessionUsed(name, for: session.host)
            }
            // Tmux side-channel just engaged — the other half of the
            // tmux-mode dismissal pair (first-output is checked in the
            // bytes-receive loop above).
            maybeDismissLaunchOverlay(reason: "tmux.mode")
            if case .tmuxControl = newMode {
                seedMoshFindScrollbackIfNeeded(reason: "tmux-mode")
            }
        }
        .onDisappear {
            stopTmuxControlChannel()
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
        scrollDiagnosticSequence += 1
        let context = [
            "mosh",
            "seq=\(scrollDiagnosticSequence)",
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
            guard isActive, session.state == .connected else {
                MoshDiagnostics.log(
                    "mosh tmux sidechannel reconnect loop stop generation=\(generation) session=\(sessionName) active=\(isActive) state=\(MoshDiagnostics.stateDescription(session.state))"
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
                }
            }
            MoshDiagnostics.log(
                "mosh tmux sidechannel reconnect stream ended generation=\(generation) session=\(sessionName) sawOutput=\(sawOutput) sawControlMode=\(sawControlMode) chunks=\(chunkCount) sessionState=\(MoshDiagnostics.stateDescription(session.state)) reason=\(channel.terminationReason?.logDescription ?? "unknown")"
            )

            if tmuxControlBox.channel === channel {
                tmuxControlBox.channel = nil
            }

            guard !Task.isCancelled && tmuxControlGeneration == generation else { break }
            guard isActive, session.state == .connected else { break }

            tmux.sideChannelDisconnected()
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
            findController.handlers = TerminalSearchAdapter.handlers(for: overlay.box)
            return overlay
        }

        dismissMoshPaneScrollbackOverlay(clearDepth: true, reason: "replace")
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
        overlay.restoreDesiredScrollOffset(in: view) { detail in
            recordMoshScrollDiagnostic(
                "surface=overlay window=\(overlay.windowId.description) \(detail)"
            )
        }
    }

    private func resetMoshScrollbackCapture(clearLocal: Bool, reason: String) {
        if moshPaneScrollbackOverlay != nil {
            dismissMoshPaneScrollbackOverlay(clearDepth: false, reason: reason)
        }
        moshScrollbackDepthByPane.removeAll(keepingCapacity: true)
        moshScrollbackInFlight = nil
        pendingMoshAltScreenScrollPointsByPane.removeAll(keepingCapacity: true)
        moshPaneInteractionProbeInFlight.removeAll(keepingCapacity: true)
        pendingMoshInteractionProbeScrollPointsByPane.removeAll(keepingCapacity: true)
        moshSplitAltScreenScrollDispatcher = ScrollDispatcher(config: .init(
            pointsPerArrowKey: 1,
            mouseWheelThresholdPoints: 3,
            maxEventsPerFlush: 8
        ))
        moshScrollbackLoading = false
        moshScrollbackGateLogCount = 0
        findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)
        if clearLocal {
            terminalBox.clearScrollback(restoringLimit: appearance.scrollbackLines)
        }
        MoshDiagnostics.log("mosh scrollback reset reason=\(reason) clearLocal=\(clearLocal)")
    }

    private func invalidateMoshScrollbackForTerminalInput(reason: String) {
        let hadOverlay = moshPaneScrollbackOverlay != nil
        let hasLocalCapture = hadOverlay
            || !moshScrollbackDepthByPane.isEmpty
            || moshScrollbackInFlight != nil
        guard hasLocalCapture else { return }
        resetMoshScrollbackCapture(clearLocal: !hadOverlay, reason: reason)
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
        guard moshScrollbackGateLogCount < 24 else { return }
        moshScrollbackGateLogCount += 1
        MoshDiagnostics.log("mosh scrollback gate \(message())")
    }

    private func handleMoshPrimaryScrollbackDelta(
        view: TerminalView,
        pointsY: Double,
        proposedOffsetY: CGFloat,
        maxOffsetY: CGFloat
    ) -> Bool {
        guard moshActiveWindow?.rendersAsPaneGrid == true else { return false }
        guard pointsY != 0 else { return true }
        guard session.host.launchMode != .customCommand,
              session.state == .connected,
              tmux.mode == .tmuxControl
        else {
            return true
        }
        guard terminalBox.view === view else { return true }

        let terminal = view.getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return false }

        guard let window = moshActiveWindow,
              let paneId = window.activePaneId ?? tmux.activePaneId,
              moshPaneScrollbackFrame(for: paneId) != nil
        else {
            logMoshScrollbackGate("overlay-skip reason=no-pane-frame")
            return true
        }

        if let pane = window.panes.first(where: { $0.id == paneId }),
           pane.isAlternateScreen == true {
            forwardMoshPaneAltScreenScroll(
                view: view,
                paneId: paneId,
                pointsY: pointsY,
                mouseReporting: pane.isMouseReporting == true,
                useSgrMouse: pane.isSgrMouse == true,
                reason: "cached-alt-screen"
            )
            return true
        }

        guard pointsY > 0 else {
            if let overlay = moshPaneScrollbackOverlay,
               overlay.paneId == paneId,
               overlay.windowId == window.id {
                scrollMoshPaneScrollbackOverlay(overlay, pointsY: pointsY)
            } else {
                logMoshScrollbackGate(
                    "overlay-skip reason=no-overlay-scroll-down-probe pane=\(paneId.description) pointsY=\(String(format: "%.2f", pointsY))"
                )
                probeMoshPaneInteractionForAltScreenScroll(
                    view: view,
                    paneId: paneId,
                    pointsY: pointsY,
                    reason: "no-overlay-scroll-down"
                )
            }
            return true
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
            return true
        }

        fetchMoshPaneScrollbackOverlay(
            overlay: overlay,
            paneId: paneId,
            pointsY: pointsY,
            currentDepth: currentDepth,
            currentMaxOffsetY: overlayMaxOffsetY,
            reason: "scroll"
        )
        return true
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
        MoshDiagnostics.log(
            "mosh scrollback forward alt-screen scroll reason=\(reason) pane=\(paneId.description) pointsY=\(String(format: "%.2f", pointsY)) mouse=\(mouseReporting) sgr=\(useSgrMouse) forwarded=\(forwardedCount) column=\(target.column) row=\(target.row)"
        )
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
        pointsY: Double
    ) -> (offsetY: CGFloat, maxOffsetY: CGFloat)? {
        guard let view = overlay.box.view else { return nil }
        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        if maxOffsetY > 0, overlay.pendingScrollPlacement != nil {
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
        }

        return (offsetY, maxOffsetY)
    }

    private func fetchMoshPaneScrollbackOverlay(
        overlay: MoshPaneScrollbackOverlayRuntime,
        paneId: PaneId,
        pointsY: Double,
        currentDepth: Int,
        currentMaxOffsetY: CGFloat,
        reason: String
    ) {
        let maxDepth = max(Self.moshScrollbackPageLines, appearance.scrollbackLines)
        guard currentDepth < maxDepth else {
            logMoshScrollbackGate(
                "overlay-skip reason=max-depth pane=\(paneId.description) depth=\(currentDepth) maxDepth=\(maxDepth)"
            )
            return
        }

        let targetDepth = min(
            maxDepth,
            max(currentDepth + Self.moshScrollbackPageLines, Self.moshScrollbackPageLines)
        )
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

        let shouldStickToTop = currentDepth > 0
            && currentMaxOffsetY > Self.moshScrollbackTopThreshold
            && (overlay.desiredScrollOffsetY ?? overlay.box.view?.contentOffset.y ?? 0) <= Self.moshScrollbackTopThreshold
        overlay.setPendingScrollPlacement(
            shouldStickToTop ? .top : .bottomMinus(CGFloat(pointsY) * 3)
        )
        moshScrollbackInFlight = (paneId: paneId, depth: targetDepth)
        moshScrollbackLoading = true
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
            else { return }

            moshScrollbackInFlight = nil
            moshScrollbackLoading = false
            let pendingAltScreenPoints =
                pendingMoshAltScreenScrollPointsByPane.removeValue(forKey: paneId) ?? 0

            guard case .captured(let capture) = result else {
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
                dismissMoshPaneScrollbackOverlay(clearDepth: true, reason: "empty-capture")
                return
            }

            overlay.clearDesiredScrollOffset()
            overlay.box.clearScrollback(restoringLimit: appearance.scrollbackLines)
            overlay.box.feed(capture.repaintBytes[...])
            moshScrollbackDepthByPane[paneId] = max(
                moshScrollbackDepthByPane[paneId] ?? 0,
                capture.requestedDepth
            )
            applyPendingMoshPaneScrollbackOverlayOffset()
            if findController.isOpen {
                findController.handlers = TerminalSearchAdapter.handlers(for: overlay.box)
                findController.updateSearch()
            }
            MoshDiagnostics.log(
                "mosh scrollback overlay fetch applied pane=\(paneId.description) depth=\(capture.requestedDepth) lines=\(capture.capturedLineCount) bytes=\(capture.repaintBytes.count)"
            )
            recordMoshScrollDiagnostic(
                "surface=overlay window=\(overlay.windowId.description) pane=\(paneId.description) fetch-applied depth=\(capture.requestedDepth) lines=\(capture.capturedLineCount) bytes=\(capture.repaintBytes.count) position=\(describeScrollPosition(for: overlay.box.view))"
            )
        }
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

        let targetDepth = min(
            maxDepth,
            max(currentDepth + Self.moshScrollbackPageLines, Self.moshScrollbackPageLines)
        )
        if let inFlight = moshScrollbackInFlight,
           inFlight.paneId == paneId,
           inFlight.depth >= targetDepth {
            logMoshScrollbackGate(
                "skip reason=in-flight pane=\(paneId.description) targetDepth=\(targetDepth) inFlightDepth=\(inFlight.depth)"
            )
            return
        }

        let shouldStickToTop = maxOffsetY > Self.moshScrollbackTopThreshold
            && view.contentOffset.y <= Self.moshScrollbackTopThreshold
        let pendingScrollPoints = CGFloat(pointsY) * 3
        moshScrollbackInFlight = (paneId: paneId, depth: targetDepth)
        moshScrollbackLoading = true
        MoshDiagnostics.log(
            "mosh scrollback fetch begin pane=\(paneId.description) depth=\(targetDepth) currentDepth=\(currentDepth) maxOffset=\(String(format: "%.1f", maxOffsetY)) proposed=\(String(format: "%.1f", proposedOffsetY))"
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
                    "mosh scrollback fetch empty pane=\(paneId.description) depth=\(targetDepth)"
                )
                return
            }

            terminalBox.clearScrollback(restoringLimit: appearance.scrollbackLines)
            terminalBox.feed(capture.repaintBytes[...])
            moshScrollbackDepthByPane[paneId] = max(
                moshScrollbackDepthByPane[paneId] ?? 0,
                capture.requestedDepth
            )

            let immediateMaxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            DispatchQueue.main.async {
                guard terminalBox.view === view else { return }
                let newMaxOffsetY = max(0, view.contentSize.height - view.bounds.height)
                let targetY: CGFloat
                if shouldStickToTop {
                    targetY = 0
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

    private func seedMoshFindScrollbackIfNeeded(reason: String) {
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
            let currentDepth = moshScrollbackDepthByPane[paneId] ?? 0
            guard currentDepth < targetDepth else {
                MoshDiagnostics.log(
                    "mosh scrollback overlay find seed skipped reason=already-seeded pane=\(paneId.description) depth=\(currentDepth) targetDepth=\(targetDepth)"
                )
                findController.updateSearch()
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

            moshScrollbackInFlight = (paneId: paneId, depth: targetDepth)
            moshScrollbackLoading = true
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

                overlay.box.clearScrollback(restoringLimit: appearance.scrollbackLines)
                overlay.box.feed(capture.repaintBytes[...])
                moshScrollbackDepthByPane[paneId] = max(
                    moshScrollbackDepthByPane[paneId] ?? 0,
                    capture.requestedDepth
                )

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

        moshScrollbackInFlight = (paneId: paneId, depth: targetDepth)
        moshScrollbackLoading = true
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
                guard !showsLaunchOverlay else { return }
                if !isAutomaticTerminalColorResponse(bytes) {
                    invalidateMoshScrollbackForTerminalInput(reason: "terminal-input")
                }
                session.send(Array(bytes))
            },
            onResize: { cols, rows in
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
            mouseReportingImpliesAltScreen: !moshPaneCycleEnabled,
            suppressDirectColorQueryResponses: false,
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
            // `!isActive`: a backgrounded (mounted, opacity-0) mosh session must
            // not reclaim first responder from the foreground (e.g. host editor).
            suppressFirstResponderReclaim: !isActive || findController.isOpen || commandPalette.isOpen,
            onHardwareKey: { key in
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
            paneFocusTapEnabled: moshPaneCycleEnabled
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

private struct MoshPaneScrollbackOverlay: View {
    let runtime: MoshPaneScrollbackOverlayRuntime
    let paneFrame: CGRect
    let onReady: () -> Void
    let onTerminalScrolled: (TerminalView) -> Void
    let onScrollDiagnostic: (String) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
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
                }
            )
            .frame(width: paneFrame.width, height: paneFrame.height)
            .clipped()
            .offset(x: paneFrame.minX, y: paneFrame.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Reference box so we can capture the UIKit `TerminalView` out of
/// SwiftUI's value-type world and feed bytes into it from async code.
@MainActor
final class TerminalBox {
    private let traceLabel: String
    weak var view: TerminalView?
    private var pendingBytes: [UInt8] = []
    private var isRenderReady = false
    private var bufferedChunkCount = 0
    private var directChunkCount = 0
    private var contrastFilter = TerminalOutputContrastFilter()

    init(traceLabel: String) {
        self.traceLabel = traceLabel
    }

    func attach(_ view: TerminalView) {
        if self.view !== view {
            isRenderReady = false
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
}

@MainActor
private final class TmuxControlChannelBox {
    var channel: TmuxControlChannel?
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
private struct SessionTopBar: View {
    let state: SessionState
    let host: Host
    let tmux: TmuxController
    let tmuxIsDegraded: Bool
    let connectionStatus: SessionConnectionStatus
    let onToggleSidebar: () -> Void
    let sidebarVisible: Bool
    let onBack: () -> Void
    /// Find-in-scrollback controller. Backs the trailing `⌕` button:
    /// tap toggles `findController.isOpen`, which makes the parent
    /// session view render the `FindBar` strip just below this top
    /// bar. The button lights up `accentSoft` while the bar is open
    /// to mirror the active-tab highlight.
    let findController: FindController
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

    /// Live appearance prefs — read for `topBarHeight`, which drives the
    /// `scale` multiplier applied to every icon, pill, dot, and font
    /// inside the bar. Flows down from SessionView/MoshSessionView's
    /// environment automatically; SessionTopBar isn't constructed
    /// outside those views.
    @Environment(AppearancePreferences.self) private var appearance

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
    static func reservedHeight(pillHeight: Double) -> CGFloat {
        CGFloat(pillHeight) + floatTopInset + floatBottomInset
    }

    /// The pill outline. Corner radius scales with the bar so the rounding
    /// stays proportional across the 26–44pt height range (≈13pt at the 32pt
    /// baseline, mirroring the mockup's 13/34 ratio). Always < half the pill
    /// height, so it's a rounded rect, never an unintended capsule.
    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 13 * scale, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 8 * scale) {
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

            // Find-in-scrollback toggle. Slot between the (tmux-only)
            // `+` button and the trailing `house` so the home button
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

            // Home — returns to the host landing. Mirrors the leading
            // sidebar toggle's icon-button style for visual symmetry,
            // replacing the v1 `back` text label which carried no
            // affordance hint.
            chromeIconButton(systemName: "house", action: onBack)
        }
        // Inner content inset (mockup uses 8px); the floating pill's own
        // side margin handles clearing the display corners, so this stays
        // small instead of the full corner-radius inset the edge-to-edge
        // bar needed.
        .padding(.horizontal, 8 * scale)
        .frame(maxWidth: .infinity)
        .frame(height: appearance.topBarHeight)
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
    }

    /// Shared icon-button style for the bar's leading sidebar toggle
    /// and trailing home / find buttons. 28×24pt hit target at the
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Passthrough layout

    @ViewBuilder
    private var passthroughStatus: some View {
        hostStatusButton {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7 * scale, height: 7 * scale)

                Text("\(host.user)@\(host.address):\(host.port)")
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
                    .font(.system(size: 10 * scale, weight: .semibold))
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
            .contentShape(Rectangle())
        }

        // Horizontal scroll so a dozen tmux windows can coexist with a
        // narrow viewport; the typical case (1-4 windows) fits
        // comfortably without any scroll indicators appearing.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6 * scale) {
                ForEach(Array(tmux.windows.enumerated()), id: \.element.id) { index, window in
                    tabButton(
                        number: index + 1,
                        name: window.name,
                        windowID: window.id.rawValue,
                        isActive: window.id == tmux.activeWindowId,
                        isDegraded: tmuxIsDegraded
                    )
                }
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
            .accessibilityLabel("New tmux window")
    }

    /// A single tmux-window tab. Tapping it switches to that window
    /// via the same path ⌘1-9 takes (`selectWindow(atPosition:)`),
    /// rather than going through the keyboard-shortcut handler — the
    /// number > 9 case has no shortcut equivalent so the tap is the
    /// only way to reach those windows.
    private func tabButton(
        number: Int,
        name: String,
        windowID: Int,
        isActive: Bool,
        isDegraded: Bool
    ) -> some View {
        let hasPendingBell = appearance.bellVisualEnabled
            && !isActive
            && tmux.bellingWindows.contains(windowID)
        let glowing = appearance.bellVisualEnabled
            && bellController.shouldGlow(forWindowID: windowID, sessionID: host.id)

        return Button(action: { tmux.selectWindow(atPosition: number) }) {
            HStack(spacing: 6) {
                Text(name)
                    .font(Typography.tesseraMono(size: 12 * scale, weight: isActive ? .medium : .regular))
                    .foregroundStyle(
                        isActive
                            ? (isDegraded ? T.amber : T.fg)
                            : (isDegraded ? T.fgDim : T.fgMuted)
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
            .padding(.horizontal, 11 * scale)
            .frame(height: 24 * scale)
            .background(
                // Capsule-rounded tab (radius = half the height), matching the
                // mockup's fully-rounded pills, rather than the prior 6pt nubs.
                RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                    .fill(tabBackground(isActive: isActive, isDegraded: isDegraded))
            )
            .overlay {
                if glowing {
                    BellGlowOverlay(color: T.accent)
                        .id(bellController.lastBellAt)
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
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: hasPendingBell)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Active-tab fill: theme accent (via `accentSoft`) in normal
    /// operation, semantic amber when tmux sync is degraded so the
    /// warning state remains unambiguous regardless of which theme
    /// the user picked. Inactive tabs are transparent.
    private func tabBackground(isActive: Bool, isDegraded: Bool) -> SwiftUI.Color {
        guard isActive else { return SwiftUI.Color.clear }
        return isDegraded ? T.amber.opacity(0.16) : T.accentSoft
    }

    private func hostStatusButton<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: { statusBreakdownVisible = true }) {
            content()
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

/// Variant of `TerminalSurface` that exposes a `onMade` hook so the
/// parent can grab the `TerminalView` after construction, and an
/// `onSend` callback so keystrokes flow out to the session.
///
/// The view returned is a `TesseraTerminalContainer`: a UIView that
/// hosts a SwiftTerm `TerminalView` as its only subview and claims
/// tmux shortcuts via `UIKeyCommand` through its position in the
/// responder chain. See `TesseraTerminalView.swift` for the ⌘T / ⌘⇧W
/// / ⌘1-9 / ⌘⇧[ / ⌘⇧] bindings and why ⌘⇧W (not ⌘W).
struct TerminalSurfaceBound: UIViewRepresentable {
    let initialData: [UInt8]
    let onMade: (TerminalView) -> Void
    let onReady: () -> Void
    let onSend: (ArraySlice<UInt8>) -> Void
    let onResize: (Int, Int) -> Void
    let onTitle: (String) -> Void
    let onUserActivity: (() -> Void)?
    let onBell: (() -> Void)?
    var onPrimaryScrollbackDelta: ((TerminalView, Double, CGFloat, CGFloat) -> Bool)? = nil
    var onPrimaryScrollbackUnderflow: ((TerminalView, Double, CGFloat, CGFloat) -> Void)? = nil
    let mouseReportingImpliesAltScreen: Bool
    let suppressDirectColorQueryResponses: Bool
    let tmuxShortcutsEnabled: Bool
    let onTmuxShortcut: (TesseraTmuxShortcut) -> Void
    let onFindShortcut: ((TesseraFindShortcut) -> Void)?
    let onSwitcherShortcut: ((TesseraSwitcherShortcut) -> Void)?
    let onOpenSettings: (() -> Void)?
    /// When true, `updateUIView` skips its "reclaim first responder"
    /// pass so the find bar's `TextField` can hold focus. Without
    /// this gate the terminal yanks first responder back on every
    /// SwiftUI re-render and the user sees the input cursor blink
    /// briefly in the bar then jump back to the terminal.
    let suppressFirstResponderReclaim: Bool
    let onHardwareKey: ((TesseraTerminalHardwareKey) -> Void)?
    var onTerminalScrolled: ((TerminalView) -> Void)? = nil
    var scrollRetentionID: String? = nil
    var onScrollDiagnostic: ((String) -> Void)? = nil

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
            mouseReportingImpliesAltScreen: mouseReportingImpliesAltScreen,
            suppressDirectColorQueryResponses: suppressDirectColorQueryResponses,
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

        let view = container.terminalView
        view.terminalDelegate = context.coordinator
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

        // §3.1: Scroll gesture covering both trackpad (continuous) and
        // mouse wheel (discrete). SwiftTerm's existing pan recognizers
        // catch touches, which this one ignores. The delegate's
        // shouldReceive(event:) override double-enforces: only `.scroll`
        // events pass through, never touches.
        let scrollGesture = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTrackpadScroll(_:))
        )
        scrollGesture.allowedScrollTypesMask = .all
        scrollGesture.delegate = context.coordinator
        view.addGestureRecognizer(scrollGesture)

        // UIScrollView (SwiftTerm's TerminalView superclass) has its own
        // built-in panGestureRecognizer that also responds to scroll-type
        // events. When both fire simultaneously, UIScrollView applies its
        // momentum/deceleration model to contentOffset while our handler
        // sets contentOffset directly — the two compete and produce visible
        // stuttering on fast scrolling. Clearing the built-in pan's scroll
        // mask makes it ignore trackpad/wheel events entirely, leaving
        // scroll handling exclusively to our gesture.
        view.panGestureRecognizer.allowedScrollTypesMask = []

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
        mouseTap.require(toFail: scrollGesture)
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
        paneFocusTap.require(toFail: scrollGesture)
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
        context.coordinator.onUserActivity = onUserActivity
        context.coordinator.onPrimaryScrollbackDelta = onPrimaryScrollbackDelta
        context.coordinator.onPrimaryScrollbackUnderflow = onPrimaryScrollbackUnderflow
        context.coordinator.onTerminalScrolled = onTerminalScrolled
        context.coordinator.setScrollRetentionID(scrollRetentionID)
        context.coordinator.onScrollDiagnostic = onScrollDiagnostic
        context.coordinator.mouseReportingImpliesAltScreen = mouseReportingImpliesAltScreen
        context.coordinator.suppressDirectColorQueryResponses = suppressDirectColorQueryResponses
        // Re-bind the mosh tap-to-focus closure + gate every update so the hit
        // test reads the current active window's layout, not a stale capture.
        context.coordinator.onPaneFocusTap = onPaneFocusTap
        context.coordinator.paneFocusTapEnabled = paneFocusTapEnabled

        applyAppearance(to: container.terminalView, container: container)

        // If focus drifted away (e.g., a modal briefly took first
        // responder), reclaim it on the next SwiftUI update pass —
        // unless the find bar is open and intentionally holding focus
        // for its own input. Without this gate the terminal grabs
        // first responder back from the find input on every SwiftUI
        // re-render, so typing into the find bar loses focus mid-key.
        let view = container.terminalView
        if !view.isFirstResponder {
            if !suppressFirstResponderReclaim {
                DispatchQueue.main.async {
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
        if container.appliedThemeID != theme.id {
            view.installColors(theme.ansi.map(swiftTermColor(rgb:)))
            let bg = uiColor(rgb: theme.bgRGB)
            let fg = uiColor(rgb: theme.fgRGB)
            view.nativeBackgroundColor = bg
            view.nativeForegroundColor = fg
            container.backgroundColor = bg
            view.backgroundColor = bg
            container.appliedThemeID = theme.id
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
        var onPrimaryScrollbackDelta: ((TerminalView, Double, CGFloat, CGFloat) -> Bool)?
        var onPrimaryScrollbackUnderflow: ((TerminalView, Double, CGFloat, CGFloat) -> Void)?
        var mouseReportingImpliesAltScreen: Bool
        var suppressDirectColorQueryResponses: Bool
        let onHardwareKey: ((TesseraTerminalHardwareKey) -> Void)?
        var onTerminalScrolled: ((TerminalView) -> Void)?
        private var scrollRetentionID: String?
        var onScrollDiagnostic: ((String) -> Void)?
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

        /// Weak ref so the scroll handler can read terminal state
        /// (`isCurrentBufferAlternate`, `mouseMode`) and call scroll
        /// methods (`scrollUp`/`scrollDown`) without creating a retain
        /// cycle with the coordinator.
        weak var terminalView: TerminalView?

        /// Mouse-click tap gesture, stored so the delegate can
        /// distinguish it from other recognizers.
        weak var mouseTapGesture: UITapGestureRecognizer?

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
        private weak var hardwareKeyboard: GCKeyboard?
        private var pendingNormalInputBytes: [UInt8] = []

        init(
            onReady: @escaping () -> Void,
            onSend: @escaping (ArraySlice<UInt8>) -> Void,
            onResize: @escaping (Int, Int) -> Void,
            onTitle: @escaping (String) -> Void,
            onUserActivity: (() -> Void)?,
            onBell: (() -> Void)?,
            onPrimaryScrollbackDelta: ((TerminalView, Double, CGFloat, CGFloat) -> Bool)?,
            onPrimaryScrollbackUnderflow: ((TerminalView, Double, CGFloat, CGFloat) -> Void)?,
            mouseReportingImpliesAltScreen: Bool,
            suppressDirectColorQueryResponses: Bool,
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
            self.mouseReportingImpliesAltScreen = mouseReportingImpliesAltScreen
            self.suppressDirectColorQueryResponses = suppressDirectColorQueryResponses
            self.onHardwareKey = onHardwareKey
            self.onTerminalScrolled = onTerminalScrolled
            self.scrollRetentionID = scrollRetentionID
            self.onScrollDiagnostic = onScrollDiagnostic
            super.init()
        }

        deinit {
            if let obs = keyboardConnectObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func setScrollRetentionID(_ id: String?) {
            guard scrollRetentionID != id else { return }
            scrollRetentionID = id
            clearDesiredScrollOffset(reason: "identity-change", view: terminalView)
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

        // MARK: - TerminalViewDelegate

        func scrolled(source: TerminalView, position: Double) {
            restoreDesiredScrollOffsetIfNeeded(in: source, position: position)
            onTerminalScrolled?(source)
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            onTitle(title)
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            if !didReportReady, newCols > 0, newRows > 0 {
                didReportReady = true
                onReady()
            }
            onResize(newCols, newRows)
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onUserActivity?()
            let colorResponse = TerminalOSCColorResponseRewriter.rewriteColorQueryResponse(
                data,
                defaultForegroundRGB: container?.terminalDefaultForegroundRGB ?? 0xD4D4D4,
                defaultBackgroundRGB: container?.terminalDefaultBackgroundRGB ?? 0x000000
            )
            if colorResponse.isColorQueryResponse {
                if !pendingNormalInputBytes.isEmpty {
                    onSend(pendingNormalInputBytes[...])
                    pendingNormalInputBytes.removeAll(keepingCapacity: true)
                }
                if suppressDirectColorQueryResponses {
                    return
                }
                onSend(colorResponse.bytes[...])
                return
            }

            if source.getTerminal().isCurrentBufferAlternate {
                if !pendingNormalInputBytes.isEmpty {
                    onSend(pendingNormalInputBytes[...])
                    pendingNormalInputBytes.removeAll(keepingCapacity: true)
                }
                onSend(data)
                return
            }

            let normalized = TerminalInputNormalizer.normalizeNormalBufferInput(
                data,
                pending: &pendingNormalInputBytes
            )
            if !normalized.isEmpty {
                onSend(normalized[...])
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

        @objc func handleTrackpadScroll(_ recognizer: UIPanGestureRecognizer) {
            guard let view = terminalView else { return }
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
                    // SwiftTerm's `TerminalView` is a UIScrollView
                    // subclass on iOS and the Metal renderer reads
                    // `contentOffset.y` (not `yDisp`) to decide which
                    // rows to draw. Its public `scrollUp(lines:)`
                    // API ends by calling `updateScroller`, which
                    // snaps contentOffset back to the bottom — so
                    // that API is broken for scrollback. Instead we
                    // write `contentOffset.y` directly.
                    //
                    // Note SwiftTerm on iOS scrolls in continuous
                    // pixel units, not line-snapped like iTerm2 on
                    // macOS — you can briefly see half a row at the
                    // top of the view mid-scroll. Line-snap would
                    // require intercepting Metal's `firstRow`
                    // computation and is out of scope.
                    //
                    // 3× multiplier: a raw 1:1 pass-through ended up
                    // too slow on iPad (Safari-style natural scroll
                    // feels brisker than a mouse wheel on a desktop
                    // by reflex). Each 3pt wheel notch now moves 9pt
                    // of content, five events per click ≈ 45pt ≈ 3
                    // lines — matching iTerm2 default feel.
                    let beforeY = view.contentOffset.y
                    let newY = beforeY - CGFloat(pointsY) * 3
                    let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
                    let consumed = onPrimaryScrollbackDelta?(view, pointsY, newY, maxOffsetY) == true
                    if consumed {
                        clearDesiredScrollOffset(reason: "primary-consumed", view: view)
                        emitScrollDiagnostic(
                            "event=\(diagnosticEvent) phase=\(phase) delta=\(Self.format(translation.y)) termAlt=\(terminal.isCurrentBufferAlternate) stateAlt=\(isAltScreen) mouse=\(mouseMode) actions=\(Self.actionDescription(actions)) primary-consumed points=\(String(format: "%.1f", pointsY)) before=\(Self.format(beforeY)) proposed=\(Self.format(newY)) after=\(Self.format(view.contentOffset.y)) max=\(Self.format(maxOffsetY)) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height))"
                        )
                        break
                    }
                    let targetY = min(max(0, newY), maxOffsetY)
                    view.contentOffset = CGPoint(
                        x: view.contentOffset.x,
                        y: targetY
                    )
                    rememberDesiredScrollOffset(targetY, maxOffsetY: maxOffsetY)
                    emitScrollDiagnostic(
                        "event=\(diagnosticEvent) phase=\(phase) delta=\(Self.format(translation.y)) termAlt=\(terminal.isCurrentBufferAlternate) stateAlt=\(isAltScreen) mouse=\(mouseMode) actions=\(Self.actionDescription(actions)) primary-write points=\(String(format: "%.1f", pointsY)) before=\(Self.format(beforeY)) proposed=\(Self.format(newY)) after=\(Self.format(view.contentOffset.y)) max=\(Self.format(maxOffsetY)) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height))"
                    )
                    if pointsY > 0 {
                        onPrimaryScrollbackUnderflow?(
                            view,
                            pointsY,
                            newY,
                            maxOffsetY
                        )
                    }
                case .mouseWheel(let buttonFlags, let cursorColumn, let cursorRow, let repeatCount):
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
                    clearDesiredScrollOffset(reason: "write-bytes", view: view)
                    onSend(ArraySlice(bytes))
                    emitScrollDiagnostic(
                        "event=\(diagnosticEvent) phase=\(phase) delta=\(Self.format(translation.y)) termAlt=\(terminal.isCurrentBufferAlternate) stateAlt=\(isAltScreen) mouse=\(mouseMode) actions=\(Self.actionDescription(actions)) write-bytes count=\(bytes.count) position=\(scrollOffsetDescription(for: view))"
                    )
                }
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

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive event: UIEvent
        ) -> Bool {
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
            // Scroll pan: trackpad-scroll-only.
            return event.type == .scroll
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Coexist peacefully with SwiftTerm's internal recognizers.
            // Our event-type filter above already guarantees we only
            // handle scroll events, so simultaneous recognition is
            // definitionally non-conflicting. The mouse-tap gesture
            // has require(toFail:) set up so it doesn't fire alongside
            // SwiftTerm's singleTap.
            true
        }
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
                .font(.system(.footnote, design: .monospaced))
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
                .font(.system(.caption2, design: .monospaced, weight: .medium))
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
                    .font(.system(.caption, design: .monospaced, weight: .medium))
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
