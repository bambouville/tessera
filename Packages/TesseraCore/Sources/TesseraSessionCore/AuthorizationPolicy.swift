import Foundation

public actor AuthenticationPolicyGeneration {
    private var generation: UInt64

    public init(initialGeneration: UInt64 = 1) {
        generation = max(1, initialGeneration)
    }

    public func current() -> UInt64 { generation }

    @discardableResult
    public func invalidate() -> UInt64 {
        generation &+= 1
        if generation == 0 { generation = 1 }
        return generation
    }
}

public struct OwnerAuthorizationRequest: Equatable, Sendable {
    public let attemptID: UUID
    public let policyGeneration: UInt64
    public let scope: OwnerAuthorizationScope
    public let expiresAt: Date

    public init(
        attemptID: UUID,
        policyGeneration: UInt64,
        scope: OwnerAuthorizationScope,
        expiresAt: Date
    ) {
        self.attemptID = attemptID
        self.policyGeneration = policyGeneration
        self.scope = scope
        self.expiresAt = expiresAt
    }
}

public struct OwnerAuthorizationBinding: Equatable, Hashable, Sendable {
    public let operation: String
    public let categories: [String]
    public let payloadDigest: Data

    public init(operation: String, categories: [String], payloadDigest: Data) {
        self.operation = operation
        self.categories = categories
        self.payloadDigest = payloadDigest
    }
}

public struct OwnerAuthorizationScope: Equatable, Hashable, Sendable {
    public let routeIdentity: String
    public let hostID: UUID
    public let publicKeyFingerprint: String
    public let authorizationBinding: OwnerAuthorizationBinding?

    public init(
        routeIdentity: String,
        hostID: UUID,
        publicKeyFingerprint: String,
        authorizationBinding: OwnerAuthorizationBinding? = nil
    ) {
        self.routeIdentity = routeIdentity
        self.hostID = hostID
        self.publicKeyFingerprint = publicKeyFingerprint
        self.authorizationBinding = authorizationBinding
    }
}

public struct FreshOwnerAuthorization: Equatable, Sendable {
    public let token: UUID
    public let attemptID: UUID
    public let policyGeneration: UInt64
    public let scope: OwnerAuthorizationScope
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        token: UUID = UUID(),
        attemptID: UUID,
        policyGeneration: UInt64,
        scope: OwnerAuthorizationScope,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.token = token
        self.attemptID = attemptID
        self.policyGeneration = policyGeneration
        self.scope = scope
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public protocol FreshOwnerAuthorizing: Sendable {
    func authorize(_ request: OwnerAuthorizationRequest) async throws -> FreshOwnerAuthorization
}

public enum OwnerAuthorizationError: Error, Equatable, Sendable {
    case scopeMismatch
    case staleAttempt
    case stalePolicy
    case expired
    case alreadyConsumed
    case revoked
    case notFresh
    case lifetimeTooLong
}

/// Mints and consumes one-shot access grants bound to the exact route and
/// public key. App lock or any policy mutation revokes all outstanding grants.
public actor DeviceAccessGrantEngine {
    public static let maximumFreshAuthorizationAge: TimeInterval = 10
    public static let maximumAuthorizationFutureSkew: TimeInterval = 1
    public static let maximumGrantLifetime: TimeInterval = 60

    public struct Authorization: Equatable, Sendable {
        public let id: UUID
        public let attemptID: UUID
        public let policyGeneration: UInt64
        public let scope: OwnerAuthorizationScope
        public let expiresAt: Date

        init(
            id: UUID,
            attemptID: UUID,
            policyGeneration: UInt64,
            scope: OwnerAuthorizationScope,
            expiresAt: Date
        ) {
            self.id = id
            self.attemptID = attemptID
            self.policyGeneration = policyGeneration
            self.scope = scope
            self.expiresAt = expiresAt
        }
    }

    private struct State: Sendable {
        let authorization: Authorization
        var consumed: Bool
        var revoked: Bool
    }

    private var states: [UUID: State] = [:]
    // Retain token identities for the engine's lifetime. Expiring this ledger
    // would let a caller recycle a token with rewritten timestamps.
    private var consumedOwnerAuthorizationTokens = Set<UUID>()
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func mint(
        from ownerAuthorization: FreshOwnerAuthorization,
        expected request: OwnerAuthorizationRequest
    ) throws -> Authorization {
        guard ownerAuthorization.attemptID == request.attemptID else {
            throw OwnerAuthorizationError.staleAttempt
        }
        guard ownerAuthorization.policyGeneration == request.policyGeneration else {
            throw OwnerAuthorizationError.stalePolicy
        }
        guard ownerAuthorization.scope == request.scope else {
            throw OwnerAuthorizationError.scopeMismatch
        }
        let currentTime = now()
        let authorizationAge = currentTime.timeIntervalSince(ownerAuthorization.issuedAt)
        guard authorizationAge >= -Self.maximumAuthorizationFutureSkew,
              authorizationAge <= Self.maximumFreshAuthorizationAge else {
            throw OwnerAuthorizationError.notFresh
        }
        guard currentTime < ownerAuthorization.expiresAt,
              currentTime < request.expiresAt else {
            throw OwnerAuthorizationError.expired
        }
        let expiresAt = min(ownerAuthorization.expiresAt, request.expiresAt)
        guard expiresAt.timeIntervalSince(currentTime) <= Self.maximumGrantLifetime else {
            throw OwnerAuthorizationError.lifetimeTooLong
        }
        guard !request.scope.routeIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.scope.publicKeyFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OwnerAuthorizationError.scopeMismatch
        }
        if let binding = request.scope.authorizationBinding {
            guard !binding.operation.isEmpty,
                  binding.operation.utf8.count <= 128,
                  binding.operation.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }),
                  binding.categories.count <= 32,
                  binding.categories == binding.categories.sorted(),
                  Set(binding.categories).count == binding.categories.count,
                  binding.categories.allSatisfy({ category in
                      !category.isEmpty
                          && category.utf8.count <= 128
                          && category.unicodeScalars.allSatisfy({
                              !CharacterSet.controlCharacters.contains($0)
                          })
                  }),
                  binding.payloadDigest.count == 32 else {
                throw OwnerAuthorizationError.scopeMismatch
            }
        }
        guard consumedOwnerAuthorizationTokens.insert(ownerAuthorization.token).inserted else {
            throw OwnerAuthorizationError.alreadyConsumed
        }
        let authorization = Authorization(
            id: UUID(),
            attemptID: request.attemptID,
            policyGeneration: request.policyGeneration,
            scope: request.scope,
            expiresAt: expiresAt
        )
        states[authorization.id] = State(
            authorization: authorization,
            consumed: false,
            revoked: false
        )
        return authorization
    }

    public func consume(
        _ authorization: Authorization,
        attemptID: UUID,
        policyGeneration: UInt64,
        scope: OwnerAuthorizationScope
    ) throws {
        guard var state = states[authorization.id] else {
            throw OwnerAuthorizationError.revoked
        }
        guard !state.revoked else { throw OwnerAuthorizationError.revoked }
        guard !state.consumed else { throw OwnerAuthorizationError.alreadyConsumed }
        guard state.authorization.attemptID == attemptID else {
            throw OwnerAuthorizationError.staleAttempt
        }
        guard state.authorization.policyGeneration == policyGeneration else {
            throw OwnerAuthorizationError.stalePolicy
        }
        guard state.authorization.scope == scope else {
            throw OwnerAuthorizationError.scopeMismatch
        }
        guard now() < state.authorization.expiresAt else {
            throw OwnerAuthorizationError.expired
        }
        state.consumed = true
        states[authorization.id] = state
    }

    /// Atomically consumes one exact capability per scope. No capability is
    /// marked consumed unless the complete batch is current and valid.
    public func consume(
        _ authorizations: [Authorization],
        attemptID: UUID,
        policyGeneration: UInt64,
        scopes: [OwnerAuthorizationScope]
    ) throws {
        guard !authorizations.isEmpty,
              authorizations.count == scopes.count,
              Set(authorizations.map(\.id)).count == authorizations.count,
              Set(authorizations.map(\.scope)).count == authorizations.count,
              Set(authorizations.map(\.scope)) == Set(scopes) else {
            throw OwnerAuthorizationError.scopeMismatch
        }
        let currentTime = now()
        for authorization in authorizations {
            guard let state = states[authorization.id], !state.revoked else {
                throw OwnerAuthorizationError.revoked
            }
            guard !state.consumed else { throw OwnerAuthorizationError.alreadyConsumed }
            guard state.authorization.attemptID == attemptID else {
                throw OwnerAuthorizationError.staleAttempt
            }
            guard state.authorization.policyGeneration == policyGeneration else {
                throw OwnerAuthorizationError.stalePolicy
            }
            guard currentTime < state.authorization.expiresAt else {
                throw OwnerAuthorizationError.expired
            }
        }
        for authorization in authorizations {
            states[authorization.id]?.consumed = true
        }
    }

    public func revokeAll() {
        // Snapshot the keys before mutating dictionary values. Iterating the
        // live keys view while applying mutations is not a reliable revocation
        // primitive across Swift runtimes.
        for id in Array(states.keys) {
            states[id]?.revoked = true
        }
    }

    public func revoke(_ authorization: Authorization) {
        states[authorization.id]?.revoked = true
    }

    public func revokeAttempt(_ attemptID: UUID) {
        let matchingIDs = states.compactMap { id, state in
            state.authorization.attemptID == attemptID ? id : nil
        }
        for id in matchingIDs {
            states[id]?.revoked = true
        }
    }
}
