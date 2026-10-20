import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH
import PortForwarding
import TesseraCore

/// Owns the Citadel `SSHClient` for a single host and exposes a simple
/// input/output byte interface the UI can bind to.
///
/// AsyncStreams plumb bytes across the Concurrency boundary:
///
///   - `outputStream` — bytes the remote pty emitted, consumed by the UI
///                      and fed into SwiftTerm's `TerminalView.feed`.
///   - generation-scoped input/control streams — created for each PTY so a
///                      cancelled child cannot poison its replacement.
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
/// Non-zero while a system authentication sheet or a host-key decision owns a
/// connect path. The handshake budget must never accrue against a human: a
/// passcode fallback can legitimately outlast it, and cancelling would tear the
/// system sheet down under the user's finger and report a path-MTU stall that
/// never happened.
///
/// Global rather than per-session on purpose. `HostKeyVerificationCoordinator`
/// coalesces identical challenges, so sessions that are *waiting* on another
/// session's prompt run no prompt of their own and would otherwise keep
/// charging.
/// Whether one connection attempt put an owner prompt in front of the user.
///
/// A background check binds one around its own connection. Prompts reach it
/// through the task tree (the key's Face ID evaluation runs in a task the
/// connection starts), so another tab's prompt, or one this attempt merely
/// joined, is not counted; neither is a cached grant, which begins none.
/// A sheet the system took down (Control Center, an incoming call) asked the
/// user nothing they answered.
final class SSHPromptAttribution: @unchecked Sendable {
    @TaskLocal static var current: SSHPromptAttribution?

    private let lock = NSLock()
    private var began = 0
    private var interrupted = 0

    /// A prompt was begun and none was taken down by the system. One that was
    /// (Control Center during the second hop's Face ID) stopped the attempt
    /// before the user could finish answering, whatever an earlier hop asked.
    var askedOwner: Bool { lock.withLock { began > 0 && interrupted == 0 } }

    func noteBegan() { lock.withLock { began += 1 } }
    func noteInterruptedBySystem() { lock.withLock { interrupted += 1 } }
}

@MainActor
enum SSHHandshakePromptGate {
    private static var depth = 0

    static var isPrompting: Bool { depth > 0 }

    static func begin() {
        depth += 1
        SSHPromptAttribution.current?.noteBegan()
        if depth == 1 {
            NotificationCenter.default.post(name: .tesseraHandshakePromptChanged, object: nil)
        }
    }

    static func end() {
        let wasPrompting = depth > 0
        depth = max(0, depth - 1)
        if wasPrompting, depth == 0 {
            NotificationCenter.default.post(name: .tesseraHandshakePromptChanged, object: nil)
        }
    }
}

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
    /// Monotonic identity of the interactive PTY child channel. A poisoned
    /// inline tmux command stream can replace this child without redoing the
    /// authenticated SSH connection, exec probes, Files bridge, or forwards.
    @Published public private(set) var interactivePTYGeneration = 0
    @Published public private(set) var detectedOSHint: String?
    @Published private(set) var wslTailscaleMTUWarning: WSLTailscaleMTUWarning?
    #if DEBUG
    /// Host-free navigation harness oracles. The task-start count detects view
    /// remounts immediately; connect calls are intercepted before socket state.
    @Published private(set) var compactNavigationHarnessSessionTaskStartCount = 0
    @Published private(set) var compactNavigationHarnessConnectCallCount = 0

    func noteCompactNavigationHarnessSessionTaskStart() {
        guard ProcessInfo.processInfo.environment[
            "TESSERA_COMPACT_NAVIGATION_HARNESS"
        ] == "1" else { return }
        compactNavigationHarnessSessionTaskStartCount += 1
    }
    #endif

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
    nonisolated private let outputContinuation: AsyncStream<[UInt8]>.Continuation
    let appleAttemptOutputEvents: AsyncStream<SessionAttemptOutputChunk>
    nonisolated private let appleAttemptOutputContinuation: AsyncStream<SessionAttemptOutputChunk>.Continuation
    nonisolated let appleOutputQueueDiagnostics: AsyncDeliveryDiagnostics?
    nonisolated private let publicationDiagnostics: AsyncDeliveryDiagnostics
    nonisolated private let inputWriteDiagnostics: AsyncDeliveryDiagnostics
    private var preparedAppleSessionAttemptID: UUID?
    private var activeAppleSessionAttemptID: UUID?

    /// Input bytes from the UI (keystrokes, paste). The PTY task reads
    /// this stream and writes to Citadel's stdin writer.
    private struct InputChunk: Sendable {
        let attemptID: UUID
        let ptyGeneration: Int
        let bytes: [UInt8]
        let admittedNanos: UInt64
        let diagnosticContext: String?
        let queueDiagnostics: AsyncDeliveryDiagnostics
    }
    private struct PTYStreamOwner: Hashable, Sendable {
        let attemptID: UUID
        let ptyGeneration: Int
    }

    private struct PTYStreams: Sendable {
        let input: AsyncStream<InputChunk>
        let inputContinuation: AsyncStream<InputChunk>.Continuation
        let control: AsyncStream<ControlMessage>
        let controlContinuation: AsyncStream<ControlMessage>.Continuation
        let owner: PTYStreamOwner
        let inputQueueDiagnostics: AsyncDeliveryDiagnostics
    }

    /// Only the streams owned by the current PTY are published here. Citadel's
    /// shell loop cancels its input/control consumers whenever output ends;
    /// reusing one process-lifetime AsyncStream after that cancellation makes
    /// the replacement consumer return immediately and closes the new PTY.
    private var activePTYStreamOwner: PTYStreamOwner?
    private var activeInputContinuation: AsyncStream<InputChunk>.Continuation?
    private var activeControlContinuation: AsyncStream<ControlMessage>.Continuation?
    /// Covers the short interval after `.connected` is published but before
    /// Citadel invokes the PTY body. Chunks remain tied to their exact attempt
    /// and generation, so recovery can never replay ambiguous old input.
    private var pendingInputChunks: [InputChunk] = []
    private var inputQueueDiagnosticsByOwner: [PTYStreamOwner: AsyncDeliveryDiagnostics] = [:]
    private var nextWriteDiagnosticContext: String?

    func noteCommandWriteDiagnostic(sequence: Int, correlation: String?) {
        nextWriteDiagnosticContext = correlation.map { "tmuxSequence=\(sequence) corr=\($0)" }
    }

    func noteTransportInputDiagnostic(correlation: String?) {
        nextWriteDiagnosticContext = correlation.map { "corr=\($0)" }
    }

    /// Out-of-band control messages (window resize, etc.). Kept separate
    /// from the byte input stream so resize requests aren't interleaved
    /// with typed characters.
    fileprivate enum ControlMessage: Sendable {
        case resize(cols: Int, rows: Int)
    }
    /// The last window size SwiftTerm reported. Cached so we can replay
    /// it to Citadel the moment the connection is established — layout
    /// often fires sizeChanged before the PTY channel exists.
    private var lastReportedSize: (cols: Int, rows: Int)?

    private var runTask: Task<Void, Never>?
    /// Writer for the current interactive child channel. Closing it replaces
    /// only the PTY and unblocks a wedged NIO `writeAndFlush`; the parent SSH
    /// client remains authenticated and continues owning its other channels.
    private var activeTTYWriter: TTYStdinWriter?
    private var interactivePTYRecoveryPendingGeneration: Int?

    /// Wall-clock budget for everything before `.connected`: TCP connect,
    /// banner, kex, auth and the chain's per-hop repeats. Citadel bounds only
    /// the TCP connect; a path-MTU blackhole completes TCP and then stalls in
    /// kex forever, parking the session in `.connecting` with no terminal
    /// state at all. Session restore resolves its cohort on terminal states,
    /// so an unbounded `.connecting` would hold that window open until the
    /// backstop instead of failing honestly.
    ///
    /// Deliberately generous: it is a backstop against permafreeze, not a
    /// responsiveness timer, and it must not preempt Citadel's own 30s TCP
    /// connect timeout on a slow link. The window ends at the chain
    /// handshake, so it never overlaps the tmux `-CC` launch watchdog.
    static let handshakeBudgetSeconds: TimeInterval = 40
    private static let handshakeWatchdogTickNanoseconds: UInt64 = 500_000_000
    /// Longest tick delta charged to the budget. Anything larger means the
    /// process was suspended, not that the handshake stalled.
    private static let handshakeWatchdogMaxTickSeconds: TimeInterval = 2

    private var handshakeWatchdog: Task<Void, Never>?
    private var handshakeDidTimeOut = false
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
        appleOutputQueueDiagnostics = SessionLatencyDiagnostics.queue(host: host.id, stage: "ssh-published-to-facade")
        publicationDiagnostics = SessionLatencyDiagnostics.queue(host: host.id, stage: "ssh-read-to-stream-publication")
        inputWriteDiagnostics = SessionLatencyDiagnostics.queue(host: host.id, stage: "ssh-write-and-flush")
        self.requireBiometric = requireBiometric
        self.isSecureEnclave = isSecureEnclave
        self.portForwarderManager = PortForwarderManager()
        self.wslTailscaleMTUWarning = HostRuntimeStateStore.wslTailscaleMTUWarning(
            for: host
        )
        (outputStream, outputContinuation) = AsyncStream.makeStream(of: [UInt8].self)
        (appleAttemptOutputEvents, appleAttemptOutputContinuation) = AsyncStream.makeStream(
            of: SessionAttemptOutputChunk.self
        )
    }

    deinit {
        outputContinuation.finish()
        appleAttemptOutputContinuation.finish()
        activeInputContinuation?.finish()
        activeControlContinuation?.finish()
    }

    // MARK: - Public API

    func prepareAppleSessionAttempt(_ attemptID: UUID) {
        preparedAppleSessionAttemptID = attemptID
    }

    var appleActiveSessionAttemptID: UUID? {
        activeAppleSessionAttemptID
    }

    /// Begin connecting to the host and open a PTY shell. Idempotent
    /// while connecting/connected.
    public func connect() {
        #if DEBUG
        if ProcessInfo.processInfo.environment[
            "TESSERA_COMPACT_NAVIGATION_HARNESS"
        ] == "1" {
            compactNavigationHarnessConnectCallCount += 1
            return
        }
        #endif

        switch state {
        case .connecting, .connected:
            return
        case .idle, .disconnected, .failed:
            break
        }
        // Shipped Apple presentation always prepares an attempt through
        // SessionEngine. Keep the released TerminalSession API usable by
        // transport integration fixtures and other direct, UI-free clients;
        // the generated token still gives their output one stable provenance.
        let attemptID = preparedAppleSessionAttemptID ?? UUID()
        preparedAppleSessionAttemptID = nil
        activeAppleSessionAttemptID = attemptID
        state = .connecting
        DiagnosticLogStore.appendSSH(
            "connect start transport=\(host.transport.rawValue) launchMode=\(host.launchMode.rawValue) authKind=\(authKindDescription(for: host)) biometricRequired=\(requireBiometric) secureEnclave=\(isSecureEnclave)"
        )
        armHandshakeWatchdog()
        runTask = Task { [weak self] in
            await self?.run(attemptID: attemptID)
        }
    }

    /// Fail a handshake that will never terminate on its own.
    ///
    /// Self-disarming: the loop exits the moment `state` leaves `.connecting`,
    /// so every success and every real failure retires it without the callers
    /// having to remember to. Charging only clamped, non-prompt time keeps a
    /// backgrounded app and a waiting user from spending the budget.
    private func armHandshakeWatchdog() {
        handshakeWatchdog?.cancel()
        handshakeDidTimeOut = false
        handshakeWatchdog = Task { @MainActor [weak self] in
            var spent: TimeInterval = 0
            var lastTick = Date()
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: Self.handshakeWatchdogTickNanoseconds
                )
                guard !Task.isCancelled, let self else { return }
                guard case .connecting = self.state else { return }

                let now = Date()
                let delta = min(
                    now.timeIntervalSince(lastTick),
                    Self.handshakeWatchdogMaxTickSeconds
                )
                lastTick = now
                if !SSHHandshakePromptGate.isPrompting {
                    spent += delta
                }
                guard spent >= Self.handshakeBudgetSeconds else { continue }

                DiagnosticLogStore.appendSSH(
                    "connect result=handshake-timeout budgetSeconds=\(Int(Self.handshakeBudgetSeconds))"
                )
                self.handshakeDidTimeOut = true
                self.runTask?.cancel()
                return
            }
        }
    }

    private func disarmHandshakeWatchdog() {
        handshakeWatchdog?.cancel()
        handshakeWatchdog = nil
    }

    /// Push bytes to the remote shell's stdin. No-op before connection.
    public func send(_ bytes: [UInt8]) {
        sendAdmitting(bytes)
    }

    /// Admit bytes to the ordered input queue for this attempt and PTY owner.
    /// Compact tmux sizing publishes synchronously at this boundary, before
    /// the writer can produce a layout reply on the output stream.
    @discardableResult
    func sendAdmitting(_ bytes: [UInt8]) -> Bool {
        let diagnosticContext = nextWriteDiagnosticContext
        nextWriteDiagnosticContext = nil
        guard !bytes.isEmpty, case .connected = state,
              interactivePTYRecoveryPendingGeneration == nil,
              let attemptID = activeAppleSessionAttemptID,
              interactivePTYGeneration > 0
        else { return false }
        let owner = PTYStreamOwner(
            attemptID: attemptID,
            ptyGeneration: interactivePTYGeneration
        )
        let queueDiagnostics = inputQueueDiagnostics(for: owner)
        let chunk = InputChunk(
            attemptID: attemptID,
            ptyGeneration: interactivePTYGeneration,
            bytes: bytes,
            admittedNanos: DispatchTime.now().uptimeNanoseconds,
            diagnosticContext: diagnosticContext,
            queueDiagnostics: queueDiagnostics
        )
        queueDiagnostics.enqueued()
        if activePTYStreamOwner == owner, let activeInputContinuation {
            switch activeInputContinuation.yield(chunk) {
            case .enqueued: return true
            case .dropped, .terminated:
                queueDiagnostics.discarded(count: 1)
                return false
            @unknown default:
                queueDiagnostics.discarded(count: 1)
                return false
            }
        } else {
            pendingInputChunks.append(chunk)
            return true
        }
    }

    /// Recover a wedged inline tmux command channel without publishing a
    /// terminal state to the logical session. Citadel child-channel close is
    /// not a safe in-place PTY replacement: on real OpenSSH/tmux 3.4 servers a
    /// replacement shell can open and then immediately receive EOF, which the
    /// owning connection used to publish as `.disconnected` and remove from
    /// the sidebar. Tear down and re-establish the authenticated transport
    /// under the same attempt instead. The Apple session engine intentionally
    /// keeps presenting `.connected` while legacy state is `.connecting`, so
    /// the live row and restore marker remain stable during this exceptional
    /// recovery window.
    ///
    /// Input is fail-closed until the replacement generation exists. Bytes
    /// already buffered for the old generation remain generation-tagged and
    /// are never replayed after ambiguous delivery.
    @discardableResult
    func requestInteractivePTYRecovery(reason: String) -> Bool {
        guard case .connected = state,
              interactivePTYRecoveryPendingGeneration == nil,
              let writer = activeTTYWriter,
              interactivePTYGeneration > 0
        else { return false }
        let generation = interactivePTYGeneration
        interactivePTYRecoveryPendingGeneration = generation
        state = .connecting
        DiagnosticLogStore.appendSSH(
            "interactive-transport recovery requested generation=\(generation) reason=\(reason)"
        )
        Task {
            try? await writer.close()
        }
        runTask?.cancel()
        return true
    }

    /// Push a new window size to the remote shell. Safe to call at any
    /// lifecycle stage. The latest value is cached until the PTY task starts
    /// and later changes go to that generation's control stream. Also caches
    /// the last value so the
    /// initial 80×24 PTY request can be corrected immediately after
    /// the connection is established.
    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lastReportedSize = (cols, rows)
        activeControlContinuation?.yield(.resize(cols: cols, rows: rows))
    }

    /// Cancel the session and transition to `.disconnected`.
    public func disconnect() {
        // Resume any pending host key verification with rejection
        // so the CheckedContinuation doesn't leak.
        if let pending = pendingHostKeyVerification {
            pending.reject()
            pendingHostKeyVerification = nil
        }
        let writer = activeTTYWriter
        activeTTYWriter = nil
        finishActivePTYStreams()
        for chunk in pendingInputChunks {
            chunk.queueDiagnostics.discarded(count: 1)
        }
        pendingInputChunks.removeAll(keepingCapacity: false)
        inputQueueDiagnosticsByOwner.removeAll(keepingCapacity: false)
        interactivePTYRecoveryPendingGeneration = nil
        client = nil
        disarmHandshakeWatchdog()
        runTask?.cancel()
        runTask = nil
        preparedAppleSessionAttemptID = nil
        activeAppleSessionAttemptID = nil
        state = .disconnected
        DiagnosticLogStore.appendSSH("disconnect requested")
        Task {
            try? await writer?.close()
        }
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
        rootPID: Int? = nil, expectedPID: Int? = nil
    ) async -> SwipePadPlainSSHProcessProbe.Snapshot? {
        guard case .connected = state else {
            SwipePadDiagnostics.log("plain-ssh detect skipped state=\(state)")
            return nil
        }
        guard client != nil else {
            SwipePadDiagnostics.log("plain-ssh detect skipped connected-without-client")
            return nil
        }

        do {
            let command = SwipePadPlainSSHProcessProbe.makeCommand(rootPID: rootPID, expectedPID: expectedPID)
            SwipePadDiagnostics.log("plain-ssh detect begin rootPIDPresent=\(rootPID != nil)")
            let text = try await executeAgentIntegrationProbeCommand(command)
            let snapshot = SwipePadPlainSSHProcessProbe.snapshot(from: text)
            SwipePadDiagnostics.log(
                "plain-ssh detect result candidateCount=\(snapshot.processNames.count) bytes=\(text.utf8.count)"
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
    /// `inShell: false` runs the command as an SSH exec request
    /// (`$SHELL -c …`) instead of feeding it to an interactive shell —
    /// the same reasoning as `OSDetectionProbe`: a host whose login
    /// dotfiles `exec tmux` would otherwise swallow the probe channel.
    func executeConnectedCommand(
        _ command: String,
        inShell: Bool = true
    ) async throws -> String {
        guard case .connected = state, let client else {
            throw NSError(
                domain: "Tessera.SSHSession",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "The terminal session is not connected.")]
            )
        }
        var output = try await client.executeCommand(
            command,
            maxResponseSize: 256 * 1024,
            mergeStreams: true,
            inShell: inShell
        )
        let bytes = output.readBytes(length: output.readableBytes) ?? []
        return String(decoding: bytes, as: UTF8.self)
    }

    func executeAgentInstallationCommand(_ command: String) async throws -> String {
        guard case .connected = state, let client else { throw AppleAgentPlatformError.staleBinding }
        return try await AppleAgentInstallationExec.run(client: client, command: command)
    }

    func executeAgentIntegrationProbeCommand(_ command: String) async throws -> String {
        guard case .connected = state, let client else { throw AppleAgentPlatformError.staleBinding }
        let attemptID = activeAppleSessionAttemptID
        let output = try await AppleAgentBoundedCommandExec.run(client: client, command: command)
        guard case .connected = state, self.client === client,
              activeAppleSessionAttemptID == attemptID else { throw AppleAgentPlatformError.staleBinding }
        return output
    }

    /// Returns a child-exec factory for the exact currently-owned SSH route.
    /// This intentionally does not use `executeConnectedCommand`: that helper
    /// buffers and merges output, whereas Agent projection requires bounded
    /// split streams and child-only cancellation.
    func agentProjectorExecAvailability(
        binding: AgentTerminalBinding,
        isBindingCurrent: @escaping @MainActor @Sendable (AgentTerminalBinding) -> Bool
    ) -> AppleAgentExecAvailability {
        guard binding.transport == .ssh || binding.transport == .sshTmux,
              case .connected = state,
              let client,
              interactivePTYGeneration > 0
        else { return .unavailable(.staleCarrier) }

        let expectedPTYGeneration = interactivePTYGeneration
        return .available(AppleAgentStreamingExecFactory { [weak self, client] request in
            guard request.binding == binding else {
                throw AppleAgentPlatformError.staleBinding
            }
            let stillCurrent = await MainActor.run { [weak self] in
                guard let self,
                      case .connected = self.state,
                      self.client === client,
                      self.interactivePTYGeneration == expectedPTYGeneration,
                      isBindingCurrent(request.binding)
                else { return false }
                return true
            }
            guard stillCurrent else { throw AppleAgentPlatformError.staleBinding }
            return try await AppleCitadelAgentExecHandle.open(
                client: client,
                request: request,
                isBindingCurrent: isBindingCurrent
            )
        })
    }

    // MARK: - Connection lifecycle

    private func run(attemptID: UUID) async {
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
            let remainsActive = await MainActor.run {
                self.activeAppleSessionAttemptID == attemptID
            }
            guard remainsActive else {
                await chain.closeAll()
                return
            }
            didConnect = true
            DiagnosticLogStore.appendSSH(
                "connect result=connected durationMs=\(Self.durationMs(since: startedAt)) rules=\(connectedHost.portForwardRules.count)"
            )
            await MainActor.run {
                guard self.activeAppleSessionAttemptID == attemptID else { return }
                self.client = client
                self.upstreamClients = chain.upstream
                self.interactivePTYGeneration &+= 1
                self.interactivePTYRecoveryPendingGeneration = nil
                self.state = .connected
            }
            Task.detached(priority: .utility) { [weak self, client] in
                guard let result = await OSDetectionProbe.run(on: client) else {
                    return
                }
                await self?.assignDetectionResult(result)
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

            while !Task.isCancelled {
                let ptyGeneration = await MainActor.run {
                    self.interactivePTYGeneration
                }
                do {
                    let readDiagnostics = DiagnosticLogStore.isVerboseEnabled ? TTYOutputDiagnostics() : nil
                    try await client.withPTY(ptyRequest, outputDiagnostics: readDiagnostics) {
                        (ttyOutput: TTYOutput, stdinWriter: TTYStdinWriter) in
                        await MainActor.run {
                            guard self.activeAppleSessionAttemptID == attemptID,
                                  self.interactivePTYGeneration == ptyGeneration
                            else { return }
                            self.activeTTYWriter = stdinWriter
                            DiagnosticLogStore.appendSSH(
                                "interactive-pty ready generation=\(ptyGeneration)"
                            )
                        }
                        do {
                            try await self.runShellLoops(
                                ttyOutput: ttyOutput,
                                stdinWriter: stdinWriter,
                                attemptID: attemptID,
                                ptyGeneration: ptyGeneration,
                                readDiagnostics: readDiagnostics
                            )
                        } catch {
                            await MainActor.run {
                                if self.interactivePTYGeneration == ptyGeneration {
                                    self.activeTTYWriter = nil
                                }
                            }
                            throw error
                        }
                        await MainActor.run {
                            if self.interactivePTYGeneration == ptyGeneration {
                                self.activeTTYWriter = nil
                            }
                        }
                    }
                } catch {
                    let willRecover = await MainActor.run {
                        self.advanceInteractivePTYRecoveryIfCurrent(
                            attemptID: attemptID,
                            completedGeneration: ptyGeneration
                        )
                    }
                    if willRecover { continue }
                    throw error
                }

                let willRecover = await MainActor.run {
                    self.advanceInteractivePTYRecoveryIfCurrent(
                        attemptID: attemptID,
                        completedGeneration: ptyGeneration
                    )
                }
                if willRecover { continue }
                break
            }

            if await restartTransportAfterInteractiveRecoveryIfNeeded(
                attemptID: attemptID,
                connectedClient: connectedClient,
                connectedChain: connectedChain
            ) { return }
            await self.portForwarderManager.detach()
            await chain.closeAll()
            await MainActor.run {
                if self.client === client {
                    self.client = nil
                    self.upstreamClients = []
                }
                if self.activeAppleSessionAttemptID == attemptID {
                    self.state = .disconnected
                }
            }
            DiagnosticLogStore.appendSSH(
                "connect result=disconnected durationMs=\(Self.durationMs(since: startedAt))"
            )
        } catch is CancellationError {
            if await restartTransportAfterInteractiveRecoveryIfNeeded(
                attemptID: attemptID,
                connectedClient: connectedClient,
                connectedChain: connectedChain
            ) { return }
            await self.portForwarderManager.detach()
            if let connectedChain { await connectedChain.closeAll() }
            // A watchdog cancellation is not a user cancellation. Reporting it
            // as `.disconnected` would present a wedged handshake as a session
            // that simply ended, with no reason and no recovery affordance.
            let timedOut = self.handshakeDidTimeOut && !didConnect
            await MainActor.run {
                if let connectedClient, self.client === connectedClient {
                    self.client = nil
                    self.upstreamClients = []
                }
                guard self.activeAppleSessionAttemptID == attemptID else { return }
                self.state = timedOut
                    ? .failed(
                        String(
                            localized: "Timed out completing the SSH handshake. The connection opened but never finished negotiating — often a path-MTU blackhole on the route.",
                            comment: "SSH connect gave up waiting for the handshake to finish"
                        )
                    )
                    : .disconnected
            }
            DiagnosticLogStore.appendSSH(
                "connect result=\(timedOut ? "handshake-timeout" : "cancelled") didConnect=\(didConnect) durationMs=\(Self.durationMs(since: startedAt))"
            )
        } catch {
            if await restartTransportAfterInteractiveRecoveryIfNeeded(
                attemptID: attemptID,
                connectedClient: connectedClient,
                connectedChain: connectedChain
            ) { return }
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
                    if self.activeAppleSessionAttemptID == attemptID {
                        self.state = .disconnected
                    }
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
                    if self.activeAppleSessionAttemptID == attemptID {
                        self.state = .failed(description)
                    }
                }
                DiagnosticLogStore.appendSSH(
                    "connect result=failed durationMs=\(Self.durationMs(since: startedAt)) error='\(error)'"
                )
            }
        }
    }

    /// Consume one internal recovery request and start a fresh authenticated
    /// transport under the same logical attempt. This helper is called from
    /// every `run` exit path because closing the old PTY may surface as normal
    /// EOF, `CancellationError`, or a NIO channel error depending on timing.
    private func restartTransportAfterInteractiveRecoveryIfNeeded(
        attemptID: UUID,
        connectedClient: SSHClient?,
        connectedChain: EstablishedSSHChain?
    ) async -> Bool {
        let shouldRestart = await MainActor.run {
            self.activeAppleSessionAttemptID == attemptID
                && self.interactivePTYRecoveryPendingGeneration != nil
                && self.state == .connecting
        }
        guard shouldRestart else { return false }

        await portForwarderManager.detach()
        if let connectedChain { await connectedChain.closeAll() }

        return await MainActor.run {
            guard self.activeAppleSessionAttemptID == attemptID,
                  self.interactivePTYRecoveryPendingGeneration != nil,
                  self.state == .connecting
            else { return false }
            if let connectedClient, self.client === connectedClient {
                self.client = nil
                self.upstreamClients = []
            }
            self.activeTTYWriter = nil
            self.interactivePTYRecoveryPendingGeneration = nil
            self.armHandshakeWatchdog()
            DiagnosticLogStore.appendSSH(
                "interactive-transport recovery reconnect attempt=\(attemptID.uuidString.prefix(8))"
            )
            self.runTask = Task { [weak self] in
                await self?.run(attemptID: attemptID)
            }
            return true
        }
    }

    /// Concurrent output/input/control drain loops. Returns when the
    /// output stream closes (clean shell exit) or the session is
    /// cancelled.
    private nonisolated func runShellLoops(
        ttyOutput: TTYOutput,
        stdinWriter: TTYStdinWriter,
        attemptID: UUID,
        ptyGeneration: Int,
        readDiagnostics: TTYOutputDiagnostics?
    ) async throws {
        let streams = await self.openPTYStreams(
            attemptID: attemptID,
            ptyGeneration: ptyGeneration
        )
        let diagnosticHostID = await self.host.id
        let diagnosticHost = diagnosticHostID.uuidString.prefix(8)
        let eventLoopPulseDiagnostics = SessionLatencyDiagnostics.queue(
            host: diagnosticHostID,
            stage: "ssh-nio-event-loop-pulse-pty-\(ptyGeneration)"
        )

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

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                if let readDiagnostics { group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(5))
                        eventLoopPulseDiagnostics.enqueued()
                        stdinWriter.whenEventLoopAvailable {
                            eventLoopPulseDiagnostics.consumed()
                        }
                        let s = readDiagnostics.snapshot()
                        DiagnosticLogStore.appendSSH("latency-v3 host=\(diagnosticHost) stage=nio-to-ssh-reader attempt=\(attemptID.uuidString.prefix(8)) pty=\(ptyGeneration) pending=\(s.pendingChunks) pendingBytes=\(s.pendingBytes) peak=\(s.maximumPendingChunks) oldestMs=\(s.oldestPendingMs.map { String(Int($0)) } ?? "unknown") received=\(s.receivedChunks) consumed=\(s.consumedChunks) maxWaitMs=\(Int(s.maximumReadWaitMs)) clipped=\(s.clippedSamples)")
                    }
                } }
                // Output drain: ttyOutput yields .stdout(ByteBuffer) and
                // .stderr(ByteBuffer). We flatten both into the output stream.
                group.addTask {
                    for try await event in ttyOutput {
                        switch event {
                        case .stdout(let buf), .stderr(let buf):
                            var b = buf
                            if let bytes = b.readBytes(length: b.readableBytes) {
                                self.publicationDiagnostics.enqueued()
                                self.yieldOutput(bytes, attemptID: attemptID)
                                self.publicationDiagnostics.consumed()
                            }
                        }
                    }
                }

                // Input drain: only this PTY generation owns this stream.
                group.addTask {
                    for await chunk in streams.input {
                        chunk.queueDiagnostics.consumed()
                        guard chunk.attemptID == attemptID,
                              chunk.ptyGeneration == ptyGeneration,
                              !chunk.bytes.isEmpty
                        else {
                            continue
                        }
                        var buffer = ByteBufferAllocator().buffer(capacity: chunk.bytes.count)
                        buffer.writeBytes(chunk.bytes)
                        let writeStarted = DispatchTime.now().uptimeNanoseconds
                        self.inputWriteDiagnostics.enqueued()
                        do {
                            try await stdinWriter.write(buffer)
                            self.inputWriteDiagnostics.consumed()
                            if let context = chunk.diagnosticContext {
                                let completed = DispatchTime.now().uptimeNanoseconds
                                DiagnosticLogStore.appendSSH("latency-input-v3 host=\(diagnosticHost) stage=write-complete \(context) inputQueueMs=\(Double(writeStarted - chunk.admittedNanos) / 1e6) flushMs=\(Double(completed - writeStarted) / 1e6)")
                            }
                        } catch {
                            self.inputWriteDiagnostics.consumed()
                            throw error
                        }
                    }
                }

                // Control drain: out-of-band messages like SIGWINCH.
                // Errors from changeSize (e.g. channel closing during a
                // resize) are swallowed — the output drain will hit the
                // same close and terminate the group cleanly.
                group.addTask {
                    for await message in streams.control {
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
        } catch {
            await self.finishPTYStreams(
                attemptID: attemptID,
                ptyGeneration: ptyGeneration,
                streams: streams
            )
            throw error
        }
        await self.finishPTYStreams(
            attemptID: attemptID,
            ptyGeneration: ptyGeneration,
            streams: streams
        )
    }

    /// Create fresh input/control streams for one PTY generation and publish
    /// them atomically. Buffered input is admitted only when its provenance
    /// exactly matches this owner; all stale generations are discarded.
    private func openPTYStreams(
        attemptID: UUID,
        ptyGeneration: Int
    ) -> PTYStreams {
        finishActivePTYStreams()
        let owner = PTYStreamOwner(
            attemptID: attemptID,
            ptyGeneration: ptyGeneration
        )
        let queueDiagnostics = inputQueueDiagnostics(for: owner)
        let (input, inputContinuation) = AsyncStream.makeStream(of: InputChunk.self)
        let (control, controlContinuation) = AsyncStream.makeStream(of: ControlMessage.self)
        let streams = PTYStreams(
            input: input,
            inputContinuation: inputContinuation,
            control: control,
            controlContinuation: controlContinuation,
            owner: owner,
            inputQueueDiagnostics: queueDiagnostics
        )
        activePTYStreamOwner = owner
        activeInputContinuation = inputContinuation
        activeControlContinuation = controlContinuation

        let pending = pendingInputChunks
        pendingInputChunks.removeAll(keepingCapacity: true)
        for chunk in pending {
            if chunk.attemptID == attemptID, chunk.ptyGeneration == ptyGeneration {
                inputContinuation.yield(chunk)
            } else {
                chunk.queueDiagnostics.discarded(count: 1)
            }
        }
        for staleOwner in Array(inputQueueDiagnosticsByOwner.keys) where staleOwner != owner {
            inputQueueDiagnosticsByOwner.removeValue(forKey: staleOwner)
        }
        return streams
    }

    /// A retiring loop may finish after its replacement is already active, so
    /// ownership is checked before clearing the published continuations.
    private func finishPTYStreams(
        attemptID: UUID,
        ptyGeneration: Int,
        streams: PTYStreams
    ) {
        streams.inputContinuation.finish()
        streams.controlContinuation.finish()
        let pendingDiagnostics = streams.inputQueueDiagnostics.snapshot(resetWindow: false).pending
        streams.inputQueueDiagnostics.discarded(count: Int(clamping: pendingDiagnostics))
        if let registered = inputQueueDiagnosticsByOwner[streams.owner],
           registered === streams.inputQueueDiagnostics {
            inputQueueDiagnosticsByOwner.removeValue(forKey: streams.owner)
        }
        let owner = streams.owner
        assert(owner.attemptID == attemptID && owner.ptyGeneration == ptyGeneration)
        guard activePTYStreamOwner == owner else { return }
        activePTYStreamOwner = nil
        activeInputContinuation = nil
        activeControlContinuation = nil
    }

    private func inputQueueDiagnostics(for owner: PTYStreamOwner) -> AsyncDeliveryDiagnostics {
        if let existing = inputQueueDiagnosticsByOwner[owner] { return existing }
        let diagnostics = SessionLatencyDiagnostics.queue(
            host: host.id,
            stage: "ssh-input-queue-pty-\(owner.ptyGeneration)"
        )
        inputQueueDiagnosticsByOwner[owner] = diagnostics
        return diagnostics
    }

    private func finishActivePTYStreams() {
        activeInputContinuation?.finish()
        activeControlContinuation?.finish()
        activePTYStreamOwner = nil
        activeInputContinuation = nil
        activeControlContinuation = nil
    }

    /// Consume one requested child-channel restart only if the same transport
    /// attempt and PTY generation still own the session. Incrementing before
    /// the replacement opens lets the launch command buffer against its exact
    /// generation while all older queued bytes fail closed.
    private func advanceInteractivePTYRecoveryIfCurrent(
        attemptID: UUID,
        completedGeneration: Int
    ) -> Bool {
        guard !Task.isCancelled,
              activeAppleSessionAttemptID == attemptID,
              state == .connected,
              interactivePTYRecoveryPendingGeneration == completedGeneration,
              interactivePTYGeneration == completedGeneration
        else { return false }
        activeTTYWriter = nil
        interactivePTYRecoveryPendingGeneration = nil
        interactivePTYGeneration &+= 1
        DiagnosticLogStore.appendSSH(
            "interactive-pty recovery advancing from=\(completedGeneration) to=\(interactivePTYGeneration)"
        )
        return true
    }

    /// Continuations are thread-safe, immutable transport sinks. Waiting for
    /// MainActor once per packet throttles the SSH reader to UI availability
    /// and lets already-received bytes accumulate seconds of age in Citadel.
    /// Publish from the one ordered reader; UI ownership/attempt validation
    /// remains in the existing facade consumer, never in this transport sink.
    nonisolated private func yieldOutput(_ bytes: [UInt8], attemptID: UUID) {
        outputContinuation.yield(bytes)
        appleOutputQueueDiagnostics?.enqueued()
        appleAttemptOutputContinuation.yield(SessionAttemptOutputChunk(
            attemptID: attemptID,
            bytes: bytes
        ))
    }

    #if DEBUG
    /// Exercises the real publication boundary without opening a connection.
    nonisolated func _publishPTYOutputForTesting(_ bytes: [UInt8], attemptID: UUID) {
        yieldOutput(bytes, attemptID: attemptID)
    }
    #endif

    /// Main-actor entry point so the detached probe task can publish both OS
    /// and network-path findings without mutating this session from a Sendable
    /// closure.
    fileprivate func assignDetectionResult(_ result: OSDetectionResult) {
        if let osHint = result.osHint {
            detectedOSHint = osHint
        }
        HostRuntimeStateStore.recordNetworkPathAssessment(
            result.networkPathAssessment,
            for: host
        )
        switch result.networkPathAssessment {
        case .unavailable:
            DiagnosticLogStore.appendSSH("network-path probe=unavailable cachedWarning=\(wslTailscaleMTUWarning != nil)")
        case .notAtRisk:
            wslTailscaleMTUWarning = nil
            DiagnosticLogStore.appendSSH("network-path probe=clear")
        case .warning(let warning):
            wslTailscaleMTUWarning = warning
            DiagnosticLogStore.appendSSH(
                "network-path probe=wsl-tailscale-mtu-risk outerMTU=\(warning.defaultInterfaceMTU) tailscaleMTU=\(warning.tailscaleInterfaceMTU)"
            )
        }
    }

    @MainActor
    private func promptForHostKeyVerification(
        _ challenge: HostKeyVerificationChallenge
    ) async -> Bool {
        let status = challenge.isChanged ? "changed" : "unknown"
        let requestID = UUID()
        DiagnosticLogStore.appendSSH(
            "hostkey prompt status=\(status) keyType=\(challenge.keyType)"
        )
        // The handshake budget must not run while the decision is the user's.
        SSHHandshakePromptGate.begin()
        defer { SSHHandshakePromptGate.end() }
        let result = await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                pendingHostKeyVerification = HostKeyVerificationRequest(
                    id: requestID,
                    challenge: challenge,
                    continuation: continuation
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.pendingHostKeyVerification?.id == requestID else { return }
                self?.pendingHostKeyVerification?.reject()
                self?.pendingHostKeyVerification = nil
            }
        }
        if pendingHostKeyVerification?.id == requestID {
            pendingHostKeyVerification = nil
        }
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
