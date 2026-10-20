import Foundation
@testable import TesseraPairingCore
import XCTest

final class PairingCoreV1Tests: XCTestCase {
    private let now: Int64 = 1_700_000_000
    private let offerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let originPrivateKey = Data((0..<32).map(UInt8.init))
    private let recipientPrivateKey = Data((32..<64).map(UInt8.init))
    private let opticalSecret = Data((0xA0...0xBF).map(UInt8.init))

    private struct Pair {
        let originAttempt: PairingOriginAttemptV1
        let recipientAttempt: PairingRecipientAttemptV1
        let disclosure: PairingOriginDisclosureV1
        let recipientCompletion: PairingRecipientCompletionV1
        let originSession: PairingSessionV1

        var recipientSession: PairingSessionV1 { recipientCompletion.session }
    }

    private func makePair(
        purpose: PairingPurpose = .continueSession,
        offerID: UUID? = nil,
        opticalSecret: Data? = nil,
        originTransactionVersions: [Int] = [1],
        recipientTransactionVersions: [Int] = [1],
        originKey: Data? = nil,
        recipientKey: Data? = nil
    ) throws -> Pair {
        let origin = try PairingHandshakeV1.beginOrigin(
            purpose: purpose,
            offerID: offerID ?? self.offerID,
            currentTime: now,
            expiresAt: now + 300,
            endpointCandidates: [
                PairingEndpointCandidateV1(host: "192.0.2.10", port: 49_152),
            ],
            oneTimeOpticalSecret: opticalSecret ?? self.opticalSecret,
            supportedTransactionVersions: originTransactionVersions,
            optionalPayloadDigest: Data(repeating: 0x55, count: 32),
            deterministicPrivateKey: originKey ?? originPrivateKey
        )
        let recipient = try PairingHandshakeV1.beginRecipient(
            encodedOffer: origin.encodedOffer,
            currentTime: now,
            supportedTransactionVersions: recipientTransactionVersions,
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: recipientKey ?? recipientPrivateKey
        )
        let disclosure = try origin.reveal(after: recipient.encodedCommitment)
        let recipientCompletion = try recipient.complete(with: disclosure.encodedHello)
        let originSession = try origin.complete(with: recipientCompletion.encodedHello)
        return Pair(
            originAttempt: origin,
            recipientAttempt: recipient,
            disclosure: disclosure,
            recipientCompletion: recipientCompletion,
            originSession: originSession
        )
    }

    func testDeterministicHandshakeAgreesOnTranscriptMaterialAndSAS() throws {
        let pair = try makePair()
        XCTAssertEqual(pair.originSession.purpose, .continueSession)
        XCTAssertEqual(pair.originSession.offerID, offerID)
        XCTAssertEqual(pair.originSession.selectedPairingVersion, 1)
        XCTAssertEqual(pair.originSession.selectedTransactionVersion, 1)
        XCTAssertEqual(pair.originSession.transcript, pair.recipientSession.transcript)
        XCTAssertEqual(pair.originSession.transcriptHash, pair.recipientSession.transcriptHash)
        XCTAssertEqual(pair.originSession.derivedMaterial, pair.recipientSession.derivedMaterial)
        XCTAssertEqual(pair.originSession.sas, pair.recipientSession.sas)
        XCTAssertEqual(pair.originSession.sas.digits.count, 6)
    }

    func testOfferDoesNotDiscloseOriginEphemeralPublicKeyBeforeRecipientCommitment() throws {
        let origin = try PairingHandshakeV1.beginOrigin(
            purpose: .enroll,
            offerID: offerID,
            currentTime: now,
            expiresAt: now + 60,
            endpointCandidates: [],
            oneTimeOpticalSecret: opticalSecret,
            supportedTransactionVersions: [1],
            deterministicPrivateKey: originPrivateKey
        )
        XCTAssertThrowsError(try origin.complete(with: Data())) {
            XCTAssertEqual($0 as? PairingError, .commitmentRequired)
        }

        let recipient = try PairingHandshakeV1.beginRecipient(
            encodedOffer: origin.encodedOffer,
            currentTime: now,
            supportedTransactionVersions: [1],
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: recipientPrivateKey
        )
        let disclosure = try origin.reveal(after: recipient.encodedCommitment)
        let publicKeyBase64 = disclosure.hello.ephemeralPublicKey.base64EncodedString()
        XCTAssertFalse(String(decoding: origin.encodedOffer, as: UTF8.self).contains(publicKeyBase64))
        XCTAssertNotEqual(
            origin.offer.originEphemeralKeyOrCommitment.value,
            disclosure.hello.ephemeralPublicKey
        )
    }

    func testStrictCanonicalOfferRejectsWhitespaceUnknownFieldsAndOversize() throws {
        let pair = try makePair()
        XCTAssertThrowsError(try PairingOfferV1.decode(pair.originAttempt.encodedOffer + Data("\n".utf8))) {
            XCTAssertEqual($0 as? PairingError, .nonCanonicalMessage)
        }

        let unknown = try changingJSONObject(pair.originAttempt.encodedOffer) {
            $0["extra"] = "forbidden"
        }
        XCTAssertThrowsError(try PairingOfferV1.decode(unknown)) {
            XCTAssertEqual($0 as? PairingError, .unknownField("extra"))
        }

        let oversized = Data(repeating: 0x20, count: PairingOfferV1.maximumEncodedBytes + 1)
        XCTAssertThrowsError(try PairingOfferV1.decode(oversized)) {
            XCTAssertEqual(
                $0 as? PairingError,
                .messageTooLarge(
                    actual: PairingOfferV1.maximumEncodedBytes + 1,
                    maximum: PairingOfferV1.maximumEncodedBytes
                )
            )
        }
    }

    func testOfferValidationRejectsUnsortedVersionsShortSecretAndUnsafeEndpoint() throws {
        let pair = try makePair(originTransactionVersions: [1, 2])
        let unsorted = try changingJSONObject(pair.originAttempt.encodedOffer) {
            $0["supportedTransactionVersions"] = [2, 1]
        }
        XCTAssertThrowsError(try PairingOfferV1.decode(unsorted)) {
            XCTAssertEqual(
                $0 as? PairingError,
                .invalidOffer(field: "supportedTransactionVersions")
            )
        }

        let shortSecret = try changingJSONObject(pair.originAttempt.encodedOffer) {
            $0["oneTimeOpticalSecret"] = Data(repeating: 7, count: 8).base64EncodedString()
        }
        XCTAssertThrowsError(try PairingOfferV1.decode(shortSecret)) {
            XCTAssertEqual($0 as? PairingError, .invalidOpticalSecret)
        }

        let badEndpoint = try changingJSONObject(pair.originAttempt.encodedOffer) {
            var endpoints = $0["endpointCandidates"] as! [[String: Any]]
            endpoints[0]["host"] = "bad host"
            $0["endpointCandidates"] = endpoints
        }
        XCTAssertThrowsError(try PairingOfferV1.decode(badEndpoint)) {
            XCTAssertEqual(
                $0 as? PairingError,
                .invalidOffer(field: "endpointCandidates.host")
            )
        }
    }

    func testOffersAreShortLivedAndAtomicallySingleUse() throws {
        let origin = try PairingHandshakeV1.beginOrigin(
            purpose: .bootstrap,
            offerID: offerID,
            currentTime: now,
            expiresAt: now + 60,
            endpointCandidates: [],
            oneTimeOpticalSecret: nil,
            supportedTransactionVersions: [1],
            deterministicPrivateKey: originPrivateKey
        )
        XCTAssertThrowsError(
            try PairingHandshakeV1.beginRecipient(
                encodedOffer: origin.encodedOffer,
                currentTime: now + 60,
                supportedTransactionVersions: [1],
                consumptionStore: PairingOfferConsumptionStoreV1(),
                deterministicPrivateKey: recipientPrivateKey
            )
        ) { XCTAssertEqual($0 as? PairingError, .offerExpired) }

        let store = PairingOfferConsumptionStoreV1()
        _ = try PairingHandshakeV1.beginRecipient(
            encodedOffer: origin.encodedOffer,
            currentTime: now,
            supportedTransactionVersions: [1],
            consumptionStore: store,
            deterministicPrivateKey: recipientPrivateKey
        )
        XCTAssertThrowsError(
            try PairingHandshakeV1.beginRecipient(
                encodedOffer: origin.encodedOffer,
                currentTime: now,
                supportedTransactionVersions: [1],
                consumptionStore: store,
                deterministicPrivateKey: Data(repeating: 0x77, count: 32)
            )
        ) { XCTAssertEqual($0 as? PairingError, .offerAlreadyConsumed) }
    }

    func testExpiryIsEnforcedAtEveryHandshakeAndSessionPhase() throws {
        let revealOrigin = try PairingHandshakeV1.beginOrigin(
            purpose: .bootstrap,
            offerID: UUID(uuidString: "41111111-2222-3333-4444-555555555555")!,
            currentTime: now,
            expiresAt: now + 60,
            endpointCandidates: [],
            oneTimeOpticalSecret: nil,
            supportedTransactionVersions: [1],
            deterministicPrivateKey: originPrivateKey
        )
        let revealRecipient = try PairingHandshakeV1.beginRecipient(
            encodedOffer: revealOrigin.encodedOffer,
            currentTime: now,
            supportedTransactionVersions: [1],
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: recipientPrivateKey
        )
        XCTAssertThrowsError(try revealOrigin.reveal(
            after: revealRecipient.encodedCommitment,
            currentTime: now + 60
        )) { XCTAssertEqual($0 as? PairingError, .offerExpired) }
        XCTAssertThrowsError(try revealOrigin.reveal(
            after: revealRecipient.encodedCommitment,
            currentTime: now
        )) { XCTAssertEqual($0 as? PairingError, .attemptAlreadyConsumed) }

        let recipientOrigin = try PairingHandshakeV1.beginOrigin(
            purpose: .bootstrap,
            offerID: UUID(uuidString: "51111111-2222-3333-4444-555555555555")!,
            currentTime: now,
            expiresAt: now + 60,
            endpointCandidates: [],
            oneTimeOpticalSecret: nil,
            supportedTransactionVersions: [1],
            deterministicPrivateKey: originPrivateKey
        )
        let expiringRecipient = try PairingHandshakeV1.beginRecipient(
            encodedOffer: recipientOrigin.encodedOffer,
            currentTime: now,
            supportedTransactionVersions: [1],
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: recipientPrivateKey
        )
        let disclosure = try recipientOrigin.reveal(after: expiringRecipient.encodedCommitment)
        XCTAssertThrowsError(try expiringRecipient.complete(
            with: disclosure.encodedHello,
            currentTime: now + 60
        )) { XCTAssertEqual($0 as? PairingError, .offerExpired) }
        XCTAssertThrowsError(try expiringRecipient.complete(
            with: disclosure.encodedHello,
            currentTime: now
        )) { XCTAssertEqual($0 as? PairingError, .attemptAlreadyConsumed) }

        let originCompletion = try PairingHandshakeV1.beginOrigin(
            purpose: .bootstrap,
            offerID: UUID(uuidString: "61111111-2222-3333-4444-555555555555")!,
            currentTime: now,
            expiresAt: now + 60,
            endpointCandidates: [],
            oneTimeOpticalSecret: nil,
            supportedTransactionVersions: [1],
            deterministicPrivateKey: originPrivateKey
        )
        let completionRecipient = try PairingHandshakeV1.beginRecipient(
            encodedOffer: originCompletion.encodedOffer,
            currentTime: now,
            supportedTransactionVersions: [1],
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: recipientPrivateKey
        )
        let completionDisclosure = try originCompletion.reveal(
            after: completionRecipient.encodedCommitment
        )
        let recipientCompletion = try completionRecipient.complete(
            with: completionDisclosure.encodedHello
        )
        XCTAssertThrowsError(try originCompletion.complete(
            with: recipientCompletion.encodedHello,
            currentTime: now + 60
        )) { XCTAssertEqual($0 as? PairingError, .offerExpired) }

        let sessionPair = try makePair()
        XCTAssertThrowsError(try sessionPair.originSession.sealPeerDecision(
            matches: true,
            currentTime: now + 300
        )) { XCTAssertEqual($0 as? PairingError, .offerExpired) }
        XCTAssertFalse(sessionPair.originSession.isTransactionReady)

        let transactionPair = try makePair()
        _ = try transactionPair.recipientSession.open(
            transactionPair.originSession.sealPeerDecision(matches: true)
        )
        _ = try transactionPair.originSession.open(
            transactionPair.recipientSession.sealPeerDecision(matches: true)
        )
        XCTAssertThrowsError(try transactionPair.originSession.sealTransactionMessage(
            Data([1]),
            currentTime: now + 300
        )) { XCTAssertEqual($0 as? PairingError, .offerExpired) }
    }

    func testAttemptsAreConsumedAfterInvalidInput() throws {
        let origin = try PairingHandshakeV1.beginOrigin(
            purpose: .bootstrap,
            offerID: offerID,
            currentTime: now,
            expiresAt: now + 60,
            endpointCandidates: [],
            oneTimeOpticalSecret: nil,
            supportedTransactionVersions: [1],
            deterministicPrivateKey: originPrivateKey
        )
        let recipient = try PairingHandshakeV1.beginRecipient(
            encodedOffer: origin.encodedOffer,
            currentTime: now,
            supportedTransactionVersions: [1],
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: recipientPrivateKey
        )
        XCTAssertThrowsError(try origin.reveal(after: Data("not json".utf8)))
        XCTAssertThrowsError(try origin.reveal(after: recipient.encodedCommitment)) {
            XCTAssertEqual($0 as? PairingError, .attemptAlreadyConsumed)
        }

        let origin2 = try PairingHandshakeV1.beginOrigin(
            purpose: .bootstrap,
            offerID: UUID(uuidString: "21111111-2222-3333-4444-555555555555")!,
            currentTime: now,
            expiresAt: now + 60,
            endpointCandidates: [],
            oneTimeOpticalSecret: nil,
            supportedTransactionVersions: [1],
            deterministicPrivateKey: originPrivateKey
        )
        let recipient2 = try PairingHandshakeV1.beginRecipient(
            encodedOffer: origin2.encodedOffer,
            currentTime: now,
            supportedTransactionVersions: [1],
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: recipientPrivateKey
        )
        let disclosure2 = try origin2.reveal(after: recipient2.encodedCommitment)
        XCTAssertThrowsError(try recipient2.complete(with: Data("bad".utf8)))
        XCTAssertThrowsError(try recipient2.complete(with: disclosure2.encodedHello)) {
            XCTAssertEqual($0 as? PairingError, .attemptAlreadyConsumed)
        }
    }

    func testPurposeOfferNegotiationAndOpticalSecretAllBindTranscript() throws {
        let baseline = try makePair()
        let changedPurpose = try makePair(purpose: .bootstrap)
        let changedOffer = try makePair(
            offerID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        let changedRawNegotiation = try makePair(
            originTransactionVersions: [1],
            recipientTransactionVersions: [1, 2]
        )
        let changedOptical = try makePair(
            opticalSecret: Data(repeating: 0xCC, count: 32)
        )

        for changed in [changedPurpose, changedOffer, changedRawNegotiation, changedOptical] {
            XCTAssertNotEqual(baseline.originSession.transcriptHash, changed.originSession.transcriptHash)
            XCTAssertNotEqual(
                baseline.originSession.derivedMaterial.originToRecipientKey,
                changed.originSession.derivedMaterial.originToRecipientKey
            )
        }
        XCTAssertEqual(changedRawNegotiation.originSession.selectedTransactionVersion, 1)
    }

    func testPurposeTamperAndDowngradeAreRejectedAndConsumeOriginAttempt() throws {
        let origin = try PairingHandshakeV1.beginOrigin(
            purpose: .enroll,
            offerID: offerID,
            currentTime: now,
            expiresAt: now + 60,
            endpointCandidates: [],
            oneTimeOpticalSecret: opticalSecret,
            supportedTransactionVersions: [1, 2],
            deterministicPrivateKey: originPrivateKey
        )
        let recipient = try PairingHandshakeV1.beginRecipient(
            encodedOffer: origin.encodedOffer,
            currentTime: now,
            supportedTransactionVersions: [1, 2],
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: recipientPrivateKey
        )
        let downgrade = try changingJSONObject(recipient.encodedCommitment) {
            $0["selectedTransactionVersion"] = 1
        }
        XCTAssertThrowsError(try origin.reveal(after: downgrade)) {
            XCTAssertEqual($0 as? PairingError, .downgradeDetected)
        }
        XCTAssertThrowsError(try origin.reveal(after: recipient.encodedCommitment)) {
            XCTAssertEqual($0 as? PairingError, .attemptAlreadyConsumed)
        }

        let origin2 = try PairingHandshakeV1.beginOrigin(
            purpose: .enroll,
            offerID: UUID(uuidString: "31111111-2222-3333-4444-555555555555")!,
            currentTime: now,
            expiresAt: now + 60,
            endpointCandidates: [],
            oneTimeOpticalSecret: opticalSecret,
            supportedTransactionVersions: [1],
            deterministicPrivateKey: originPrivateKey
        )
        let recipient2 = try PairingHandshakeV1.beginRecipient(
            encodedOffer: origin2.encodedOffer,
            currentTime: now,
            supportedTransactionVersions: [1],
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: recipientPrivateKey
        )
        let wrongPurpose = try changingJSONObject(recipient2.encodedCommitment) {
            $0["purpose"] = PairingPurpose.bootstrap.rawValue
        }
        XCTAssertThrowsError(try origin2.reveal(after: wrongPurpose)) {
            XCTAssertEqual($0 as? PairingError, .commitmentMismatch)
        }
    }

    func testReflectedRecipientKeyIsRejected() throws {
        let origin = try PairingHandshakeV1.beginOrigin(
            purpose: .continueSession,
            offerID: offerID,
            currentTime: now,
            expiresAt: now + 60,
            endpointCandidates: [],
            oneTimeOpticalSecret: opticalSecret,
            supportedTransactionVersions: [1],
            deterministicPrivateKey: originPrivateKey
        )
        let recipient = try PairingHandshakeV1.beginRecipient(
            encodedOffer: origin.encodedOffer,
            currentTime: now,
            supportedTransactionVersions: [1],
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: originPrivateKey
        )
        let disclosure = try origin.reveal(after: recipient.encodedCommitment)
        XCTAssertThrowsError(try recipient.complete(with: disclosure.encodedHello)) {
            XCTAssertEqual($0 as? PairingError, .reflectedPublicKey)
        }
    }

    func testFramesEnforceDecisionsDirectionSequenceReplayAndAuthentication() throws {
        let pair = try makePair()
        XCTAssertThrowsError(try pair.originSession.sealTransactionMessage(Data([1]))) {
            XCTAssertEqual($0 as? PairingError, .peerDecisionRequired)
        }

        let originDecision = try pair.originSession.sealPeerDecision(matches: true)
        XCTAssertThrowsError(try pair.originSession.open(originDecision)) {
            XCTAssertEqual($0 as? PairingError, .wrongDirection)
        }
        XCTAssertEqual(try pair.recipientSession.open(originDecision).kind, .peerDecision)
        XCTAssertThrowsError(try pair.recipientSession.open(originDecision)) {
            XCTAssertEqual($0 as? PairingError, .replayedFrame(0))
        }
        let recipientDecision = try pair.recipientSession.sealPeerDecision(matches: true)
        _ = try pair.originSession.open(recipientDecision)

        let first = try pair.originSession.sealTransactionMessage(Data("first".utf8))
        let second = try pair.originSession.sealTransactionMessage(Data("second".utf8))
        XCTAssertThrowsError(try pair.recipientSession.open(second)) {
            XCTAssertEqual($0 as? PairingError, .outOfOrder(expected: 1, actual: 2))
        }

        var tampered = first
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        XCTAssertThrowsError(try pair.recipientSession.open(tampered)) {
            XCTAssertEqual($0 as? PairingError, .authenticationFailed)
        }
        XCTAssertEqual(try pair.recipientSession.open(first).payload, Data("first".utf8))
        XCTAssertEqual(try pair.recipientSession.open(second).payload, Data("second".utf8))
    }

    func testFrameParserRejectsLengthAndVersionTampering() throws {
        let pair = try makePair()
        let frame = try pair.originSession.sealPeerDecision(matches: true)
        var trailing = frame
        trailing.append(0)
        XCTAssertThrowsError(try PairingFrameV1.decode(trailing)) {
            XCTAssertEqual($0 as? PairingError, .invalidFrame)
        }
        var wrongVersion = frame
        wrongVersion[PairingFrameV1.magic.count] = 2
        XCTAssertThrowsError(try PairingFrameV1.decode(wrongVersion)) {
            XCTAssertEqual($0 as? PairingError, .unsupportedFrameVersion(2))
        }
    }

    func testGenericEnvelopeOrderAndCompletion() throws {
        let pair = try makePair()
        XCTAssertFalse(pair.originSession.isTransactionReady)
        XCTAssertFalse(pair.recipientSession.isTransactionReady)
        _ = try pair.recipientSession.open(
            pair.originSession.sealPeerDecision(matches: true)
        )
        XCTAssertFalse(pair.originSession.isTransactionReady)
        XCTAssertFalse(pair.recipientSession.isTransactionReady)
        _ = try pair.originSession.open(
            pair.recipientSession.sealPeerDecision(matches: true)
        )
        XCTAssertTrue(pair.originSession.isTransactionReady)
        XCTAssertTrue(pair.recipientSession.isTransactionReady)
        let transaction = try pair.originSession.sealTransactionMessage(Data([1, 2, 3]))
        XCTAssertEqual(try pair.recipientSession.open(transaction).payload, Data([1, 2, 3]))
        let originCompletion = try pair.originSession.sealCompletion(Data("done".utf8))
        XCTAssertFalse(pair.originSession.isTransactionReady)
        XCTAssertEqual(try pair.recipientSession.open(originCompletion).kind, .completion)
        XCTAssertFalse(pair.recipientSession.isTransactionReady)
        let recipientCompletion = try pair.recipientSession.sealCompletion()
        XCTAssertEqual(try pair.originSession.open(recipientCompletion).kind, .completion)
        XCTAssertTrue(pair.originSession.isComplete)
        XCTAssertTrue(pair.recipientSession.isComplete)
        XCTAssertThrowsError(try pair.originSession.sealTransactionMessage(Data())) {
            XCTAssertEqual($0 as? PairingError, .unexpectedMessageOrder)
        }
    }

    func testFullyCompletedSessionRejectsAuthenticatedPostCompletionTraffic() throws {
        let pair = try makePair()
        let rejection = try rejectionVector()
        let postCompletionKind = try XCTUnwrap(
            PairingEnvelopeKindV1(
                rawValue: try XCTUnwrap(rejection["postCompletionEnvelopeKind"] as? String)
            )
        )
        XCTAssertEqual(postCompletionKind, .abort)
        let peerChannel = PairingFrameChannelV1(
            localRole: .origin,
            transcriptHash: pair.originSession.transcriptHash,
            material: pair.originSession.derivedMaterial
        )
        let decision = try peerChannel.seal(
            PairingEnvelopeV1(kind: .peerDecision, payload: Data([1]))
        )
        let completion = try peerChannel.seal(
            PairingEnvelopeV1(kind: .completion, payload: Data())
        )
        let lateAbort = try peerChannel.seal(
            PairingEnvelopeV1(kind: postCompletionKind, payload: Data("late".utf8))
        )

        _ = try pair.recipientSession.open(decision)
        _ = try pair.recipientSession.sealPeerDecision(matches: true)
        _ = try pair.recipientSession.open(completion)
        _ = try pair.recipientSession.sealCompletion()
        XCTAssertTrue(pair.recipientSession.isComplete)
        XCTAssertThrowsError(try pair.recipientSession.open(lateAbort)) {
            XCTAssertEqual($0 as? PairingError, .unexpectedMessageOrder)
        }
        XCTAssertTrue(pair.recipientSession.isComplete)
    }

    func testNegativePeerDecisionTerminatesSession() throws {
        let pair = try makePair()
        let rejection = try pair.originSession.sealPeerDecision(matches: false)
        XCTAssertEqual(try pair.recipientSession.open(rejection).payload, Data([0]))
        XCTAssertThrowsError(try pair.recipientSession.sealPeerDecision(matches: true)) {
            XCTAssertEqual($0 as? PairingError, .pairingRejected)
        }
        XCTAssertThrowsError(try pair.originSession.sealTransactionMessage(Data())) {
            XCTAssertEqual($0 as? PairingError, .pairingRejected)
        }
    }

    func testDeterministicVectorMaterial() throws {
        let pair = try makePair()
        _ = try pair.recipientSession.open(
            pair.originSession.sealPeerDecision(matches: true)
        )
        _ = try pair.originSession.open(
            pair.recipientSession.sealPeerDecision(matches: true)
        )
        let transactionFrame = try pair.originSession.sealTransactionMessage(
            Data("continuation-vector".utf8)
        )
        let actual: [String: Any] = [
            "vector": "tessera-pairing-v1-purpose-bound-optical",
            "originPrivateKeyHex": originPrivateKey.hex,
            "recipientPrivateKeyHex": recipientPrivateKey.hex,
            "opticalSecretHex": opticalSecret.hex,
            "offerBase64": pair.originAttempt.encodedOffer.base64EncodedString(),
            "commitmentBase64": pair.recipientAttempt.encodedCommitment.base64EncodedString(),
            "originHelloBase64": pair.disclosure.encodedHello.base64EncodedString(),
            "recipientHelloBase64": pair.recipientCompletion.encodedHello.base64EncodedString(),
            "transcriptHex": pair.originSession.transcript.hex,
            "transcriptHashHex": pair.originSession.transcriptHash.hex,
            "originToRecipientKeyHex": pair.originSession.derivedMaterial.originToRecipientKey.hex,
            "recipientToOriginKeyHex": pair.originSession.derivedMaterial.recipientToOriginKey.hex,
            "originToRecipientNonceHex": pair.originSession.derivedMaterial.originToRecipientNonce.hex,
            "recipientToOriginNonceHex": pair.originSession.derivedMaterial.recipientToOriginNonce.hex,
            "sas": pair.originSession.sas.digits,
            "transactionFrameHex": transactionFrame.hex,
        ]
        let vectorURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../ProtocolVectors/pairing/v1/purpose-bound-optical.json")
            .standardizedFileURL
        let expectedData = try Data(contentsOf: vectorURL)
        let expected = try XCTUnwrap(
            JSONSerialization.jsonObject(with: expectedData) as? [String: Any]
        )
        XCTAssertEqual(actual as NSDictionary, expected as NSDictionary)

        let decodedFrame = try PairingFrameV1.decode(transactionFrame)
        XCTAssertEqual(decodedFrame.direction, .originToRecipient)
        XCTAssertEqual(decodedFrame.sequence, 1)
    }

    func testPairingSchemaAndRejectionVectorsMatchEnforcedContract() throws {
        let schemas: [(String, Set<String>)] = [
            ("offer.schema.json", [
                "version", "offerID", "purpose", "expiresAt", "originRole",
                "originEphemeralKeyOrCommitment", "endpointCandidates",
                "supportedPairingVersions", "supportedTransactionVersions",
            ]),
            ("commitment.schema.json", [
                "version", "offerID", "purpose", "role", "offerDigest",
                "supportedPairingVersions", "supportedTransactionVersions",
                "selectedPairingVersion", "selectedTransactionVersion", "helloDigest",
            ]),
            ("hello.schema.json", [
                "version", "offerID", "purpose", "role", "offerDigest",
                "ephemeralPublicKey", "supportedPairingVersions",
                "supportedTransactionVersions", "selectedPairingVersion",
                "selectedTransactionVersion",
            ]),
            ("envelope.schema.json", ["kind", "payload"]),
        ]
        for (filename, requiredFields) in schemas {
            let schema = try jsonObject(filename)
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false, filename)
            XCTAssertEqual(
                Set(try XCTUnwrap(schema["required"] as? [String])),
                requiredFields,
                filename
            )
        }

        let envelopeSchema = try jsonObject("envelope.schema.json")
        XCTAssertEqual(
            envelopeSchema["x-maximumEncodedEnvelopeBytes"] as? Int,
            PairingEnvelopeV1.maximumEncodedBytes
        )
        let payloadLimits = try XCTUnwrap(
            envelopeSchema["x-maximumDecodedPayloadBytesByKind"] as? [String: Int]
        )
        XCTAssertEqual(payloadLimits["peerDecision"], 1)
        XCTAssertEqual(
            payloadLimits["transactionMessage"],
            PairingEnvelopeV1.maximumTransactionPayloadBytes
        )
        XCTAssertEqual(payloadLimits["abort"], PairingEnvelopeV1.maximumAbortPayloadBytes)
        XCTAssertEqual(
            payloadLimits["completion"],
            PairingEnvelopeV1.maximumCompletionPayloadBytes
        )

        let layout = try jsonObject("frame-layout.json")
        XCTAssertEqual(layout["byteOrder"] as? String, "big-endian")
        XCTAssertEqual(layout["maximumEncodedBytes"] as? Int, PairingFrameV1.maximumEncodedBytes)
        XCTAssertEqual(layout["headerByteCount"] as? Int, PairingFrameV1.headerByteCount)
        let fields = try XCTUnwrap(layout["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.map { $0["name"] as? String }, [
            "magic", "version", "direction", "sequence", "sealedPayloadLength",
            "sealedPayload",
        ])
        XCTAssertEqual(fields.compactMap { $0["offset"] as? Int }, [0, 4, 5, 6, 14, 18])

        let rejection = try rejectionVector()
        XCTAssertEqual(rejection["handshakeExpiryBoundary"] as? Int64, now + 60)
        XCTAssertEqual(rejection["sessionExpiryBoundary"] as? Int64, now + 300)
        XCTAssertEqual(
            rejection["downgradedSelectedTransactionVersion"] as? Int,
            1
        )

        let vectorData = try Data(contentsOf: vectorURL("purpose-bound-optical.json"))
        let vector = try XCTUnwrap(
            JSONSerialization.jsonObject(with: vectorData) as? [String: Any]
        )
        for (vectorField, schemaFilename) in [
            ("commitmentBase64", "commitment.schema.json"),
            ("originHelloBase64", "hello.schema.json"),
            ("recipientHelloBase64", "hello.schema.json"),
        ] {
            let encoded = try XCTUnwrap(
                Data(base64Encoded: try XCTUnwrap(vector[vectorField] as? String))
            )
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            let schema = try jsonObject(schemaFilename)
            XCTAssertEqual(
                Set(object.keys),
                Set(try XCTUnwrap(schema["required"] as? [String])),
                vectorField
            )
        }
        let encodedEnvelope = try PairingEnvelopeV1(
            kind: .transactionMessage,
            payload: Data("schema-vector".utf8)
        ).encoded()
        let envelopeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedEnvelope) as? [String: Any]
        )
        XCTAssertEqual(Set(envelopeObject.keys), ["kind", "payload"])
        let encodedOffer = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(vector["offerBase64"] as? String))
        )
        let transactionFrame = try XCTUnwrap(
            Data(hex: try XCTUnwrap(vector["transactionFrameHex"] as? String))
        )
        let decodedFrame = try PairingFrameV1.decode(transactionFrame)
        let example = try XCTUnwrap(layout["example"] as? [String: Any])
        XCTAssertEqual(example["encodedBytes"] as? Int, transactionFrame.count)
        XCTAssertEqual(example["sequence"] as? Int, Int(decodedFrame.sequence))
        XCTAssertEqual(
            example["sealedPayloadLength"] as? Int,
            decodedFrame.sealedPayload.count
        )
        XCTAssertEqual(
            example["nonceHex"] as? String,
            decodedFrame.sealedPayload.prefix(12).hex
        )
        XCTAssertThrowsError(try PairingHandshakeV1.beginRecipient(
            encodedOffer: encodedOffer,
            currentTime: now + 300,
            supportedTransactionVersions: [1],
            consumptionStore: PairingOfferConsumptionStoreV1(),
            deterministicPrivateKey: recipientPrivateKey
        )) { XCTAssertEqual($0 as? PairingError, .offerExpired) }
    }

    private func changingJSONObject(
        _ data: Data,
        _ change: (inout [String: Any]) -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        change(&object)
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func vectorURL(_ filename: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../ProtocolVectors/pairing/v1/\(filename)")
            .standardizedFileURL
    }

    private func jsonObject(_ filename: String) throws -> [String: Any] {
        let data = try Data(contentsOf: vectorURL(filename))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func rejectionVector() throws -> [String: Any] {
        let data = try Data(contentsOf: vectorURL("rejections.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
