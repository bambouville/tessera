import CryptoKit
import Foundation
import XCTest
@testable import Tessera

@MainActor
final class BootstrapNearbyHandshakeTests: XCTestCase {
    private let originSeed = Data((0..<32).map(UInt8.init))
    private let recipientSeed = Data((32..<64).map(UInt8.init))

    func test_releasedAppleV2WireVectorExactBytes() throws {
        let vector = try loadLegacyV2Vector()
        XCTAssertEqual(vector.protocolVersion, NearbyBootstrapProtocol.version)

        let originSeed = try XCTUnwrap(Data(hex: vector.origin.privateKeySeedHex))
        let recipientSeed = try XCTUnwrap(Data(hex: vector.recipient.privateKeySeedHex))
        let originPublicKey = try XCTUnwrap(Data(hex: vector.origin.publicKeyHex))
        let recipientPublicKey = try XCTUnwrap(Data(hex: vector.recipient.publicKeyHex))
        let originHello = NearbyHandshakeHello(
            version: vector.protocolVersion,
            role: .origin,
            ephemeralPublicKey: originPublicKey,
            displayName: nil,
            appVersion: vector.releasedAppVersion,
            supportedVersions: [vector.protocolVersion]
        )
        let recipientHello = NearbyHandshakeHello(
            version: vector.protocolVersion,
            role: .recipient,
            ephemeralPublicKey: recipientPublicKey,
            displayName: nil,
            appVersion: vector.releasedAppVersion,
            supportedVersions: [vector.protocolVersion]
        )
        XCTAssertEqual(
            try originHello.encoded(),
            Data(vector.origin.canonicalHelloJSON.utf8)
        )
        XCTAssertEqual(
            try recipientHello.encoded(),
            Data(vector.recipient.canonicalHelloJSON.utf8)
        )

        let projection = LegacyV2CommitmentProjection(
            version: vector.protocolVersion,
            role: .recipient,
            ephemeralPublicKey: recipientPublicKey
        )
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(
            try canonicalEncoder.encode(projection),
            Data(vector.commitment.canonicalProjectionJSON.utf8)
        )

        let originAttempt = try NearbyHandshake.begin(
            role: .origin,
            deterministicPrivateKey: originSeed
        )
        let recipientAttempt = try NearbyHandshake.begin(
            role: .recipient,
            deterministicPrivateKey: recipientSeed
        )
        XCTAssertEqual(originAttempt.hello.ephemeralPublicKey, originPublicKey)
        XCTAssertEqual(recipientAttempt.hello.ephemeralPublicKey, recipientPublicKey)
        let commitment = try NearbyHandshake.recipientCommitment(for: recipientAttempt)
        XCTAssertEqual(commitment.helloDigest.hex, vector.commitment.helloDigestHex)
        let releasedCommitmentBytes = Data(vector.commitment.canonicalJSON.utf8)
        XCTAssertEqual(
            try NearbyHandshakeCommitment.decode(releasedCommitmentBytes).encoded(),
            releasedCommitmentBytes
        )

        let transcript = try NearbyHandshake.makeTranscript(
            originHello: originHello,
            recipientHello: recipientHello
        )
        XCTAssertEqual(transcript.hex, vector.transcriptHex)

        let origin = try NearbyHandshake.completeOrigin(
            originAttempt,
            with: recipientAttempt.hello,
            verifying: commitment
        )
        let recipient = try NearbyHandshake.completeRecipient(
            recipientAttempt,
            with: originAttempt.hello
        )
        XCTAssertEqual(origin.transcriptHash.hex, vector.transcriptHashHex)
        XCTAssertEqual(recipient.transcriptHash, origin.transcriptHash)
        XCTAssertEqual(origin.sas.digits, vector.sasDigits)
        XCTAssertEqual(recipient.sas, origin.sas)

        let originPrivateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: originSeed
        )
        let recipientCryptoPublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: recipientPublicKey
        )
        let sharedSecret = try originPrivateKey.sharedSecretFromKeyAgreement(
            with: recipientCryptoPublicKey
        )
        let sasKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: origin.transcriptHash,
            sharedInfo: Data("tessera/nearby-bootstrap/sas/v1".utf8),
            outputByteCount: 8
        )
        XCTAssertEqual(
            sasKey.withUnsafeBytes { Data($0).hex },
            vector.sasBytesHex
        )

        let originDecision = try origin.sealSASDecision(matches: true)
        let recipientDecision = try recipient.sealSASDecision(matches: true)
        XCTAssertTrue(try origin.openPeerSASDecision(recipientDecision))
        XCTAssertTrue(try recipient.openPeerSASDecision(originDecision))
        let originTest = try origin.sealTestPayload(Data("origin-vector".utf8))
        let recipientTest = try recipient.sealTestPayload(Data("recipient-vector".utf8))
        try assertLegacyV2Frame(originDecision, named: "origin-sas-match", in: vector)
        try assertLegacyV2Frame(recipientDecision, named: "recipient-sas-match", in: vector)
        try assertLegacyV2Frame(originTest, named: "origin-debug-test", in: vector)
        try assertLegacyV2Frame(recipientTest, named: "recipient-debug-test", in: vector)
    }

    func test_deterministicX25519TranscriptAndSASVector() throws {
        let (origin, recipient, originSession, recipientSession) = try makeSessions()
        let commitment = try NearbyHandshake.recipientCommitment(
            for: try NearbyHandshake.begin(
                role: .recipient,
                deterministicPrivateKey: recipientSeed
            )
        )

        XCTAssertEqual(
            origin.hello.ephemeralPublicKey.hex,
            "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f"
        )
        XCTAssertEqual(
            recipient.hello.ephemeralPublicKey.hex,
            "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254"
        )
        XCTAssertEqual(
            originSession.transcriptHash.hex,
            "7e3631b4e7284359ef2dce76be1e393c8cb867cc6c619f432432b9b004818087"
        )
        XCTAssertEqual(
            commitment.helloDigest.hex,
            "f88dc1093b87c5d709997a5bc4ce3efa19bd58fce8ca5fb5d87a769e742c04a2"
        )
        XCTAssertEqual(originSession.sas.digits, "027492")
        XCTAssertEqual(recipientSession.transcriptHash, originSession.transcriptHash)
        XCTAssertEqual(recipientSession.sas, originSession.sas)
    }

    func test_displayLabelsAreBoundedButDoNotChangeV2CommitmentOrSAS() throws {
        let unnamedRecipient = try NearbyHandshake.begin(
            role: .recipient,
            deterministicPrivateKey: recipientSeed
        )
        let namedOrigin = try NearbyHandshake.begin(
            role: .origin,
            deterministicPrivateKey: originSeed,
            displayName: "  Origin\n iPad  "
        )
        let namedRecipient = try NearbyHandshake.begin(
            role: .recipient,
            deterministicPrivateKey: recipientSeed,
            displayName: "Recipient\tiPhone"
        )

        let legacyCommitment = try NearbyHandshake.recipientCommitment(
            for: unnamedRecipient
        )
        let namedCommitment = try NearbyHandshake.recipientCommitment(
            for: namedRecipient
        )
        XCTAssertEqual(namedCommitment.helloDigest, legacyCommitment.helloDigest)

        let originSession = try NearbyHandshake.completeOrigin(
            namedOrigin,
            with: namedRecipient.hello,
            verifying: namedCommitment
        )
        let recipientSession = try NearbyHandshake.completeRecipient(
            namedRecipient,
            with: namedOrigin.hello
        )
        XCTAssertEqual(originSession.sas.digits, "027492")
        XCTAssertEqual(recipientSession.sas, originSession.sas)
        XCTAssertEqual(originSession.peerDisplayName, "Recipient iPhone")
        XCTAssertEqual(recipientSession.peerDisplayName, "Origin iPad")
    }

    func test_displayAndBonjourLabelsStripControlsAndRespectByteBudgets() {
        let raw = "\u{0}\n  " + String(repeating: "😀", count: 60) + "\t end"
        let display = NearbyDeviceLabel.sanitized(raw)
        let service = NearbyDeviceLabel.serviceName(raw)

        XCTAssertLessThanOrEqual(display.count, 48)
        XCTAssertLessThanOrEqual(display.utf8.count, 192)
        XCTAssertLessThanOrEqual(service.utf8.count, 63)
        XCTAssertFalse(display.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        })
        XCTAssertFalse(service.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        })
        XCTAssertEqual(NearbyDeviceLabel.sanitized(" \n\t "), NearbyDeviceLabel.generic)
        XCTAssertEqual(NearbyDeviceLabel.serviceName(" \n\t "), NearbyDeviceLabel.serviceFallback)
    }

    func test_roleReflectionFailsAndConsumesAttempt() throws {
        let origin = try NearbyHandshake.begin(
            role: .origin,
            deterministicPrivateKey: originSeed
        )
        let reflectedRole = NearbyHandshakeHello(
            role: .origin,
            ephemeralPublicKey: Data(repeating: 7, count: 32)
        )
        let validRecipient = try NearbyHandshake.begin(
            role: .recipient,
            deterministicPrivateKey: recipientSeed
        )
        let commitment = try NearbyHandshake.recipientCommitment(for: validRecipient)

        XCTAssertThrowsError(
            try NearbyHandshake.completeOrigin(
                origin,
                with: reflectedRole,
                verifying: commitment
            )
        ) { error in
            XCTAssertEqual(
                error as? NearbyHandshakeError,
                .invalidCommitment
            )
        }

        XCTAssertThrowsError(
            try NearbyHandshake.completeOrigin(
                origin,
                with: validRecipient.hello,
                verifying: commitment
            )
        ) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .attemptAlreadyConsumed)
        }
    }

    func test_reflectedPublicKeyFailsEvenWithOppositeRoleLabel() throws {
        let origin = try NearbyHandshake.begin(
            role: .origin,
            deterministicPrivateKey: originSeed
        )
        let reflectedKey = NearbyHandshakeHello(
            role: .recipient,
            ephemeralPublicKey: origin.hello.ephemeralPublicKey
        )
        let recipient = try NearbyHandshake.begin(
            role: .recipient,
            deterministicPrivateKey: originSeed
        )
        let commitment = try NearbyHandshake.recipientCommitment(for: recipient)

        XCTAssertThrowsError(
            try NearbyHandshake.completeOrigin(
                origin,
                with: reflectedKey,
                verifying: commitment
            )
        ) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .reflectedPublicKey)
        }
    }

    func test_recipientCommitmentRejectsChangedRevealAndConsumesOriginAttempt() throws {
        let origin = try NearbyHandshake.begin(
            role: .origin,
            deterministicPrivateKey: originSeed
        )
        let recipient = try NearbyHandshake.begin(
            role: .recipient,
            deterministicPrivateKey: recipientSeed
        )
        let changedRecipient = NearbyHandshake.begin(role: .recipient)
        let commitment = try NearbyHandshake.recipientCommitment(for: recipient)

        XCTAssertThrowsError(
            try NearbyHandshake.completeOrigin(
                origin,
                with: changedRecipient.hello,
                verifying: commitment
            )
        ) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .commitmentMismatch)
        }
        XCTAssertThrowsError(
            try NearbyHandshake.completeOrigin(
                origin,
                with: recipient.hello,
                verifying: commitment
            )
        ) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .attemptAlreadyConsumed)
        }
    }

    func test_recipientCannotCompleteBeforePublishingCommitment() throws {
        let origin = try NearbyHandshake.begin(
            role: .origin,
            deterministicPrivateKey: originSeed
        )
        let recipient = try NearbyHandshake.begin(
            role: .recipient,
            deterministicPrivateKey: recipientSeed
        )

        XCTAssertThrowsError(
            try NearbyHandshake.completeRecipient(
                recipient,
                with: origin.hello
            )
        ) { error in
            XCTAssertEqual(
                error as? NearbyHandshakeError,
                .recipientCommitmentRequired
            )
        }

        _ = try NearbyHandshake.recipientCommitment(for: recipient)
        XCTAssertNoThrow(
            try NearbyHandshake.completeRecipient(
                recipient,
                with: origin.hello
            )
        )
    }

    func test_changedTranscriptProducesDifferentMatchingSAS() throws {
        let alternateRecipientSeed = Data((64..<96).map(UInt8.init))
        let alternateOrigin = try NearbyHandshake.begin(
            role: .origin,
            deterministicPrivateKey: originSeed
        )
        let alternateRecipient = try NearbyHandshake.begin(
            role: .recipient,
            deterministicPrivateKey: alternateRecipientSeed
        )
        let commitment = try NearbyHandshake.recipientCommitment(for: alternateRecipient)
        let originSession = try NearbyHandshake.completeOrigin(
            alternateOrigin,
            with: alternateRecipient.hello,
            verifying: commitment
        )
        let recipientSession = try NearbyHandshake.completeRecipient(
            alternateRecipient,
            with: alternateOrigin.hello
        )
        let (_, _, baseline, _) = try makeSessions()

        XCTAssertNotEqual(originSession.transcriptHash, baseline.transcriptHash)
        XCTAssertNotEqual(originSession.sas, baseline.sas)
        XCTAssertEqual(originSession.sas, recipientSession.sas)
    }

    func test_directionalChannelSealsOpensAndRejectsReflection() throws {
        let (origin, recipient) = try makeConfirmedSessions()
        let originFrame = try origin.sealTestPayload(Data("origin".utf8))
        XCTAssertEqual(try recipient.openTestPayload(originFrame), Data("origin".utf8))

        let recipientFrame = try recipient.sealTestPayload(Data("recipient".utf8))
        XCTAssertEqual(try origin.openTestPayload(recipientFrame), Data("recipient".utf8))

        let reflected = try origin.sealTestPayload(Data("reflection".utf8))
        XCTAssertThrowsError(try origin.openTestPayload(reflected)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .wrongDirection)
        }
    }

    func test_channelRejectsTamperWithoutConsumingSequence() throws {
        let (origin, recipient) = try makeConfirmedSessions()
        let frame = try origin.sealTestPayload(Data("authenticated".utf8))
        var tampered = frame
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01

        XCTAssertThrowsError(try recipient.openTestPayload(tampered)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .authenticationFailed)
        }
        XCTAssertEqual(try recipient.openTestPayload(frame), Data("authenticated".utf8))
    }

    func test_channelRejectsReorderingThenAcceptsOriginalOrder() throws {
        let (origin, recipient) = try makeConfirmedSessions()
        let first = try origin.sealTestPayload(Data("first".utf8))
        let second = try origin.sealTestPayload(Data("second".utf8))

        XCTAssertThrowsError(try recipient.openTestPayload(second)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .outOfOrder(expected: 1, actual: 2))
        }
        XCTAssertEqual(try recipient.openTestPayload(first), Data("first".utf8))
        XCTAssertEqual(try recipient.openTestPayload(second), Data("second".utf8))
    }

    func test_debugChannelHooksRequireSASConfirmation() throws {
        let (_, _, origin, recipient) = try makeSessions()
        XCTAssertThrowsError(try origin.sealTestPayload(Data("blocked".utf8))) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .sasNotConfirmed)
        }
        XCTAssertThrowsError(try recipient.openTestPayload(Data())) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .sasNotConfirmed)
        }
    }

    func test_encryptedChannelAcceptsNonZeroIndexedDataSlice() throws {
        let (_, _, origin, recipient) = try makeSessions()
        let publicKey = BootstrapCoordinatorTests.fixturePublicKey()
        try confirmMutualSAS(origin: origin, recipient: recipient)
        let frame = try recipient.sealRecipientPublicKey(publicKey)
        let padded = Data([0xFF]) + frame
        let sliced = padded.dropFirst()

        XCTAssertNotEqual(sliced.startIndex, 0)
        XCTAssertEqual(try origin.openRecipientPublicKey(sliced), publicKey)
    }

    func test_manifestAPIsRequireLocalSASAndExplicitOriginAuthorizationInOrder() throws {
        let (_, _, origin, recipient) = try makeSessions()
        let manifest = BootstrapManifestTests.makeManifestForCrossTest()
        let approvedManifest = try ApprovedBootstrapManifest(
            exportedManifest: manifest,
            selectedOptionalTransfers: Set(BootstrapOptionalTransfer.allCases)
        )
        let publicKey = BootstrapCoordinatorTests.fixturePublicKey()

        XCTAssertThrowsError(try origin.sealOriginAuthorizationProof()) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .sasNotConfirmed)
        }
        XCTAssertThrowsError(try origin.sealManifest(approvedManifest)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .sasNotConfirmed)
        }

        let originDecision = try origin.sealSASDecision(matches: true)
        let recipientDecision = try recipient.sealSASDecision(matches: true)
        XCTAssertTrue(try origin.openPeerSASDecision(recipientDecision))
        XCTAssertTrue(try recipient.openPeerSASDecision(originDecision))
        XCTAssertThrowsError(try origin.sealManifest(approvedManifest)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .originAuthorizationRequired)
        }
        XCTAssertThrowsError(try origin.recordOriginAuthorization(.approved)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .recipientPublicKeyRequired)
        }
        let keyFrame = try recipient.sealRecipientPublicKey(publicKey)
        XCTAssertEqual(try origin.openRecipientPublicKey(keyFrame), publicKey)
        try origin.recordOriginAuthorization(.approved)
        XCTAssertThrowsError(try origin.sealManifest(approvedManifest)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .authorizationProofRequired)
        }

        let proof = try origin.sealOriginAuthorizationProof()
        let encryptedManifest = try origin.sealManifest(approvedManifest)

        XCTAssertThrowsError(try recipient.openManifest(encryptedManifest)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .authorizationProofRequired)
        }
        try recipient.openOriginAuthorizationProof(proof)
        XCTAssertEqual(recipient.currentOriginAuthorization, .approved)
        XCTAssertEqual(
            try recipient.openManifest(encryptedManifest),
            approvedManifest.manifest
        )
    }

    func test_productionGrantReceiptAndAckAreEncryptedOrderedAndHashBound() throws {
        let (_, _, origin, recipient) = try makeSessions()
        let manifest = BootstrapManifestTests.makeManifestForCrossTest()
        let approvedManifest = try ApprovedBootstrapManifest(
            exportedManifest: manifest,
            selectedOptionalTransfers: Set(BootstrapOptionalTransfer.allCases)
        )
        let wireManifest = approvedManifest.manifest
        let publicKey = BootstrapCoordinatorTests.fixturePublicKey()
        try confirmMutualSAS(origin: origin, recipient: recipient)

        XCTAssertNoThrow(try recipient.sealRecipientPublicKey(publicKey))
        // Use a fresh pair because the preceding assertion consumed the one-shot frame.
        let (_, _, freshOrigin, freshRecipient) = try makeSessions()
        try confirmMutualSAS(origin: freshOrigin, recipient: freshRecipient)
        let keyFrame = try freshRecipient.sealRecipientPublicKey(publicKey)
        _ = try freshOrigin.openRecipientPublicKey(keyFrame)
        try freshOrigin.recordOriginAuthorization(.approved)

        let receipt = BootstrapGrantBatchReceipt(
            publicKeyID: publicKey.id,
            publicKeyFingerprint: publicKey.fingerprint,
            results: manifest.hosts.map {
                BootstrapHostGrantResult(
                    hostID: $0.id,
                    hostName: $0.name,
                    status: $0.authenticationHint == .publicKey
                        ? .installed : .excludedAuthentication,
                    detail: nil
                )
            }
        )
        try receipt.validate(manifest: wireManifest, publicKey: publicKey.core)

        XCTAssertThrowsError(try freshOrigin.sealGrantReceipt(receipt)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .importAcceptanceRequired)
        }
        let proof = try freshOrigin.sealOriginAuthorizationProof()
        let manifestFrame = try freshOrigin.sealManifest(approvedManifest)
        try freshRecipient.openOriginAuthorizationProof(proof)
        _ = try freshRecipient.openManifest(manifestFrame)

        XCTAssertThrowsError(try freshOrigin.sealGrantReceipt(receipt)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .importAcceptanceRequired)
        }
        let acceptance = try BootstrapImportAcceptance.acknowledging(
            wireManifest,
            acceptedHostIDs: Set(wireManifest.hosts.map(\.id))
        )
        let acceptanceFrame = try freshRecipient.sealImportAcceptance(acceptance)
        let openedAcceptance = try freshOrigin.openImportAcceptance(acceptanceFrame)
        XCTAssertTrue(try openedAcceptance.validates(wireManifest))

        XCTAssertThrowsError(
            try freshRecipient.sealCompletionAcknowledgement(
                .acknowledging(receipt)
            )
        ) { error in
            XCTAssertEqual(
                error as? NearbyHandshakeError,
                .completionAcknowledgementRequired
            )
        }
        let receiptFrame = try freshOrigin.sealGrantReceipt(receipt)
        let received = try freshRecipient.openGrantReceipt(receiptFrame)
        XCTAssertEqual(received, receipt)
        let acknowledgement = try BootstrapGrantCompletionAcknowledgement
            .acknowledging(received)
        let ackFrame = try freshRecipient.sealCompletionAcknowledgement(acknowledgement)
        let openedAck = try freshOrigin.openCompletionAcknowledgement(ackFrame)
        XCTAssertTrue(try openedAck.validates(receipt))

        var modifiedResults = receipt.results
        if let first = modifiedResults.first {
            modifiedResults[0] = BootstrapHostGrantResult(
                hostID: first.hostID,
                hostName: first.hostName,
                status: first.status == .installed ? .notSelected : first.status,
                detail: nil
            )
        }
        let modified = BootstrapGrantBatchReceipt(
            publicKeyID: receipt.publicKeyID,
            publicKeyFingerprint: receipt.publicKeyFingerprint,
            results: modifiedResults
        )
        XCTAssertFalse(try openedAck.validates(modified))
    }

    func test_importAcceptanceRejectsIDsOutsideManifestAndBindsManifestHash() throws {
        let manifest = BootstrapManifestTests.makeManifestForCrossTest()
        XCTAssertThrowsError(
            try BootstrapImportAcceptance.acknowledging(
                manifest,
                acceptedHostIDs: [UUID()]
            )
        ) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .invalidImportAcceptance)
        }

        let acceptance = try BootstrapImportAcceptance.acknowledging(
            manifest,
            acceptedHostIDs: Set(manifest.hosts.map(\.id))
        )
        var changedHosts = manifest.hosts
        changedHosts[0] = BootstrapHostDescriptor(
            id: changedHosts[0].id,
            name: "changed",
            address: changedHosts[0].address,
            port: changedHosts[0].port,
            user: changedHosts[0].user,
            transport: changedHosts[0].transport,
            launchMode: changedHosts[0].launchMode,
            tmuxSessionName: changedHosts[0].tmuxSessionName,
            tags: changedHosts[0].tags,
            osHint: changedHosts[0].osHint,
            sortOrder: changedHosts[0].sortOrder,
            authenticationHint: changedHosts[0].authenticationHint,
            identityID: changedHosts[0].identityID,
            hostKeyFingerprint: changedHosts[0].hostKeyFingerprint,
            portForwards: changedHosts[0].portForwards
        )
        let changed = BootstrapManifest(
            version: manifest.version,
            identities: manifest.identities,
            hosts: changedHosts,
            jumpChains: manifest.jumpChains,
            appearance: manifest.appearance,
            settings: manifest.settings
        )
        XCTAssertFalse(try acceptance.validates(changed))
    }

    func test_recipientPublicKeyRequiresSASAndCannotBeReplayed() throws {
        let (_, _, origin, recipient) = try makeSessions()
        let publicKey = BootstrapCoordinatorTests.fixturePublicKey()

        XCTAssertThrowsError(try recipient.sealRecipientPublicKey(publicKey)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .sasNotConfirmed)
        }
        try confirmMutualSAS(origin: origin, recipient: recipient)
        let frame = try recipient.sealRecipientPublicKey(publicKey)
        XCTAssertThrowsError(try recipient.sealRecipientPublicKey(publicKey)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .recipientPublicKeyAlreadySent)
        }
        XCTAssertEqual(try origin.openRecipientPublicKey(frame), publicKey)
        XCTAssertThrowsError(try origin.openRecipientPublicKey(frame)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .recipientPublicKeyAlreadySent)
        }
    }

    func test_sasMismatchPermanentlyAbortsSessionAndFreshAttemptGetsFreshKey() throws {
        let (_, _, origin, recipient) = try makeSessions()
        let rejection = try origin.sealSASDecision(matches: false)
        XCTAssertFalse(try recipient.openPeerSASDecision(rejection))
        XCTAssertThrowsError(try origin.sealSASDecision(matches: true)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .transferAborted)
        }
        XCTAssertThrowsError(
            try recipient.sealRecipientPublicKey(BootstrapCoordinatorTests.fixturePublicKey())
        ) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .transferAborted)
        }

        let fresh = NearbyHandshake.begin(role: .origin)
        let anotherFresh = NearbyHandshake.begin(role: .origin)
        XCTAssertNotEqual(fresh.hello.ephemeralPublicKey, anotherFresh.hello.ephemeralPublicKey)
    }

    func test_futureCommitmentVersionFailsAsIncompatiblePeerNotCorruption() throws {
        let digest = Data(repeating: 1, count: 32).base64EncodedString()
        let future = Data("""
        {"version":3,"role":"recipient","helloDigest":"\(digest)",\
        "appVersion":"9.9","futureField":true}
        """.utf8)

        XCTAssertThrowsError(try NearbyHandshakeCommitment.decode(future)) { error in
            guard case .incompatiblePeerVersion(let info, let message) =
                error as? NearbyHandshakeError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(message, .commitment)
            XCTAssertEqual(info.version, 3)
            XCTAssertEqual(info.appVersion, "9.9")
            XCTAssertNotEqual(error as? NearbyHandshakeError, .invalidCommitment)
            XCTAssertTrue(
                error.localizedDescription.contains("Update Tessera on this device"),
                error.localizedDescription
            )
        }
    }

    func test_futureHelloWithRenamedKeysFailsAsIncompatiblePeer() throws {
        let reshaped = Data("""
        {"version":3,"kind":"origin","publicKey":"QUFBQQ==","supportedVersions":[2,3]}
        """.utf8)

        XCTAssertThrowsError(try NearbyHandshakeHello.decode(reshaped)) { error in
            guard case .incompatiblePeerVersion(let info, let message) =
                error as? NearbyHandshakeError else {
                return XCTFail("expected clean version error, got: \(error)")
            }
            XCTAssertEqual(message, .hello)
            XCTAssertEqual(info.version, 3)
            XCTAssertEqual(info.supportedVersions, [2, 3])
            XCTAssertFalse(error is DecodingError)
        }
    }

    func test_olderHelloVersionReportsPeerUpdateNeeded() throws {
        let key = Data(repeating: 4, count: 32).base64EncodedString()
        let v1 = Data("""
        {"version":1,"role":"origin","ephemeralPublicKey":"\(key)"}
        """.utf8)

        XCTAssertThrowsError(try NearbyHandshakeHello.decode(v1)) { error in
            guard case .incompatiblePeerVersion(let info, .hello) =
                error as? NearbyHandshakeError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(info.version, 1)
            XCTAssertTrue(
                error.localizedDescription.contains("Update Tessera on the other device"),
                error.localizedDescription
            )
        }
    }

    func test_advisoryFieldsDoNotChangeCommitmentDigestTranscriptOrSAS() throws {
        let origin = try NearbyHandshake.begin(
            role: .origin,
            deterministicPrivateKey: originSeed
        )
        let recipient = try NearbyHandshake.begin(
            role: .recipient,
            deterministicPrivateKey: recipientSeed
        )
        let commitment = try NearbyHandshake.recipientCommitment(for: recipient)
        // The attempt's own hello carries the advisory defaults; the frozen
        // vector digest must still hold because the commitment hashes only
        // the v2 projection {version, role, ephemeralPublicKey}.
        XCTAssertEqual(
            commitment.helloDigest.hex,
            "f88dc1093b87c5d709997a5bc4ce3efa19bd58fce8ca5fb5d87a769e742c04a2"
        )

        // A reveal whose advisory fields differ from the committed hello must
        // still verify, and transcript/SAS must match the frozen vector.
        let adornedReveal = NearbyHandshakeHello(
            role: .recipient,
            ephemeralPublicKey: recipient.hello.ephemeralPublicKey,
            displayName: "Someone's iPhone",
            appVersion: "99.0",
            supportedVersions: [2, 9]
        )
        let session = try NearbyHandshake.completeOrigin(
            origin,
            with: adornedReveal,
            verifying: commitment
        )
        XCTAssertEqual(
            session.transcriptHash.hex,
            "7e3631b4e7284359ef2dce76be1e393c8cb867cc6c619f432432b9b004818087"
        )
        XCTAssertEqual(session.sas.digits, "027492")
    }

    func test_legacyShapedDecoderIgnoresAdvisoryFields() throws {
        // Mirrors the decoder already shipped in pre-advisory v2 builds: a
        // bare JSONDecoder over the original field set. New optional fields
        // must be invisible to it.
        struct LegacyHello: Decodable {
            let version: Int
            let role: NearbyHandshakeRole
            let ephemeralPublicKey: Data
            let displayName: String?
        }
        struct LegacyCommitment: Decodable {
            let version: Int
            let role: NearbyHandshakeRole
            let helloDigest: Data
        }

        let attempt = try NearbyHandshake.begin(
            role: .recipient,
            deterministicPrivateKey: recipientSeed,
            displayName: "iPhone"
        )
        XCTAssertNotNil(attempt.hello.supportedVersions)
        let legacyHello = try JSONDecoder().decode(
            LegacyHello.self,
            from: attempt.hello.encoded()
        )
        XCTAssertEqual(legacyHello.version, 2)
        XCTAssertEqual(legacyHello.ephemeralPublicKey, attempt.hello.ephemeralPublicKey)

        let commitment = try NearbyHandshake.recipientCommitment(for: attempt)
        let legacyCommitment = try JSONDecoder().decode(
            LegacyCommitment.self,
            from: commitment.encoded()
        )
        XCTAssertEqual(legacyCommitment.version, 2)
        XCTAssertEqual(legacyCommitment.helloDigest, commitment.helloDigest)
    }

    func test_channelFrameVersionMismatchThrowsDistinctFrameError() throws {
        let (origin, recipient) = try makeConfirmedSessions()
        var frame = try origin.sealTestPayload(Data("payload".utf8))
        frame[4] = 2 // version byte immediately after the 4-byte TBCH magic

        XCTAssertThrowsError(try recipient.openTestPayload(frame)) { error in
            XCTAssertEqual(error as? NearbyHandshakeError, .unsupportedFrameVersion(2))
            XCTAssertTrue(
                error.localizedDescription.contains("frame version"),
                error.localizedDescription
            )
            XCTAssertFalse(
                error.localizedDescription.contains("nearby-handshake version"),
                "frame error wording must not collide with the hello version error"
            )
        }
    }

    func test_versionProbeToleratesGarbageWithoutVersionKey() throws {
        XCTAssertNil(NearbyVersionProbe.probe(Data("not json".utf8)))
        XCTAssertNil(NearbyVersionProbe.probe(Data("{\"noVersion\":true}".utf8)))
        XCTAssertNil(NearbyVersionProbe.probe(Data("{\"version\":\"2\"}".utf8)))
        XCTAssertNil(NearbyVersionProbe.probe(Data("{\"version\":true}".utf8)))
        XCTAssertNil(NearbyVersionProbe.probe(Data("[2]".utf8)))

        // Probe-nil payloads keep their original structural decode errors.
        XCTAssertThrowsError(
            try NearbyHandshakeHello.decode(Data("{\"noVersion\":true}".utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError, "unexpected error: \(error)")
        }

        // Advisory fields are sanitized and capped at construction.
        let hostile = Data("""
        {"version":3,"appVersion":"9.9\\n\\u0000 evil",\
        "supportedVersions":[1,2,3,4,5,6,7,8,9,10]}
        """.utf8)
        let info = try XCTUnwrap(NearbyVersionProbe.probe(hostile))
        XCTAssertEqual(info.supportedVersions?.count, 8)
        let appVersion = try XCTUnwrap(info.appVersion)
        XCTAssertFalse(appVersion.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        })
    }

    private func loadLegacyV2Vector() throws -> LegacyNearbyBootstrapV2Vector {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ProtocolVectors")
            .appendingPathComponent("legacy-nearby-bootstrap")
            .appendingPathComponent("v2")
            .appendingPathComponent("canonical.json")
        return try JSONDecoder().decode(
            LegacyNearbyBootstrapV2Vector.self,
            from: Data(contentsOf: url)
        )
    }

    private func assertLegacyV2Frame(
        _ actual: Data,
        named name: String,
        in vector: LegacyNearbyBootstrapV2Vector
    ) throws {
        let expected = try XCTUnwrap(vector.frames.first { $0.name == name })
        let expectedData = try XCTUnwrap(Data(hex: expected.frameHex))
        let alternateData = try XCTUnwrap(Data(hex: expected.alternateFrameHex))
        XCTAssertTrue(
            actual == expectedData || actual == alternateData,
            "legacy v2 frame drifted: \(name), actual=\(actual.hex)"
        )
        XCTAssertGreaterThanOrEqual(actual.count, 14)
        XCTAssertEqual(actual.prefix(4), Data("TBCH".utf8))
        XCTAssertEqual(actual[4], UInt8(expected.frameVersion))
        XCTAssertEqual(actual[5], UInt8(expected.directionByte))
        XCTAssertEqual(
            expected.directionByte,
            expected.direction == "originToRecipient" ? 1 : 2
        )
        let sequence = actual.subdata(in: 6..<14).reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        XCTAssertEqual(sequence, expected.sequence)
    }

    private func makeSessions() throws -> (
        NearbyHandshakeAttempt,
        NearbyHandshakeAttempt,
        NearbyManifestTransferSession,
        NearbyManifestTransferSession
    ) {
        let origin = try NearbyHandshake.begin(
            role: .origin,
            deterministicPrivateKey: originSeed
        )
        let recipient = try NearbyHandshake.begin(
            role: .recipient,
            deterministicPrivateKey: recipientSeed
        )
        let commitment = try NearbyHandshake.recipientCommitment(for: recipient)
        let originSession = try NearbyHandshake.completeOrigin(
            origin,
            with: recipient.hello,
            verifying: commitment
        )
        let recipientSession = try NearbyHandshake.completeRecipient(
            recipient,
            with: origin.hello
        )
        return (origin, recipient, originSession, recipientSession)
    }

    private func makeConfirmedSessions() throws -> (
        NearbyManifestTransferSession,
        NearbyManifestTransferSession
    ) {
        let (_, _, origin, recipient) = try makeSessions()
        try confirmMutualSAS(origin: origin, recipient: recipient)
        return (origin, recipient)
    }

    private func confirmMutualSAS(
        origin: NearbyManifestTransferSession,
        recipient: NearbyManifestTransferSession
    ) throws {
        let originDecision = try origin.sealSASDecision(matches: true)
        let recipientDecision = try recipient.sealSASDecision(matches: true)
        XCTAssertTrue(try origin.openPeerSASDecision(recipientDecision))
        XCTAssertTrue(try recipient.openPeerSASDecision(originDecision))
    }
}

private struct LegacyNearbyBootstrapV2Vector: Decodable {
    let protocolVersion: Int
    let releasedAppVersion: String
    let origin: Participant
    let recipient: Participant
    let commitment: Commitment
    let transcriptHex: String
    let transcriptHashHex: String
    let sasBytesHex: String
    let sasDigits: String
    let frames: [Frame]

    struct Participant: Decodable {
        let privateKeySeedHex: String
        let publicKeyHex: String
        let canonicalHelloJSON: String
    }

    struct Commitment: Decodable {
        let canonicalProjectionJSON: String
        let helloDigestHex: String
        let canonicalJSON: String
    }

    struct Frame: Decodable {
        let name: String
        let direction: String
        let directionByte: Int
        let sequence: UInt64
        let frameVersion: Int
        let frameHex: String
        let alternateFrameHex: String
    }
}

private struct LegacyV2CommitmentProjection: Encodable {
    let version: Int
    let role: NearbyHandshakeRole
    let ephemeralPublicKey: Data
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
