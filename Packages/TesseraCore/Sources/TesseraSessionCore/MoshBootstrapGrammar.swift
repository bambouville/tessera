import Foundation

/// The classified, portable outcome of reading a `mosh-server new`
/// transcript. Deliberately tiny: everything richer (auth failures, host-key
/// rejections, exit statuses) belongs to the platform's transport layer,
/// which owns the localized user-facing text.
///
/// Mirrors Android's `MoshBootstrapFailure`.
public enum MoshBootstrapGrammarFailure: Error, Equatable, Sendable {
    /// The transcript shows the remote shell could not find `mosh-server`.
    case missingServer
    /// No `MOSH CONNECT` line at all.
    case missingConnect
    /// A `MOSH CONNECT` line was present but its port or key is unusable.
    /// The transcript is intentionally NOT retained on this value — a
    /// malformed line may still contain live key material.
    case malformedConnect
}

/// The ephemeral credentials `mosh-server new` prints on its way out.
///
/// Never log a value of this type; route anything derived from it through
/// `SensitiveDataRedaction` first.
public struct MoshConnectCredentials: Equatable, Sendable {
    public let udpPort: Int
    public let base64Key: String
    /// Parsed from mosh-server's own `[mosh-server detached, pid = N]`
    /// banner. `nil` whenever the banner is absent or unparseable — callers
    /// must treat a missing PID as "cannot safely signal the server".
    public let serverPID: Int?

    public init(udpPort: Int, base64Key: String, serverPID: Int?) {
        self.udpPort = udpPort
        self.base64Key = base64Key
        self.serverPID = serverPID
    }
}

/// Portable statement of the mosh bootstrap grammar: the exact command text
/// both platforms send, the exact response shape they are allowed to believe,
/// and the PID-reuse-safe server termination script.
///
/// The parse rules here are iOS's, which are the strict ones and therefore
/// canonical: a `MOSH CONNECT` line is recognised only by the literal
/// single-space prefix `"MOSH CONNECT "` after trimming, and only with
/// exactly four whitespace-separated fields. Android's earlier lenient
/// whitespace-split additionally accepted `MOSH\tCONNECT` / `MOSH  CONNECT`,
/// shapes mosh-server never emits; accepting them only widens what a hostile
/// or garbled transcript can talk Tessera into dialling.
public enum MoshBootstrapGrammar {

    /// The literal prefix, single space included. Load-bearing: see the type
    /// comment for why the lenient split loses.
    public static let connectLinePrefix = "MOSH CONNECT "

    /// mosh's session key is 16 bytes, i.e. 22 base64 characters before the
    /// optional `==` padding.
    public static let connectKeyLength = 22

    public static let detachedBannerPrefix = "[mosh-server detached, pid = "

    private static let base64KeyAlphabet = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/"
    )

    // MARK: - Command construction

    /// The exec-channel command that starts `mosh-server new` with the
    /// optional trailing `-- <argv>` the launch mode asked for, delivered so
    /// the binary is found wherever the user's own shells find it.
    ///
    /// An SSH exec channel runs `$SHELL -c`: a non-login shell that never
    /// reads `.zprofile` or `.bash_profile`. On a host where mosh-server lives
    /// on a login-only PATH — Homebrew on macOS, a Nix profile, `~/.local/bin`
    /// — the bare command fails with "command not found" even though every
    /// shell the user can see resolves it, and SSH to the same host keeps
    /// working because that shell *is* a login shell. Probe first and exec
    /// directly when the binary resolves, so a Linux host with mosh in
    /// `/usr/bin` pays nothing extra; only a host that would otherwise fail
    /// outright re-runs the identical argv through its login shell. The probe
    /// itself runs under `sh -c` so the outcome never depends on the login
    /// shell's dialect (fish cannot parse `if …; then …; fi`).
    ///
    /// The same trap and the same repair as tmux's control-mode launch
    /// (`AutoTmuxCommands.resolvingTmuxOnPath`).
    public static func serverNewCommand(launchCommand: String?) -> String {
        let invocation = "exec " + serverNewInvocation(launchCommand: launchCommand)
        let body = "if command -v mosh-server >/dev/null 2>&1; then \(invocation); "
            + "else exec \"${SHELL:-/bin/sh}\" -l -c \(singleQuotedShellString(invocation)); fi"
        return "sh -c \(singleQuotedShellString(body))"
    }

    /// The bare `mosh-server new -c 256 [-- <argv>]` argv that
    /// `serverNewCommand` delivers.
    ///
    /// `-c 256` is what the reference `mosh` wrapper passes for an
    /// xterm-256color client, and it is the only thing mosh-server consults
    /// when it exports TERM into whatever it spawns: without it the shell —
    /// or, on mosh+tmux, the visible tmux client — runs as plain `xterm`, an
    /// 8-colour terminfo, and every colour is squashed on its way to the
    /// device (orange to red; the greys of ghost-text autosuggestions and
    /// completion menus to black). An all-whitespace launch command is
    /// treated as absent so a misconfigured host still gets a plain login
    /// shell.
    public static func serverNewInvocation(launchCommand: String?) -> String {
        let trimmed = launchCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "mosh-server new -c 256" }
        return "mosh-server new -c 256 -- \(trimmed)"
    }

    /// PID comes from mosh-server's own detached banner, which may be
    /// arbitrarily stale by the time anything wants the server gone. Re-check
    /// the command name immediately before signalling so PID reuse cannot
    /// terminate an unrelated process; treat an already-exited server as
    /// success, and never escalate past `TERM`.
    ///
    /// Android's guarded form is canonical here (`MoshSessionRecoveryPolicy`);
    /// iOS's own kill site produces byte-identical text.
    ///
    /// Exit codes: `0` server gone (or never there), `64` the PID is alive but
    /// is not a mosh-server — refuse to signal it.
    public static func makeServerTerminationScript(pid: Int) -> String {
        precondition(pid > 0)
        let body = "pid=\(pid); "
            + "if ! kill -0 \"$pid\" 2>/dev/null; then exit 0; fi; "
            + "set -- $(ps -p \"$pid\" -o comm= 2>/dev/null); "
            + "case \"${1:-}\" in *mosh-server*) ;; *) exit 64;; esac; "
            + "kill -TERM \"$pid\"; n=0; "
            + "while kill -0 \"$pid\" 2>/dev/null && [ \"$n\" -lt 5 ]; do "
            + "sleep 1; n=$((n+1)); done; "
            + "! kill -0 \"$pid\" 2>/dev/null"
        return "sh -lc \(singleQuotedShellString(body))"
    }

    /// The line prefix a liveness probe answers with. One of `alive`, `gone`
    /// or `unknown` follows it.
    public static let serverLivenessMarker = "TESSERA_MOSH_SERVER="

    /// Ask whether the session's detached mosh-server still runs, without
    /// touching it.
    ///
    /// Mosh has no timeout of its own: when the host restarts, the client
    /// keeps sending to a server that no longer exists, for as long as the
    /// app keeps it open. Only the host can say the server is gone. The PID
    /// fence matches `makeServerTerminationScript`'s, read the other way: a
    /// PID we cannot signal is not our server (mosh-server runs as the SSH
    /// user), and a PID now running something else is a reused number after
    /// a restart. Both are `gone`. A host whose `ps` cannot name the process
    /// answers `unknown`, which callers must treat as no evidence: guessing
    /// `gone` there would reconnect a live session. The name is matched
    /// unsplit because macOS prints the executable's whole path, which may
    /// contain spaces; a word split there would read a live server as gone.
    ///
    /// `sh -c`, not a login shell: the probe repeats while the link is down,
    /// and a profile that prints, prompts or execs something must not decide
    /// the answer. `kill` is a shell builtin and `ps` is on the exec
    /// channel's default PATH.
    public static func makeServerLivenessScript(pid: Int) -> String {
        precondition(pid > 0)
        let marker = serverLivenessMarker
        let body = "pid=\(pid); "
            + "if ! kill -0 \"$pid\" 2>/dev/null; then echo \(marker)gone; exit 0; fi; "
            + "c=$(ps -p \"$pid\" -o comm= 2>/dev/null); "
            + "case \"$c\" in "
            + "*mosh-server*) echo \(marker)alive;; "
            + "*[![:space:]]*) echo \(marker)gone;; "
            + "*) echo \(marker)unknown;; esac"
        return "sh -c \(singleQuotedShellString(body))"
    }

    /// Read a liveness probe's answer. Only an exact marker line counts; the
    /// last one wins. Anything else — a shell that printed nothing, a banner,
    /// a truncated line — is `unknown`, never `gone`.
    public static func parseServerLiveness(_ output: String) -> MoshServerLiveness {
        var verdict = MoshServerLiveness.unknown
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(serverLivenessMarker) else { continue }
            let value = String(line.dropFirst(serverLivenessMarker.count))
            verdict = MoshServerLiveness(rawValue: value) ?? .unknown
        }
        return verdict
    }

    /// POSIX single-quoting: the only escape inside `'…'` is `'\''`.
    public static func singleQuotedShellString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Response parsing

    /// Read the credentials out of a bootstrap transcript.
    ///
    /// Throws `.malformedConnect` when a `MOSH CONNECT` line existed but no
    /// line yielded a usable port and key, and `.missingConnect` when no line
    /// carried the prefix at all. The distinction matters: malformed means the
    /// server ran and we cannot trust what it said, missing usually means
    /// something else ate the channel.
    public static func parseConnectResponse(
        stdout: String,
        stderr: String = ""
    ) throws -> MoshConnectCredentials {
        let combinedOutput = combinedBootstrapOutput(stdout: stdout, stderr: stderr)
        let serverPID = detachedServerPID(from: combinedOutput)
        var sawMalformedLine = false

        for rawLine in combinedOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(connectLinePrefix) else { continue }

            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 4 else {
                sawMalformedLine = true
                continue
            }

            guard let port = Int(fields[2]), (1...65_535).contains(port) else {
                sawMalformedLine = true
                continue
            }

            guard let key = normalizedConnectKey(String(fields[3])) else {
                sawMalformedLine = true
                continue
            }

            return MoshConnectCredentials(
                udpPort: port,
                base64Key: key,
                serverPID: serverPID
            )
        }

        if sawMalformedLine {
            throw MoshBootstrapGrammarFailure.malformedConnect
        }
        throw MoshBootstrapGrammarFailure.missingConnect
    }

    /// Strip mosh's optional `==` padding and accept only a 22-character
    /// standard-alphabet base64 body. Anything else is credential-shaped
    /// noise, not a credential.
    public static func normalizedConnectKey(_ rawKey: String) -> String? {
        let candidate: Substring
        if rawKey.hasSuffix("==") {
            candidate = rawKey.dropLast(2)
        } else {
            candidate = Substring(rawKey)
        }

        guard candidate.count == connectKeyLength else { return nil }
        guard candidate.unicodeScalars.allSatisfy({ base64KeyAlphabet.contains($0) })
        else { return nil }

        return String(candidate)
    }

    /// `[mosh-server detached, pid = N]`. Only a strictly positive decimal
    /// PID on an otherwise exact line counts.
    public static func detachedServerPID(from output: String) -> Int? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(detachedBannerPrefix), line.hasSuffix("]") else {
                continue
            }

            let pidStart = line.index(
                line.startIndex,
                offsetBy: detachedBannerPrefix.count
            )
            let pidEnd = line.index(before: line.endIndex)
            let pidText = line[pidStart..<pidEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = Int(pidText), pid > 0 else { continue }
            return pid
        }

        return nil
    }

    /// mosh-server may print `MOSH CONNECT` on either stream depending on the
    /// remote shell; the parser reads one combined view. Joining is skipped
    /// when either side is empty so a single-stream transcript keeps its exact
    /// line numbering.
    public static func combinedBootstrapOutput(
        stdout: String,
        stderr: String
    ) -> String {
        guard !stderr.isEmpty else { return stdout }
        guard !stdout.isEmpty else { return stderr }
        return "\(stdout)\n\(stderr)"
    }

    /// "mosh-server isn't installed" has to be distinguishable from "the
    /// bootstrap failed", because only the former has a useful remedy. Both
    /// markers must be present: an ordinary transcript mentioning
    /// `mosh-server` is not a diagnosis, and neither is a bare
    /// "command not found" for something else.
    public static func transcriptSuggestsMissingServer(_ combinedOutput: String) -> Bool {
        let normalized = combinedOutput.lowercased()
        guard normalized.contains("mosh-server") else { return false }
        return normalized.contains("not found")
            || normalized.contains("command not found")
            || normalized.contains("no such file")
    }

    /// Stream-order convenience matching the platform call sites: stderr
    /// first, because that is where a shell reports a missing binary.
    public static func transcriptSuggestsMissingServer(
        stdout: String,
        stderr: String
    ) -> Bool {
        transcriptSuggestsMissingServer("\(stderr)\n\(stdout)")
    }
}
