import Foundation
import TesseraPairingCore
import TesseraProtocolCore
@testable import TesseraContinuityCore
import XCTest

final class ContinuationTransactionV1Tests: XCTestCase {
    private let offerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    func testEncryptedTransactionCompletesOnlyAfterConnectionAndAcknowledgement() throws {
        let paired = try sessions(confirm: true)
        let observer = try sessions(confirm: true)
        var origin = try ContinuationTransactionV1(session: paired.origin)
        var recipient = try ContinuationTransactionV1(session: paired.recipient)
        let descriptor = fixtureDescriptor()

        let descriptorFrame = try origin.makeDescriptor(descriptor)
        XCTAssertNoThrow(try PairingFrameV1.decode(descriptorFrame))
        let descriptorMessage = try observer.recipient.open(descriptorFrame).payload
        XCTAssertEqual(try recipient.receiveDescriptor(descriptorFrame), descriptor)

        let acceptanceFrame = try recipient.descriptorDurablyAccepted(at: instant)
        let acceptanceMessage = try observer.origin.open(acceptanceFrame).payload
        XCTAssertEqual(
            try origin.receiveAcceptance(acceptanceFrame).action,
            .continueSession
        )

        XCTAssertThrowsError(
            try recipient.receiveCompletionAcknowledgement(Data())
        ) { XCTAssertEqual($0 as? ContinuationTransactionError, .invalidTransition) }

        let connectionFrame = try recipient.connectionCompleted(
            hostID: descriptor.hostID,
            at: instant
        )
        let connectionMessage = try observer.origin.open(connectionFrame).payload
        let acknowledgementFrame = try origin.receiveConnectionReceipt(connectionFrame)
        let acknowledgementMessage = try observer.recipient.open(acknowledgementFrame).payload
        let receipt = try recipient.receiveCompletionAcknowledgement(
            acknowledgementFrame
        )
        XCTAssertEqual(origin.state, .completed(receipt))
        XCTAssertEqual(recipient.state, .completed(receipt))
        XCTAssertThrowsError(try origin.abort(code: "late_abort")) {
            XCTAssertEqual($0 as? ContinuationTransactionError, .invalidTransition)
        }
        XCTAssertThrowsError(try recipient.abort(code: "late_abort")) {
            XCTAssertEqual($0 as? ContinuationTransactionError, .invalidTransition)
        }

        let vectorData = try Data(
            contentsOf: vectorURL("continuation-transaction/v1/canonical.json")
        )
        let expectedVector = try XCTUnwrap(
            JSONSerialization.jsonObject(with: vectorData) as? [String: String]
        )
        let actualVector: [String: String] = [
            "descriptorMessageBase64": descriptorMessage.base64EncodedString(),
            "acceptanceMessageBase64": acceptanceMessage.base64EncodedString(),
            "connectionMessageBase64": connectionMessage.base64EncodedString(),
            "completionAcknowledgementMessageBase64": acknowledgementMessage.base64EncodedString(),
        ]
        XCTAssertEqual(actualVector, expectedVector)
        for encoded in expectedVector.values {
            let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
            let message = try ContinuationTransactionMessageV1.decode(bytes)
            XCTAssertEqual(try message.encoded(), bytes)
        }
    }

    func testTransactionCannotStartBeforePositivePeerDecision() throws {
        let unconfirmed = try sessions(confirm: false)
        XCTAssertThrowsError(try ContinuationTransactionV1(session: unconfirmed.origin)) {
            XCTAssertEqual($0 as? ContinuationTransactionError, .invalidTransition)
        }
        XCTAssertThrowsError(try ContinuationTransactionV1(session: unconfirmed.recipient)) {
            XCTAssertEqual($0 as? ContinuationTransactionError, .invalidTransition)
        }
    }

    func testAbortIsValidatedPropagatedAndTerminal() throws {
        let paired = try sessions(confirm: true)
        var origin = try ContinuationTransactionV1(session: paired.origin)
        var recipient = try ContinuationTransactionV1(session: paired.recipient)
        let rejection = try rejectionVector()

        for code in try XCTUnwrap(rejection["invalidAbortCodes"] as? [String]) {
            XCTAssertThrowsError(try origin.abort(code: code)) {
                XCTAssertEqual($0 as? ContinuationTransactionError, .invalidAbort)
            }
        }
        let validCode = try XCTUnwrap(rejection["validAbortCode"] as? String)
        let message = try origin.abort(code: validCode)
        XCTAssertEqual(try recipient.receiveAbort(message).code, validCode)
        XCTAssertEqual(origin.state, .aborted(validCode))
        XCTAssertEqual(recipient.state, .aborted(validCode))
        XCTAssertThrowsError(try recipient.receiveAbort(message)) {
            XCTAssertEqual($0 as? ContinuationTransactionError, .invalidTransition)
        }
    }

    func testAbortReceivedThroughExpectedOperationIsSurfacedWithoutMisclassification() throws {
        let paired = try sessions(confirm: true)
        var origin = try ContinuationTransactionV1(session: paired.origin)
        var recipient = try ContinuationTransactionV1(session: paired.recipient)
        let abort = try origin.abort(code: "peer_cancelled")

        XCTAssertThrowsError(try recipient.receiveDescriptor(abort)) {
            XCTAssertEqual(
                $0 as? ContinuationTransactionError,
                .remoteAbort("peer_cancelled")
            )
        }
        XCTAssertEqual(recipient.state, .aborted("peer_cancelled"))
    }

    func testTransactionRejectsRawAndUnrelatedPairingTraffic() throws {
        let exact = try sessions(confirm: true)
        let unrelated = try sessions(
            confirm: true,
            originPrivateKey: Data((64..<96).map(UInt8.init)),
            recipientPrivateKey: Data((96..<128).map(UInt8.init))
        )
        var origin = try ContinuationTransactionV1(session: exact.origin)
        var exactRecipient = try ContinuationTransactionV1(session: exact.recipient)
        var unrelatedRecipient = try ContinuationTransactionV1(session: unrelated.recipient)
        let descriptor = fixtureDescriptor()

        let raw = try ContinuationTransactionMessageV1(
            transactionID: offerID,
            kind: .descriptor,
            payload: descriptor.encoded()
        ).encoded()
        XCTAssertThrowsError(try exactRecipient.receiveDescriptor(raw)) {
            XCTAssertEqual($0 as? PairingError, .invalidFrame)
        }

        let frame = try origin.makeDescriptor(descriptor)
        XCTAssertThrowsError(try unrelatedRecipient.receiveDescriptor(frame)) {
            XCTAssertEqual($0 as? PairingError, .authenticationFailed)
        }
        XCTAssertEqual(try exactRecipient.receiveDescriptor(frame), descriptor)
    }

    func testTransactionChannelRejectsDirectionAndReplay() throws {
        let directionSessions = try sessions(confirm: true)
        var directionRecipient = try ContinuationTransactionV1(
            session: directionSessions.recipient
        )
        let wrongDirection = try directionSessions.recipient.sealTransactionMessage(Data("bad".utf8))
        XCTAssertThrowsError(try directionRecipient.receiveDescriptor(wrongDirection)) {
            XCTAssertEqual($0 as? PairingError, .wrongDirection)
        }

        let replaySessions = try sessions(confirm: true)
        var replayRecipient = try ContinuationTransactionV1(session: replaySessions.recipient)
        let malformed = try replaySessions.origin.sealTransactionMessage(Data("bad".utf8))
        XCTAssertThrowsError(try replayRecipient.receiveDescriptor(malformed)) {
            XCTAssertEqual($0 as? ContinuationTransactionError, .malformedMessage)
        }
        XCTAssertThrowsError(try replayRecipient.receiveDescriptor(malformed)) {
            XCTAssertEqual($0 as? PairingError, .replayedFrame(1))
        }
    }

    private func sessions(
        confirm: Bool,
        originPrivateKey: Data = Data((0..<32).map(UInt8.init)),
        recipientPrivateKey: Data = Data((32..<64).map(UInt8.init))
    ) throws -> (origin: PairingSessionV1, recipient: PairingSessionV1) {
        let originAttempt = try PairingHandshakeV1.beginOrigin(
            purpose: .continueSession,
            offerID: offerID,
            currentTime: 1_700_000_000,
            expiresAt: 1_700_000_300,
            endpointCandidates: [],
            oneTimeOpticalSecret: Data((0xA0...0xBF).map(UInt8.init)),
            supportedTransactionVersions: [1],
            deterministicPrivateKey: originPrivateKey
        )
        let recipientAttempt = try PairingHandshakeV1.beginRecipient(
            encodedOffer: originAttempt.encodedOffer,
            currentTime: 1_700_000_000,
            supportedTransactionVersions: [1],
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: recipientPrivateKey
        )
        let disclosure = try originAttempt.reveal(after: recipientAttempt.encodedCommitment)
        let recipientCompletion = try recipientAttempt.complete(with: disclosure.encodedHello)
        let originSession = try originAttempt.complete(with: recipientCompletion.encodedHello)
        let recipientSession = recipientCompletion.session
        if confirm {
            try recipientSession.open(originSession.sealPeerDecision(matches: true))
            try originSession.open(recipientSession.sealPeerDecision(matches: true))
        }
        return (originSession, recipientSession)
    }

    private func fixtureDescriptor() -> ContinuationDescriptorV1 {
        ContinuationDescriptorV1(
            endpoint: ContinuationEndpointV1(
                hostID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                name: "production",
                user: "alice",
                address: "server.example",
                port: 2222,
                transport: .mosh,
                hostKeyFingerprint: "SHA256:destination"
            ),
            launchMode: .pinnedTmux,
            tmuxSessionName: "dev"
        )
    }

    private func vectorURL(_ relativePath: String) -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("ProtocolVectors").appendingPathComponent(relativePath)
    }

    private func rejectionVector() throws -> [String: Any] {
        let data = try Data(
            contentsOf: vectorURL("continuation-transaction/v1/rejections.json")
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
