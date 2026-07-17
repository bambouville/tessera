// Tessera/Files/RemoteCwdPoller.swift
//
// Shared cwd-poll loop for transports where the terminal delivers no
// (reliable) in-band cwd signal. It asks the host — over the FileBridge,
// never the terminal transport — where the session's interactive shell
// currently sits, and pushes the answer into the panel's follow state:
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

enum RemoteCwdPoller {

    /// How to find the shell whose cwd the panel should follow.
    enum ShellDiscovery {
        /// mosh: the shell is the remote mosh-server's child, and the
        /// bootstrap banner captured the server PID.
        case moshServerChild(serverPID: Int)
        /// Plain SSH: nothing ties our terminal channel to a remote PID,
        /// so follow the newest tty-attached shell owned by the user.
        /// With several interactive sessions on one host this can pick a
        /// sibling's shell — OSC 7 stays the precise, instant source;
        /// this is the works-without-setup net underneath it.
        case newestLoginShell
        /// tmux launch modes: ask tmux itself for the named session's
        /// active pane. Session-scoped (safe with several tmux sessions
        /// on the host) and independent of the -CC side channel — which
        /// is deliberately DOWN for backgrounded sessions, so pane
        /// metadata can't answer there (the Upload sheet's case).
        case tmuxSession(name: String)
    }

    static let pollIntervalNanoseconds: UInt64 = 2_500_000_000

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
        [
            panelOpen ? "open" : "closed",
            sessionActive ? "active" : "bg",
            tmuxAttached ? "tmux" : "plain",
            serverPID.map(String.init) ?? "nopid",
        ].joined(separator: ":")
    }

    /// Marker prefixing the cwd line so parsing survives login-shell
    /// noise: exec output merges stderr, and rc files sourced by the
    /// remote shell (zshenv, SSH_SOURCE_BASHRC bashrc, nvm, motd) can
    /// print ahead of our own output.
    static let pathMarker = "TESSERA_CWD="

    /// Resolve the shell's PID in `$sp` into a marker-tagged cwd line —
    /// `readlink /proc/<pid>/cwd` on Linux, `lsof` fallback for
    /// macOS/BSD hosts. Trailing `exit 0` per the OSDetectionProbe
    /// pattern so a miss doesn't surface as an exec error.
    private static let cwdLookup =
        #"[ -n "$sp" ] && d=$(readlink "/proc/$sp/cwd" 2>/dev/null "#
        + #"|| lsof -a -p "$sp" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n1); "#
        + #"[ -n "$d" ] && printf 'TESSERA_CWD=%s\n' "$d"; exit 0"#

    /// sshd runs exec requests as `<login shell> -c <cmd>`, and fish /
    /// (t)csh reject POSIX `sp=$(...)` outright — so the payload always
    /// rides an explicit `sh -c` (embedded single quotes escaped with
    /// the `'\''` idiom, which fish and csh parse the same way).
    private static func posixWrapped(_ payload: String) -> String {
        "sh -c '" + payload.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func discoveryCommand(for discovery: ShellDiscovery) -> String {
        switch discovery {
        case .moshServerChild(let serverPID):
            return posixWrapped(
                #"sp=$(pgrep -P \#(serverPID) 2>/dev/null | head -n1); "# + cwdLookup
            )
        case .newestLoginShell:
            // tty filter (`pts/` Linux, `ttys` macOS) drops daemons AND
            // the bridge's own tty-less exec wrapper shell, which would
            // otherwise always be the newest match. comm ending in "sh"
            // covers bash/zsh/fish/dash/ksh/tcsh (incl. `-` login and
            // path-prefixed forms); `!~ /ssh$/` keeps ssh clients out.
            // Explicit max-PID pick: row order is NOT pid order on
            // macOS (BSD ps sorts by controlling tty first). Highest
            // PID ≈ newest — a heuristic, not an anchor; see
            // ShellDiscovery.newestLoginShell.
            return posixWrapped(
                #"sp=$(ps -u "${USER:-$(id -un)}" -o pid= -o tty= -o comm= 2>/dev/null "#
                + #"| awk '$2 ~ /^(pts\/|ttys)/ && $3 ~ /sh$/ && $3 !~ /ssh$/ "#
                + #"{ if ($1+0 > p) p = $1+0 } END { if (p) print p }'); "#
                + cwdLookup
            )
        case .tmuxSession(let name):
            // display-message -p answers with the session's active pane
            // in its current window — the same pane the -CC
            // subscription would report. Bare target name: tmux matches
            // exact names before prefixes, and the `=` exact-match
            // prefix comes back EMPTY from display-message on tmux 3.6a
            // (verified empirically — don't "fix" this back).
            // PATH prefix: non-interactive sshd exec PATH omits the
            // homebrew/local prefixes, so a macOS host's tmux
            // (/opt/homebrew/bin/tmux) is invisible without it.
            let quotedTarget = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return posixWrapped(
                #"PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; "#
                + #"d=$(tmux display-message -p -t "# + quotedTarget
                + #" '#{pane_current_path}' 2>/dev/null); "#
                + #"[ -n "$d" ] && printf 'TESSERA_CWD=%s\n' "$d"; exit 0"#
            )
        }
    }

    /// The marker-tagged line as an absolute path, or nil on a miss
    /// (empty output, error/rc noise, no marker). First marker wins.
    static func reportedPath(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(pathMarker) else { continue }
            let path = String(line.dropFirst(pathMarker.count))
            return path.hasPrefix("/") ? path : nil
        }
        return nil
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
        var consecutiveMisses = 0
        while !Task.isCancelled {
            if let oscSignal, oscSignal() != nil {
                consecutiveMisses = 0
            } else if let bridge = panel.bridge, bridge.state == .connected {
                let output = (try? await bridge.exec(command, inShell: false)) ?? ""
                if Task.isCancelled { return }
                if let path = reportedPath(in: output) {
                    consecutiveMisses = 0
                    panel.terminalReportedDirectory(path)
                } else {
                    // Debounce transient misses (shell mid-exec, pgrep
                    // hiccup) so follow doesn't flicker to "no signal".
                    consecutiveMisses += 1
                    if consecutiveMisses == 2 {
                        panel.terminalReportedDirectory(nil)
                    }
                }
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
