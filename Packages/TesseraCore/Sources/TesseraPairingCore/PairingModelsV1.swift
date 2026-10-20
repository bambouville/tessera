import Crypto
import Foundation

public enum PairingPurpose: String, Codable, CaseIterable, Sendable {
    case continueSession = "continue"
    case bootstrap
    case enroll
    case setUpAndContinue
}

public enum PairingRoleV1: String, Codable, CaseIterable, Sendable {
    case origin
    case recipient

    public var peer: PairingRoleV1 {
        switch self {
        case .origin: return .recipient
        case .recipient: return .origin
        }
    }
}

public enum PairingEndpointTransportV1: String, Codable, CaseIterable, Sendable {
    case tcp
}

public struct PairingEndpointCandidateV1: Codable, Equatable, Sendable {
    public let transport: PairingEndpointTransportV1
    public let host: String
    public let port: UInt16

    public init(
        transport: PairingEndpointTransportV1 = .tcp,
        host: String,
        port: UInt16
    ) {
        self.transport = transport
        self.host = host
        self.port = port
    }

    fileprivate func validate() throws {
        guard port != 0 else { throw PairingError.invalidOffer(field: "endpointCandidates.port") }
        guard !host.isEmpty,
              host.utf8.count <= PairingOfferV1.maximumEndpointHostBytes,
              host.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && !CharacterSet.whitespacesAndNewlines.contains($0)
              }) else {
            throw PairingError.invalidOffer(field: "endpointCandidates.host")
        }
    }
}

public enum PairingOriginKeyMaterialKindV1: String, Codable, CaseIterable, Sendable {
    /// SHA-256 commitment to the offer ID, purpose, and origin ephemeral key.
    /// Pairing v1 deliberately does not permit the offer to disclose the key.
    case commitment
}

public struct PairingOriginKeyMaterialV1: Codable, Equatable, Sendable {
    public let kind: PairingOriginKeyMaterialKindV1
    public let value: Data

    public init(kind: PairingOriginKeyMaterialKindV1 = .commitment, value: Data) {
        self.kind = kind
        self.value = value
    }
}

/// Short-lived rendezvous data for Pairing v1. The only secret this type can
/// represent is a one-time optical secret; credentials and transaction payloads
/// have no fields in this closed schema.
public struct PairingOfferV1: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumEncodedBytes = 4_096
    public static let maximumLifetimeSeconds: Int64 = 10 * 60
    public static let maximumEndpointCandidates = 8
    public static let maximumEndpointHostBytes = 253
    public static let minimumOpticalSecretBytes = 16
    public static let maximumOpticalSecretBytes = 64
    public static let maximumVersionCount = 16

    public let version: Int
    public let offerID: UUID
    public let purpose: PairingPurpose
    /// Unix time in whole seconds. Integer time is intentional: it has one
    /// canonical, language-neutral JSON representation.
    public let expiresAt: Int64
    public let originRole: PairingRoleV1
    public let originEphemeralKeyOrCommitment: PairingOriginKeyMaterialV1
    public let endpointCandidates: [PairingEndpointCandidateV1]
    public let oneTimeOpticalSecret: Data?
    public let supportedPairingVersions: [Int]
    public let supportedTransactionVersions: [Int]
    public let optionalPayloadDigest: Data?

    public init(
        version: Int = PairingOfferV1.currentVersion,
        offerID: UUID,
        purpose: PairingPurpose,
        expiresAt: Int64,
        originRole: PairingRoleV1 = .origin,
        originEphemeralKeyOrCommitment: PairingOriginKeyMaterialV1,
        endpointCandidates: [PairingEndpointCandidateV1],
        oneTimeOpticalSecret: Data?,
        supportedPairingVersions: [Int] = [PairingOfferV1.currentVersion],
        supportedTransactionVersions: [Int],
        optionalPayloadDigest: Data? = nil
    ) {
        self.version = version
        self.offerID = offerID
        self.purpose = purpose
        self.expiresAt = expiresAt
        self.originRole = originRole
        self.originEphemeralKeyOrCommitment = originEphemeralKeyOrCommitment
        self.endpointCandidates = endpointCandidates
        self.oneTimeOpticalSecret = oneTimeOpticalSecret
        self.supportedPairingVersions = supportedPairingVersions
        self.supportedTransactionVersions = supportedTransactionVersions
        self.optionalPayloadDigest = optionalPayloadDigest
    }

    public func encoded() throws -> Data {
        try validate()
        return try PairingWireCodecV1.encodeBounded(self, maximum: Self.maximumEncodedBytes)
    }

    public static func decode(_ data: Data) throws -> PairingOfferV1 {
        let offer: PairingOfferV1 = try PairingWireCodecV1.decodeCanonical(
            data,
            maximum: Self.maximumEncodedBytes,
            allowedRootFields: [
                "version", "offerID", "purpose", "expiresAt", "originRole",
                "originEphemeralKeyOrCommitment", "endpointCandidates",
                "oneTimeOpticalSecret", "supportedPairingVersions",
                "supportedTransactionVersions", "optionalPayloadDigest",
            ]
        )
        try offer.validate()
        return offer
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw PairingError.unsupportedPairingVersion(version)
        }
        guard offerID.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw PairingError.invalidOffer(field: "offerID")
        }
        guard expiresAt > 0 else { throw PairingError.invalidOffer(field: "expiresAt") }
        guard originRole == .origin else { throw PairingError.invalidOffer(field: "originRole") }
        guard originEphemeralKeyOrCommitment.kind == .commitment,
              originEphemeralKeyOrCommitment.value.count == SHA256.Digest.byteCount else {
            throw PairingError.invalidOffer(field: "originEphemeralKeyOrCommitment")
        }
        guard endpointCandidates.count <= Self.maximumEndpointCandidates else {
            throw PairingError.invalidOffer(field: "endpointCandidates")
        }
        try endpointCandidates.forEach { try $0.validate() }
        if let oneTimeOpticalSecret {
            guard (Self.minimumOpticalSecretBytes...Self.maximumOpticalSecretBytes)
                .contains(oneTimeOpticalSecret.count) else {
                throw PairingError.invalidOpticalSecret
            }
        }
        guard PairingWireCodecV1.isCanonicalVersionList(
            supportedPairingVersions,
            maximumCount: Self.maximumVersionCount
        ), supportedPairingVersions.contains(Self.currentVersion) else {
            throw PairingError.invalidOffer(field: "supportedPairingVersions")
        }
        guard PairingWireCodecV1.isCanonicalVersionList(
            supportedTransactionVersions,
            maximumCount: Self.maximumVersionCount
        ) else {
            throw PairingError.invalidOffer(field: "supportedTransactionVersions")
        }
        if let optionalPayloadDigest,
           optionalPayloadDigest.count != SHA256.Digest.byteCount {
            throw PairingError.invalidOffer(field: "optionalPayloadDigest")
        }
    }

    /// Applies the short-lived rendezvous policy at the moment an offer is
    /// consumed. Structural decoding is time-independent so checked-in vectors
    /// remain usable after their illustrative timestamps pass.
    public func validateFresh(at unixTime: Int64) throws {
        guard expiresAt > unixTime else { throw PairingError.offerExpired }
        let (lifetime, overflow) = expiresAt.subtractingReportingOverflow(unixTime)
        guard !overflow, lifetime <= Self.maximumLifetimeSeconds else {
            throw PairingError.offerLifetimeTooLong
        }
    }
}

public struct PairingCommitmentV1: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumEncodedBytes = 4_096

    public let version: Int
    public let offerID: UUID
    public let purpose: PairingPurpose
    public let role: PairingRoleV1
    public let offerDigest: Data
    public let supportedPairingVersions: [Int]
    public let supportedTransactionVersions: [Int]
    public let selectedPairingVersion: Int
    public let selectedTransactionVersion: Int
    public let helloDigest: Data

    init(
        offerID: UUID,
        purpose: PairingPurpose,
        offerDigest: Data,
        supportedPairingVersions: [Int],
        supportedTransactionVersions: [Int],
        selectedPairingVersion: Int,
        selectedTransactionVersion: Int,
        helloDigest: Data
    ) {
        version = Self.currentVersion
        self.offerID = offerID
        self.purpose = purpose
        role = .recipient
        self.offerDigest = offerDigest
        self.supportedPairingVersions = supportedPairingVersions
        self.supportedTransactionVersions = supportedTransactionVersions
        self.selectedPairingVersion = selectedPairingVersion
        self.selectedTransactionVersion = selectedTransactionVersion
        self.helloDigest = helloDigest
    }

    public func encoded() throws -> Data {
        try validate()
        return try PairingWireCodecV1.encodeBounded(self, maximum: Self.maximumEncodedBytes)
    }

    public static func decode(_ data: Data) throws -> PairingCommitmentV1 {
        let value: PairingCommitmentV1 = try PairingWireCodecV1.decodeCanonical(
            data,
            maximum: Self.maximumEncodedBytes,
            allowedRootFields: [
                "version", "offerID", "purpose", "role", "offerDigest",
                "supportedPairingVersions", "supportedTransactionVersions",
                "selectedPairingVersion", "selectedTransactionVersion", "helloDigest",
            ]
        )
        try value.validate()
        return value
    }

    func validate() throws {
        guard version == Self.currentVersion else {
            throw PairingError.unsupportedPairingVersion(version)
        }
        guard role == .recipient else {
            throw PairingError.unexpectedRole(expected: .recipient, actual: role)
        }
        guard offerDigest.count == SHA256.Digest.byteCount,
              helloDigest.count == SHA256.Digest.byteCount else {
            throw PairingError.invalidCommitment
        }
        guard PairingWireCodecV1.isCanonicalVersionList(
            supportedPairingVersions,
            maximumCount: PairingOfferV1.maximumVersionCount
        ), PairingWireCodecV1.isCanonicalVersionList(
            supportedTransactionVersions,
            maximumCount: PairingOfferV1.maximumVersionCount
        ), supportedPairingVersions.contains(selectedPairingVersion),
           supportedTransactionVersions.contains(selectedTransactionVersion) else {
            throw PairingError.invalidCommitment
        }
    }
}

public struct PairingHelloV1: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumEncodedBytes = 4_096

    public let version: Int
    public let offerID: UUID
    public let purpose: PairingPurpose
    public let role: PairingRoleV1
    public let offerDigest: Data
    public let ephemeralPublicKey: Data
    public let supportedPairingVersions: [Int]
    public let supportedTransactionVersions: [Int]
    public let selectedPairingVersion: Int
    public let selectedTransactionVersion: Int

    init(
        offerID: UUID,
        purpose: PairingPurpose,
        role: PairingRoleV1,
        offerDigest: Data,
        ephemeralPublicKey: Data,
        supportedPairingVersions: [Int],
        supportedTransactionVersions: [Int],
        selectedPairingVersion: Int,
        selectedTransactionVersion: Int
    ) {
        version = Self.currentVersion
        self.offerID = offerID
        self.purpose = purpose
        self.role = role
        self.offerDigest = offerDigest
        self.ephemeralPublicKey = ephemeralPublicKey
        self.supportedPairingVersions = supportedPairingVersions
        self.supportedTransactionVersions = supportedTransactionVersions
        self.selectedPairingVersion = selectedPairingVersion
        self.selectedTransactionVersion = selectedTransactionVersion
    }

    public func encoded() throws -> Data {
        try validate()
        return try PairingWireCodecV1.encodeBounded(self, maximum: Self.maximumEncodedBytes)
    }

    public static func decode(_ data: Data) throws -> PairingHelloV1 {
        let value: PairingHelloV1 = try PairingWireCodecV1.decodeCanonical(
            data,
            maximum: Self.maximumEncodedBytes,
            allowedRootFields: [
                "version", "offerID", "purpose", "role", "offerDigest",
                "ephemeralPublicKey", "supportedPairingVersions",
                "supportedTransactionVersions", "selectedPairingVersion",
                "selectedTransactionVersion",
            ]
        )
        try value.validate()
        return value
    }

    func validate() throws {
        guard version == Self.currentVersion else {
            throw PairingError.unsupportedPairingVersion(version)
        }
        guard offerDigest.count == SHA256.Digest.byteCount else {
            throw PairingError.invalidHello
        }
        guard ephemeralPublicKey.count == 32 else { throw PairingError.invalidPublicKey }
        guard PairingWireCodecV1.isCanonicalVersionList(
            supportedPairingVersions,
            maximumCount: PairingOfferV1.maximumVersionCount
        ), PairingWireCodecV1.isCanonicalVersionList(
            supportedTransactionVersions,
            maximumCount: PairingOfferV1.maximumVersionCount
        ), supportedPairingVersions.contains(selectedPairingVersion),
           supportedTransactionVersions.contains(selectedTransactionVersion) else {
            throw PairingError.invalidHello
        }
    }
}

public struct PairingShortAuthenticationStringV1: Equatable, Hashable, Sendable,
    CustomStringConvertible
{
    public let value: Int

    public init(value: Int) throws {
        guard (0...999_999).contains(value) else { throw PairingError.invalidSAS }
        self.value = value
    }

    public var digits: String { String(format: "%06d", value) }
    public var displayValue: String { "\(digits.prefix(3)) \(digits.suffix(3))" }
    public var description: String { displayValue }
}

public enum PairingError: Error, Equatable, Sendable {
    case malformedMessage
    case nonCanonicalMessage
    case unknownField(String)
    case messageTooLarge(actual: Int, maximum: Int)
    case unsupportedPairingVersion(Int)
    case unsupportedFrameVersion(Int)
    case invalidOffer(field: String)
    case invalidOpticalSecret
    case offerExpired
    case offerLifetimeTooLong
    case offerAlreadyConsumed
    case noCommonPairingVersion
    case noCommonTransactionVersion
    case downgradeDetected
    case invalidPrivateKey
    case invalidPublicKey
    case invalidCommitment
    case commitmentMismatch
    case originKeyCommitmentMismatch
    case invalidHello
    case unexpectedRole(expected: PairingRoleV1, actual: PairingRoleV1)
    case reflectedPublicKey
    case attemptAlreadyConsumed
    case commitmentRequired
    case invalidSAS
    case invalidEnvelope
    case invalidFrame
    case wrongDirection
    case replayedFrame(UInt64)
    case outOfOrder(expected: UInt64, actual: UInt64)
    case sequenceExhausted
    case authenticationFailed
    case peerDecisionRequired
    case peerDecisionAlreadySent
    case peerDecisionAlreadyReceived
    case pairingRejected
    case sessionAborted
    case completionAlreadySent
    case completionAlreadyReceived
    case unexpectedMessageOrder
}

enum PairingWireCodecV1 {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw PairingError.malformedMessage
        }
    }

    static func encodeBounded<Value: Encodable>(_ value: Value, maximum: Int) throws -> Data {
        let data = try encode(value)
        guard data.count <= maximum else {
            throw PairingError.messageTooLarge(actual: data.count, maximum: maximum)
        }
        return data
    }

    static func decodeCanonical<Value: Codable>(
        _ data: Data,
        maximum: Int,
        allowedRootFields: Set<String>
    ) throws -> Value {
        guard data.count <= maximum else {
            throw PairingError.messageTooLarge(actual: data.count, maximum: maximum)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw PairingError.malformedMessage
        }
        guard let dictionary = object as? [String: Any] else {
            throw PairingError.malformedMessage
        }
        if let unknown = Set(dictionary.keys).subtracting(allowedRootFields).sorted().first {
            throw PairingError.unknownField(unknown)
        }
        let value: Value
        do {
            value = try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw PairingError.malformedMessage
        }
        guard try encode(value) == data else { throw PairingError.nonCanonicalMessage }
        return value
    }

    static func isCanonicalVersionList(_ versions: [Int], maximumCount: Int) -> Bool {
        !versions.isEmpty
            && versions.count <= maximumCount
            && versions.allSatisfy { $0 > 0 }
            && versions == Array(Set(versions)).sorted()
    }
}

extension Data {
    mutating func pairingAppendUInt16(_ value: UInt16) {
        append(contentsOf: value.pairingBigEndianBytes)
    }

    mutating func pairingAppendUInt32(_ value: UInt32) {
        append(contentsOf: value.pairingBigEndianBytes)
    }

    mutating func pairingAppendUInt64(_ value: UInt64) {
        append(contentsOf: value.pairingBigEndianBytes)
    }

    mutating func pairingAppendLengthPrefixed(_ value: Data) throws {
        guard value.count <= Int(UInt32.max) else { throw PairingError.malformedMessage }
        pairingAppendUInt32(UInt32(value.count))
        append(value)
    }

    var pairingUInt32BigEndian: UInt32 {
        reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    var pairingUInt64BigEndian: UInt64 {
        reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

extension FixedWidthInteger {
    var pairingBigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}
