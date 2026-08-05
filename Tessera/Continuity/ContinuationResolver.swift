import Foundation

/// A local saved-host candidate, its persisted connection key, and its typed
/// route identity. The string key is retained as persistence metadata; route
/// matching deliberately uses the typed coordinates so delimiters in endpoint
/// fields cannot alias two different hosts.
struct ContinuationHostCandidate: Equatable, Sendable {
    let host: Host
    let connectionKey: String
    let resolverRoute: [SessionActivityRouteCoordinate]?

    init(host: Host, connectionKey: String) {
        self.host = host
        self.connectionKey = connectionKey
        resolverRoute = host.jumpChainBrokenReason == nil
            ? (host.jumpChain + [host]).map(SessionActivityRouteCoordinate.init(host:))
            : nil
    }

    /// Convenience for callers that already have a complete, non-broken Host
    /// route. SwiftData integrations should pass `PersistedHost.connectionKey`
    /// explicitly so both sides use the same source of truth.
    init(host: Host) {
        self.host = host
        let endpoint = SessionActivityEndpoint(host: host)
        let via = host.jumpChain.map { SessionActivityEndpoint(host: $0) }
        if host.jumpChainBrokenReason == nil {
            connectionKey = SessionActivityDescriptor.connectionKey(
                for: endpoint,
                via: via
            )
            resolverRoute = (host.jumpChain + [host]).map(
                SessionActivityRouteCoordinate.init(host:)
            )
        } else {
            connectionKey = "broken:\(host.id.uuidString)"
            resolverRoute = nil
        }
    }
}

enum ContinuationResolution: Equatable, Sendable {
    /// The receiver already has the sender's stable host UUID.
    case fastPath(Host)
    /// UUIDs differ, but transport, login endpoint, and jump route match.
    case endpointMatch(Host)
    /// The receiver has never seen this host. The descriptor itself is the
    /// editor prefill and retains the sender's UUID when saved.
    case prefill(SessionActivityDescriptor)

    var host: Host? {
        switch self {
        case .fastPath(let host), .endpointMatch(let host): host
        case .prefill: nil
        }
    }

    var descriptor: SessionActivityDescriptor? {
        switch self {
        case .fastPath, .endpointMatch: nil
        case .prefill(let descriptor): descriptor
        }
    }
}

/// Pure, ordered continuation resolution. UUID equality is authoritative; an
/// endpoint match is only the fallback for independently-created copies, and
/// unknown hosts remain an explicit editor-confirmation flow.
enum ContinuationResolver {
    static func resolve(
        _ descriptor: SessionActivityDescriptor,
        among candidates: [ContinuationHostCandidate]
    ) -> ContinuationResolution {
        if let match = candidates.first(where: { $0.host.id == descriptor.hostID }) {
            return .fastPath(match.host)
        }
        if let match = candidates.first(where: {
            guard let candidateRoute = $0.resolverRoute else { return false }
            return candidateRoute == descriptor.resolverRoute
        }) {
            return .endpointMatch(match.host)
        }
        return .prefill(descriptor)
    }

    static func resolve(
        _ descriptor: SessionActivityDescriptor,
        among hosts: [Host]
    ) -> ContinuationResolution {
        resolve(
            descriptor,
            among: hosts.map { ContinuationHostCandidate(host: $0) }
        )
    }
}

/// Maps the sender's public host-key comparison hints onto the receiver's
/// route identifiers. The destination UUID is deliberately absent from a
/// connection key, so an endpoint match can select a locally-created host
/// whose id differs from the descriptor's `hostID`. Passing the descriptor's
/// UUID-keyed dictionary through unchanged would then silently discard the
/// destination hint at first connect.
///
/// Route position is safe here because endpoint matching already requires the
/// same ordered jump chain. We still compare every public endpoint field and
/// fail closed if a caller supplies a route that does not describe the same
/// connection.
enum ContinuationTrustHintMapper {
    static func hints(
        from descriptor: SessionActivityDescriptor,
        for localHost: Host
    ) -> [UUID: String] {
        let advertisedRoute = descriptor.via + [descriptor.endpoint]
        let localRoute = localHost.jumpChain + [localHost]
        guard advertisedRoute.count == localRoute.count else { return [:] }

        var result: [UUID: String] = [:]
        for (advertised, local) in zip(advertisedRoute, localRoute) {
            guard advertised.user == local.user,
                  advertised.address == local.address,
                  advertised.port == local.port,
                  advertised.transport == local.transport
            else { return [:] }
            if let fingerprint = advertised.hostKeyFingerprint {
                result[local.id] = fingerprint
            }
        }
        return result
    }
}

/// A Handoff auto-tmux descriptor names the exact remote rendezvous. Generic
/// launches may reuse the ordinary per-host singleton; an exact continuation
/// target reuses only a live session known to have joined that same target.
enum ContinuationTmuxReusePolicy {
    static func mayReuseAutoTmuxSession(
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

/// Snapshot of an already-saved route endpoint used to decide whether a
/// never-seen destination may safely reuse it during editor prefill.
struct ContinuationSavedRouteEndpoint: Equatable, Sendable {
    let endpoint: SessionActivityEndpoint
    let jumpHostID: UUID?
}

enum ContinuationRouteReuseConflict: Equatable, Sendable {
    case destinationIdentifierAlreadyExists
    case endpointDiffers(UUID)
    case routeDiffers(UUID)
}

/// Pure preflight for the only potentially mutating part of a Handoff
/// prefill. Existing jump hosts are reusable, but are never silently edited.
enum ContinuationRouteReusePolicy {
    static func conflict(
        for descriptor: SessionActivityDescriptor,
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
                  saved.endpoint.transport == advertised.transport
            else { return .endpointDiffers(advertised.hostID) }

            let expectedJumpID: UUID? = index == 0
                ? nil
                : descriptor.via[index - 1].hostID
            if saved.jumpHostID != expectedJumpID {
                return .routeDiffers(advertised.hostID)
            }
        }
        return nil
    }
}

/// The set of PersistedHost rows a `.prefill` continuation would insert:
/// the destination (always new by resolver contract) plus every `via`
/// endpoint not already saved. Pure so the admission quota and its tests
/// share one counting rule with ContentView.
enum ContinuationInsertionPlanner {
    static func plannedInsertedHostIDs(
        for descriptor: SessionActivityDescriptor,
        hasSavedHost: (UUID) -> Bool
    ) -> Set<UUID> {
        Set([descriptor.hostID] + descriptor.via.compactMap {
            hasSavedHost($0.hostID) ? nil : $0.hostID
        })
    }
}
