// Tessera/Files/RemoteCwdPoller.swift
//
// iOS-facing name for the shared cwd poll. The command policy — the three
// discovery modes, the `sh -c` wrapping, the TESSERA_CWD marker, the miss
// debounce and the poll interval — lives in
// `TesseraDomainCore.RemoteCwdProbe` so Android probes a host with the
// exact same shell text. What stays here is the loop itself: the
// FileBridge exec, the sleep, and the push into the panel's follow state.
//
// Why the loop exists at all (verbatim from the shared core):
//
//   - plain mosh: a stock remote mosh-server drops OSC 7 before it ever
//     enters the state sync, so polling is the ONLY follow source unless
//     the host runs our fork. The bootstrap banner gave us the server
//     PID; the shell is its child.
//   - plain SSH: OSC 7 works end-to-end but only once shell integration
//     is installed. The poller is the zero-setup fallback: it stands
//     down whenever OSC 7 is live (the `oscSignal` probe) and otherwise
//     follows the user's newest tty-attached shell by heuristic.
//
// Under tmux the pane-metadata subscription owns cwd; both session views
// key their poll task off `tmux.mode` so this loop never runs attached.

import Foundation
import TesseraDomainCore

enum RemoteCwdPoller {

    /// How to find the shell whose cwd the panel should follow.
    typealias ShellDiscovery = RemoteCwdProbe.ShellDiscovery

    static let pollIntervalNanoseconds: UInt64 =
        UInt64(RemoteCwdProbe.pollIntervalSeconds * 1_000_000_000)

    /// Identity string for the `.task(id:)` driving a poll loop: any
    /// change (panel toggled, tab switched, tmux attached/detached,
    /// bootstrap delivered a PID) cancels the running loop and starts a
    /// fresh one, whose entry guard decides whether to poll at all.
    static func taskKey(
        panelOpen: Bool,
        sessionActive: Bool,
        tmuxAttached: Bool,
        serverPID: Int? = nil
    ) -> String {
        RemoteCwdProbe.taskKey(
            panelOpen: panelOpen,
            sessionActive: sessionActive,
            tmuxAttached: tmuxAttached,
            serverPID: serverPID
        )
    }

    /// Marker prefixing the cwd line so parsing survives login-shell noise.
    static let pathMarker = RemoteCwdProbe.pathMarker

    static func discoveryCommand(for discovery: ShellDiscovery) -> String {
        RemoteCwdProbe.discoveryCommand(for: discovery)
    }

    /// The marker-tagged line as an absolute path, or nil on a miss
    /// (empty output, error/rc noise, no marker). First marker wins.
    static func reportedPath(in output: String) -> String? {
        RemoteCwdProbe.reportedPath(in: output)
    }

    /// Poll loop body — call from a `.task(id: taskKey(...))` after the
    /// view's own entry guard. Runs until cancelled.
    ///
    /// `oscSignal` (SSH only): probe returning the terminal's last OSC 7
    /// value. While non-nil, OSC 7 owns follow — it's instant and
    /// per-shell exact — and the poller just idles. The caller must
    /// return nil until OSC 7 has actually DELIVERED outside tmux this
    /// session: `hostCurrentDirectory` alone never clears, and bytes
    /// that rode the tmux control channel can latch a stale value (the
    /// reason the mosh view passes no probe at all — a stock
    /// mosh-server drops passthrough OSC 7, so nothing would ever
    /// refresh it there. When the host runs our fork, real OSC 7
    /// reports simply coexist with the poll — same values.)
    @MainActor
    static func run(
        panel: FilesPanelController,
        discovery: ShellDiscovery,
        oscSignal: (() -> String?)? = nil
    ) async {
        let command = discoveryCommand(for: discovery)
        // Debounce transient misses (shell mid-exec, pgrep hiccup) so
        // follow doesn't flicker to "no signal" — the streak rule lives in
        // the shared core.
        var debounce = RemoteCwdProbe.FollowDebounce()
        while !Task.isCancelled {
            let tick: RemoteCwdProbe.FollowDebounce.Tick
            if let oscSignal, oscSignal() != nil {
                tick = .oscSignalLive
            } else if let bridge = panel.bridge, bridge.state == .connected {
                let output = (try? await bridge.exec(command, inShell: false)) ?? ""
                if Task.isCancelled { return }
                tick = .probed(output: output)
            } else {
                tick = .notPolled
            }
            switch debounce.step(tick) {
            case .report(let path):
                panel.terminalReportedDirectory(path)
            case .clearFollow:
                panel.terminalReportedDirectory(nil)
            case .hold:
                break
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
