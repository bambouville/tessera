import Foundation
@preconcurrency import Citadel
import NIOCore
import TesseraCore

/// Bounded installer commands on a child-only exec channel. In particular,
/// cancellation of a best-effort abort must not retain an active FileBridge
/// operation or close the terminal's authenticated SSH client.
@MainActor
enum AppleAgentInstallationExec {
    /// A failed remote command can race SSH channel teardown. Preserve the
    /// installer's fixed diagnostic code without exposing its traceback, paths
    /// or arbitrary remote stderr. Real caller cancellation remains cancellation.
    static func classifiedFailure(_ error: Error, output: Data) -> Error {
        let codes: Set<String> = ["artifactBudget", "checksumMismatch", "chunkConflict", "chunkGap",
            "executableVerificationFailed", "insecureDirectory", "insecureFile", "installationBusy",
            "installationChanged", "installedChecksumMismatch", "invalidArtifact", "invalidChunk",
            "invalidOperation", "invalidRollback", "publicationConflict", "shortWrite", "stagingBudget",
            "unrecognizedInstallation", "unsupportedTarget", "uploadMismatch", "verificationDeadline",
            "verificationOutputBudget", "versionStorageBudget"]
        guard let last = String(data: output, encoding: .utf8)?.split(separator: "\n").last,
              last.hasPrefix("RuntimeError: ") else { return error }
        let code = String(last.dropFirst("RuntimeError: ".count))
        if code == "newerIntegrationInstalled" { return AgentLifecycleIntegrationInstallError.newerInstalled }
        guard codes.contains(code) else { return error }
        return AgentLifecycleIntegrationInstallError.verificationFailed("artifact: " + code)
    }

    static func completeForCaller(_ result: Result<String, Error>) throws -> String {
        // The unstructured worker's cancellation state is not the caller's.
        // A queued remote failure must not win over already-requested caller
        // cancellation while its actor-isolated cancellation handler waits.
        try Task.checkCancellation()
        return try result.get()
    }

    static func run(client: SSHClient, command: String) async throws -> String {
        try await AppleAgentBoundedCommandExec.run(client: client, command: command, installation: true)
    }
}

/// Bounded child-only exec for integration reads and explicit installation.
/// A timeout closes only its child channel; the terminal and sibling channels
/// remain owned by their session. No submitted command is replayed.
@MainActor
enum AppleAgentBoundedCommandExec {
    static func run(client: SSHClient, command: String, installation: Bool = false) async throws -> String {
        try await run(timeout: installation ? .seconds(10) : .milliseconds(Int64(AgentReadRecoveryPolicy.processProofTimeoutMilliseconds)), installation: installation) { operation in
            let perform: (TTYOutput, TTYStdinWriter) async throws -> Void = { inbound, writer in
                guard await operation.accept(close: { try? await writer.close() }) else { return }
                do {
                    var input = ByteBuffer()
                    input.writeString(command + (installation ? "\n" : ";exit\n"))
                    try await writer.write(input)
                    if installation { try await writer.closeInput() }
                    for try await chunk in inbound {
                        let bytes: ByteBuffer
                        switch chunk { case .stdout(let value), .stderr(let value): bytes = value }
                        try await operation.append(Data(bytes.readableBytesView))
                    }
                    // Settle before withTTY's cleanup: remote EOF may already
                    // have closed the child, which is not a command failure.
                    await operation.succeed()
                } catch {
                    await operation.fail(error)
                    throw error
                }
            }
            if installation {
                try await client.withExec("/bin/sh -s", perform: perform)
            } else {
                // Match executeCommand(inShell: true)'s ShellRequest so login
                // profile exports (CODEX_HOME, PATH, etc.) remain available.
                try await client.withTTY(perform: perform)
            }
        }
    }

    /// Producer injection exercises timeout/cancellation with channels that
    /// open or deliver output after the caller's deadline.
    static func run(timeout: Duration, installation: Bool = false,
                    execute: @escaping @Sendable (Operation) async throws -> Void) async throws -> String {
        let operation = Operation(installation: installation)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: Result<String, Error>
            do { result = .success(try await operation.run(timeout: timeout, execute: execute)) }
            catch { result = .failure(error) }
            try Task.checkCancellation()
            return try result.get()
        } onCancel: {
            Task { @MainActor in operation.finish(.failure(CancellationError())) }
        }
    }

    @MainActor
    final class Operation {
        private var continuation: CheckedContinuation<String, Error>?
        private var worker: Task<Void, Never>?
        private var deadline: Task<Void, Never>?
        private var closeChild: (@Sendable () async -> Void)?
        private var output = Data()
        private var finished = false
        private let installation: Bool

        init(installation: Bool) { self.installation = installation }

        func run(timeout: Duration,
                 execute: @escaping @Sendable (Operation) async throws -> Void) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                guard !finished else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self else { return }
                    let error: Error = self.installation
                        ? AgentLifecycleIntegrationInstallError.verificationFailed("installation command timed out")
                        : AgentProjectionError.channelUnavailable
                    self.finish(.failure(error))
                }
                worker = Task {
                    do {
                        try await execute(self)
                        self.succeed()
                    } catch {
                        self.fail(error)
                    }
                }
            }
        }

        func accept(close: @escaping @Sendable () async -> Void) -> Bool {
            guard !finished else { Task { await close() }; return false }
            closeChild = close
            return true
        }

        func append(_ bytes: Data) throws {
            guard !finished else { throw CancellationError() }
            guard output.count + bytes.count <= (installation ? 256 : 128) * 1024 else {
                if installation { throw AgentLifecycleIntegrationInstallError.verificationFailed("installation output budget") }
                throw AppleAgentPlatformError.boundedPayloadExceeded
            }
            output.append(bytes)
        }

        func succeed() { finish(.success(String(decoding: output, as: UTF8.self))) }

        func fail(_ error: Error) {
            finish(.failure(installation ? AppleAgentInstallationExec.classifiedFailure(error, output: output) : error))
        }

        func finish(_ result: Result<String, Error>) {
            guard !finished else { return }
            finished = true
            deadline?.cancel(); deadline = nil
            worker?.cancel(); worker = nil
            if let closeChild { Task { await closeChild() } }
            closeChild = nil
            let completion = continuation; continuation = nil
            completion?.resume(with: result)
        }
    }
}

/// The installed, read-only projector entry point.  It is deliberately a
/// fixed exec request rather than a caller-provided shell string: the only
/// variable payload is the bounded canonical JSON written to its stdin.
enum AppleAgentProjectorCommand {
    static let executable = "$HOME/.config/tessera/tessera-agent-project"
    static let ingestionHost = "\"$HOME/.config/tessera/tessera-agent-host\" connect --stdio --runtime-base \"$HOME/.config/tessera/agent-host\" --context-from-hello"
}

/// A cancellable child exec channel built directly on Citadel's `withExec`.
/// It never touches the owning terminal's PTY.  `cancel()` closes the child
/// writer/channel and leaves the authenticated SSH client (and therefore the
/// user's interactive terminal, forwards, and sibling channels) alive.
@MainActor
final class AppleCitadelAgentExecHandle: AppleAgentStreamingExecHandle {
    private static let maximumBufferedFrames = 128

    private let binding: AgentTerminalBinding
    private let isBindingCurrent: @MainActor @Sendable (AgentTerminalBinding) -> Bool
    private let onFinish: @MainActor @Sendable () -> Void
    private let stream: AsyncThrowingStream<AgentExecFrame, Error>
    private let continuation: AsyncThrowingStream<AgentExecFrame, Error>.Continuation
    private let iteratorBox: AppleAgentExecIteratorBox
    private var writer: TTYStdinWriter?
    private var worker: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var didFinish = false
    private var terminalError: Error?
    private var duplex = false
    private var writing = false

    private init(
        binding: AgentTerminalBinding,
        isBindingCurrent: @escaping @MainActor @Sendable (AgentTerminalBinding) -> Bool,
        onFinish: @escaping @MainActor @Sendable () -> Void,
        stream: AsyncThrowingStream<AgentExecFrame, Error>,
        continuation: AsyncThrowingStream<AgentExecFrame, Error>.Continuation
    ) {
        self.binding = binding
        self.isBindingCurrent = isBindingCurrent
        self.onFinish = onFinish
        self.stream = stream
        self.continuation = continuation
        iteratorBox = AppleAgentExecIteratorBox(stream.makeAsyncIterator())
    }

    static func open(
        client: SSHClient,
        request: AgentExecRequest,
        command: String = AppleAgentProjectorCommand.executable,
        isBindingCurrent: @escaping @MainActor @Sendable (AgentTerminalBinding) -> Bool,
        onFinish: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws -> AppleCitadelAgentExecHandle {
        let pair = AsyncThrowingStream<AgentExecFrame, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedFrames)
        )
        let handle = AppleCitadelAgentExecHandle(
            binding: request.binding,
            isBindingCurrent: isBindingCurrent,
            onFinish: onFinish,
            stream: pair.stream,
            continuation: pair.continuation
        )
        handle.duplex = request.program == .ingestionHost
        handle.start(client: client, request: request,
                     command: handle.duplex ? AppleAgentProjectorCommand.ingestionHost : command)
        try await withTaskCancellationHandler {
            try await handle.waitUntilReady()
        } onCancel: {
            Task { await handle.cancel() }
        }
        return handle
    }

    func nextFrame() async throws -> AgentExecFrame? {
        guard isBindingCurrent(binding) else {
            await cancel()
            throw AppleAgentPlatformError.staleBinding
        }
        return try await iteratorBox.next()
    }

    func cancel() async {
        worker?.cancel()
        if let writer {
            try? await writer.close()
        }
        finish(throwing: AppleAgentPlatformError.cancelled)
    }

    func send(_ data: Data) async throws {
        guard duplex, !didFinish, !writing, data.count <= 65_540,
              isBindingCurrent(binding), let writer else { throw AppleAgentPlatformError.staleBinding }
        writing = true
        defer { writing = false }
        var bytes = ByteBuffer(); bytes.writeBytes(data)
        try await writer.write(bytes)
        guard isBindingCurrent(binding), !didFinish else { throw AppleAgentPlatformError.staleBinding }
    }

    private func start(client: SSHClient, request: AgentExecRequest, command: String) {
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.withExec(command) { inbound, childWriter in
                    var stdin = ByteBuffer()
                    stdin.writeBytes(request.stdin)
                    try await childWriter.write(stdin)
                    if request.program != .ingestionHost { try await childWriter.closeInput() }
                    await self.markReady(writer: childWriter)

                    for try await output in inbound {
                        await self.emit(output)
                    }
                }
                await self.emitExit(status: 0)
                await self.finish(throwing: nil)
            } catch is CancellationError {
                await self.finish(throwing: AppleAgentPlatformError.cancelled)
            } catch let failure as SSHClient.CommandFailed {
                let status = Int32(clamping: failure.exitCode)
                await self.emitExit(status: status)
                await self.finish(throwing: nil)
            } catch {
                await self.finish(throwing: error)
            }
        }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if didFinish {
                continuation.resume(throwing: terminalError ?? AppleAgentPlatformError.streamingExecUnavailable)
            } else if writer != nil {
                continuation.resume()
            } else {
                readyContinuation = continuation
            }
        }
    }

    private func markReady(writer: TTYStdinWriter) {
        guard isBindingCurrent(binding) else {
            Task { try? await writer.close() }
            finish(throwing: AppleAgentPlatformError.staleBinding)
            return
        }
        guard !didFinish else {
            Task { try? await writer.close() }
            return
        }
        self.writer = writer
        readyContinuation?.resume()
        readyContinuation = nil
    }

    private func emit(_ output: ExecCommandOutput) {
        switch output {
        case .stdout(var buffer):
            emit(data: Data(buffer.readBytes(length: buffer.readableBytes) ?? []), stderr: false)
        case .stderr(var buffer):
            emit(data: Data(buffer.readBytes(length: buffer.readableBytes) ?? []), stderr: true)
        }
    }

    private func emit(data: Data, stderr: Bool) {
        guard isBindingCurrent(binding) else {
            Task { await self.cancel() }
            finish(throwing: AppleAgentPlatformError.staleBinding)
            return
        }
        let maximum = stderr ? AgentExecFrame.maximumDiagnosticBytes : AgentExecFrame.maximumFrameBytes
        var offset = 0
        while offset < data.count, !didFinish {
            let end = min(offset + maximum, data.count)
            let payload = data.subdata(in: offset..<end)
            let kind: AgentExecFrame.Kind = stderr ? .stderr(payload) : .stdout(payload)
            guard let frame = AgentExecFrame(
                carrierGeneration: binding.carrierGeneration,
                kind: kind
            ) else {
                finish(throwing: AppleAgentPlatformError.malformedStreamFrame)
                return
            }
            switch continuation.yield(frame) {
            case .enqueued:
                offset = end
            case .dropped:
                Task { await self.cancel() }
                finish(throwing: AppleAgentPlatformError.boundedPayloadExceeded)
                return
            case .terminated:
                Task { await self.cancel() }
                return
            @unknown default:
                finish(throwing: AppleAgentPlatformError.malformedStreamFrame)
                return
            }
        }
    }

    private func emitExit(status: Int32) {
        guard isBindingCurrent(binding) else {
            finish(throwing: AppleAgentPlatformError.staleBinding)
            return
        }
        guard !didFinish,
              let frame = AgentExecFrame(
                carrierGeneration: binding.carrierGeneration,
                kind: .exit(status: status)
              )
        else { return }
        switch continuation.yield(frame) {
        case .enqueued:
            break
        case .dropped:
            finish(throwing: AppleAgentPlatformError.boundedPayloadExceeded)
        case .terminated:
            break
        @unknown default:
            finish(throwing: AppleAgentPlatformError.malformedStreamFrame)
        }
    }

    private func finish(throwing error: Error?) {
        guard !didFinish else { return }
        didFinish = true
        terminalError = error
        writer = nil
        onFinish()
        if let error {
            continuation.finish(throwing: error)
            readyContinuation?.resume(throwing: error)
        } else {
            continuation.finish()
            readyContinuation?.resume()
        }
        readyContinuation = nil
    }
}

/// AsyncStream iterators have a mutating async `next`; keeping that iterator
/// directly on a global-actor object would hold actor-isolated inout state
/// across suspension. This single-consumer box is owned by the handle and is
/// reached only through `nextFrame()`.
private final class AppleAgentExecIteratorBox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<AgentExecFrame, Error>.AsyncIterator

    init(_ iterator: AsyncThrowingStream<AgentExecFrame, Error>.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> AgentExecFrame? {
        try await iterator.next()
    }
}

/// Host/session capability exposed to the presentation/runtime wiring.  A
/// route which lacks a reusable authenticated side channel stays visibly
/// unavailable; it does not initiate an independent password/biometric flow.
enum AppleAgentExecAvailability {
    case available(AppleAgentStreamingExecFactory)
    case unavailable(Reason)

    enum Reason: String, Sendable {
        case hostAccessRequired
        case sideChannelUnavailable
        case staleCarrier
    }
}

/// The sole Apple transport switch.  All four transport variants feed the
/// same `AppleAgentStreamingExecPort`; this factory only selects the already
/// authenticated owner that can open a child exec channel.
@MainActor
enum AppleAgentLiveRouteFactory {
    static func execAvailability(
        binding: AgentTerminalBinding,
        sshSession: SSHSession? = nil,
        moshSession: MoshSession? = nil,
        moshFileBridge: FileBridge? = nil,
        moshControlChannel: TmuxControlChannel? = nil,
        isBindingCurrent: @escaping @MainActor @Sendable (AgentTerminalBinding) -> Bool
    ) -> AppleAgentExecAvailability {
        guard isBindingCurrent(binding) else { return .unavailable(.staleCarrier) }
        switch binding.transport {
        case .ssh, .sshTmux:
            guard let sshSession else { return .unavailable(.staleCarrier) }
            return sshSession.agentProjectorExecAvailability(
                binding: binding,
                isBindingCurrent: isBindingCurrent
            )
        case .mosh:
            // Plain mosh retains the already-authenticated bootstrap ride for
            // this exact live carrier. Never create a Files bridge or prompt
            // merely because V2 opened.
            if let moshSession {
                return moshSession.agentProjectorExecAvailability(
                    binding: binding,
                    isBindingCurrent: isBindingCurrent
                )
            }
            // Compatibility for an existing Files/scrollback route owned by
            // another surface. This branch never connects that route.
            guard let moshFileBridge else { return .unavailable(.sideChannelUnavailable) }
            return moshFileBridge.agentProjectorExecAvailability(binding: binding, isBindingCurrent: isBindingCurrent)
        case .moshTmux:
            guard let moshControlChannel else { return .unavailable(.sideChannelUnavailable) }
            return moshControlChannel.agentProjectorExecAvailability(
                binding: binding,
                isBindingCurrent: isBindingCurrent
            )
        }
    }
}
