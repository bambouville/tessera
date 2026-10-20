import Foundation

/// Frozen compatibility epoch used by released Apple builds. New pairing is a
/// separate protocol and must never widen this version set in place.
public enum LegacyNearbyBootstrapV2 {
    public static let version = 2
    public static let supportedVersions = [2]
    /// Released cleartext hello and commitment records share this 4 KiB cap.
    /// The aliases make each decoder's local obligation explicit while the
    /// compatibility spelling remains available to Apple transport adapters.
    public static let maximumHelloMessageSize = 4_096
    public static let maximumCommitmentMessageSize = 4_096
    public static let maximumHandshakeMessageSize = maximumHelloMessageSize
    /// Complete TBCH frame bytes, including its header, nonce, and tag.
    public static let maximumEncryptedFrameSize = 65_536
    public static let serviceType = "_tessera-bootstrap._tcp"

}

public enum LegacyNearbyHandshakeRoleV2: String, Codable, CaseIterable, Sendable {
    case origin
    case recipient

    public var peer: Self {
        switch self {
        case .origin: return .recipient
        case .recipient: return .origin
        }
    }
}

/// Sanitized, advisory-only description of the peer's version claims. These
/// values are cleartext and therefore never become a trust input.
public struct LegacyNearbyPeerVersionInfoV2: Equatable, Sendable {
    public let version: Int
    public let appVersion: String?
    public let supportedVersions: [Int]?

    public init(
        version: Int,
        appVersion: String?,
        supportedVersions: [Int]?
    ) {
        self.version = version
        let cleaned = appVersion.map(Self.sanitizedAppVersion)
        self.appVersion = (cleaned?.isEmpty ?? true) ? nil : cleaned
        self.supportedVersions = supportedVersions.map { Array($0.prefix(8)) }
    }

    private static let allowedAppVersionScalars = CharacterSet(
        charactersIn: "0123456789abcdefghijklmnopqrstuvwxyz"
            + "ABCDEFGHIJKLMNOPQRSTUVWXYZ.+-"
    )

    private static func sanitizedAppVersion(_ rawValue: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in rawValue.unicodeScalars
        where allowedAppVersionScalars.contains(scalar) {
            scalars.append(scalar)
            if scalars.count == 32 { break }
        }
        return String(scalars)
    }
}

public enum LegacyNearbyVersionedMessageKindV2: String, Equatable, Sendable {
    case commitment
    case hello
}

/// Version-first probe used before strict decoding. `nil` means the payload is
/// not a JSON object carrying an integer `version`.
public enum LegacyNearbyVersionProbeV2 {
    public static func probe(_ data: Data) -> LegacyNearbyPeerVersionInfoV2? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawVersion = object["version"],
              let number = rawVersion as? NSNumber,
              !isBoolean(number),
              let version = rawVersion as? Int
        else { return nil }
        let appVersion = object["appVersion"] as? String
        let supported = (object["supportedVersions"] as? [Any])?.compactMap { $0 as? Int }
        return LegacyNearbyPeerVersionInfoV2(
            version: version,
            appVersion: appVersion,
            supportedVersions: supported
        )
    }

    /// Foundation bridges JSON booleans and numbers through `NSNumber`.
    /// Swift's conditional casts can therefore treat the numeric value `1`
    /// as `Bool`, even though it was an integer on the wire. The Objective-C
    /// type encoding keeps those two JSON token kinds distinct on Darwin and
    /// swift-corelibs-foundation without importing CoreFoundation.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        switch String(cString: number.objCType) {
        case "B", "c": true
        default: false
        }
    }
}

public enum BootstrapManifestProtocol {
    public static let currentVersion = 2
}
