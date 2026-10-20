import Foundation

/// The single boundary for removing secrets from text before it reaches
/// either platform logging or Tessera's on-device diagnostic file.
///
/// Bootstrap parser errors intentionally retain no transcript at all. This
/// remains defense in depth for errors produced below the SSH library and for
/// diagnostic call sites that receive remote command output.
///
/// The patterns form ONE ordered list. Order is behaviour: the mosh
/// `MOSH CONNECT` line scrub runs before the bare-key scrub so a well-formed
/// line keeps its (validated) port for diagnosis, and the key scrub then
/// catches split or exception-bridged key material the line scrub could not
/// see. Callers pick a prefix/subset of the list for their sink; the applied
/// order is always this one, never the caller's argument order.
public enum SensitiveDataRedaction {

    /// The ordered redaction stages. Adding a case means adding it to
    /// `orderedPatterns` in the position its semantics require.
    public enum Pattern: String, CaseIterable, Sendable {
        /// `MOSH CONNECT <port> <key>` — the live session credential as
        /// mosh-server prints it.
        case moshConnectLine
        /// A bare 22-character base64 mosh key with optional `==` padding,
        /// anywhere in the text.
        case moshConnectKey
        /// `password=`, `passphrase=`, `secret=`, `token=` (or `:`-separated)
        /// key/value pairs.
        case credentialAssignment
        /// Anything shaped like `user@host` — account and endpoint identity.
        case endpointIdentifier
    }

    /// The canonical full list, in application order.
    public static let orderedPatterns: [Pattern] = [
        .moshConnectLine,
        .moshConnectKey,
        .credentialAssignment,
        .endpointIdentifier,
    ]

    /// The subset applied to transport detail that can still reach a
    /// user-facing failure message. Endpoint and credential-assignment
    /// scrubbing is deliberately absent: the user is entitled to see which
    /// host they failed to reach.
    public static let transportDetailPatterns: [Pattern] = [
        .moshConnectLine,
        .moshConnectKey,
    ]

    // MARK: - Entry points

    /// Apply the full ordered list. This is the app-wide diagnostic-file
    /// authority; a platform whose diagnostic sink has its own additional
    /// rule table may pass a narrower `patterns` subset and apply the rest
    /// itself.
    public static func redact(
        _ text: String,
        patterns: [Pattern] = orderedPatterns
    ) -> String {
        let requested = Set(patterns)
        var result = text
        for pattern in orderedPatterns where requested.contains(pattern) {
            result = apply(pattern, to: result)
        }
        return result
    }

    /// The mosh-only subset — see `transportDetailPatterns`.
    public static func redactTransportDetail(_ text: String) -> String {
        redact(text, patterns: transportDetailPatterns)
    }

    /// Bounded metadata about a bootstrap transcript that is safe to log in
    /// full: byte counts and whether the credential marker was present at
    /// all. Never the transcript.
    public static func bootstrapTranscriptSummary(
        stdout: String,
        stderr: String
    ) -> String {
        "stdoutBytes=\(stdout.utf8.count) stderrBytes=\(stderr.utf8.count) "
            + "connectMarker=\(containsConnectMarker(stdout) || containsConnectMarker(stderr))"
    }

    // MARK: - Patterns

    private static let moshConnectLineExpression = try! NSRegularExpression(
        pattern: #"(?im)\bMOSH[ \t]+CONNECT(?:[ \t]+[^\r\n]*)?"#
    )
    private static let moshConnectKeyExpression = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{22}(?:==)?(?![A-Za-z0-9+/=])"#
    )
    /// Matches Android's `DiagnosticLogStore` rule verbatim, including the
    /// `:` alternative and the `$1=` normalisation of it.
    private static let credentialAssignmentExpression = try! NSRegularExpression(
        pattern: #"(?i)(password|passphrase|secret|token)[=:][^ ]+"#
    )
    /// A `user@host` identifier, and deliberately nothing else that contains
    /// an `@`.
    ///
    /// tmux names every window `@N`, so the earlier `\S+@\S+` swallowed whole
    /// diagnostic lines — `target=@3`, an escaped `…\t@3\t…` metadata row —
    /// and hid exactly the window identity a tmux report is read for. An
    /// endpoint's local part is a word-ish token that sits on a boundary, so
    /// requiring that (and refusing one that begins right after an escape
    /// backslash) keeps `alice@prod.internal` redacted while leaving a window
    /// id legible.
    private static let endpointIdentifierExpression = try! NSRegularExpression(
        pattern: #"(?<![\w.\-\\])[\w.\-]+@[\w.\-]+"#
    )

    private static func apply(_ pattern: Pattern, to text: String) -> String {
        switch pattern {
        case .moshConnectLine:
            return redactingConnectLines(in: text)
        case .moshConnectKey:
            return replacingMatches(
                of: moshConnectKeyExpression,
                in: text,
                withTemplate: "<redacted-key>"
            )
        case .credentialAssignment:
            return replacingMatches(
                of: credentialAssignmentExpression,
                in: text,
                withTemplate: "$1=<redacted>"
            )
        case .endpointIdentifier:
            return replacingMatches(
                of: endpointIdentifierExpression,
                in: text,
                withTemplate: "<redacted-endpoint>"
            )
        }
    }

    private static func redactingConnectLines(in text: String) -> String {
        let mutable = NSMutableString(string: text)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let matches = moshConnectLineExpression.matches(in: text, range: fullRange)

        // Work backwards so replacing one line cannot invalidate the ranges of
        // earlier matches. A port is retained only after strict decimal/range
        // validation; every malformed tail is treated as credential material.
        for match in matches.reversed() {
            let connectText = mutable.substring(with: match.range)
            let fields = connectText.split(whereSeparator: \Character.isWhitespace)
            let replacement: String
            if fields.count >= 4, isValidMoshPortToken(fields[2]) {
                replacement = "MOSH CONNECT \(fields[2]) <redacted>"
            } else {
                replacement = "MOSH CONNECT <redacted>"
            }
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    private static func replacingMatches(
        of expression: NSRegularExpression,
        in text: String,
        withTemplate template: String
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: template
        )
    }

    private static func containsConnectMarker(_ text: String) -> Bool {
        text.range(of: "MOSH CONNECT", options: [.caseInsensitive]) != nil
    }

    private static func isValidMoshPortToken(_ token: Substring) -> Bool {
        guard !token.isEmpty,
              token.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let port = Int(token),
              (1...65_535).contains(port)
        else { return false }
        return true
    }
}
