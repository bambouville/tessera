import Foundation
import TesseraDomainCore
import TesseraProtocolCore

/// A saved-host candidate plus the typed route supplied by its platform
/// repository. Broken or unresolved routes use nil and cannot endpoint-match.
public struct ContinuationHostCandidate: Equatable, Sendable {
    public let profile: HostProfile
    public let connectionKey: String
    public let resolverRoute: [ContinuationRouteCoordinate]?

    public init(
        profile: HostProfile,
        connectionKey: String,
        resolverRoute: [ContinuationRouteCoordinate]?
    ) {
        self.profile = profile
        self.connectionKey = connectionKey
        self.resolverRoute = resolverRoute
    }
}

public enum ContinuationResolution: Equatable, Sendable {
    /// The receiver already has the sender's stable host identifier.
    case fastPath(HostProfile)
    /// Identifiers differ, but the typed ordered public route is identical.
    case endpointMatch(HostProfile)
    /// The descriptor is an explicit editor prefill, never an automatic save.
    case prefill(ContinuationDescriptorV1)

    public var host: HostProfile? {
        switch self {
        case .fastPath(let host), .endpointMatch(let host): return host
        case .prefill: return nil
        }
    }
}

/// UUID-first, typed-route-fallback resolution. Persistence connection-key
/// strings are intentionally not structural comparators.
public enum ContinuationResolver {
    public static func resolve(
        _ descriptor: ContinuationDescriptorV1,
        among candidates: [ContinuationHostCandidate]
    ) -> ContinuationResolution {
        if let exact = candidates.first(where: { $0.profile.id == descriptor.hostID }) {
            return .fastPath(exact.profile)
        }
        if let routeMatch = candidates.first(where: {
            guard let route = $0.resolverRoute else { return false }
            return route == descriptor.resolverRoute
        }) {
            return .endpointMatch(routeMatch.profile)
        }
        return .prefill(descriptor)
    }
}

/// One local route node for position-safe comparison-hint mapping.
public struct ContinuationLocalRouteEndpoint: Equatable, Sendable {
    public let hostID: UUID
    public let user: String
    public let address: String
    public let port: Int
    public let transport: ContinuationWireTransport

    public init(
        hostID: UUID,
        user: String,
        address: String,
        port: Int,
        transport: ContinuationWireTransport
    ) {
        self.hostID = hostID
        self.user = user
        self.address = address
        self.port = port
        self.transport = transport
    }

    public init(profile: HostProfile) {
        hostID = profile.id
        user = profile.endpoint.user
        address = profile.endpoint.address
        port = Int(profile.endpoint.port)
        transport = profile.transport == .ssh ? .ssh : .mosh
    }
}

/// Continuation fingerprints are explicit comparison hints, never silent pins.
public enum ContinuationTrustHintPolicy {
    public static func hints(
        from descriptor: ContinuationDescriptorV1,
        for localRoute: [ContinuationLocalRouteEndpoint]
    ) -> [UUID: String] {
        let advertisedRoute = descriptor.via + [descriptor.endpoint]
        guard advertisedRoute.count == localRoute.count else { return [:] }

        var result: [UUID: String] = [:]
        for (advertised, local) in zip(advertisedRoute, localRoute) {
            guard advertised.user == local.user,
                  advertised.address == local.address,
                  advertised.port == local.port,
                  advertised.transport == local.transport else {
                return [:]
            }
            if let fingerprint = advertised.hostKeyFingerprint {
                result[local.hostID] = fingerprint
            }
        }
        return result
    }
}

/// Compatibility spelling matching the pre-refactor Apple helper.
public typealias ContinuationTrustHintMapper = ContinuationTrustHintPolicy

public struct ContinuationSavedRouteEndpoint: Equatable, Sendable {
    public let endpoint: ContinuationEndpointV1
    public let jumpHostID: UUID?

    public init(endpoint: ContinuationEndpointV1, jumpHostID: UUID?) {
        self.endpoint = endpoint
        self.jumpHostID = jumpHostID
    }
}

public enum ContinuationRouteReuseConflict: Equatable, Sendable {
    case destinationIdentifierAlreadyExists
    case endpointDiffers(UUID)
    case routeDiffers(UUID)
}

/// Existing jump hosts may be reused, but a descriptor may never silently
/// edit their endpoint or parent relationship.
public enum ContinuationRouteReusePolicy {
    public static func conflict(
        for descriptor: ContinuationDescriptorV1,
        destinationIdentifierExists: Bool,
        savedVia: [UUID: ContinuationSavedRouteEndpoint]
    ) -> ContinuationRouteReuseConflict? {
        if destinationIdentifierExists {
            return .destinationIdentifierAlreadyExists
        }
        for (index, advertised) in descriptor.via.enumerated() {
            guard let saved = savedVia[advertised.hostID] else { continue }
            guard saved.endpoint.user == advertised.user,
                  saved.endpoint.address == advertised.address,
                  saved.endpoint.port == advertised.port,
                  saved.endpoint.transport == advertised.transport else {
                return .endpointDiffers(advertised.hostID)
            }
            let expectedParent = index == 0 ? nil : descriptor.via[index - 1].hostID
            guard saved.jumpHostID == expectedParent else {
                return .routeDiffers(advertised.hostID)
            }
        }
        return nil
    }
}

public struct ContinuationInsertionPlan: Equatable, Sendable {
    public let insertedHostIDs: Set<UUID>

    public init(insertedHostIDs: Set<UUID>) {
        self.insertedHostIDs = insertedHostIDs
    }

    public var newRowCount: Int { insertedHostIDs.count }
}

/// Counts the destination plus only unsaved route endpoints. The destination
/// remains unconditional because this is called only for resolver `.prefill`.
public enum ContinuationInsertionPlanner {
    public static func plan(
        for descriptor: ContinuationDescriptorV1,
        hasSavedHost: (UUID) -> Bool
    ) -> ContinuationInsertionPlan {
        ContinuationInsertionPlan(insertedHostIDs: Set(
            [descriptor.hostID] + descriptor.via.compactMap {
                hasSavedHost($0.hostID) ? nil : $0.hostID
            }
        ))
    }

    public static func plannedInsertedHostIDs(
        for descriptor: ContinuationDescriptorV1,
        hasSavedHost: (UUID) -> Bool
    ) -> Set<UUID> {
        plan(for: descriptor, hasSavedHost: hasSavedHost).insertedHostIDs
    }
}

public enum ContinuationHostAccess: Equatable, Sendable {
    /// Entitlement truth is pending, but rows within this included quota are
    /// entitlement-independent and must remain available offline.
    case checking(includedMaximumSavedHosts: Int)
    case limited(maximumSavedHosts: Int)
    case unlimited
}

public enum ContinuationAdmissionDecision: Equatable, Sendable {
    case allow
    case requiresUpgrade
    case checkingEntitlement
}

/// Pure, atomic admission policy. Platform billing adapters map their current
/// entitlement state into this small semantic input.
public enum ContinuationAdmissionPolicy {
    public static func decision(
        existingHostCount: Int,
        insertionPlan: ContinuationInsertionPlan,
        access: ContinuationHostAccess
    ) -> ContinuationAdmissionDecision {
        decision(
            existingHostCount: existingHostCount,
            newRowCount: insertionPlan.newRowCount,
            access: access
        )
    }

    public static func decision(
        existingHostCount: Int,
        newRowCount: Int,
        access: ContinuationHostAccess
    ) -> ContinuationAdmissionDecision {
        guard newRowCount > 0 else { return .allow }
        let requestedTotal = max(0, existingHostCount) + newRowCount
        switch access {
        case .unlimited:
            return .allow
        case .limited(let maximumSavedHosts)
            where requestedTotal <= max(0, maximumSavedHosts):
            return .allow
        case .checking(let includedMaximumSavedHosts)
            where requestedTotal <= max(0, includedMaximumSavedHosts):
            return .allow
        case .checking:
            return .checkingEntitlement
        case .limited:
            return .requiresUpgrade
        }
    }
}

/// Exact continuation targets may reuse only the same live tmux rendezvous.
public enum ContinuationTmuxReusePolicy {
    public static func mayReuseAutoTmuxSession(
        requestedSessionName: String?,
        activeSessionName: String?
    ) -> Bool {
        let requested = requestedSessionName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requested.isEmpty else { return true }
        let active = activeSessionName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return active == requested
    }
}
