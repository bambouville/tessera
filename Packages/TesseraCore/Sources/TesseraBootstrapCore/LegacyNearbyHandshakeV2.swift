import Crypto
import Foundation
import TesseraEnrollmentCore
import TesseraProtocolCore

private enum LegacyNearbyDeviceLabelV2 {
    static func sanitized(_ rawValue: String) -> String {
        let withoutControls = rawValue.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()
        let collapsed = withoutControls
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let candidate = collapsed
        var result = ""
        var byteCount = 0
        for character in candidate.prefix(48) {
            let fragment = String(character)
            guard byteCount + fragment.utf8.count <= 192 else { break }
            result.append(character)
            byteCount += fragment.utf8.count
        }
        return result
    }
}

/// Cleartext handshake message. The role label is load-bearing: callers must
/// never infer roles from connection direction or device names.
public struct LegacyNearbyHandshakeHelloV2: Codable, Equatable, Sendable {
    public static let currentVersion = LegacyNearbyBootstrapV2.version

    public let version: Int
    public let role: LegacyNearbyHandshakeRoleV2
    public let ephemeralPublicKey: Data
    public let displayName: String?
    /// Advisory only (see NearbyBootstrapCompatibility.swift): lets a
    /// mismatch error name the peer's app release. Stays out of the
    /// commitment projection and transcript.
    public let appVersion: String?
    /// Advisory only: versions this peer could complete a transfer with, so
    /// a future build can decide whether a downgrade path exists.
    public let supportedVersions: [Int]?

    public init(
        version: Int = LegacyNearbyHandshakeHelloV2.currentVersion,
        role: LegacyNearbyHandshakeRoleV2,
        ephemeralPublicKey: Data,
        displayName: String? = nil,
        appVersion: String? = nil,
        supportedVersions: [Int]? = LegacyNearbyBootstrapV2.supportedVersions
    ) {
        self.version = version
        self.role = role
        self.ephemeralPublicKey = ephemeralPublicKey
        self.displayName = displayName.map {
            LegacyNearbyDeviceLabelV2.sanitized($0)
        }
        self.appVersion = appVersion
        self.supportedVersions = supportedVersions
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= LegacyNearbyBootstrapV2.maximumHelloMessageSize else {
            throw LegacyNearbyHandshakeErrorV2.invalidFrame
        }
        return data
    }

    public static func decode(_ data: Data) throws -> LegacyNearbyHandshakeHelloV2 {
        guard data.count <= LegacyNearbyBootstrapV2.maximumHelloMessageSize else {
            throw LegacyNearbyHandshakeErrorV2.invalidFrame
        }
        if let info = LegacyNearbyVersionProbeV2.probe(data), info.version != currentVersion {
            throw LegacyNearbyHandshakeErrorV2.incompatiblePeerVersion(info, message: .hello)
        }
        return try JSONDecoder().decode(LegacyNearbyHandshakeHelloV2.self, from: data)
    }
}

/// The recipient's binding commitment for the role-asymmetric nearby
/// handshake. The origin must receive this value before disclosing its
/// ephemeral public key; the recipient reveals the committed hello only after
/// it receives the origin hello. That ordering prevents an active relay from
/// choosing either leg's key after learning the other leg's SAS.
public struct LegacyNearbyHandshakeCommitmentV2: Codable, Equatable, Sendable {
    public static let currentVersion = LegacyNearbyHandshakeHelloV2.currentVersion

    public let version: Int
    public let role: LegacyNearbyHandshakeRoleV2
    public let helloDigest: Data
    /// Advisory only; see NearbyBootstrapCompatibility.swift. The commitment
    /// is the first bytes on the wire, so these fields are what lets a future
    /// origin recognize an old recipient and downgrade (or explain the
    /// mismatch) before disclosing anything.
    public let appVersion: String?
    public let supportedVersions: [Int]?

    fileprivate init(
        version: Int = LegacyNearbyHandshakeCommitmentV2.currentVersion,
        role: LegacyNearbyHandshakeRoleV2 = .recipient,
        helloDigest: Data,
        appVersion: String? = nil,
        supportedVersions: [Int]? = LegacyNearbyBootstrapV2.supportedVersions
    ) {
        self.version = version
        self.role = role
        self.helloDigest = helloDigest
        self.appVersion = appVersion
        self.supportedVersions = supportedVersions
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= LegacyNearbyBootstrapV2.maximumCommitmentMessageSize else {
            throw LegacyNearbyHandshakeErrorV2.invalidFrame
        }
        return data
    }

    public static func decode(_ data: Data) throws -> LegacyNearbyHandshakeCommitmentV2 {
        guard data.count <= LegacyNearbyBootstrapV2.maximumCommitmentMessageSize else {
            throw LegacyNearbyHandshakeErrorV2.invalidFrame
        }
        if let info = LegacyNearbyVersionProbeV2.probe(data), info.version != currentVersion {
            throw LegacyNearbyHandshakeErrorV2.incompatiblePeerVersion(info, message: .commitment)
        }
        let commitment = try JSONDecoder().decode(Self.self, from: data)
        try commitment.validate()
        return commitment
    }

    fileprivate func validate() throws {
        guard version == Self.currentVersion else {
            throw LegacyNearbyHandshakeErrorV2.incompatiblePeerVersion(
                LegacyNearbyPeerVersionInfoV2(
                    version: version,
                    appVersion: appVersion,
                    supportedVersions: supportedVersions
                ),
                message: .commitment
            )
        }
        guard role == .recipient,
              helloDigest.count == SHA256.Digest.byteCount else {
            throw LegacyNearbyHandshakeErrorV2.invalidCommitment
        }
    }
}

public struct LegacyNearbyShortAuthenticationStringV2: Equatable, Hashable, Sendable,
    CustomStringConvertible
{
    public let value: Int

    public init(value: Int) throws {
        guard (0...999_999).contains(value) else {
            throw LegacyNearbyHandshakeErrorV2.invalidSAS
        }
        self.value = value
    }

    public var digits: String {
        String(format: "%06d", value)
    }

    public var displayValue: String {
        let raw = digits
        return "\(raw.prefix(3)) \(raw.suffix(3))"
    }

    public var description: String { displayValue }
}

public enum LegacyNearbyOriginAuthorizationV2: Equatable, Sendable {
    case pending
    case approved
    case denied
}

public enum LegacyBootstrapHostGrantStatusV2: String, Codable, Equatable, Sendable {
    case installed
    case failed
    case notSelected
    case rejectedImport
    case excludedAuthentication
}

/// Truthful per-host outcome returned by the origin after it attempts the
/// selected public-key grants. Every host in the manifest receives exactly one
/// result, including hosts that were not selected or were credential-ineligible.
public struct LegacyBootstrapHostGrantResultV2: Codable, Equatable, Identifiable, Sendable {
    public let hostID: UUID
    public let hostName: String
    public let status: LegacyBootstrapHostGrantStatusV2
    public let detail: String?

    public var id: UUID { hostID }

    public init(
        hostID: UUID,
        hostName: String,
        status: LegacyBootstrapHostGrantStatusV2,
        detail: String?
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.status = status
        self.detail = detail
    }
}

public struct LegacyBootstrapGrantBatchReceiptV2: Codable, Equatable, Sendable {
    public static let maximumDetailLength = 512

    public let publicKeyID: UUID
    public let publicKeyFingerprint: String
    public let results: [LegacyBootstrapHostGrantResultV2]

    public init(
        publicKeyID: UUID,
        publicKeyFingerprint: String,
        results: [LegacyBootstrapHostGrantResultV2]
    ) {
        self.publicKeyID = publicKeyID
        self.publicKeyFingerprint = publicKeyFingerprint
        self.results = results
    }

    public func validate(
        manifest: BootstrapManifest,
        publicKey: EnrollmentPublicKeyV1
    ) throws {
        guard publicKeyID == publicKey.id,
              publicKeyFingerprint == publicKey.fingerprint,
              results.count == manifest.hosts.count,
              Set(results.map(\.hostID)).count == results.count,
              Set(results.map(\.hostID)) == Set(manifest.hosts.map(\.id))
        else { throw LegacyNearbyHandshakeErrorV2.invalidGrantReceipt }

        let hostsByID = Dictionary(uniqueKeysWithValues: manifest.hosts.map { ($0.id, $0) })
        for result in results {
            guard let host = hostsByID[result.hostID],
                  result.hostName == host.name,
                  (result.detail?.count ?? 0) <= Self.maximumDetailLength
            else { throw LegacyNearbyHandshakeErrorV2.invalidGrantReceipt }

            switch (host.authenticationHint, result.status) {
            case (.publicKey, .installed), (.publicKey, .failed),
                 (.publicKey, .notSelected), (.publicKey, .rejectedImport):
                break
            case (.password, .excludedAuthentication), (.none, .excludedAuthentication):
                break
            default:
                throw LegacyNearbyHandshakeErrorV2.invalidGrantReceipt
            }

            if result.status == .failed {
                guard let detail = result.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !detail.isEmpty
                else { throw LegacyNearbyHandshakeErrorV2.invalidGrantReceipt }
            } else if result.detail != nil {
                throw LegacyNearbyHandshakeErrorV2.invalidGrantReceipt
            }
        }
    }

    fileprivate func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Authenticated acknowledgement sent after the recipient has durably applied
/// the manifest, but before the origin mutates any remote authorized_keys file.
/// This closes the collision/retry window where a host could be granted on the
/// origin without a corresponding recipient-side host and ledger record.
public struct LegacyBootstrapImportAcceptanceV2: Codable, Equatable, Sendable {
    public let manifestHash: Data
    public let acceptedHostIDs: [UUID]

    public static func acknowledging(
        _ manifest: BootstrapManifest,
        acceptedHostIDs: Set<UUID>
    ) throws -> LegacyBootstrapImportAcceptanceV2 {
        let manifestIDs = Set(manifest.hosts.map(\.id))
        guard acceptedHostIDs.isSubset(of: manifestIDs) else {
            throw LegacyNearbyHandshakeErrorV2.invalidImportAcceptance
        }
        return LegacyBootstrapImportAcceptanceV2(
            manifestHash: Data(SHA256.hash(data: try manifest.encoded())),
            acceptedHostIDs: acceptedHostIDs.sorted {
                $0.uuidString < $1.uuidString
            }
        )
    }

    public func validates(_ manifest: BootstrapManifest) throws -> Bool {
        self == (try Self.acknowledging(
            manifest,
            acceptedHostIDs: Set(acceptedHostIDs)
        )) && Set(acceptedHostIDs).count == acceptedHostIDs.count
    }
}

public struct LegacyBootstrapGrantCompletionAcknowledgementV2: Codable, Equatable, Sendable {
    public let publicKeyID: UUID
    public let grantReceiptHash: Data

    public static func acknowledging(
        _ receipt: LegacyBootstrapGrantBatchReceiptV2
    ) throws -> LegacyBootstrapGrantCompletionAcknowledgementV2 {
        LegacyBootstrapGrantCompletionAcknowledgementV2(
            publicKeyID: receipt.publicKeyID,
            grantReceiptHash: Data(SHA256.hash(data: try receipt.encoded()))
        )
    }

    public func validates(_ receipt: LegacyBootstrapGrantBatchReceiptV2) throws -> Bool {
        self == (try Self.acknowledging(receipt))
    }
}

public enum LegacyNearbyHandshakeErrorV2: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case incompatiblePeerVersion(LegacyNearbyPeerVersionInfoV2, message: LegacyNearbyVersionedMessageKindV2)
    case unsupportedFrameVersion(Int)
    case invalidPrivateKey
    case invalidPublicKey
    case unexpectedPeerRole(expected: LegacyNearbyHandshakeRoleV2, actual: LegacyNearbyHandshakeRoleV2)
    case reflectedPublicKey
    case attemptAlreadyConsumed
    case recipientCommitmentRequired
    case invalidCommitment
    case commitmentMismatch
    case invalidSAS
    case sasAlreadyDecided
    case sasMismatch
    case transferAborted
    case sasNotConfirmed
    case originAuthorizationRequired
    case originAuthorizationAlreadyDecided
    case originAuthorizationDenied
    case originOnlyOperation
    case recipientOnlyOperation
    case authorizationProofRequired
    case authorizationProofAlreadySent
    case recipientPublicKeyRequired
    case recipientPublicKeyAlreadySent
    case manifestAlreadyTransferred
    case importAcceptanceRequired
    case importAcceptanceAlreadyTransferred
    case invalidImportAcceptance
    case grantReceiptRequired
    case grantReceiptAlreadyTransferred
    case completionAcknowledgementRequired
    case completionAcknowledgementAlreadyTransferred
    case invalidGrantReceipt
    case unexpectedMessage
    case invalidFrame
    case wrongDirection
    case outOfOrder(expected: UInt64, actual: UInt64)
    case sequenceExhausted
    case authenticationFailed

}

/// A single-use ephemeral X25519 attempt. Completion consumes the attempt even
/// when the peer hello is invalid, so a role reflection or mismatch cannot be
/// retried in-place with the same key material.
public final class LegacyNearbyHandshakeAttemptV2: @unchecked Sendable {
    public let role: LegacyNearbyHandshakeRoleV2
    public let hello: LegacyNearbyHandshakeHelloV2

    fileprivate let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let lock = NSLock()
    private var consumed = false
    private var recipientCommitmentPublished = false

    fileprivate init(
        role: LegacyNearbyHandshakeRoleV2,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        displayName: String?,
        appVersion: String?,
        supportedVersions: [Int]?
    ) {
        self.role = role
        self.privateKey = privateKey
        self.hello = LegacyNearbyHandshakeHelloV2(
            role: role,
            ephemeralPublicKey: privateKey.publicKey.rawRepresentation,
            displayName: displayName,
            appVersion: appVersion,
            supportedVersions: supportedVersions
        )
    }

    fileprivate func markRecipientCommitmentPublished() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { throw LegacyNearbyHandshakeErrorV2.attemptAlreadyConsumed }
        recipientCommitmentPublished = true
    }

    fileprivate func consume(requiringRecipientCommitment: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { throw LegacyNearbyHandshakeErrorV2.attemptAlreadyConsumed }
        if requiringRecipientCommitment, !recipientCommitmentPublished {
            throw LegacyNearbyHandshakeErrorV2.recipientCommitmentRequired
        }
        consumed = true
    }
}

public enum LegacyNearbyHandshakeV2 {
    private static let transcriptLabel = Data("tessera/nearby-bootstrap/transcript/v2".utf8)
    private static let commitmentLabel = Data("tessera/nearby-bootstrap/recipient-commitment/v2".utf8)

    /// Starts a fresh attempt with a new ephemeral X25519 private key.
    public static func begin(
        role: LegacyNearbyHandshakeRoleV2,
        displayName: String? = nil,
        appVersion: String? = nil,
        supportedVersions: [Int]? = LegacyNearbyBootstrapV2.supportedVersions
    ) -> LegacyNearbyHandshakeAttemptV2 {
        LegacyNearbyHandshakeAttemptV2(
            role: role,
            privateKey: Curve25519.KeyAgreement.PrivateKey(),
            displayName: displayName,
            appVersion: appVersion,
            supportedVersions: supportedVersions
        )
    }

    #if DEBUG
    /// Deterministic construction for protocol vectors. This API is absent
    /// from release builds so production attempts can only use fresh entropy.
    public static func begin(
        role: LegacyNearbyHandshakeRoleV2,
        deterministicPrivateKey rawRepresentation: Data,
        displayName: String? = nil,
        appVersion: String? = nil,
        supportedVersions: [Int]? = LegacyNearbyBootstrapV2.supportedVersions
    ) throws -> LegacyNearbyHandshakeAttemptV2 {
        do {
            return LegacyNearbyHandshakeAttemptV2(
                role: role,
                privateKey: try Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: rawRepresentation
                ),
                displayName: displayName,
                appVersion: appVersion,
                supportedVersions: supportedVersions
            )
        } catch {
            throw LegacyNearbyHandshakeErrorV2.invalidPrivateKey
        }
    }
    #endif

    /// Produces the recipient's commitment before the origin discloses its
    /// hello. The committed bytes are the canonical, role-labelled hello.
    public static func recipientCommitment(
        for attempt: LegacyNearbyHandshakeAttemptV2
    ) throws -> LegacyNearbyHandshakeCommitmentV2 {
        guard attempt.role == .recipient else {
            throw LegacyNearbyHandshakeErrorV2.recipientOnlyOperation
        }
        try attempt.markRecipientCommitmentPublished()
        return LegacyNearbyHandshakeCommitmentV2(
            helloDigest: try commitmentDigest(for: attempt.hello),
            appVersion: attempt.hello.appVersion,
            supportedVersions: attempt.hello.supportedVersions
        )
    }

    /// Completes the recipient side after it has committed and received the
    /// origin's hello. The coordinator reveals `attempt.hello` only after this
    /// peer hello arrived.
    public static func completeRecipient(
        _ attempt: LegacyNearbyHandshakeAttemptV2,
        with originHello: LegacyNearbyHandshakeHelloV2
    ) throws -> LegacyNearbyManifestTransferSessionV2 {
        guard attempt.role == .recipient else {
            throw LegacyNearbyHandshakeErrorV2.recipientOnlyOperation
        }
        try attempt.consume(requiringRecipientCommitment: true)
        return try completeConsumed(attempt, with: originHello)
    }

    /// Completes the origin side only after verifying that the revealed
    /// recipient hello matches the commitment received before the origin hello
    /// was sent.
    public static func completeOrigin(
        _ attempt: LegacyNearbyHandshakeAttemptV2,
        with recipientHello: LegacyNearbyHandshakeHelloV2,
        verifying commitment: LegacyNearbyHandshakeCommitmentV2
    ) throws -> LegacyNearbyManifestTransferSessionV2 {
        guard attempt.role == .origin else {
            throw LegacyNearbyHandshakeErrorV2.originOnlyOperation
        }
        try attempt.consume()
        try commitment.validate()
        guard commitment.helloDigest == (try commitmentDigest(for: recipientHello)) else {
            throw LegacyNearbyHandshakeErrorV2.commitmentMismatch
        }
        return try completeConsumed(attempt, with: recipientHello)
    }

    /// Shared X25519 completion after the role-specific disclosure order has
    /// already been enforced. Device names never influence the transcript.
    private static func completeConsumed(
        _ attempt: LegacyNearbyHandshakeAttemptV2,
        with peerHello: LegacyNearbyHandshakeHelloV2
    ) throws -> LegacyNearbyManifestTransferSessionV2 {
        guard peerHello.version == LegacyNearbyHandshakeHelloV2.currentVersion else {
            throw LegacyNearbyHandshakeErrorV2.unsupportedVersion(peerHello.version)
        }
        guard peerHello.role == attempt.role.peer else {
            throw LegacyNearbyHandshakeErrorV2.unexpectedPeerRole(
                expected: attempt.role.peer,
                actual: peerHello.role
            )
        }
        guard peerHello.ephemeralPublicKey != attempt.hello.ephemeralPublicKey else {
            throw LegacyNearbyHandshakeErrorV2.reflectedPublicKey
        }

        let peerPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: peerHello.ephemeralPublicKey
            )
        } catch {
            throw LegacyNearbyHandshakeErrorV2.invalidPublicKey
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try attempt.privateKey.sharedSecretFromKeyAgreement(
                with: peerPublicKey
            )
        } catch {
            throw LegacyNearbyHandshakeErrorV2.invalidPublicKey
        }

        let originHello = attempt.role == .origin ? attempt.hello : peerHello
        let recipientHello = attempt.role == .recipient ? attempt.hello : peerHello
        let transcript = try makeTranscript(
            originHello: originHello,
            recipientHello: recipientHello
        )
        let transcriptHash = Data(SHA256.hash(data: transcript))
        let material = deriveMaterial(
            sharedSecret: sharedSecret,
            transcriptHash: transcriptHash
        )
        return try LegacyNearbyManifestTransferSessionV2(
            localRole: attempt.role,
            transcriptHash: transcriptHash,
            material: material,
            peerDisplayName: peerHello.displayName.map {
                LegacyNearbyDeviceLabelV2.sanitized($0)
            }
        )
    }

    private static func commitmentDigest(
        for recipientHello: LegacyNearbyHandshakeHelloV2
    ) throws -> Data {
        guard recipientHello.version == LegacyNearbyHandshakeHelloV2.currentVersion,
              recipientHello.role == .recipient,
              recipientHello.ephemeralPublicKey.count == 32 else {
            throw LegacyNearbyHandshakeErrorV2.invalidCommitment
        }
        var committed = Data()
        committed.appendLengthPrefixed(commitmentLabel)
        // Version-2 peers committed the three original hello fields. Keep
        // hashing that legacy projection so an older decoder may ignore the
        // optional display label without breaking the commitment or SAS.
        committed.appendLengthPrefixed(
            try canonicalCommitmentProjection(for: recipientHello)
        )
        return Data(SHA256.hash(data: committed))
    }

    private static func canonicalCommitmentProjection(
        for recipientHello: LegacyNearbyHandshakeHelloV2
    ) throws -> Data {
        let projection = LegacyNearbyHandshakeCommitmentProjectionV2(
            version: recipientHello.version,
            role: recipientHello.role,
            ephemeralPublicKey: recipientHello.ephemeralPublicKey
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(projection)
    }

    #if DEBUG
    /// Deterministic compatibility hook for the frozen released-v2 vectors.
    public static func commitmentProjection(
        for recipientHello: LegacyNearbyHandshakeHelloV2
    ) throws -> Data {
        try canonicalCommitmentProjection(for: recipientHello)
    }
    #endif

    /// Canonical transcript with semantic ordering, explicit role labels, and
    /// length-delimited public keys. It is exposed for deterministic vectors.
    public static func makeTranscript(
        originHello: LegacyNearbyHandshakeHelloV2,
        recipientHello: LegacyNearbyHandshakeHelloV2
    ) throws -> Data {
        guard originHello.version == LegacyNearbyHandshakeHelloV2.currentVersion else {
            throw LegacyNearbyHandshakeErrorV2.unsupportedVersion(originHello.version)
        }
        guard recipientHello.version == LegacyNearbyHandshakeHelloV2.currentVersion else {
            throw LegacyNearbyHandshakeErrorV2.unsupportedVersion(recipientHello.version)
        }
        guard originHello.role == .origin else {
            throw LegacyNearbyHandshakeErrorV2.unexpectedPeerRole(expected: .origin, actual: originHello.role)
        }
        guard recipientHello.role == .recipient else {
            throw LegacyNearbyHandshakeErrorV2.unexpectedPeerRole(expected: .recipient, actual: recipientHello.role)
        }
        guard originHello.ephemeralPublicKey.count == 32,
              recipientHello.ephemeralPublicKey.count == 32 else {
            throw LegacyNearbyHandshakeErrorV2.invalidPublicKey
        }
        guard originHello.ephemeralPublicKey != recipientHello.ephemeralPublicKey else {
            throw LegacyNearbyHandshakeErrorV2.reflectedPublicKey
        }

        var transcript = Data()
        transcript.appendLengthPrefixed(transcriptLabel)
        transcript.appendUInt16(UInt16(LegacyNearbyHandshakeHelloV2.currentVersion))
        transcript.appendLengthPrefixed(Data("role:origin".utf8))
        transcript.appendLengthPrefixed(originHello.ephemeralPublicKey)
        transcript.appendLengthPrefixed(Data("role:recipient".utf8))
        transcript.appendLengthPrefixed(recipientHello.ephemeralPublicKey)
        return transcript
    }

    private static func deriveMaterial(
        sharedSecret: SharedSecret,
        transcriptHash: Data
    ) -> LegacyNearbyDirectionalMaterialV2 {
        func bytes(label: String, count: Int) -> Data {
            let key = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: transcriptHash,
                sharedInfo: Data("tessera/nearby-bootstrap/\(label)/v1".utf8),
                outputByteCount: count
            )
            return key.withUnsafeBytes { Data($0) }
        }

        return LegacyNearbyDirectionalMaterialV2(
            originToRecipientKey: SymmetricKey(
                data: bytes(label: "key/origin-to-recipient", count: 32)
            ),
            recipientToOriginKey: SymmetricKey(
                data: bytes(label: "key/recipient-to-origin", count: 32)
            ),
            originToRecipientNonce: bytes(
                label: "nonce/origin-to-recipient",
                count: 12
            ),
            recipientToOriginNonce: bytes(
                label: "nonce/recipient-to-origin",
                count: 12
            ),
            sasBytes: bytes(label: "sas", count: 8)
        )
    }
}

private struct LegacyNearbyHandshakeCommitmentProjectionV2: Codable {
    let version: Int
    let role: LegacyNearbyHandshakeRoleV2
    let ephemeralPublicKey: Data
}

/// The application-facing encrypted exchange. Its public API makes the required
/// order explicit:
///
/// `confirmSAS` -> recipient public key -> origin records Face ID authorization
/// -> encrypted authorization proof -> encrypted manifest -> authenticated
/// import acknowledgement -> truthful grant receipt -> encrypted completion
/// acknowledgement.
///
/// A mismatch permanently aborts this object. The caller must create a fresh
/// `LegacyNearbyHandshakeAttemptV2`, which also guarantees fresh ephemeral keys/code.
public final class LegacyNearbyManifestTransferSessionV2: @unchecked Sendable {
    public let localRole: LegacyNearbyHandshakeRoleV2
    public let transcriptHash: Data
    public let sas: LegacyNearbyShortAuthenticationStringV2
    public let peerDisplayName: String?

    private let lock = NSLock()
    private var localSASDecision: Bool?
    private var peerSASDecision: Bool?
    private var aborted = false
    private var originAuthorization: LegacyNearbyOriginAuthorizationV2 = .pending
    /// Declarations are trusted only after opening the authenticated key frame.
    private var peerManifestExtensionsStorage: [String] = []
    public var peerManifestExtensions: [String] {
        lock.lock(); defer { lock.unlock() }
        return peerManifestExtensionsStorage
    }
    public static let agentCenterEnabledExtension = "settings.agentCenterEnabled"
    private var recipientPublicKeySent = false
    private var recipientPublicKeyReceived = false
    private var authorizationProofSent = false
    private var authorizationProofReceived = false
    private var manifestSent = false
    private var manifestReceived = false
    private var importAcceptanceSent = false
    private var importAcceptanceReceived = false
    private var grantReceiptSent = false
    private var grantReceiptReceived = false
    private var completionAcknowledgementSent = false
    private var completionAcknowledgementReceived = false
    private let channel: LegacyNearbyEncryptedChannelV2

    fileprivate init(
        localRole: LegacyNearbyHandshakeRoleV2,
        transcriptHash: Data,
        material: LegacyNearbyDirectionalMaterialV2,
        peerDisplayName: String?
    ) throws {
        self.localRole = localRole
        self.transcriptHash = transcriptHash
        self.peerDisplayName = peerDisplayName
        self.sas = try LegacyNearbyShortAuthenticationStringV2(
            value: Int(material.sasBytes.uint64BigEndian % 1_000_000)
        )
        self.channel = LegacyNearbyEncryptedChannelV2(
            localRole: localRole,
            transcriptHash: transcriptHash,
            material: material
        )
    }

    public var currentOriginAuthorization: LegacyNearbyOriginAuthorizationV2 {
        lock.lock()
        defer { lock.unlock() }
        return originAuthorization
    }

    /// Seals the local user's visual comparison as the first encrypted frame.
    /// Both peers exchange this decision before any setup payload is accepted,
    /// which lets an untouched comparison screen learn about a rejection
    /// immediately. `false` is terminal; the same session cannot be retried.
    public func sealSASDecision(matches: Bool) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !aborted else { throw LegacyNearbyHandshakeErrorV2.transferAborted }
        guard localSASDecision == nil else {
            throw LegacyNearbyHandshakeErrorV2.sasAlreadyDecided
        }
        let frame = try channel.seal(
            LegacyNearbyEncryptedEnvelopeV2(
                kind: .sasDecision,
                payload: Data([matches ? 1 : 0])
            )
        )
        localSASDecision = matches
        if !matches {
            aborted = true
        }
        return frame
    }

    /// Opens the peer's first encrypted frame and records its SAS decision.
    /// A negative decision is returned to the coordinator so it can show a
    /// specific peer-rejection notice instead of a generic disconnect error.
    public func openPeerSASDecision(_ frame: Data) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard peerSASDecision == nil else {
            throw LegacyNearbyHandshakeErrorV2.sasAlreadyDecided
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .sasDecision,
              envelope.payload.count == 1,
              let rawDecision = envelope.payload.first,
              rawDecision == 0 || rawDecision == 1 else {
            throw LegacyNearbyHandshakeErrorV2.unexpectedMessage
        }
        let matches = rawDecision == 1
        peerSASDecision = matches
        if !matches {
            aborted = true
        }
        return matches
    }

    /// Transfers only recipient-owned public key metadata after the recipient
    /// has locally confirmed SAS. This message authorizes nothing by itself.
    public func sealRecipientPublicKey(
        _ publicKey: EnrollmentPublicKeyV1,
        manifestExtensions: [String] = []
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .recipient else { throw LegacyNearbyHandshakeErrorV2.recipientOnlyOperation }
        guard !recipientPublicKeySent else {
            throw LegacyNearbyHandshakeErrorV2.recipientPublicKeyAlreadySent
        }
        try publicKey.validate()
        try Self.validateManifestExtensions(manifestExtensions)
        var payload = try canonicalEncode(publicKey)
        if !manifestExtensions.isEmpty {
            guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw LegacyNearbyHandshakeErrorV2.invalidPublicKey
            }
            object["manifestExtensions"] = manifestExtensions
            payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        let frame = try channel.seal(
            LegacyNearbyEncryptedEnvelopeV2(kind: .recipientPublicKey, payload: payload)
        )
        recipientPublicKeySent = true
        return frame
    }

    public func openRecipientPublicKey(_ frame: Data) throws -> EnrollmentPublicKeyV1 {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw LegacyNearbyHandshakeErrorV2.originOnlyOperation }
        guard !recipientPublicKeyReceived else {
            throw LegacyNearbyHandshakeErrorV2.recipientPublicKeyAlreadySent
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .recipientPublicKey else {
            throw LegacyNearbyHandshakeErrorV2.unexpectedMessage
        }
        let publicKey: EnrollmentPublicKeyV1
        do {
            publicKey = try JSONDecoder().decode(EnrollmentPublicKeyV1.self, from: envelope.payload)
            try publicKey.validate()
            let declaration = try JSONDecoder().decode(ManifestExtensionDeclaration.self, from: envelope.payload)
            let extensions = declaration.manifestExtensions ?? []
            try Self.validateManifestExtensions(extensions)
            peerManifestExtensionsStorage = extensions
        } catch let error as LegacyNearbyHandshakeErrorV2 {
            throw error
        } catch {
            throw LegacyNearbyHandshakeErrorV2.invalidPublicKey
        }
        recipientPublicKeyReceived = true
        return publicKey
    }

    private struct ManifestExtensionDeclaration: Decodable {
        let manifestExtensions: [String]?
    }

    private static func validateManifestExtensions(_ extensions: [String]) throws {
        guard extensions.count <= 16, Set(extensions).count == extensions.count,
              extensions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 &&
                  $0.utf8.allSatisfy { (0x21...0x7e).contains($0) } }) else {
            throw LegacyNearbyHandshakeErrorV2.invalidPublicKey
        }
    }

    /// Records the origin's explicit authorization result. Integration code
    /// supplies `.approved` only after fresh local biometric success.
    public func recordOriginAuthorization(
        _ authorization: LegacyNearbyOriginAuthorizationV2
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw LegacyNearbyHandshakeErrorV2.originOnlyOperation }
        guard recipientPublicKeyReceived else {
            throw LegacyNearbyHandshakeErrorV2.recipientPublicKeyRequired
        }
        guard originAuthorization == .pending else {
            throw LegacyNearbyHandshakeErrorV2.originAuthorizationAlreadyDecided
        }
        switch authorization {
        case .pending:
            throw LegacyNearbyHandshakeErrorV2.originAuthorizationRequired
        case .denied:
            originAuthorization = .denied
            aborted = true
            throw LegacyNearbyHandshakeErrorV2.originAuthorizationDenied
        case .approved:
            originAuthorization = .approved
        }
    }

    /// Seals the origin-authorization proof which must be sent immediately
    /// before the manifest on the same ordered channel.
    public func sealOriginAuthorizationProof() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw LegacyNearbyHandshakeErrorV2.originOnlyOperation }
        guard originAuthorization == .approved else {
            throw LegacyNearbyHandshakeErrorV2.originAuthorizationRequired
        }
        guard !authorizationProofSent else {
            throw LegacyNearbyHandshakeErrorV2.authorizationProofAlreadySent
        }
        let data = try channel.seal(
            LegacyNearbyEncryptedEnvelopeV2(kind: .originAuthorization, payload: Data())
        )
        authorizationProofSent = true
        return data
    }

    /// Opens the explicit authorization proof. There is intentionally no
    /// recipient-side setter for this state; it can only come from an
    /// authenticated origin-direction frame after local SAS confirmation.
    public func openOriginAuthorizationProof(_ frame: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .recipient else { throw LegacyNearbyHandshakeErrorV2.recipientOnlyOperation }
        guard originAuthorization == .pending else {
            throw LegacyNearbyHandshakeErrorV2.originAuthorizationAlreadyDecided
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .originAuthorization, envelope.payload.isEmpty else {
            throw LegacyNearbyHandshakeErrorV2.unexpectedMessage
        }
        originAuthorization = .approved
        authorizationProofReceived = true
    }

    /// The only manifest-sealing API. Both local SAS confirmation and explicit
    /// origin approval/proof ordering are checked, and the payload must come
    /// from the fail-closed optional-transfer approval wrapper.
    public func sealManifest(_ approvedManifest: ApprovedBootstrapManifestV2) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw LegacyNearbyHandshakeErrorV2.originOnlyOperation }
        guard originAuthorization == .approved else {
            throw LegacyNearbyHandshakeErrorV2.originAuthorizationRequired
        }
        guard authorizationProofSent else {
            throw LegacyNearbyHandshakeErrorV2.authorizationProofRequired
        }
        guard !manifestSent else {
            throw LegacyNearbyHandshakeErrorV2.manifestAlreadyTransferred
        }
        try approvedManifest.validate()
        guard approvedManifest.manifest.settings.agentCenterEnabled == nil ||
              peerManifestExtensionsStorage.contains(Self.agentCenterEnabledExtension) else {
            throw BootstrapManifestError.unknownField(path: "manifest.settings", field: "agentCenterEnabled")
        }
        let frame = try channel.seal(
            LegacyNearbyEncryptedEnvelopeV2(
                kind: .manifest,
                payload: approvedManifest.manifest.encoded()
            )
        )
        manifestSent = true
        return frame
    }

    /// The only public manifest-opening API. A recipient cannot even attempt
    /// manifest decryption until it has locally confirmed SAS and received the
    /// authenticated origin-authorization proof.
    public func openManifest(_ frame: Data) throws -> BootstrapManifest {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .recipient else { throw LegacyNearbyHandshakeErrorV2.recipientOnlyOperation }
        guard originAuthorization == .approved, authorizationProofReceived else {
            throw LegacyNearbyHandshakeErrorV2.authorizationProofRequired
        }
        guard recipientPublicKeySent else {
            throw LegacyNearbyHandshakeErrorV2.recipientPublicKeyRequired
        }
        guard !manifestReceived else {
            throw LegacyNearbyHandshakeErrorV2.manifestAlreadyTransferred
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .manifest else {
            throw LegacyNearbyHandshakeErrorV2.unexpectedMessage
        }
        let manifest = try BootstrapManifest.decode(envelope.payload)
        manifestReceived = true
        return manifest
    }

    public func sealImportAcceptance(
        _ acceptance: LegacyBootstrapImportAcceptanceV2
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .recipient else { throw LegacyNearbyHandshakeErrorV2.recipientOnlyOperation }
        guard manifestReceived else { throw LegacyNearbyHandshakeErrorV2.importAcceptanceRequired }
        guard !importAcceptanceSent else {
            throw LegacyNearbyHandshakeErrorV2.importAcceptanceAlreadyTransferred
        }
        let frame = try channel.seal(
            LegacyNearbyEncryptedEnvelopeV2(
                kind: .importAcceptance,
                payload: try canonicalEncode(acceptance)
            )
        )
        importAcceptanceSent = true
        return frame
    }

    public func openImportAcceptance(
        _ frame: Data
    ) throws -> LegacyBootstrapImportAcceptanceV2 {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw LegacyNearbyHandshakeErrorV2.originOnlyOperation }
        guard manifestSent else { throw LegacyNearbyHandshakeErrorV2.importAcceptanceRequired }
        guard !importAcceptanceReceived else {
            throw LegacyNearbyHandshakeErrorV2.importAcceptanceAlreadyTransferred
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .importAcceptance else {
            throw LegacyNearbyHandshakeErrorV2.unexpectedMessage
        }
        let acceptance: LegacyBootstrapImportAcceptanceV2
        do {
            acceptance = try JSONDecoder().decode(
                LegacyBootstrapImportAcceptanceV2.self,
                from: envelope.payload
            )
        } catch {
            throw LegacyNearbyHandshakeErrorV2.invalidImportAcceptance
        }
        importAcceptanceReceived = true
        return acceptance
    }

    public func sealGrantReceipt(_ receipt: LegacyBootstrapGrantBatchReceiptV2) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw LegacyNearbyHandshakeErrorV2.originOnlyOperation }
        guard manifestSent, importAcceptanceReceived else {
            throw LegacyNearbyHandshakeErrorV2.importAcceptanceRequired
        }
        guard !grantReceiptSent else {
            throw LegacyNearbyHandshakeErrorV2.grantReceiptAlreadyTransferred
        }
        let frame = try channel.seal(
            LegacyNearbyEncryptedEnvelopeV2(kind: .grantReceipt, payload: receipt.encoded())
        )
        grantReceiptSent = true
        return frame
    }

    public func openGrantReceipt(_ frame: Data) throws -> LegacyBootstrapGrantBatchReceiptV2 {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .recipient else { throw LegacyNearbyHandshakeErrorV2.recipientOnlyOperation }
        guard manifestReceived, importAcceptanceSent else {
            throw LegacyNearbyHandshakeErrorV2.importAcceptanceRequired
        }
        guard !grantReceiptReceived else {
            throw LegacyNearbyHandshakeErrorV2.grantReceiptAlreadyTransferred
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .grantReceipt else {
            throw LegacyNearbyHandshakeErrorV2.unexpectedMessage
        }
        let receipt: LegacyBootstrapGrantBatchReceiptV2
        do {
            receipt = try JSONDecoder().decode(
                LegacyBootstrapGrantBatchReceiptV2.self,
                from: envelope.payload
            )
        } catch {
            throw LegacyNearbyHandshakeErrorV2.invalidGrantReceipt
        }
        grantReceiptReceived = true
        return receipt
    }

    public func sealCompletionAcknowledgement(
        _ acknowledgement: LegacyBootstrapGrantCompletionAcknowledgementV2
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .recipient else { throw LegacyNearbyHandshakeErrorV2.recipientOnlyOperation }
        guard grantReceiptReceived else {
            throw LegacyNearbyHandshakeErrorV2.completionAcknowledgementRequired
        }
        guard !completionAcknowledgementSent else {
            throw LegacyNearbyHandshakeErrorV2.completionAcknowledgementAlreadyTransferred
        }
        let frame = try channel.seal(
            LegacyNearbyEncryptedEnvelopeV2(
                kind: .completionAcknowledgement,
                payload: try canonicalEncode(acknowledgement)
            )
        )
        completionAcknowledgementSent = true
        return frame
    }

    public func openCompletionAcknowledgement(
        _ frame: Data
    ) throws -> LegacyBootstrapGrantCompletionAcknowledgementV2 {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw LegacyNearbyHandshakeErrorV2.originOnlyOperation }
        guard grantReceiptSent else {
            throw LegacyNearbyHandshakeErrorV2.completionAcknowledgementRequired
        }
        guard !completionAcknowledgementReceived else {
            throw LegacyNearbyHandshakeErrorV2.completionAcknowledgementAlreadyTransferred
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .completionAcknowledgement else {
            throw LegacyNearbyHandshakeErrorV2.unexpectedMessage
        }
        let acknowledgement: LegacyBootstrapGrantCompletionAcknowledgementV2
        do {
            acknowledgement = try JSONDecoder().decode(
                LegacyBootstrapGrantCompletionAcknowledgementV2.self,
                from: envelope.payload
            )
        } catch {
            throw LegacyNearbyHandshakeErrorV2.invalidFrame
        }
        completionAcknowledgementReceived = true
        return acknowledgement
    }

    private func requireActiveAndSASConfirmed() throws {
        guard !aborted else { throw LegacyNearbyHandshakeErrorV2.transferAborted }
        guard localSASDecision == true,
              peerSASDecision == true else {
            throw LegacyNearbyHandshakeErrorV2.sasNotConfirmed
        }
    }

    #if DEBUG
    // Debug-only hooks let protocol tests exercise framing without making a
    // release-build channel API that can bypass the typed transfer sequence.
    public func sealTestPayload(_ payload: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        return try channel.seal(LegacyNearbyEncryptedEnvelopeV2(kind: .test, payload: payload))
    }

    public func openTestPayload(_ frame: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        let envelope = try channel.open(frame)
        guard envelope.kind == .test else { throw LegacyNearbyHandshakeErrorV2.unexpectedMessage }
        return envelope.payload
    }
    #endif

    private func canonicalEncode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private struct LegacyNearbyDirectionalMaterialV2 {
    let originToRecipientKey: SymmetricKey
    let recipientToOriginKey: SymmetricKey
    let originToRecipientNonce: Data
    let recipientToOriginNonce: Data
    let sasBytes: Data
}

private enum LegacyNearbyFrameDirectionV2: UInt8 {
    case originToRecipient = 1
    case recipientToOrigin = 2

    var peer: LegacyNearbyFrameDirectionV2 {
        switch self {
        case .originToRecipient: return .recipientToOrigin
        case .recipientToOrigin: return .originToRecipient
        }
    }
}

// Internal (not private) and CaseIterable so BootstrapWireSchemaTests can pin
// the wire kinds against the frozen v2 schema.
public enum LegacyNearbyEncryptedEnvelopeKindV2: String, Codable, CaseIterable {
    case sasDecision
    case recipientPublicKey
    case originAuthorization
    case manifest
    case importAcceptance
    case grantReceipt
    case completionAcknowledgement
    #if DEBUG
    case test
    #endif
}

private struct LegacyNearbyEncryptedEnvelopeV2: Codable {
    let kind: LegacyNearbyEncryptedEnvelopeKindV2
    let payload: Data
}

private final class LegacyNearbyEncryptedChannelV2: @unchecked Sendable {
    private static let magic = Data([0x54, 0x42, 0x43, 0x48]) // TBCH
    /// Bumps only together with LegacyNearbyBootstrapV2.version.
    private static let version: UInt8 = 1

    private let lock = NSLock()
    private let transcriptHash: Data
    private let outgoingDirection: LegacyNearbyFrameDirectionV2
    private let outgoingKey: SymmetricKey
    private let outgoingNonce: Data
    private let incomingKey: SymmetricKey
    private let incomingNonce: Data
    private var nextOutgoingSequence: UInt64 = 0
    private var nextIncomingSequence: UInt64 = 0

    init(
        localRole: LegacyNearbyHandshakeRoleV2,
        transcriptHash: Data,
        material: LegacyNearbyDirectionalMaterialV2
    ) {
        self.transcriptHash = transcriptHash
        switch localRole {
        case .origin:
            outgoingDirection = .originToRecipient
            outgoingKey = material.originToRecipientKey
            outgoingNonce = material.originToRecipientNonce
            incomingKey = material.recipientToOriginKey
            incomingNonce = material.recipientToOriginNonce
        case .recipient:
            outgoingDirection = .recipientToOrigin
            outgoingKey = material.recipientToOriginKey
            outgoingNonce = material.recipientToOriginNonce
            incomingKey = material.originToRecipientKey
            incomingNonce = material.originToRecipientNonce
        }
    }

    func seal(_ envelope: LegacyNearbyEncryptedEnvelopeV2) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard nextOutgoingSequence < UInt64.max else {
            throw LegacyNearbyHandshakeErrorV2.sequenceExhausted
        }
        let sequence = nextOutgoingSequence
        let header = makeHeader(direction: outgoingDirection, sequence: sequence)
        let plaintext = try JSONEncoder().encode(envelope)
        let nonce: ChaChaPoly.Nonce
        do {
            nonce = try ChaChaPoly.Nonce(data: nonceData(base: outgoingNonce, sequence: sequence))
        } catch {
            throw LegacyNearbyHandshakeErrorV2.invalidFrame
        }
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.seal(
                plaintext,
                using: outgoingKey,
                nonce: nonce,
                authenticating: authenticatedData(header: header)
            )
        } catch {
            throw LegacyNearbyHandshakeErrorV2.authenticationFailed
        }
        let frame = header + box.combined
        guard frame.count <= LegacyNearbyBootstrapV2.maximumEncryptedFrameSize else {
            throw LegacyNearbyHandshakeErrorV2.invalidFrame
        }
        nextOutgoingSequence += 1
        return frame
    }

    func open(_ inputFrame: Data) throws -> LegacyNearbyEncryptedEnvelopeV2 {
        lock.lock()
        defer { lock.unlock() }
        // Foundation `Data` slices preserve their original non-zero indices.
        // Normalize once before the fixed-offset frame parser indexes them.
        let frame = Data(inputFrame)
        guard frame.count <= LegacyNearbyBootstrapV2.maximumEncryptedFrameSize else {
            throw LegacyNearbyHandshakeErrorV2.invalidFrame
        }
        let headerCount = Self.magic.count + 1 + 1 + 8
        guard frame.count > headerCount,
              frame.prefix(Self.magic.count) == Self.magic else {
            throw LegacyNearbyHandshakeErrorV2.invalidFrame
        }
        let version = frame[Self.magic.count]
        guard version == Self.version else {
            throw LegacyNearbyHandshakeErrorV2.unsupportedFrameVersion(Int(version))
        }
        guard let direction = LegacyNearbyFrameDirectionV2(
            rawValue: frame[Self.magic.count + 1]
        ) else {
            throw LegacyNearbyHandshakeErrorV2.invalidFrame
        }
        guard direction == outgoingDirection.peer else {
            throw LegacyNearbyHandshakeErrorV2.wrongDirection
        }
        let sequenceStart = Self.magic.count + 2
        let sequence = frame.subdata(in: sequenceStart..<(sequenceStart + 8)).uint64BigEndian
        guard sequence == nextIncomingSequence else {
            throw LegacyNearbyHandshakeErrorV2.outOfOrder(
                expected: nextIncomingSequence,
                actual: sequence
            )
        }
        let header = frame.prefix(headerCount)
        let combined = frame.dropFirst(headerCount)
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: combined)
        } catch {
            throw LegacyNearbyHandshakeErrorV2.invalidFrame
        }
        let expectedNonce = nonceData(base: incomingNonce, sequence: sequence)
        let sealedNonce = box.nonce.withUnsafeBytes { Data($0) }
        guard sealedNonce == expectedNonce else {
            throw LegacyNearbyHandshakeErrorV2.authenticationFailed
        }
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(
                box,
                using: incomingKey,
                authenticating: authenticatedData(header: Data(header))
            )
        } catch {
            throw LegacyNearbyHandshakeErrorV2.authenticationFailed
        }
        let envelope: LegacyNearbyEncryptedEnvelopeV2
        do {
            envelope = try JSONDecoder().decode(LegacyNearbyEncryptedEnvelopeV2.self, from: plaintext)
        } catch {
            throw LegacyNearbyHandshakeErrorV2.invalidFrame
        }
        nextIncomingSequence += 1
        return envelope
    }

    private func makeHeader(direction: LegacyNearbyFrameDirectionV2, sequence: UInt64) -> Data {
        var header = Self.magic
        header.append(Self.version)
        header.append(direction.rawValue)
        header.appendUInt64(sequence)
        return header
    }

    private func authenticatedData(header: Data) -> Data {
        header + transcriptHash
    }

    private func nonceData(base: Data, sequence: UInt64) -> Data {
        var bytes = Array(base)
        let sequenceBytes = sequence.bigEndianBytes
        for index in 0..<8 {
            bytes[bytes.count - 8 + index] ^= sequenceBytes[index]
        }
        return Data(bytes)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: value.bigEndianBytes)
    }

    mutating func appendUInt64(_ value: UInt64) {
        append(contentsOf: value.bigEndianBytes)
    }

    mutating func appendLengthPrefixed(_ data: Data) {
        precondition(data.count <= Int(UInt16.max))
        appendUInt16(UInt16(data.count))
        append(data)
    }

    var uint64BigEndian: UInt64 {
        reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}
