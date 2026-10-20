import Foundation

public enum ContinuationWireTransport: String, Codable, CaseIterable, Sendable {
    case ssh
    case mosh
}

public enum ContinuationWireLaunchMode: String, Codable, CaseIterable, Sendable {
    case autoTmux
    case pinnedTmux
    case customCommand
}

public enum ContinuationAction: String, Codable, Equatable, Sendable {
    case continueSession
    case reconnect

    public init(launchMode: ContinuationWireLaunchMode) {
        switch launchMode {
        case .autoTmux, .pinnedTmux: self = .continueSession
        case .customCommand: self = .reconnect
        }
    }
}

public struct ContinuationEndpointV1: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let name: String
    public let user: String
    public let address: String
    public let port: Int
    public let transport: ContinuationWireTransport
    public let hostKeyFingerprint: String?

    public var hostKeyFP: String? { hostKeyFingerprint }

    public init(
        hostID: UUID,
        name: String,
        user: String,
        address: String,
        port: Int,
        transport: ContinuationWireTransport,
        hostKeyFingerprint: String? = nil
    ) {
        self.hostID = hostID
        self.name = name
        self.user = user
        self.address = address
        self.port = port
        self.transport = transport
        self.hostKeyFingerprint = hostKeyFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case hostID
        case name
        case user
        case address
        case port
        case transport
        case hostKeyFingerprint = "hostKeyFP"
    }
}

public struct ContinuationRouteCoordinate: Codable, Equatable, Hashable, Sendable {
    public let user: String
    public let address: String
    public let port: Int
    public let transport: ContinuationWireTransport

    public init(
        user: String,
        address: String,
        port: Int,
        transport: ContinuationWireTransport
    ) {
        self.user = user
        self.address = address
        self.port = port
        self.transport = transport
    }

    public init(endpoint: ContinuationEndpointV1) {
        user = endpoint.user
        address = endpoint.address
        port = endpoint.port
        transport = endpoint.transport
    }
}

/// Byte-compatible source replacement for the shipped
/// `SessionActivityDescriptor` schema v1.
public struct ContinuationDescriptorV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumHandoffBytes = 3 * 1024
    public static let maximumViaCount = 8

    public let schemaVersion: Int
    public let endpoint: ContinuationEndpointV1
    public let connectionKey: String
    public let launchMode: ContinuationWireLaunchMode
    public let tmuxSessionName: String?
    public let via: [ContinuationEndpointV1]

    public var hostID: UUID { endpoint.hostID }
    public var name: String { endpoint.name }
    public var user: String { endpoint.user }
    public var address: String { endpoint.address }
    public var port: Int { endpoint.port }
    public var transport: ContinuationWireTransport { endpoint.transport }
    public var hostKeyFingerprint: String? { endpoint.hostKeyFingerprint }
    public var hostKeyFP: String? { endpoint.hostKeyFP }
    public var tmux: String? { tmuxSessionName }
    public var v: Int { schemaVersion }
    public var continuationAction: ContinuationAction { ContinuationAction(launchMode: launchMode) }
    public var resolverRoute: [ContinuationRouteCoordinate] {
        Self.resolverRoute(for: endpoint, via: via)
    }

    public init(
        endpoint: ContinuationEndpointV1,
        launchMode: ContinuationWireLaunchMode,
        tmuxSessionName: String?,
        via: [ContinuationEndpointV1] = [],
        connectionKey: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.endpoint = endpoint
        self.connectionKey = connectionKey ?? Self.connectionKey(for: endpoint, via: via)
        self.launchMode = launchMode
        self.tmuxSessionName = tmuxSessionName
        self.via = via
    }

    public static func connectionKey(
        for endpoint: ContinuationEndpointV1,
        via: [ContinuationEndpointV1]
    ) -> String {
        var key = "\(endpoint.transport.rawValue):\(endpoint.user)@\(endpoint.address):\(endpoint.port)"
        if !via.isEmpty {
            key += "&via=" + via.map(\.hostID.uuidString).joined(separator: ",")
        }
        return key
    }

    public static func resolverRoute(
        for endpoint: ContinuationEndpointV1,
        via: [ContinuationEndpointV1]
    ) -> [ContinuationRouteCoordinate] {
        (via + [endpoint]).map(ContinuationRouteCoordinate.init(endpoint:))
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumHandoffBytes else {
            throw ContinuationDescriptorError.exceedsHandoffBudget(
                actual: data.count,
                maximum: Self.maximumHandoffBytes
            )
        }
        return data
    }

    public init(encoded data: Data) throws {
        guard data.count <= Self.maximumHandoffBytes else {
            throw ContinuationDescriptorError.exceedsHandoffBudget(
                actual: data.count,
                maximum: Self.maximumHandoffBytes
            )
        }
        self = try JSONDecoder().decode(Self.self, from: data)
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ContinuationDescriptorError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !connectionKey.isEmpty else { throw ContinuationDescriptorError.emptyConnectionKey }
        guard via.count <= Self.maximumViaCount else {
            throw ContinuationDescriptorError.tooManyViaEndpoints(via.count)
        }
        for candidate in [endpoint] + via {
            guard (1...65_535).contains(candidate.port) else {
                throw ContinuationDescriptorError.invalidPort(candidate.port)
            }
            if let fingerprint = candidate.hostKeyFingerprint,
               fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ContinuationDescriptorError.invalidHostKeyFingerprint
            }
        }
        var seen = Set<UUID>()
        for candidate in via + [endpoint] {
            guard seen.insert(candidate.hostID).inserted else {
                throw ContinuationDescriptorError.duplicateRouteHostID(candidate.hostID)
            }
        }
        switch continuationAction {
        case .continueSession:
            guard let tmuxSessionName,
                  !tmuxSessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ContinuationDescriptorError.missingTmuxSessionName
            }
            guard TmuxTargetValidation.isSafeSessionName(tmuxSessionName) else {
                throw ContinuationDescriptorError.invalidTmuxSessionName
            }
        case .reconnect:
            guard tmuxSessionName == nil else {
                throw ContinuationDescriptorError.unexpectedTmuxSessionName
            }
        }
        let expected = Self.connectionKey(for: endpoint, via: via)
        guard connectionKey == expected else {
            throw ContinuationDescriptorError.connectionKeyMismatch(
                expected: expected,
                actual: connectionKey
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "v"
        case hostID
        case connectionKey
        case name
        case user
        case address
        case port
        case transport
        case launchMode
        case tmuxSessionName = "tmux"
        case via
        case hostKeyFingerprint = "hostKeyFP"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        endpoint = ContinuationEndpointV1(
            hostID: try values.decode(UUID.self, forKey: .hostID),
            name: try values.decode(String.self, forKey: .name),
            user: try values.decode(String.self, forKey: .user),
            address: try values.decode(String.self, forKey: .address),
            port: try values.decode(Int.self, forKey: .port),
            transport: try values.decode(ContinuationWireTransport.self, forKey: .transport),
            hostKeyFingerprint: try values.decodeIfPresent(
                String.self,
                forKey: .hostKeyFingerprint
            )
        )
        connectionKey = try values.decode(String.self, forKey: .connectionKey)
        launchMode = try values.decode(ContinuationWireLaunchMode.self, forKey: .launchMode)
        tmuxSessionName = try values.decodeIfPresent(String.self, forKey: .tmuxSessionName)
        via = try values.decode([ContinuationEndpointV1].self, forKey: .via)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(hostID, forKey: .hostID)
        try values.encode(connectionKey, forKey: .connectionKey)
        try values.encode(name, forKey: .name)
        try values.encode(user, forKey: .user)
        try values.encode(address, forKey: .address)
        try values.encode(port, forKey: .port)
        try values.encode(transport, forKey: .transport)
        try values.encode(launchMode, forKey: .launchMode)
        try values.encodeIfPresent(tmuxSessionName, forKey: .tmuxSessionName)
        try values.encode(via, forKey: .via)
        try values.encodeIfPresent(hostKeyFingerprint, forKey: .hostKeyFingerprint)
    }
}

public enum ContinuationDescriptorError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidPort(Int)
    case emptyConnectionKey
    case invalidHostKeyFingerprint
    case brokenJumpChain(String)
    case duplicateRouteHostID(UUID)
    case tooManyViaEndpoints(Int)
    case missingTmuxSessionName
    case invalidTmuxSessionName
    case unexpectedTmuxSessionName
    case connectionKeyMismatch(expected: String, actual: String)
    case exceedsHandoffBudget(actual: Int, maximum: Int)
}

public enum ContinuationActivityCodec {
    public static let activityType = "com.bambouville.tessera.session"
    public static let descriptorKey = "descriptor"

    public static func encode(_ descriptor: ContinuationDescriptorV1) throws -> Data {
        try descriptor.encoded()
    }

    public static func decode(_ data: Data) throws -> ContinuationDescriptorV1 {
        try ContinuationDescriptorV1(encoded: data)
    }
}
