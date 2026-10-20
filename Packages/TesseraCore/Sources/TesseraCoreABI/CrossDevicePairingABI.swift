import Foundation
import TesseraBootstrapCore
import TesseraContinuityCore
import TesseraCrossDeviceCore
import TesseraEnrollmentCore
import TesseraPairingCore
import TesseraProtocolCore
import TesseraSessionCore

/// The intentionally small, transport-neutral C ABI for Pairing v1.  A
/// platform owns QR scanning/rendering, sockets, persistence, and UI; this
/// actor-backed ABI owns the pairing and transaction order.
public struct CrossDeviceABICommandV1: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumPayloadBytes = 1_048_576
    /// Raw socket bytes are base64-encoded inside the bounded canonical JSON
    /// command. Keeping a distinct limit leaves room for that expansion and
    /// the largest generation/envelope while the stream decoder continues to
    /// own the independent aggregate-buffer bound.
    public static let maximumSocketChunkBytes = 786_000

    public enum Kind: String, Codable, Sendable {
        case createOrigin
        case createRecipient
        case start
        case admitPeer
        /// Raw bytes from the local socket. The ABI owns TPR1 fragmentation,
        /// coalescing, and record validation.
        case receiveBytes
        /// Required when the local socket reaches EOF; a partial TPR1 record
        /// is terminal rather than being silently retained.
        case finishStream
        case decideSAS
        case cancel
        case checkExpiration
        case securityPolicyChanged
        case applicationDidLock
        case provideContinuationDescriptor
        case continuationDescriptorDurablyAccepted
        case continuationConnectionCompleted
        case provideBootstrapRecipientPublicKey
        case approveBootstrapManifest
        case bootstrapImportDurablyApplied
        case bootstrapRemoteGrantsDurablyVerified
        case bootstrapAccessStateDurablyRecorded
        case beginEnrollment
        case approveEnrollment
        case enrollmentInstallationDurablyVerified
        case enrollmentRequesterRecordDurablyCommitted
    }

    public let version: Int
    public let kind: Kind
    /// Required on every command.  Creation establishes the generation;
    /// subsequently it is a stale-attempt fence at the ABI boundary.
    public let generation: UInt64
    public let purpose: PairingPurpose?
    public let expiresAt: Int64?
    public let endpointCandidates: [PairingEndpointCandidateV1]?
    public let supportedTransactionVersions: [Int]?
    public let optionalPayloadDigest: Data?
    /// Canonical QR scanner text, never a raw PairingOffer byte sequence.
    public let qrText: String?
    public let bytes: Data?
    public let matches: Bool?
    public let descriptor: Data?
    public let hostID: UUID?
    public let acceptedHostIDs: [UUID]?
    public let grantResults: [BootstrapHostGrantResultV1]?
    public let publicKey: DevicePublicKeyDescriptorV2?
    public let manifest: BootstrapManifestV2?
    public let selectedOptionalTransfers: [String]?
    /// Hosts the sender chose to copy, or nil for every host in the manifest.
    /// Selection narrows the manifest itself, because the pairing transaction
    /// binds the authorization set to exactly the hosts that remain.
    public let selectedHostIDs: [UUID]?
    public let enrollmentRequest: EnrollmentRequestV1?
    public let enrollmentID: UUID?
    public let publicKeyFingerprint: String?
    public let routeIdentity: String?
    public let atMilliseconds: Int64?
    public let issuedAtMilliseconds: Int64?
    public let expiresAuthorizationAtMilliseconds: Int64?
    public let policyGeneration: UInt64?

    private enum CodingKeys: String, CodingKey {
        case version = "v", kind, generation, purpose, expiresAt, endpointCandidates
        case supportedTransactionVersions, optionalPayloadDigest
        case qrText, bytes, matches, descriptor, hostID, acceptedHostIDs
        case grantResults, publicKey, manifest, selectedOptionalTransfers, selectedHostIDs, enrollmentRequest, enrollmentID
        case publicKeyFingerprint, routeIdentity, atMilliseconds, issuedAtMilliseconds
        case expiresAuthorizationAtMilliseconds, policyGeneration
    }

    public init(
        version: Int = Self.currentVersion,
        kind: Kind,
        generation: UInt64,
        purpose: PairingPurpose? = nil,
        expiresAt: Int64? = nil,
        endpointCandidates: [PairingEndpointCandidateV1]? = nil,
        supportedTransactionVersions: [Int]? = nil,
        optionalPayloadDigest: Data? = nil,
        qrText: String? = nil,
        bytes: Data? = nil,
        matches: Bool? = nil,
        descriptor: Data? = nil,
        hostID: UUID? = nil,
        acceptedHostIDs: [UUID]? = nil,
        grantResults: [BootstrapHostGrantResultV1]? = nil,
        publicKey: DevicePublicKeyDescriptorV2? = nil,
        manifest: BootstrapManifestV2? = nil,
        selectedOptionalTransfers: [String]? = nil,
        selectedHostIDs: [UUID]? = nil,
        enrollmentRequest: EnrollmentRequestV1? = nil,
        enrollmentID: UUID? = nil,
        publicKeyFingerprint: String? = nil,
        routeIdentity: String? = nil,
        atMilliseconds: Int64? = nil,
        issuedAtMilliseconds: Int64? = nil,
        expiresAuthorizationAtMilliseconds: Int64? = nil,
        policyGeneration: UInt64? = nil
    ) {
        self.version = version; self.kind = kind; self.generation = generation
        self.purpose = purpose; self.expiresAt = expiresAt; self.endpointCandidates = endpointCandidates
        self.supportedTransactionVersions = supportedTransactionVersions
        self.optionalPayloadDigest = optionalPayloadDigest
        self.qrText = qrText
        self.bytes = bytes; self.matches = matches; self.descriptor = descriptor; self.hostID = hostID
        self.acceptedHostIDs = acceptedHostIDs; self.grantResults = grantResults; self.publicKey = publicKey
        self.manifest = manifest; self.selectedOptionalTransfers = selectedOptionalTransfers
        self.selectedHostIDs = selectedHostIDs
        self.enrollmentRequest = enrollmentRequest; self.enrollmentID = enrollmentID
        self.publicKeyFingerprint = publicKeyFingerprint; self.routeIdentity = routeIdentity
        self.atMilliseconds = atMilliseconds; self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAuthorizationAtMilliseconds = expiresAuthorizationAtMilliseconds; self.policyGeneration = policyGeneration
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder.crossDeviceABI.encode(self)
        guard data.count <= Self.maximumPayloadBytes else { throw CrossDeviceABIError.payloadTooLarge(data.count) }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty else { throw CrossDeviceABIError.emptyPayload }
        guard data.count <= maximumPayloadBytes else { throw CrossDeviceABIError.payloadTooLarge(data.count) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        // The C boundary accepts exactly one canonical representation, so an
        // adapter cannot smuggle ignored fields or alternate JSON spellings.
        guard try value.encoded() == data else { throw CrossDeviceABIError.nonCanonicalPayload }
        return value
    }

    public func validate() throws {
        guard version == Self.currentVersion else { throw CrossDeviceABIError.unsupportedVersion(version) }
        let present = Set([
            purpose == nil ? nil : "purpose", expiresAt == nil ? nil : "expiresAt",
            endpointCandidates == nil ? nil : "endpointCandidates", supportedTransactionVersions == nil ? nil : "supportedTransactionVersions",
            optionalPayloadDigest == nil ? nil : "optionalPayloadDigest", qrText == nil ? nil : "qrText",
            bytes == nil ? nil : "bytes", matches == nil ? nil : "matches", descriptor == nil ? nil : "descriptor",
            hostID == nil ? nil : "hostID", acceptedHostIDs == nil ? nil : "acceptedHostIDs",
            grantResults == nil ? nil : "grantResults", publicKey == nil ? nil : "publicKey",
            manifest == nil ? nil : "manifest", selectedOptionalTransfers == nil ? nil : "selectedOptionalTransfers",
            selectedHostIDs == nil ? nil : "selectedHostIDs",
            enrollmentRequest == nil ? nil : "enrollmentRequest", enrollmentID == nil ? nil : "enrollmentID",
            publicKeyFingerprint == nil ? nil : "publicKeyFingerprint", routeIdentity == nil ? nil : "routeIdentity",
            atMilliseconds == nil ? nil : "atMilliseconds", issuedAtMilliseconds == nil ? nil : "issuedAtMilliseconds",
            expiresAuthorizationAtMilliseconds == nil ? nil : "expiresAuthorizationAtMilliseconds",
            policyGeneration == nil ? nil : "policyGeneration",
        ].compactMap { $0 })
        let allowed: Set<String>
        switch kind {
        case .createOrigin: allowed = ["purpose", "expiresAt", "endpointCandidates", "supportedTransactionVersions", "optionalPayloadDigest"]
        case .createRecipient: allowed = ["qrText", "supportedTransactionVersions"]
        case .receiveBytes: allowed = ["bytes"]
        case .decideSAS: allowed = ["matches"]
        case .provideContinuationDescriptor: allowed = ["descriptor"]
        case .continuationDescriptorDurablyAccepted, .bootstrapAccessStateDurablyRecorded: allowed = ["atMilliseconds"]
        case .continuationConnectionCompleted: allowed = ["hostID", "atMilliseconds"]
        case .provideBootstrapRecipientPublicKey: allowed = ["publicKey"]
        case .approveBootstrapManifest: allowed = ["manifest", "selectedOptionalTransfers", "selectedHostIDs", "issuedAtMilliseconds", "expiresAuthorizationAtMilliseconds", "policyGeneration"]
        case .bootstrapImportDurablyApplied: allowed = ["acceptedHostIDs", "atMilliseconds"]
        case .bootstrapRemoteGrantsDurablyVerified: allowed = ["grantResults", "atMilliseconds", "policyGeneration"]
        case .beginEnrollment: allowed = ["enrollmentRequest"]
        case .approveEnrollment: allowed = ["routeIdentity", "issuedAtMilliseconds", "expiresAuthorizationAtMilliseconds", "policyGeneration"]
        case .enrollmentInstallationDurablyVerified: allowed = ["enrollmentID", "publicKeyFingerprint", "routeIdentity", "atMilliseconds"]
        case .enrollmentRequesterRecordDurablyCommitted: allowed = ["enrollmentID", "publicKeyFingerprint", "atMilliseconds"]
        case .securityPolicyChanged: allowed = ["policyGeneration"]
        case .start, .admitPeer, .cancel, .checkExpiration, .applicationDidLock, .finishStream: allowed = []
        }
        guard present.isSubset(of: allowed) else { throw CrossDeviceABIError.invalidField }
        func requiredDate() throws -> Date {
            guard let atMilliseconds else { throw CrossDeviceABIError.missingField }
            return Date(timeIntervalSince1970: TimeInterval(atMilliseconds) / 1_000)
        }
        switch kind {
        case .createOrigin:
            guard purpose != nil, expiresAt != nil,
                  let endpointCandidates, !endpointCandidates.isEmpty,
                  let supportedTransactionVersions, !supportedTransactionVersions.isEmpty
            else { throw CrossDeviceABIError.missingField }
            guard endpointCandidates.count <= PairingOfferV1.maximumEndpointCandidates,
                  optionalPayloadDigest.map({ $0.count <= 64 }) ?? true
            else { throw CrossDeviceABIError.invalidField }
        case .createRecipient:
            guard let qrText, !qrText.isEmpty,
                  qrText.utf8.count <= PairingQRTextCodecV1.maximumEncodedCharacters,
                  let supportedTransactionVersions, !supportedTransactionVersions.isEmpty
            else { throw CrossDeviceABIError.missingField }
        case .receiveBytes:
            guard let bytes, !bytes.isEmpty,
                  bytes.count <= Self.maximumSocketChunkBytes
            else { throw CrossDeviceABIError.invalidField }
        case .decideSAS: guard matches != nil else { throw CrossDeviceABIError.missingField }
        case .provideContinuationDescriptor:
            guard let descriptor, !descriptor.isEmpty, descriptor.count <= ContinuationDescriptorV1.maximumHandoffBytes else { throw CrossDeviceABIError.invalidField }
        case .continuationDescriptorDurablyAccepted, .bootstrapAccessStateDurablyRecorded:
            _ = try requiredDate()
        case .continuationConnectionCompleted:
            guard hostID != nil else { throw CrossDeviceABIError.missingField }; _ = try requiredDate()
        case .provideBootstrapRecipientPublicKey:
            guard let publicKey else { throw CrossDeviceABIError.missingField }; try publicKey.validate()
        case .approveBootstrapManifest:
            guard let manifest, let selectedOptionalTransfers, policyGeneration != nil,
                  let issuedAtMilliseconds, let expiresAuthorizationAtMilliseconds,
                  !manifest.hosts.isEmpty,
                  Set(selectedOptionalTransfers).count == selectedOptionalTransfers.count,
                  selectedOptionalTransfers.allSatisfy({ BootstrapOptionalTransfer(rawValue: $0) != nil }),
                  issuedAtMilliseconds <= expiresAuthorizationAtMilliseconds
            else { throw CrossDeviceABIError.invalidField }
            if let selectedHostIDs {
                guard !selectedHostIDs.isEmpty,
                      Set(selectedHostIDs).count == selectedHostIDs.count,
                      Set(selectedHostIDs).isSubset(of: Set(manifest.hosts.map(\.id)))
                else { throw CrossDeviceABIError.invalidField }
            }
            try manifest.validate()
        case .bootstrapImportDurablyApplied:
            guard let acceptedHostIDs, acceptedHostIDs.count <= BootstrapManifestV2.maximumHostCount else { throw CrossDeviceABIError.invalidField }; _ = try requiredDate()
        case .bootstrapRemoteGrantsDurablyVerified:
            guard let grantResults, grantResults.count <= BootstrapManifestV2.maximumHostCount,
                  policyGeneration != nil else { throw CrossDeviceABIError.missingField }
            _ = try requiredDate()
        case .beginEnrollment:
            guard let enrollmentRequest else { throw CrossDeviceABIError.missingField }; try enrollmentRequest.validate()
        case .approveEnrollment:
            guard let routeIdentity, !routeIdentity.isEmpty, policyGeneration != nil,
                  let issuedAtMilliseconds, let expiresAuthorizationAtMilliseconds,
                  issuedAtMilliseconds <= expiresAuthorizationAtMilliseconds
            else { throw CrossDeviceABIError.missingField }
        case .enrollmentInstallationDurablyVerified:
            guard enrollmentID != nil, let publicKeyFingerprint, !publicKeyFingerprint.isEmpty,
                  let routeIdentity, !routeIdentity.isEmpty else { throw CrossDeviceABIError.missingField }
            _ = try requiredDate()
        case .enrollmentRequesterRecordDurablyCommitted:
            guard enrollmentID != nil, let publicKeyFingerprint, !publicKeyFingerprint.isEmpty else { throw CrossDeviceABIError.missingField }
            _ = try requiredDate()
        case .securityPolicyChanged: guard policyGeneration != nil else { throw CrossDeviceABIError.missingField }
        case .start, .admitPeer, .cancel, .checkExpiration, .applicationDidLock, .finishStream: break
        }
    }
}

public enum CrossDeviceABIError: Error, Equatable, Sendable {
    case unsupportedVersion(Int), emptyPayload, payloadTooLarge(Int), missingField, invalidField
    case nonCanonicalPayload, invalidHandle, unconfigured, alreadyConfigured, staleGeneration
    case unsupportedOwnerAuthorizationCapability, unsupportedEnrollmentCapability, protocolTerminated
}

private extension CrossDeviceABICommandV1 {
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(atMilliseconds!) / 1_000)
    }
}

public struct CrossDeviceABIEventV1: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public enum Kind: String, Codable, Sendable {
        case configured, qrOffer, outboundRecord, sasAvailable, pairingApproved
        case continuationDescriptorReceived, continuationConnectionRequired, continuationCompleted
        case bootstrapOwnerAuthorizationRequired, bootstrapImportRequired
        case bootstrapRemoteGrantVerificationRequired, bootstrapAccessRecordRequired, bootstrapCompleted
        case enrollmentApprovalRequired, enrollmentInstallationRequired, enrollmentRecordRequired, enrollmentCompleted
        case terminal, commandRejected, destroyed
    }
    public let version: Int
    public let kind: Kind
    public let generation: UInt64
    public let attemptID: UUID?
    public let payload: Data?
    public let code: String?
    private enum CodingKeys: String, CodingKey { case version = "v", kind, generation, attemptID, payload, code }
    public init(version: Int = Self.currentVersion, kind: Kind, generation: UInt64, attemptID: UUID? = nil, payload: Data? = nil, code: String? = nil) {
        self.version = version; self.kind = kind; self.generation = generation; self.attemptID = attemptID; self.payload = payload; self.code = code
    }
    public func encoded() throws -> Data {
        let data = try JSONEncoder.crossDeviceABI.encode(self)
        guard data.count <= CrossDeviceABICommandV1.maximumPayloadBytes else { throw CrossDeviceABIError.payloadTooLarge(data.count) }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty else { throw CrossDeviceABIError.emptyPayload }
        guard data.count <= CrossDeviceABICommandV1.maximumPayloadBytes else { throw CrossDeviceABIError.payloadTooLarge(data.count) }
        let event = try JSONDecoder().decode(Self.self, from: data)
        guard event.version == Self.currentVersion, try event.encoded() == data else { throw CrossDeviceABIError.nonCanonicalPayload }
        return event
    }
}

public final class CrossDeviceABIRuntimeV1: @unchecked Sendable {
    public typealias EventSink = @Sendable (Data) -> Void
    private let lock = NSLock()
    private var isDestroyed = false
    private var suppressCallbacks = false
    private var tail = Task<Void, Never> {}
    private let destroyCompletion = DispatchGroup()
    private let callbackScopeToken = UUID().uuidString
    private let eventSink: EventSink
    private var runtime: CrossDevicePairingRuntimeV1?
    private var generation: UInt64?
    private let ownerAuthorizer = CrossDeviceABIOwnerAuthorizer()
    private let grantEngine = DeviceAccessGrantEngine()
    private var pendingBootstrapRecipientKey: DevicePublicKeyDescriptorV2?
    private var pendingEnrollmentRequest: EnrollmentRequestV1?
    private let streamDecoder = PairingStreamRecordDecoderV1()
    private var protocolTerminated = false

    public init(eventSink: @escaping EventSink) { self.eventSink = eventSink }

    public func submit(_ data: Data) {
        enqueue { [self] in
            do { try await apply(CrossDeviceABICommandV1.decode(data)) }
            catch { emitRejection(error) }
        }
    }

    public func destroy() {
        let reentrant = isExecutingEventSinkOnCurrentThread
        let shouldWait = !reentrant
        lock.lock()
        if !isDestroyed {
            isDestroyed = true; suppressCallbacks = reentrant; destroyCompletion.enter()
            let previous = tail
            tail = Task { [self] in
                await previous.value
                if !reentrant { try? deliver(CrossDeviceABIEventV1(kind: .destroyed, generation: generation ?? 0)) }
                destroyCompletion.leave()
            }
        }
        lock.unlock()
        if shouldWait { destroyCompletion.wait() }
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !isDestroyed else { return }
        let previous = tail
        tail = Task { await previous.value; await operation() }
    }

    private func apply(_ command: CrossDeviceABICommandV1) async throws {
        switch command.kind {
        case .createOrigin:
            guard runtime == nil else { throw CrossDeviceABIError.alreadyConfigured }
            guard let purpose = command.purpose else { throw CrossDeviceABIError.missingField }
            let configured = try CrossDevicePairingRuntimeV1(origin: .init(
                purpose: purpose, expiresAt: command.expiresAt!, endpointCandidates: command.endpointCandidates!,
                // The optical secret is generated inside the shared ABI and
                // becomes observable only within the outbound QR offer.
                oneTimeOpticalSecret: Self.freshOpticalSecret(),
                supportedTransactionVersions: command.supportedTransactionVersions!, optionalPayloadDigest: command.optionalPayloadDigest
            ), generation: command.generation, enrollmentAdapter: enrollmentAdapter(for: purpose))
            runtime = configured; generation = command.generation
            try deliver(CrossDeviceABIEventV1(kind: .configured, generation: command.generation, attemptID: await configured.attemptID))
        case .createRecipient:
            guard runtime == nil else { throw CrossDeviceABIError.alreadyConfigured }
            let offerBytes: Data
            offerBytes = try PairingQRTextCodecV1.decodeOfferBytes(command.qrText!)
            let offer = try PairingOfferV1.decode(offerBytes)
            let configured = try CrossDevicePairingRuntimeV1(recipient: .init(
                encodedOffer: offerBytes, supportedTransactionVersions: command.supportedTransactionVersions!
            ), generation: command.generation, enrollmentAdapter: enrollmentAdapter(for: offer.purpose))
            runtime = configured; generation = command.generation
            try deliver(CrossDeviceABIEventV1(kind: .configured, generation: command.generation, attemptID: await configured.attemptID))
        default:
            guard let runtime, generation == command.generation else { throw runtime == nil ? CrossDeviceABIError.unconfigured : CrossDeviceABIError.staleGeneration }
            guard !protocolTerminated else { throw CrossDeviceABIError.protocolTerminated }
            let events: [CrossDevicePairingEventV1]
            switch command.kind {
            case .start: events = await runtime.start()
            case .admitPeer: events = await runtime.admitPeer()
            case .receiveBytes:
                do {
                    var output: [CrossDevicePairingEventV1] = []
                    for record in try streamDecoder.append(command.bytes!) {
                        output += await runtime.receive(record)
                    }
                    events = output
                } catch {
                    try await terminateMalformedStream(runtime, generation: command.generation)
                    return
                }
            case .finishStream:
                do {
                    try streamDecoder.finish()
                    let state = await runtime.state
                    if case .completed = state { events = []; break }
                    if case .terminal = state { events = []; break }
                    try await terminatePeerDisconnected(runtime, generation: command.generation)
                    return
                } catch {
                    try await terminateMalformedStream(runtime, generation: command.generation)
                    return
                }
            case .decideSAS: events = await runtime.decideSAS(matches: command.matches!)
            case .cancel: events = await runtime.cancel()
            case .checkExpiration: events = await runtime.checkExpiration()
            case .securityPolicyChanged:
                await revokeABIOwnedAuthorizations()
                events = await runtime.securityPolicyChanged(to: command.policyGeneration!)
            case .applicationDidLock:
                await revokeABIOwnedAuthorizations()
                events = await runtime.applicationDidLock()
            case .provideContinuationDescriptor: events = await runtime.provideContinuationDescriptor(try ContinuationDescriptorV1(encoded: command.descriptor!))
            case .continuationDescriptorDurablyAccepted: events = await runtime.continuationDescriptorDurablyAccepted(at: command.date)
            case .continuationConnectionCompleted: events = await runtime.continuationConnectionCompleted(hostID: command.hostID!, at: command.date)
            case .provideBootstrapRecipientPublicKey: events = await runtime.provideBootstrapRecipientPublicKey(command.publicKey!)
            case .approveBootstrapManifest:
                guard let recipientKey = pendingBootstrapRecipientKey else { throw CrossDeviceABIError.unsupportedOwnerAuthorizationCapability }
                let selected = Set(command.selectedOptionalTransfers!.compactMap(BootstrapOptionalTransfer.init(rawValue:)))
                let approved = try ApprovedBootstrapManifestV2(
                    exportedManifest: command.manifest!,
                    selectedHostIDs: command.selectedHostIDs.map(Set.init),
                    selectedOptionalTransfers: selected
                )
                let binding = try BootstrapTransactionV1.ownerAuthorizationBinding(for: approved)
                let attemptID = await runtime.attemptID
                let issued = Date(timeIntervalSince1970: TimeInterval(command.issuedAtMilliseconds!) / 1_000)
                let expires = Date(timeIntervalSince1970: TimeInterval(command.expiresAuthorizationAtMilliseconds!) / 1_000)
                try validateFreshAuthorizationEvidence(issuedAt: issued, expiresAt: expires)
                var authorizations: [DeviceAccessGrantEngine.Authorization] = []
                do {
                    for host in approved.manifest.hosts {
                        let scope = OwnerAuthorizationScope(
                            routeIdentity: try BootstrapTransactionV1.routeIdentity(for: host.id, in: approved.manifest),
                            hostID: host.id,
                            publicKeyFingerprint: recipientKey.fingerprint,
                            authorizationBinding: binding
                        )
                        authorizations.append(try await grantEngine.mint(
                            from: FreshOwnerAuthorization(attemptID: attemptID, policyGeneration: command.policyGeneration!, scope: scope, issuedAt: issued, expiresAt: expires),
                            expected: OwnerAuthorizationRequest(attemptID: attemptID, policyGeneration: command.policyGeneration!, scope: scope, expiresAt: expires)
                        ))
                    }
                    events = await runtime.provideBootstrapOwnerAuthorizations(authorizations, approvedManifest: approved, using: grantEngine, policyGeneration: command.policyGeneration!)
                } catch {
                    for authorization in authorizations { await grantEngine.revoke(authorization) }
                    throw error
                }
            case .bootstrapImportDurablyApplied: events = await runtime.bootstrapImportDurablyApplied(acceptedHostIDs: command.acceptedHostIDs!, at: command.date)
            case .bootstrapRemoteGrantsDurablyVerified: events = await runtime.bootstrapRemoteGrantsDurablyVerified(command.grantResults!, at: command.date, policyGeneration: command.policyGeneration!)
            case .bootstrapAccessStateDurablyRecorded: events = await runtime.bootstrapAccessStateDurablyRecorded(at: command.date)
            case .beginEnrollment: events = await runtime.beginEnrollment(command.enrollmentRequest!)
            case .approveEnrollment:
                guard let request = pendingEnrollmentRequest else { throw CrossDeviceABIError.unsupportedEnrollmentCapability }
                let issued = Date(timeIntervalSince1970: TimeInterval(command.issuedAtMilliseconds!) / 1_000)
                let expires = Date(timeIntervalSince1970: TimeInterval(command.expiresAuthorizationAtMilliseconds!) / 1_000)
                try validateFreshAuthorizationEvidence(issuedAt: issued, expiresAt: expires)
                let scope = OwnerAuthorizationScope(routeIdentity: command.routeIdentity!, hostID: request.hostID, publicKeyFingerprint: request.publicKey.fingerprint)
                ownerAuthorizer.supply(
                    attemptID: request.id, policyGeneration: command.policyGeneration!, scope: scope,
                    issuedAt: issued, expiresAt: expires
                )
                events = await runtime.approveEnrollment(scope: scope, policyGeneration: command.policyGeneration!, expiresAt: expires)
            case .enrollmentInstallationDurablyVerified:
                events = await runtime.enrollmentInstallationDurablyVerified(.init(enrollmentID: command.enrollmentID!, publicKeyFingerprint: command.publicKeyFingerprint!, routeIdentity: command.routeIdentity!, recordedAt: command.date))
            case .enrollmentRequesterRecordDurablyCommitted:
                events = await runtime.enrollmentRequesterRecordDurablyCommitted(.init(enrollmentID: command.enrollmentID!, publicKeyFingerprint: command.publicKeyFingerprint!, recordedAt: command.date))
            case .createOrigin, .createRecipient: fatalError("handled above")
            }
            for event in events {
                if case .bootstrapOwnerAuthorizationRequired(let request) = event { pendingBootstrapRecipientKey = request.recipientKey }
                if case .enrollmentApprovalRequired(let request) = event { pendingEnrollmentRequest = request }
                if case .terminal = event {
                    protocolTerminated = true
                    await revokeABIOwnedAuthorizations()
                    pendingBootstrapRecipientKey = nil
                    pendingEnrollmentRequest = nil
                    ownerAuthorizer.clear()
                }
                if case .bootstrapCompleted = event { pendingBootstrapRecipientKey = nil }
                if case .enrollmentCompleted = event {
                    pendingEnrollmentRequest = nil
                    ownerAuthorizer.clear()
                }
                try deliver(map(event, generation: command.generation, attemptID: await runtime.attemptID))
            }
        }
    }

    private func map(_ event: CrossDevicePairingEventV1, generation: UInt64, attemptID: UUID) throws -> CrossDeviceABIEventV1 {
        switch event {
        case .qrOffer(let bytes):
            return .init(kind: .qrOffer, generation: generation, attemptID: attemptID, payload: Data(try PairingQRTextCodecV1.encode(offerBytes: bytes).utf8))
        case .outboundRecord(let record): return .init(kind: .outboundRecord, generation: generation, attemptID: attemptID, payload: try record.encoded())
        case .sasAvailable(let sas): return .init(kind: .sasAvailable, generation: generation, attemptID: attemptID, code: sas.digits)
        case .pairingApproved: return .init(kind: .pairingApproved, generation: generation, attemptID: attemptID)
        case .continuationDescriptorReceived(let value): return try payloadEvent(.continuationDescriptorReceived, value, generation, attemptID)
        case .continuationConnectionRequired(let value): return try payloadEvent(.continuationConnectionRequired, value, generation, attemptID)
        case .continuationCompleted(let value): return try payloadEvent(.continuationCompleted, value, generation, attemptID)
        case .bootstrapOwnerAuthorizationRequired(let value):
            let projection = CrossDeviceBootstrapAuthorizationProjection(attemptID: value.attemptID, recipientKey: value.recipientKey, operation: value.operation, transactionVersion: value.transactionVersion)
            return try payloadEvent(.bootstrapOwnerAuthorizationRequired, projection, generation, attemptID)
        case .bootstrapImportRequired(let value): return try payloadEvent(.bootstrapImportRequired, value, generation, attemptID)
        case .bootstrapRemoteGrantVerificationRequired(let value):
            let projection = CrossDeviceBootstrapGrantProjection(
                attemptID: value.attemptID,
                recipientKey: value.recipientKey,
                manifest: value.approvedManifest.manifest,
                selectedOptionalTransfers: value.approvedManifest.selectedOptionalTransfers.map(\.rawValue).sorted(),
                acceptance: value.acceptance
            )
            return try payloadEvent(.bootstrapRemoteGrantVerificationRequired, projection, generation, attemptID)
        case .bootstrapAccessRecordRequired(let value): return try payloadEvent(.bootstrapAccessRecordRequired, value, generation, attemptID)
        case .bootstrapCompleted(let value): return try payloadEvent(.bootstrapCompleted, value, generation, attemptID)
        case .enrollmentApprovalRequired(let value): return try payloadEvent(.enrollmentApprovalRequired, value, generation, attemptID)
        case .enrollmentInstallationRequired(let value):
            return try payloadEvent(.enrollmentInstallationRequired, CrossDeviceEnrollmentInstallProjection(enrollmentID: value.enrollmentID, authorizedKeysLine: value.authorizedKeysLine), generation, attemptID)
        case .enrollmentRecordRequired(let value): return try payloadEvent(.enrollmentRecordRequired, value, generation, attemptID)
        case .enrollmentCompleted(let value):
            return try payloadEvent(.enrollmentCompleted, CrossDeviceEnrollmentCompletionProjection(enrollmentID: value.enrollmentID, completedAtMilliseconds: Int64(value.completedAt.timeIntervalSince1970 * 1_000)), generation, attemptID)
        case .terminal(let code): return .init(kind: .terminal, generation: generation, attemptID: attemptID, code: code.rawValue)
        }
    }

    private func payloadEvent<T: Encodable>(_ kind: CrossDeviceABIEventV1.Kind, _ value: T, _ generation: UInt64, _ attemptID: UUID) throws -> CrossDeviceABIEventV1 {
        .init(kind: kind, generation: generation, attemptID: attemptID, payload: try JSONEncoder.crossDeviceABI.encode(value))
    }
    private func deliver(_ event: CrossDeviceABIEventV1) throws { deliver(try event.encoded()) }
    private func deliver(_ data: Data) {
        lock.lock(); let shouldDeliver = !suppressCallbacks; lock.unlock(); guard shouldDeliver else { return }
        let dictionary = Thread.current.threadDictionary; let previous = dictionary[Self.callbackScopeKey]
        dictionary[Self.callbackScopeKey] = callbackScopeToken
        defer { if let previous { dictionary[Self.callbackScopeKey] = previous } else { dictionary.removeObject(forKey: Self.callbackScopeKey) } }
        eventSink(data)
    }
    private func emitRejection(_ error: Error) {
        if let data = try? CrossDeviceABIEventV1(kind: .commandRejected, generation: generation ?? 0, code: Self.errorCode(error)).encoded() { deliver(data) }
    }
    private var isExecutingEventSinkOnCurrentThread: Bool { Thread.current.threadDictionary[Self.callbackScopeKey] as? String == callbackScopeToken }
    private static let callbackScopeKey = "com.bambouville.tessera.cross-device-abi.callback-runtime"
    private static func errorCode(_ error: Error) -> String {
        switch error {
        case let error as CrossDeviceABIError:
            switch error {
            case .staleGeneration: return "stale_generation"
            case .unsupportedEnrollmentCapability: return "unsupported_enrollment_capability"
            case .unsupportedOwnerAuthorizationCapability: return "unsupported_owner_authorization_capability"
            case .protocolTerminated: return "protocol_terminated"
            default: return "abi_\(String(describing: error))"
            }
        case let error as OwnerAuthorizationError:
            switch error {
            case .notFresh: return "stale_authorization"
            case .expired: return "expired_authorization"
            case .staleAttempt: return "stale_attempt"
            case .stalePolicy: return "stale_policy"
            case .scopeMismatch: return "authorization_scope_mismatch"
            case .alreadyConsumed: return "authorization_already_consumed"
            case .revoked: return "authorization_revoked"
            case .lifetimeTooLong: return "authorization_lifetime_too_long"
            }
        case is PairingQRTextErrorV1: return "invalid_qr_text"
        default: return "command_failed"
        }
    }

    private static func freshOpticalSecret() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<PairingOfferV1.minimumOpticalSecretBytes).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }

    private func enrollmentAdapter(for purpose: PairingPurpose) -> CrossDeviceEnrollmentAdapterV1? {
        guard purpose == .enroll else { return nil }
        return CrossDeviceEnrollmentAdapterV1(authorizer: ownerAuthorizer, grantEngine: grantEngine)
    }

    /// The platform attests successful LocalAuthentication to this ABI; the
    /// ABI does not infer biometric hardware from timestamps. It validates
    /// that approval evidence against ABI-owned wall time, then mints the
    /// exact one-shot authorization internally.
    private func validateFreshAuthorizationEvidence(issuedAt: Date, expiresAt: Date) throws {
        let now = Date()
        let age = now.timeIntervalSince(issuedAt)
        guard age >= -DeviceAccessGrantEngine.maximumAuthorizationFutureSkew,
              age <= DeviceAccessGrantEngine.maximumFreshAuthorizationAge else {
            throw OwnerAuthorizationError.notFresh
        }
        guard now < expiresAt else { throw OwnerAuthorizationError.expired }
        guard expiresAt.timeIntervalSince(now) <= DeviceAccessGrantEngine.maximumGrantLifetime else {
            throw OwnerAuthorizationError.lifetimeTooLong
        }
    }

    private func revokeABIOwnedAuthorizations() async {
        await grantEngine.revokeAll()
    }

    private func terminateMalformedStream(
        _ runtime: CrossDevicePairingRuntimeV1,
        generation: UInt64
    ) async throws {
        protocolTerminated = true
        let attemptID = await runtime.attemptID
        // Close the peer-visible authenticated attempt, but project the local
        // terminal cause accurately instead of reclassifying malformed wire
        // bytes as a user cancellation.
        for event in await runtime.cancel() {
            if case .outboundRecord = event {
                try deliver(map(event, generation: generation, attemptID: attemptID))
            }
        }
        pendingBootstrapRecipientKey = nil
        pendingEnrollmentRequest = nil
        ownerAuthorizer.clear()
        await revokeABIOwnedAuthorizations()
        try deliver(CrossDeviceABIEventV1(
            kind: .terminal,
            generation: generation,
            attemptID: attemptID,
            code: CrossDeviceTerminalCodeV1.malformedOrReplay.rawValue
        ))
    }

    private func terminatePeerDisconnected(
        _ runtime: CrossDevicePairingRuntimeV1,
        generation: UInt64
    ) async throws {
        protocolTerminated = true
        let attemptID = await runtime.attemptID
        for event in await runtime.cancel() {
            if case .outboundRecord = event {
                try deliver(map(event, generation: generation, attemptID: attemptID))
            }
        }
        pendingBootstrapRecipientKey = nil
        pendingEnrollmentRequest = nil
        ownerAuthorizer.clear()
        await revokeABIOwnedAuthorizations()
        try deliver(CrossDeviceABIEventV1(
            kind: .terminal,
            generation: generation,
            attemptID: attemptID,
            code: "peerDisconnected"
        ))
    }
}

private final class CrossDeviceABIOwnerAuthorizer: @unchecked Sendable, FreshOwnerAuthorizing {
    private struct Evidence: Sendable { let attemptID: UUID; let policyGeneration: UInt64; let scope: OwnerAuthorizationScope; let issuedAt: Date; let expiresAt: Date }
    private let lock = NSLock()
    private var evidence: Evidence?
    func clear() { lock.lock(); evidence = nil; lock.unlock() }
    func supply(attemptID: UUID, policyGeneration: UInt64, scope: OwnerAuthorizationScope, issuedAt: Date, expiresAt: Date) { lock.lock(); evidence = Evidence(attemptID: attemptID, policyGeneration: policyGeneration, scope: scope, issuedAt: issuedAt, expiresAt: expiresAt); lock.unlock() }
    func authorize(_ request: OwnerAuthorizationRequest) async throws -> FreshOwnerAuthorization {
        let evidence = lock.withLock { () -> Evidence? in
            let pending = self.evidence
            self.evidence = nil
            return pending
        }
        guard let evidence,
              evidence.attemptID == request.attemptID,
              evidence.policyGeneration == request.policyGeneration,
              evidence.scope == request.scope,
              evidence.expiresAt == request.expiresAt
        else { throw OwnerAuthorizationError.scopeMismatch }
        return FreshOwnerAuthorization(attemptID: request.attemptID, policyGeneration: request.policyGeneration, scope: request.scope, issuedAt: evidence.issuedAt, expiresAt: evidence.expiresAt)
    }
}

private struct CrossDeviceBootstrapAuthorizationProjection: Codable, Sendable {
    let attemptID: UUID; let recipientKey: DevicePublicKeyDescriptorV2; let operation: String; let transactionVersion: Int
}
private struct CrossDeviceBootstrapGrantProjection: Codable, Sendable {
    let attemptID: UUID
    let recipientKey: DevicePublicKeyDescriptorV2
    let manifest: BootstrapManifestV2
    let selectedOptionalTransfers: [String]
    let acceptance: BootstrapImportAcceptanceV1
}
private struct CrossDeviceEnrollmentInstallProjection: Codable, Sendable { let enrollmentID: UUID; let authorizedKeysLine: String }
private struct CrossDeviceEnrollmentCompletionProjection: Codable, Sendable { let enrollmentID: UUID; let completedAtMilliseconds: Int64 }
private extension JSONEncoder { static var crossDeviceABI: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder } }

public typealias TesseraCrossDeviceABIEventCallback = @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void
private final class CCrossDeviceABIRuntime: @unchecked Sendable {
    let runtime: CrossDeviceABIRuntimeV1
    init(callback: @escaping TesseraCrossDeviceABIEventCallback, context: UnsafeMutableRawPointer?) {
        let box = CrossDeviceCallbackBox(callback: callback, context: context)
        runtime = CrossDeviceABIRuntimeV1 { data in data.withUnsafeBytes { raw in box.callback(raw.bindMemory(to: UInt8.self).baseAddress, data.count, box.context) } }
    }
}
private final class CrossDeviceCallbackBox: @unchecked Sendable { let callback: TesseraCrossDeviceABIEventCallback; let context: UnsafeMutableRawPointer?; init(callback: @escaping TesseraCrossDeviceABIEventCallback, context: UnsafeMutableRawPointer?) { self.callback = callback; self.context = context } }
private enum CCrossDeviceABIRegistry {
    static let lock = NSLock(); static var nextToken: UInt = 1; static var runtimes: [UInt: CCrossDeviceABIRuntime] = [:]
    static func insert(_ runtime: CCrossDeviceABIRuntime) -> UnsafeMutableRawPointer { lock.lock(); defer { lock.unlock() }; let token = nextToken; nextToken &+= 1; runtimes[token] = runtime; return UnsafeMutableRawPointer(bitPattern: token)! }
    static func withRuntime<T>(_ handle: UnsafeMutableRawPointer?, _ body: (CCrossDeviceABIRuntime) -> T) -> T? { guard let token = handle.map({ UInt(bitPattern: $0) }) else { return nil }; lock.lock(); defer { lock.unlock() }; guard let runtime = runtimes[token] else { return nil }; return body(runtime) }
    static func remove(_ handle: UnsafeMutableRawPointer?) -> CCrossDeviceABIRuntime? { guard let token = handle.map({ UInt(bitPattern: $0) }) else { return nil }; lock.lock(); defer { lock.unlock() }; return runtimes.removeValue(forKey: token) }
}
@_cdecl("tessera_cross_device_abi_version") public func tesseraCrossDeviceABIVersion() -> UInt32 { UInt32(CrossDeviceABICommandV1.currentVersion) }
@_cdecl("tessera_cross_device_abi_max_payload_bytes") public func tesseraCrossDeviceABIMaxPayloadBytes() -> Int { CrossDeviceABICommandV1.maximumPayloadBytes }
@_cdecl("tessera_cross_device_runtime_create") public func tesseraCrossDeviceRuntimeCreate(callback: @escaping TesseraCrossDeviceABIEventCallback, context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer { CCrossDeviceABIRegistry.insert(CCrossDeviceABIRuntime(callback: callback, context: context)) }
@_cdecl("tessera_cross_device_runtime_send") public func tesseraCrossDeviceRuntimeSend(handle: UnsafeMutableRawPointer?, bytes: UnsafePointer<UInt8>?, count: Int) -> Int32 { guard let handle, let bytes, count > 0, count <= CrossDeviceABICommandV1.maximumPayloadBytes else { return -1 }; guard CCrossDeviceABIRegistry.withRuntime(handle, { $0.runtime.submit(Data(bytes: bytes, count: count)) }) != nil else { return -2 }; return 0 }
@_cdecl("tessera_cross_device_runtime_destroy") public func tesseraCrossDeviceRuntimeDestroy(handle: UnsafeMutableRawPointer?) { CCrossDeviceABIRegistry.remove(handle)?.runtime.destroy() }
