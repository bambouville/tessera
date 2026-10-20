import Foundation
import TesseraBootstrapCore
import TesseraContinuityCore
import TesseraEnrollmentCore
import TesseraPairingCore
import TesseraProtocolCore
import TesseraSessionCore

public enum CrossDeviceTerminalCodeV1: String, Equatable, Sendable {
    case cancelled
    case expired
    case sasRejected
    case peerAborted
    case policyChanged
    case applicationLocked
    case invalidOrder
    case malformedOrReplay
    case failed
}

/// Platform adapters consume these values in order. It contains no platform
/// APIs: QR rendering, sockets, persistence, biometric UI, and connections
/// are all explicit adapter responsibilities.
public enum CrossDevicePairingEventV1: Sendable {
    case qrOffer(Data)
    case outboundRecord(PairingStreamRecordV1)
    case sasAvailable(PairingShortAuthenticationStringV1)
    case pairingApproved
    case continuationDescriptorReceived(ContinuationDescriptorV1)
    case continuationConnectionRequired(ContinuationDescriptorV1)
    case continuationCompleted(ContinuationConnectionReceiptV1)
    case bootstrapOwnerAuthorizationRequired(CrossDeviceBootstrapAuthorizationRequestV1)
    case bootstrapImportRequired(BootstrapManifestV2)
    case bootstrapRemoteGrantVerificationRequired(CrossDeviceBootstrapGrantRequestV1)
    case bootstrapAccessRecordRequired(BootstrapGrantReceiptV1)
    case bootstrapCompleted(BootstrapCompletionV1)
    case enrollmentApprovalRequired(EnrollmentRequestV1)
    case enrollmentInstallationRequired(EnrollmentInstallGrant)
    case enrollmentRecordRequired(EnrollmentRequestV1)
    case enrollmentCompleted(EnrollmentCompletionReceipt)
    case terminal(CrossDeviceTerminalCodeV1)
}

public struct CrossDeviceBootstrapAuthorizationRequestV1: Equatable, Sendable {
    public let attemptID: UUID
    public let recipientKey: DevicePublicKeyDescriptorV2
    public let operation: String
    public let transactionVersion: Int
    public var peerSupportsAgentCenterEnabled: Bool { transactionVersion == 2 }

    public init(attemptID: UUID, recipientKey: DevicePublicKeyDescriptorV2, transactionVersion: Int = 1) {
        self.attemptID = attemptID
        self.recipientKey = recipientKey
        self.transactionVersion = transactionVersion
        operation = BootstrapTransactionV1.ownerAuthorizationOperation
    }
}

/// Complete public, authorization-bound input for a platform installer. The
/// adapter still owns SSH and persistence, but it cannot substitute a key,
/// route, or manifest after the recipient's durable import acceptance.
public struct CrossDeviceBootstrapGrantRequestV1: Equatable, Sendable {
    public let attemptID: UUID
    public let recipientKey: DevicePublicKeyDescriptorV2
    public let approvedManifest: ApprovedBootstrapManifestV2
    public let acceptance: BootstrapImportAcceptanceV1

    public init(
        attemptID: UUID,
        recipientKey: DevicePublicKeyDescriptorV2,
        approvedManifest: ApprovedBootstrapManifestV2,
        acceptance: BootstrapImportAcceptanceV1
    ) {
        self.attemptID = attemptID
        self.recipientKey = recipientKey
        self.approvedManifest = approvedManifest
        self.acceptance = acceptance
    }
}

public enum CrossDevicePairingRuntimeStateV1: Equatable, Sendable {
    case handshaking
    case awaitingSAS
    case activeContinuation
    case activeBootstrap
    case activeEnrollment
    case completed
    case terminal(CrossDeviceTerminalCodeV1)
}

/// One attempt only. This actor wraps pairing plus transaction ordering so a
/// platform adapter cannot accidentally start a transaction before the same
/// approved transcript has authenticated its purpose and version.
public actor CrossDevicePairingRuntimeV1 {
    public let role: PairingRoleV1
    public let purpose: PairingPurpose
    public let generation: UInt64
    public let attemptID: UUID

    private let originDriver: PairingOriginDriverV1?
    private let recipientDriver: PairingRecipientDriverV1?
    private var stateStorage: CrossDevicePairingRuntimeStateV1 = .handshaking
    private var initialPending: [CrossDevicePairingEventV1]
    private var session: PairingSessionV1?
    private var continuation: ContinuationTransactionV1?
    private var bootstrap: BootstrapTransactionV1?
    private var bootstrapRecipientKey: DevicePublicKeyDescriptorV2?
    private var approvedBootstrapManifest: ApprovedBootstrapManifestV2?
    private var setupBootstrapCompleted = false
    private let enrollmentAdapter: CrossDeviceEnrollmentAdapterV1?
    private var enrollmentTransaction: EnrollmentTransactionV1?
    private var enrollmentStateMachine: EnrollmentStateMachine?
    private var terminalEmitted = false
    private var invalidationEpoch: UInt64 = 0

    public init(
        origin configuration: PairingOriginDriverConfigurationV1,
        generation: UInt64 = 0,
        enrollmentAdapter: CrossDeviceEnrollmentAdapterV1? = nil,
        now: @escaping @Sendable () -> Int64 = { PairingHandshakeV1.unixTimeNow() }
    ) throws {
        let driver = try PairingOriginDriverV1(configuration: configuration, now: now)
        role = .origin
        purpose = configuration.purpose
        self.generation = generation
        attemptID = driver.offer.offerID
        originDriver = driver
        recipientDriver = nil
        self.enrollmentAdapter = enrollmentAdapter
        initialPending = [.qrOffer(driver.offerBytes)]
    }

    public init(
        recipient configuration: PairingRecipientDriverConfigurationV1,
        generation: UInt64 = 0,
        enrollmentAdapter: CrossDeviceEnrollmentAdapterV1? = nil,
        now: @escaping @Sendable () -> Int64 = { PairingHandshakeV1.unixTimeNow() }
    ) throws {
        let driver = try PairingRecipientDriverV1(configuration: configuration, now: now)
        role = .recipient
        purpose = driver.offer.purpose
        self.generation = generation
        attemptID = driver.offer.offerID
        originDriver = nil
        recipientDriver = driver
        self.enrollmentAdapter = enrollmentAdapter
        initialPending = [.outboundRecord(driver.initialRecord)]
    }

    public var state: CrossDevicePairingRuntimeStateV1 { stateStorage }

    /// Process-local provenance for the existing shared continuation receive
    /// state machine. This value is intentionally not Codable and is available
    /// only while an authenticated continuation transaction is active.
    public func continuationTransportBinding() -> ContinuationTransportBinding? {
        guard stateStorage == .activeContinuation, let session else { return nil }
        switch purpose {
        case .continueSession:
            return .authenticatedPairing(
                transcriptHash: session.transcriptHash,
                purpose: .continueSession
            )
        case .setUpAndContinue:
            guard setupBootstrapCompleted else { return nil }
            return .authenticatedPairing(
                transcriptHash: session.transcriptHash,
                purpose: .setUpAndContinue
            )
        case .bootstrap, .enroll:
            return nil
        }
    }

    /// Delivers the QR offer or recipient commitment exactly once.
    public func start() -> [CrossDevicePairingEventV1] {
        guard !isTerminal else { return [] }
        let output = initialPending
        initialPending = []
        return output
    }

    /// Reserves the one-shot attempt for the adapter's accepted or connected
    /// byte stream. Calling this before transport ownership is established is
    /// optional, because the first record also admits the peer atomically.
    public func admitPeer() -> [CrossDevicePairingEventV1] {
        guard !isTerminal else { return [] }
        do {
            if let originDriver { try originDriver.admitPeer() }
            if let recipientDriver { try recipientDriver.admitPeer() }
            return []
        } catch { return fail(error) }
    }

    public func receive(_ record: PairingStreamRecordV1) async -> [CrossDevicePairingEventV1] {
        guard !isTerminal else { return [] }
        if session == nil {
            do {
                let records = try receiveHandshake(record)
                var output = records.map(CrossDevicePairingEventV1.outboundRecord)
                if let sas = currentSAS, stateStorage != .awaitingSAS {
                    stateStorage = .awaitingSAS
                    output.append(.sasAvailable(sas))
                }
                if let terminal = currentDriverTerminalCode {
                    return output + terminate(terminal)
                }
                output += try activateIfApproved()
                return output
            } catch { return fail(error) }
        }
        guard record.kind == .authenticatedPairingFrame else { return fail(CrossDeviceRuntimeError.invalidOrder) }
        return await receiveAuthenticatedFrame(record.payload)
    }

    public func decideSAS(matches: Bool) -> [CrossDevicePairingEventV1] {
        guard !isTerminal else { return [] }
        do {
            let record = try decideHandshakeSAS(matches: matches)
            var output: [CrossDevicePairingEventV1] = [.outboundRecord(record)]
            if !matches { return output + terminate(.sasRejected) }
            output += try activateIfApproved()
            return output
        } catch { return fail(error) }
    }

    public func cancel() async -> [CrossDevicePairingEventV1] {
        guard !isTerminal else { return [] }
        let epoch = invalidationEpoch
        if let enrollmentTransaction, let enrollmentStateMachine {
            let message = try? await enrollmentStateMachine.cancel()
            guard epoch == invalidationEpoch, !isTerminal else { return [] }
            if let message,
               let record = try? authenticatedRecord(enrollmentTransaction.seal(message)) {
                return [.outboundRecord(record)] + terminate(.cancelled)
            }
        }
        guard epoch == invalidationEpoch, !isTerminal else { return [] }
        var output: [CrossDevicePairingEventV1] = []
        if let record = originDriver?.cancel() ?? recipientDriver?.cancel() {
            output.append(.outboundRecord(record))
        }
        return output + terminate(.cancelled)
    }

    public func securityPolicyChanged(to generation: UInt64) async -> [CrossDevicePairingEventV1] {
        _ = generation
        guard !isTerminal else { return [] }
        let epoch = invalidationEpoch
        let message = await enrollmentStateMachine?.securityPolicyChanged()
        guard epoch == invalidationEpoch, !isTerminal else { return [] }
        return invalidateWithEnrollmentFailure(.policyChanged, message: message)
    }

    public func applicationDidLock() async -> [CrossDevicePairingEventV1] {
        guard !isTerminal else { return [] }
        let epoch = invalidationEpoch
        let message = await enrollmentStateMachine?.applicationDidLock()
        guard epoch == invalidationEpoch, !isTerminal else { return [] }
        return invalidateWithEnrollmentFailure(.applicationLocked, message: message)
    }

    /// Foreground adapters call this from their offer-expiry timer. Expiry is
    /// otherwise also enforced at every handshake/session operation.
    public func checkExpiration() -> [CrossDevicePairingEventV1] {
        guard !isTerminal else { return [] }
        _ = originDriver?.state ?? recipientDriver?.state
        guard currentDriverExpired else { return [] }
        return terminate(.expired)
    }

    public func provideContinuationDescriptor(
        _ descriptor: ContinuationDescriptorV1
    ) -> [CrossDevicePairingEventV1] {
        guard !isTerminal, var continuation, bootstrap == nil else {
            return isTerminal ? [] : fail(CrossDeviceRuntimeError.invalidOrder)
        }
        do {
            let frame = try continuation.makeDescriptor(descriptor)
            self.continuation = continuation
            try beginSetupBootstrapIfNeeded()
            return [.outboundRecord(try authenticatedRecord(frame))]
        } catch { return fail(error) }
    }

    public func continuationDescriptorDurablyAccepted(at date: Date) -> [CrossDevicePairingEventV1] {
        guard !isTerminal, var continuation, bootstrap == nil else {
            return isTerminal ? [] : fail(CrossDeviceRuntimeError.invalidOrder)
        }
        do {
            let frame = try continuation.descriptorDurablyAccepted(at: date)
            let descriptor = try continuationDescriptor(from: continuation)
            self.continuation = continuation
            return [.outboundRecord(try authenticatedRecord(frame)), .continuationConnectionRequired(descriptor)]
        } catch { return fail(error) }
    }

    public func continuationConnectionCompleted(
        hostID: UUID,
        at date: Date
    ) -> [CrossDevicePairingEventV1] {
        guard !isTerminal, var continuation else {
            return isTerminal ? [] : fail(CrossDeviceRuntimeError.invalidOrder)
        }
        do {
            let frame = try continuation.connectionCompleted(hostID: hostID, at: date)
            self.continuation = continuation
            return [.outboundRecord(try authenticatedRecord(frame))]
        } catch { return fail(error) }
    }

    public func provideBootstrapRecipientPublicKey(
        _ key: DevicePublicKeyDescriptorV2
    ) -> [CrossDevicePairingEventV1] {
        guard !isTerminal, var bootstrap else {
            return isTerminal ? [] : fail(CrossDeviceRuntimeError.invalidOrder)
        }
        do {
            let frame = try bootstrap.makeRecipientPublicKey(key)
            self.bootstrap = bootstrap
            return [.outboundRecord(try authenticatedRecord(frame))]
        } catch { return fail(error) }
    }

    public func provideBootstrapOwnerAuthorizations(
        _ authorizations: [DeviceAccessGrantEngine.Authorization],
        approvedManifest: ApprovedBootstrapManifestV2,
        using grantEngine: DeviceAccessGrantEngine,
        policyGeneration: UInt64
    ) async -> [CrossDevicePairingEventV1] {
        guard !isTerminal, var bootstrap else {
            return isTerminal ? [] : fail(CrossDeviceRuntimeError.invalidOrder)
        }
        let epoch = invalidationEpoch
        do {
            let proof = try await bootstrap.consumeOwnerAuthorizations(
                authorizations,
                approvedManifest: approvedManifest,
                using: grantEngine
            )
            let manifestFrames = try bootstrap.makeManifestMessages(
                approvedManifest,
                policyGeneration: policyGeneration
            )
            guard epoch == invalidationEpoch, !isTerminal else { return [] }
            self.bootstrap = bootstrap
            self.approvedBootstrapManifest = approvedManifest
            return try ([proof] + manifestFrames).map { .outboundRecord(try authenticatedRecord($0)) }
        } catch { return fail(error) }
    }

    public func bootstrapImportDurablyApplied(
        acceptedHostIDs: [UUID],
        at date: Date
    ) -> [CrossDevicePairingEventV1] {
        guard !isTerminal, var bootstrap else {
            return isTerminal ? [] : fail(CrossDeviceRuntimeError.invalidOrder)
        }
        do {
            let frame = try bootstrap.importDurablyApplied(acceptedHostIDs: acceptedHostIDs, at: date)
            self.bootstrap = bootstrap
            return [.outboundRecord(try authenticatedRecord(frame))]
        } catch { return fail(error) }
    }

    public func bootstrapRemoteGrantsDurablyVerified(
        _ results: [BootstrapHostGrantResultV1],
        at date: Date,
        policyGeneration: UInt64
    ) -> [CrossDevicePairingEventV1] {
        guard !isTerminal, var bootstrap else {
            return isTerminal ? [] : fail(CrossDeviceRuntimeError.invalidOrder)
        }
        do {
            let frame = try bootstrap.remoteGrantsDurablyVerified(
                results, at: date, policyGeneration: policyGeneration
            )
            self.bootstrap = bootstrap
            return [.outboundRecord(try authenticatedRecord(frame))]
        } catch { return fail(error) }
    }

    public func bootstrapAccessStateDurablyRecorded(at date: Date) -> [CrossDevicePairingEventV1] {
        guard !isTerminal, var bootstrap else {
            return isTerminal ? [] : fail(CrossDeviceRuntimeError.invalidOrder)
        }
        do {
            let frame = try bootstrap.accessStateDurablyRecorded(at: date)
            self.bootstrap = bootstrap
            return [.outboundRecord(try authenticatedRecord(frame))]
        } catch { return fail(error) }
    }

    public func beginEnrollment(_ request: EnrollmentRequestV1) async -> [CrossDevicePairingEventV1] {
        guard !isTerminal else { return [] }
        guard role == .recipient,
              let enrollmentTransaction,
              let enrollmentStateMachine else { return fail(CrossDeviceRuntimeError.invalidOrder) }
        let epoch = invalidationEpoch
        do {
            let message = try await enrollmentStateMachine.request(request)
            guard epoch == invalidationEpoch, !isTerminal else { return [] }
            return [.outboundRecord(try authenticatedRecord(enrollmentTransaction.seal(message)))]
        } catch { return fail(error) }
    }

    public func approveEnrollment(
        scope: OwnerAuthorizationScope,
        policyGeneration: UInt64,
        expiresAt: Date
    ) async -> [CrossDevicePairingEventV1] {
        guard !isTerminal else { return [] }
        guard role == .origin, let enrollmentStateMachine else {
            return fail(CrossDeviceRuntimeError.invalidOrder)
        }
        let epoch = invalidationEpoch
        do {
            _ = try await enrollmentStateMachine.approve(
                scope: scope, policyGeneration: policyGeneration, expiresAt: expiresAt
            )
            guard epoch == invalidationEpoch, !isTerminal else { return [] }
            let grant = try await enrollmentStateMachine.beginInstallation(
                policyGeneration: policyGeneration,
                scope: scope
            )
            guard epoch == invalidationEpoch, !isTerminal else { return [] }
            return [.enrollmentInstallationRequired(grant)]
        } catch { return fail(error) }
    }

    public func enrollmentInstallationDurablyVerified(
        _ receipt: DurableEnrollmentInstallReceipt
    ) async -> [CrossDevicePairingEventV1] {
        guard !isTerminal else { return [] }
        guard role == .origin,
              let enrollmentTransaction,
              let enrollmentStateMachine else { return fail(CrossDeviceRuntimeError.invalidOrder) }
        let epoch = invalidationEpoch
        do {
            let message = try await enrollmentStateMachine.installationDurablyVerified(receipt)
            guard epoch == invalidationEpoch, !isTerminal else { return [] }
            return [.outboundRecord(try authenticatedRecord(enrollmentTransaction.seal(message)))]
        } catch { return fail(error) }
    }

    public func enrollmentRequesterRecordDurablyCommitted(
        _ receipt: DurableEnrollmentRecordReceipt
    ) async -> [CrossDevicePairingEventV1] {
        guard !isTerminal else { return [] }
        guard role == .recipient,
              let enrollmentTransaction,
              let enrollmentStateMachine else { return fail(CrossDeviceRuntimeError.invalidOrder) }
        let epoch = invalidationEpoch
        do {
            let message = try await enrollmentStateMachine.requesterRecordDurablyCommitted(receipt)
            guard epoch == invalidationEpoch, !isTerminal else { return [] }
            return [.outboundRecord(try authenticatedRecord(enrollmentTransaction.seal(message)))]
        } catch { return fail(error) }
    }

    private var isTerminal: Bool {
        switch stateStorage {
        case .completed, .terminal: return true
        default: return false
        }
    }

    private var currentSAS: PairingShortAuthenticationStringV1? {
        originDriver?.sas ?? recipientDriver?.sas
    }

    private var currentDriverTerminalCode: CrossDeviceTerminalCodeV1? {
        let driverState = originDriver?.state ?? recipientDriver?.state
        guard case .invalidated(let reason) = driverState else { return nil }
        switch reason {
        case .cancelled: return .peerAborted
        case .expired: return .expired
        case .rejected: return .sasRejected
        case .failed: return .failed
        }
    }

    private func receiveHandshake(_ record: PairingStreamRecordV1) throws -> [PairingStreamRecordV1] {
        if let originDriver { return try originDriver.receive(record) }
        if let recipientDriver { return try recipientDriver.receive(record) }
        return []
    }

    private func decideHandshakeSAS(matches: Bool) throws -> PairingStreamRecordV1 {
        if let originDriver { return try originDriver.decideSAS(matches: matches) }
        if let recipientDriver { return try recipientDriver.decideSAS(matches: matches) }
        throw PairingHandshakeDriverErrorV1.invalidated
    }

    private func activateIfApproved() throws -> [CrossDevicePairingEventV1] {
        guard session == nil,
              let approved = originDriver?.approvedSession ?? recipientDriver?.approvedSession else { return [] }
        session = approved
        let output: [CrossDevicePairingEventV1] = [.pairingApproved]
        switch purpose {
        case .continueSession:
            continuation = try ContinuationTransactionV1(session: approved)
            stateStorage = .activeContinuation
        case .bootstrap:
            bootstrap = try BootstrapTransactionV1(session: approved)
            stateStorage = .activeBootstrap
        case .setUpAndContinue:
            continuation = try ContinuationTransactionV1(session: approved)
            stateStorage = .activeContinuation
        case .enroll:
            guard let enrollmentAdapter else { throw CrossDeviceRuntimeError.invalidPurpose }
            let transaction = try EnrollmentTransactionV1(session: approved)
            enrollmentStateMachine = try EnrollmentStateMachine(
                transaction: transaction,
                authorizer: enrollmentAdapter.authorizer,
                grantEngine: enrollmentAdapter.grantEngine,
                now: enrollmentAdapter.now
            )
            enrollmentTransaction = transaction
            stateStorage = .activeEnrollment
        }
        return output
    }

    private func receiveAuthenticatedFrame(_ frame: Data) async -> [CrossDevicePairingEventV1] {
        guard let session else { return fail(CrossDeviceRuntimeError.invalidOrder) }
        // A peer abort is a generic pairing envelope and intentionally has
        // precedence over transaction routing.
        do {
            if let bootstrap {
                return try receiveBootstrap(frame, bootstrap: bootstrap)
            }
            if let continuation {
                return try receiveContinuation(frame, continuation: continuation)
            }
            if let enrollmentTransaction, let enrollmentStateMachine {
                return try await receiveEnrollment(
                    frame, transaction: enrollmentTransaction, stateMachine: enrollmentStateMachine
                )
            }
            _ = session
            return fail(CrossDeviceRuntimeError.invalidOrder)
        } catch { return fail(error) }
    }

    private func receiveContinuation(
        _ frame: Data,
        continuation initial: ContinuationTransactionV1
    ) throws -> [CrossDevicePairingEventV1] {
        var transaction = initial
        switch transaction.state {
        case .awaitingDescriptor:
            let descriptor = try transaction.receiveDescriptor(frame)
            self.continuation = transaction
            try beginSetupBootstrapIfNeeded()
            return [.continuationDescriptorReceived(descriptor)]
        case .awaitingAcceptance:
            _ = try transaction.receiveAcceptance(frame)
            self.continuation = transaction
            return []
        case .awaitingConnection:
            let acknowledgement = try transaction.receiveConnectionReceipt(frame)
            self.continuation = transaction
            return [
                .outboundRecord(try authenticatedRecord(acknowledgement)),
                .continuationCompleted(try completedContinuation(transaction)),
            ] + completeRuntimeIfFinished()
        case .awaitingCompletionAcknowledgement:
            let receipt = try transaction.receiveCompletionAcknowledgement(frame)
            self.continuation = transaction
            return [.continuationCompleted(receipt)] + completeRuntimeIfFinished()
        default:
            throw CrossDeviceRuntimeError.invalidOrder
        }
    }

    private func receiveBootstrap(
        _ frame: Data,
        bootstrap initial: BootstrapTransactionV1
    ) throws -> [CrossDevicePairingEventV1] {
        var transaction = initial
        switch transaction.state {
        case .awaitingRecipientKey:
            let key = try transaction.receiveRecipientPublicKey(frame)
            self.bootstrap = transaction
            bootstrapRecipientKey = key
            return [.bootstrapOwnerAuthorizationRequired(
                CrossDeviceBootstrapAuthorizationRequestV1(attemptID: attemptID, recipientKey: key, transactionVersion: transaction.version)
            )]
        case .awaitingAuthorizationProof:
            _ = try transaction.receiveAuthorizationProof(frame)
            self.bootstrap = transaction
            return []
        case .awaitingManifest, .receivingManifest:
            if let manifest = try transaction.receiveManifestMessage(frame) {
                self.bootstrap = transaction
                return [.bootstrapImportRequired(manifest)]
            }
            self.bootstrap = transaction
            return []
        case .awaitingImportAcceptance:
            let acceptance = try transaction.receiveImportAcceptance(frame)
            self.bootstrap = transaction
            guard let bootstrapRecipientKey, let approvedBootstrapManifest else {
                throw CrossDeviceRuntimeError.invalidOrder
            }
            return [.bootstrapRemoteGrantVerificationRequired(
                CrossDeviceBootstrapGrantRequestV1(
                    attemptID: attemptID,
                    recipientKey: bootstrapRecipientKey,
                    approvedManifest: approvedBootstrapManifest,
                    acceptance: acceptance
                )
            )]
        case .awaitingGrantReceipt:
            let receipt = try transaction.receiveGrantReceipt(frame)
            self.bootstrap = transaction
            return [.bootstrapAccessRecordRequired(receipt)]
        case .awaitingGrantAcknowledgement:
            let completionFrame = try transaction.receiveGrantAcknowledgement(frame)
            self.bootstrap = transaction
            return [.outboundRecord(try authenticatedRecord(completionFrame))]
                + (try bootstrapFinished(completedBootstrap(transaction)))
        case .awaitingCompletion:
            let completion = try transaction.receiveCompletion(frame)
            bootstrap = transaction
            return try bootstrapFinished(completion)
        default:
            throw CrossDeviceRuntimeError.invalidOrder
        }
    }

    private func bootstrapFinished(_ completion: BootstrapCompletionV1) throws -> [CrossDevicePairingEventV1] {
        let output: [CrossDevicePairingEventV1] = [.bootstrapCompleted(completion)]
        bootstrap = nil
        bootstrapRecipientKey = nil
        approvedBootstrapManifest = nil
        if purpose == .setUpAndContinue, continuation != nil {
            setupBootstrapCompleted = true
            stateStorage = .activeContinuation
        } else {
            stateStorage = .completed
        }
        return output
    }

    private func beginSetupBootstrapIfNeeded() throws {
        guard purpose == .setUpAndContinue, bootstrap == nil, let session else { return }
        bootstrap = try BootstrapTransactionV1(session: session)
        stateStorage = .activeBootstrap
    }

    private func receiveEnrollment(
        _ frame: Data,
        transaction: EnrollmentTransactionV1,
        stateMachine: EnrollmentStateMachine
    ) async throws -> [CrossDevicePairingEventV1] {
        let epoch = invalidationEpoch
        let message = try transaction.open(frame)
        let response = await stateMachine.receive(message)
        guard epoch == invalidationEpoch, !isTerminal else { return [] }
        let enrollmentState = await stateMachine.state
        guard epoch == invalidationEpoch, !isTerminal else { return [] }
        var output: [CrossDevicePairingEventV1] = []
        var terminal: CrossDeviceTerminalCodeV1?
        switch enrollmentState {
        case .awaitingApproval(let request): output.append(.enrollmentApprovalRequired(request))
        case .recordingRequester(let request): output.append(.enrollmentRecordRequired(request))
        case .completed(let receipt):
            output.append(.enrollmentCompleted(receipt))
            stateStorage = .completed
        case .cancelled: terminal = .peerAborted
        case .rejected, .failed: terminal = .failed
        default: break
        }
        if let response { output.append(.outboundRecord(try authenticatedRecord(transaction.seal(response)))) }
        if let terminal { output += terminate(terminal) }
        return output
    }

    private func completeRuntimeIfFinished() -> [CrossDevicePairingEventV1] {
        guard let continuation else { return [] }
        if case .completed = continuation.state { stateStorage = .completed }
        return []
    }

    private func authenticatedRecord(_ frame: Data) throws -> PairingStreamRecordV1 {
        try PairingStreamRecordV1(kind: .authenticatedPairingFrame, payload: frame)
    }

    private func continuationDescriptor(
        from transaction: ContinuationTransactionV1
    ) throws -> ContinuationDescriptorV1 {
        if case .awaitingConnection(let descriptor) = transaction.state { return descriptor }
        throw CrossDeviceRuntimeError.invalidOrder
    }

    private func completedContinuation(
        _ transaction: ContinuationTransactionV1
    ) throws -> ContinuationConnectionReceiptV1 {
        if case .completed(let receipt) = transaction.state { return receipt }
        throw CrossDeviceRuntimeError.invalidOrder
    }

    private func completedBootstrap(
        _ transaction: BootstrapTransactionV1
    ) throws -> BootstrapCompletionV1 {
        if case .completed(let completion) = transaction.state { return completion }
        throw CrossDeviceRuntimeError.invalidOrder
    }

    private func invalidateWithEnrollmentFailure(
        _ code: CrossDeviceTerminalCodeV1,
        message: EnrollmentMessageV1?
    ) -> [CrossDevicePairingEventV1] {
        guard !isTerminal else { return [] }
        if let message, let enrollmentTransaction,
           let record = try? authenticatedRecord(enrollmentTransaction.seal(message)) {
            return [.outboundRecord(record)] + terminate(code)
        }
        var output: [CrossDevicePairingEventV1] = []
        if let record = originDriver?.cancel() ?? recipientDriver?.cancel() {
            output.append(.outboundRecord(record))
        }
        return output + terminate(code)
    }

    private func fail(_ error: Error) -> [CrossDevicePairingEventV1] {
        let code: CrossDeviceTerminalCodeV1
        if let pairing = error as? PairingError {
            switch pairing {
            case .offerExpired: code = .expired
            case .pairingRejected: code = .sasRejected
            case .sessionAborted: code = .peerAborted
            case .replayedFrame, .outOfOrder, .authenticationFailed: code = .malformedOrReplay
            default: code = .invalidOrder
            }
        } else if case .remoteAbort = error as? ContinuationTransactionError {
            code = .peerAborted
        } else if case .remoteAbort = error as? BootstrapTransactionError {
            code = .peerAborted
        } else if let driver = error as? PairingHandshakeDriverErrorV1,
                  driver == .invalidated {
            code = currentDriverExpired ? .expired : .failed
        } else { code = .invalidOrder }
        return terminate(code)
    }

    private var currentDriverExpired: Bool {
        if case .invalidated(.expired) = originDriver?.state { return true }
        if case .invalidated(.expired) = recipientDriver?.state { return true }
        return false
    }

    private func terminate(_ code: CrossDeviceTerminalCodeV1) -> [CrossDevicePairingEventV1] {
        guard !terminalEmitted else { return [] }
        terminalEmitted = true
        invalidationEpoch &+= 1
        initialPending = []
        session = nil
        continuation = nil
        bootstrap = nil
        bootstrapRecipientKey = nil
        approvedBootstrapManifest = nil
        setupBootstrapCompleted = false
        enrollmentTransaction = nil
        enrollmentStateMachine = nil
        stateStorage = .terminal(code)
        return [.terminal(code)]
    }
}

public struct CrossDeviceEnrollmentAdapterV1: @unchecked Sendable {
    public let authorizer: any FreshOwnerAuthorizing
    public let grantEngine: DeviceAccessGrantEngine?
    public let now: @Sendable () -> Date

    public init(
        authorizer: any FreshOwnerAuthorizing,
        grantEngine: DeviceAccessGrantEngine? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authorizer = authorizer
        self.grantEngine = grantEngine
        self.now = now
    }
}

private enum CrossDeviceRuntimeError: Error { case invalidPurpose, invalidOrder }
