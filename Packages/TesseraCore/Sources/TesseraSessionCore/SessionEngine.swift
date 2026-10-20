import Foundation

public actor SessionEngine {
    public typealias EventSink = @Sendable (SessionEvent) -> Void

    public let sessionID: UUID
    private var generation = SessionGeneration(rawValue: 1)
    private var state: SharedSessionState = .idle
    private var currentAttemptID: UUID?
    private var currentPolicyGeneration: UInt64?
    private var terminalAttemptID: UUID?
    private var destroyed = false
    private var challengeRegistry: ChallengeRegistry.Storage
    private var pendingCommandReceipts: [SessionCommandReceipt] = []
    private var pendingCommandReceiptMembership: Set<SessionCommandReceipt> = []
    private let eventSink: EventSink
    private let backendPorts: SessionBackendPorts?

    public init(
        sessionID: UUID = UUID(),
        initialGeneration: SessionGeneration = SessionGeneration(rawValue: 1),
        backendPorts: SessionBackendPorts? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        eventSink: @escaping EventSink
    ) {
        self.sessionID = sessionID
        generation = initialGeneration
        self.backendPorts = backendPorts
        challengeRegistry = ChallengeRegistry.Storage(now: now)
        self.eventSink = eventSink
    }

    public func handle(_ command: SessionCommand) throws {
        guard !destroyed else { throw SessionEngineError.destroyed }
        if let receipt = command.completionReceipt {
            guard !pendingCommandReceiptMembership.contains(receipt) else {
                throw SessionEngineError.duplicateReceipt
            }
            guard pendingCommandReceipts.count < SessionCommandLimits.maximumPendingReceipts
            else {
                emit(.commandCompleted(
                    generation: generation,
                    receipt: receipt,
                    result: .failed(CoreFailure(code: "too_many_pending_commands"))
                ))
                throw SessionEngineError.tooManyPendingReceipts
            }
            pendingCommandReceiptMembership.insert(receipt)
            pendingCommandReceipts.append(receipt)
        }
        do {
            try handleAccepted(command)
        } catch {
            if let receipt = command.completionReceipt,
               removePendingCommandReceipt(receipt) {
                emit(.commandCompleted(
                    generation: generation,
                    receipt: receipt,
                    result: .failed(CoreFailure(code: "command_rejected"))
                ))
            }
            throw error
        }
    }

    private func handleAccepted(_ command: SessionCommand) throws {
        switch command {
        case .connect(let intent):
            guard currentAttemptID == nil else { throw SessionEngineError.connectAlreadyActive }
            challengeRegistry.invalidateAll()
            currentAttemptID = intent.requestID
            currentPolicyGeneration = intent.policyGeneration
            state = .connecting(attemptID: intent.requestID)
            emit(.stateChanged(generation: generation, state: state))
            try dispatchBackend(command)
        case .cancelConnect(let attemptID):
            guard currentAttemptID == attemptID else { throw SessionEngineError.staleAttempt }
            challengeRegistry.invalidateAll()
            terminalAttemptID = attemptID
            currentAttemptID = nil
            currentPolicyGeneration = nil
            state = .disconnected
            bumpGeneration()
            failPendingCommandReceipts(code: "session_disconnected")
            emit(.stateChanged(generation: generation, state: state))
            try dispatchBackend(command)
        case .disconnect:
            challengeRegistry.invalidateAll()
            if let currentAttemptID { terminalAttemptID = currentAttemptID }
            currentAttemptID = nil
            currentPolicyGeneration = nil
            state = .disconnected
            bumpGeneration()
            failPendingCommandReceipts(code: "session_disconnected")
            emit(.stateChanged(generation: generation, state: state))
            try dispatchBackend(command)
        case .sendInput(let bytes):
            guard case .connected = state, !bytes.isEmpty else {
                throw SessionEngineError.notConnected
            }
            guard bytes.count <= SessionCommandLimits.maximumInputBytes
            else { throw SessionEngineError.inputTooLarge }
            try dispatchBackend(command)
        case .resize(let columns, let rows):
            guard columns > 0, rows > 0,
                  columns <= SessionCommandLimits.maximumColumns,
                  rows <= SessionCommandLimits.maximumRows
            else { throw SessionEngineError.invalidGeometry }
            try dispatchBackend(command)
        case .submitChallengeResponse(let response):
            guard let currentAttemptID else {
                throw SessionEngineError.staleAttempt
            }
            guard let currentPolicyGeneration else {
                throw SessionEngineError.stalePolicy
            }
            _ = try challengeRegistry.consume(
                response,
                currentAttemptID: currentAttemptID,
                currentPolicyGeneration: currentPolicyGeneration
            )
            try dispatchBackend(command)
        case .destroy:
            destroyed = true
            challengeRegistry.invalidateAll()
            if let currentAttemptID { terminalAttemptID = currentAttemptID }
            currentAttemptID = nil
            currentPolicyGeneration = nil
            bumpGeneration()
            failPendingCommandReceipts(code: "session_destroyed")
            try dispatchBackend(command)
            emit(.destroyed(generation: generation))
        case .moveTmuxWindow(let target, let move):
            guard isValidWindowID(target) else { throw SessionEngineError.invalidTmuxPayload }
            if case .position(let position) = move, !(0..<512).contains(position) {
                throw SessionEngineError.invalidTmuxPayload
            }
            try dispatchBackend(command)
        case .selectTmuxWindow(let target), .closeTmuxWindow(let target),
             .renameTmuxWindow(let target, _):
            guard isValidWindowID(target) else { throw SessionEngineError.invalidTmuxPayload }
            if case .renameTmuxWindow(_, let name) = command {
                guard isValidRename(name) else { throw SessionEngineError.invalidTmuxPayload }
            }
            try dispatchBackend(command)
        case .selectTmuxPane(let target), .closeTmuxPane(let target),
             .setTmuxPaneZoomed(let target, _), .splitTmuxPane(let target, _, _):
            guard isValidPaneID(target) else { throw SessionEngineError.invalidTmuxPayload }
            try dispatchBackend(command)
        case .sendTmuxPaneKey(_, let target, let receipt):
            guard isValidPaneID(target) else { throw SessionEngineError.invalidTmuxPayload }
            if receipt != nil {
                guard case .connected = state else { throw SessionEngineError.notConnected }
            }
            try dispatchBackend(command)
        case .sendTmuxPaneInput(let data, let target, let receipt):
            guard isValidPaneID(target), !data.isEmpty,
                  data.count <= SessionCommandLimits.maximumInputBytes
            else { throw SessionEngineError.invalidTmuxPayload }
            if receipt != nil {
                guard case .connected = state else { throw SessionEngineError.notConnected }
            }
            try dispatchBackend(command)
        case .renumberTmuxWindows, .createTmuxWindow, .cycleTmuxPane, .setTmuxGridPresentation,
             .claimTmuxGridAuthority, .reclaimTmuxGridAuthority,
             .completeTmuxGridAuthorityRepaint, .setFocused,
             .setApplicationVisibility, .requestFullRepaint:
            try dispatchBackend(command)
        }
    }

    /// Completes an acknowledged backend operation against the exact receipt
    /// admitted by `handle`. Late or duplicate adapter callbacks are inert.
    public func backendCommandCompleted(
        receipt: SessionCommandReceipt,
        result: SessionCommandResult
    ) {
        guard !destroyed, removePendingCommandReceipt(receipt) else { return }
        emit(.commandCompleted(generation: generation, receipt: receipt, result: result))
    }

    public func transportConnected(attemptID: UUID, policyGeneration: UInt64) throws {
        guard currentAttemptID == attemptID else { throw SessionEngineError.staleAttempt }
        guard currentPolicyGeneration == policyGeneration else {
            throw SessionEngineError.stalePolicy
        }
        if case .connected = state { return }
        state = .connected
        emit(.stateChanged(generation: generation, state: state))
    }

    /// Reconcile a backend connect operation that returned without starting
    /// the transport. This is distinct from a disconnect: no connection was
    /// established, so the generation remains valid and no backend operation
    /// is dispatched. The attempt and connecting state must both still match
    /// so a late idle sample cannot rewind a newer or connected attempt.
    public func transportConnectDidNotStart(attemptID: UUID) throws {
        guard !destroyed else { throw SessionEngineError.destroyed }
        guard currentAttemptID == attemptID,
              state == .connecting(attemptID: attemptID)
        else { throw SessionEngineError.staleAttempt }
        challengeRegistry.invalidateAll()
        terminalAttemptID = attemptID
        currentAttemptID = nil
        currentPolicyGeneration = nil
        state = .idle
        failPendingCommandReceipts(code: "session_connect_did_not_start")
        emit(.stateChanged(generation: generation, state: state))
    }

    /// Adopt a transport attempt that was already in flight when a platform
    /// adapter attached (for example after SwiftUI presentation recreation).
    /// This changes shared state without asking the backend to connect twice.
    public func adoptTransportAttempt(_ intent: ConnectionIntent) throws {
        guard currentAttemptID == nil else {
            guard currentAttemptID == intent.requestID,
                  currentPolicyGeneration == intent.policyGeneration
            else { throw SessionEngineError.connectAlreadyActive }
            return
        }
        challengeRegistry.invalidateAll()
        currentAttemptID = intent.requestID
        currentPolicyGeneration = intent.policyGeneration
        state = .connecting(attemptID: intent.requestID)
        emit(.stateChanged(generation: generation, state: state))
    }

    /// Backend-originated disconnect (remote EOF, transport cancellation, or
    /// reconnect exhaustion). Command-originated disconnects are already
    /// projected by `handle(.disconnect)`; exact duplicate reports are
    /// idempotent while stale attempts are rejected.
    public func transportDisconnected(attemptID: UUID) throws {
        guard !destroyed else { throw SessionEngineError.destroyed }
        guard let activeAttemptID = currentAttemptID else {
            guard terminalAttemptID == attemptID else {
                throw SessionEngineError.staleAttempt
            }
            return
        }
        guard activeAttemptID == attemptID else { throw SessionEngineError.staleAttempt }
        challengeRegistry.invalidateAll()
        terminalAttemptID = attemptID
        currentAttemptID = nil
        currentPolicyGeneration = nil
        state = .disconnected
        bumpGeneration()
        failPendingCommandReceipts(code: "session_disconnected")
        emit(.stateChanged(generation: generation, state: state))
    }

    /// Backend-originated failure when the adapter may have attached after the
    /// attempt began. If an attempt id is supplied it remains stale-safe.
    public func transportFailed(_ failure: CoreFailure, attemptID: UUID? = nil) throws {
        if let attemptID, currentAttemptID != attemptID {
            throw SessionEngineError.staleAttempt
        }
        guard !destroyed else { throw SessionEngineError.destroyed }
        challengeRegistry.invalidateAll()
        if let activeAttemptID = currentAttemptID {
            terminalAttemptID = activeAttemptID
        }
        currentAttemptID = nil
        currentPolicyGeneration = nil
        state = .failed(failure)
        bumpGeneration()
        failPendingCommandReceipts(code: "session_failed")
        emit(.failure(generation: generation, failure: failure))
        emit(.stateChanged(generation: generation, state: state))
    }

    public func transportBytes(
        _ bytes: Data,
        generation expected: SessionGeneration,
        receipt: TerminalOutputReceipt? = nil
    ) {
        guard !destroyed, expected == generation, case .connected = state else { return }
        emit(.terminalBytes(generation: generation, bytes: bytes, receipt: receipt))
    }

    /// Adapter-originated bytes bound to the transport attempt that observed
    /// them. This prevents an old queued backend chunk from being accepted by
    /// a later reconnect while still allowing the first valid reconnect chunk
    /// before the event projection has caught up to the new generation.
    public func transportBytes(
        _ bytes: Data,
        attemptID expected: UUID,
        receipt: TerminalOutputReceipt? = nil
    ) {
        guard !destroyed, expected == currentAttemptID,
              case .connected = state else { return }
        emit(.terminalBytes(generation: generation, bytes: bytes, receipt: receipt))
    }

    /// A pure relay: accepted on the generation alone, never stored, merged
    /// or deduplicated here. Android's `TmuxSnapshotRepublishGate` depends on
    /// that: it skips re-sending the same snapshot payload under the same
    /// generation because a relay that already accepted it can learn nothing
    /// from it again. Any change that makes this engine keep, reset or drop
    /// tmux snapshot state must bump `generation` whenever that state is lost
    /// (or make the gate forget its last payload), or the gate would suppress
    /// exactly the re-send that restores it.
    public func tmuxSnapshotChanged(_ snapshot: TmuxSnapshot, generation expected: SessionGeneration) {
        guard accepts(expected) else { return }
        emit(.tmuxSnapshotChanged(generation: generation, snapshot: snapshot))
    }

    public func gridAuthorityChanged(
        _ snapshot: GridAuthoritySnapshot,
        generation expected: SessionGeneration
    ) {
        guard accepts(expected) else { return }
        emit(.gridAuthorityChanged(generation: generation, snapshot: snapshot))
    }

    public func challenge(
        _ challenge: SessionChallenge,
        generation expected: SessionGeneration
    ) throws {
        guard accepts(expected), challenge.context.attemptID == currentAttemptID,
              challenge.context.policyGeneration == currentPolicyGeneration else { return }
        guard challenge.context.sessionID == sessionID else {
            throw ChallengeValidationError.staleSession
        }
        try challengeRegistry.insert(challenge)
        emit(.challenge(generation: generation, challenge: challenge))
    }

    public func remoteWorkingDirectoryChanged(_ path: String?, generation expected: SessionGeneration) {
        guard accepts(expected) else { return }
        emit(.remoteWorkingDirectoryChanged(generation: generation, path: path))
    }

    public func forwardingStateChanged(_ states: [ForwardingState], generation expected: SessionGeneration) {
        guard accepts(expected) else { return }
        emit(.forwardingStateChanged(generation: generation, states: states))
    }

    public func recoverableWarning(_ warning: CoreFailure, generation expected: SessionGeneration) {
        guard accepts(expected) else { return }
        emit(.recoverableWarning(generation: generation, warning: warning))
    }

    public func diagnostic(_ event: DiagnosticEvent, generation expected: SessionGeneration) {
        guard accepts(expected) else { return }
        emit(.diagnostics(generation: generation, event: event))
    }

    public func fail(_ failure: CoreFailure, attemptID: UUID) throws {
        guard currentAttemptID == attemptID else { throw SessionEngineError.staleAttempt }
        challengeRegistry.invalidateAll()
        terminalAttemptID = attemptID
        currentAttemptID = nil
        currentPolicyGeneration = nil
        state = .failed(failure)
        bumpGeneration()
        failPendingCommandReceipts(code: "session_failed")
        emit(.failure(generation: generation, failure: failure))
        emit(.stateChanged(generation: generation, state: state))
    }

    public func snapshot() -> (SessionGeneration, SharedSessionState) {
        (generation, state)
    }

    private func bumpGeneration() {
        generation = SessionGeneration(rawValue: generation.rawValue &+ 1)
    }

    private func failPendingCommandReceipts(code: String) {
        let receipts = pendingCommandReceipts
        pendingCommandReceipts.removeAll(keepingCapacity: true)
        pendingCommandReceiptMembership.removeAll(keepingCapacity: true)
        for receipt in receipts {
            emit(.commandCompleted(
                generation: generation,
                receipt: receipt,
                result: .failed(CoreFailure(code: code))
            ))
        }
    }

    private func removePendingCommandReceipt(_ receipt: SessionCommandReceipt) -> Bool {
        guard pendingCommandReceiptMembership.remove(receipt) != nil else { return false }
        pendingCommandReceipts.removeAll { $0 == receipt }
        return true
    }

    private func emit(_ event: SessionEvent) {
        eventSink(event)
    }

    private func accepts(_ expected: SessionGeneration) -> Bool {
        !destroyed && expected == generation
    }

    private func dispatchBackend(_ command: SessionCommand) throws {
        let operation = SessionBackendOperation(command)
        guard let backendPorts else {
            emit(.recoverableWarning(
                generation: generation,
                warning: CoreFailure(
                    code: "backend_unconfigured",
                    arguments: ["operation": operation.kindCode]
                )
            ))
            if let receipt = command.completionReceipt {
                backendCommandCompleted(
                    receipt: receipt,
                    result: .failed(CoreFailure(code: "backend_unconfigured"))
                )
            }
            return
        }
        do {
            try backendPorts.perform(operation)
        } catch {
            throw SessionEngineError.backendRejected
        }
    }

    private func isValidWindowID(_ value: String) -> Bool {
        guard let value = WindowId(wireValue: value) else { return false }
        return (0...SessionCommandLimits.maximumTmuxObjectID).contains(value.rawValue)
    }

    private func isValidPaneID(_ value: String) -> Bool {
        guard let value = PaneId(wireValue: value) else { return false }
        return (0...SessionCommandLimits.maximumTmuxObjectID).contains(value.rawValue)
    }

    private func isValidRename(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty,
              scalars.count <= SessionCommandLimits.maximumRenameUnicodeScalars,
              scalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
        else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum SessionEngineError: Error, Equatable, Sendable {
    case destroyed
    case connectAlreadyActive
    case staleAttempt
    case stalePolicy
    case notConnected
    case inputTooLarge
    case invalidGeometry
    case invalidTmuxPayload
    case duplicateReceipt
    case tooManyPendingReceipts
    case backendRejected
}
