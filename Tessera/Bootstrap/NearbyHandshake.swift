import CryptoKit
import Foundation

public enum NearbyHandshakeRole: String, Codable, CaseIterable, Sendable {
    case origin
    case recipient

    public var peer: NearbyHandshakeRole {
        switch self {
        case .origin: return .recipient
        case .recipient: return .origin
        }
    }
}

enum NearbyDeviceLabel {
    static let generic = "Nearby Tessera device"
    static let serviceFallback = "Tessera device"

    static func sanitized(
        _ rawValue: String?,
        fallback: String = generic
    ) -> String {
        guard let rawValue else { return fallback }
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
        let candidate = collapsed.isEmpty ? fallback : collapsed
        var result = ""
        var byteCount = 0
        for character in candidate.prefix(48) {
            let fragment = String(character)
            guard byteCount + fragment.utf8.count <= 192 else { break }
            result.append(character)
            byteCount += fragment.utf8.count
        }
        return result.isEmpty ? fallback : result
    }

    /// DNS-SD service instance names are a single label, so the Bonjour name
    /// must fit 63 UTF-8 bytes even though the encrypted hello may carry the
    /// longer human-readable device label.
    static func serviceName(_ rawValue: String?) -> String {
        let candidate = sanitized(rawValue, fallback: serviceFallback)
        var result = ""
        var byteCount = 0
        for character in candidate {
            let fragment = String(character)
            guard byteCount + fragment.utf8.count <= 63 else { break }
            result.append(character)
            byteCount += fragment.utf8.count
        }
        return result.isEmpty ? serviceFallback : result
    }
}

/// Cleartext handshake message. The role label is load-bearing: callers must
/// never infer roles from connection direction or device names.
public struct NearbyHandshakeHello: Codable, Equatable, Sendable {
    public static let currentVersion = NearbyBootstrapProtocol.version

    public let version: Int
    public let role: NearbyHandshakeRole
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
        version: Int = NearbyHandshakeHello.currentVersion,
        role: NearbyHandshakeRole,
        ephemeralPublicKey: Data,
        displayName: String? = nil,
        appVersion: String? = AppVersion.marketing,
        supportedVersions: [Int]? = NearbyBootstrapProtocol.supportedVersions
    ) {
        self.version = version
        self.role = role
        self.ephemeralPublicKey = ephemeralPublicKey
        self.displayName = displayName.map {
            NearbyDeviceLabel.sanitized($0)
        }
        self.appVersion = appVersion
        self.supportedVersions = supportedVersions
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> NearbyHandshakeHello {
        if let info = NearbyVersionProbe.probe(data), info.version != currentVersion {
            throw NearbyHandshakeError.incompatiblePeerVersion(info, message: .hello)
        }
        return try JSONDecoder().decode(NearbyHandshakeHello.self, from: data)
    }
}

/// The recipient's binding commitment for the role-asymmetric nearby
/// handshake. The origin must receive this value before disclosing its
/// ephemeral public key; the recipient reveals the committed hello only after
/// it receives the origin hello. That ordering prevents an active relay from
/// choosing either leg's key after learning the other leg's SAS.
public struct NearbyHandshakeCommitment: Codable, Equatable, Sendable {
    public static let currentVersion = NearbyHandshakeHello.currentVersion

    public let version: Int
    public let role: NearbyHandshakeRole
    public let helloDigest: Data
    /// Advisory only; see NearbyBootstrapCompatibility.swift. The commitment
    /// is the first bytes on the wire, so these fields are what lets a future
    /// origin recognize an old recipient and downgrade (or explain the
    /// mismatch) before disclosing anything.
    public let appVersion: String?
    public let supportedVersions: [Int]?

    fileprivate init(
        version: Int = NearbyHandshakeCommitment.currentVersion,
        role: NearbyHandshakeRole = .recipient,
        helloDigest: Data,
        appVersion: String? = AppVersion.marketing,
        supportedVersions: [Int]? = NearbyBootstrapProtocol.supportedVersions
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
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> NearbyHandshakeCommitment {
        if let info = NearbyVersionProbe.probe(data), info.version != currentVersion {
            throw NearbyHandshakeError.incompatiblePeerVersion(info, message: .commitment)
        }
        let commitment = try JSONDecoder().decode(Self.self, from: data)
        try commitment.validate()
        return commitment
    }

    fileprivate func validate() throws {
        guard version == Self.currentVersion else {
            throw NearbyHandshakeError.incompatiblePeerVersion(
                NearbyPeerVersionInfo(
                    version: version,
                    appVersion: appVersion,
                    supportedVersions: supportedVersions
                ),
                message: .commitment
            )
        }
        guard role == .recipient,
              helloDigest.count == SHA256.Digest.byteCount else {
            throw NearbyHandshakeError.invalidCommitment
        }
    }
}

public struct NearbyShortAuthenticationString: Equatable, Hashable, Sendable,
    CustomStringConvertible
{
    public let value: Int

    public init(value: Int) throws {
        guard (0...999_999).contains(value) else {
            throw NearbyHandshakeError.invalidSAS
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

public enum NearbyOriginAuthorization: Equatable, Sendable {
    case pending
    case approved
    case denied
}

enum BootstrapHostGrantStatus: String, Codable, Equatable, Sendable {
    case installed
    case failed
    case notSelected
    case rejectedImport
    case excludedAuthentication
}

/// Truthful per-host outcome returned by the origin after it attempts the
/// selected public-key grants. Every host in the manifest receives exactly one
/// result, including hosts that were not selected or were credential-ineligible.
struct BootstrapHostGrantResult: Codable, Equatable, Identifiable, Sendable {
    let hostID: UUID
    let hostName: String
    let status: BootstrapHostGrantStatus
    let detail: String?

    var id: UUID { hostID }
}

struct BootstrapGrantBatchReceipt: Codable, Equatable, Sendable {
    static let maximumDetailLength = 512

    let publicKeyID: UUID
    let publicKeyFingerprint: String
    let results: [BootstrapHostGrantResult]

    func validate(
        manifest: BootstrapManifest,
        publicKey: EnrollmentPublicKey
    ) throws {
        guard publicKeyID == publicKey.id,
              publicKeyFingerprint == publicKey.fingerprint,
              results.count == manifest.hosts.count,
              Set(results.map(\.hostID)).count == results.count,
              Set(results.map(\.hostID)) == Set(manifest.hosts.map(\.id))
        else { throw NearbyHandshakeError.invalidGrantReceipt }

        let hostsByID = Dictionary(uniqueKeysWithValues: manifest.hosts.map { ($0.id, $0) })
        for result in results {
            guard let host = hostsByID[result.hostID],
                  result.hostName == host.name,
                  (result.detail?.count ?? 0) <= Self.maximumDetailLength
            else { throw NearbyHandshakeError.invalidGrantReceipt }

            switch (host.authenticationHint, result.status) {
            case (.publicKey, .installed), (.publicKey, .failed),
                 (.publicKey, .notSelected), (.publicKey, .rejectedImport):
                break
            case (.password, .excludedAuthentication), (.none, .excludedAuthentication):
                break
            default:
                throw NearbyHandshakeError.invalidGrantReceipt
            }

            if result.status == .failed {
                guard let detail = result.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !detail.isEmpty
                else { throw NearbyHandshakeError.invalidGrantReceipt }
            } else if result.detail != nil {
                throw NearbyHandshakeError.invalidGrantReceipt
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
struct BootstrapImportAcceptance: Codable, Equatable, Sendable {
    let manifestHash: Data
    let acceptedHostIDs: [UUID]

    static func acknowledging(
        _ manifest: BootstrapManifest,
        acceptedHostIDs: Set<UUID>
    ) throws -> BootstrapImportAcceptance {
        let manifestIDs = Set(manifest.hosts.map(\.id))
        guard acceptedHostIDs.isSubset(of: manifestIDs) else {
            throw NearbyHandshakeError.invalidImportAcceptance
        }
        return BootstrapImportAcceptance(
            manifestHash: Data(SHA256.hash(data: try manifest.encoded())),
            acceptedHostIDs: acceptedHostIDs.sorted {
                $0.uuidString < $1.uuidString
            }
        )
    }

    func validates(_ manifest: BootstrapManifest) throws -> Bool {
        self == (try Self.acknowledging(
            manifest,
            acceptedHostIDs: Set(acceptedHostIDs)
        )) && Set(acceptedHostIDs).count == acceptedHostIDs.count
    }
}

struct BootstrapGrantCompletionAcknowledgement: Codable, Equatable, Sendable {
    let publicKeyID: UUID
    let grantReceiptHash: Data

    static func acknowledging(
        _ receipt: BootstrapGrantBatchReceipt
    ) throws -> BootstrapGrantCompletionAcknowledgement {
        BootstrapGrantCompletionAcknowledgement(
            publicKeyID: receipt.publicKeyID,
            grantReceiptHash: Data(SHA256.hash(data: try receipt.encoded()))
        )
    }

    func validates(_ receipt: BootstrapGrantBatchReceipt) throws -> Bool {
        self == (try Self.acknowledging(receipt))
    }
}

public enum NearbyHandshakeError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case incompatiblePeerVersion(NearbyPeerVersionInfo, message: NearbyVersionedMessageKind)
    case unsupportedFrameVersion(Int)
    case invalidPrivateKey
    case invalidPublicKey
    case unexpectedPeerRole(expected: NearbyHandshakeRole, actual: NearbyHandshakeRole)
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

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported nearby-handshake version \(version)."
        case .incompatiblePeerVersion(let info, _):
            let release = info.appVersion.map { " (\($0))" } ?? ""
            if info.version > NearbyBootstrapProtocol.version {
                return "The other device is running a newer version of Tessera\(release). "
                    + "Update Tessera on this device, then try again."
            }
            return "The other device is running an older version of Tessera\(release). "
                + "Update Tessera on the other device, then try again."
        case .unsupportedFrameVersion(let version):
            return "The encrypted channel used an unsupported frame version (\(version)). "
                + "Both devices must run compatible versions of Tessera."
        case .invalidPrivateKey: return "Invalid ephemeral private key."
        case .invalidPublicKey: return "Invalid ephemeral public key."
        case .unexpectedPeerRole(let expected, let actual):
            return "Expected peer role \(expected.rawValue), got \(actual.rawValue)."
        case .reflectedPublicKey: return "The peer reflected the local public key."
        case .attemptAlreadyConsumed: return "This handshake attempt has already been consumed."
        case .recipientCommitmentRequired:
            return "Publish the recipient commitment before completing the handshake."
        case .invalidCommitment: return "Invalid nearby-handshake commitment."
        case .commitmentMismatch: return "The recipient hello does not match its commitment."
        case .invalidSAS: return "Invalid short authentication string."
        case .sasAlreadyDecided: return "The code comparison has already been decided."
        case .sasMismatch: return "The codes did not match; start a fresh transfer."
        case .transferAborted: return "This transfer was aborted; start a fresh transfer."
        case .sasNotConfirmed: return "Confirm the code before continuing."
        case .originAuthorizationRequired: return "Origin authorization is required."
        case .originAuthorizationAlreadyDecided: return "Origin authorization has already been decided."
        case .originAuthorizationDenied: return "The origin denied this transfer."
        case .originOnlyOperation: return "Only the origin may perform this operation."
        case .recipientOnlyOperation: return "Only the recipient may perform this operation."
        case .authorizationProofRequired: return "Authorization proof must precede the manifest."
        case .authorizationProofAlreadySent: return "Authorization proof has already been sent."
        case .recipientPublicKeyRequired: return "The recipient public key is required."
        case .recipientPublicKeyAlreadySent: return "The recipient public key was already transferred."
        case .manifestAlreadyTransferred: return "The manifest was already transferred."
        case .importAcceptanceRequired:
            return "The recipient must acknowledge imported hosts before key grants begin."
        case .importAcceptanceAlreadyTransferred:
            return "The manifest import acknowledgement was already transferred."
        case .invalidImportAcceptance:
            return "The manifest import acknowledgement is invalid."
        case .grantReceiptRequired: return "The grant receipt must follow the manifest."
        case .grantReceiptAlreadyTransferred: return "The grant receipt was already transferred."
        case .completionAcknowledgementRequired:
            return "The completion acknowledgement must follow the grant receipt."
        case .completionAcknowledgementAlreadyTransferred:
            return "The completion acknowledgement was already transferred."
        case .invalidGrantReceipt: return "The host-grant receipt is invalid."
        case .unexpectedMessage: return "Unexpected encrypted message."
        case .invalidFrame: return "Invalid encrypted frame."
        case .wrongDirection: return "Encrypted frame has the wrong direction."
        case .outOfOrder(let expected, let actual):
            return "Expected frame \(expected), got \(actual)."
        case .sequenceExhausted: return "Encrypted-channel sequence is exhausted."
        case .authenticationFailed: return "Encrypted-frame authentication failed."
        }
    }
}

/// A single-use ephemeral X25519 attempt. Completion consumes the attempt even
/// when the peer hello is invalid, so a role reflection or mismatch cannot be
/// retried in-place with the same key material.
public final class NearbyHandshakeAttempt: @unchecked Sendable {
    public let role: NearbyHandshakeRole
    public let hello: NearbyHandshakeHello

    fileprivate let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let lock = NSLock()
    private var consumed = false
    private var recipientCommitmentPublished = false

    fileprivate init(
        role: NearbyHandshakeRole,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        displayName: String?
    ) {
        self.role = role
        self.privateKey = privateKey
        self.hello = NearbyHandshakeHello(
            role: role,
            ephemeralPublicKey: privateKey.publicKey.rawRepresentation,
            displayName: displayName
        )
    }

    fileprivate func markRecipientCommitmentPublished() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { throw NearbyHandshakeError.attemptAlreadyConsumed }
        recipientCommitmentPublished = true
    }

    fileprivate func consume(requiringRecipientCommitment: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { throw NearbyHandshakeError.attemptAlreadyConsumed }
        if requiringRecipientCommitment, !recipientCommitmentPublished {
            throw NearbyHandshakeError.recipientCommitmentRequired
        }
        consumed = true
    }
}

public enum NearbyHandshake {
    private static let transcriptLabel = Data("tessera/nearby-bootstrap/transcript/v2".utf8)
    private static let commitmentLabel = Data("tessera/nearby-bootstrap/recipient-commitment/v2".utf8)

    /// Starts a fresh attempt with a new ephemeral X25519 private key.
    public static func begin(
        role: NearbyHandshakeRole,
        displayName: String? = nil
    ) -> NearbyHandshakeAttempt {
        NearbyHandshakeAttempt(
            role: role,
            privateKey: Curve25519.KeyAgreement.PrivateKey(),
            displayName: displayName
        )
    }

    #if DEBUG
    /// Deterministic construction for protocol vectors. This API is absent
    /// from release builds so production attempts can only use fresh entropy.
    public static func begin(
        role: NearbyHandshakeRole,
        deterministicPrivateKey rawRepresentation: Data,
        displayName: String? = nil
    ) throws -> NearbyHandshakeAttempt {
        do {
            return NearbyHandshakeAttempt(
                role: role,
                privateKey: try Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: rawRepresentation
                ),
                displayName: displayName
            )
        } catch {
            throw NearbyHandshakeError.invalidPrivateKey
        }
    }
    #endif

    /// Produces the recipient's commitment before the origin discloses its
    /// hello. The committed bytes are the canonical, role-labelled hello.
    public static func recipientCommitment(
        for attempt: NearbyHandshakeAttempt
    ) throws -> NearbyHandshakeCommitment {
        guard attempt.role == .recipient else {
            throw NearbyHandshakeError.recipientOnlyOperation
        }
        try attempt.markRecipientCommitmentPublished()
        return NearbyHandshakeCommitment(
            helloDigest: try commitmentDigest(for: attempt.hello)
        )
    }

    /// Completes the recipient side after it has committed and received the
    /// origin's hello. The coordinator reveals `attempt.hello` only after this
    /// peer hello arrived.
    public static func completeRecipient(
        _ attempt: NearbyHandshakeAttempt,
        with originHello: NearbyHandshakeHello
    ) throws -> NearbyManifestTransferSession {
        guard attempt.role == .recipient else {
            throw NearbyHandshakeError.recipientOnlyOperation
        }
        try attempt.consume(requiringRecipientCommitment: true)
        return try completeConsumed(attempt, with: originHello)
    }

    /// Completes the origin side only after verifying that the revealed
    /// recipient hello matches the commitment received before the origin hello
    /// was sent.
    public static func completeOrigin(
        _ attempt: NearbyHandshakeAttempt,
        with recipientHello: NearbyHandshakeHello,
        verifying commitment: NearbyHandshakeCommitment
    ) throws -> NearbyManifestTransferSession {
        guard attempt.role == .origin else {
            throw NearbyHandshakeError.originOnlyOperation
        }
        try attempt.consume()
        try commitment.validate()
        guard commitment.helloDigest == (try commitmentDigest(for: recipientHello)) else {
            throw NearbyHandshakeError.commitmentMismatch
        }
        return try completeConsumed(attempt, with: recipientHello)
    }

    /// Shared X25519 completion after the role-specific disclosure order has
    /// already been enforced. Device names never influence the transcript.
    private static func completeConsumed(
        _ attempt: NearbyHandshakeAttempt,
        with peerHello: NearbyHandshakeHello
    ) throws -> NearbyManifestTransferSession {
        guard peerHello.version == NearbyHandshakeHello.currentVersion else {
            throw NearbyHandshakeError.unsupportedVersion(peerHello.version)
        }
        guard peerHello.role == attempt.role.peer else {
            throw NearbyHandshakeError.unexpectedPeerRole(
                expected: attempt.role.peer,
                actual: peerHello.role
            )
        }
        guard peerHello.ephemeralPublicKey != attempt.hello.ephemeralPublicKey else {
            throw NearbyHandshakeError.reflectedPublicKey
        }

        let peerPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: peerHello.ephemeralPublicKey
            )
        } catch {
            throw NearbyHandshakeError.invalidPublicKey
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try attempt.privateKey.sharedSecretFromKeyAgreement(
                with: peerPublicKey
            )
        } catch {
            throw NearbyHandshakeError.invalidPublicKey
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
        return try NearbyManifestTransferSession(
            localRole: attempt.role,
            transcriptHash: transcriptHash,
            material: material,
            peerDisplayName: peerHello.displayName.map {
                NearbyDeviceLabel.sanitized($0)
            }
        )
    }

    private static func commitmentDigest(
        for recipientHello: NearbyHandshakeHello
    ) throws -> Data {
        guard recipientHello.version == NearbyHandshakeHello.currentVersion,
              recipientHello.role == .recipient,
              recipientHello.ephemeralPublicKey.count == 32 else {
            throw NearbyHandshakeError.invalidCommitment
        }
        var committed = Data()
        committed.appendLengthPrefixed(commitmentLabel)
        // Version-2 peers committed the three original hello fields. Keep
        // hashing that legacy projection so an older decoder may ignore the
        // optional display label without breaking the commitment or SAS.
        let projection = NearbyHandshakeCommitmentProjection(
            version: recipientHello.version,
            role: recipientHello.role,
            ephemeralPublicKey: recipientHello.ephemeralPublicKey
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        committed.appendLengthPrefixed(try encoder.encode(projection))
        return Data(SHA256.hash(data: committed))
    }

    /// Canonical transcript with semantic ordering, explicit role labels, and
    /// length-delimited public keys. It is exposed for deterministic vectors.
    public static func makeTranscript(
        originHello: NearbyHandshakeHello,
        recipientHello: NearbyHandshakeHello
    ) throws -> Data {
        guard originHello.version == NearbyHandshakeHello.currentVersion else {
            throw NearbyHandshakeError.unsupportedVersion(originHello.version)
        }
        guard recipientHello.version == NearbyHandshakeHello.currentVersion else {
            throw NearbyHandshakeError.unsupportedVersion(recipientHello.version)
        }
        guard originHello.role == .origin else {
            throw NearbyHandshakeError.unexpectedPeerRole(expected: .origin, actual: originHello.role)
        }
        guard recipientHello.role == .recipient else {
            throw NearbyHandshakeError.unexpectedPeerRole(expected: .recipient, actual: recipientHello.role)
        }
        guard originHello.ephemeralPublicKey.count == 32,
              recipientHello.ephemeralPublicKey.count == 32 else {
            throw NearbyHandshakeError.invalidPublicKey
        }
        guard originHello.ephemeralPublicKey != recipientHello.ephemeralPublicKey else {
            throw NearbyHandshakeError.reflectedPublicKey
        }

        var transcript = Data()
        transcript.appendLengthPrefixed(transcriptLabel)
        transcript.appendUInt16(UInt16(NearbyHandshakeHello.currentVersion))
        transcript.appendLengthPrefixed(Data("role:origin".utf8))
        transcript.appendLengthPrefixed(originHello.ephemeralPublicKey)
        transcript.appendLengthPrefixed(Data("role:recipient".utf8))
        transcript.appendLengthPrefixed(recipientHello.ephemeralPublicKey)
        return transcript
    }

    private static func deriveMaterial(
        sharedSecret: SharedSecret,
        transcriptHash: Data
    ) -> NearbyDirectionalMaterial {
        func bytes(label: String, count: Int) -> Data {
            let key = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: transcriptHash,
                sharedInfo: Data("tessera/nearby-bootstrap/\(label)/v1".utf8),
                outputByteCount: count
            )
            return key.withUnsafeBytes { Data($0) }
        }

        return NearbyDirectionalMaterial(
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

private struct NearbyHandshakeCommitmentProjection: Codable {
    let version: Int
    let role: NearbyHandshakeRole
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
/// `NearbyHandshakeAttempt`, which also guarantees fresh ephemeral keys/code.
public final class NearbyManifestTransferSession: @unchecked Sendable {
    public let localRole: NearbyHandshakeRole
    public let transcriptHash: Data
    public let sas: NearbyShortAuthenticationString
    public let peerDisplayName: String?

    private let lock = NSLock()
    private var localSASDecision: Bool?
    private var peerSASDecision: Bool?
    private var aborted = false
    private var originAuthorization: NearbyOriginAuthorization = .pending
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
    private let channel: NearbyEncryptedChannel

    fileprivate init(
        localRole: NearbyHandshakeRole,
        transcriptHash: Data,
        material: NearbyDirectionalMaterial,
        peerDisplayName: String?
    ) throws {
        self.localRole = localRole
        self.transcriptHash = transcriptHash
        self.peerDisplayName = peerDisplayName
        self.sas = try NearbyShortAuthenticationString(
            value: Int(material.sasBytes.uint64BigEndian % 1_000_000)
        )
        self.channel = NearbyEncryptedChannel(
            localRole: localRole,
            transcriptHash: transcriptHash,
            material: material
        )
    }

    public var currentOriginAuthorization: NearbyOriginAuthorization {
        lock.lock()
        defer { lock.unlock() }
        return originAuthorization
    }

    /// Seals the local user's visual comparison as the first encrypted frame.
    /// Both peers exchange this decision before any setup payload is accepted,
    /// which lets an untouched comparison screen learn about a rejection
    /// immediately. `false` is terminal; the same session cannot be retried.
    func sealSASDecision(matches: Bool) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !aborted else { throw NearbyHandshakeError.transferAborted }
        guard localSASDecision == nil else {
            throw NearbyHandshakeError.sasAlreadyDecided
        }
        let frame = try channel.seal(
            NearbyEncryptedEnvelope(
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
    func openPeerSASDecision(_ frame: Data) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard peerSASDecision == nil else {
            throw NearbyHandshakeError.sasAlreadyDecided
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .sasDecision,
              envelope.payload.count == 1,
              let rawDecision = envelope.payload.first,
              rawDecision == 0 || rawDecision == 1 else {
            throw NearbyHandshakeError.unexpectedMessage
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
    func sealRecipientPublicKey(_ publicKey: EnrollmentPublicKey) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .recipient else { throw NearbyHandshakeError.recipientOnlyOperation }
        guard !recipientPublicKeySent else {
            throw NearbyHandshakeError.recipientPublicKeyAlreadySent
        }
        try publicKey.validate()
        let payload = try canonicalEncode(publicKey)
        let frame = try channel.seal(
            NearbyEncryptedEnvelope(kind: .recipientPublicKey, payload: payload)
        )
        recipientPublicKeySent = true
        return frame
    }

    func openRecipientPublicKey(_ frame: Data) throws -> EnrollmentPublicKey {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw NearbyHandshakeError.originOnlyOperation }
        guard !recipientPublicKeyReceived else {
            throw NearbyHandshakeError.recipientPublicKeyAlreadySent
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .recipientPublicKey else {
            throw NearbyHandshakeError.unexpectedMessage
        }
        let publicKey: EnrollmentPublicKey
        do {
            publicKey = try JSONDecoder().decode(EnrollmentPublicKey.self, from: envelope.payload)
            try publicKey.validate()
        } catch let error as NearbyHandshakeError {
            throw error
        } catch {
            throw NearbyHandshakeError.invalidPublicKey
        }
        recipientPublicKeyReceived = true
        return publicKey
    }

    /// Records the origin's explicit authorization result. Integration code
    /// supplies `.approved` only after fresh local biometric success.
    public func recordOriginAuthorization(
        _ authorization: NearbyOriginAuthorization
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw NearbyHandshakeError.originOnlyOperation }
        guard recipientPublicKeyReceived else {
            throw NearbyHandshakeError.recipientPublicKeyRequired
        }
        guard originAuthorization == .pending else {
            throw NearbyHandshakeError.originAuthorizationAlreadyDecided
        }
        switch authorization {
        case .pending:
            throw NearbyHandshakeError.originAuthorizationRequired
        case .denied:
            originAuthorization = .denied
            aborted = true
            throw NearbyHandshakeError.originAuthorizationDenied
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
        guard localRole == .origin else { throw NearbyHandshakeError.originOnlyOperation }
        guard originAuthorization == .approved else {
            throw NearbyHandshakeError.originAuthorizationRequired
        }
        guard !authorizationProofSent else {
            throw NearbyHandshakeError.authorizationProofAlreadySent
        }
        let data = try channel.seal(
            NearbyEncryptedEnvelope(kind: .originAuthorization, payload: Data())
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
        guard localRole == .recipient else { throw NearbyHandshakeError.recipientOnlyOperation }
        guard originAuthorization == .pending else {
            throw NearbyHandshakeError.originAuthorizationAlreadyDecided
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .originAuthorization, envelope.payload.isEmpty else {
            throw NearbyHandshakeError.unexpectedMessage
        }
        originAuthorization = .approved
        authorizationProofReceived = true
    }

    /// The only manifest-sealing API. Both local SAS confirmation and explicit
    /// origin approval/proof ordering are checked, and the payload must come
    /// from the fail-closed optional-transfer approval wrapper.
    func sealManifest(_ approvedManifest: ApprovedBootstrapManifest) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw NearbyHandshakeError.originOnlyOperation }
        guard originAuthorization == .approved else {
            throw NearbyHandshakeError.originAuthorizationRequired
        }
        guard authorizationProofSent else {
            throw NearbyHandshakeError.authorizationProofRequired
        }
        guard !manifestSent else {
            throw NearbyHandshakeError.manifestAlreadyTransferred
        }
        try approvedManifest.validate()
        let frame = try channel.seal(
            NearbyEncryptedEnvelope(
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
        guard localRole == .recipient else { throw NearbyHandshakeError.recipientOnlyOperation }
        guard originAuthorization == .approved, authorizationProofReceived else {
            throw NearbyHandshakeError.authorizationProofRequired
        }
        guard recipientPublicKeySent else {
            throw NearbyHandshakeError.recipientPublicKeyRequired
        }
        guard !manifestReceived else {
            throw NearbyHandshakeError.manifestAlreadyTransferred
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .manifest else {
            throw NearbyHandshakeError.unexpectedMessage
        }
        let manifest = try BootstrapManifest.decode(envelope.payload)
        manifestReceived = true
        return manifest
    }

    func sealImportAcceptance(
        _ acceptance: BootstrapImportAcceptance
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .recipient else { throw NearbyHandshakeError.recipientOnlyOperation }
        guard manifestReceived else { throw NearbyHandshakeError.importAcceptanceRequired }
        guard !importAcceptanceSent else {
            throw NearbyHandshakeError.importAcceptanceAlreadyTransferred
        }
        let frame = try channel.seal(
            NearbyEncryptedEnvelope(
                kind: .importAcceptance,
                payload: try canonicalEncode(acceptance)
            )
        )
        importAcceptanceSent = true
        return frame
    }

    func openImportAcceptance(
        _ frame: Data
    ) throws -> BootstrapImportAcceptance {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw NearbyHandshakeError.originOnlyOperation }
        guard manifestSent else { throw NearbyHandshakeError.importAcceptanceRequired }
        guard !importAcceptanceReceived else {
            throw NearbyHandshakeError.importAcceptanceAlreadyTransferred
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .importAcceptance else {
            throw NearbyHandshakeError.unexpectedMessage
        }
        let acceptance: BootstrapImportAcceptance
        do {
            acceptance = try JSONDecoder().decode(
                BootstrapImportAcceptance.self,
                from: envelope.payload
            )
        } catch {
            throw NearbyHandshakeError.invalidImportAcceptance
        }
        importAcceptanceReceived = true
        return acceptance
    }

    func sealGrantReceipt(_ receipt: BootstrapGrantBatchReceipt) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw NearbyHandshakeError.originOnlyOperation }
        guard manifestSent, importAcceptanceReceived else {
            throw NearbyHandshakeError.importAcceptanceRequired
        }
        guard !grantReceiptSent else {
            throw NearbyHandshakeError.grantReceiptAlreadyTransferred
        }
        let frame = try channel.seal(
            NearbyEncryptedEnvelope(kind: .grantReceipt, payload: receipt.encoded())
        )
        grantReceiptSent = true
        return frame
    }

    func openGrantReceipt(_ frame: Data) throws -> BootstrapGrantBatchReceipt {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .recipient else { throw NearbyHandshakeError.recipientOnlyOperation }
        guard manifestReceived, importAcceptanceSent else {
            throw NearbyHandshakeError.importAcceptanceRequired
        }
        guard !grantReceiptReceived else {
            throw NearbyHandshakeError.grantReceiptAlreadyTransferred
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .grantReceipt else {
            throw NearbyHandshakeError.unexpectedMessage
        }
        let receipt: BootstrapGrantBatchReceipt
        do {
            receipt = try JSONDecoder().decode(
                BootstrapGrantBatchReceipt.self,
                from: envelope.payload
            )
        } catch {
            throw NearbyHandshakeError.invalidGrantReceipt
        }
        grantReceiptReceived = true
        return receipt
    }

    func sealCompletionAcknowledgement(
        _ acknowledgement: BootstrapGrantCompletionAcknowledgement
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .recipient else { throw NearbyHandshakeError.recipientOnlyOperation }
        guard grantReceiptReceived else {
            throw NearbyHandshakeError.completionAcknowledgementRequired
        }
        guard !completionAcknowledgementSent else {
            throw NearbyHandshakeError.completionAcknowledgementAlreadyTransferred
        }
        let frame = try channel.seal(
            NearbyEncryptedEnvelope(
                kind: .completionAcknowledgement,
                payload: try canonicalEncode(acknowledgement)
            )
        )
        completionAcknowledgementSent = true
        return frame
    }

    func openCompletionAcknowledgement(
        _ frame: Data
    ) throws -> BootstrapGrantCompletionAcknowledgement {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        guard localRole == .origin else { throw NearbyHandshakeError.originOnlyOperation }
        guard grantReceiptSent else {
            throw NearbyHandshakeError.completionAcknowledgementRequired
        }
        guard !completionAcknowledgementReceived else {
            throw NearbyHandshakeError.completionAcknowledgementAlreadyTransferred
        }
        let envelope = try channel.open(frame)
        guard envelope.kind == .completionAcknowledgement else {
            throw NearbyHandshakeError.unexpectedMessage
        }
        let acknowledgement: BootstrapGrantCompletionAcknowledgement
        do {
            acknowledgement = try JSONDecoder().decode(
                BootstrapGrantCompletionAcknowledgement.self,
                from: envelope.payload
            )
        } catch {
            throw NearbyHandshakeError.invalidFrame
        }
        completionAcknowledgementReceived = true
        return acknowledgement
    }

    private func requireActiveAndSASConfirmed() throws {
        guard !aborted else { throw NearbyHandshakeError.transferAborted }
        guard localSASDecision == true,
              peerSASDecision == true else {
            throw NearbyHandshakeError.sasNotConfirmed
        }
    }

    #if DEBUG
    // Debug-only hooks let protocol tests exercise framing without making a
    // release-build channel API that can bypass the typed transfer sequence.
    func sealTestPayload(_ payload: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        return try channel.seal(NearbyEncryptedEnvelope(kind: .test, payload: payload))
    }

    func openTestPayload(_ frame: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireActiveAndSASConfirmed()
        let envelope = try channel.open(frame)
        guard envelope.kind == .test else { throw NearbyHandshakeError.unexpectedMessage }
        return envelope.payload
    }
    #endif

    private func canonicalEncode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private struct NearbyDirectionalMaterial {
    let originToRecipientKey: SymmetricKey
    let recipientToOriginKey: SymmetricKey
    let originToRecipientNonce: Data
    let recipientToOriginNonce: Data
    let sasBytes: Data
}

private enum NearbyFrameDirection: UInt8 {
    case originToRecipient = 1
    case recipientToOrigin = 2

    var peer: NearbyFrameDirection {
        switch self {
        case .originToRecipient: return .recipientToOrigin
        case .recipientToOrigin: return .originToRecipient
        }
    }
}

// Internal (not private) and CaseIterable so BootstrapWireSchemaTests can pin
// the wire kinds against the frozen v2 schema.
enum NearbyEncryptedEnvelopeKind: String, Codable, CaseIterable {
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

private struct NearbyEncryptedEnvelope: Codable {
    let kind: NearbyEncryptedEnvelopeKind
    let payload: Data
}

private final class NearbyEncryptedChannel: @unchecked Sendable {
    private static let magic = Data([0x54, 0x42, 0x43, 0x48]) // TBCH
    /// Bumps only together with NearbyBootstrapProtocol.version.
    private static let version: UInt8 = 1

    private let lock = NSLock()
    private let transcriptHash: Data
    private let outgoingDirection: NearbyFrameDirection
    private let outgoingKey: SymmetricKey
    private let outgoingNonce: Data
    private let incomingKey: SymmetricKey
    private let incomingNonce: Data
    private var nextOutgoingSequence: UInt64 = 0
    private var nextIncomingSequence: UInt64 = 0

    init(
        localRole: NearbyHandshakeRole,
        transcriptHash: Data,
        material: NearbyDirectionalMaterial
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

    func seal(_ envelope: NearbyEncryptedEnvelope) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard nextOutgoingSequence < UInt64.max else {
            throw NearbyHandshakeError.sequenceExhausted
        }
        let sequence = nextOutgoingSequence
        let header = makeHeader(direction: outgoingDirection, sequence: sequence)
        let plaintext = try JSONEncoder().encode(envelope)
        let nonce: ChaChaPoly.Nonce
        do {
            nonce = try ChaChaPoly.Nonce(data: nonceData(base: outgoingNonce, sequence: sequence))
        } catch {
            throw NearbyHandshakeError.invalidFrame
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
            throw NearbyHandshakeError.authenticationFailed
        }
        nextOutgoingSequence += 1
        return header + box.combined
    }

    func open(_ inputFrame: Data) throws -> NearbyEncryptedEnvelope {
        lock.lock()
        defer { lock.unlock() }
        // Foundation `Data` slices preserve their original non-zero indices.
        // Normalize once before the fixed-offset frame parser indexes them.
        let frame = Data(inputFrame)
        let headerCount = Self.magic.count + 1 + 1 + 8
        guard frame.count > headerCount,
              frame.prefix(Self.magic.count) == Self.magic else {
            throw NearbyHandshakeError.invalidFrame
        }
        let version = frame[Self.magic.count]
        guard version == Self.version else {
            throw NearbyHandshakeError.unsupportedFrameVersion(Int(version))
        }
        guard let direction = NearbyFrameDirection(
            rawValue: frame[Self.magic.count + 1]
        ) else {
            throw NearbyHandshakeError.invalidFrame
        }
        guard direction == outgoingDirection.peer else {
            throw NearbyHandshakeError.wrongDirection
        }
        let sequenceStart = Self.magic.count + 2
        let sequence = frame.subdata(in: sequenceStart..<(sequenceStart + 8)).uint64BigEndian
        guard sequence == nextIncomingSequence else {
            throw NearbyHandshakeError.outOfOrder(
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
            throw NearbyHandshakeError.invalidFrame
        }
        let expectedNonce = nonceData(base: incomingNonce, sequence: sequence)
        let sealedNonce = box.nonce.withUnsafeBytes { Data($0) }
        guard sealedNonce == expectedNonce else {
            throw NearbyHandshakeError.authenticationFailed
        }
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(
                box,
                using: incomingKey,
                authenticating: authenticatedData(header: Data(header))
            )
        } catch {
            throw NearbyHandshakeError.authenticationFailed
        }
        let envelope: NearbyEncryptedEnvelope
        do {
            envelope = try JSONDecoder().decode(NearbyEncryptedEnvelope.self, from: plaintext)
        } catch {
            throw NearbyHandshakeError.invalidFrame
        }
        nextIncomingSequence += 1
        return envelope
    }

    private func makeHeader(direction: NearbyFrameDirection, sequence: UInt64) -> Data {
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
