import Foundation

/// The public, credential-free description of one endpoint in a continuation
/// route. The same type represents the destination and each bastion hop so the
/// route cannot acquire an untyped payload as the feature grows.
struct SessionActivityEndpoint: Codable, Equatable, Sendable {
    let hostID: UUID
    let name: String
    let user: String
    let address: String
    let port: Int
    let transport: HostTransport
    let hostKeyFingerprint: String?

    /// Wire-contract spelling used by the design and trust-card integration.
    var hostKeyFP: String? { hostKeyFingerprint }

    init(
        hostID: UUID,
        name: String,
        user: String,
        address: String,
        port: Int,
        transport: HostTransport,
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

    init(host: Host, hostKeyFingerprint: String? = nil) {
        self.init(
            hostID: host.id,
            name: host.name,
            user: host.user,
            address: host.address,
            port: host.port,
            transport: host.transport,
            hostKeyFingerprint: hostKeyFingerprint
        )
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

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try values.decode(UUID.self, forKey: .hostID)
        name = try values.decode(String.self, forKey: .name)
        user = try values.decode(String.self, forKey: .user)
        address = try values.decode(String.self, forKey: .address)
        port = try values.decode(Int.self, forKey: .port)
        transport = try values.decode(HostTransport.self, forKey: .transport)
        hostKeyFingerprint = try values.decodeIfPresent(String.self, forKey: .hostKeyFingerprint)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(hostID, forKey: .hostID)
        try values.encode(name, forKey: .name)
        try values.encode(user, forKey: .user)
        try values.encode(address, forKey: .address)
        try values.encode(port, forKey: .port)
        try values.encode(transport, forKey: .transport)
        try values.encodeIfPresent(hostKeyFingerprint, forKey: .hostKeyFingerprint)
    }
}

/// Collision-free resolver identity for one route position. Keeping the
/// coordinates typed avoids treating delimiter-bearing usernames or hostnames
/// as structure when independently-created host records are compared.
struct SessionActivityRouteCoordinate: Equatable, Sendable {
    let user: String
    let address: String
    let port: Int
    let transport: HostTransport

    init(endpoint: SessionActivityEndpoint) {
        user = endpoint.user
        address = endpoint.address
        port = endpoint.port
        transport = endpoint.transport
    }

    init(host: Host) {
        user = host.user
        address = host.address
        port = host.port
        transport = host.transport
    }
}

/// A versioned allowlist of the public information needed to continue or
/// reconnect a session on another device.
///
/// Deliberately absent: passwords, credential modes, key identifiers/private
/// handles, commands, environment variables, snippets, notes, trust pins, and
/// terminal contents. `hostKeyFP` is a public fingerprint used only to inform
/// the receiving device's explicit TOFU decision; it is never installed as a
/// local trust pin.
struct SessionActivityDescriptor: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumHandoffBytes = 3 * 1024
    static let maximumViaCount = 8

    enum DescriptorError: Error, Equatable, LocalizedError {
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

        var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let version):
                return "Unsupported continuation schema version \(version)."
            case .invalidPort(let port):
                return "Continuation endpoint has invalid port \(port)."
            case .emptyConnectionKey:
                return "Continuation endpoint has an empty connection key."
            case .invalidHostKeyFingerprint:
                return "Continuation endpoint has an empty host-key fingerprint."
            case .brokenJumpChain(let reason):
                return "Continuation route is unavailable: \(reason)"
            case .duplicateRouteHostID(let id):
                return "Continuation route repeats host \(id.uuidString)."
            case .tooManyViaEndpoints(let count):
                return "Continuation route contains \(count) jump hosts."
            case .missingTmuxSessionName:
                return "A tmux continuation requires its resolved session name."
            case .invalidTmuxSessionName:
                return "The continuation tmux session name contains unsafe characters."
            case .unexpectedTmuxSessionName:
                return "A plain reconnect cannot advertise a tmux session."
            case .connectionKeyMismatch:
                return "Continuation connection key does not match its endpoint route."
            case .exceedsHandoffBudget(let actual, let maximum):
                return "Continuation descriptor is \(actual) bytes; the limit is \(maximum)."
            }
        }
    }

    let schemaVersion: Int
    let endpoint: SessionActivityEndpoint
    let connectionKey: String
    let launchMode: HostLaunchMode
    /// Resolved server-side tmux session name. This is required for tmux
    /// launch modes and absent for honest plain SSH/mosh reconnects.
    let tmuxSessionName: String?
    /// Bastions in dial order, outermost first.
    let via: [SessionActivityEndpoint]

    var hostID: UUID { endpoint.hostID }
    var name: String { endpoint.name }
    var user: String { endpoint.user }
    var address: String { endpoint.address }
    var port: Int { endpoint.port }
    var transport: HostTransport { endpoint.transport }
    var hostKeyFingerprint: String? { endpoint.hostKeyFingerprint }
    var hostKeyFP: String? { endpoint.hostKeyFP }
    var tmux: String? { tmuxSessionName }
    var v: Int { schemaVersion }

    var continuationAction: ContinuationAction {
        ContinuationAction(launchMode: launchMode)
    }

    init(
        endpoint: SessionActivityEndpoint,
        launchMode: HostLaunchMode,
        tmuxSessionName: String?,
        via: [SessionActivityEndpoint] = [],
        connectionKey: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.endpoint = endpoint
        self.connectionKey = connectionKey ?? Self.connectionKey(for: endpoint, via: via)
        self.launchMode = launchMode
        self.tmuxSessionName = tmuxSessionName
        self.via = via
    }

    /// Extracts the descriptor's allowlisted fields from the live Host DTO.
    /// Secret-bearing Host fields are intentionally never accepted as
    /// descriptor initializer parameters.
    init(
        host: Host,
        resolvedTmuxSessionName: String?,
        hostKeyFingerprint: String? = nil,
        viaHostKeyFingerprints: [UUID: String] = [:],
        connectionKey: String? = nil
    ) throws {
        if let broken = host.jumpChainBrokenReason {
            throw DescriptorError.brokenJumpChain(broken)
        }
        let endpoint = SessionActivityEndpoint(
            host: host,
            hostKeyFingerprint: hostKeyFingerprint
        )
        let via = host.jumpChain.map {
            SessionActivityEndpoint(
                host: $0,
                hostKeyFingerprint: viaHostKeyFingerprints[$0.id]
            )
        }
        self.init(
            endpoint: endpoint,
            launchMode: host.launchMode,
            tmuxSessionName: resolvedTmuxSessionName,
            via: via,
            connectionKey: connectionKey
        )
        try validate()
    }

    /// The exact connection-key shape used by `PersistedHost.connectionKey`.
    /// Keeping this pure makes endpoint matching available before SwiftData or
    /// credential resolution enters the continuation flow.
    static func connectionKey(
        for endpoint: SessionActivityEndpoint,
        via: [SessionActivityEndpoint]
    ) -> String {
        var key = "\(endpoint.transport.rawValue):\(endpoint.user)@\(endpoint.address):\(endpoint.port)"
        if !via.isEmpty {
            key += "&via=" + via.map(\.hostID.uuidString).joined(separator: ",")
        }
        return key
    }

    /// Resolver-only route identity for independently-created saved hosts.
    /// Persisted and wire connection keys retain UUIDs; this typed route
    /// intentionally uses ordered public endpoint coordinates so equivalent
    /// bastion routes can match even when every local UUID differs.
    static func resolverRoute(
        for endpoint: SessionActivityEndpoint,
        via: [SessionActivityEndpoint]
    ) -> [SessionActivityRouteCoordinate] {
        (via + [endpoint]).map(SessionActivityRouteCoordinate.init(endpoint:))
    }

    var resolverRoute: [SessionActivityRouteCoordinate] {
        Self.resolverRoute(for: endpoint, via: via)
    }

    /// Encodes the descriptor for NSUserActivity and enforces the design's
    /// practical 3 KiB payload budget at the boundary that broadcasts it.
    func handoffData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumHandoffBytes else {
            throw DescriptorError.exceedsHandoffBudget(
                actual: data.count,
                maximum: Self.maximumHandoffBytes
            )
        }
        return data
    }

    init(handoffData: Data) throws {
        guard handoffData.count <= Self.maximumHandoffBytes else {
            throw DescriptorError.exceedsHandoffBudget(
                actual: handoffData.count,
                maximum: Self.maximumHandoffBytes
            )
        }
        self = try JSONDecoder().decode(Self.self, from: handoffData)
        try validate()
    }

    /// Builds a local, credential-empty editor prefill. Sender UUIDs are
    /// adopted intentionally so a subsequently bootstrapped/synced copy takes
    /// the resolver's UUID fast path rather than becoming a duplicate.
    func makePrefilledHost() -> Host {
        let routeFingerprints = Dictionary(
            uniqueKeysWithValues: ([endpoint] + via).compactMap { routeEndpoint in
                routeEndpoint.hostKeyFingerprint.map {
                    (routeEndpoint.hostID, $0)
                }
            }
        )
        let jumpHosts = via.map {
            Host(
                id: $0.hostID,
                name: $0.name,
                address: $0.address,
                port: $0.port,
                user: $0.user,
                transport: $0.transport,
                autoTmux: false,
                launchMode: .customCommand
            )
        }
        return Host(
            id: hostID,
            name: name,
            address: address,
            port: port,
            user: user,
            transport: transport,
            autoTmux: launchMode != .customCommand,
            launchMode: launchMode,
            tmuxSessionName: launchMode == .pinnedTmux ? tmuxSessionName : nil,
            jumpChain: jumpHosts,
            continuationHostKeyFingerprints: routeFingerprints
        )
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DescriptorError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !connectionKey.isEmpty else {
            throw DescriptorError.emptyConnectionKey
        }
        guard via.count <= Self.maximumViaCount else {
            throw DescriptorError.tooManyViaEndpoints(via.count)
        }
        for candidate in [endpoint] + via {
            guard (1...65_535).contains(candidate.port) else {
                throw DescriptorError.invalidPort(candidate.port)
            }
            if let fingerprint = candidate.hostKeyFingerprint,
               fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw DescriptorError.invalidHostKeyFingerprint
            }
        }
        var seen = Set<UUID>()
        for candidate in via + [endpoint] {
            guard seen.insert(candidate.hostID).inserted else {
                throw DescriptorError.duplicateRouteHostID(candidate.hostID)
            }
        }

        switch continuationAction {
        case .continueSession:
            guard let tmuxSessionName,
                  !tmuxSessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DescriptorError.missingTmuxSessionName
            }
            guard MoshBootstrap.isShellSafeSessionName(tmuxSessionName) else {
                throw DescriptorError.invalidTmuxSessionName
            }
        case .reconnect:
            guard tmuxSessionName == nil else {
                throw DescriptorError.unexpectedTmuxSessionName
            }
        }

        let expected = Self.connectionKey(for: endpoint, via: via)
        guard connectionKey == expected else {
            throw DescriptorError.connectionKeyMismatch(expected: expected, actual: connectionKey)
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

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        endpoint = SessionActivityEndpoint(
            hostID: try values.decode(UUID.self, forKey: .hostID),
            name: try values.decode(String.self, forKey: .name),
            user: try values.decode(String.self, forKey: .user),
            address: try values.decode(String.self, forKey: .address),
            port: try values.decode(Int.self, forKey: .port),
            transport: try values.decode(HostTransport.self, forKey: .transport),
            hostKeyFingerprint: try values.decodeIfPresent(
                String.self,
                forKey: .hostKeyFingerprint
            )
        )
        connectionKey = try values.decode(String.self, forKey: .connectionKey)
        launchMode = try values.decode(HostLaunchMode.self, forKey: .launchMode)
        tmuxSessionName = try values.decodeIfPresent(String.self, forKey: .tmuxSessionName)
        via = try values.decode([SessionActivityEndpoint].self, forKey: .via)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
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

/// User-visible semantics for a continuation. Only tmux-owned screens can be
/// continued; plain SSH and plain mosh always create a new remote session.
enum ContinuationAction: String, Codable, Equatable, Sendable {
    case continueSession
    case reconnect

    init(launchMode: HostLaunchMode) {
        switch launchMode {
        case .autoTmux, .pinnedTmux:
            self = .continueSession
        case .customCommand:
            self = .reconnect
        }
    }

    var label: String {
        switch self {
        case .continueSession: "Continue"
        case .reconnect: "Reconnect"
        }
    }
}
