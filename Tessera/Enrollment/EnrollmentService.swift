import Foundation
import Observation

/// Peer authentication supplied by the byte transport. Device names are never
/// trust inputs; enrollment accepts either Apple's same-account continuation
/// stream binding or a separately verified SAS transcript.
enum EnrollmentPeerBinding: Equatable, Sendable {
    case appleAccountContinuationStream
    case sasBound(transcriptHash: Data)
    case unbound

    var allowsEnrollment: Bool {
        switch self {
        case .appleAccountContinuationStream:
            return true
        case .sasBound(let transcriptHash):
            return !transcriptHash.isEmpty
        case .unbound:
            return false
        }
    }
}

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

        /// Compares only the immutable, non-secret Host authorization facts.
        /// The public key, peer, flow, rendered endpoint, and host label remain
        /// bound by full GrantSnapshot equality at capability consumption; this
        /// second check detects live policy re-resolution changing the actual
        /// route or credential identity after consent but before mutation.
        func matchesResolvedHost(_ host: Host) -> Bool {
            hostID == host.id
                && route == (host.jumpChain + [host]).map(RouteNode.init(host:))
                && jumpChainBrokenReason == host.jumpChainBrokenReason
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
                jumpChainBrokenReason: host.jumpChainBrokenReason
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
                return "A fresh device-owner authorization is required."
            case .grantSnapshotMismatch:
                return "The host grant changed after device-owner authorization."
            case .invalidAuthorizationBatch:
                return "The host grant selection is invalid."
            case .invalidRequest:
                return "The public-key grant request is invalid."
            case .trackedAccessConflict:
                return "Tracked access for an earlier host route must be resolved before granting this key again."
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
        guard !isClosed else { throw TransportError.closed }
        guard let peer, !peer.isClosed else { throw TransportError.peerUnavailable }
        peer.onBytes?(bytes)
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
                return "Enrollment requires an Apple continuation stream or a SAS-bound transport."
            case .invalidTransition:
                return "Enrollment action is invalid in the current state."
            case .invalidRequest:
                return "Enrollment request is invalid."
            case .transportFailure:
                return "Enrollment transport failed."
            case .authorizationFailed:
                return "Fresh biometric authorization failed."
            case .staleAuthorization:
                return "Biometric authorization was not fresh."
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
    var onGrantReady: ((EnrollmentGrantRequest) -> Void)?

    private let transport: EnrollmentMessageTransport
    private let authorizer: EnrollmentBiometricAuthorizing
    private let grantEngine: SyncDeviceAccessGrantEngine
    private let now: () -> Date
    private var decoder = EnrollmentFrameDecoder()

    init(
        transport: EnrollmentMessageTransport,
        authorizer: EnrollmentBiometricAuthorizing,
        grantEngine: SyncDeviceAccessGrantEngine? = nil,
        now: @escaping () -> Date = Date.init
    ) throws {
        // LOAD-BEARING: NSUserActivity continuation streams are bound by
        // Apple's same-account identity service. If enrollment moves to any
        // other transport, that transport must first prove a verified SAS.
        guard transport.peerBinding.allowsEnrollment else {
            throw ServiceError.peerBindingRequired
        }
        self.transport = transport
        self.authorizer = authorizer
        self.grantEngine = grantEngine ?? SyncDeviceAccessGrantEngine()
        self.now = now
        transport.onBytes = { [weak self] bytes in
            self?.receive(bytes)
        }
        transport.onClose = { [weak self] in
            self?.transportDidClose()
        }
    }

    func request(_ request: EnrollmentRequest) throws {
        guard state == .idle else { throw ServiceError.invalidTransition }
        do {
            try request.validate()
        } catch {
            state = .failed(request.id, .invalidRequest)
            throw ServiceError.invalidRequest
        }

        state = .requesting(request)
        do {
            try send(.request(request))
        } catch {
            state = .failed(request.id, .transportFailure)
            transport.close()
            throw ServiceError.transportFailure
        }
    }

    /// The sole grant boundary. It always performs a new biometric evaluation
    /// and only then emits an installer-ready, public-key-only grant request.
    func approve(
        authorizationHostName: String = "this host",
        grantSnapshot: SyncDeviceAccessGrantEngine.GrantSnapshot
    ) async throws -> EnrollmentGrantRequest {
        guard case .awaitingApproval(let request) = state else {
            throw ServiceError.invalidTransition
        }
        state = .authorizing(request)

        let grantAuthorization: SyncDeviceAccessGrantEngine.Authorization
        do {
            let safeHostName = EnrollmentDisplayMetadata.isSafe(authorizationHostName)
                && !authorizationHostName.isEmpty
                ? authorizationHostName
                : "this host"
            guard grantSnapshot.hostID == request.hostID,
                  grantSnapshot.hostLabel == safeHostName,
                  grantSnapshot.peerDeviceName == request.requestingDeviceName,
                  grantSnapshot.flow == .enrollment,
                  grantSnapshot.publicKey == request.publicKey,
                  grantSnapshot.route.last?.id == request.hostID else {
                throw ServiceError.invalidRequest
            }
            grantAuthorization = try await grantEngine.authorize(
                snapshots: [grantSnapshot]
            ) {
                let evaluatedAuthorization = try await authorizer.authorizeFreshBiometrics(
                    reason: "Authorize \(request.requestingDeviceName) on \(safeHostName)"
                )
                guard state == .authorizing(request) else {
                    throw ServiceError.invalidTransition
                }
                let age = now().timeIntervalSince(evaluatedAuthorization.evaluatedAt)
                guard age >= -Self.maximumAuthorizationFutureSkew,
                      age <= Self.maximumAuthorizationAge else {
                    throw ServiceError.staleAuthorization
                }
            }
        } catch ServiceError.invalidTransition {
            throw ServiceError.invalidTransition
        } catch ServiceError.invalidRequest {
            guard state == .authorizing(request) else {
                throw ServiceError.invalidTransition
            }
            failLocally(
                enrollmentID: request.id,
                failure: .invalidRequest,
                remoteFailure: .protocolViolation
            )
            throw ServiceError.invalidRequest
        } catch ServiceError.staleAuthorization {
            guard state == .authorizing(request) else {
                throw ServiceError.invalidTransition
            }
            failLocally(
                enrollmentID: request.id,
                failure: .staleAuthorization,
                remoteFailure: .authorizationFailed
            )
            throw ServiceError.staleAuthorization
        } catch {
            guard state == .authorizing(request) else {
                throw ServiceError.invalidTransition
            }
            failLocally(
                enrollmentID: request.id,
                failure: .authorizationFailed,
                remoteFailure: .authorizationFailed
            )
            throw ServiceError.authorizationFailed
        }

        guard state == .authorizing(request) else {
            grantEngine.invalidate(grantAuthorization)
            throw ServiceError.invalidTransition
        }

        let grant = EnrollmentGrantRequest(
            request: request,
            accessAuthorization: grantAuthorization
        )
        state = .awaitingInstallation(grant)
        onGrantReady?(grant)
        return grant
    }

    func installationSucceeded() throws {
        guard case .awaitingInstallation(let grant) = state else {
            throw ServiceError.invalidTransition
        }
        if let authorization = grant.accessAuthorization {
            grantEngine.invalidate(authorization)
        }
        state = .awaitingRequesterRecord(grant)
        do {
            try send(.installed(enrollmentID: grant.enrollmentID))
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
        state = .failed(grant.enrollmentID, .installationFailed)
        do {
            try send(.failed(
                enrollmentID: grant.enrollmentID,
                failure: .installationFailed
            ))
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
        state = .awaitingOriginCompletion(request)
        do {
            try send(.recorded(enrollmentID: request.id))
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
        state = .failed(request.id, .persistenceFailed)
        do {
            try send(.failed(
                enrollmentID: request.id,
                failure: .persistenceFailed
            ))
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
        state = .rejected(request.id)
        do {
            try send(.rejected(enrollmentID: request.id))
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
        state = .cancelled(id)
        do {
            try send(.cancelled(enrollmentID: id))
        } catch {
            state = .failed(id, .transportFailure)
            transport.close()
            throw ServiceError.transportFailure
        }
        transport.close()
    }

    private func receive(_ bytes: Data) {
        guard !state.isTerminal else { return }
        do {
            for message in try decoder.append(bytes) {
                handle(message)
                if state.isTerminal { break }
            }
        } catch {
            state = .failed(state.enrollmentID, .protocolViolation)
            transport.close()
        }
    }

    private func handle(_ message: EnrollmentMessage) {
        switch (state, message) {
        case (.idle, .request(let request)):
            do {
                try request.validate()
                state = .awaitingApproval(request)
            } catch {
                failLocally(
                    enrollmentID: request.id,
                    failure: .invalidRequest,
                    remoteFailure: .protocolViolation
                )
            }

        case (.requesting(let request), .installed(let id)) where request.id == id:
            state = .recordingRequester(request)

        case (.awaitingRequesterRecord(let grant), .recorded(let id))
            where grant.enrollmentID == id:
            state = .completed(id)
            do {
                try send(.completed(enrollmentID: id))
            } catch {
                state = .failed(id, .transportFailure)
            }
            transport.close()

        case (.awaitingOriginCompletion(let request), .completed(let id))
            where request.id == id:
            state = .completed(id)
            transport.close()

        case (.requesting(let request), .rejected(let id)) where request.id == id:
            state = .rejected(id)
            transport.close()

        case (.requesting(let request), .cancelled(let id)) where request.id == id:
            state = .cancelled(id)
            transport.close()

        case (_, .failed(let id, let failure)) where state.enrollmentID == id:
            invalidatePendingGrantAuthorization()
            state = .failed(id, .remote(failure))
            transport.close()

        case (_, .cancelled(let id)) where state.enrollmentID == id:
            invalidatePendingGrantAuthorization()
            state = .cancelled(id)
            transport.close()

        default:
            invalidatePendingGrantAuthorization()
            state = .failed(state.enrollmentID ?? message.enrollmentID, .protocolViolation)
            transport.close()
        }
    }

    private func send(_ message: EnrollmentMessage) throws {
        try transport.send(EnrollmentFrameCodec.encode(message))
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
        state = .failed(state.enrollmentID, .transportFailure)
    }

    private func invalidatePendingGrantAuthorization() {
        guard case .awaitingInstallation(let grant) = state,
              let authorization = grant.accessAuthorization else { return }
        grantEngine.invalidate(authorization)
    }
}
