import Combine
import Foundation
import Observation
import TesseraCore
import TmuxControl

/// Apple-only presentation mapping for the portable lifecycle projection.
/// Policy and lifecycle decisions consume `SharedSessionState`; legacy views
/// receive this value only to preserve their existing labels and colors.
func legacySessionState(from state: SharedSessionState) -> SessionState {
    switch state {
    case .idle: return .idle
    case .connecting: return .connecting
    case .connected: return .connected
    case .disconnected: return .disconnected
    case .failed(let failure): return .failed(failure.code)
    }
}

/// The only boundary allowed to observe Apple transport objects directly.
/// Concrete SSH and mosh publishers are erased here before entering the
/// portable `SessionEngine`, and tests can supply the same contract without
/// teaching the coordinator about a third transport type.
@MainActor
protocol AppleSessionBackendEventSource: TerminalSession {
    var appleSessionStateEvents: AnyPublisher<SessionState, Never> { get }
    var appleWorkingDirectoryEvents: AnyPublisher<String?, Never> { get }
    var appleHostKeyChallengeEvents: AnyPublisher<HostKeyVerificationRequest?, Never> { get }
    var appleAttemptOutputEvents: AsyncStream<SessionAttemptOutputChunk> { get }
    var appleOutputQueueDiagnostics: AsyncDeliveryDiagnostics? { get }
    var appleActiveSessionAttemptID: UUID? { get }
    func prepareAppleSessionAttempt(_ attemptID: UUID)
}

extension AppleSessionBackendEventSource {
    var appleOutputQueueDiagnostics: AsyncDeliveryDiagnostics? { nil }
}

extension SSHSession: AppleSessionBackendEventSource {
    var appleSessionStateEvents: AnyPublisher<SessionState, Never> {
        $state.eraseToAnyPublisher()
    }
    var appleWorkingDirectoryEvents: AnyPublisher<String?, Never> {
        $remoteWorkingDirectory.eraseToAnyPublisher()
    }
    var appleHostKeyChallengeEvents: AnyPublisher<HostKeyVerificationRequest?, Never> {
        $pendingHostKeyVerification.eraseToAnyPublisher()
    }
}

extension MoshSession: AppleSessionBackendEventSource {
    var appleSessionStateEvents: AnyPublisher<SessionState, Never> {
        $state.eraseToAnyPublisher()
    }
    var appleWorkingDirectoryEvents: AnyPublisher<String?, Never> {
        $remoteWorkingDirectory.eraseToAnyPublisher()
    }
    var appleHostKeyChallengeEvents: AnyPublisher<HostKeyVerificationRequest?, Never> {
        $pendingHostKeyVerification.eraseToAnyPublisher()
    }
}

/// Apple presentation boundary for the portable session state machine. Every
/// command enters one retained `SessionEngine`; Apple transports and tmux are
/// backend ports, and all presentation state is projected from engine events.
@MainActor
struct AppleSessionCommandFacade {
    enum DispatchResult: Equatable {
        case handled
        case rejectedHost
        case unsupported
        /// The grid-authority gate refused it (S5′).
        case refused(SessionCommandAuthorityRefusal)
    }

    /// What became of acknowledged typing (`sendInputAcknowledged`).
    enum InputDelivery: Equatable {
        case sent
        /// The S5′ gate refused it, at dispatch or when it was applied.
        case refused
        /// The engine or the backend dropped it: no session, no connection,
        /// no active pane in tmux control mode, or tmux failed it.
        case dropped
    }

    private let coordinator: AppleSessionCoordinator
    /// The concrete controller that originated commands from this facade.
    /// The retained coordinator can outlive and be rebound by SwiftUI views;
    /// each queued command must nevertheless execute against its source.
    private let commandTmux: TmuxController?

    var hostID: UUID { coordinator.hostID }
    var generation: SessionGeneration { coordinator.generation }

    init(
        session: any TerminalSession,
        generation: SessionGeneration = SessionGeneration(rawValue: 1),
        tmux: TmuxController? = nil,
        challengeResponder: (@MainActor (ChallengeResponse) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        commandTmux = tmux
        coordinator = AppleSessionCoordinatorRegistry.shared.coordinator(
            for: session,
            generation: generation,
            now: now
        )
        coordinator.configure(tmux: tmux, challengeResponder: challengeResponder)
    }

    func connect() { coordinator.connectIfNeeded() }
    func disconnect() { _ = dispatch(.disconnect) }
    func sendInput(_ bytes: [UInt8]) { _ = dispatch(.sendInput(Data(bytes))) }

    /// Typing whose sender must learn its fate (an uploaded path). It is
    /// `sendInput` in every other respect: gated as typing at dispatch and
    /// again when applied, routed like a key and queued in order with keys,
    /// since it is enqueued before this returns. `completion` runs once, on
    /// the main actor: at once when dispatch refuses it, otherwise when the
    /// backend applies or drops it (under inline tmux, on tmux's reply).
    func sendInputAcknowledged(
        _ bytes: [UInt8],
        completion: @escaping @MainActor (InputDelivery) -> Void
    ) {
        let command = SessionCommand.sendInput(Data(bytes))
        guard !bytes.isEmpty, coordinator.supports(command, tmux: commandTmux) else {
            completion(.dropped)
            return
        }
        if let refusal = coordinator.authorityRefusal(command.authorityGate, tmux: commandTmux) {
            coordinator.noteAuthorityRefusal(command.authorityGate, refusal, stage: "dispatch")
            completion(.refused)
            return
        }
        coordinator.enqueue(command, tmux: commandTmux, delivery: completion)
    }
    func resize(columns: Int, rows: Int) {
        _ = dispatch(.resize(columns: columns, rows: rows))
    }

    func sendTmuxPaneInputAcknowledged(_ bytes: [UInt8], paneID: PaneId) async -> Bool {
        guard !bytes.isEmpty else { return false }
        return await coordinator.enqueueAcknowledged(tmux: commandTmux) { receipt in
            .sendTmuxPaneInput(
                data: Data(bytes),
                paneID: paneID.description,
                receipt: receipt
            )
        }
    }

    func sendTmuxPaneKeyAcknowledged(_ key: SessionTmuxPaneKey, paneID: PaneId) async -> Bool {
        await coordinator.enqueueAcknowledged(tmux: commandTmux) { receipt in
            .sendTmuxPaneKey(key, paneID: paneID.description, receipt: receipt)
        }
    }

    @discardableResult
    func respondToHostKeyChallenge(
        _ challengeID: UUID,
        decision: ChallengeDecision
    ) -> Bool {
        coordinator.respondToHostKeyChallenge(challengeID, decision: decision)
    }

    @discardableResult
    func dispatch(_ command: SessionCommand) -> DispatchResult {
        if case .connect(let intent) = command, intent.hostID != hostID {
            return .rejectedHost
        }
        guard coordinator.supports(command, tmux: commandTmux) else { return .unsupported }
        // S5′: every key, paste, path, mouse report, mosh byte and window or
        // pane mutation passes this one O(1) read; the backend rechecks it
        // when the command is applied.
        if let refusal = coordinator.authorityRefusal(command.authorityGate, tmux: commandTmux) {
            coordinator.noteAuthorityRefusal(command.authorityGate, refusal, stage: "dispatch")
            return .refused(refusal)
        }
        coordinator.enqueue(command, tmux: commandTmux)
        return .handled
    }

    /// The S5′ gate's verdict on `command` now, without sending it.
    func authorityRefusal(for command: SessionCommand) -> SessionCommandAuthorityRefusal? {
        coordinator.authorityRefusal(command.authorityGate, tmux: commandTmux)
    }

    var events: AsyncStream<SessionEvent> { coordinator.events() }
    func events(diagnostics: AsyncDeliveryDiagnostics) -> AsyncStream<SessionEvent> {
        coordinator.events(diagnostics: diagnostics)
    }
    var state: SharedSessionState { coordinator.state }
    var statePublisher: AnyPublisher<SharedSessionState, Never> {
        coordinator.statePublisher
    }
    var challengeRequests: AnyPublisher<HostKeyVerificationRequest?, Never> {
        coordinator.challengeRequests
    }
    var workingDirectory: String? { coordinator.workingDirectory }
    var workingDirectoryPublisher: AnyPublisher<String?, Never> {
        coordinator.workingDirectoryPublisher
    }

#if DEBUG
    /// Deterministic lifecycle race seam: preserves the transport attempt that
    /// originated a queued state transition even if a newer attempt is active
    /// by the time SessionEngine processes it.
    func _ingestTransportStateForTesting(
        _ state: SessionState,
        originatingIntent: ConnectionIntent
    ) {
        coordinator.submitLegacyState(state, expectedIntent: originatingIntent)
    }

    /// Deterministic race seam: models a backend chunk already observed by
    /// the adapter while the command queue is still draining older lifecycle
    /// transitions. Production output uses this exact enqueue path.
    func _ingestTransportBytesForTesting(
        _ bytes: Data,
        attemptID: UUID? = nil,
        receipt: TerminalOutputReceipt? = nil
    ) {
        coordinator.submitTransportBytes(bytes, attemptID: attemptID, receipt: receipt)
    }

    var _bulkBatchesForTesting: [(items: Int, bytes: Int)] { coordinator.bulkBatchesForTesting }

    var _challengeRenewalCountForTesting: Int { coordinator.challengeRenewalCountForTesting }

    /// Transport-ordered items (bytes/snapshots/lifecycle) still queued ahead
    /// of the engine. Ground truth for the bounded-input-latency tests: when a
    /// command's backend effect is observed while this is still large, the
    /// command provably overtook the observational backlog.
    var _orderedLaneCountForTesting: Int {
        coordinator._orderedLaneCountForTesting
    }
#endif
}

@MainActor
private final class AppleSessionCoordinatorRegistry {
    static let shared = AppleSessionCoordinatorRegistry()

    private struct Entry {
        weak var session: (any TerminalSession)?
        let coordinator: AppleSessionCoordinator
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// The clock applies only when creating the session object's retained coordinator.
    func coordinator(
        for session: any TerminalSession,
        generation: SessionGeneration,
        now: @escaping @Sendable () -> Date
    ) -> AppleSessionCoordinator {
        entries = entries.filter { $0.value.session != nil }
        let key = ObjectIdentifier(session)
        if let entry = entries[key], entry.session === session {
            return entry.coordinator
        }
        let coordinator = AppleSessionCoordinator(
            session: session,
            initialGeneration: generation,
            now: now
        )
        entries[key] = Entry(session: session, coordinator: coordinator)
        return coordinator
    }
}

/// Retained Apple adapter. The AsyncStreams are serialization points: one
/// preserves command/transport ordering into SessionEngine; another preserves
/// backend operation ordering back onto MainActor.
@MainActor
private final class AppleSessionCoordinator {
    private struct BackendEnvelope: @unchecked Sendable {
        let operation: SessionBackendOperation
        let receipt: UUID?
        let tmux: TmuxController?
    }

    private struct CommandTarget: @unchecked Sendable {
        let tmux: TmuxController?
    }

    /// SessionEngine invokes backend ports synchronously while processing one
    /// command at a time. This tiny locked handoff binds that operation to the
    /// UI command receipt without teaching the portable engine about Apple
    /// object lifetime.
    private final class BackendReceiptBox: @unchecked Sendable {
        private struct Context {
            let receipt: UUID
            let tmux: TmuxController?
        }

        private let lock = NSLock()
        private var current: Context?

        func begin(_ receipt: UUID, tmux: TmuxController?) {
            lock.lock()
            precondition(current == nil)
            current = Context(receipt: receipt, tmux: tmux)
            lock.unlock()
        }

        func take() -> (receipt: UUID, tmux: TmuxController?)? {
            lock.lock()
            defer { lock.unlock() }
            let value = current
            current = nil
            return value.map { ($0.receipt, $0.tmux) }
        }

        func clearIfCurrent(_ receipt: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard current?.receipt == receipt else { return false }
            current = nil
            return true
        }
    }

    private enum LegacyState: Sendable {
        case idle
        case connecting
        case connected
        case disconnected
        case failed(CoreFailure)
    }

    private enum EngineInput: Sendable {
        case command(SessionCommand, receipt: UUID, target: CommandTarget)
        case state(LegacyState, intent: ConnectionIntent?)
        case bytes(Data, attemptID: UUID, receipt: TerminalOutputReceipt?)
        case tmux(TmuxSnapshot)
        case challenge(SessionChallenge)
        case workingDirectory(String?)
        case commandCompleted(SessionCommandReceipt, SessionCommandResult)
    }

    /// Amortized O(1) FIFO. `Array.removeFirst()` is O(n); a flood of queued
    /// output chunks would otherwise turn draining into O(n²).
    private struct EngineInputFIFO<Element> {
        private var storage: [Element] = []
        private var head = 0
        var isEmpty: Bool { head >= storage.count }
        var count: Int { storage.count - head }
        var first: Element? { head < storage.count ? storage[head] : nil }
        var last: Element? { head < storage.count ? storage.last : nil }
        mutating func append(_ element: Element) { storage.append(element) }
        mutating func replaceLast(with element: Element) {
            storage[storage.count - 1] = element
        }
        mutating func popFirst() -> Element? {
            guard head < storage.count else { return nil }
            let element = storage[head]
            head += 1
            if head > 64, head * 2 >= storage.count {
                storage.removeFirst(head)
                head = 0
            }
            return element
        }
    }

    private struct QueuedEngineInput {
        let seq: UInt64
        var input: EngineInput
        let admittedAt = ContinuousClock.now
    }

    private struct QueuedEngineCommand {
        /// Newest lifecycle admission this command must not overtake.
        let lifecycleBarrierSeq: UInt64
        let input: EngineInput
    }

    let hostID: UUID
    private weak var session: (any TerminalSession)?
    private weak var tmux: TmuxController?
    private var challengeResponder: (@MainActor (ChallengeResponse) -> Void)?
    private var pendingChallengeRequest: HostKeyVerificationRequest?
    private var pendingChallengeRegistration: ChallengeContext?
    private let now: @Sendable () -> Date
    // Allow for queue latency before the engine consumes the response.
    private static let challengeRenewalMargin: TimeInterval = 5
    private var activeIntent: ConnectionIntent?

    private let engine: SessionEngine
    private let receiptBox: BackendReceiptBox
    /// Engine admission is split into two lanes with one serialized consumer.
    ///
    /// - `commandLane`: latency-sensitive commands (typing, resize, tmux
    ///   actions) plus their backend completions. Never waits behind
    ///   observational traffic.
    /// - `orderedLane`: everything the transport reports — lifecycle/attempt
    ///   transitions, challenges, terminal bytes, tmux snapshots, working
    ///   directory — in strict arrival order relative to each other, so a
    ///   `.connected` still precedes its attempt's first bytes and tail bytes
    ///   still land before their attempt's `.disconnected`.
    ///
    /// A command may never overtake a lifecycle/attempt-boundary item that was
    /// admitted before it (input must not dispatch against a disconnected or
    /// superseded attempt, and a challenge response must not outrun its
    /// challenge registration). Each command therefore carries the admission
    /// seq of the newest lifecycle item it must stay behind; the consumer
    /// drains the ordered lane up to that barrier first. Bulk items admitted
    /// before a command but after its barrier are overtaken — that is the
    /// bounded-latency property: a backlog of output can no longer delay
    /// interactive input (docs/refactor/input-stall-after-shared-refactor-
    /// findings.md, repair property 1).
    private var commandLane = EngineInputFIFO<QueuedEngineCommand>()
    private var orderedLane = EngineInputFIFO<QueuedEngineInput>()
    private var outputQueueDiagnosticAfter = ContinuousClock.now
    private var maximumOrderedWaitMs = 0
    private var maximumOrderedDepth = 0
    private struct EngineRoundTripSample {
        var count = 0
        var items = 0
        var totalMs: Double = 0
        var maximumMs: Double = 0
    }
    private var engineRoundTripSamples: [String: EngineRoundTripSample] = [:]
    /// Admission seqs of lifecycle items currently in `orderedLane` (FIFO).
    private var queuedLifecycleSeqs: [UInt64] = []
    private var admissionSeq: UInt64 = 0
    private let orderedQueueDiagnostics: AsyncDeliveryDiagnostics
    private let commandQueueDiagnostics: AsyncDeliveryDiagnostics
    private let engineRoundTripDiagnostics: AsyncDeliveryDiagnostics
    private var lastLifecycleSeq: UInt64 = 0
    /// Admission instants of in-flight latency-sensitive input commands,
    /// keyed by command receipt, for stage-latency diagnostics.
    private var inputAdmissionInstants: [UUID: ContinuousClock.Instant] = [:]
    private var authorityRefusalCount = 0
    private let engineInputDoorbell: AsyncStream<Void>.Continuation
    private let backendContinuation: AsyncStream<BackendEnvelope>.Continuation
    private let engineEventContinuation: AsyncStream<SessionEvent>.Continuation
    private var inputTask: Task<Void, Never>?
    private var backendTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var stopped = false
    /// Commands remain synchronous at the SwiftUI boundary, but backend work
    /// crosses two serialized tasks. Holding the session through the matching
    /// backend receipt prevents close/retry from deallocating it after the tab
    /// is removed but before `disconnect()` is performed.
    private var commandSessionRetains: [UUID: any TerminalSession] = [:]
    private var commandResultContinuations: [
        SessionCommandReceipt: CheckedContinuation<Bool, Never>
    ] = [:]
    /// `sendInputAcknowledged` callbacks, by backend receipt.
    private var inputDeliveries: [UUID: @MainActor (AppleSessionCommandFacade.InputDelivery) -> Void] = [:]

    private struct Subscriber {
        let continuation: AsyncStream<SessionEvent>.Continuation
        let diagnostics: AsyncDeliveryDiagnostics?
        func yield(_ event: SessionEvent) {
            diagnostics?.enqueued()
            continuation.yield(event)
        }
        func finish() { continuation.finish() }
    }
    private var subscribers: [UUID: Subscriber] = [:]
    private var cachedState: SharedSessionState = .idle
    private var cachedGeneration: SessionGeneration
    private var cachedTmuxSnapshot: TmuxSnapshot?
    private var cachedAuthority: GridAuthoritySnapshot = .unknown
    private var cachedChallenge: SessionChallenge?
    private var cachedWorkingDirectory: String?
    private var hasCachedWorkingDirectory = false
    private var observedTmuxSnapshot: TmuxSnapshot?
    private let challengeSubject = CurrentValueSubject<HostKeyVerificationRequest?, Never>(nil)
    private let stateSubject = CurrentValueSubject<SharedSessionState, Never>(.idle)
    private let workingDirectorySubject = CurrentValueSubject<String?, Never>(nil)

    var generation: SessionGeneration { cachedGeneration }
    var state: SharedSessionState { cachedState }
    var workingDirectory: String? { cachedWorkingDirectory }
    var statePublisher: AnyPublisher<SharedSessionState, Never> {
        stateSubject.removeDuplicates().eraseToAnyPublisher()
    }
    var challengeRequests: AnyPublisher<HostKeyVerificationRequest?, Never> {
        challengeSubject.eraseToAnyPublisher()
    }
    var workingDirectoryPublisher: AnyPublisher<String?, Never> {
        workingDirectorySubject.removeDuplicates().eraseToAnyPublisher()
    }

    init(
        session: any TerminalSession,
        initialGeneration: SessionGeneration,
        now: @escaping @Sendable () -> Date
    ) {
        self.session = session
        self.now = now
        hostID = session.host.id
        orderedQueueDiagnostics = SessionLatencyDiagnostics.queue(host: session.host.id, stage: "facade-ordered-queue")
        commandQueueDiagnostics = SessionLatencyDiagnostics.queue(host: session.host.id, stage: "facade-command-queue")
        engineRoundTripDiagnostics = SessionLatencyDiagnostics.queue(host: session.host.id, stage: "facade-engine-round-trip")
        cachedGeneration = initialGeneration
        cachedWorkingDirectory = session.remoteWorkingDirectory
        hasCachedWorkingDirectory = cachedWorkingDirectory != nil
        workingDirectorySubject.send(cachedWorkingDirectory)

        switch session.state {
        case .idle:
            cachedState = .idle
        case .connecting:
            if let attemptID = (session as? any AppleSessionBackendEventSource)?
                .appleActiveSessionAttemptID {
                let intent = ConnectionIntent(
                    requestID: attemptID,
                    hostID: session.host.id,
                    policyGeneration: 0
                )
                activeIntent = intent
                cachedState = .connecting(attemptID: intent.requestID)
            } else {
                cachedState = .failed(Self.missingAttemptFailure(for: .connecting))
            }
        case .connected:
            if let attemptID = (session as? any AppleSessionBackendEventSource)?
                .appleActiveSessionAttemptID {
                activeIntent = ConnectionIntent(
                    requestID: attemptID,
                    hostID: session.host.id,
                    policyGeneration: 0
                )
                cachedState = .connected
            } else {
                cachedState = .failed(Self.missingAttemptFailure(for: .connected))
            }
        case .disconnected:
            cachedState = .disconnected
        case .failed:
            cachedState = .failed(CoreFailure(code: "transport_failed"))
        }
        stateSubject.send(cachedState)

        let doorbell = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        engineInputDoorbell = doorbell.continuation
        let backend = AsyncStream.makeStream(of: BackendEnvelope.self)
        backendContinuation = backend.continuation
        let engineEvents = AsyncStream.makeStream(of: SessionEvent.self)
        engineEventContinuation = engineEvents.continuation
        let backendDiagnostics = SessionLatencyDiagnostics.queue(host: session.host.id, stage: "engine-to-backend")
        let eventDiagnostics = SessionLatencyDiagnostics.queue(host: session.host.id, stage: "engine-to-publication")
        let receiptBox = BackendReceiptBox()
        self.receiptBox = receiptBox

        engine = SessionEngine(
            sessionID: session.host.id,
            initialGeneration: initialGeneration,
            backendPorts: SessionBackendPorts { operation in
                let context = receiptBox.take()
                backendDiagnostics.enqueued()
                backend.continuation.yield(BackendEnvelope(
                    operation: operation,
                    receipt: context?.receipt,
                    tmux: context?.tmux
                ))
            },
            now: now,
            eventSink: { event in
                eventDiagnostics.enqueued()
                engineEvents.continuation.yield(event)
            }
        )

        inputTask = Task { @MainActor [weak self] in
            for await _ in doorbell.stream {
                while true {
                    guard let self, !self.stopped else { return }
                    guard let item = self.dequeueNextEngineInput() else { break }
                    await self.processEngineInput(item)
                }
            }
        }
        backendTask = Task { @MainActor [weak self] in
            for await envelope in backend.stream.mainActorDelivery(diagnostics: backendDiagnostics) {
                guard let self, !self.stopped else { break }
                self.applyBackend(
                    envelope.operation,
                    tmux: envelope.tmux,
                    receipt: envelope.receipt
                )
                if let receipt = envelope.receipt {
                    self.commandSessionRetains[receipt] = nil
                    // Exactly once: an operation that did not report it dropped it.
                    self.finishInputDelivery(receipt, .dropped)
                }
            }
        }
        eventTask = Task { @MainActor [weak self] in
            for await event in engineEvents.stream.mainActorDelivery(diagnostics: eventDiagnostics) {
                guard let self, !self.stopped else { break }
                self.publish(event)
            }
        }

        observeSession()
    }

    deinit {
        engineInputDoorbell.finish()
        backendContinuation.finish()
        engineEventContinuation.finish()
        inputTask?.cancel()
        backendTask?.cancel()
        eventTask?.cancel()
        outputTask?.cancel()
    }

    // MARK: - Engine admission lanes

    private static func isLifecycle(_ input: EngineInput) -> Bool {
        switch input {
        case .state, .challenge: return true
        case .command, .bytes, .tmux, .workingDirectory, .commandCompleted:
            return false
        }
    }

    /// Admit a transport-reported item in strict arrival order. Adjacent tmux
    /// snapshots are coalescible observational state: only the newest matters,
    /// so it replaces a still-queued predecessor instead of queueing behind it.
    private func enqueueOrdered(_ input: EngineInput) {
        if case .tmux = input, let tail = orderedLane.last, case .tmux = tail.input {
            orderedLane.replaceLast(with: QueuedEngineInput(seq: tail.seq, input: input))
            engineInputDoorbell.yield()
            return
        }
        admissionSeq &+= 1
        if Self.isLifecycle(input) {
            lastLifecycleSeq = admissionSeq
            queuedLifecycleSeqs.append(admissionSeq)
        }
        orderedLane.append(QueuedEngineInput(seq: admissionSeq, input: input))
        orderedQueueDiagnostics.enqueued()
        engineInputDoorbell.yield()
    }

    /// Admit a latency-sensitive item bound behind the newest already-admitted
    /// lifecycle boundary.
    private func enqueueEngineCommand(_ input: EngineInput) {
        admissionSeq &+= 1
        commandLane.append(QueuedEngineCommand(
            lifecycleBarrierSeq: lastLifecycleSeq,
            input: input
        ))
        commandQueueDiagnostics.enqueued()
        engineInputDoorbell.yield()
    }

    private func dequeueNextEngineInput() -> EngineInput? {
        if let command = commandLane.first {
            if let lifecycleSeq = queuedLifecycleSeqs.first,
               lifecycleSeq <= command.lifecycleBarrierSeq {
                return popOrderedLane()
            }
            _ = commandLane.popFirst()
            commandQueueDiagnostics.consumed()
            return command.input
        }
        return popOrderedLane()
    }

    private func popOrderedLane() -> EngineInput? {
        guard let item = orderedLane.popFirst() else { return nil }
        orderedQueueDiagnostics.consumed()
        if DiagnosticLogStore.isVerboseEnabled {
            let now = ContinuousClock.now
            let waited = item.admittedAt.duration(to: now).components
            let milliseconds = Int(Double(waited.seconds) * 1_000 + Double(waited.attoseconds) / 1e15)
            maximumOrderedWaitMs = max(maximumOrderedWaitMs, milliseconds)
            maximumOrderedDepth = max(maximumOrderedDepth, orderedLane.count + 1)
            if now >= outputQueueDiagnosticAfter {
                let stages = engineRoundTripSamples.keys.sorted().map { kind in
                    let sample = engineRoundTripSamples[kind]!
                    return "\(kind){count=\(sample.count),items=\(sample.items),wallMs=\(Int(sample.totalMs)),maxMs=\(Int(sample.maximumMs))}"
                }.joined(separator: " ")
                DiagnosticLogStore.appendTerminalPerformance("session-output-queue host=\(hostID.uuidString.prefix(8)) maxWaitMs=\(maximumOrderedWaitMs) maxDepth=\(maximumOrderedDepth) currentDepth=\(orderedLane.count) commandDepth=\(commandLane.count) engineRoundTrips='\(stages)'")
                outputQueueDiagnosticAfter = now.advanced(by: .seconds(5))
                maximumOrderedWaitMs = 0
                maximumOrderedDepth = 0
                engineRoundTripSamples.removeAll(keepingCapacity: true)
            }
        }
        if Self.isLifecycle(item.input), queuedLifecycleSeqs.first == item.seq {
            queuedLifecycleSeqs.removeFirst()
        }
        return item.input
    }

    private func processEngineInput(_ item: EngineInput) async {
        engineRoundTripDiagnostics.enqueued()
        defer { engineRoundTripDiagnostics.consumed() }
        // Wall time deliberately includes executor waits. A cheap actor
        // operation can still drain slower than arrival under UI contention;
        // distinguish that from renderer feed CPU in the paired-device log.
        let roundTripStart = DiagnosticLogStore.isVerboseEnabled ? ContinuousClock.now : nil
        var roundTripItems = 1
        defer {
            if let roundTripStart, DiagnosticLogStore.isVerboseEnabled {
                let duration = roundTripStart.duration(to: ContinuousClock.now).components
                let milliseconds = Double(duration.seconds) * 1_000
                    + Double(duration.attoseconds) / 1e15
                var kind: String
                switch item {
                case .bytes: kind = "bytes"
                case .tmux: kind = "tmux"
                case .state: kind = "state"
                case .challenge: kind = "challenge"
                case .workingDirectory: kind = "directory"
                case .command: kind = "command"
                case .commandCompleted: kind = "completion"
                }
                if roundTripItems > 1 { kind = "bulk" }
                var sample = engineRoundTripSamples[kind, default: EngineRoundTripSample()]
                sample.count += 1
                sample.items += roundTripItems
                sample.totalMs += milliseconds
                sample.maximumMs = max(sample.maximumMs, milliseconds)
                engineRoundTripSamples[kind] = sample
            }
        }
        if case .command(let command, let receipt, let target) = item {
            noteInputStage("engine", receipt: receipt, clear: false)
            receiptBox.begin(receipt, tmux: target.tmux)
            do {
                try await engine.handle(command)
            } catch {
                if case .submitChallengeResponse = command {
                    DiagnosticLogStore.appendSSH("hostkey challenge response rejected reason=\(String(describing: error))")
                }
                _ = receiptBox.clearIfCurrent(receipt)
                commandSessionRetains[receipt] = nil
                inputAdmissionInstants[receipt] = nil
                if let completionReceipt = command.completionReceipt {
                    finishCommand(completionReceipt, succeeded: false)
                }
                finishInputDelivery(receipt, .dropped)
                await Self.publishAdapterRejection(error, from: engine)
            }
            // Every accepted command dispatches one backend operation.
            // If that invariant ever changes, release instead of
            // retaining an Apple session indefinitely.
            if receiptBox.clearIfCurrent(receipt) {
                commandSessionRetains[receipt] = nil
                finishInputDelivery(receipt, .dropped)
            }
        } else {
            let batch = takeOrderedBatch(startingWith: item)
            roundTripItems = batch.count
            await Self.apply(batch, to: engine)
        }
    }

    /// Amortize UI-to-engine scheduling without merging packets or receipts.
    /// Interactive commands still win as soon as their lifecycle barrier is
    /// satisfied. A batch stops before any lifecycle/challenge boundary and
    /// cannot monopolize the engine: at most 32 items / 64 KiB, except an
    /// already-admitted single oversized packet whose identity stays intact.
    private func takeOrderedBatch(startingWith first: EngineInput) -> [EngineInput] {
        guard var bytes = Self.bulkByteCount(first) else { return [first] }
        var batch = [first]
        #if DEBUG
        defer {
            if bulkBatchesForTesting.count < 128 {
                bulkBatchesForTesting.append((batch.count, bytes))
            }
        }
        #endif
        while batch.count < 32, bytes < 64 * 1_024 {
            if let command = commandLane.first {
                guard let barrier = queuedLifecycleSeqs.first,
                      barrier <= command.lifecycleBarrierSeq else { break }
            }
            guard let next = orderedLane.first,
                  let nextBytes = Self.bulkByteCount(next.input),
                  bytes + nextBytes <= 64 * 1_024,
                  let input = popOrderedLane() else { break }
            batch.append(input)
            bytes += nextBytes
        }
        return batch
    }

    private static func bulkByteCount(_ input: EngineInput) -> Int? {
        switch input {
        case .bytes(let bytes, _, _): return bytes.count
        case .tmux, .workingDirectory: return 0
        default: return nil
        }
    }

    private static func isLatencySensitiveInput(_ command: SessionCommand) -> Bool {
        switch command {
        case .sendInput, .sendTmuxPaneInput, .sendTmuxPaneKey: return true
        default: return false
        }
    }

    /// Stage-latency diagnostics for interactive input (findings repair
    /// property 4): one correlation id per keystroke with monotonic waits at
    /// facade admission, engine acceptance, and backend application. The tmux
    /// layer continues the same id through command transmit and response.
    private func noteInputAdmission(_ command: SessionCommand, receipt: UUID) {
        guard Self.isLatencySensitiveInput(command) else { return }
        inputAdmissionInstants[receipt] = ContinuousClock.now
        // The correlation token stays past the log store's 4-token rate-limit
        // signature so per-keystroke ids cannot mint unbounded signatures.
        DiagnosticLogStore.append(
            .app,
            "session-input admitted commandLane=\(commandLane.count) orderedLane=\(orderedLane.count) corr=\(Self.inputCorrelation(receipt))"
        )
    }

    /// No-op unless `receipt` was admitted as latency-sensitive input.
    private func noteInputStage(_ stage: String, receipt: UUID, clear: Bool) {
        guard let admittedAt = inputAdmissionInstants[receipt] else { return }
        if clear { inputAdmissionInstants[receipt] = nil }
        let waited = admittedAt.duration(to: ContinuousClock.now)
        let waitedMs = Int(Double(waited.components.seconds) * 1_000
            + Double(waited.components.attoseconds) / 1e15)
        DiagnosticLogStore.append(
            .app,
            "session-input \(stage) sinceAdmissionMs=\(waitedMs) lane=command corr=\(Self.inputCorrelation(receipt))"
        )
    }

    static func inputCorrelation(_ receipt: UUID) -> String {
        String(receipt.uuidString.prefix(8))
    }

#if DEBUG
    /// Test seam: transport-ordered items still queued ahead of the engine.
    var _orderedLaneCountForTesting: Int { orderedLane.count }
    private(set) var bulkBatchesForTesting: [(items: Int, bytes: Int)] = []
    private(set) var challengeRenewalCountForTesting = 0
#endif

    func configure(
        tmux: TmuxController?,
        challengeResponder: (@MainActor (ChallengeResponse) -> Void)?
    ) {
        if let tmux, self.tmux !== tmux {
            self.tmux = tmux
            observedTmuxSnapshot = nil
            submitTmuxIfChanged(tmux)
            armTmuxObservation(tmux)
        }
        if let challengeResponder { self.challengeResponder = challengeResponder }
    }

    func connectIfNeeded() {
        guard activeIntent == nil else { return }
        switch cachedState {
        case .connecting, .connected:
            return
        case .idle, .disconnected, .failed:
            enqueue(.connect(ConnectionIntent(hostID: hostID, policyGeneration: 0)))
        }
    }

    func supports(_ command: SessionCommand, tmux commandTmux: TmuxController? = nil) -> Bool {
        guard !stopped else { return false }
        let tmux = commandTmux ?? self.tmux
        switch command {
        case .selectTmuxWindow(let target), .closeTmuxWindow(let target):
            return tmux != nil && WindowId(wireValue: target) != nil
        case .selectTmuxPane(let target), .closeTmuxPane(let target):
            return tmux != nil && PaneId(wireValue: target) != nil
        case .sendTmuxPaneInput(_, let target, _),
             .sendTmuxPaneKey(_, let target, _),
             .splitTmuxPane(let target, _, _),
             .setTmuxPaneZoomed(let target, _):
            return tmux != nil && PaneId(wireValue: target) != nil
        case .renameTmuxWindow(let target, _), .moveTmuxWindow(let target, _):
            return tmux != nil && WindowId(wireValue: target) != nil
        case .renumberTmuxWindows, .createTmuxWindow, .cycleTmuxPane, .setTmuxGridPresentation,
             .claimTmuxGridAuthority, .reclaimTmuxGridAuthority,
             .completeTmuxGridAuthorityRepaint:
            return tmux != nil
        case .requestFullRepaint:
            return tmux != nil || session is MoshSession
        case .submitChallengeResponse(let response):
            return cachedChallenge?.context.challengeID == response.challengeID
                || challengeResponder != nil
        default:
            return true
        }
    }

    func enqueue(
        _ command: SessionCommand,
        tmux: TmuxController? = nil,
        delivery: (@MainActor (AppleSessionCommandFacade.InputDelivery) -> Void)? = nil
    ) {
        switch command {
        case .connect(let intent): activeIntent = intent
        case .disconnect, .destroy: activeIntent = nil
        case .cancelConnect(let attemptID):
            if activeIntent?.requestID == attemptID { activeIntent = nil }
        default: break
        }
        let receipt = UUID()
        if let session { commandSessionRetains[receipt] = session }
        if let delivery { inputDeliveries[receipt] = delivery }
        noteInputAdmission(command, receipt: receipt)
        enqueueEngineCommand(.command(
            command,
            receipt: receipt,
            target: CommandTarget(tmux: tmux)
        ))
    }

    func enqueueAcknowledged(
        tmux: TmuxController? = nil,
        _ command: (SessionCommandReceipt) -> SessionCommand
    ) async -> Bool {
        let receipt = SessionCommandReceipt()
        let value = command(receipt)
        guard supports(value, tmux: tmux) else { return false }
        if let refusal = authorityRefusal(value.authorityGate, tmux: tmux) {
            noteAuthorityRefusal(value.authorityGate, refusal, stage: "dispatch")
            return false
        }
        guard commandResultContinuations.count < SessionCommandLimits.maximumPendingReceipts
        else { return false }
        return await withCheckedContinuation { continuation in
            commandResultContinuations[receipt] = continuation
            enqueue(value, tmux: tmux)
        }
    }

    /// The S5′ gate: why a command of this gate must not reach tmux or the
    /// mosh transport now, from the controller's projection (two stored
    /// properties). Nil admits it, as does a session without tmux.
    func authorityRefusal(
        _ gate: SessionCommandAuthorityGate,
        tmux commandTmux: TmuxController? = nil
    ) -> SessionCommandAuthorityRefusal? {
        guard gate != .ungated, let tmux = commandTmux ?? tmux else { return nil }
        return gate.refusal(
            gatesTyping: !tmux.gridAuthorityAllowsInput,
            mutationRefusal: tmux.gridAuthorityMutationRefusal
        )
    }

    /// Refusals are counted, not logged per key.
    func noteAuthorityRefusal(
        _ gate: SessionCommandAuthorityGate,
        _ refusal: SessionCommandAuthorityRefusal,
        stage: String
    ) {
        authorityRefusalCount += 1
        guard authorityRefusalCount == 1 || authorityRefusalCount % 100 == 0 else { return }
        DiagnosticLogStore.append(
            .app,
            "session-input refused stage=\(stage) gate=\(gate.rawValue) reason=\(refusal.rawValue) count=\(authorityRefusalCount)"
        )
    }

    func respondToHostKeyChallenge(
        _ challengeID: UUID,
        decision: ChallengeDecision
    ) -> Bool {
        guard let request = pendingChallengeRequest, request.id == challengeID,
              let intent = activeIntent
        else { return false }
        let answerTime = now()
        let registration: ChallengeContext
        if let current = pendingChallengeRegistration,
           answerTime < current.expiresAt.addingTimeInterval(-Self.challengeRenewalMargin) {
            registration = current
        } else {
            let original = pendingChallengeRegistration
            let context = ChallengeContext(
                sessionID: original?.sessionID ?? hostID,
                attemptID: original?.attemptID ?? intent.requestID,
                policyGeneration: original?.policyGeneration ?? intent.policyGeneration,
                expiresAt: answerTime.addingTimeInterval(SessionChallenge.maximumLifetime)
            )
            pendingChallengeRegistration = context
            registration = context
            // Commands wait behind this lifecycle item, so registration precedes the answer.
            enqueueOrdered(.challenge(.hostKey(
                context: context,
                endpoint: KnownHostEndpoint(host: request.endpoint),
                fingerprint: request.fingerprint,
                hint: request.isChanged ? "changed:\(request.keyType)" : "unknown:\(request.keyType)"
            )))
            let ageSeconds = original.map {
                Int(answerTime.timeIntervalSince($0.expiresAt) + SessionChallenge.maximumLifetime)
            } ?? 0
            DiagnosticLogStore.appendSSH("hostkey challenge renewed ageSeconds=\(ageSeconds)")
#if DEBUG
            challengeRenewalCountForTesting += 1
#endif
        }
        enqueue(.submitChallengeResponse(ChallengeResponse(
            challengeID: registration.challengeID,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration,
            decision: decision
        )))
        // The sheet closes on the tap, but the request stays pending until
        // the engine consumes the answer. A presenter that re-subscribes in
        // that window (ContentView rebuilds its merged publisher on each
        // update) would replay it and show the answered sheet again.
        if challengeSubject.value?.id == request.id { challengeSubject.send(nil) }
        return true
    }

    func events(diagnostics: AsyncDeliveryDiagnostics? = nil) -> AsyncStream<SessionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            let subscriber = Subscriber(continuation: continuation, diagnostics: diagnostics)
            subscribers[id] = subscriber
            replayState(to: subscriber)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers[id] = nil }
            }
        }
    }

    private func replayState(to continuation: Subscriber) {
        continuation.yield(.stateChanged(generation: cachedGeneration, state: cachedState))
        if hasCachedWorkingDirectory {
            continuation.yield(.remoteWorkingDirectoryChanged(
                generation: cachedGeneration,
                path: cachedWorkingDirectory
            ))
        }
        if let cachedTmuxSnapshot {
            continuation.yield(.tmuxSnapshotChanged(
                generation: cachedGeneration,
                snapshot: cachedTmuxSnapshot
            ))
            continuation.yield(.gridAuthorityChanged(
                generation: cachedGeneration,
                snapshot: cachedAuthority
            ))
        }
        if let cachedChallenge {
            continuation.yield(.challenge(
                generation: cachedGeneration,
                challenge: cachedChallenge
            ))
        }
    }

    private static func apply(_ items: [EngineInput], to engine: isolated SessionEngine) {
        for item in items { apply(item, to: engine) }
    }

    private static func apply(_ item: EngineInput, to engine: isolated SessionEngine) {
        do {
            switch item {
            case .command:
                preconditionFailure("commands are receipt-bound by the input task")
            case .state(.idle, let intent):
                guard let intent else { return }
                try engine.transportConnectDidNotStart(
                    attemptID: intent.requestID
                )
            case .state(.connecting, let intent):
                guard let intent else { return }
                let (_, state) = engine.snapshot()
                if case .idle = state { try engine.adoptTransportAttempt(intent) }
            case .state(.connected, let intent):
                guard let intent else { return }
                let (_, state) = engine.snapshot()
                if case .idle = state { try engine.adoptTransportAttempt(intent) }
                try engine.transportConnected(
                    attemptID: intent.requestID,
                    policyGeneration: intent.policyGeneration
                )
            case .state(.disconnected, let intent):
                guard let intent else { return }
                try engine.transportDisconnected(attemptID: intent.requestID)
            case .state(.failed(let failure), let intent):
                try engine.transportFailed(failure, attemptID: intent?.requestID)
            case .bytes(let bytes, let attemptID, let receipt):
                engine.transportBytes(bytes, attemptID: attemptID, receipt: receipt)
            case .tmux(let snapshot):
                let (generation, _) = engine.snapshot()
                engine.tmuxSnapshotChanged(snapshot, generation: generation)
                engine.gridAuthorityChanged(snapshot.authority, generation: generation)
            case .challenge(let challenge):
                let (generation, _) = engine.snapshot()
                try engine.challenge(challenge, generation: generation)
            case .workingDirectory(let path):
                let (generation, _) = engine.snapshot()
                engine.remoteWorkingDirectoryChanged(path, generation: generation)
            case .commandCompleted(let receipt, let result):
                engine.backendCommandCompleted(receipt: receipt, result: result)
            }
        } catch {
            publishAdapterRejection(error, from: engine)
        }
    }

    private static func publishAdapterRejection(
        _ error: Error,
        from engine: isolated SessionEngine
    ) {
        let (generation, _) = engine.snapshot()
        engine.recoverableWarning(
            CoreFailure(code: "apple_adapter_rejected", arguments: [
                "reason": String(describing: error)
            ]),
            generation: generation
        )
    }

    private func applyBackend(
        _ operation: SessionBackendOperation,
        tmux commandTmux: TmuxController?,
        receipt: UUID? = nil
    ) {
        guard let session else {
            if let receipt { finishInputDelivery(receipt, .dropped) }
            return
        }
        let tmux = commandTmux ?? self.tmux
        // S5′ at apply time: the gate may have closed while the command
        // waited in the ordered queue.
        if let refusal = authorityRefusal(operation.authorityGate, tmux: tmux) {
            noteAuthorityRefusal(operation.authorityGate, refusal, stage: "apply")
            if let receipt {
                noteInputStage("refused", receipt: receipt, clear: true)
                finishInputDelivery(receipt, .refused)
            }
            switch operation {
            case .sendTmuxPaneInput(_, _, let paneReceipt), .sendTmuxPaneKey(_, _, let paneReceipt):
                complete(paneReceipt, failure: "tmux_owned_by_peer")
            default:
                break
            }
            return
        }
        switch operation {
        case .connect(let intent):
            (session as? any AppleSessionBackendEventSource)?
                .prepareAppleSessionAttempt(intent.requestID)
            session.connect()
            // Bind the synchronous post-call sample to the command that
            // produced it. An idle result means this exact connect did not
            // start; it must not be inferred from whatever attempt happens
            // to be current when the serialized input is later processed.
            submitLegacyState(session.state, expectedIntent: intent)
        case .cancelConnect, .disconnect, .destroy:
            session.disconnect()
            submitLegacyState(session.state)
        case .sendInput(let data):
            if let receipt { noteInputStage("backend", receipt: receipt, clear: true) }
            if session.host.transport != .mosh,
               let tmux,
               tmux.controlPath == .inline,
               tmux.mode == .tmuxControl {
                let correlation = receipt.map(Self.inputCorrelation)
                if let delivery = receipt.flatMap({ inputDeliveries.removeValue(forKey: $0) }) {
                    // Control mode types into the active pane, and tmux's
                    // reply is the delivery: the report moves into it.
                    tmux.sendInput(Array(data), correlation: correlation) { sent in
                        delivery(sent ? .sent : .dropped)
                    }
                } else {
                    tmux.sendInput(Array(data), correlation: correlation)
                }
            } else {
                (session as? SSHSession)?.noteTransportInputDiagnostic(
                    correlation: receipt.map(Self.inputCorrelation))
                (session as? MoshSession)?.noteTransportInputDiagnostic(
                    correlation: receipt.map(Self.inputCorrelation))
                // Both transports drop input once they are not connected.
                let admitted: Bool
                if let ssh = session as? SSHSession {
                    admitted = ssh.sendAdmitting(Array(data))
                } else if let mosh = session as? MoshSession {
                    admitted = mosh.sendAdmitting(Array(data))
                } else {
                    admitted = session.state == .connected
                    session.send(Array(data))
                }
                if let receipt { finishInputDelivery(receipt, admitted ? .sent : .dropped) }
            }
        case .resize(let columns, let rows):
            session.resize(cols: columns, rows: rows)
            tmux?.updateClientSize(cols: columns, rows: rows)
        case .selectTmuxWindow(let target):
            if let id = WindowId(wireValue: target) { tmux?.selectWindow(id) }
        case .selectTmuxPane(let target):
            if let id = PaneId(wireValue: target) { tmux?.selectPanePreservingWindowZoom(id) }
        case .sendTmuxPaneInput(let data, let target, let paneReceipt):
            if let receipt { noteInputStage("backend", receipt: receipt, clear: true) }
            guard let tmux, let id = PaneId(wireValue: target) else {
                complete(paneReceipt, succeeded: false)
                return
            }
            if let paneReceipt {
                Task { @MainActor [weak self, weak tmux] in
                    let succeeded = await tmux?.sendInputAcknowledged(
                        Array(data),
                        toPane: id
                    ) ?? false
                    self?.complete(paneReceipt, succeeded: succeeded)
                }
            } else {
                tmux.sendInput(Array(data), toPane: id)
            }
        case .sendTmuxPaneKey(let key, let target, let paneReceipt):
            if let receipt { noteInputStage("backend", receipt: receipt, clear: true) }
            guard let tmux, let id = PaneId(wireValue: target) else {
                complete(paneReceipt, succeeded: false)
                return
            }
            guard let paneKey = PaneInputKey(rawValue: key.tmuxKeyName) else {
                complete(paneReceipt, succeeded: false)
                return
            }
            if let paneReceipt {
                Task { @MainActor [weak self, weak tmux] in
                    let succeeded = await tmux?.sendKeyAcknowledged(
                        paneKey,
                        toPane: id
                    ) ?? false
                    self?.complete(paneReceipt, succeeded: succeeded)
                }
            } else {
                tmux.sendInput(key.bytes, toPane: id)
            }
        case .moveTmuxWindow(let target, let move):
            if let tmux, let id = WindowId(wireValue: target),
               let destination = move.destination(in: tmux.windows.map(\.id), moving: id) {
                tmux.moveWindow(id, to: destination)
            }
        case .renumberTmuxWindows: tmux?.renumberWindows()
        case .createTmuxWindow: tmux?.newWindow()
        case .closeTmuxWindow(let target):
            if let id = WindowId(wireValue: target) { tmux?.killWindow(id) }
        case .closeTmuxPane(let target):
            if let id = PaneId(wireValue: target) { tmux?.killPane(id) }
        case .splitTmuxPane(let target, let axis, let before):
            if let id = PaneId(wireValue: target) {
                tmux?.splitPane(
                    id,
                    axis: axis == .horizontal ? .horizontal : .vertical,
                    before: before
                )
            }
        case .cycleTmuxPane(let forward): tmux?.cyclePane(forward: forward)
        case .setTmuxPaneZoomed(let target, let zoomed):
            if let id = PaneId(wireValue: target) { tmux?.setPaneZoomed(id, zoomed: zoomed) }
        case .renameTmuxWindow(let target, let name):
            if let id = WindowId(wireValue: target) { tmux?.renameWindow(id, to: name) }
        case .setTmuxGridPresentation(let presentation):
            tmux?.setGridAuthorityUsesCompactSinglePaneGrid(presentation == .singlePane)
        case .claimTmuxGridAuthority(let reason, let repaintEvenIfSame):
            tmux?.claimActiveViewport(
                reason: reason.rawValue,
                repaintEvenIfSame: repaintEvenIfSame
            )
        case .reclaimTmuxGridAuthority(let reason):
            // The veil's tap. Idempotence lives in the shared reducer: a tap
            // during a visible claim is a no-op, a tap while the channel is
            // down becomes an intent that claims after the next attach (R4).
            _ = tmux?.reclaimGridAuthority(reason: reason.rawValue)
        case .completeTmuxGridAuthorityRepaint(let generation):
            tmux?.completeGridAuthoritySideChannelRepaint(generation: generation)
        case .setFocused(let focused):
            if focused { tmux?.refreshActiveWindowOnForeground() }
            else { tmux?.prepareForAppInactivity() }
        case .setApplicationVisibility(let visibility):
            if visibility == .active { tmux?.refreshActiveWindowOnForeground() }
            else { tmux?.prepareForAppInactivity() }
        case .requestFullRepaint:
            if let mosh = session as? MoshSession { mosh.forceFullRepaint() }
            else { tmux?.claimActiveViewport(reason: "shared-session-command", repaintEvenIfSame: true) }
        case .submitChallengeResponse(let response):
            if let challengeResponder {
                challengeResponder(response)
            } else if pendingChallengeRequest?.id == response.challengeID
                || pendingChallengeRegistration?.challengeID == response.challengeID {
                switch response.decision {
                case .approve: pendingChallengeRequest?.accept()
                case .reject, .cancel: pendingChallengeRequest?.reject()
                }
            }
        }
    }

    private func complete(_ receipt: SessionCommandReceipt?, succeeded: Bool) {
        complete(receipt, failure: succeeded ? nil : "tmux_command_rejected")
    }

    private func complete(_ receipt: SessionCommandReceipt?, failure code: String?) {
        guard let receipt else { return }
        enqueueEngineCommand(.commandCompleted(
            receipt,
            code.map { .failed(CoreFailure(code: $0)) } ?? .succeeded
        ))
    }

    private func finishCommand(_ receipt: SessionCommandReceipt, succeeded: Bool) {
        commandResultContinuations.removeValue(forKey: receipt)?.resume(returning: succeeded)
    }

    private func finishInputDelivery(
        _ receipt: UUID,
        _ delivery: AppleSessionCommandFacade.InputDelivery
    ) {
        inputDeliveries.removeValue(forKey: receipt)?(delivery)
    }

    private func observeSession() {
        guard let session else { return }
        if let source = session as? any AppleSessionBackendEventSource {
            source.appleSessionStateEvents
                .sink { [weak self] in self?.submitLegacyState($0) }
                .store(in: &cancellables)
            source.appleWorkingDirectoryEvents
                .sink { [weak self] in self?.submitWorkingDirectory($0) }
                .store(in: &cancellables)
            source.appleHostKeyChallengeEvents
                .sink { [weak self] in self?.submitChallenge($0) }
                .store(in: &cancellables)
            let output = source.appleAttemptOutputEvents
            let diagnostics = source.appleOutputQueueDiagnostics
            outputTask = Task { @MainActor [weak self] in
                for await chunk in output.mainActorDelivery(diagnostics: diagnostics) {
                    guard let self, !self.stopped else { break }
                    self.submitTransportBytes(
                        Data(chunk.bytes),
                        attemptID: chunk.attemptID,
                        receipt: chunk.deliveryID.map {
                            TerminalOutputReceipt(
                                deliveryID: $0,
                                repaintRequestID: chunk.repaintRequestID
                            )
                        }
                    )
                }
            }
        } else {
            submitLegacyState(session.state)
            submitWorkingDirectory(session.remoteWorkingDirectory)
            let output = session.outputStream
            outputTask = Task { @MainActor [weak self] in
                for await bytes in output.mainActorDelivery() {
                    guard let self, !self.stopped else { break }
                    self.submitTransportBytes(Data(bytes))
                }
            }
        }
    }

    fileprivate func submitLegacyState(
        _ state: SessionState,
        expectedIntent: ConnectionIntent? = nil
    ) {
        let legacy: LegacyState
        switch state {
        case .idle: legacy = .idle
        case .connecting: legacy = .connecting
        case .connected: legacy = .connected
        case .disconnected: legacy = .disconnected
        case .failed: legacy = .failed(CoreFailure(code: "transport_failed"))
        }
        let sampledIntent: ConnectionIntent?
        if let expectedIntent {
            sampledIntent = expectedIntent
        } else if let attemptID = (session as? any AppleSessionBackendEventSource)?
            .appleActiveSessionAttemptID {
            sampledIntent = activeIntent?.requestID == attemptID
                ? activeIntent
                : ConnectionIntent(
                    requestID: attemptID,
                    hostID: hostID,
                    policyGeneration: 0
                )
        } else {
            sampledIntent = activeIntent
        }
        switch state {
        case .idle:
            enqueueOrdered(.state(legacy, intent: sampledIntent))
            if sampledIntent?.requestID == activeIntent?.requestID {
                activeIntent = nil
            }
        case .connecting, .connected:
            // A just-dispatched reconnect is authoritative even when the
            // transport's attempt tag still reflects the previous attempt.
            // Only source-driven/direct attempts are adopted from the sample.
            guard let projectedIntent = activeIntent ?? sampledIntent else {
                enqueueOrdered(.state(
                    .failed(Self.missingAttemptFailure(for: state)),
                    intent: nil
                ))
                return
            }
            if activeIntent == nil { activeIntent = projectedIntent }
            enqueueOrdered(.state(legacy, intent: projectedIntent))
        case .disconnected, .failed:
            enqueueOrdered(.state(legacy, intent: sampledIntent))
            if sampledIntent?.requestID == activeIntent?.requestID {
                activeIntent = nil
            }
        }
    }

    private static func missingAttemptFailure(for state: SessionState) -> CoreFailure {
        CoreFailure(code: "apple_adapter_missing_attempt", arguments: [
            "state": String(describing: state),
        ])
    }

    private func submitWorkingDirectory(_ path: String?) {
        enqueueOrdered(.workingDirectory(path))
    }

    fileprivate func submitTransportBytes(
        _ bytes: Data,
        attemptID: UUID? = nil,
        receipt: TerminalOutputReceipt? = nil
    ) {
        // Bind the chunk to the adapter's synchronously maintained attempt.
        // Unlike the event-backed generation projection, this advances before
        // the first reconnect bytes can arrive and still rejects an old
        // attempt's queued output after the reconnect becomes connected.
        guard let attemptID = attemptID ?? activeIntent?.requestID else { return }
        enqueueOrdered(.bytes(bytes, attemptID: attemptID, receipt: receipt))
    }

    private func submitChallenge(_ request: HostKeyVerificationRequest?) {
        pendingChallengeRequest = request
        pendingChallengeRegistration = nil
        guard let request, let intent = activeIntent else {
            if request == nil {
                cachedChallenge = nil
                challengeSubject.send(nil)
            }
            return
        }
        let context = ChallengeContext(
            challengeID: request.id,
            sessionID: hostID,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration,
            expiresAt: now().addingTimeInterval(SessionChallenge.maximumLifetime)
        )
        pendingChallengeRegistration = context
        enqueueOrdered(.challenge(.hostKey(
            context: context,
            endpoint: KnownHostEndpoint(host: request.endpoint),
            fingerprint: request.fingerprint,
            hint: request.isChanged ? "changed:\(request.keyType)" : "unknown:\(request.keyType)"
        )))
    }

    private func submitTmuxIfChanged(_ tmux: TmuxController) {
        let snapshot = tmux.snapshot
        guard snapshot != observedTmuxSnapshot else { return }
        observedTmuxSnapshot = snapshot
        enqueueOrdered(.tmux(snapshot))
    }

    private func armTmuxObservation(_ observed: TmuxController) {
        withObservationTracking {
            _ = observed.snapshot
        } onChange: { [weak self, weak observed] in
            Task { @MainActor in
                guard let self, let observed, self.tmux === observed, !self.stopped else { return }
                self.submitTmuxIfChanged(observed)
                self.armTmuxObservation(observed)
            }
        }
    }

    private func publish(_ event: SessionEvent) {
        switch event {
        case .stateChanged(let generation, let state):
            cachedGeneration = generation
            cachedState = state
            stateSubject.send(state)
            if case .connecting = state {
                // Host-key and credential challenges remain active while the
                // attempt is in flight.
            } else {
                cachedChallenge = nil
                challengeSubject.send(nil)
            }
        case .tmuxSnapshotChanged(let generation, let snapshot):
            cachedGeneration = generation
            cachedTmuxSnapshot = snapshot
        case .gridAuthorityChanged(let generation, let authority):
            cachedGeneration = generation
            cachedAuthority = authority
        case .challenge(let generation, let challenge):
            cachedGeneration = generation
            cachedChallenge = challenge
            // A renewal must not re-present the sheet the user just answered.
            if pendingChallengeRequest?.id == challenge.context.challengeID {
                challengeSubject.send(pendingChallengeRequest)
            }
        case .remoteWorkingDirectoryChanged(let generation, let path):
            cachedGeneration = generation
            cachedWorkingDirectory = path
            hasCachedWorkingDirectory = true
            workingDirectorySubject.send(path)
        case .failure(let generation, _), .recoverableWarning(let generation, _),
             .terminalBytes(let generation, _, _), .forwardingStateChanged(let generation, _),
             .diagnostics(let generation, _), .destroyed(let generation):
            cachedGeneration = generation
        case .commandCompleted(let generation, let receipt, let result):
            cachedGeneration = generation
            finishCommand(receipt, succeeded: result == .succeeded)
        }
        for continuation in subscribers.values { continuation.yield(event) }
    }
}

extension TerminalSession {
    var sessionCommands: AppleSessionCommandFacade {
        AppleSessionCommandFacade(session: self)
    }

    func sessionCommands(
        tmux: TmuxController,
        challengeResponder: (@MainActor (ChallengeResponse) -> Void)? = nil
    ) -> AppleSessionCommandFacade {
        AppleSessionCommandFacade(
            session: self,
            tmux: tmux,
            challengeResponder: challengeResponder
        )
    }
}
