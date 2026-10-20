import Foundation
import TesseraSessionCore

/// The mosh bootstrap seam plus the app-wide diagnostic redaction authority.
///
/// The grammar rules here are the strict ones (a literal `"MOSH CONNECT "`
/// prefix, exactly four fields), which is a deliberate tightening for Android:
/// its earlier lenient whitespace split also accepted `MOSH\tCONNECT`, a shape
/// mosh-server never emits, and every extra shape accepted only widens what a
/// garbled or hostile transcript can talk Tessera into dialling.
///
/// Nothing here ever returns a transcript. `parseConnectResponse` deliberately
/// discards the text on failure, because a malformed `MOSH CONNECT` line may
/// still carry live key material.

/// The result of reading a `mosh-server new` transcript.
///
/// ```json
/// {"credentials":{"base64Key":"…","serverPID":4321,"udpPort":60001},"ok":true}
/// ```
/// or
/// ```json
/// {"failure":"missingServer","ok":false}
/// ```
/// `failure` is `missingServer` (the remote shell could not find
/// `mosh-server`) | `missingConnect` (no `MOSH CONNECT` line at all) |
/// `malformedConnect` (a line was present but its port or key is unusable).
/// The distinction matters: malformed means the server ran and we cannot trust
/// what it said, missing usually means something else ate the channel.
public struct MoshConnectABIResponse: Codable, Equatable, Sendable {
    public struct Credentials: Codable, Equatable, Sendable {
        public var udpPort: Int
        public var base64Key: String
        /// From mosh-server's own `[mosh-server detached, pid = N]` banner.
        /// Null whenever the banner is absent or unparseable — a caller must
        /// treat a missing PID as "cannot safely signal the server".
        public var serverPID: Int?
    }

    public enum Failure: String, Codable, Sendable {
        case missingServer, missingConnect, malformedConnect
    }

    public var ok: Bool
    public var credentials: Credentials?
    public var failure: Failure?
}

/// Parses a bootstrap transcript into credentials or a classified failure.
///
/// Both streams are supplied because mosh-server prints `MOSH CONNECT` on
/// either one depending on the remote shell; the parser reads one combined
/// view. Returns the byte count under the string contract, or -1 for invalid
/// arguments. A parse failure is a successful call with `ok: false`, not -1 —
/// the classification is the answer.
@_cdecl("tessera_mosh_parse_connect_response")
public func tesseraMoshParseConnectResponse(
    stdoutBytes: UnsafePointer<UInt8>?,
    stdoutCount: Int,
    stderrBytes: UnsafePointer<UInt8>?,
    stderrCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard case let .some(standardOutput) = SharedABI.optionalString(stdoutBytes, stdoutCount),
          case let .some(standardError) = SharedABI.optionalString(stderrBytes, stderrCount)
    else { return -1 }

    let response: MoshConnectABIResponse
    do {
        // "mosh-server isn't installed" is checked FIRST, matching the iOS
        // call site: the grammar itself only reports missing-vs-malformed
        // connect lines, and a transcript whose shell could not find the
        // binary would otherwise be reported as `missingConnect` — the one
        // failure that has a useful remedy, described as the one that does
        // not.
        guard !MoshBootstrapGrammar.transcriptSuggestsMissingServer(
            stdout: standardOutput ?? "",
            stderr: standardError ?? ""
        ) else {
            return SharedABI.copyOutJSON(
                MoshConnectABIResponse(ok: false, credentials: nil, failure: .missingServer),
                outputBytes,
                outputCapacity
            )
        }
        let credentials = try MoshBootstrapGrammar.parseConnectResponse(
            stdout: standardOutput ?? "",
            stderr: standardError ?? ""
        )
        response = MoshConnectABIResponse(
            ok: true,
            credentials: .init(
                udpPort: credentials.udpPort,
                base64Key: credentials.base64Key,
                serverPID: credentials.serverPID
            ),
            failure: nil
        )
    } catch let failure as MoshBootstrapGrammarFailure {
        let classified: MoshConnectABIResponse.Failure
        switch failure {
        case .missingServer: classified = .missingServer
        case .missingConnect: classified = .missingConnect
        case .malformedConnect: classified = .malformedConnect
        }
        response = MoshConnectABIResponse(ok: false, credentials: nil, failure: classified)
    } catch {
        return -1
    }
    return SharedABI.copyOutJSON(response, outputBytes, outputCapacity)
}

/// `mosh-server new`, with the optional trailing `-- <argv>` the launch mode
/// asked for. An all-whitespace launch command is treated as absent, so a
/// misconfigured host still gets a plain login shell. A zero-length argument
/// means no launch command. Returns the byte count under the string contract.
@_cdecl("tessera_mosh_server_new_command")
public func tesseraMoshServerNewCommand(
    launchCommandBytes: UnsafePointer<UInt8>?,
    launchCommandCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard case let .some(launchCommand) = SharedABI.optionalString(
        launchCommandBytes,
        launchCommandCount,
        maximum: 65_536
    ) else { return -1 }
    return SharedABI.copyOut(
        MoshBootstrapGrammar.serverNewCommand(launchCommand: launchCommand),
        outputBytes,
        outputCapacity
    )
}

/// The PID-reuse-fenced server termination script.
///
/// The PID comes from mosh-server's detached banner and may be arbitrarily
/// stale by the time anything wants the server gone, so the script re-checks
/// `ps -o comm=` for `*mosh-server*` immediately before signalling, treats an
/// already-exited server as success, and never escalates past `TERM`. Exit
/// codes: 0 server gone (or never there), 64 the PID is alive but is not a
/// mosh-server.
///
/// Returns the byte count under the string contract, or -1 for a non-positive
/// PID.
@_cdecl("tessera_mosh_server_termination_script")
public func tesseraMoshServerTerminationScript(
    pid: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard pid > 0 else { return -1 }
    return SharedABI.copyOut(
        MoshBootstrapGrammar.makeServerTerminationScript(pid: Int(pid)),
        outputBytes,
        outputCapacity
    )
}

/// The read-only liveness probe for a session's detached mosh-server: prints
/// `TESSERA_MOSH_SERVER=alive`, `=gone` or `=unknown` and never signals the
/// process. A PID that cannot be signalled or that now runs something else is
/// `gone`; a host whose `ps` cannot name the process is `unknown`.
///
/// Returns the byte count under the string contract, or -1 for a non-positive
/// PID.
@_cdecl("tessera_mosh_server_liveness_script")
public func tesseraMoshServerLivenessScript(
    pid: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard pid > 0 else { return -1 }
    return SharedABI.copyOut(
        MoshBootstrapGrammar.makeServerLivenessScript(pid: Int(pid)),
        outputBytes,
        outputCapacity
    )
}

/// Read a liveness probe's output: 1 alive, 2 gone, 0 unknown (no exact
/// marker line, which is never evidence of loss), -1 invalid arguments.
@_cdecl("tessera_mosh_server_liveness_verdict")
public func tesseraMoshServerLivenessVerdict(
    outputInputBytes: UnsafePointer<UInt8>?,
    outputInputCount: Int
) -> Int32 {
    guard case let .some(output) = SharedABI.optionalString(
        outputInputBytes,
        outputInputCount,
        maximum: 65_536
    ) else { return -1 }
    switch MoshBootstrapGrammar.parseServerLiveness(output ?? "") {
    case .unknown: return 0
    case .alive: return 1
    case .gone: return 2
    }
}

/// How long mosh must stay unreachable in the foreground before the first
/// liveness probe, in milliseconds.
@_cdecl("tessera_mosh_server_liveness_grace_milliseconds")
public func tesseraMoshServerLivenessGraceMilliseconds() -> UInt64 {
    UInt64((MoshServerLivenessPolicy.unreachableGraceSeconds * 1_000).rounded())
}

/// When the next liveness probe runs, in milliseconds: -1 when none follows
/// (the server is gone, or the arguments are invalid), -2 when it waits for a
/// wake only (network path change, return to the foreground, unlock), else
/// the delay. `outcome` is 0 unknown, 1 alive, 2 gone, 3 host unreachable (SSH
/// failed, so the script never ran); `consecutiveHostFailures` counts the
/// current run of host-unreachable outcomes, this one included; `askedOwner`
/// is nonzero when this probe put an owner-authentication prompt in front of
/// the user.
@_cdecl("tessera_mosh_server_liveness_next_probe_milliseconds")
public func tesseraMoshServerLivenessNextProbeMilliseconds(
    outcome: Int32,
    consecutiveHostFailures: Int32,
    askedOwner: Int32
) -> Int64 {
    let decoded: MoshServerLivenessPolicy.Outcome
    switch outcome {
    case 0: decoded = .unknown
    case 1: decoded = .alive
    case 2: decoded = .gone
    case 3: decoded = .hostUnreachable
    default: return -1
    }
    switch MoshServerLivenessPolicy.nextProbe(
        after: decoded,
        consecutiveHostFailures: Int(consecutiveHostFailures),
        askedOwner: askedOwner != 0
    ) {
    case .none: return -1
    case .onWake: return -2
    case .after(let seconds): return Int64((seconds * 1_000).rounded())
    }
}

/// Whether a transcript says `mosh-server` is not installed, as opposed to
/// saying the bootstrap failed — only the former has a useful remedy. Both
/// markers must be present. Returns 1, 0, or -1 for invalid arguments.
@_cdecl("tessera_mosh_transcript_suggests_missing_server")
public func tesseraMoshTranscriptSuggestsMissingServer(
    stdoutBytes: UnsafePointer<UInt8>?,
    stdoutCount: Int,
    stderrBytes: UnsafePointer<UInt8>?,
    stderrCount: Int
) -> Int32 {
    guard case let .some(standardOutput) = SharedABI.optionalString(stdoutBytes, stdoutCount),
          case let .some(standardError) = SharedABI.optionalString(stderrBytes, stderrCount)
    else { return -1 }
    return MoshBootstrapGrammar.transcriptSuggestsMissingServer(
        stdout: standardOutput ?? "",
        stderr: standardError ?? ""
    ) ? 1 : 0
}

/// The PID from `[mosh-server detached, pid = N]`, or 0 when the banner is
/// absent or unparseable. -1 for invalid arguments.
///
/// 0 is the "no PID" answer rather than an error because a transcript without
/// the banner is ordinary; the caller must then treat the server as
/// un-signallable.
@_cdecl("tessera_mosh_detached_server_pid")
public func tesseraMoshDetachedServerPID(
    outputInputBytes: UnsafePointer<UInt8>?,
    outputInputCount: Int
) -> Int32 {
    guard let output = SharedABI.requiredString(outputInputBytes, outputInputCount)
    else { return -1 }
    guard let pid = MoshBootstrapGrammar.detachedServerPID(from: output),
          pid > 0, pid <= Int(Int32.max)
    else { return 0 }
    return Int32(pid)
}

/// The canonical 22-character form of a `MOSH CONNECT` key (padding stripped,
/// alphabet checked). Returns the byte count under the string contract, or -1
/// when the key is not usable.
@_cdecl("tessera_mosh_normalized_connect_key")
public func tesseraMoshNormalizedConnectKey(
    keyBytes: UnsafePointer<UInt8>?,
    keyCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let raw = SharedABI.requiredString(keyBytes, keyCount, maximum: 256),
          let normalized = MoshBootstrapGrammar.normalizedConnectKey(raw)
    else { return -1 }
    return SharedABI.copyOut(normalized, outputBytes, outputCapacity)
}

// MARK: - Redaction

/// Removes secrets from text bound for a log or the on-device diagnostic file.
///
/// `patternsBytes` is an optional JSON array of pattern names —
/// `["moshConnectLine","moshConnectKey","credentialAssignment",
/// "endpointIdentifier"]` — selecting a subset; omit it (zero length) for the
/// full ordered list. The *applied* order is always the core's, never the
/// caller's argument order: the `MOSH CONNECT` line scrub must run before the
/// bare-key scrub so a well-formed line keeps its validated port for
/// diagnosis, and the key scrub then catches split or exception-bridged key
/// material the line scrub could not see.
///
/// Returns the byte count under the string contract, or -1 for invalid
/// arguments or an unknown pattern name.
@_cdecl("tessera_redact_sensitive")
public func tesseraRedactSensitive(
    textBytes: UnsafePointer<UInt8>?,
    textCount: Int,
    patternsBytes: UnsafePointer<UInt8>?,
    patternsCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let text = SharedABI.requiredString(textBytes, textCount) else { return -1 }

    var patterns = SensitiveDataRedaction.orderedPatterns
    if patternsBytes != nil, patternsCount > 0 {
        guard let names = SharedABI.decode(
            [String].self,
            patternsBytes,
            patternsCount,
            maximum: 1_024
        ) else { return -1 }
        var selected: [SensitiveDataRedaction.Pattern] = []
        for name in names {
            guard let pattern = SensitiveDataRedaction.Pattern(rawValue: name) else { return -1 }
            selected.append(pattern)
        }
        patterns = selected
    }

    let redacted = SensitiveDataRedaction.redact(text, patterns: patterns)
    // An empty result is unreadable through the string contract's length
    // query; a caller asking to redact whitespace-only text gets it back
    // unchanged anyway, so this can only fire on genuinely empty input, which
    // `requiredString` already rejected.
    return SharedABI.copyOut(redacted, outputBytes, outputCapacity)
}

/// Bounded metadata about a bootstrap transcript that is safe to log in full:
/// byte counts and whether the credential marker was present at all. Never the
/// transcript. Returns the byte count under the string contract.
@_cdecl("tessera_mosh_bootstrap_transcript_summary")
public func tesseraMoshBootstrapTranscriptSummary(
    stdoutBytes: UnsafePointer<UInt8>?,
    stdoutCount: Int,
    stderrBytes: UnsafePointer<UInt8>?,
    stderrCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard case let .some(standardOutput) = SharedABI.optionalString(stdoutBytes, stdoutCount),
          case let .some(standardError) = SharedABI.optionalString(stderrBytes, stderrCount)
    else { return -1 }
    return SharedABI.copyOut(
        SensitiveDataRedaction.bootstrapTranscriptSummary(
            stdout: standardOutput ?? "",
            stderr: standardError ?? ""
        ),
        outputBytes,
        outputCapacity
    )
}
