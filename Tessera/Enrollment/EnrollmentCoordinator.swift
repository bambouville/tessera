import Foundation
import Observation
import SwiftData
import UIKit

/// Device builds keep the enrollment identity in the Secure Enclave. The iOS
/// Simulator has neither that hardware nor a faithful generic-password
/// user-presence ACL, so its production UI uses an unlocked, recoverable
/// Ed25519 software key. This keeps local-discovery and transfer testing honest
/// without weakening the physical-device build, falsely labelling simulator
/// material as hardware-backed, or creating a legacy software P-256 key that
/// Tessera cannot export for recovery.
enum DeviceEnrollmentKeyPolicy {
    static var usesSecureEnclave: Bool {
#if targetEnvironment(simulator)
        false
#else
        true
#endif
    }

    static var publicProtection: EnrollmentPublicKeyProtection {
        usesSecureEnclave ? .secureEnclave : .software
    }

    static var keyAlgorithm: KeyAlgorithm {
        usesSecureEnclave ? .ecdsaP256 : .ed25519
    }

    static var enrollmentAlgorithm: EnrollmentPublicKeyAlgorithm {
        usesSecureEnclave ? .secureEnclaveP256 : .ed25519
    }

    static var keyStoreProtection: KeyStore.KeyProtection {
        .deviceUnlocked
    }

    static var materialProtection: KeyStore.KeyMaterialProtection {
        usesSecureEnclave
            ? .deviceUnlocked(deviceOnly: true)
            : .deviceUnlocked(deviceOnly: false)
    }

    static var boundaryProtection: KeyBoundaryProtection {
        .deviceUnlocked
    }

}

/// One production composition point for the device enrollment identity used by
/// both Handoff enrollment and nearby first-open setup. Keeping key creation,
/// reuse validation, and public metadata together prevents either transport
/// from silently drifting back to a simulator-incompatible Secure Enclave
/// request or misreporting software material as hardware-backed.
@MainActor
enum DeviceEnrollmentKeyFactory {
    enum FactoryError: Error, LocalizedError {
        case invalidPublicKey

        var errorDescription: String? {
            "The local device key has invalid public metadata."
        }
    }

    static func storedKey(
        in context: ModelContext,
        initialOwnerAuthentication: Bool = false,
        metadata: KeySecurityMetadataStore = KeySecurityMetadataStore()
    ) throws -> StoredKey {
        if let existing = try reusableKey(in: context, metadata: metadata) {
            return existing
        }

        let key: StoredKey
        switch DeviceEnrollmentKeyPolicy.keyAlgorithm {
        case .ed25519:
            key = try KeyStore.generateEd25519(
                name: "Tessera device key",
                context: context,
                protection: DeviceEnrollmentKeyPolicy.keyStoreProtection
            )
        case .ecdsaP256:
            key = try KeyStore.generateP256(
                name: "Tessera device key",
                enclave: DeviceEnrollmentKeyPolicy.usesSecureEnclave,
                protection: DeviceEnrollmentKeyPolicy.keyStoreProtection
            )
        case .rsa:
            preconditionFailure("RSA is never a device enrollment key")
        }
        key.requiresBiometric = initialOwnerAuthentication
        try StoredKeyLifecycle.persistCreatedKey(
            key,
            boundary: .generation,
            persistence: .live(context)
        )
        metadata.markBoundaryProtection(
            DeviceEnrollmentKeyPolicy.boundaryProtection,
            for: key.id
        )
        return key
    }

    static func ownerAuthenticationPreference(
        in context: ModelContext,
        defaultPreference: Bool,
        metadata: KeySecurityMetadataStore = KeySecurityMetadataStore()
    ) -> Bool {
        (try? reusableKey(in: context, metadata: metadata))?
            .requiresBiometric ?? defaultPreference
    }

    private static func reusableKey(
        in context: ModelContext,
        metadata: KeySecurityMetadataStore
    ) throws -> StoredKey? {
        let keys = try context.fetch(FetchDescriptor<StoredKey>())
        for existing in keys where
            existing.name == "Tessera device key"
                && existing.algorithm == DeviceEnrollmentKeyPolicy.keyAlgorithm
                && existing.isSecureEnclave == DeviceEnrollmentKeyPolicy.usesSecureEnclave {
            let integrity = KeyStore.privateMaterialIntegrity(
                forKeyID: existing.id,
                algorithm: existing.algorithm,
                isSecureEnclave: existing.isSecureEnclave,
                expectedAuthorizedKeysLine: existing.authorizedKeysLine
            )
            metadata.markMaterialIntegrity(integrity, for: existing.id)
            guard let protection = try? KeyStore.materialProtection(forKeyID: existing.id),
                  isReusable(
                    existing,
                    integrity: integrity,
                    protection: protection,
                    expectedSecureEnclave: DeviceEnrollmentKeyPolicy.usesSecureEnclave,
                    expectedProtection: DeviceEnrollmentKeyPolicy.materialProtection,
                    expectedAlgorithm: DeviceEnrollmentKeyPolicy.keyAlgorithm
                  ) else {
                continue
            }
            metadata.markBoundaryProtection(
                DeviceEnrollmentKeyPolicy.boundaryProtection,
                for: existing.id
            )
            return existing
        }
        return nil
    }

    static func publicKey(from key: StoredKey) throws -> EnrollmentPublicKey {
        let parts = key.authorizedKeysLine.split(
            maxSplits: 2,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard parts.count >= 2,
              let algorithm = EnrollmentPublicKeyAlgorithm(rawValue: String(parts[0]))
        else { throw FactoryError.invalidPublicKey }

        let publicKey = EnrollmentPublicKey(
            id: key.id,
            displayName: key.name,
            algorithm: algorithm,
            blob: String(parts[1]),
            fingerprint: key.canonicalFingerprint,
            protection: key.isSecureEnclave ? .secureEnclave : .software
        )
        try publicKey.validate()
        return publicKey
    }

    static func isReusable(
        _ key: StoredKey,
        integrity: KeyMaterialIntegrity,
        protection: KeyStore.KeyMaterialProtection,
        expectedSecureEnclave: Bool = true,
        expectedBiometric: Bool? = nil,
        expectedProtection: KeyStore.KeyMaterialProtection = .deviceUnlocked(deviceOnly: true),
        expectedAlgorithm: KeyAlgorithm = .ecdsaP256
    ) -> Bool {
        guard key.name == "Tessera device key",
              key.algorithm == expectedAlgorithm,
              key.isSecureEnclave == expectedSecureEnclave,
              expectedBiometric.map({ key.requiresBiometric == $0 }) ?? true,
              protection == expectedProtection else {
            return false
        }
        switch protection {
        case .userPresence:
            return integrity == .valid || integrity == .authenticationRequired
        case .deviceUnlocked:
            return integrity == .valid
        case .missing:
            return false
        }
    }
}

enum DeviceEnrollmentKeyProvisioningError: LocalizedError, Equatable {
    case authorizationCancelled
    case authorizationUnavailable(String)
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationCancelled:
            return "Device authentication was cancelled. The device key was not shared."
        case .authorizationUnavailable(let reason):
            return Self.message(
                reason,
                fallback: "Device owner authentication is unavailable."
            )
        case .authorizationFailed(let reason):
            return Self.message(reason, fallback: "Device authentication failed.")
        }
    }

    private static func message(_ reason: String, fallback: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

/// Provisions the local key used by nearby bootstrap and Handoff enrollment as
/// one ordered authorization transaction. When the user's effective default
/// requires owner authentication, Tessera obtains fresh consent before the
/// device public key can leave this device. Keeping owner authentication out of
/// the immutable Secure Enclave ACL lets the user change that policy later
/// without replacing the SSH key.
@MainActor
enum DeviceEnrollmentKeyProvisioner {
    typealias Authorizer = @MainActor @Sendable (String) async throws -> Void
    typealias KeyProvider = @MainActor @Sendable () throws -> StoredKey

    static let authorizationReason =
        "Authorize Tessera to protect and use this device key for SSH connections."

    static func requiresFreshAuthorization(
        globalPreference: Bool,
        keyPreference: Bool
    ) -> Bool {
        globalPreference && keyPreference
    }

    static func provision(
        requiresOwnerAuthentication: Bool,
        authorize: @escaping Authorizer = { reason in
            try await liveAuthorize(reason: reason)
        },
        makeKey: @escaping KeyProvider
    ) async throws -> StoredKey {
        if requiresOwnerAuthentication {
            try await authorize(authorizationReason)
            try Task.checkCancellation()
        }

        if requiresOwnerAuthentication {
            DiagnosticLogStore.appendKeys(
                "device-enrollment fresh owner-authentication completed"
            )
        }
        return try makeKey()
    }

    private static func liveAuthorize(reason: String) async throws {
        switch await BiometricGate.evaluateForKeyUse(reason: reason) {
        case .authenticated:
            return
        case .userCancelled:
            throw DeviceEnrollmentKeyProvisioningError.authorizationCancelled
        case .unavailable(let reason):
            throw DeviceEnrollmentKeyProvisioningError.authorizationUnavailable(reason)
        case .failed(let reason):
            throw DeviceEnrollmentKeyProvisioningError.authorizationFailed(reason)
        }
    }
}

@MainActor
struct EnrollmentLiveBiometricAuthorizer: EnrollmentBiometricAuthorizing {
    enum AuthorizationError: Error, LocalizedError {
        case denied(String)

        var errorDescription: String? {
            switch self {
            case .denied(let reason): return reason
            }
        }
    }

    func authorizeFreshBiometrics(
        reason: String
    ) async throws -> EnrollmentFreshBiometricAuthorization {
        switch await BiometricGate.evaluate(reason: reason) {
        case .authenticated:
            return EnrollmentFreshBiometricAuthorization()
        case .userCancelled:
            throw AuthorizationError.denied("Authorization was cancelled.")
        case .unavailable(let reason), .failed(let reason):
            throw AuthorizationError.denied(reason)
        }
    }
}

/// Bridges the pure enrollment state machine to Handoff streams, key
/// lifecycle, the remote installer, and both-sided audit ledgers.
///
/// This object never opens an SSH connection until the origin user explicitly
/// approves the fully rendered request. The request wire type contains only a
/// public key. Passwords remain exclusively in the origin device's Host DTO.
@MainActor
@Observable
final class EnrollmentCoordinator {
    private struct RequesterLedgerSnapshot {
        let keyID: UUID
        let hostID: UUID
        let hostLabel: String
        let endpoint: String
        let routeIdentity: String
        let peerDeviceName: String
        let publicKeyFingerprint: String
        let authorizedKeysLine: String
    }

    enum Role: Equatable, Sendable {
        case requester
        case origin
    }

    enum Phase: Equatable, Sendable {
        case idle
        case openingStreams(hostName: String)
        case requesting(EnrollmentRequest)
        case awaitingApproval(EnrollmentRequest)
        case authorizing(EnrollmentRequest)
        case installing(EnrollmentGrantRequest)
        case syncingRecords(hostName: String)
        case completed(hostName: String)
        case rejected
        case cancelled
        case failed(String)

        var isPresented: Bool {
            if case .idle = self { return false }
            return true
        }
    }

    enum CoordinatorError: Error, LocalizedError {
        case continuationStreamsUnavailable(String)
        case hostMismatch
        case missingHost
        case requestNotReady
        case existingAccessConflict

        var errorDescription: String? {
            switch self {
            case .continuationStreamsUnavailable(let reason):
                return "Could not open the secure continuation channel: \(reason)"
            case .hostMismatch:
                return "The peer requested a different host than the focused session."
            case .missingHost:
                return "The enrollment host is no longer available."
            case .requestNotReady:
                return "The enrollment request is not ready for this action."
            case .existingAccessConflict:
                return "This key has tracked access for an earlier version of the host route. Revoke or resolve that access before requesting a new grant."
            }
        }
    }

    typealias DeviceKeyProvider = @MainActor (_ context: ModelContext) async throws -> StoredKey

    private(set) var role: Role?
    private(set) var phase: Phase = .idle
    private(set) var serviceState: EnrollmentService.State = .idle
    /// Local, authoritative consent target. Peer-supplied host labels are never
    /// used to describe where an origin-side mutation will occur.
    private(set) var approvalHostName: String?
    private(set) var approvalEndpoint: String?
    @ObservationIgnored var onRequesterEnrollmentCompleted: ((PersistedHost) -> Void)?

    private var service: EnrollmentService?
    private var transport: EnrollmentContinuationStreamTransport?
    private var operationTask: Task<Void, Never>?
    private var requesterHost: PersistedHost?
    private var requesterAuthorizationHostID: UUID?
    private var requesterKey: StoredKey?
    private var requesterPeerName = "other device"
    private var requesterContext: ModelContext?
    private var requesterCompletionPersisted = false
    private var requesterCompletionDelivered = false
    /// `getContinuationStreams` completes asynchronously and cannot be
    /// cancelled. Bind each callback to the exact requester attempt that
    /// created it so a delayed callback cannot replace a newer transport.
    private var requesterStreamAttempt: UInt64 = 0
    private var pendingRequesterStreamAttempt: UInt64?
    /// Only an intent created by this attempt may be discarded when the peer
    /// proves that no installation occurred. A pre-existing uncertain entry may
    /// describe an older ambiguous attempt and must survive a later rejection.
    private var requesterIntentCreatedForCurrentAttempt = false
    private var requesterLedgerSnapshot: RequesterLedgerSnapshot?
    private var originHost: Host?
    private let metadata: KeySecurityMetadataStore
    private let grantEngine: SyncDeviceAccessGrantEngine
    private let authorizer: EnrollmentBiometricAuthorizing
    private let deviceKeyProvider: DeviceKeyProvider?

    init(
        metadata: KeySecurityMetadataStore = KeySecurityMetadataStore(),
        authorizer: EnrollmentBiometricAuthorizing? = nil,
        deviceKeyProvider: DeviceKeyProvider? = nil,
        grantEngine: SyncDeviceAccessGrantEngine? = nil
    ) {
        self.metadata = metadata
        self.authorizer = authorizer ?? EnrollmentLiveBiometricAuthorizer()
        self.deviceKeyProvider = deviceKeyProvider
        self.grantEngine = grantEngine ?? SyncDeviceAccessGrantEngine(metadata: metadata)
    }

    /// Requester entry point, called only from the explicit credential-card
    /// button after a system Handoff continuation has been selected.
    func requestAuthorization(
        through activity: NSUserActivity,
        for host: PersistedHost,
        authorizationHostID: UUID? = nil,
        peerDeviceName: String = "other device",
        in modelContext: ModelContext,
        defaultKeyUseOwnerAuthentication: Bool
    ) {
        reset(closePeer: true)
        role = .requester
        requesterHost = host
        requesterAuthorizationHostID = authorizationHostID ?? host.id
        requesterPeerName = peerDeviceName
        requesterContext = modelContext
        requesterCompletionPersisted = false
        requesterCompletionDelivered = false
        phase = .openingStreams(hostName: displayName(for: host))

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let key = try await self.deviceEnrollmentKey(
                    in: modelContext,
                    defaultOwnerAuthentication: defaultKeyUseOwnerAuthentication
                )
                try Task.checkCancellation()
                guard self.role == .requester,
                      self.requesterHost === host else { return }
                let publicKey = try DeviceEnrollmentKeyFactory.publicKey(from: key)
                self.requesterKey = key
                self.requesterStreamAttempt &+= 1
                let streamAttempt = self.requesterStreamAttempt
                self.pendingRequesterStreamAttempt = streamAttempt

                // Apple peer binding is the authorization boundary for this transport.
                // No endpoint, device name, or descriptor field substitutes for it.
                activity.getContinuationStreams { [weak self] input, output, error in
                    Task { @MainActor in
                        guard let self,
                              self.pendingRequesterStreamAttempt == streamAttempt,
                              self.role == .requester,
                              let host = self.requesterHost else {
                            input?.close()
                            output?.close()
                            return
                        }
                        // Consume before constructing a transport. Even if a malformed
                        // activity invokes its completion twice, only the first callback
                        // can affect this coordinator.
                        self.pendingRequesterStreamAttempt = nil
                        guard let input, let output else {
                            self.fail(CoordinatorError.continuationStreamsUnavailable(
                                error?.localizedDescription ?? "The peer did not provide streams."
                            ))
                            return
                        }
                        self.beginRequester(
                            input: input,
                            output: output,
                            host: host,
                            publicKey: publicKey
                        )
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.role == .requester else { return }
                self.fail(error)
            }
        }
    }

    /// Origin entry point for `ActivityBroadcaster.onContinuationStreams`.
    /// `host` must be the currently focused authenticated session advertised by
    /// that broadcaster; request host IDs are checked before approval.
    func acceptOriginStreams(
        input: InputStream,
        output: OutputStream,
        focusedHost host: Host
    ) {
        reset(closePeer: true)
        role = .origin
        originHost = host
        approvalHostName = displayName(for: host)
        approvalEndpoint = "\(host.user)@\(host.address):\(host.port)"
        do {
            let stream = EnrollmentContinuationStreamTransport(input: input, output: output)
            let service = try EnrollmentService(
                transport: stream,
                authorizer: authorizer,
                grantEngine: grantEngine
            )
            self.transport = stream
            self.service = service
            stream.onServiceEvent = { [weak self] in self?.reconcileServiceState() }
            stream.start()
            reconcileServiceState()
        } catch {
            input.close()
            output.close()
            fail(error)
        }
    }

    /// Explicit origin approval. Fresh owner authentication occurs in
    /// `EnrollmentService.approve()` before the installer can be reached.
    func approve() {
        guard role == .origin,
              let service,
              let originHost,
              case .awaitingApproval(let request) = service.state
        else {
            fail(CoordinatorError.requestNotReady)
            return
        }
        guard request.hostID == originHost.id else {
            try? service.reject()
            fail(CoordinatorError.hostMismatch)
            return
        }
        // Freeze the complete non-secret connection semantics before owner
        // authorization. This exact Host value is retained for installation;
        // no mutable persistence is re-resolved after consent.
        let installRequest = SyncDeviceAccessGrantEngine.InstallRequest(
            host: originHost,
            hostLabel: displayName(for: originHost),
            endpoint: "\(originHost.address):\(originHost.port)",
            peerDeviceName: request.requestingDeviceName,
            flow: .enrollment,
            publicKey: request.publicKey
        )

        operationTask?.cancel()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let grant = try await service.approve(
                    authorizationHostName: installRequest.hostLabel,
                    grantSnapshot: installRequest.grantSnapshot
                )
                self.reconcileServiceState()
                try Task.checkCancellation()
                guard let accessAuthorization = grant.accessAuthorization else {
                    throw SyncDeviceAccessGrantEngine.GrantError.authorizationRequired
                }
                defer { self.grantEngine.invalidate(accessAuthorization) }
                try await self.grantEngine.install(
                    installRequest,
                    authorization: accessAuthorization
                )
                try Task.checkCancellation()
                try service.installationSucceeded()
                self.reconcileServiceState()
            } catch is CancellationError {
                if !service.state.isTerminal { try? service.cancel() }
                self.reconcileServiceState()
            } catch {
                if case .awaitingInstallation = service.state {
                    try? service.installationFailed()
                }
                self.fail(error)
            }
        }
    }

    func reject() {
        guard role == .origin, let service else {
            cancel()
            return
        }
        do {
            try service.reject()
            reconcileServiceState()
        } catch {
            fail(error)
        }
    }

    func cancel() {
        invalidateRequesterStreamAttempt()
        operationTask?.cancel()
        operationTask = nil
        if let service, !service.state.isTerminal, service.state != .idle {
            try? service.cancel()
        }
        transport?.close()
        service = nil
        transport = nil
        originHost = nil
        requesterHost = nil
        requesterKey = nil
        requesterContext = nil
        requesterCompletionPersisted = false
        requesterCompletionDelivered = false
        approvalHostName = nil
        approvalEndpoint = nil
        role = nil
        serviceState = .cancelled(nil)
        phase = .cancelled
    }

    /// App lifecycle hook: an enrollment channel never survives backgrounding.
    func applicationDidEnterBackground() {
        guard phase.isPresented else { return }
        cancel()
    }

    /// App-lock hook. Lock is a stronger boundary than scene lifecycle: an
    /// enrollment already past SSH connection establishment must still have its
    /// installer task and continuation streams cancelled synchronously.
    func applicationDidLock() {
        guard phase.isPresented else { return }
        cancel()
    }

    func dismissTerminalState() {
        switch phase {
        case .completed, .rejected, .cancelled, .failed:
            reset(closePeer: true)
        default:
            break
        }
    }

    private func beginRequester(
        input: InputStream,
        output: OutputStream,
        host: PersistedHost,
        publicKey: EnrollmentPublicKey
    ) {
        do {
            let stream = EnrollmentContinuationStreamTransport(input: input, output: output)
            let service = try EnrollmentService(
                transport: stream,
                authorizer: authorizer,
                grantEngine: grantEngine
            )
            self.transport = stream
            self.service = service
            stream.onServiceEvent = { [weak self] in self?.reconcileServiceState() }
            stream.start()

            let request = EnrollmentRequest(
                hostID: requesterAuthorizationHostID ?? host.id,
                hostName: displayName(for: host),
                requestingDeviceName: UIDevice.current.name,
                publicKey: publicKey
            )
            // Validate locally before creating audit state. Once the request is
            // sent, any transport loss or cancellation is ambiguous: the origin
            // may already have installed the key. Persist an uncertain requester
            // ledger intent before that first causally relevant send.
            try request.validate()
            try stageRequesterIntentIfNeeded(
                host: host,
                key: publicKey
            )
            try service.request(request)
            reconcileServiceState()
        } catch {
            input.close()
            output.close()
            fail(error)
        }
    }

    private func reconcileServiceState() {
        guard let service else { return }
        serviceState = service.state
        switch service.state {
        case .idle:
            phase = .idle
        case .requesting(let request):
            phase = .requesting(request)
        case .awaitingApproval(let request):
            guard let host = originHost, request.hostID == host.id else {
                try? service.reject()
                fail(CoordinatorError.hostMismatch)
                return
            }
            phase = .awaitingApproval(request)
        case .authorizing(let request):
            phase = .authorizing(request)
        case .awaitingInstallation(let grant):
            phase = .installing(grant)
        case .awaitingRequesterRecord(let grant):
            phase = .syncingRecords(hostName: localHostName(fallback: grant.hostName))
        case .recordingRequester:
            guard role == .requester, !requesterCompletionPersisted else {
                phase = .failed("Enrollment persistence changed state unexpectedly.")
                return
            }
            do {
                try finishRequesterEnrollment()
                requesterCompletionPersisted = true
                try service.requesterPersistenceSucceeded()
                reconcileServiceState()
            } catch {
                if case .recordingRequester = service.state {
                    try? service.requesterPersistenceFailed()
                }
                serviceState = service.state
                phase = .failed(error.localizedDescription)
            }
            return
        case .awaitingOriginCompletion(let request):
            phase = .syncingRecords(hostName: localHostName(fallback: request.hostName))
        case .completed:
            if role == .requester {
                guard requesterCompletionPersisted else {
                    phase = .failed("The origin completed before local enrollment was recorded.")
                    return
                }
                if !requesterCompletionDelivered, let requesterHost {
                    requesterCompletionDelivered = true
                    onRequesterEnrollmentCompleted?(requesterHost)
                }
            }
            let hostName = requesterHost.map(displayName(for:))
                ?? originHost.map(displayName(for:))
                ?? "host"
            phase = .completed(hostName: hostName)
        case .rejected:
            if role == .requester {
                discardRequesterIntentWhenNoInstallWasProven()
            }
            phase = .rejected
        case .cancelled:
            phase = .cancelled
        case .failed(_, let failure):
            if role == .requester,
               failure == .remote(.authorizationFailed) {
                // Origin-side authorization failure occurs before the grant
                // engine can reach its installer, so this protocol result is as
                // conclusive as an explicit rejection.
                discardRequesterIntentWhenNoInstallWasProven()
            }
            phase = .failed(message(for: failure))
        }
    }

    private func finishRequesterEnrollment() throws {
        guard let context = requesterContext,
              let host = requesterHost,
              let key = requesterKey
        else { throw CoordinatorError.missingHost }

        let identities = try context.fetch(FetchDescriptor<Identity>())
        let identity: Identity
        if let existing = identities.first(where: {
            if case .key(let keyID) = $0.credentialMode { return keyID == key.id }
            return false
        }) {
            identity = existing
        } else {
            identity = Identity(
                name: "\(UIDevice.current.name) device key",
                user: host.effectiveUser,
                credentialMode: .key(key.id)
            )
            context.insert(identity)
        }
        host.identity = identity
        try context.save()

        let publicKey = try DeviceEnrollmentKeyFactory.publicKey(from: key)
        guard let snapshot = requesterLedgerSnapshot,
              snapshot.keyID == key.id,
              snapshot.hostID == host.id,
              snapshot.publicKeyFingerprint == publicKey.fingerprint,
              snapshot.authorizedKeysLine == publicKey.authorizedKeysLine
        else { throw CoordinatorError.missingHost }
        guard !metadata.hasConflictingRemoteInstallation(
            keyID: snapshot.keyID,
            hostID: snapshot.hostID,
            routeIdentity: snapshot.routeIdentity,
            publicKeyFingerprint: snapshot.publicKeyFingerprint,
            authorizedKeysLine: snapshot.authorizedKeysLine,
            direction: .receivedFromPeer
        ) else {
            throw CoordinatorError.existingAccessConflict
        }
        metadata.recordRemoteInstallation(
            keyID: snapshot.keyID,
            hostID: snapshot.hostID,
            hostLabel: snapshot.hostLabel,
            endpoint: snapshot.endpoint,
            routeIdentity: snapshot.routeIdentity,
            peerDeviceName: snapshot.peerDeviceName,
            direction: .receivedFromPeer,
            flow: .enrollment,
            publicKeyFingerprint: snapshot.publicKeyFingerprint,
            authorizedKeysLine: snapshot.authorizedKeysLine
        )
        requesterIntentCreatedForCurrentAttempt = false
    }

    private func stageRequesterIntentIfNeeded(
        host: PersistedHost,
        key: EnrollmentPublicKey
    ) throws {
        let snapshot = RequesterLedgerSnapshot(
            keyID: key.id,
            hostID: host.id,
            hostLabel: displayName(for: host),
            endpoint: "\(host.address):\(host.port)",
            routeIdentity: RemoteAccessRouteIdentity.value(for: Host(from: host)),
            peerDeviceName: requesterPeerName,
            publicKeyFingerprint: key.fingerprint,
            authorizedKeysLine: key.authorizedKeysLine
        )
        requesterLedgerSnapshot = snapshot
        let existing = metadata.record(for: key.id).remoteInstallations.first {
            $0.hostID == host.id
        }
        guard let existing else {
            metadata.recordRemoteInstallation(
                keyID: snapshot.keyID,
                hostID: snapshot.hostID,
                hostLabel: snapshot.hostLabel,
                endpoint: snapshot.endpoint,
                routeIdentity: snapshot.routeIdentity,
                peerDeviceName: snapshot.peerDeviceName,
                direction: .receivedFromPeer,
                flow: .enrollment,
                verificationState: .uncertain,
                publicKeyFingerprint: snapshot.publicKeyFingerprint,
                authorizedKeysLine: snapshot.authorizedKeysLine
            )
            requesterIntentCreatedForCurrentAttempt = true
            return
        }
        guard existing.routeIdentity == snapshot.routeIdentity,
              existing.publicKeyFingerprint == snapshot.publicKeyFingerprint,
              existing.authorizedKeysLine == snapshot.authorizedKeysLine,
              existing.direction == .receivedFromPeer
        else {
            requesterLedgerSnapshot = nil
            throw CoordinatorError.existingAccessConflict
        }
        // A verified placement already covers this host, while an uncertain
        // placement may belong to a previous interrupted attempt. Neither is
        // safe for this attempt to delete on rejection.
        requesterIntentCreatedForCurrentAttempt = false
    }

    private func discardRequesterIntentWhenNoInstallWasProven() {
        guard requesterIntentCreatedForCurrentAttempt,
              let snapshot = requesterLedgerSnapshot
        else { return }
        metadata.discardRemoteInstallationIntent(
            keyID: snapshot.keyID,
            hostID: snapshot.hostID,
            routeIdentity: snapshot.routeIdentity,
            publicKeyFingerprint: snapshot.publicKeyFingerprint,
            authorizedKeysLine: snapshot.authorizedKeysLine,
            direction: .receivedFromPeer,
            flow: .enrollment
        )
        requesterIntentCreatedForCurrentAttempt = false
    }

    private func deviceEnrollmentKey(
        in context: ModelContext,
        defaultOwnerAuthentication: Bool
    ) async throws -> StoredKey {
        if let deviceKeyProvider {
            return try await deviceKeyProvider(context)
        }
        let keyPreference = DeviceEnrollmentKeyFactory
            .ownerAuthenticationPreference(
                in: context,
                defaultPreference: defaultOwnerAuthentication,
                metadata: metadata
            )
        return try await DeviceEnrollmentKeyProvisioner.provision(
            requiresOwnerAuthentication: DeviceEnrollmentKeyProvisioner
                .requiresFreshAuthorization(
                    globalPreference: defaultOwnerAuthentication,
                    keyPreference: keyPreference
                ),
            makeKey: {
                try DeviceEnrollmentKeyFactory.storedKey(
                    in: context,
                    initialOwnerAuthentication: defaultOwnerAuthentication,
                    metadata: self.metadata
                )
            }
        )
    }

    static func isReusableDeviceEnrollmentKey(
        _ key: StoredKey,
        integrity: KeyMaterialIntegrity,
        protection: KeyStore.KeyMaterialProtection,
        expectedSecureEnclave: Bool = true,
        expectedBiometric: Bool? = nil,
        expectedProtection: KeyStore.KeyMaterialProtection = .deviceUnlocked(deviceOnly: true),
        expectedAlgorithm: KeyAlgorithm = .ecdsaP256
    ) -> Bool {
        DeviceEnrollmentKeyFactory.isReusable(
            key,
            integrity: integrity,
            protection: protection,
            expectedSecureEnclave: expectedSecureEnclave,
            expectedBiometric: expectedBiometric,
            expectedProtection: expectedProtection,
            expectedAlgorithm: expectedAlgorithm
        )
    }

    private func fail(_ error: Error) {
        invalidateRequesterStreamAttempt()
        let message = error.localizedDescription
        DiagnosticLogStore.appendApp("enrollment result=failed error='\(message)'")
        transport?.close()
        service = nil
        transport = nil
        serviceState = .failed(serviceState.enrollmentID, .transportFailure)
        phase = .failed(message)
    }

    private func reset(closePeer: Bool) {
        invalidateRequesterStreamAttempt()
        operationTask?.cancel()
        operationTask = nil
        if closePeer { transport?.close() }
        service = nil
        transport = nil
        requesterHost = nil
        requesterAuthorizationHostID = nil
        requesterKey = nil
        requesterContext = nil
        requesterCompletionPersisted = false
        requesterCompletionDelivered = false
        requesterIntentCreatedForCurrentAttempt = false
        requesterLedgerSnapshot = nil
        requesterPeerName = "other device"
        originHost = nil
        approvalHostName = nil
        approvalEndpoint = nil
        role = nil
        serviceState = .idle
        phase = .idle
    }

    private func invalidateRequesterStreamAttempt() {
        requesterStreamAttempt &+= 1
        pendingRequesterStreamAttempt = nil
    }

    private func displayName(for host: PersistedHost) -> String {
        let trimmed = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host.address : trimmed
    }

    private func displayName(for host: Host) -> String {
        let trimmed = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host.address : trimmed
    }

    private func localHostName(fallback: String) -> String {
        requesterHost.map(displayName(for:))
            ?? originHost.map(displayName(for:))
            ?? fallback
    }

    private func message(for failure: EnrollmentService.Failure) -> String {
        switch failure {
        case .peerBindingRequired:
            return "The continuation channel could not prove its Apple peer binding."
        case .invalidTransition:
            return "Enrollment changed state unexpectedly."
        case .invalidRequest:
            return "The peer sent an invalid enrollment request."
        case .protocolViolation:
            return "The peer sent an invalid enrollment message."
        case .transportFailure:
            return "The continuation channel closed before enrollment completed."
        case .authorizationFailed:
            return "Device-owner authorization failed."
        case .staleAuthorization:
            return "Device-owner authorization expired before installation began."
        case .installationFailed:
            return "The public key could not be installed on the host."
        case .persistenceFailed:
            return "The requesting device could not record the authorization."
        case .remote(let remote):
            switch remote {
            case .authorizationFailed:
                return "The other device did not authorize this request."
            case .installationFailed:
                return "The other device could not install this public key."
            case .persistenceFailed:
                return "The other device could not record this authorization."
            case .protocolViolation:
                return "The other device rejected the enrollment protocol."
            }
        }
    }
}
