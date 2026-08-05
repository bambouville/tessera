import Foundation
import CryptoKit

/// Public-key algorithms the enrollment wire protocol can authorize. Keeping
/// this closed prevents an arbitrary authorized_keys line from crossing the
/// continuation stream disguised as key metadata.
enum EnrollmentPublicKeyAlgorithm: String, Codable, CaseIterable, Sendable {
    case ed25519 = "ssh-ed25519"
    case secureEnclaveP256 = "ecdsa-sha2-nistp256"
}

enum EnrollmentPublicKeyProtection: String, Codable, Sendable {
    case secureEnclave
    case software
}

/// Display metadata is deliberately not a trust input, but it still appears in
/// the biometric consent UI. Reject leading/trailing whitespace, control
/// characters, and bidirectional-formatting controls so a peer cannot make one
/// host/device label visually impersonate another.
enum EnrollmentDisplayMetadata {
    static let forbiddenBidiScalars: Set<UInt32> = [
        0x061C, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]

    static func isSafe(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
                && !forbiddenBidiScalars.contains(scalar.value)
        }
    }
}

/// The only key-shaped value enrollment can express. It contains the public
/// SSH blob and display/audit metadata; there is intentionally no initializer
/// accepting StoredKey, KeyStore, private bytes, a Keychain handle, or a
/// Secure Enclave key reference.
struct EnrollmentPublicKey: Codable, Equatable, Sendable {
    static let maximumBlobBytes = 16 * 1024
    static let maximumDisplayNameLength = 128

    enum ValidationError: Error, Equatable, LocalizedError {
        case emptyDisplayName
        case displayNameTooLong
        case invalidBlob
        case blobTooLarge
        case algorithmMismatch
        case protectionMismatch
        case invalidFingerprint
        case fingerprintMismatch
        case unsafeDisplayName

        var errorDescription: String? {
            switch self {
            case .emptyDisplayName:
                return "Enrollment public-key name is empty."
            case .displayNameTooLong:
                return "Enrollment public-key name is too long."
            case .invalidBlob:
                return "Enrollment public-key blob is not canonical base64."
            case .blobTooLarge:
                return "Enrollment public-key blob exceeds the protocol limit."
            case .algorithmMismatch:
                return "Enrollment public-key blob does not match its declared algorithm."
            case .protectionMismatch:
                return "Enrollment public-key protection metadata is impossible for its algorithm."
            case .invalidFingerprint:
                return "Enrollment public-key fingerprint is invalid."
            case .fingerprintMismatch:
                return "Enrollment public-key fingerprint does not match its blob."
            case .unsafeDisplayName:
                return "Enrollment public-key name contains unsafe display characters."
            }
        }
    }

    let id: UUID
    let displayName: String
    let algorithm: EnrollmentPublicKeyAlgorithm
    /// Base64 SSH wire blob only, without an algorithm prefix or comment.
    let blob: String
    let fingerprint: String
    let protection: EnrollmentPublicKeyProtection

    var authorizedKeysLine: String {
        "\(algorithm.rawValue) \(blob)"
    }

    func validate() throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ValidationError.emptyDisplayName }
        guard name.count <= Self.maximumDisplayNameLength else {
            throw ValidationError.displayNameTooLong
        }
        guard EnrollmentDisplayMetadata.isSafe(displayName) else {
            throw ValidationError.unsafeDisplayName
        }
        guard !blob.isEmpty,
              blob.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let decoded = Data(base64Encoded: blob),
              decoded.base64EncodedString() == blob
        else { throw ValidationError.invalidBlob }
        guard decoded.count <= Self.maximumBlobBytes else {
            throw ValidationError.blobTooLarge
        }
        guard Self.sshBlobAlgorithm(decoded) == algorithm.rawValue else {
            throw ValidationError.algorithmMismatch
        }
        guard Self.isStructurallyValidSSHBlob(decoded, algorithm: algorithm) else {
            throw ValidationError.invalidBlob
        }
        guard protection != .secureEnclave || algorithm == .secureEnclaveP256 else {
            throw ValidationError.protectionMismatch
        }
        guard fingerprint.hasPrefix("SHA256:"),
              fingerprint.count > "SHA256:".count,
              fingerprint.count <= 160,
              fingerprint.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw ValidationError.invalidFingerprint }
        guard fingerprint == Self.fingerprint(forSSHBlob: decoded) else {
            throw ValidationError.fingerprintMismatch
        }
    }

    static func fingerprint(forSSHBlob blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob))
        return "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private static func sshBlobAlgorithm(_ blob: Data) -> String? {
        var cursor = SSHBlobCursor(data: blob)
        guard let name = cursor.readString(maximumLength: 128) else { return nil }
        return String(data: name, encoding: .utf8)
    }

    private static func isStructurallyValidSSHBlob(
        _ blob: Data,
        algorithm: EnrollmentPublicKeyAlgorithm
    ) -> Bool {
        var cursor = SSHBlobCursor(data: blob)
        guard let declared = cursor.readString(maximumLength: 128),
              String(data: declared, encoding: .utf8) == algorithm.rawValue
        else { return false }

        switch algorithm {
        case .ed25519:
            guard let key = cursor.readString(maximumLength: 32),
                  key.count == 32
            else { return false }
        case .secureEnclaveP256:
            guard let curve = cursor.readString(maximumLength: 16),
                  String(data: curve, encoding: .utf8) == "nistp256",
                  let point = cursor.readString(maximumLength: 65),
                  point.count == 65,
                  point.first == 0x04
            else { return false }
        }
        return cursor.isAtEnd
    }

    private struct SSHBlobCursor {
        let data: Data
        var offset = 0

        var isAtEnd: Bool { offset == data.count }

        mutating func readString(maximumLength: Int) -> Data? {
            guard offset <= data.count - 4 else { return nil }
            let lengthRange = offset..<(offset + 4)
            let length = data[lengthRange].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length >= 0,
                  length <= maximumLength,
                  offset <= data.count - length
            else { return nil }
            defer { offset += length }
            return data.subdata(in: offset..<(offset + length))
        }
    }
}

struct EnrollmentRequest: Codable, Equatable, Sendable {
    static let maximumDisplayNameLength = 128

    enum ValidationError: Error, Equatable, LocalizedError {
        case emptyHostName
        case emptyDeviceName
        case displayNameTooLong
        case unsafeDisplayMetadata

        var errorDescription: String? {
            switch self {
            case .emptyHostName:
                return "Enrollment host name is empty."
            case .emptyDeviceName:
                return "Enrollment device name is empty."
            case .displayNameTooLong:
                return "Enrollment display metadata is too long."
            case .unsafeDisplayMetadata:
                return "Enrollment display metadata contains unsafe characters."
            }
        }
    }

    let id: UUID
    let hostID: UUID
    let hostName: String
    /// Display-only. Peer authentication comes from the transport binding.
    let requestingDeviceName: String
    let publicKey: EnrollmentPublicKey

    init(
        id: UUID = UUID(),
        hostID: UUID,
        hostName: String,
        requestingDeviceName: String,
        publicKey: EnrollmentPublicKey
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.requestingDeviceName = requestingDeviceName
        self.publicKey = publicKey
    }

    func validate() throws {
        let host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = requestingDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw ValidationError.emptyHostName }
        guard !device.isEmpty else { throw ValidationError.emptyDeviceName }
        guard host.count <= Self.maximumDisplayNameLength,
              device.count <= Self.maximumDisplayNameLength
        else { throw ValidationError.displayNameTooLong }
        guard EnrollmentDisplayMetadata.isSafe(hostName),
              EnrollmentDisplayMetadata.isSafe(requestingDeviceName)
        else { throw ValidationError.unsafeDisplayMetadata }
        try publicKey.validate()
    }
}

/// Output of the biometric approval boundary. This is deliberately a public
/// key line plus routing/display metadata: enough for an installer adapter,
/// with no local private-key or credential-storage type in the API.
struct EnrollmentGrantRequest: Equatable, Sendable {
    let enrollmentID: UUID
    let hostID: UUID
    let hostName: String
    let requestingDeviceName: String
    let publicKey: EnrollmentPublicKey
    /// Opaque local capability minted by the shared grant engine. It is never
    /// encoded or sent to the peer and carries no key material.
    let accessAuthorization: SyncDeviceAccessGrantEngine.Authorization?

    var authorizedKeysLine: String { publicKey.authorizedKeysLine }

    init(request: EnrollmentRequest) {
        self.init(request: request, accessAuthorization: nil)
    }

    init(
        request: EnrollmentRequest,
        accessAuthorization: SyncDeviceAccessGrantEngine.Authorization?
    ) {
        enrollmentID = request.id
        hostID = request.hostID
        hostName = request.hostName
        requestingDeviceName = request.requestingDeviceName
        publicKey = request.publicKey
        self.accessAuthorization = accessAuthorization
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enrollmentID == rhs.enrollmentID
            && lhs.hostID == rhs.hostID
            && lhs.hostName == rhs.hostName
            && lhs.requestingDeviceName == rhs.requestingDeviceName
            && lhs.publicKey == rhs.publicKey
    }
}

enum EnrollmentRemoteFailure: String, Codable, Equatable, Sendable {
    case authorizationFailed
    case installationFailed
    case persistenceFailed
    case protocolViolation
}

/// One versioned enrollment message. The enum is an explicit allowlist: there
/// is no dictionary/extra payload where a private key could be added silently.
enum EnrollmentMessage: Equatable, Sendable {
    static let currentVersion = 1

    case request(EnrollmentRequest)
    /// The origin verified the remote authorized_keys mutation. The requester
    /// must durably save its local identity + ledger before acknowledging it.
    case installed(enrollmentID: UUID)
    /// The requester durably recorded the install. The origin does not enter a
    /// completed state until this acknowledgement arrives.
    case recorded(enrollmentID: UUID)
    /// Final origin receipt. Only after this arrives may the requester expose
    /// its completion callback and start a connection with the new key.
    case completed(enrollmentID: UUID)
    case rejected(enrollmentID: UUID)
    case cancelled(enrollmentID: UUID)
    case failed(enrollmentID: UUID, failure: EnrollmentRemoteFailure)

    var enrollmentID: UUID {
        switch self {
        case .request(let request): return request.id
        case .installed(let id), .recorded(let id), .completed(let id),
             .rejected(let id), .cancelled(let id),
             .failed(let id, _): return id
        }
    }
}

extension EnrollmentMessage: Codable {
    enum CodingError: Error, Equatable, LocalizedError {
        case unsupportedVersion(Int)
        case missingRequest
        case unexpectedRequest
        case missingFailure
        case unexpectedFailure

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "Unsupported enrollment message version \(version)."
            case .missingRequest:
                return "Enrollment request payload is missing."
            case .unexpectedRequest:
                return "Enrollment control message contains a request payload."
            case .missingFailure:
                return "Enrollment failure code is missing."
            case .unexpectedFailure:
                return "Enrollment non-failure message contains a failure code."
            }
        }
    }

    private enum Kind: String, Codable {
        case request
        case installed
        case recorded
        case completed
        case rejected
        case cancelled
        case failed
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind = "type"
        case enrollmentID
        case request
        case failure
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw CodingError.unsupportedVersion(version)
        }
        let kind = try values.decode(Kind.self, forKey: .kind)
        let request = try values.decodeIfPresent(EnrollmentRequest.self, forKey: .request)
        let failure = try values.decodeIfPresent(EnrollmentRemoteFailure.self, forKey: .failure)

        switch kind {
        case .request:
            guard let request else { throw CodingError.missingRequest }
            guard failure == nil else { throw CodingError.unexpectedFailure }
            try request.validate()
            self = .request(request)
        case .installed, .recorded, .completed, .rejected, .cancelled:
            guard request == nil else { throw CodingError.unexpectedRequest }
            guard failure == nil else { throw CodingError.unexpectedFailure }
            let id = try values.decode(UUID.self, forKey: .enrollmentID)
            switch kind {
            case .installed: self = .installed(enrollmentID: id)
            case .recorded: self = .recorded(enrollmentID: id)
            case .completed: self = .completed(enrollmentID: id)
            case .rejected: self = .rejected(enrollmentID: id)
            case .cancelled: self = .cancelled(enrollmentID: id)
            default: fatalError("exhaustive kind switch")
            }
        case .failed:
            guard request == nil else { throw CodingError.unexpectedRequest }
            guard let failure else { throw CodingError.missingFailure }
            self = .failed(
                enrollmentID: try values.decode(UUID.self, forKey: .enrollmentID),
                failure: failure
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentVersion, forKey: .version)
        switch self {
        case .request(let request):
            try request.validate()
            try values.encode(Kind.request, forKey: .kind)
            try values.encode(request, forKey: .request)
        case .installed(let id):
            try values.encode(Kind.installed, forKey: .kind)
            try values.encode(id, forKey: .enrollmentID)
        case .recorded(let id):
            try values.encode(Kind.recorded, forKey: .kind)
            try values.encode(id, forKey: .enrollmentID)
        case .completed(let id):
            try values.encode(Kind.completed, forKey: .kind)
            try values.encode(id, forKey: .enrollmentID)
        case .rejected(let id):
            try values.encode(Kind.rejected, forKey: .kind)
            try values.encode(id, forKey: .enrollmentID)
        case .cancelled(let id):
            try values.encode(Kind.cancelled, forKey: .kind)
            try values.encode(id, forKey: .enrollmentID)
        case .failed(let id, let failure):
            try values.encode(Kind.failed, forKey: .kind)
            try values.encode(id, forKey: .enrollmentID)
            try values.encode(failure, forKey: .failure)
        }
    }
}

enum EnrollmentFrameCodec {
    static let maximumPayloadBytes = 64 * 1024
    static let headerBytes = 4

    enum FrameError: Error, Equatable, LocalizedError {
        case emptyPayload
        case payloadTooLarge(Int)
        case invalidPayload

        var errorDescription: String? {
            switch self {
            case .emptyPayload:
                return "Enrollment frame payload is empty."
            case .payloadTooLarge(let count):
                return "Enrollment frame payload is too large (\(count) bytes)."
            case .invalidPayload:
                return "Enrollment frame payload is invalid."
            }
        }
    }

    static func encode(_ message: EnrollmentMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(message)
        guard !payload.isEmpty else { throw FrameError.emptyPayload }
        guard payload.count <= maximumPayloadBytes else {
            throw FrameError.payloadTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: headerBytes)
        frame.append(payload)
        return frame
    }
}

/// Incremental decoder for continuation streams, where reads may split a
/// length prefix or coalesce multiple enrollment frames.
struct EnrollmentFrameDecoder: Sendable {
    private var buffer = Data()

    mutating func append(_ bytes: Data) throws -> [EnrollmentMessage] {
        buffer.append(bytes)
        var messages: [EnrollmentMessage] = []

        while buffer.count >= EnrollmentFrameCodec.headerBytes {
            let length = buffer.prefix(EnrollmentFrameCodec.headerBytes).reduce(0) {
                ($0 << 8) | Int($1)
            }
            guard length > 0 else { throw EnrollmentFrameCodec.FrameError.emptyPayload }
            guard length <= EnrollmentFrameCodec.maximumPayloadBytes else {
                throw EnrollmentFrameCodec.FrameError.payloadTooLarge(length)
            }
            let frameBytes = EnrollmentFrameCodec.headerBytes + length
            guard buffer.count >= frameBytes else { break }

            let payload = buffer.subdata(
                in: EnrollmentFrameCodec.headerBytes..<frameBytes
            )
            do {
                messages.append(try JSONDecoder().decode(EnrollmentMessage.self, from: payload))
            } catch let error as EnrollmentMessage.CodingError {
                throw error
            } catch let error as EnrollmentPublicKey.ValidationError {
                throw error
            } catch let error as EnrollmentRequest.ValidationError {
                throw error
            } catch {
                throw EnrollmentFrameCodec.FrameError.invalidPayload
            }
            buffer.removeSubrange(0..<frameBytes)
        }

        return messages
    }
}
