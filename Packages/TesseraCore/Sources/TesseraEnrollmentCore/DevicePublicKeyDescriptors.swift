import Crypto
import Foundation

/// SSH algorithms accepted by enrollment. The source-level P-256 name is
/// platform neutral while its raw value remains byte-compatible with v1.
public enum DevicePublicKeyAlgorithm: String, Codable, CaseIterable, Sendable {
    case ed25519 = "ssh-ed25519"
    case ecdsaNistP256 = "ecdsa-sha2-nistp256"
}

/// Shipped v1 protection metadata. These raw values are frozen for legacy
/// Apple peers and must not be used as an authorization signal.
public enum EnrollmentPublicKeyProtectionV1: String, Codable, CaseIterable, Sendable {
    case secureEnclave
    case software
}

/// Platform-neutral, display-only protection claim for new peers.
public enum DevicePublicKeyProtectionClaim: String, Codable, CaseIterable, Sendable {
    case softwareExportable
    case platformProtected
    case platformHardwareBacked
    case platformStrongHardware
    case unknown
}

public enum DevicePublicKeyValidationError: Error, Equatable, Sendable {
    case emptyDisplayName
    case displayNameTooLong
    case unsafeDisplayName
    case invalidBlob
    case blobTooLarge
    case algorithmMismatch
    case protectionMismatch
    case invalidFingerprint
    case fingerprintMismatch
}

public enum EnrollmentDisplayMetadata {
    public static let maximumLength = 128

    private static let forbiddenBidiScalars: Set<UInt32> = [
        0x061C, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]

    public static func isSafe(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count <= maximumLength else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
                && !forbiddenBidiScalars.contains(scalar.value)
        }
    }
}

/// Byte-compatible public-key schema used by EnrollmentMessage v1.
public struct EnrollmentPublicKeyV1: Codable, Equatable, Sendable {
    public static let maximumBlobBytes = 16 * 1024

    public let id: UUID
    public let displayName: String
    public let algorithm: DevicePublicKeyAlgorithm
    /// Canonical base64 SSH wire blob, without an algorithm prefix or comment.
    public let blob: String
    public let fingerprint: String
    public let protection: EnrollmentPublicKeyProtectionV1

    public init(
        id: UUID,
        displayName: String,
        algorithm: DevicePublicKeyAlgorithm,
        blob: String,
        fingerprint: String,
        protection: EnrollmentPublicKeyProtectionV1
    ) {
        self.id = id
        self.displayName = displayName
        self.algorithm = algorithm
        self.blob = blob
        self.fingerprint = fingerprint
        self.protection = protection
    }

    public var sshBlob: String { blob }
    public var authorizedKeysLine: String { "\(algorithm.rawValue) \(blob)" }

    public func validate() throws {
        try DevicePublicKeyValidator.validate(
            displayName: displayName,
            algorithm: algorithm,
            sshBlob: blob,
            fingerprint: fingerprint
        )
        guard protection != .secureEnclave || algorithm == .ecdsaNistP256 else {
            throw DevicePublicKeyValidationError.protectionMismatch
        }
    }
}

/// Compatibility spelling used by schema inventories.
public typealias DevicePublicKeyDescriptorV1 = EnrollmentPublicKeyV1

/// Platform-neutral public-key metadata for pairing-era enrollment.
public struct DevicePublicKeyDescriptorV2: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public let id: UUID
    public let displayName: String
    public let algorithm: DevicePublicKeyAlgorithm
    public let sshBlob: String
    public let fingerprint: String
    public let protectionClaim: DevicePublicKeyProtectionClaim

    public init(
        id: UUID,
        displayName: String,
        algorithm: DevicePublicKeyAlgorithm,
        sshBlob: String,
        fingerprint: String,
        protectionClaim: DevicePublicKeyProtectionClaim
    ) {
        self.id = id
        self.displayName = displayName
        self.algorithm = algorithm
        self.sshBlob = sshBlob
        self.fingerprint = fingerprint
        self.protectionClaim = protectionClaim
    }

    public init(legacy descriptor: EnrollmentPublicKeyV1) {
        id = descriptor.id
        displayName = descriptor.displayName
        algorithm = descriptor.algorithm
        sshBlob = descriptor.blob
        fingerprint = descriptor.fingerprint
        protectionClaim = descriptor.protection == .secureEnclave
            ? .platformHardwareBacked
            : .softwareExportable
    }

    public var authorizedKeysLine: String { "\(algorithm.rawValue) \(sshBlob)" }

    public func validate() throws {
        try DevicePublicKeyValidator.validate(
            displayName: displayName,
            algorithm: algorithm,
            sshBlob: sshBlob,
            fingerprint: fingerprint
        )
    }
}

public enum DevicePublicKeyValidator {
    public static func fingerprint(forSSHBlob blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob))
        return "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    public static func validate(
        displayName: String,
        algorithm: DevicePublicKeyAlgorithm,
        sshBlob: String,
        fingerprint: String
    ) throws {
        guard !displayName.isEmpty else {
            throw DevicePublicKeyValidationError.emptyDisplayName
        }
        guard displayName.count <= EnrollmentDisplayMetadata.maximumLength else {
            throw DevicePublicKeyValidationError.displayNameTooLong
        }
        guard EnrollmentDisplayMetadata.isSafe(displayName) else {
            throw DevicePublicKeyValidationError.unsafeDisplayName
        }
        guard !sshBlob.isEmpty,
              sshBlob.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let decoded = Data(base64Encoded: sshBlob),
              decoded.base64EncodedString() == sshBlob else {
            throw DevicePublicKeyValidationError.invalidBlob
        }
        guard decoded.count <= EnrollmentPublicKeyV1.maximumBlobBytes else {
            throw DevicePublicKeyValidationError.blobTooLarge
        }
        guard sshBlobAlgorithm(decoded) == algorithm.rawValue else {
            throw DevicePublicKeyValidationError.algorithmMismatch
        }
        guard isStructurallyValid(decoded, algorithm: algorithm) else {
            throw DevicePublicKeyValidationError.invalidBlob
        }
        guard fingerprint.hasPrefix("SHA256:"),
              fingerprint.count > "SHA256:".count,
              fingerprint.count <= 160,
              fingerprint.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw DevicePublicKeyValidationError.invalidFingerprint
        }
        guard fingerprint == self.fingerprint(forSSHBlob: decoded) else {
            throw DevicePublicKeyValidationError.fingerprintMismatch
        }
    }

    private static func sshBlobAlgorithm(_ blob: Data) -> String? {
        var cursor = SSHBlobCursor(data: blob)
        guard let name = cursor.readString(maximumLength: 128) else { return nil }
        return String(data: name, encoding: .utf8)
    }

    private static func isStructurallyValid(
        _ blob: Data,
        algorithm: DevicePublicKeyAlgorithm
    ) -> Bool {
        var cursor = SSHBlobCursor(data: blob)
        guard let declared = cursor.readString(maximumLength: 128),
              String(data: declared, encoding: .utf8) == algorithm.rawValue else {
            return false
        }
        switch algorithm {
        case .ed25519:
            guard let key = cursor.readString(maximumLength: 32), key.count == 32 else {
                return false
            }
        case .ecdsaNistP256:
            guard let curve = cursor.readString(maximumLength: 16),
                  String(data: curve, encoding: .utf8) == "nistp256",
                  let point = cursor.readString(maximumLength: 65),
                  point.count == 65,
                  point.first == 0x04 else {
                return false
            }
        }
        return cursor.isAtEnd
    }

    private struct SSHBlobCursor {
        let data: Data
        var offset = 0

        var isAtEnd: Bool { offset == data.count }

        mutating func readString(maximumLength: Int) -> Data? {
            guard offset <= data.count - 4 else { return nil }
            let length = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length <= maximumLength, offset <= data.count - length else { return nil }
            defer { offset += length }
            return data.subdata(in: offset..<(offset + length))
        }
    }
}

public enum DevicePublicKeyDescriptorCodecError: Error, Equatable, Sendable {
    case payloadTooLarge(actual: Int, maximum: Int)
}

public enum DevicePublicKeyDescriptorCodecV1 {
    public static let maximumPayloadBytes = 24 * 1024

    public static func encode(_ descriptor: EnrollmentPublicKeyV1) throws -> Data {
        try descriptor.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(descriptor)
        guard data.count <= maximumPayloadBytes else {
            throw DevicePublicKeyDescriptorCodecError.payloadTooLarge(
                actual: data.count,
                maximum: maximumPayloadBytes
            )
        }
        return data
    }

    public static func decode(_ data: Data) throws -> EnrollmentPublicKeyV1 {
        guard data.count <= maximumPayloadBytes else {
            throw DevicePublicKeyDescriptorCodecError.payloadTooLarge(
                actual: data.count,
                maximum: maximumPayloadBytes
            )
        }
        let descriptor = try JSONDecoder().decode(EnrollmentPublicKeyV1.self, from: data)
        try descriptor.validate()
        return descriptor
    }
}

public enum DevicePublicKeyDescriptorCodecV2 {
    public static let maximumPayloadBytes = 24 * 1024

    public static func encode(_ descriptor: DevicePublicKeyDescriptorV2) throws -> Data {
        try descriptor.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(descriptor)
        guard data.count <= maximumPayloadBytes else {
            throw DevicePublicKeyDescriptorCodecError.payloadTooLarge(
                actual: data.count,
                maximum: maximumPayloadBytes
            )
        }
        return data
    }

    public static func decode(_ data: Data) throws -> DevicePublicKeyDescriptorV2 {
        guard data.count <= maximumPayloadBytes else {
            throw DevicePublicKeyDescriptorCodecError.payloadTooLarge(
                actual: data.count,
                maximum: maximumPayloadBytes
            )
        }
        let descriptor = try JSONDecoder().decode(DevicePublicKeyDescriptorV2.self, from: data)
        try descriptor.validate()
        return descriptor
    }
}
