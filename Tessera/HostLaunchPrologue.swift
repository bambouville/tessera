import Foundation

/// Per-host shell prologue built from the `envVars` and `startupSnippet`
/// fields on `Host`. Prepended to the auto-tmux / pinned-tmux / custom
/// launch command at connect time so user-defined `KEY=VALUE` exports
/// and a free-form startup snippet run before the real launch command.
///
/// Pure helper — no UIKit, no IO. Two output forms:
///   - `multilineStdin` for SSH transport (sent line-by-line to the
///     interactive shell over stdin, alongside the launch command).
///   - `inlineForArgv` for mosh transport (semicolon-joined and
///     embedded inside `sh -lc '...'`, since mosh-server execs the
///     inner command in a non-shell context).
///
/// The env-var parser accepts either bare `KEY=value` or the more
/// common `export KEY=value` form (the leading `export ` is stripped
/// before validation). VALUE is passed to the remote shell unchanged
/// so that the usual bash-style mechanics work: `$HOME` expands,
/// `"hello world"` works, command substitution with `$(...)` works.
/// We trust the user's input; this is the user's own iPad typing
/// into their own host config.
enum HostLaunchPrologue {

    /// Newline-separated form for SSH stdin. Returns `nil` when both
    /// inputs are empty after trimming.
    ///
    /// Output ends with a trailing newline so the caller can splice
    /// it directly before the existing launch-command bytes.
    static func multilineStdin(envVars: String, startupSnippet: String) -> String? {
        var lines: [String] = []
        for export in exportLines(from: envVars) {
            lines.append(export)
        }
        let snippet = startupSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippet.isEmpty { lines.append(snippet) }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Semicolon-joined form intended to be wrapped in `sh -lc '...'`
    /// for the mosh path. Returns `nil` when both inputs are empty
    /// after trimming.
    ///
    /// Output ends with `; ` so the caller can splice directly before
    /// `exec <real-launch-command>` inside the single-quoted argv.
    static func inlineForArgv(envVars: String, startupSnippet: String) -> String? {
        var parts: [String] = []
        for export in exportLines(from: envVars) {
            parts.append(export)
        }
        let snippet = startupSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippet.isEmpty { parts.append(snippet) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ") + "; "
    }

    // MARK: - Internals

    /// Parse the `envVars` text into an array of `export KEY=VALUE`
    /// statements. Lines that are empty, comment-only (`#…`), missing
    /// an `=`, or whose key (after stripping an optional leading
    /// `export `) fails the `[A-Za-z_][A-Za-z0-9_]*` regex are skipped
    /// silently.
    ///
    /// VALUE is emitted verbatim with no quoting — `$HOME`, double
    /// quotes, and command substitutions are left for the remote
    /// shell to interpret as the user wrote them.
    static func exportLines(from envVars: String) -> [String] {
        var result: [String] = []
        for raw in envVars.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Strip an optional leading `export ` so users can paste
            // bash-style `export FOO=bar` lines and have them work.
            if line.hasPrefix("export ") || line.hasPrefix("export\t") {
                line = String(line.dropFirst("export".count))
                    .trimmingCharacters(in: .whitespaces)
            }
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
            guard isValidEnvKey(String(key)) else { continue }
            let value = line[line.index(after: eqIdx)...]
            result.append("export \(key)=\(value)")
        }
        return result
    }

    private static func isValidEnvKey(_ key: String) -> Bool {
        guard let first = key.first else { return false }
        if !(first.isLetter || first == "_") { return false }
        for c in key.dropFirst() where !(c.isLetter || c.isNumber || c == "_") {
            return false
        }
        return true
    }
}
