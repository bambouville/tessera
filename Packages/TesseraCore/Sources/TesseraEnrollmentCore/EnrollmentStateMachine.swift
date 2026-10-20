import Foundation
import TesseraSessionCore

public struct EnrollmentInstallGrant: Equatable, Sendable {
    public let request: EnrollmentRequestV1
    public let ownerAuthorizationRequest: OwnerAuthorizationRequest
    public let accessAuthorization: DeviceAccessGrantEngine.Authorization

    public init(
        request: EnrollmentRequestV1,
        ownerAuthorizationRequest: OwnerAuthorizationRequest,
        accessAuthorization: DeviceAccessGrantEngine.Authorization
    ) {
        self.request = request
        self.ownerAuthorizationRequest = ownerAuthorizationRequest
        self.accessAuthorization = accessAuthorization
    }

    public var enrollmentID: UUID { request.id }
    public var authorizedKeysLine: String { request.publicKey.authorizedKeysLine }
}

/// Evidence from an installer adapter that the exact authorized_keys mutation
/// has completed, was read back, and its audit intent is durable.
public struct DurableEnrollmentInstallReceipt: Equatable, Sendable {
    public let enrollmentID: UUID
    public let publicKeyFingerprint: String
    public let routeIdentity: String
    public let recordedAt: Date

    public init(
        enrollmentID: UUID,
        publicKeyFingerprint: String,
        routeIdentity: String,
        recordedAt: Date
    ) {
        self.enrollmentID = enrollmentID
        self.publicKeyFingerprint = publicKeyFingerprint
        self.routeIdentity = routeIdentity
        self.recordedAt = recordedAt
    }
}

/// Evidence that the requester durably saved its local identity and access
/// ledger before it emits the `recorded` wire receipt.
public struct DurableEnrollmentRecordReceipt: Equatable, Sendable {
    public let enrollmentID: UUID
    public let publicKeyFingerprint: String
    public let recordedAt: Date

    public init(
        enrollmentID: UUID,
        publicKeyFingerprint: String,
        recordedAt: Date
    ) {
        self.enrollmentID = enrollmentID
        self.publicKeyFingerprint = publicKeyFingerprint
        self.recordedAt = recordedAt
    }
}

/// Final protocol receipt. The requester may expose completion or connect with
/// the new key only after receiving this acknowledgement.
public struct EnrollmentCompletionReceipt: Equatable, Sendable {
    public let enrollmentID: UUID
    public let completedAt: Date

    public init(enrollmentID: UUID, completedAt: Date) {
        self.enrollmentID = enrollmentID
        self.completedAt = completedAt
    }
}

public enum EnrollmentFailure: Equatable, Sendable {
    case peerBindingRequired
    case invalidRequest
    case protocolViolation
    case authorizationFailed
    case staleAuthorization
    case installationFailed
    case persistenceFailed
    case transportFailure
    case policyInvalidated
    case remote(EnrollmentRemoteFailureV1)
}

public enum EnrollmentState: Equatable, Sendable {
    case idle
    case requesting(EnrollmentRequestV1)
    case awaitingApproval(EnrollmentRequestV1)
    case authorizing(EnrollmentRequestV1)
    case awaitingInstallation(EnrollmentInstallGrant)
    case installing(EnrollmentInstallGrant)
    case awaitingRequesterRecord(EnrollmentInstallGrant, DurableEnrollmentInstallReceipt)
    case recordingRequester(EnrollmentRequestV1)
    case awaitingOriginCompletion(EnrollmentRequestV1, DurableEnrollmentRecordReceipt)
    case completed(EnrollmentCompletionReceipt)
    case rejected(UUID)
    case cancelled(UUID?)
    case failed(UUID?, EnrollmentFailure)

    public var enrollmentID: UUID? {
        switch self {
        case .idle: return nil
        case .requesting(let request), .awaitingApproval(let request),
             .authorizing(let request), .recordingRequester(let request):
            return request.id
        case .awaitingInstallation(let grant), .installing(let grant):
            return grant.enrollmentID
        case .awaitingRequesterRecord(let grant, _):
            return grant.enrollmentID
        case .awaitingOriginCompletion(let request, _):
            return request.id
        case .completed(let receipt): return receipt.enrollmentID
        case .rejected(let id): return id
        case .cancelled(let id), .failed(let id, _): return id
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .rejected, .cancelled, .failed: return true
        default: return false
        }
    }
}

public enum EnrollmentStateMachineError: Error, Equatable, Sendable {
    case peerBindingRequired
    case invalidTransition
    case invalidRequest
    case authorizationFailed
    case staleAuthorization
    case receiptMismatch
    case policyInvalidated
}

/// Platform-neutral strict enrollment coordinator. Platform adapters own byte
/// delivery, owner-authentication UI, authorized_keys mutation, and durable
/// persistence; this actor owns their ordering and one-shot authorization.
public actor EnrollmentStateMachine {
    public static let maximumAuthorizationAge: TimeInterval = 10
    public static let maximumAuthorizationFutureSkew: TimeInterval = 1

    public private(set) var state: EnrollmentState = .idle

    private let peerBinding: PeerBinding
    private let authorizer: any FreshOwnerAuthorizing
    private let grantEngine: DeviceAccessGrantEngine
    private let now: @Sendable () -> Date

    public init(
        peerBinding: PeerBinding,
        authorizer: any FreshOwnerAuthorizing,
        grantEngine: DeviceAccessGrantEngine? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard peerBinding.allowsEnrollment else {
            throw EnrollmentStateMachineError.peerBindingRequired
        }
        self.peerBinding = peerBinding
        self.authorizer = authorizer
        // The authorization capability and the enrollment state machine must
        // use the same clock. Besides making deterministic adapters possible,
        // this avoids accepting freshness at the state boundary and then
        // rejecting the same proof as stale while minting the one-shot grant.
        self.grantEngine = grantEngine ?? DeviceAccessGrantEngine(now: now)
        self.now = now
    }

    /// Constructs the shared authority from a live Pairing v1 enrollment
    /// transaction. Callers cannot substitute arbitrary transcript bytes.
    public init(
        transaction: EnrollmentTransactionV1,
        authorizer: any FreshOwnerAuthorizing,
        grantEngine: DeviceAccessGrantEngine? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        try self.init(
            peerBinding: try transaction.consumePeerBinding(),
            authorizer: authorizer,
            grantEngine: grantEngine,
            now: now
        )
    }

    public func request(_ request: EnrollmentRequestV1) throws -> EnrollmentMessageV1 {
        guard state == .idle else { throw EnrollmentStateMachineError.invalidTransition }
        do {
            try request.validate()
        } catch {
            state = .failed(request.id, .invalidRequest)
            throw EnrollmentStateMachineError.invalidRequest
        }
        state = .requesting(request)
        return .request(request)
    }

    /// Performs fresh owner authorization and mints a one-shot capability
    /// bound to the exact enrollment attempt, host route, policy generation,
    /// and public-key fingerprint.
    public func approve(
        scope: OwnerAuthorizationScope,
        policyGeneration: UInt64,
        expiresAt: Date
    ) async throws -> EnrollmentInstallGrant {
        guard case .awaitingApproval(let request) = state else {
            throw EnrollmentStateMachineError.invalidTransition
        }
        guard scope.hostID == request.hostID,
              scope.publicKeyFingerprint == request.publicKey.fingerprint,
              !scope.routeIdentity.isEmpty,
              now() < expiresAt else {
            state = .failed(request.id, .invalidRequest)
            throw EnrollmentStateMachineError.invalidRequest
        }
        state = .authorizing(request)
        let authorizationRequest = OwnerAuthorizationRequest(
            attemptID: request.id,
            policyGeneration: policyGeneration,
            scope: scope,
            expiresAt: expiresAt
        )

        let ownerAuthorization: FreshOwnerAuthorization
        do {
            ownerAuthorization = try await authorizer.authorize(authorizationRequest)
        } catch {
            guard state == .authorizing(request) else {
                throw EnrollmentStateMachineError.invalidTransition
            }
            state = .failed(request.id, .authorizationFailed)
            throw EnrollmentStateMachineError.authorizationFailed
        }

        guard state == .authorizing(request) else {
            throw EnrollmentStateMachineError.invalidTransition
        }
        let age = now().timeIntervalSince(ownerAuthorization.issuedAt)
        guard age >= -Self.maximumAuthorizationFutureSkew,
              age <= Self.maximumAuthorizationAge else {
            state = .failed(request.id, .staleAuthorization)
            throw EnrollmentStateMachineError.staleAuthorization
        }

        do {
            let access = try await grantEngine.mint(
                from: ownerAuthorization,
                expected: authorizationRequest
            )
            guard state == .authorizing(request) else {
                await grantEngine.revoke(access)
                throw EnrollmentStateMachineError.invalidTransition
            }
            let grant = EnrollmentInstallGrant(
                request: request,
                ownerAuthorizationRequest: authorizationRequest,
                accessAuthorization: access
            )
            state = .awaitingInstallation(grant)
            return grant
        } catch let error as EnrollmentStateMachineError {
            throw error
        } catch {
            state = .failed(request.id, .authorizationFailed)
            throw EnrollmentStateMachineError.authorizationFailed
        }
    }

    /// Consumes the capability before returning an installer-ready request.
    /// The caller may suspend only after this method succeeds.
    public func beginInstallation(
        policyGeneration: UInt64,
        scope: OwnerAuthorizationScope
    ) async throws -> EnrollmentInstallGrant {
        guard case .awaitingInstallation(let grant) = state else {
            throw EnrollmentStateMachineError.invalidTransition
        }
        guard grant.ownerAuthorizationRequest.policyGeneration == policyGeneration,
              grant.ownerAuthorizationRequest.scope == scope else {
            state = .failed(grant.enrollmentID, .policyInvalidated)
            await grantEngine.revoke(grant.accessAuthorization)
            throw EnrollmentStateMachineError.policyInvalidated
        }
        state = .installing(grant)
        do {
            try await grantEngine.consume(
                grant.accessAuthorization,
                attemptID: grant.enrollmentID,
                policyGeneration: policyGeneration,
                scope: scope
            )
        } catch {
            state = .failed(grant.enrollmentID, .policyInvalidated)
            throw EnrollmentStateMachineError.policyInvalidated
        }
        guard state == .installing(grant) else {
            throw EnrollmentStateMachineError.invalidTransition
        }
        return grant
    }

    /// Emits `installed` only after the installer provides exact durable and
    /// read-back-verified evidence.
    public func installationDurablyVerified(
        _ receipt: DurableEnrollmentInstallReceipt
    ) throws -> EnrollmentMessageV1 {
        guard case .installing(let grant) = state else {
            throw EnrollmentStateMachineError.invalidTransition
        }
        guard receipt.enrollmentID == grant.enrollmentID,
              receipt.publicKeyFingerprint == grant.request.publicKey.fingerprint,
              receipt.routeIdentity == grant.ownerAuthorizationRequest.scope.routeIdentity else {
            state = .failed(grant.enrollmentID, .installationFailed)
            throw EnrollmentStateMachineError.receiptMismatch
        }
        state = .awaitingRequesterRecord(grant, receipt)
        return .installed(enrollmentID: grant.enrollmentID)
    }

    public func installationFailed() -> EnrollmentMessageV1? {
        guard case .installing(let grant) = state else { return nil }
        state = .failed(grant.enrollmentID, .installationFailed)
        return .failed(enrollmentID: grant.enrollmentID, failure: .installationFailed)
    }

    /// Emits `recorded` only after local identity and ledger persistence.
    public func requesterRecordDurablyCommitted(
        _ receipt: DurableEnrollmentRecordReceipt
    ) throws -> EnrollmentMessageV1 {
        guard case .recordingRequester(let request) = state else {
            throw EnrollmentStateMachineError.invalidTransition
        }
        guard receipt.enrollmentID == request.id,
              receipt.publicKeyFingerprint == request.publicKey.fingerprint else {
            state = .failed(request.id, .persistenceFailed)
            throw EnrollmentStateMachineError.receiptMismatch
        }
        state = .awaitingOriginCompletion(request, receipt)
        return .recorded(enrollmentID: request.id)
    }

    public func requesterPersistenceFailed() -> EnrollmentMessageV1? {
        guard case .recordingRequester(let request) = state else { return nil }
        state = .failed(request.id, .persistenceFailed)
        return .failed(enrollmentID: request.id, failure: .persistenceFailed)
    }

    public func reject() throws -> EnrollmentMessageV1 {
        guard case .awaitingApproval(let request) = state else {
            throw EnrollmentStateMachineError.invalidTransition
        }
        state = .rejected(request.id)
        return .rejected(enrollmentID: request.id)
    }

    /// Lets a platform adapter reject display/routing metadata that is outside
    /// the wire schema but still authorization-sensitive on that platform.
    /// The shared machine owns the terminal transition and wire failure.
    public func adapterValidationFailed() -> EnrollmentMessageV1? {
        guard !state.isTerminal else { return nil }
        guard let id = state.enrollmentID else {
            state = .failed(nil, .protocolViolation)
            return nil
        }
        state = .failed(id, .invalidRequest)
        return .failed(enrollmentID: id, failure: .protocolViolation)
    }

    /// Records a transport loss without letting the platform presentation
    /// become a second protocol authority.
    public func transportFailed() async {
        guard !state.isTerminal else { return }
        let id = state.enrollmentID
        await grantEngine.revokeAll()
        state = .failed(id, .transportFailure)
    }

    /// Reconciles an outbound write failure after the shared machine may have
    /// already entered the logical terminal state represented by that frame.
    /// Delivery failure is the final authority: a rejected/cancelled/completed
    /// message that did not leave the process is not protocol completion.
    public func outboundSendFailed() async {
        let id = state.enrollmentID
        await grantEngine.revokeAll()
        state = .failed(id, .transportFailure)
    }

    /// Handles one decoded peer message and returns the sole response, if any.
    @discardableResult
    public func receive(_ message: EnrollmentMessageV1) async -> EnrollmentMessageV1? {
        guard !state.isTerminal else { return nil }
        switch (state, message) {
        case (.idle, .request(let request)):
            do {
                try request.validate()
                state = .awaitingApproval(request)
            } catch {
                state = .failed(request.id, .invalidRequest)
                return .failed(enrollmentID: request.id, failure: .protocolViolation)
            }
            return nil

        case (.requesting(let request), .installed(let id)) where request.id == id:
            state = .recordingRequester(request)
            return nil

        case (.awaitingRequesterRecord(let grant, _), .recorded(let id))
            where grant.enrollmentID == id:
            let completion = EnrollmentCompletionReceipt(enrollmentID: id, completedAt: now())
            state = .completed(completion)
            return .completed(enrollmentID: id)

        case (.awaitingOriginCompletion(let request, _), .completed(let id))
            where request.id == id:
            state = .completed(EnrollmentCompletionReceipt(enrollmentID: id, completedAt: now()))
            return nil

        case (.requesting(let request), .rejected(let id)) where request.id == id:
            state = .rejected(id)
            return nil

        case (_, .failed(let id, let failure)) where state.enrollmentID == id:
            await grantEngine.revokeAttempt(id)
            state = .failed(id, .remote(failure))
            return nil

        case (_, .cancelled(let id)) where state.enrollmentID == id:
            await grantEngine.revokeAttempt(id)
            state = .cancelled(id)
            return nil

        default:
            let id = state.enrollmentID ?? message.enrollmentID
            if let attemptID = state.enrollmentID {
                await grantEngine.revokeAttempt(attemptID)
            }
            state = .failed(id, .protocolViolation)
            return .failed(enrollmentID: id, failure: .protocolViolation)
        }
    }

    public func cancel() async throws -> EnrollmentMessageV1 {
        guard !state.isTerminal, state != .idle, let id = state.enrollmentID else {
            throw EnrollmentStateMachineError.invalidTransition
        }
        await grantEngine.revokeAttempt(id)
        state = .cancelled(id)
        return .cancelled(enrollmentID: id)
    }

    /// App lock, credential policy mutation, and route mutation all use this
    /// fail-closed invalidation path.
    public func securityPolicyChanged() async -> EnrollmentMessageV1? {
        guard !state.isTerminal, state != .idle else { return nil }
        let id = state.enrollmentID
        await grantEngine.revokeAll()
        state = .failed(id, .policyInvalidated)
        return id.map { .failed(enrollmentID: $0, failure: .authorizationFailed) }
    }

    public func applicationDidLock() async -> EnrollmentMessageV1? {
        await securityPolicyChanged()
    }
}
