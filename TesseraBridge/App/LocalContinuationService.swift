import AppKit
import Foundation
import TesseraBridgeCore

struct LocalContinuationResult: Sendable {
    let sessionName: String
    let sessionID: String
    let matchedByStableHostID: Bool
}

enum LocalContinuationServiceError: Error, LocalizedError {
    case remoteHost
    case rejected(MacLocalContinuationRejection)
    case tmuxUnavailable
    case tmuxSessionUnavailable(String)
    case invalidTmuxResponse
    case iTermUnavailable
    case attachScriptUnavailable
    case iTermLaunchFailed(String)
    case iTermAttachUnverified
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .remoteHost:
            "This session belongs to another host. Remote iTerm2 continuation is not available yet."
        case .rejected(.localUserMismatch):
            "The incoming session names this Mac but uses a different local account."
        case .rejected(.localHostKeyMismatch):
            "The incoming session looks local, but its SSH host-key hint does not match this Mac."
        case .rejected(.localRouteUnsupported):
            "A continuation targeting this Mac cannot include a bastion route."
        case .rejected(.localSessionMissing):
            "The incoming continuation does not identify an exact tmux session."
        case .tmuxUnavailable:
            "tmux was not found in /opt/homebrew/bin or /usr/local/bin."
        case .tmuxSessionUnavailable(let name):
            "The local tmux session “\(name)” is not available."
        case .invalidTmuxResponse:
            "tmux returned an invalid session identity."
        case .iTermUnavailable:
            "iTerm2 is not installed."
        case .attachScriptUnavailable:
            "The Tessera iTerm2 attach integration is missing from the Bridge bundle."
        case .iTermLaunchFailed(let detail):
            "iTerm2 could not open the session: \(detail)"
        case .iTermAttachUnverified:
            "iTerm2 launched, but Bridge could not verify a new tmux attachment."
        case .commandFailed(let detail):
            detail
        }
    }
}

actor LocalContinuationService {
    private struct TmuxSessionState: Sendable {
        let executableURL: URL
        let sessionID: String
        let sessionName: String
        let controlClientIDs: Set<String>
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func continueSession(
        encodedDescriptor: Data,
        localHostID: UUID,
        configuredAddress: String
    ) async throws -> LocalContinuationResult {
        let snapshot = Self.localEndpointSnapshot(
            hostID: localHostID,
            configuredAddress: configuredAddress
        )
        let disposition = try MacLocalContinuationResolver.resolve(
            encodedDescriptor: encodedDescriptor,
            local: snapshot
        )
        let intent: MacLocalTmuxAttachIntent
        switch disposition {
        case .local(let value): intent = value
        case .remote: throw LocalContinuationServiceError.remoteHost
        case .rejected(let reason):
            throw LocalContinuationServiceError.rejected(reason)
        }

        let before = try Self.queryTmuxSession(named: intent.sessionName.rawValue)
        let receiptNonce = UUID().uuidString.lowercased()
        try Self.clearAttachReceipt(
            tmuxExecutableURL: before.executableURL,
            sessionID: before.sessionID
        )
        try Self.launchIterm(
            tmuxExecutableURL: before.executableURL,
            sessionID: before.sessionID,
            receiptNonce: receiptNonce
        )
        let after: TmuxSessionState
        do {
            after = try await Self.waitForAttachment(
                expected: before,
                receiptNonce: receiptNonce
            )
        } catch {
            try? Self.clearAttachReceipt(
                tmuxExecutableURL: before.executableURL,
                sessionID: before.sessionID
            )
            throw error
        }
        try Self.clearAttachReceipt(
            tmuxExecutableURL: after.executableURL,
            sessionID: after.sessionID
        )
        try stampMacAuthority(
            tmuxExecutableURL: after.executableURL,
            sessionID: after.sessionID,
            localHostID: localHostID
        )
        return LocalContinuationResult(
            sessionName: after.sessionName,
            sessionID: after.sessionID,
            matchedByStableHostID: intent.matchedByStableHostID
        )
    }

    private func stampMacAuthority(
        tmuxExecutableURL: URL,
        sessionID: String,
        localHostID: UUID
    ) throws {
        let generationKey = "reverseContinuation.authorityGeneration"
        let generation = UInt64(max(0, defaults.integer(forKey: generationKey))) + 1
        defaults.set(Int(min(generation, UInt64(Int.max))), forKey: generationKey)
        let wireValue = MacGridAuthorityStampFactory.wireValue(
            deviceID: localHostID,
            generation: generation
        )
        let result = try Self.run(
            tmuxExecutableURL,
            arguments: [
                "set-option", "-t", sessionID,
                "@tessera_authority", wireValue,
            ]
        )
        guard result.status == 0 else {
            throw LocalContinuationServiceError.commandFailed(
                result.stderr.nilIfEmpty ?? "Could not claim tmux authority."
            )
        }
    }

    private static func waitForAttachment(
        expected: TmuxSessionState,
        receiptNonce: String
    ) async throws -> TmuxSessionState {
        for _ in 0..<50 {
            let state = try queryTmuxSession(
                sessionID: expected.sessionID,
                expectedName: expected.sessionName
            )
            let newControlClients = state.controlClientIDs
                .subtracting(expected.controlClientIDs)
            if !newControlClients.isEmpty,
               try attachReceipt(
                   tmuxExecutableURL: state.executableURL,
                   sessionID: state.sessionID
               ) == receiptNonce {
                return state
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw LocalContinuationServiceError.iTermAttachUnverified
    }

    private static func queryTmuxSession(named sessionName: String) throws -> TmuxSessionState {
        try queryTmuxSession(
            target: "=\(sessionName):",
            expectedSessionID: nil,
            expectedName: sessionName
        )
    }

    private static func queryTmuxSession(
        sessionID: String,
        expectedName: String
    ) throws -> TmuxSessionState {
        try queryTmuxSession(
            target: sessionID,
            expectedSessionID: sessionID,
            expectedName: expectedName
        )
    }

    private static func queryTmuxSession(
        target: String,
        expectedSessionID: String?,
        expectedName: String
    ) throws -> TmuxSessionState {
        let executableURL = try tmuxExecutableURL()
        let result = try run(
            executableURL,
            arguments: [
                "display-message", "-p", "-t", target,
                "#{session_id}\t#{session_name}",
            ]
        )
        guard result.status == 0 else {
            throw LocalContinuationServiceError.tmuxSessionUnavailable(expectedName)
        }
        let fields = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == 2,
              fields[1] == expectedName,
              fields[0].hasPrefix("$") else {
            throw LocalContinuationServiceError.invalidTmuxResponse
        }
        if let expectedSessionID, fields[0] != expectedSessionID {
            throw LocalContinuationServiceError.invalidTmuxResponse
        }
        return TmuxSessionState(
            executableURL: executableURL,
            sessionID: fields[0],
            sessionName: fields[1],
            controlClientIDs: try controlClientIDs(
                tmuxExecutableURL: executableURL,
                sessionID: fields[0]
            )
        )
    }

    private static func controlClientIDs(
        tmuxExecutableURL: URL,
        sessionID: String
    ) throws -> Set<String> {
        let result = try run(
            tmuxExecutableURL,
            arguments: [
                "list-clients", "-t", sessionID, "-F",
                "#{client_pid}\t#{client_control_mode}\t#{client_name}\t#{client_tty}",
            ]
        )
        guard result.status == 0 else {
            throw LocalContinuationServiceError.invalidTmuxResponse
        }
        let lines = result.stdout.split(whereSeparator: \Character.isNewline)
        var identities = Set<String>()
        for line in lines {
            let fields = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count == 4,
                  Int32(fields[0]) != nil,
                  fields[1] == "0" || fields[1] == "1" else {
                throw LocalContinuationServiceError.invalidTmuxResponse
            }
            if fields[1] == "1" {
                identities.insert("\(fields[0])\t\(fields[2])\t\(fields[3])")
            }
        }
        return identities
    }

    private static func attachReceipt(
        tmuxExecutableURL: URL,
        sessionID: String
    ) throws -> String {
        let result = try run(
            tmuxExecutableURL,
            arguments: [
                "show-option", "-qv", "-t", sessionID,
                "@tessera_attach_receipt",
            ]
        )
        guard result.status == 0 else { return "" }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clearAttachReceipt(
        tmuxExecutableURL: URL,
        sessionID: String
    ) throws {
        let result = try run(
            tmuxExecutableURL,
            arguments: [
                "set-option", "-qu", "-t", sessionID,
                "@tessera_attach_receipt",
            ]
        )
        guard result.status == 0 else {
            throw LocalContinuationServiceError.commandFailed(
                "Could not clear the tmux attachment receipt."
            )
        }
    }

    private static func tmuxExecutableURL() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
        ]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:))
        else { throw LocalContinuationServiceError.tmuxUnavailable }
        return URL(fileURLWithPath: path)
    }

    private static func launchIterm(
        tmuxExecutableURL: URL,
        sessionID: String,
        receiptNonce: String
    ) throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.googlecode.iterm2"
        ) else {
            throw LocalContinuationServiceError.iTermUnavailable
        }
        let runnerURL = appURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("it2run")
        guard FileManager.default.isExecutableFile(atPath: runnerURL.path) else {
            throw LocalContinuationServiceError.iTermUnavailable
        }
        guard let scriptURL = Bundle.main.url(
            forResource: "tessera_iterm_attach",
            withExtension: "py"
        ) else {
            throw LocalContinuationServiceError.attachScriptUnavailable
        }
        let result = try run(
            runnerURL,
            arguments: [
                scriptURL.path,
                tmuxExecutableURL.path,
                sessionID,
                receiptNonce,
            ]
        )
        guard result.status == 0 else {
            throw LocalContinuationServiceError.iTermLaunchFailed(
                result.stderr.nilIfEmpty ?? "it2run exited with status \(result.status)."
            )
        }
    }

    private static func localEndpointSnapshot(
        hostID: UUID,
        configuredAddress: String
    ) -> MacLocalEndpointSnapshot {
        let host = Host.current()
        var addresses = Set(host.addresses)
        addresses.formUnion(host.names)
        addresses.insert(configuredAddress)
        addresses.insert(ProcessInfo.processInfo.hostName)
        return MacLocalEndpointSnapshot(
            hostID: hostID,
            user: NSUserName(),
            addressCandidates: addresses,
            sshHostKeyFingerprints: localSSHHostKeyFingerprints()
        )
    }

    private static func localSSHHostKeyFingerprints() -> Set<String> {
        let paths = [
            "/etc/ssh/ssh_host_ed25519_key.pub",
            "/etc/ssh/ssh_host_ecdsa_key.pub",
            "/etc/ssh/ssh_host_rsa_key.pub",
        ]
        var fingerprints = Set<String>()
        for path in paths where FileManager.default.isReadableFile(atPath: path) {
            guard let result = try? run(
                URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                arguments: ["-lf", path, "-E", "sha256"]
            ), result.status == 0 else { continue }
            let fields = result.stdout.split(whereSeparator: \Character.isWhitespace)
            if fields.count >= 2 { fingerprints.insert(String(fields[1])) }
        }
        return fingerprints
    }

    private struct ProcessResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(_ executableURL: URL, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LocalContinuationServiceError.commandFailed(error.localizedDescription)
        }
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            stderr: String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
