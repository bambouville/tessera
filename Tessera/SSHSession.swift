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
    // Internal (not private) so the session view can hand the same
    // auth-gating flags to the per-host FileBridge, which reuses this
    // session's credential resolution for its own SSH connection.
    let requireBiometric: Bool
    let isSecureEnclave: Bool

    /// Owns the live `PortForwarder` instances for this session's host.
    /// SessionView reads it for the top-bar chip; TunnelsRegistry
    /// registers it on appear so the global Tunnels view can project
    /// active forwarders across hosts.
    public let portForwarderManager: PortForwarderManager

    @Published public private(set) var state: SessionState = .idle
    @Published public private(set) var detectedOSHint: String?

    // TerminalSession cwd/injection surface — see the protocol docs.
    // Published: the Upload sheet's host rows refresh live when a cwd
    // arrives (tmux pane metadata lands seconds after a reattach).
    @Published public var remoteWorkingDirectory: String?
    @Published public var pendingPathInjection: String?

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
    /// Bastion clients when the host connects through a jump chain,
    /// outermost first. Closed explicitly in run()'s epilogues.
    private var upstreamClients: [SSHClient] = []

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
            pending.reject()
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
        await detectForegroundProcessNamesIfAvailable(rootPID: rootPID) ?? []
    }

    /// Agent Center needs to distinguish a failed exec-channel probe from a
    /// successful snapshot containing no agents. Swipe Pad keeps using the
    /// compatibility wrapper above, where both cases mean “no profile”.
    public func detectForegroundProcessNamesIfAvailable(
        rootPID: Int? = nil
    ) async -> [String]? {
        await detectForegroundProcessSnapshotIfAvailable(rootPID: rootPID)?.processNames
    }

    func detectForegroundProcessSnapshotIfAvailable(
        rootPID: Int? = nil
    ) async -> SwipePadPlainSSHProcessProbe.Snapshot? {
        guard case .connected = state else {
            SwipePadDiagnostics.log("plain-ssh detect skipped state=\(state)")
            return nil
        }
        guard let client else {
            SwipePadDiagnostics.log("plain-ssh detect skipped connected-without-client")
            return nil
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
            let snapshot = SwipePadPlainSSHProcessProbe.snapshot(from: text)
            SwipePadDiagnostics.log(
                "plain-ssh detect result candidateCount=\(snapshot.processNames.count) bytes=\(bytes.count)"
            )
            return snapshot
        } catch {
            SwipePadDiagnostics.log("plain-ssh detect failed error='\(error)'")
            return nil
        }
    }

    /// Runs a small, non-interactive command on the already-authenticated
    /// terminal connection. Agent Center uses this for its read-only hook
    /// check so opening the surface never creates a second SSH authentication
    /// attempt or owner-presence prompt.
    func executeConnectedCommand(_ command: String) async throws -> String {
        guard case .connected = state, let client else {
            throw NSError(
                domain: "Tessera.SSHSession",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The terminal session is not connected."]
            )
        }
        var output = try await client.executeCommand(
            command,
            maxResponseSize: 256 * 1024,
            mergeStreams: true,
            inShell: true
        )
        let bytes = output.readBytes(length: output.readableBytes) ?? []
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Connection lifecycle

    private func run() async {
        let fallbackHost = host
        let requireBiometric = self.requireBiometric
        let isSecureEnclave = self.isSecureEnclave
        var didConnect = false
        var connectedClient: SSHClient?
        var connectedChain: EstablishedSSHChain?
        let startedAt = Date()
        do {
            DiagnosticLogStore.appendSSH("connect step=auth-resolve")
            let (chain, connectedHost) = try await withPendingSSHConnectionAttempt {
                DiagnosticLogStore.appendSSH(
                    "connect step=ssh-handshake hops=\(fallbackHost.jumpChain.count + 1)"
                )
                let chain = try await establishSSHChain(
                    for: fallbackHost,
                    requireBiometric: requireBiometric,
                    isSecureEnclave: isSecureEnclave,
                    hostKeyPrompt: { [weak self] challenge in
                        await self?.promptForHostKeyVerification(challenge) ?? false
                    }
                )
                return (chain, chain.resolvedHost)
            }
            let client = chain.client
            connectedClient = client
            connectedChain = chain
            didConnect = true
            DiagnosticLogStore.appendSSH(
                "connect result=connected durationMs=\(Self.durationMs(since: startedAt)) rules=\(connectedHost.portForwardRules.count)"
            )
            await MainActor.run {
                self.client = client
                self.upstreamClients = chain.upstream
                self.state = .connected
            }
            Task.detached(priority: .utility) { [weak self, client] in
                guard let detected = await OSDetectionProbe.run(on: client) else {
                    return
                }
                await self?.assignDetectedOSHint(detected)
            }

            let rulesToAttach = connectedHost.portForwardRules
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
            await chain.closeAll()
            await MainActor.run {
                if self.client === client {
                    self.client = nil
                    self.upstreamClients = []
                }
                self.state = .disconnected
            }
            DiagnosticLogStore.appendSSH(
                "connect result=disconnected durationMs=\(Self.durationMs(since: startedAt))"
            )
        } catch is CancellationError {
            await self.portForwarderManager.detach()
            if let connectedChain { await connectedChain.closeAll() }
            await MainActor.run {
                if let connectedClient, self.client === connectedClient {
                    self.client = nil
                    self.upstreamClients = []
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
                if let connectedChain { await connectedChain.closeAll() }
                await MainActor.run {
                    if let connectedClient, self.client === connectedClient {
                        self.client = nil
                        self.upstreamClients = []
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
