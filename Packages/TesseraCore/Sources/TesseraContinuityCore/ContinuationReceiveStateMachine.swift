import Foundation
import TesseraDomainCore
import TesseraProtocolCore

/// Authenticated provenance supplied by the platform transport adapter. It is
/// intentionally not Codable, so a payload cannot assert its own binding.
public enum ContinuationPairingPurpose: Equatable, Sendable {
    case continueSession
    case setUpAndContinue
}

public enum ContinuationTransportBinding: Equatable, Sendable {
    case appleAccountHandoff
    case authenticatedPairing(
        transcriptHash: Data,
        purpose: ContinuationPairingPurpose
    )
    case authenticatedRelay(peerID: Data, channelBinding: Data)
    case unbound

    public var allowsContinuity: Bool {
        switch self {
        case .appleAccountHandoff:
            return true
        case .authenticatedPairing(let hash, _):
            return !hash.isEmpty
        case .authenticatedRelay(let peerID, let binding):
            return !peerID.isEmpty && !binding.isEmpty
        case .unbound:
            return false
        }
    }
}

public struct PendingContinuation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let descriptor: ContinuationDescriptorV1
    public let transportBinding: ContinuationTransportBinding
    public let receivedAt: Date
    public let policyGeneration: UInt64

    public init(
        id: UUID = UUID(),
        descriptor: ContinuationDescriptorV1,
        transportBinding: ContinuationTransportBinding,
        receivedAt: Date = Date(),
        policyGeneration: UInt64
    ) {
        self.id = id
        self.descriptor = descriptor
        self.transportBinding = transportBinding
        self.receivedAt = receivedAt
        self.policyGeneration = policyGeneration
    }
}

public enum ContinuationConnectionTarget: Equatable, Sendable {
    case existing(HostProfile)
    case admitted(hostID: UUID)

    public var hostID: UUID {
        switch self {
        case .existing(let profile): return profile.id
        case .admitted(let id): return id
        }
    }
}

public struct ContinuationCompletionReceipt: Equatable, Sendable {
    public let continuationID: UUID
    public let hostID: UUID
    public let completedAt: Date

    public init(continuationID: UUID, hostID: UUID, completedAt: Date) {
        self.continuationID = continuationID
        self.hostID = hostID
        self.completedAt = completedAt
    }
}

public enum ContinuationReceiveFailure: Equatable, Sendable {
    case invalidDescriptor
    case unauthenticatedTransport
    case hostAdmissionDenied
    case credentialEnrollmentFailed
    case connectionFailed
    case policyInvalidated
    case invalidTransition
}

public enum ContinuationReceiveState: Equatable, Sendable {
    case idle
    case received(PendingContinuation)
    case stashedBehindLock(PendingContinuation)
    case ready(PendingContinuation)
    case resolving(PendingContinuation)
    case needsHostAdmission(PendingContinuation, ContinuationInsertionPlan)
    case needsCredential(PendingContinuation, ContinuationConnectionTarget)
    case connecting(PendingContinuation, ContinuationConnectionTarget)
    case completed(ContinuationCompletionReceipt)
    case cancelled(UUID?)
    case failed(UUID?, ContinuationReceiveFailure)

    public var pending: PendingContinuation? {
        switch self {
        case .received(let pending), .stashedBehindLock(let pending),
             .ready(let pending), .resolving(let pending):
            return pending
        case .needsHostAdmission(let pending, _), .needsCredential(let pending, _),
             .connecting(let pending, _):
            return pending
        case .idle, .completed, .cancelled, .failed:
            return nil
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: return true
        default: return false
        }
    }
}

public enum ContinuationReceiveError: Error, Equatable, Sendable {
    case busy
    /// Preserves the protocol validator's structured failure when decoding
    /// reached schema-v1 validation. A nil detail means the bytes were not a
    /// decodable descriptor at all.
    case invalidDescriptor(ContinuationDescriptorError?)
    case unauthenticatedTransport
    case invalidTransition
    case stalePolicy
    case mismatchedContinuation
    case mismatchedHost
}

/// Pure receive coordinator shared by Apple Handoff, Android pairing, and
/// future authenticated transports. UI, persistence, credentials, and network
/// connection work remain in adapters.
public struct ContinuationReceiveStateMachine: Sendable {
    public private(set) var state: ContinuationReceiveState
    public private(set) var lastFailure: ContinuationReceiveError?

    private let now: @Sendable () -> Date

    public init(
        initialState: ContinuationReceiveState = .idle,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        state = initialState
        self.now = now
    }

    /// Decodes the exact schema-v1 payload and immediately applies the app-lock
    /// boundary. Busy rejection never discards the valid pending continuation.
    @discardableResult
    public mutating func receiveDescriptor(
        _ bytes: Data,
        transportBinding: ContinuationTransportBinding,
        isLocked: Bool,
        policyGeneration: UInt64
    ) throws -> PendingContinuation {
        // A terminal receipt is still owned by the caller until it explicitly
        // releases it with `reset()`. In particular, completion or a failure
        // reached after accepting an authenticated activity must not be
        // overwritten by a second delivery while the Apple adapter still
        // holds the first activity's continuation-stream authority.
        // Cancellation is itself the explicit release action, so a cancelled
        // receipt may be replaced directly.
        guard state == .idle || state.isReleasedCancellation else {
            lastFailure = .busy
            throw ContinuationReceiveError.busy
        }
        guard transportBinding.allowsContinuity else {
            state = .failed(nil, .unauthenticatedTransport)
            lastFailure = .unauthenticatedTransport
            throw ContinuationReceiveError.unauthenticatedTransport
        }
        let descriptor: ContinuationDescriptorV1
        do {
            descriptor = try ContinuationActivityCodec.decode(bytes)
        } catch let error as ContinuationDescriptorError {
            state = .failed(nil, .invalidDescriptor)
            lastFailure = .invalidDescriptor(error)
            throw ContinuationReceiveError.invalidDescriptor(error)
        } catch {
            state = .failed(nil, .invalidDescriptor)
            lastFailure = .invalidDescriptor(nil)
            throw ContinuationReceiveError.invalidDescriptor(nil)
        }
        let pending = PendingContinuation(
            descriptor: descriptor,
            transportBinding: transportBinding,
            receivedAt: now(),
            policyGeneration: policyGeneration
        )
        state = .received(pending)
        state = isLocked ? .stashedBehindLock(pending) : .ready(pending)
        lastFailure = nil
        return pending
    }

    public mutating func unlock() throws {
        guard case .stashedBehindLock(let pending) = state else {
            throw ContinuationReceiveError.invalidTransition
        }
        state = .ready(pending)
        lastFailure = nil
    }

    /// Rewinds only an unconsumed Apple-compatible intent behind the lock.
    /// Once the user has consumed the activity, the released iOS application
    /// lets the resulting editor/connection follow normal app-lock lifecycle;
    /// enrollment grants remain independently invalidated by their coordinator.
    public mutating func applicationDidLock() {
        guard case .ready(let pending) = state else { return }
        state = .stashedBehindLock(pending)
    }

    public mutating func consume(
        _ continuationID: UUID,
        policyGeneration: UInt64
    ) throws -> PendingContinuation {
        guard case .ready(let pending) = state else {
            throw ContinuationReceiveError.invalidTransition
        }
        guard pending.id == continuationID else {
            throw ContinuationReceiveError.mismatchedContinuation
        }
        try requireCurrentPolicy(pending, policyGeneration: policyGeneration)
        state = .resolving(pending)
        return pending
    }

    /// Resolves from repository snapshots inside the core so callers cannot
    /// assert a fast-path or endpoint match for an unrelated local host.
    @discardableResult
    public mutating func resolve(
        among candidates: [ContinuationHostCandidate],
        hasSavedHost: (UUID) -> Bool
    ) throws -> ContinuationResolution {
        guard case .resolving(let pending) = state else {
            throw ContinuationReceiveError.invalidTransition
        }
        let resolution = ContinuationResolver.resolve(
            pending.descriptor,
            among: candidates
        )
        try resolutionCompleted(resolution, hasSavedHost: hasSavedHost)
        return resolution
    }

    /// Existing hosts always proceed through local credential revalidation.
    /// Unknown hosts first pass atomic row admission before any insertion.
    mutating func resolutionCompleted(
        _ resolution: ContinuationResolution,
        hasSavedHost: (UUID) -> Bool
    ) throws {
        guard case .resolving(let pending) = state else {
            throw ContinuationReceiveError.invalidTransition
        }
        switch resolution {
        case .fastPath(let profile), .endpointMatch(let profile):
            state = .needsCredential(pending, .existing(profile))
        case .prefill(let descriptor):
            guard descriptor == pending.descriptor else {
                state = .failed(pending.id, .invalidTransition)
                throw ContinuationReceiveError.mismatchedContinuation
            }
            state = .needsHostAdmission(
                pending,
                ContinuationInsertionPlanner.plan(
                    for: descriptor,
                    hasSavedHost: hasSavedHost
                )
            )
        }
    }

    public mutating func hostAdmissionCompleted(
        continuationID: UUID,
        admittedHostID: UUID,
        insertedHostIDs: Set<UUID>,
        policyGeneration: UInt64
    ) throws {
        guard case .needsHostAdmission(let pending, let plan) = state else {
            throw ContinuationReceiveError.invalidTransition
        }
        guard pending.id == continuationID else {
            throw ContinuationReceiveError.mismatchedContinuation
        }
        guard admittedHostID == pending.descriptor.hostID,
              plan.insertedHostIDs.contains(admittedHostID),
              insertedHostIDs == plan.insertedHostIDs else {
            throw ContinuationReceiveError.mismatchedHost
        }
        try requireCurrentPolicy(pending, policyGeneration: policyGeneration)
        state = .needsCredential(pending, .admitted(hostID: admittedHostID))
    }

    public mutating func hostAdmissionDenied() throws {
        guard case .needsHostAdmission(let pending, _) = state else {
            throw ContinuationReceiveError.invalidTransition
        }
        state = .failed(pending.id, .hostAdmissionDenied)
    }

    public mutating func credentialEnrollmentCompleted(
        continuationID: UUID,
        hostID: UUID,
        policyGeneration: UInt64
    ) throws {
        guard case .needsCredential(let pending, let target) = state else {
            throw ContinuationReceiveError.invalidTransition
        }
        guard pending.id == continuationID else {
            throw ContinuationReceiveError.mismatchedContinuation
        }
        guard target.hostID == hostID else { throw ContinuationReceiveError.mismatchedHost }
        try requireCurrentPolicy(pending, policyGeneration: policyGeneration)
        state = .connecting(pending, target)
    }

    public mutating func credentialEnrollmentFailed() throws {
        guard case .needsCredential(let pending, _) = state else {
            throw ContinuationReceiveError.invalidTransition
        }
        state = .failed(pending.id, .credentialEnrollmentFailed)
    }

    @discardableResult
    public mutating func connectionCompleted(
        continuationID: UUID,
        hostID: UUID,
        policyGeneration: UInt64
    ) throws -> ContinuationCompletionReceipt {
        guard case .connecting(let pending, let target) = state else {
            throw ContinuationReceiveError.invalidTransition
        }
        guard pending.id == continuationID else {
            throw ContinuationReceiveError.mismatchedContinuation
        }
        guard target.hostID == hostID else { throw ContinuationReceiveError.mismatchedHost }
        try requireCurrentPolicy(pending, policyGeneration: policyGeneration)
        let receipt = ContinuationCompletionReceipt(
            continuationID: pending.id,
            hostID: target.hostID,
            completedAt: now()
        )
        state = .completed(receipt)
        return receipt
    }

    public mutating func connectionFailed() throws {
        guard case .connecting(let pending, _) = state else {
            throw ContinuationReceiveError.invalidTransition
        }
        state = .failed(pending.id, .connectionFailed)
    }

    public mutating func cancel() {
        state = .cancelled(state.pending?.id)
        lastFailure = nil
    }

    public mutating func securityPolicyChanged(to newGeneration: UInt64) {
        guard let pending = state.pending,
              pending.policyGeneration != newGeneration else { return }
        state = .failed(pending.id, .policyInvalidated)
        lastFailure = .stalePolicy
    }

    public mutating func clearLastFailure() {
        lastFailure = nil
    }

    public mutating func reset() {
        state = .idle
        lastFailure = nil
    }

    private mutating func requireCurrentPolicy(
        _ pending: PendingContinuation,
        policyGeneration: UInt64
    ) throws {
        guard pending.policyGeneration == policyGeneration else {
            state = .failed(pending.id, .policyInvalidated)
            lastFailure = .stalePolicy
            throw ContinuationReceiveError.stalePolicy
        }
    }
}

private extension ContinuationReceiveState {
    var isReleasedCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
