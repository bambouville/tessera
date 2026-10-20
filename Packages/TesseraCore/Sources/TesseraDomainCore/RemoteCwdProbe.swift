import Foundation

/// Shared command policy for the cwd poll — the loop that asks a host where
/// the session's interactive shell currently sits, for transports where the
/// terminal delivers no (reliable) in-band cwd signal.
///
/// The probe runs over a short-lived authenticated exec channel (iOS: the
/// FileBridge; Android: its own SSH exec), NEVER the terminal transport:
///
///   - plain mosh: a stock remote mosh-server drops OSC 7 before it ever
///     enters the state sync, so polling is the ONLY follow source unless
///     the host runs our fork. The bootstrap banner gave us the server
///     PID; the shell is its child.
///   - plain SSH: OSC 7 works end-to-end but only once shell integration
///     is installed. The poller is the zero-setup fallback: it stands
///     down whenever OSC 7 is live (the `oscSignal` probe) and otherwise
///     follows the user's newest tty-attached shell by heuristic.
///
/// Under tmux the pane-metadata subscription owns cwd while the -CC side
/// channel is up; the `.tmuxSession` mode covers the case where it is
/// deliberately DOWN (backgrounded sessions, the Upload sheet).
///
/// The transport, the timer, and the follow-state sink stay on each
/// platform. Android peer: `RemoteCwdProbe` (feature-session).
public enum RemoteCwdProbe {

    /// How to find the shell whose cwd the panel should follow.
    public enum ShellDiscovery: Equatable, Hashable, Sendable {
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

    // MARK: - Cadence policy

    /// Seconds between polls. Slow on purpose: this is a fallback signal,
    /// and every tick costs a remote exec.
    public static let pollIntervalSeconds: TimeInterval = 2.5

    /// A single miss is noise (shell mid-exec, pgrep hiccup); follow only
    /// clears once the host has missed this many polls in a row.
    public static let missesBeforeClearingFollow = 2

    /// Identity string for the task driving a poll loop: any change (panel
    /// toggled, tab switched, tmux attached/detached, bootstrap delivered a
    /// PID) cancels the running loop and starts a fresh one, whose entry
    /// guard decides whether to poll at all.
    public static func taskKey(
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

    /// The miss debounce as pure state, so both platforms flicker (or
    /// rather, don't) identically. One instance per poll loop.
    public struct FollowDebounce: Equatable, Sendable {
        /// What happened on one tick of the loop.
        public enum Tick: Equatable, Sendable {
            /// OSC 7 is live and owns follow — the probe is skipped and the
            /// miss streak resets, because the terminal itself is answering.
            case oscSignalLive
            /// The probe ran; `output` is its merged stdout/stderr.
            case probed(output: String)
            /// Nothing to poll (no bridge / not connected). Deliberately
            /// does NOT count as a miss: a disconnected bridge says nothing
            /// about where the shell is.
            case notPolled
        }

        /// What the loop should do with the panel's follow state.
        public enum Outcome: Equatable, Sendable {
            /// Leave follow exactly as it is.
            case hold
            /// The host reported this absolute path.
            case report(String)
            /// The miss streak just hit the debounce limit — drop follow.
            case clearFollow
        }

        public private(set) var consecutiveMisses = 0

        public init() {}

        public mutating func step(_ tick: Tick) -> Outcome {
            switch tick {
            case .notPolled:
                return .hold
            case .oscSignalLive:
                consecutiveMisses = 0
                return .hold
            case .probed(let output):
                guard let path = RemoteCwdProbe.reportedPath(in: output) else {
                    consecutiveMisses += 1
                    // Exactly at the limit, never again: a host that stays
                    // silent must not re-clear an already-cleared follow.
                    return consecutiveMisses == RemoteCwdProbe.missesBeforeClearingFollow
                        ? .clearFollow : .hold
                }
                consecutiveMisses = 0
                return .report(path)
            }
        }
    }

    // MARK: - Command construction

    /// Marker prefixing the cwd line so parsing survives login-shell
    /// noise: exec output merges stderr, and rc files sourced by the
    /// remote shell (zshenv, SSH_SOURCE_BASHRC bashrc, nvm, motd) can
    /// print ahead of our own output.
    public static let pathMarker = "TESSERA_CWD="

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
    public static func posixWrapped(_ payload: String) -> String {
        "sh -c '" + singleQuoteEscaped(payload) + "'"
    }

    /// The `'\''` idiom: end the quote, emit an escaped quote, reopen.
    private static func singleQuoteEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    public static func discoveryCommand(for discovery: ShellDiscovery) -> String {
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
            let quotedTarget = "'" + singleQuoteEscaped(name) + "'"
            return posixWrapped(
                #"PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; "#
                + #"d=$(tmux display-message -p -t "# + quotedTarget
                + #" '#{pane_current_path}' 2>/dev/null); "#
                + #"[ -n "$d" ] && printf 'TESSERA_CWD=%s\n' "$d"; exit 0"#
            )
        }
    }

    // MARK: - Parsing

    /// The marker-tagged line as an absolute path, or nil on a miss
    /// (empty output, error/rc noise, no marker). First marker wins.
    ///
    /// The control-character rejection is Android's hardening, adopted as the
    /// shared rule: this parses remote-controlled probe output that is NOT
    /// gated by `RemotePathGrammar.pathCandidate`, so a path smuggling C0/C1
    /// bytes must die here rather than reach path navigation. (iOS previously
    /// accepted such paths; they only ever failed later at stat time.)
    public static func reportedPath(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(pathMarker) else { continue }
            let path = String(line.dropFirst(pathMarker.count))
            guard path.hasPrefix("/"),
                  !path.unicodeScalars.contains(where: {
                      $0.value < 0x20 || (0x7F...0x9F).contains($0.value)
                  })
            else { return nil }
            return path
        }
        return nil
    }
}
