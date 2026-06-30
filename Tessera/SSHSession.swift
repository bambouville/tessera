import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH
import PortForwarding

/// Owns the Citadel `SSHClient` for a single host and exposes a simple
/// input/output byte interface the UI can bind to.
///
/// Two AsyncStreams plumb bytes across the Concurrency boundary:
///
///   - `outputStream` — bytes the remote pty emitted, consumed by the UI
///                      and fed into SwiftTerm's `TerminalView.feed`.
///   - `inputStream`  — bytes the user typed, consumed inside the PTY
///                      task and written to the Citadel stdin writer.
///
/// The session is single-use: `connect()` spawns a long-lived task that
/// owns the Citadel connection and shell loop; `disconnect()` cancels
/// that task and transitions to `.disconnected`.
///
/// Conforms to `TerminalSession` so transport-agnostic wiring (tmux
/// fanout, tests) can drive it uniformly; the mosh variant will adopt
/// the same protocol. SSH-specific state (`pendingHostKeyVerification`)
/// stays on this concrete type rather than being hoisted to the
/// protocol.
@MainActor
public final class SSHSession: ObservableObject, TerminalSession {

    public let host: Host
    private let requireBiometric: Bool
    private let isSecureEnclave: Bool

    /// Owns the live `PortForwarder` instances for this session's host.
    /// SessionView reads it for the top-bar chip; TunnelsRegistry
    /// registers it on appear so the global Tunnels view can project
    /// active forwarders across hosts.
    public let portForwarderManager: PortForwarderManager

    @Published public private(set) var state: SessionState = .idle
    @Published public private(set) var detectedOSHint: String?

    /// Set by the host key validator when the server's key is unknown
    /// or has changed. ContentView presents `HostKeyVerificationView`
    /// when this is non-nil.
    @Published var pendingHostKeyVerification: HostKeyVerificationRequest?

    /// Output bytes from the remote pty. UI subscribes to this stream
    /// and feeds each chunk into SwiftTerm via `TerminalView.feed`.
    public let outputStream: AsyncStream<[UInt8]>
    private let outputContinuation: AsyncStream<[UInt8]>.Continuation

    /// Input bytes from the UI (keystrokes, paste). The PTY task reads
    /// this stream and writes to Citadel's stdin writer.
    private let inputStream: AsyncStream<[UInt8]>
    private let inputContinuation: AsyncStream<[UInt8]>.Continuation

    /// Out-of-band control messages (window resize, etc.). Kept separate
    /// from the byte input stream so resize requests aren't interleaved
    /// with typed characters.
    fileprivate enum ControlMessage: Sendable {
        case resize(cols: Int, rows: Int)
    }
    private let controlStream: AsyncStream<ControlMessage>
    private let controlContinuation: AsyncStream<ControlMessage>.Continuation

    /// The last window size SwiftTerm reported. Cached so we can replay
    /// it to Citadel the moment the connection is established — layout
    /// often fires sizeChanged before the PTY channel exists.
    private var lastReportedSize: (cols: Int, rows: Int)?

    private var runTask: Task<Void, Never>?
    private var client: SSHClient?

    public init(
        host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false
    ) {
        self.host = host
        self.requireBiometric = requireBiometric
        self.isSecureEnclave = isSecureEnclave
        self.portForwarderManager = PortForwarderManager()
        (outputStream, outputContinuation) = AsyncStream.makeStream(of: [UInt8].self)
        (inputStream, inputContinuation) = AsyncStream.makeStream(of: [UInt8].self)
        (controlStream, controlContinuation) = AsyncStream.makeStream(of: ControlMessage.self)
    }

    deinit {
        outputContinuation.finish()
        inputContinuation.finish()
        controlContinuation.finish()
    }

    // MARK: - Public API

    /// Begin connecting to the host and open a PTY shell. Idempotent
    /// while connecting/connected.
    public func connect() {
        switch state {
        case .connecting, .connected:
            return
        case .idle, .disconnected, .failed:
            break
        }
        state = .connecting
        DiagnosticLogStore.appendSSH(
            "connect start transport=\(host.transport.rawValue) launchMode=\(host.launchMode.rawValue) authKind=\(authKindDescription(for: host)) biometricRequired=\(requireBiometric) secureEnclave=\(isSecureEnclave)"
        )
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// Push bytes to the remote shell's stdin. No-op before connection.
    public func send(_ bytes: [UInt8]) {
        guard case .connected = state else { return }
        inputContinuation.yield(bytes)
    }

    /// Push a new window size to the remote shell. Safe to call at any
    /// lifecycle stage — events queue in the control stream until the
    /// PTY task starts draining. Also caches the last value so the
    /// initial 80×24 PTY request can be corrected immediately after
    /// the connection is established.
    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lastReportedSize = (cols, rows)
        controlContinuation.yield(.resize(cols: cols, rows: rows))
    }

    /// Cancel the session and transition to `.disconnected`.
    public func disconnect() {
        // Resume any pending host key verification with rejection
        // so the CheckedContinuation doesn't leak.
        if let pending = pendingHostKeyVerification {
            pending.continuation.resume(returning: false)
            pendingHostKeyVerification = nil
        }
        client = nil
        runTask?.cancel()
        runTask = nil
        inputContinuation.yield([]) // wake the write loop so it can exit
        state = .disconnected
        DiagnosticLogStore.appendSSH("disconnect requested")
    }

    /// Plain-SSH fallback for swipe-pad profile detection. tmux control mode
    /// is more exact when available; this path asks the remote host for a
    /// process snapshot over an SSH exec channel so no probe bytes are written
    /// into the user's interactive terminal.
    public func detectForegroundProcessNames(rootPID: Int? = nil) async -> [String] {
        guard case .connected = state else {
            SwipePadDiagnostics.log("plain-ssh detect skipped state=\(state)")
            return []
        }
        guard let client else {
            SwipePadDiagnostics.log("plain-ssh detect skipped connected-without-client")
            return []
        }

        do {
            let command = SwipePadPlainSSHProcessProbe.makeCommand(rootPID: rootPID)
            SwipePadDiagnostics.log("plain-ssh detect begin rootPIDPresent=\(rootPID != nil)")
            var output = try await client.executeCommand(
                command,
                maxResponseSize: 128 * 1024,
                mergeStreams: true,
                inShell: true
            )
            let bytes = output.readBytes(length: output.readableBytes) ?? []
            let text = String(decoding: bytes, as: UTF8.self)
            let names = SwipePadPlainSSHProcessProbe.processNames(from: text)
            SwipePadDiagnostics.log(
                "plain-ssh detect result candidateCount=\(names.count) bytes=\(bytes.count)"
            )
            return names
        } catch {
            SwipePadDiagnostics.log("plain-ssh detect failed error='\(error)'")
            return []
        }
    }

    // MARK: - Connection lifecycle

    private func run() async {
        let capturedHost = host
        let requireBiometric = self.requireBiometric
        let isSecureEnclave = self.isSecureEnclave
        var didConnect = false
        var connectedClient: SSHClient?
        let startedAt = Date()
        do {
            DiagnosticLogStore.appendSSH("connect step=auth-resolve")
            let authMethod = try await resolveSSHAuthMethod(
                for: capturedHost,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave
            )
            DiagnosticLogStore.appendSSH("connect step=ssh-handshake port=\(capturedHost.port)")
            let endpoint = "\(capturedHost.address):\(capturedHost.port)"
            let validator = TesseraHostKeyValidator(
                endpoint: endpoint,
                prompt: { [weak self] challenge in
                    await self?.promptForHostKeyVerification(challenge) ?? false
                }
            )
            let client = try await SSHClient.connect(
                host: capturedHost.address,
                port: capturedHost.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
            connectedClient = client
            didConnect = true
            DiagnosticLogStore.appendSSH(
                "connect result=connected durationMs=\(Self.durationMs(since: startedAt)) rules=\(capturedHost.portForwardRules.count)"
            )
            await MainActor.run {
                self.client = client
                self.state = .connected
            }
            Task.detached(priority: .utility) { [weak self, client] in
                guard let detected = await OSDetectionProbe.run(on: client) else {
                    return
                }
                await self?.assignDetectedOSHint(detected)
            }

            let rulesToAttach = capturedHost.portForwardRules
            await MainActor.run {
                self.portForwarderManager.attach(to: client, rules: rulesToAttach)
            }

            let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: 80,
                terminalRowHeight: 24,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )

            try await client.withPTY(ptyRequest) {
                (ttyOutput: TTYOutput, stdinWriter: TTYStdinWriter) in
                try await self.runShellLoops(ttyOutput: ttyOutput, stdinWriter: stdinWriter)
            }

            await self.portForwarderManager.detach()
            await MainActor.run {
                if self.client === client {
                    self.client = nil
                }
                self.state = .disconnected
            }
            DiagnosticLogStore.appendSSH(
                "connect result=disconnected durationMs=\(Self.durationMs(since: startedAt))"
            )
        } catch is CancellationError {
            await self.portForwarderManager.detach()
            await MainActor.run {
                if let connectedClient, self.client === connectedClient {
                    self.client = nil
                }
                self.state = .disconnected
            }
            DiagnosticLogStore.appendSSH(
                "connect result=cancelled didConnect=\(didConnect) durationMs=\(Self.durationMs(since: startedAt))"
            )
        } catch {
            await self.portForwarderManager.detach()
            // Post-connect errors are treated as clean disconnection, not
            // failure. A Ctrl+D exit throws "Already closed" from somewhere
            // in Citadel's teardown path after the remote shell ends; a
            // dropped TCP session throws a NIO channel error. From the
            // user's perspective both are "the session ended, take me back"
            // — only pre-connect errors (auth failed, host unreachable)
            // deserve the red failed banner.
            if didConnect {
                await MainActor.run {
                    if let connectedClient, self.client === connectedClient {
                        self.client = nil
                    }
                    self.state = .disconnected
                }
                DiagnosticLogStore.appendSSH(
                    "connect result=post-connect-disconnect durationMs=\(Self.durationMs(since: startedAt)) error='\(error)'"
                )
            } else {
                let description = describeSSHError(error)
                await MainActor.run {
                    if let connectedClient, self.client === connectedClient {
                        self.client = nil
                    }
                    self.state = .failed(description)
                }
                DiagnosticLogStore.appendSSH(
                    "connect result=failed durationMs=\(Self.durationMs(since: startedAt)) error='\(error)'"
                )
            }
        }
    }

    /// Concurrent output/input/control drain loops. Returns when the
    /// output stream closes (clean shell exit) or the session is
    /// cancelled.
    private nonisolated func runShellLoops(
        ttyOutput: TTYOutput,
        stdinWriter: TTYStdinWriter
    ) async throws {
        // Replay any size that SwiftTerm reported before the PTY was
        // open. Without this the remote shell stays at the 80×24
        // default for full-screen TUIs until the user manually resizes.
        if let cached = await self.lastReportedSize {
            try? await stdinWriter.changeSize(
                cols: cached.cols,
                rows: cached.rows,
                pixelWidth: 0,
                pixelHeight: 0
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Output drain: ttyOutput yields .stdout(ByteBuffer) and
            // .stderr(ByteBuffer). We flatten both into the output stream.
            group.addTask {
                for try await event in ttyOutput {
                    switch event {
                    case .stdout(let buf), .stderr(let buf):
                        var b = buf
                        if let bytes = b.readBytes(length: b.readableBytes) {
                            await self.yieldOutput(bytes)
                        }
                    }
                }
            }

            // Input drain: read user keystrokes from inputStream and
            // write them to the remote stdin.
            let inputStream = await self.inputStream
            group.addTask {
                for await bytes in inputStream {
                    if bytes.isEmpty { continue } // disconnect wake-up
                    var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
                    buffer.writeBytes(bytes)
                    try await stdinWriter.write(buffer)
                }
            }

            // Control drain: out-of-band messages like SIGWINCH.
            // Errors from changeSize (e.g. channel closing during a
            // resize) are swallowed — the output drain will hit the
            // same close and terminate the group cleanly.
            let controlStream = await self.controlStream
            group.addTask {
                for await message in controlStream {
                    switch message {
                    case .resize(let cols, let rows):
                        try? await stdinWriter.changeSize(
                            cols: cols,
                            rows: rows,
                            pixelWidth: 0,
                            pixelHeight: 0
                        )
                    }
                }
            }

            // Wait for any task to end, then cancel the others. The
            // output drain ending means the shell exited; input and
            // control drains only terminate via cancellation.
            try await group.next()
            group.cancelAll()
        }
    }

    /// Bridge for the nonisolated loop to yield onto the main-actor
    /// continuation.
    private func yieldOutput(_ bytes: [UInt8]) {
        outputContinuation.yield(bytes)
    }

    /// Main-actor entry point so the detached probe task can assign
    /// `detectedOSHint` without needing a `[weak self]` mutation
    /// inside a Sendable closure.
    fileprivate func assignDetectedOSHint(_ value: String) {
        detectedOSHint = value
    }

    @MainActor
    private func promptForHostKeyVerification(
        _ challenge: HostKeyVerificationChallenge
    ) async -> Bool {
        let status = challenge.isChanged ? "changed" : "unknown"
        DiagnosticLogStore.appendSSH(
            "hostkey prompt status=\(status) keyType=\(challenge.keyType)"
        )
        let result = await withCheckedContinuation { continuation in
            pendingHostKeyVerification = HostKeyVerificationRequest(
                challenge: challenge,
                continuation: continuation
            )
        }
        pendingHostKeyVerification = nil
        DiagnosticLogStore.appendSSH(
            "hostkey prompt result=\(result ? "accepted" : "rejected") status=\(status) keyType=\(challenge.keyType)"
        )
        return result
    }

    private static func durationMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    private func authKindDescription(for host: Host) -> String {
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
