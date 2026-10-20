import Foundation
import Observation
import TesseraEnrollmentCore
import TesseraSessionCore

/// Keep the released app name while sharing the actual peer-authentication
/// claim with the platform-neutral enrollment state machine and Apple stream
/// adapter. Device names never contribute to this binding.
typealias EnrollmentPeerBinding = PeerBinding

@MainActor
protocol EnrollmentMessageTransport: AnyObject {
    var peerBinding: EnrollmentPeerBinding { get }
    var onBytes: ((Data) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func send(_ bytes: Data) throws
    func close()
}

struct EnrollmentFreshBiometricAuthorization: Equatable, Sendable {
    let evaluatedAt: Date

    init(evaluatedAt: Date = Date()) {
        self.evaluatedAt = evaluatedAt
    }
}

@MainActor
protocol EnrollmentBiometricAuthorizing {
    /// Must evaluate a new LocalAuthentication biometric policy each call. A
    /// cached unlock or previously successful context does not satisfy this API.
    func authorizeFreshBiometrics(reason: String) async throws
        -> EnrollmentFreshBiometricAuthorization
}

/// Bridges the released LocalAuthentication boundary into the platform-neutral
/// owner-authorization protocol. The shared machine remains the sole owner of
/// freshness, attempt, scope, and policy validation; the Apple adapter only
/// performs the system biometric evaluation and returns its timestamp.
private final class EnrollmentOwnerAuthorizerAdapter: FreshOwnerAuthorizing,
    @unchecked Sendable {
    private let authorizer: EnrollmentBiometricAuthorizing
    private let lock = NSLock()
    private var authorizationReason = String(localized: "Authorize this device on this host")

    init(authorizer: EnrollmentBiometricAuthorizing) {
        self.authorizer = authorizer
    }

    func setAuthorizationReason(_ reason: String) {
        lock.withLock { authorizationReason = reason }
    }

    func authorize(
        _ request: OwnerAuthorizationRequest
    ) async throws -> FreshOwnerAuthorization {
        let reason = lock.withLock { authorizationReason }
        let evaluated = try await authorizer.authorizeFreshBiometrics(
            reason: reason
        )
        return FreshOwnerAuthorization(
            attemptID: request.attemptID,
            policyGeneration: request.policyGeneration,
            scope: request.scope,
            issuedAt: evaluated.evaluatedAt,
            expiresAt: request.expiresAt
        )
    }
}

/// The single mutation boundary for sync-originated device-access grants.
///
/// Callers can describe only a public key plus local routing metadata. A grant
/// cannot reach the remote installer until this engine has minted an opaque,
/// host-scoped authorization by running the caller's fresh owner-authentication
/// closure. Batch authorizations are consumed once per selected host and are
/// explicitly invalidated when their protocol attempt ends.
@MainActor
final class SyncDeviceAccessGrantEngine {
    struct Authorization: Equatable, Sendable {
        fileprivate let engineID: UUID
        fileprivate let id: UUID

        fileprivate init(engineID: UUID, id: UUID) {
            self.engineID = engineID
            self.id = id
        }
    }

    struct GrantSnapshot: Equatable, Sendable {
        struct RouteNode: Equatable, Sendable {
            let id: UUID
            let name: String
            let user: String
            let address: String
            let port: Int
            let transport: HostTransport
            let storedKeyID: UUID?
            let privateKeyFilename: String?
            let passwordCredentialRevision: HostPasswordCredentialRevision?
            let continuationHostKeyFingerprints: [UUID: String]
            let continuationPeerLabel: String?

            init(host: Host) {
                id = host.id
                name = host.name
                user = host.user
                address = host.address
                port = host.port
                transport = host.transport
                storedKeyID = host.storedKeyID
                privateKeyFilename = host.privateKeyFilename
                passwordCredentialRevision = host.passwordCredentialRevision
                continuationHostKeyFingerprints = host.continuationHostKeyFingerprints
                continuationPeerLabel = host.continuationPeerLabel
            }
        }

        let hostID: UUID
        let hostLabel: String
        let endpoint: String
        let peerDeviceName: String
        let flow: KeySecurityRecord.RemoteAccessFlow
        let publicKey: EnrollmentPublicKey
        /// Outermost bastion first, destination last. Password contents and
        /// private material never enter this snapshot; only credential identity
        /// and revision semantics are bound.
        let route: [RouteNode]
        let jumpChainBrokenReason: String?
        /// Canonical route identity frozen with the rest of the authorization
        /// snapshot. This is also the exact scope consumed by the shared grant.
        let routeIdentity: String

        /// Compares only the immutable, non-secret Host authorization facts.
        /// The public key, peer, flow, rendered endpoint, and host label remain
        /// bound by full GrantSnapshot equality at capability consumption; this
        /// second check detects live policy re-resolution changing the actual
        /// route or credential identity after consent but before mutation.
        func matchesResolvedHost(_ host: Host) -> Bool {
            hostID == host.id
                && route == (host.jumpChain + [host]).map(RouteNode.init(host:))
                && jumpChainBrokenReason == host.jumpChainBrokenReason
                && routeIdentity == RemoteAccessRouteIdentity.value(for: host)
        }
    }

    struct InstallRequest {
        let host: Host
        let hostLabel: String
        let endpoint: String
        let peerDeviceName: String
        let flow: KeySecurityRecord.RemoteAccessFlow
        let publicKey: EnrollmentPublicKey

        var hostID: UUID { host.id }
        var authorizedKeysLine: String { publicKey.authorizedKeysLine }
        var routeIdentity: String { RemoteAccessRouteIdentity.value(for: host) }

        var grantSnapshot: GrantSnapshot {
            GrantSnapshot(
                hostID: host.id,
                hostLabel: hostLabel,
                endpoint: endpoint,
                peerDeviceName: peerDeviceName,
                flow: flow,
                publicKey: publicKey,
                route: (host.jumpChain + [host]).map(GrantSnapshot.RouteNode.init(host:)),
                jumpChainBrokenReason: host.jumpChainBrokenReason,
                routeIdentity: routeIdentity
            )
        }
    }

    enum GrantError: Error, Equatable, LocalizedError {
        case authorizationRequired
        case grantSnapshotMismatch
        case invalidAuthorizationBatch
        case invalidRequest
        case trackedAccessConflict

        var errorDescription: String? {
            switch self {
            case .authorizationRequired:
                return String(localized: "A fresh device-owner authorization is required.")
            case .grantSnapshotMismatch:
                return String(localized: "The host grant changed after device-owner authorization.")
            case .invalidAuthorizationBatch:
                return String(localized: "The host grant selection is invalid.")
            case .invalidRequest:
                return String(localized: "The public-key grant request is invalid.")
            case .trackedAccessConflict:
                return String(localized: "Tracked access for an earlier host route must be resolved before granting this key again.")
            }
        }
    }

    typealias Installer = @MainActor (InstallRequest) async throws -> Void
    typealias LedgerRecorder = @MainActor (InstallRequest) throws -> Void

    private let engineID = UUID()
    private let installer: Installer
    private let recordIntent: LedgerRecorder
    private let recordVerified: LedgerRecorder
    private var remainingSnapshotsByAuthorization: [UUID: [GrantSnapshot]] = [:]

    private(set) var authorizationRequestCount = 0
    private(set) var installationAttemptCount = 0
    var activeAuthorizationCount: Int { remainingSnapshotsByAuthorization.count }

    /// Production boundary. The uncertain audit intent is durable before SSH
    /// begins, and the installer preserves those audit fields while moving the
    /// same row to verified after remote read-back succeeds.
    init(
        metadata: KeySecurityMetadataStore = KeySecurityMetadataStore(),
        installerOverride: Installer? = nil
    ) {
        recordIntent = { request in
            guard !metadata.hasConflictingRemoteInstallation(
                keyID: request.publicKey.id,
                hostID: request.hostID,
                routeIdentity: request.routeIdentity,
                publicKeyFingerprint: request.publicKey.fingerprint,
                authorizedKeysLine: request.authorizedKeysLine,
                direction: .grantedToPeer
            ) else {
                throw GrantError.trackedAccessConflict
            }
            metadata.recordRemoteInstallation(
                keyID: request.publicKey.id,
                hostID: request.hostID,
                hostLabel: request.hostLabel,
                endpoint: request.endpoint,
                routeIdentity: request.routeIdentity,
                peerDeviceName: request.peerDeviceName,
                direction: .grantedToPeer,
                flow: request.flow,
                verificationState: .uncertain,
                publicKeyFingerprint: request.publicKey.fingerprint,
                authorizedKeysLine: request.authorizedKeysLine
            )
        }
        installer = installerOverride ?? { request in
            try await RemoteAuthorizedKeysInstaller.install(
                line: request.authorizedKeysLine,
                keyID: request.publicKey.id,
                on: request.host,
                ledgerContext: RemoteAuthorizedKeysInstaller.LedgerContext(
                    metadata: metadata,
                    keyID: request.publicKey.id,
                    hostID: request.hostID,
                    hostLabel: request.hostLabel,
                    endpoint: request.endpoint,
                    routeIdentity: request.routeIdentity,
                    authorizationSnapshot: request.grantSnapshot,
                    peerDeviceName: request.peerDeviceName,
                    direction: .grantedToPeer,
                    flow: request.flow,
                    publicKeyFingerprint: request.publicKey.fingerprint,
                    authorizedKeysLine: request.authorizedKeysLine,
                    preserveExistingAuditFields: true
                )
            )
        }
        recordVerified = { request in
            metadata.markRemoteInstallationVerificationState(
                .verified,
                keyID: request.publicKey.id,
                hostID: request.hostID,
                hostLabel: request.hostLabel,
                endpoint: request.endpoint,
                routeIdentity: request.routeIdentity,
                publicKeyFingerprint: request.publicKey.fingerprint,
                authorizedKeysLine: request.authorizedKeysLine
            )
        }
    }

    /// Deterministic injection boundary. Tests can observe the engine without
    /// replacing either protocol state machine with a second install path.
    init(
        testInstaller: @escaping Installer,
        intentRecorder: @escaping LedgerRecorder = { _ in },
        verificationRecorder: @escaping LedgerRecorder = { _ in }
    ) {
        installer = testInstaller
        recordIntent = intentRecorder
        recordVerified = verificationRecorder
    }

    func authorize(
        snapshots: [GrantSnapshot],
        authenticating: @MainActor () async throws -> Void
    ) async throws -> Authorization {
        guard Set(snapshots.map(\.hostID)).count == snapshots.count else {
            throw GrantError.invalidAuthorizationBatch
        }
        do {
            for snapshot in snapshots { try snapshot.publicKey.validate() }
        } catch {
            throw GrantError.invalidRequest
        }
        authorizationRequestCount += 1
        try await authenticating()
        try Task.checkCancellation()
        let authorization = Authorization(engineID: engineID, id: UUID())
        remainingSnapshotsByAuthorization[authorization.id] = snapshots
        return authorization
    }

    func install(
        _ request: InstallRequest,
        authorization: Authorization
    ) async throws {
        guard authorization.engineID == engineID,
              var remainingSnapshots = remainingSnapshotsByAuthorization[authorization.id]
        else { throw GrantError.authorizationRequired }
        do {
            try request.publicKey.validate()
        } catch {
            throw GrantError.invalidRequest
        }
        let snapshot = request.grantSnapshot
        guard let authorizedIndex = remainingSnapshots.firstIndex(of: snapshot) else {
            throw GrantError.grantSnapshotMismatch
        }
        remainingSnapshots.remove(at: authorizedIndex)

        // Consume before any suspension so a duplicated callback cannot race a
        // second mutation for the same rendered host selection.
        if remainingSnapshots.isEmpty {
            remainingSnapshotsByAuthorization.removeValue(forKey: authorization.id)
        } else {
            remainingSnapshotsByAuthorization[authorization.id] = remainingSnapshots
        }

        installationAttemptCount += 1
        try recordIntent(request)
        try await installer(request)
        try Task.checkCancellation()
        try recordVerified(request)
    }

    func invalidate(_ authorization: Authorization) {
        guard authorization.engineID == engineID else { return }
        remainingSnapshotsByAuthorization.removeValue(forKey: authorization.id)
    }
}

/// In-process transport used by deterministic requester/origin tests and the
/// simulator harness. Production continuation-stream transport implements the
/// same byte contract.
@MainActor
final class EnrollmentLoopbackTransport: EnrollmentMessageTransport {
    enum TransportError: Error, Equatable {
        case closed
        case peerUnavailable
    }

    let peerBinding: EnrollmentPeerBinding
    var onBytes: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private weak var peer: EnrollmentLoopbackTransport?
    private(set) var isClosed = false
    private var nextSendError: TransportError?

    private init(peerBinding: EnrollmentPeerBinding) {
        self.peerBinding = peerBinding
    }

    static func pair(
        peerBinding: EnrollmentPeerBinding = .appleAccountContinuationStream
    ) -> (EnrollmentLoopbackTransport, EnrollmentLoopbackTransport) {
        let first = EnrollmentLoopbackTransport(peerBinding: peerBinding)
        let second = EnrollmentLoopbackTransport(peerBinding: peerBinding)
        first.peer = second
        second.peer = first
        return (first, second)
    }

    func send(_ bytes: Data) throws {
        if let nextSendError {
            self.nextSendError = nil
            throw nextSendError
        }
        guard !isClosed else { throw TransportError.closed }
        guard let peer, !peer.isClosed else { throw TransportError.peerUnavailable }
        peer.onBytes?(bytes)
    }

    /// Deterministic transport-failure seam for the in-process test transport.
    func failNextSend(with error: TransportError = .peerUnavailable) {
        nextSendError = error
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        let peer = self.peer
        self.peer = nil
        peer?.peerDidClose()
    }

    private func peerDidClose() {
        guard !isClosed else { return }
        isClosed = true
        peer = nil
        onClose?()
    }
}

private struct EnrollmentCoreOperationResult<Value: Sendable>: Sendable {
    let value: Value
    let state: EnrollmentState
}

/// The Apple continuation-stream transport is deliberately synchronous: a
/// write can immediately deliver a peer frame and existing UI/tests observe
/// the resulting state before `send` returns. Shared non-suspending protocol
/// transitions run on their actor and rendezvous here, preserving that released
/// ordering without moving any UI or LocalAuthentication work off MainActor.
private final class EnrollmentCoreBlockingResult<Value: Sendable>:
    @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Value, Error>?

    func resolve(_ result: Result<Value, Error>) {
        condition.lock()
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    func wait() throws -> Value {
        condition.lock()
        while result == nil { condition.wait() }
        let result = self.result!
        condition.unlock()
        return try result.get()
    }
}

@MainActor
@Observable
final class EnrollmentService {
    static let maximumAuthorizationAge: TimeInterval = 10
    static let maximumAuthorizationFutureSkew: TimeInterval = 1

    enum Failure: Equatable, Sendable {
        case peerBindingRequired
        case invalidTransition
        case invalidRequest
        case protocolViolation
        case transportFailure
        case authorizationFailed
        case staleAuthorization
        case installationFailed
        case persistenceFailed
        case remote(EnrollmentRemoteFailure)
    }

    enum ServiceError: Error, Equatable, LocalizedError {
        case peerBindingRequired
        case invalidTransition
        case invalidRequest
        case transportFailure
        case authorizationFailed
        case staleAuthorization

        var errorDescription: String? {
            switch self {
            case .peerBindingRequired:
                return String(localized: "Enrollment requires an Apple continuation stream or a SAS-bound transport.")
            case .invalidTransition:
                return String(localized: "Enrollment action is invalid in the current state.")
            case .invalidRequest:
                return String(localized: "Enrollment request is invalid.")
            case .transportFailure:
                return String(localized: "Enrollment transport failed.")
            case .authorizationFailed:
                return String(localized: "Fresh biometric authorization failed.")
            case .staleAuthorization:
                return String(localized: "Biometric authorization was not fresh.")
            }
        }
    }

    enum State: Equatable, Sendable {
        case idle
        case requesting(EnrollmentRequest)
        case awaitingApproval(EnrollmentRequest)
        case authorizing(EnrollmentRequest)
        case awaitingInstallation(EnrollmentGrantRequest)
        /// Origin has verified authorized_keys and is waiting for the requester
        /// to durably save its identity + ledger.
        case awaitingRequesterRecord(EnrollmentGrantRequest)
        /// Requester has received the install result but has not yet told the
        /// service that local persistence succeeded.
        case recordingRequester(EnrollmentRequest)
        /// Requester sent its durable-record receipt and is waiting for the
        /// origin's final protocol completion acknowledgement.
        case awaitingOriginCompletion(EnrollmentRequest)
        case completed(UUID)
        case rejected(UUID)
        case cancelled(UUID?)
        case failed(UUID?, Failure)

        var enrollmentID: UUID? {
            switch self {
            case .idle: return nil
            case .requesting(let request), .awaitingApproval(let request),
                 .authorizing(let request), .recordingRequester(let request),
                 .awaitingOriginCompletion(let request): return request.id
            case .awaitingInstallation(let grant), .awaitingRequesterRecord(let grant):
                return grant.enrollmentID
            case .completed(let id), .rejected(let id): return id
            case .cancelled(let id), .failed(let id, _): return id
            }
        }

        var isTerminal: Bool {
            switch self {
            case .completed, .rejected, .cancelled, .failed: return true
            default: return false
            }
        }
    }

    private(set) var state: State = .idle
    /// Observable snapshot of the transport-neutral authority. Apple-specific
    /// presentation continues to use `state`, but every transition is accepted
    /// by this shared machine before that presentation state changes.
    private(set) var sharedState: EnrollmentState = .idle
    var onGrantReady: ((EnrollmentGrantRequest) -> Void)?

    private let transport: EnrollmentMessageTransport
    private let grantEngine: SyncDeviceAccessGrantEngine
    private let ownerAuthorizerAdapter: EnrollmentOwnerAuthorizerAdapter
    private let core: EnrollmentStateMachine
    private let now: @Sendable () -> Date
    private var decoder = EnrollmentFrameDecoder()
    private var policyGeneration: UInt64 = 1
    private var approvalScope: OwnerAuthorizationScope?

    init(
        transport: EnrollmentMessageTransport,
        authorizer: EnrollmentBiometricAuthorizing,
        grantEngine: SyncDeviceAccessGrantEngine? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let peerBinding = transport.peerBinding
        guard peerBinding.allowsEnrollment else {
            throw ServiceError.peerBindingRequired
        }
        self.transport = transport
        self.grantEngine = grantEngine ?? SyncDeviceAccessGrantEngine()
        self.now = now
        let ownerAuthorizerAdapter = EnrollmentOwnerAuthorizerAdapter(
            authorizer: authorizer
        )
        self.ownerAuthorizerAdapter = ownerAuthorizerAdapter
        core = try EnrollmentStateMachine(
            peerBinding: peerBinding,
            authorizer: ownerAuthorizerAdapter,
            now: { now() }
        )
        transport.onBytes = { [weak self] bytes in
            self?.receive(bytes)
        }
        transport.onClose = { [weak self] in
            self?.transportDidClose()
        }
    }

    func request(_ request: EnrollmentRequest) throws {
        do {
            let message = try performCore { core in
                try await core.request(request.core)
            }
            state = .requesting(request)
            try send(EnrollmentMessage(core: message))
        } catch EnrollmentStateMachineError.invalidRequest {
            state = .failed(request.id, .invalidRequest)
            throw ServiceError.invalidRequest
        } catch EnrollmentStateMachineError.invalidTransition {
            throw ServiceError.invalidTransition
        } catch ServiceError.transportFailure {
            throw ServiceError.transportFailure
        } catch {
            state = .failed(request.id, .transportFailure)
            transport.close()
            throw ServiceError.transportFailure
        }
    }

    /// The sole grant boundary. It always performs a new biometric evaluation
    /// and only then emits an installer-ready, public-key-only grant request.
    func approve(
        authorizationHostName: String = String(localized: "this host"),
        grantSnapshot: SyncDeviceAccessGrantEngine.GrantSnapshot
    ) async throws -> EnrollmentGrantRequest {
        guard case .awaitingApproval(let request) = state else {
            throw ServiceError.invalidTransition
        }
        let safeHostName = EnrollmentDisplayMetadata.isSafe(authorizationHostName)
            && !authorizationHostName.isEmpty
            ? authorizationHostName
            : String(localized: "this host")
        guard grantSnapshot.hostID == request.hostID,
              grantSnapshot.hostLabel == safeHostName,
              grantSnapshot.peerDeviceName == request.requestingDeviceName,
              grantSnapshot.flow == .enrollment,
              grantSnapshot.publicKey == request.publicKey,
              grantSnapshot.route.last?.id == request.hostID,
              !grantSnapshot.routeIdentity.isEmpty else {
            _ = try? performCore { core in
                await core.adapterValidationFailed()
            }
            failLocally(
                enrollmentID: request.id,
                failure: .invalidRequest,
                remoteFailure: .protocolViolation
            )
            throw ServiceError.invalidRequest
        }

        let scope = OwnerAuthorizationScope(
            routeIdentity: grantSnapshot.routeIdentity,
            hostID: request.hostID,
            publicKeyFingerprint: request.publicKey.fingerprint
        )
        let reason = "Authorize \(request.requestingDeviceName) on \(safeHostName)"
        ownerAuthorizerAdapter.setAuthorizationReason(reason)
        state = .authorizing(request)
        sharedState = .authorizing(request.core)

        do {
            _ = try await core.approve(
                scope: scope,
                policyGeneration: policyGeneration,
                expiresAt: now().addingTimeInterval(Self.maximumAuthorizationAge)
            )
            sharedState = await core.state
            guard state == .authorizing(request) else {
                _ = await core.securityPolicyChanged()
                sharedState = await core.state
                throw ServiceError.invalidTransition
            }
            _ = try await core.beginInstallation(
                policyGeneration: policyGeneration,
                scope: scope
            )
            sharedState = await core.state

            // The shared machine has already performed fresh owner
            // authorization and consumed its one-shot capability. Mint the
            // legacy Apple installer capability without a second biometric;
            // it remains bound to the exact frozen snapshot and can be used
            // only once by the existing SwiftData/SSH audit boundary.
            let grantAuthorization = try await grantEngine.authorize(
                snapshots: [grantSnapshot],
                authenticating: {}
            )
            guard state == .authorizing(request) else {
                grantEngine.invalidate(grantAuthorization)
                _ = await core.securityPolicyChanged()
                sharedState = await core.state
                throw ServiceError.invalidTransition
            }
            approvalScope = scope
            let grant = EnrollmentGrantRequest(
                request: request,
                accessAuthorization: grantAuthorization
            )
            state = .awaitingInstallation(grant)
            onGrantReady?(grant)
            return grant
        } catch EnrollmentStateMachineError.invalidTransition {
            sharedState = await core.state
            throw ServiceError.invalidTransition
        } catch EnrollmentStateMachineError.staleAuthorization {
            sharedState = await core.state
            failLocally(
                enrollmentID: request.id,
                failure: .staleAuthorization,
                remoteFailure: .authorizationFailed
            )
            throw ServiceError.staleAuthorization
        } catch EnrollmentStateMachineError.invalidRequest {
            sharedState = await core.state
            failLocally(
                enrollmentID: request.id,
                failure: .invalidRequest,
                remoteFailure: .protocolViolation
            )
            throw ServiceError.invalidRequest
        } catch ServiceError.invalidTransition {
            throw ServiceError.invalidTransition
        } catch {
            sharedState = await core.state
            guard state == .authorizing(request) else {
                throw ServiceError.invalidTransition
            }
            if case .installing = sharedState {
                _ = await core.installationFailed()
                sharedState = await core.state
            }
            failLocally(
                enrollmentID: request.id,
                failure: .authorizationFailed,
                remoteFailure: .authorizationFailed
            )
            throw ServiceError.authorizationFailed
        }
    }

    func installationSucceeded() throws {
        guard case .awaitingInstallation(let grant) = state else {
            throw ServiceError.invalidTransition
        }
        guard let scope = approvalScope else {
            throw ServiceError.invalidTransition
        }
        if let authorization = grant.accessAuthorization {
            grantEngine.invalidate(authorization)
        }
        do {
            let message = try performCore { core in
                try await core.installationDurablyVerified(
                    DurableEnrollmentInstallReceipt(
                        enrollmentID: grant.enrollmentID,
                        publicKeyFingerprint: grant.publicKey.fingerprint,
                        routeIdentity: scope.routeIdentity,
                        recordedAt: Date()
                    )
                )
            }
            state = .awaitingRequesterRecord(grant)
            try send(EnrollmentMessage(core: message))
        } catch EnrollmentStateMachineError.invalidTransition {
            throw ServiceError.invalidTransition
        } catch {
            state = .failed(grant.enrollmentID, .transportFailure)
            transport.close()
            throw ServiceError.transportFailure
        }
    }

    func installationFailed() throws {
        guard case .awaitingInstallation(let grant) = state else {
            throw ServiceError.invalidTransition
        }
        if let authorization = grant.accessAuthorization {
            grantEngine.invalidate(authorization)
        }
        do {
            guard let message = try performCore({ core in
                await core.installationFailed()
            }) else { throw ServiceError.invalidTransition }
            state = .failed(grant.enrollmentID, .installationFailed)
            try send(EnrollmentMessage(core: message))
        } catch ServiceError.invalidTransition {
            throw ServiceError.invalidTransition
        } catch {
            state = .failed(grant.enrollmentID, .transportFailure)
            transport.close()
            throw ServiceError.transportFailure
        }
        transport.close()
    }

    /// Requester-side durable-persistence boundary. The coordinator calls this
    /// only after SwiftData and the local ledger have both been saved. A final
    /// origin acknowledgement still gates requester completion.
    func requesterPersistenceSucceeded() throws {
        guard case .recordingRequester(let request) = state else {
            throw ServiceError.invalidTransition
        }
        do {
            let message = try performCore { core in
                try await core.requesterRecordDurablyCommitted(
                    DurableEnrollmentRecordReceipt(
                        enrollmentID: request.id,
                        publicKeyFingerprint: request.publicKey.fingerprint,
                        recordedAt: Date()
                    )
                )
            }
            state = .awaitingOriginCompletion(request)
            try send(EnrollmentMessage(core: message))
        } catch EnrollmentStateMachineError.invalidTransition {
            throw ServiceError.invalidTransition
        } catch {
            state = .failed(request.id, .transportFailure)
            transport.close()
            throw ServiceError.transportFailure
        }
    }

    func requesterPersistenceFailed() throws {
        guard case .recordingRequester(let request) = state else {
            throw ServiceError.invalidTransition
        }
        do {
            guard let message = try performCore({ core in
                await core.requesterPersistenceFailed()
            }) else { throw ServiceError.invalidTransition }
            state = .failed(request.id, .persistenceFailed)
            try send(EnrollmentMessage(core: message))
        } catch ServiceError.invalidTransition {
            throw ServiceError.invalidTransition
        } catch {
            state = .failed(request.id, .transportFailure)
            transport.close()
            throw ServiceError.transportFailure
        }
        transport.close()
    }

    func reject() throws {
        guard case .awaitingApproval(let request) = state else {
            throw ServiceError.invalidTransition
        }
        do {
            let message = try performCore { core in
                try await core.reject()
            }
            state = .rejected(request.id)
            try send(EnrollmentMessage(core: message))
        } catch EnrollmentStateMachineError.invalidTransition {
            throw ServiceError.invalidTransition
        } catch {
            state = .failed(request.id, .transportFailure)
            transport.close()
            throw ServiceError.transportFailure
        }
        transport.close()
    }

    func cancel() throws {
        guard !state.isTerminal, state != .idle,
              let id = state.enrollmentID
        else { throw ServiceError.invalidTransition }
        invalidatePendingGrantAuthorization()
        do {
            let message = try performCore { core in
                try await core.cancel()
            }
            state = .cancelled(id)
            try send(EnrollmentMessage(core: message))
        } catch EnrollmentStateMachineError.invalidTransition {
            throw ServiceError.invalidTransition
        } catch {
            state = .failed(id, .transportFailure)
            transport.close()
            throw ServiceError.transportFailure
        }
        transport.close()
    }

    /// App lock always revokes the shared one-shot authorization. The Apple UI
    /// retains its released cancellation presentation and wire message while
    /// the shared authority records the stronger policy-invalidated terminal
    /// state.
    func applicationDidLock() {
        guard !state.isTerminal, state != .idle,
              let id = state.enrollmentID else { return }
        invalidatePendingGrantAuthorization()
        _ = try? performCore { core in
            await core.applicationDidLock()
        }
        state = .cancelled(id)
        try? send(.cancelled(enrollmentID: id))
        transport.close()
    }

    func securityPolicyChanged() {
        guard !state.isTerminal, state != .idle else { return }
        policyGeneration &+= 1
        if policyGeneration == 0 { policyGeneration = 1 }
        invalidatePendingGrantAuthorization()
        do {
            let response = try performCore { core in
                await core.securityPolicyChanged()
            }
            projectSharedState(preserving: state)
            if let response { try send(EnrollmentMessage(core: response)) }
        } catch {
            state = .failed(state.enrollmentID, .transportFailure)
        }
        transport.close()
    }

    private func receive(_ bytes: Data) {
        guard !state.isTerminal else { return }
        do {
            for message in try decoder.append(bytes) {
                handleThroughCore(message)
                if state.isTerminal { break }
            }
        } catch {
            _ = try? performCore { core in
                await core.adapterValidationFailed()
            }
            state = .failed(state.enrollmentID, .protocolViolation)
            transport.close()
        }
    }

    private func handleThroughCore(_ message: EnrollmentMessage) {
        let priorState = state
        do {
            let response = try performCore { core in
                await core.receive(message.core)
            }
            projectSharedState(preserving: priorState)
            if let response {
                try send(EnrollmentMessage(core: response))
            }
            if state.isTerminal { transport.close() }
        } catch ServiceError.transportFailure {
            // `send` has already reconciled both authorities and closed the
            // transport. Preserve transport failure rather than reclassifying
            // it as a peer protocol violation.
        } catch {
            invalidatePendingGrantAuthorization()
            state = .failed(
                priorState.enrollmentID ?? message.enrollmentID,
                .protocolViolation
            )
            transport.close()
        }
    }

    private func projectSharedState(preserving prior: State) {
        switch sharedState {
        case .idle:
            state = .idle
        case .requesting(let request):
            state = .requesting(EnrollmentRequest(core: request))
        case .awaitingApproval(let request):
            state = .awaitingApproval(EnrollmentRequest(core: request))
        case .authorizing(let request):
            state = .authorizing(EnrollmentRequest(core: request))
        case .awaitingInstallation(let sharedGrant), .installing(let sharedGrant):
            if case .awaitingInstallation(let appleGrant) = prior,
               appleGrant.enrollmentID == sharedGrant.enrollmentID {
                state = .awaitingInstallation(appleGrant)
            } else {
                state = .awaitingInstallation(EnrollmentGrantRequest(
                    request: EnrollmentRequest(core: sharedGrant.request)
                ))
            }
        case .awaitingRequesterRecord(let sharedGrant, _):
            if case .awaitingRequesterRecord(let appleGrant) = prior,
               appleGrant.enrollmentID == sharedGrant.enrollmentID {
                state = .awaitingRequesterRecord(appleGrant)
            } else {
                state = .awaitingRequesterRecord(EnrollmentGrantRequest(
                    request: EnrollmentRequest(core: sharedGrant.request)
                ))
            }
        case .recordingRequester(let request):
            state = .recordingRequester(EnrollmentRequest(core: request))
        case .awaitingOriginCompletion(let request, _):
            state = .awaitingOriginCompletion(EnrollmentRequest(core: request))
        case .completed(let receipt):
            state = .completed(receipt.enrollmentID)
        case .rejected(let id):
            state = .rejected(id)
        case .cancelled(let id):
            state = .cancelled(id)
        case .failed(let id, let failure):
            state = .failed(id, appleFailure(for: failure))
        }
    }

    private func appleFailure(for failure: EnrollmentFailure) -> Failure {
        switch failure {
        case .peerBindingRequired: return .peerBindingRequired
        case .invalidRequest: return .invalidRequest
        case .protocolViolation: return .protocolViolation
        case .authorizationFailed: return .authorizationFailed
        case .staleAuthorization: return .staleAuthorization
        case .installationFailed: return .installationFailed
        case .persistenceFailed: return .persistenceFailed
        case .transportFailure: return .transportFailure
        case .policyInvalidated: return .authorizationFailed
        case .remote(let failure):
            return .remote(EnrollmentRemoteFailure(rawValue: failure.rawValue)!)
        }
    }

    private func send(_ message: EnrollmentMessage) throws {
        do {
            try transport.send(EnrollmentFrameCodec.encode(message))
        } catch {
            reconcileOutboundSendFailure()
            throw ServiceError.transportFailure
        }
    }

    /// Makes the shared machine the terminal authority for every failed write,
    /// including writes whose logical transition was already terminal (reject,
    /// cancel, failure, or final completion acknowledgement).
    private func reconcileOutboundSendFailure() {
        let enrollmentID = state.enrollmentID
        invalidatePendingGrantAuthorization()
        _ = try? performCore { core in
            await core.outboundSendFailed()
        }
        state = .failed(enrollmentID, .transportFailure)
        transport.close()
    }

    private func failLocally(
        enrollmentID: UUID,
        failure: Failure,
        remoteFailure: EnrollmentRemoteFailure
    ) {
        state = .failed(enrollmentID, failure)
        try? send(.failed(enrollmentID: enrollmentID, failure: remoteFailure))
        transport.close()
    }

    private func transportDidClose() {
        guard !state.isTerminal else { return }
        invalidatePendingGrantAuthorization()
        _ = try? performCore { core in
            await core.transportFailed()
        }
        state = .failed(state.enrollmentID, .transportFailure)
    }

    private func invalidatePendingGrantAuthorization() {
        guard case .awaitingInstallation(let grant) = state,
              let authorization = grant.accessAuthorization else { return }
        grantEngine.invalidate(authorization)
    }

    private func performCore<Value: Sendable>(
        _ operation: @escaping @Sendable (EnrollmentStateMachine) async throws -> Value
    ) throws -> Value {
        let core = self.core
        let result = EnrollmentCoreBlockingResult<
            EnrollmentCoreOperationResult<Value>
        >()
        Task.detached {
            do {
                let value = try await operation(core)
                result.resolve(.success(EnrollmentCoreOperationResult(
                    value: value,
                    state: await core.state
                )))
            } catch {
                result.resolve(.failure(error))
            }
        }
        do {
            let completed = try result.wait()
            sharedState = completed.state
            return completed.value
        } catch {
            sharedState = readCoreState()
            throw error
        }
    }

    private func readCoreState() -> EnrollmentState {
        let core = self.core
        let result = EnrollmentCoreBlockingResult<EnrollmentState>()
        Task.detached {
            result.resolve(.success(await core.state))
        }
        return (try? result.wait()) ?? sharedState
    }
}
