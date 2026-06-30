import Foundation
import Citadel
import NIOCore

enum RemoteAuthorizedKeysInstaller {
    enum InstallError: LocalizedError, Equatable, Sendable {
        case authentication(String)
        case network(String)
        case hostKeyRejected
        case selfInstall
        case remoteCommandFailed(stderr: String)
        case verificationFailed(stderr: String)

        var errorDescription: String? {
            switch self {
            case .authentication(let message):
                return message.isEmpty ? "Authentication failed" : message
            case .network(let message):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return "Network unreachable" }
                return "Network unreachable: \(trimmed)"
            case .hostKeyRejected:
                return "Host key was not trusted. Connect once first to review it, then retry."
            case .selfInstall:
                return "This host uses this key for authentication. Choose a host identity that uses a different key or password."
            case .remoteCommandFailed(let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return "Could not write to ~/.ssh/authorized_keys"
                }
                return "Could not write to ~/.ssh/authorized_keys: \(trimmed)"
            case .verificationFailed(let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return "Could not verify ~/.ssh/authorized_keys"
                }
                return "Could not verify ~/.ssh/authorized_keys: \(trimmed)"
            }
        }
    }

    private static let verificationMarker = "TESSERA_KEY_INSTALLED"

    static func install(key: StoredKey, on host: Host) async throws {
        try await install(line: key.authorizedKeysLine, keyID: key.id, on: host)
    }

    static func install(
        line authorizedKeysLine: String,
        keyID: UUID,
        on host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false
    ) async throws {
        DiagnosticLogStore.appendKeys(
            "install begin key=\(shortID(keyID)) host=\(shortID(host.id)) authKind=\(authKindDescription(for: host, isSecureEnclave: isSecureEnclave)) biometricRequired=\(requireBiometric)"
        )
        do {
            try validateCanInstall(keyID: keyID, on: host)
        } catch {
            DiagnosticLogStore.appendKeys("install rejected key=\(shortID(keyID)) host=\(shortID(host.id)) reason=self-install")
            throw error
        }
        try await install(
            line: authorizedKeysLine,
            on: host,
            requireBiometric: requireBiometric,
            isSecureEnclave: isSecureEnclave
        )
    }

    static func install(
        line authorizedKeysLine: String,
        on host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false
    ) async throws {
        let startedAt = Date()
        let authMethod: SSHAuthenticationMethod
        do {
            DiagnosticLogStore.appendKeys("install step=auth-resolve host=\(shortID(host.id))")
            authMethod = try await resolveSSHAuthMethod(
                for: host,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave
            )
        } catch {
            DiagnosticLogStore.appendKeys(
                "install failed step=auth-resolve host=\(shortID(host.id)) durationMs=\(durationMs(since: startedAt)) error='\(error)'"
            )
            throw classifyConnectionError(error)
        }

        let endpoint = "\(host.address):\(host.port)"
        let validator = TesseraHostKeyValidator(endpoint: endpoint, prompt: nil)

        let client: SSHClient
        do {
            DiagnosticLogStore.appendKeys("install step=connect host=\(shortID(host.id)) port=\(host.port)")
            client = try await SSHClient.connect(
                host: host.address,
                port: host.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
        } catch {
            DiagnosticLogStore.appendKeys(
                "install failed step=connect host=\(shortID(host.id)) durationMs=\(durationMs(since: startedAt)) error='\(error)'"
            )
            throw classifyConnectionError(error)
        }

        do {
            DiagnosticLogStore.appendKeys("install step=append-key host=\(shortID(host.id))")
            _ = try await execute(
                makeInstallCommand(line: authorizedKeysLine),
                on: client
            )
        } catch {
            try? await client.close()
            DiagnosticLogStore.appendKeys(
                "install failed step=append-key host=\(shortID(host.id)) durationMs=\(durationMs(since: startedAt)) error='\(error)'"
            )
            throw InstallError.remoteCommandFailed(
                stderr: commandFailureMessage(error)
            )
        }

        let verificationOutput: String
        do {
            DiagnosticLogStore.appendKeys("install step=verify host=\(shortID(host.id))")
            verificationOutput = try await execute(
                makeVerifyCommand(line: authorizedKeysLine),
                on: client
            )
        } catch {
            try? await client.close()
            DiagnosticLogStore.appendKeys(
                "install failed step=verify host=\(shortID(host.id)) durationMs=\(durationMs(since: startedAt)) error='\(error)'"
            )
            throw InstallError.verificationFailed(
                stderr: commandFailureMessage(error)
            )
        }

        try? await client.close()

        guard verificationOutput.contains(verificationMarker) else {
            DiagnosticLogStore.appendKeys(
                "install failed step=verify-marker host=\(shortID(host.id)) durationMs=\(durationMs(since: startedAt)) outputBytes=\(verificationOutput.utf8.count)"
            )
            throw InstallError.verificationFailed(stderr: verificationOutput)
        }
        DiagnosticLogStore.appendKeys(
            "install result=success host=\(shortID(host.id)) durationMs=\(durationMs(since: startedAt))"
        )
    }

    /// Idempotent install. The `{ grep || echo; }` group is load-bearing:
    /// without the braces, bash parses `A && B && C && grep || echo` as
    /// `((A && B && C && grep) || echo)` (left-to-right associativity of
    /// equal-precedence && / ||), so a failed mkdir/touch/chmod would
    /// still trigger the `echo` and append into a broken state. Grouping
    /// the idempotency check requires the prep chain first, then runs
    /// the `grep || echo` pair as a single conditional unit.
    static func makeInstallCommand(line: String) -> String {
        let quotedLine = singleQuotedShellString(line)
        return "mkdir -m 700 -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && { grep -qxF \(quotedLine) ~/.ssh/authorized_keys || echo \(quotedLine) >> ~/.ssh/authorized_keys; }"
    }

    /// Verification command. The marker pair (`TESSERA_KEY_INSTALLED` /
    /// `TESSERA_KEY_MISSING`) is wrapped in an `if/then/else` rather
    /// than `&& A || B` so an unrelated failure of the success-branch
    /// echo cannot silently fall through to the missing-marker path.
    static func makeVerifyCommand(line: String) -> String {
        let quotedLine = singleQuotedShellString(line)
        return "if grep -qxF \(quotedLine) ~/.ssh/authorized_keys; then echo \(verificationMarker); else echo TESSERA_KEY_MISSING; fi"
    }

    static func singleQuotedShellString(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    static func validateCanInstall(keyID: UUID, on host: Host) throws {
        guard host.storedKeyID != keyID else {
            throw InstallError.selfInstall
        }
    }

    private static func execute(_ command: String, on client: SSHClient) async throws -> String {
        var output = try await client.executeCommand(
            command,
            maxResponseSize: 64 * 1024,
            mergeStreams: true,
            inShell: true
        )
        let bytes = output.readBytes(length: output.readableBytes) ?? []
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func classifyConnectionError(_ error: Error) -> InstallError {
        switch error {
        case is HostKeyRejectedError:
            return .hostKeyRejected

        case let error as AuthResolutionError:
            return .authentication(error.errorDescription ?? "Authentication failed")

        case is AuthenticationFailed:
            return .authentication("Authentication failed")

        case let error as SSHClientError:
            switch error {
            case .unsupportedPasswordAuthentication:
                return .authentication("The server does not accept password authentication.")
            case .unsupportedPrivateKeyAuthentication:
                return .authentication("The server does not accept public-key authentication.")
            case .unsupportedHostBasedAuthentication:
                return .authentication("The server does not accept host-based authentication.")
            case .allAuthenticationOptionsFailed:
                return .authentication("Authentication failed")
            case .channelCreationFailed:
                return .network("Failed to open the SSH exec channel.")
            }

        case let error as CitadelError:
            switch error {
            case .unauthorized:
                return .authentication("Authentication failed")
            default:
                return .network(describeSSHError(error))
            }

        default:
            return .network(describeSSHError(error))
        }
    }

    private static func commandFailureMessage(_ error: Error) -> String {
        if let commandFailed = error as? SSHClient.CommandFailed {
            return "Remote command failed with exit status \(commandFailed.exitCode)."
        }
        return describeSSHError(error)
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private static func durationMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    private static func authKindDescription(for host: Host, isSecureEnclave: Bool) -> String {
        if isSecureEnclave {
            return "secure-enclave"
        }
        if host.storedKeyID != nil {
            return "key"
        }
        if !host.password.isEmpty {
            return "password"
        }
        return "unknown"
    }
}
