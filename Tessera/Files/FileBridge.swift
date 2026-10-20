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
import os
import TesseraCore

@MainActor
@Observable
final class FileBridge: FileBridging {
    private static let idleTimeoutSeconds: TimeInterval = 10 * 60
    private static let idleTimeoutNanoseconds: UInt64 = 10 * 60 * 1_000_000_000
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
    /// Shared by every transfer on this connection, one per direction.
    private var uploadWindow = SFTPPipelineWindow.uploads()
    private var downloadWindow = SFTPPipelineWindow.downloads()
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

    func setPermissions(_ permissions: UInt16, at path: String) async throws {
        try await withSFTPOperation { sftp in
            var attributes = SFTPFileAttributes()
            attributes.permissions = UInt32(permissions & 0o7777)
            try await sftp.setAttributes(at: path, to: attributes)
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
                let total = Self.byteCount(attributes?.size)
                _ = FileManager.default.createFile(atPath: localURL.path, contents: nil)
                let localFile = try FileHandle(forWritingTo: localURL)
                defer { try? localFile.close() }
                try localFile.truncate(atOffset: 0)

                progress?(0, total)
                try await SFTPTransferPipeline.download(
                    from: remoteFile,
                    window: downloadWindow,
                    sizeHint: total,
                    write: { chunk in
                        try chunk.withUnsafeReadableBytes { try localFile.write(contentsOf: $0) }
                    },
                    progress: { transferred in
                        self.recordActivity()
                        progress?(transferred, total)
                    }
                )

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
                progress?(0, total)
                try await SFTPTransferPipeline.upload(
                    to: remoteFile,
                    window: uploadWindow,
                    nextChunk: { try localFile.read(upToCount: $0) },
                    acknowledged: { transferred in
                        self.recordActivity()
                        progress?(transferred, total)
                    }
                )

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

    func executeAgentInstallationCommand(_ command: String) async throws -> String {
        try await withSSHOperation { client in
            try await AppleAgentInstallationExec.run(client: client, command: command)
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
        case .some(0o100000):
            kind = .file
        case .none:
            // SFTP v3 servers may omit ATTR_PERMISSIONS entirely. That
            // removes both the file type and the mode bits, so guessing
            // "regular file" would let replacement uploads bypass the
            // unsupported-type gate and lose an existing private/executable
            // mode. Keep the entry visible, but fail closed for actions that
            // require a known file kind.
            kind = .other
        default:
            kind = .other
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

    /// SFTP sizes are uint64. One beyond Int64.max, from a hostile or buggy
    /// server, is an unknown size rather than a trap in Int64 progress and
    /// byte-count formatting.
    nonisolated static func byteCount(_ size: UInt64?) -> Int64? {
        size.flatMap { Int64(exactly: $0) }
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
            let mapped = FileBridgeError.network(String(localized: "SSH connection did not produce a client.", comment: "SSH connection failure"))
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
            self.uploadWindow = .uploads()
            self.downloadWindow = .downloads()
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

    /// Reuses this already-authenticated same-host route for a projector child
    /// exec channel. It never calls `connect()` and therefore never prompts for
    /// credentials/biometrics merely because Agent Center opened. The legacy
    /// `exec` method remains deliberately unsuitable because it buffers and
    /// merges output.
    func agentProjectorExecAvailability(
        binding: AgentTerminalBinding,
        isBindingCurrent: @escaping @MainActor @Sendable (AgentTerminalBinding) -> Bool
    ) -> AppleAgentExecAvailability {
        guard binding.transport == .mosh,
              state == .connected,
              let client
        else { return .unavailable(.hostAccessRequired) }

        let expectedConnectionGeneration = connectionGeneration
        return .available(AppleAgentStreamingExecFactory { [weak self, client] request in
            guard request.binding == binding else {
                throw AppleAgentPlatformError.staleBinding
            }
            let retainedRoute = await MainActor.run { [weak self] in
                guard let self,
                      self.state == .connected,
                      self.client === client,
                      self.connectionGeneration == expectedConnectionGeneration,
                      isBindingCurrent(request.binding)
                else { return false }
                // Keep this already-connected Files/scrollback route alive
                // until the projector child finishes; do not reconnect it.
                self.activeOperationCount += 1
                self.recordActivity()
                return true
            }
            guard retainedRoute else { throw AppleAgentPlatformError.staleBinding }
            return try await AppleCitadelAgentExecHandle.open(
                client: client,
                request: request,
                isBindingCurrent: isBindingCurrent,
                onFinish: { [weak self] in self?.finishOperation() }
            )
        })
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
            return .authenticationFailed(String(localized: "Authentication failed.", comment: "SSH auth failure"))

        case let error as SSHClientError:
            switch error {
            case .unsupportedPasswordAuthentication:
                return .authenticationFailed(String(localized: "The server does not accept password authentication.", comment: "SSH auth failure"))
            case .unsupportedPrivateKeyAuthentication:
                return .authenticationFailed(String(localized: "The server does not accept public-key authentication.", comment: "SSH auth failure"))
            case .unsupportedHostBasedAuthentication:
                return .authenticationFailed(String(localized: "The server does not accept host-based authentication.", comment: "SSH auth failure"))
            case .allAuthenticationOptionsFailed:
                return .authenticationFailed(String(localized: "Authentication failed.", comment: "SSH auth failure"))
            case .channelCreationFailed:
                return .network(String(localized: "Failed to open the SSH channel.", comment: "SSH channel failure"))
            }

        case let error as CitadelError:
            switch error {
            case .unauthorized:
                return .authenticationFailed(String(localized: "Authentication failed.", comment: "SSH auth failure"))
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
            return String(localized: "Remote command failed with exit status \(commandFailed.exitCode).", comment: "Remote command failure; the argument is a shell exit status")
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

/// The two requests a pipelined transfer sends. `SFTPFile` conforms;
/// FileBridgeTests substitutes a scripted server.
protocol PipelinedSFTPFile: AnyObject {
    func writeFuture(_ data: ByteBuffer, at offset: UInt64) -> EventLoopFuture<Void>
    func readFuture(from offset: UInt64, length: UInt32) -> EventLoopFuture<ByteBuffer>
}

extension SFTPFile: PipelinedSFTPFile {}

/// SFTP answers every read and write request separately. Awaiting each reply
/// before sending the next request caps a transfer at one request per round
/// trip — for 32 KB writes, 1.6 MB/s at 20 ms and 320 KB/s at 100 ms — however
/// fast the link is. So requests are pipelined, with up to about 2 MB
/// outstanding like OpenSSH's sftp client (the channel window OpenSSH's server
/// grants a session). Every other request on the connection — browsing, the
/// close that ends a cancelled transfer — waits behind what transfers have
/// queued, so a per-connection `SFTPPipelineWindow` holds the outstanding
/// bytes to what the measured rate needs. Requests travel in batches so the
/// main actor resumes once per batch rather than once per request.
@MainActor
enum SFTPTransferPipeline {
    nonisolated static let writeRequestLength = SFTPFile.maximumWriteRequestLength
    nonisolated static let writeRequestsPerBatch = 8
    /// Every OpenSSH release answers 64 KiB reads in full.
    nonisolated static let readRequestLength: UInt32 = 64 * 1024
    /// Reads shrink to a server's cap, but never below this.
    nonisolated static let minimumReadRequestLength: UInt32 = 4 * 1024
    nonisolated static let readRequestsPerBatch = 4

    nonisolated static func uptimeNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Writes each `nextChunk(maximumByteCount)` result (nil or empty at end
    /// of input) at consecutive offsets, reporting the cumulative bytes the
    /// server has acknowledged — never bytes merely queued.
    static func upload(
        to file: PipelinedSFTPFile,
        window: SFTPPipelineWindow,
        nextChunk: (Int) throws -> Data?,
        acknowledged: (Int64) -> Void,
        clock: @escaping @Sendable () -> UInt64 = uptimeNanoseconds
    ) async throws {
        var inFlight: [(end: Int64, acknowledgement: EventLoopFuture<Void>)] = []
        var submitted: Int64 = 0
        func batchBytes() -> Int {
            window.requestsPerBatch(requestLength: writeRequestLength, maximum: writeRequestsPerBatch)
                * writeRequestLength
        }
        while true {
            try Task.checkCancellation()
            while let oldest = inFlight.first, window.outstandingBytes + batchBytes() > window.limitBytes {
                inFlight.removeFirst()
                try await oldest.acknowledgement.get()
                acknowledged(oldest.end)
                try Task.checkCancellation()
            }
            guard let chunk = try nextChunk(batchBytes()), !chunk.isEmpty else { break }
            var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            let ticket = window.send(bytes: chunk.count, at: clock())
            let acknowledgement = file.writeFuture(buffer, at: UInt64(submitted))
            // On the event loop as the reply arrives, before any awaiting
            // task resumes.
            acknowledgement.whenComplete { result in
                window.answer(ticket, at: clock(), succeeded: (try? result.get()) != nil)
            }
            submitted += Int64(chunk.count)
            inFlight.append((submitted, acknowledgement))
        }
        for batch in inFlight {
            try await batch.acknowledgement.get()
            acknowledged(batch.end)
        }
    }

    /// Reads from offset 0 to end of file, passing bytes to `write` strictly
    /// in order and reporting the cumulative count. `sizeHint`, the size when
    /// the file was opened, bounds read-ahead; beyond it one request at a time
    /// probes for end of file, until a full reply shows the file grew.
    static func download(
        from file: PipelinedSFTPFile,
        window: SFTPPipelineWindow,
        sizeHint: Int64?,
        write: (ByteBuffer) throws -> Void,
        progress: (Int64) -> Void,
        clock: @escaping @Sendable () -> UInt64 = uptimeNanoseconds
    ) async throws {
        typealias Request = (offset: UInt64, length: UInt32, reply: EventLoopFuture<ByteBuffer>)
        typealias Batch = (requests: [Request], replies: EventLoopFuture<[Result<ByteBuffer, Error>]>)
        let sizeAtOpen = sizeHint.map { UInt64(max(0, $0)) }
        var readAheadLimit = sizeAtOpen ?? .max
        var requestLength = readRequestLength
        var lastShortReply: Int?
        var nextRequestOffset: UInt64 = 0
        var delivered: UInt64 = 0
        var inFlight: [Batch] = []

        while true {
            try Task.checkCancellation()
            while true {
                let requestsPerBatch = window.requestsPerBatch(
                    requestLength: Int(requestLength),
                    maximum: readRequestsPerBatch
                )
                guard inFlight.isEmpty
                    || (nextRequestOffset < readAheadLimit
                        && window.outstandingBytes + requestsPerBatch * Int(requestLength) <= window.limitBytes)
                else { break }
                let sentAt = clock()
                var requests: [Request] = []
                repeat {
                    let reply = file.readFuture(from: nextRequestOffset, length: requestLength)
                    requests.append((nextRequestOffset, requestLength, reply))
                    nextRequestOffset += UInt64(requestLength)
                } while requests.count < requestsPerBatch && nextRequestOffset < readAheadLimit
                let ticket = window.send(bytes: requests.count * Int(requestLength), at: sentAt)
                let replies = EventLoopFuture.whenAllComplete(
                    requests.map(\.reply),
                    on: requests[0].reply.eventLoop
                )
                // On the event loop as the last reply arrives — also for
                // batches dropped below, whose replies still cross the link.
                replies.whenSuccess { results in
                    window.answer(
                        ticket,
                        at: clock(),
                        succeeded: results.allSatisfy { (try? $0.get()) != nil }
                    )
                }
                inFlight.append((requests, replies))
            }

            let batch = inFlight.removeFirst()
            let replies = try await batch.replies.get()
            var resumeOffset: UInt64?
            for (request, reply) in zip(batch.requests, replies) {
                let chunk = try reply.get()
                let count = chunk.readableBytes
                guard count > 0 else {
                    progress(Int64(delivered))
                    return
                }
                guard count <= Int(request.length) else { throw SFTPError.invalidResponse }
                try write(chunk)
                delivered += UInt64(count)
                if count < Int(request.length) {
                    // A short reply leaves a gap before the requests after
                    // it: drop those and resume at the gap. Two in a row of
                    // one length mean the server caps reads; one alone — the
                    // end of a growing file, an odd filesystem — changes
                    // nothing.
                    if lastShortReply == count {
                        requestLength = max(UInt32(count), minimumReadRequestLength)
                    }
                    lastShortReply = count
                    resumeOffset = delivered
                    break
                }
                lastShortReply = nil
                if let sizeAtOpen, request.offset + UInt64(request.length) > sizeAtOpen {
                    // A full reply past the size at open: the file grew.
                    readAheadLimit = .max
                }
            }
            progress(Int64(delivered))
            if let resumeOffset {
                inFlight.removeAll()
                nextRequestOffset = resumeOffset
            }
        }
    }
}

/// How many bytes pipelined transfers may leave unanswered on one connection
/// in one direction — shared by every transfer that way, because the queue
/// they build is the one every other request on the connection waits behind.
///
/// The limit is the fastest rate measured in the last two seconds times the
/// quickest round trip plus a quarter second: enough to keep the link busy
/// with about the budget queued. On a fast link that is the whole ceiling;
/// at 10 Mbit/s it is about 400 KB rather than 2 MB, so browsing during an
/// upload stays responsive. Samples taken behind a queue never raise the
/// quickest round trip, or transfers would ratchet it up; a near-empty
/// sample replaces it once it is ten seconds old, so a path that got slower
/// — another app's upload, a VPN relay — doesn't pin the window at the
/// floor. Android's `SftpPipelineWindow` is the same controller.
final class SFTPPipelineWindow: @unchecked Sendable {
    static let queueBudgetNanoseconds: UInt64 = 250_000_000
    static let rateWindowNanoseconds: UInt64 = 2_000_000_000
    static let minimumLatencyLifetimeNanoseconds: UInt64 = 10_000_000_000

    /// One request's worth at the floor: on a link that slow, nothing waits
    /// behind more than it did when transfers were stop-and-wait.
    static func uploads() -> SFTPPipelineWindow {
        let request = SFTPTransferPipeline.writeRequestLength
        return SFTPPipelineWindow(floorBytes: request, ceilingBytes: 64 * request, initialBytes: 4 * request)
    }

    static func downloads() -> SFTPPipelineWindow {
        let request = Int(SFTPTransferPipeline.readRequestLength)
        return SFTPPipelineWindow(floorBytes: request, ceilingBytes: 32 * request, initialBytes: 4 * request)
    }

    struct Ticket: Sendable {
        let bytes: Int
        /// Unanswered bytes once this request left, its own included.
        let outstandingAtSend: Int
        let sentAt: UInt64
    }

    private struct State {
        var limitBytes: Int
        var outstandingBytes = 0
        var minimumLatency = UInt64.max
        var minimumLatencyMeasuredAt: UInt64 = 0
        var rates: [(answeredAt: UInt64, bytesPerNanosecond: Double)] = []
        var lastActivity: UInt64?
    }

    let floorBytes: Int
    let ceilingBytes: Int
    let initialBytes: Int
    private let state: OSAllocatedUnfairLock<State>

    init(floorBytes: Int, ceilingBytes: Int, initialBytes: Int) {
        self.floorBytes = floorBytes
        self.ceilingBytes = ceilingBytes
        self.initialBytes = min(max(initialBytes, floorBytes), ceilingBytes)
        state = OSAllocatedUnfairLock(initialState: State(limitBytes: self.initialBytes))
    }

    var limitBytes: Int { state.withLock { $0.limitBytes } }
    var outstandingBytes: Int { state.withLock { $0.outstandingBytes } }

    /// About a quarter of the window in whole requests, so several batches
    /// are in flight.
    func requestsPerBatch(requestLength: Int, maximum: Int) -> Int {
        min(max(limitBytes / 4 / requestLength, 1), maximum)
    }

    func send(bytes: Int, at now: UInt64) -> Ticket {
        state.withLock { state in
            // A connection idle this long may be on another path by now.
            if state.outstandingBytes == 0, let last = state.lastActivity,
               now >= last, now - last >= Self.minimumLatencyLifetimeNanoseconds {
                state = State(limitBytes: initialBytes)
            }
            state.outstandingBytes += bytes
            state.lastActivity = now
            return Ticket(bytes: bytes, outstandingAtSend: state.outstandingBytes, sentAt: now)
        }
    }

    /// The server answered — or will never answer — `ticket`'s requests.
    /// It answers in order, so every byte outstanding when they left crossed
    /// in the meantime; failures return their bytes without a sample.
    func answer(_ ticket: Ticket, at now: UInt64, succeeded: Bool) {
        state.withLock { state in
            state.outstandingBytes = max(state.outstandingBytes - ticket.bytes, 0)
            state.lastActivity = max(state.lastActivity ?? now, now)
            guard succeeded else { return }
            let latency = now > ticket.sentAt ? now - ticket.sentAt : 1
            if latency < state.minimumLatency
                || (ticket.outstandingAtSend <= floorBytes
                    && now >= state.minimumLatencyMeasuredAt
                    && now - state.minimumLatencyMeasuredAt >= Self.minimumLatencyLifetimeNanoseconds) {
                state.minimumLatency = latency
                state.minimumLatencyMeasuredAt = now
            }
            state.rates.append((now, Double(ticket.outstandingAtSend) / Double(latency)))
            let horizonStart = now > Self.rateWindowNanoseconds ? now - Self.rateWindowNanoseconds : 0
            state.rates.removeAll { $0.answeredAt < horizonStart && $0.answeredAt != now }
            let fastest = state.rates.map(\.bytesPerNanosecond).max() ?? 0
            let target = fastest * (Double(state.minimumLatency) + Double(Self.queueBudgetNanoseconds))
            state.limitBytes = Int(min(max(target, Double(floorBytes)), Double(ceilingBytes)))
        }
    }
}
