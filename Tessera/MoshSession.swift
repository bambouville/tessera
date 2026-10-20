import Dispatch
import Foundation
import Network
import UIKit
import Citadel
import MoshBridge
import NIOCore
import NIOSSH
import PortForwarding
import TesseraCore
import TesseraSessionCore
import TmuxControl
import TmuxControlCore

/// The bootstrap result and, for plain mosh only, its already-authenticated
/// SSH route. `withPendingSSHConnectionAttempt` needs a Sendable carrier so
/// cancellation can close that route before it escapes into a live session.
private struct MoshBootstrapAttempt: @unchecked Sendable {
    let result: MoshBootstrapResult
    let agentBootstrapConnection: MoshBootstrapConnection?
    /// The route the bootstrap authenticated over. The server PID it returned
    /// means something only on this route's destination.
    let route: Host
}

/// One renewable auxiliary SSH route for a surviving UDP session. Waiters share
/// authentication; cancellation of one consumer must not cancel other readers.
/// A retired attempt can finish late, but can never replace the current lease.
@MainActor
final class MoshAgentReadCarrier<Value: Sendable> {
    struct Lease: Sendable {
        let id = UUID()
        let value: Value
    }

    private(set) var current: Lease?
    private let close: @Sendable (Value) async -> Void
    private let deadline: Duration
    private let retryDelay: Duration
    private var retryAfter: ContinuousClock.Instant?
    private var attemptID: UUID?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Lease, Error>] = [:]

    init(deadline: Duration = .seconds(12), retryDelay: Duration = .seconds(2),
         close: @escaping @Sendable (Value) async -> Void) {
        self.deadline = deadline
        self.retryDelay = retryDelay
        self.close = close
    }

    deinit {
        worker?.cancel()
        timer?.cancel()
        if let current { let close = close; Task { await close(current.value) } }
        for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
    }

    func replace(with value: Value?) {
        reset()
        current = value.map { Lease(value: $0) }
    }

    func reset() {
        if let current { invalidate(current.id) }
        finishAttempt(.failure(CancellationError()), id: attemptID)
        retryAfter = nil
    }

    func invalidate(_ leaseID: UUID) {
        guard let current, current.id == leaseID else { return }
        self.current = nil
        let close = close
        Task { await close(current.value) }
    }

    func acquire(isUsable: (Value) -> Bool,
                 open: @escaping @Sendable () async throws -> Value) async throws -> Lease {
        try Task.checkCancellation()
        if let current {
            if isUsable(current.value) { return current }
            invalidate(current.id)
        }
        if let retryAfter, ContinuousClock.now < retryAfter {
            throw AgentProjectionError.channelUnavailable
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            let lease = try await withCheckedThrowingContinuation { continuation in
                waiters[waiterID] = continuation
                guard attemptID == nil else { return }
                let id = UUID()
                attemptID = id
                worker = Task { [weak self, close] in
                    let result: Result<Value, Error>
                    do { result = .success(try await open()) }
                    catch { result = .failure(error) }
                    guard let self, self.attemptID == id else {
                        if case .success(let value) = result { await close(value) }
                        return
                    }
                    self.finishAttempt(result.map { Lease(value: $0) }, id: id)
                }
                timer = Task { [weak self, deadline] in
                    do { try await Task.sleep(for: deadline) } catch { return }
                    self?.finishAttempt(.failure(AgentProjectionError.channelUnavailable), id: id)
                }
            }
            try Task.checkCancellation()
            return lease
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if waiters.isEmpty { finishAttempt(.failure(CancellationError()), id: attemptID) }
    }

    private func finishAttempt(_ result: Result<Lease, Error>, id: UUID?) {
        guard let id, attemptID == id else { return }
        attemptID = nil
        worker?.cancel(); worker = nil
        timer?.cancel(); timer = nil
        switch result {
        case .success(let lease): current = lease; retryAfter = nil
        case .failure(let error):
            if !(error is CancellationError) { retryAfter = .now.advanced(by: retryDelay) }
        }
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }
}

/// Transport failures retire only the auxiliary lease. Projector/relay commands
/// and user actions are never replayed by this wrapper.
struct MoshAgentReadExecHandle: AppleAgentStreamingExecHandle {
    let base: any AppleAgentStreamingExecHandle
    let isCurrent: @MainActor @Sendable () -> Bool
    let failed: @MainActor @Sendable (Error) -> Void

    func nextFrame() async throws -> AgentExecFrame? {
        do {
            guard await isCurrent() else { throw AppleAgentPlatformError.staleBinding }
            let frame = try await base.nextFrame()
            guard await isCurrent() else { throw AppleAgentPlatformError.staleBinding }
            return frame
        }
        catch { await failed(error); throw error }
    }

    func send(_ data: Data) async throws {
        do {
            guard await isCurrent() else { throw AppleAgentPlatformError.staleBinding }
            try await base.send(data)
            guard await isCurrent() else { throw AppleAgentPlatformError.staleBinding }
        }
        catch { await failed(error); throw error }
    }

    func cancel() async { await base.cancel() }
}

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

/// Resumes a continuation with whichever of several racers answers first.
private final class MoshProbeRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ value: T) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
        return continuation != nil
    }
}

/// Owns a liveness probe's SSH chain so an abandoned probe still closes it.
/// Citadel's exec waits on a future that ignores task cancellation; without
/// this, a probe whose exec never answered would keep its authenticated route
/// open after the watch had moved on to the next one.
private final class MoshProbeChainHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var chain: EstablishedSSHChain?
    private var isAbandoned = false

    /// False when the probe was abandoned first; the caller closes `chain`.
    func adopt(_ chain: EstablishedSSHChain) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isAbandoned else { return false }
        self.chain = chain
        return true
    }

    /// The chain for the probe to close itself, unless abandon took it.
    func take() -> EstablishedSSHChain? {
        lock.lock()
        defer { lock.unlock() }
        let chain = self.chain
        self.chain = nil
        return chain
    }

    func abandon() {
        lock.lock()
        isAbandoned = true
        let chain = self.chain
        self.chain = nil
        lock.unlock()
        guard let chain else { return }
        Task { await chain.closeAll() }
    }
}

/// Bytes a liveness preflight has received, confined to its connection's
/// serial queue.
private final class MoshPreflightBuffer: @unchecked Sendable {
    var bytes: [UInt8] = []
}

/// A server-loss rebuild stopped before running a custom launch command the
/// user has not agreed to rerun. It fails like the lost session did, with
/// Retry, which starts the host afresh.
private struct MoshServerLossRecoveryRefusedError: LocalizedError {
    var errorDescription: String? { MoshSession.serverLossMessage }
}

/// The probe reached a different destination than the one that started the
/// server, so its answer says nothing about this session.
private struct MoshLivenessRouteChangedError: Error {}

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

/// Match NotificationEngine's contact/reply thresholds and age selection.
struct MoshOutageTiming: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case contact, reply }

    let startedAt: TimeInterval
    let kind: Kind
    let seconds: Int

    static func next(
        previous: Self?, connected: Bool, reachable: Bool,
        serverContactAgeMilliseconds: UInt64, replyAgeMilliseconds: UInt64,
        now: TimeInterval
    ) -> Self? {
        guard connected, !reachable, now.isFinite else { return nil }
        let kind: Kind
        let age: UInt64
        if serverContactAgeMilliseconds > 6_500 {
            kind = .contact
            age = serverContactAgeMilliseconds
        } else if replyAgeMilliseconds > 10_000 {
            kind = .reply
            age = replyAgeMilliseconds
        } else {
            return nil
        }
        let seconds = Int(clamping: age / 1_000)
        // A kind switch selects a different clock, whose age may be younger.
        let previousSeconds = previous?.kind == kind ? previous?.seconds ?? 0 : 0
        return Self(
            startedAt: previous?.startedAt ?? now,
            kind: kind,
            seconds: max(previousSeconds, seconds)
        )
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
    private let gridAuthorityDeviceID: String?
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

    @Published public private(set) var state: SessionState = .idle {
        didSet {
            if state != .connected { outageTiming = nil }
            reconcileServerLivenessWatch()
        }
    }
    @Published private(set) var transportState: MoshTransportState = .idle {
        didSet { reconcileServerLivenessWatch() }
    }
    @Published private(set) var outageTiming: MoshOutageTiming?
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
    let appleAttemptOutputEvents: AsyncStream<SessionAttemptOutputChunk>
    private let appleAttemptOutputContinuation: AsyncStream<SessionAttemptOutputChunk>.Continuation
    nonisolated let appleOutputQueueDiagnostics: AsyncDeliveryDiagnostics?
    nonisolated private let outputPublicationDiagnostics: AsyncDeliveryDiagnostics
    private var preparedAppleSessionAttemptID: UUID?
    private var activeAppleSessionAttemptID: UUID?
    private var nextTransportInputDiagnosticCorrelation: String?

    private var driver: MoshTransportDriver?
    /// Agent reads start on the bootstrap SSH route and renew it independently
    /// when TCP dies while Mosh's UDP session survives a roam or suspension.
    private let agentReadCarrier = MoshAgentReadCarrier<MoshBootstrapConnection>(close: { await $0.close() })
    private var agentBootstrapResult: MoshBootstrapResult?
    private var agentBootstrapHost: Host?
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
    /// Consumed by ContentView on `.failed`: true means the host answered that
    /// this session's mosh-server no longer exists (a reboot, an OOM kill), so
    /// nothing will ever answer this client again. ContentView rebuilds it on
    /// a fresh server, as closing and reopening the tab would, when
    /// `MoshServerLossRecovery` allows; otherwise it stays failed with Retry.
    @Published private(set) var recommendsReconnectAfterServerLoss = false
    private lazy var serverLivenessWatch = MoshServerLivenessWatch(
        probe: { [weak self] pid in
            await self?.probeRemoteServerLiveness(pid: pid)
        },
        onServerGone: { [weak self] pid in
            self?.handleRemoteServerLoss(serverPID: pid)
        }
    )
    /// The server PID and the route whose destination it lives on. A probe
    /// asks that destination only; an edited host never answers for it.
    private var remoteServerRoute: (pid: Int, host: Host)?
    /// Set when this session rebuilds one whose server was lost: the restore
    /// policy that decided it. Every bootstrap attempt checks
    /// `MoshServerLossRecovery` again against the host it is about to
    /// launch, because a launch command edited in since the lost session
    /// started is not the one the decision approved.
    private let serverLossRecoveryRestorePolicy: SessionRestorePolicy?
    private var isAppInForeground = true
    nonisolated(unsafe) private var appActivityObservers: [NSObjectProtocol] = []
    private static let serverLivenessProbeTimeoutSeconds: TimeInterval = 12
    private static let serverLivenessPreflightTimeoutSeconds: TimeInterval = 5
    /// Transient bootstrap failures (network blip, DNS or a VPN still coming
    /// up after a wake, the host slow to open the exec channel right at
    /// reconnect time) retry on a fresh SSH connection before the session
    /// declares .failed — a manual retry seconds later reliably succeeds, so
    /// ride the blip out. The ladder is dense at first because the common
    /// causes clear within a second or two (field logs: a 10 s rung waited
    /// out after one failed lookup of a Tailscale name), and
    /// `ConnectivityRetryWake` cuts any rung short when the network path
    /// changes or the app returns to the foreground. Retries stop once the
    /// budget is spent; it still spans the ~50 s outages seen in the field
    /// when every attempt runs into a connect timeout. Attempts are charged at most
    /// `bootstrapRetryAttemptChargeCapSeconds`, so a suspension mid-attempt
    /// cannot spend the budget.
    private var bootstrapRetriesUsed = 0
    private var bootstrapRetryChargedSeconds: TimeInterval = 0
    private static let bootstrapRetryDelaysSeconds: [TimeInterval] = [1, 2, 3, 5, 8]
    private static let bootstrapRetryBudgetSeconds: TimeInterval = 60
    private static let bootstrapRetryAttemptChargeCapSeconds: TimeInterval = 16
    private var remoteServerMonitorTask: Task<Void, Never>?
    private var didStart = false
    private var didReachConnectedState = false
    private var lastReportedSize: (cols: Int, rows: Int)?
    /// PID of the detached remote mosh-server, parsed from its bootstrap
    /// banner. `private(set)`: the session view reads it to locate the
    /// server's child shell for the Files panel's cwd polling fallback
    /// (plain mosh can't carry OSC 7 — stock mosh-servers drop it before
    /// it ever reaches the state sync).
    private(set) var remoteServerPID: Int? {
        didSet { reconcileServerLivenessWatch() }
    }
    /// Allocated on the driver's serial queue before output crosses to the
    /// main actor. A side-channel render bind can therefore snapshot a true
    /// producer high-water mark and distinguish output already queued before
    /// the bind from the first SSP update produced afterwards.
    private let outputDeliverySequence = MoshOutputDeliverySequence()
    private var nextFullRepaintRequestID: UInt64 = 0
    private var outstandingFullRepaintRequestIDs: Set<UInt64> = []
    private var canceledFullRepaintRequestIDs: Set<UInt64> = []
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

    public convenience init(
        host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false,
        preserveTmuxGeometry: Bool = false,
        gridAuthorityDeviceID: String? = nil
    ) {
        self.init(
            host: host,
            requireBiometric: requireBiometric,
            isSecureEnclave: isSecureEnclave,
            preserveTmuxGeometry: preserveTmuxGeometry,
            serverLossRecoveryRestorePolicy: nil,
            gridAuthorityDeviceID: gridAuthorityDeviceID
        )
    }

    init(
        host: Host,
        requireBiometric: Bool,
        isSecureEnclave: Bool,
        preserveTmuxGeometry: Bool,
        serverLossRecoveryRestorePolicy: SessionRestorePolicy?,
        gridAuthorityDeviceID: String? = nil
    ) {
        self.gridAuthorityDeviceID = gridAuthorityDeviceID
        self.host = host
        self.serverLossRecoveryRestorePolicy = serverLossRecoveryRestorePolicy
        appleOutputQueueDiagnostics = SessionLatencyDiagnostics.queue(host: host.id, stage: "mosh-published-to-facade")
        outputPublicationDiagnostics = SessionLatencyDiagnostics.queue(host: host.id, stage: "mosh-driver-to-main-publication")
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
        let attemptOutputPair = AsyncStream.makeStream(of: SessionAttemptOutputChunk.self)
        appleAttemptOutputEvents = attemptOutputPair.stream
        appleAttemptOutputContinuation = attemptOutputPair.continuation

        // The liveness watch runs only in the foreground: a suspended app
        // cannot finish a probe, and a probe that needs Face ID must have a
        // user in front of it. Foreground, not active: the Face ID and
        // passcode sheets resign the app's activity, and stopping on that
        // would cancel the very prompt the probe is waiting on.
        // `applicationState` reads background during a cold launch, which
        // posts no willEnterForeground: becoming active also proves the
        // foreground (resigning proves nothing, so it is not observed).
        isAppInForeground = UIApplication.shared.applicationState != .background
        let center = NotificationCenter.default
        appActivityObservers = [
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppInForeground(true) }
            },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppInForeground(true) }
            },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppInForeground(false) }
            },
        ]
    }

    deinit {
        outputContinuation.finish()
        appleAttemptOutputContinuation.finish()
        for observer in appActivityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func prepareAppleSessionAttempt(_ attemptID: UUID) {
        preparedAppleSessionAttemptID = attemptID
    }

    var appleActiveSessionAttemptID: UUID? {
        activeAppleSessionAttemptID
    }

    public func connect() {
        guard !didStart else { return }
        // SessionEngine prepares shipped Apple connections. A direct
        // TerminalSession caller still receives one stable attempt token so
        // the compatibility API and transport harnesses keep exact output
        // provenance without weakening the adapter-owned application path.
        let attemptID = preparedAppleSessionAttemptID ?? UUID()
        preparedAppleSessionAttemptID = nil
        activeAppleSessionAttemptID = attemptID
        didStart = true
        state = .connecting
        transportState = .connecting
        MoshDiagnostics.log(
            "session connect start transport=\(host.transport.rawValue) launchMode=\(host.launchMode.rawValue) authKind=\(authKindDescription()) biometricRequired=\(requireBiometric) secureEnclave=\(isSecureEnclave)"
        )
        bootstrapTask = Task { [weak self] in
            await self?.bootstrapAndStart(attemptID: attemptID)
        }
    }

    public func send(_ bytes: [UInt8]) {
        sendAdmitting(bytes)
    }

    /// Admit bytes to the driver's ordered input queue. False means nothing
    /// was queued: the session is not connected or has no driver.
    @discardableResult
    func sendAdmitting(_ bytes: [UInt8]) -> Bool {
        let correlation = nextTransportInputDiagnosticCorrelation
        nextTransportInputDiagnosticCorrelation = nil
        guard !bytes.isEmpty, case .connected = state, let driver else { return false }
        let started = DispatchTime.now().uptimeNanoseconds
        driver.send(bytes, correlation: correlation)
        if let correlation {
            MoshDiagnostics.log(
                "latency-input-v3 host=\(host.id.uuidString.prefix(8)) transport=mosh stage=driver-enqueue corr=\(correlation) callMs=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)"
            )
        }
        return true
    }

    /// One-shot metadata supplied by the command facade immediately before
    /// [send]. It never records input bytes and cannot alter delivery.
    func noteTransportInputDiagnostic(correlation: String?) {
        nextTransportInputDiagnosticCorrelation = correlation
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
        requiringFreshRemoteState: Bool = false,
        onScheduled: (@MainActor (UInt64) -> Void)? = nil,
        completion: (@MainActor (UInt64?) -> Void)? = nil
    ) {
        guard nextFullRepaintRequestID < TerminalOutputReceipt.maximumIdentifier else {
            failReceiptSequence(kind: "repaint request")
            completion?(nil)
            return
        }
        nextFullRepaintRequestID += 1
        let requestID = nextFullRepaintRequestID
        outstandingFullRepaintRequestIDs.insert(requestID)
        onScheduled?(requestID)
        if canceledFullRepaintRequestIDs.remove(requestID) != nil {
            outstandingFullRepaintRequestIDs.remove(requestID)
            completion?(nil)
            return
        }
        guard case .connected = state, let driver else {
            outstandingFullRepaintRequestIDs.remove(requestID)
            completion?(nil)
            return
        }
        driver.forceFullRepaint(
            requestID: requestID,
            requiringFreshRemoteState: requiringFreshRemoteState
        ) { outputDeliveryTarget in
            Task { @MainActor in
                if outputDeliveryTarget == nil {
                    self.outstandingFullRepaintRequestIDs.remove(requestID)
                    self.canceledFullRepaintRequestIDs.remove(requestID)
                }
                completion?(outputDeliveryTarget)
            }
        }
    }

    /// Highest terminal delivery allocated by the Mosh producer, including
    /// chunks that have not yet reached the session event consumer. The
    /// driver queue fence also orders this read after any output callback
    /// already in progress when a side-channel bind establishes its cut.
    var latestOutputDeliveryID: UInt64 {
        driver?.outputDeliveryBarrier() ?? outputDeliverySequence.highWater
    }

    /// Retire a forced frame whose render owner no longer exists. The driver
    /// may already be producing it; suppressing the tagged chunk at the
    /// session boundary prevents it from entering a replacement view.
    public func cancelFullRepaint(requestID: UInt64) {
        guard outstandingFullRepaintRequestIDs.contains(requestID) else { return }
        canceledFullRepaintRequestIDs.insert(requestID)
        driver?.cancelFullRepaint(requestID: requestID)
    }

    /// Retire every full-frame request allocated before the caller changes
    /// render ownership. The returned high-water mark also lets the final
    /// surface reject a request whose bytes had already left this source but
    /// had not yet reached the terminal consumer.
    @discardableResult
    public func retireOutstandingFullRepaints() -> UInt64 {
        canceledFullRepaintRequestIDs.formUnion(outstandingFullRepaintRequestIDs)
        for requestID in outstandingFullRepaintRequestIDs {
            driver?.cancelFullRepaint(requestID: requestID)
        }
        return nextFullRepaintRequestID
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
        preparedAppleSessionAttemptID = nil
        activeAppleSessionAttemptID = nil
        jumpFallbackWatchdogTask?.cancel()
        jumpFallbackWatchdogTask = nil
        jumpFallbackCleanupTask?.cancel()
        jumpFallbackCleanupTask = nil
        bootstrapJumpChainHopCount = 0
        serverLivenessWatch.stop(reason: "disconnect")
        stopRemoteServerMonitor()
        releaseAgentBootstrapConnection()
        driver?.disconnect()
        driver = nil
        transportState = .disconnected
        if case .failed = state {
            return
        }
        state = .disconnected
    }

    private func bootstrapAndStart(attemptID: UUID) async {
        MoshDiagnostics.log(
            "bootstrap start transport=\(host.transport.rawValue) launchMode=\(host.launchMode.rawValue) port=\(host.port)"
        )
        let attemptStartedNanos = DispatchTime.now().uptimeNanoseconds
        let retryWakeGeneration = ConnectivityRetryWake.shared.generation
        do {
            let fallbackHost = host
            let requireBiometric = self.requireBiometric
            let isSecureEnclave = self.isSecureEnclave
            let recoveryRestorePolicy = serverLossRecoveryRestorePolicy
            let attempt = try await withPendingSSHConnectionAttempt(
                onRejectedValue: { (attempt: MoshBootstrapAttempt) in
                    if let connection = attempt.agentBootstrapConnection {
                        await connection.close()
                    }
                }
            ) {
                // Resolve the endpoint here because MoshBootstrap is owned by
                // the parallel transcript-redaction remediation. Its common
                // auth resolver fails closed if this policy changes again.
                let policy = try await resolveSSHConnectionPolicy(
                    for: fallbackHost,
                    requireBiometric: requireBiometric,
                    isSecureEnclave: isSecureEnclave
                )
                if let recoveryRestorePolicy,
                   MoshServerLossRecovery.decide(
                       launchMode: policy.host.launchMode,
                       launchCommand: policy.host.launchCommand,
                       restorePolicy: recoveryRestorePolicy,
                       isAppLocked: false
                   ) != .rebuild {
                    throw MoshServerLossRecoveryRefusedError()
                }
                let visibleTmuxClientIgnoresSize = policy.host.launchMode == .autoTmux
                    || policy.host.launchMode == .pinnedTmux
                if policy.host.launchMode == .customCommand {
                    let connection = try await MoshBootstrap.bootstrapRetainingConnection(
                        host: policy.host,
                        requireBiometric: policy.requireBiometric,
                        isSecureEnclave: policy.isSecureEnclave,
                        hostKeyPrompt: { [weak self] challenge in
                            await self?.promptForHostKeyVerification(challenge) ?? false
                        },
                        preserveTmuxGeometry: self.preserveTmuxGeometry,
                        visibleTmuxClientIgnoresSize: visibleTmuxClientIgnoresSize,
                        gridAuthorityDeviceID: self.gridAuthorityDeviceID ?? GridAuthorityDeviceIdentity.current().id
                    )
                    do {
                        try Task.checkCancellation()
                        try await SSHAuthenticationPolicyStore.shared.revalidate(policy)
                        return MoshBootstrapAttempt(
                            result: connection.result,
                            agentBootstrapConnection: connection,
                            route: connection.resolvedHost
                        )
                    } catch {
                        await connection.close()
                        throw error
                    }
                }
                let result = try await MoshBootstrap.bootstrap(
                    host: policy.host,
                    requireBiometric: policy.requireBiometric,
                    isSecureEnclave: policy.isSecureEnclave,
                    hostKeyPrompt: { [weak self] challenge in
                        await self?.promptForHostKeyVerification(challenge) ?? false
                    },
                    preserveTmuxGeometry: self.preserveTmuxGeometry,
                    visibleTmuxClientIgnoresSize: visibleTmuxClientIgnoresSize,
                    gridAuthorityDeviceID: self.gridAuthorityDeviceID ?? GridAuthorityDeviceIdentity.current().id
                )
                try Task.checkCancellation()
                try await SSHAuthenticationPolicyStore.shared.revalidate(policy)
                return MoshBootstrapAttempt(
                    result: result,
                    agentBootstrapConnection: nil,
                    route: policy.host
                )
            }

            guard !Task.isCancelled else {
                if let connection = attempt.agentBootstrapConnection {
                    await connection.close()
                }
                return
            }
            let result = attempt.result
            releaseAgentBootstrapConnection()
            if let connection = attempt.agentBootstrapConnection {
                agentBootstrapResult = connection.result
                agentBootstrapHost = connection.resolvedHost
                agentReadCarrier.replace(with: connection)
            }

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
                base64Key: result.base64Key,
                attemptID: attemptID
            )
            remoteServerRoute = result.serverPID.map { (pid: $0, host: attempt.route) }
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
            let attemptSeconds = TimeInterval(
                DispatchTime.now().uptimeNanoseconds - attemptStartedNanos
            ) / 1_000_000_000
            bootstrapRetryChargedSeconds += Self.bootstrapRetryCharge(
                forAttemptSeconds: attemptSeconds
            )
            if let backoff = nextBootstrapRetryDelay(after: error) {
                // bootstrapTask stays non-nil so disconnect() can still
                // cancel the sleeping retry.
                bootstrapRetriesUsed += 1
                bootstrapRetryChargedSeconds += backoff
                MoshDiagnostics.log(
                    "bootstrap retry #\(bootstrapRetriesUsed) backoffSeconds=\(Int(backoff)) chargedSeconds=\(Int(bootstrapRetryChargedSeconds.rounded())) error=\(SensitiveDataRedactor.redact(String(describing: error)))"
                )
                let wake = await ConnectivityRetryWake.shared.sleep(
                    seconds: backoff,
                    unlessSignalledSince: retryWakeGeneration
                )
                if wake == .signalled {
                    MoshDiagnostics.log("bootstrap retry #\(bootstrapRetriesUsed) woke early")
                }
                guard wake != .cancelled, !Task.isCancelled, state == .connecting else {
                    bootstrapTask = nil
                    MoshDiagnostics.log("bootstrap cancelled")
                    transportState = .disconnected
                    if state != .disconnected {
                        state = .disconnected
                    }
                    return
                }
                await bootstrapAndStart(attemptID: attemptID)
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

    private func releaseAgentBootstrapConnection() {
        agentReadCarrier.reset()
        agentBootstrapResult = nil
        agentBootstrapHost = nil
    }

    /// A new route must reach the same account through the same verified
    /// endpoints as the UDP session. Credential policy is still resolved live.
    /// Editing the destination requires reconnecting the terminal, not reading
    /// a different machine's transcript under this session's identity.
    static func isSameAgentReadRoute(_ lhs: Host, _ rhs: Host) -> Bool {
        let left = lhs.jumpChain + [lhs]
        let right = rhs.jumpChain + [rhs]
        return lhs.jumpChainBrokenReason == nil && rhs.jumpChainBrokenReason == nil
            && left.count == right.count
            && zip(left, right).allSatisfy {
                $0.id == $1.id && $0.address == $1.address && $0.port == $1.port && $0.user == $1.user
            }
    }

    private func acquireAgentReadCarrier(expectedAttemptID: UUID?) async throws
        -> MoshAgentReadCarrier<MoshBootstrapConnection>.Lease {
        guard case .connected = state, activeAppleSessionAttemptID == expectedAttemptID,
              let result = agentBootstrapResult, let originalHost = agentBootstrapHost else {
            throw AppleAgentPlatformError.staleBinding
        }
        let host = host
        let requireBiometric = requireBiometric
        let isSecureEnclave = isSecureEnclave
        let lease = try await agentReadCarrier.acquire(isUsable: { $0.client.isConnected }) {
            try await withPendingSSHConnectionAttempt(onRejectedValue: { await $0.close() }) {
                let policy = try await resolveSSHConnectionPolicy(
                    for: host, requireBiometric: requireBiometric, isSecureEnclave: isSecureEnclave
                )
                guard await Self.isSameAgentReadRoute(originalHost, policy.host) else {
                    throw AppleAgentPlatformError.staleBinding
                }
                let chain = try await establishSSHChain(
                    for: policy.host, requireBiometric: policy.requireBiometric,
                    isSecureEnclave: policy.isSecureEnclave, hostKeyPrompt: nil
                )
                do {
                    try Task.checkCancellation()
                    try await SSHAuthenticationPolicyStore.shared.revalidate(policy)
                    guard await Self.isSameAgentReadRoute(originalHost, chain.resolvedHost) else {
                        throw AppleAgentPlatformError.staleBinding
                    }
                    MoshDiagnostics.log("agent read carrier renewed")
                    return MoshBootstrapConnection(result: result, chain: chain)
                } catch {
                    await chain.closeAll()
                    throw error
                }
            }
        }
        guard case .connected = state, activeAppleSessionAttemptID == expectedAttemptID,
              agentReadCarrier.current?.id == lease.id else {
            throw AppleAgentPlatformError.staleBinding
        }
        return lease
    }

    private func retireFailedAgentReadCarrier(_ leaseID: UUID, error: Error) {
        // Child cancellation, supersession and remote program errors do not
        // establish that the authenticated SSH route itself is broken.
        guard !(error is CancellationError), !(error is AppleAgentPlatformError),
              !(error is SSHClient.CommandFailed) else { return }
        agentReadCarrier.invalidate(leaseID)
    }

    var canInspectAgentIntegration: Bool {
        state == .connected && agentBootstrapResult != nil
    }

    /// Read-only integration/process inspection on this session's owned route.
    /// Installation commands keep their explicit installer path; this helper
    /// neither opens a Files connection nor retries a submitted command.
    func executeAgentIntegrationProbeCommand(_ command: String) async throws -> String {
        let expectedAttemptID = activeAppleSessionAttemptID
        let lease = try await acquireAgentReadCarrier(expectedAttemptID: expectedAttemptID)
        do {
            let result = try await AppleAgentBoundedCommandExec.run(client: lease.value.client, command: command)
            guard !Task.isCancelled, state == .connected,
                  activeAppleSessionAttemptID == expectedAttemptID,
                  agentReadCarrier.current?.id == lease.id else {
                throw AppleAgentPlatformError.staleBinding
            }
            return result
        } catch {
            retireFailedAgentReadCarrier(lease.id, error: error)
            throw error
        }
    }

    #if DEBUG
    var agentReadCarrierIDForTesting: UUID? { agentReadCarrier.current?.id }

    var serverLivenessProbeCountForTesting: Int { serverLivenessWatch.probeCount }

    var serverLivenessLastOutcomeForTesting: MoshServerLivenessPolicy.Outcome? {
        serverLivenessWatch.lastOutcome
    }

    /// Close the real auxiliary TCP route without altering Mosh or clearing the
    /// lease, so fixture tests exercise production dead-client detection.
    func dropAgentReadCarrierForTesting() async {
        if let lease = agentReadCarrier.current { await lease.value.close() }
    }
    #endif

    func detectForegroundProcessSnapshotIfAvailable(
        rootPID: Int, expectedPID: Int? = nil
    ) async -> SwipePadPlainSSHProcessProbe.Snapshot? {
        guard case .connected = state, rootPID > 0 else { return nil }
        do {
            let output = try await executeAgentIntegrationProbeCommand(
                SwipePadPlainSSHProcessProbe.makeCommand(rootPID: rootPID, expectedPID: expectedPID)
            )
            return SwipePadPlainSSHProcessProbe.snapshot(from: output)
        } catch {
            return nil
        }
    }

    /// Opens a read child on this session's renewable auxiliary SSH route.
    /// Recovery never repeats mosh-server startup or touches terminal input.
    func agentProjectorExecAvailability(
        binding: AgentTerminalBinding,
        isBindingCurrent: @escaping @MainActor @Sendable (AgentTerminalBinding) -> Bool
    ) -> AppleAgentExecAvailability {
        guard binding.transport == .mosh,
              case .connected = state,
              agentBootstrapResult != nil else {
            return .unavailable(.sideChannelUnavailable)
        }
        let expectedAttemptID = activeAppleSessionAttemptID
        return .available(AppleAgentStreamingExecFactory { [weak self] request in
            guard request.binding == binding else {
                throw AppleAgentPlatformError.staleBinding
            }
            guard let self else { throw AppleAgentPlatformError.staleBinding }
            guard await isBindingCurrent(request.binding) else { throw AppleAgentPlatformError.staleBinding }
            let lease = try await self.acquireAgentReadCarrier(expectedAttemptID: expectedAttemptID)
            let stillCurrent: @MainActor @Sendable (AgentTerminalBinding) -> Bool = { [weak self] candidate in
                guard let self else { return false }
                return self.state == .connected
                    && self.activeAppleSessionAttemptID == expectedAttemptID
                    && self.agentReadCarrier.current?.id == lease.id
                    && isBindingCurrent(candidate)
            }
            do {
                let handle = try await AppleAgentIngestionConnection.withSearchDeadline(.seconds(6), discard: { await $0.cancel() }) {
                    guard stillCurrent(request.binding) else { throw AppleAgentPlatformError.staleBinding }
                    return try await AppleCitadelAgentExecHandle.open(
                        client: lease.value.client, request: request, isBindingCurrent: stillCurrent
                    )
                }
                return MoshAgentReadExecHandle(base: handle, isCurrent: { stillCurrent(binding) }, failed: { [weak self] error in
                    self?.retireFailedAgentReadCarrier(lease.id, error: error)
                })
            } catch {
                await self.retireFailedAgentReadCarrier(lease.id, error: error)
                throw error
            }
        })
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
                String(localized: "The remote mosh-server PID was unavailable, so Tessera did not start a second login command automatically.")
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
                    String(localized: "mosh is unreachable through the jump chain — UDP cannot traverse SSH bastions. Reconnecting over SSH…")
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
            String(
                localized: "mosh is unreachable through the jump chain, but Tessera could not safely stop its remote mosh-server before switching transports. \(SensitiveDataRedactor.redact(detail)) Connect with SSH manually.",
                comment: "mosh jump-chain fallback could not clean up the remote mosh-server"
            )
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
    private func nextBootstrapRetryDelay(after error: Error) -> TimeInterval? {
        guard state == .connecting,
              let bootstrapError = error as? MoshBootstrapError,
              case .connectionFailed = bootstrapError
        else { return nil }
        return Self.bootstrapRetryDelay(
            retriesUsed: bootstrapRetriesUsed,
            chargedSeconds: bootstrapRetryChargedSeconds
        )
    }

    /// The next rung, or nil once it would overrun the budget. Past the end of
    /// the ladder the delay holds at its last rung.
    static func bootstrapRetryDelay(
        retriesUsed: Int,
        chargedSeconds: TimeInterval
    ) -> TimeInterval? {
        let ladder = bootstrapRetryDelaysSeconds
        let delay = ladder[min(max(retriesUsed, 0), ladder.count - 1)]
        guard chargedSeconds + delay <= bootstrapRetryBudgetSeconds else { return nil }
        return delay
    }

    /// What one failed attempt costs the retry budget.
    static func bootstrapRetryCharge(forAttemptSeconds seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, 0), bootstrapRetryAttemptChargeCapSeconds)
    }

    private func makeDriver(
        targetAddress: String,
        udpPort: Int,
        base64Key: String,
        attemptID: UUID
    ) -> MoshTransportDriver {
        MoshTransportDriver(
            host: targetAddress,
            diagnosticHostID: host.id,
            udpPort: udpPort,
            base64Key: base64Key,
            outputDeliverySequence: outputDeliverySequence,
            onOutput: { [weak self] bytes, deliveryID, repaintRequestID, delivered in
                let publication = self?.outputPublicationDiagnostics
                publication?.enqueued()
                Task { @MainActor in
                    defer { publication?.consumed() }
                    guard let self else { return }
                    let chunkIndex = deliveryID
                    if chunkIndex <= 12 || chunkIndex == 25 || chunkIndex == 50 {
                        MoshDiagnostics.log(
                            "session output delivery chunk#\(chunkIndex) bytes=\(bytes.count)"
                        )
                    }
                    let canceled = repaintRequestID.map {
                        self.outstandingFullRepaintRequestIDs.remove($0)
                        return self.canceledFullRepaintRequestIDs.remove($0) != nil
                    } ?? false
                    if !canceled {
                        self.outputContinuation.yield(bytes)
                        self.appleOutputQueueDiagnostics?.enqueued()
                        self.appleAttemptOutputContinuation.yield(SessionAttemptOutputChunk(
                            attemptID: attemptID,
                            bytes: bytes,
                            deliveryID: deliveryID,
                            repaintRequestID: repaintRequestID
                        ))
                    }
                    delivered?(deliveryID)
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
                    self.releaseAgentBootstrapConnection()
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
                    self.releaseAgentBootstrapConnection()
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
            },
            onOutageChanged: { [weak self] timing in
                Task { @MainActor in
                    guard let self, self.state == .connected,
                          self.activeAppleSessionAttemptID == attemptID else { return }
                    self.outageTiming = timing
                }
            }
        )
    }

    private func failReceiptSequence(kind: String) {
        let message = "Mosh \(kind) sequence exhausted"
        MoshDiagnostics.log(message)
        state = .failed(message)
        updateTransportState(.disconnected, reason: message)
        driver?.disconnect()
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

    // MARK: - Server liveness

    private func setAppInForeground(_ foreground: Bool) {
        guard isAppInForeground != foreground else { return }
        isAppInForeground = foreground
        reconcileServerLivenessWatch()
    }

    private func reconcileServerLivenessWatch() {
        serverLivenessWatch.update(MoshServerLivenessWatch.Conditions(
            isSessionConnected: state == .connected,
            isTransportReachable: transportState == .connected,
            isAppInForeground: isAppInForeground,
            serverPID: remoteServerPID
        ))
    }

    /// The host said this session's server is gone. Mosh would keep calling
    /// the session connected forever, so end it the way the jump fallback
    /// does: `.failed` first so driver teardown cannot replace the verdict,
    /// with `recommendsReconnectAfterServerLoss` telling ContentView to
    /// rebuild it on a fresh server.
    private func handleRemoteServerLoss(serverPID: Int) {
        guard state == .connected, remoteServerPID == serverPID else { return }
        MoshDiagnostics.log(
            "server liveness gone pid=\(serverPID) transport=\(transportState.logDescription) launchMode=\(host.launchMode.rawValue)"
        )
        stopRemoteServerMonitor()
        releaseAgentBootstrapConnection()
        recommendsReconnectAfterServerLoss = true
        updateTransportState(.disconnected, reason: "server gone")
        state = .failed(Self.serverLossMessage)
        driver?.disconnect()
        driver = nil
    }

    nonisolated static var serverLossMessage: String {
        String(
            localized: "The mosh-server for this session is no longer running — the host may have restarted.",
            comment: "A mosh session ended because the host reported its remote mosh-server gone; Retry starts a new one"
        )
    }

    /// One liveness question to the host on a fresh SSH connection. Failing
    /// to reach or log in is `hostUnreachable` — the host is still down or out
    /// of reach, which says nothing about the server. Anything that needs the
    /// user (a cancelled Face ID, a locked app, a host key to approve) or a
    /// route that no longer leads to the server's host is `unknown`.
    private func probeRemoteServerLiveness(
        pid: Int
    ) async -> MoshServerLivenessWatch.ProbeAnswer {
        guard let route = remoteServerRoute, route.pid == pid else {
            MoshDiagnostics.log("server liveness probe skipped pid=\(pid) reason=no-route")
            return .init(outcome: .unknown)
        }
        let policy: SSHConnectionPolicySnapshot
        let mayAskOwner: Bool
        do {
            policy = try await resolveSSHConnectionPolicy(
                for: host,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave
            )
            mayAskOwner = try await Self.routeMayAskForOwner(policy)
        } catch {
            MoshDiagnostics.log(
                "server liveness probe policy unavailable pid=\(pid) error=\(describeSSHError(error))"
            )
            return .init(outcome: .unknown)
        }
        guard Self.isSameAgentReadRoute(route.host, policy.host) else {
            MoshDiagnostics.log("server liveness probe skipped pid=\(pid) reason=route-changed")
            return .init(outcome: .unknown)
        }
        if mayAskOwner {
            // Resolving a protected key raises Face ID before any packet is
            // sent, so a host that is still down would prompt on every rung.
            // Ask for the key only once the first hop answers as an SSH
            // server. Until then nothing was asked of the user, and the timed
            // ladder stands.
            let firstHop = policy.host.jumpChain.first ?? policy.host
            let answers = await Self.answersAsSSHServer(
                address: firstHop.address,
                port: firstHop.port,
                timeoutSeconds: Self.serverLivenessPreflightTimeoutSeconds
            )
            guard !Task.isCancelled else { return .init(outcome: .unknown) }
            guard answers else {
                MoshDiagnostics.log("server liveness preflight unanswered pid=\(pid)")
                return .init(outcome: .hostUnreachable)
            }
        }

        let probeHost = host
        let requireBiometric = self.requireBiometric
        let isSecureEnclave = self.isSecureEnclave
        let routeHost = route.host
        let holder = MoshProbeChainHolder()
        // Whether this probe put a prompt in front of the user, rather than
        // whether its route could: a cached grant asks nothing, and a hop
        // that fails before its key is resolved asks nothing either.
        let prompts = SSHPromptAttribution()
        let probe = SSHPromptAttribution.$current.withValue(prompts) {
            Task { () -> MoshServerLivenessPolicy.Outcome in
                do {
                    let output = try await Self.runRemoteServerLivenessScript(
                        on: probeHost,
                        route: routeHost,
                        requireBiometric: requireBiometric,
                        isSecureEnclave: isSecureEnclave,
                        serverPID: pid,
                        holder: holder
                    )
                    return MoshServerLivenessPolicy.Outcome(
                        MoshBootstrapGrammar.parseServerLiveness(output)
                    )
                } catch {
                    let outcome = Self.livenessOutcome(for: error)
                    MoshDiagnostics.log(
                        "server liveness probe failed pid=\(pid) outcome=\(outcome.rawValue) error=\(describeSSHError(error))"
                    )
                    return outcome
                }
            }
        }
        let outcome = await withTaskCancellationHandler {
            await Self.value(
                of: probe,
                timeoutSeconds: Self.serverLivenessProbeTimeoutSeconds,
                fallback: .hostUnreachable,
                onAbandon: { holder.abandon() }
            )
        } onCancel: {
            probe.cancel()
            holder.abandon()
        }
        // A lock, an unlock or a credential change while the answer was in
        // flight voids it: the session must not end, or be rebuilt, on the
        // strength of a check the current policy would not have allowed.
        let askedOwner = prompts.askedOwner
        do {
            try SSHAuthenticationPolicyStore.shared.revalidate(policy)
        } catch {
            MoshDiagnostics.log(
                "server liveness probe voided pid=\(pid) outcome=\(outcome.rawValue) error=\(describeSSHError(error))"
            )
            return .init(outcome: .unknown, askedOwner: askedOwner)
        }
        return .init(outcome: outcome, askedOwner: askedOwner)
    }

    /// Whether connecting over `policy`'s route can ask the device owner for
    /// a key on any hop. Bastions resolve their own key policy, exactly as
    /// `establishSSHChain` does.
    private static func routeMayAskForOwner(
        _ policy: SSHConnectionPolicySnapshot
    ) async throws -> Bool {
        if policy.requireBiometric { return true }
        let store = SSHAuthenticationPolicyStore.shared
        for hop in policy.host.jumpChain {
            if store.hasCurrentPolicyProvider {
                store.registerPersistedHost(hop.id)
            }
            let hopPolicy = try await resolveSSHConnectionPolicy(
                for: hop,
                requireBiometric: false,
                isSecureEnclave: false
            )
            if hopPolicy.requireBiometric { return true }
        }
        return false
    }

    /// Only a failure to reach or log in to the host is `hostUnreachable`.
    /// What needs the user (credentials, host-key trust) or proves nothing
    /// about this server (cancellation, a changed route) is `unknown`.
    nonisolated static func livenessOutcome(
        for error: Error
    ) -> MoshServerLivenessPolicy.Outcome {
        var underlying = error
        while let hop = underlying as? SSHChainHopError {
            underlying = hop.underlying
        }
        switch underlying {
        case is CancellationError, is AuthResolutionError, is HostKeyRejectedError,
             is HostKeyApprovalRequired, is MoshLivenessRouteChangedError:
            return .unknown
        case let client as SSHClientError:
            // The host is up and refused this login: a credential for the
            // user to fix, not a host that is still coming back.
            switch client {
            case .allAuthenticationOptionsFailed, .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication, .unsupportedHostBasedAuthentication:
                return .unknown
            default:
                return .hostUnreachable
            }
        default:
            return .hostUnreachable
        }
    }

    private nonisolated static func runRemoteServerLivenessScript(
        on host: Host,
        route: Host,
        requireBiometric: Bool,
        isSecureEnclave: Bool,
        serverPID: Int,
        holder: MoshProbeChainHolder
    ) async throws -> String {
        let chain = try await withPendingSSHConnectionAttempt {
            try await establishSSHChain(
                for: host,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave,
                hostKeyPrompt: nil
            )
        }
        guard holder.adopt(chain) else {
            await chain.closeAll()
            throw CancellationError()
        }
        do {
            guard await isSameAgentReadRoute(route, chain.resolvedHost) else {
                throw MoshLivenessRouteChangedError()
            }
            var output = try await chain.client.executeCommand(
                MoshBootstrapGrammar.makeServerLivenessScript(pid: serverPID),
                maxResponseSize: 4 * 1024
            )
            let text = output.readString(length: output.readableBytes) ?? ""
            await holder.take()?.closeAll()
            return text
        } catch {
            await holder.take()?.closeAll()
            throw error
        }
    }

    /// Wait for `task`, giving up after `timeoutSeconds` of waiting. SSH
    /// connects only time out after 30 s, and a rebooting host often drops
    /// packets rather than refusing them. Time spent while Face ID or a
    /// passcode sheet is up does not count: abandoning there would tear the
    /// sheet down under the user's finger and ask again on the next rung.
    /// An overrunning probe is cancelled, `onAbandon` closes what it holds,
    /// and its late answer is discarded.
    static func value<T: Sendable>(
        of task: Task<T, Never>,
        timeoutSeconds: TimeInterval,
        fallback: T,
        onAbandon: @escaping @Sendable () -> Void
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let race = MoshProbeRace(continuation)
            let timer = Task { @MainActor in
                var spent: TimeInterval = 0
                var lastTick = Date()
                while spent < timeoutSeconds {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    let now = Date()
                    // A suspension mid-wait is not the host's silence.
                    let delta = min(now.timeIntervalSince(lastTick), 1)
                    lastTick = now
                    if !SSHHandshakePromptGate.isPrompting {
                        spent += delta
                    }
                }
                guard race.resume(fallback) else { return }
                task.cancel()
                onAbandon()
            }
            Task {
                let value = await task.value
                timer.cancel()
                race.resume(value)
            }
        }
    }

    /// Whether `address:port` answers as an SSH server within the timeout:
    /// the TCP handshake completes and the server sends its identification
    /// line. A refusal, an unsatisfied path, silence and a listener that
    /// accepts before sshd can serve all count as no.
    private nonisolated static func answersAsSSHServer(
        address: String,
        port: Int,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return false
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(address),
            port: nwPort,
            using: .tcp
        )
        let queue = DispatchQueue(label: "tessera.mosh-liveness-preflight")
        let received = MoshPreflightBuffer()
        let answered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let race = MoshProbeRace(continuation)
            // Callbacks all run on `queue`, which confines `received`.
            @Sendable func receiveMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { data, _, isComplete, error in
                    if let data {
                        received.bytes.append(contentsOf: data)
                        switch scanSSHIdentification(received.bytes) {
                        case .identified:
                            race.resume(true)
                            return
                        case .notSSH:
                            race.resume(false)
                            return
                        case .needMore:
                            break
                        }
                    }
                    guard error == nil, !isComplete else {
                        race.resume(false)
                        return
                    }
                    receiveMore()
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    receiveMore()
                case .waiting, .failed, .cancelled:
                    race.resume(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                race.resume(false)
            }
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        return answered
    }

    enum SSHIdentificationScan: Equatable {
        case identified
        case needMore
        case notSSH
    }

    /// Whether the bytes a server sent so far hold its SSH identification
    /// line: a line that starts "SSH-". RFC 4253 lets a server send other
    /// lines first, and TCP may split any of them, so a line that is still
    /// arriving, or could still turn into one, asks for more. A server that
    /// sends `limit` bytes without one is not an SSH server.
    nonisolated static func scanSSHIdentification(
        _ received: [UInt8],
        limit: Int = 8 * 1_024
    ) -> SSHIdentificationScan {
        let marker = Array("SSH-".utf8)
        // Only the first `limit` bytes count, so a stream that keeps ending
        // in a partial "SS" cannot keep the check reading.
        let window = received.prefix(limit)
        let full = window.count >= limit
        var lineStart = window.startIndex
        while lineStart < window.endIndex {
            let line = window[lineStart...]
            let compared = min(line.count, marker.count)
            if line.prefix(compared).elementsEqual(marker.prefix(compared)) {
                if compared == marker.count { return .identified }
                return full ? .notSSH : .needMore
            }
            guard let newline = line.firstIndex(of: UInt8(ascii: "\n")) else { break }
            lineStart = newline + 1
        }
        return full ? .notSSH : .needMore
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
                        String(localized: "Remote exit monitor finished without an exit marker.")
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
            return String(
                localized: "Could not start mosh. The remote host may not have `mosh-server` installed or on PATH, or it exited immediately during startup.",
                comment: "mosh startup failure with no usable detail from the host"
            )
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
            return String(localized: "Could not start mosh: the host accepted the SSH connection but never opened the command channel (15 s). It may be overloaded or limiting sessions.")
        }

        if lowered == "connection closed"
            || lowered.contains("closed")
            || lowered.contains("shutdown")
            || lowered.contains("end of file")
            || lowered.contains("eof")
        {
            return String(
                localized: "Could not start mosh. The remote host may not have `mosh-server` installed or on PATH, or it exited immediately during startup.",
                comment: "mosh startup failure with no usable detail from the host"
            )
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

/// One monotonically increasing receipt source shared by a Mosh session and
/// its driver. Allocation happens before the driver hands output to another
/// executor, while reads happen on the main actor at a render-owner bind.
final class MoshOutputDeliverySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var highWater: UInt64 {
        lock.withLock { value }
    }

    func allocate() -> UInt64? {
        lock.withLock {
            guard value < TerminalOutputReceipt.maximumIdentifier else { return nil }
            value += 1
            return value
        }
    }
}

final class MoshTransportDriver {
    private let host: String
    private let diagnosticHost: String
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
    private var outageTiming: MoshOutageTiming?
    private var tickCount = 0
    private var outputChunkCount = 0
    private var outputByteCount = 0
    /// Non-nil only during a forced framebuffer replay. Buffer its chunks so
    /// the delivery callback can identify the exact AsyncStream element whose
    /// consumption is allowed to lift the continuity veil.
    private var forceFullRepaintOutput: [UInt8]?
    private struct PendingFullRepaint {
        let bridge: MoshBridgeClient
        let fenceToken: UInt64?
        let deadline: ContinuousClock.Instant
        let completion: (UInt64?) -> Void
    }
    private var pendingFullRepaints: [UInt64: PendingFullRepaint] = [:]
    private var resizeCount = 0
    private var sendCount = 0
    private let inputQueueDiagnostics: AsyncDeliveryDiagnostics
    private let nativeInputDiagnostics: AsyncDeliveryDiagnostics

    private let outputDeliverySequence: MoshOutputDeliverySequence

    private let onOutput: ([UInt8], UInt64, UInt64?, ((UInt64?) -> Void)?) -> Void
    private let onConnected: () -> Void
    private let onDisconnected: () -> Void
    private let onFailed: (String) -> Void
    private let onTransportReachabilityChanged: (Bool) -> Void
    private let onOutageChanged: (MoshOutageTiming?) -> Void

    init(
        host: String,
        diagnosticHostID: UUID,
        udpPort: Int,
        base64Key: String,
        outputDeliverySequence: MoshOutputDeliverySequence = MoshOutputDeliverySequence(),
        onOutput: @escaping ([UInt8], UInt64, UInt64?, ((UInt64?) -> Void)?) -> Void,
        onConnected: @escaping () -> Void,
        onDisconnected: @escaping () -> Void,
        onFailed: @escaping (String) -> Void,
        onTransportReachabilityChanged: @escaping (Bool) -> Void,
        onOutageChanged: @escaping (MoshOutageTiming?) -> Void = { _ in }
    ) {
        self.host = host
        diagnosticHost = String(diagnosticHostID.uuidString.prefix(8))
        self.udpPort = udpPort
        self.base64Key = base64Key
        self.outputDeliverySequence = outputDeliverySequence
        inputQueueDiagnostics = SessionLatencyDiagnostics.queue(
            host: diagnosticHostID,
            stage: "mosh-native-input-queue"
        )
        nativeInputDiagnostics = SessionLatencyDiagnostics.queue(
            host: diagnosticHostID,
            stage: "mosh-native-inject-tick"
        )
        self.onOutput = onOutput
        self.onConnected = onConnected
        self.onDisconnected = onDisconnected
        self.onFailed = onFailed
        self.onTransportReachabilityChanged = onTransportReachabilityChanged
        self.onOutageChanged = onOutageChanged
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
                        userInfo: [NSLocalizedDescriptionKey: String(localized: "Mosh session key is unavailable.")]
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

    func send(_ bytes: [UInt8], correlation: String? = nil) {
        guard !bytes.isEmpty else { return }
        let admitted = DispatchTime.now().uptimeNanoseconds
        inputQueueDiagnostics.enqueued(nanos: admitted)
        queue.async {
            let dequeued = DispatchTime.now().uptimeNanoseconds
            self.inputQueueDiagnostics.consumed(nanos: dequeued)
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
                let nativeStarted = DispatchTime.now().uptimeNanoseconds
                self.nativeInputDiagnostics.enqueued(nanos: nativeStarted)
                defer { self.nativeInputDiagnostics.consumed() }
                try bridge.injectBytes(Data(normalizedBytes))
                let injected = DispatchTime.now().uptimeNanoseconds
                self.tickLocked()
                if let correlation {
                    let completed = DispatchTime.now().uptimeNanoseconds
                    MoshDiagnostics.log(
                        "latency-input-v3 host=\(self.diagnosticHost) transport=mosh stage=native-complete corr=\(correlation) inputQueueMs=\(Double(dequeued - admitted) / 1e6) injectMs=\(Double(injected - nativeStarted) / 1e6) tickMs=\(Double(completed - injected) / 1e6)"
                    )
                }
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

    func forceFullRepaint(
        requestID: UInt64,
        requiringFreshRemoteState: Bool = false,
        completion: @escaping (UInt64?) -> Void
    ) {
        queue.async {
            guard !self.finished, let bridge = self.bridge else {
                completion(nil)
                return
            }
            do {
                guard self.pendingFullRepaints[requestID] == nil else {
                    completion(nil)
                    return
                }
                let token = requiringFreshRemoteState ? try bridge.beginFullRepaintFence() : nil
                if token == 0 {
                    MoshDiagnostics.log("driver force-full-repaint fence unavailable request=\(requestID)")
                    completion(nil)
                    return
                }
                self.pendingFullRepaints[requestID] = PendingFullRepaint(
                    bridge: bridge,
                    fenceToken: token,
                    deadline: .now.advanced(by: .seconds(2)),
                    completion: completion
                )
                if token != nil {
                    // Send the new fence and arm the normal pump before any
                    // replay collector exists. Its output remains natural.
                    self.tickLocked()
                }
                self.continueFullRepaintLocked(requestID: requestID)
            } catch {
                completion(nil)
                self.failLocked(error)
            }
        }
    }

    func cancelFullRepaint(requestID: UInt64) {
        queue.async {
            self.pendingFullRepaints.removeValue(forKey: requestID)?.completion(nil)
        }
    }

    private func continueFullRepaintLocked(requestID: UInt64) {
        guard let request = pendingFullRepaints[requestID] else { return }
        guard !finished, bridge === request.bridge else {
            pendingFullRepaints.removeValue(forKey: requestID)?.completion(nil)
            return
        }
        if let token = request.fenceToken {
            guard ContinuousClock.now < request.deadline else {
                MoshDiagnostics.log("driver force-full-repaint fence timed out request=\(requestID)")
                pendingFullRepaints.removeValue(forKey: requestID)?.completion(nil)
                return
            }
            guard request.bridge.isFullRepaintFenceReady(token: token) else {
                queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
                    self?.continueFullRepaintLocked(requestID: requestID)
                }
                return
            }
        }
        pendingFullRepaints.removeValue(forKey: requestID)
        MoshDiagnostics.log("driver force-full-repaint request=\(requestID)")
        forceFullRepaintOutput = []
        do {
            try request.bridge.forceFullRepaint()
            // Never receive/tick under this collector: a real remote update
            // must retain its natural delivery rather than a replay receipt.
            let bytes = forceFullRepaintOutput ?? []
            forceFullRepaintOutput = nil
            guard !bytes.isEmpty else {
                MoshDiagnostics.log("driver force-full-repaint emitted no output")
                request.completion(nil)
                return
            }
            emitOutput(bytes, repaintRequestID: requestID, delivered: request.completion)
        } catch {
            forceFullRepaintOutput = nil
            request.completion(nil)
            failLocked(error)
        }
    }

    private func cancelPendingFullRepaintsLocked() {
        let pending = Array(pendingFullRepaints.values)
        pendingFullRepaints.removeAll()
        for request in pending { request.completion(nil) }
    }

    /// A synchronous producer-side cut used only from the main actor while
    /// rebinding a render surface. Output callbacks already running or queued
    /// on this driver allocate their receipt before this returns.
    func outputDeliveryBarrier() -> UInt64 {
        queue.sync { outputDeliverySequence.highWater }
    }

    func disconnect() {
        queue.async {
            guard !self.finished else { return }
            MoshDiagnostics.log(
                "driver disconnect requested outputChunks=\(self.outputChunkCount) outputBytes=\(self.outputByteCount)"
            )
            self.finished = true
            self.base64Key = nil
            self.cancelPendingFullRepaintsLocked()
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
        repaintRequestID: UInt64? = nil,
        delivered: ((UInt64?) -> Void)? = nil
    ) {
        guard !bytes.isEmpty else { return }
        guard let deliveryID = outputDeliverySequence.allocate() else {
            delivered?(nil)
            failLocked(NSError(
                domain: "com.bambouville.Tessera.MoshTransport",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Mosh output delivery sequence exhausted."]
            ))
            return
        }
        outputChunkCount += 1
        outputByteCount += bytes.count
        let chunkIndex = outputChunkCount
        if chunkIndex <= 12 || chunkIndex == 25 || chunkIndex == 50 {
            MoshDiagnostics.log(
                "driver output chunk#\(chunkIndex) bytes=\(bytes.count) totalBytes=\(outputByteCount)"
            )
        }
        onOutput(bytes, deliveryID, repaintRequestID, delivered)
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

        guard milliseconds != UInt.max || outageTiming != nil else { return }

        let clamped = min(milliseconds, outageTiming == nil ? UInt(Int.max) : 1000)
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
        let timing = MoshOutageTiming.next(
            previous: outageTiming,
            connected: bridge.isConnected,
            reachable: reachable,
            serverContactAgeMilliseconds: bridge.serverContactAgeMilliseconds,
            replyAgeMilliseconds: bridge.replyAgeMilliseconds,
            now: ProcessInfo.processInfo.systemUptime
        )
        if timing != outageTiming {
            outageTiming = timing
            onOutageChanged(timing)
        }
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
        cancelPendingFullRepaintsLocked()
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
        cancelPendingFullRepaintsLocked()
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
/// When a mosh session's tmux side channel should be running.
///
/// Pulled out of `MoshSessionView` so it can be tested: the view's own copy
/// was a `private var` on a SwiftUI `View`, which is why the 2026-09-11
/// regression — the channel dropping whenever the user looked at another tab —
/// had nothing guarding it.
///
/// The rule is deliberately NOT "while the user is watching". For mosh this is
/// the session's only control connection: tmux window/pane metadata,
/// capture-pane scrollback synthesis, and the host's port forwarding all ride
/// it. Both siblings already agree — SSH+tmux carries `-CC` on its primary
/// connection and keeps it through a switch, and Android cancels its side
/// channel only when the transport itself goes.
///
/// Nor is it "while an agent is being observed". V1 gated the channel on
/// `shouldMaintainObservation(sessionID:)` — surface demand, a bootstrap latch,
/// or a known agent in that session — and it was tempting to restore that latch
/// in V2 and let it own this lifetime again. It must not: none of the three
/// things riding this channel are agent features, so agent demand is the wrong
/// authority for them. The cost of the broader rule is one idle SSH connection
/// per connected mosh+tmux session, which is the price of the session having a
/// control connection at all. Agent Center pays for what it uses by rate, not
/// by dropping the carrier — see `AgentCenterV2DiscoveryPolicy`.
enum MoshSideChannelLifetime {
    static func shouldMaintain(
        launchMode: HostLaunchMode,
        isConnected: Bool
    ) -> Bool {
        switch launchMode {
        case .customCommand:
            // Plain mosh has no tmux to control.
            return false
        case .autoTmux, .pinnedTmux:
            return isConnected
        }
    }
}

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

    private struct InputChunk: Sendable {
        let bytes: [UInt8]
        let admittedNanos: UInt64
        let sequence: Int?
        let correlation: String?
    }

    let outputStream: AsyncStream<[UInt8]>
    private let outputContinuation: AsyncStream<[UInt8]>.Continuation
    nonisolated let outputQueueDiagnostics: AsyncDeliveryDiagnostics

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
    private let inputStream: AsyncStream<InputChunk>
    private let inputContinuation: AsyncStream<InputChunk>.Continuation
    private let controlStream: AsyncStream<ControlMessage>
    private let controlContinuation: AsyncStream<ControlMessage>.Continuation
    nonisolated private let diagnosticHost: String
    nonisolated private let inputQueueDiagnostics: AsyncDeliveryDiagnostics
    nonisolated private let inputWriteDiagnostics: AsyncDeliveryDiagnostics
    nonisolated private let nioEventLoopDiagnostics: AsyncDeliveryDiagnostics
    private var nextWriteDiagnostic: (sequence: Int, correlation: String?)?
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
    private let portForwardRules: [PortForwarding.PortForwardRule]

    init(
        host: Host,
        requireBiometric: Bool = false,
        isSecureEnclave: Bool = false,
        sessionName: String,
        initialSize: (cols: Int, rows: Int)?,
        preserveTmuxGeometry: Bool = false,
        preservedServerSize: (cols: Int, rows: Int)? = nil,
        portForwarderManager: PortForwarderManager? = nil,
        portForwardRules: [PortForwarding.PortForwardRule] = []
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
        diagnosticHost = String(host.id.uuidString.prefix(8))
        outputQueueDiagnostics = SessionLatencyDiagnostics.queue(
            host: host.id,
            stage: "mosh-sidechannel-read-to-main"
        )
        inputQueueDiagnostics = SessionLatencyDiagnostics.queue(
            host: host.id,
            stage: "mosh-sidechannel-input-queue"
        )
        inputWriteDiagnostics = SessionLatencyDiagnostics.queue(
            host: host.id,
            stage: "mosh-sidechannel-write-and-flush"
        )
        nioEventLoopDiagnostics = SessionLatencyDiagnostics.queue(
            host: host.id,
            stage: "mosh-sidechannel-nio-event-loop"
        )
        (outputStream, outputContinuation) = AsyncStream.makeStream(of: [UInt8].self)
        (inputStream, inputContinuation) = AsyncStream.makeStream(of: InputChunk.self)
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
        sendAdmitting(bytes)
    }

    /// Admit bytes to this control channel's ordered SSH input queue. A
    /// terminated channel cannot publish a new compact client size.
    @discardableResult
    func sendAdmitting(_ bytes: [UInt8]) -> Bool {
        let diagnostic = nextWriteDiagnostic
        nextWriteDiagnostic = nil
        guard !bytes.isEmpty else { return false }
        let admitted = DispatchTime.now().uptimeNanoseconds
        let chunk = InputChunk(
            bytes: bytes,
            admittedNanos: admitted,
            sequence: diagnostic?.sequence,
            correlation: diagnostic?.correlation
        )
        inputQueueDiagnostics.enqueued(nanos: admitted)
        switch inputContinuation.yield(chunk) {
        case .enqueued: return true
        case .dropped, .terminated:
            inputQueueDiagnostics.discarded(count: 1)
            return false
        @unknown default:
            inputQueueDiagnostics.discarded(count: 1)
            return false
        }
    }

    func noteCommandWriteDiagnostic(sequence: Int, correlation: String?) {
        nextWriteDiagnostic = (sequence, correlation)
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
        _ = inputContinuation.yield(InputChunk(
            bytes: [],
            admittedNanos: DispatchTime.now().uptimeNanoseconds,
            sequence: nil,
            correlation: nil
        ))
        inputContinuation.finish()
        controlContinuation.finish()
        outputContinuation.finish()
        discardPendingDiagnostics()
    }

    func detectForegroundProcessNames(rootPID: Int) async -> [String] {
        await detectForegroundProcessNamesIfAvailable(rootPID: rootPID) ?? []
    }

    func detectForegroundProcessNamesIfAvailable(rootPID: Int) async -> [String]? {
        await detectForegroundProcessSnapshotIfAvailable(rootPID: rootPID)?.processNames
    }

    func detectForegroundProcessSnapshotIfAvailable(
        rootPID: Int, expectedPID: Int? = nil
    ) async -> SwipePadPlainSSHProcessProbe.Snapshot? {
        guard client != nil else {
            SwipePadDiagnostics.log(
                "mosh tmux-pane-ps skipped reason=no-client rootPID=\(rootPID)"
            )
            return nil
        }

        do {
            let command = SwipePadPlainSSHProcessProbe.makeCommand(rootPID: rootPID, expectedPID: expectedPID)
            SwipePadDiagnostics.log(
                "mosh tmux-pane-ps begin rootPID=\(rootPID)"
            )
            let text = try await executeAgentIntegrationProbeCommand(command)
            let snapshot = SwipePadPlainSSHProcessProbe.snapshot(from: text)
            SwipePadDiagnostics.log(
                "mosh tmux-pane-ps result rootPID=\(rootPID) candidateCount=\(snapshot.processNames.count) bytes=\(text.utf8.count)"
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
                userInfo: [NSLocalizedDescriptionKey: String(localized: "The tmux control channel is not connected.")]
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

    func executeAgentInstallationCommand(_ command: String) async throws -> String {
        guard let client else { throw AppleAgentPlatformError.staleBinding }
        return try await AppleAgentInstallationExec.run(client: client, command: command)
    }

    func executeAgentIntegrationProbeCommand(_ command: String) async throws -> String {
        guard terminationReason == nil, let client else { throw AppleAgentPlatformError.staleBinding }
        let output = try await AppleAgentBoundedCommandExec.run(client: client, command: command)
        guard terminationReason == nil, self.client === client else { throw AppleAgentPlatformError.staleBinding }
        return output
    }

    /// Uses the already-authenticated mosh tmux control SSH client for a
    /// separate projector exec child. It is intentionally not implemented in
    /// terms of `executeConnectedCommand`, which buffers/merges output.
    func agentProjectorExecAvailability(
        binding: AgentTerminalBinding,
        isBindingCurrent: @escaping @MainActor @Sendable (AgentTerminalBinding) -> Bool
    ) -> AppleAgentExecAvailability {
        guard binding.transport == .moshTmux,
              terminationReason == nil,
              let client
        else { return .unavailable(.sideChannelUnavailable) }

        return .available(AppleAgentStreamingExecFactory { [weak self, client] request in
            guard request.binding == binding else {
                throw AppleAgentPlatformError.staleBinding
            }
            let stillCurrent = await MainActor.run { [weak self] in
                guard let self,
                      self.terminationReason == nil,
                      self.client === client,
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

    /// The control channel joins Tessera's *view* session, the same one the
    /// visible mosh client attaches to. Window selection is session-scoped: a
    /// control client sitting in the user's session would move its own current
    /// window and leave the visible client behind.
    static func attachCommand(
        sessionName: String,
        preserveTmuxGeometry: Bool = false
    ) -> String {
        AutoTmuxCommands.moshControlChannelCommand(
            sessionTarget: sessionName,
            preserveInitialGeometry: preserveTmuxGeometry
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
                let readDiagnostics = DiagnosticLogStore.isVerboseEnabled
                    ? TTYOutputDiagnostics()
                    : nil
                do {
                    MoshDiagnostics.log(
                        "tmux sidechannel attach attempt=\(attempt)/\(Self.attachRetryLimit) sessionNameLength=\(sessionName.count)"
                    )
                    try await connectedClient.withPTY(
                        Self.ptyRequest(size: lastKnownSize),
                        outputDiagnostics: readDiagnostics
                    ) {
                        (ttyOutput: TTYOutput, stdinWriter: TTYStdinWriter) in
                        try await Self.writeCommand(command, to: stdinWriter)
                        try await self.runControlLoops(
                            ttyOutput: ttyOutput,
                            stdinWriter: stdinWriter,
                            attempt: attempt,
                            stats: stats,
                            readDiagnostics: readDiagnostics
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
        inputContinuation.finish()
        controlContinuation.finish()
        discardPendingInputDiagnostics()
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
        let line = Self.commandLine(command)
        var buffer = ByteBufferAllocator().buffer(capacity: line.utf8.count)
        buffer.writeBytes(line.utf8)
        try await stdinWriter.write(buffer)
    }

    /// The attach command contains POSIX compound syntax (PATH fallback).
    /// `exec if ...` is invalid even in a POSIX shell, and the interactive
    /// login shell may use another dialect entirely, such as fish.
    nonisolated static func commandLine(_ command: String) -> String {
        "exec /bin/sh -c \(MoshBootstrapGrammar.singleQuotedShellString(command))\n"
    }

    private nonisolated func runControlLoops(
        ttyOutput: TTYOutput,
        stdinWriter: TTYStdinWriter,
        attempt: Int,
        stats: TmuxControlChannelAttemptStats,
        readDiagnostics: TTYOutputDiagnostics?
    ) async throws {
        let inputStream = self.inputStream
        let controlStream = self.controlStream

        try await withThrowingTaskGroup(of: Void.self) { group in
            if let readDiagnostics {
                let diagnosticHost = self.diagnosticHost
                let eventLoopDiagnostics = self.nioEventLoopDiagnostics
                group.addTask {
                    defer {
                        let pending = eventLoopDiagnostics.snapshot(resetWindow: false).pending
                        eventLoopDiagnostics.discarded(count: Int(clamping: pending))
                    }
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(5))
                        let snapshot = readDiagnostics.snapshot()
                        DiagnosticLogStore.appendSSH(
                            "latency-v3 host=\(diagnosticHost) stage=mosh-sidechannel-nio-to-reader attempt=\(attempt) pending=\(snapshot.pendingChunks) pendingBytes=\(snapshot.pendingBytes) peak=\(snapshot.maximumPendingChunks) oldestMs=\(snapshot.oldestPendingMs.map { String(Int($0)) } ?? "unknown") received=\(snapshot.receivedChunks) consumed=\(snapshot.consumedChunks) maxWaitMs=\(Int(snapshot.maximumReadWaitMs)) clipped=\(snapshot.clippedSamples)"
                        )
                        eventLoopDiagnostics.enqueued()
                        stdinWriter.whenEventLoopAvailable {
                            eventLoopDiagnostics.consumed()
                        }
                    }
                }
            }
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
                        self.outputQueueDiagnostics.enqueued()
                        if !(await self.yieldOutput(bytes)) {
                            self.outputQueueDiagnostics.discarded(count: 1)
                        }

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
                for await chunk in inputStream {
                    self.inputQueueDiagnostics.consumed()
                    let bytes = chunk.bytes
                    if bytes.isEmpty { continue }
                    inputChunkCount += 1
                    if inputChunkCount <= 4 {
                        MoshDiagnostics.log(
                            "tmux sidechannel stdin attempt=\(attempt) chunk#\(inputChunkCount) bytes=\(bytes.count)"
                        )
                    }
                    var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
                    buffer.writeBytes(bytes)
                    let writeStarted = DispatchTime.now().uptimeNanoseconds
                    self.inputWriteDiagnostics.enqueued(nanos: writeStarted)
                    do {
                        try await stdinWriter.write(buffer)
                        let completed = DispatchTime.now().uptimeNanoseconds
                        self.inputWriteDiagnostics.consumed(nanos: completed)
                        if let sequence = chunk.sequence {
                            DiagnosticLogStore.appendSSH(
                                "latency-input-v3 host=\(self.diagnosticHost) transport=mosh-tmux stage=write-complete tmuxSequence=\(sequence) corr=\(chunk.correlation ?? "none") inputQueueMs=\(Double(writeStarted - chunk.admittedNanos) / 1e6) flushMs=\(Double(completed - writeStarted) / 1e6)"
                            )
                        }
                    } catch {
                        self.inputWriteDiagnostics.consumed()
                        throw error
                    }
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

    private func yieldOutput(_ bytes: [UInt8]) -> Bool {
        switch outputContinuation.yield(bytes) {
        case .enqueued: return true
        case .dropped, .terminated: return false
        @unknown default: return false
        }
    }

    private func discardPendingInputDiagnostics() {
        let inputPending = inputQueueDiagnostics.snapshot(resetWindow: false).pending
        inputQueueDiagnostics.discarded(count: Int(clamping: inputPending))
        let writePending = inputWriteDiagnostics.snapshot(resetWindow: false).pending
        inputWriteDiagnostics.discarded(count: Int(clamping: writePending))
        let eventLoopPending = nioEventLoopDiagnostics.snapshot(resetWindow: false).pending
        nioEventLoopDiagnostics.discarded(count: Int(clamping: eventLoopPending))
    }

    private func discardPendingDiagnostics() {
        discardPendingInputDiagnostics()
        let outputPending = outputQueueDiagnostics.snapshot(resetWindow: false).pending
        outputQueueDiagnostics.discarded(count: Int(clamping: outputPending))
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
