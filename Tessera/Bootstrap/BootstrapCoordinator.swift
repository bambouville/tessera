import Foundation
import Observation
import SwiftData

enum BootstrapBiometricDecision: Equatable, Sendable {
    case authenticated
    case cancelled
    case unavailable(String)
    case failed(String)
}

struct BootstrapRecipientKey: Equatable, Sendable {
    let storedKeyID: UUID
    let publicKey: EnrollmentPublicKey

    init(storedKeyID: UUID, publicKey: EnrollmentPublicKey) throws {
        guard storedKeyID == publicKey.id else {
            throw BootstrapCoordinatorError.invalidRecipientKey
        }
        try publicKey.validate()
        self.storedKeyID = storedKeyID
        self.publicKey = publicKey
    }
}

struct BootstrapCredentialChecklistItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let hostName: String
    let authenticationHint: BootstrapAuthenticationHint

    var isGrantEligible: Bool { authenticationHint == .publicKey }

    var actionLabel: String {
        switch authenticationHint {
        case .publicKey: return "authorize this device"
        case .password: return "password on first connect"
        case .none: return "credential on first connect"
        }
    }

    var detail: String {
        switch authenticationHint {
        case .publicKey:
            return "Install the other device's public key using this device's existing access."
        case .password:
            return "Excluded. Passwords never transfer and will be requested on first connect."
        case .none:
            return "Excluded because this device has no reusable authenticated path."
        }
    }
}

extension BootstrapHostGrantStatus {
    /// Receipt rows that still need a local credential or a retry keep an
    /// explicit path back to host configuration. In particular, password and
    /// credential-less hosts are expected exclusions, not dead ends.
    var offersConfigureLater: Bool {
        switch self {
        case .installed:
            return false
        case .failed, .notSelected, .rejectedImport, .excludedAuthentication:
            return true
        }
    }
}

struct BootstrapGrantSelectionState: Equatable, Sendable {
    let peerDisplayName: String
    let code: String
    let publicKeyName: String
    let publicKeyFingerprint: String
    let publicKeyProtection: EnrollmentPublicKeyProtection
    let checklist: [BootstrapCredentialChecklistItem]
    var selectedHostIDs: Set<UUID>
    var selectedOptionalTransfers: Set<BootstrapOptionalTransfer>

    var selectedCount: Int { selectedHostIDs.count }
}

struct BootstrapGrantInstallRequest: Equatable, Sendable {
    let hostID: UUID
    let hostName: String
    let endpoint: String
    let peerDeviceName: String
    let publicKeyID: UUID
    let publicKeyFingerprint: String
    let authorizedKeysLine: String
    let host: Host
}

struct BootstrapRecipientGrantRecord: Equatable, Sendable {
    let hostID: UUID
    let hostName: String
    let endpoint: String
    let routeIdentity: String
    let peerDeviceName: String
    let recipientKey: BootstrapRecipientKey
}

struct BootstrapFlowReceipt: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        case sent(hostCount: Int)
        case received(BootstrapImportReceipt)
    }

    let direction: Direction
    let peerDisplayName: String
    let recipientPublicKey: EnrollmentPublicKey
    let credentialChecklist: [BootstrapCredentialChecklistItem]
    let grantReceipt: BootstrapGrantBatchReceipt
}

enum BootstrapFlowPhase: Equatable, Sendable {
    case inactive
    case welcome
    case browsing
    case offering
    case negotiating(role: NearbyHandshakeRole, peerDisplayName: String)
    case compareCode(role: NearbyHandshakeRole, peerDisplayName: String, code: String)
    case waitingForPeerCode(role: NearbyHandshakeRole, peerDisplayName: String, code: String)
    case notifyingCodeRejection(peerDisplayName: String)
    case awaitingRecipientPublicKey(peerDisplayName: String, code: String)
    case authorizingRecipientKey
    case selectingGrants(BootstrapGrantSelectionState)
    case waitingForOriginApproval(peerDisplayName: String, code: String)
    case authorizingOrigin(BootstrapGrantSelectionState)
    case transferring(role: NearbyHandshakeRole, peerDisplayName: String)
    case completed(BootstrapFlowReceipt)
    case failed(message: String)
}

enum BootstrapCoordinatorError: Error, Equatable, LocalizedError {
    case notConfigured
    case invalidState
    case peerConnectionAlreadyActive
    case handshakeTimedOut
    case authorizationFailed(String)
    case invalidRecipientKey
    case missingHost(UUID)
    case selectedHostChanged(UUID)
    case rejectedImportedHost(UUID)
    case completionAcknowledgementMismatch

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Nearby setup is not ready yet."
        case .invalidState:
            return "Nearby setup is no longer at that step."
        case .peerConnectionAlreadyActive:
            return "A nearby setup connection is already active."
        case .handshakeTimedOut:
            return "The nearby device did not respond in time. Try nearby setup again."
        case .authorizationFailed(let reason):
            return reason
        case .invalidRecipientKey:
            return "The recipient device key is invalid."
        case .missingHost:
            return "A selected host is no longer available."
        case .selectedHostChanged:
            return "A selected host or its jump route changed. Review the grant selection again."
        case .rejectedImportedHost:
            return "A granted host conflicted with local setup and was not imported."
        case .completionAcknowledgementMismatch:
            return "The other device did not acknowledge the final grant receipt."
        }
    }
}

/// Device-local completion marker for the first-open choice. It is deliberately
/// outside the portable settings allowlist: inheriting a setup on another
/// device must never mark this device's welcome flow complete.
struct BootstrapFirstOpenStore {
    private static let key = "tessera.nearbyBootstrap.completed.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isComplete: Bool { defaults.bool(forKey: Self.key) }

    func markComplete() {
        defaults.set(true, forKey: Self.key)
    }
}

/// Foreground-only, explicit nearby-bootstrap coordinator. Constructing,
/// configuring, and presenting it never start discovery or connect to a peer.
/// The recipient sends only a validated public key after local SAS confirmation
/// and, for a protected physical-device key, fresh owner authentication.
/// The origin performs one fresh biometric authorization for the selected host
/// batch, sends the manifest only after that authorization, installs each grant,
/// and keeps the encrypted connection alive through a receipt acknowledgement.
@MainActor
@Observable
final class BootstrapCoordinator {
    typealias BiometricAuthorizer = @MainActor @Sendable (String) async -> BootstrapBiometricDecision
    typealias ManifestExporter = @MainActor @Sendable () async throws -> BootstrapManifest
    typealias ManifestImporter = @MainActor @Sendable (
        BootstrapManifest,
        String
    ) async throws -> BootstrapImportReceipt
    typealias RecipientKeyProvider = @MainActor @Sendable () async throws -> BootstrapRecipientKey
    typealias GrantInstaller = @MainActor @Sendable (
        BootstrapGrantInstallRequest
    ) async throws -> Void
    typealias OriginGrantRecorder = @MainActor @Sendable (
        BootstrapGrantInstallRequest
    ) throws -> Void
    typealias GrantHostResolver = @MainActor @Sendable (
        BootstrapGrantInstallRequest
    ) throws -> Host
    typealias RecipientGrantRecorder = @MainActor @Sendable (
        BootstrapRecipientGrantRecord
    ) throws -> Void
    typealias RecipientGrantIntentRecorder = @MainActor @Sendable (
        BootstrapRecipientGrantRecord
    ) throws -> Void
    typealias RecipientGrantIntentRemover = @MainActor @Sendable (
        BootstrapRecipientGrantRecord
    ) -> Void
    typealias InterruptedImportProvider = @MainActor @Sendable () -> Bool
    typealias ImportCompletionRecorder = @MainActor @Sendable (
        BootstrapManifest
    ) throws -> Void
    typealias ImportPromotionRecorder = @MainActor @Sendable (
        BootstrapManifest
    ) throws -> Void
    typealias InterruptedImportAbandoner = @MainActor @Sendable () -> Void

    private(set) var phase: BootstrapFlowPhase = .inactive
    private(set) var discoveredPeers: [NearbyDiscoveredPeer] = []
    private(set) var peerRejectionNotice: String?
    /// Public-key transcript for the active attempt. This contains no secret
    /// material and lets deterministic tests prove that retry created a fresh
    /// ephemeral-key exchange rather than merely repainting the old SAS.
    private(set) var activeHandshakeTranscriptHash: Data?

    var isPresented: Bool { phase != .inactive }

    private struct PendingOriginBatch {
        let manifest: BootstrapManifest
        let publicKey: EnrollmentPublicKey
        var selection: BootstrapGrantSelectionState
    }

    private enum AttemptIntent: Equatable {
        case receive(displayName: String)
        case send(displayName: String)
    }

    private let service: NearbyTransferService
    private let firstOpenStore: BootstrapFirstOpenStore
    private let biometricAuthorizer: BiometricAuthorizer
    private let handshakeTimeoutNanoseconds: UInt64
    private var manifestExporter: ManifestExporter?
    private var manifestImporter: ManifestImporter?
    private var recipientKeyProvider: RecipientKeyProvider?
    private let grantEngine: SyncDeviceAccessGrantEngine
    private var grantHostResolver: GrantHostResolver?
    private var recipientGrantRecorder: RecipientGrantRecorder?
    private var recipientGrantIntentRecorder: RecipientGrantIntentRecorder?
    private var recipientGrantIntentRemover: RecipientGrantIntentRemover?
    private var interruptedImportProvider: InterruptedImportProvider
    private var importCompletionRecorder: ImportCompletionRecorder
    private var importPromotionRecorder: ImportPromotionRecorder
    private var interruptedImportAbandoner: InterruptedImportAbandoner

    private var connection: (any NearbyByteConnection)?
    private var session: NearbyManifestTransferSession?
    private var role: NearbyHandshakeRole?
    private var peerDisplayName = "Nearby Tessera device"
    private var recipientKey: BootstrapRecipientKey?
    private var pendingOriginBatch: PendingOriginBatch?
    private var attemptIntent: AttemptIntent?
    private var failedAttemptIntent: AttemptIntent?
    private var worker: Task<Void, Never>?
    private var sasDecisionSender: Task<Void, Never>?
    private var handshakeDeadlineTask: Task<Void, Never>?
    private var localSASMatched = false
    private var localSASDecisionSent = false
    private var localSASRejected = false
    private var peerSASMatched = false
    private var generation: UInt64 = 0

    convenience init() {
        self.init(
            service: NearbyTransferService(),
            firstOpenStore: BootstrapFirstOpenStore(),
            biometricAuthorizer: { reason in
                await BootstrapCoordinator.liveBiometricAuthorizer(reason: reason)
            }
        )
    }

    init(
        service: NearbyTransferService,
        firstOpenStore: BootstrapFirstOpenStore = BootstrapFirstOpenStore(),
        biometricAuthorizer: @escaping BiometricAuthorizer,
        manifestExporter: ManifestExporter? = nil,
        manifestImporter: ManifestImporter? = nil,
        recipientKeyProvider: RecipientKeyProvider? = nil,
        grantEngine: SyncDeviceAccessGrantEngine? = nil,
        grantHostResolver: GrantHostResolver? = nil,
        grantInstaller: GrantInstaller? = nil,
        originGrantRecorder: OriginGrantRecorder? = nil,
        recipientGrantRecorder: RecipientGrantRecorder? = nil,
        recipientGrantIntentRecorder: RecipientGrantIntentRecorder? = nil,
        recipientGrantIntentRemover: RecipientGrantIntentRemover? = nil,
        handshakeTimeoutNanoseconds: UInt64 = 30_000_000_000,
        interruptedImportProvider: @escaping InterruptedImportProvider = { false },
        importCompletionRecorder: @escaping ImportCompletionRecorder = { _ in },
        importPromotionRecorder: @escaping ImportPromotionRecorder = { _ in },
        interruptedImportAbandoner: @escaping InterruptedImportAbandoner = {}
    ) {
        self.service = service
        self.firstOpenStore = firstOpenStore
        self.biometricAuthorizer = biometricAuthorizer
        self.handshakeTimeoutNanoseconds = handshakeTimeoutNanoseconds
        self.manifestExporter = manifestExporter
        self.manifestImporter = manifestImporter
        self.recipientKeyProvider = recipientKeyProvider
        self.grantHostResolver = grantHostResolver
        if let grantEngine {
            self.grantEngine = grantEngine
        } else if let grantInstaller {
            self.grantEngine = SyncDeviceAccessGrantEngine(
                testInstaller: { request in
                    try await grantInstaller(Self.legacyInstallRequest(from: request))
                },
                verificationRecorder: { request in
                    try originGrantRecorder?(Self.legacyInstallRequest(from: request))
                }
            )
        } else {
            self.grantEngine = SyncDeviceAccessGrantEngine()
        }
        self.recipientGrantRecorder = recipientGrantRecorder
        self.recipientGrantIntentRecorder = recipientGrantIntentRecorder
        self.recipientGrantIntentRemover = recipientGrantIntentRemover
        self.interruptedImportProvider = interruptedImportProvider
        self.importCompletionRecorder = importCompletionRecorder
        self.importPromotionRecorder = importPromotionRecorder
        self.interruptedImportAbandoner = interruptedImportAbandoner
        service.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// Binds production persistence, device-key lifecycle, installer,
    /// and audit ledgers. Reconfiguration remains side-effect free: key creation
    /// is deferred until the user chooses either a fresh local setup or confirms
    /// the nearby-transfer SAS. Bindings already injected — by tests or the
    /// DEBUG harness — are left alone; only the importer always rebinds so it
    /// tracks the latest `admissionHandler`.
    func configure(
        modelContext: ModelContext,
        appearance: AppearancePreferences,
        admissionHandler: @escaping BootstrapAdmissionHandler = { _ in .proceedFull },
        finalAdmissionValidator: @escaping BootstrapFinalAdmissionValidator = { _ in true }
    ) {
        manifestExporter = manifestExporter ?? {
            try await BootstrapManifestAdapter.export(
                from: modelContext,
                appearance: appearance
            )
        }
        manifestImporter = { manifest, peerName in
            while true {
                let plan = try BootstrapManifestAdapter.plannedInsertions(
                    manifest,
                    to: modelContext
                )
                let response = await admissionHandler(plan)
                do {
                    switch response {
                    case .proceedFull:
                        return try await BootstrapManifestAdapter.apply(
                            manifest,
                            fromPeer: peerName,
                            to: modelContext,
                            appearance: appearance,
                            finalAdmissionValidator: finalAdmissionValidator
                        )
                    case .restrictTo(let hostIDs):
                        return try await BootstrapManifestAdapter.apply(
                            manifest,
                            fromPeer: peerName,
                            to: modelContext,
                            appearance: appearance,
                            restrictTo: hostIDs,
                            finalAdmissionValidator: finalAdmissionValidator
                        )
                    case .cancel:
                        throw CancellationError()
                    }
                } catch BootstrapImportAdmissionError.stateChanged {
                    // Host count or access changed during the sheet. Re-plan
                    // and let the same admission handler decide from live state.
                    continue
                }
            }
        }
        recipientKeyProvider = recipientKeyProvider ?? {
            let defaultPreference = appearance.requireBiometricForKeyUse
            let keyPreference = DeviceEnrollmentKeyFactory
                .ownerAuthenticationPreference(
                    in: modelContext,
                    defaultPreference: defaultPreference
                )
            let stored = try await DeviceEnrollmentKeyProvisioner.provision(
                requiresOwnerAuthentication: DeviceEnrollmentKeyProvisioner
                    .requiresFreshAuthorization(
                        globalPreference: defaultPreference,
                        keyPreference: keyPreference
                    ),
                makeKey: {
                    try DeviceEnrollmentKeyFactory.storedKey(
                        in: modelContext,
                        initialOwnerAuthentication: defaultPreference
                    )
                }
            )
            return try BootstrapRecipientKey(
                storedKeyID: stored.id,
                publicKey: DeviceEnrollmentKeyFactory.publicKey(from: stored)
            )
        }
        grantHostResolver = grantHostResolver ?? { request in
            let hosts = try modelContext.fetch(FetchDescriptor<PersistedHost>())
            guard let persisted = hosts.first(where: { $0.id == request.hostID }) else {
                throw BootstrapCoordinatorError.missingHost(request.hostID)
            }
            return Host(from: persisted)
        }
        recipientGrantRecorder = recipientGrantRecorder ?? { record in
            try BootstrapCoordinator.liveRecordRecipientGrant(
                record,
                in: modelContext
            )
        }
        recipientGrantIntentRecorder = recipientGrantIntentRecorder ?? { record in
            KeySecurityMetadataStore().recordRemoteInstallation(
                keyID: record.recipientKey.storedKeyID,
                hostID: record.hostID,
                hostLabel: record.hostName,
                endpoint: record.endpoint,
                routeIdentity: record.routeIdentity,
                peerDeviceName: record.peerDeviceName,
                direction: .receivedFromPeer,
                flow: .bootstrap,
                verificationState: .uncertain,
                publicKeyFingerprint: record.recipientKey.publicKey.fingerprint,
                authorizedKeysLine: record.recipientKey.publicKey.authorizedKeysLine
            )
        }
        recipientGrantIntentRemover = recipientGrantIntentRemover ?? { record in
            KeySecurityMetadataStore().discardRemoteInstallationIntent(
                keyID: record.recipientKey.storedKeyID,
                hostID: record.hostID,
                routeIdentity: record.routeIdentity,
                publicKeyFingerprint: record.recipientKey.publicKey.fingerprint,
                authorizedKeysLine: record.recipientKey.publicKey.authorizedKeysLine,
                direction: .receivedFromPeer,
                flow: .bootstrap
            )
        }
        interruptedImportProvider = {
            BootstrapImportProvenanceStore().hasInterruptedImport
        }
        importCompletionRecorder = { manifest in
            try BootstrapImportProvenanceStore().markComplete(manifest)
        }
        importPromotionRecorder = { manifest in
            try BootstrapManifestAdapter.refreshImportProvenance(
                for: manifest,
                in: modelContext
            )
        }
        interruptedImportAbandoner = {
            BootstrapImportProvenanceStore().clearAll()
        }
    }

    func beginIfFirstOpen(hasHosts: Bool) {
        guard phase == .inactive,
              (!hasHosts || interruptedImportProvider()),
              !firstOpenStore.isComplete else { return }
        phase = .welcome
    }

    func setUpAsNew() {
        guard phase == .welcome else { return }
        guard let recipientKeyProvider else {
            fail(BootstrapCoordinatorError.notConfigured)
            return
        }
        let operationGeneration = generation
        phase = .authorizingRecipientKey
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                // Use the same provider as nearby inheritance so both
                // first-open choices share authorization, integrity, and
                // owner-presence policy semantics.
                _ = try await recipientKeyProvider()
                try Task.checkCancellation()
                guard operationGeneration == generation else { return }
                interruptedImportAbandoner()
                firstOpenStore.markComplete()
                worker = nil
                phase = .inactive
            } catch is CancellationError {
                return
            } catch {
                guard operationGeneration == generation else { return }
                fail(error)
            }
        }
    }

    func startRecipientDiscovery(displayName: String = NearbyDeviceLabel.serviceFallback) {
        guard phase == .welcome || phase == .inactive || isFailure else { return }
        resetAttempt(keepingPresentation: true)
        attemptIntent = .receive(displayName: displayName)
        do {
            try requireConfigured()
            try service.startBrowsing()
            phase = .browsing
        } catch {
            fail(error)
        }
    }

    func startOffering(displayName: String) {
        guard phase == .inactive || isFailure else { return }
        resetAttempt(keepingPresentation: true)
        attemptIntent = .send(displayName: displayName)
        do {
            try requireConfigured()
            try service.startOffering(displayName: displayName)
            phase = .offering
        } catch {
            fail(error)
        }
    }

    func selectPeer(_ peer: NearbyDiscoveredPeer) {
        guard phase == .browsing,
              connection == nil,
              case .receive(let displayName) = attemptIntent
        else { return }
        do {
            beginHandshake(
                connection: try service.connect(to: peer),
                role: .recipient,
                peerDisplayName: peer.displayName,
                localDisplayName: displayName
            )
        } catch {
            fail(error)
        }
    }

    func confirmCodeMatches() {
        guard case .compareCode(let role, let peerName, let code) = phase,
              let session,
              let connection,
              !localSASMatched,
              !localSASRejected
        else { return }
        do {
            let decisionFrame = try session.sealSASDecision(matches: true)
            localSASMatched = true
            phase = .waitingForPeerCode(
                role: role,
                peerDisplayName: peerName,
                code: code
            )
            sendSASDecision(
                decisionFrame,
                connection: connection,
                role: role,
                peerName: peerName,
                code: code,
                matches: true
            )
        } catch {
            fail(error)
        }
    }

    func rejectCode() {
        guard case .compareCode(let role, let peerName, let code) = phase,
              let session,
              let connection,
              !localSASMatched,
              !localSASRejected
        else { return }
        do {
            let decisionFrame = try session.sealSASDecision(matches: false)
            localSASRejected = true
            phase = .notifyingCodeRejection(peerDisplayName: peerName)
            sendSASDecision(
                decisionFrame,
                connection: connection,
                role: role,
                peerName: peerName,
                code: code,
                matches: false
            )
        } catch {
            fail(error)
        }
    }

    func acknowledgePeerRejection() {
        peerRejectionNotice = nil
    }

    func setGrantSelected(hostID: UUID, selected: Bool) {
        guard case .selectingGrants(var selection) = phase,
              selection.checklist.contains(where: { $0.id == hostID && $0.isGrantEligible }),
              var pendingOriginBatch
        else { return }
        if selected {
            selection.selectedHostIDs.insert(hostID)
        } else {
            selection.selectedHostIDs.remove(hostID)
        }
        pendingOriginBatch.selection = selection
        self.pendingOriginBatch = pendingOriginBatch
        phase = .selectingGrants(selection)
    }

    func setOptionalTransfer(
        _ transfer: BootstrapOptionalTransfer,
        selected: Bool
    ) {
        guard case .selectingGrants(var selection) = phase,
              var pendingOriginBatch
        else { return }
        if selected {
            selection.selectedOptionalTransfers.insert(transfer)
        } else {
            selection.selectedOptionalTransfers.remove(transfer)
        }
        pendingOriginBatch.selection = selection
        self.pendingOriginBatch = pendingOriginBatch
        phase = .selectingGrants(selection)
    }

    /// One explicit action authorizes the already-rendered selected batch. It
    /// causes exactly one fresh biometric evaluation; per-host installers never
    /// prompt the coordinator for a second batch authorization. The resulting
    /// host-scoped capability comes from the same grant engine as enrollment.
    func approveOriginTransfer() {
        guard case .selectingGrants(let selection) = phase,
              role == .origin,
              session != nil,
              connection != nil,
              let pendingOriginBatch,
              pendingOriginBatch.selection == selection
        else { return }

        let selectedRequests: [SyncDeviceAccessGrantEngine.InstallRequest]
        let approvedManifest: ApprovedBootstrapManifest
        do {
            selectedRequests = try pendingOriginInstallRequests(for: selection)
            // Freeze the exact optional-data selection rendered by the approval
            // screen before Face ID or any other suspension point.
            approvedManifest = try ApprovedBootstrapManifest(
                exportedManifest: pendingOriginBatch.manifest,
                selectedOptionalTransfers: selection.selectedOptionalTransfers
            )
        } catch {
            fail(error)
            return
        }
        let selectedRequestsByHostID = Dictionary(
            uniqueKeysWithValues: selectedRequests.map { ($0.hostID, $0) }
        )

        phase = .authorizingOrigin(selection)
        let operationGeneration = generation
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await grantEngine.authorize(
                    snapshots: selectedRequests.map(\.grantSnapshot)
                ) {
                    let decision = await self.biometricAuthorizer(
                        "Approve setup and \(selection.selectedCount) host key grant\(selection.selectedCount == 1 ? "" : "s") with code \(selection.code)"
                    )
                    switch decision {
                    case .authenticated:
                        return
                    case .cancelled:
                        throw BootstrapCoordinatorError.authorizationFailed(
                            "Nearby setup was not approved."
                        )
                    case .unavailable(let reason), .failed(let reason):
                        throw BootstrapCoordinatorError.authorizationFailed(reason)
                    }
                }
                guard !Task.isCancelled, operationGeneration == generation else {
                    grantEngine.invalidate(authorization)
                    return
                }
                await finishOriginAuthorization(
                    authorization,
                    approvedManifest: approvedManifest,
                    selectedRequestsByHostID: selectedRequestsByHostID,
                    operationGeneration: operationGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                try? session?.recordOriginAuthorization(.denied)
                guard operationGeneration == generation else { return }
                fail(error)
            }
        }
    }

    func stopForBackground() {
        guard phase != .inactive else { return }
        cancel()
    }

    func cancel() {
        resetAttempt(keepingPresentation: false)
        phase = .inactive
    }

    func finish() {
        if case .completed(let receipt) = phase, case .received = receipt.direction {
            firstOpenStore.markComplete()
        }
        resetAttempt(keepingPresentation: false)
        phase = .inactive
    }

    func retry() {
        guard isFailure else { return }
        switch failedAttemptIntent {
        case .receive(let displayName):
            startRecipientDiscovery(displayName: displayName)
        case .send(let displayName):
            startOffering(displayName: displayName)
        case nil:
            phase = .welcome
        }
    }

    private static func liveBiometricAuthorizer(
        reason: String
    ) async -> BootstrapBiometricDecision {
        switch await BiometricGate.evaluate(reason: reason) {
        case .authenticated: return .authenticated
        case .userCancelled: return .cancelled
        case .unavailable(let reason): return .unavailable(reason)
        case .failed(let reason): return .failed(reason)
        }
    }

    static func liveRecipientKey(
        in modelContext: ModelContext,
        metadata: KeySecurityMetadataStore = KeySecurityMetadataStore()
    ) throws -> BootstrapRecipientKey {
        let stored = try DeviceEnrollmentKeyFactory.storedKey(
            in: modelContext,
            metadata: metadata
        )
        return try BootstrapRecipientKey(
            storedKeyID: stored.id,
            publicKey: DeviceEnrollmentKeyFactory.publicKey(from: stored)
        )
    }

    private static func liveRecordRecipientGrant(
        _ record: BootstrapRecipientGrantRecord,
        in modelContext: ModelContext
    ) throws {
        let hosts = try modelContext.fetch(FetchDescriptor<PersistedHost>())
        guard let host = hosts.first(where: { $0.id == record.hostID }) else {
            throw BootstrapCoordinatorError.missingHost(record.hostID)
        }
        let identities = try modelContext.fetch(FetchDescriptor<Identity>())
        let identity = identities.first {
            guard $0.user == host.effectiveUser,
                  case .key(let keyID) = $0.credentialMode
            else { return false }
            return keyID == record.recipientKey.storedKeyID
        } ?? {
            let created = Identity(
                name: "Tessera device key · \(host.effectiveUser)",
                user: host.effectiveUser,
                credentialMode: .key(record.recipientKey.storedKeyID)
            )
            modelContext.insert(created)
            return created
        }()
        host.identity = identity
        try modelContext.save()

        KeySecurityMetadataStore().recordRemoteInstallation(
            keyID: record.recipientKey.storedKeyID,
            hostID: record.hostID,
            hostLabel: record.hostName,
            endpoint: record.endpoint,
            routeIdentity: record.routeIdentity,
            peerDeviceName: record.peerDeviceName,
            direction: .receivedFromPeer,
            flow: .bootstrap,
            publicKeyFingerprint: record.recipientKey.publicKey.fingerprint,
            authorizedKeysLine: record.recipientKey.publicKey.authorizedKeysLine
        )
    }

    private var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func requireConfigured() throws {
        guard manifestExporter != nil,
              manifestImporter != nil,
              recipientKeyProvider != nil,
              recipientGrantRecorder != nil,
              recipientGrantIntentRecorder != nil,
              recipientGrantIntentRemover != nil
        else { throw BootstrapCoordinatorError.notConfigured }
    }

    private func handle(_ event: NearbyTransferServiceEvent) {
        switch event {
        case .peersChanged(let peers):
            guard phase == .browsing else { return }
            discoveredPeers = peers
        case .incomingConnection(let incoming):
            guard phase == .offering,
                  connection == nil,
                  case .send(let displayName) = attemptIntent
            else {
                Task { await incoming.cancel() }
                return
            }
            beginHandshake(
                connection: incoming,
                role: .origin,
                peerDisplayName: NearbyDeviceLabel.generic,
                localDisplayName: displayName
            )
        case .failed(let error):
            fail(error)
        }
    }

    private func beginHandshake(
        connection: any NearbyByteConnection,
        role: NearbyHandshakeRole,
        peerDisplayName: String,
        localDisplayName: String
    ) {
        guard self.connection == nil else {
            Task { await connection.cancel() }
            fail(BootstrapCoordinatorError.peerConnectionAlreadyActive)
            return
        }
        self.connection = connection
        self.role = role
        self.peerDisplayName = peerDisplayName
        phase = .negotiating(role: role, peerDisplayName: peerDisplayName)
        generation &+= 1
        let operationGeneration = generation
        let handshakeTimeoutNanoseconds = self.handshakeTimeoutNanoseconds
        handshakeDeadlineTask?.cancel()
        handshakeDeadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: handshakeTimeoutNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  operationGeneration == generation,
                  case .negotiating = phase
            else { return }
            fail(BootstrapCoordinatorError.handshakeTimedOut)
        }

        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let attempt = NearbyHandshake.begin(
                    role: role,
                    displayName: localDisplayName
                )
                try await connection.start()
                try Task.checkCancellation()
                let session: NearbyManifestTransferSession
                switch role {
                case .origin:
                    let commitmentData = try await connection.receive(maximumSize: NearbyBootstrapProtocol.maximumHandshakeMessageSize)
                    try Task.checkCancellation()
                    let commitment = try NearbyHandshakeCommitment.decode(commitmentData)
                    try await connection.send(attempt.hello.encoded())
                    let recipientHelloData = try await connection.receive(maximumSize: NearbyBootstrapProtocol.maximumHandshakeMessageSize)
                    try Task.checkCancellation()
                    let recipientHello = try NearbyHandshakeHello.decode(recipientHelloData)
                    session = try NearbyHandshake.completeOrigin(
                        attempt,
                        with: recipientHello,
                        verifying: commitment
                    )
                case .recipient:
                    let commitment = try NearbyHandshake.recipientCommitment(for: attempt)
                    try await connection.send(commitment.encoded())
                    let originHelloData = try await connection.receive(maximumSize: NearbyBootstrapProtocol.maximumHandshakeMessageSize)
                    try Task.checkCancellation()
                    let originHello = try NearbyHandshakeHello.decode(originHelloData)
                    try await connection.send(attempt.hello.encoded())
                    session = try NearbyHandshake.completeRecipient(
                        attempt,
                        with: originHello
                    )
                }
                guard operationGeneration == generation else { return }
                let resolvedPeerDisplayName = session.peerDisplayName
                    ?? NearbyDeviceLabel.sanitized(peerDisplayName)
                self.session = session
                activeHandshakeTranscriptHash = session.transcriptHash
                self.peerDisplayName = resolvedPeerDisplayName
                handshakeDeadlineTask?.cancel()
                handshakeDeadlineTask = nil
                worker = nil
                phase = .compareCode(
                    role: role,
                    peerDisplayName: resolvedPeerDisplayName,
                    code: session.sas.displayValue
                )
                listenForPeerSASDecision(
                    connection: connection,
                    session: session,
                    role: role,
                    peerName: resolvedPeerDisplayName,
                    code: session.sas.displayValue,
                    operationGeneration: operationGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                guard operationGeneration == generation else { return }
                fail(error)
            }
        }
    }

    /// The comparison screen remains an active protocol state. Listening here
    /// lets a passive peer learn that the other user rejected the code without
    /// first tapping one of its own comparison buttons.
    private func listenForPeerSASDecision(
        connection: any NearbyByteConnection,
        session: NearbyManifestTransferSession,
        role: NearbyHandshakeRole,
        peerName: String,
        code: String,
        operationGeneration: UInt64
    ) {
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let frame = try await connection.receive(maximumSize: 65_536)
                try Task.checkCancellation()
                let matches = try session.openPeerSASDecision(frame)
                guard operationGeneration == generation else { return }
                worker = nil
                guard matches else {
                    failFromPeerRejection(peerName: peerName)
                    return
                }
                peerSASMatched = true
                continueAfterMutualSAS(
                    role: role,
                    peerName: peerName,
                    code: code
                )
            } catch is CancellationError {
                return
            } catch {
                guard operationGeneration == generation,
                      !localSASRejected else { return }
                fail(error)
            }
        }
    }

    private func sendSASDecision(
        _ frame: Data,
        connection: any NearbyByteConnection,
        role: NearbyHandshakeRole,
        peerName: String,
        code: String,
        matches: Bool
    ) {
        let operationGeneration = generation
        sasDecisionSender = Task { [weak self] in
            guard let self else { return }
            do {
                try await connection.send(frame)
                guard operationGeneration == generation else { return }
                sasDecisionSender = nil
                if matches {
                    localSASDecisionSent = true
                    continueAfterMutualSAS(
                        role: role,
                        peerName: peerName,
                        code: code
                    )
                } else {
                    failMessage(
                        "You rejected the pairing code. No setup data was transferred."
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard operationGeneration == generation else { return }
                if matches {
                    fail(error)
                } else {
                    failMessage(
                        "You rejected the pairing code. No setup data was transferred."
                    )
                }
            }
        }
    }

    private func continueAfterMutualSAS(
        role: NearbyHandshakeRole,
        peerName: String,
        code: String
    ) {
        guard localSASMatched,
              localSASDecisionSent,
              peerSASMatched,
              !localSASRejected else { return }
        switch role {
        case .origin:
            phase = .awaitingRecipientPublicKey(
                peerDisplayName: peerName,
                code: code
            )
            prepareOriginBatch(peerName: peerName, code: code)
        case .recipient:
            guard let recipientKeyProvider else {
                fail(BootstrapCoordinatorError.notConfigured)
                return
            }
            let operationGeneration = generation
            phase = .authorizingRecipientKey
            worker = Task { [weak self] in
                guard let self else { return }
                do {
                    let key = try await recipientKeyProvider()
                    try Task.checkCancellation()
                    guard operationGeneration == generation else { return }
                    recipientKey = key
                    phase = .waitingForOriginApproval(
                        peerDisplayName: peerName,
                        code: code
                    )
                    sendRecipientKeyAndWait(key)
                } catch is CancellationError {
                    return
                } catch {
                    guard operationGeneration == generation else { return }
                    fail(error)
                }
            }
        }
    }

    private func failFromPeerRejection(peerName: String) {
        let message = "\(peerName) rejected the pairing code. No setup data was transferred."
        failMessage(message)
        peerRejectionNotice = message
    }

    private func prepareOriginBatch(peerName: String, code: String) {
        guard let connection, let session, let manifestExporter else {
            fail(BootstrapCoordinatorError.invalidState)
            return
        }
        let operationGeneration = generation
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let publicKeyFrame = try await connection.receive(maximumSize: 65_536)
                try Task.checkCancellation()
                let publicKey = try session.openRecipientPublicKey(publicKeyFrame)
                let manifest = try await manifestExporter()
                try Task.checkCancellation()
                let checklist = manifest.hosts.map(Self.checklistItem)
                let selection = BootstrapGrantSelectionState(
                    peerDisplayName: peerName,
                    code: code,
                    publicKeyName: publicKey.displayName,
                    publicKeyFingerprint: publicKey.fingerprint,
                    publicKeyProtection: publicKey.protection,
                    checklist: checklist,
                    selectedHostIDs: Set(checklist.filter(\.isGrantEligible).map(\.id)),
                    selectedOptionalTransfers: []
                )
                guard operationGeneration == generation else { return }
                pendingOriginBatch = PendingOriginBatch(
                    manifest: manifest,
                    publicKey: publicKey,
                    selection: selection
                )
                worker = nil
                phase = .selectingGrants(selection)
            } catch is CancellationError {
                return
            } catch {
                guard operationGeneration == generation else { return }
                fail(error)
            }
        }
    }

    private func sendRecipientKeyAndWait(_ key: BootstrapRecipientKey) {
        guard let connection, let session else {
            fail(BootstrapCoordinatorError.invalidState)
            return
        }
        let operationGeneration = generation
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                try await connection.send(
                    try session.sealRecipientPublicKey(key.publicKey)
                )
                let proof = try await connection.receive(maximumSize: 65_536)
                try Task.checkCancellation()
                try session.openOriginAuthorizationProof(proof)
                guard operationGeneration == generation else { return }
                phase = .transferring(role: .recipient, peerDisplayName: peerDisplayName)

                let manifestFrame = try await connection.receive(
                    maximumSize: BootstrapManifest.maximumEncodedByteCount + 65_536
                )
                try Task.checkCancellation()
                let manifest = try session.openManifest(manifestFrame)
                guard let manifestImporter,
                      let recipientGrantRecorder,
                      let recipientGrantIntentRecorder,
                      let recipientGrantIntentRemover else {
                    throw BootstrapCoordinatorError.notConfigured
                }
                let importReceipt = try await manifestImporter(
                    manifest,
                    peerDisplayName
                )
                let descriptorsByID = Dictionary(
                    uniqueKeysWithValues: manifest.hosts.map { ($0.id, $0) }
                )
                let routeIdentitiesByHostID = try Dictionary(
                    uniqueKeysWithValues: manifest.hosts.map { descriptor in
                        (
                            descriptor.id,
                            RemoteAccessRouteIdentity.value(
                                for: try Self.hostSnapshot(
                                    for: descriptor,
                                    in: manifest
                                )
                            )
                        )
                    }
                )
                for descriptor in manifest.hosts
                where descriptor.authenticationHint == .publicKey
                    && importReceipt.acceptedHostIDs.contains(descriptor.id) {
                    try recipientGrantIntentRecorder(
                        BootstrapRecipientGrantRecord(
                            hostID: descriptor.id,
                            hostName: descriptor.name,
                            endpoint: "\(descriptor.user)@\(descriptor.address):\(descriptor.port)",
                            routeIdentity: routeIdentitiesByHostID[descriptor.id]!,
                            peerDeviceName: peerDisplayName,
                            recipientKey: key
                        )
                    )
                }
                let importAcceptance = try BootstrapImportAcceptance.acknowledging(
                    manifest,
                    acceptedHostIDs: importReceipt.acceptedHostIDs
                )
                try await connection.send(
                    try session.sealImportAcceptance(importAcceptance)
                )

                let grantFrame = try await connection.receive(
                    maximumSize: BootstrapManifest.maximumEncodedByteCount + 65_536
                )
                try Task.checkCancellation()
                let grantReceipt = try session.openGrantReceipt(grantFrame)
                try grantReceipt.validate(manifest: manifest, publicKey: key.publicKey)

                for result in grantReceipt.results {
                    guard let descriptor = descriptorsByID[result.hostID] else {
                        throw NearbyHandshakeError.invalidGrantReceipt
                    }
                    guard result.status == .installed else {
                        // `.failed` is ambiguous: the origin may have appended
                        // the key and then lost verification/receipt. Retain the
                        // recipient's uncertain intent for recovery. The other
                        // non-installed statuses prove no installer ran.
                        if result.status != .failed,
                           descriptor.authenticationHint == .publicKey,
                           importReceipt.acceptedHostIDs.contains(result.hostID) {
                            recipientGrantIntentRemover(
                                BootstrapRecipientGrantRecord(
                                    hostID: descriptor.id,
                                    hostName: descriptor.name,
                                    endpoint: "\(descriptor.user)@\(descriptor.address):\(descriptor.port)",
                                    routeIdentity: routeIdentitiesByHostID[descriptor.id]!,
                                    peerDeviceName: peerDisplayName,
                                    recipientKey: key
                                )
                            )
                        }
                        continue
                    }
                    guard importReceipt.acceptedHostIDs.contains(result.hostID) else {
                        throw BootstrapCoordinatorError.rejectedImportedHost(result.hostID)
                    }
                    try recipientGrantRecorder(
                        BootstrapRecipientGrantRecord(
                            hostID: descriptor.id,
                            hostName: descriptor.name,
                            endpoint: "\(descriptor.user)@\(descriptor.address):\(descriptor.port)",
                            routeIdentity: routeIdentitiesByHostID[descriptor.id]!,
                            peerDeviceName: peerDisplayName,
                            recipientKey: key
                        )
                    )
                }

                let acknowledgement = try BootstrapGrantCompletionAcknowledgement
                    .acknowledging(grantReceipt)
                try importPromotionRecorder(manifest)
                try await connection.send(
                    try session.sealCompletionAcknowledgement(acknowledgement)
                )
                try importCompletionRecorder(manifest)
                guard operationGeneration == generation else { return }
                let checklist = manifest.hosts.map(Self.checklistItem)
                finishNetwork()
                firstOpenStore.markComplete()
                phase = .completed(
                    BootstrapFlowReceipt(
                        direction: .received(importReceipt),
                        peerDisplayName: peerDisplayName,
                        recipientPublicKey: key.publicKey,
                        credentialChecklist: checklist,
                        grantReceipt: grantReceipt
                    )
                )
            } catch is CancellationError {
                // Task cancellation means a local cancel/background already
                // reset this attempt. A `CancellationError` thrown by the
                // importer itself — the admission handler declined the batch —
                // arrives on a live task; end the attempt cleanly so the
                // origin does not wait forever on the acceptance frame.
                guard operationGeneration == generation, !Task.isCancelled else { return }
                failMessage("Nearby setup was cancelled.")
            } catch {
                guard operationGeneration == generation else { return }
                fail(error)
            }
        }
    }

    private func finishOriginAuthorization(
        _ grantAuthorization: SyncDeviceAccessGrantEngine.Authorization,
        approvedManifest: ApprovedBootstrapManifest,
        selectedRequestsByHostID: [UUID: SyncDeviceAccessGrantEngine.InstallRequest],
        operationGeneration: UInt64
    ) async {
        guard operationGeneration == generation else {
            grantEngine.invalidate(grantAuthorization)
            return
        }
        defer { grantEngine.invalidate(grantAuthorization) }
        guard
              let session,
              let connection,
              let pendingOriginBatch
        else { return }

        do {
            try session.recordOriginAuthorization(.approved)

            phase = .transferring(
                role: .origin,
                peerDisplayName: pendingOriginBatch.selection.peerDisplayName
            )
            let proof = try session.sealOriginAuthorizationProof()
            let manifestFrame = try session.sealManifest(approvedManifest)
            let wireManifest = approvedManifest.manifest
            try await connection.send(proof)
            try await connection.send(manifestFrame)

            let importAcceptanceFrame = try await connection.receive(maximumSize: 65_536)
            try Task.checkCancellation()
            let importAcceptance = try session.openImportAcceptance(
                importAcceptanceFrame
            )
            guard try importAcceptance.validates(wireManifest) else {
                throw NearbyHandshakeError.invalidImportAcceptance
            }
            let acceptedHostIDs = Set(importAcceptance.acceptedHostIDs)

            var results: [BootstrapHostGrantResult] = []
            for descriptor in wireManifest.hosts {
                try Task.checkCancellation()
                guard descriptor.authenticationHint == .publicKey else {
                    results.append(Self.result(for: descriptor, status: .excludedAuthentication))
                    continue
                }
                guard pendingOriginBatch.selection.selectedHostIDs.contains(descriptor.id) else {
                    results.append(Self.result(for: descriptor, status: .notSelected))
                    continue
                }
                guard acceptedHostIDs.contains(descriptor.id) else {
                    results.append(Self.result(for: descriptor, status: .rejectedImport))
                    continue
                }

                do {
                    guard let installRequest = selectedRequestsByHostID[descriptor.id] else {
                        throw BootstrapCoordinatorError.selectedHostChanged(descriptor.id)
                    }
                    try await grantEngine.install(
                        installRequest,
                        authorization: grantAuthorization
                    )
                    try Task.checkCancellation()
                    results.append(Self.result(for: descriptor, status: .installed))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    results.append(
                        Self.result(
                            for: descriptor,
                            status: .failed,
                            detail: Self.sanitizedGrantFailure(error)
                        )
                    )
                }
            }

            let grantReceipt = BootstrapGrantBatchReceipt(
                publicKeyID: pendingOriginBatch.publicKey.id,
                publicKeyFingerprint: pendingOriginBatch.publicKey.fingerprint,
                results: results
            )
            try grantReceipt.validate(
                manifest: wireManifest,
                publicKey: pendingOriginBatch.publicKey
            )
            try await connection.send(try session.sealGrantReceipt(grantReceipt))

            let acknowledgementFrame = try await connection.receive(maximumSize: 65_536)
            try Task.checkCancellation()
            let acknowledgement = try session.openCompletionAcknowledgement(
                acknowledgementFrame
            )
            guard try acknowledgement.validates(grantReceipt) else {
                throw BootstrapCoordinatorError.completionAcknowledgementMismatch
            }
            guard operationGeneration == generation else { return }
            let checklist = wireManifest.hosts.map(Self.checklistItem)
            finishNetwork()
            phase = .completed(
                BootstrapFlowReceipt(
                    direction: .sent(hostCount: wireManifest.hosts.count),
                    peerDisplayName: pendingOriginBatch.selection.peerDisplayName,
                    recipientPublicKey: pendingOriginBatch.publicKey,
                    credentialChecklist: checklist,
                    grantReceipt: grantReceipt
                )
            )
        } catch is CancellationError {
            guard operationGeneration == generation else { return }
            failMessage("Nearby setup was cancelled.")
        } catch {
            guard operationGeneration == generation else { return }
            fail(error)
        }
    }

    private func makeInstallRequest(
        descriptor: BootstrapHostDescriptor,
        publicKey: EnrollmentPublicKey,
        peerName: String
    ) throws -> BootstrapGrantInstallRequest {
        guard let manifestExporter else {
            throw BootstrapCoordinatorError.notConfigured
        }
        _ = manifestExporter // configuration guard; source host comes from the live model callback.
        let unresolved = try liveHostSnapshot(for: descriptor.id)
        let probeRequest = BootstrapGrantInstallRequest(
            hostID: descriptor.id,
            hostName: descriptor.name,
            endpoint: "\(descriptor.user)@\(descriptor.address):\(descriptor.port)",
            peerDeviceName: peerName,
            publicKeyID: publicKey.id,
            publicKeyFingerprint: publicKey.fingerprint,
            authorizedKeysLine: publicKey.authorizedKeysLine,
            host: unresolved
        )
        let host = try grantHostResolver?(probeRequest) ?? unresolved
        try validateLiveGrantHost(host, descriptor: descriptor)
        return BootstrapGrantInstallRequest(
            hostID: descriptor.id,
            hostName: descriptor.name,
            endpoint: "\(descriptor.user)@\(descriptor.address):\(descriptor.port)",
            peerDeviceName: peerName,
            publicKeyID: publicKey.id,
            publicKeyFingerprint: publicKey.fingerprint,
            authorizedKeysLine: publicKey.authorizedKeysLine,
            host: host
        )
    }

    private func pendingOriginInstallRequests(
        for selection: BootstrapGrantSelectionState
    ) throws -> [SyncDeviceAccessGrantEngine.InstallRequest] {
        guard let pendingOriginBatch else {
            throw BootstrapCoordinatorError.invalidState
        }
        return try pendingOriginBatch.manifest.hosts.compactMap { descriptor in
            guard descriptor.authenticationHint == .publicKey,
                  selection.selectedHostIDs.contains(descriptor.id) else { return nil }
            let request = try makeInstallRequest(
                descriptor: descriptor,
                publicKey: pendingOriginBatch.publicKey,
                peerName: selection.peerDisplayName
            )
            return SyncDeviceAccessGrantEngine.InstallRequest(
                host: request.host,
                hostLabel: request.hostName,
                endpoint: request.endpoint,
                peerDeviceName: request.peerDeviceName,
                flow: .bootstrap,
                publicKey: pendingOriginBatch.publicKey
            )
        }
    }

    private func validateLiveGrantHost(
        _ host: Host,
        descriptor: BootstrapHostDescriptor
    ) throws {
        guard let pendingOriginBatch else {
            throw BootstrapCoordinatorError.invalidState
        }
        let manifest = pendingOriginBatch.manifest
        let expectedTransport: HostTransport = descriptor.transport == .mosh ? .mosh : .ssh
        guard host.id == descriptor.id,
              host.name == descriptor.name,
              host.address == descriptor.address,
              host.port == Int(descriptor.port),
              host.user == descriptor.user,
              host.transport == expectedTransport,
              host.jumpChainBrokenReason == nil else {
            throw BootstrapCoordinatorError.selectedHostChanged(descriptor.id)
        }

        let linksByHostID = Dictionary(
            uniqueKeysWithValues: manifest.jumpChains.map { ($0.hostID, $0.jumpHostID) }
        )
        var innerHopIDs: [UUID] = []
        var currentID = descriptor.id
        while let jumpID = linksByHostID[currentID] {
            innerHopIDs.append(jumpID)
            currentID = jumpID
        }
        let expectedHopIDs = innerHopIDs.reversed()
        guard host.jumpChain.map(\.id).elementsEqual(expectedHopIDs) else {
            throw BootstrapCoordinatorError.selectedHostChanged(descriptor.id)
        }

        let descriptorsByID = Dictionary(
            uniqueKeysWithValues: manifest.hosts.map { ($0.id, $0) }
        )
        for hop in host.jumpChain {
            guard let hopDescriptor = descriptorsByID[hop.id] else {
                throw BootstrapCoordinatorError.selectedHostChanged(descriptor.id)
            }
            let hopTransport: HostTransport = hopDescriptor.transport == .mosh ? .mosh : .ssh
            guard hop.name == hopDescriptor.name,
                  hop.address == hopDescriptor.address,
                  hop.port == Int(hopDescriptor.port),
                  hop.user == hopDescriptor.user,
                  hop.transport == hopTransport else {
                throw BootstrapCoordinatorError.selectedHostChanged(descriptor.id)
            }
        }
    }

    private static func legacyInstallRequest(
        from request: SyncDeviceAccessGrantEngine.InstallRequest
    ) -> BootstrapGrantInstallRequest {
        BootstrapGrantInstallRequest(
            hostID: request.hostID,
            hostName: request.hostLabel,
            endpoint: request.endpoint,
            peerDeviceName: request.peerDeviceName,
            publicKeyID: request.publicKey.id,
            publicKeyFingerprint: request.publicKey.fingerprint,
            authorizedKeysLine: request.authorizedKeysLine,
            host: request.host
        )
    }

    /// Recreates the exact secret-free route represented by the immutable
    /// manifest. Origin approval separately proves its frozen live Host has
    /// these same connection semantics, so both ledgers retain one route
    /// identity without sending any credential material.
    private static func hostSnapshot(
        for descriptor: BootstrapHostDescriptor,
        in manifest: BootstrapManifest
    ) throws -> Host {
        let descriptorsByID = Dictionary(
            uniqueKeysWithValues: manifest.hosts.map { ($0.id, $0) }
        )
        let linksByHostID = Dictionary(
            uniqueKeysWithValues: manifest.jumpChains.map { ($0.hostID, $0.jumpHostID) }
        )
        var innerHops: [BootstrapHostDescriptor] = []
        var seen: Set<UUID> = [descriptor.id]
        var currentID = descriptor.id
        while let jumpID = linksByHostID[currentID] {
            guard seen.insert(jumpID).inserted,
                  let jump = descriptorsByID[jumpID] else {
                throw BootstrapCoordinatorError.selectedHostChanged(descriptor.id)
            }
            innerHops.append(jump)
            currentID = jumpID
        }
        let jumpChain = innerHops.reversed().map { Self.directHostSnapshot(for: $0) }
        var destination = Self.directHostSnapshot(for: descriptor)
        destination.jumpChain = jumpChain
        return destination
    }

    private static func directHostSnapshot(
        for descriptor: BootstrapHostDescriptor
    ) -> Host {
        Host(
            id: descriptor.id,
            name: descriptor.name,
            address: descriptor.address,
            port: Int(descriptor.port),
            user: descriptor.user,
            transport: descriptor.transport == .mosh ? .mosh : .ssh,
            launchMode: .customCommand
        )
    }

    /// Injected installers need a transport-ready Host. Production installation
    /// resolves its own current snapshot in the callback; tests deliberately do
    /// not have SwiftData, so a public-only descriptor snapshot is sufficient.
    private func liveHostSnapshot(for hostID: UUID) throws -> Host {
        guard let pendingOriginBatch,
              let descriptor = pendingOriginBatch.manifest.hosts.first(where: { $0.id == hostID })
        else { throw BootstrapCoordinatorError.missingHost(hostID) }
        return Host(
            id: descriptor.id,
            name: descriptor.name,
            address: descriptor.address,
            port: Int(descriptor.port),
            user: descriptor.user,
            transport: descriptor.transport == .mosh ? .mosh : .ssh,
            launchMode: .customCommand
        )
    }

    private static func checklistItem(
        _ host: BootstrapHostDescriptor
    ) -> BootstrapCredentialChecklistItem {
        BootstrapCredentialChecklistItem(
            id: host.id,
            hostName: host.name,
            authenticationHint: host.authenticationHint
        )
    }

    private static func result(
        for descriptor: BootstrapHostDescriptor,
        status: BootstrapHostGrantStatus,
        detail: String? = nil
    ) -> BootstrapHostGrantResult {
        BootstrapHostGrantResult(
            hostID: descriptor.id,
            hostName: descriptor.name,
            status: status,
            detail: detail
        )
    }

    private static func sanitizedGrantFailure(_ error: Error) -> String {
        let trimmed = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "Key installation failed." : trimmed
        return String(value.prefix(BootstrapGrantBatchReceipt.maximumDetailLength))
    }

    private func finishNetwork() {
        worker = nil
        sasDecisionSender = nil
        handshakeDeadlineTask?.cancel()
        handshakeDeadlineTask = nil
        service.stop()
        discoveredPeers = []
        session = nil
        role = nil
        recipientKey = nil
        pendingOriginBatch = nil
        localSASMatched = false
        localSASDecisionSent = false
        localSASRejected = false
        peerSASMatched = false
        activeHandshakeTranscriptHash = nil
        let activeConnection = connection
        connection = nil
        Task { await activeConnection?.cancel() }
    }

    private func resetAttempt(keepingPresentation: Bool) {
        generation &+= 1
        worker?.cancel()
        worker = nil
        sasDecisionSender?.cancel()
        sasDecisionSender = nil
        handshakeDeadlineTask?.cancel()
        handshakeDeadlineTask = nil
        service.stop()
        discoveredPeers = []
        session = nil
        role = nil
        recipientKey = nil
        pendingOriginBatch = nil
        localSASMatched = false
        localSASDecisionSent = false
        localSASRejected = false
        peerSASMatched = false
        activeHandshakeTranscriptHash = nil
        attemptIntent = nil
        failedAttemptIntent = nil
        peerRejectionNotice = nil
        peerDisplayName = "Nearby Tessera device"
        let activeConnection = connection
        connection = nil
        Task { await activeConnection?.cancel() }
        if !keepingPresentation { phase = .inactive }
    }

    private func fail(_ error: Error) {
        DiagnosticLogStore.appendApp(
            "bootstrap attempt failed role=\(role.map { String(describing: $0) } ?? "none") "
                + Self.diagnosticFailureSummary(for: error)
        )
        failMessage(Self.userFacingFailureMessage(for: error, peerName: peerDisplayName))
    }

    /// Stable, content-free failure classification for the user-shareable
    /// diagnostic log. Error descriptions are deliberately excluded: decode
    /// and manifest errors may embed peer-controlled field names, and opaque
    /// framework errors are not a safe structured-log boundary.
    static func diagnosticFailureSummary(for error: Error) -> String {
        let code: String
        switch error {
        case is NearbyHandshakeError: code = "handshake"
        case is BootstrapManifestError: code = "manifest"
        case is DecodingError: code = "decoding"
        case is NearbyTransferServiceError: code = "transport"
        case BootstrapCoordinatorError.handshakeTimedOut: code = "handshake-timeout"
        case is BootstrapCoordinatorError: code = "coordinator"
        case is CancellationError: code = "cancelled"
        default: code = "other"
        }
        return "failureCode=\(code) failureType=\(String(reflecting: type(of: error)))"
    }

    /// Maps protocol errors to actionable failure text. Version mismatches
    /// become directional update guidance naming the right device; raw
    /// decoding errors become a cross-version hint instead of Foundation's
    /// "data couldn't be read"; everything else keeps its own wording.
    static func userFacingFailureMessage(for error: Error, peerName: String) -> String {
        switch error {
        case NearbyHandshakeError.incompatiblePeerVersion(let info, _):
            let release = info.appVersion.map { " (\($0))" } ?? ""
            if info.version > NearbyBootstrapProtocol.version {
                return "\(peerName) is running a newer version of Tessera\(release). "
                    + "Update Tessera on this device, then try again."
            }
            return "\(peerName) is running an older version of Tessera\(release). "
                + "Update Tessera on \(peerName), then try again."
        case NearbyHandshakeError.unsupportedFrameVersion,
             NearbyHandshakeError.unsupportedVersion:
            return "The encrypted channel between the devices is incompatible. "
                + "Make sure both devices run the same version of Tessera, then try again."
        case BootstrapManifestError.unsupportedVersion(let version):
            if version > BootstrapManifest.currentVersion {
                return "\(peerName) sent setup data from a newer version of Tessera. "
                    + "Update Tessera on this device, then try again."
            }
            return "\(peerName) sent setup data from an older version of Tessera. "
                + "Update Tessera on \(peerName), then try again."
        case BootstrapManifestError.unknownField(let path, let field):
            return "\(peerName) sent setup data with a field this version of Tessera "
                + "does not accept (\(path).\(field)). If \(peerName) is running a newer "
                + "version of Tessera, update this device, then try again."
        case is DecodingError:
            return "The devices could not understand each other's setup messages. "
                + "Make sure both devices are running the same version of Tessera, "
                + "then try again."
        default:
            return error.localizedDescription
        }
    }


    private func failMessage(_ message: String) {
        let retryIntent = attemptIntent ?? failedAttemptIntent
        resetAttempt(keepingPresentation: true)
        failedAttemptIntent = retryIntent
        phase = .failed(message: message)
    }
}
