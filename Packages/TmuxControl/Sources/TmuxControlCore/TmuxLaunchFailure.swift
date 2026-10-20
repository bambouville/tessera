import Foundation

/// Why an auto/pinned tmux launch never produced a usable control session.
///
/// The taxonomy is shared because the *policy* is shared — every platform
/// degrades a failed tmux launch to a plain shell rather than presenting a dead
/// session — even though the platforms detect the failure by different means.
/// iOS types a one-liner into a PTY and scans for the script's sentinels
/// (`AutoTmuxSentinelScanner`); Android opens a dedicated exec channel and
/// learns the failure as an exit status plus whatever the remote shell printed.
/// Both end up here.
///
/// The raw values cross the C ABI, so they are part of the contract: append
/// new cases, never renumber existing ones.
public enum TmuxLaunchFailure: Int32, Equatable, Sendable, CaseIterable {
    /// `tmux` is not on the remote `$PATH`.
    case unavailable = 1
    /// `tmux` exists but the session could not be created.
    case startFailed = 2
    /// The host's own dotfiles already put us inside a tmux client.
    case nested = 3

    /// Classify a control-mode launch that ended *without ever engaging*.
    ///
    /// The caller must establish non-engagement first. Exit status alone cannot:
    /// a session that ran for an hour and died when the host rebooted also exits
    /// non-zero, and that is a disconnect to recover from, not a launch to
    /// degrade. Equally, output alone cannot — a PTY merges stderr into stdout,
    /// so `command not found` arrives on the same stream a healthy session would
    /// have used for its first control frame.
    ///
    /// `output` should carry whatever the remote produced on either stream.
    /// Returns nil when nothing suggests the launch itself failed.
    public static func classify(exitStatus: Int32?, output: String) -> TmuxLaunchFailure? {
        let haystack = output.lowercased()

        // Checked first: a nested launch also prints "not found" on some hosts
        // when the guard re-execs, and nesting is the more specific diagnosis.
        if haystack.contains("sessions should be nested") { return .nested }

        // 127 is the shell's own "command not found", which is the single most
        // reliable signal here — it needs no text at all, so it survives a host
        // that localizes its shell messages.
        if exitStatus == 127 { return .unavailable }
        let missing = haystack.contains("command not found")
            || haystack.contains("not found")
            || haystack.contains("no such file")
        if missing && haystack.contains("tmux") { return .unavailable }

        if haystack.contains("no server running")
            || haystack.contains("failed to connect to server")
            || haystack.contains("lost server")
            || haystack.contains("error connecting to")
            || haystack.contains("open terminal failed") {
            return .startFailed
        }

        // A launch that never engaged control mode and exited non-zero failed,
        // even when the host said something we do not recognise. A plain shell
        // is strictly more useful to the user than a session that is simply
        // gone, which is what the unclassified path used to produce.
        if let exitStatus, exitStatus != 0 { return .startFailed }
        return nil
    }
}
