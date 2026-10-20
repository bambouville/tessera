import Foundation
import TesseraPairingCore

/// Authentication claim supplied by a platform byte-transport adapter.
///
/// The released Apple continuation-stream path is represented directly. A
/// Pairing v1 path cannot manufacture this claim from transcript bytes; it must
/// construct an `EnrollmentTransactionV1` from a live, purpose-bound, confirmed
/// `PairingSessionV1` instead.
public struct PeerBinding: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case appleAccountContinuationStream
        case pairingV1(
            offerID: UUID,
            transcriptHash: Data,
            purpose: PairingPurpose,
            pairingVersion: Int,
            transactionVersion: Int
        )
        case unbound
    }

    let kind: Kind

    private init(kind: Kind) {
        self.kind = kind
    }

    public static let appleAccountContinuationStream = PeerBinding(
        kind: .appleAccountContinuationStream
    )
    public static let unbound = PeerBinding(kind: .unbound)

    static func pairingV1(
        offerID: UUID,
        transcriptHash: Data,
        purpose: PairingPurpose,
        pairingVersion: Int,
        transactionVersion: Int
    ) -> PeerBinding {
        PeerBinding(kind: .pairingV1(
            offerID: offerID,
            transcriptHash: transcriptHash,
            purpose: purpose,
            pairingVersion: pairingVersion,
            transactionVersion: transactionVersion
        ))
    }

    public var allowsEnrollment: Bool {
        switch kind {
        case .appleAccountContinuationStream:
            return true
        case .pairingV1(
            _, let transcriptHash, let purpose, let pairingVersion, let transactionVersion
        ):
            return transcriptHash.count == EnrollmentTransactionV1.transcriptHashBytes
                && purpose == .enroll
                && pairingVersion == PairingOfferV1.currentVersion
                && transactionVersion == EnrollmentTransactionV1.currentVersion
        case .unbound:
            return false
        }
    }
}
