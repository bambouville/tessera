import Crypto
import Foundation

public enum PairingEnvelopeKindV1: String, Codable, CaseIterable, Sendable {
    case peerDecision
    case transactionMessage
    case abort
    case completion
}

/// Closed plaintext carried by PairingFrameV1. Transaction-specific messages
/// remain opaque until after the pairing purpose and selected transaction
/// version have been authenticated by the handshake transcript.
public struct PairingEnvelopeV1: Codable, Equatable, Sendable {
    public static let maximumTransactionPayloadBytes = 32 * 1_024
    public static let maximumAbortPayloadBytes = 1_024
    public static let maximumCompletionPayloadBytes = 4 * 1_024
    static let maximumEncodedBytes = 48 * 1_024

    public let kind: PairingEnvelopeKindV1
    public let payload: Data

    public init(kind: PairingEnvelopeKindV1, payload: Data) throws {
        self.kind = kind
        self.payload = payload
        try validate()
    }

    func encoded() throws -> Data {
        try validate()
        return try PairingWireCodecV1.encodeBounded(self, maximum: Self.maximumEncodedBytes)
    }

    static func decode(_ data: Data) throws -> PairingEnvelopeV1 {
        let value: PairingEnvelopeV1 = try PairingWireCodecV1.decodeCanonical(
            data,
            maximum: Self.maximumEncodedBytes,
            allowedRootFields: ["kind", "payload"]
        )
        try value.validate()
        return value
    }

    func validate() throws {
        switch kind {
        case .peerDecision:
            guard payload.count == 1, payload[0] == 0 || payload[0] == 1 else {
                throw PairingError.invalidEnvelope
            }
        case .transactionMessage:
            guard payload.count <= Self.maximumTransactionPayloadBytes else {
                throw PairingError.invalidEnvelope
            }
        case .abort:
            guard payload.count <= Self.maximumAbortPayloadBytes else {
                throw PairingError.invalidEnvelope
            }
        case .completion:
            guard payload.count <= Self.maximumCompletionPayloadBytes else {
                throw PairingError.invalidEnvelope
            }
        }
    }
}

public enum PairingFrameDirectionV1: UInt8, Codable, CaseIterable, Sendable {
    case originToRecipient = 1
    case recipientToOrigin = 2

    public var peer: PairingFrameDirectionV1 {
        switch self {
        case .originToRecipient: return .recipientToOrigin
        case .recipientToOrigin: return .originToRecipient
        }
    }
}

/// Authenticated binary frame. The nonce is included in `sealedPayload` by
/// ChaCha20-Poly1305 and is also checked against the direction-specific derived
/// base nonce and sequence before decryption.
public struct PairingFrameV1: Equatable, Sendable {
    public static let currentVersion: UInt8 = 1
    public static let maximumEncodedBytes = 65_536
    public static let magic = Data([0x54, 0x50, 0x46, 0x31]) // TPF1
    public static let headerByteCount = 4 + 1 + 1 + 8 + 4

    public let version: UInt8
    public let direction: PairingFrameDirectionV1
    public let sequence: UInt64
    public let sealedPayload: Data

    fileprivate init(
        direction: PairingFrameDirectionV1,
        sequence: UInt64,
        sealedPayload: Data
    ) {
        version = Self.currentVersion
        self.direction = direction
        self.sequence = sequence
        self.sealedPayload = sealedPayload
    }

    public func encoded() throws -> Data {
        guard version == Self.currentVersion else {
            throw PairingError.unsupportedFrameVersion(Int(version))
        }
        guard sealedPayload.count >= 12 + 16,
              sealedPayload.count <= Int(UInt32.max) else {
            throw PairingError.invalidFrame
        }
        var output = authenticatedHeader()
        output.append(sealedPayload)
        guard output.count <= Self.maximumEncodedBytes else {
            throw PairingError.messageTooLarge(
                actual: output.count,
                maximum: Self.maximumEncodedBytes
            )
        }
        return output
    }

    public static func decode(_ input: Data) throws -> PairingFrameV1 {
        let data = Data(input)
        guard data.count <= Self.maximumEncodedBytes else {
            throw PairingError.messageTooLarge(
                actual: data.count,
                maximum: Self.maximumEncodedBytes
            )
        }
        guard data.count >= Self.headerByteCount + 12 + 16,
              data.prefix(Self.magic.count) == Self.magic else {
            throw PairingError.invalidFrame
        }
        let version = data[Self.magic.count]
        guard version == Self.currentVersion else {
            throw PairingError.unsupportedFrameVersion(Int(version))
        }
        guard let direction = PairingFrameDirectionV1(
            rawValue: data[Self.magic.count + 1]
        ) else {
            throw PairingError.invalidFrame
        }
        let sequenceStart = Self.magic.count + 2
        let sequenceEnd = sequenceStart + 8
        let sequence = data.subdata(in: sequenceStart..<sequenceEnd).pairingUInt64BigEndian
        let lengthEnd = sequenceEnd + 4
        let declaredLength = Int(
            data.subdata(in: sequenceEnd..<lengthEnd).pairingUInt32BigEndian
        )
        guard declaredLength >= 12 + 16,
              data.count == Self.headerByteCount + declaredLength else {
            throw PairingError.invalidFrame
        }
        return PairingFrameV1(
            direction: direction,
            sequence: sequence,
            sealedPayload: data.dropFirst(Self.headerByteCount)
        )
    }

    func authenticatedHeader() -> Data {
        var output = Self.magic
        output.append(version)
        output.append(direction.rawValue)
        output.pairingAppendUInt64(sequence)
        output.pairingAppendUInt32(UInt32(sealedPayload.count))
        return output
    }
}

/// Purpose-bound result of a completed PairingHandshakeV1. It owns both
/// directional sequence spaces and enforces the generic envelope order:
/// decisions first, then transaction/completion (or abort at any time).
public final class PairingSessionV1: @unchecked Sendable {
    public let localRole: PairingRoleV1
    public let purpose: PairingPurpose
    public let offerID: UUID
    public let selectedPairingVersion: Int
    public let selectedTransactionVersion: Int
    public let transcriptHash: Data
    public let sas: PairingShortAuthenticationStringV1

    let transcript: Data
    let derivedMaterial: PairingDerivedMaterialV1

    private let lock = NSLock()
    private let channel: PairingFrameChannelV1
    private var localDecision: Bool?
    private var peerDecision: Bool?
    private var localCompletionSent = false
    private var peerCompletionReceived = false
    private var aborted = false
    private let expiresAt: Int64
    private let now: @Sendable () -> Int64

    init(
        localRole: PairingRoleV1,
        purpose: PairingPurpose,
        offerID: UUID,
        selectedPairingVersion: Int,
        selectedTransactionVersion: Int,
        transcript: Data,
        transcriptHash: Data,
        material: PairingDerivedMaterialV1,
        expiresAt: Int64,
        now: @escaping @Sendable () -> Int64
    ) throws {
        self.localRole = localRole
        self.purpose = purpose
        self.offerID = offerID
        self.selectedPairingVersion = selectedPairingVersion
        self.selectedTransactionVersion = selectedTransactionVersion
        self.transcript = transcript
        self.transcriptHash = transcriptHash
        derivedMaterial = material
        self.expiresAt = expiresAt
        self.now = now
        sas = try PairingShortAuthenticationStringV1(
            value: Int(material.sasBytes.pairingUInt64BigEndian % 1_000_000)
        )
        channel = PairingFrameChannelV1(
            localRole: localRole,
            transcriptHash: transcriptHash,
            material: material
        )
    }

    public var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return localCompletionSent && peerCompletionReceived && !aborted
    }

    /// True only while the purpose/version/transcript binding is approved by
    /// both peers and still available to carry transaction messages. A
    /// transaction coordinator must reject the session while this is false.
    public var isTransactionReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return localDecision == true
            && peerDecision == true
            && !localCompletionSent
            && !peerCompletionReceived
            && !aborted
            && now() < expiresAt
    }

    public func sealPeerDecision(matches: Bool) throws -> Data {
        try sealPeerDecision(matches: matches, currentTime: nil)
    }

    /// Internal deterministic clock override for conformance tests.
    func sealPeerDecision(
        matches: Bool,
        currentTime: Int64?
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireNotTerminal(currentTime: currentTime)
        guard localDecision == nil else { throw PairingError.peerDecisionAlreadySent }
        let frame = try channel.seal(
            PairingEnvelopeV1(kind: .peerDecision, payload: Data([matches ? 1 : 0]))
        )
        localDecision = matches
        return frame
    }

    public func sealTransactionMessage(_ payload: Data) throws -> Data {
        try sealTransactionMessage(payload, currentTime: nil)
    }

    /// Internal deterministic clock override for conformance tests.
    func sealTransactionMessage(
        _ payload: Data,
        currentTime: Int64?
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireReadyForTransaction(currentTime: currentTime)
        return try channel.seal(
            PairingEnvelopeV1(kind: .transactionMessage, payload: payload)
        )
    }

    public func sealAbort(_ payload: Data = Data()) throws -> Data {
        try sealAbort(payload, currentTime: nil)
    }

    /// Internal deterministic clock override for conformance tests.
    func sealAbort(
        _ payload: Data,
        currentTime: Int64?
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireNotTerminal(currentTime: currentTime)
        let frame = try channel.seal(PairingEnvelopeV1(kind: .abort, payload: payload))
        aborted = true
        return frame
    }

    public func sealCompletion(_ payload: Data = Data()) throws -> Data {
        try sealCompletion(payload, currentTime: nil)
    }

    /// Internal deterministic clock override for conformance tests.
    func sealCompletion(
        _ payload: Data,
        currentTime: Int64?
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try requireNotTerminal(currentTime: currentTime)
        try requireDecisionsConfirmed()
        guard !localCompletionSent else { throw PairingError.completionAlreadySent }
        let frame = try channel.seal(
            PairingEnvelopeV1(kind: .completion, payload: payload)
        )
        localCompletionSent = true
        return frame
    }

    /// Opens the next authenticated frame, enforces its direction and exact
    /// sequence, then advances the envelope state machine.
    @discardableResult
    public func open(_ encodedFrame: Data) throws -> PairingEnvelopeV1 {
        try open(encodedFrame, currentTime: nil)
    }

    /// Opens one transaction-layer frame and returns only its authenticated
    /// payload. A generic pairing abort is surfaced as `sessionAborted` so
    /// transaction coordinators cannot misclassify a peer cancellation as a
    /// transaction ordering error after the envelope sequence is consumed.
    public func openTransactionMessage(_ encodedFrame: Data) throws -> Data {
        let envelope = try open(encodedFrame)
        switch envelope.kind {
        case .transactionMessage:
            return envelope.payload
        case .abort:
            throw PairingError.sessionAborted
        case .peerDecision, .completion:
            throw PairingError.unexpectedMessageOrder
        }
    }

    /// Internal deterministic clock override for conformance tests.
    @discardableResult
    func open(
        _ encodedFrame: Data,
        currentTime: Int64?
    ) throws -> PairingEnvelopeV1 {
        lock.lock()
        defer { lock.unlock() }
        try requireNotTerminal(currentTime: currentTime)
        let envelope = try channel.open(encodedFrame)
        do {
            switch envelope.kind {
            case .peerDecision:
                guard peerDecision == nil else { throw PairingError.peerDecisionAlreadyReceived }
                guard !localCompletionSent, !peerCompletionReceived else {
                    throw PairingError.unexpectedMessageOrder
                }
                let matches = envelope.payload[0] == 1
                peerDecision = matches
            case .transactionMessage:
                try requireReadyForTransaction(currentTime: currentTime)
            case .abort:
                aborted = true
            case .completion:
                try requireDecisionsConfirmed()
                guard !peerCompletionReceived else {
                    throw PairingError.completionAlreadyReceived
                }
                guard !localCompletionSent || !peerCompletionReceived else {
                    throw PairingError.unexpectedMessageOrder
                }
                peerCompletionReceived = true
            }
        } catch {
            // An authenticated peer violating the generic envelope order makes
            // the session terminal. It cannot probe alternate orderings using
            // the same transcript and keys.
            aborted = true
            throw error
        }
        return envelope
    }

    private func requireDecisionsConfirmed() throws {
        if localDecision == false || peerDecision == false { throw PairingError.pairingRejected }
        guard localDecision == true, peerDecision == true else {
            throw PairingError.peerDecisionRequired
        }
    }

    private func requireReadyForTransaction(currentTime: Int64?) throws {
        try requireNotTerminal(currentTime: currentTime)
        try requireDecisionsConfirmed()
        guard !localCompletionSent, !peerCompletionReceived else {
            throw PairingError.unexpectedMessageOrder
        }
    }

    private func requireNotTerminal(currentTime: Int64?) throws {
        guard !aborted else { throw PairingError.sessionAborted }
        if localDecision == false || peerDecision == false { throw PairingError.pairingRejected }
        if localCompletionSent && peerCompletionReceived {
            throw PairingError.unexpectedMessageOrder
        }
        guard (currentTime ?? now()) < expiresAt else {
            aborted = true
            throw PairingError.offerExpired
        }
    }
}

final class PairingFrameChannelV1: @unchecked Sendable {
    private let lock = NSLock()
    private let transcriptHash: Data
    private let outgoingDirection: PairingFrameDirectionV1
    private let outgoingKey: SymmetricKey
    private let outgoingNonce: Data
    private let incomingKey: SymmetricKey
    private let incomingNonce: Data
    private var nextOutgoingSequence: UInt64 = 0
    private var nextIncomingSequence: UInt64 = 0

    init(
        localRole: PairingRoleV1,
        transcriptHash: Data,
        material: PairingDerivedMaterialV1
    ) {
        self.transcriptHash = transcriptHash
        switch localRole {
        case .origin:
            outgoingDirection = .originToRecipient
            outgoingKey = SymmetricKey(data: material.originToRecipientKey)
            outgoingNonce = material.originToRecipientNonce
            incomingKey = SymmetricKey(data: material.recipientToOriginKey)
            incomingNonce = material.recipientToOriginNonce
        case .recipient:
            outgoingDirection = .recipientToOrigin
            outgoingKey = SymmetricKey(data: material.recipientToOriginKey)
            outgoingNonce = material.recipientToOriginNonce
            incomingKey = SymmetricKey(data: material.originToRecipientKey)
            incomingNonce = material.originToRecipientNonce
        }
    }

    func seal(_ envelope: PairingEnvelopeV1) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard nextOutgoingSequence < UInt64.max else { throw PairingError.sequenceExhausted }
        let sequence = nextOutgoingSequence
        let plaintext = try envelope.encoded()
        let nonceData = try makeNonce(base: outgoingNonce, sequence: sequence)
        let nonce: ChaChaPoly.Nonce
        do {
            nonce = try ChaChaPoly.Nonce(data: nonceData)
        } catch {
            throw PairingError.invalidFrame
        }

        // Ciphertext length equals plaintext length, and the combined sealed
        // box adds the fixed 12-byte nonce and 16-byte tag.
        let placeholder = Data(count: plaintext.count + 12 + 16)
        let headerFrame = PairingFrameV1(
            direction: outgoingDirection,
            sequence: sequence,
            sealedPayload: placeholder
        )
        let sealedBox: ChaChaPoly.SealedBox
        do {
            sealedBox = try ChaChaPoly.seal(
                plaintext,
                using: outgoingKey,
                nonce: nonce,
                authenticating: authenticatedData(headerFrame.authenticatedHeader())
            )
        } catch {
            throw PairingError.authenticationFailed
        }
        let frame = PairingFrameV1(
            direction: outgoingDirection,
            sequence: sequence,
            sealedPayload: sealedBox.combined
        )
        let encoded = try frame.encoded()
        nextOutgoingSequence += 1
        return encoded
    }

    func open(_ encodedFrame: Data) throws -> PairingEnvelopeV1 {
        lock.lock()
        defer { lock.unlock() }
        let frame = try PairingFrameV1.decode(encodedFrame)
        guard frame.direction == outgoingDirection.peer else {
            throw PairingError.wrongDirection
        }
        if frame.sequence < nextIncomingSequence {
            throw PairingError.replayedFrame(frame.sequence)
        }
        guard frame.sequence == nextIncomingSequence else {
            throw PairingError.outOfOrder(
                expected: nextIncomingSequence,
                actual: frame.sequence
            )
        }
        let expectedNonce = try makeNonce(base: incomingNonce, sequence: frame.sequence)
        let sealedBox: ChaChaPoly.SealedBox
        do {
            sealedBox = try ChaChaPoly.SealedBox(combined: frame.sealedPayload)
        } catch {
            throw PairingError.invalidFrame
        }
        let actualNonce = sealedBox.nonce.withUnsafeBytes { Data($0) }
        guard actualNonce == expectedNonce else { throw PairingError.authenticationFailed }
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(
                sealedBox,
                using: incomingKey,
                authenticating: authenticatedData(frame.authenticatedHeader())
            )
        } catch {
            throw PairingError.authenticationFailed
        }
        let envelope = try PairingEnvelopeV1.decode(plaintext)
        nextIncomingSequence += 1
        return envelope
    }

    private func authenticatedData(_ header: Data) -> Data { header + transcriptHash }

    private func makeNonce(base: Data, sequence: UInt64) throws -> Data {
        guard base.count == 12 else { throw PairingError.invalidFrame }
        var bytes = Array(base)
        let sequenceBytes = sequence.pairingBigEndianBytes
        for index in 0..<8 {
            bytes[bytes.count - 8 + index] ^= sequenceBytes[index]
        }
        return Data(bytes)
    }
}
