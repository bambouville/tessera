import Crypto
import Foundation
import TesseraEnrollmentCore
import TesseraPairingCore
import TesseraProtocolCore
import TesseraSessionCore

public enum BootstrapTransactionMessageKindV1: String, Codable, CaseIterable, Sendable {
    case recipientPublicKey
    case authorizationProof
    case manifestStart
    case manifestChunk
    case manifestEnd
    case importAcceptance
    case grantReceipt
    case grantAcknowledgement
    case completion
    case abort
}

/// Closed transaction envelope carried inside a pairing `transactionMessage`.
/// `body` is canonical JSON for exactly one of the public body types below.
public struct BootstrapTransactionMessageV1: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumEncodedBytes = 30 * 1_024

    public let version: Int
    public let transactionID: UUID
    public let kind: BootstrapTransactionMessageKindV1
    public let body: Data

    public init(
        version: Int = BootstrapTransactionMessageV1.currentVersion,
        transactionID: UUID,
        kind: BootstrapTransactionMessageKindV1,
        body: Data
    ) {
        self.version = version
        self.transactionID = transactionID
        self.kind = kind
        self.body = body
    }

    public func encoded() throws -> Data { try encoded(expectedVersion: Self.currentVersion) }

    func encoded(expectedVersion: Int) throws -> Data {
        guard [1, 2].contains(expectedVersion), version == expectedVersion else {
            throw BootstrapTransactionError.unsupportedVersion(version)
        }
        guard body.count <= BootstrapTransactionChunkV1.maximumBodyBytes else {
            throw BootstrapTransactionError.messageTooLarge(body.count)
        }
        let data = try BootstrapTransactionCodec.encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw BootstrapTransactionError.messageTooLarge(data.count)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self { try decode(data, expectedVersion: currentVersion) }

    static func decode(_ data: Data, expectedVersion: Int) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw BootstrapTransactionError.messageTooLarge(data.count)
        }
        let message: Self = try BootstrapTransactionCodec.decode(
            data,
            allowedFields: ["version", "transactionID", "kind", "body"]
        )
        guard message.version == expectedVersion else {
            throw BootstrapTransactionError.unsupportedVersion(message.version)
        }
        guard try message.encoded(expectedVersion: expectedVersion) == data else {
            throw BootstrapTransactionError.nonCanonicalMessage
        }
        return message
    }
}

public struct BootstrapRecipientPublicKeyV1: Codable, Equatable, Sendable {
    public let key: DevicePublicKeyDescriptorV2

    public init(key: DevicePublicKeyDescriptorV2) { self.key = key }
}

/// Proof that the origin consumed a fresh owner authorization. The capability
/// itself is intentionally absent and non-Codable.
public struct BootstrapAuthorizationProofV1: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let policyGeneration: UInt64
    public let publicKeyFingerprint: String
    public let authorizedHostIDs: [UUID]

    public init(
        attemptID: UUID,
        policyGeneration: UInt64,
        publicKeyFingerprint: String,
        authorizedHostIDs: [UUID]
    ) {
        self.attemptID = attemptID
        self.policyGeneration = policyGeneration
        self.publicKeyFingerprint = publicKeyFingerprint
        self.authorizedHostIDs = authorizedHostIDs
    }
}

public struct BootstrapManifestStartV1: Codable, Equatable, Sendable {
    public let manifestHash: Data
    public let byteCount: Int
    public let hostIDs: [UUID]

    public init(manifestHash: Data, byteCount: Int, hostIDs: [UUID]) {
        self.manifestHash = manifestHash
        self.byteCount = byteCount
        self.hostIDs = hostIDs
    }
}

public struct BootstrapTransactionChunkV1: Codable, Equatable, Sendable {
    /// Leaves enough room for base64 and the closed outer envelopes.
    public static let maximumChunkBytes = 16 * 1_024
    static let maximumBodyBytes = 24 * 1_024

    public let manifestHash: Data
    public let offset: Int
    public let bytes: Data

    public init(manifestHash: Data, offset: Int, bytes: Data) {
        self.manifestHash = manifestHash
        self.offset = offset
        self.bytes = bytes
    }
}

public struct BootstrapManifestEndV1: Codable, Equatable, Sendable {
    public let manifestHash: Data

    public init(manifestHash: Data) { self.manifestHash = manifestHash }
}

public struct BootstrapImportAcceptanceV1: Codable, Equatable, Sendable {
    public let manifestHash: Data
    public let acceptedHostIDs: [UUID]
    public let durableAt: Date

    public init(manifestHash: Data, acceptedHostIDs: [UUID], durableAt: Date) {
        self.manifestHash = manifestHash
        self.acceptedHostIDs = acceptedHostIDs
        self.durableAt = durableAt
    }
}

public enum BootstrapHostGrantStatusV1: String, Codable, CaseIterable, Sendable {
    case installed
    case alreadyInstalled
    case failed
    case skipped
}

public struct BootstrapHostGrantResultV1: Codable, Equatable, Sendable, Identifiable {
    public let hostID: UUID
    public let status: BootstrapHostGrantStatusV1
    public let errorCode: String?

    public var id: UUID { hostID }

    public init(hostID: UUID, status: BootstrapHostGrantStatusV1, errorCode: String? = nil) {
        self.hostID = hostID
        self.status = status
        self.errorCode = errorCode
    }
}

public struct BootstrapGrantReceiptV1: Codable, Equatable, Sendable {
    public let manifestHash: Data
    public let publicKeyFingerprint: String
    public let results: [BootstrapHostGrantResultV1]
    public let verifiedAt: Date

    public init(
        manifestHash: Data,
        publicKeyFingerprint: String,
        results: [BootstrapHostGrantResultV1],
        verifiedAt: Date
    ) {
        self.manifestHash = manifestHash
        self.publicKeyFingerprint = publicKeyFingerprint
        self.results = results
        self.verifiedAt = verifiedAt
    }
}

public struct BootstrapGrantAcknowledgementV1: Codable, Equatable, Sendable {
    public let grantReceiptHash: Data
    public let durableAt: Date

    public init(grantReceiptHash: Data, durableAt: Date) {
        self.grantReceiptHash = grantReceiptHash
        self.durableAt = durableAt
    }
}

public struct BootstrapCompletionV1: Codable, Equatable, Sendable {
    public let manifestHash: Data
    public let grantReceiptHash: Data

    public init(manifestHash: Data, grantReceiptHash: Data) {
        self.manifestHash = manifestHash
        self.grantReceiptHash = grantReceiptHash
    }
}

public struct BootstrapAbortV1: Codable, Equatable, Sendable {
    public let code: String

    public init(code: String) { self.code = code }
}

public enum BootstrapTransactionStateV1: Equatable, Sendable {
    case recipientReady
    case awaitingRecipientKey
    case awaitingOwnerAuthorization(DevicePublicKeyDescriptorV2)
    case awaitingAuthorizationProof
    case awaitingManifest
    case receivingManifest(receivedBytes: Int, expectedBytes: Int)
    case awaitingDurableImport(BootstrapManifestV2)
    case awaitingImportAcceptance
    case awaitingRemoteGrants(BootstrapImportAcceptanceV1)
    case awaitingGrantReceipt(BootstrapManifestV2)
    case awaitingDurableAccessRecord(BootstrapGrantReceiptV1)
    case awaitingGrantAcknowledgement(BootstrapGrantReceiptV1)
    case awaitingCompletion(BootstrapGrantReceiptV1)
    case completed(BootstrapCompletionV1)
    case aborted(String)

    fileprivate var isTerminal: Bool {
        switch self {
        case .completed, .aborted: return true
        default: return false
        }
    }
}

public enum BootstrapTransactionError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case wrongPurpose
    case wrongRole
    case invalidTransition
    case wrongTransaction
    case malformedMessage
    case nonCanonicalMessage
    case messageTooLarge(Int)
    case invalidPublicKey
    case authorizationScopeMismatch
    case policyInvalidated
    case manifestMismatch
    case invalidChunk
    case invalidAcceptance
    case invalidGrantReceipt
    case invalidAcknowledgement
    case invalidAbort
    case remoteAbort(String)
    case optionalTransferAuthorizationRequired
    case unexpectedPairingEnvelope(PairingEnvelopeKindV1)
}

/// Strict bootstrap transaction ordering layered over an authenticated
/// purpose-bound PairingSessionV1. Persistence and remote mutation are
/// represented by explicit durable receipt inputs from platform adapters.
/// The historical type name is retained for source compatibility; v1 and v2
/// share this state machine, with the authenticated session selecting the codec.
public struct BootstrapTransactionV1: Sendable {
    public static let currentVersion = 1
    public static let supportedVersions = [1, 2]
    public let version: Int
    public var peerSupportsAgentCenterEnabled: Bool { version == 2 }
    public static let ownerAuthorizationOperation = "bootstrap-manifest-v2"

    public let transactionID: UUID
    public let localRole: PairingRoleV1
    public let transcriptHash: Data
    public private(set) var state: BootstrapTransactionStateV1

    private let session: PairingSessionV1
    private var recipientKey: DevicePublicKeyDescriptorV2?
    private var manifestHash: Data?
    private var expectedManifestBytes = 0
    private var expectedHostIDs: [UUID] = []
    private var manifestBuffer = Data()
    private var grantReceiptHash: Data?
    private var policyGeneration: UInt64?
    private var authorizedScopesByHostID: [UUID: OwnerAuthorizationScope] = [:]
    private var acceptedHostIDs: [UUID] = []
    private var authorizedManifestHash: Data?
    private var authorizedOptionalTransfers: Set<BootstrapOptionalTransfer>?

    public init(session: PairingSessionV1) throws {
        guard Self.supportedVersions.contains(session.selectedTransactionVersion) else {
            throw BootstrapTransactionError.unsupportedVersion(session.selectedTransactionVersion)
        }
        guard session.purpose == .bootstrap || session.purpose == .setUpAndContinue else {
            throw BootstrapTransactionError.wrongPurpose
        }
        guard session.isTransactionReady else {
            throw BootstrapTransactionError.invalidTransition
        }
        version = session.selectedTransactionVersion
        transactionID = session.offerID
        localRole = session.localRole
        transcriptHash = session.transcriptHash
        state = session.localRole == .origin ? .awaitingRecipientKey : .recipientReady
        self.session = session
    }

    public mutating func makeRecipientPublicKey(
        _ key: DevicePublicKeyDescriptorV2
    ) throws -> Data {
        guard localRole == .recipient, state == .recipientReady else {
            throw BootstrapTransactionError.invalidTransition
        }
        do { try key.validate() } catch { throw BootstrapTransactionError.invalidPublicKey }
        let frame = try message(.recipientPublicKey, BootstrapRecipientPublicKeyV1(key: key))
        recipientKey = key
        state = .awaitingAuthorizationProof
        return frame
    }

    public mutating func receiveRecipientPublicKey(_ data: Data) throws -> DevicePublicKeyDescriptorV2 {
        guard localRole == .origin, state == .awaitingRecipientKey else {
            throw BootstrapTransactionError.invalidTransition
        }
        let body: BootstrapRecipientPublicKeyV1 = try receive(data, kind: .recipientPublicKey)
        do { try body.key.validate() } catch { throw BootstrapTransactionError.invalidPublicKey }
        recipientKey = body.key
        state = .awaitingOwnerAuthorization(body.key)
        return body.key
    }

    /// Consumes a one-shot capability before any manifest or exact trust
    /// material is released. Every selected host must be independently in the
    /// authorized set supplied by the adapter.
    public mutating func consumeOwnerAuthorizations(
        _ authorizations: [DeviceAccessGrantEngine.Authorization],
        selectedHostIDs: [UUID],
        using grantEngine: DeviceAccessGrantEngine
    ) async throws -> Data {
        try await consumeOwnerAuthorizations(
            authorizations,
            selectedHostIDs: selectedHostIDs,
            approvedManifest: nil,
            using: grantEngine
        )
    }

    /// Binds the explicitly selected and filtered manifest snapshot to the
    /// same one-shot capabilities that authorize the bootstrap grant.
    public mutating func consumeOwnerAuthorizations(
        _ authorizations: [DeviceAccessGrantEngine.Authorization],
        approvedManifest: ApprovedBootstrapManifestV2,
        using grantEngine: DeviceAccessGrantEngine
    ) async throws -> Data {
        try await consumeOwnerAuthorizations(
            authorizations,
            selectedHostIDs: approvedManifest.manifest.hosts.map(\.id),
            approvedManifest: approvedManifest,
            using: grantEngine
        )
    }

    private mutating func consumeOwnerAuthorizations(
        _ authorizations: [DeviceAccessGrantEngine.Authorization],
        selectedHostIDs: [UUID],
        approvedManifest: ApprovedBootstrapManifestV2?,
        using grantEngine: DeviceAccessGrantEngine
    ) async throws -> Data {
        guard localRole == .origin,
              case .awaitingOwnerAuthorization(let key) = state else {
            throw BootstrapTransactionError.invalidTransition
        }
        guard !selectedHostIDs.isEmpty,
              Set(selectedHostIDs).count == selectedHostIDs.count,
              authorizations.count == selectedHostIDs.count,
              Set(authorizations.map(\.scope.hostID)) == Set(selectedHostIDs),
              let authorization = authorizations.first,
              authorizations.allSatisfy({
                  $0.attemptID == transactionID
                      && $0.policyGeneration == authorization.policyGeneration
                      && $0.scope.publicKeyFingerprint == key.fingerprint
              }) else {
            throw BootstrapTransactionError.authorizationScopeMismatch
        }
        var approvedHash: Data?
        if let approvedManifest {
            do { try approvedManifest.validate() }
            catch { throw BootstrapTransactionError.optionalTransferAuthorizationRequired }
            let expectedBinding = try Self.ownerAuthorizationBinding(for: approvedManifest)
            guard authorizations.allSatisfy({
                $0.scope.authorizationBinding == expectedBinding
            }) else {
                throw BootstrapTransactionError.optionalTransferAuthorizationRequired
            }
            let manifest = approvedManifest.manifest
            guard Set(manifest.hosts.map(\.id)) == Set(selectedHostIDs) else {
                throw BootstrapTransactionError.manifestMismatch
            }
            for authorization in authorizations {
                guard authorization.scope.routeIdentity == (try Self.routeIdentity(
                    for: authorization.scope.hostID,
                    in: manifest
                )) else {
                    throw BootstrapTransactionError.authorizationScopeMismatch
                }
            }
            approvedHash = expectedBinding.payloadDigest
        } else {
            guard authorizations.allSatisfy({ $0.scope.authorizationBinding == nil }) else {
                throw BootstrapTransactionError.optionalTransferAuthorizationRequired
            }
        }
        do {
            try await grantEngine.consume(
                authorizations,
                attemptID: transactionID,
                policyGeneration: authorization.policyGeneration,
                scopes: authorizations.map(\.scope)
            )
        } catch {
            throw BootstrapTransactionError.authorizationScopeMismatch
        }
        let frame = try message(.authorizationProof, BootstrapAuthorizationProofV1(
            attemptID: transactionID,
            policyGeneration: authorization.policyGeneration,
            publicKeyFingerprint: key.fingerprint,
            authorizedHostIDs: selectedHostIDs
        ))
        recipientKey = key
        policyGeneration = authorization.policyGeneration
        expectedHostIDs = selectedHostIDs
        authorizedScopesByHostID = Dictionary(
            uniqueKeysWithValues: authorizations.map { ($0.scope.hostID, $0.scope) }
        )
        authorizedManifestHash = approvedHash
        authorizedOptionalTransfers = approvedManifest?.selectedOptionalTransfers
        state = .awaitingImportAcceptance
        return frame
    }

    public mutating func receiveAuthorizationProof(_ data: Data) throws -> BootstrapAuthorizationProofV1 {
        guard localRole == .recipient, state == .awaitingAuthorizationProof,
              let key = recipientKey else {
            throw BootstrapTransactionError.invalidTransition
        }
        let proof: BootstrapAuthorizationProofV1 = try receive(data, kind: .authorizationProof)
        guard proof.attemptID == transactionID,
              proof.publicKeyFingerprint == key.fingerprint,
              !proof.authorizedHostIDs.isEmpty,
              Set(proof.authorizedHostIDs).count == proof.authorizedHostIDs.count else {
            throw BootstrapTransactionError.authorizationScopeMismatch
        }
        policyGeneration = proof.policyGeneration
        expectedHostIDs = proof.authorizedHostIDs
        state = .awaitingManifest
        return proof
    }

    /// Compatibility path for manifests with no optional transfer categories.
    public mutating func makeManifestMessages(
        _ manifest: BootstrapManifestV2,
        policyGeneration currentPolicyGeneration: UInt64
    ) throws -> [Data] {
        try validateManifestSendState(policyGeneration: currentPolicyGeneration)
        do { try manifest.validateOptionalTransferSelection([]) }
        catch { throw BootstrapTransactionError.optionalTransferAuthorizationRequired }
        guard authorizedManifestHash == nil else {
            throw BootstrapTransactionError.optionalTransferAuthorizationRequired
        }
        return try makeManifestMessages(
            manifest,
            requiredAuthorizedManifestHash: nil
        )
    }

    public mutating func makeManifestMessages(
        _ approvedManifest: ApprovedBootstrapManifestV2,
        policyGeneration currentPolicyGeneration: UInt64
    ) throws -> [Data] {
        try validateManifestSendState(policyGeneration: currentPolicyGeneration)
        do { try approvedManifest.validate() }
        catch { throw BootstrapTransactionError.optionalTransferAuthorizationRequired }
        guard authorizedOptionalTransfers == approvedManifest.selectedOptionalTransfers,
              let authorizedManifestHash else {
            throw BootstrapTransactionError.optionalTransferAuthorizationRequired
        }
        return try makeManifestMessages(
            approvedManifest.manifest,
            requiredAuthorizedManifestHash: authorizedManifestHash
        )
    }

    private mutating func makeManifestMessages(
        _ manifest: BootstrapManifestV2,
        requiredAuthorizedManifestHash: Data?
    ) throws -> [Data] {
        let bytes = try manifest.encoded()
        try validateManifestVersion(bytes)
        if let requiredAuthorizedManifestHash,
           Self.digest(bytes) != requiredAuthorizedManifestHash {
            throw BootstrapTransactionError.optionalTransferAuthorizationRequired
        }
        let manifestHostIDs = manifest.hosts.map(\.id)
        guard !manifestHostIDs.isEmpty,
              Set(manifestHostIDs) == Set(expectedHostIDs),
              authorizedScopesByHostID.count == manifestHostIDs.count else {
            throw BootstrapTransactionError.manifestMismatch
        }
        for hostID in manifestHostIDs {
            guard let scope = authorizedScopesByHostID[hostID],
                  scope.routeIdentity == (try Self.routeIdentity(for: hostID, in: manifest)) else {
                throw BootstrapTransactionError.authorizationScopeMismatch
            }
        }
        let hash = Self.digest(bytes)
        var result = [try message(.manifestStart, BootstrapManifestStartV1(
            manifestHash: hash,
            byteCount: bytes.count,
            hostIDs: manifestHostIDs
        ))]
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + BootstrapTransactionChunkV1.maximumChunkBytes, bytes.count)
            result.append(try message(.manifestChunk, BootstrapTransactionChunkV1(
                manifestHash: hash,
                offset: offset,
                bytes: bytes.subdata(in: offset..<end)
            )))
            offset = end
        }
        result.append(try message(.manifestEnd, BootstrapManifestEndV1(manifestHash: hash)))
        manifestHash = hash
        expectedHostIDs = manifestHostIDs
        authorizedScopesByHostID.removeAll()
        authorizedManifestHash = nil
        authorizedOptionalTransfers = nil
        return result
    }

    private func validateManifestSendState(policyGeneration currentPolicyGeneration: UInt64) throws {
        guard localRole == .origin, state == .awaitingImportAcceptance,
              policyGeneration == currentPolicyGeneration,
              recipientKey != nil,
              manifestHash == nil else {
            throw policyGeneration == currentPolicyGeneration
                ? BootstrapTransactionError.invalidTransition
                : BootstrapTransactionError.policyInvalidated
        }
    }

    public mutating func receiveManifestMessage(_ data: Data) throws -> BootstrapManifestV2? {
        guard localRole == .recipient else { throw BootstrapTransactionError.wrongRole }
        let outer = try authenticatedMessage(data)
        switch outer.kind {
        case .manifestStart:
            guard state == .awaitingManifest else {
                throw BootstrapTransactionError.invalidTransition
            }
            let start: BootstrapManifestStartV1 = try BootstrapTransactionCodec.decodeBody(outer.body)
            guard start.manifestHash.count == SHA256.Digest.byteCount,
                  start.byteCount > 0,
                  start.byteCount <= BootstrapManifestV2.maximumEncodedByteCount,
                  !start.hostIDs.isEmpty,
                  Set(start.hostIDs).count == start.hostIDs.count,
                  Set(start.hostIDs) == Set(expectedHostIDs) else {
                throw BootstrapTransactionError.manifestMismatch
            }
            manifestHash = start.manifestHash
            expectedManifestBytes = start.byteCount
            expectedHostIDs = start.hostIDs
            manifestBuffer.removeAll(keepingCapacity: true)
            state = .receivingManifest(receivedBytes: 0, expectedBytes: start.byteCount)
            return nil
        case .manifestChunk:
            guard case .receivingManifest = state, let manifestHash else {
                throw BootstrapTransactionError.invalidTransition
            }
            let chunk: BootstrapTransactionChunkV1 = try BootstrapTransactionCodec.decodeBody(outer.body)
            guard chunk.manifestHash == manifestHash,
                  chunk.offset == manifestBuffer.count,
                  !chunk.bytes.isEmpty,
                  chunk.bytes.count <= BootstrapTransactionChunkV1.maximumChunkBytes,
                  manifestBuffer.count + chunk.bytes.count <= expectedManifestBytes else {
                throw BootstrapTransactionError.invalidChunk
            }
            manifestBuffer.append(chunk.bytes)
            state = .receivingManifest(
                receivedBytes: manifestBuffer.count,
                expectedBytes: expectedManifestBytes
            )
            return nil
        case .manifestEnd:
            guard case .receivingManifest = state, let manifestHash else {
                throw BootstrapTransactionError.invalidTransition
            }
            let end: BootstrapManifestEndV1 = try BootstrapTransactionCodec.decodeBody(outer.body)
            guard end.manifestHash == manifestHash,
                  manifestBuffer.count == expectedManifestBytes,
                  Self.digest(manifestBuffer) == manifestHash else {
                throw BootstrapTransactionError.manifestMismatch
            }
            try validateManifestVersion(manifestBuffer)
            let manifest = try BootstrapManifestV2.decode(manifestBuffer)
            guard manifest.hosts.map(\.id) == expectedHostIDs else {
                throw BootstrapTransactionError.manifestMismatch
            }
            state = .awaitingDurableImport(manifest)
            return manifest
        default:
            throw BootstrapTransactionError.invalidTransition
        }
    }

    public mutating func importDurablyApplied(
        acceptedHostIDs: [UUID],
        at date: Date
    ) throws -> Data {
        guard localRole == .recipient,
              case .awaitingDurableImport(let manifest) = state,
              let manifestHash else {
            throw BootstrapTransactionError.invalidTransition
        }
        guard !acceptedHostIDs.isEmpty,
              Set(acceptedHostIDs).isSubset(of: Set(manifest.hosts.map(\.id))),
              Set(acceptedHostIDs).count == acceptedHostIDs.count else {
            throw BootstrapTransactionError.invalidAcceptance
        }
        let acceptance = BootstrapImportAcceptanceV1(
            manifestHash: manifestHash,
            acceptedHostIDs: acceptedHostIDs,
            durableAt: date
        )
        let frame = try message(.importAcceptance, acceptance)
        self.acceptedHostIDs = acceptedHostIDs
        state = .awaitingGrantReceipt(manifest)
        return frame
    }

    public mutating func receiveImportAcceptance(
        _ data: Data
    ) throws -> BootstrapImportAcceptanceV1 {
        guard localRole == .origin, state == .awaitingImportAcceptance,
              let manifestHash else {
            throw BootstrapTransactionError.invalidTransition
        }
        let acceptance: BootstrapImportAcceptanceV1 = try receive(data, kind: .importAcceptance)
        guard acceptance.manifestHash == manifestHash,
              !acceptance.acceptedHostIDs.isEmpty,
              Set(acceptance.acceptedHostIDs).isSubset(of: Set(expectedHostIDs)),
              Set(acceptance.acceptedHostIDs).count == acceptance.acceptedHostIDs.count else {
            throw BootstrapTransactionError.invalidAcceptance
        }
        state = .awaitingRemoteGrants(acceptance)
        return acceptance
    }

    public mutating func remoteGrantsDurablyVerified(
        _ results: [BootstrapHostGrantResultV1],
        at date: Date,
        policyGeneration currentPolicyGeneration: UInt64
    ) throws -> Data {
        guard localRole == .origin,
              case .awaitingRemoteGrants(let acceptance) = state,
              let manifestHash,
              let key = recipientKey else {
            throw BootstrapTransactionError.invalidTransition
        }
        guard policyGeneration == currentPolicyGeneration else {
            throw BootstrapTransactionError.policyInvalidated
        }
        guard results.map(\.hostID) == acceptance.acceptedHostIDs,
              results.allSatisfy(Self.isValidGrantResult) else {
            throw BootstrapTransactionError.invalidGrantReceipt
        }
        let receipt = BootstrapGrantReceiptV1(
            manifestHash: manifestHash,
            publicKeyFingerprint: key.fingerprint,
            results: results,
            verifiedAt: date
        )
        let hash = try Self.canonicalDigest(receipt)
        let frame = try message(.grantReceipt, receipt)
        grantReceiptHash = hash
        state = .awaitingGrantAcknowledgement(receipt)
        return frame
    }

    public mutating func receiveGrantReceipt(_ data: Data) throws -> BootstrapGrantReceiptV1 {
        guard localRole == .recipient,
              case .awaitingGrantReceipt(let manifest) = state,
              let manifestHash,
              let key = recipientKey else {
            throw BootstrapTransactionError.invalidTransition
        }
        let receipt: BootstrapGrantReceiptV1 = try receive(data, kind: .grantReceipt)
        guard receipt.manifestHash == manifestHash,
              receipt.publicKeyFingerprint == key.fingerprint,
              receipt.results.map(\.hostID) == acceptedHostIDs,
              Set(receipt.results.map(\.hostID)).isSubset(of: Set(manifest.hosts.map(\.id))),
              receipt.results.allSatisfy(Self.isValidGrantResult) else {
            throw BootstrapTransactionError.invalidGrantReceipt
        }
        grantReceiptHash = try Self.canonicalDigest(receipt)
        state = .awaitingDurableAccessRecord(receipt)
        return receipt
    }

    public mutating func accessStateDurablyRecorded(at date: Date) throws -> Data {
        guard localRole == .recipient,
              case .awaitingDurableAccessRecord(let receipt) = state,
              let grantReceiptHash else {
            throw BootstrapTransactionError.invalidTransition
        }
        let frame = try message(.grantAcknowledgement, BootstrapGrantAcknowledgementV1(
            grantReceiptHash: grantReceiptHash,
            durableAt: date
        ))
        state = .awaitingCompletion(receipt)
        return frame
    }

    public mutating func receiveGrantAcknowledgement(_ data: Data) throws -> Data {
        guard localRole == .origin,
              case .awaitingGrantAcknowledgement = state,
              let manifestHash,
              let grantReceiptHash else {
            throw BootstrapTransactionError.invalidTransition
        }
        let acknowledgement: BootstrapGrantAcknowledgementV1 = try receive(
            data,
            kind: .grantAcknowledgement
        )
        guard acknowledgement.grantReceiptHash == grantReceiptHash else {
            throw BootstrapTransactionError.invalidAcknowledgement
        }
        let completion = BootstrapCompletionV1(
            manifestHash: manifestHash,
            grantReceiptHash: grantReceiptHash
        )
        let frame = try message(.completion, completion)
        state = .completed(completion)
        return frame
    }

    public mutating func receiveCompletion(_ data: Data) throws -> BootstrapCompletionV1 {
        guard localRole == .recipient,
              case .awaitingCompletion = state,
              let manifestHash,
              let grantReceiptHash else {
            throw BootstrapTransactionError.invalidTransition
        }
        let completion: BootstrapCompletionV1 = try receive(data, kind: .completion)
        guard completion.manifestHash == manifestHash,
              completion.grantReceiptHash == grantReceiptHash else {
            throw BootstrapTransactionError.invalidAcknowledgement
        }
        state = .completed(completion)
        return completion
    }

    public mutating func securityPolicyChanged(to generation: UInt64) {
        _ = generation // Generations are device-local; the event itself invalidates the attempt.
        guard !state.isTerminal else { return }
        terminate(code: "policy_invalidated")
    }

    public mutating func applicationDidLock() {
        guard !state.isTerminal else { return }
        terminate(code: "application_locked")
    }

    public mutating func abort(code: String) throws -> Data {
        guard !state.isTerminal else { throw BootstrapTransactionError.invalidTransition }
        try Self.validateAbortCode(code)
        let frame = try message(.abort, BootstrapAbortV1(code: code))
        terminate(code: code)
        return frame
    }

    @discardableResult
    public mutating func receiveAbort(_ data: Data) throws -> BootstrapAbortV1 {
        guard !state.isTerminal else { throw BootstrapTransactionError.invalidTransition }
        let outer = try authenticatedMessage(data, acceptingAbort: true)
        guard outer.kind == .abort else { throw BootstrapTransactionError.invalidTransition }
        let abort: BootstrapAbortV1 = try BootstrapTransactionCodec.decodeBody(outer.body)
        try Self.validateAbortCode(abort.code)
        terminate(code: abort.code)
        return abort
    }

    private func message<Body: Codable>(
        _ kind: BootstrapTransactionMessageKindV1,
        _ body: Body
    ) throws -> Data {
        let inner = try BootstrapTransactionMessageV1(
            version: version,
            transactionID: transactionID,
            kind: kind,
            body: BootstrapTransactionCodec.encode(body)
        ).encoded(expectedVersion: version)
        return try session.sealTransactionMessage(inner)
    }

    private mutating func receive<Body: Codable>(
        _ data: Data,
        kind: BootstrapTransactionMessageKindV1
    ) throws -> Body {
        let outer = try authenticatedMessage(data)
        guard outer.kind == kind else { throw BootstrapTransactionError.invalidTransition }
        return try BootstrapTransactionCodec.decodeBody(outer.body)
    }

    private mutating func authenticatedMessage(
        _ data: Data,
        acceptingAbort: Bool = false
    ) throws -> BootstrapTransactionMessageV1 {
        let payload = try session.openTransactionMessage(data)
        let outer = try BootstrapTransactionMessageV1.decode(payload, expectedVersion: version)
        guard outer.transactionID == transactionID else {
            throw BootstrapTransactionError.wrongTransaction
        }
        if outer.kind == .abort, !acceptingAbort {
            let abort: BootstrapAbortV1 = try BootstrapTransactionCodec.decodeBody(outer.body)
            try Self.validateAbortCode(abort.code)
            terminate(code: abort.code)
            throw BootstrapTransactionError.remoteAbort(abort.code)
        }
        return outer
    }

    private func validateManifestVersion(_ bytes: Data) throws {
        guard version == 1 else { return }
        let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        let settings = root?["settings"] as? [String: Any]
        guard settings?["agentCenterEnabled"] == nil else {
            throw BootstrapTransactionError.manifestMismatch
        }
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    public static func ownerAuthorizationBinding(
        for approvedManifest: ApprovedBootstrapManifestV2
    ) throws -> OwnerAuthorizationBinding {
        try approvedManifest.validate()
        return OwnerAuthorizationBinding(
            operation: ownerAuthorizationOperation,
            categories: approvedManifest.selectedOptionalTransfers.map(\.rawValue).sorted(),
            payloadDigest: digest(try approvedManifest.manifest.encoded())
        )
    }

    public static func routeIdentity(
        for hostID: UUID,
        in manifest: BootstrapManifestV2
    ) throws -> String {
        try manifest.validate()
        let hostsByID = Dictionary(uniqueKeysWithValues: manifest.hosts.map { ($0.id, $0) })
        let jumpByHostID = Dictionary(
            uniqueKeysWithValues: manifest.jumpChains.map { ($0.hostID, $0.jumpHostID) }
        )
        guard hostsByID[hostID] != nil else { throw BootstrapTransactionError.manifestMismatch }
        var innerToOuter = [hostID]
        var current = hostID
        while let jumpID = jumpByHostID[current] {
            innerToOuter.append(jumpID)
            current = jumpID
        }
        let route = innerToOuter.reversed().compactMap { hostsByID[$0] }
        guard route.count == innerToOuter.count else {
            throw BootstrapTransactionError.manifestMismatch
        }
        var fields = ["v1", "route", String(route.count)]
        for host in route {
            fields.append(host.id.uuidString)
            fields.append(host.transport.rawValue)
            fields.append(host.user)
            fields.append(host.address)
            fields.append(String(host.port))
        }
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func isValidGrantResult(_ result: BootstrapHostGrantResultV1) -> Bool {
        switch result.status {
        case .failed:
            guard let code = result.errorCode else { return false }
            return !code.isEmpty && code.utf8.count <= 128
        case .installed, .alreadyInstalled, .skipped:
            return result.errorCode == nil
        }
    }

    private static func validateAbortCode(_ code: String) throws {
        guard !code.isEmpty,
              code.utf8.count <= 128,
              code.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw BootstrapTransactionError.invalidAbort
        }
    }

    private mutating func terminate(code: String) {
        state = .aborted(code)
        manifestBuffer.removeAll()
        authorizedScopesByHostID.removeAll()
        acceptedHostIDs.removeAll()
        authorizedManifestHash = nil
        authorizedOptionalTransfers = nil
    }

    private static func canonicalDigest<T: Codable>(_ value: T) throws -> Data {
        digest(try BootstrapTransactionCodec.encode(value))
    }
}

enum BootstrapTransactionCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(value) }
        catch { throw BootstrapTransactionError.malformedMessage }
    }

    static func decode<T: Decodable>(
        _ data: Data,
        allowedFields: Set<String>? = nil
    ) throws -> T {
        if let allowedFields {
            let object: Any
            do { object = try JSONSerialization.jsonObject(with: data) }
            catch { throw BootstrapTransactionError.malformedMessage }
            guard let root = object as? [String: Any],
                  Set(root.keys).isSubset(of: allowedFields) else {
                throw BootstrapTransactionError.malformedMessage
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try decoder.decode(T.self, from: data) }
        catch { throw BootstrapTransactionError.malformedMessage }
    }

    static func decodeBody<T: Codable>(_ data: Data) throws -> T {
        let value: T = try decode(data)
        guard try encode(value) == data else {
            throw BootstrapTransactionError.nonCanonicalMessage
        }
        return value
    }
}
