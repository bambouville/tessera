import Foundation
import TesseraPairingCore
import TesseraSessionCore
import XCTest
@testable import TesseraEnrollmentCore

final class EnrollmentTransactionV1Tests: XCTestCase {
    private let now: Int64 = 1_700_000_000
    private let offerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func test_confirmedEnrollmentSessionConstructsExactVersionedBinding() throws {
        let sessions = try makeSessions(purpose: .enroll)
        try confirm(sessions)

        let origin = try EnrollmentTransactionV1(session: sessions.origin)
        let recipient = try EnrollmentTransactionV1(session: sessions.recipient)

        XCTAssertEqual(origin.transactionID, offerID)
        XCTAssertEqual(origin.localRole, .origin)
        XCTAssertEqual(recipient.localRole, .recipient)
        XCTAssertEqual(origin.purpose, .enroll)
        XCTAssertEqual(origin.selectedPairingVersion, PairingOfferV1.currentVersion)
        XCTAssertEqual(origin.selectedTransactionVersion, EnrollmentTransactionV1.currentVersion)
        XCTAssertEqual(origin.transcriptHash.count, EnrollmentTransactionV1.transcriptHashBytes)
        XCTAssertEqual(origin.transcriptHash, recipient.transcriptHash)
        let transcriptHashHex = origin.transcriptHash.map {
            String(format: "%02x", $0)
        }.joined()
        let actual: [String: Any] = [
            "pairingVersion": origin.selectedPairingVersion,
            "purpose": origin.purpose.rawValue,
            "transactionID": origin.transactionID.uuidString,
            "transactionVersion": origin.selectedTransactionVersion,
            "transcriptHashHex": transcriptHashHex,
        ]
        var expected = try transactionVector()
        expected.removeValue(forKey: "cancelledPairingFrameHex")
        XCTAssertEqual(actual as NSDictionary, expected as NSDictionary)
    }

    func test_unconfirmedSessionIsRejected() throws {
        let sessions = try makeSessions(purpose: .enroll)

        XCTAssertThrowsError(try EnrollmentTransactionV1(session: sessions.origin)) {
            XCTAssertEqual($0 as? EnrollmentTransactionError, .pairingNotReady)
        }
    }

    func test_wrongPurposeSessionIsRejectedEvenAfterConfirmation() throws {
        let sessions = try makeSessions(purpose: .continueSession)
        try confirm(sessions)

        XCTAssertThrowsError(try EnrollmentTransactionV1(session: sessions.origin)) {
            XCTAssertEqual($0 as? EnrollmentTransactionError, .wrongPurpose)
        }
    }

    func test_wrongNegotiatedTransactionVersionIsRejected() throws {
        let sessions = try makeSessions(
            purpose: .enroll,
            transactionVersions: [2]
        )
        try confirm(sessions)

        XCTAssertThrowsError(try EnrollmentTransactionV1(session: sessions.origin)) {
            XCTAssertEqual(
                $0 as? EnrollmentTransactionError,
                .unsupportedTransactionVersion(2)
            )
        }
    }

    func test_pairingTransactionCanConstructEnrollmentAuthority() async throws {
        let sessions = try makeSessions(purpose: .enroll)
        try confirm(sessions)
        let transaction = try EnrollmentTransactionV1(session: sessions.origin)
        let machine = try EnrollmentStateMachine(
            transaction: transaction,
            authorizer: TransactionOwnerAuthorizer(now: Date(timeIntervalSince1970: 1))
        )

        let state = await machine.state
        XCTAssertEqual(state, .idle)

        XCTAssertThrowsError(
            try EnrollmentStateMachine(
                transaction: transaction,
                authorizer: TransactionOwnerAuthorizer(now: Date(timeIntervalSince1970: 1))
            )
        ) {
            XCTAssertEqual(
                $0 as? EnrollmentTransactionError,
                .transactionAlreadyConsumed
            )
        }
    }

    func test_sessionThatStopsBeingReadyCannotEnterEnrollment() throws {
        let sessions = try makeSessions(purpose: .enroll)
        try confirm(sessions)
        let transaction = try EnrollmentTransactionV1(session: sessions.origin)
        _ = try sessions.origin.sealCompletion()

        XCTAssertThrowsError(
            try EnrollmentStateMachine(
                transaction: transaction,
                authorizer: TransactionOwnerAuthorizer(now: Date(timeIntervalSince1970: 1))
            )
        ) {
            XCTAssertEqual($0 as? EnrollmentTransactionError, .pairingNotReady)
        }
    }

    func test_enrollmentMessagesAreBoundToTheExactPairingChannel() async throws {
        let sessions = try makeSessions(purpose: .enroll)
        try confirm(sessions)
        let originTransaction = try EnrollmentTransactionV1(session: sessions.origin)
        let recipientTransaction = try EnrollmentTransactionV1(session: sessions.recipient)
        _ = try EnrollmentStateMachine(
            transaction: originTransaction,
            authorizer: TransactionOwnerAuthorizer(now: Date(timeIntervalSince1970: 1))
        )
        _ = try EnrollmentStateMachine(
            transaction: recipientTransaction,
            authorizer: TransactionOwnerAuthorizer(now: Date(timeIntervalSince1970: 1))
        )
        let message = EnrollmentMessageV1.cancelled(enrollmentID: offerID)
        let frame = try originTransaction.seal(message)
        let frameHex = frame.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            frameHex,
            try transactionVector()["cancelledPairingFrameHex"] as? String
        )
        XCTAssertEqual(try recipientTransaction.open(frame), message)

        let unrelatedSessions = try makeSessions(
            purpose: .enroll,
            offerID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        try confirm(unrelatedSessions)
        let unrelatedTransaction = try EnrollmentTransactionV1(
            session: unrelatedSessions.recipient
        )
        _ = try EnrollmentStateMachine(
            transaction: unrelatedTransaction,
            authorizer: TransactionOwnerAuthorizer(now: Date(timeIntervalSince1970: 1))
        )
        XCTAssertThrowsError(try unrelatedTransaction.open(frame))
    }

    func test_pairingWireSeamRejectsUseBeforeStateMachineActivation() throws {
        let sessions = try makeSessions(purpose: .enroll)
        try confirm(sessions)
        let transaction = try EnrollmentTransactionV1(session: sessions.origin)

        XCTAssertThrowsError(
            try transaction.seal(.cancelled(enrollmentID: offerID))
        ) {
            XCTAssertEqual($0 as? EnrollmentTransactionError, .transactionNotActivated)
        }
    }

    private func makeSessions(
        purpose: PairingPurpose,
        offerID: UUID? = nil,
        transactionVersions: [Int] = [1]
    ) throws -> (origin: PairingSessionV1, recipient: PairingSessionV1) {
        let originAttempt = try PairingHandshakeV1.beginOrigin(
            purpose: purpose,
            offerID: offerID ?? self.offerID,
            currentTime: now,
            expiresAt: now + 300,
            endpointCandidates: [],
            oneTimeOpticalSecret: Data((0xA0...0xBF).map(UInt8.init)),
            supportedTransactionVersions: transactionVersions,
            deterministicPrivateKey: Data((0..<32).map(UInt8.init))
        )
        let recipientAttempt = try PairingHandshakeV1.beginRecipient(
            encodedOffer: originAttempt.encodedOffer,
            currentTime: now,
            supportedTransactionVersions: transactionVersions,
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: Data((32..<64).map(UInt8.init))
        )
        let disclosure = try originAttempt.reveal(after: recipientAttempt.encodedCommitment)
        let recipientCompletion = try recipientAttempt.complete(with: disclosure.encodedHello)
        return (
            try originAttempt.complete(with: recipientCompletion.encodedHello),
            recipientCompletion.session
        )
    }

    private func confirm(
        _ sessions: (origin: PairingSessionV1, recipient: PairingSessionV1)
    ) throws {
        try sessions.recipient.open(sessions.origin.sealPeerDecision(matches: true))
        try sessions.origin.open(sessions.recipient.sealPeerDecision(matches: true))
    }

    private func transactionVector() throws -> [String: Any] {
        let vectorURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(
                "../../../../ProtocolVectors/enrollment/v1/pairing-transaction.json"
            )
            .standardizedFileURL
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL)) as? [String: Any]
        )
    }
}

private struct TransactionOwnerAuthorizer: FreshOwnerAuthorizing {
    let now: Date

    func authorize(_ request: OwnerAuthorizationRequest) async throws -> FreshOwnerAuthorization {
        FreshOwnerAuthorization(
            attemptID: request.attemptID,
            policyGeneration: request.policyGeneration,
            scope: request.scope,
            issuedAt: now,
            expiresAt: request.expiresAt
        )
    }
}
