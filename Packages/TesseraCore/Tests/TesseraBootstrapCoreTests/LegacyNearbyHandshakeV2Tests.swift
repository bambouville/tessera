import Crypto
import Foundation
import XCTest
@testable import TesseraBootstrapCore
import TesseraEnrollmentCore
import TesseraProtocolCore

final class LegacyNearbyHandshakeV2Tests: XCTestCase {
    func testReleasedVectorSchemaDescribesExpandedCompatibilityEvidence() throws {
        let schemaData = try Data(contentsOf: vectorDirectoryURL()
            .appendingPathComponent("schema.json"))
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        )
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let required = Set(try XCTUnwrap(schema["required"] as? [String]))
        XCTAssertTrue(required.isSuperset(of: [
            "directionalMaterial", "fullTransfer", "frames",
        ]))
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let fullFrame = try XCTUnwrap(
            definitions["fullTransferFrame"] as? [String: Any]
        )
        let properties = try XCTUnwrap(fullFrame["properties"] as? [String: Any])
        let kind = try XCTUnwrap(properties["kind"] as? [String: Any])
        let schemaKinds = Set(try XCTUnwrap(kind["enum"] as? [String]))
        let releasedKinds = Set(
            LegacyNearbyEncryptedEnvelopeKindV2.allCases
                .filter { $0 != .test }
                .map(\.rawValue)
        )
        XCTAssertEqual(schemaKinds, releasedKinds.subtracting(["sasDecision"]))
    }

    func testAuthenticatedManifestExtensionDeclarationAndReleasedDecoderCompatibility() throws {
        for extensions in [[], [LegacyNearbyManifestTransferSessionV2.agentCenterEnabledExtension], ["future.extension"]] {
            let vector = try loadVector()
            let sessions = try complete(makeAttempts(vector))
            for pair in [sessions] {
                let originDecision = try pair.origin.sealSASDecision(matches: true)
                let recipientDecision = try pair.recipient.sealSASDecision(matches: true)
                _ = try pair.origin.openPeerSASDecision(recipientDecision)
                _ = try pair.recipient.openPeerSASDecision(originDecision)
            }
            let key = try legacyPublicKey()
            let frame = try sessions.recipient.sealRecipientPublicKey(key, manifestExtensions: extensions)
            XCTAssertLessThan(frame.count, 65_536)
            XCTAssertEqual(try sessions.origin.openRecipientPublicKey(frame), key)
            XCTAssertEqual(sessions.origin.peerManifestExtensions, extensions)
            // Reproduce the released origin's exact payload decoder against new bytes.
            let plaintext = try ChaChaPoly.open(
                ChaChaPoly.SealedBox(combined: Data(frame.dropFirst(14))),
                using: SymmetricKey(data: XCTUnwrap(Data(hex: vector.directionalMaterial.recipientToOriginKeyHex))),
                authenticating: Data(frame.prefix(14)) + sessions.origin.transcriptHash)
            struct ReleasedEnvelope: Decodable { let kind: String; let payload: Data }
            let envelope = try JSONDecoder().decode(ReleasedEnvelope.self, from: plaintext)
            XCTAssertEqual(envelope.kind, "recipientPublicKey")
            let releasedKey = try JSONDecoder().decode(EnrollmentPublicKeyV1.self, from: envelope.payload)
            try releasedKey.validate()
            XCTAssertEqual(releasedKey, key)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any])
            XCTAssertEqual(object["manifestExtensions"] as? [String], extensions.isEmpty ? nil : extensions)
            try sessions.origin.recordOriginAuthorization(.approved)
            try sessions.recipient.openOriginAuthorizationProof(sessions.origin.sealOriginAuthorizationProof())
            let extended = try ApprovedBootstrapManifestV2(exportedManifest: legacyManifest(agentCenterEnabled: true),
                selectedOptionalTransfers: [])
            if extensions.contains(LegacyNearbyManifestTransferSessionV2.agentCenterEnabledExtension) {
                let frame = try sessions.origin.sealManifest(extended)
                XCTAssertEqual(try sessions.recipient.openManifest(frame).settings.agentCenterEnabled, true)
            } else {
                XCTAssertThrowsError(try sessions.origin.sealManifest(extended)) {
                    XCTAssertEqual($0 as? BootstrapManifestError,
                        .unknownField(path: "manifest.settings", field: "agentCenterEnabled"))
                }
                let released = try ApprovedBootstrapManifestV2(exportedManifest: legacyManifest(), selectedOptionalTransfers: [])
                XCTAssertNil(try sessions.recipient.openManifest(sessions.origin.sealManifest(released)).settings.agentCenterEnabled)
            }
        }
    }

    func testManifestExtensionDeclarationIsBounded() throws {
        let sessions = try complete(makeAttempts(loadVector()))
        let a = try sessions.origin.sealSASDecision(matches: true)
        let b = try sessions.recipient.sealSASDecision(matches: true)
        _ = try sessions.origin.openPeerSASDecision(b)
        _ = try sessions.recipient.openPeerSASDecision(a)
        for invalid in [Array(repeating: "a", count: 17), [""], [String(repeating: "x", count: 129)], ["a", "a"], ["bad\nname"]] {
            XCTAssertThrowsError(try sessions.recipient.sealRecipientPublicKey(legacyPublicKey(), manifestExtensions: invalid))
        }
    }

    func testMalformedAuthenticatedManifestDeclarationsFailBeforeKeyAdmission() throws {
        let invalid: [Any] = [(0..<17).map { "extension.\($0)" }, [""],
            [String(repeating: "x", count: 129)], ["a", "a"], ["bad\nname"], true, "settings.agentCenterEnabled"]
        for declaration in invalid {
            let vector = try loadVector()
            let sessions = try complete(makeAttempts(vector))
            let originDecision = try sessions.origin.sealSASDecision(matches: true)
            let recipientDecision = try sessions.recipient.sealSASDecision(matches: true)
            _ = try sessions.origin.openPeerSASDecision(recipientDecision)
            _ = try sessions.recipient.openPeerSASDecision(originDecision)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: canonicalJSON(legacyPublicKey())) as? [String: Any])
            object["manifestExtensions"] = declaration
            let frame = try legacyVectorFrame(kind: "recipientPublicKey",
                payload: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), direction: 2, sequence: 1,
                key: XCTUnwrap(Data(hex: vector.directionalMaterial.recipientToOriginKeyHex)),
                baseNonce: XCTUnwrap(Data(hex: vector.directionalMaterial.recipientToOriginNonceHex)),
                transcriptHash: sessions.origin.transcriptHash, payloadFirst: false)
            XCTAssertThrowsError(try sessions.origin.openRecipientPublicKey(frame)) {
                XCTAssertEqual($0 as? LegacyNearbyHandshakeErrorV2, .invalidPublicKey)
            }
            XCTAssertTrue(sessions.origin.peerManifestExtensions.isEmpty)
            XCTAssertThrowsError(try sessions.origin.recordOriginAuthorization(.approved)) {
                XCTAssertEqual($0 as? LegacyNearbyHandshakeErrorV2, .recipientPublicKeyRequired)
            }
        }
    }

    func testReleasedAppleV2FullTransferVectorCompletely() throws {
        let vector = try loadVector()
        let fullTransfer = vector.fullTransfer
        let sessions = try complete(makeAttempts(vector))
        let originDecision = try sessions.origin.sealSASDecision(matches: true)
        let recipientDecision = try sessions.recipient.sealSASDecision(matches: true)
        _ = try sessions.origin.openPeerSASDecision(recipientDecision)
        _ = try sessions.recipient.openPeerSASDecision(originDecision)

        let key = try legacyPublicKey()
        let keyFrame = try sessions.recipient.sealRecipientPublicKey(key)
        XCTAssertEqual(try sessions.origin.openRecipientPublicKey(keyFrame), key)
        try sessions.origin.recordOriginAuthorization(.approved)
        let proofFrame = try sessions.origin.sealOriginAuthorizationProof()
        try sessions.recipient.openOriginAuthorizationProof(proofFrame)

        let approved = try ApprovedBootstrapManifestV2(
            exportedManifest: legacyManifest(),
            selectedOptionalTransfers: []
        )
        let manifestFrame = try sessions.origin.sealManifest(approved)
        let manifest = try sessions.recipient.openManifest(manifestFrame)
        let acceptance = try LegacyBootstrapImportAcceptanceV2.acknowledging(
            manifest,
            acceptedHostIDs: Set(manifest.hosts.map(\.id))
        )
        let acceptanceFrame = try sessions.recipient.sealImportAcceptance(acceptance)
        XCTAssertEqual(try sessions.origin.openImportAcceptance(acceptanceFrame), acceptance)

        let receipt = LegacyBootstrapGrantBatchReceiptV2(
            publicKeyID: key.id,
            publicKeyFingerprint: key.fingerprint,
            results: manifest.hosts.map {
                LegacyBootstrapHostGrantResultV2(
                    hostID: $0.id,
                    hostName: $0.name,
                    status: .installed,
                    detail: nil
                )
            }
        )
        try receipt.validate(manifest: manifest, publicKey: key)
        let receiptFrame = try sessions.origin.sealGrantReceipt(receipt)
        XCTAssertEqual(try sessions.recipient.openGrantReceipt(receiptFrame), receipt)
        let completion = try LegacyBootstrapGrantCompletionAcknowledgementV2
            .acknowledging(receipt)
        let completionFrame = try sessions.recipient.sealCompletionAcknowledgement(completion)
        XCTAssertEqual(
            try sessions.origin.openCompletionAcknowledgement(completionFrame),
            completion
        )

        let originSeed = try XCTUnwrap(Data(hex: vector.origin.privateKeySeedHex))
        let recipientPublicKey = try XCTUnwrap(Data(hex: vector.recipient.publicKeyHex))
        let sharedSecret = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: originSeed
        ).sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        )
        func material(_ label: String, count: Int) -> Data {
            sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: sessions.origin.transcriptHash,
                sharedInfo: Data("tessera/nearby-bootstrap/\(label)/v1".utf8),
                outputByteCount: count
            ).withUnsafeBytes { Data($0) }
        }

        let originKey = material("key/origin-to-recipient", count: 32)
        let recipientKey = material("key/recipient-to-origin", count: 32)
        let originNonce = material("nonce/origin-to-recipient", count: 12)
        let recipientNonce = material("nonce/recipient-to-origin", count: 12)
        XCTAssertEqual(originKey.hex, vector.directionalMaterial.originToRecipientKeyHex)
        XCTAssertEqual(recipientKey.hex, vector.directionalMaterial.recipientToOriginKeyHex)
        XCTAssertEqual(originNonce.hex, vector.directionalMaterial.originToRecipientNonceHex)
        XCTAssertEqual(recipientNonce.hex, vector.directionalMaterial.recipientToOriginNonceHex)
        XCTAssertEqual(
            String(decoding: try canonicalJSON(key), as: UTF8.self),
            fullTransfer.recipientPublicKeyCanonicalJSON
        )
        XCTAssertEqual(
            String(decoding: try manifest.encoded(), as: UTF8.self),
            fullTransfer.manifestCanonicalJSON
        )
        XCTAssertEqual(
            String(decoding: try canonicalJSON(acceptance), as: UTF8.self),
            fullTransfer.importAcceptanceCanonicalJSON
        )
        XCTAssertEqual(
            String(decoding: try canonicalJSON(receipt), as: UTF8.self),
            fullTransfer.grantReceiptCanonicalJSON
        )
        XCTAssertEqual(
            String(decoding: try canonicalJSON(completion), as: UTF8.self),
            fullTransfer.completionAcknowledgementCanonicalJSON
        )
        for (name, kind, payload, direction, sequence, frame) in [
            ("recipient-public-key", "recipientPublicKey", try canonicalJSON(key), 2, 1, keyFrame),
            ("origin-authorization-proof", "originAuthorization", Data(), 1, 1, proofFrame),
            ("origin-manifest", "manifest", try manifest.encoded(), 1, 2, manifestFrame),
            ("recipient-import-acceptance", "importAcceptance", try canonicalJSON(acceptance), 2, 2, acceptanceFrame),
            ("origin-grant-receipt", "grantReceipt", try canonicalJSON(receipt), 1, 3, receiptFrame),
            ("recipient-completion-acknowledgement", "completionAcknowledgement", try canonicalJSON(completion), 2, 3, completionFrame),
        ] {
            let expected = try XCTUnwrap(fullTransfer.frames.first { $0.name == name })
            let key = direction == 1 ? originKey : recipientKey
            let nonce = direction == 1 ? originNonce : recipientNonce
            let kindFirst = try legacyVectorFrame(
                kind: kind,
                payload: payload,
                direction: UInt8(direction),
                sequence: UInt64(sequence),
                key: key,
                baseNonce: nonce,
                transcriptHash: sessions.origin.transcriptHash,
                payloadFirst: false
            )
            let payloadFirst = try legacyVectorFrame(
                kind: kind,
                payload: payload,
                direction: UInt8(direction),
                sequence: UInt64(sequence),
                key: key,
                baseNonce: nonce,
                transcriptHash: sessions.origin.transcriptHash,
                payloadFirst: true
            )
            XCTAssertTrue(frame == kindFirst || frame == payloadFirst)
            XCTAssertEqual(kindFirst.hex, expected.frameHex, name)
            XCTAssertEqual(payloadFirst.hex, expected.alternateFrameHex, name)
            XCTAssertEqual(expected.kind, kind)
            XCTAssertEqual(expected.directionByte, UInt8(direction))
            XCTAssertEqual(expected.sequence, UInt64(sequence))
            try assertFrameMetadata(frame, expected: expected)
        }
        XCTAssertEqual(Set(fullTransfer.frames.map(\.name)), Set([
            "recipient-public-key", "origin-authorization-proof", "origin-manifest",
            "recipient-import-acceptance", "origin-grant-receipt",
            "recipient-completion-acknowledgement",
        ]))

        try assertFullTransferFramesAccepted(vector: vector, alternate: false)
        try assertFullTransferFramesAccepted(vector: vector, alternate: true)
    }

    func testCleartextMessagesEnforceLocalEncodedAndDecodedByteLimits() throws {
        let maximum = LegacyNearbyBootstrapV2.maximumHandshakeMessageSize
        XCTAssertEqual(maximum, LegacyNearbyBootstrapV2.maximumHelloMessageSize)
        XCTAssertEqual(maximum, LegacyNearbyBootstrapV2.maximumCommitmentMessageSize)

        let baseHello = LegacyNearbyHandshakeHelloV2(
            role: .origin,
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            appVersion: ""
        )
        let baseHelloSize = try baseHello.encoded().count
        let boundaryHello = LegacyNearbyHandshakeHelloV2(
            role: .origin,
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            appVersion: String(repeating: "a", count: maximum - baseHelloSize)
        )
        XCTAssertEqual(try boundaryHello.encoded().count, maximum)
        let oversizedHello = LegacyNearbyHandshakeHelloV2(
            role: .origin,
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            appVersion: String(repeating: "a", count: maximum - baseHelloSize + 1)
        )
        XCTAssertThrowsError(try oversizedHello.encoded()) {
            XCTAssertEqual($0 as? LegacyNearbyHandshakeErrorV2, .invalidFrame)
        }

        let baseAttempt = LegacyNearbyHandshakeV2.begin(
            role: .recipient,
            appVersion: ""
        )
        let baseCommitmentSize = try LegacyNearbyHandshakeV2
            .recipientCommitment(for: baseAttempt).encoded().count
        let boundaryAttempt = LegacyNearbyHandshakeV2.begin(
            role: .recipient,
            appVersion: String(repeating: "b", count: maximum - baseCommitmentSize)
        )
        XCTAssertEqual(
            try LegacyNearbyHandshakeV2.recipientCommitment(for: boundaryAttempt).encoded().count,
            maximum
        )
        let oversizedAttempt = LegacyNearbyHandshakeV2.begin(
            role: .recipient,
            appVersion: String(repeating: "b", count: maximum - baseCommitmentSize + 1)
        )
        XCTAssertThrowsError(
            try LegacyNearbyHandshakeV2.recipientCommitment(for: oversizedAttempt).encoded()
        ) {
            XCTAssertEqual($0 as? LegacyNearbyHandshakeErrorV2, .invalidFrame)
        }

        let exactBoundary = versionClaim(version: 3, byteCount: maximum)
        XCTAssertThrowsError(try LegacyNearbyHandshakeHelloV2.decode(exactBoundary)) {
            guard case .incompatiblePeerVersion(let info, message: .hello) =
                $0 as? LegacyNearbyHandshakeErrorV2 else {
                return XCTFail("expected the exact-size hello to reach version probing")
            }
            XCTAssertEqual(info.version, 3)
        }
        XCTAssertThrowsError(try LegacyNearbyHandshakeCommitmentV2.decode(exactBoundary)) {
            guard case .incompatiblePeerVersion(let info, message: .commitment) =
                $0 as? LegacyNearbyHandshakeErrorV2 else {
                return XCTFail("expected the exact-size commitment to reach version probing")
            }
            XCTAssertEqual(info.version, 3)
        }
        let oversizedBoundary = exactBoundary + Data([0x20])
        XCTAssertThrowsError(try LegacyNearbyHandshakeHelloV2.decode(oversizedBoundary)) {
            XCTAssertEqual($0 as? LegacyNearbyHandshakeErrorV2, .invalidFrame)
        }
        XCTAssertThrowsError(try LegacyNearbyHandshakeCommitmentV2.decode(oversizedBoundary)) {
            XCTAssertEqual($0 as? LegacyNearbyHandshakeErrorV2, .invalidFrame)
        }
    }

    func testEncryptedFramesEnforceLocalByteLimitWithoutConsumingSequence() throws {
        let vector = try loadVector()
        let sessions = try complete(makeAttempts(vector))
        let originDecision = try sessions.origin.sealSASDecision(matches: true)
        let recipientDecision = try sessions.recipient.sealSASDecision(matches: true)
        XCTAssertTrue(try sessions.origin.openPeerSASDecision(recipientDecision))
        XCTAssertTrue(try sessions.recipient.openPeerSASDecision(originDecision))

        XCTAssertThrowsError(
            try sessions.origin.sealTestPayload(Data(repeating: 0x41, count: 50_000))
        ) {
            XCTAssertEqual($0 as? LegacyNearbyHandshakeErrorV2, .invalidFrame)
        }
        let afterRejectedOversize = try sessions.origin.sealTestPayload(Data("still-sequence-one".utf8))
        XCTAssertEqual(
            try sessions.recipient.openTestPayload(afterRejectedOversize),
            Data("still-sequence-one".utf8)
        )

        var exactBoundary = Data(
            repeating: 0,
            count: LegacyNearbyBootstrapV2.maximumEncryptedFrameSize
        )
        exactBoundary.replaceSubrange(0..<4, with: [0x54, 0x42, 0x43, 0x48])
        exactBoundary[4] = 2
        XCTAssertThrowsError(try sessions.origin.openTestPayload(exactBoundary)) {
            XCTAssertEqual($0 as? LegacyNearbyHandshakeErrorV2, .unsupportedFrameVersion(2))
        }
        XCTAssertThrowsError(try sessions.origin.openTestPayload(exactBoundary + Data([0]))) {
            XCTAssertEqual($0 as? LegacyNearbyHandshakeErrorV2, .invalidFrame)
        }
    }

    func testReleasedAppleV2CanonicalVectorCompletely() throws {
        let vector = try loadVector()
        XCTAssertEqual(vector.protocolVersion, LegacyNearbyBootstrapV2.version)
        XCTAssertEqual(vector.releasedAppVersion, "0.3.6")

        let originSeed = try XCTUnwrap(Data(hex: vector.origin.privateKeySeedHex))
        let recipientSeed = try XCTUnwrap(Data(hex: vector.recipient.privateKeySeedHex))
        let originPublicKey = try XCTUnwrap(Data(hex: vector.origin.publicKeyHex))
        let recipientPublicKey = try XCTUnwrap(Data(hex: vector.recipient.publicKeyHex))

        let originHello = LegacyNearbyHandshakeHelloV2(
            version: vector.protocolVersion,
            role: .origin,
            ephemeralPublicKey: originPublicKey,
            appVersion: vector.releasedAppVersion,
            supportedVersions: [vector.protocolVersion]
        )
        let recipientHello = LegacyNearbyHandshakeHelloV2(
            version: vector.protocolVersion,
            role: .recipient,
            ephemeralPublicKey: recipientPublicKey,
            appVersion: vector.releasedAppVersion,
            supportedVersions: [vector.protocolVersion]
        )
        XCTAssertEqual(try originHello.encoded(), Data(vector.origin.canonicalHelloJSON.utf8))
        XCTAssertEqual(try recipientHello.encoded(), Data(vector.recipient.canonicalHelloJSON.utf8))
        XCTAssertEqual(
            try LegacyNearbyHandshakeV2.commitmentProjection(for: recipientHello),
            Data(vector.commitment.canonicalProjectionJSON.utf8)
        )

        let attempts = try makeAttempts(vector)
        XCTAssertEqual(attempts.origin.hello.ephemeralPublicKey, originPublicKey)
        XCTAssertEqual(attempts.recipient.hello.ephemeralPublicKey, recipientPublicKey)
        let commitment = try LegacyNearbyHandshakeV2.recipientCommitment(
            for: attempts.recipient
        )
        XCTAssertEqual(commitment.helloDigest.hex, vector.commitment.helloDigestHex)
        let commitmentBytes = Data(vector.commitment.canonicalJSON.utf8)
        XCTAssertEqual(
            try LegacyNearbyHandshakeCommitmentV2.decode(commitmentBytes).encoded(),
            commitmentBytes
        )

        let transcript = try LegacyNearbyHandshakeV2.makeTranscript(
            originHello: originHello,
            recipientHello: recipientHello
        )
        XCTAssertEqual(transcript.hex, vector.transcriptHex)

        let sessions = try complete(attempts)
        XCTAssertEqual(sessions.origin.transcriptHash.hex, vector.transcriptHashHex)
        XCTAssertEqual(sessions.recipient.transcriptHash, sessions.origin.transcriptHash)
        XCTAssertEqual(sessions.origin.sas.digits, vector.sasDigits)
        XCTAssertEqual(sessions.recipient.sas, sessions.origin.sas)

        let sharedSecret = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: originSeed
        ).sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        )
        let sasMaterial = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: sessions.origin.transcriptHash,
            sharedInfo: Data("tessera/nearby-bootstrap/sas/v1".utf8),
            outputByteCount: 8
        )
        XCTAssertEqual(
            sasMaterial.withUnsafeBytes { Data($0).hex },
            vector.sasBytesHex
        )

        let originDecision = try sessions.origin.sealSASDecision(matches: true)
        let recipientDecision = try sessions.recipient.sealSASDecision(matches: true)
        XCTAssertTrue(try sessions.origin.openPeerSASDecision(recipientDecision))
        XCTAssertTrue(try sessions.recipient.openPeerSASDecision(originDecision))
        let originTest = try sessions.origin.sealTestPayload(Data("origin-vector".utf8))
        let recipientTest = try sessions.recipient.sealTestPayload(Data("recipient-vector".utf8))

        try assertGenerated(originDecision, named: "origin-sas-match", vector: vector)
        try assertGenerated(recipientDecision, named: "recipient-sas-match", vector: vector)
        try assertGenerated(originTest, named: "origin-debug-test", vector: vector)
        try assertGenerated(recipientTest, named: "recipient-debug-test", vector: vector)

        for alternate in [false, true] {
            try assertOriginFramesAccepted(vector: vector, alternate: alternate)
            try assertRecipientFramesAccepted(vector: vector, alternate: alternate)
        }

        XCTAssertEqual(originSeed.hex, vector.origin.privateKeySeedHex)
        XCTAssertEqual(recipientSeed.hex, vector.recipient.privateKeySeedHex)
        XCTAssertEqual(Set(vector.frames.map(\.name)), [
            "origin-sas-match", "recipient-sas-match",
            "origin-debug-test", "recipient-debug-test",
        ])
    }

    private func assertOriginFramesAccepted(
        vector: Vector,
        alternate: Bool
    ) throws {
        let sessions = try complete(makeAttempts(vector))
        _ = try sessions.recipient.sealSASDecision(matches: true)
        let decision = try frame(named: "origin-sas-match", vector: vector, alternate: alternate)
        XCTAssertTrue(try sessions.recipient.openPeerSASDecision(decision))
        let test = try frame(named: "origin-debug-test", vector: vector, alternate: alternate)
        XCTAssertEqual(try sessions.recipient.openTestPayload(test), Data("origin-vector".utf8))
    }

    private func assertRecipientFramesAccepted(
        vector: Vector,
        alternate: Bool
    ) throws {
        let sessions = try complete(makeAttempts(vector))
        _ = try sessions.origin.sealSASDecision(matches: true)
        let decision = try frame(named: "recipient-sas-match", vector: vector, alternate: alternate)
        XCTAssertTrue(try sessions.origin.openPeerSASDecision(decision))
        let test = try frame(named: "recipient-debug-test", vector: vector, alternate: alternate)
        XCTAssertEqual(try sessions.origin.openTestPayload(test), Data("recipient-vector".utf8))
    }

    private func assertFullTransferFramesAccepted(
        vector: Vector,
        alternate: Bool
    ) throws {
        let sessions = try complete(makeAttempts(vector))
        _ = try sessions.origin.sealSASDecision(matches: true)
        _ = try sessions.recipient.sealSASDecision(matches: true)
        XCTAssertTrue(try sessions.origin.openPeerSASDecision(
            frame(named: "recipient-sas-match", vector: vector, alternate: alternate)
        ))
        XCTAssertTrue(try sessions.recipient.openPeerSASDecision(
            frame(named: "origin-sas-match", vector: vector, alternate: alternate)
        ))

        let publicKey = try legacyPublicKey()
        _ = try sessions.recipient.sealRecipientPublicKey(publicKey)
        XCTAssertEqual(
            try sessions.origin.openRecipientPublicKey(
                fullTransferFrame(
                    named: "recipient-public-key",
                    vector: vector,
                    alternate: alternate
                )
            ),
            publicKey
        )
        try sessions.origin.recordOriginAuthorization(.approved)
        _ = try sessions.origin.sealOriginAuthorizationProof()
        try sessions.recipient.openOriginAuthorizationProof(
            fullTransferFrame(
                named: "origin-authorization-proof",
                vector: vector,
                alternate: alternate
            )
        )

        let approved = try ApprovedBootstrapManifestV2(
            exportedManifest: legacyManifest(),
            selectedOptionalTransfers: []
        )
        _ = try sessions.origin.sealManifest(approved)
        let manifest = try sessions.recipient.openManifest(
            fullTransferFrame(
                named: "origin-manifest",
                vector: vector,
                alternate: alternate
            )
        )
        let acceptance = try LegacyBootstrapImportAcceptanceV2.acknowledging(
            manifest,
            acceptedHostIDs: Set(manifest.hosts.map(\.id))
        )
        _ = try sessions.recipient.sealImportAcceptance(acceptance)
        XCTAssertEqual(
            try sessions.origin.openImportAcceptance(
                fullTransferFrame(
                    named: "recipient-import-acceptance",
                    vector: vector,
                    alternate: alternate
                )
            ),
            acceptance
        )

        let receipt = LegacyBootstrapGrantBatchReceiptV2(
            publicKeyID: publicKey.id,
            publicKeyFingerprint: publicKey.fingerprint,
            results: manifest.hosts.map {
                LegacyBootstrapHostGrantResultV2(
                    hostID: $0.id,
                    hostName: $0.name,
                    status: .installed,
                    detail: nil
                )
            }
        )
        _ = try sessions.origin.sealGrantReceipt(receipt)
        XCTAssertEqual(
            try sessions.recipient.openGrantReceipt(
                fullTransferFrame(
                    named: "origin-grant-receipt",
                    vector: vector,
                    alternate: alternate
                )
            ),
            receipt
        )
        let completion = try LegacyBootstrapGrantCompletionAcknowledgementV2
            .acknowledging(receipt)
        _ = try sessions.recipient.sealCompletionAcknowledgement(completion)
        XCTAssertEqual(
            try sessions.origin.openCompletionAcknowledgement(
                fullTransferFrame(
                    named: "recipient-completion-acknowledgement",
                    vector: vector,
                    alternate: alternate
                )
            ),
            completion
        )
    }

    private func assertGenerated(
        _ data: Data,
        named name: String,
        vector: Vector
    ) throws {
        let expected = try XCTUnwrap(vector.frames.first { $0.name == name })
        XCTAssertTrue(
            data.hex == expected.frameHex || data.hex == expected.alternateFrameHex,
            "\(name) did not match either released Foundation JSON spelling"
        )
        try assertFrameMetadata(data, expected: expected)
        try assertFrameMetadata(
            XCTUnwrap(Data(hex: expected.frameHex)),
            expected: expected
        )
        try assertFrameMetadata(
            XCTUnwrap(Data(hex: expected.alternateFrameHex)),
            expected: expected
        )
        XCTAssertNotEqual(expected.frameHex, expected.alternateFrameHex)
    }

    private func assertFrameMetadata(_ data: Data, expected: Vector.Frame) throws {
        XCTAssertEqual(data.prefix(4), Data([0x54, 0x42, 0x43, 0x48]))
        XCTAssertEqual(data[4], expected.frameVersion)
        XCTAssertEqual(data[5], expected.directionByte)
        XCTAssertEqual(data.subdata(in: 6..<14).uint64BigEndian, expected.sequence)
        XCTAssertEqual(
            expected.direction,
            expected.directionByte == 1 ? "originToRecipient" : "recipientToOrigin"
        )
    }

    private func frame(
        named name: String,
        vector: Vector,
        alternate: Bool
    ) throws -> Data {
        let value = try XCTUnwrap(vector.frames.first { $0.name == name })
        return try XCTUnwrap(Data(hex: alternate ? value.alternateFrameHex : value.frameHex))
    }

    private func fullTransferFrame(
        named name: String,
        vector: Vector,
        alternate: Bool
    ) throws -> Data {
        let value = try XCTUnwrap(vector.fullTransfer.frames.first { $0.name == name })
        return try XCTUnwrap(Data(hex: alternate ? value.alternateFrameHex : value.frameHex))
    }

    private func makeAttempts(
        _ vector: Vector
    ) throws -> (
        origin: LegacyNearbyHandshakeAttemptV2,
        recipient: LegacyNearbyHandshakeAttemptV2
    ) {
        (
            try LegacyNearbyHandshakeV2.begin(
                role: .origin,
                deterministicPrivateKey: XCTUnwrap(Data(hex: vector.origin.privateKeySeedHex)),
                appVersion: vector.releasedAppVersion
            ),
            try LegacyNearbyHandshakeV2.begin(
                role: .recipient,
                deterministicPrivateKey: XCTUnwrap(Data(hex: vector.recipient.privateKeySeedHex)),
                appVersion: vector.releasedAppVersion
            )
        )
    }

    private func complete(
        _ attempts: (
            origin: LegacyNearbyHandshakeAttemptV2,
            recipient: LegacyNearbyHandshakeAttemptV2
        )
    ) throws -> (
        origin: LegacyNearbyManifestTransferSessionV2,
        recipient: LegacyNearbyManifestTransferSessionV2
    ) {
        let commitment = try LegacyNearbyHandshakeV2.recipientCommitment(
            for: attempts.recipient
        )
        return (
            try LegacyNearbyHandshakeV2.completeOrigin(
                attempts.origin,
                with: attempts.recipient.hello,
                verifying: commitment
            ),
            try LegacyNearbyHandshakeV2.completeRecipient(
                attempts.recipient,
                with: attempts.origin.hello
            )
        )
    }

    private func loadVector() throws -> Vector {
        try JSONDecoder().decode(
            Vector.self,
            from: Data(contentsOf: vectorURL())
        )
    }

    private func vectorURL() -> URL {
        vectorDirectoryURL().appendingPathComponent("canonical.json")
    }

    private func vectorDirectoryURL() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root
            .appendingPathComponent("ProtocolVectors")
            .appendingPathComponent("legacy-nearby-bootstrap/v2")
    }

    private func versionClaim(version: Int, byteCount: Int) -> Data {
        let prefix = Data(#"{"version":\#(version),"padding":""#.utf8)
        let suffix = Data(#""}"#.utf8)
        precondition(prefix.count + suffix.count <= byteCount)
        return prefix
            + Data(repeating: 0x61, count: byteCount - prefix.count - suffix.count)
            + suffix
    }

    private func canonicalJSON<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func legacyPublicKey() throws -> EnrollmentPublicKeyV1 {
        let key = EnrollmentPublicKeyV1(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            displayName: "Recipient key",
            algorithm: .ed25519,
            blob: "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f",
            fingerprint: "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA",
            protection: .software
        )
        try key.validate()
        return key
    }

    private func legacyManifest(agentCenterEnabled: Bool? = nil) -> BootstrapManifestV2 {
        BootstrapManifestV2(
            hosts: [BootstrapHostDescriptor(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                name: "vector-host",
                address: "server.example",
                user: "alice",
                transport: .ssh,
                launchMode: .autoTmux,
                authenticationHint: .publicKey
            )],
            jumpChains: [],
            appearance: BootstrapAppearanceSettings(
                colorScheme: "system",
                accent: "blue",
                customAccentRGB: 31_487,
                monospacedFontName: "SFMono-Regular",
                terminalFontSize: 14,
                chromeMaterial: "system",
                cursorStyle: "block",
                cursorBlink: true,
                terminalThemeID: "default"
            ),
            settings: BootstrapGeneralSettings(
                scrollbackLines: 10_000,
                modifierBehavior: "oneShot",
                bellSoundEnabled: false,
                bellVisualEnabled: true,
                bellNotificationEnabled: false,
                accessoryBarKeys: [],
                filesReaperDays: 30,
                filesDefaultDestination: "cwd",
                agentCenterEnabled: agentCenterEnabled
            )
        )
    }

    private func legacyVectorFrame(
        kind: String,
        payload: Data,
        direction: UInt8,
        sequence: UInt64,
        key: Data,
        baseNonce: Data,
        transcriptHash: Data,
        payloadFirst: Bool
    ) throws -> Data {
        var header = Data([0x54, 0x42, 0x43, 0x48, 1, direction])
        for shift in stride(from: 56, through: 0, by: -8) {
            header.append(UInt8(truncatingIfNeeded: sequence >> UInt64(shift)))
        }
        var nonce = Array(baseNonce)
        for (index, shift) in stride(from: 56, through: 0, by: -8).enumerated() {
            nonce[nonce.count - 8 + index] ^= UInt8(
                truncatingIfNeeded: sequence >> UInt64(shift)
            )
        }
        let payloadBase64 = payload.base64EncodedString()
        let plaintext = payloadFirst
            ? Data("{\"payload\":\"\(payloadBase64)\",\"kind\":\"\(kind)\"}".utf8)
            : Data("{\"kind\":\"\(kind)\",\"payload\":\"\(payloadBase64)\"}".utf8)
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: ChaChaPoly.Nonce(data: nonce),
            authenticating: header + transcriptHash
        )
        return header + box.combined
    }
}

private struct Vector: Decodable {
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
        let kind: String?
        let direction: String
        let directionByte: UInt8
        let sequence: UInt64
        let frameVersion: UInt8
        let frameHex: String
        let alternateFrameHex: String
    }

    struct DirectionalMaterial: Decodable {
        let originToRecipientKeyHex: String
        let recipientToOriginKeyHex: String
        let originToRecipientNonceHex: String
        let recipientToOriginNonceHex: String
    }

    struct FullTransfer: Decodable {
        let recipientPublicKeyCanonicalJSON: String
        let manifestCanonicalJSON: String
        let importAcceptanceCanonicalJSON: String
        let grantReceiptCanonicalJSON: String
        let completionAcknowledgementCanonicalJSON: String
        let frames: [Frame]
    }

    let protocolVersion: Int
    let releasedAppVersion: String
    let origin: Participant
    let recipient: Participant
    let commitment: Commitment
    let transcriptHex: String
    let transcriptHashHex: String
    let sasBytesHex: String
    let sasDigits: String
    let directionalMaterial: DirectionalMaterial
    let fullTransfer: FullTransfer
    let frames: [Frame]
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

    var uint64BigEndian: UInt64 {
        reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
