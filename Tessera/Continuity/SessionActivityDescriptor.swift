import Foundation
import TesseraProtocolCore

/// Apple-facing adapter around the portable continuation-v1 endpoint. The app
/// keeps its runtime enums at UI/session boundaries while every byte and
/// validation decision comes from `TesseraProtocolCore`.
struct SessionActivityEndpoint: Codable, Equatable, Sendable {
    let hostID: UUID
    let name: String
    let user: String
    let address: String
    let port: Int
    let transport: HostTransport
    let hostKeyFingerprint: String?

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

    init(core: ContinuationEndpointV1) {
        self.init(
            hostID: core.hostID,
            name: core.name,
            user: core.user,
            address: core.address,
            port: core.port,
            transport: HostTransport(core.transport),
            hostKeyFingerprint: core.hostKeyFingerprint
        )
    }

    var core: ContinuationEndpointV1 {
        ContinuationEndpointV1(
            hostID: hostID,
            name: name,
            user: user,
            address: address,
            port: port,
            transport: ContinuationWireTransport(transport),
            hostKeyFingerprint: hostKeyFingerprint
        )
    }

    init(from decoder: Decoder) throws {
        self.init(core: try ContinuationEndpointV1(from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        try core.encode(to: encoder)
    }
}

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

    init(core: ContinuationRouteCoordinate) {
        user = core.user
        address = core.address
        port = core.port
        transport = HostTransport(core.transport)
    }
}

/// Compatibility facade retaining the app's established source API while
/// delegating schema-v1 coding and validation to the portable shared core.
struct SessionActivityDescriptor: Codable, Equatable, Sendable {
    typealias DescriptorError = ContinuationDescriptorError

    static let currentSchemaVersion = ContinuationDescriptorV1.currentSchemaVersion
    static let maximumHandoffBytes = ContinuationDescriptorV1.maximumHandoffBytes
    static let maximumViaCount = ContinuationDescriptorV1.maximumViaCount

    /// Portable representation used by the Apple transport, resolver, and
    /// state-machine adapters. Keeping this internal prevents UI call sites
    /// from taking a dependency on wire-only types while avoiding a second
    /// source of protocol truth inside the app target.
    let core: ContinuationDescriptorV1

    var schemaVersion: Int { core.schemaVersion }
    var endpoint: SessionActivityEndpoint { SessionActivityEndpoint(core: core.endpoint) }
    var connectionKey: String { core.connectionKey }
    var launchMode: HostLaunchMode { HostLaunchMode(core.launchMode) }
    var tmuxSessionName: String? { core.tmuxSessionName }
    var via: [SessionActivityEndpoint] { core.via.map(SessionActivityEndpoint.init(core:)) }

    var hostID: UUID { core.hostID }
    var name: String { core.name }
    var user: String { core.user }
    var address: String { core.address }
    var port: Int { core.port }
    var transport: HostTransport { HostTransport(core.transport) }
    var hostKeyFingerprint: String? { core.hostKeyFingerprint }
    var hostKeyFP: String? { core.hostKeyFP }
    var tmux: String? { core.tmux }
    var v: Int { core.v }
    var continuationAction: ContinuationAction { core.continuationAction }
    var resolverRoute: [SessionActivityRouteCoordinate] {
        core.resolverRoute.map(SessionActivityRouteCoordinate.init(core:))
    }

    init(
        endpoint: SessionActivityEndpoint,
        launchMode: HostLaunchMode,
        tmuxSessionName: String?,
        via: [SessionActivityEndpoint] = [],
        connectionKey: String? = nil
    ) {
        core = ContinuationDescriptorV1(
            endpoint: endpoint.core,
            launchMode: ContinuationWireLaunchMode(launchMode),
            tmuxSessionName: tmuxSessionName,
            via: via.map(\.core),
            connectionKey: connectionKey
        )
    }

    init(core: ContinuationDescriptorV1) {
        self.core = core
    }

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
        self.init(
            endpoint: SessionActivityEndpoint(
                host: host,
                hostKeyFingerprint: hostKeyFingerprint
            ),
            launchMode: host.launchMode,
            tmuxSessionName: resolvedTmuxSessionName,
            via: host.jumpChain.map {
                SessionActivityEndpoint(
                    host: $0,
                    hostKeyFingerprint: viaHostKeyFingerprints[$0.id]
                )
            },
            connectionKey: connectionKey
        )
        try validate()
    }

    static func connectionKey(
        for endpoint: SessionActivityEndpoint,
        via: [SessionActivityEndpoint]
    ) -> String {
        ContinuationDescriptorV1.connectionKey(
            for: endpoint.core,
            via: via.map(\.core)
        )
    }

    static func resolverRoute(
        for endpoint: SessionActivityEndpoint,
        via: [SessionActivityEndpoint]
    ) -> [SessionActivityRouteCoordinate] {
        ContinuationDescriptorV1.resolverRoute(
            for: endpoint.core,
            via: via.map(\.core)
        ).map(SessionActivityRouteCoordinate.init(core:))
    }

    func handoffData() throws -> Data {
        try core.encoded()
    }

    init(handoffData: Data) throws {
        core = try ContinuationDescriptorV1(encoded: handoffData)
    }

    func validate() throws {
        try core.validate()
    }

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

    init(from decoder: Decoder) throws {
        core = try ContinuationDescriptorV1(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try core.encode(to: encoder)
    }
}

typealias ContinuationAction = TesseraProtocolCore.ContinuationAction

extension ContinuationAction {
    init(launchMode: HostLaunchMode) {
        self.init(launchMode: ContinuationWireLaunchMode(launchMode))
    }

    var label: String {
        switch self {
        case .continueSession:
            String(localized: "Continue", comment: "Continuation action name")
        case .reconnect:
            String(localized: "Reconnect", comment: "Continuation action name")
        }
    }
}

extension ContinuationDescriptorError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            String(localized: "Unsupported continuation schema version \(version).")
        case .invalidPort(let port):
            String(localized: "Continuation endpoint has invalid port \(port).")
        case .emptyConnectionKey:
            String(localized: "Continuation endpoint has an empty connection key.")
        case .invalidHostKeyFingerprint:
            String(localized: "Continuation endpoint has an empty host-key fingerprint.")
        case .brokenJumpChain(let reason):
            String(localized: "Continuation route is unavailable: \(reason)")
        case .duplicateRouteHostID(let id):
            String(localized: "Continuation route repeats host \(id.uuidString).")
        case .tooManyViaEndpoints(let count):
            String(
                localized: "Continuation route contains \(count) jump hosts.",
                comment: "Continuity validation error. Pluralized on the jump-host count."
            )
        case .missingTmuxSessionName:
            String(localized: "A tmux continuation requires its resolved session name.")
        case .invalidTmuxSessionName:
            String(localized: "The continuation tmux session name contains unsafe characters.")
        case .unexpectedTmuxSessionName:
            String(localized: "A plain reconnect cannot advertise a tmux session.")
        case .connectionKeyMismatch:
            String(localized: "Continuation connection key does not match its endpoint route.")
        case .exceedsHandoffBudget(let actual, let maximum):
            String(localized: "Continuation descriptor is \(actual) bytes; the limit is \(maximum).")
        }
    }
}

extension ContinuationWireTransport {
    init(_ transport: HostTransport) {
        switch transport {
        case .ssh: self = .ssh
        case .mosh: self = .mosh
        }
    }
}

extension HostTransport {
    init(_ transport: ContinuationWireTransport) {
        switch transport {
        case .ssh: self = .ssh
        case .mosh: self = .mosh
        }
    }
}

private extension ContinuationWireLaunchMode {
    init(_ launchMode: HostLaunchMode) {
        switch launchMode {
        case .autoTmux: self = .autoTmux
        case .pinnedTmux: self = .pinnedTmux
        case .customCommand: self = .customCommand
        }
    }
}

private extension HostLaunchMode {
    init(_ launchMode: ContinuationWireLaunchMode) {
        switch launchMode {
        case .autoTmux: self = .autoTmux
        case .pinnedTmux: self = .pinnedTmux
        case .customCommand: self = .customCommand
        }
    }
}
