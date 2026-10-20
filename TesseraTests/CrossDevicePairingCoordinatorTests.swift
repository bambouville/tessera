import XCTest
@testable import Tessera
import TesseraCore
import CryptoKit
import SwiftData

@MainActor
final class CrossDevicePairingCoordinatorTests: XCTestCase {
    func testGrantMutationRejectsUnsavedUnrelatedRouteEditBeforeReceiptPersistence() throws {
        enum UnexpectedPersistence: Error { case reached }
        let context = ModelContext(try TesseraModelContainer.make(inMemory: true))
        context.autosaveEnabled = false
        let originalIdentity = Identity(name: "Original", user: "test", credentialMode: .none)
        let target = PersistedHost(name: "Grant target", address: "grant.invalid", identity: originalIdentity)
        let unrelated = PersistedHost(name: "Unrelated", address: "original.invalid")
        context.insert(originalIdentity)
        context.insert(target)
        context.insert(unrelated)
        try context.save()

        func snapshot() throws -> ContinuationSecurityPolicySnapshot {
            let hosts = try context.fetch(FetchDescriptor<PersistedHost>())
                .sorted { $0.id.uuidString < $1.id.uuidString }
            return ContinuationSecurityPolicySnapshot(
                hostConnections: hosts.map {
                    .init(id: $0.id, user: $0.effectiveUser, address: $0.address, port: $0.port,
                          transport: $0.transport, launchMode: $0.launchMode,
                          tmuxSessionName: $0.tmuxSessionName, launchCommand: $0.launchCommand,
                          environment: "", startupSnippet: "", portForwardRulesData: nil)
                },
                jumpLinks: [], hostCredentials: [], requiresBiometricForKeyUse: false,
                passwordCredentialRevision: 0
            )
        }
        let acceptedBaseline = try snapshot()
        var adoptedBaseline: ContinuationSecurityPolicySnapshot? = acceptedBaseline
        var generation: UInt64 = 1
        unrelated.address = "edited-without-save.invalid"
        XCTAssertTrue(context.hasChanges)
        let currentSnapshot = try snapshot()
        let publicKey = BootstrapCoordinatorTests.fixturePublicKey()
        let record = BootstrapRecipientGrantRecord(
            hostID: target.id, hostName: target.name, endpoint: "test@grant.invalid:22",
            routeIdentity: "fixture-route", peerDeviceName: "Test peer",
            recipientKey: try BootstrapRecipientKey(storedKeyID: publicKey.id, publicKey: publicKey)
        )
        var reconciled = false
        var persisted = false
        XCTAssertThrowsError(try {
            try PairedBootstrapPersistence.requireCurrentMutation(
                captureFence: { generation },
                reconcile: {
                    reconciled = true
                    if currentSnapshot.invalidates(replacing: acceptedBaseline, allowingCredentialCompletionFor: nil) {
                        generation += 1
                    }
                },
                isAuthorized: { $0 == generation }, isLocked: { false }
            )
            try BootstrapCoordinator.liveRecordRecipientGrant(record, in: context, save: { _ in
                persisted = true
                try PairedBootstrapPersistence.save(
                    approvedSnapshot: snapshot(), previousSnapshot: adoptedBaseline,
                    adopt: { adoptedBaseline = $0 },
                    // Even a regression must not write device-key metadata or
                    // save the user's unrelated edit from this host-free test.
                    persist: { throw UnexpectedPersistence.reached }
                )
            })
        }()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(reconciled)
        XCTAssertEqual(generation, 2)
        XCTAssertFalse(persisted)
        XCTAssertEqual(adoptedBaseline, acceptedBaseline)
        XCTAssertEqual(target.identity?.id, originalIdentity.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Identity>()).count, 1)
        XCTAssertEqual(unrelated.address, "edited-without-save.invalid")
        XCTAssertTrue(context.hasChanges, "Rejecting the grant must preserve the user's unsaved edit")
    }

    func testGrantMutationAllowsCurrentUnlockedAttemptBeforeApprovedSave() throws {
        var baseline: Int? = 1
        var events: [String] = []
        try PairedBootstrapPersistence.requireCurrentMutation(
            captureFence: { events.append("capture"); return 7 },
            reconcile: { events.append("reconcile") },
            isAuthorized: { events.append("authorize"); return $0 == 7 },
            isLocked: { events.append("lock"); return false }
        )
        try PairedBootstrapPersistence.save(
            approvedSnapshot: 2, previousSnapshot: baseline,
            adopt: { baseline = $0; events.append("adopt") },
            persist: { XCTAssertEqual(baseline, 2); events.append("save") }
        )
        XCTAssertEqual(events, ["capture", "reconcile", "authorize", "lock", "adopt", "save"])
    }

    func testApprovedPersistenceAdoptsBeforeSynchronousSaveObserver() throws {
        var baseline: Int? = 1
        var current = 2
        var invalidated = false
        try PairedBootstrapPersistence.save(
            approvedSnapshot: current, previousSnapshot: baseline,
            adopt: { baseline = $0 },
            persist: { invalidated = current != baseline }
        )
        XCTAssertFalse(invalidated, "Synchronous didSave must see the approved model change")
        current = 3
        invalidated = current != baseline
        XCTAssertTrue(invalidated, "A later unrelated save must still invalidate pairing")
    }

    func testApprovedPersistenceRestoresBaselineWhenSaveFails() {
        enum Failure: Error { case save }
        var baseline: Int? = 1
        XCTAssertThrowsError(try PairedBootstrapPersistence.save(
            approvedSnapshot: 2, previousSnapshot: baseline,
            adopt: { baseline = $0 },
            persist: { throw Failure.save }
        ))
        XCTAssertEqual(baseline, 1)
    }

    func testContinuationDeliversOnceAndCompletesAfterExactConnectionCallback() async throws {
        for transport in [HostTransport.ssh, .mosh] {
            for tmux in [false, true] {
                let host = Host(address: "continuation.invalid", user: "test", transport: transport,
                    launchMode: tmux ? .pinnedTmux : .customCommand)
                let descriptor = try SessionActivityDescriptor(
                    host: host, resolvedTmuxSessionName: tmux ? "exact-workspace" : nil
                ).core
                let continuationID = UUID()
                var deliveries = 0
                let adapters = CrossDevicePairingPlatformAdapters(
                    receiveDescriptor: { value, _ in
                        XCTAssertEqual(value.hostID, descriptor.hostID)
                        XCTAssertEqual(value.tmux, descriptor.tmux)
                        deliveries += 1
                        return continuationID
                    }, cancelDescriptor: { _ in },
                    recipientKey: Self.adapters.recipientKey,
                    exportManifest: Self.adapters.exportManifest,
                    importManifest: Self.adapters.importManifest,
                    verifyGrants: Self.adapters.verifyGrants,
                    recordAccess: Self.adapters.recordAccess,
                    freshOwnerApproval: Self.adapters.freshOwnerApproval
                )
                let origin = CrossDevicePairingCoordinator(adapters: adapters, listenerFactory: {
                    PairingLocalTCPListener(endpointEnumerator: PairingCoordinatorFixedEndpointEnumerator())
                })
                let recipient = CrossDevicePairingCoordinator(adapters: adapters)
                defer { origin.cancel(); recipient.cancel() }
                origin.beginOrigin(purpose: .continueSession, descriptor: descriptor)
                try await waitUntil { origin.qrText != nil }
                recipient.beginRecipient(qrText: try XCTUnwrap(origin.qrText))
                try await waitUntil {
                    if case .compareSAS = origin.phase, case .compareSAS = recipient.phase { return true }
                    return false
                }
                origin.decideSAS(matches: true); recipient.decideSAS(matches: true)
                try await waitUntil { deliveries > 0 }
                recipient.continuationDurablyAccepted(continuationID: continuationID, hostID: host.id)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(deliveries, 1, "durable acceptance must not launch a second continuation")
                recipient.continuationConnectionCompleted(continuationID: UUID(), hostID: host.id)
                try await Task.sleep(for: .milliseconds(50))
                if case .completed = recipient.phase { XCTFail("stale connection completed pairing") }
                recipient.continuationConnectionCompleted(continuationID: continuationID, hostID: host.id)
                try await waitUntil {
                    if case .completed = origin.phase, case .completed = recipient.phase { return true }
                    return false
                }
            }
        }
    }

    func testRecipientRetainsAuthenticatedSkippedGrantResults() async throws {
        try await verifyBootstrapReceipt(continueAfterSetup: false)
    }

    func testSetupAndContinueKeepsSenderAliveUntilConnectionReceipt() async throws {
        try await verifyBootstrapReceipt(continueAfterSetup: true)
    }

    private func verifyBootstrapReceipt(continueAfterSetup: Bool) async throws {
        let key = Curve25519.Signing.PrivateKey()
        let line = KeyStore.ed25519AuthorizedKeysLine(publicKey: key.publicKey, comment: "receipt test")
        let blob = String(line.split(separator: " ")[1])
        let recipientKey = DevicePublicKeyDescriptorV2(
            id: UUID(), displayName: "Test recipient", algorithm: .ed25519,
            sshBlob: blob,
            fingerprint: DevicePublicKeyValidator.fingerprint(forSSHBlob: try XCTUnwrap(Data(base64Encoded: blob))),
            protectionClaim: .softwareExportable
        )
        var recorded = false
        var delivered: ContinuationDescriptorV1?
        let continuationID = UUID()
        let grantStatus: BootstrapHostGrantStatusV1 = continueAfterSetup ? .installed : .skipped
        let fixtureHost = PairingReviewHarness.manifest.hosts[0]
        let continuationHost = Host(id: fixtureHost.id, address: fixtureHost.address,
            user: fixtureHost.user, autoTmux: false, launchMode: .customCommand)
        let descriptor = try SessionActivityDescriptor(host: continuationHost, resolvedTmuxSessionName: nil).core
        let adapters = CrossDevicePairingPlatformAdapters(
            receiveDescriptor: { value, _ in
                XCTAssertTrue(continueAfterSetup)
                XCTAssertTrue(recorded, "setup must be durable before continuation")
                XCTAssertNil(delivered, "continuation must be delivered once")
                delivered = value
                return continuationID
            },
            cancelDescriptor: { _ in }, recipientKey: { recipientKey },
            exportManifest: { _ in PairingReviewHarness.manifest },
            importManifest: { manifest, _ in manifest.hosts.map(\.id) },
            verifyGrants: { request in request.acceptance.acceptedHostIDs.map {
                BootstrapHostGrantResultV1(hostID: $0, status: grantStatus)
            } },
            recordAccess: { receipt, _, _ in
                XCTAssertTrue(receipt.results.allSatisfy { $0.status == grantStatus })
                recorded = true
            },
            freshOwnerApproval: { _ in Date() }
        )
        let origin = CrossDevicePairingCoordinator(adapters: adapters, listenerFactory: {
            PairingLocalTCPListener(endpointEnumerator: PairingCoordinatorFixedEndpointEnumerator())
        })
        let recipient = CrossDevicePairingCoordinator(adapters: adapters)
        defer { origin.cancel(); recipient.cancel() }
        origin.beginOrigin(purpose: continueAfterSetup ? .setUpAndContinue : .bootstrap,
            descriptor: continueAfterSetup ? descriptor : nil)
        try await waitUntil { origin.qrText != nil }
        recipient.beginRecipient(qrText: try XCTUnwrap(origin.qrText))
        try await waitUntil {
            if case .compareSAS = origin.phase, case .compareSAS = recipient.phase { return true }
            return false
        }
        origin.decideSAS(matches: true)
        recipient.decideSAS(matches: true)
        try await waitUntil {
            if case .bootstrapOriginApproval = origin.phase { return true }
            return false
        }
        origin.approveBootstrapOrigin()
        try await waitUntil {
            if case .bootstrapRecipientImport = recipient.phase { return true }
            return false
        }
        recipient.approveBootstrapRecipientImport()
        if continueAfterSetup {
            try await waitUntil { delivered != nil }
            if case .completed = origin.phase { XCTFail("sender closed before continuation") }
            recipient.continuationDurablyAccepted(continuationID: continuationID, hostID: descriptor.hostID)
            try await Task.sleep(for: .milliseconds(100))
            recipient.continuationConnectionCompleted(continuationID: continuationID, hostID: descriptor.hostID)
        }
        try await waitUntil {
            if case .completed = recipient.phase { return true }
            return false
        }
        guard case .completed(let result) = recipient.phase else { return XCTFail("missing receipt") }
        let receipt = try XCTUnwrap(result)
        XCTAssertEqual(recipient.presentationPurpose, continueAfterSetup ? .setUpAndContinue : .bootstrap)
        XCTAssertEqual(receipt.direction, .received)
        XCTAssertEqual(recipient.finishedReceivingSetup, !continueAfterSetup,
                       "done returns to Hosts only when no session was continued")
        XCTAssertFalse(origin.finishedReceivingSetup)
        XCTAssertEqual(recipient.presentation.stages.last, continueAfterSetup ? .connect : .transfer)
        XCTAssertTrue(recorded)
        XCTAssertEqual(receipt.hosts.count, 4)
        XCTAssertTrue(receipt.hosts.allSatisfy { $0.status == grantStatus })
        XCTAssertEqual(receipt.hasUnverifiedAccess, !continueAfterSetup &&
            PairingReviewHarness.manifest.hosts.contains { $0.authenticationHint != .password })
        try await waitUntil {
            if case .completed = origin.phase { return true }
            return false
        }
        XCTAssertEqual(origin.presentationPurpose, continueAfterSetup ? .setUpAndContinue : .bootstrap)
        origin.dismiss()
        XCTAssertNil(origin.presentationPurpose)
    }

    func testReceiptDoesNotClaimSkippedAccessIsReady() {
        let receipt = CrossDevicePairingReceipt(direction: .received, hosts: [
            .init(id: UUID(), name: "Fixture", status: .skipped, wasAccepted: true)
        ], optionalCategoryCount: 0)
        XCTAssertTrue(receipt.hasUnverifiedAccess)
    }

    func testReceiptRecognizesExpectedPasswordGrantSkip() {
        let receipt = CrossDevicePairingReceipt(direction: .sent, hosts: [
            .init(id: UUID(), name: "Password fixture", status: .skipped, wasAccepted: true, passwordOnFirstConnect: true)
        ], optionalCategoryCount: 0)
        XCTAssertFalse(receipt.hasUnverifiedAccess)
        XCTAssertEqual(receipt.hosts.first?.presentationOutcome, .passwordNeeded)
    }

    func testFirstConfirmationKeepsCodeVisibleUntilPeerConfirms() async throws {
        let origin = CrossDevicePairingCoordinator(adapters: Self.adapters, listenerFactory: {
            PairingLocalTCPListener(endpointEnumerator: PairingCoordinatorFixedEndpointEnumerator())
        })
        let recipient = CrossDevicePairingCoordinator(adapters: Self.adapters)
        defer { origin.cancel(); recipient.cancel() }
        origin.beginOrigin(purpose: .bootstrap)
        try await waitUntil { origin.qrText != nil }
        recipient.beginRecipient(qrText: try XCTUnwrap(origin.qrText))
        try await waitUntil {
            if case .compareSAS = origin.phase, case .compareSAS = recipient.phase { return true }
            return false
        }
        guard case .compareSAS(let code) = origin.phase else { return XCTFail("missing code") }
        XCTAssertEqual(recipient.phase, .compareSAS(code))
        origin.decideSAS(matches: true)
        XCTAssertEqual(origin.phase, .waitingForPeerSAS(code))
        // A second tap must not re-submit an already consumed consent event.
        origin.decideSAS(matches: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(origin.phase, .waitingForPeerSAS(code))
        XCTAssertEqual(recipient.phase, .compareSAS(code))
        recipient.decideSAS(matches: false)
        try await waitUntil {
            if case .failed = origin.phase { return true }
            return false
        }
    }

    func testScannerPresentationCanTransitionIntoRecipientValidation() async {
        let coordinator = CrossDevicePairingCoordinator(adapters: Self.adapters)
        coordinator.beginScanning()
        XCTAssertEqual(coordinator.phase, .scanning)
        XCTAssertTrue(coordinator.showsPresentation)

        // Regression: the scanner is already presented, but its one manual/QR
        // callback must be able to replace that inert state with recipient
        // validation rather than being rejected as a second active attempt.
        coordinator.beginRecipient(qrText: "not-a-canonical-pairing-offer")
        await Task.yield()
        guard case .failed = coordinator.phase else {
            return XCTFail("recipient validation was not started from scanner")
        }
    }

    func testBackgroundCancelsCameraOnlyScannerState() {
        let coordinator = CrossDevicePairingCoordinator(adapters: Self.adapters)
        coordinator.beginScanning()
        XCTAssertEqual(coordinator.phase, .scanning)
        coordinator.applicationDidLockOrBackground()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(coordinator.showsPresentation)
    }

    func testCancelWhileListenerStartIsQueuedCannotResurrectAttempt() async throws {
        let coordinator = CrossDevicePairingCoordinator(adapters: Self.adapters)
        coordinator.beginOrigin(purpose: .bootstrap)
        XCTAssertEqual(coordinator.phase, .connecting)

        // beginOrigin schedules listener startup after returning to the main
        // executor. Cancelling here must fence that suspended work even if the
        // Network listener later reports ready or failed.
        coordinator.cancel()
        XCTAssertEqual(coordinator.phase, .idle)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(coordinator.isPresented)
    }

    func testCancelAfterOfferClosesTransportAndClearsAttempt() async throws {
        let coordinator = CrossDevicePairingCoordinator(
            adapters: Self.adapters,
            listenerFactory: {
                PairingLocalTCPListener(
                    endpointEnumerator: PairingCoordinatorFixedEndpointEnumerator()
                )
            }
        )
        coordinator.beginOrigin(purpose: .bootstrap)
        try await waitUntil { coordinator.phase == .showingOffer }
        XCTAssertNotNil(coordinator.qrText)

        // Regression: lifecycle invalidation closes the listener before the
        // shared runtime emits its best-effort abort. Dropping that one
        // outbound record must still allow the local cancelled terminal event
        // to clear every per-attempt field.
        coordinator.cancel()
        try await waitUntil { coordinator.phase == .idle }
        XCTAssertNil(coordinator.qrText)
        XCTAssertNil(coordinator.purpose)
        XCTAssertFalse(coordinator.isPresented)

        coordinator.beginScanning()
        XCTAssertEqual(coordinator.phase, .scanning)
        coordinator.cancel()
    }

    func testContinuationReceiptGateRejectsConcurrentHandoffAndDuplicates() {
        var gate = CrossDeviceContinuationReceiptGate()
        let expectedContinuation = UUID()
        let expectedHost = UUID()
        gate.expect(continuationID: expectedContinuation, hostID: expectedHost)

        // A simultaneous Apple Handoff has a different receive ID/host and
        // must not consume this QR-pairing receipt boundary.
        XCTAssertFalse(gate.acceptDurable(continuationID: UUID(), hostID: expectedHost))
        XCTAssertFalse(gate.acceptCompletion(continuationID: expectedContinuation, hostID: expectedHost))
        XCTAssertTrue(gate.acceptDurable(continuationID: expectedContinuation, hostID: expectedHost))
        XCTAssertFalse(gate.acceptDurable(continuationID: expectedContinuation, hostID: expectedHost))
        XCTAssertTrue(gate.acceptCompletion(continuationID: expectedContinuation, hostID: expectedHost))
        XCTAssertFalse(gate.acceptCompletion(continuationID: expectedContinuation, hostID: expectedHost))
    }

    private static let adapters = CrossDevicePairingPlatformAdapters(
        receiveDescriptor: { _, _ in nil },
        cancelDescriptor: { _ in },
        recipientKey: { throw PairingLocalTCPTransportError.network },
        exportManifest: { _ in throw PairingLocalTCPTransportError.network },
        importManifest: { _, _ in throw PairingLocalTCPTransportError.network },
        verifyGrants: { _ in [] },
        recordAccess: { _, _, _ in },
        freshOwnerApproval: { _ in throw PairingLocalTCPTransportError.network }
    )

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                return XCTFail("timed out waiting for pairing coordinator phase")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct PairingCoordinatorFixedEndpointEnumerator: PairingLocalEndpointEnumerating {
    func candidates(port: UInt16) -> [PairingEndpointCandidateV1] {
        [PairingEndpointCandidateV1(host: "127.0.0.1", port: port)]
    }
}
