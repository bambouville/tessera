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
}

enum MoshBootstrapError: Error, Equatable, LocalizedError, Sendable {
    case authenticationFailed(String)
    case connectionFailed(String)
    case hostKeyRejected
    case missingServer(stderr: String)
    case missingConnect(stdout: String)
    case malformedConnect(stdout: String)
    case remoteCommandFailed(exitCode: Int, stderr: String)

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
        case .remoteCommandFailed(let exitCode, _):
            return "Could not start mosh: the remote bootstrap command failed with exit status \(exitCode)."
        }
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
        let authMethod: SSHAuthenticationMethod
        do {
            authMethod = try await resolveSSHAuthMethod(
                for: host,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave
            )
        } catch {
            throw classifyConnectionError(error)
        }

        let endpoint = "\(host.address):\(host.port)"
        let validator = TesseraHostKeyValidator(
            endpoint: endpoint,
            prompt: hostKeyPrompt
        )

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: host.address,
                port: host.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
        } catch {
            throw classifyConnectionError(error)
        }

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
            try? await client.close()
            if transcriptSuggestsMissingServer(transcript) {
                throw MoshBootstrapError.missingServer(stderr: transcript.stderr)
            }
            let parsed = try parseConnectResponse(
                stdout: transcript.stdout,
                stderr: transcript.stderr
            )
            return MoshBootstrapResult(
                udpPort: parsed.udpPort,
                base64Key: parsed.base64Key,
                serverPID: parsed.serverPID,
                detectedOSHint: detectedOSHint
            )
        } catch let error as RemoteCommandFailure {
            try? await client.close()
            if transcriptSuggestsMissingServer(error.transcript) {
                throw MoshBootstrapError.missingServer(stderr: error.transcript.stderr)
            }
            throw MoshBootstrapError.remoteCommandFailed(
                exitCode: error.exitCode,
                stderr: error.transcript.stderr
            )
        } catch let error as BootstrapCommandFailure {
            try? await client.close()
            if transcriptSuggestsMissingServer(error.transcript) {
                throw MoshBootstrapError.missingServer(stderr: error.transcript.stderr)
            }
            throw MoshBootstrapError.connectionFailed(
                MoshSession.userFacingStartupFailureMessage(
                    from: describeSSHError(error.underlying)
                )
            )
        } catch let error as MoshBootstrapError {
            try? await client.close()
            throw error
        } catch {
            try? await client.close()
            throw MoshBootstrapError.connectionFailed(
                MoshSession.userFacingStartupFailureMessage(
                    from: describeSSHError(error)
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
            throw MoshBootstrapError.malformedConnect(
                stdout: combinedOutput
            )
        }
        throw MoshBootstrapError.missingConnect(
            stdout: combinedOutput
        )
    }

    private static func classifyConnectionError(_ error: Error) -> MoshBootstrapError {
        switch error {
        case is HostKeyRejectedError:
            return .hostKeyRejected

        case let error as AuthResolutionError:
            return .authenticationFailed(error.errorDescription ?? describeSSHError(error))

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
                return .connectionFailed(describeSSHError(error))
            }

        default:
            return .connectionFailed(describeSSHError(error))
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
