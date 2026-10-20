import Foundation

public enum CredentialKind: String, Sendable {
    case none
    case password
    case signingKey
}

public enum CredentialUseError: Error, Equatable, Sendable {
    case unsupportedOperation
    case stalePolicy(expected: UInt64, actual: UInt64)
    case wrongAttempt
    case alreadyConsumed
    case ownerAuthorizationRequired
    case unavailable
}

/// A local credential operation. Implementations may release a password once
/// or ask platform hardware to sign, but never expose private-key bytes.
public protocol CredentialCapability: Sendable {
    var kind: CredentialKind { get }
    var credentialID: UUID? { get }
    var policyGeneration: UInt64 { get }
    var requiresOwnerAuthorization: Bool { get }

    func providePassword(attemptID: UUID) async throws -> String
    func sign(payload: Data, algorithm: String, attemptID: UUID) async throws -> Data
}

public extension CredentialCapability {
    func providePassword(attemptID: UUID) async throws -> String {
        throw CredentialUseError.unsupportedOperation
    }

    func sign(payload: Data, algorithm: String, attemptID: UUID) async throws -> Data {
        throw CredentialUseError.unsupportedOperation
    }
}

public struct RouteCredential: Sendable {
    public let hostID: UUID
    public let capability: any CredentialCapability

    public init(hostID: UUID, capability: any CredentialCapability) {
        self.hostID = hostID
        self.capability = capability
    }
}

public struct ConnectionRequest: Sendable {
    public static let maximumLifetime: TimeInterval = 60

    public let id: UUID
    public let route: HostRoute
    public let credentials: [RouteCredential]
    public let policyGeneration: UInt64
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        route: HostRoute,
        credentials: [RouteCredential],
        policyGeneration: UInt64,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) throws {
        let resolvedExpiresAt = expiresAt
            ?? createdAt.addingTimeInterval(Self.maximumLifetime)
        let routeIDs = Set(route.nodesInDialOrder.map(\.profile.id))
        let credentialIDs = credentials.map(\.hostID)
        guard credentialIDs.count == Set(credentialIDs).count,
              Set(credentialIDs).isSubset(of: routeIDs)
        else { throw ConnectionRequestError.invalidCredentialRoute }
        guard credentials.allSatisfy({ $0.capability.policyGeneration == policyGeneration }) else {
            throw ConnectionRequestError.mixedPolicyGeneration
        }
        guard resolvedExpiresAt > createdAt,
              resolvedExpiresAt.timeIntervalSince(createdAt) <= Self.maximumLifetime
        else { throw ConnectionRequestError.invalidLifetime }
        self.id = id
        self.route = route
        self.credentials = credentials
        self.policyGeneration = policyGeneration
        self.createdAt = createdAt
        self.expiresAt = resolvedExpiresAt
    }

    /// Revalidates the short-lived request immediately before a platform
    /// adapter starts using any credential capability.
    public func validateForUse(
        now: Date = Date(),
        currentPolicyGeneration: UInt64
    ) throws {
        guard currentPolicyGeneration == policyGeneration else {
            throw ConnectionRequestError.stalePolicy(
                expected: policyGeneration,
                actual: currentPolicyGeneration
            )
        }
        guard now >= createdAt, now < expiresAt else {
            throw ConnectionRequestError.expired
        }
    }
}

public enum ConnectionRequestError: Error, Equatable, Sendable {
    case invalidCredentialRoute
    case mixedPolicyGeneration
    case invalidLifetime
    case stalePolicy(expected: UInt64, actual: UInt64)
    case expired
}

public protocol HostRepository: Sendable {
    func host(id: UUID) async throws -> HostProfile?
    func hosts() async throws -> [HostProfile]
    func save(_ profile: HostProfile) async throws
}

public protocol CredentialRepository: Sendable {
    func reference(forHostID hostID: UUID) async throws -> LocalCredentialReference
    func capability(
        for reference: LocalCredentialReference,
        attemptID: UUID,
        policyGeneration: UInt64
    ) async throws -> any CredentialCapability
}
