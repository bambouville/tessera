import Foundation
import TesseraPairingCore

public enum EnrollmentTransactionError: Error, Equatable, Sendable {
    case unsupportedPairingVersion(Int)
    case unsupportedTransactionVersion(Int)
    case wrongPurpose
    case invalidTranscriptHashLength(Int)
    case pairingNotReady
    case transactionAlreadyConsumed
    case transactionNotActivated
    case unexpectedPairingEnvelope(PairingEnvelopeKindV1)
    case invalidEnrollmentPayload
}

/// Unforgeable enrollment authority derived from a live Pairing v1 session.
///
/// There is deliberately no public memberwise or transcript-based initializer.
/// A caller must possess the completed handshake object, with both peers having
/// confirmed the SAS and the session still ready for transaction traffic.
public final class EnrollmentTransactionV1: @unchecked Sendable {
    public static let currentVersion = 1
    public static let transcriptHashBytes = 32

    public let transactionID: UUID
    public let localRole: PairingRoleV1
    public let transcriptHash: Data
    public let purpose: PairingPurpose
    public let selectedPairingVersion: Int
    public let selectedTransactionVersion: Int

    private let lock = NSLock()
    private let session: PairingSessionV1
    private var consumed = false

    public init(session: PairingSessionV1) throws {
        guard session.selectedPairingVersion == PairingOfferV1.currentVersion else {
            throw EnrollmentTransactionError.unsupportedPairingVersion(
                session.selectedPairingVersion
            )
        }
        guard session.selectedTransactionVersion == Self.currentVersion else {
            throw EnrollmentTransactionError.unsupportedTransactionVersion(
                session.selectedTransactionVersion
            )
        }
        guard session.purpose == .enroll else {
            throw EnrollmentTransactionError.wrongPurpose
        }
        guard session.transcriptHash.count == Self.transcriptHashBytes else {
            throw EnrollmentTransactionError.invalidTranscriptHashLength(
                session.transcriptHash.count
            )
        }
        guard session.isTransactionReady else {
            throw EnrollmentTransactionError.pairingNotReady
        }

        transactionID = session.offerID
        localRole = session.localRole
        transcriptHash = session.transcriptHash
        purpose = session.purpose
        selectedPairingVersion = session.selectedPairingVersion
        selectedTransactionVersion = session.selectedTransactionVersion
        self.session = session
    }

    func consumePeerBinding() throws -> PeerBinding {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else {
            throw EnrollmentTransactionError.transactionAlreadyConsumed
        }
        guard session.isTransactionReady else {
            throw EnrollmentTransactionError.pairingNotReady
        }
        consumed = true
        return .pairingV1(
            offerID: session.offerID,
            transcriptHash: session.transcriptHash,
            purpose: session.purpose,
            pairingVersion: session.selectedPairingVersion,
            transactionVersion: session.selectedTransactionVersion
        )
    }

    /// Seals one complete Enrollment v1 message inside the authenticated
    /// Pairing v1 transaction channel. Cross-platform adapters must send these
    /// bytes, never a raw `EnrollmentFrameCodecV1` frame.
    public func seal(_ message: EnrollmentMessageV1) throws -> Data {
        try requireActivated()
        return try session.sealTransactionMessage(
            EnrollmentFrameCodecV1.encode(message)
        )
    }

    /// Opens one complete authenticated Pairing v1 frame and returns its sole
    /// Enrollment v1 message. Byte-stream adapters must first assemble exact
    /// PairingFrameV1 boundaries before calling this method.
    public func open(_ authenticatedFrame: Data) throws -> EnrollmentMessageV1 {
        try requireActivated()
        let payload = try session.openTransactionMessage(authenticatedFrame)
        guard payload.count >= EnrollmentFrameCodecV1.headerBytes else {
            throw EnrollmentTransactionError.invalidEnrollmentPayload
        }
        let declaredLength = payload
            .prefix(EnrollmentFrameCodecV1.headerBytes)
            .reduce(0) { ($0 << 8) | Int($1) }
        guard payload.count == EnrollmentFrameCodecV1.headerBytes + declaredLength else {
            throw EnrollmentTransactionError.invalidEnrollmentPayload
        }
        var decoder = EnrollmentFrameDecoderV1()
        let messages = try decoder.append(payload)
        guard messages.count == 1 else {
            throw EnrollmentTransactionError.invalidEnrollmentPayload
        }
        return messages[0]
    }

    private func requireActivated() throws {
        lock.lock()
        defer { lock.unlock() }
        guard consumed else {
            throw EnrollmentTransactionError.transactionNotActivated
        }
        guard session.isTransactionReady else {
            throw EnrollmentTransactionError.pairingNotReady
        }
    }
}
