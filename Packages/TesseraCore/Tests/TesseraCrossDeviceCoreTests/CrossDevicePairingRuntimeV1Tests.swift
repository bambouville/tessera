import Foundation
import TesseraBootstrapCore
import TesseraContinuityCore
import TesseraEnrollmentCore
import TesseraPairingCore
import TesseraProtocolCore
import TesseraSessionCore
@testable import TesseraCrossDeviceCore
import XCTest

final class CrossDevicePairingRuntimeV1Tests: XCTestCase {
    private final class UnixClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64

        init(_ value: Int64) { self.value = value }

        func now() -> Int64 {
            lock.withLock { value }
        }

        func advance(by seconds: Int64) {
            lock.withLock { value += seconds }
        }
    }

    private actor TestAuthorizer: FreshOwnerAuthorizing {
        func authorize(_ request: OwnerAuthorizationRequest) async throws -> FreshOwnerAuthorization {
            FreshOwnerAuthorization(
                attemptID: request.attemptID,
                policyGeneration: request.policyGeneration,
                scope: request.scope,
                issuedAt: Date(),
                expiresAt: request.expiresAt
            )
        }
    }

    private actor BlockingAuthorizer: FreshOwnerAuthorizing {
        private var pending: (
            request: OwnerAuthorizationRequest,
            continuation: CheckedContinuation<FreshOwnerAuthorization, Error>
        )?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        func authorize(_ request: OwnerAuthorizationRequest) async throws -> FreshOwnerAuthorization {
            try await withCheckedThrowingContinuation { continuation in
                pending = (request, continuation)
                let waiters = startWaiters
                startWaiters = []
                waiters.forEach { $0.resume() }
            }
        }

        func waitUntilStarted() async {
            if pending != nil { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func resume() {
            guard let pending else { return }
            self.pending = nil
            pending.continuation.resume(returning: FreshOwnerAuthorization(
                attemptID: pending.request.attemptID,
                policyGeneration: pending.request.policyGeneration,
                scope: pending.request.scope,
                issuedAt: Date(),
                expiresAt: pending.request.expiresAt
            ))
        }
    }
    private func record(_ events: [CrossDevicePairingEventV1]) throws -> PairingStreamRecordV1 {
        for event in events {
            if case .outboundRecord(let record) = event { return record }
        }
        XCTFail("expected outbound record")
        throw NSError(domain: "CrossDevicePairingRuntimeV1Tests", code: 1)
    }

    private func terminal(_ events: [CrossDevicePairingEventV1]) -> [CrossDeviceTerminalCodeV1] {
        events.compactMap { event in
            if case .terminal(let value) = event { return value }
            return nil
        }
    }

    private func descriptor() -> ContinuationDescriptorV1 {
        ContinuationDescriptorV1(
            endpoint: ContinuationEndpointV1(
                hostID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                name: "production", user: "alice", address: "server.example", port: 22,
                transport: .ssh, hostKeyFingerprint: "SHA256:test"
            ), launchMode: .pinnedTmux, tmuxSessionName: "dev"
        )
    }

    private func key() throws -> DevicePublicKeyDescriptorV2 {
        let value = DevicePublicKeyDescriptorV2(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            displayName: "Test key", algorithm: .ed25519,
            sshBlob: "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f",
            fingerprint: "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA",
            protectionClaim: .platformStrongHardware
        )
        try value.validate()
        return value
    }

    private func enrollmentKey() throws -> EnrollmentPublicKeyV1 {
        let value = EnrollmentPublicKeyV1(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            displayName: "Test key",
            algorithm: .ed25519,
            blob: "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f",
            fingerprint: "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA",
            protection: .software
        )
        try value.validate()
        return value
    }

    private func manifest(agentCenterEnabled: Bool? = nil) throws -> ApprovedBootstrapManifestV2 {
        try ApprovedBootstrapManifestV2(exportedManifest: BootstrapManifestV2(
            hosts: [BootstrapHostDescriptor(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                name: "production", address: "server.example", user: "alice",
                transport: .ssh, launchMode: .autoTmux
            )], jumpChains: [],
            appearance: BootstrapAppearanceSettings(
                colorScheme: "system", accent: "blue", customAccentRGB: 0x007AFF,
                monospacedFontName: "SFMono-Regular", terminalFontSize: 14,
                chromeMaterial: "system", cursorStyle: "block", cursorBlink: true,
                terminalThemeID: "default"
            ), settings: BootstrapGeneralSettings(
                scrollbackLines: 10_000, modifierBehavior: "oneShot", bellSoundEnabled: false,
                bellVisualEnabled: true, bellNotificationEnabled: false, accessoryBarKeys: [],
                filesReaperDays: 30, filesDefaultDestination: "cwd", agentCenterEnabled: agentCenterEnabled
            )
        ), selectedOptionalTransfers: [])
    }

    private func paired(
        purpose: PairingPurpose = .continueSession,
        enrollmentAdapter: CrossDeviceEnrollmentAdapterV1? = nil
    ) async throws -> (CrossDevicePairingRuntimeV1, CrossDevicePairingRuntimeV1) {
        let now = PairingHandshakeV1.unixTimeNow()
        let origin = try CrossDevicePairingRuntimeV1(
            origin: PairingOriginDriverConfigurationV1(
                purpose: purpose,
                expiresAt: now + 300,
                endpointCandidates: [],
                oneTimeOpticalSecret: Data(repeating: 1, count: 32)
            ),
            enrollmentAdapter: enrollmentAdapter
        )
        let originStart = await origin.start()
        guard case .qrOffer(let offer) = try XCTUnwrap(originStart.first) else { throw XCTSkip() }
        let recipient = try CrossDevicePairingRuntimeV1(
            recipient: PairingRecipientDriverConfigurationV1(
                encodedOffer: offer,
                consumptionStore: PairingOfferConsumptionStoreV1()
            ),
            enrollmentAdapter: enrollmentAdapter
        )
        let commitment = try record(await recipient.start())
        let originHello = try record(await origin.receive(commitment))
        let recipientHello = try record(await recipient.receive(originHello))
        _ = await origin.receive(recipientHello)
        let originDecision = try record(await origin.decideSAS(matches: true))
        _ = await recipient.receive(originDecision)
        let recipientDecision = try record(await recipient.decideSAS(matches: true))
        _ = await origin.receive(recipientDecision)
        return (origin, recipient)
    }

    func testContinuationWaitsForDurableAcceptanceAndConnection() async throws {
        let (origin, recipient) = try await paired()
        guard case .authenticatedPairing(let originHash, .continueSession) = await origin.continuationTransportBinding(),
              case .authenticatedPairing(let recipientHash, .continueSession) = await recipient.continuationTransportBinding() else {
            return XCTFail("continuation must expose authenticated pairing provenance")
        }
        XCTAssertEqual(originHash, recipientHash)
        XCTAssertEqual(originHash.count, 32)
        let descriptor = ContinuationDescriptorV1(
            endpoint: ContinuationEndpointV1(
                hostID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                name: "production", user: "alice", address: "server.example", port: 22,
                transport: .ssh, hostKeyFingerprint: "SHA256:test"
            ),
            launchMode: .pinnedTmux,
            tmuxSessionName: "dev"
        )
        let descriptorFrame = try record(await origin.provideContinuationDescriptor(descriptor))
        let received = await recipient.receive(descriptorFrame)
        XCTAssertTrue(received.contains { if case .continuationDescriptorReceived = $0 { return true }; return false })
        let acceptance = await recipient.continuationDescriptorDurablyAccepted(at: Date())
        XCTAssertTrue(acceptance.contains { if case .continuationConnectionRequired = $0 { return true }; return false })
        _ = await origin.receive(try record(acceptance))
        let connected = await recipient.continuationConnectionCompleted(hostID: descriptor.endpoint.hostID, at: Date())
        let acknowledgement = await origin.receive(try record(connected))
        let complete = await recipient.receive(try record(acknowledgement))
        XCTAssertTrue(complete.contains { if case .continuationCompleted = $0 { return true }; return false })
        let originState = await origin.state
        let recipientState = await recipient.state
        XCTAssertEqual(originState, .completed)
        XCTAssertEqual(recipientState, .completed)
        let postCompletionCancel = await origin.cancel()
        let postCompletionReceive = await recipient.receive(descriptorFrame)
        let postCompletionDescriptor = await origin.provideContinuationDescriptor(descriptor)
        let postCompletionAcceptance = await recipient.continuationDescriptorDurablyAccepted(at: Date())
        let postCompletionConnection = await recipient.continuationConnectionCompleted(
            hostID: descriptor.endpoint.hostID,
            at: Date()
        )
        XCTAssertTrue(postCompletionCancel.isEmpty)
        XCTAssertTrue(postCompletionReceive.isEmpty)
        XCTAssertTrue(postCompletionDescriptor.isEmpty)
        XCTAssertTrue(postCompletionAcceptance.isEmpty)
        XCTAssertTrue(postCompletionConnection.isEmpty)
    }

    func testCancelWrongOrderAndPolicyEmitOneTerminalEvent() async throws {
        let now = PairingHandshakeV1.unixTimeNow()
        let origin = try CrossDevicePairingRuntimeV1(origin: PairingOriginDriverConfigurationV1(
            purpose: .continueSession, expiresAt: now + 300, endpointCandidates: [], oneTimeOpticalSecret: nil
        ))
        let rejected = await origin.decideSAS(matches: false)
        XCTAssertEqual(terminal(rejected), [.invalidOrder])

        let (activeOrigin, _) = try await paired()
        let cancelled = await activeOrigin.cancel()
        XCTAssertEqual(terminal(cancelled), [.cancelled])
        let secondCancel = await activeOrigin.cancel()
        XCTAssertTrue(secondCancel.isEmpty)

        let (policyOrigin, _) = try await paired()
        let policy = await policyOrigin.securityPolicyChanged(to: 2)
        XCTAssertEqual(terminal(policy), [.policyChanged])
    }

    func testSetUpAndContinueRetainsDescriptorBeforeBootstrap() async throws {
        let (origin, recipient) = try await paired(purpose: .setUpAndContinue)
        let preDescriptorBinding = await recipient.continuationTransportBinding()
        XCTAssertNil(preDescriptorBinding)
        let descriptor = ContinuationDescriptorV1(
            endpoint: ContinuationEndpointV1(
                hostID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                name: "production", user: "alice", address: "server.example", port: 22,
                transport: .ssh, hostKeyFingerprint: "SHA256:test"
            ), launchMode: .pinnedTmux, tmuxSessionName: "dev"
        )
        let descriptorFrame = try record(await origin.provideContinuationDescriptor(descriptor))
        let received = await recipient.receive(descriptorFrame)
        XCTAssertTrue(received.contains { if case .continuationDescriptorReceived = $0 { return true }; return false })
        let prematureBinding = await recipient.continuationTransportBinding()
        XCTAssertNil(prematureBinding)
        let premature = await recipient.continuationDescriptorDurablyAccepted(at: Date())
        XCTAssertEqual(terminal(premature), [.invalidOrder])
        XCTAssertFalse(premature.contains { if case .continuationConnectionRequired = $0 { return true }; return false })
    }

    func testEnrollmentPurposeActivatesTypedEnrollmentRuntime() async throws {
        let adapter = CrossDeviceEnrollmentAdapterV1(authorizer: TestAuthorizer())
        let (origin, recipient) = try await paired(purpose: .enroll, enrollmentAdapter: adapter)
        let originState = await origin.state
        let recipientState = await recipient.state
        XCTAssertEqual(originState, .activeEnrollment)
        XCTAssertEqual(recipientState, .activeEnrollment)
    }

    func testBootstrapHonorsEveryDurableBoundary() async throws {
        let (origin, recipient) = try await paired(purpose: .bootstrap)
        let publicKey = try key()
        let approved = try manifest(agentCenterEnabled: true)
        let hostID = try XCTUnwrap(approved.manifest.hosts.first?.id)
        let keyFrame = try record(await recipient.provideBootstrapRecipientPublicKey(publicKey))
        let ownerRequest = await origin.receive(keyFrame)
        guard case .bootstrapOwnerAuthorizationRequired(let request) = try XCTUnwrap(ownerRequest.first) else {
            return XCTFail("expected owner authorization request")
        }
        XCTAssertEqual(request.transactionVersion, 2)
        XCTAssertTrue(request.peerSupportsAgentCenterEnabled)
        let scope = OwnerAuthorizationScope(
            routeIdentity: try BootstrapTransactionV1.routeIdentity(for: hostID, in: approved.manifest),
            hostID: hostID, publicKeyFingerprint: publicKey.fingerprint,
            authorizationBinding: try BootstrapTransactionV1.ownerAuthorizationBinding(for: approved)
        )
        let now = Date()
        let engine = DeviceAccessGrantEngine(now: { now })
        let expected = OwnerAuthorizationRequest(
            attemptID: request.attemptID, policyGeneration: 7, scope: scope,
            expiresAt: now.addingTimeInterval(60)
        )
        let authorization = try await engine.mint(from: FreshOwnerAuthorization(
            attemptID: request.attemptID, policyGeneration: 7, scope: scope,
            issuedAt: now, expiresAt: now.addingTimeInterval(60)
        ), expected: expected)
        let manifestOutput = await origin.provideBootstrapOwnerAuthorizations(
            [authorization], approvedManifest: approved, using: engine, policyGeneration: 7
        )
        XCTAssertTrue(terminal(manifestOutput).isEmpty)
        XCTAssertGreaterThanOrEqual(manifestOutput.count, 4)
        var importEvent: [CrossDevicePairingEventV1] = []
        for frame in manifestOutput.compactMap({ if case .outboundRecord(let value) = $0 { return value }; return nil }) {
            importEvent = await recipient.receive(frame)
        }
        XCTAssertTrue(importEvent.contains { if case .bootstrapImportRequired(let manifest) = $0 { return manifest.settings.agentCenterEnabled == true }; return false })
        let acceptance = await recipient.bootstrapImportDurablyApplied(acceptedHostIDs: [hostID], at: now)
        let grantRequest = await origin.receive(try record(acceptance))
        guard case .bootstrapRemoteGrantVerificationRequired(let request) = try XCTUnwrap(grantRequest.first) else {
            return XCTFail("expected exact remote grant request")
        }
        let originAttemptID = await origin.attemptID
        XCTAssertEqual(request.attemptID, originAttemptID)
        XCTAssertEqual(request.recipientKey, publicKey)
        XCTAssertEqual(request.approvedManifest, approved)
        XCTAssertEqual(request.acceptance.acceptedHostIDs, [hostID])
        let receipt = await origin.bootstrapRemoteGrantsDurablyVerified(
            [BootstrapHostGrantResultV1(hostID: hostID, status: .installed)], at: now, policyGeneration: 7
        )
        let accessRecord = await recipient.receive(try record(receipt))
        XCTAssertTrue(accessRecord.contains { if case .bootstrapAccessRecordRequired = $0 { return true }; return false })
        let acknowledgement = await recipient.bootstrapAccessStateDurablyRecorded(at: now)
        let completion = await origin.receive(try record(acknowledgement))
        let recipientComplete = await recipient.receive(try record(completion))
        XCTAssertTrue(recipientComplete.contains { if case .bootstrapCompleted = $0 { return true }; return false })
        let originState = await origin.state
        let recipientState = await recipient.state
        XCTAssertEqual(originState, .completed)
        XCTAssertEqual(recipientState, .completed)

    }

    func testSetUpAndContinueCompletesBootstrapBeforeConnection() async throws {
        let (origin, recipient) = try await paired(purpose: .setUpAndContinue)
        let descriptor = descriptor()
        let descriptorFrame = try record(await origin.provideContinuationDescriptor(descriptor))
        let descriptorEvents = await recipient.receive(descriptorFrame)
        XCTAssertTrue(descriptorEvents.contains {
            if case .continuationDescriptorReceived = $0 { return true }
            return false
        })
        XCTAssertFalse(descriptorEvents.contains {
            if case .continuationConnectionRequired = $0 { return true }
            return false
        })

        let publicKey = try key()
        let approved = try manifest(agentCenterEnabled: true)
        let hostID = try XCTUnwrap(approved.manifest.hosts.first?.id)
        let keyFrame = try record(await recipient.provideBootstrapRecipientPublicKey(publicKey))
        let ownerEvents = await origin.receive(keyFrame)
        guard case .bootstrapOwnerAuthorizationRequired(let request) = try XCTUnwrap(ownerEvents.first) else {
            return XCTFail("expected bootstrap owner authorization")
        }
        let instant = Date()
        XCTAssertEqual(request.transactionVersion, 2)
        XCTAssertTrue(request.peerSupportsAgentCenterEnabled)
        let scope = OwnerAuthorizationScope(
            routeIdentity: try BootstrapTransactionV1.routeIdentity(for: hostID, in: approved.manifest),
            hostID: hostID,
            publicKeyFingerprint: publicKey.fingerprint,
            authorizationBinding: try BootstrapTransactionV1.ownerAuthorizationBinding(for: approved)
        )
        let engine = DeviceAccessGrantEngine(now: { instant })
        let authorizationRequest = OwnerAuthorizationRequest(
            attemptID: request.attemptID,
            policyGeneration: 3,
            scope: scope,
            expiresAt: instant.addingTimeInterval(60)
        )
        let authorization = try await engine.mint(
            from: FreshOwnerAuthorization(
                attemptID: request.attemptID,
                policyGeneration: 3,
                scope: scope,
                issuedAt: instant,
                expiresAt: authorizationRequest.expiresAt
            ),
            expected: authorizationRequest
        )
        let manifestEvents = await origin.provideBootstrapOwnerAuthorizations(
            [authorization], approvedManifest: approved, using: engine, policyGeneration: 3
        )
        var importEvents: [CrossDevicePairingEventV1] = []
        for outbound in manifestEvents.compactMap({ event -> PairingStreamRecordV1? in
            if case .outboundRecord(let value) = event { return value }
            return nil
        }) {
            importEvents = await recipient.receive(outbound)
        }
        XCTAssertTrue(importEvents.contains {
            if case .bootstrapImportRequired(let manifest) = $0 { return manifest.settings.agentCenterEnabled == true }
            return false
        })
        XCTAssertFalse(importEvents.contains {
            if case .continuationConnectionRequired = $0 { return true }
            return false
        })
        let acceptance = await recipient.bootstrapImportDurablyApplied(
            acceptedHostIDs: [hostID], at: instant
        )
        _ = await origin.receive(try record(acceptance))
        let grantReceipt = await origin.bootstrapRemoteGrantsDurablyVerified(
            [BootstrapHostGrantResultV1(hostID: hostID, status: .installed)],
            at: instant,
            policyGeneration: 3
        )
        _ = await recipient.receive(try record(grantReceipt))
        let durableAccess = await recipient.bootstrapAccessStateDurablyRecorded(at: instant)
        let originCompletion = await origin.receive(try record(durableAccess))
        let recipientCompletion = await recipient.receive(try record(originCompletion))
        XCTAssertTrue(recipientCompletion.contains {
            if case .bootstrapCompleted = $0 { return true }
            return false
        })
        XCTAssertFalse(recipientCompletion.contains {
            if case .continuationConnectionRequired = $0 { return true }
            return false
        })
        let originContinuationState = await origin.state
        let recipientContinuationState = await recipient.state
        XCTAssertEqual(originContinuationState, .activeContinuation)
        XCTAssertEqual(recipientContinuationState, .activeContinuation)
        let postBootstrapBinding = await recipient.continuationTransportBinding()
        XCTAssertNotNil(postBootstrapBinding)

        let durableDescriptor = await recipient.continuationDescriptorDurablyAccepted(at: instant)
        XCTAssertTrue(durableDescriptor.contains {
            if case .continuationConnectionRequired = $0 { return true }
            return false
        })
        _ = await origin.receive(try record(durableDescriptor))
        let connected = await recipient.continuationConnectionCompleted(
            hostID: descriptor.endpoint.hostID,
            at: instant
        )
        let acknowledgement = await origin.receive(try record(connected))
        _ = await recipient.receive(try record(acknowledgement))
        let finalOriginState = await origin.state
        let finalRecipientState = await recipient.state
        XCTAssertEqual(finalOriginState, .completed)
        XCTAssertEqual(finalRecipientState, .completed)
    }

    func testEnrollmentCompletesOnlyAfterBothDurableReceipts() async throws {
        let adapter = CrossDeviceEnrollmentAdapterV1(authorizer: TestAuthorizer())
        let (origin, recipient) = try await paired(purpose: .enroll, enrollmentAdapter: adapter)
        let request = EnrollmentRequestV1(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            hostID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            hostName: "zeus",
            requestingDeviceName: "Android",
            publicKey: try enrollmentKey()
        )
        let requestEvents = await recipient.beginEnrollment(request)
        let approvalEvents = await origin.receive(try record(requestEvents))
        XCTAssertTrue(approvalEvents.contains {
            if case .enrollmentApprovalRequired = $0 { return true }
            return false
        })
        let scope = OwnerAuthorizationScope(
            routeIdentity: "ssh:alice@zeus.example:22",
            hostID: request.hostID,
            publicKeyFingerprint: request.publicKey.fingerprint
        )
        let approval = await origin.approveEnrollment(
            scope: scope,
            policyGeneration: 5,
            expiresAt: Date().addingTimeInterval(60)
        )
        XCTAssertTrue(approval.contains {
            if case .enrollmentInstallationRequired = $0 { return true }
            return false
        })
        XCTAssertFalse(approval.contains {
            if case .outboundRecord = $0 { return true }
            return false
        })
        let installed = await origin.enrollmentInstallationDurablyVerified(
            DurableEnrollmentInstallReceipt(
                enrollmentID: request.id,
                publicKeyFingerprint: request.publicKey.fingerprint,
                routeIdentity: scope.routeIdentity,
                recordedAt: Date()
            )
        )
        let recordRequired = await recipient.receive(try record(installed))
        XCTAssertTrue(recordRequired.contains {
            if case .enrollmentRecordRequired = $0 { return true }
            return false
        })
        let recorded = await recipient.enrollmentRequesterRecordDurablyCommitted(
            DurableEnrollmentRecordReceipt(
                enrollmentID: request.id,
                publicKeyFingerprint: request.publicKey.fingerprint,
                recordedAt: Date()
            )
        )
        let originCompletion = await origin.receive(try record(recorded))
        XCTAssertTrue(originCompletion.contains {
            if case .enrollmentCompleted = $0 { return true }
            return false
        })
        let recipientCompletion = await recipient.receive(try record(originCompletion))
        XCTAssertTrue(recipientCompletion.contains {
            if case .enrollmentCompleted = $0 { return true }
            return false
        })
        let originState = await origin.state
        let recipientState = await recipient.state
        XCTAssertEqual(originState, .completed)
        XCTAssertEqual(recipientState, .completed)

        let staleInstall = DurableEnrollmentInstallReceipt(
            enrollmentID: request.id,
            publicKeyFingerprint: request.publicKey.fingerprint,
            routeIdentity: scope.routeIdentity,
            recordedAt: Date()
        )
        let staleRecord = DurableEnrollmentRecordReceipt(
            enrollmentID: request.id,
            publicKeyFingerprint: request.publicKey.fingerprint,
            recordedAt: Date()
        )
        let staleBegin = await recipient.beginEnrollment(request)
        let staleApproval = await origin.approveEnrollment(
            scope: scope,
            policyGeneration: 5,
            expiresAt: Date().addingTimeInterval(60)
        )
        let staleInstallation = await origin.enrollmentInstallationDurablyVerified(staleInstall)
        let staleCommit = await recipient.enrollmentRequesterRecordDurablyCommitted(staleRecord)
        let finalOriginState = await origin.state
        let finalRecipientState = await recipient.state
        XCTAssertTrue(staleBegin.isEmpty)
        XCTAssertTrue(staleApproval.isEmpty)
        XCTAssertTrue(staleInstallation.isEmpty)
        XCTAssertTrue(staleCommit.isEmpty)
        XCTAssertEqual(finalOriginState, .completed)
        XCTAssertEqual(finalRecipientState, .completed)
    }

    func testPeerSASRejectionAndAuthenticatedCancelPropagateTerminally() async throws {
        let now = PairingHandshakeV1.unixTimeNow()
        let origin = try CrossDevicePairingRuntimeV1(origin: PairingOriginDriverConfigurationV1(
            purpose: .continueSession,
            expiresAt: now + 60,
            endpointCandidates: [],
            oneTimeOpticalSecret: Data(repeating: 9, count: 32)
        ))
        let originStart = await origin.start()
        guard case .qrOffer(let offer) = try XCTUnwrap(originStart.first) else {
            return XCTFail("missing offer")
        }
        let recipient = try CrossDevicePairingRuntimeV1(recipient: PairingRecipientDriverConfigurationV1(
            encodedOffer: offer,
            consumptionStore: PairingOfferConsumptionStoreV1()
        ))
        let originHello = try record(await origin.receive(try record(await recipient.start())))
        let recipientHello = try record(await recipient.receive(originHello))
        _ = await origin.receive(recipientHello)
        let rejection = await recipient.decideSAS(matches: false)
        XCTAssertEqual(terminal(rejection), [.sasRejected])
        let peerRejection = await origin.receive(try record(rejection))
        XCTAssertEqual(terminal(peerRejection), [.sasRejected])

        let (activeOrigin, activeRecipient) = try await paired()
        let cancelled = await activeOrigin.cancel()
        XCTAssertEqual(terminal(cancelled), [.cancelled])
        let peerCancellation = await activeRecipient.receive(try record(cancelled))
        XCTAssertEqual(terminal(peerCancellation), [.peerAborted])
    }

    func testExpiryAdmissionReplayAndDurabilityFailuresFailClosed() async throws {
        let clock = UnixClock(1_000)
        let expiring = try CrossDevicePairingRuntimeV1(
            origin: PairingOriginDriverConfigurationV1(
                purpose: .continueSession,
                expiresAt: 1_005,
                endpointCandidates: [],
                oneTimeOpticalSecret: nil
            ),
            now: { clock.now() }
        )
        clock.advance(by: 6)
        let expiration = await expiring.checkExpiration()
        let postExpirationStart = await expiring.start()
        XCTAssertEqual(terminal(expiration), [.expired])
        XCTAssertTrue(postExpirationStart.isEmpty)

        let reservable = try CrossDevicePairingRuntimeV1(origin: PairingOriginDriverConfigurationV1(
            purpose: .continueSession,
            expiresAt: PairingHandshakeV1.unixTimeNow() + 60,
            endpointCandidates: [],
            oneTimeOpticalSecret: nil
        ))
        let firstAdmission = await reservable.admitPeer()
        let secondAdmission = await reservable.admitPeer()
        XCTAssertTrue(firstAdmission.isEmpty)
        XCTAssertEqual(terminal(secondAdmission), [.invalidOrder])

        let (origin, recipient) = try await paired()
        let descriptorFrame = try record(await origin.provideContinuationDescriptor(descriptor()))
        let firstDescriptor = await recipient.receive(descriptorFrame)
        let replayedDescriptor = await recipient.receive(descriptorFrame)
        XCTAssertTrue(terminal(firstDescriptor).isEmpty)
        // No peer frame is legal while the recipient is waiting for its own
        // durable acceptance adapter, so the replay is rejected before a
        // second transaction decode is attempted.
        XCTAssertEqual(terminal(replayedDescriptor), [.invalidOrder])

        let (bootstrapOrigin, bootstrapRecipient) = try await paired(purpose: .bootstrap)
        let keyFrame = try record(await bootstrapRecipient.provideBootstrapRecipientPublicKey(try key()))
        _ = await bootstrapOrigin.receive(keyFrame)
        let failedReceipt = await bootstrapRecipient.bootstrapImportDurablyApplied(
            acceptedHostIDs: [UUID()],
            at: Date()
        )
        XCTAssertEqual(terminal(failedReceipt), [.invalidOrder])
        XCTAssertFalse(failedReceipt.contains {
            if case .outboundRecord = $0 { return true }
            return false
        })
    }

    func testEnrollmentPolicyAndLockInvalidationSendAuthenticatedFailure() async throws {
        let adapter = CrossDeviceEnrollmentAdapterV1(authorizer: TestAuthorizer())
        let (origin, recipient) = try await paired(purpose: .enroll, enrollmentAdapter: adapter)
        let request = EnrollmentRequestV1(
            id: UUID(), hostID: UUID(), hostName: "host", requestingDeviceName: "Android",
            publicKey: try enrollmentKey()
        )
        _ = await origin.receive(try record(await recipient.beginEnrollment(request)))
        let policy = await origin.securityPolicyChanged(to: 99)
        XCTAssertEqual(terminal(policy), [.policyChanged])
        let remotePolicy = await recipient.receive(try record(policy))
        XCTAssertEqual(terminal(remotePolicy), [.failed])

        let (lockOrigin, lockRecipient) = try await paired(purpose: .enroll, enrollmentAdapter: adapter)
        let lockRequest = EnrollmentRequestV1(
            id: UUID(), hostID: UUID(), hostName: "host", requestingDeviceName: "Android",
            publicKey: try enrollmentKey()
        )
        _ = await lockOrigin.receive(try record(await lockRecipient.beginEnrollment(lockRequest)))
        let locked = await lockOrigin.applicationDidLock()
        XCTAssertEqual(terminal(locked), [.applicationLocked])
        let remoteLock = await lockRecipient.receive(try record(locked))
        XCTAssertEqual(terminal(remoteLock), [.failed])
    }

    func testAwaitedEnrollmentApprovalCannotResumeAfterApplicationLock() async throws {
        let authorizer = BlockingAuthorizer()
        let adapter = CrossDeviceEnrollmentAdapterV1(authorizer: authorizer)
        let (origin, recipient) = try await paired(purpose: .enroll, enrollmentAdapter: adapter)
        let request = EnrollmentRequestV1(
            id: UUID(),
            hostID: UUID(),
            hostName: "host",
            requestingDeviceName: "Android",
            publicKey: try enrollmentKey()
        )
        _ = await origin.receive(try record(await recipient.beginEnrollment(request)))
        let scope = OwnerAuthorizationScope(
            routeIdentity: "ssh://alice@host:22",
            hostID: request.hostID,
            publicKeyFingerprint: request.publicKey.fingerprint
        )

        async let suspendedApproval = origin.approveEnrollment(
            scope: scope,
            policyGeneration: 7,
            expiresAt: Date().addingTimeInterval(60)
        )
        await authorizer.waitUntilStarted()
        let lockEvents = await origin.applicationDidLock()
        await authorizer.resume()
        let resumedEvents = await suspendedApproval

        XCTAssertEqual(terminal(lockEvents), [.applicationLocked])
        XCTAssertTrue(resumedEvents.isEmpty)
        XCTAssertFalse(resumedEvents.contains {
            if case .enrollmentInstallationRequired = $0 { return true }
            return false
        })
        let state = await origin.state
        XCTAssertEqual(state, .terminal(.applicationLocked))
    }
}
