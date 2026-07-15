// Tessera/Files/FileBridge.swift
// Remote Files feature - SSH/SFTP bridge implementation.
// Contracts: Tessera/Files/FilesContracts.swift

#if canImport(Darwin)
import Darwin
#endif

import Citadel
import Foundation
import NIOCore
import Observation

@MainActor
@Observable
final class FileBridge: FileBridging {
    private static let idleTimeoutSeconds: TimeInterval = 10 * 60
    private static let idleTimeoutNanoseconds: UInt64 = 10 * 60 * 1_000_000_000
    private static let transferChunkSize = 128 * 1024
    private static let execMaxResponseSize = 1024 * 1024

    let key: FileBridgeKey
    private(set) var state: FileBridgeState = .idle
    private(set) var homeDirectory: String?
    /// See FileBridging: the panel holds this true while open so the
    /// idle timer never disconnects under a visible listing.
    var suppressIdleTeardown = false

    // `var`, not `let`: the Host DTO freezes credentials (password,
    // storedKeyID) at construction, so the registry refreshes this
    // snapshot on every lookup — otherwise a bridge cached before a
    // credential rotation would retry the old secret forever. Only read
    // at connect time; a live connection is unaffected.
    private var host: Host
    private var requireBiometric: Bool
    private var isSecureEnclave: Bool

    private var client: SSHClient?
    /// Bastion clients when the host connects through a jump chain,
    /// outermost first. Closed with the main client on every teardown.
    private var upstreamClients: [SSHClient] = []
    /// Route actually used by the live SFTP socket. The registry key is based
    /// on the caller's frozen session snapshot, while connection policy is
    /// intentionally re-read live; comparing this before reuse prevents a
    /// bridge established through route B from masquerading as route A after
    /// topology edits.
    private var connectedRouteIdentity: String?
    private var sftp: SFTPClient?
    private var connectTask: Task<Void, Error>?
    private var connectionGeneration = 0
    private var idleTask: Task<Void, Never>?
    private var lastActivity = Date.distantPast
    private var activeOperationCount = 0

    init(host: Host, requireBiometric: Bool, isSecureEnclave: Bool) {
        self.host = host
        self.requireBiometric = requireBiometric
        self.isSecureEnclave = isSecureEnclave
        self.key = FileBridgeKey(host: host)
    }

    /// Refresh the credential snapshot used by the NEXT connect (the
    /// registry calls this on every cache hit so credential rotations
    /// and biometric-flag changes take effect without app relaunch).
    func updateCredentials(host: Host, requireBiometric: Bool, isSecureEnclave: Bool) {
        self.host = host
        self.requireBiometric = requireBiometric
        self.isSecureEnclave = isSecureEnclave
    }

    func connect() async throws {
        let desiredRouteIdentity: String
        do {
            let policy = try await resolveSSHConnectionPolicy(
                for: host,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave
            )
            desiredRouteIdentity = policy.host.sshConnectionRouteIdentity
        } catch {
            throw Self.mapConnectError(error)
        }

        if state == .connected {
            guard connectedRouteIdentity != desiredRouteIdentity else { return }
            await disconnect(cancelIdleTimer: true)
        }
        if let connectTask {
            try await connectTask.value
            // A model save cancels in-flight SSH establishment, but a topology
            // change can race the subsequent SFTP open. Re-enter once so the
            // completed socket is checked against the route requested here.
            if connectedRouteIdentity != desiredRouteIdentity {
                await disconnect(cancelIdleTimer: true)
                try await connect()
            }
            return
        }

        connectionGeneration += 1
        let generation = connectionGeneration
        state = .connecting

        let task = Task { [weak self] in
            guard let self else { throw FileBridgeError.notConnected }
            try await self.performConnect(generation: generation)
        }
        connectTask = task

        do {
            try await task.value
            connectTask = nil
            if connectedRouteIdentity != desiredRouteIdentity {
                await disconnect(cancelIdleTimer: true)
                try await connect()
            }
        } catch {
            connectTask = nil
            throw error
        }
    }

    func disconnect() async {
        await disconnect(cancelIdleTimer: true)
    }

    func listDirectory(_ path: String) async throws -> [RemoteFileEntry] {
        try await withSFTPOperation {
            let absolutePath = try await $0.getRealPath(atPath: path)
            let listings = try await $0.listDirectory(atPath: absolutePath)
            let entries = listings
                .flatMap(\.components)
                .compactMap { component -> RemoteFileEntry? in
                    guard component.filename != ".", component.filename != ".." else {
                        return nil
                    }
                    return Self.mapEntry(
                        filename: component.filename,
                        absoluteDirectoryPath: absolutePath,
                        rawMode: component.attributes.permissions,
                        size: component.attributes.size,
                        mtime: component.attributes.accessModificationTime?.modificationTime
                    )
                }
            return Self.sortedEntries(entries)
        }
    }

    func realPath(_ path: String) async throws -> String {
        try await withSFTPOperation {
            try await $0.getRealPath(atPath: path)
        }
    }

    func createDirectory(_ path: String) async throws {
        try await withSFTPOperation {
            try await $0.createDirectory(atPath: path)
        }
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        try await withSFTPOperation {
            try await $0.rename(at: oldPath, to: newPath)
        }
    }

    func removeFile(_ path: String) async throws {
        try await withSFTPOperation {
            try await $0.remove(at: path)
        }
    }

    func removeDirectory(_ path: String) async throws {
        try await withSFTPOperation {
            try await $0.rmdir(at: path)
        }
    }

    func download(
        remotePath: String,
        to localURL: URL,
        progress: TransferProgressHandler?
    ) async throws {
        try await withSFTPOperation { sftp in
            let remoteFile = try await sftp.openFile(filePath: remotePath, flags: .read)
            do {
                let attributes = try? await remoteFile.readAttributes()
                let total = attributes?.size.map(Int64.init)
                _ = FileManager.default.createFile(atPath: localURL.path, contents: nil)
                let localFile = try FileHandle(forWritingTo: localURL)
                defer { try? localFile.close() }
                try localFile.truncate(atOffset: 0)

                var offset: UInt64 = 0
                var transferred: Int64 = 0
                progress?(0, total)

                while true {
                    try Task.checkCancellation()
                    var chunk = try await remoteFile.read(
                        from: offset,
                        length: UInt32(Self.transferChunkSize)
                    )
                    let byteCount = chunk.readableBytes
                    guard byteCount > 0 else { break }

                    let bytes = chunk.readBytes(length: byteCount) ?? []
                    try localFile.write(contentsOf: Data(bytes))
                    offset += UInt64(byteCount)
                    transferred += Int64(byteCount)
                    self.recordActivity()
                    progress?(transferred, total)
                }

                try? await remoteFile.close()
            } catch {
                try? await remoteFile.close()
                throw error
            }
        }
    }

    func upload(
        localURL: URL,
        to remotePath: String,
        progress: TransferProgressHandler?
    ) async throws {
        try await withSFTPOperation { sftp in
            let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
            let total = (attributes[.size] as? NSNumber).map { $0.int64Value }
            let localFile = try FileHandle(forReadingFrom: localURL)
            defer { try? localFile.close() }

            let remoteFile = try await sftp.openFile(
                filePath: remotePath,
                flags: [.write, .create, .truncate]
            )
            do {
                var offset: UInt64 = 0
                progress?(0, total)

                while true {
                    try Task.checkCancellation()
                    guard let data = try localFile.read(upToCount: Self.transferChunkSize),
                          !data.isEmpty
                    else {
                        break
                    }

                    var buffer = ByteBuffer()
                    buffer.writeBytes(data)
                    try await remoteFile.write(buffer, at: offset)

                    offset += UInt64(data.count)
                    self.recordActivity()
                    progress?(Int64(offset), total)
                }

                try? await remoteFile.close()
            } catch {
                try? await remoteFile.close()
                throw error
            }
        }
    }

    @discardableResult
    func exec(_ command: String, inShell: Bool) async throws -> String {
        try await withSSHOperation { client in
            var output = try await client.executeCommand(
                command,
                maxResponseSize: Self.execMaxResponseSize,
                mergeStreams: true,
                inShell: inShell
            )
            let bytes = output.readBytes(length: output.readableBytes) ?? []
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Pure mapping hook for unit tests; Citadel's SFTP types stay out of
    /// tests so W1 has no socket or subsystem dependency.
    nonisolated static func mapEntry(
        filename: String,
        absoluteDirectoryPath: String,
        rawMode: UInt32?,
        size: UInt64?,
        mtime: Date?
    ) -> RemoteFileEntry {
        let kind: RemoteFileEntry.Kind
        switch rawMode.map({ $0 & 0o170000 }) {
        case .some(0o040000):
            kind = .directory
        case .some(0o120000):
            kind = .symlink
        default:
            kind = .file
        }

        return RemoteFileEntry(
            name: filename,
            path: joinedPath(directory: absoluteDirectoryPath, filename: filename),
            kind: kind,
            size: kind == .directory ? nil : size,
            modified: mtime,
            permissions: rawMode.map { UInt16($0 & 0o7777) }
        )
    }

    nonisolated static func sortedEntries(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.kind == .directory, rhs.kind != .directory {
                return true
            }
            if lhs.kind != .directory, rhs.kind == .directory {
                return false
            }

            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison == .orderedSame {
                return lhs.path < rhs.path
            }
            return comparison == .orderedAscending
        }
    }

    private func performConnect(generation: Int) async throws {
        var connectedChain: EstablishedSSHChain?

        do {
            try Task.checkCancellation()
            let fallbackHost = host
            let requireBiometric = self.requireBiometric
            let isSecureEnclave = self.isSecureEnclave
            let chain = try await withPendingSSHConnectionAttempt {
                try await establishSSHChain(
                    for: fallbackHost,
                    requireBiometric: requireBiometric,
                    isSecureEnclave: isSecureEnclave,
                    hostKeyPrompt: nil
                )
            }
            connectedChain = chain
            try await closeIfConnectStale(generation: generation, chain: chain, sftp: nil)
        } catch is CancellationError {
            if let connectedChain { await connectedChain.closeAll() }
            let mapped = FileBridgeError.cancelled
            applyConnectFailure(mapped, generation: generation)
            throw mapped
        } catch {
            if let connectedChain { await connectedChain.closeAll() }
            let mapped = Self.mapConnectError(error)
            applyConnectFailure(mapped, generation: generation)
            throw mapped
        }

        guard let connectedChain else {
            let mapped = FileBridgeError.network("SSH connection did not produce a client.")
            applyConnectFailure(mapped, generation: generation)
            throw mapped
        }
        let connectedClient = connectedChain.client

        var openedSFTP: SFTPClient?
        do {
            try Task.checkCancellation()
            let sftp = try await connectedClient.openSFTP()
            openedSFTP = sftp
            let home = try await sftp.getRealPath(atPath: ".")
            try await closeIfConnectStale(generation: generation, chain: connectedChain, sftp: sftp)

            self.client = connectedClient
            self.upstreamClients = connectedChain.upstream
            self.connectedRouteIdentity = connectedChain.resolvedHost
                .sshConnectionRouteIdentity
            self.sftp = sftp
            self.homeDirectory = home
            self.state = .connected
            self.recordActivity()
        } catch is CancellationError {
            try? await openedSFTP?.close()
            await connectedChain.closeAll()
            let mapped = FileBridgeError.cancelled
            applyConnectFailure(mapped, generation: generation)
            throw mapped
        } catch {
            try? await openedSFTP?.close()
            await connectedChain.closeAll()
            let mapped = FileBridgeError.sftpUnavailable(describeSSHError(error))
            applyConnectFailure(mapped, generation: generation)
            throw mapped
        }
    }

    private func closeIfConnectStale(
        generation: Int,
        chain: EstablishedSSHChain,
        sftp: SFTPClient?
    ) async throws {
        guard generation == connectionGeneration, !Task.isCancelled else {
            try? await sftp?.close()
            await chain.closeAll()
            throw CancellationError()
        }
    }

    private func applyConnectFailure(_ error: FileBridgeError, generation: Int) {
        guard generation == connectionGeneration else {
            return
        }
        state = .failed(error.localizedDescription)
    }

    private func disconnect(cancelIdleTimer: Bool) async {
        if cancelIdleTimer {
            idleTask?.cancel()
        }
        idleTask = nil
        connectTask?.cancel()
        connectTask = nil
        connectionGeneration += 1
        activeOperationCount = 0

        let currentSFTP = sftp
        let currentClient = client
        let currentUpstream = upstreamClients
        sftp = nil
        client = nil
        upstreamClients = []
        connectedRouteIdentity = nil
        homeDirectory = nil

        try? await currentSFTP?.close()
        try? await currentClient?.close()
        for bastion in currentUpstream.reversed() {
            try? await bastion.close()
        }
        state = .idle
    }

    private func withSFTPOperation<T>(
        _ body: (SFTPClient) async throws -> T
    ) async throws -> T {
        guard state == .connected, let sftp else {
            throw FileBridgeError.notConnected
        }
        return try await runOperation {
            try await body(sftp)
        }
    }

    private func withSSHOperation<T>(
        _ body: (SSHClient) async throws -> T
    ) async throws -> T {
        guard state == .connected, let client else {
            throw FileBridgeError.notConnected
        }
        return try await runOperation {
            try await body(client)
        }
    }

    private func runOperation<T>(_ body: () async throws -> T) async throws -> T {
        activeOperationCount += 1
        recordActivity()

        do {
            let result = try await body()
            finishOperation()
            return result
        } catch is CancellationError {
            finishOperation()
            throw FileBridgeError.cancelled
        } catch let error as FileBridgeError {
            finishOperation()
            throw error
        } catch {
            finishOperation()
            if Self.isConnectionClosedError(error) {
                guard state == .connected else {
                    throw FileBridgeError.notConnected
                }
                await markDropped()
                throw FileBridgeError.network(describeSSHError(error))
            }
            throw FileBridgeError.remoteOperationFailed(Self.remoteOperationMessage(error))
        }
    }

    private func finishOperation() {
        activeOperationCount = max(0, activeOperationCount - 1)
        recordActivity()
    }

    private func recordActivity() {
        lastActivity = Date()
        scheduleIdleTeardown()
    }

    private func scheduleIdleTeardown() {
        idleTask?.cancel()
        guard state == .connected else {
            idleTask = nil
            return
        }

        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.disconnectIfIdle()
        }
    }

    private func disconnectIfIdle() async {
        guard state == .connected else {
            return
        }
        guard activeOperationCount == 0, !suppressIdleTeardown else {
            scheduleIdleTeardown()
            return
        }

        let idleFor = Date().timeIntervalSince(lastActivity)
        if idleFor >= Self.idleTimeoutSeconds {
            await disconnect(cancelIdleTimer: false)
        } else {
            scheduleIdleTeardown()
        }
    }

    private func markDropped() async {
        idleTask?.cancel()
        idleTask = nil
        activeOperationCount = 0

        let currentSFTP = sftp
        let currentClient = client
        let currentUpstream = upstreamClients
        sftp = nil
        client = nil
        upstreamClients = []
        connectedRouteIdentity = nil
        homeDirectory = nil
        state = .dropped

        try? await currentSFTP?.close()
        try? await currentClient?.close()
        for bastion in currentUpstream.reversed() {
            try? await bastion.close()
        }
    }

    private static func mapConnectError(_ error: Error) -> FileBridgeError {
        // Hop-attributed failures carry the real cause inside. Classify
        // that (so a bastion's unknown host key still maps to the
        // trust-in-terminal remedy), then re-attach the hop label to
        // message-bearing results.
        if let hopError = error as? SSHChainHopError {
            let mapped = mapConnectError(hopError.underlying)
            switch mapped {
            case .authenticationFailed(let message):
                return .authenticationFailed("Jump host \(hopError.hopLabel): \(message)")
            case .network(let message):
                return .network("Jump host \(hopError.hopLabel): \(message)")
            default:
                return mapped
            }
        }
        switch error {
        case is HostKeyRejectedError:
            return .hostKeyNeedsTerminalTrust

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
                return .network("Failed to open the SSH channel.")
            }

        case let error as CitadelError:
            switch error {
            case .unauthorized:
                return .authenticationFailed("Authentication failed.")
            default:
                return .network(describeSSHError(error))
            }

        default:
            return .network(describeSSHError(error))
        }
    }

    private static func remoteOperationMessage(_ error: Error) -> String {
        if let sftpError = error as? SFTPError {
            switch sftpError {
            case .errorStatus(let status):
                let message = status.message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty {
                    return message
                }
                return status.errorCode.debugDescription
            default:
                break
            }
        }
        if let status = error as? SFTPMessage.Status {
            let message = status.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                return message
            }
        }
        if let commandFailed = error as? SSHClient.CommandFailed {
            return "Remote command failed with exit status \(commandFailed.exitCode)."
        }
        return describeSSHError(error)
    }

    private static func isConnectionClosedError(_ error: Error) -> Bool {
        if let sftpError = error as? SFTPError {
            switch sftpError {
            case .connectionClosed, .missingResponse, .fileHandleInvalid:
                return true
            case .errorStatus(let status):
                return status.errorCode == .noConnection || status.errorCode == .connectionLost
            default:
                return false
            }
        }

        if let channelError = error as? ChannelError {
            switch channelError {
            case .ioOnClosedChannel, .alreadyClosed, .outputClosed, .inputClosed, .eof:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            #if canImport(Darwin)
            switch CInt(nsError.code) {
            case ECONNRESET, EPIPE, ENOTCONN, ETIMEDOUT:
                return true
            default:
                break
            }
            #endif
        }

        let description = String(describing: error).lowercased()
        return description.contains("already closed")
            || description.contains("closed channel")
            || description.contains("connection closed")
            || description.contains("connection reset")
            || description.contains("broken pipe")
            || description.contains("not connected")
            || description.contains("eof")
    }

    private nonisolated static func joinedPath(directory: String, filename: String) -> String {
        guard directory != "/" else {
            return "/\(filename)"
        }
        var directory = directory
        while directory.hasSuffix("/") {
            directory.removeLast()
        }
        guard !directory.isEmpty else {
            return filename
        }
        return "\(directory)/\(filename)"
    }
}
