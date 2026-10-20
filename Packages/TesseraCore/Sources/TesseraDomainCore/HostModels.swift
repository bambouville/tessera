import Foundation

public enum HostTransportKind: String, Codable, CaseIterable, Sendable {
    case ssh
    case mosh
}

public struct HostEndpoint: Codable, Equatable, Hashable, Sendable {
    public var user: String
    public var address: String
    public var port: UInt16

    public init(user: String, address: String, port: UInt16 = 22) {
        self.user = user
        self.address = address
        self.port = port
    }

    public func validated() throws -> Self {
        guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.emptyUser
        }
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.emptyAddress
        }
        return self
    }
}

public enum HostLaunchPolicy: Equatable, Sendable {
    case autoTmux
    case pinnedTmux(sessionName: String)
    /// Reconnect using the platform-local command configuration. Arbitrary
    /// shell text is intentionally absent from the shared public profile.
    case customCommand
}

extension HostLaunchPolicy: Codable {
    private enum Kind: String, Codable {
        case autoTmux
        case pinnedTmux
        case customCommand
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case tmux
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .autoTmux:
            self = .autoTmux
        case .pinnedTmux:
            self = .pinnedTmux(sessionName: try values.decode(String.self, forKey: .tmux))
        case .customCommand:
            self = .customCommand
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .autoTmux:
            try values.encode(Kind.autoTmux, forKey: .kind)
        case .pinnedTmux(let sessionName):
            try values.encode(Kind.pinnedTmux, forKey: .kind)
            try values.encode(sessionName, forKey: .tmux)
        case .customCommand:
            try values.encode(Kind.customCommand, forKey: .kind)
        }
    }
}

// `PortForwardDirection` / `PortForwardEndpoint` / `PortForwardRule` and their
// validator now live in `PortForwarding.swift` in this target.

/// Public, secret-free saved-host configuration. Credential references live in
/// the platform repository and are resolved only after the security gate.
public struct HostProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var endpoint: HostEndpoint
    public var transport: HostTransportKind
    public var launch: HostLaunchPolicy
    public var jumpHostIDs: [UUID]
    public var portForwards: [PortForwardRule]
    public var tags: [String]
    public var osHint: String?

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: HostEndpoint,
        transport: HostTransportKind = .ssh,
        launch: HostLaunchPolicy = .autoTmux,
        jumpHostIDs: [UUID] = [],
        portForwards: [PortForwardRule] = [],
        tags: [String] = [],
        osHint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.transport = transport
        self.launch = launch
        self.jumpHostIDs = jumpHostIDs
        self.portForwards = portForwards
        self.tags = tags
        self.osHint = osHint
    }

    public func validated(maximumJumpCount: Int = 8) throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.emptyName
        }
        _ = try endpoint.validated()
        guard jumpHostIDs.count <= maximumJumpCount else {
            throw DomainValidationError.tooManyJumpHosts(jumpHostIDs.count)
        }
        var seen = Set<UUID>()
        for id in jumpHostIDs + [id] {
            guard seen.insert(id).inserted else {
                throw DomainValidationError.cyclicOrDuplicateRoute(id)
            }
        }
        for rule in portForwards {
            _ = try rule.validated()
        }
        switch launch {
        case .pinnedTmux(let sessionName):
            guard !sessionName.isEmpty else { throw DomainValidationError.emptyTmuxSession }
        case .autoTmux, .customCommand:
            break
        }
        return self
    }
}

/// Local-only persistence metadata. It intentionally does not conform to
/// Codable, preventing it from entering continuation/bootstrap payloads by
/// generic serialization.
public enum LocalCredentialReference: Equatable, Sendable {
    case none
    case password(identityID: UUID)
    case key(keyID: UUID)
}

public struct ResolvedRouteNode: Equatable, Sendable {
    public let profile: HostProfile
    public let credentialReference: LocalCredentialReference

    public init(profile: HostProfile, credentialReference: LocalCredentialReference) {
        self.profile = profile
        self.credentialReference = credentialReference
    }
}

public struct HostRoute: Equatable, Sendable {
    public let hops: [ResolvedRouteNode]
    public let destination: ResolvedRouteNode

    public init(hops: [ResolvedRouteNode], destination: ResolvedRouteNode) throws {
        guard hops.count <= 8 else { throw DomainValidationError.tooManyJumpHosts(hops.count) }
        let nodes = hops + [destination]
        var seen = Set<UUID>()
        for node in nodes {
            _ = try node.profile.validated()
            guard seen.insert(node.profile.id).inserted else {
                throw DomainValidationError.cyclicOrDuplicateRoute(node.profile.id)
            }
        }
        self.hops = hops
        self.destination = destination
    }

    public var nodesInDialOrder: [ResolvedRouteNode] { hops + [destination] }

    public var structuralIdentity: String {
        nodesInDialOrder.map {
            let endpoint = $0.profile.endpoint
            return "\(endpoint.user)@\(endpoint.address):\(endpoint.port)/\($0.profile.transport.rawValue)"
        }.joined(separator: "→")
    }
}

public enum DomainValidationError: Error, Equatable, Sendable {
    case emptyName
    case emptyUser
    case emptyAddress
    case emptyBindAddress
    case emptyTargetHost
    case emptyTmuxSession
    case tooManyJumpHosts(Int)
    case cyclicOrDuplicateRoute(UUID)
}
