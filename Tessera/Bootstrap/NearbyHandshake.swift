import Foundation
import TesseraBootstrapCore
import TesseraEnrollmentCore
import TesseraProtocolCore

public typealias NearbyHandshakeRole = LegacyNearbyHandshakeRoleV2
public typealias NearbyShortAuthenticationString = LegacyNearbyShortAuthenticationStringV2
public typealias NearbyOriginAuthorization = LegacyNearbyOriginAuthorizationV2
typealias BootstrapHostGrantStatus = LegacyBootstrapHostGrantStatusV2
typealias BootstrapHostGrantResult = LegacyBootstrapHostGrantResultV2
typealias BootstrapGrantBatchReceipt = LegacyBootstrapGrantBatchReceiptV2
typealias BootstrapImportAcceptance = LegacyBootstrapImportAcceptanceV2
typealias BootstrapGrantCompletionAcknowledgement = LegacyBootstrapGrantCompletionAcknowledgementV2
typealias NearbyEncryptedEnvelopeKind = LegacyNearbyEncryptedEnvelopeKindV2
public typealias NearbyHandshakeError = LegacyNearbyHandshakeErrorV2

enum NearbyDeviceLabel {
    static let generic = String(localized: "Nearby Tessera device")
    static let serviceFallback = String(localized: "Tessera device")

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

/// Apple-facing spelling of the portable released-v2 hello. The only Apple
/// policy here is the bundle marketing-version default and localized fallback
/// used when sanitizing a human-readable device label.
public struct NearbyHandshakeHello: Codable, Equatable, Sendable {
    public static let currentVersion = LegacyNearbyHandshakeHelloV2.currentVersion

    public let version: Int
    public let role: NearbyHandshakeRole
    public let ephemeralPublicKey: Data
    public let displayName: String?
    public let appVersion: String?
    public let supportedVersions: [Int]?

    public init(
        version: Int = currentVersion,
        role: NearbyHandshakeRole,
        ephemeralPublicKey: Data,
        displayName: String? = nil,
        appVersion: String? = AppVersion.marketing,
        supportedVersions: [Int]? = NearbyBootstrapProtocol.supportedVersions
    ) {
        self.version = version
        self.role = role
        self.ephemeralPublicKey = ephemeralPublicKey
        self.displayName = displayName.map { NearbyDeviceLabel.sanitized($0) }
        self.appVersion = appVersion
        self.supportedVersions = supportedVersions
    }

    fileprivate init(core: LegacyNearbyHandshakeHelloV2) {
        // Decoding the released Codable model assigned wire fields directly;
        // preserve that behavior here. Locally constructed hellos still pass
        // through the public initializer's Apple label sanitation.
        version = core.version
        role = core.role
        ephemeralPublicKey = core.ephemeralPublicKey
        displayName = core.displayName
        appVersion = core.appVersion
        supportedVersions = core.supportedVersions
    }

    fileprivate var core: LegacyNearbyHandshakeHelloV2 {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            // Round-trip through the portable decoder so a received wire
            // label is not silently re-sanitized by its construction API.
            return try LegacyNearbyHandshakeHelloV2.decode(encoder.encode(self))
        }
    }

    public func encoded() throws -> Data { try core.encoded() }

    public static func decode(_ data: Data) throws -> Self {
        Self(core: try LegacyNearbyHandshakeHelloV2.decode(data))
    }
}

public struct NearbyHandshakeCommitment: Codable, Equatable, Sendable {
    public static let currentVersion = LegacyNearbyHandshakeCommitmentV2.currentVersion

    public let version: Int
    public let role: NearbyHandshakeRole
    public let helloDigest: Data
    public let appVersion: String?
    public let supportedVersions: [Int]?

    fileprivate init(core: LegacyNearbyHandshakeCommitmentV2) {
        version = core.version
        role = core.role
        helloDigest = core.helloDigest
        appVersion = core.appVersion
        supportedVersions = core.supportedVersions
    }

    fileprivate var core: LegacyNearbyHandshakeCommitmentV2 {
        // The portable strict decoder is the sole public construction path for
        // commitments, preserving the released validation boundary.
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try LegacyNearbyHandshakeCommitmentV2.decode(encoder.encode(self))
        }
    }

    public func encoded() throws -> Data { try core.encoded() }

    public static func decode(_ data: Data) throws -> Self {
        Self(core: try LegacyNearbyHandshakeCommitmentV2.decode(data))
    }
}

public final class NearbyHandshakeAttempt: @unchecked Sendable {
    public let role: NearbyHandshakeRole
    public let hello: NearbyHandshakeHello
    fileprivate let core: LegacyNearbyHandshakeAttemptV2

    fileprivate init(core: LegacyNearbyHandshakeAttemptV2) {
        self.core = core
        role = core.role
        hello = NearbyHandshakeHello(core: core.hello)
    }
}

public enum NearbyHandshake {
    public static func begin(
        role: NearbyHandshakeRole,
        displayName: String? = nil
    ) -> NearbyHandshakeAttempt {
        NearbyHandshakeAttempt(
            core: LegacyNearbyHandshakeV2.begin(
                role: role,
                displayName: displayName.map { NearbyDeviceLabel.sanitized($0) },
                appVersion: AppVersion.marketing
            )
        )
    }

    #if DEBUG
    public static func begin(
        role: NearbyHandshakeRole,
        deterministicPrivateKey rawRepresentation: Data,
        displayName: String? = nil
    ) throws -> NearbyHandshakeAttempt {
        NearbyHandshakeAttempt(
            core: try LegacyNearbyHandshakeV2.begin(
                role: role,
                deterministicPrivateKey: rawRepresentation,
                displayName: displayName.map { NearbyDeviceLabel.sanitized($0) },
                appVersion: AppVersion.marketing
            )
        )
    }
    #endif

    public static func recipientCommitment(
        for attempt: NearbyHandshakeAttempt
    ) throws -> NearbyHandshakeCommitment {
        NearbyHandshakeCommitment(
            core: try LegacyNearbyHandshakeV2.recipientCommitment(for: attempt.core)
        )
    }

    public static func completeRecipient(
        _ attempt: NearbyHandshakeAttempt,
        with originHello: NearbyHandshakeHello
    ) throws -> NearbyManifestTransferSession {
        NearbyManifestTransferSession(
            core: try LegacyNearbyHandshakeV2.completeRecipient(
                attempt.core,
                with: try originHello.core
            )
        )
    }

    public static func completeOrigin(
        _ attempt: NearbyHandshakeAttempt,
        with recipientHello: NearbyHandshakeHello,
        verifying commitment: NearbyHandshakeCommitment
    ) throws -> NearbyManifestTransferSession {
        NearbyManifestTransferSession(
            core: try LegacyNearbyHandshakeV2.completeOrigin(
                attempt.core,
                with: try recipientHello.core,
                verifying: try commitment.core
            )
        )
    }

    public static func makeTranscript(
        originHello: NearbyHandshakeHello,
        recipientHello: NearbyHandshakeHello
    ) throws -> Data {
        try LegacyNearbyHandshakeV2.makeTranscript(
            originHello: try originHello.core,
            recipientHello: try recipientHello.core
        )
    }
}

/// Thin Apple adapter around the portable ordered transfer state machine. Only
/// the existing app enrollment-key wrapper crosses this boundary.
public final class NearbyManifestTransferSession: @unchecked Sendable {
    private let core: LegacyNearbyManifestTransferSessionV2

    fileprivate init(core: LegacyNearbyManifestTransferSessionV2) {
        self.core = core
    }

    public var localRole: NearbyHandshakeRole { core.localRole }
    public var transcriptHash: Data { core.transcriptHash }
    public var sas: NearbyShortAuthenticationString { core.sas }
    public var peerDisplayName: String? { core.peerDisplayName }
    public var currentOriginAuthorization: NearbyOriginAuthorization {
        core.currentOriginAuthorization
    }

    func sealSASDecision(matches: Bool) throws -> Data {
        try core.sealSASDecision(matches: matches)
    }

    func openPeerSASDecision(_ frame: Data) throws -> Bool {
        try core.openPeerSASDecision(frame)
    }

    var peerSupportsAgentCenterEnabled: Bool {
        core.peerManifestExtensions.contains(LegacyNearbyManifestTransferSessionV2.agentCenterEnabledExtension)
    }

    func sealRecipientPublicKey(_ publicKey: EnrollmentPublicKey, declareManifestExtensions: Bool = true) throws -> Data {
        try core.sealRecipientPublicKey(publicKey.core, manifestExtensions: declareManifestExtensions
            ? [LegacyNearbyManifestTransferSessionV2.agentCenterEnabledExtension] : [])
    }

    func openRecipientPublicKey(_ frame: Data) throws -> EnrollmentPublicKey {
        EnrollmentPublicKey(core: try core.openRecipientPublicKey(frame))
    }

    public func recordOriginAuthorization(
        _ authorization: NearbyOriginAuthorization
    ) throws {
        try core.recordOriginAuthorization(authorization)
    }

    public func sealOriginAuthorizationProof() throws -> Data {
        try core.sealOriginAuthorizationProof()
    }

    public func openOriginAuthorizationProof(_ frame: Data) throws {
        try core.openOriginAuthorizationProof(frame)
    }

    func sealManifest(_ approvedManifest: ApprovedBootstrapManifest) throws -> Data {
        try core.sealManifest(approvedManifest)
    }

    public func openManifest(_ frame: Data) throws -> BootstrapManifest {
        try core.openManifest(frame)
    }

    func sealImportAcceptance(_ acceptance: BootstrapImportAcceptance) throws -> Data {
        try core.sealImportAcceptance(acceptance)
    }

    func openImportAcceptance(_ frame: Data) throws -> BootstrapImportAcceptance {
        try core.openImportAcceptance(frame)
    }

    func sealGrantReceipt(_ receipt: BootstrapGrantBatchReceipt) throws -> Data {
        try core.sealGrantReceipt(receipt)
    }

    func openGrantReceipt(_ frame: Data) throws -> BootstrapGrantBatchReceipt {
        try core.openGrantReceipt(frame)
    }

    func sealCompletionAcknowledgement(
        _ acknowledgement: BootstrapGrantCompletionAcknowledgement
    ) throws -> Data {
        try core.sealCompletionAcknowledgement(acknowledgement)
    }

    func openCompletionAcknowledgement(
        _ frame: Data
    ) throws -> BootstrapGrantCompletionAcknowledgement {
        try core.openCompletionAcknowledgement(frame)
    }

    #if DEBUG
    func sealTestPayload(_ payload: Data) throws -> Data {
        try core.sealTestPayload(payload)
    }

    func openTestPayload(_ frame: Data) throws -> Data {
        try core.openTestPayload(frame)
    }
    #endif
}

extension LegacyNearbyHandshakeErrorV2: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return String(localized: "Unsupported nearby-handshake version \(version).")
        case .incompatiblePeerVersion(let info, _):
            let release = info.appVersion.map { " (\($0))" } ?? ""
            if info.version > NearbyBootstrapProtocol.version {
                return String(localized: "The other device is running a newer version of Tessera\(release). Update Tessera on this device, then try again.")
            }
            return String(localized: "The other device is running an older version of Tessera\(release). Update Tessera on the other device, then try again.")
        case .unsupportedFrameVersion(let version):
            return String(localized: "The encrypted channel used an unsupported frame version (\(version)). Both devices must run compatible versions of Tessera.")
        case .invalidPrivateKey: return String(localized: "Invalid ephemeral private key.")
        case .invalidPublicKey: return String(localized: "Invalid ephemeral public key.")
        case .unexpectedPeerRole(let expected, let actual):
            return String(localized: "Expected peer role \(expected.rawValue), got \(actual.rawValue).")
        case .reflectedPublicKey: return String(localized: "The peer reflected the local public key.")
        case .attemptAlreadyConsumed: return String(localized: "This handshake attempt has already been consumed.")
        case .recipientCommitmentRequired:
            return String(localized: "Publish the recipient commitment before completing the handshake.")
        case .invalidCommitment: return String(localized: "Invalid nearby-handshake commitment.")
        case .commitmentMismatch: return String(localized: "The recipient hello does not match its commitment.")
        case .invalidSAS: return String(localized: "Invalid short authentication string.")
        case .sasAlreadyDecided: return String(localized: "The code comparison has already been decided.")
        case .sasMismatch: return String(localized: "The codes did not match; start a fresh transfer.")
        case .transferAborted: return String(localized: "This transfer was aborted; start a fresh transfer.")
        case .sasNotConfirmed: return String(localized: "Confirm the code before continuing.")
        case .originAuthorizationRequired: return String(localized: "Origin authorization is required.")
        case .originAuthorizationAlreadyDecided: return String(localized: "Origin authorization has already been decided.")
        case .originAuthorizationDenied: return String(localized: "The origin denied this transfer.")
        case .originOnlyOperation: return String(localized: "Only the origin may perform this operation.")
        case .recipientOnlyOperation: return String(localized: "Only the recipient may perform this operation.")
        case .authorizationProofRequired: return String(localized: "Authorization proof must precede the manifest.")
        case .authorizationProofAlreadySent: return String(localized: "Authorization proof has already been sent.")
        case .recipientPublicKeyRequired: return String(localized: "The recipient public key is required.")
        case .recipientPublicKeyAlreadySent: return String(localized: "The recipient public key was already transferred.")
        case .manifestAlreadyTransferred: return String(localized: "The manifest was already transferred.")
        case .importAcceptanceRequired:
            return String(localized: "The recipient must acknowledge imported hosts before key grants begin.")
        case .importAcceptanceAlreadyTransferred:
            return String(localized: "The manifest import acknowledgement was already transferred.")
        case .invalidImportAcceptance:
            return String(localized: "The manifest import acknowledgement is invalid.")
        case .grantReceiptRequired: return String(localized: "The grant receipt must follow the manifest.")
        case .grantReceiptAlreadyTransferred: return String(localized: "The grant receipt was already transferred.")
        case .completionAcknowledgementRequired:
            return String(localized: "The completion acknowledgement must follow the grant receipt.")
        case .completionAcknowledgementAlreadyTransferred:
            return String(localized: "The completion acknowledgement was already transferred.")
        case .invalidGrantReceipt: return String(localized: "The host-grant receipt is invalid.")
        case .unexpectedMessage: return String(localized: "Unexpected encrypted message.")
        case .invalidFrame: return String(localized: "Invalid encrypted frame.")
        case .wrongDirection: return String(localized: "Encrypted frame has the wrong direction.")
        case .outOfOrder(let expected, let actual):
            return String(localized: "Expected frame \(expected), got \(actual).")
        case .sequenceExhausted: return String(localized: "Encrypted-channel sequence is exhausted.")
        case .authenticationFailed: return String(localized: "Encrypted-frame authentication failed.")
        }
    }
}
