import Foundation
import Citadel
import NIOCore

struct MoshBootstrapResult: Equatable, Sendable {
    let udpPort: Int
    let base64Key: String
    let serverPID: Int?
    /// OS family parsed from a side-channel probe run on the bootstrap
    /// SSH client right before it's closed. `nil` when the probe fails
    /// or the parser can't classify the output. Mosh sessions consume
    /// this and republish via `@Published var detectedOSHint`.
    let detectedOSHint: String?
    /// Live destination address and topology actually used by the bootstrap
    /// SSH chain. Mosh's UDP driver and its SSH-fallback policy must use this
    /// snapshot, not the session's potentially stale construction-time Host.
    let targetAddress: String?
    let jumpChainHopCount: Int

    init(
        udpPort: Int,
        base64Key: String,
        serverPID: Int?,
        detectedOSHint: String?,
        targetAddress: String? = nil,
        jumpChainHopCount: Int = 0
    ) {
        self.udpPort = udpPort
        self.base64Key = base64Key
        self.serverPID = serverPID
        self.detectedOSHint = detectedOSHint
        self.targetAddress = targetAddress
        self.jumpChainHopCount = jumpChainHopCount
    }
}

enum MoshBootstrapError: Error, Equatable, LocalizedError, Sendable {
    case authenticationFailed(String)
    case connectionFailed(String)
    case hostKeyRejected
    case missingServer
    case missingConnect
    case malformedConnect
    case remoteCommandFailed(exitCode: Int)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let reason):
            return reason
        case .connectionFailed(let reason):
            return reason
        case .hostKeyRejected:
            return "The server's SSH host key was rejected."
        case .missingServer:
            return "Could not start mosh: the remote host does not have `mosh-server` installed or on PATH."
        case .missingConnect:
            return "Could not start mosh: `mosh-server` never printed a MOSH CONNECT line."
        case .malformedConnect:
            return "Could not start mosh: `mosh-server` printed a malformed MOSH CONNECT line."
        case .remoteCommandFailed(let exitCode):
            return "Could not start mosh: the remote bootstrap command failed with exit status \(exitCode)."
        }
    }
}

/// The single boundary for removing live mosh session credentials from text
/// before it reaches either unified logging or Tessera's diagnostic file.
///
/// Bootstrap parser errors intentionally retain no transcript at all. This
/// remains defense in depth for errors produced below Citadel and for future
/// diagnostic call sites that receive remote command output.
enum SensitiveDataRedactor {
    private static let moshConnectLinePattern = try! NSRegularExpression(
        pattern: #"(?im)\bMOSH[ \t]+CONNECT(?:[ \t]+[^\r\n]*)?"#
    )
    private static let moshKeyPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{22}(?:==)?(?![A-Za-z0-9+/=])"#
    )

    static func redact(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let matches = moshConnectLinePattern.matches(in: text, range: fullRange)

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

        // Defense in depth for exception bridges that contain only the key,
        // and for malformed output that splits CONNECT and its key over lines.
        let connectRedacted = mutable as String
        let redactedRange = NSRange(
            connectRedacted.startIndex..<connectRedacted.endIndex,
            in: connectRedacted
        )
        return moshKeyPattern.stringByReplacingMatches(
            in: connectRedacted,
            range: redactedRange,
            withTemplate: "<redacted-key>"
        )
    }

    static func bootstrapTranscriptSummary(stdout: String, stderr: String) -> String {
        "stdoutBytes=\(stdout.utf8.count) stderrBytes=\(stderr.utf8.count) connectMarker=\(containsConnectMarker(stdout) || containsConnectMarker(stderr))"
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

enum MoshBootstrap {
    typealias SessionNameResolver = (Host) -> String

    static func bootstrap(
        host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false,
        hostKeyPrompt: HostKeyVerificationPrompt? = nil,
        sessionNameResolver: SessionNameResolver = HostRuntimeStateStore.sessionName(for:)
    ) async throws -> MoshBootstrapResult {
        // The bootstrap SSH ride (and only this ride) carries the mosh key
        // exchange; it goes through the shared jump-chain establisher so a
        // bastioned host can still launch mosh-server. The subsequent UDP
        // flow is direct device→host and cannot traverse the chain — the
        // session layer detects unreachable servers and falls back.
        let chain: EstablishedSSHChain
        do {
            chain = try await establishSSHChain(
                for: host,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave,
                hostKeyPrompt: hostKeyPrompt
            )
        } catch {
            throw classifyConnectionError(error)
        }
        let client = chain.client

        do {
            let transcript = try await executeBootstrapCommand(
                bootstrapCommand(
                    for: host,
                    sessionNameResolver: sessionNameResolver
                ),
                on: client
            )
            // Probe the OS family before closing the bootstrap client.
            // Mosh has no SSH transport after this point, so this is the
            // only window we have. Any error returns nil and the result
            // simply lacks a detected hint.
            let detectedOSHint = await OSDetectionProbe.run(on: client)
            await chain.closeAll()
            if transcriptSuggestsMissingServer(transcript) {
                throw MoshBootstrapError.missingServer
            }
            let parsed = try parseConnectResponse(
                stdout: transcript.stdout,
                stderr: transcript.stderr
            )
            return MoshBootstrapResult(
                udpPort: parsed.udpPort,
                base64Key: parsed.base64Key,
                serverPID: parsed.serverPID,
                detectedOSHint: detectedOSHint,
                targetAddress: chain.resolvedHost.address,
                jumpChainHopCount: chain.resolvedHost.jumpChain.count
            )
        } catch let error as RemoteCommandFailure {
            await chain.closeAll()
            let transcriptSummary = SensitiveDataRedactor.bootstrapTranscriptSummary(
                stdout: error.transcript.stdout,
                stderr: error.transcript.stderr
            )
            MoshDiagnostics.log(
                "bootstrap remote-command failed exit=\(error.exitCode) transcript=\(transcriptSummary)"
            )
            if transcriptSuggestsMissingServer(error.transcript) {
                throw MoshBootstrapError.missingServer
            }
            throw MoshBootstrapError.remoteCommandFailed(
                exitCode: error.exitCode
            )
        } catch let error as BootstrapCommandFailure {
            await chain.closeAll()
            let transcriptSummary = SensitiveDataRedactor.bootstrapTranscriptSummary(
                stdout: error.transcript.stdout,
                stderr: error.transcript.stderr
            )
            MoshDiagnostics.log(
                "bootstrap command failed type=\(String(describing: type(of: error.underlying))) detail=\(SensitiveDataRedactor.redact(String(describing: error.underlying))) transcript=\(transcriptSummary)"
            )
            if transcriptSuggestsMissingServer(error.transcript) {
                throw MoshBootstrapError.missingServer
            }
            throw MoshBootstrapError.connectionFailed(
                MoshSession.userFacingStartupFailureMessage(
                    from: SensitiveDataRedactor.redact(describeSSHError(error.underlying))
                )
            )
        } catch let error as MoshBootstrapError {
            await chain.closeAll()
            throw error
        } catch {
            await chain.closeAll()
            MoshDiagnostics.log(
                "bootstrap exec-phase failed type=\(String(describing: type(of: error))) detail=\(SensitiveDataRedactor.redact(String(describing: error)))"
            )
            throw MoshBootstrapError.connectionFailed(
                MoshSession.userFacingStartupFailureMessage(
                    from: SensitiveDataRedactor.redact(describeSSHError(error))
                )
            )
        }
    }

    static func bootstrapCommand(
        for host: Host,
        sessionNameResolver: SessionNameResolver = HostRuntimeStateStore.sessionName(for:)
    ) -> String {
        if let command = launchCommand(for: host, sessionNameResolver: sessionNameResolver) {
            return "mosh-server new -- \(command)"
        }
        return "mosh-server new"
    }

    static func launchCommand(
        for host: Host,
        sessionNameResolver: SessionNameResolver = HostRuntimeStateStore.sessionName(for:)
    ) -> String? {
        let prologue = HostLaunchPrologue.inlineForArgv(
            envVars: host.envVars,
            startupSnippet: host.startupSnippet
        )

        switch host.launchMode {
        case .autoTmux:
            let inner = tmuxLaunchCommand(sessionName: sessionNameResolver(host))
            return wrap(inner: inner, prologue: prologue)

        case .pinnedTmux:
            let sessionName = resolvedTmuxSessionName(
                for: host,
                sessionNameResolver: sessionNameResolver
            ) ?? sessionNameResolver(host)
            let inner = tmuxLaunchCommand(sessionName: sessionName)
            return wrap(inner: inner, prologue: prologue)

        case .customCommand:
            let command = host.launchCommand ?? ""
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Fallback: no launch command, but the user asked for
                // exports / startup snippet — pass them through `sh -lc`
                // so mosh still has *something* to exec.
                guard let prologue else { return nil }
                let body = prologue + "exec $SHELL -l"
                return "sh -lc \(singleQuotedShellString(body))"
            }
            // The custom-command path was already wrapped in `sh -lc`;
            // splice the prologue inside the same single-quoted argv
            // so user exports run before the custom command.
            let body = (prologue ?? "") + command
            return "sh -lc \(singleQuotedShellString(body))"
        }
    }

    /// Wrap a tmux launch command in `sh -lc` only when there's a
    /// prologue to inject; otherwise return the bare command so
    /// `mosh-server new -- tmux ...` keeps the existing argv shape.
    private static func wrap(inner: String, prologue: String?) -> String {
        guard let prologue else { return inner }
        let body = prologue + "exec " + inner
        return "sh -lc \(singleQuotedShellString(body))"
    }

    private static func tmuxLaunchCommand(sessionName: String) -> String {
        "tmux -u new-session -A -s \(sessionName) \\; set-option -t \(sessionName) status off"
    }

    static func resolvedTmuxSessionName(
        for host: Host,
        sessionNameResolver: SessionNameResolver = HostRuntimeStateStore.sessionName(for:)
    ) -> String? {
        switch host.launchMode {
        case .autoTmux:
            return sessionNameResolver(host)

        case .pinnedTmux:
            let trimmed = host.tmuxSessionName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return isShellSafeSessionName(trimmed)
                ? trimmed
                : sessionNameResolver(host)

        case .customCommand:
            return nil
        }
    }

    static func parseConnectResponse(
        stdout: String,
        stderr: String = ""
    ) throws -> MoshBootstrapResult {
        let combinedOutput = combinedBootstrapOutput(stdout: stdout, stderr: stderr)
        let serverPID = detachedServerPID(from: combinedOutput)
        var sawMalformedLine = false

        for rawLine in combinedOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("MOSH CONNECT ") else { continue }

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

            return MoshBootstrapResult(
                udpPort: port,
                base64Key: key,
                serverPID: serverPID,
                detectedOSHint: nil
            )
        }

        if sawMalformedLine {
            throw MoshBootstrapError.malformedConnect
        }
        throw MoshBootstrapError.missingConnect
    }

    private static func classifyConnectionError(_ error: Error) -> MoshBootstrapError {
        MoshDiagnostics.log(
            "bootstrap connect-phase failed type=\(String(describing: type(of: error))) detail=\(SensitiveDataRedactor.redact(String(describing: error)))"
        )
        // Unwrap hop-attributed failures so per-kind handling (host key,
        // auth, retry classification) still applies; keep the hop label on
        // message cases.
        if let hopError = error as? SSHChainHopError {
            let classified = classifyConnectionError(hopError.underlying)
            switch classified {
            case .authenticationFailed(let message):
                return .authenticationFailed("Jump host \(hopError.hopLabel): \(message)")
            case .connectionFailed(let message):
                return .connectionFailed("Jump host \(hopError.hopLabel): \(message)")
            default:
                return classified
            }
        }
        switch error {
        case is HostKeyRejectedError:
            return .hostKeyRejected

        case let error as AuthResolutionError:
            return .authenticationFailed(
                SensitiveDataRedactor.redact(error.errorDescription ?? describeSSHError(error))
            )

        case is AuthenticationFailed:
            return .authenticationFailed("Authentication failed.")

        case let error as SSHClientError:
            switch error {
            case .unsupportedPasswordAuthentication:
                return .authenticationFailed("The server does not accept password authentication.")
            case .unsupportedPrivateKeyAuthentication:
                return .authenticationFailed("The server does not accept public-key authentication.")
            case .unsupportedHostBasedAuthentication:
                return .authenticationFailed("The server does not accept host-based authentication.")
            case .allAuthenticationOptionsFailed:
                return .authenticationFailed("Authentication failed.")
            case .channelCreationFailed:
                return .connectionFailed("Failed to open the SSH exec channel.")
            }

        case let error as CitadelError:
            switch error {
            case .unauthorized:
                return .authenticationFailed("Authentication failed.")
            default:
                return .connectionFailed(SensitiveDataRedactor.redact(describeSSHError(error)))
            }

        default:
            return .connectionFailed(SensitiveDataRedactor.redact(describeSSHError(error)))
        }
    }

    private static func isShellSafeSessionName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func singleQuotedShellString(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func normalizedConnectKey(_ rawKey: String) -> String? {
        let candidate: Substring
        if rawKey.hasSuffix("==") {
            candidate = rawKey.dropLast(2)
        } else {
            candidate = Substring(rawKey)
        }

        guard candidate.count == 22 else { return nil }

        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/"
        )
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }

        return String(candidate)
    }

    private static func combinedBootstrapOutput(
        stdout: String,
        stderr: String
    ) -> String {
        guard !stderr.isEmpty else { return stdout }
        guard !stdout.isEmpty else { return stderr }
        return "\(stdout)\n\(stderr)"
    }

    private static func detachedServerPID(from output: String) -> Int? {
        let prefix = "[mosh-server detached, pid = "

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(prefix), line.hasSuffix("]") else { continue }

            let pidStart = line.index(line.startIndex, offsetBy: prefix.count)
            let pidEnd = line.index(before: line.endIndex)
            let pidText = line[pidStart..<pidEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = Int(pidText), pid > 0 else { continue }
            return pid
        }

        return nil
    }

    private static func transcriptSuggestsMissingServer(
        _ transcript: CommandTranscript
    ) -> Bool {
        let combined = "\(transcript.stderr)\n\(transcript.stdout)".lowercased()
        guard combined.contains("mosh-server") else { return false }
        return combined.contains("not found")
            || combined.contains("command not found")
            || combined.contains("no such file")
    }

    private static func executeBootstrapCommand(
        _ command: String,
        on client: SSHClient
    ) async throws -> CommandTranscript {
        let streams = try await client.executeCommandPair(command)

        async let stdoutResult = collectBootstrapStream(streams.stdout)
        async let stderrResult = collectBootstrapStream(streams.stderr)

        let (stdout, stdoutError) = await stdoutResult
        let (stderr, stderrError) = await stderrResult
        let transcript = CommandTranscript(
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )

        if let error = firstBootstrapStreamError(
            stdoutError: stdoutError,
            stderrError: stderrError
        ) {
            if let error = error as? SSHClient.CommandFailed {
                throw RemoteCommandFailure(
                    exitCode: error.exitCode,
                    transcript: transcript
                )
            }
            throw BootstrapCommandFailure(
                underlying: error,
                transcript: transcript
            )
        }
        return transcript
    }

    private static func collectBootstrapStream(
        _ stream: AsyncThrowingStream<ByteBuffer, Error>
    ) async -> (Data, Error?) {
        var data = Data()
        do {
            for try await buffer in stream {
                append(buffer, to: &data)
            }
            return (data, nil)
        } catch {
            return (data, error)
        }
    }

    private static func firstBootstrapStreamError(
        stdoutError: Error?,
        stderrError: Error?
    ) -> Error? {
        if let commandFailed = stdoutError as? SSHClient.CommandFailed {
            return commandFailed
        }
        if let commandFailed = stderrError as? SSHClient.CommandFailed {
            return commandFailed
        }
        return stdoutError ?? stderrError
    }

    private static func append(_ buffer: ByteBuffer, to data: inout Data) {
        var buffer = buffer
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            data.append(contentsOf: bytes)
        }
    }
}

private struct CommandTranscript: Equatable, Sendable {
    let stdout: String
    let stderr: String
}

private struct RemoteCommandFailure: Error {
    let exitCode: Int
    let transcript: CommandTranscript
}

private struct BootstrapCommandFailure: Error {
    let underlying: Error
    let transcript: CommandTranscript
}
