import Foundation
import Crypto
import TesseraEnrollmentCore
import TesseraPairingCore
import TesseraProtocolCore
import TesseraSessionCore
@testable import TesseraBootstrapCore
import XCTest

final class BootstrapTransactionV1Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let offerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testFullTransactionRequiresEveryDurableReceiptInOrder() async throws {
        try await checkFullTransaction(version: 1)
    }

    func testV2FullTransactionMatchesCanonicalVectorsAndDurableOrdering() async throws {
        try await checkFullTransaction(version: 2)
    }

    private func checkFullTransaction(version: Int) async throws {
        let paired = try confirmedSessions(originVersions: [version], recipientVersions: [version])
        let observer = try confirmedSessions(originVersions: [version], recipientVersions: [version])
        var origin = try BootstrapTransactionV1(session: paired.origin)
        var recipient = try BootstrapTransactionV1(session: paired.recipient)
        let key = try publicKey()
        let manifest = fixtureManifest()

        let keyMessage = try recipient.makeRecipientPublicKey(key)
        _ = try observer.origin.open(keyMessage)
        XCTAssertEqual(try origin.receiveRecipientPublicKey(keyMessage), key)

        let grantEngine = DeviceAccessGrantEngine(now: { self.now })
        let scope = OwnerAuthorizationScope(
            routeIdentity: try BootstrapTransactionV1.routeIdentity(
                for: manifest.hosts[0].id,
                in: manifest
            ),
            hostID: manifest.hosts[0].id,
            publicKeyFingerprint: key.fingerprint
        )
        let request = OwnerAuthorizationRequest(
            attemptID: offerID,
            policyGeneration: 7,
            scope: scope,
            expiresAt: now.addingTimeInterval(60)
        )
        let authorization = try await grantEngine.mint(
            from: FreshOwnerAuthorization(
                attemptID: offerID,
                policyGeneration: 7,
                scope: scope,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(60)
            ),
            expected: request
        )
        let proof = try await origin.consumeOwnerAuthorizations(
            [authorization],
            selectedHostIDs: manifest.hosts.map(\.id),
            using: grantEngine
        )
        _ = try observer.recipient.open(proof)
        XCTAssertEqual(try recipient.receiveAuthorizationProof(proof).policyGeneration, 7)

        let messages = try origin.makeManifestMessages(manifest, policyGeneration: 7)
        XCTAssertGreaterThanOrEqual(messages.count, 3)
        var receivedManifest: BootstrapManifestV2?
        for message in messages {
            _ = try observer.recipient.open(message)
            if let value = try recipient.receiveManifestMessage(message) {
                receivedManifest = value
            }
        }
        XCTAssertEqual(receivedManifest, manifest)

        let acceptance = try recipient.importDurablyApplied(
            acceptedHostIDs: manifest.hosts.map(\.id),
            at: now
        )
        let acceptanceMessage = try observer.origin.open(acceptance).payload
        let accepted = try origin.receiveImportAcceptance(acceptance)
        XCTAssertEqual(accepted.acceptedHostIDs, manifest.hosts.map(\.id))

        for invalidResults in [
            [BootstrapHostGrantResultV1(
                hostID: manifest.hosts[0].id,
                status: .installed,
                errorCode: "unexpected"
            )],
            [BootstrapHostGrantResultV1(
                hostID: manifest.hosts[0].id,
                status: .failed
            )],
            [],
        ] {
            XCTAssertThrowsError(try origin.remoteGrantsDurablyVerified(
                invalidResults,
                at: now,
                policyGeneration: 7
            )) {
                XCTAssertEqual($0 as? BootstrapTransactionError, .invalidGrantReceipt)
            }
        }

        let incompleteReceipt = BootstrapGrantReceiptV1(
            manifestHash: accepted.manifestHash,
            publicKeyFingerprint: key.fingerprint,
            results: [],
            verifiedAt: now
        )
        let incompleteReceiptMessage = try BootstrapTransactionMessageV1(
            version: version,
            transactionID: offerID,
            kind: .grantReceipt,
            body: BootstrapTransactionCodec.encode(incompleteReceipt)
        ).encoded(expectedVersion: version)
        let incompleteReceiptFrame = try paired.origin.sealTransactionMessage(
            incompleteReceiptMessage
        )
        _ = try observer.recipient.open(incompleteReceiptFrame)
        XCTAssertThrowsError(try recipient.receiveGrantReceipt(incompleteReceiptFrame)) {
            XCTAssertEqual($0 as? BootstrapTransactionError, .invalidGrantReceipt)
        }

        let receiptMessage = try origin.remoteGrantsDurablyVerified(
            [BootstrapHostGrantResultV1(hostID: manifest.hosts[0].id, status: .installed)],
            at: now,
            policyGeneration: 7
        )
        let receiptInnerMessage = try observer.recipient.open(receiptMessage).payload
        let receipt = try recipient.receiveGrantReceipt(receiptMessage)
        XCTAssertEqual(receipt.results.map(\.status), [.installed])

        let acknowledgement = try recipient.accessStateDurablyRecorded(at: now)
        let acknowledgementMessage = try observer.origin.open(acknowledgement).payload
        let completionMessage = try origin.receiveGrantAcknowledgement(acknowledgement)
        let completionInnerMessage = try observer.recipient.open(completionMessage).payload
        let completion = try recipient.receiveCompletion(completionMessage)
        XCTAssertEqual(origin.state, .completed(completion))
        XCTAssertEqual(recipient.state, .completed(completion))
        origin.securityPolicyChanged(to: 7)
        recipient.applicationDidLock()
        XCTAssertEqual(origin.state, .completed(completion))
        XCTAssertEqual(recipient.state, .completed(completion))
        XCTAssertThrowsError(try origin.abort(code: "late_abort")) {
            XCTAssertEqual($0 as? BootstrapTransactionError, .invalidTransition)
        }

        let vectorData = try Data(
            contentsOf: vectorURL("bootstrap-transaction/v\(version)/receipts.json")
        )
        let expectedVector = try XCTUnwrap(
            JSONSerialization.jsonObject(with: vectorData) as? [String: String]
        )
        let actualVector: [String: String] = [
            "importAcceptanceMessageBase64": acceptanceMessage.base64EncodedString(),
            "grantReceiptMessageBase64": receiptInnerMessage.base64EncodedString(),
            "grantAcknowledgementMessageBase64": acknowledgementMessage.base64EncodedString(),
            "completionMessageBase64": completionInnerMessage.base64EncodedString(),
        ]
        XCTAssertEqual(actualVector, expectedVector)
        for encoded in expectedVector.values {
            let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
            let message = try BootstrapTransactionMessageV1.decode(bytes, expectedVersion: version)
            XCTAssertEqual(try message.encoded(expectedVersion: version), bytes)
        }
    }

    func testNegotiationMatrixGatesManifestExtensionAndPreservesExplicitFalse() async throws {
        for originVersions in [[1], [1, 2]] {
            for recipientVersions in [[1], [1, 2]] {
                let selected = Set(originVersions).intersection(recipientVersions).max()!
                for enabled in [true, false] {
                    let manifest = fixtureManifest(agentCenterEnabled: selected == 2 ? enabled : nil)
                    var transactions = try await authorizedTransactions(for: manifest,
                        originVersions: originVersions, recipientVersions: recipientVersions)
                    XCTAssertEqual(transactions.origin.version, selected)
                    XCTAssertEqual(transactions.recipient.version, selected)
                    XCTAssertEqual(transactions.origin.peerSupportsAgentCenterEnabled, selected == 2)
                    let bytes = try manifest.encoded()
                    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                    let settings = try XCTUnwrap(root["settings"] as? [String: Any])
                    XCTAssertEqual(settings["agentCenterEnabled"] as? Bool, selected == 2 ? enabled : nil)
                    var received: BootstrapManifestV2?
                    for frame in try transactions.origin.makeManifestMessages(manifest, policyGeneration: 7) {
                        received = try transactions.recipient.receiveManifestMessage(frame) ?? received
                    }
                    XCTAssertEqual(received?.settings.agentCenterEnabled, selected == 2 ? enabled : nil)
                    if selected == 1 {
                        var other = try await authorizedTransactions(for: manifest,
                            originVersions: originVersions, recipientVersions: recipientVersions)
                        XCTAssertThrowsError(try other.origin.makeManifestMessages(
                            fixtureManifest(agentCenterEnabled: enabled), policyGeneration: 7)) {
                            XCTAssertEqual($0 as? BootstrapTransactionError, .manifestMismatch)
                        }
                    }
                }
            }
        }
    }

    func testV1ReceiverRejectsExtendedManifestEvenWithValidHashAndAuthorization() async throws {
        for value in [true, false, NSNull()] as [Any] {
            let manifest = fixtureManifest()
            var transaction = try await authorizedTransactions(for: manifest)
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest.encoded()) as? [String: Any])
            var settings = try XCTUnwrap(root["settings"] as? [String: Any])
            settings["agentCenterEnabled"] = value
            root["settings"] = settings
            let bytes = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            let hash = Data(SHA256.hash(data: bytes))
            func seal<T: Codable>(_ kind: BootstrapTransactionMessageKindV1, _ body: T) throws -> Data {
                try transaction.originSession.sealTransactionMessage(BootstrapTransactionMessageV1(
                    transactionID: offerID, kind: kind, body: BootstrapTransactionCodec.encode(body)).encoded())
            }
            _ = try transaction.recipient.receiveManifestMessage(seal(.manifestStart, BootstrapManifestStartV1(
                manifestHash: hash, byteCount: bytes.count, hostIDs: manifest.hosts.map(\.id))))
            _ = try transaction.recipient.receiveManifestMessage(seal(.manifestChunk, BootstrapTransactionChunkV1(
                manifestHash: hash, offset: 0, bytes: bytes)))
            XCTAssertThrowsError(try transaction.recipient.receiveManifestMessage(seal(.manifestEnd,
                BootstrapManifestEndV1(manifestHash: hash)))) {
                XCTAssertEqual($0 as? BootstrapTransactionError, .manifestMismatch)
            }
        }
    }

    func testV2DecoderIsStrictCanonicalAndV1DecoderRejectsIt() throws {
        let data = try BootstrapTransactionMessageV2(transactionID: offerID, kind: .abort,
            body: Data(#"{"code":"user_cancelled"}"#.utf8)).encoded()
        XCTAssertEqual(try BootstrapTransactionMessageV2.decode(data).encoded(), data)
        XCTAssertThrowsError(try BootstrapTransactionMessageV1.decode(data)) {
            XCTAssertEqual($0 as? BootstrapTransactionError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try BootstrapTransactionMessageV2.decode(Data(" ".utf8) + data))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["extra"] = true
        XCTAssertThrowsError(try BootstrapTransactionMessageV2.decode(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])))
        let v1 = try BootstrapTransactionMessageV1(transactionID: offerID, kind: .abort,
            body: Data(#"{"code":"user_cancelled"}"#.utf8)).encoded()
        XCTAssertThrowsError(try BootstrapTransactionMessageV2.decode(v1))
    }

    func testManifestChunkReorderingAndPolicyMutationFailClosed() async throws {
        let sessions = try confirmedSessions()
        var origin = try BootstrapTransactionV1(session: sessions.origin)
        var recipient = try BootstrapTransactionV1(session: sessions.recipient)
        let key = try publicKey()
        let manifest = fixtureManifest()
        _ = try origin.receiveRecipientPublicKey(recipient.makeRecipientPublicKey(key))

        let scope = OwnerAuthorizationScope(
            routeIdentity: try BootstrapTransactionV1.routeIdentity(
                for: manifest.hosts[0].id,
                in: manifest
            ),
            hostID: manifest.hosts[0].id,
            publicKeyFingerprint: key.fingerprint
        )
        let engine = DeviceAccessGrantEngine(now: { self.now })
        let request = OwnerAuthorizationRequest(
            attemptID: offerID,
            policyGeneration: 7,
            scope: scope,
            expiresAt: now.addingTimeInterval(30)
        )
        let authorization = try await engine.mint(
            from: FreshOwnerAuthorization(
                attemptID: offerID,
                policyGeneration: 7,
                scope: scope,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(30)
            ),
            expected: request
        )
        let proof = try await origin.consumeOwnerAuthorizations(
            [authorization],
            selectedHostIDs: manifest.hosts.map(\.id),
            using: engine
        )
        _ = try recipient.receiveAuthorizationProof(proof)
        XCTAssertThrowsError(try origin.makeManifestMessages(manifest, policyGeneration: 8)) {
            XCTAssertEqual($0 as? BootstrapTransactionError, .policyInvalidated)
        }

        let messages = try origin.makeManifestMessages(manifest, policyGeneration: 7)
        XCTAssertNil(try recipient.receiveManifestMessage(messages[0]))
        XCTAssertThrowsError(try recipient.receiveManifestMessage(messages.last!)) {
            guard case .outOfOrder = $0 as? PairingError else {
                return XCTFail("expected authenticated channel ordering failure, got \($0)")
            }
        }
    }

    func testManifestMustMatchEveryAuthorizedExactHostRoute() async throws {
        for version in [1, 2] { try await checkManifestMustMatchEveryAuthorizedExactHostRoute(version: version) }
    }

    private func checkManifestMustMatchEveryAuthorizedExactHostRoute(version: Int) async throws {
        let manifest = fixtureManifest()
        var transactions = try await authorizedTransactions(for: manifest, originVersions: [version], recipientVersions: [version])
        let rejection = try rejectionVector(version: version)

        let changedRoute = fixtureManifest(address: try XCTUnwrap(
            rejection["changedRouteAddress"] as? String
        ))
        XCTAssertThrowsError(
            try transactions.origin.makeManifestMessages(changedRoute, policyGeneration: 7)
        ) {
            XCTAssertEqual($0 as? BootstrapTransactionError, .authorizationScopeMismatch)
        }

        let changedHost = fixtureManifest(
            hostID: try XCTUnwrap(UUID(uuidString: try XCTUnwrap(
                rejection["replacementHostID"] as? String
            )))
        )
        XCTAssertThrowsError(
            try transactions.origin.makeManifestMessages(changedHost, policyGeneration: 7)
        ) {
            XCTAssertEqual($0 as? BootstrapTransactionError, .manifestMismatch)
        }
    }

    func testPolicyAndLockEventsInvalidateActiveTransactionsRegardlessOfGeneration() async throws {
        for version in [1, 2] { try await checkPolicyAndLockEventsInvalidateActiveTransactionsRegardlessOfGeneration(version: version) }
    }

    private func checkPolicyAndLockEventsInvalidateActiveTransactionsRegardlessOfGeneration(version: Int) async throws {
        let rejection = try rejectionVector(version: version)
        var authorized = try await authorizedTransactions(for: fixtureManifest(), originVersions: [version], recipientVersions: [version])
        let first = try confirmedSessions(originVersions: [version], recipientVersions: [version])
        var recipient = try BootstrapTransactionV1(session: first.recipient)

        authorized.origin.securityPolicyChanged(to: try XCTUnwrap(
            rejection["deviceLocalPolicyGenerationCollision"] as? UInt64
        ))
        recipient.applicationDidLock()
        XCTAssertEqual(authorized.origin.state, .aborted("policy_invalidated"))
        XCTAssertEqual(recipient.state, .aborted("application_locked"))

        let second = try confirmedSessions(originVersions: [version], recipientVersions: [version])
        var sender = try BootstrapTransactionV1(session: second.origin)
        var receiver = try BootstrapTransactionV1(session: second.recipient)
        XCTAssertThrowsError(try sender.abort(code: try XCTUnwrap(
            rejection["invalidAbortCode"] as? String
        ))) {
            XCTAssertEqual($0 as? BootstrapTransactionError, .invalidAbort)
        }
        let validCode = try XCTUnwrap(rejection["validAbortCode"] as? String)
        let abortMessage = try sender.abort(code: validCode)
        XCTAssertEqual(try receiver.receiveAbort(abortMessage).code, validCode)
        XCTAssertEqual(sender.state, .aborted(validCode))
        XCTAssertEqual(receiver.state, .aborted(validCode))
        XCTAssertThrowsError(try receiver.receiveAbort(abortMessage)) {
            XCTAssertEqual($0 as? BootstrapTransactionError, .invalidTransition)
        }
    }

    func testTransactionRequiresConfirmedPairingBeforeActivation() throws {
        let sessions = try pairingSessions(confirm: false)
        XCTAssertThrowsError(try BootstrapTransactionV1(session: sessions.origin)) {
            XCTAssertEqual($0 as? BootstrapTransactionError, .invalidTransition)
        }
        XCTAssertThrowsError(try BootstrapTransactionV1(session: sessions.recipient)) {
            XCTAssertEqual($0 as? BootstrapTransactionError, .invalidTransition)
        }
    }

    func testTransactionRejectsRawAndUnrelatedPairingTraffic() throws {
        let exact = try confirmedSessions()
        let unrelated = try confirmedSessions(
            originPrivateKey: Data((64..<96).map(UInt8.init)),
            recipientPrivateKey: Data((96..<128).map(UInt8.init))
        )
        var exactOrigin = try BootstrapTransactionV1(session: exact.origin)
        var exactRecipient = try BootstrapTransactionV1(session: exact.recipient)
        var unrelatedOrigin = try BootstrapTransactionV1(session: unrelated.origin)
        let key = try publicKey()

        let raw = try BootstrapTransactionMessageV1(
            transactionID: offerID,
            kind: .recipientPublicKey,
            body: BootstrapTransactionCodec.encode(BootstrapRecipientPublicKeyV1(key: key))
        ).encoded()
        XCTAssertThrowsError(try exactOrigin.receiveRecipientPublicKey(raw)) {
            XCTAssertEqual($0 as? PairingError, .invalidFrame)
        }

        let frame = try exactRecipient.makeRecipientPublicKey(key)
        XCTAssertNoThrow(try PairingFrameV1.decode(frame))
        XCTAssertThrowsError(try unrelatedOrigin.receiveRecipientPublicKey(frame)) {
            XCTAssertEqual($0 as? PairingError, .authenticationFailed)
        }
        XCTAssertEqual(try exactOrigin.receiveRecipientPublicKey(frame), key)
    }

    func testAbortReceivedThroughExpectedOperationIsSurfacedWithoutMisclassification() throws {
        let paired = try confirmedSessions()
        var origin = try BootstrapTransactionV1(session: paired.origin)
        var recipient = try BootstrapTransactionV1(session: paired.recipient)
        let abort = try recipient.abort(code: "peer_cancelled")

        XCTAssertThrowsError(try origin.receiveRecipientPublicKey(abort)) {
            XCTAssertEqual(
                $0 as? BootstrapTransactionError,
                .remoteAbort("peer_cancelled")
            )
        }
        XCTAssertEqual(origin.state, .aborted("peer_cancelled"))
    }

    func testTransactionChannelRejectsDirectionAndReplay() throws {
        let directionSessions = try confirmedSessions()
        var directionOrigin = try BootstrapTransactionV1(session: directionSessions.origin)
        let wrongDirection = try directionSessions.origin.sealTransactionMessage(Data("bad".utf8))
        XCTAssertThrowsError(try directionOrigin.receiveRecipientPublicKey(wrongDirection)) {
            XCTAssertEqual($0 as? PairingError, .wrongDirection)
        }

        let replaySessions = try confirmedSessions()
        var replayOrigin = try BootstrapTransactionV1(session: replaySessions.origin)
        let malformed = try replaySessions.recipient.sealTransactionMessage(Data("bad".utf8))
        XCTAssertThrowsError(try replayOrigin.receiveRecipientPublicKey(malformed)) {
            XCTAssertEqual($0 as? BootstrapTransactionError, .malformedMessage)
        }
        XCTAssertThrowsError(try replayOrigin.receiveRecipientPublicKey(malformed)) {
            XCTAssertEqual($0 as? PairingError, .replayedFrame(1))
        }
    }

    func testEveryOptionalTransferCategoryRequiresApprovalBoundAuthorization() async throws {
        for version in [1, 2] { try await checkEveryOptionalTransferCategoryRequiresApprovalBoundAuthorization(version: version) }
    }

    private func checkEveryOptionalTransferCategoryRequiresApprovalBoundAuthorization(version: Int) async throws {
        let vector = try optionalTransferRejectionVector(version: version)
        let categoryNames = try XCTUnwrap(vector["optionalCategories"] as? [String])
        XCTAssertEqual(Set(categoryNames), Set(BootstrapOptionalTransfer.allCases.map(\.rawValue)))
        let source = optionalTransferSourceManifest()

        for categoryName in categoryNames {
            let category = try XCTUnwrap(BootstrapOptionalTransfer(rawValue: categoryName))
            let filtered = try source.selectingOptionalTransfers([category])
            var transactions = try await authorizedTransactions(for: filtered, originVersions: [version], recipientVersions: [version])
            XCTAssertThrowsError(
                try transactions.origin.makeManifestMessages(filtered, policyGeneration: 7),
                categoryName
            ) {
                XCTAssertEqual(
                    $0 as? BootstrapTransactionError,
                    .optionalTransferAuthorizationRequired
                )
            }
        }
    }

    func testApprovedOptionalManifestIsBoundToConsumedCapabilityAndExactSnapshot() async throws {
        for version in [1, 2] { try await checkApprovedOptionalManifestIsBoundToConsumedCapabilityAndExactSnapshot(version: version) }
    }

    private func checkApprovedOptionalManifestIsBoundToConsumedCapabilityAndExactSnapshot(version: Int) async throws {
        let vector = try optionalTransferRejectionVector(version: version)
        let selected = Set(try XCTUnwrap(vector["authorizedSelection"] as? [String]).map {
            try XCTUnwrap(BootstrapOptionalTransfer(rawValue: $0))
        })
        let source = optionalTransferSourceManifest()
        let approved = try ApprovedBootstrapManifestV2(
            exportedManifest: source,
            selectedOptionalTransfers: selected
        )
        var transactions = try await authorizedTransactions(for: approved, version: version)

        let changedSelection = try ApprovedBootstrapManifestV2(
            exportedManifest: source,
            selectedOptionalTransfers: [.trustedHostKeys]
        )
        do {
            _ = try await authorizedTransactions(
                for: approved,
                authorizationBindingFor: changedSelection,
                version: version
            )
            XCTFail("mismatched owner-authorization binding must fail")
        } catch {
            XCTAssertEqual(
                error as? BootstrapTransactionError,
                .optionalTransferAuthorizationRequired
            )
        }
        XCTAssertThrowsError(try transactions.origin.makeManifestMessages(
            changedSelection,
            policyGeneration: 7
        )) {
            XCTAssertEqual(
                $0 as? BootstrapTransactionError,
                .optionalTransferAuthorizationRequired
            )
        }

        let changedSource = optionalTransferSourceManifest(note: try XCTUnwrap(
            vector["changedAuthorizedNote"] as? String
        ))
        let changedSnapshot = try ApprovedBootstrapManifestV2(
            exportedManifest: changedSource,
            selectedOptionalTransfers: selected
        )
        XCTAssertThrowsError(try transactions.origin.makeManifestMessages(
            changedSnapshot,
            policyGeneration: 7
        )) {
            XCTAssertEqual(
                $0 as? BootstrapTransactionError,
                .optionalTransferAuthorizationRequired
            )
        }

        let messages = try transactions.origin.makeManifestMessages(
            approved,
            policyGeneration: 7
        )
        var received: BootstrapManifestV2?
        for message in messages {
            if let manifest = try transactions.recipient.receiveManifestMessage(message) {
                received = manifest
            }
        }
        XCTAssertEqual(received, approved.manifest)
        XCTAssertFalse((approved.manifest.knownHosts ?? []).isEmpty)
        XCTAssertNotNil(approved.manifest.hosts[0].hostKeyFingerprint)
        XCTAssertEqual(approved.manifest.hosts[0].notes, source.hosts[0].notes)
        XCTAssertNil(approved.manifest.hosts[0].launchCommand)
        XCTAssertNil(approved.manifest.hosts[0].envVars)
        XCTAssertNil(approved.manifest.hosts[0].startupSnippet)
        XCTAssertThrowsError(try transactions.origin.makeManifestMessages(
            approved,
            policyGeneration: 7
        )) {
            XCTAssertEqual($0 as? BootstrapTransactionError, .invalidTransition)
        }
    }

    private func authorizedTransactions(
        for manifest: BootstrapManifestV2,
        originVersions: [Int] = [1], recipientVersions: [Int] = [1]
    ) async throws -> (origin: BootstrapTransactionV1, recipient: BootstrapTransactionV1, originSession: PairingSessionV1) {
        let sessions = try confirmedSessions(originVersions: originVersions, recipientVersions: recipientVersions)
        var origin = try BootstrapTransactionV1(session: sessions.origin)
        var recipient = try BootstrapTransactionV1(session: sessions.recipient)
        let key = try publicKey()
        _ = try origin.receiveRecipientPublicKey(recipient.makeRecipientPublicKey(key))
        let scope = OwnerAuthorizationScope(
            routeIdentity: try BootstrapTransactionV1.routeIdentity(
                for: manifest.hosts[0].id,
                in: manifest
            ),
            hostID: manifest.hosts[0].id,
            publicKeyFingerprint: key.fingerprint
        )
        let engine = DeviceAccessGrantEngine(now: { self.now })
        let request = OwnerAuthorizationRequest(
            attemptID: offerID,
            policyGeneration: 7,
            scope: scope,
            expiresAt: now.addingTimeInterval(30)
        )
        let authorization = try await engine.mint(
            from: FreshOwnerAuthorization(
                attemptID: offerID,
                policyGeneration: 7,
                scope: scope,
                issuedAt: now,
                expiresAt: request.expiresAt
            ),
            expected: request
        )
        let proof = try await origin.consumeOwnerAuthorizations(
            [authorization],
            selectedHostIDs: manifest.hosts.map(\.id),
            using: engine
        )
        _ = try recipient.receiveAuthorizationProof(proof)
        return (origin, recipient, sessions.origin)
    }

    private func authorizedTransactions(
        for approvedManifest: ApprovedBootstrapManifestV2,
        authorizationBindingFor bindingManifest: ApprovedBootstrapManifestV2? = nil,
        version: Int = 1
    ) async throws -> (origin: BootstrapTransactionV1, recipient: BootstrapTransactionV1) {
        let manifest = approvedManifest.manifest
        let sessions = try confirmedSessions(originVersions: [version], recipientVersions: [version])
        var origin = try BootstrapTransactionV1(session: sessions.origin)
        var recipient = try BootstrapTransactionV1(session: sessions.recipient)
        let key = try publicKey()
        _ = try origin.receiveRecipientPublicKey(recipient.makeRecipientPublicKey(key))
        let scope = OwnerAuthorizationScope(
            routeIdentity: try BootstrapTransactionV1.routeIdentity(
                for: manifest.hosts[0].id,
                in: manifest
            ),
            hostID: manifest.hosts[0].id,
            publicKeyFingerprint: key.fingerprint,
            authorizationBinding: try BootstrapTransactionV1.ownerAuthorizationBinding(
                for: bindingManifest ?? approvedManifest
            )
        )
        let engine = DeviceAccessGrantEngine(now: { self.now })
        let request = OwnerAuthorizationRequest(
            attemptID: offerID,
            policyGeneration: 7,
            scope: scope,
            expiresAt: now.addingTimeInterval(30)
        )
        let authorization = try await engine.mint(
            from: FreshOwnerAuthorization(
                attemptID: offerID,
                policyGeneration: 7,
                scope: scope,
                issuedAt: now,
                expiresAt: request.expiresAt
            ),
            expected: request
        )
        let proof = try await origin.consumeOwnerAuthorizations(
            [authorization],
            approvedManifest: approvedManifest,
            using: engine
        )
        _ = try recipient.receiveAuthorizationProof(proof)
        return (origin, recipient)
    }

    private func confirmedSessions(
        originPrivateKey: Data = Data((0..<32).map(UInt8.init)),
        recipientPrivateKey: Data = Data((32..<64).map(UInt8.init)),
        originVersions: [Int] = [1], recipientVersions: [Int] = [1]
    ) throws -> (origin: PairingSessionV1, recipient: PairingSessionV1) {
        try pairingSessions(
            confirm: true,
            originPrivateKey: originPrivateKey,
            recipientPrivateKey: recipientPrivateKey,
            originVersions: originVersions, recipientVersions: recipientVersions
        )
    }

    private func pairingSessions(
        confirm: Bool,
        originPrivateKey: Data = Data((0..<32).map(UInt8.init)),
        recipientPrivateKey: Data = Data((32..<64).map(UInt8.init)),
        originVersions: [Int] = [1], recipientVersions: [Int] = [1]
    ) throws -> (origin: PairingSessionV1, recipient: PairingSessionV1) {
        let originAttempt = try PairingHandshakeV1.beginOrigin(
            purpose: .bootstrap,
            offerID: offerID,
            currentTime: 1_700_000_000,
            expiresAt: 1_700_000_300,
            endpointCandidates: [],
            oneTimeOpticalSecret: Data((0xA0...0xBF).map(UInt8.init)),
            supportedTransactionVersions: originVersions,
            deterministicPrivateKey: originPrivateKey
        )
        let recipientAttempt = try PairingHandshakeV1.beginRecipient(
            encodedOffer: originAttempt.encodedOffer,
            currentTime: 1_700_000_000,
            supportedTransactionVersions: recipientVersions,
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

    private func publicKey() throws -> DevicePublicKeyDescriptorV2 {
        let blob = "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"
        let value = DevicePublicKeyDescriptorV2(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            displayName: "Android key",
            algorithm: .ed25519,
            sshBlob: blob,
            fingerprint: "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA",
            protectionClaim: .platformStrongHardware
        )
        try value.validate()
        return value
    }

    private func fixtureManifest(
        hostID: UUID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
        address: String = "server.example",
        agentCenterEnabled: Bool? = nil
    ) -> BootstrapManifestV2 {
        BootstrapManifestV2(
            hosts: [BootstrapHostDescriptor(
                id: hostID,
                name: "production",
                address: address,
                user: "alice",
                transport: .ssh,
                launchMode: .autoTmux
            )],
            jumpChains: [],
            appearance: BootstrapAppearanceSettings(
                colorScheme: "system",
                accent: "blue",
                customAccentRGB: 0x00_7A_FF,
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

    private func optionalTransferSourceManifest(
        note: String = "internal note"
    ) -> BootstrapManifestV2 {
        let base = fixtureManifest()
        let host = base.hosts[0]
        let enrichedHost = BootstrapHostDescriptor(
            id: host.id,
            name: host.name,
            address: host.address,
            port: host.port,
            user: host.user,
            transport: host.transport,
            launchMode: host.launchMode,
            tmuxSessionName: host.tmuxSessionName,
            tags: host.tags,
            osHint: host.osHint,
            sortOrder: host.sortOrder,
            authenticationHint: host.authenticationHint,
            identityID: host.identityID,
            hostKeyFingerprint: "SHA256:destination",
            launchCommand: "exec tmux attach -t dev",
            notes: note,
            envVars: "TERM=xterm-256color",
            startupSnippet: "cd /srv/app",
            portForwards: host.portForwards
        )
        let knownHost = BootstrapKnownHostDescriptor(
            hostID: host.id,
            fingerprint: "SHA256:cQoXbReba908/C49JxLoCDmoLE25BznKXbJG8nfohEg=",
            keyString: "ssh-ed25519 "
                + "AAAAC3NzaC1lZDI1NTE5AAAAIOqcFFoJtrRM4aFUrs7PZI8Zz4GfdpExu4M1fWpnD0Ge",
            firstSeen: Date(timeIntervalSinceReferenceDate: 0),
            lastSeen: Date(timeIntervalSinceReferenceDate: 86_400)
        )
        return BootstrapManifestV2(
            identities: base.identities,
            hosts: [enrichedHost],
            jumpChains: base.jumpChains,
            knownHosts: [knownHost],
            appearance: base.appearance,
            settings: base.settings
        )
    }

    private func vectorURL(_ relativePath: String) -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("ProtocolVectors").appendingPathComponent(relativePath)
    }

    private func rejectionVector(version: Int) throws -> [String: Any] {
        let data = try Data(
            contentsOf: vectorURL("bootstrap-transaction/v\(version)/rejections.json")
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func optionalTransferRejectionVector(version: Int) throws -> [String: Any] {
        let data = try Data(
            contentsOf: vectorURL(
                "bootstrap-transaction/v\(version)/optional-transfer-rejections.json"
            )
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
