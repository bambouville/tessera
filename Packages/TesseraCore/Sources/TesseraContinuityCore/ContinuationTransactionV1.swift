import Crypto
import Foundation
import TesseraPairingCore
import TesseraProtocolCore

public enum ContinuationTransactionMessageKindV1: String, Codable, CaseIterable, Sendable {
    case descriptor
    case accepted
    case connected
    case completionAcknowledgement
    case abort
}

public struct ContinuationTransactionMessageV1: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumEncodedBytes = 8 * 1_024

    public let version: Int
    public let transactionID: UUID
    public let kind: ContinuationTransactionMessageKindV1
    public let payload: Data

    public init(
        version: Int = ContinuationTransactionMessageV1.currentVersion,
        transactionID: UUID,
        kind: ContinuationTransactionMessageKindV1,
        payload: Data
    ) {
        self.version = version
        self.transactionID = transactionID
        self.kind = kind
        self.payload = payload
    }

    public func encoded() throws -> Data {
        guard version == Self.currentVersion else {
            throw ContinuationTransactionError.unsupportedVersion(version)
        }
        let data = try ContinuationTransactionCodec.encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw ContinuationTransactionError.messageTooLarge(data.count)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw ContinuationTransactionError.messageTooLarge(data.count)
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw ContinuationTransactionError.malformedMessage }
        guard let root = object as? [String: Any],
              Set(root.keys).isSubset(of: ["version", "transactionID", "kind", "payload"]) else {
            throw ContinuationTransactionError.malformedMessage
        }
        let value: Self = try ContinuationTransactionCodec.decode(data)
        guard value.version == currentVersion else {
            throw ContinuationTransactionError.unsupportedVersion(value.version)
        }
        guard try value.encoded() == data else {
            throw ContinuationTransactionError.nonCanonicalMessage
        }
        return value
    }
}

public struct ContinuationAcceptanceV1: Codable, Equatable, Sendable {
    public let descriptorHash: Data
    public let hostID: UUID
    public let action: ContinuationAction
    public let durableAt: Date

    public init(
        descriptorHash: Data,
        hostID: UUID,
        action: ContinuationAction,
        durableAt: Date
    ) {
        self.descriptorHash = descriptorHash
        self.hostID = hostID
        self.action = action
        self.durableAt = durableAt
    }
}

public struct ContinuationConnectionReceiptV1: Codable, Equatable, Sendable {
    public let descriptorHash: Data
    public let hostID: UUID
    public let action: ContinuationAction
    public let connectedAt: Date

    public init(
        descriptorHash: Data,
        hostID: UUID,
        action: ContinuationAction,
        connectedAt: Date
    ) {
        self.descriptorHash = descriptorHash
        self.hostID = hostID
        self.action = action
        self.connectedAt = connectedAt
    }
}

public struct ContinuationCompletionAcknowledgementV1: Codable, Equatable, Sendable {
    public let connectionReceiptHash: Data

    public init(connectionReceiptHash: Data) {
        self.connectionReceiptHash = connectionReceiptHash
    }
}

public struct ContinuationTransactionAbortV1: Codable, Equatable, Sendable {
    public let code: String

    public init(code: String) { self.code = code }
}

public enum ContinuationTransactionStateV1: Equatable, Sendable {
    case readyToSend
    case awaitingDescriptor
    case awaitingAcceptance(ContinuationDescriptorV1)
    case awaitingDurableAcceptance(ContinuationDescriptorV1)
    case awaitingConnection(ContinuationDescriptorV1)
    case awaitingCompletionAcknowledgement(ContinuationConnectionReceiptV1)
    case completed(ContinuationConnectionReceiptV1)
    case aborted(String)

    fileprivate var isTerminal: Bool {
        switch self {
        case .completed, .aborted: return true
        default: return false
        }
    }
}

public enum ContinuationTransactionError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case wrongPurpose
    case invalidTransition
    case wrongTransaction
    case malformedMessage
    case nonCanonicalMessage
    case messageTooLarge(Int)
    case descriptorMismatch
    case receiptMismatch
    case invalidAbort
    case remoteAbort(String)
    case unexpectedPairingEnvelope(PairingEnvelopeKindV1)
}

/// New QR/pairing transaction. Apple Handoff remains a direct adapter into
/// ContinuationReceiveStateMachine and does not pass through this wire epoch.
public struct ContinuationTransactionV1: Sendable {
    public static let currentVersion = 1

    public let transactionID: UUID
    public let localRole: PairingRoleV1
    public let transcriptHash: Data
    public private(set) var state: ContinuationTransactionStateV1

    private let session: PairingSessionV1
    private var descriptorHash: Data?

    public init(session: PairingSessionV1) throws {
        // Transaction profile v2 changes only bootstrap in the combined flow.
        // Its continuation leg still emits/accepts strictly v1 messages.
        guard session.selectedTransactionVersion == Self.currentVersion ||
              (session.purpose == .setUpAndContinue && session.selectedTransactionVersion == 2) else {
            throw ContinuationTransactionError.unsupportedVersion(
                session.selectedTransactionVersion
            )
        }
        guard session.purpose == .continueSession || session.purpose == .setUpAndContinue else {
            throw ContinuationTransactionError.wrongPurpose
        }
        guard session.isTransactionReady else {
            throw ContinuationTransactionError.invalidTransition
        }
        transactionID = session.offerID
        localRole = session.localRole
        transcriptHash = session.transcriptHash
        state = localRole == .origin ? .readyToSend : .awaitingDescriptor
        self.session = session
    }

    public mutating func makeDescriptor(_ descriptor: ContinuationDescriptorV1) throws -> Data {
        guard localRole == .origin, state == .readyToSend else {
            throw ContinuationTransactionError.invalidTransition
        }
        let bytes = try descriptor.encoded()
        let hash = Self.digest(bytes)
        let frame = try message(.descriptor, payload: bytes)
        descriptorHash = hash
        state = .awaitingAcceptance(descriptor)
        return frame
    }

    public mutating func receiveDescriptor(_ data: Data) throws -> ContinuationDescriptorV1 {
        guard localRole == .recipient, state == .awaitingDescriptor else {
            throw ContinuationTransactionError.invalidTransition
        }
        let bytes = try receive(data, kind: .descriptor)
        let descriptor = try ContinuationDescriptorV1(encoded: bytes)
        descriptorHash = Self.digest(bytes)
        state = .awaitingDurableAcceptance(descriptor)
        return descriptor
    }

    /// Called only after host admission and any required credential record are
    /// durable. It does not claim a connection exists yet.
    public mutating func descriptorDurablyAccepted(at date: Date) throws -> Data {
        guard localRole == .recipient,
              case .awaitingDurableAcceptance(let descriptor) = state,
              let descriptorHash else {
            throw ContinuationTransactionError.invalidTransition
        }
        let acceptance = ContinuationAcceptanceV1(
            descriptorHash: descriptorHash,
            hostID: descriptor.hostID,
            action: descriptor.continuationAction,
            durableAt: date
        )
        let frame = try message(.accepted, body: acceptance)
        state = .awaitingConnection(descriptor)
        return frame
    }

    public mutating func receiveAcceptance(_ data: Data) throws -> ContinuationAcceptanceV1 {
        guard localRole == .origin,
              case .awaitingAcceptance(let descriptor) = state,
              let descriptorHash else {
            throw ContinuationTransactionError.invalidTransition
        }
        let acceptance: ContinuationAcceptanceV1 = try receiveBody(data, kind: .accepted)
        guard acceptance.descriptorHash == descriptorHash,
              acceptance.hostID == descriptor.hostID,
              acceptance.action == descriptor.continuationAction else {
            throw ContinuationTransactionError.descriptorMismatch
        }
        state = .awaitingConnection(descriptor)
        return acceptance
    }

    /// Completion is emitted only after the destination independently connects
    /// and, for tmux modes, attaches the exact advertised rendezvous.
    public mutating func connectionCompleted(hostID: UUID, at date: Date) throws -> Data {
        guard localRole == .recipient,
              case .awaitingConnection(let descriptor) = state,
              let descriptorHash,
              descriptor.hostID == hostID else {
            throw ContinuationTransactionError.invalidTransition
        }
        let receipt = ContinuationConnectionReceiptV1(
            descriptorHash: descriptorHash,
            hostID: hostID,
            action: descriptor.continuationAction,
            connectedAt: date
        )
        let frame = try message(.connected, body: receipt)
        state = .awaitingCompletionAcknowledgement(receipt)
        return frame
    }

    public mutating func receiveConnectionReceipt(_ data: Data) throws -> Data {
        guard localRole == .origin,
              case .awaitingConnection(let descriptor) = state,
              let descriptorHash else {
            throw ContinuationTransactionError.invalidTransition
        }
        let receipt: ContinuationConnectionReceiptV1 = try receiveBody(data, kind: .connected)
        guard receipt.descriptorHash == descriptorHash,
              receipt.hostID == descriptor.hostID,
              receipt.action == descriptor.continuationAction else {
            throw ContinuationTransactionError.receiptMismatch
        }
        let receiptHash = try Self.canonicalDigest(receipt)
        let frame = try message(
            .completionAcknowledgement,
            body: ContinuationCompletionAcknowledgementV1(
                connectionReceiptHash: receiptHash
            )
        )
        state = .completed(receipt)
        return frame
    }

    public mutating func receiveCompletionAcknowledgement(
        _ data: Data
    ) throws -> ContinuationConnectionReceiptV1 {
        guard localRole == .recipient,
              case .awaitingCompletionAcknowledgement(let receipt) = state else {
            throw ContinuationTransactionError.invalidTransition
        }
        let acknowledgement: ContinuationCompletionAcknowledgementV1 = try receiveBody(
            data,
            kind: .completionAcknowledgement
        )
        guard acknowledgement.connectionReceiptHash == (try Self.canonicalDigest(receipt)) else {
            throw ContinuationTransactionError.receiptMismatch
        }
        state = .completed(receipt)
        return receipt
    }

    public mutating func abort(code: String) throws -> Data {
        guard !state.isTerminal else { throw ContinuationTransactionError.invalidTransition }
        try Self.validateAbortCode(code)
        let frame = try message(.abort, body: ContinuationTransactionAbortV1(code: code))
        state = .aborted(code)
        return frame
    }

    @discardableResult
    public mutating func receiveAbort(_ data: Data) throws -> ContinuationTransactionAbortV1 {
        guard !state.isTerminal else { throw ContinuationTransactionError.invalidTransition }
        let abort: ContinuationTransactionAbortV1 = try receiveBody(data, kind: .abort)
        try Self.validateAbortCode(abort.code)
        state = .aborted(abort.code)
        return abort
    }

    private func message(
        _ kind: ContinuationTransactionMessageKindV1,
        payload: Data
    ) throws -> Data {
        let inner = try ContinuationTransactionMessageV1(
            transactionID: transactionID,
            kind: kind,
            payload: payload
        ).encoded()
        return try session.sealTransactionMessage(inner)
    }

    private func message<Body: Codable>(
        _ kind: ContinuationTransactionMessageKindV1,
        body: Body
    ) throws -> Data {
        try message(kind, payload: ContinuationTransactionCodec.encode(body))
    }

    private mutating func receive(
        _ data: Data,
        kind: ContinuationTransactionMessageKindV1
    ) throws -> Data {
        let payload = try session.openTransactionMessage(data)
        let message = try ContinuationTransactionMessageV1.decode(payload)
        guard message.transactionID == transactionID else {
            throw ContinuationTransactionError.wrongTransaction
        }
        if message.kind == .abort, kind != .abort {
            let abort: ContinuationTransactionAbortV1 = try ContinuationTransactionCodec.decode(
                message.payload
            )
            try Self.validateAbortCode(abort.code)
            state = .aborted(abort.code)
            throw ContinuationTransactionError.remoteAbort(abort.code)
        }
        guard message.kind == kind else {
            throw ContinuationTransactionError.invalidTransition
        }
        return message.payload
    }

    private mutating func receiveBody<Body: Codable>(
        _ data: Data,
        kind: ContinuationTransactionMessageKindV1
    ) throws -> Body {
        let bytes = try receive(data, kind: kind)
        let value: Body = try ContinuationTransactionCodec.decode(bytes)
        guard try ContinuationTransactionCodec.encode(value) == bytes else {
            throw ContinuationTransactionError.nonCanonicalMessage
        }
        return value
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private static func canonicalDigest<T: Codable>(_ value: T) throws -> Data {
        digest(try ContinuationTransactionCodec.encode(value))
    }

    private static func validateAbortCode(_ code: String) throws {
        guard !code.isEmpty,
              code.utf8.count <= 128,
              code.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ContinuationTransactionError.invalidAbort
        }
    }
}

private enum ContinuationTransactionCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(value) }
        catch { throw ContinuationTransactionError.malformedMessage }
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try decoder.decode(T.self, from: data) }
        catch { throw ContinuationTransactionError.malformedMessage }
    }
}
