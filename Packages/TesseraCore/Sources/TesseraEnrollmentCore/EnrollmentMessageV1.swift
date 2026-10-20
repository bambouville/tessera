import Foundation

public struct EnrollmentRequestV1: Codable, Equatable, Sendable {
    public let id: UUID
    public let hostID: UUID
    public let hostName: String
    /// Display-only. Authorization comes from PeerBinding.
    public let requestingDeviceName: String
    public let publicKey: EnrollmentPublicKeyV1

    public init(
        id: UUID = UUID(),
        hostID: UUID,
        hostName: String,
        requestingDeviceName: String,
        publicKey: EnrollmentPublicKeyV1
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.requestingDeviceName = requestingDeviceName
        self.publicKey = publicKey
    }

    public func validate() throws {
        guard !hostName.isEmpty else { throw EnrollmentRequestValidationError.emptyHostName }
        guard !requestingDeviceName.isEmpty else {
            throw EnrollmentRequestValidationError.emptyDeviceName
        }
        guard hostName.count <= EnrollmentDisplayMetadata.maximumLength,
              requestingDeviceName.count <= EnrollmentDisplayMetadata.maximumLength else {
            throw EnrollmentRequestValidationError.displayNameTooLong
        }
        guard EnrollmentDisplayMetadata.isSafe(hostName),
              EnrollmentDisplayMetadata.isSafe(requestingDeviceName) else {
            throw EnrollmentRequestValidationError.unsafeDisplayMetadata
        }
        try publicKey.validate()
    }
}

public enum EnrollmentRequestValidationError: Error, Equatable, Sendable {
    case emptyHostName
    case emptyDeviceName
    case displayNameTooLong
    case unsafeDisplayMetadata
}

public enum EnrollmentRemoteFailureV1: String, Codable, Equatable, Sendable {
    case authorizationFailed
    case installationFailed
    case persistenceFailed
    case protocolViolation
}

/// Shipped enrollment-v1 message allowlist. Coding keys, values, and request /
/// install / record / complete ordering are frozen.
public enum EnrollmentMessageV1: Equatable, Sendable {
    public static let currentVersion = 1

    case request(EnrollmentRequestV1)
    case installed(enrollmentID: UUID)
    case recorded(enrollmentID: UUID)
    case completed(enrollmentID: UUID)
    case rejected(enrollmentID: UUID)
    case cancelled(enrollmentID: UUID)
    case failed(enrollmentID: UUID, failure: EnrollmentRemoteFailureV1)

    public var enrollmentID: UUID {
        switch self {
        case .request(let request): return request.id
        case .installed(let id), .recorded(let id), .completed(let id),
             .rejected(let id), .cancelled(let id), .failed(let id, _):
            return id
        }
    }
}

extension EnrollmentMessageV1: Codable {
    public enum CodingError: Error, Equatable, Sendable {
        case unsupportedVersion(Int)
        case missingRequest
        case unexpectedRequest
        case missingFailure
        case unexpectedFailure
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

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw CodingError.unsupportedVersion(version)
        }
        let kind = try values.decode(Kind.self, forKey: .kind)
        let request = try values.decodeIfPresent(EnrollmentRequestV1.self, forKey: .request)
        let failure = try values.decodeIfPresent(EnrollmentRemoteFailureV1.self, forKey: .failure)

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
            default: preconditionFailure("exhaustive enrollment kind")
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

    public func encode(to encoder: Encoder) throws {
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

public enum EnrollmentFrameCodecV1 {
    public static let maximumPayloadBytes = 64 * 1024
    public static let headerBytes = 4

    public static func encode(_ message: EnrollmentMessageV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(message)
        guard !payload.isEmpty else { throw EnrollmentFrameError.emptyPayload }
        guard payload.count <= maximumPayloadBytes else {
            throw EnrollmentFrameError.payloadTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: headerBytes)
        frame.append(payload)
        return frame
    }
}

public enum EnrollmentFrameError: Error, Equatable, Sendable {
    case emptyPayload
    case payloadTooLarge(Int)
    case invalidPayload
}

public struct EnrollmentFrameDecoderV1: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [EnrollmentMessageV1] {
        buffer.append(bytes)
        var messages: [EnrollmentMessageV1] = []
        while buffer.count >= EnrollmentFrameCodecV1.headerBytes {
            let length = buffer.prefix(EnrollmentFrameCodecV1.headerBytes).reduce(0) {
                ($0 << 8) | Int($1)
            }
            guard length > 0 else { throw EnrollmentFrameError.emptyPayload }
            guard length <= EnrollmentFrameCodecV1.maximumPayloadBytes else {
                throw EnrollmentFrameError.payloadTooLarge(length)
            }
            let frameBytes = EnrollmentFrameCodecV1.headerBytes + length
            guard buffer.count >= frameBytes else { break }
            let payload = buffer.subdata(in: EnrollmentFrameCodecV1.headerBytes..<frameBytes)
            do {
                messages.append(try JSONDecoder().decode(EnrollmentMessageV1.self, from: payload))
            } catch let error as EnrollmentMessageV1.CodingError {
                throw error
            } catch let error as DevicePublicKeyValidationError {
                throw error
            } catch let error as EnrollmentRequestValidationError {
                throw error
            } catch {
                throw EnrollmentFrameError.invalidPayload
            }
            buffer.removeSubrange(0..<frameBytes)
        }
        return messages
    }
}
