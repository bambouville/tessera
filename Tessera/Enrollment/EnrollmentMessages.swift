import Foundation
import TesseraEnrollmentCore

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
                return String(localized: "Enrollment public-key name is empty.")
            case .displayNameTooLong:
                return String(localized: "Enrollment public-key name is too long.")
            case .invalidBlob:
                return String(localized: "Enrollment public-key blob is not canonical base64.")
            case .blobTooLarge:
                return String(localized: "Enrollment public-key blob exceeds the protocol limit.")
            case .algorithmMismatch:
                return String(localized: "Enrollment public-key blob does not match its declared algorithm.")
            case .protectionMismatch:
                return String(localized: "Enrollment public-key protection metadata is impossible for its algorithm.")
            case .invalidFingerprint:
                return String(localized: "Enrollment public-key fingerprint is invalid.")
            case .fingerprintMismatch:
                return String(localized: "Enrollment public-key fingerprint does not match its blob.")
            case .unsafeDisplayName:
                return String(localized: "Enrollment public-key name contains unsafe display characters.")
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

    init(
        id: UUID,
        displayName: String,
        algorithm: EnrollmentPublicKeyAlgorithm,
        blob: String,
        fingerprint: String,
        protection: EnrollmentPublicKeyProtection
    ) {
        self.id = id
        self.displayName = displayName
        self.algorithm = algorithm
        self.blob = blob
        self.fingerprint = fingerprint
        self.protection = protection
    }

    var authorizedKeysLine: String {
        "\(algorithm.rawValue) \(blob)"
    }

    var core: EnrollmentPublicKeyV1 {
        EnrollmentPublicKeyV1(
            id: id,
            displayName: displayName,
            algorithm: algorithm == .ed25519 ? .ed25519 : .ecdsaNistP256,
            blob: blob,
            fingerprint: fingerprint,
            protection: protection == .secureEnclave ? .secureEnclave : .software
        )
    }

    init(core: EnrollmentPublicKeyV1) {
        id = core.id
        displayName = core.displayName
        algorithm = core.algorithm == .ed25519 ? .ed25519 : .secureEnclaveP256
        blob = core.blob
        fingerprint = core.fingerprint
        protection = core.protection == .secureEnclave ? .secureEnclave : .software
    }

    func validate() throws {
        do {
            try core.validate()
        } catch let error as DevicePublicKeyValidationError {
            throw ValidationError(core: error)
        }
    }

    static func fingerprint(forSSHBlob blob: Data) -> String {
        DevicePublicKeyValidator.fingerprint(forSSHBlob: blob)
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
                return String(localized: "Enrollment host name is empty.")
            case .emptyDeviceName:
                return String(localized: "Enrollment device name is empty.")
            case .displayNameTooLong:
                return String(localized: "Enrollment display metadata is too long.")
            case .unsafeDisplayMetadata:
                return String(localized: "Enrollment display metadata contains unsafe characters.")
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

    var core: EnrollmentRequestV1 {
        EnrollmentRequestV1(
            id: id,
            hostID: hostID,
            hostName: hostName,
            requestingDeviceName: requestingDeviceName,
            publicKey: publicKey.core
        )
    }

    init(core: EnrollmentRequestV1) {
        id = core.id
        hostID = core.hostID
        hostName = core.hostName
        requestingDeviceName = core.requestingDeviceName
        publicKey = EnrollmentPublicKey(core: core.publicKey)
    }

    func validate() throws {
        do {
            try core.validate()
        } catch let error as EnrollmentRequestValidationError {
            throw ValidationError(core: error)
        } catch let error as DevicePublicKeyValidationError {
            throw EnrollmentPublicKey.ValidationError(core: error)
        }
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

    var core: EnrollmentMessageV1 {
        switch self {
        case .request(let request): .request(request.core)
        case .installed(let id): .installed(enrollmentID: id)
        case .recorded(let id): .recorded(enrollmentID: id)
        case .completed(let id): .completed(enrollmentID: id)
        case .rejected(let id): .rejected(enrollmentID: id)
        case .cancelled(let id): .cancelled(enrollmentID: id)
        case .failed(let id, let failure):
            .failed(
                enrollmentID: id,
                failure: EnrollmentRemoteFailureV1(rawValue: failure.rawValue)!
            )
        }
    }

    init(core: EnrollmentMessageV1) {
        switch core {
        case .request(let request): self = .request(EnrollmentRequest(core: request))
        case .installed(let id): self = .installed(enrollmentID: id)
        case .recorded(let id): self = .recorded(enrollmentID: id)
        case .completed(let id): self = .completed(enrollmentID: id)
        case .rejected(let id): self = .rejected(enrollmentID: id)
        case .cancelled(let id): self = .cancelled(enrollmentID: id)
        case .failed(let id, let failure):
            self = .failed(
                enrollmentID: id,
                failure: EnrollmentRemoteFailure(rawValue: failure.rawValue)!
            )
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
                return String(localized: "Unsupported enrollment message version \(version).")
            case .missingRequest:
                return String(localized: "Enrollment request payload is missing.")
            case .unexpectedRequest:
                return String(localized: "Enrollment control message contains a request payload.")
            case .missingFailure:
                return String(localized: "Enrollment failure code is missing.")
            case .unexpectedFailure:
                return String(localized: "Enrollment non-failure message contains a failure code.")
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
        do {
            self.init(core: try EnrollmentMessageV1(from: decoder))
        } catch let error as EnrollmentMessageV1.CodingError {
            throw CodingError(core: error)
        } catch let error as DevicePublicKeyValidationError {
            throw EnrollmentPublicKey.ValidationError(core: error)
        } catch let error as EnrollmentRequestValidationError {
            throw EnrollmentRequest.ValidationError(core: error)
        }
    }

    func encode(to encoder: Encoder) throws {
        do {
            try core.encode(to: encoder)
        } catch let error as DevicePublicKeyValidationError {
            throw EnrollmentPublicKey.ValidationError(core: error)
        } catch let error as EnrollmentRequestValidationError {
            throw EnrollmentRequest.ValidationError(core: error)
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
                return String(localized: "Enrollment frame payload is empty.")
            case .payloadTooLarge(let count):
                return String(localized: "Enrollment frame payload is too large (\(count) bytes).")
            case .invalidPayload:
                return String(localized: "Enrollment frame payload is invalid.")
            }
        }
    }

    static func encode(_ message: EnrollmentMessage) throws -> Data {
        do {
            return try EnrollmentFrameCodecV1.encode(message.core)
        } catch let error as EnrollmentFrameError {
            throw FrameError(core: error)
        } catch let error as DevicePublicKeyValidationError {
            throw EnrollmentPublicKey.ValidationError(core: error)
        } catch let error as EnrollmentRequestValidationError {
            throw EnrollmentRequest.ValidationError(core: error)
        }
    }
}

/// Incremental decoder for continuation streams, where reads may split a
/// length prefix or coalesce multiple enrollment frames.
struct EnrollmentFrameDecoder: Sendable {
    private var core = EnrollmentFrameDecoderV1()

    mutating func append(_ bytes: Data) throws -> [EnrollmentMessage] {
        do {
            return try core.append(bytes).map(EnrollmentMessage.init(core:))
        } catch let error as EnrollmentFrameError {
            throw EnrollmentFrameCodec.FrameError(core: error)
        } catch let error as EnrollmentMessageV1.CodingError {
            throw EnrollmentMessage.CodingError(core: error)
        } catch let error as DevicePublicKeyValidationError {
            throw EnrollmentPublicKey.ValidationError(core: error)
        } catch let error as EnrollmentRequestValidationError {
            throw EnrollmentRequest.ValidationError(core: error)
        }
    }
}

private extension EnrollmentPublicKey.ValidationError {
    init(core: DevicePublicKeyValidationError) {
        self = switch core {
        case .emptyDisplayName: .emptyDisplayName
        case .displayNameTooLong: .displayNameTooLong
        case .unsafeDisplayName: .unsafeDisplayName
        case .invalidBlob: .invalidBlob
        case .blobTooLarge: .blobTooLarge
        case .algorithmMismatch: .algorithmMismatch
        case .protectionMismatch: .protectionMismatch
        case .invalidFingerprint: .invalidFingerprint
        case .fingerprintMismatch: .fingerprintMismatch
        }
    }
}

private extension EnrollmentRequest.ValidationError {
    init(core: EnrollmentRequestValidationError) {
        self = switch core {
        case .emptyHostName: .emptyHostName
        case .emptyDeviceName: .emptyDeviceName
        case .displayNameTooLong: .displayNameTooLong
        case .unsafeDisplayMetadata: .unsafeDisplayMetadata
        }
    }
}

private extension EnrollmentMessage.CodingError {
    init(core: EnrollmentMessageV1.CodingError) {
        self = switch core {
        case .unsupportedVersion(let version): .unsupportedVersion(version)
        case .missingRequest: .missingRequest
        case .unexpectedRequest: .unexpectedRequest
        case .missingFailure: .missingFailure
        case .unexpectedFailure: .unexpectedFailure
        }
    }
}

private extension EnrollmentFrameCodec.FrameError {
    init(core: EnrollmentFrameError) {
        self = switch core {
        case .emptyPayload: .emptyPayload
        case .payloadTooLarge(let count): .payloadTooLarge(count)
        case .invalidPayload: .invalidPayload
        }
    }
}
