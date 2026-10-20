import Foundation

/// Transaction support is purpose-specific. Version 2 changes bootstrap only;
/// the continuation leg of setup-and-continue retains its v1 message contract.
public enum PairingTransactionVersionsV1 {
    public static func supported(for purpose: PairingPurpose) -> [Int] {
        switch purpose {
        case .bootstrap, .setUpAndContinue: return [1, 2]
        case .continueSession, .enroll: return [1]
        }
    }
}

/// Platform-neutral configuration for the peer that renders a QR offer.
public struct PairingOriginDriverConfigurationV1: Sendable {
    public let purpose: PairingPurpose
    public let expiresAt: Int64
    public let endpointCandidates: [PairingEndpointCandidateV1]
    public let oneTimeOpticalSecret: Data?
    public let supportedTransactionVersions: [Int]
    public let optionalPayloadDigest: Data?

    public init(
        purpose: PairingPurpose,
        expiresAt: Int64,
        endpointCandidates: [PairingEndpointCandidateV1],
        oneTimeOpticalSecret: Data?,
        supportedTransactionVersions: [Int]? = nil,
        optionalPayloadDigest: Data? = nil
    ) {
        self.purpose = purpose
        self.expiresAt = expiresAt
        self.endpointCandidates = endpointCandidates
        self.oneTimeOpticalSecret = oneTimeOpticalSecret
        self.supportedTransactionVersions = supportedTransactionVersions ?? PairingTransactionVersionsV1.supported(for: purpose)
        self.optionalPayloadDigest = optionalPayloadDigest
    }
}

public struct PairingRecipientDriverConfigurationV1: Sendable {
    public let encodedOffer: Data
    public let supportedTransactionVersions: [Int]
    public let consumptionStore: PairingOfferConsumptionStoreV1

    public init(
        encodedOffer: Data,
        supportedTransactionVersions: [Int]? = nil,
        consumptionStore: PairingOfferConsumptionStoreV1 = .shared
    ) {
        self.encodedOffer = encodedOffer
        self.supportedTransactionVersions = supportedTransactionVersions ?? (try? PairingOfferV1.decode(encodedOffer)).map {
            PairingTransactionVersionsV1.supported(for: $0.purpose)
        } ?? [1]
        self.consumptionStore = consumptionStore
    }
}

public enum PairingHandshakeDriverInvalidationV1: Equatable, Sendable {
    case cancelled
    case expired
    case rejected
    case failed
}

public enum PairingHandshakeDriverStateV1: Equatable, Sendable {
    case awaitingRecipientCommitment
    case awaitingOriginHello
    case awaitingRecipientHello
    case awaitingSASDecision
    case approved
    case invalidated(PairingHandshakeDriverInvalidationV1)
}

public enum PairingHandshakeDriverErrorV1: Error, Equatable, Sendable {
    case unexpectedRecord(expected: PairingStreamRecordKindV1, actual: PairingStreamRecordKindV1)
    case peerAlreadyAdmitted
    case localDecisionAlreadyMade
    case sasUnavailable
    case sessionUnavailable
    case handshakeComplete
    case invalidated
}

/// Shared orchestration for a QR/local-stream Pairing-v1 origin. Network and
/// UI adapters pass records in/out; this type admits one peer and retains no
/// session handle until both people approve the same SAS.
public final class PairingOriginDriverV1: @unchecked Sendable {
    public let offerBytes: Data
    public let offer: PairingOfferV1

    private let attempt: PairingOriginAttemptV1
    private let now: @Sendable () -> Int64
    private let lock = NSLock()
    private var stateStorage: PairingHandshakeDriverStateV1 = .awaitingRecipientCommitment
    private var peerAdmitted = false
    private var rawSession: PairingSessionV1?
    private var localDecisionMade = false
    private var peerDecisionMade = false
    private var approvedSessionStorage: PairingSessionV1?

    public init(
        configuration: PairingOriginDriverConfigurationV1,
        now: @escaping @Sendable () -> Int64 = { PairingHandshakeV1.unixTimeNow() }
    ) throws {
        self.now = now
        attempt = try PairingHandshakeV1.beginOrigin(
            purpose: configuration.purpose,
            currentTime: now(),
            expiresAt: configuration.expiresAt,
            endpointCandidates: configuration.endpointCandidates,
            oneTimeOpticalSecret: configuration.oneTimeOpticalSecret,
            supportedTransactionVersions: configuration.supportedTransactionVersions,
            optionalPayloadDigest: configuration.optionalPayloadDigest
        )
        offerBytes = attempt.encodedOffer
        offer = attempt.offer
    }

    public var state: PairingHandshakeDriverStateV1 {
        lock.lock(); defer { lock.unlock() }
        invalidateIfExpiredLocked()
        return stateStorage
    }

    /// Available after the cryptographic handshake, before either decision.
    public var sas: PairingShortAuthenticationStringV1? {
        lock.lock(); defer { lock.unlock() }
        invalidateIfExpiredLocked()
        return rawSession?.sas
    }

    /// The session becomes observable only after mutual SAS approval.
    public var approvedSession: PairingSessionV1? {
        lock.lock(); defer { lock.unlock() }
        invalidateIfExpiredLocked()
        return approvedSessionStorage
    }

    /// Reserves this one-shot attempt for exactly one local byte connection.
    public func admitPeer() throws {
        lock.lock(); defer { lock.unlock() }
        try requireLiveLocked()
        guard !peerAdmitted else { throw PairingHandshakeDriverErrorV1.peerAlreadyAdmitted }
        peerAdmitted = true
    }

    public func receive(_ record: PairingStreamRecordV1) throws -> [PairingStreamRecordV1] {
        lock.lock(); defer { lock.unlock() }
        guard stateStorage != .approved else {
            // The approved session, not the handshake driver, owns all later
            // authenticated transaction traffic. Do not consume a frame from
            // the escaped session or invalidate that usable session here.
            throw PairingHandshakeDriverErrorV1.handshakeComplete
        }
        do {
            try requireLiveLocked()
            if !peerAdmitted { peerAdmitted = true }
            switch stateStorage {
            case .awaitingRecipientCommitment:
                try require(record, kind: .recipientCommitment)
                let disclosure = try attempt.reveal(after: record.payload)
                stateStorage = .awaitingRecipientHello
                return [try PairingStreamRecordV1(kind: .originHello, payload: disclosure.encodedHello)]
            case .awaitingRecipientHello:
                try require(record, kind: .recipientHello)
                rawSession = try attempt.complete(with: record.payload)
                stateStorage = .awaitingSASDecision
                return []
            case .awaitingSASDecision:
                try require(record, kind: .authenticatedPairingFrame)
                try receiveDecisionLocked(record.payload)
                return []
            case .approved:
                // Excluded by the guard above while the same lock is held.
                throw PairingHandshakeDriverErrorV1.handshakeComplete
            case .awaitingOriginHello, .invalidated:
                throw PairingHandshakeDriverErrorV1.invalidated
            }
        } catch {
            invalidateLocked(for: error)
            throw error
        }
    }

    public func decideSAS(matches: Bool) throws -> PairingStreamRecordV1 {
        lock.lock(); defer { lock.unlock() }
        do {
            try requireLiveLocked()
            guard case .awaitingSASDecision = stateStorage else {
                throw PairingHandshakeDriverErrorV1.sasUnavailable
            }
            guard !localDecisionMade else { throw PairingHandshakeDriverErrorV1.localDecisionAlreadyMade }
            guard let rawSession else { throw PairingHandshakeDriverErrorV1.sessionUnavailable }
            let frame = try rawSession.sealPeerDecision(matches: matches)
            localDecisionMade = true
            let output = try PairingStreamRecordV1(kind: .authenticatedPairingFrame, payload: frame)
            guard matches else {
                stateStorage = .invalidated(.rejected)
                self.rawSession = nil
                return output
            }
            publishIfApprovedLocked()
            return output
        } catch {
            invalidateLocked(for: error)
            throw error
        }
    }

    /// Cancels the attempt and optionally emits one authenticated abort after
    /// the handshake. Callers close their listener/connection immediately.
    public func cancel() -> PairingStreamRecordV1? {
        lock.lock(); defer { lock.unlock() }
        guard !isTerminalLocked() else { return nil }
        defer { invalidateLocked(.cancelled) }
        guard let rawSession else { return nil }
        return try? PairingStreamRecordV1(
            kind: .authenticatedPairingFrame,
            payload: try rawSession.sealAbort()
        )
    }

    private func receiveDecisionLocked(_ frame: Data) throws {
        guard let rawSession else { throw PairingHandshakeDriverErrorV1.sessionUnavailable }
        let envelope = try rawSession.open(frame)
        if envelope.kind == .abort {
            stateStorage = .invalidated(.cancelled)
            self.rawSession = nil
            return
        }
        guard envelope.kind == .peerDecision else { throw PairingError.unexpectedMessageOrder }
        peerDecisionMade = true
        guard envelope.payload == Data([1]) else {
            stateStorage = .invalidated(.rejected)
            self.rawSession = nil
            return
        }
        publishIfApprovedLocked()
    }

    private func publishIfApprovedLocked() {
        guard localDecisionMade, peerDecisionMade, let rawSession, rawSession.isTransactionReady else { return }
        approvedSessionStorage = rawSession
        stateStorage = .approved
    }

    private func require(_ record: PairingStreamRecordV1, kind: PairingStreamRecordKindV1) throws {
        guard record.kind == kind else {
            throw PairingHandshakeDriverErrorV1.unexpectedRecord(expected: kind, actual: record.kind)
        }
    }

    private func requireLiveLocked() throws {
        invalidateIfExpiredLocked()
        guard !isTerminalLocked() else { throw PairingHandshakeDriverErrorV1.invalidated }
    }

    private func invalidateIfExpiredLocked() {
        guard now() >= offer.expiresAt, !isTerminalLocked() else { return }
        invalidateLocked(.expired)
    }

    private func isTerminalLocked() -> Bool {
        if case .invalidated = stateStorage { return true }
        return false
    }

    private func invalidateLocked(_ reason: PairingHandshakeDriverInvalidationV1) {
        stateStorage = .invalidated(reason)
        rawSession = nil
        approvedSessionStorage = nil
    }

    private func invalidateLocked(for error: Error) {
        if let pairing = error as? PairingError, pairing == .offerExpired {
            invalidateLocked(.expired)
        } else if let pairing = error as? PairingError, pairing == .pairingRejected {
            invalidateLocked(.rejected)
        } else {
            invalidateLocked(.failed)
        }
    }
}

/// Shared orchestration for the peer that scans an offer and opens the local
/// connection. Its commitment is the first stream record it emits.
public final class PairingRecipientDriverV1: @unchecked Sendable {
    public let initialRecord: PairingStreamRecordV1
    public let offer: PairingOfferV1

    private let attempt: PairingRecipientAttemptV1
    private let now: @Sendable () -> Int64
    private let lock = NSLock()
    private var stateStorage: PairingHandshakeDriverStateV1 = .awaitingOriginHello
    private var peerAdmitted = false
    private var rawSession: PairingSessionV1?
    private var localDecisionMade = false
    private var peerDecisionMade = false
    private var approvedSessionStorage: PairingSessionV1?

    public init(
        configuration: PairingRecipientDriverConfigurationV1,
        now: @escaping @Sendable () -> Int64 = { PairingHandshakeV1.unixTimeNow() }
    ) throws {
        self.now = now
        attempt = try PairingHandshakeV1.beginRecipient(
            encodedOffer: configuration.encodedOffer,
            currentTime: now(),
            supportedTransactionVersions: configuration.supportedTransactionVersions,
            consumptionStore: configuration.consumptionStore
        )
        offer = attempt.offer
        initialRecord = try PairingStreamRecordV1(
            kind: .recipientCommitment,
            payload: attempt.encodedCommitment
        )
    }

    public var state: PairingHandshakeDriverStateV1 {
        lock.lock(); defer { lock.unlock() }
        invalidateIfExpiredLocked()
        return stateStorage
    }

    public var sas: PairingShortAuthenticationStringV1? {
        lock.lock(); defer { lock.unlock() }
        invalidateIfExpiredLocked()
        return rawSession?.sas
    }

    public var approvedSession: PairingSessionV1? {
        lock.lock(); defer { lock.unlock() }
        invalidateIfExpiredLocked()
        return approvedSessionStorage
    }

    public func admitPeer() throws {
        lock.lock(); defer { lock.unlock() }
        try requireLiveLocked()
        guard !peerAdmitted else { throw PairingHandshakeDriverErrorV1.peerAlreadyAdmitted }
        peerAdmitted = true
    }

    public func receive(_ record: PairingStreamRecordV1) throws -> [PairingStreamRecordV1] {
        lock.lock(); defer { lock.unlock() }
        guard stateStorage != .approved else {
            throw PairingHandshakeDriverErrorV1.handshakeComplete
        }
        do {
            try requireLiveLocked()
            if !peerAdmitted { peerAdmitted = true }
            switch stateStorage {
            case .awaitingOriginHello:
                try require(record, kind: .originHello)
                let completion = try attempt.complete(with: record.payload)
                rawSession = completion.session
                stateStorage = .awaitingSASDecision
                return [try PairingStreamRecordV1(kind: .recipientHello, payload: completion.encodedHello)]
            case .awaitingSASDecision:
                try require(record, kind: .authenticatedPairingFrame)
                try receiveDecisionLocked(record.payload)
                return []
            case .approved:
                throw PairingHandshakeDriverErrorV1.handshakeComplete
            case .awaitingRecipientCommitment, .awaitingRecipientHello, .invalidated:
                throw PairingHandshakeDriverErrorV1.invalidated
            }
        } catch {
            invalidateLocked(for: error)
            throw error
        }
    }

    public func decideSAS(matches: Bool) throws -> PairingStreamRecordV1 {
        lock.lock(); defer { lock.unlock() }
        do {
            try requireLiveLocked()
            guard case .awaitingSASDecision = stateStorage else {
                throw PairingHandshakeDriverErrorV1.sasUnavailable
            }
            guard !localDecisionMade else { throw PairingHandshakeDriverErrorV1.localDecisionAlreadyMade }
            guard let rawSession else { throw PairingHandshakeDriverErrorV1.sessionUnavailable }
            let frame = try rawSession.sealPeerDecision(matches: matches)
            localDecisionMade = true
            let output = try PairingStreamRecordV1(kind: .authenticatedPairingFrame, payload: frame)
            guard matches else {
                stateStorage = .invalidated(.rejected)
                self.rawSession = nil
                return output
            }
            publishIfApprovedLocked()
            return output
        } catch {
            invalidateLocked(for: error)
            throw error
        }
    }

    public func cancel() -> PairingStreamRecordV1? {
        lock.lock(); defer { lock.unlock() }
        guard !isTerminalLocked() else { return nil }
        defer { invalidateLocked(.cancelled) }
        guard let rawSession else { return nil }
        return try? PairingStreamRecordV1(
            kind: .authenticatedPairingFrame,
            payload: try rawSession.sealAbort()
        )
    }

    private func receiveDecisionLocked(_ frame: Data) throws {
        guard let rawSession else { throw PairingHandshakeDriverErrorV1.sessionUnavailable }
        let envelope = try rawSession.open(frame)
        if envelope.kind == .abort {
            stateStorage = .invalidated(.cancelled)
            self.rawSession = nil
            return
        }
        guard envelope.kind == .peerDecision else { throw PairingError.unexpectedMessageOrder }
        peerDecisionMade = true
        guard envelope.payload == Data([1]) else {
            stateStorage = .invalidated(.rejected)
            self.rawSession = nil
            return
        }
        publishIfApprovedLocked()
    }

    private func publishIfApprovedLocked() {
        guard localDecisionMade, peerDecisionMade, let rawSession, rawSession.isTransactionReady else { return }
        approvedSessionStorage = rawSession
        stateStorage = .approved
    }

    private func require(_ record: PairingStreamRecordV1, kind: PairingStreamRecordKindV1) throws {
        guard record.kind == kind else {
            throw PairingHandshakeDriverErrorV1.unexpectedRecord(expected: kind, actual: record.kind)
        }
    }

    private func requireLiveLocked() throws {
        invalidateIfExpiredLocked()
        guard !isTerminalLocked() else { throw PairingHandshakeDriverErrorV1.invalidated }
    }

    private func invalidateIfExpiredLocked() {
        guard now() >= offer.expiresAt, !isTerminalLocked() else { return }
        invalidateLocked(.expired)
    }

    private func isTerminalLocked() -> Bool {
        if case .invalidated = stateStorage { return true }
        return false
    }

    private func invalidateLocked(_ reason: PairingHandshakeDriverInvalidationV1) {
        stateStorage = .invalidated(reason)
        rawSession = nil
        approvedSessionStorage = nil
    }

    private func invalidateLocked(for error: Error) {
        if let pairing = error as? PairingError, pairing == .offerExpired {
            invalidateLocked(.expired)
        } else if let pairing = error as? PairingError, pairing == .pairingRejected {
            invalidateLocked(.rejected)
        } else {
            invalidateLocked(.failed)
        }
    }
}
