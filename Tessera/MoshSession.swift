import Dispatch
import Foundation
import Citadel
import MoshBridge
import NIOCore
import NIOSSH
import PortForwarding
import TmuxControl

enum MoshDiagnostics {
    static func log(_ message: @autoclosure () -> String) {
        DiagnosticLogStore.appendMosh(SensitiveDataRedactor.redact(message()))
    }

    static func stateDescription(_ state: SessionState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        case .failed(let reason):
            return "failed(\(reason))"
        }
    }

    static func sizeDescription(_ size: (cols: Int, rows: Int)?) -> String {
        guard let size else { return "nil" }
        return "\(size.cols)x\(size.rows)"
    }

    static func deadlineDescription(_ deadline: UInt) -> String {
        deadline == UInt.max ? "max" : "\(deadline)ms"
    }

    static func preview(_ bytes: some Collection<UInt8>, limit: Int = 64) -> String {
        guard !bytes.isEmpty else { return "<empty>" }

        let prefixBytes = Array(bytes.prefix(limit))
        var out = ""
        out.reserveCapacity(prefixBytes.count * 2)

        for byte in prefixBytes {
            switch byte {
            case 0x1B:
                out += "\\e"
            case 0x0D:
                out += "\\r"
            case 0x0A:
                out += "\\n"
            case 0x09:
                out += "\\t"
            case 0x20...0x7E:
                out.append(Character(UnicodeScalar(Int(byte))!))
            default:
                out += String(format: "\\x%02X", byte)
            }
        }

        if bytes.count > limit {
            out += "…"
        }
        return out
    }
}

enum MoshInputNormalizer {
    /// Upstream mosh puts the local terminal in application-cursor mode and
    /// sends arrow keys as SS3. The remote mosh server converts SS3 back to CSI
    /// when the remote application has not enabled cursor-key mode.
    static func normalizeArrowKeysForMosh(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count >= 3 else { return bytes }

        var normalized: [UInt8] = []
        normalized.reserveCapacity(bytes.count)

        var index = 0
        while index < bytes.count {
            let nextIndex = index + 2
            if nextIndex < bytes.count,
               bytes[index] == 0x1B,
               bytes[index + 1] == 0x5B,
               isArrowFinalByte(bytes[nextIndex]) {
                normalized.append(0x1B)
                normalized.append(0x4F)
                normalized.append(bytes[nextIndex])
                index += 3
                continue
            }

            normalized.append(bytes[index])
            index += 1
        }

        return normalized
    }

    private static func isArrowFinalByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41, 0x42, 0x43, 0x44:
            return true
        default:
            return false
        }
    }
}

enum MoshTransportState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected

    var logDescription: String {
        switch self {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        }
    }
}

/// Swift wrapper over the ObjC++ mosh bridge plus the SSH bootstrap hop.
///
/// The important constraint here is queue confinement: every bridge call
/// and callback stays on the dedicated serial `mosh.transport` queue
/// because upstream `Network::Transport` is not thread-safe.
@MainActor
public final class MoshSession: ObservableObject, TerminalSession {

    public let host: Host
    let requireBiometric: Bool
    let isSecureEnclave: Bool
    /// Optional observer mode for clients that must render the existing remote
    /// grid without participating in tmux sizing. Visible app sessions leave
    /// this false and advertise their physical viewport.
    let preserveTmuxGeometry: Bool

    /// Owns the live `PortForwarder` instances for this mosh session.
    /// Forwarders ride on the long-lived SSH back-channel that
    /// `TmuxControlChannel` opens for tmux -CC; for `customCommand`
    /// launch mode there is no back-channel and the manager stays
    /// empty. `MoshSessionView` reads it for the top-bar chip and
    /// registers it with `TunnelsRegistry`.
    public let portForwarderManager: PortForwarderManager

    @Published public private(set) var state: SessionState = .idle
    @Published private(set) var transportState: MoshTransportState = .idle
    @Published var pendingHostKeyVerification: HostKeyVerificationRequest?
    @Published public private(set) var detectedOSHint: String?
    @Published private(set) var wslTailscaleMTUWarning: WSLTailscaleMTUWarning?

    // TerminalSession cwd/injection surface — see the protocol docs.
    // Published: the Upload sheet's host rows refresh live when a cwd
    // arrives (tmux pane metadata lands seconds after a reattach).
    @Published public var remoteWorkingDirectory: String?
    @Published public var pendingPathInjection: String?

    public let outputStream: AsyncStream<[UInt8]>
    private let outputContinuation: AsyncStream<[UInt8]>.Continuation

    private var driver: MoshTransportDriver?
    private var bootstrapTask: Task<Void, Never>?
    /// Watchdog armed after `driver.connect()` when the host reaches its
    /// server through a jump chain: the mosh UDP flow is device→host
    /// direct and usually firewalled in bastioned topologies, so if the
    /// driver never reports connected in time we recommend rebuilding
    /// this session on the SSH transport (ContentView reacts).
    private var jumpFallbackWatchdogTask: Task<Void, Never>?
    private var jumpFallbackCleanupTask: Task<Void, Never>?
    private static let jumpFallbackTimeoutNanos: UInt64 = 8_000_000_000
    private var bootstrapJumpChainHopCount = 0
    /// Consumed by ContentView on `.failed`: true means "the SSH ride
    /// worked but mosh UDP never made contact through the jump chain" —
    /// the session should be retried over plain SSH automatically.
    @Published private(set) var recommendsSSHFallback = false
    /// Transient bootstrap failures (network blip or the host slow to
    /// open the exec channel right at reconnect time) retry on a fresh
    /// SSH connection before the session declares .failed — a manual
    /// retry seconds later reliably succeeds, so ride the blip out.
    /// The escalating backoff spans the ~50 s outage window observed
    /// in the field: attempt windows ≈ t+0, +18 s, +43 s.
    private var bootstrapRetriesUsed = 0
    private static let bootstrapRetryBackoffNanos: [UInt64] = [3_000_000_000, 10_000_000_000]
    private var remoteServerMonitorTask: Task<Void, Never>?
    private var didStart = false
    private var didReachConnectedState = false
    private var lastReportedSize: (cols: Int, rows: Int)?
    /// PID of the detached remote mosh-server, parsed from its bootstrap
    /// banner. `private(set)`: the session view reads it to locate the
    /// server's child shell for the Files panel's cwd polling fallback
    /// (plain mosh can't carry OSC 7 — stock mosh-servers drop it before
    /// it ever reaches the state sync).
    private(set) var remoteServerPID: Int?
    private var outputDeliveryCount = 0
    private var resizeRequestCount = 0
    /// Non-nil only when a compact continuation attached to an existing tmux
    /// session. The local view may be smaller, but mosh must keep advertising
    /// this authoritative remote grid or its PTY will resize the tmux client.
    private var preservedRemoteTmuxGeometry: (cols: Int, rows: Int)?

    var preservedRemoteTmuxSize: (cols: Int, rows: Int)? {
        preservedRemoteTmuxGeometry
    }

    /// Promote a successfully ceded phone-born grid into the same remote-size
    /// hold used by existing-session continuations. This outlives the current
    /// `TmuxController`/SSH side channel, so backgrounding or reconnecting can
    /// never replay the compact physical viewport into the visible mosh PTY.
    func preserveRemoteTmuxSizeAfterCede(cols: Int, rows: Int) {
        guard preserveTmuxGeometry, cols > 0, rows > 0 else { return }
        objectWillChange.send()
        preservedRemoteTmuxGeometry = (cols, rows)
        driver?.resize(cols: cols, rows: rows)
        MoshDiagnostics.log(
            "session remote tmux geometry held after cede size=\(cols)x\(rows)"
        )
    }

    public init(
        host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false,
        preserveTmuxGeometry: Bool = false
    ) {
        self.host = host
        self.requireBiometric = requireBiometric
        self.isSecureEnclave = isSecureEnclave
        self.preserveTmuxGeometry = preserveTmuxGeometry
        self.portForwarderManager = PortForwarderManager()
        self.wslTailscaleMTUWarning = HostRuntimeStateStore.wslTailscaleMTUWarning(
            for: host
        )

        let outputPair = AsyncStream.makeStream(of: [UInt8].self)
        outputStream = outputPair.stream
        outputContinuation = outputPair.continuation
    }

    deinit {
        outputContinuation.finish()
    }

    public func connect() {
        guard !didStart else { return }
        didStart = true
        state = .connecting
        transportState = .connecting
        MoshDiagnostics.log(
            "session connect start transport=\(host.transport.rawValue) launchMode=\(host.launchMode.rawValue) authKind=\(authKindDescription()) biometricRequired=\(requireBiometric) secureEnclave=\(isSecureEnclave)"
        )
        bootstrapTask = Task { [weak self] in
            await self?.bootstrapAndStart()
        }
    }

    public func send(_ bytes: [UInt8]) {
        guard case .connected = state else { return }
        driver?.send(bytes)
    }

    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lastReportedSize = (cols, rows)
        resizeRequestCount += 1
        if resizeRequestCount <= 6 {
            MoshDiagnostics.log(
                "session resize request #\(resizeRequestCount) size=\(cols)x\(rows) state=\(MoshDiagnostics.stateDescription(state))"
            )
        }
        if let preservedRemoteTmuxGeometry {
            driver?.resize(
                cols: preservedRemoteTmuxGeometry.cols,
                rows: preservedRemoteTmuxGeometry.rows
            )
        } else {
            driver?.resize(cols: cols, rows: rows)
        }
    }

    /// Re-emit the whole screen from the mosh client's framebuffer model.
    /// The SSP diff stream never repaints cells it believes the terminal
    /// already shows, so anything painted outside it (a buffered attach
    /// replay across a tmux window resize, a restored continuity snapshot)
    /// survives until the model is force-resynchronized.
    public func forceFullRepaint(
        completion: (@MainActor (Int?) -> Void)? = nil
    ) {
        guard case .connected = state, let driver else {
            completion?(nil)
            return
        }
        driver.forceFullRepaint { outputDeliveryTarget in
            Task { @MainActor in
                completion?(outputDeliveryTarget)
            }
        }
    }

    public func disconnect() {
        MoshDiagnostics.log(
            "session disconnect requested state=\(MoshDiagnostics.stateDescription(state)) didReachConnected=\(didReachConnectedState)"
        )
        if let pending = pendingHostKeyVerification {
            pending.reject()
            pendingHostKeyVerification = nil
        }
        bootstrapTask?.cancel()
        bootstrapTask = nil
        jumpFallbackWatchdogTask?.cancel()
        jumpFallbackWatchdogTask = nil
        jumpFallbackCleanupTask?.cancel()
        jumpFallbackCleanupTask = nil
        bootstrapJumpChainHopCount = 0
        stopRemoteServerMonitor()
        driver?.disconnect()
        driver = nil
        transportState = .disconnected
        if case .failed = state {
            return
        }
        state = .disconnected
    }

    private func bootstrapAndStart() async {
        MoshDiagnostics.log(
            "bootstrap start transport=\(host.transport.rawValue) launchMode=\(host.launchMode.rawValue) port=\(host.port)"
        )
        do {
            let fallbackHost = host
            let requireBiometric = self.requireBiometric
            let isSecureEnclave = self.isSecureEnclave
            let result = try await withPendingSSHConnectionAttempt {
                // Resolve the endpoint here because MoshBootstrap is owned by
                // the parallel transcript-redaction remediation. Its common
                // auth resolver fails closed if this policy changes again.
                let policy = try await resolveSSHConnectionPolicy(
                    for: fallbackHost,
                    requireBiometric: requireBiometric,
                    isSecureEnclave: isSecureEnclave
                )
                let result = try await MoshBootstrap.bootstrap(
                    host: policy.host,
                    requireBiometric: policy.requireBiometric,
                    isSecureEnclave: policy.isSecureEnclave,
                    hostKeyPrompt: { [weak self] challenge in
                        await self?.promptForHostKeyVerification(challenge) ?? false
                    },
                    preserveTmuxGeometry: self.preserveTmuxGeometry,
                    // The SSH -CC side channel is the single tmux sizing
                    // authority. The visible mosh PTY still follows the local
                    // viewport, but must not win tmux's latest-client policy
                    // merely because the user typed after another device
                    // resized the shared session.
                    visibleTmuxClientIgnoresSize: policy.host.launchMode == .autoTmux
                        || policy.host.launchMode == .pinnedTmux,
                    gridAuthorityDeviceID: GridAuthorityDeviceIdentity.current().id
                )
                try Task.checkCancellation()
                try await SSHAuthenticationPolicyStore.shared.revalidate(policy)
                return result
            }

            guard !Task.isCancelled else { return }

            if let detected = result.detectedOSHint {
                detectedOSHint = detected
            }
            HostRuntimeStateStore.recordNetworkPathAssessment(
                result.networkPathAssessment,
                for: host
            )
            switch result.networkPathAssessment {
            case .unavailable:
                MoshDiagnostics.log(
                    "network-path probe=unavailable cachedWarning=\(wslTailscaleMTUWarning != nil)"
                )
            case .notAtRisk:
                wslTailscaleMTUWarning = nil
                MoshDiagnostics.log("network-path probe=clear")
            case .warning(let warning):
                wslTailscaleMTUWarning = warning
                MoshDiagnostics.log(
                    "network-path probe=wsl-tailscale-mtu-risk outerMTU=\(warning.defaultInterfaceMTU) tailscaleMTU=\(warning.tailscaleInterfaceMTU)"
                )
            }
            let driver = makeDriver(
                targetAddress: result.targetAddress ?? host.address,
                udpPort: result.udpPort,
                base64Key: result.base64Key
            )
            remoteServerPID = result.serverPID
            bootstrapJumpChainHopCount = result.jumpChainHopCount
            preservedRemoteTmuxGeometry = result.preservedTmuxGeometry.map {
                (cols: $0.cols, rows: $0.rows)
            }
            MoshDiagnostics.log(
                "bootstrap success udpPort=\(result.udpPort) keyLength=\(result.base64Key.count) serverPID=\(result.serverPID.map(String.init) ?? "nil") lastSize=\(MoshDiagnostics.sizeDescription(lastReportedSize))"
            )
            bootstrapTask = nil
            self.driver = driver
            if let size = result.preservedTmuxGeometry {
                driver.resize(cols: size.cols, rows: size.rows)
            } else if let size = lastReportedSize {
                driver.resize(cols: size.cols, rows: size.rows)
            }
            driver.connect()
            startJumpFallbackWatchdogIfNeeded()
        } catch is CancellationError {
            bootstrapTask = nil
            remoteServerPID = nil
            MoshDiagnostics.log("bootstrap cancelled")
            transportState = .disconnected
            if state != .disconnected {
                state = .disconnected
            }
        } catch {
            remoteServerPID = nil
            if shouldRetryBootstrap(after: error) {
                // bootstrapTask stays non-nil so disconnect() can still
                // cancel the sleeping retry.
                let backoff = Self.bootstrapRetryBackoffNanos[bootstrapRetriesUsed]
                bootstrapRetriesUsed += 1
                MoshDiagnostics.log(
                    "bootstrap retry #\(bootstrapRetriesUsed) backoffSeconds=\(backoff / 1_000_000_000) error=\(SensitiveDataRedactor.redact(String(describing: error)))"
                )
                try? await Task.sleep(nanoseconds: backoff)
                guard !Task.isCancelled, state == .connecting else {
                    bootstrapTask = nil
                    MoshDiagnostics.log("bootstrap cancelled")
                    transportState = .disconnected
                    if state != .disconnected {
                        state = .disconnected
                    }
                    return
                }
                await bootstrapAndStart()
                return
            }
            bootstrapTask = nil
            MoshDiagnostics.log(
                "bootstrap failed error=\(SensitiveDataRedactor.redact(error.localizedDescription))"
            )
            transportState = .disconnected
            state = .failed(SensitiveDataRedactor.redact(
                error.localizedDescription.isEmpty
                    ? describeSSHError(error)
                    : error.localizedDescription
            ))
        }
    }

    private func startJumpFallbackWatchdogIfNeeded() {
        guard bootstrapJumpChainHopCount > 0 else { return }
        jumpFallbackWatchdogTask?.cancel()
        let armedAt = Date()
        jumpFallbackWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.jumpFallbackTimeoutNanos)
            guard !Task.isCancelled else { return }
            self?.handleJumpFallbackTimeout(armedAt: armedAt)
        }
    }

    private func handleJumpFallbackTimeout(armedAt: Date) {
        jumpFallbackWatchdogTask = nil
        guard !didReachConnectedState, state == .connecting else { return }
        // Task.sleep deadlines keep elapsing while the process is suspended;
        // waking up long past the arm time means mosh never actually got 8
        // continuous foreground seconds to make contact. Re-arm instead of
        // condemning a transport that was frozen mid-handshake.
        let elapsed = Date().timeIntervalSince(armedAt)
        let budget = TimeInterval(Self.jumpFallbackTimeoutNanos) / 1_000_000_000
        if elapsed > budget * 2 {
            MoshDiagnostics.log(
                "jump fallback watchdog woke after suspension (elapsed=\(Int(elapsed))s), re-arming"
            )
            startJumpFallbackWatchdogIfNeeded()
            return
        }
        MoshDiagnostics.log(
            "jump fallback: driver never connected through \(bootstrapJumpChainHopCount)-hop chain"
        )
        _ = beginJumpFallback(reason: "watchdog timeout")
    }

    /// Start the automatic SSH takeover only after the detached mosh-server
    /// from this bootstrap has been stopped. Without that barrier, an
    /// asymmetric UDP path can release the remote child while the client never
    /// sees a reply, causing the SSH fallback to run a custom command or
    /// startup snippet a second time.
    @discardableResult
    private func beginJumpFallback(reason: String) -> Bool {
        guard bootstrapJumpChainHopCount > 0 else { return false }
        guard state == .connecting else { return true }
        guard !recommendsSSHFallback, jumpFallbackCleanupTask == nil else {
            return true
        }

        jumpFallbackWatchdogTask?.cancel()
        jumpFallbackWatchdogTask = nil

        guard let serverPID = remoteServerPID, serverPID > 0 else {
            failJumpFallbackCleanup(
                "The remote mosh-server PID was unavailable, so Tessera did not start a second login command automatically."
            )
            return true
        }

        let cleanupHost = host
        let requireBiometric = self.requireBiometric
        let isSecureEnclave = self.isSecureEnclave
        MoshDiagnostics.log(
            "jump fallback cleanup start reason=\(reason) pid=\(serverPID)"
        )
        jumpFallbackCleanupTask = Task { [weak self] in
            do {
                try await Self.terminateRemoteMoshServerForFallback(
                    on: cleanupHost,
                    requireBiometric: requireBiometric,
                    isSecureEnclave: isSecureEnclave,
                    serverPID: serverPID
                )
                try Task.checkCancellation()
                guard let self else { return }
                self.jumpFallbackCleanupTask = nil
                guard self.state == .connecting else { return }
                self.remoteServerPID = nil
                self.recommendsSSHFallback = true
                self.updateTransportState(
                    .disconnected,
                    reason: "jump fallback cleanup complete"
                )
                // Set failed before disconnecting the driver so teardown
                // callbacks cannot replace this takeover state.
                self.state = .failed(
                    "mosh is unreachable through the jump chain — UDP cannot traverse SSH bastions. Reconnecting over SSH…"
                )
                self.driver?.disconnect()
                self.driver = nil
                MoshDiagnostics.log(
                    "jump fallback recommended reason=\(reason) pid=\(serverPID)"
                )
            } catch is CancellationError {
                // An explicit session disconnect owns the final state.
            } catch {
                guard let self else { return }
                self.jumpFallbackCleanupTask = nil
                guard self.state == .connecting else { return }
                self.failJumpFallbackCleanup(describeSSHError(error))
            }
        }
        return true
    }

    private func failJumpFallbackCleanup(_ detail: String) {
        MoshDiagnostics.log(
            "jump fallback cleanup failed detail=\(SensitiveDataRedactor.redact(detail))"
        )
        updateTransportState(.disconnected, reason: "jump fallback cleanup failed")
        state = .failed(
            "mosh is unreachable through the jump chain, but Tessera could not safely stop its remote mosh-server before switching transports. \(SensitiveDataRedactor.redact(detail)) Connect with SSH manually."
        )
        driver?.disconnect()
        driver = nil
    }

    private nonisolated static func terminateRemoteMoshServerForFallback(
        on host: Host,
        requireBiometric: Bool,
        isSecureEnclave: Bool,
        serverPID: Int
    ) async throws {
        let chain = try await withPendingSSHConnectionAttempt {
            try await establishSSHChain(
                for: host,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave,
                hostKeyPrompt: nil
            )
        }
        do {
            var output = try await chain.client.executeCommand(
                remoteMoshServerTerminationCommand(serverPID: serverPID),
                maxResponseSize: 4 * 1024
            )
            output.clear()
            await chain.closeAll()
        } catch {
            await chain.closeAll()
            throw error
        }
    }

    /// PID comes from mosh-server's own detached banner. Verify the process
    /// name again immediately before signalling so PID reuse cannot terminate
    /// an unrelated process; treat an already-exited server as success.
    nonisolated static func remoteMoshServerTerminationCommand(
        serverPID: Int
    ) -> String {
        precondition(serverPID > 0)
        return "sh -lc 'pid=\(serverPID); "
            + "if ! kill -0 \"$pid\" 2>/dev/null; then exit 0; fi; "
            + "set -- $(ps -p \"$pid\" -o comm= 2>/dev/null); "
            + "case \"${1:-}\" in *mosh-server*) ;; *) exit 64;; esac; "
            + "kill -TERM \"$pid\"; n=0; "
            + "while kill -0 \"$pid\" 2>/dev/null && [ \"$n\" -lt 5 ]; do "
            + "sleep 1; n=$((n+1)); done; "
            + "! kill -0 \"$pid\" 2>/dev/null'"
    }

    /// Only the transient network class retries — auth failures would
    /// loop biometric prompts, host-key rejections are a user decision,
    /// and missing/garbled mosh-server output is deterministic.
    private func shouldRetryBootstrap(after error: Error) -> Bool {
        guard state == .connecting,
              bootstrapRetriesUsed < Self.bootstrapRetryBackoffNanos.count,
              let bootstrapError = error as? MoshBootstrapError,
              case .connectionFailed = bootstrapError
        else { return false }
        return true
    }

    private func makeDriver(
        targetAddress: String,
        udpPort: Int,
        base64Key: String
    ) -> MoshTransportDriver {
        MoshTransportDriver(
            host: targetAddress,
            udpPort: udpPort,
            base64Key: base64Key,
            onOutput: { [weak self] bytes, delivered in
                Task { @MainActor in
                    guard let self else { return }
                    self.outputDeliveryCount += 1
                    let chunkIndex = self.outputDeliveryCount
                    if chunkIndex <= 12 || chunkIndex == 25 || chunkIndex == 50 {
                        MoshDiagnostics.log(
                            "session output delivery chunk#\(chunkIndex) bytes=\(bytes.count)"
                        )
                    }
                    self.outputContinuation.yield(bytes)
                    delivered?(self.outputDeliveryCount)
                }
            },
            onConnected: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.jumpFallbackWatchdogTask?.cancel()
                    self.jumpFallbackWatchdogTask = nil
                    self.didReachConnectedState = true
                    MoshDiagnostics.log(
                        "session connected previousState=\(MoshDiagnostics.stateDescription(self.state))"
                    )
                    self.updateTransportState(.connected, reason: "initial")
                    if self.state == .connecting || self.state == .idle {
                        self.state = .connected
                    }
                    self.startRemoteServerMonitorIfNeeded()
                }
            },
            onDisconnected: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.bootstrapTask = nil
                    self.driver = nil
                    MoshDiagnostics.log(
                        "session disconnected state=\(MoshDiagnostics.stateDescription(self.state)) didReachConnected=\(self.didReachConnectedState)"
                    )
                    self.updateTransportState(.disconnected, reason: "driver disconnected")
                    if self.state == .disconnected {
                        return
                    }
                    if case .failed = self.state {
                        return
                    }
                    if self.didReachConnectedState {
                        self.stopRemoteServerMonitor()
                        self.state = .disconnected
                    } else {
                        // A driver that dies before first contact on a
                        // jump-chained host is the UDP-unreachable case
                        // arriving early — same fallback as the watchdog.
                        if self.beginJumpFallback(
                            reason: "driver disconnected pre-connect"
                        ) {
                            return
                        }
                        self.stopRemoteServerMonitor()
                        self.state = .failed(
                            Self.userFacingStartupFailureMessage(from: nil)
                        )
                    }
                }
            },
            onFailed: { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    self.bootstrapTask = nil
                    self.driver = nil
                    MoshDiagnostics.log(
                        "session failed didReachConnected=\(self.didReachConnectedState) message=\(message)"
                    )
                    self.updateTransportState(.disconnected, reason: "driver failed")
                    if self.didReachConnectedState {
                        self.stopRemoteServerMonitor()
                        if Self.shouldTreatPostConnectFailureAsDisconnect(message) {
                            self.state = .disconnected
                        } else {
                            self.state = .failed(message)
                        }
                    } else {
                        // Fast pre-contact failures (socket errors, blocked
                        // UDP surfacing as an ICMP reject) on a jump-chained
                        // host take the same SSH fallback as the watchdog —
                        // it must not depend on WHICH way mosh fails.
                        if self.beginJumpFallback(reason: "driver failed pre-connect") {
                            return
                        }
                        self.stopRemoteServerMonitor()
                        self.state = .failed(
                            Self.userFacingStartupFailureMessage(from: message)
                        )
                    }
                }
            },
            onTransportReachabilityChanged: { [weak self] reachable in
                Task { @MainActor in
                    guard let self else { return }
                    let nextState: MoshTransportState = reachable
                        ? .connected
                        : .disconnected
                    self.updateTransportState(
                        nextState,
                        reason: "driver reachability"
                    )
                }
            }
        )
    }

    private func updateTransportState(
        _ newState: MoshTransportState,
        reason: String
    ) {
        guard transportState != newState else { return }
        MoshDiagnostics.log(
            "session transport state=\(newState.logDescription) previous=\(transportState.logDescription) reason=\(reason)"
        )
        transportState = newState
    }

    private func startRemoteServerMonitorIfNeeded() {
        guard host.launchMode == .customCommand else { return }
        guard let remoteServerPID, remoteServerPID > 0 else { return }
        guard remoteServerMonitorTask == nil else { return }

        let monitoredHost = host
        let requireBiometric = self.requireBiometric
        let isSecureEnclave = self.isSecureEnclave
        MoshDiagnostics.log(
            "remote exit monitor start pid=\(remoteServerPID) transport=\(monitoredHost.transport.rawValue) launchMode=\(monitoredHost.launchMode.rawValue) port=\(monitoredHost.port)"
        )
        remoteServerMonitorTask = Task { [weak self, monitoredHost] in
            do {
                try await Self.waitForRemoteServerExit(
                    on: monitoredHost,
                    requireBiometric: requireBiometric,
                    isSecureEnclave: isSecureEnclave,
                    serverPID: remoteServerPID
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.handleObservedRemoteServerExit(serverPID: remoteServerPID)
                }
            } catch is CancellationError {
                MoshDiagnostics.log("remote exit monitor cancelled pid=\(remoteServerPID)")
            } catch {
                MoshDiagnostics.log(
                    "remote exit monitor failed pid=\(remoteServerPID) error=\(describeSSHError(error))"
                )
            }
        }
    }

    private func stopRemoteServerMonitor() {
        remoteServerMonitorTask?.cancel()
        remoteServerMonitorTask = nil
        remoteServerPID = nil
    }

    private func handleObservedRemoteServerExit(serverPID: Int) {
        guard remoteServerPID == serverPID else { return }

        MoshDiagnostics.log(
            "remote exit monitor observed pid=\(serverPID) state=\(MoshDiagnostics.stateDescription(state))"
        )
        remoteServerMonitorTask = nil
        remoteServerPID = nil
        if case .failed = state {
            return
        }
        if state != .disconnected {
            transportState = .disconnected
            state = .disconnected
        }
        driver?.disconnect()
    }

    private nonisolated static func waitForRemoteServerExit(
        on host: Host,
        requireBiometric: Bool,
        isSecureEnclave: Bool,
        serverPID: Int
    ) async throws {
        let chain = try await withPendingSSHConnectionAttempt {
            try await establishSSHChain(
                for: host,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave,
                hostKeyPrompt: nil
            )
        }
        let client = chain.client

        do {
            let command = remoteServerMonitorCommand(serverPID: serverPID)
            MoshDiagnostics.log(
                "remote exit monitor exec pid=\(serverPID)"
            )
            let streams = try await client.executeCommandPair(command)
            async let stdoutResult = collectRemoteMonitorStream(streams.stdout)
            async let stderrResult = collectRemoteMonitorStream(streams.stderr)

            let (stdout, stdoutError) = await stdoutResult
            let (stderr, stderrError) = await stderrResult
            let stdoutText = String(decoding: stdout, as: UTF8.self)
            let stderrText = String(decoding: stderr, as: UTF8.self)
            let sawExitMarker = stdoutText.contains(remoteServerExitMarker)
                || stderrText.contains(remoteServerExitMarker)

            if sawExitMarker {
                MoshDiagnostics.log(
                    "remote exit monitor observed marker pid=\(serverPID) stdoutBytes=\(stdout.count) stderrBytes=\(stderr.count)"
                )
                await chain.closeAll()
                return
            }

            if let error = firstRemoteMonitorError(
                stdoutError: stdoutError,
                stderrError: stderrError
            ) {
                await chain.closeAll()
                throw error
            }

            await chain.closeAll()
            throw NSError(
                domain: "Tessera.MoshSession",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Remote exit monitor finished without an exit marker."
                ]
            )
        } catch {
            await chain.closeAll()
            throw error
        }
    }

    private nonisolated static func remoteServerMonitorCommand(
        serverPID: Int
    ) -> String {
        "sh -lc 'while kill -0 \(serverPID) 2>/dev/null; do sleep 1; done; echo \(remoteServerExitMarker)'"
    }

    private nonisolated static func collectRemoteMonitorStream(
        _ stream: AsyncThrowingStream<ByteBuffer, Error>
    ) async -> (Data, Error?) {
        var data = Data()
        do {
            for try await buffer in stream {
                var buffer = buffer
                if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                    data.append(contentsOf: bytes)
                }
            }
            return (data, nil)
        } catch {
            return (data, error)
        }
    }

    private nonisolated static func firstRemoteMonitorError(
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

    nonisolated static func userFacingStartupFailureMessage(from rawMessage: String?) -> String {
        let trimmed = rawMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return "Could not start mosh. The remote host may not have `mosh-server` installed or on PATH, or it exited immediately during startup."
        }

        let lowered = trimmed.lowercased()
        if lowered.contains("mosh-server")
            || lowered.contains("mosh connect")
            || lowered.hasPrefix("could not start mosh")
        {
            return trimmed
        }

        // Citadel's exec/TTY channel open carries a hard 15 s timeout;
        // its bare enum case would otherwise surface verbatim.
        if trimmed == "channelCreationFailed" {
            return "Could not start mosh: the host accepted the SSH connection but never opened the command channel (15 s). It may be overloaded or limiting sessions."
        }

        if lowered == "connection closed"
            || lowered.contains("closed")
            || lowered.contains("shutdown")
            || lowered.contains("end of file")
            || lowered.contains("eof")
        {
            return "Could not start mosh. The remote host may not have `mosh-server` installed or on PATH, or it exited immediately during startup."
        }

        return trimmed
    }

    nonisolated static func shouldTreatPostConnectFailureAsDisconnect(
        _ rawMessage: String?
    ) -> Bool {
        let trimmed = rawMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        return lowered == "connection closed"
            || lowered.contains("closed")
            || lowered.contains("shutdown")
            || lowered.contains("end of file")
            || lowered.contains("eof")
    }

    private func promptForHostKeyVerification(
        _ challenge: HostKeyVerificationChallenge
    ) async -> Bool {
        let status = challenge.isChanged ? "changed" : "unknown"
        let requestID = UUID()
        DiagnosticLogStore.appendSSH(
            "hostkey prompt transport=mosh status=\(status) keyType=\(challenge.keyType)"
        )
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
            "hostkey prompt transport=mosh result=\(result ? "accepted" : "rejected") status=\(status) keyType=\(challenge.keyType)"
        )
        return result
    }

    private func authKindDescription() -> String {
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

private let remoteServerExitMarker = "__TESSERA_REMOTE_EXIT__"

final class MoshTransportDriver {
    private let host: String
    private let udpPort: Int
    /// The printable bootstrap credential is needed only until MoshCore has
    /// initialized its binary crypto session. It must not live for the whole
    /// terminal session alongside the bridge.
    private var base64Key: String?
    private let queue = DispatchQueue(label: "mosh.transport")

    private var bridge: MoshBridgeClient?
    private var readSources: [Int32: DispatchSourceRead] = [:]
    private var timerSource: DispatchSourceTimer?
    private var observedSocketFDs: Set<Int32> = []
    private var lastReportedSize: (cols: Int, rows: Int)?
    private var hasStarted = false
    private var finished = false
    private var didReportConnected = false
    private var lastReportedTransportReachable: Bool?
    private var tickCount = 0
    private var outputChunkCount = 0
    private var outputByteCount = 0
    /// Non-nil only during a forced framebuffer replay. Buffer its chunks so
    /// the delivery callback can identify the exact AsyncStream element whose
    /// consumption is allowed to lift the continuity veil.
    private var forceFullRepaintOutput: [UInt8]?
    private var resizeCount = 0
    private var sendCount = 0

    private let onOutput: ([UInt8], ((Int) -> Void)?) -> Void
    private let onConnected: () -> Void
    private let onDisconnected: () -> Void
    private let onFailed: (String) -> Void
    private let onTransportReachabilityChanged: (Bool) -> Void

    init(
        host: String,
        udpPort: Int,
        base64Key: String,
        onOutput: @escaping ([UInt8], ((Int) -> Void)?) -> Void,
        onConnected: @escaping () -> Void,
        onDisconnected: @escaping () -> Void,
        onFailed: @escaping (String) -> Void,
        onTransportReachabilityChanged: @escaping (Bool) -> Void
    ) {
        self.host = host
        self.udpPort = udpPort
        self.base64Key = base64Key
        self.onOutput = onOutput
        self.onConnected = onConnected
        self.onDisconnected = onDisconnected
        self.onFailed = onFailed
        self.onTransportReachabilityChanged = onTransportReachabilityChanged
    }

    func connect() {
        queue.async {
            guard !self.hasStarted, !self.finished else { return }
            self.hasStarted = true
            MoshDiagnostics.log(
                "driver connect start udpPort=\(self.udpPort) lastSize=\(MoshDiagnostics.sizeDescription(self.lastReportedSize))"
            )

            do {
                guard let base64Key = self.base64Key else {
                    throw NSError(
                        domain: "com.bambouville.Tessera.MoshTransport",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Mosh session key is unavailable."]
                    )
                }
                let bridge = try MoshBridgeClient(
                    host: self.host,
                    port: self.udpPort,
                    base64Key: base64Key
                )
                // MoshCore owns a decoded, wipeable credential from here.
                // Dropping this reference minimizes the immutable Swift
                // String's lifetime even though Swift cannot guarantee that
                // its former storage is overwritten.
                self.base64Key = nil
                bridge.outputHandler = { [weak self] data in
                    guard let self else { return }
                    let bytes = [UInt8](data)
                    if !bytes.isEmpty {
                        if self.forceFullRepaintOutput != nil {
                            self.forceFullRepaintOutput?.append(contentsOf: bytes)
                        } else {
                            self.emitOutput(bytes)
                        }
                    }
                }

                if let size = self.lastReportedSize {
                    try bridge.resize(withColumns: size.cols, rows: size.rows)
                }

                try bridge.start()
                self.bridge = bridge
                let socketFDs = self.socketFDs(for: bridge)
                MoshDiagnostics.log(
                    "driver connect started socketFDs=\(socketFDs) connected=\(bridge.isConnected)"
                )
                self.updateReadSourcesLocked()
                self.tickLocked()
            } catch {
                self.base64Key = nil
                self.failLocked(error)
            }
        }
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async {
            guard !self.finished, let bridge = self.bridge else { return }

            do {
                let applicationCursorKeys = bridge.applicationModeCursorKeys
                let normalizedBytes = MoshInputNormalizer.normalizeArrowKeysForMosh(bytes)
                self.sendCount += 1
                if self.sendCount <= 12 || self.sendCount == 25 || self.sendCount == 50 {
                    let changed = normalizedBytes != bytes
                    MoshDiagnostics.log(
                        "driver send #\(self.sendCount) bytes=\(bytes.count) appCursor=\(applicationCursorKeys) changed=\(changed)"
                    )
                }
                try bridge.injectBytes(Data(normalizedBytes))
                self.tickLocked()
            } catch {
                self.failLocked(error)
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        queue.async {
            guard !self.finished else { return }
            self.lastReportedSize = (cols, rows)
            self.resizeCount += 1
            if self.resizeCount <= 6 {
                MoshDiagnostics.log(
                    "driver resize #\(self.resizeCount) size=\(cols)x\(rows) bridgeReady=\(self.bridge != nil)"
                )
            }

            guard let bridge = self.bridge else { return }
            do {
                try bridge.resize(withColumns: cols, rows: rows)
                self.tickLocked()
            } catch {
                self.failLocked(error)
            }
        }
    }

    func forceFullRepaint(completion: @escaping (Int?) -> Void) {
        queue.async {
            guard !self.finished, let bridge = self.bridge else {
                completion(nil)
                return
            }
            MoshDiagnostics.log("driver force-full-repaint")
            self.forceFullRepaintOutput = []
            do {
                try bridge.forceFullRepaint()
                self.tickLocked()
                let bytes = self.forceFullRepaintOutput ?? []
                self.forceFullRepaintOutput = nil
                guard !bytes.isEmpty else {
                    MoshDiagnostics.log("driver force-full-repaint emitted no output")
                    completion(nil)
                    return
                }
                self.emitOutput(bytes, delivered: completion)
            } catch {
                self.forceFullRepaintOutput = nil
                completion(nil)
                self.failLocked(error)
            }
        }
    }

    func disconnect() {
        queue.async {
            guard !self.finished else { return }
            MoshDiagnostics.log(
                "driver disconnect requested outputChunks=\(self.outputChunkCount) outputBytes=\(self.outputByteCount)"
            )
            self.finished = true
            self.base64Key = nil
            self.cancelSourcesLocked()
            self.bridge?.shutdown()
            self.bridge = nil
            self.onDisconnected()
        }
    }

    #if DEBUG
    /// Reads both sides of the Swift/native ownership boundary on the driver's
    /// serial queue so lifetime tests observe a completed handoff, not a race.
    func retainsBootstrapKeyMaterialForTesting() -> Bool {
        queue.sync {
            base64Key != nil
                || (bridge?.retainsBootstrapKeyMaterial ?? false)
        }
    }
    #endif

    private func emitOutput(
        _ bytes: [UInt8],
        delivered: ((Int) -> Void)? = nil
    ) {
        guard !bytes.isEmpty else { return }
        outputChunkCount += 1
        outputByteCount += bytes.count
        let chunkIndex = outputChunkCount
        if chunkIndex <= 12 || chunkIndex == 25 || chunkIndex == 50 {
            MoshDiagnostics.log(
                "driver output chunk#\(chunkIndex) bytes=\(bytes.count) totalBytes=\(outputByteCount)"
            )
        }
        onOutput(bytes, delivered)
    }

    private func tickLocked() {
        guard !finished, let bridge else { return }

        do {
            tickCount += 1
            let nextDeadline = try tickMilliseconds(from: bridge)
            updateReadSourcesLocked()
            reportConnectedIfNeededLocked()
            reportTransportReachabilityIfNeededLocked()
            if tickCount <= 10 || (didReportConnected && outputChunkCount == 0 && tickCount <= 20) {
                let socketFDs = socketFDs(for: bridge)
                MoshDiagnostics.log(
                    "driver tick#\(tickCount) deadline=\(MoshDiagnostics.deadlineDescription(nextDeadline)) connected=\(bridge.isConnected) reachable=\(bridge.isTransportReachable) shutdown=\(bridge.isShutdownComplete) socketFDs=\(socketFDs) outputChunks=\(outputChunkCount)"
                )
            }

            if bridge.isShutdownComplete {
                finishDisconnectedLocked()
                return
            }

            scheduleTimerLocked(afterMilliseconds: nextDeadline)
        } catch {
            failLocked(error)
        }
    }

    private func tickMilliseconds(from bridge: MoshBridgeClient) throws -> UInt {
        var error: NSError?
        let nextDeadline = bridge.tick(&error)
        if let error {
            throw error
        }
        return nextDeadline
    }

    private func updateReadSourcesLocked() {
        let newFDs = Set(bridge.map(socketFDs(for:)) ?? [])
        guard newFDs != observedSocketFDs else { return }

        for fd in observedSocketFDs.subtracting(newFDs) {
            readSources[fd]?.cancel()
            readSources[fd] = nil
        }

        for fd in newFDs.subtracting(observedSocketFDs) {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.tickLocked()
            }
            source.resume()
            readSources[fd] = source
        }

        observedSocketFDs = newFDs
        MoshDiagnostics.log("driver socketFD update fds=\(Array(newFDs).sorted())")
    }

    private func scheduleTimerLocked(afterMilliseconds milliseconds: UInt) {
        timerSource?.cancel()
        timerSource = nil

        guard milliseconds != UInt.max else { return }

        let clamped = min(milliseconds, UInt(Int.max))
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler { [weak self] in
            self?.tickLocked()
        }
        source.schedule(
            deadline: .now() + .milliseconds(Int(clamped)),
            leeway: .milliseconds(clamped == 0 ? 0 : 10)
        )
        source.resume()
        timerSource = source
    }

    private func cancelSourcesLocked() {
        for source in readSources.values {
            source.cancel()
        }
        readSources.removeAll()
        observedSocketFDs.removeAll()

        timerSource?.cancel()
        timerSource = nil
    }

    private func reportConnectedIfNeededLocked() {
        guard let bridge, bridge.isConnected, !didReportConnected else { return }
        didReportConnected = true
        MoshDiagnostics.log(
            "driver connected outputChunks=\(outputChunkCount) outputBytes=\(outputByteCount)"
        )
        onConnected()
    }

    private func reportTransportReachabilityIfNeededLocked() {
        guard let bridge, didReportConnected else { return }
        let reachable = bridge.isTransportReachable
        guard lastReportedTransportReachable != reachable else { return }
        lastReportedTransportReachable = reachable
        MoshDiagnostics.log(
            "driver transport reachability=\(reachable ? "connected" : "disconnected") ticks=\(tickCount) outputChunks=\(outputChunkCount)"
        )
        onTransportReachabilityChanged(reachable)
    }

    private func finishDisconnectedLocked() {
        guard !finished else { return }
        finished = true
        base64Key = nil
        cancelSourcesLocked()
        bridge = nil
        MoshDiagnostics.log(
            "driver finished disconnected ticks=\(tickCount) outputChunks=\(outputChunkCount) outputBytes=\(outputByteCount)"
        )
        onDisconnected()
    }

    private func failLocked(_ error: Error) {
        guard !finished else { return }
        finished = true
        base64Key = nil
        cancelSourcesLocked()
        bridge?.shutdown()
        bridge = nil
        let message = SensitiveDataRedactor.redact(
            (error as NSError).localizedDescription
        )
        MoshDiagnostics.log(
            "driver failed ticks=\(tickCount) outputChunks=\(outputChunkCount) outputBytes=\(outputByteCount) error=\(message)"
        )
        onFailed(message)
    }

    private func socketFDs(for bridge: MoshBridgeClient) -> [Int32] {
        bridge.socketFDs.compactMap { number in
            let value = number.int32Value
            return value >= 0 ? value : nil
        }
    }
}

/// Lightweight second SSH exec channel used only for tmux control-mode
/// traffic under mosh transport. The main mosh UDP session keeps owning
/// terminal rendering; this channel carries only `tmux -CC` metadata and
/// control commands.
enum TmuxControlChannelTerminationReason: Equatable {
    case cancelled
    case streamEnded
    case failed(String)

    var userFacingDescription: String {
        switch self {
        case .cancelled:
            return "control connection stopped"
        case .streamEnded:
            return "control stream ended"
        case .failed(let reason):
            return reason.isEmpty ? "control connection failed" : reason
        }
    }

    var logDescription: String {
        switch self {
        case .cancelled:
            return "cancelled"
        case .streamEnded:
            return "streamEnded"
        case .failed(let reason):
            return "failed(\(reason))"
        }
    }
}

@MainActor
final class TmuxControlChannel {
    private static let attachRetryLimit = 10
    private static let attachRetryDelayNanoseconds: UInt64 = 500_000_000

    private enum ControlMessage: Sendable {
        case resize(cols: Int, rows: Int)
    }

    let outputStream: AsyncStream<[UInt8]>
    private let outputContinuation: AsyncStream<[UInt8]>.Continuation

    private let host: Host
    private let requireBiometric: Bool
    private let isSecureEnclave: Bool
    private let sessionName: String
    private let preserveTmuxGeometry: Bool
    /// Existing authoritative grid captured before the visible mosh client
    /// attached. Keep the SSH control client's PTY at the same virtual size;
    /// otherwise two ignored compact clients make tmux fall back to 50x20.
    private let preservedServerSize: (cols: Int, rows: Int)?
    private var lastKnownSize: (cols: Int, rows: Int)?
    private let inputStream: AsyncStream<[UInt8]>
    private let inputContinuation: AsyncStream<[UInt8]>.Continuation
    private let controlStream: AsyncStream<ControlMessage>
    private let controlContinuation: AsyncStream<ControlMessage>.Continuation
    private var runTask: Task<Void, Never>?
    private var didStart = false
    private var client: SSHClient?
    private(set) var terminationReason: TmuxControlChannelTerminationReason?

    /// When non-nil, port-forwarders attach to the long-lived SSH client
    /// this channel opens for tmux -CC, and detach when it closes.
    /// Mosh's tmux side-channel is the only SSH connection that survives
    /// past mosh-server bootstrap, so it's the only place forwarding
    /// can ride for mosh hosts. Reconnect cycles re-attach with the
    /// fresh client; the manager dedupes by rule id.
    private let portForwarderManager: PortForwarderManager?
    private let portForwardRules: [PortForwardRule]

    init(
        host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false,
        sessionName: String,
        initialSize: (cols: Int, rows: Int)?,
        preserveTmuxGeometry: Bool = false,
        preservedServerSize: (cols: Int, rows: Int)? = nil,
        portForwarderManager: PortForwarderManager? = nil,
        portForwardRules: [PortForwardRule] = []
    ) {
        self.host = host
        self.requireBiometric = requireBiometric
        self.isSecureEnclave = isSecureEnclave
        self.sessionName = sessionName
        self.preserveTmuxGeometry = preserveTmuxGeometry
        self.preservedServerSize = preservedServerSize
        self.lastKnownSize = preservedServerSize ?? initialSize
        self.portForwarderManager = portForwarderManager
        self.portForwardRules = portForwardRules
        (outputStream, outputContinuation) = AsyncStream.makeStream(of: [UInt8].self)
        (inputStream, inputContinuation) = AsyncStream.makeStream(of: [UInt8].self)
        (controlStream, controlContinuation) = AsyncStream.makeStream(of: ControlMessage.self)
    }

    deinit {
        outputContinuation.finish()
        inputContinuation.finish()
        controlContinuation.finish()
    }

    func connect() {
        guard !didStart else { return }
        didStart = true
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        inputContinuation.yield(bytes)
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let remoteSize = preservedServerSize ?? (cols, rows)
        lastKnownSize = remoteSize
        controlContinuation.yield(.resize(cols: remoteSize.cols, rows: remoteSize.rows))
    }

    func disconnect() {
        terminationReason = .cancelled
        client = nil
        runTask?.cancel()
        runTask = nil
        inputContinuation.yield([])
        inputContinuation.finish()
        controlContinuation.finish()
        outputContinuation.finish()
    }

    func detectForegroundProcessNames(rootPID: Int) async -> [String] {
        await detectForegroundProcessNamesIfAvailable(rootPID: rootPID) ?? []
    }

    func detectForegroundProcessNamesIfAvailable(rootPID: Int) async -> [String]? {
        await detectForegroundProcessSnapshotIfAvailable(rootPID: rootPID)?.processNames
    }

    func detectForegroundProcessSnapshotIfAvailable(
        rootPID: Int
    ) async -> SwipePadPlainSSHProcessProbe.Snapshot? {
        guard let client else {
            SwipePadDiagnostics.log(
                "mosh tmux-pane-ps skipped reason=no-client rootPID=\(rootPID)"
            )
            return nil
        }

        do {
            let command = SwipePadPlainSSHProcessProbe.makeCommand(rootPID: rootPID)
            SwipePadDiagnostics.log(
                "mosh tmux-pane-ps begin rootPID=\(rootPID)"
            )
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
                "mosh tmux-pane-ps result rootPID=\(rootPID) candidateCount=\(snapshot.processNames.count) bytes=\(bytes.count)"
            )
            return snapshot
        } catch {
            SwipePadDiagnostics.log(
                "mosh tmux-pane-ps failed rootPID=\(rootPID) error='\(error)'"
            )
            return nil
        }
    }

    func executeConnectedCommand(_ command: String) async throws -> String {
        guard let client else {
            throw NSError(
                domain: "Tessera.TmuxControlChannel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The tmux control channel is not connected."]
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

    static func attachCommand(
        sessionName: String,
        preserveTmuxGeometry: Bool = false
    ) -> String {
        guard preserveTmuxGeometry else {
            return "tmux -CC attach -t \(sessionName)"
        }
        return AutoTmuxScript.geometryPreservingClientCommand(
            tmuxCommand: "tmux -CC attach",
            arguments: "-t \(sessionName)"
        )
    }

    private func run() async {
        let command = Self.attachCommand(
            sessionName: sessionName,
            preserveTmuxGeometry: preserveTmuxGeometry
        )
        MoshDiagnostics.log(
            "tmux sidechannel run start sessionNameLength=\(sessionName.count) transport=\(host.transport.rawValue) launchMode=\(host.launchMode.rawValue) port=\(host.port)"
        )
        var client: SSHClient?
        var connectedChain: EstablishedSSHChain?
        var terminationReason: TmuxControlChannelTerminationReason = .streamEnded

        do {
            let fallbackHost = host
            let requireBiometric = self.requireBiometric
            let isSecureEnclave = self.isSecureEnclave
            MoshDiagnostics.log(
                "tmux sidechannel ssh connect start port=\(fallbackHost.port) hops=\(fallbackHost.jumpChain.count + 1) sessionNameLength=\(self.sessionName.count)"
            )
            let chain = try await withPendingSSHConnectionAttempt {
                try await establishSSHChain(
                    for: fallbackHost,
                    requireBiometric: requireBiometric,
                    isSecureEnclave: isSecureEnclave,
                    hostKeyPrompt: nil
                )
            }
            let connectedClient = chain.client
            client = connectedClient
            connectedChain = chain
            self.client = connectedClient
            MoshDiagnostics.log(
                "tmux sidechannel ssh connected sessionNameLength=\(sessionName.count)"
            )

            // Attach any port-forward rules to this freshly-connected SSH
            // client. Reconnects produce a new SSHClient, so we always
            // detach in the cleanup epilogue (below) before the next run
            // re-attaches with the new client.
            if let portForwarderManager {
                await portForwarderManager.attach(to: connectedClient, rules: portForwardRules)
            }

            var attempt = 1
            while !Task.isCancelled {
                let stats = TmuxControlChannelAttemptStats()
                do {
                    MoshDiagnostics.log(
                        "tmux sidechannel attach attempt=\(attempt)/\(Self.attachRetryLimit) sessionNameLength=\(sessionName.count)"
                    )
                    try await connectedClient.withPTY(Self.ptyRequest(size: lastKnownSize)) {
                        (ttyOutput: TTYOutput, stdinWriter: TTYStdinWriter) in
                        try await Self.writeCommand(command, to: stdinWriter)
                        try await self.runControlLoops(
                            ttyOutput: ttyOutput,
                            stdinWriter: stdinWriter,
                            attempt: attempt,
                            stats: stats
                        )
                    }
                    let summary = await stats.snapshot()
                    if Self.shouldRetryCleanAttachEnd(summary: summary, attempt: attempt) {
                        MoshDiagnostics.log(
                            "tmux sidechannel attach ended empty attempt=\(attempt) retry=true \(summary.logDescription)"
                        )
                        attempt += 1
                        try await Task.sleep(nanoseconds: Self.attachRetryDelayNanoseconds)
                        continue
                    }
                    MoshDiagnostics.log(
                        "tmux sidechannel attach ended attempt=\(attempt) \(summary.logDescription)"
                    )
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let summary = await stats.snapshot()
                    let shouldRetry = Self.shouldRetryAttach(
                        error: error,
                        summary: summary,
                        attempt: attempt
                    )
                    MoshDiagnostics.log(
                        "tmux sidechannel attach failed attempt=\(attempt) retry=\(shouldRetry) error=\(Self.describeAttachError(error)) \(summary.logDescription)"
                    )
                    guard shouldRetry else { throw error }
                    attempt += 1
                    try await Task.sleep(nanoseconds: Self.attachRetryDelayNanoseconds)
                }
            }

            if Task.isCancelled {
                throw CancellationError()
            }
        } catch is CancellationError {
            terminationReason = .cancelled
            MoshDiagnostics.log(
                "tmux sidechannel cancelled sessionNameLength=\(sessionName.count)"
            )
        } catch {
            terminationReason = .failed(Self.describeAttachError(error))
            MoshDiagnostics.log(
                "tmux sidechannel failed sessionNameLength=\(sessionName.count) error=\(Self.describeAttachError(error))"
            )
        }

        // Tear down forwarders BEFORE closing the SSHClient so direct-tcpip
        // channels release cleanly. Manager.detach() awaits each forwarder
        // and is safe to call even when nothing was attached.
        if let portForwarderManager {
            await portForwarderManager.detach()
        }

        if let connectedChain {
            await connectedChain.closeAll()
            MoshDiagnostics.log(
                "tmux sidechannel ssh closed sessionNameLength=\(sessionName.count)"
            )
        }
        if let client, self.client === client {
            self.client = nil
        }

        self.terminationReason = terminationReason
        outputContinuation.finish()
        runTask = nil
        MoshDiagnostics.log(
            "tmux sidechannel output finished sessionNameLength=\(sessionName.count) reason=\(terminationReason.logDescription)"
        )
    }

    private static func shouldRetryCleanAttachEnd(
        summary: TmuxControlChannelAttemptSummary,
        attempt: Int
    ) -> Bool {
        attempt < attachRetryLimit
            && summary.stdoutBytes == 0
            && summary.stderrBytes == 0
    }

    private static func shouldRetryAttach(
        error: Error,
        summary: TmuxControlChannelAttemptSummary,
        attempt: Int
    ) -> Bool {
        guard attempt < attachRetryLimit else { return false }

        if summary.failurePattern != nil {
            return true
        }

        return error is SSHClient.CommandFailed && summary.stdoutBytes == 0
    }

    private static func describeAttachError(_ error: Error) -> String {
        if let commandFailed = error as? SSHClient.CommandFailed {
            return "commandFailed(exitCode=\(commandFailed.exitCode))"
        }
        return describeSSHError(error)
    }

    private static func ptyRequest(
        size: (cols: Int, rows: Int)?
    ) -> SSHChannelRequestEvent.PseudoTerminalRequest {
        SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: size?.cols ?? 80,
            terminalRowHeight: size?.rows ?? 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
    }

    private nonisolated static func writeCommand(
        _ command: String,
        to stdinWriter: TTYStdinWriter
    ) async throws {
        let line = "exec \(command)\n"
        var buffer = ByteBufferAllocator().buffer(capacity: line.utf8.count)
        buffer.writeBytes(line.utf8)
        try await stdinWriter.write(buffer)
    }

    private nonisolated func runControlLoops(
        ttyOutput: TTYOutput,
        stdinWriter: TTYStdinWriter,
        attempt: Int,
        stats: TmuxControlChannelAttemptStats
    ) async throws {
        let inputStream = self.inputStream
        let controlStream = self.controlStream

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await event in ttyOutput {
                    switch event {
                    case .stdout(let stdoutBuffer):
                        var buffer = stdoutBuffer
                        guard let bytes = buffer.readBytes(length: buffer.readableBytes),
                              !bytes.isEmpty
                        else { continue }
                        let log = await stats.recordStdout(bytes)
                        if log.chunkCount <= 4 {
                            MoshDiagnostics.log(
                                "tmux sidechannel stdout attempt=\(attempt) chunk#\(log.chunkCount) bytes=\(bytes.count) totalBytes=\(log.totalBytes)"
                            )
                        }
                        await self.yieldOutput(bytes)

                    case .stderr(let stderrBuffer):
                        var buffer = stderrBuffer
                        guard let bytes = buffer.readBytes(length: buffer.readableBytes),
                              !bytes.isEmpty
                        else { continue }
                        let log = await stats.recordStderr(bytes)
                        if log.chunkCount <= 4 {
                            MoshDiagnostics.log(
                                "tmux sidechannel stderr attempt=\(attempt) chunk#\(log.chunkCount) bytes=\(bytes.count) totalBytes=\(log.totalBytes)"
                            )
                        }
                    }
                }
            }

            group.addTask {
                var inputChunkCount = 0
                for await bytes in inputStream {
                    if bytes.isEmpty { continue }
                    inputChunkCount += 1
                    if inputChunkCount <= 4 {
                        MoshDiagnostics.log(
                            "tmux sidechannel stdin attempt=\(attempt) chunk#\(inputChunkCount) bytes=\(bytes.count)"
                        )
                    }
                    var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
                    buffer.writeBytes(bytes)
                    try await stdinWriter.write(buffer)
                }
            }

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

            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func yieldOutput(_ bytes: [UInt8]) {
        outputContinuation.yield(bytes)
    }
}

private struct TmuxControlChannelChunkLog: Sendable {
    let chunkCount: Int
    let totalBytes: Int
}

private enum TmuxControlChannelFailurePattern: String, Sendable {
    case missingSession
    case noServer
    case serverConnectionFailed
}

private struct TmuxControlChannelAttemptSummary: Sendable {
    let stdoutChunks: Int
    let stdoutBytes: Int
    let stderrChunks: Int
    let stderrBytes: Int
    let failurePattern: TmuxControlChannelFailurePattern?

    var logDescription: String {
        var description = "stdoutChunks=\(stdoutChunks) stdoutBytes=\(stdoutBytes) stderrChunks=\(stderrChunks) stderrBytes=\(stderrBytes)"
        if let failurePattern {
            description += " failurePattern=\(failurePattern.rawValue)"
        }
        return description
    }
}

private actor TmuxControlChannelAttemptStats {
    private var stdoutChunks = 0
    private var stdoutBytes = 0
    private var stderrChunks = 0
    private var stderrBytes = 0
    private var failurePattern: TmuxControlChannelFailurePattern?

    func recordStdout(_ bytes: [UInt8]) -> TmuxControlChannelChunkLog {
        stdoutChunks += 1
        stdoutBytes += bytes.count
        recordFailurePattern(in: bytes)
        return TmuxControlChannelChunkLog(
            chunkCount: stdoutChunks,
            totalBytes: stdoutBytes
        )
    }

    func recordStderr(_ bytes: [UInt8]) -> TmuxControlChannelChunkLog {
        stderrChunks += 1
        stderrBytes += bytes.count
        recordFailurePattern(in: bytes)
        return TmuxControlChannelChunkLog(
            chunkCount: stderrChunks,
            totalBytes: stderrBytes
        )
    }

    func snapshot() -> TmuxControlChannelAttemptSummary {
        TmuxControlChannelAttemptSummary(
            stdoutChunks: stdoutChunks,
            stdoutBytes: stdoutBytes,
            stderrChunks: stderrChunks,
            stderrBytes: stderrBytes,
            failurePattern: failurePattern
        )
    }

    private func recordFailurePattern(in bytes: [UInt8]) {
        guard failurePattern == nil else { return }

        let text = String(decoding: bytes, as: UTF8.self).lowercased()
        if text.contains("can't find session")
            || text.contains("no sessions") {
            failurePattern = .missingSession
        } else if text.contains("no server running") {
            failurePattern = .noServer
        } else if text.contains("failed to connect to server") {
            failurePattern = .serverConnectionFailed
        }
    }
}
