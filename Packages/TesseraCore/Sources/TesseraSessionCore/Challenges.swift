import Foundation
import TesseraTrustCore

public struct ChallengeContext: Codable, Equatable, Sendable {
    public let challengeID: UUID
    public let sessionID: UUID
    public let attemptID: UUID
    public let policyGeneration: UInt64
    public let expiresAt: Date

    public init(
        challengeID: UUID = UUID(),
        sessionID: UUID,
        attemptID: UUID,
        policyGeneration: UInt64,
        expiresAt: Date
    ) {
        self.challengeID = challengeID
        self.sessionID = sessionID
        self.attemptID = attemptID
        self.policyGeneration = policyGeneration
        self.expiresAt = expiresAt
    }
}

public enum SessionChallenge: Codable, Equatable, Sendable {
    case hostKey(context: ChallengeContext, endpoint: KnownHostEndpoint, fingerprint: String, hint: String?)
    case credential(context: ChallengeContext, credentialID: UUID?, kind: String)
    case ownerAuthorization(context: ChallengeContext, reasonCode: String)
    case importConflict(context: ChallengeContext, conflictCode: String)

    public var context: ChallengeContext {
        switch self {
        case .hostKey(let context, _, _, _),
             .credential(let context, _, _),
             .ownerAuthorization(let context, _),
             .importConflict(let context, _):
            return context
        }
    }

    public static let maximumLifetime: TimeInterval = 60
    public static let maximumEncodedBytes = 4_096
    public static let maximumHostBytes = 255
    public static let maximumFingerprintBytes = 256
    public static let maximumHintBytes = 1_024
    public static let maximumCodeBytes = 64

    public func validate(now: Date) throws {
        let lifetime = context.expiresAt.timeIntervalSince(now)
        guard lifetime > 0, lifetime <= Self.maximumLifetime else {
            throw ChallengeValidationError.invalidLifetime
        }

        switch self {
        case .hostKey(_, let endpoint, let fingerprint, let hint):
            try Self.validateDisplay(
                endpoint.host,
                field: "host",
                maximumBytes: Self.maximumHostBytes,
                allowEmpty: false
            )
            try Self.validateDisplay(
                fingerprint,
                field: "fingerprint",
                maximumBytes: Self.maximumFingerprintBytes,
                allowEmpty: false
            )
            if let hint {
                try Self.validateDisplay(
                    hint,
                    field: "hint",
                    maximumBytes: Self.maximumHintBytes,
                    allowEmpty: true
                )
            }
        case .credential(_, _, let kind):
            try Self.validateDisplay(
                kind,
                field: "credentialKind",
                maximumBytes: Self.maximumCodeBytes,
                allowEmpty: false
            )
        case .ownerAuthorization(_, let reasonCode):
            try Self.validateDisplay(
                reasonCode,
                field: "reasonCode",
                maximumBytes: Self.maximumCodeBytes,
                allowEmpty: false
            )
        case .importConflict(_, let conflictCode):
            try Self.validateDisplay(
                conflictCode,
                field: "conflictCode",
                maximumBytes: Self.maximumCodeBytes,
                allowEmpty: false
            )
        }

        guard try JSONEncoder().encode(self).count <= Self.maximumEncodedBytes else {
            throw ChallengeValidationError.encodedSizeExceeded
        }
    }

    private static func validateDisplay(
        _ value: String,
        field: String,
        maximumBytes: Int,
        allowEmpty: Bool
    ) throws {
        guard (allowEmpty || !value.isEmpty),
              value.utf8.count <= maximumBytes,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
        else { throw ChallengeValidationError.invalidDisplayMetadata(field: field) }
    }
}

public enum ChallengeDecision: String, Codable, Sendable {
    case approve
    case reject
    case cancel
}

public struct ChallengeResponse: Codable, Equatable, Sendable {
    public let challengeID: UUID
    public let attemptID: UUID
    public let policyGeneration: UInt64
    public let decision: ChallengeDecision

    public init(
        challengeID: UUID,
        attemptID: UUID,
        policyGeneration: UInt64,
        decision: ChallengeDecision
    ) {
        self.challengeID = challengeID
        self.attemptID = attemptID
        self.policyGeneration = policyGeneration
        self.decision = decision
    }
}

public enum ChallengeValidationError: Error, Equatable, Sendable {
    case duplicateChallenge
    case unknownChallenge
    case staleSession
    case staleAttempt
    case stalePolicy
    case expired
    case alreadyConsumed
    case invalidLifetime
    case invalidDisplayMetadata(field: String)
    case encodedSizeExceeded
}

public actor ChallengeRegistry {
    struct Storage: Sendable {
        private struct Entry: Sendable {
            let challenge: SessionChallenge
            var consumed: Bool
        }

        private var entries: [UUID: Entry] = [:]
        private let now: @Sendable () -> Date

        init(now: @escaping @Sendable () -> Date) {
            self.now = now
        }

        mutating func insert(_ challenge: SessionChallenge) throws {
            try challenge.validate(now: now())
            guard entries[challenge.context.challengeID] == nil else {
                throw ChallengeValidationError.duplicateChallenge
            }
            entries[challenge.context.challengeID] = Entry(challenge: challenge, consumed: false)
        }

        mutating func consume(
            _ response: ChallengeResponse,
            currentAttemptID: UUID,
            currentPolicyGeneration: UInt64
        ) throws -> SessionChallenge {
            guard var entry = entries[response.challengeID] else {
                throw ChallengeValidationError.unknownChallenge
            }
            guard !entry.consumed else { throw ChallengeValidationError.alreadyConsumed }
            let context = entry.challenge.context
            guard response.attemptID == currentAttemptID, context.attemptID == currentAttemptID else {
                throw ChallengeValidationError.staleAttempt
            }
            guard response.policyGeneration == currentPolicyGeneration,
                  context.policyGeneration == currentPolicyGeneration else {
                throw ChallengeValidationError.stalePolicy
            }
            guard now() < context.expiresAt else { throw ChallengeValidationError.expired }
            entry.consumed = true
            entries[response.challengeID] = entry
            return entry.challenge
        }

        mutating func invalidateAll() {
            entries.removeAll(keepingCapacity: false)
        }
    }

    private var storage: Storage

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        storage = Storage(now: now)
    }

    public func insert(_ challenge: SessionChallenge) throws {
        try storage.insert(challenge)
    }

    public func consume(
        _ response: ChallengeResponse,
        currentAttemptID: UUID,
        currentPolicyGeneration: UInt64
    ) throws -> SessionChallenge {
        try storage.consume(
            response,
            currentAttemptID: currentAttemptID,
            currentPolicyGeneration: currentPolicyGeneration
        )
    }

    public func invalidateAll() {
        storage.invalidateAll()
    }
}
