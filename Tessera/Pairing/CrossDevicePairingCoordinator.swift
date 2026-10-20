import Foundation
import Observation
import TesseraCore

/// Adopt only an already-approved, synchronous persistence mutation before
/// ModelContext.didSave can observe it. Never span an await with this boundary:
/// unrelated route/credential/policy edits must continue to invalidate pairing.
enum PairedBootstrapPersistence {
    /// Reconcile unsaved edits before adopting an approved grant mutation.
    /// Keep this check and the caller's mutation on the same synchronous actor turn.
    @MainActor
    static func requireCurrentMutation(
        captureFence: () -> UInt64?,
        reconcile: () -> Void,
        isAuthorized: (UInt64) -> Bool,
        isLocked: () -> Bool
    ) throws {
        guard let fence = captureFence() else { throw CancellationError() }
        try Task.checkCancellation()
        reconcile()
        guard isAuthorized(fence), !isLocked() else { throw CancellationError() }
    }

    static func save<Snapshot>(
        approvedSnapshot: Snapshot,
        previousSnapshot: Snapshot?,
        adopt: (Snapshot?) -> Void,
        persist: () throws -> Void
    ) throws {
        adopt(approvedSnapshot)
        do { try persist() }
        catch {
            adopt(previousSnapshot)
            throw error
        }
    }
}

/// App-owned adapters for the process-local parts of Pairing-v1. The shared
/// runtime owns record ordering and receipts; these closures own SwiftData,
/// Keychain, biometrics, and SSH without serializing any capability into it.
@MainActor
struct CrossDevicePairingPlatformAdapters {
    /// Returns the existing continuation's opaque receive ID only after its
    /// descriptor has crossed that coordinator's durable receive boundary.
    typealias DescriptorReceiver = @MainActor (ContinuationDescriptorV1, ContinuationTransportBinding) -> UUID?
    typealias DescriptorCancellation = @MainActor (UUID) -> Void
    typealias RecipientKeyProvider = @MainActor () async throws -> DevicePublicKeyDescriptorV2
    typealias ManifestExporter = @MainActor (Bool) async throws -> BootstrapManifestV2
    /// Persists the import plus its pre-install uncertain receipt for the exact
    /// recipient key. The runtime does not advance until this returns.
    typealias ManifestImporter = @MainActor (BootstrapManifestV2, DevicePublicKeyDescriptorV2) async throws -> [UUID]
    typealias GrantVerifier = @MainActor (CrossDeviceBootstrapGrantRequestV1) async -> [BootstrapHostGrantResultV1]
    typealias AccessRecorder = @MainActor (
        BootstrapGrantReceiptV1,
        DevicePublicKeyDescriptorV2,
        BootstrapManifestV2
    ) throws -> Void
    typealias FreshOwnerApproval = @MainActor (String) async throws -> Date

    let receiveDescriptor: DescriptorReceiver
    let cancelDescriptor: DescriptorCancellation
    let recipientKey: RecipientKeyProvider
    let exportManifest: ManifestExporter
    let importManifest: ManifestImporter
    let verifyGrants: GrantVerifier
    let recordAccess: AccessRecorder
    let freshOwnerApproval: FreshOwnerApproval
}

enum CrossDevicePairingPresentationPhase: Equatable {
    case idle
    case showingOffer
    case scanning
    case connecting
    case compareSAS(String)
    case waitingForPeerSAS(String)
    case waitingForSetupChoice
    case bootstrapOriginApproval(BootstrapGrantSelectionState)
    case bootstrapRecipientImport([BootstrapCredentialChecklistItem])
    case transferring
    case completed(CrossDevicePairingReceipt?)
    case failed(String)
}

/// What a finished setup transfer actually did. QR pairing used to end on a
/// bare "pairing complete", which left the sender with no record of what was
/// copied or whether each host's key access was installed.
struct CrossDevicePairingReceipt: Equatable {
    enum Direction: Equatable {
        case sent
        case received
    }

    struct HostOutcome: Equatable, Identifiable {
        let id: UUID
        let name: String
        let status: BootstrapHostGrantStatusV1?
        /// False only when an acceptance set was actually received and excluded
        /// this host. Never guessed: a receipt that overstates is worse than none.
        let wasAccepted: Bool?
        var passwordOnFirstConnect: Bool = false

        var presentationOutcome: SetupFlowPresentationV1.Outcome {
            SetupFlowPresentationV1.outcome(.init(id: id,
                access: status.flatMap { SetupFlowPresentationV1.Access(rawValue: $0.rawValue) } ?? .unknown,
                wasAccepted: wasAccepted, passwordNeeded: passwordOnFirstConnect))
        }

        var label: LocalizedStringResource { SetupAccessCopy.label(presentationOutcome) }

        var isNegative: Bool { status == .failed || wasAccepted == false }
    }

    let direction: Direction
    let hosts: [HostOutcome]
    let optionalCategoryCount: Int

    var hasUnverifiedAccess: Bool {
        hosts.contains { $0.status == .failed || ($0.status == .skipped && !$0.passwordOnFirstConnect) || $0.wasAccepted == false }
    }
}

extension CrossDevicePairingPresentationPhase {
    /// Consent phases list every host and optional category, so they can exceed
    /// the card on a phone.
    var isScrollableConsent: Bool {
        switch self {
        case .bootstrapOriginApproval, .bootstrapRecipientImport, .completed: true
        default: false
        }
    }
}

/// Correlates existing continuation callbacks to one Pairing-v1 descriptor.
/// Apple Handoff and local QR pairing share `ContinuationCoordinator`; this
/// gate prevents a simultaneous Apple receipt from advancing the QR attempt.
struct CrossDeviceContinuationReceiptGate {
    private var expected: (id: UUID, hostID: UUID)?
    private var accepted = false
    private var completed = false

    var expectedContinuationID: UUID? { expected?.id }

    mutating func expect(continuationID: UUID, hostID: UUID) {
        expected = (continuationID, hostID)
        accepted = false
        completed = false
    }

    mutating func acceptDurable(continuationID: UUID, hostID: UUID) -> Bool {
        guard expected?.id == continuationID,
              expected?.hostID == hostID,
              !accepted
        else { return false }
        accepted = true
        return true
    }

    mutating func acceptCompletion(continuationID: UUID, hostID: UUID) -> Bool {
        guard expected?.id == continuationID,
              expected?.hostID == hostID,
              accepted,
              !completed
        else { return false }
        completed = true
        return true
    }

    mutating func reset() {
        expected = nil
        accepted = false
        completed = false
    }
}

/// Foreground-only bridge between the Pairing-v1 runtime and iOS adapters. It
/// owns the listener/socket lifetime and deliberately never decides protocol
/// state from socket callbacks; every record goes through the shared runtime.
@MainActor
@Observable
final class CrossDevicePairingCoordinator {
    private(set) var phase: CrossDevicePairingPresentationPhase = .idle
    private(set) var qrText: String?
    private(set) var purpose: PairingPurpose?
    private var finishedPurpose: PairingPurpose?
    private var stoppedAt: SetupFlowPresentationV1.Stage?
    private(set) var operationStatus: SetupFlowPresentationV1.Phase = .transferring
    var presentationPurpose: PairingPurpose? { purpose ?? finishedPurpose }
    var presentationAttempt: UInt64 { lifecycleGeneration }
    /// Finished receiving setup alone: set up and continue has already
    /// opened the continued session, which "done" must not leave.
    var finishedReceivingSetup: Bool {
        guard case .completed(let receipt) = phase else { return false }
        return receipt?.direction == .received && presentationPurpose == .bootstrap
    }

    var presentation: SetupFlowPresentationV1.Output {
        let status: SetupFlowPresentationV1.Phase
        switch phase {
        case .idle, .showingOffer, .scanning: status = .entry
        case .connecting: status = .connecting
        case .compareSAS: status = .compareCode
        case .waitingForPeerSAS: status = .waitingForPeerCode
        case .waitingForSetupChoice: status = .waitingForSelection
        case .bootstrapOriginApproval: status = .choosing
        case .bootstrapRecipientImport: status = .reviewingImport
        case .transferring: status = operationStatus
        case .completed: status = .completed
        case .failed: status = .failed
        }
        return SetupFlowPresentationV1.project(.init(
            purpose: presentationPurpose ?? .bootstrap, phase: status,
            supportedActions: [.cancel, .confirmCode, .rejectCode, .approve, .importSetup, .done],
            selection: originSelection.map {
                .init(mode: .copy, allHostIDs: $0.checklist.map(\.id), selectedHostIDs: Array($0.selectedHostIDs),
                      grantEligibleHostIDs: $0.checklist.filter(\.isGrantEligible).map(\.id),
                      jumpLinks: originManifest?.jumpChains ?? [])
            }, stoppedAt: stoppedAt
        ))
    }

    var isPresented: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// A delivered continuation may need the existing host/prefill/credential
    /// UI. Pairing remains active to preserve its receipts, but must yield
    /// hit-testing and visual priority to that established flow.
    var showsPresentation: Bool { isPresented && !awaitingContinuationUI }

    private var adapters: CrossDevicePairingPlatformAdapters!
    private let listenerFactory: @MainActor () -> PairingLocalTCPListener
    private let grantEngine = DeviceAccessGrantEngine()
    private var policyGeneration: UInt64 = 1
    private var runtime: CrossDevicePairingRuntimeV1?
    private var listener: PairingLocalTCPListener?
    private var connection: PairingTCPRecordConnection?
    private var receiveTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var transportClosureExpected = false
    private var lifecycleGeneration: UInt64 = 0
    private var originDescriptor: ContinuationDescriptorV1?
    private var deferredDescriptor: ContinuationDescriptorV1?
    private var pendingManifest: BootstrapManifestV2?
    private var receivedManifest: BootstrapManifestV2?
    private var recipientPublicKey: DevicePublicKeyDescriptorV2?
    private var pendingOwnerAuthorization: CrossDeviceBootstrapAuthorizationRequestV1?
    /// The manifest the approval screen was rendered from. Approval has to bind
    /// the hosts the sender actually saw, not a second export taken later.
    private var originManifest: BootstrapManifestV2?
    private var originSelection: BootstrapGrantSelectionState?
    private var comparedCode: String = ""
    private var grantResults: [BootstrapHostGrantResultV1] = []
    /// The hosts the peer durably accepted. nil until an acceptance is received,
    /// so the receipt can distinguish "refused" from "never learned".
    private var acceptedHostIDs: Set<UUID>?
    private var continuationReceiptGate = CrossDeviceContinuationReceiptGate()
    private var awaitingContinuationUI = false

    init() {
        listenerFactory = { PairingLocalTCPListener() }
    }

    init(
        adapters: CrossDevicePairingPlatformAdapters,
        listenerFactory: @escaping @MainActor () -> PairingLocalTCPListener = {
            PairingLocalTCPListener()
        }
    ) {
        self.adapters = adapters
        self.listenerFactory = listenerFactory
    }

    /// A process-local fence for adapter mutations that may suspend for user
    /// admission or owner presence. It is never serialized or sent to a peer.
    func mutationFence() -> UInt64? {
        guard runtime != nil, phase.allowsDurableMutation else { return nil }
        return lifecycleGeneration
    }

    func isMutationAuthorized(by fence: UInt64) -> Bool {
        fence == lifecycleGeneration && runtime != nil && phase.allowsDurableMutation
    }

    func configure(adapters: CrossDevicePairingPlatformAdapters) {
        guard !isPresented else { return }
        self.adapters = adapters
    }

    func beginOrigin(
        purpose: PairingPurpose,
        descriptor: ContinuationDescriptorV1? = nil
    ) {
        guard !isPresented else { return }
        guard adapters != nil else {
            phase = .failed(String(localized: "Cross-device pairing is not configured."))
            return
        }
        guard (purpose == .continueSession || purpose == .setUpAndContinue) == (descriptor != nil) else {
            phase = .failed(String(localized: "A continuation descriptor is required for this pairing action."))
            return
        }
        self.purpose = purpose
        originDescriptor = descriptor
        phase = .connecting
        let lifecycle = beginLifecycle()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let listener = self.listenerFactory()
                let candidates = try await listener.start()
                guard self.isCurrent(lifecycle) else {
                    listener.cancel()
                    return
                }
                let runtime = try CrossDevicePairingRuntimeV1(
                    origin: PairingOriginDriverConfigurationV1(
                        purpose: purpose,
                        expiresAt: PairingHandshakeV1.unixTimeNow() + PairingOfferV1.maximumLifetimeSeconds,
                        endpointCandidates: candidates,
                        oneTimeOpticalSecret: Self.randomOpticalSecret()
                    )
                )
                self.listener = listener
                self.runtime = runtime
                await self.process(await runtime.start(), from: runtime)
                guard self.isCurrent(lifecycle, runtime: runtime) else { return }
                self.receiveTask = Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener else { return }
                    do {
                        let connection = try await listener.acceptConnection()
                        guard self.isCurrent(lifecycle, runtime: runtime) else {
                            await connection.cancel()
                            return
                        }
                        self.connection = connection
                        try await connection.start()
                        guard self.isCurrent(lifecycle, runtime: runtime) else {
                            await connection.cancel()
                            return
                        }
                        await self.process(await runtime.admitPeer(), from: runtime)
                        await self.receiveLoop(connection: connection, runtime: runtime)
                    } catch {
                        self.failUnlessCancelled(error)
                    }
                }
                self.armExpiry(for: runtime)
            } catch {
                self.failUnlessCancelled(error)
            }
        }
    }

    /// Presents the scanner before an offer is available. This is kept
    /// separate from `beginRecipient` so camera permission/manual entry are a
    /// UI concern and no socket is opened until canonical text is supplied.
    func beginScanning() {
        guard !isPresented else { return }
        guard adapters != nil else {
            phase = .failed(String(localized: "Cross-device pairing is not configured."))
            return
        }
        _ = beginLifecycle()
        phase = .scanning
    }

    func dismiss() {
        reset()
    }

    /// The scanner already enforces canonical QR text; this second parse keeps
    /// the coordinator safe for manual text submission and tests alike.
    func beginRecipient(qrText: String) {
        // Scanner presentation is intentionally an inert pre-connection
        // state. Its one canonical callback is allowed to replace it; every
        // authenticated/active attempt remains non-reentrant.
        guard !isPresented || phase == .scanning else { return }
        guard adapters != nil else {
            phase = .failed(String(localized: "Cross-device pairing is not configured."))
            return
        }
        phase = .connecting
        let lifecycle = beginLifecycle()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let offer = try PairingQRTextCodecV1.decode(qrText)
                let runtime = try CrossDevicePairingRuntimeV1(
                    recipient: PairingRecipientDriverConfigurationV1(encodedOffer: try offer.encoded())
                )
                let connection = try await PairingTCPRecordConnection.connect(to: offer.endpointCandidates)
                guard self.isCurrent(lifecycle) else {
                    await connection.cancel()
                    return
                }
                self.purpose = offer.purpose
                self.runtime = runtime
                self.connection = connection
                await self.process(await runtime.start(), from: runtime)
                guard self.isCurrent(lifecycle, runtime: runtime) else { return }
                await self.process(await runtime.admitPeer(), from: runtime)
                guard self.isCurrent(lifecycle, runtime: runtime) else { return }
                self.receiveTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.receiveLoop(connection: connection, runtime: runtime)
                }
                self.armExpiry(for: runtime)
            } catch {
                self.failUnlessCancelled(error)
            }
        }
    }

    func decideSAS(matches: Bool) {
        guard let runtime, case .compareSAS(let code) = phase else { return }
        if matches { phase = .waitingForPeerSAS(code) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.process(await runtime.decideSAS(matches: matches), from: runtime)
        }
    }

    /// Keeps the checkbox state equal to what will transfer: selecting a host
    /// pulls in the jump hosts it routes through, and deselecting one drops
    /// anything that can no longer reach its destination intact.
    func setGrantSelected(hostID: UUID, selected: Bool) {
        guard var selection = originSelection, let manifest = originManifest else { return }
        var ids = selection.selectedHostIDs
        if selected {
            ids.insert(hostID)
            ids = BootstrapManifestV2.hostSelectionClosure(ids, jumpChains: manifest.jumpChains)
        } else {
            ids.remove(hostID)
            ids = ids.filter { candidate in
                !BootstrapManifestV2.hostSelectionClosure(
                    [candidate], jumpChains: manifest.jumpChains
                ).contains(hostID)
            }
        }
        selection.selectedHostIDs = ids
        originSelection = selection
        if case .bootstrapOriginApproval = phase { phase = .bootstrapOriginApproval(selection) }
    }

    func setOptionalTransfer(_ transfer: BootstrapOptionalTransfer, selected: Bool) {
        guard var selection = originSelection else { return }
        if selected { selection.selectedOptionalTransfers.insert(transfer) }
        else { selection.selectedOptionalTransfers.remove(transfer) }
        originSelection = selection
        if case .bootstrapOriginApproval = phase { phase = .bootstrapOriginApproval(selection) }
    }

    func approveBootstrapOrigin() {
        guard let runtime, let request = pendingOwnerAuthorization else { return }
        operationStatus = .authorizing
        phase = .transferring
        let lifecycle = lifecycleGeneration
        operationTask?.cancel()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Bind the manifest the sender actually reviewed, not a second
                // export taken after approval.
                guard let manifest = self.originManifest,
                      let selection = self.originSelection,
                      !selection.selectedHostIDs.isEmpty
                else { throw PairingLocalTCPTransportError.network }
                try Task.checkCancellation()
                guard self.isCurrent(lifecycle, runtime: runtime) else { return }
                let approved = try ApprovedBootstrapManifestV2(
                    exportedManifest: manifest,
                    selectedHostIDs: selection.selectedHostIDs,
                    selectedOptionalTransfers: selection.selectedOptionalTransfers
                )
                let binding = try BootstrapTransactionV1.ownerAuthorizationBinding(for: approved)
                let approvedAt = try await self.adapters.freshOwnerApproval(
                    String(localized: "Approve setup transfer to this paired device")
                )
                try Task.checkCancellation()
                guard self.isCurrent(lifecycle, runtime: runtime) else { return }
                let expiresAt = approvedAt.addingTimeInterval(DeviceAccessGrantEngine.maximumGrantLifetime)
                var authorizations: [DeviceAccessGrantEngine.Authorization] = []
                for host in approved.manifest.hosts {
                    let scope = OwnerAuthorizationScope(
                        routeIdentity: try BootstrapTransactionV1.routeIdentity(for: host.id, in: approved.manifest),
                        hostID: host.id,
                        publicKeyFingerprint: request.recipientKey.fingerprint,
                        authorizationBinding: binding
                    )
                    let owner = FreshOwnerAuthorization(
                        attemptID: request.attemptID,
                        policyGeneration: self.policyGeneration,
                        scope: scope,
                        issuedAt: approvedAt,
                        expiresAt: expiresAt
                    )
                    let authorization = try await self.grantEngine.mint(
                        from: owner,
                        expected: OwnerAuthorizationRequest(
                            attemptID: request.attemptID,
                            policyGeneration: self.policyGeneration,
                            scope: scope,
                            expiresAt: expiresAt
                        )
                    )
                    authorizations.append(authorization)
                    try Task.checkCancellation()
                    guard self.isCurrent(lifecycle, runtime: runtime) else {
                        await self.grantEngine.revokeAll()
                        return
                    }
                }
                self.pendingOwnerAuthorization = nil
                self.operationStatus = .transferring
                await self.process(await runtime.provideBootstrapOwnerAuthorizations(
                    authorizations,
                    approvedManifest: approved,
                    using: self.grantEngine,
                    policyGeneration: self.policyGeneration
                ), from: runtime)
            } catch {
                await self.grantEngine.revokeAll()
                self.failUnlessCancelled(error)
            }
        }
    }

    func approveBootstrapRecipientImport() {
        guard let runtime, let manifest = pendingManifest else { return }
        operationStatus = .importing
        phase = .transferring
        let lifecycle = lifecycleGeneration
        operationTask?.cancel()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let recipientPublicKey else {
                    throw PairingLocalTCPTransportError.network
                }
                try Task.checkCancellation()
                guard self.isCurrent(lifecycle, runtime: runtime) else { return }
                let acceptedHostIDs = try await self.adapters.importManifest(manifest, recipientPublicKey)
                // The recipient's own admission policy may exclude hosts; the
                // receipt must report those as not imported rather than copied.
                try Task.checkCancellation()
                guard self.isCurrent(lifecycle, runtime: runtime) else { return }
                self.acceptedHostIDs = Set(acceptedHostIDs)
                self.pendingManifest = nil
                self.operationStatus = .waitingForGrant
                await self.process(await runtime.bootstrapImportDurablyApplied(
                    acceptedHostIDs: acceptedHostIDs,
                    at: Date()
                ), from: runtime)
            } catch {
                self.failUnlessCancelled(error)
            }
        }
    }

    func applicationDidLockOrBackground() {
        guard let runtime else {
            // Camera-only scanning has no runtime/socket yet, but it is still
            // sensitive foreground state and must disappear immediately.
            reset()
            return
        }
        invalidateLifecycle()
        cancelDeliveredContinuationIfNeeded()
        transportClosureExpected = true
        cancelTransport()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.grantEngine.revokeAll()
            await self.process(await runtime.applicationDidLock(), from: runtime)
        }
    }

    /// Any route, credential, or owner-presence policy mutation invalidates
    /// the in-flight attempt before another record or remote SSH mutation can
    /// use stale authorization. Import code adopts its own expected durable
    /// mutation as a new baseline in ContentView.
    func securityPolicyChanged() {
        policyGeneration &+= 1
        if policyGeneration == 0 { policyGeneration = 1 }
        guard let runtime else { return }
        invalidateLifecycle()
        cancelDeliveredContinuationIfNeeded()
        transportClosureExpected = true
        cancelTransport()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.grantEngine.revokeAll()
            await self.process(await runtime.securityPolicyChanged(to: self.policyGeneration), from: runtime)
        }
    }

    func cancel() {
        guard let runtime else {
            reset()
            return
        }
        invalidateLifecycle()
        cancelDeliveredContinuationIfNeeded()
        transportClosureExpected = true
        cancelTransport()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.grantEngine.revokeAll()
            await self.process(await runtime.cancel(), from: runtime)
        }
    }

    /// Called by the existing ContinuationCoordinator after its own durable
    /// acceptance boundary, not when a descriptor merely arrived over TCP.
    func continuationDurablyAccepted(continuationID: UUID, hostID: UUID) {
        guard let runtime,
              continuationReceiptGate.acceptDurable(continuationID: continuationID, hostID: hostID)
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.process(await runtime.continuationDescriptorDurablyAccepted(at: Date()), from: runtime)
        }
    }

    /// Called at the existing render-ready continuation receipt boundary, so
    /// SSH, SSH+tmux, mosh, and mosh+tmux share one exact completion path.
    func continuationConnectionCompleted(continuationID: UUID, hostID: UUID) {
        guard let runtime,
              continuationReceiptGate.acceptCompletion(continuationID: continuationID, hostID: hostID)
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.process(await runtime.continuationConnectionCompleted(hostID: hostID, at: Date()), from: runtime)
        }
    }

    private func receiveLoop(
        connection: PairingTCPRecordConnection,
        runtime: CrossDevicePairingRuntimeV1
    ) async {
        do {
            while !Task.isCancelled {
                await process(await runtime.receive(try await connection.receiveRecord()), from: runtime)
            }
        } catch {
            failUnlessCancelled(error)
        }
    }

    private func process(
        _ events: [CrossDevicePairingEventV1],
        from sourceRuntime: CrossDevicePairingRuntimeV1
    ) async {
        guard runtime === sourceRuntime else { return }
        for event in events {
            guard runtime === sourceRuntime else { return }
            switch event {
            case .qrOffer(let offer):
                do {
                    qrText = try PairingQRTextCodecV1.encode(offerBytes: offer)
                    phase = .showingOffer
                } catch { failUnlessCancelled(error) }
            case .outboundRecord(let record):
                do {
                    guard let connection else { throw PairingLocalTCPTransportError.connectionClosed }
                    try await connection.send(record)
                    try Task.checkCancellation()
                    guard runtime === sourceRuntime else { return }
                } catch {
                    if transportClosureExpected { continue }
                    failUnlessCancelled(error)
                }
            case .sasAvailable(let sas):
                comparedCode = sas.displayValue
                phase = .compareSAS(sas.displayValue)
            case .pairingApproved:
                phase = purpose == .bootstrap || purpose == .setUpAndContinue ? .waitingForSetupChoice : .transferring
                await pairingApproved()
            case .continuationDescriptorReceived(let descriptor):
                await receiveContinuationDescriptor(descriptor)
            case .continuationConnectionRequired(let descriptor):
                // The existing continuation UI received this descriptor before
                // issuing its durable-acceptance callback. Re-delivery here
                // creates a second UI attempt and resets the accepted receipt
                // gate, so the eventual render-ready callback is discarded.
                // setup-and-continue reaches this event without prior delivery.
                if !awaitingContinuationUI {
                    await deliverContinuationDescriptor(descriptor)
                }
            case .continuationCompleted:
                finishAttempt(with: .completed(makeReceipt()))
            case .bootstrapOwnerAuthorizationRequired(let request):
                pendingOwnerAuthorization = request
                do {
                    let manifest = try await adapters.exportManifest(request.peerSupportsAgentCenterEnabled)
                    try Task.checkCancellation()
                    guard runtime === sourceRuntime else { return }
                    let checklist = manifest.hosts.map(BootstrapCredentialChecklistItem.init)
                    let selection = BootstrapGrantSelectionState(
                        peerDisplayName: request.recipientKey.displayName,
                        code: comparedCode,
                        publicKeyName: request.recipientKey.displayName,
                        publicKeyFingerprint: request.recipientKey.fingerprint,
                        // Only a hardware-backed claim may suppress the warning. An
                        // unknown or merely platform-protected claim is not evidence of
                        // hardware protection, and treating it as such would overstate
                        // the safety of the key the user is about to authorize.
                        publicKeyProtection: {
                            switch request.recipientKey.protectionClaim {
                            case .platformHardwareBacked, .platformStrongHardware: .secureEnclave
                            case .softwareExportable, .platformProtected, .unknown: .software
                            }
                        }(),
                        checklist: checklist,
                        // Selection narrows the manifest here, so excluding a
                        // password host would stop it being copied at all.
                        // Everything is copied unless the sender says otherwise.
                        selectedHostIDs: Set(checklist.map(\.id)),
                        selectedOptionalTransfers: []
                    )
                    originManifest = manifest
                    originSelection = selection
                    phase = .bootstrapOriginApproval(selection)
                } catch { failUnlessCancelled(error) }
            case .bootstrapImportRequired(let manifest):
                pendingManifest = manifest
                receivedManifest = manifest
                phase = .bootstrapRecipientImport(manifest.hosts.map(BootstrapCredentialChecklistItem.init))
            case .bootstrapRemoteGrantVerificationRequired(let request):
                operationStatus = .granting
                let results = await adapters.verifyGrants(request)
                guard !Task.isCancelled, let runtime, runtime === sourceRuntime else { return }
                grantResults = results
                acceptedHostIDs = Set(request.acceptance.acceptedHostIDs)
                operationStatus = .recordingAccess
                await process(await runtime.bootstrapRemoteGrantsDurablyVerified(
                    results, at: Date(), policyGeneration: policyGeneration
                ), from: runtime)
            case .bootstrapAccessRecordRequired(let receipt):
                operationStatus = .recordingAccess
                do {
                    guard let recipientPublicKey, let receivedManifest else {
                        throw PairingLocalTCPTransportError.network
                    }
                    try adapters.recordAccess(receipt, recipientPublicKey, receivedManifest)
                    grantResults = receipt.results
                    guard let runtime else { return }
                    await process(await runtime.bootstrapAccessStateDurablyRecorded(at: Date()), from: runtime)
                } catch { failUnlessCancelled(error) }
            case .bootstrapCompleted:
                if let descriptor = deferredDescriptor {
                    deferredDescriptor = nil
                    await deliverContinuationDescriptor(descriptor)
                } else if purpose == .setUpAndContinue {
                    // The sender's setup receipt is only an intermediate
                    // boundary. Keep TCP alive for acceptance and the actual
                    // connection receipt from the receiving device.
                    operationStatus = .awaitingConnection
                    phase = .transferring
                } else {
                    finishAttempt(with: .completed(makeReceipt()))
                }
            case .enrollmentApprovalRequired, .enrollmentInstallationRequired,
                 .enrollmentRecordRequired, .enrollmentCompleted:
                failUnlessCancelled(PairingLocalTCPTransportError.network)
            case .terminal(let code):
                if code != .cancelled || awaitingContinuationUI {
                    cancelDeliveredContinuationIfNeeded()
                }
                finishAttempt(with: code == .cancelled ? .idle : .failed(String(localized:
                    SetupAccessCopy.failure(SetupFlowPresentationV1.failureReason(code.rawValue)))))
            }
        }
    }

    private func pairingApproved() async {
        guard let runtime, let purpose else { return }
        do {
            switch purpose {
            case .continueSession:
                if let descriptor = originDescriptor {
                    await process(await runtime.provideContinuationDescriptor(descriptor), from: runtime)
                }
            case .bootstrap:
                if await runtime.role == .recipient,
                   !Task.isCancelled,
                   self.runtime === runtime {
                    await provideRecipientKey(to: runtime)
                }
            case .setUpAndContinue:
                if let descriptor = originDescriptor {
                    await process(await runtime.provideContinuationDescriptor(descriptor), from: runtime)
                }
            case .enroll:
                throw PairingLocalTCPTransportError.network
            }
        } catch { failUnlessCancelled(error) }
    }

    private func receiveContinuationDescriptor(_ descriptor: ContinuationDescriptorV1) async {
        guard let runtime, let purpose else { return }
        if purpose == .setUpAndContinue {
            deferredDescriptor = descriptor
            await provideRecipientKey(to: runtime)
        } else {
            await deliverContinuationDescriptor(descriptor)
        }
    }

    private func deliverContinuationDescriptor(_ descriptor: ContinuationDescriptorV1) async {
        guard let runtime, let binding = await runtime.continuationTransportBinding() else {
            failUnlessCancelled(PairingLocalTCPTransportError.network)
            return
        }
        guard !Task.isCancelled, self.runtime === runtime else { return }
        guard let continuationID = adapters.receiveDescriptor(descriptor, binding) else {
            await process(await runtime.cancel(), from: runtime)
            return
        }
        continuationReceiptGate.expect(continuationID: continuationID, hostID: descriptor.hostID)
        awaitingContinuationUI = true
    }

    private func provideRecipientKey(to runtime: CrossDevicePairingRuntimeV1) async {
        do {
            let key = try await adapters.recipientKey()
            try Task.checkCancellation()
            guard self.runtime === runtime else { return }
            recipientPublicKey = key
            await process(await runtime.provideBootstrapRecipientPublicKey(key), from: runtime)
        } catch { failUnlessCancelled(error) }
    }

    private func armExpiry(for runtime: CrossDevicePairingRuntimeV1) {
        expiryTask?.cancel()
        expiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await self.process(await runtime.checkExpiration(), from: runtime)
            }
        }
    }

    private func failUnlessCancelled(_ error: Error) {
        guard !Task.isCancelled else { return }
        cancelDeliveredContinuationIfNeeded()
        finishAttempt(with: .failed(error.localizedDescription))
    }

    private func cancelTransport() {
        receiveTask?.cancel()
        receiveTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        listener?.cancel()
        listener = nil
        let connection = connection
        self.connection = nil
        Task { await connection?.cancel() }
    }

    private func reset() {
        invalidateLifecycle()
        cancelDeliveredContinuationIfNeeded()
        cancelTransport()
        clearAttemptState()
        phase = .idle
        Task { await grantEngine.revokeAll() }
    }

    /// Must be called before `finishAttempt`, which clears the state it reads.
    /// Returns nil for a continuation-only attempt, which transfers no setup.
    private func makeReceipt() -> CrossDevicePairingReceipt? {
        let statuses = Dictionary(
            grantResults.map { ($0.hostID, $0.status) },
            uniquingKeysWith: { _, latest in latest }
        )
        func accepted(_ id: UUID) -> Bool? { acceptedHostIDs.map { $0.contains(id) } }
        if let selection = originSelection {
            return CrossDevicePairingReceipt(
                direction: .sent,
                hosts: selection.checklist
                    .filter { selection.selectedHostIDs.contains($0.id) }
                    .map { .init(id: $0.id, name: $0.hostName, status: statuses[$0.id], wasAccepted: accepted($0.id), passwordOnFirstConnect: $0.authenticationHint == .password) },
                optionalCategoryCount: selection.selectedOptionalTransfers.count
            )
        }
        if let manifest = receivedManifest {
            return CrossDevicePairingReceipt(
                direction: .received,
                hosts: manifest.hosts.map { .init(id: $0.id, name: $0.name, status: statuses[$0.id], wasAccepted: accepted($0.id), passwordOnFirstConnect: $0.authenticationHint == .password) },
                optionalCategoryCount: 0
            )
        }
        return nil
    }

    private func finishAttempt(with finalPhase: CrossDevicePairingPresentationPhase) {
        let finalPurpose = purpose
        let finalStage = presentation.currentStage
        invalidateLifecycle()
        cancelTransport()
        clearAttemptState()
        if finalPhase != .idle {
            finishedPurpose = finalPurpose
            stoppedAt = finalStage
        }
        phase = finalPhase
        Task { await grantEngine.revokeAll() }
    }

    private func clearAttemptState() {
        runtime = nil
        qrText = nil
        purpose = nil
        finishedPurpose = nil
        stoppedAt = nil
        operationStatus = .transferring
        originDescriptor = nil
        deferredDescriptor = nil
        pendingManifest = nil
        receivedManifest = nil
        recipientPublicKey = nil
        pendingOwnerAuthorization = nil
        originManifest = nil
        originSelection = nil
        comparedCode = ""
        grantResults = []
        acceptedHostIDs = nil
        continuationReceiptGate.reset()
        awaitingContinuationUI = false
        transportClosureExpected = false
    }

    @discardableResult
    private func beginLifecycle() -> UInt64 {
        operationTask?.cancel()
        operationTask = nil
        lifecycleGeneration &+= 1
        if lifecycleGeneration == 0 { lifecycleGeneration = 1 }
        return lifecycleGeneration
    }

    private func invalidateLifecycle() {
        operationTask?.cancel()
        operationTask = nil
        lifecycleGeneration &+= 1
        if lifecycleGeneration == 0 { lifecycleGeneration = 1 }
    }

    private func isCurrent(
        _ generation: UInt64,
        runtime expectedRuntime: CrossDevicePairingRuntimeV1? = nil
    ) -> Bool {
        guard generation == lifecycleGeneration, !Task.isCancelled else { return false }
        guard let expectedRuntime else { return true }
        return runtime === expectedRuntime
    }

    private func cancelDeliveredContinuationIfNeeded() {
        guard awaitingContinuationUI,
              let continuationID = continuationReceiptGate.expectedContinuationID
        else { return }
        adapters.cancelDescriptor(continuationID)
        continuationReceiptGate.reset()
    }

    private static func randomOpticalSecret() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }
}

private extension CrossDevicePairingPresentationPhase {
    var allowsDurableMutation: Bool {
        switch self {
        case .connecting, .compareSAS, .waitingForPeerSAS, .waitingForSetupChoice, .bootstrapOriginApproval,
             .bootstrapRecipientImport, .transferring:
            return true
        case .idle, .showingOffer, .scanning, .completed, .failed:
            return false
        }
    }
}
