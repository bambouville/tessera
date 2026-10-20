import Foundation
import XCTest
import TesseraBootstrapCore
import TesseraContinuityCore
import TesseraEnrollmentCore
import TesseraPairingCore
import TesseraProtocolCore
import TesseraSessionCore
@testable import TesseraCoreABI

final class CrossDevicePairingABITests: XCTestCase {
    func testCommandsRejectMalformedOversizedAndNonCanonicalPayloads() throws {
        XCTAssertThrowsError(try CrossDeviceABICommandV1.decode(Data())) {
            XCTAssertEqual($0 as? CrossDeviceABIError, .emptyPayload)
        }
        XCTAssertThrowsError(try CrossDeviceABICommandV1.decode(Data(repeating: 0, count: CrossDeviceABICommandV1.maximumPayloadBytes + 1))) {
            XCTAssertEqual($0 as? CrossDeviceABIError, .payloadTooLarge(CrossDeviceABICommandV1.maximumPayloadBytes + 1))
        }
        let command = try originCommand(generation: 3).encoded()
        let nonCanonical = Data(String(decoding: command, as: UTF8.self).replacingOccurrences(of: ",", with: ", ").utf8)
        XCTAssertThrowsError(try CrossDeviceABICommandV1.decode(nonCanonical)) {
            XCTAssertEqual($0 as? CrossDeviceABIError, .nonCanonicalPayload)
        }
        XCTAssertThrowsError(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: 1, bytes: Data()).encoded()) {
            XCTAssertEqual($0 as? CrossDeviceABIError, .invalidField)
        }
        XCTAssertThrowsError(try CrossDeviceABICommandV1(
            kind: .start, generation: 1, manifest: bootstrapManifest()
        ).encoded()) {
            XCTAssertEqual($0 as? CrossDeviceABIError, .invalidField)
        }
        let maximumChunk = CrossDeviceABICommandV1(
            kind: .receiveBytes,
            generation: .max,
            bytes: Data(repeating: 0, count: CrossDeviceABICommandV1.maximumSocketChunkBytes)
        )
        XCTAssertLessThanOrEqual(try maximumChunk.encoded().count, CrossDeviceABICommandV1.maximumPayloadBytes)
        XCTAssertThrowsError(try CrossDeviceABICommandV1(
            kind: .receiveBytes,
            generation: 1,
            bytes: Data(repeating: 0, count: CrossDeviceABICommandV1.maximumSocketChunkBytes + 1)
        ).encoded()) {
            XCTAssertEqual($0 as? CrossDeviceABIError, .invalidField)
        }
    }

    func testQRTextBoundaryIsCanonicalAndNeverAcceptsRawOfferBytes() async throws {
        let originCapture = CrossDeviceEventCapture()
        let origin = CrossDeviceABIRuntimeV1 { originCapture.receive($0) }
        defer { origin.destroy() }
        origin.submit(try originCommand(generation: 31).encoded())
        await originCapture.wait(forCount: 1)
        origin.submit(try CrossDeviceABICommandV1(kind: .start, generation: 31).encoded())
        await originCapture.wait(forCount: 2)
        let text = String(decoding: try payload(of: .qrOffer, in: originCapture), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(PairingQRTextCodecV1.prefix))

        let recipientCapture = CrossDeviceEventCapture()
        let recipient = CrossDeviceABIRuntimeV1 { recipientCapture.receive($0) }
        defer { recipient.destroy() }
        recipient.submit(try CrossDeviceABICommandV1(
            kind: .createRecipient, generation: 31, supportedTransactionVersions: [1], qrText: text + "="
        ).encoded())
        await recipientCapture.wait(forCount: 1)
        XCTAssertEqual(recipientCapture.events.last?.kind, .commandRejected)
        XCTAssertEqual(recipientCapture.events.last?.code, "invalid_qr_text")
    }

    func testRawSocketChunksSupportFragmentationCoalescingAndFailClosedEOF() async throws {
        let generation: UInt64 = 32
        let originCapture = CrossDeviceEventCapture()
        let recipientCapture = CrossDeviceEventCapture()
        let origin = CrossDeviceABIRuntimeV1 { originCapture.receive($0) }
        let recipient = CrossDeviceABIRuntimeV1 { recipientCapture.receive($0) }
        defer { origin.destroy(); recipient.destroy() }
        origin.submit(try originCommand(generation: generation).encoded())
        await originCapture.wait(forCount: 1)
        origin.submit(try CrossDeviceABICommandV1(kind: .start, generation: generation).encoded())
        await originCapture.wait(forCount: 2)
        recipient.submit(try CrossDeviceABICommandV1(
            kind: .createRecipient, generation: generation, supportedTransactionVersions: [1],
            qrText: String(decoding: try payload(of: .qrOffer, in: originCapture), as: UTF8.self)
        ).encoded())
        await recipientCapture.wait(forCount: 1)
        recipient.submit(try CrossDeviceABICommandV1(kind: .start, generation: generation).encoded())
        await recipientCapture.wait(forCount: 2)
        let commitment = try payload(of: .outboundRecord, in: recipientCapture)

        let beforeFragment = originCapture.events.count
        let split = commitment.count / 2
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: commitment.prefix(split)).encoded())
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(originCapture.events.count, beforeFragment)
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: commitment.dropFirst(split)).encoded())
        await originCapture.wait(forCount: beforeFragment + 1)
        XCTAssertEqual(originCapture.events.last?.kind, .outboundRecord)

        // A fresh origin sees both coalesced records in order. The first
        // produces its hello; replaying that commitment is then terminal.
        let coalescedCapture = CrossDeviceEventCapture()
        let coalescedRecipientCapture = CrossDeviceEventCapture()
        let coalesced = CrossDeviceABIRuntimeV1 { coalescedCapture.receive($0) }
        let coalescedRecipient = CrossDeviceABIRuntimeV1 { coalescedRecipientCapture.receive($0) }
        defer { coalesced.destroy(); coalescedRecipient.destroy() }
        coalesced.submit(try originCommand(generation: generation + 1).encoded())
        await coalescedCapture.wait(forCount: 1)
        coalesced.submit(try CrossDeviceABICommandV1(kind: .start, generation: generation + 1).encoded())
        await coalescedCapture.wait(forCount: 2)
        coalescedRecipient.submit(try CrossDeviceABICommandV1(
            kind: .createRecipient, generation: generation + 1, supportedTransactionVersions: [1],
            qrText: String(decoding: try payload(of: .qrOffer, in: coalescedCapture), as: UTF8.self)
        ).encoded())
        await coalescedRecipientCapture.wait(forCount: 1)
        coalescedRecipient.submit(try CrossDeviceABICommandV1(kind: .start, generation: generation + 1).encoded())
        await coalescedRecipientCapture.wait(forCount: 2)
        let coalescedCommitment = try payload(of: .outboundRecord, in: coalescedRecipientCapture)
        var twoRecords = coalescedCommitment
        twoRecords.append(coalescedCommitment)
        coalesced.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation + 1, bytes: twoRecords).encoded())
        await coalescedCapture.wait(forCount: 4)
        XCTAssertTrue(coalescedCapture.events.contains { $0.kind == .outboundRecord })
        XCTAssertTrue(coalescedCapture.events.contains { $0.kind == .terminal })

        let eofCapture = CrossDeviceEventCapture()
        let eofRuntime = CrossDeviceABIRuntimeV1 { eofCapture.receive($0) }
        defer { eofRuntime.destroy() }
        eofRuntime.submit(try originCommand(generation: generation + 2).encoded())
        await eofCapture.wait(forCount: 1)
        eofRuntime.submit(try CrossDeviceABICommandV1(kind: .start, generation: generation + 2).encoded())
        await eofCapture.wait(forCount: 2)
        eofRuntime.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation + 2, bytes: commitment.prefix(3)).encoded())
        try? await Task.sleep(nanoseconds: 30_000_000)
        eofRuntime.submit(try CrossDeviceABICommandV1(kind: .finishStream, generation: generation + 2).encoded())
        await eofCapture.wait(forCount: 3)
        XCTAssertEqual(eofCapture.events.last?.kind, .terminal)
        XCTAssertEqual(eofCapture.events.last?.code, "malformedOrReplay")

        let cleanEOFCapture = CrossDeviceEventCapture()
        let cleanEOF = CrossDeviceABIRuntimeV1 { cleanEOFCapture.receive($0) }
        defer { cleanEOF.destroy() }
        cleanEOF.submit(try originCommand(generation: generation + 3).encoded())
        await cleanEOFCapture.wait(forCount: 1)
        cleanEOF.submit(try CrossDeviceABICommandV1(kind: .start, generation: generation + 3).encoded())
        await cleanEOFCapture.wait(forCount: 2)
        cleanEOF.submit(try CrossDeviceABICommandV1(kind: .finishStream, generation: generation + 3).encoded())
        await cleanEOFCapture.wait(forCount: 3)
        XCTAssertEqual(cleanEOFCapture.events.last?.kind, .terminal)
        XCTAssertEqual(cleanEOFCapture.events.last?.code, "peerDisconnected")
    }

    func testStaleGenerationAndEnrollmentConfigurationAreExplicit() async throws {
        let capture = CrossDeviceEventCapture()
        let runtime = CrossDeviceABIRuntimeV1 { capture.receive($0) }
        runtime.submit(try originCommand(generation: 7).encoded())
        await capture.wait(forCount: 1)
        runtime.submit(try CrossDeviceABICommandV1(kind: .start, generation: 8).encoded())
        await capture.wait(forCount: 2)
        XCTAssertEqual(capture.events.last?.kind, .commandRejected)
        XCTAssertEqual(capture.events.last?.code, "stale_generation")
        runtime.destroy()

        let denied = CrossDeviceEventCapture()
        let deniedRuntime = CrossDeviceABIRuntimeV1 { denied.receive($0) }
        let enroll = CrossDeviceABICommandV1(
            kind: .createOrigin,
            generation: 4,
            purpose: .enroll,
            expiresAt: Int64(Date().timeIntervalSince1970) + 60,
            endpointCandidates: [.init(host: "127.0.0.1", port: 1234)],
            supportedTransactionVersions: [1]
        )
        deniedRuntime.submit(try enroll.encoded())
        await denied.wait(forCount: 1)
        XCTAssertEqual(denied.events.last?.kind, .configured)
        deniedRuntime.destroy()
    }

    func testFullContinuationBridgeMapsEveryPublicEvent() async throws {
        let originCapture = CrossDeviceEventCapture()
        let recipientCapture = CrossDeviceEventCapture()
        let origin = CrossDeviceABIRuntimeV1 { originCapture.receive($0) }
        let recipient = CrossDeviceABIRuntimeV1 { recipientCapture.receive($0) }
        defer { origin.destroy(); recipient.destroy() }
        let generation: UInt64 = 91

        origin.submit(try originCommand(generation: generation).encoded())
        await originCapture.wait(forCount: 1)
        origin.submit(try CrossDeviceABICommandV1(kind: .start, generation: generation).encoded())
        await originCapture.wait(forCount: 2)
        let offer = try payload(of: .qrOffer, in: originCapture)

        recipient.submit(try CrossDeviceABICommandV1(
            kind: .createRecipient, generation: generation, supportedTransactionVersions: [1], qrText: String(decoding: offer, as: UTF8.self)
        ).encoded())
        await recipientCapture.wait(forCount: 1)
        recipient.submit(try CrossDeviceABICommandV1(kind: .start, generation: generation).encoded())
        await recipientCapture.wait(forCount: 2)
        let commitment = try payload(of: .outboundRecord, in: recipientCapture)

        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: commitment).encoded())
        await originCapture.wait(forCount: 3)
        let originHello = try payload(of: .outboundRecord, in: originCapture)
        recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: originHello).encoded())
        await recipientCapture.wait(forCount: 4)
        let recipientHello = try payload(of: .outboundRecord, in: recipientCapture)
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: recipientHello).encoded())
        await originCapture.wait(forCount: 4)
        XCTAssertEqual(originCapture.events.last?.kind, .sasAvailable)
        XCTAssertEqual(originCapture.events.last?.code?.count, 6)
        XCTAssertEqual(recipientCapture.events.last?.kind, .sasAvailable)

        recipient.submit(try CrossDeviceABICommandV1(kind: .decideSAS, generation: generation, matches: true).encoded())
        await recipientCapture.wait(forCount: 5)
        let recipientDecision = try payload(of: .outboundRecord, in: recipientCapture)
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: recipientDecision).encoded())
        // Receiving the peer's approval intentionally emits no event until
        // this side makes its own SAS decision.
        origin.submit(try CrossDeviceABICommandV1(kind: .decideSAS, generation: generation, matches: true).encoded())
        await originCapture.wait(forCount: 6)
        XCTAssertTrue(originCapture.events.contains { $0.kind == .pairingApproved })
        let originDecision = try payload(of: .outboundRecord, in: originCapture)
        recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: originDecision).encoded())
        await recipientCapture.wait(forCount: 6)
        XCTAssertTrue(recipientCapture.events.contains { $0.kind == .pairingApproved })

        let descriptor = try continuationDescriptor().encoded()
        let originBeforeDescriptor = originCapture.events.count
        origin.submit(try CrossDeviceABICommandV1(kind: .provideContinuationDescriptor, generation: generation, descriptor: descriptor).encoded())
        await originCapture.wait(forCount: originBeforeDescriptor + 1)
        let descriptorRecord = try payload(of: .outboundRecord, in: originCapture)
        let recipientBeforeDescriptor = recipientCapture.events.count
        recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: descriptorRecord).encoded())
        await recipientCapture.wait(forCount: recipientBeforeDescriptor + 1)
        XCTAssertEqual(recipientCapture.events.last?.kind, .continuationDescriptorReceived)

        let recipientBeforeAcceptance = recipientCapture.events.count
        recipient.submit(try CrossDeviceABICommandV1(kind: .continuationDescriptorDurablyAccepted, generation: generation, atMilliseconds: 1_700_000_000_000).encoded())
        await recipientCapture.wait(forCount: recipientBeforeAcceptance + 2)
        XCTAssertTrue(recipientCapture.events.contains { $0.kind == .continuationConnectionRequired })
        let acceptance = try payload(of: .outboundRecord, in: recipientCapture)
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: acceptance).encoded())
        // Acceptance is an internal state transition on the sender.

        let recipientBeforeConnection = recipientCapture.events.count
        recipient.submit(try CrossDeviceABICommandV1(kind: .continuationConnectionCompleted, generation: generation, hostID: continuationDescriptor().hostID, atMilliseconds: 1_700_000_001_000).encoded())
        await recipientCapture.wait(forCount: recipientBeforeConnection + 1)
        let connectionReceipt = try payload(of: .outboundRecord, in: recipientCapture)
        let originBeforeCompletion = originCapture.events.count
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: connectionReceipt).encoded())
        await originCapture.wait(forCount: originBeforeCompletion + 2)
        XCTAssertTrue(originCapture.events.contains { $0.kind == .continuationCompleted })
        let acknowledgement = try payload(of: .outboundRecord, in: originCapture)
        let recipientBeforeAcknowledgement = recipientCapture.events.count
        recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: acknowledgement).encoded())
        await recipientCapture.wait(forCount: recipientBeforeAcknowledgement + 1)
        XCTAssertTrue(recipientCapture.events.contains { $0.kind == .continuationCompleted })
    }

    func testTerminalOperationsAreMappedAndDestroyIsACompletionBarrier() async throws {
        let capture = CrossDeviceEventCapture()
        let runtime = CrossDeviceABIRuntimeV1 { capture.receive($0) }
        runtime.submit(try originCommand(generation: 12).encoded())
        await capture.wait(forCount: 1)
        runtime.submit(try CrossDeviceABICommandV1(kind: .applicationDidLock, generation: 12).encoded())
        await capture.wait(forCount: 2)
        XCTAssertEqual(capture.events.last?.kind, .terminal)
        XCTAssertEqual(capture.events.last?.code, "applicationLocked")
        runtime.destroy()
        XCTAssertEqual(capture.events.last?.kind, .destroyed)
    }

    func testBootstrapOwnerApprovalMintsOpaqueCapabilitiesAndRejectsStaleEvidence() async throws {
        let good = try await bootstrapOwnerApprovalAttempt(issuedAt: Date(), expiresAt: Date().addingTimeInterval(30))
        XCTAssertTrue(good.contains { $0.kind == .outboundRecord })
        XCTAssertFalse(good.contains { $0.kind == .terminal })

        let stale = try await bootstrapOwnerApprovalAttempt(
            issuedAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 2),
            retryWith: (Date(), Date().addingTimeInterval(30))
        )
        XCTAssertTrue(stale.contains { $0.kind == .commandRejected && $0.code == "stale_authorization" })
        XCTAssertTrue(stale.contains { $0.kind == .outboundRecord })
        XCTAssertFalse(stale.contains { $0.kind == .terminal })
    }

    func testNegotiatedBootstrapVersionReachesAndroidAuthorizationEvent() async throws {
        for versions in [[1], [1, 2]] {
            let events = try await bootstrapOwnerApprovalAttempt(issuedAt: Date(),
                expiresAt: Date().addingTimeInterval(30), supportedVersions: versions)
            let event = try XCTUnwrap(events.first { $0.kind == .bootstrapOwnerAuthorizationRequired })
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(event.payload)) as? [String: Any])
            XCTAssertEqual(object["transactionVersion"] as? Int, versions.max())
        }
    }

    func testBiometricApprovalEvidenceRejectsFutureIssuedTimes() async throws {
        let now = Date()
        let events = try await bootstrapOwnerApprovalAttempt(
            issuedAt: now.addingTimeInterval(DeviceAccessGrantEngine.maximumAuthorizationFutureSkew + 2),
            expiresAt: now.addingTimeInterval(30)
        )
        XCTAssertTrue(events.contains { $0.kind == .commandRejected && $0.code == "stale_authorization" })
        XCTAssertFalse(events.contains { $0.kind == .terminal })
    }

    func testCallbacksAreSerializedAndDestroySuppressesQueuedCallbacks() async throws {
        let capture = SerializationCapture()
        let runtime = CrossDeviceABIRuntimeV1 { capture.receive($0) }
        runtime.submit(try originCommand(generation: 61).encoded())
        runtime.submit(try CrossDeviceABICommandV1(kind: .start, generation: 61).encoded())
        runtime.destroy()
        let countAtDestroy = capture.count
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(capture.maximumInFlight, 1)
        XCTAssertEqual(capture.count, countAtDestroy)
        XCTAssertEqual(capture.events.last?.kind, .destroyed)
    }

    func testEnrollmentBridgeUsesFreshEvidenceWithoutExportingAuthorizationCapabilities() async throws {
        let generation: UInt64 = 73
        let originCapture = CrossDeviceEventCapture()
        let recipientCapture = CrossDeviceEventCapture()
        let origin = CrossDeviceABIRuntimeV1 { originCapture.receive($0) }
        let recipient = CrossDeviceABIRuntimeV1 { recipientCapture.receive($0) }
        defer { origin.destroy(); recipient.destroy() }
        origin.submit(try originCommand(generation: generation, purpose: .enroll).encoded())
        await originCapture.wait(forCount: 1)
        origin.submit(try CrossDeviceABICommandV1(kind: .start, generation: generation).encoded())
        await originCapture.wait(forCount: 2)
        recipient.submit(try CrossDeviceABICommandV1(kind: .createRecipient, generation: generation, supportedTransactionVersions: [1], qrText: String(decoding: try payload(of: .qrOffer, in: originCapture), as: UTF8.self)).encoded())
        await recipientCapture.wait(forCount: 1)
        recipient.submit(try CrossDeviceABICommandV1(kind: .start, generation: generation).encoded())
        await recipientCapture.wait(forCount: 2)
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: recipientCapture)).encoded())
        await originCapture.wait(forCount: 3)
        recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: originCapture)).encoded())
        await recipientCapture.wait(forCount: 4)
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: recipientCapture)).encoded())
        await originCapture.wait(forCount: 4)
        recipient.submit(try CrossDeviceABICommandV1(kind: .decideSAS, generation: generation, matches: true).encoded())
        await recipientCapture.wait(forCount: 5)
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: recipientCapture)).encoded())
        origin.submit(try CrossDeviceABICommandV1(kind: .decideSAS, generation: generation, matches: true).encoded())
        await originCapture.wait(forCount: 6)
        recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: originCapture)).encoded())
        await recipientCapture.wait(forCount: 6)

        let request = try enrollmentRequest()
        let recipientBeforeRequest = recipientCapture.events.count
        recipient.submit(try CrossDeviceABICommandV1(kind: .beginEnrollment, generation: generation, enrollmentRequest: request).encoded())
        await recipientCapture.wait(forCount: recipientBeforeRequest + 1)
        let originBeforeRequest = originCapture.events.count
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: recipientCapture)).encoded())
        await originCapture.wait(forCount: originBeforeRequest + 1)
        XCTAssertEqual(originCapture.events.last?.kind, .enrollmentApprovalRequired)

        let originBeforeApproval = originCapture.events.count
        let now = Date()
        origin.submit(try CrossDeviceABICommandV1(
            kind: .approveEnrollment, generation: generation, routeIdentity: "ssh:alice@server.example:22",
            issuedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            expiresAuthorizationAtMilliseconds: Int64(now.addingTimeInterval(30).timeIntervalSince1970 * 1_000),
            policyGeneration: 11
        ).encoded())
        await originCapture.wait(forCount: originBeforeApproval + 1)
        XCTAssertEqual(originCapture.events.last?.kind, .enrollmentInstallationRequired)
        let installProjection = try XCTUnwrap(originCapture.events.last?.payload)
        XCTAssertFalse(String(decoding: installProjection, as: UTF8.self).contains("accessAuthorization"))

        let originBeforeInstalled = originCapture.events.count
        origin.submit(try CrossDeviceABICommandV1(
            kind: .enrollmentInstallationDurablyVerified, generation: generation, enrollmentID: request.id,
            publicKeyFingerprint: request.publicKey.fingerprint, routeIdentity: "ssh:alice@server.example:22",
            atMilliseconds: Int64(now.timeIntervalSince1970 * 1_000)
        ).encoded())
        await originCapture.wait(forCount: originBeforeInstalled + 1)
        let recipientBeforeInstalled = recipientCapture.events.count
        recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: originCapture)).encoded())
        await recipientCapture.wait(forCount: recipientBeforeInstalled + 1)
        XCTAssertEqual(recipientCapture.events.last?.kind, .enrollmentRecordRequired)

        let recipientBeforeRecorded = recipientCapture.events.count
        recipient.submit(try CrossDeviceABICommandV1(
            kind: .enrollmentRequesterRecordDurablyCommitted, generation: generation, enrollmentID: request.id,
            publicKeyFingerprint: request.publicKey.fingerprint, atMilliseconds: Int64(now.timeIntervalSince1970 * 1_000)
        ).encoded())
        await recipientCapture.wait(forCount: recipientBeforeRecorded + 1)
        let originBeforeRecorded = originCapture.events.count
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: recipientCapture)).encoded())
        await originCapture.wait(forCount: originBeforeRecorded + 2)
        XCTAssertTrue(originCapture.events.contains { $0.kind == .enrollmentCompleted })
        let recipientBeforeCompleted = recipientCapture.events.count
        recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: originCapture)).encoded())
        await recipientCapture.wait(forCount: recipientBeforeCompleted + 1)
        XCTAssertTrue(recipientCapture.events.contains { $0.kind == .enrollmentCompleted })

        let originCountAfterCompletion = originCapture.events.count
        let recipientCountAfterCompletion = recipientCapture.events.count
        origin.submit(try CrossDeviceABICommandV1(
            kind: .enrollmentInstallationDurablyVerified, generation: generation, enrollmentID: request.id,
            publicKeyFingerprint: request.publicKey.fingerprint, routeIdentity: "ssh:alice@server.example:22",
            atMilliseconds: Int64(now.timeIntervalSince1970 * 1_000)
        ).encoded())
        recipient.submit(try CrossDeviceABICommandV1(
            kind: .enrollmentRequesterRecordDurablyCommitted, generation: generation, enrollmentID: request.id,
            publicKeyFingerprint: request.publicKey.fingerprint, atMilliseconds: Int64(now.timeIntervalSince1970 * 1_000)
        ).encoded())
        recipient.submit(try CrossDeviceABICommandV1(
            kind: .beginEnrollment, generation: generation, enrollmentRequest: request
        ).encoded())
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(originCapture.events.count, originCountAfterCompletion)
        XCTAssertEqual(recipientCapture.events.count, recipientCountAfterCompletion)
        XCTAssertFalse(originCapture.events.contains { $0.kind == .terminal })
        XCTAssertFalse(recipientCapture.events.contains { $0.kind == .terminal })
    }

    func testCHandleUseAfterDestroyAndReentrantDestroyAreSafe() throws {
        let command = try originCommand(generation: 17).encoded()
        let callback: TesseraCrossDeviceABIEventCallback = { _, _, _ in }
        let handle = tesseraCrossDeviceRuntimeCreate(callback: callback, context: nil)
        XCTAssertEqual(send(command, to: handle), 0)
        tesseraCrossDeviceRuntimeDestroy(handle: handle)
        tesseraCrossDeviceRuntimeDestroy(handle: handle)
        XCTAssertEqual(send(command, to: handle), -2)
        XCTAssertEqual(tesseraCrossDeviceABIVersion(), 1)
        XCTAssertEqual(tesseraCrossDeviceABIMaxPayloadBytes(), 1_048_576)

        let box = ReentrantCrossDeviceDestroyBox()
        let context = Unmanaged.passRetained(box).toOpaque()
        let reentrant: TesseraCrossDeviceABIEventCallback = { _, _, context in
            guard let context else { return }
            let box = Unmanaged<ReentrantCrossDeviceDestroyBox>.fromOpaque(context).takeUnretainedValue()
            box.calls += 1
            tesseraCrossDeviceRuntimeDestroy(handle: box.handle)
        }
        let reentrantHandle = tesseraCrossDeviceRuntimeCreate(callback: reentrant, context: context)
        box.handle = reentrantHandle
        XCTAssertEqual(send(command, to: reentrantHandle), 0)
        // The command is queued; give the serial callback executor one turn.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(box.calls, 1)
        XCTAssertEqual(send(command, to: reentrantHandle), -2)
        Unmanaged<ReentrantCrossDeviceDestroyBox>.fromOpaque(context).release()
    }

    private func originCommand(generation: UInt64) -> CrossDeviceABICommandV1 {
        originCommand(generation: generation, purpose: .continueSession)
    }

    private func originCommand(generation: UInt64, purpose: PairingPurpose, supportedVersions: [Int] = [1]) -> CrossDeviceABICommandV1 {
        CrossDeviceABICommandV1(
            kind: .createOrigin,
            generation: generation,
            purpose: purpose,
            expiresAt: Int64(Date().timeIntervalSince1970) + 300,
            endpointCandidates: [.init(host: "127.0.0.1", port: 23001)],
            supportedTransactionVersions: supportedVersions
        )
    }

    private func continuationDescriptor() -> ContinuationDescriptorV1 {
        ContinuationDescriptorV1(
            endpoint: .init(hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "host", user: "user", address: "example.test", port: 22, transport: .ssh, hostKeyFingerprint: nil),
            launchMode: .autoTmux,
            tmuxSessionName: "tessera"
        )
    }

    /// Android narrows a setup transfer through this field, so its rules are a
    /// contract: absent means every host, and a supplied selection must be a
    /// non-empty, duplicate-free subset of the manifest it accompanies.
    func testApproveBootstrapManifestValidatesTheHostSelection() throws {
        let manifest = bootstrapManifest()
        let present = manifest.hosts[0].id
        let absent = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        func command(_ selectedHostIDs: [UUID]?) -> CrossDeviceABICommandV1 {
            CrossDeviceABICommandV1(
                kind: .approveBootstrapManifest,
                generation: 1,
                manifest: manifest,
                selectedOptionalTransfers: [],
                selectedHostIDs: selectedHostIDs,
                issuedAtMilliseconds: 1_000,
                expiresAuthorizationAtMilliseconds: 2_000,
                policyGeneration: 1
            )
        }

        XCTAssertNoThrow(try command(nil).encoded(), "absent selection means every host")
        XCTAssertNoThrow(try command([present]).encoded())

        for rejected in [[], [absent], [present, present], [present, absent]] {
            XCTAssertThrowsError(try command(rejected).encoded(), "\(rejected)") {
                XCTAssertEqual($0 as? CrossDeviceABIError, .invalidField)
            }
        }
    }

    private func bootstrapManifest() -> BootstrapManifestV2 {
        BootstrapManifestV2(
            hosts: [BootstrapHostDescriptor(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                name: "production", address: "server.example", user: "alice",
                transport: .ssh, launchMode: .autoTmux
            )],
            jumpChains: [],
            appearance: BootstrapAppearanceSettings(
                colorScheme: "system", accent: "blue", customAccentRGB: 0x007AFF,
                monospacedFontName: "SFMono-Regular", terminalFontSize: 14,
                chromeMaterial: "system", cursorStyle: "block", cursorBlink: true,
                terminalThemeID: "default"
            ),
            settings: BootstrapGeneralSettings(
                scrollbackLines: 10_000, modifierBehavior: "oneShot", bellSoundEnabled: false,
                bellVisualEnabled: true, bellNotificationEnabled: false, accessoryBarKeys: [],
                filesReaperDays: 30, filesDefaultDestination: "cwd"
            )
        )
    }

    private func bootstrapKey() throws -> DevicePublicKeyDescriptorV2 {
        let key = DevicePublicKeyDescriptorV2(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, displayName: "Android key",
            algorithm: .ed25519,
            sshBlob: "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f",
            fingerprint: "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA",
            protectionClaim: .platformStrongHardware
        )
        try key.validate()
        return key
    }

    private func enrollmentRequest() throws -> EnrollmentRequestV1 {
        let key = EnrollmentPublicKeyV1(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!, displayName: "Android key",
            algorithm: .ed25519,
            blob: "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f",
            fingerprint: "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA", protection: .software
        )
        try key.validate()
        return EnrollmentRequestV1(hostID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!, hostName: "server", requestingDeviceName: "Android", publicKey: key)
    }

    private func bootstrapOwnerApprovalAttempt(
        issuedAt: Date,
        expiresAt: Date,
        retryWith: (Date, Date)? = nil,
        supportedVersions: [Int] = [1]
    ) async throws -> [CrossDeviceABIEventV1] {
        let generation: UInt64 = 44
        let originCapture = CrossDeviceEventCapture()
        let recipientCapture = CrossDeviceEventCapture()
        let origin = CrossDeviceABIRuntimeV1 { originCapture.receive($0) }
        let recipient = CrossDeviceABIRuntimeV1 { recipientCapture.receive($0) }
        origin.submit(try originCommand(generation: generation, purpose: .bootstrap, supportedVersions: supportedVersions).encoded())
        await originCapture.wait(forCount: 1)
        origin.submit(try CrossDeviceABICommandV1(kind: .start, generation: generation).encoded())
        await originCapture.wait(forCount: 2)
        let offer = try payload(of: .qrOffer, in: originCapture)
        recipient.submit(try CrossDeviceABICommandV1(kind: .createRecipient, generation: generation, supportedTransactionVersions: supportedVersions, qrText: String(decoding: offer, as: UTF8.self)).encoded())
        await recipientCapture.wait(forCount: 1)
        recipient.submit(try CrossDeviceABICommandV1(kind: .start, generation: generation).encoded())
        await recipientCapture.wait(forCount: 2)
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: recipientCapture)).encoded())
        await originCapture.wait(forCount: 3)
        recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: originCapture)).encoded())
        await recipientCapture.wait(forCount: 4)
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: recipientCapture)).encoded())
        await originCapture.wait(forCount: 4)
        recipient.submit(try CrossDeviceABICommandV1(kind: .decideSAS, generation: generation, matches: true).encoded())
        await recipientCapture.wait(forCount: 5)
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: recipientCapture)).encoded())
        origin.submit(try CrossDeviceABICommandV1(kind: .decideSAS, generation: generation, matches: true).encoded())
        await originCapture.wait(forCount: 6)
        recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: originCapture)).encoded())
        await recipientCapture.wait(forCount: 6)
        recipient.submit(try CrossDeviceABICommandV1(kind: .provideBootstrapRecipientPublicKey, generation: generation, publicKey: try bootstrapKey()).encoded())
        await recipientCapture.wait(forCount: 7)
        origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try payload(of: .outboundRecord, in: recipientCapture)).encoded())
        await originCapture.wait(forCount: 7)
        XCTAssertEqual(originCapture.events.last?.kind, .bootstrapOwnerAuthorizationRequired)
        let beforeApproval = originCapture.events.count
        origin.submit(try CrossDeviceABICommandV1(
            kind: .approveBootstrapManifest,
            generation: generation,
            manifest: bootstrapManifest(),
            selectedOptionalTransfers: [],
            issuedAtMilliseconds: Int64(issuedAt.timeIntervalSince1970 * 1_000),
            expiresAuthorizationAtMilliseconds: Int64(expiresAt.timeIntervalSince1970 * 1_000),
            policyGeneration: 9
        ).encoded())
        await originCapture.wait(forCount: beforeApproval + 1)
        if let retryWith {
            XCTAssertEqual(originCapture.events.last?.kind, .commandRejected)
            let beforeRetry = originCapture.events.count
            origin.submit(try CrossDeviceABICommandV1(
                kind: .approveBootstrapManifest,
                generation: generation,
                manifest: bootstrapManifest(),
                selectedOptionalTransfers: [],
                issuedAtMilliseconds: Int64(retryWith.0.timeIntervalSince1970 * 1_000),
                expiresAuthorizationAtMilliseconds: Int64(retryWith.1.timeIntervalSince1970 * 1_000),
                policyGeneration: 9
            ).encoded())
            await originCapture.wait(forCount: beforeRetry + 1)
        } else if originCapture.events.last?.kind == .commandRejected {
            let events = originCapture.events
            origin.destroy(); recipient.destroy()
            return events
        }
        // Carry the ABI's complete bootstrap transaction over its public
        // outbound-record events. No pairing/bootstrap framing is recreated
        // in the test adapter.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let recipientCursor = recipientCapture.events.count
        for event in originCapture.events.dropFirst(beforeApproval) where event.kind == .outboundRecord {
            recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try XCTUnwrap(event.payload)).encoded())
        }
        await recipientCapture.wait(forCount: recipientCursor + 1)
        XCTAssertTrue(recipientCapture.events.contains { $0.kind == .bootstrapImportRequired })
        let importedManifest = try JSONDecoder().decode(
            BootstrapManifestV2.self,
            from: try XCTUnwrap(recipientCapture.events.last(where: { $0.kind == .bootstrapImportRequired })?.payload)
        )
        XCTAssertEqual(importedManifest, bootstrapManifest())

        let now = Date()
        let hostID = try XCTUnwrap(bootstrapManifest().hosts.first?.id)
        let recipientBeforeImport = recipientCapture.events.count
        recipient.submit(try CrossDeviceABICommandV1(
            kind: .bootstrapImportDurablyApplied, generation: generation,
            acceptedHostIDs: [hostID], atMilliseconds: Int64(now.timeIntervalSince1970 * 1_000)
        ).encoded())
        await recipientCapture.wait(forCount: recipientBeforeImport + 1)
        let originBeforeAcceptance = originCapture.events.count
        for event in recipientCapture.events.dropFirst(recipientCursor) where event.kind == .outboundRecord {
            origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try XCTUnwrap(event.payload)).encoded())
        }
        await originCapture.wait(forCount: originBeforeAcceptance + 1)
        XCTAssertTrue(originCapture.events.contains { $0.kind == .bootstrapRemoteGrantVerificationRequired })
        let grantProjection = try JSONDecoder().decode(
            BootstrapGrantProjection.self,
            from: try XCTUnwrap(originCapture.events.last(where: { $0.kind == .bootstrapRemoteGrantVerificationRequired })?.payload)
        )
        XCTAssertEqual(grantProjection.recipientKey, try bootstrapKey())
        XCTAssertEqual(grantProjection.manifest, bootstrapManifest())
        XCTAssertEqual(grantProjection.selectedOptionalTransfers, [])
        XCTAssertEqual(grantProjection.acceptance.acceptedHostIDs, [hostID])

        let recipientBeforeGrantReceipt = recipientCapture.events.count
        let originBeforeGrantReceipt = originCapture.events.count
        origin.submit(try CrossDeviceABICommandV1(
            kind: .bootstrapRemoteGrantsDurablyVerified, generation: generation,
            grantResults: [.init(hostID: hostID, status: .installed)],
            atMilliseconds: Int64(now.timeIntervalSince1970 * 1_000), policyGeneration: 9
        ).encoded())
        await originCapture.wait(forCount: originBeforeGrantReceipt + 1)
        for event in originCapture.events.dropFirst(originBeforeGrantReceipt) where event.kind == .outboundRecord {
            recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try XCTUnwrap(event.payload)).encoded())
        }
        await recipientCapture.wait(forCount: recipientBeforeGrantReceipt + 1)
        XCTAssertTrue(recipientCapture.events.contains { $0.kind == .bootstrapAccessRecordRequired })

        let originBeforeCompletion = originCapture.events.count
        let recipientBeforeCompletion = recipientCapture.events.count
        recipient.submit(try CrossDeviceABICommandV1(
            kind: .bootstrapAccessStateDurablyRecorded, generation: generation,
            atMilliseconds: Int64(now.timeIntervalSince1970 * 1_000)
        ).encoded())
        await recipientCapture.wait(forCount: recipientBeforeCompletion + 1)
        for event in recipientCapture.events.dropFirst(recipientBeforeCompletion) where event.kind == .outboundRecord {
            origin.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try XCTUnwrap(event.payload)).encoded())
        }
        await originCapture.wait(forCount: originBeforeCompletion + 1)
        for event in originCapture.events.dropFirst(originBeforeCompletion) where event.kind == .outboundRecord {
            recipient.submit(try CrossDeviceABICommandV1(kind: .receiveBytes, generation: generation, bytes: try XCTUnwrap(event.payload)).encoded())
        }
        await recipientCapture.wait(forCount: recipientBeforeCompletion + 2)
        XCTAssertTrue(originCapture.events.contains { $0.kind == .bootstrapCompleted })
        XCTAssertTrue(recipientCapture.events.contains { $0.kind == .bootstrapCompleted })
        let events = originCapture.events
        origin.destroy(); recipient.destroy()
        return events
    }

    private func payload(of kind: CrossDeviceABIEventV1.Kind, in capture: CrossDeviceEventCapture) throws -> Data {
        try XCTUnwrap(capture.events.last(where: { $0.kind == kind })?.payload)
    }

    private func send(_ data: Data, to handle: UnsafeMutableRawPointer) -> Int32 {
        data.withUnsafeBytes { raw in
            tesseraCrossDeviceRuntimeSend(handle: handle, bytes: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count)
        }
    }
}

private final class CrossDeviceEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CrossDeviceABIEventV1] = []
    var events: [CrossDeviceABIEventV1] { lock.lock(); defer { lock.unlock() }; return storage }
    func receive(_ data: Data) { if let event = try? CrossDeviceABIEventV1.decode(data) { lock.lock(); storage.append(event); lock.unlock() } }
    func wait(forCount count: Int, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if events.count >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for \(count) cross-device ABI events; got \(events.count): \(events.map { "\($0.kind.rawValue):\($0.code ?? "-")" })")
    }
}

private final class ReentrantCrossDeviceDestroyBox: @unchecked Sendable { var handle: UnsafeMutableRawPointer?; var calls = 0 }

private final class SerializationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CrossDeviceABIEventV1] = []
    private var active = 0
    private var maximum = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    var maximumInFlight: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    var events: [CrossDeviceABIEventV1] { lock.lock(); defer { lock.unlock() }; return storage }
    func receive(_ data: Data) {
        lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock()
        Thread.sleep(forTimeInterval: 0.01)
        if let event = try? CrossDeviceABIEventV1.decode(data) { lock.lock(); storage.append(event); lock.unlock() }
        lock.lock(); active -= 1; lock.unlock()
    }
}

private struct BootstrapGrantProjection: Decodable {
    let attemptID: UUID
    let recipientKey: DevicePublicKeyDescriptorV2
    let manifest: BootstrapManifestV2
    let selectedOptionalTransfers: [String]
    let acceptance: BootstrapImportAcceptanceV1
}
