import Foundation
@testable import TesseraPairingCore
import TesseraBootstrapCore
import TesseraContinuityCore
import XCTest

final class PairingStreamDriverV1Tests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var value: Int64
        init(_ value: Int64) { self.value = value }
    }

    private func makeOrigin(
        purpose: PairingPurpose = .continueSession,
        clock: Clock? = nil
    ) throws -> PairingOriginDriverV1 {
        let now = clock?.value ?? PairingHandshakeV1.unixTimeNow()
        return try PairingOriginDriverV1(
            configuration: PairingOriginDriverConfigurationV1(
                purpose: purpose,
                expiresAt: now + 300,
                endpointCandidates: [PairingEndpointCandidateV1(host: "192.0.2.44", port: 4_444)],
                oneTimeOpticalSecret: Data(repeating: 0xA5, count: 32)
            ),
            now: { clock?.value ?? PairingHandshakeV1.unixTimeNow() }
        )
    }

    private func makeRecipient(
        _ origin: PairingOriginDriverV1,
        clock: Clock? = nil,
        store: PairingOfferConsumptionStoreV1 = PairingOfferConsumptionStoreV1()
    ) throws -> PairingRecipientDriverV1 {
        try PairingRecipientDriverV1(
            configuration: PairingRecipientDriverConfigurationV1(
                encodedOffer: origin.offerBytes,
                consumptionStore: store
            ),
            now: { clock?.value ?? PairingHandshakeV1.unixTimeNow() }
        )
    }

    @discardableResult
    private func handshake(
        purpose: PairingPurpose = .continueSession
    ) throws -> (PairingOriginDriverV1, PairingRecipientDriverV1) {
        let origin = try makeOrigin(purpose: purpose)
        let recipient = try makeRecipient(origin)
        let originHello = try XCTUnwrap(origin.receive(recipient.initialRecord).first)
        let recipientHello = try XCTUnwrap(recipient.receive(originHello).first)
        XCTAssertNil(origin.sas)
        XCTAssertTrue(try origin.receive(recipientHello).isEmpty)
        XCTAssertEqual(origin.sas, recipient.sas)
        return (origin, recipient)
    }

    @discardableResult
    private func approve(
        purpose: PairingPurpose = .continueSession
    ) throws -> (PairingSessionV1, PairingSessionV1) {
        let (origin, recipient) = try handshake(purpose: purpose)
        let originDecision = try origin.decideSAS(matches: true)
        XCTAssertNil(origin.approvedSession)
        XCTAssertTrue(try recipient.receive(originDecision).isEmpty)
        let recipientDecision = try recipient.decideSAS(matches: true)
        XCTAssertTrue(try origin.receive(recipientDecision).isEmpty)
        return (try XCTUnwrap(origin.approvedSession), try XCTUnwrap(recipient.approvedSession))
    }

    func testRecordCodecRoundTripsExactlyAndIncrementally() throws {
        let first = try PairingStreamRecordV1(kind: .recipientCommitment, payload: Data([1, 2, 3]))
        let second = try PairingStreamRecordV1(kind: .authenticatedPairingFrame, payload: Data([4, 5]))
        let joined = try first.encoded() + second.encoded()

        let decoder = PairingStreamRecordDecoderV1()
        XCTAssertEqual(try decoder.append(joined.prefix(3)), [])
        XCTAssertEqual(try decoder.append(joined.dropFirst(3).prefix(9)), [])
        XCTAssertEqual(try decoder.append(joined.dropFirst(12)), [first, second])
        try decoder.finish()
        XCTAssertEqual(try PairingStreamRecordV1.decodeExactly(try first.encoded()), first)
        XCTAssertThrowsError(try PairingStreamRecordV1.decodeExactly(joined)) {
            XCTAssertEqual($0 as? PairingStreamRecordErrorV1, .trailingRecords)
        }
    }

    func testRecordCodecRejectsVersionKindLengthsAndTruncation() throws {
        var unknownVersion = try PairingStreamRecordV1(
            kind: .originHello, payload: Data([1])
        ).encoded()
        unknownVersion[PairingStreamRecordV1.magic.count] = 2
        XCTAssertThrowsError(try PairingStreamRecordV1.decodeExactly(unknownVersion)) {
            XCTAssertEqual($0 as? PairingStreamRecordErrorV1, .unsupportedVersion(2))
        }

        var unknownKind = try PairingStreamRecordV1(
            kind: .originHello, payload: Data([1])
        ).encoded()
        unknownKind[PairingStreamRecordV1.magic.count + 1] = 99
        XCTAssertThrowsError(try PairingStreamRecordV1.decodeExactly(unknownKind)) {
            XCTAssertEqual($0 as? PairingStreamRecordErrorV1, .unknownKind(99))
        }

        var zeroLength = try PairingStreamRecordV1(
            kind: .originHello, payload: Data([1])
        ).encoded()
        let lengthOffset = PairingStreamRecordV1.magic.count + 2
        zeroLength.replaceSubrange(lengthOffset..<(lengthOffset + 4), with: [0, 0, 0, 0])
        XCTAssertThrowsError(try PairingStreamRecordV1.decodeExactly(zeroLength)) {
            XCTAssertEqual($0 as? PairingStreamRecordErrorV1, .zeroLength)
        }

        var oversized = try PairingStreamRecordV1(
            kind: .originHello, payload: Data([1])
        ).encoded()
        oversized.replaceSubrange(lengthOffset..<(lengthOffset + 4), with: [0, 1, 0, 1])
        XCTAssertThrowsError(try PairingStreamRecordV1.decodeExactly(oversized)) {
            XCTAssertEqual(
                $0 as? PairingStreamRecordErrorV1,
                .payloadTooLarge(
                    actual: 65_537,
                    maximum: PairingStreamRecordV1.maximumPayloadBytes(for: .originHello)
                )
            )
        }

        let decoder = PairingStreamRecordDecoderV1()
        _ = try decoder.append(Data(try PairingStreamRecordV1(
            kind: .originHello, payload: Data([1, 2])
        ).encoded().dropLast()))
        XCTAssertThrowsError(try decoder.finish()) {
            XCTAssertEqual($0 as? PairingStreamRecordErrorV1, .truncatedAtFinish)
        }

        let oversizedInput = Data(
            repeating: 0,
            count: PairingStreamRecordDecoderV1.maximumBufferedBytes + 1
        )
        let boundedDecoder = PairingStreamRecordDecoderV1()
        XCTAssertThrowsError(try boundedDecoder.append(oversizedInput)) {
            XCTAssertEqual(
                $0 as? PairingStreamRecordErrorV1,
                .bufferedBytesTooLarge(
                    actual: oversizedInput.count,
                    maximum: PairingStreamRecordDecoderV1.maximumBufferedBytes
                )
            )
        }
        XCTAssertThrowsError(try boundedDecoder.append(Data([1]))) {
            XCTAssertEqual($0 as? PairingStreamRecordErrorV1, .decoderFailed)
        }
    }

    func testQRTextCodecRoundTripsCanonicalOfferAndRejectsAlternateURLs() throws {
        let origin = try makeOrigin()
        let text = try PairingQRTextCodecV1.encode(offerBytes: origin.offerBytes)
        XCTAssertEqual(try PairingQRTextCodecV1.decodeOfferBytes(text), origin.offerBytes)
        XCTAssertEqual(try PairingQRTextCodecV1.decode(text), origin.offer)

        for invalid in [
            text + "#fragment",
            text + "&other=value",
            text.replacingOccurrences(of: "?offer=", with: "?other="),
            text.replacingOccurrences(of: "tessera://pair", with: "tessera://other"),
            text + "=",
            "tessera://user@pair/v1?offer=abc",
        ] {
            XCTAssertThrowsError(try PairingQRTextCodecV1.decodeOfferBytes(invalid), "\\(invalid)")
        }
        XCTAssertThrowsError(try PairingQRTextCodecV1.decodeOfferBytes(
            PairingQRTextCodecV1.prefix + String(repeating: "A", count: PairingQRTextCodecV1.maximumEncodedCharacters)
        )) { XCTAssertEqual($0 as? PairingQRTextErrorV1, .tooLarge) }
    }

    func testAllPurposesCompleteHandshakeAndMutualApproval() throws {
        for purpose in PairingPurpose.allCases {
            let (origin, recipient) = try handshake(purpose: purpose)
            XCTAssertNotNil(origin.sas, "\\(purpose)")
            XCTAssertNotNil(recipient.sas, "\\(purpose)")
            XCTAssertNil(origin.approvedSession, "\\(purpose)")
            XCTAssertNil(recipient.approvedSession, "\\(purpose)")
            let originDecision = try origin.decideSAS(matches: true)
            XCTAssertTrue(try recipient.receive(originDecision).isEmpty)
            let recipientDecision = try recipient.decideSAS(matches: true)
            XCTAssertTrue(try origin.receive(recipientDecision).isEmpty)
            XCTAssertEqual(origin.approvedSession?.purpose, purpose, "\\(purpose)")
            XCTAssertEqual(recipient.approvedSession?.purpose, purpose, "\\(purpose)")
        }
    }

    func testRoleAndOrderingErrorsInvalidateAttempt() throws {
        let origin = try makeOrigin()
        let wrong = try PairingStreamRecordV1(kind: .recipientHello, payload: Data([1]))
        XCTAssertThrowsError(try origin.receive(wrong)) {
            XCTAssertEqual(
                $0 as? PairingHandshakeDriverErrorV1,
                .unexpectedRecord(expected: .recipientCommitment, actual: .recipientHello)
            )
        }
        XCTAssertEqual(origin.state, .invalidated(.failed))
        XCTAssertThrowsError(try origin.receive(wrong)) {
            XCTAssertEqual($0 as? PairingHandshakeDriverErrorV1, .invalidated)
        }
    }

    func testDuplicateDecisionInvalidatesAndPeerDecisionIsAcceptedOnlyOnce() throws {
        let (origin, recipient) = try handshake()
        let decision = try origin.decideSAS(matches: true)
        XCTAssertThrowsError(try origin.decideSAS(matches: true)) {
            XCTAssertEqual($0 as? PairingHandshakeDriverErrorV1, .localDecisionAlreadyMade)
        }
        XCTAssertEqual(origin.state, .invalidated(.failed))

        let (origin2, recipient2) = try handshake()
        let peerDecision = try recipient2.decideSAS(matches: true)
        XCTAssertTrue(try origin2.receive(peerDecision).isEmpty)
        XCTAssertThrowsError(try origin2.receive(peerDecision))
        XCTAssertEqual(origin2.state, .invalidated(.failed))
        _ = recipient
        _ = decision
    }

    func testRejectReplayExpiryCancellationAndOnePeerAdmission() throws {
        let (origin, recipient) = try handshake()
        let reject = try origin.decideSAS(matches: false)
        XCTAssertTrue(try recipient.receive(reject).isEmpty)
        XCTAssertEqual(origin.state, .invalidated(.rejected))
        XCTAssertEqual(recipient.state, .invalidated(.rejected))

        let replayOrigin = try makeOrigin()
        let store = PairingOfferConsumptionStoreV1()
        _ = try makeRecipient(replayOrigin, store: store)
        XCTAssertThrowsError(try makeRecipient(replayOrigin, store: store)) {
            XCTAssertEqual($0 as? PairingError, .offerAlreadyConsumed)
        }

        let clock = Clock(PairingHandshakeV1.unixTimeNow())
        let expiringOrigin = try makeOrigin(clock: clock)
        clock.value = expiringOrigin.offer.expiresAt
        XCTAssertEqual(expiringOrigin.state, .invalidated(.expired))
        XCTAssertThrowsError(try expiringOrigin.admitPeer()) {
            XCTAssertEqual($0 as? PairingHandshakeDriverErrorV1, .invalidated)
        }

        let cancellable = try makeOrigin()
        XCTAssertNil(cancellable.cancel())
        XCTAssertEqual(cancellable.state, .invalidated(.cancelled))

        let (cancellingOrigin, cancellingRecipient) = try handshake()
        let authenticatedCancel = try XCTUnwrap(cancellingOrigin.cancel())
        XCTAssertTrue(try cancellingRecipient.receive(authenticatedCancel).isEmpty)
        XCTAssertEqual(cancellingOrigin.state, .invalidated(.cancelled))
        XCTAssertEqual(cancellingRecipient.state, .invalidated(.cancelled))

        let onePeer = try makeOrigin()
        try onePeer.admitPeer()
        XCTAssertThrowsError(try onePeer.admitPeer()) {
            XCTAssertEqual($0 as? PairingHandshakeDriverErrorV1, .peerAlreadyAdmitted)
        }
    }

    func testApprovedSessionsInitializeContinuationAndBootstrapTransactions() throws {
        let (continuationOrigin, continuationRecipient) = try approve(purpose: .continueSession)
        _ = try ContinuationTransactionV1(session: continuationOrigin)
        _ = try ContinuationTransactionV1(session: continuationRecipient)

        let (bootstrapOrigin, bootstrapRecipient) = try approve(purpose: .bootstrap)
        _ = try BootstrapTransactionV1(session: bootstrapOrigin)
        _ = try BootstrapTransactionV1(session: bootstrapRecipient)
    }

    func testApprovedDriverRejectsTransactionTrafficWithoutConsumingSession() throws {
        let (originDriver, recipientDriver) = try handshake()
        let originDecision = try originDriver.decideSAS(matches: true)
        _ = try recipientDriver.receive(originDecision)
        let recipientDecision = try recipientDriver.decideSAS(matches: true)
        _ = try originDriver.receive(recipientDecision)
        let originSession = try XCTUnwrap(originDriver.approvedSession)
        let recipientSession = try XCTUnwrap(recipientDriver.approvedSession)
        let frame = try recipientSession.sealTransactionMessage(Data([7]))
        let record = try PairingStreamRecordV1(kind: .authenticatedPairingFrame, payload: frame)

        XCTAssertThrowsError(try originDriver.receive(record)) {
            XCTAssertEqual($0 as? PairingHandshakeDriverErrorV1, .handshakeComplete)
        }
        XCTAssertEqual(originDriver.state, .approved)
        XCTAssertEqual(try originSession.openTransactionMessage(frame), Data([7]))
    }
}
